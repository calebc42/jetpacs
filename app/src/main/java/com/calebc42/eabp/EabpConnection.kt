package com.calebc42.eabp

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Owns one live Emacs connection.
 *
 * Runs a blocking read loop on its own thread and dispatches inbound frames by
 * kind. The connection IS presence: while this object is alive and readable,
 * Emacs is considered up. When it dies, the companion keeps rendering surfaces
 * from cache — Emacs being gone is the default state, not an error.
 */
class EabpConnection(
    private val context: Context,
    private val socket: Socket,
    private val surfaces: SurfaceManager,
    private val onClosed: (EabpConnection) -> Unit,
) {
    private val codec: FrameCodec =
        NdjsonFrameCodec(socket.getInputStream(), socket.getOutputStream())

    @Volatile private var running = true

    /** Capabilities granted to this session (set during the handshake). */
    @Volatile var granted: List<String> = emptyList()
        private set

    @Volatile var helloComplete = false
        private set

    // What the companion can offer in v0. Anything Emacs `wants` that isn't here
    // is simply not granted — the forward-compat mechanism from the spec.
    private val supported = setOf(
        "surfaces.widget", "surfaces.notification", "surfaces.dialog",
        "capabilities", "triggers", "queue.replay",
    )

    fun start() {
        thread(name = "eabp-conn") {
            try {
                while (running) {
                    val frame = codec.read() ?: break
                    dispatch(frame)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Read loop ended: ${e.message}")
            } finally {
                shutdown()
            }
        }
    }

    /**
     * Thread-safe send (codec write is itself synchronized).
     * Returns true only if the frame was written; on failure the connection
     * is torn down and false is returned, so callers that must not lose
     * events (the replay loop, the action receiver) can react.
     */
    fun send(frame: Frame): Boolean {
        return try {
            codec.write(frame)
            Log.d(TAG, "=> ${frame.kind} (${frame.id})")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Send failed: ${e.message}")
            shutdown()
            false
        }
    }

    private fun dispatch(frame: Frame) {
        Log.d(TAG, "<= ${frame.kind} (${frame.id})")
        // Everything except the handshake itself requires a completed handshake.
        if (!helloComplete && frame.kind != Kind.SESSION_HELLO) {
            send(error(frame.id, "proto-version", "handshake required before '${frame.kind}'"))
            return
        }
        when (frame.kind) {
            Kind.SESSION_HELLO -> handleHello(frame)
            Kind.PING -> send(Frame(kind = Kind.PONG, replyTo = frame.id))
            "queue.replay" -> handleQueueReplay(frame)

            "surface.update" -> {
                val err = surfaces.update(frame.payload)
                if (err == null) send(Frame(kind = Kind.ACK, replyTo = frame.id))
                else send(error(frame.id, "spec-invalid", err))
            }
            "surface.remove" -> {
                surfaces.remove(frame.payload.optString("surface"))
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            Kind.DIALOG_SHOW -> {
                EabpRuntime.dialogState.show(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.DIALOG_DISMISS -> {
                EabpRuntime.dialogState.dismiss()
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // StateFlow setters are thread-safe; Compose collects on the UI
            // thread — no main-looper hop needed (the dialog path never had one).
            Kind.PIE_MENU_SHOW -> {
                EabpRuntime.pieMenuState.show(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.PIE_MENU_DISMISS -> {
                EabpRuntime.pieMenuState.dismiss()
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // capability.*, trigger.*, state.* dispatch lands in later phases.
            else -> send(error(frame.id, "spec-invalid", "unhandled kind '${frame.kind}'"))
        }
    }

    private fun handleHello(hello: Frame) {
        val proto = hello.payload.optInt("protocol", 0)
        if (proto != EABP_PROTOCOL_VERSION) {
            send(error(hello.id, "proto-version",
                "companion speaks v$EABP_PROTOCOL_VERSION, client offered v$proto"))
            shutdown()
            return
        }

        val wants = hello.payload.optJSONArray("wants").toStringList()
        granted = wants.filter { it in supported }

        // Already on the "eabp-conn" background thread: safe to query Room.
        val dbCount = EabpRuntime.database?.eventDao()?.count() ?: 0

        val welcome = Frame(
            kind = Kind.SESSION_WELCOME,
            replyTo = hello.id,
            payload = JSONObject().apply {
                put("protocol", EABP_PROTOCOL_VERSION)
                put("server", "eabp-companion/0.2 android/${Build.VERSION.SDK_INT}")
                put("granted", JSONArray(granted))
                put("permissions", JSONObject().apply {
                    put("post_notifications", hasNotificationPermission())
                    put("exact_alarms", canScheduleExactAlarms())
                })
                put("surfaces", surfaces.revisionSnapshot())
                put("queued_events", dbCount)
            },
        )
        helloComplete = true
        EabpRuntime.setConnected(true)
        send(welcome)
        // If a wake notification got the user here, its job is done.
        EmacsWaker.clear(context)
        Log.i(TAG, "Handshake complete. granted=$granted queued=$dbCount")
    }

    /**
     * Stream queued events oldest-first, deleting EACH event only after its
     * frame was successfully written — a connection death mid-replay leaves
     * the remainder intact for the next session (the v1 bulk-delete lost
     * them). Expired events (per-event TTL) are dropped without delivery.
     * Ends with `queue.drained` carrying counts.
     */
    /** Guards against concurrent replays (e.g. duplicate replay requests). */
    private val replayInFlight = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun handleQueueReplay(requestFrame: Frame) {
        if (!replayInFlight.compareAndSet(false, true)) {
            Log.w(TAG, "Replay already in flight; ignoring duplicate request")
            send(Frame(kind = "queue.drained", replyTo = requestFrame.id,
                payload = JSONObject().put("delivered", 0).put("expired", 0)
                    .put("duplicate_request", true)))
            return
        }
        thread(name = "EabpReplay") {
            try {
                replayLocked(requestFrame)
            } finally {
                replayInFlight.set(false)
            }
        }
    }

    private fun replayLocked(requestFrame: Frame) {
        val dao = EabpRuntime.database?.eventDao()
        if (dao == null) {
            send(Frame(kind = "queue.drained", replyTo = requestFrame.id,
                payload = JSONObject().put("delivered", 0).put("expired", 0)))
            return
        }

        val now = System.currentTimeMillis()
        val events = dao.getAllChronological()
        var delivered = 0
        var expired = 0
        Log.i(TAG, "Replaying ${events.size} offline events to Emacs")

        for (queued in events) {
            if (!running) return

            val ttl = queued.ttlS
            if (ttl != null && now - queued.queuedAt > ttl * 1000) {
                dao.delete(queued)
                expired++
                continue
            }

            val payload = replayPayload(queued)
            if (payload == null) {           // unparseable: drop, don't wedge
                dao.delete(queued)
                continue
            }

            val kind = queued.kind.ifEmpty { "event.action" }
            if (!send(Frame(kind = kind, payload = payload))) {
                Log.w(TAG, "Replay aborted after $delivered events; remainder kept")
                return
            }
            dao.delete(queued)
            delivered++
        }

        send(Frame(kind = "queue.drained", replyTo = requestFrame.id,
            payload = JSONObject().put("delivered", delivered).put("expired", expired)))
    }

    /** Shape-preserving payload; reconstructs legacy v1 rows. */
    private fun replayPayload(q: QueuedEvent): JSONObject? = runCatching {
        if (q.payload.isNotEmpty()) {
            JSONObject(q.payload).put("queued_at", q.queuedAt)
        } else {
            JSONObject().apply {
                put("surface", q.surface)
                put("revision_seen", q.revisionSeen)
                put("action", q.action)
                put("args", JSONObject(q.args))
                put("fields", JSONObject.NULL)
                put("queued_at", q.queuedAt)
            }
        }
    }.getOrNull()

    private fun error(replyTo: String?, code: String, detail: String): Frame =
        Frame(
            kind = Kind.ERROR,
            replyTo = replyTo,
            payload = JSONObject().apply {
                put("code", code)
                put("detail", detail)
            },
        )

    private fun hasNotificationPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else true

    private fun canScheduleExactAlarms(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else true

    fun shutdown() {
        if (!running) return
        running = false
        codec.close()
        runCatching { socket.close() }
        onClosed(this)
    }

    private fun JSONArray?.toStringList(): List<String> =
        if (this == null) emptyList() else (0 until length()).map { optString(it) }

    companion object {
        private const val TAG = "EabpConnection"
    }
}