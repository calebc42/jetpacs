package com.calebc42.jetpacs

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Owns one live Emacs connection, speaking JSON-RPC 2.0 over
 * Content-Length frames (SPEC-2 §§2–3).
 *
 * Two threads, split by SPEC-2 §5: a reader that drains the socket as
 * fast as frames arrive and feeds the [InboundPipeline] (conflating
 * latest-wins traffic, bounding everything), and a dispatcher that
 * processes surviving messages in order. The split is the backpressure:
 * a burst of snapshots costs one render of the newest per surface, not
 * a render of every frame that sat in the pipe.
 *
 * The connection IS presence: while this object is alive and readable,
 * Emacs is considered up. When it dies, the companion keeps rendering
 * surfaces from cache — Emacs being gone is the default state, not an
 * error.
 */
class JetpacsConnection(
    private val context: Context,
    private val socket: Socket,
    private val surfaces: SurfaceManager,
    private val onClosed: (JetpacsConnection) -> Unit,
) {
    private val codec: FrameCodec =
        ContentLengthFrameCodec(socket.getInputStream(), socket.getOutputStream())

    private val pipeline = InboundPipeline()

    @Volatile private var running = true

    /** Capabilities granted to this session (set during the handshake). */
    @Volatile var granted: List<String> = emptyList()
        private set

    @Volatile var helloComplete = false
        private set

    // What the companion can offer. Anything Emacs `wants` that isn't here
    // is simply not granted — the forward-compat mechanism from the spec.
    private val supported = setOf(
        "surfaces.widget", "surfaces.notification", "surfaces.dialog",
        "capabilities", "triggers", "queue.replay", "theme",
        // This companion partitions reminder alarms by owner, so one app's
        // `reminders.set` never cancels another's. Emacs gates the scoped
        // send on this grant (else it degrades — see jetpacs-reminders-owner-set).
        "reminders.owner",
    )

    fun start() {
        thread(name = "jetpacs-read") {
            try {
                while (running) {
                    val msg = codec.read() ?: break
                    if (!pipeline.offer(msg, conflationKey(msg))) {
                        // §5 rule 4: bounded queue exhausted — the peer is
                        // flooding the un-droppable classes. Fail closed at
                        // the connection level; outstanding requests die
                        // with it, cleanly.
                        Log.e(TAG, "Inbound queue exhausted; refusing 1401 and closing")
                        notify(Method.LOG_ERROR, logErrorParams(
                            EbpError.OVERLOADED, "inbound queue exhausted",
                            kindData("overloaded")))
                        break
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Read loop ended: ${e.message}")
            } finally {
                pipeline.close()
                shutdown()
            }
        }
        thread(name = "jetpacs-dispatch") {
            try {
                while (true) dispatch(pipeline.take() ?: break)
            } catch (e: Exception) {
                Log.w(TAG, "Dispatch loop ended: ${e.message}")
            } finally {
                if (pipeline.conflated > 0)
                    Log.i(TAG, "Conflation dropped ${pipeline.conflated} superseded frame(s)")
                shutdown()
            }
        }
    }

    /**
     * SPEC-2 §5 rule 1 — the latest-wins classes and their keys. A frame
     * with a key supersedes an unprocessed queued frame with the same key:
     * surfaces by the revision guard, annotations by their §8 seq discard,
     * the theme by replacement. Ordered and event traffic returns null and
     * is never conflated.
     */
    private fun conflationKey(msg: RpcIn): String? {
        val n = msg as? RpcNotification ?: return null
        fun keyed(prefix: String, field: String): String? =
            n.params.optString(field).takeIf { it.isNotEmpty() }?.let { "$prefix/$it" }
        return when (n.method) {
            Method.SURFACE_UPDATE -> keyed("surface", "surface")
            Method.THEME_SET -> "theme"
            Method.ELDOC_SHOW -> keyed("eldoc", "id")
            Method.DIAGNOSTICS_SHOW -> keyed("diagnostics", "id")
            Method.FONTIFY_SHOW -> keyed("fontify", "id")
            else -> null
        }
    }

    // ─── Outbound ────────────────────────────────────────────────────────────

    /**
     * Fire-and-forget notification (thread-safe; codec write is
     * synchronized). True only if the frame was written; on a dead socket
     * the connection is torn down and false returned, so callers that must
     * not lose events (the replay loop, the action receiver) can react.
     * An over-cap frame is refused locally without costing the connection.
     */
    fun notify(method: String, params: JSONObject): Boolean {
        val ok = writeMessage(Rpc.notification(method, params))
        if (ok) Log.d(TAG, "=> $method")
        return ok
    }

    private fun respond(id: Any, result: JSONObject): Boolean =
        writeMessage(Rpc.response(id, result))

    private fun respondError(id: Any?, code: Int, message: String, data: JSONObject? = null): Boolean =
        writeMessage(Rpc.error(id, code, message, data))

    private fun kindData(kind: String): JSONObject = JSONObject().put("kind", kind)

    /** `log.error` params: an error object minus the id (SPEC-2 §2.3). */
    private fun logErrorParams(code: Int, message: String, data: JSONObject? = null): JSONObject =
        JSONObject().apply {
            put("code", code)
            put("message", message)
            data?.let { put("data", it) }
        }

    private fun writeMessage(message: JSONObject): Boolean = try {
        codec.write(message)
        true
    } catch (e: FrameTooLargeException) {
        // Sender-side frame cap (SPEC-2 §2.2): refuse locally, keep the
        // connection — prefer a missing update to an oversized frame.
        Log.w(TAG, "Refused oversized outbound frame: ${e.message}")
        false
    } catch (e: Exception) {
        Log.w(TAG, "Send failed: ${e.message}")
        shutdown()
        false
    }

    // ─── Inbound dispatch ────────────────────────────────────────────────────

    private fun dispatch(msg: RpcIn) {
        when (msg) {
            is RpcOversize -> {
                // Receiver-side frame cap: the body was skipped byte-exactly
                // and never parsed, so there is no id to answer — the typed
                // refusal rides log.error and the connection lives.
                Log.w(TAG, "Skipped oversized inbound frame (${msg.bytes} > ${msg.max} bytes)")
                notify(Method.LOG_ERROR, logErrorParams(
                    EbpError.FRAME_TOO_LARGE, "frame skipped unread",
                    kindData("frame-too-large")
                        .put("bytes", msg.bytes).put("max", msg.max)))
            }
            is RpcMalformed -> {
                Log.w(TAG, "Malformed frame: ${msg.why}")
                respondError(null, msg.code, msg.why)
            }
            is RpcResponse ->
                Log.w(TAG, "Unexpected response for id ${msg.id} (companion sent no request)")
            is RpcRequest -> dispatchRequest(msg)
            is RpcNotification -> dispatchNotification(msg)
        }
    }

    private fun dispatchRequest(req: RpcRequest) {
        Log.d(TAG, "<= ${req.method} (#${req.id})")
        // Fail-closed dispatcher rule (SPEC-2 §3): until the proof
        // completes, every other request is refused BY EXPLICIT ANSWER —
        // never silently, never fail-open.
        if (!helloComplete &&
            req.method != Method.SESSION_HELLO && req.method != Method.AUTH_RESPONSE
        ) {
            respondError(req.id, EbpError.NOT_AUTHENTICATED,
                "handshake required before '${req.method}'", kindData("not-authenticated"))
            return
        }
        when (req.method) {
            Method.SESSION_HELLO -> handleHello(req)
            Method.AUTH_RESPONSE -> handleAuthResponse(req)
            Method.CAPABILITY_INVOKE -> handleCapabilityInvoke(req)
            Method.QUEUE_REPLAY -> handleQueueReplay(req)
            Method.TRIGGERS_SET -> handleTriggersSet(req)
            Method.REMINDERS_SET -> handleRemindersSet(req)
            in Method.CLIENT_NOTIFICATIONS -> respondError(
                req.id, EbpError.INVALID_REQUEST,
                "'${req.method}' is a notification, not a request", kindData("not-a-request"))
            in Method.COMPANION_SENDS -> respondError(
                req.id, EbpError.INVALID_REQUEST,
                "'${req.method}' travels companion → client", kindData("wrong-direction"))
            // Unknown method: -32601, and the connection lives — the
            // forward-compat rule, request half.
            else -> respondError(req.id, EbpError.METHOD_NOT_FOUND,
                "unknown method '${req.method}'", kindData("method-not-found"))
        }
    }

    private fun dispatchNotification(n: RpcNotification) {
        Log.d(TAG, "<= ${n.method}")
        if (!helloComplete) {
            // Fail-closed, notification half: dropped, not dispatched.
            Log.w(TAG, "Dropped pre-handshake notification '${n.method}'")
            return
        }
        when (n.method) {
            Method.SURFACE_UPDATE -> {
                val err = surfaces.update(n.params)
                // A notification has no reply; a refused update is an
                // unsolicited fault, so the typed refusal rides log.error.
                if (err != null) notify(Method.LOG_ERROR, logErrorParams(
                    EbpError.SPEC_INVALID, "surface.update refused: $err",
                    kindData("spec-invalid")))
            }
            Method.SURFACE_REMOVE -> surfaces.remove(n.params.optString("surface"))

            Method.DIALOG_SHOW -> JetpacsRuntime.dialogState.show(n.params)
            Method.DIALOG_DISMISS -> JetpacsRuntime.dialogState.dismiss()

            // StateFlow setters are thread-safe; Compose collects on the UI
            // thread — no main-looper hop needed (the dialog path never had one).
            Method.PIE_MENU_SHOW -> JetpacsRuntime.pieMenuState.show(n.params)
            Method.PIE_MENU_DISMISS -> JetpacsRuntime.pieMenuState.dismiss()

            // Completion candidates for the editor's suggestion strip.
            // Ephemeral by design: not persisted, no revision — a stale one
            // is just ignored.
            Method.COMPLETIONS_SHOW -> JetpacsRuntime.completionState.show(n.params)

            // Editor-sync pushes (see jetpacs-sync.el): flymake diagnostics
            // for a synced file, and Emacs asking for a fresh full-text open
            // after a seq mismatch. Same ephemeral rules as completions.
            Method.DIAGNOSTICS_SHOW -> JetpacsRuntime.editSyncState.showDiagnostics(n.params)
            Method.EDIT_RESYNC -> JetpacsRuntime.editSyncState.requestResync(n.params)
            Method.EDIT_APPLY -> JetpacsRuntime.editSyncState.showApply(n.params)
            Method.ELDOC_SHOW -> JetpacsRuntime.editSyncState.showEldoc(n.params)
            Method.FONTIFY_SHOW -> JetpacsRuntime.editSyncState.showFontify(n.params)

            // Emacs mirroring its theme onto the companion (SPEC §7). Each
            // push replaces the previous; `colors: null` clears back to the
            // companion's own scheme. Persisted so the look survives restarts.
            Method.THEME_SET -> JetpacsRuntime.setEmacsTheme(context, n.params)

            // Echo-area messages mirrored from Emacs (throttled Emacs-side).
            // Toast genuinely needs the main looper — unlike the StateFlow
            // paths above, it constructs platform UI.
            Method.TOAST_SHOW -> {
                val text = n.params.optString("text")
                if (text.isNotEmpty()) {
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        android.widget.Toast.makeText(
                            context, text, android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
            }

            // Cancellation channel (SPEC-2 §2.3). The first cut has no
            // cancellable requests companion-side; acknowledge by log only.
            Method.RPC_CANCEL ->
                Log.i(TAG, "rpc.cancel for #${n.params.opt("id")} — nothing cancellable")

            in Method.COMPANION_SENDS ->
                Log.w(TAG, "Dropped wrong-direction notification '${n.method}'")
            in Method.REQUESTS ->
                Log.w(TAG, "Dropped '${n.method}' sent without an id (it is a request)")
            // Unknown notification: logged and dropped, connection lives —
            // the forward-compat rule, notification half.
            else -> Log.i(TAG, "Unknown notification '${n.method}' — dropped")
        }
    }

    // ─── Handshake (SPEC-2 §3) ───────────────────────────────────────────────

    /** Server nonce for the in-flight auth round, nulled once it completes. */
    @Volatile private var authNonce: String? = null

    private fun handleHello(req: RpcRequest) {
        val proto = req.params.optInt("protocol", 0)
        if (proto != JETPACS_PROTOCOL_VERSION) {
            respondError(req.id, EbpError.PROTO_VERSION,
                "companion speaks v$JETPACS_PROTOCOL_VERSION, client offered v$proto",
                kindData("proto-version"))
            shutdown()
            return
        }

        val wants = req.params.optJSONArray("wants").toStringList()
        granted = wants.filter { it in supported }

        // Pairing gate: the challenge IS the hello's response (SPEC-2 §3),
        // which makes the ordering structural. Emacs must prove it holds
        // the token this device shows on its pairing screen.
        val nonce = JetpacsAuth.newNonce()
        authNonce = nonce
        respond(req.id, JSONObject().put("nonce", nonce))
    }

    private fun handleAuthResponse(req: RpcRequest) {
        val serverNonce = authNonce
        val clientNonce = req.params.optString("nonce")
        val mac = req.params.optString("mac")
        if (serverNonce == null || helloComplete) {
            respondError(req.id, EbpError.AUTH_FAILED, "no challenge outstanding",
                kindData("auth-failed"))
            shutdown()
            return
        }
        val token = JetpacsAuth.token(context)
        val expected = JetpacsAuth.hmacHex(token, "ebp1:client:$serverNonce:$clientNonce")
        if (clientNonce.isEmpty() || !JetpacsAuth.macEquals(mac, expected)) {
            Log.w(TAG, "Pairing failed: bad client MAC")
            respondError(req.id, EbpError.AUTH_FAILED,
                "pairing token mismatch — set jetpacs-auth-token to the token " +
                    "shown on the companion's pairing screen",
                kindData("auth-failed"))
            shutdown()
            return
        }
        authNonce = null

        // Already on the dispatch background thread: safe to query Room.
        val dbCount = JetpacsRuntime.database?.eventDao()?.count() ?: 0
        JetpacsRuntime.refreshQueuedCount()

        // The welcome (the treaty) is the auth.response's response.
        val welcome = JSONObject().apply {
            put("protocol", JETPACS_PROTOCOL_VERSION)
            put("server", "jetpacs-companion/0.3 android/${Build.VERSION.SDK_INT}")
            // The mutual half: prove WE hold the token too, so Emacs can
            // refuse a rogue app that squatted the port before we bound it.
            put("server_proof",
                JetpacsAuth.hmacHex(token, "ebp1:server:$clientNonce:$serverNonce"))
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
                        // The sample-able predicate catalog (SPEC §11
                        // "State predicates & sampling") — what a `when`
                        // gate may reference. Negotiated separately from
                        // trigger_types: sample-ability ≠ trigger-ability.
                        put("state_types",
                            JSONArray(StateSampler.STATE_TYPES.sorted()))
                    }
                })
            }
            put("surfaces", surfaces.revisionSnapshot())
            put("queued_events", dbCount)
        }
        helloComplete = true
        JetpacsAuth.markPaired(context)
        JetpacsRuntime.setPaired()
        JetpacsRuntime.setConnected(true)
        respond(req.id, welcome)
        // If a wake notification got the user here, its job is done.
        EmacsWaker.clear(context)
        Log.i(TAG, "Handshake complete (paired). granted=$granted queued=$dbCount")
    }

    // ─── Requests above the handshake ────────────────────────────────────────

    /** Guards against concurrent replays (e.g. duplicate replay requests). */
    private val replayInFlight = AtomicBoolean(false)

    /**
     * Stream queued events oldest-first as notifications, deleting EACH
     * event only after its frame was successfully written — a connection
     * death mid-replay leaves the remainder intact for the next session.
     * Expired events (per-event TTL) are dropped without delivery. The
     * drain summary is the request's response (v1's `queue.drained`
     * dissolved into it).
     */
    private fun handleQueueReplay(req: RpcRequest) {
        if (!replayInFlight.compareAndSet(false, true)) {
            Log.w(TAG, "Replay already in flight; answering duplicate immediately")
            respond(req.id, JSONObject()
                .put("delivered", 0).put("expired", 0).put("duplicate_request", true))
            return
        }
        thread(name = "JetpacsReplay") {
            try {
                replayLocked(req)
            } finally {
                // A send can fail after some rows were already delivered and
                // deleted. Keep the UI's waiting count truthful on every exit,
                // not only after a completely drained replay.
                JetpacsRuntime.refreshQueuedCount()
                replayInFlight.set(false)
            }
        }
    }

    private fun replayLocked(req: RpcRequest) {
        val dao = JetpacsRuntime.database?.eventDao()
        if (dao == null) {
            respond(req.id, JSONObject().put("delivered", 0).put("expired", 0))
            return
        }

        val now = System.currentTimeMillis()
        val events = dao.getAllChronological()
        var delivered = 0
        var expired = 0
        Log.i(TAG, "Replaying ${events.size} offline events to Emacs")

        for (queued in events) {
            // The connection died: the request dies with it (SPEC-2 §2.3);
            // the remainder stays queued for the next session.
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

            val method = queued.kind.ifEmpty { Method.EVENT_ACTION }
            if (!notify(method, payload)) {
                Log.w(TAG, "Replay aborted after $delivered events; remainder kept")
                return
            }
            dao.delete(queued)
            delivered++
        }

        respond(req.id, JSONObject().put("delivered", delivered).put("expired", expired))
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
     * SPEC §10: run a device capability. The result is the response —
     * v1's `capability.result` and its dead `ok:false` state dissolved;
     * failures are typed errors (1001–1003) whose `data` carries the
     * remedy (`perm`, `settings`) for the client to act on.
     */
    private fun handleCapabilityInvoke(req: RpcRequest) {
        val cap = req.params.optString("cap")
        val args = req.params.optJSONObject("args") ?: JSONObject()
        try {
            val result = DeviceCapabilities.invoke(context, cap, args)
            respond(req.id, JSONObject().apply {
                if (result.length() > 0) put("result", result)
            })
        } catch (e: CapabilityException) {
            Log.i(TAG, "capability.invoke $cap failed: ${e.code} (${e.message})")
            val data = kindData(e.code)
            e.perm?.let { data.put("perm", it) }
            e.settings?.let { data.put("settings", it) }
            respondError(req.id, capErrorCode(e.code), e.message ?: "capability failed", data)
        }
    }

    private fun capErrorCode(kind: String): Int = when (kind) {
        "cap-unsupported" -> EbpError.CAP_UNSUPPORTED
        "cap-permission" -> EbpError.CAP_PERMISSION
        else -> EbpError.CAP_FAILED
    }

    /**
     * The device → Emacs event-source channel (SPEC §11): persist the
     * replace-set and re-arm listeners. Wholesale rejection is a typed
     * 1101 — the v1 codeless rejection is dead. Already off-main (the
     * dispatch thread), so the Room writes are legal here.
     */
    private fun handleTriggersSet(req: RpcRequest) {
        val host = JetpacsRuntime.triggerHost
        val err = if (host == null) "trigger host not running"
        else host.replaceSet(req.params.optJSONArray("triggers"))
        if (err == null) respond(req.id, JSONObject())
        else respondError(req.id, EbpError.TRIGGERS_REJECTED, err, kindData("triggers-rejected"))
    }

    /**
     * Upcoming timed org items → exact alarms. Each set replaces only
     * its owner's previous set (blank = the unowned bucket), so
     * coexisting apps never cancel each other's reminders. Promoted to a
     * request so acceptance is typed.
     */
    private fun handleRemindersSet(req: RpcRequest) {
        ReminderScheduler.replaceAll(
            context,
            req.params.optString("owner"),
            req.params.optJSONArray("reminders"))
        respond(req.id, JSONObject())
    }

    fun shutdown() {
        if (!running) return
        running = false
        pipeline.close()
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
