package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/** Protocol version the companion speaks (EBP 2: the JSON-RPC 2.0 envelope). */
const val JETPACS_PROTOCOL_VERSION = 2

/**
 * Dot-namespaced JSON-RPC method names (SPEC-2 §4).
 *
 * A request carries an `id` and is answered exactly once — result XOR
 * error; a notification carries no `id` and is never answered. The v1
 * kinds `ack`, `error`, `ping`, `pong`, `auth.challenge`,
 * `session.welcome`, `capability.result`, and `queue.drained` dissolved
 * into that structure: challenges and welcomes are handshake *responses*,
 * capability results and drain summaries are their requests' responses,
 * and acks stopped existing.
 */
object Method {
    // Requests, Emacs → companion (answered exactly once).
    const val SESSION_HELLO = "session.hello"
    const val AUTH_RESPONSE = "auth.response"
    const val CAPABILITY_INVOKE = "capability.invoke"
    const val QUEUE_REPLAY = "queue.replay"
    const val TRIGGERS_SET = "triggers.set"
    const val REMINDERS_SET = "reminders.set"

    // Notifications, Emacs → companion.
    const val SURFACE_UPDATE = "surface.update"
    const val SURFACE_REMOVE = "surface.remove"
    const val DIALOG_SHOW = "dialog.show"
    const val DIALOG_DISMISS = "dialog.dismiss"
    const val PIE_MENU_SHOW = "pie_menu.show"
    const val PIE_MENU_DISMISS = "pie_menu.dismiss"
    const val TOAST_SHOW = "toast.show"
    const val THEME_SET = "theme.set"
    const val COMPLETIONS_SHOW = "completions.show"
    const val DIAGNOSTICS_SHOW = "diagnostics.show"
    const val ELDOC_SHOW = "eldoc.show"
    const val FONTIFY_SHOW = "fontify.show"
    const val EDIT_RESYNC = "edit.resync"
    const val EDIT_APPLY = "edit.apply"

    // Notifications, companion → Emacs.
    const val EVENT_ACTION = "event.action"
    const val STATE_CHANGED = "state.changed"
    const val LOG_ERROR = "log.error"

    // Notification, either direction (SPEC-2 §2.3 cancellation).
    const val RPC_CANCEL = "rpc.cancel"

    /** Methods the companion accepts as requests. */
    val REQUESTS = setOf(
        SESSION_HELLO, AUTH_RESPONSE, CAPABILITY_INVOKE,
        QUEUE_REPLAY, TRIGGERS_SET, REMINDERS_SET,
    )

    /** Methods the companion accepts as notifications. */
    val CLIENT_NOTIFICATIONS = setOf(
        SURFACE_UPDATE, SURFACE_REMOVE, DIALOG_SHOW, DIALOG_DISMISS,
        PIE_MENU_SHOW, PIE_MENU_DISMISS, TOAST_SHOW, THEME_SET,
        COMPLETIONS_SHOW, DIAGNOSTICS_SHOW, ELDOC_SHOW, FONTIFY_SHOW,
        EDIT_RESYNC, EDIT_APPLY, RPC_CANCEL,
    )

    /** Methods only the companion sends — receiving one is a direction violation. */
    val COMPANION_SENDS = setOf(EVENT_ACTION, STATE_CHANGED, LOG_ERROR)
}

/**
 * Error codes (SPEC-2 §2.4). `-32768..-32000` is JSON-RPC's reserved
 * range; application codes live outside it, with the readable v1 string
 * vocabulary carried as `data.kind`. Never emit `32000` (a jsonrpc.el
 * sentinel meaning "no error") or `-1` (its local "Server died").
 */
