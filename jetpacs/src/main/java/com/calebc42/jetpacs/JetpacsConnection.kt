package com.calebc42.jetpacs

import android.content.Context
import android.os.Build
import android.util.Log
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
class JetpacsConnection(
    private val context: Context,
    private val socket: Socket,
    private val surfaces: SurfaceManager,
    private val onClosed: (JetpacsConnection) -> Unit,
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
        "capabilities", "triggers", "queue.replay", "theme",
    )

    fun start() {
        thread(name = "jetpacs-conn") {
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
        if (!helloComplete && frame.kind != Kind.SESSION_HELLO &&
            frame.kind != Kind.AUTH_RESPONSE
        ) {
            send(error(frame.id, "proto-version", "handshake required before '${frame.kind}'"))
            return
        }
        when (frame.kind) {
            Kind.SESSION_HELLO -> handleHello(frame)
            Kind.AUTH_RESPONSE -> handleAuthResponse(frame)
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
                JetpacsRuntime.dialogState.show(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.DIALOG_DISMISS -> {
                JetpacsRuntime.dialogState.dismiss()
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // StateFlow setters are thread-safe; Compose collects on the UI
            // thread — no main-looper hop needed (the dialog path never had one).
            Kind.PIE_MENU_SHOW -> {
                JetpacsRuntime.pieMenuState.show(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.PIE_MENU_DISMISS -> {
                JetpacsRuntime.pieMenuState.dismiss()
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // Completion candidates for the editor's suggestion strip.
            // Ephemeral by design: not ACKed into the surface store, no
            // revision, no persistence — a stale one is just ignored.
            Kind.COMPLETIONS_SHOW -> {
                JetpacsRuntime.completionState.show(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // Editor-sync pushes (see jetpacs-sync.el): flymake diagnostics for
            // a synced file, and Emacs asking for a fresh full-text open
            // after a seq mismatch. Same ephemeral rules as completions.
            Kind.DIAGNOSTICS_SHOW -> {
                JetpacsRuntime.editSyncState.showDiagnostics(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.EDIT_RESYNC -> {
                JetpacsRuntime.editSyncState.requestResync(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.ELDOC_SHOW -> {
                JetpacsRuntime.editSyncState.showEldoc(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }
            Kind.FONTIFY_SHOW -> {
                JetpacsRuntime.editSyncState.showFontify(frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // Emacs mirroring its theme onto the companion (SPEC §7). Each
            // push replaces the previous; `colors: null` clears back to the
            // companion's own scheme. Persisted so the look survives restarts.
            Kind.THEME_SET -> {
                JetpacsRuntime.setEmacsTheme(context, frame.payload)
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // Upcoming timed org items → exact alarms. Each set replaces the
            // previous one, so stale reminders can't fire.
            "reminders.set" -> {
                ReminderScheduler.replaceAll(
                    context, frame.payload.optJSONArray("reminders"))
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // Echo-area messages mirrored from Emacs (throttled Emacs-side).
            // Toast genuinely needs the main looper — unlike the StateFlow
            // paths above, it constructs platform UI.
            Kind.TOAST_SHOW -> {
                val text = frame.payload.optString("text")
                if (text.isNotEmpty()) {
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        android.widget.Toast.makeText(context, text, android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
                send(Frame(kind = Kind.ACK, replyTo = frame.id))
            }

            // The Emacs → device effector channel (SPEC §10).
            Kind.CAPABILITY_INVOKE -> handleCapabilityInvoke(frame)

            // The device → Emacs event-source channel (SPEC §11): persist
            // the replace-set and re-arm listeners. Already off-main (the
            // read thread), so the Room writes are legal here.
            Kind.TRIGGERS_SET -> {
                val host = JetpacsRuntime.triggerHost
                if (host == null) {
                    send(error(frame.id, "spec-invalid", "trigger host not running"))
                } else {
                    val err = host.replaceSet(frame.payload.optJSONArray("triggers"))
                    if (err == null) send(Frame(kind = Kind.ACK, replyTo = frame.id))
                    else send(error(frame.id, "spec-invalid", err))
                }
            }

            else -> send(error(frame.id, "spec-invalid", "unhandled kind '${frame.kind}'"))
        }
    }

    /** Server nonce for the in-flight auth round, nulled once it completes. */
    @Volatile private var authNonce: String? = null

    /** The hello frame id the eventual welcome must reply to. */
    @Volatile private var pendingHelloId: String? = null

    private fun handleHello(hello: Frame) {
        val proto = hello.payload.optInt("protocol", 0)
        if (proto != Jetpacs_PROTOCOL_VERSION) {
            send(error(hello.id, "proto-version",
                "companion speaks v$Jetpacs_PROTOCOL_VERSION, client offered v$proto"))
            shutdown()
            return
        }

        val wants = hello.payload.optJSONArray("wants").toStringList()
        granted = wants.filter { it in supported }

        // Pairing gate: don't welcome yet — challenge. Emacs must prove it
        // holds the token this device shows on its pairing screen.
        val nonce = JetpacsAuth.newNonce()
        authNonce = nonce
        pendingHelloId = hello.id
        send(Frame(
            kind = Kind.AUTH_CHALLENGE,
            replyTo = hello.id,
            payload = JSONObject().put("nonce", nonce),
        ))
    }

    private fun handleAuthResponse(frame: Frame) {
        val serverNonce = authNonce
        val clientNonce = frame.payload.optString("nonce")
        val mac = frame.payload.optString("mac")
        if (serverNonce == null || helloComplete) {
            send(error(frame.id, "auth-failed", "no challenge outstanding"))
            shutdown()
            return
        }
        val token = JetpacsAuth.token(context)
        val expected = JetpacsAuth.hmacHex(token, "jetpacs1:client:$serverNonce:$clientNonce")
        if (clientNonce.isEmpty() || !JetpacsAuth.macEquals(mac, expected)) {
            Log.w(TAG, "Pairing failed: bad client MAC")
            send(error(frame.id, "auth-failed",
                "pairing token mismatch — set jetpacs-auth-token to the token " +
                    "shown on the companion's pairing screen"))
            shutdown()
            return
        }
        authNonce = null

        // Already on the "jetpacs-conn" background thread: safe to query Room.
        val dbCount = JetpacsRuntime.database?.eventDao()?.count() ?: 0
        JetpacsRuntime.refreshQueuedCount()

        val welcome = Frame(
            kind = Kind.SESSION_WELCOME,
            replyTo = pendingHelloId,
            payload = JSONObject().apply {
                put("protocol", Jetpacs_PROTOCOL_VERSION)
                put("server", "jetpacs-companion/0.2 android/${Build.VERSION.SDK_INT}")
                // The mutual half: prove WE hold the token too, so Emacs can
                // refuse a rogue app that squatted the port before we bound it.
                put("server_proof",
                    JetpacsAuth.hmacHex(token, "jetpacs1:server:$clientNonce:$serverNonce"))
                put("granted", JSONArray(granted))
                // The node-vocabulary catalog (SPEC §3, §9): every widget
                // node this build can render. Always present (rendering
                // app:* surfaces is core, not a negotiated capability) so a
                // newer client can gate a too-new node and render a fallback
                // rather than have it silently degrade on an old companion.
                put("node_types", JSONArray(SDUI_NODE_TYPES.sorted()))
                // The device report (SPEC §10–§11): what capability.invoke
                // can do here, the permission map so elisp degrades
                // gracefully instead of invoking blind, and the trigger-type
                // catalog so the client can skip a registration this
                // companion would reject (one unknown type must never cost
                // the whole replace-set).
                if ("capabilities" in granted || "triggers" in granted) {
                    put("device", JSONObject().apply {
                        if ("capabilities" in granted) {
                            put("caps", JSONArray(DeviceCapabilities.names()))
                            put("perms", DeviceCapabilities.permissionMap(context))
                        }
                        if ("triggers" in granted) {
                            put("trigger_types",
                                JSONArray(TriggerHost.SUPPORTED_TYPES.sorted()))
                        }
                    })
                }
                put("surfaces", surfaces.revisionSnapshot())
                put("queued_events", dbCount)
            },
        )
        helloComplete = true
        JetpacsAuth.markPaired(context)
        JetpacsRuntime.setPaired()
        JetpacsRuntime.setConnected(true)
        send(welcome)
        // If a wake notification got the user here, its job is done.
        EmacsWaker.clear(context)
        Log.i(TAG, "Handshake complete (paired). granted=$granted queued=$dbCount")
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
        thread(name = "JetpacsReplay") {
            try {
                replayLocked(requestFrame)
            } finally {
                // A send can fail after some rows were already delivered and
                // deleted. Keep the UI's waiting count truthful on every exit,
                // not only after a completely drained replay.
                JetpacsRuntime.refreshQueuedCount()
                replayInFlight.set(false)
            }
        }
    }

    private fun replayLocked(requestFrame: Frame) {
        val dao = JetpacsRuntime.database?.eventDao()
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

    /**
     * SPEC §10: run a device capability and reply with `capability.result`
     * or a typed error the client can act on (grey out, deep-link to the
     * grant screen). Runs on the read-loop thread; capabilities must stay
     * quick or hop threads themselves.
     */
    private fun handleCapabilityInvoke(frame: Frame) {
        val cap = frame.payload.optString("cap")
        val args = frame.payload.optJSONObject("args") ?: JSONObject()
        try {
            val result = DeviceCapabilities.invoke(context, cap, args)
            send(Frame(
                kind = Kind.CAPABILITY_RESULT,
                replyTo = frame.id,
                payload = JSONObject().apply {
                    put("ok", true)
                    if (result.length() > 0) put("result", result)
                },
            ))
        } catch (e: CapabilityException) {
            Log.i(TAG, "capability.invoke $cap failed: ${e.code} (${e.message})")
            send(Frame(
                kind = Kind.ERROR,
                replyTo = frame.id,
                payload = JSONObject().apply {
                    put("code", e.code)
                    put("detail", e.message)
                    e.perm?.let { put("perm", it) }
                    e.settings?.let { put("settings", it) }
                },
            ))
        }
    }

    private fun error(replyTo: String?, code: String, detail: String): Frame =
        Frame(
            kind = Kind.ERROR,
            replyTo = replyTo,
            payload = JSONObject().apply {
                put("code", code)
                put("detail", detail)
            },
        )

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
        private const val TAG = "JetpacsConnection"
    }
}