object EbpError {
    const val PARSE = -32700
    const val INVALID_REQUEST = -32600
    const val METHOD_NOT_FOUND = -32601
    const val INVALID_PARAMS = -32602
    const val INTERNAL = -32603
    const val CAP_UNSUPPORTED = 1001
    const val CAP_PERMISSION = 1002
    const val CAP_FAILED = 1003
    const val TRIGGERS_REJECTED = 1101
    const val NOT_AUTHENTICATED = 1200
    const val SPEC_INVALID = 1201
    const val PROTO_VERSION = 1202
    const val AUTH_FAILED = 1203
    const val REQUEST_CANCELLED = 1301
    const val FRAME_TOO_LARGE = 1400
    const val OVERLOADED = 1401
}

/** One inbound wire message, classified by the parser (or the codec). */
sealed interface RpcIn

/** A request: must be answered exactly once, result XOR error. */
class RpcRequest(val id: Any, val method: String, val params: JSONObject) : RpcIn

/** A notification: never answered. */
class RpcNotification(val method: String, val params: JSONObject) : RpcIn

/** A response to a request this side sent (none exist in the first cut). */
class RpcResponse(val id: Any, val result: JSONObject?, val error: JSONObject?) : RpcIn

/**
 * A frame over the cap: the codec skipped its body byte-exactly without
 * parsing it (SPEC-2 §2.2). Reported on `log.error`, never answered —
 * there is no id to answer.
 */
class RpcOversize(val bytes: Long, val max: Int) : RpcIn

/** Parsed as JSON but not as a JSON-RPC 2.0 message (or a prohibited batch). */
class RpcMalformed(val code: Int, val why: String) : RpcIn

/** Builders and the parser for JSON-RPC 2.0 message objects. */
object Rpc {
    fun parse(text: String): RpcIn {
        val value = try {
            JSONTokener(text).nextValue()
        } catch (e: JSONException) {
            return RpcMalformed(EbpError.PARSE, "unparseable frame: ${e.message}")
        }
        if (value is JSONArray)
            return RpcMalformed(EbpError.INVALID_REQUEST, "batch arrays are prohibited")
        val obj = value as? JSONObject
            ?: return RpcMalformed(EbpError.INVALID_REQUEST, "frame is not an object")
        if (obj.optString("jsonrpc") != "2.0")
            return RpcMalformed(EbpError.INVALID_REQUEST, "missing jsonrpc \"2.0\"")
        val id: Any? = if (obj.has("id") && !obj.isNull("id")) obj.get("id") else null
        val method = obj.optString("method")
        return when {
            method.isNotEmpty() && id != null ->
                if (id is String || id is Number)
                    RpcRequest(id, method, obj.optJSONObject("params") ?: JSONObject())
                else RpcMalformed(EbpError.INVALID_REQUEST, "id must be a string or a number")
            method.isNotEmpty() ->
                RpcNotification(method, obj.optJSONObject("params") ?: JSONObject())
            id != null && (obj.has("result") || obj.has("error")) ->
                RpcResponse(id, obj.optJSONObject("result"), obj.optJSONObject("error"))
            else ->
                RpcMalformed(EbpError.INVALID_REQUEST, "neither request, notification, nor response")
        }
    }

    fun notification(method: String, params: JSONObject): JSONObject =
        JSONObject().apply {
            put("jsonrpc", "2.0")
            put("method", method)
            put("params", params)
        }

    fun request(id: Any, method: String, params: JSONObject): JSONObject =
        notification(method, params).put("id", id)

    fun response(id: Any, result: JSONObject): JSONObject =
        JSONObject().apply {
            put("jsonrpc", "2.0")
            put("id", id)
            put("result", result)
        }

    /** An error response; a null ID means the request's id was undetectable. */
    fun error(id: Any?, code: Int, message: String, data: JSONObject? = null): JSONObject =
        JSONObject().apply {
            put("jsonrpc", "2.0")
            put("id", id ?: JSONObject.NULL)
            put("error", JSONObject().apply {
                put("code", code)
                put("message", message)
                data?.let { put("data", it) }
            })
        }
}
