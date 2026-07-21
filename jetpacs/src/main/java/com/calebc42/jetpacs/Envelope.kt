package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/** Protocol version the companion speaks (EBP 2: the JSON-RPC 2.0 envelope). */
const val JETPACS_PROTOCOL_VERSION = 2

// The Method table (dot-namespaced JSON-RPC method names, SPEC-2 §4) and
// the EbpError codes are GENERATED from the contract's `methods` and
// `error_codes` (ebp/contract.json) by the `generateContractTypes` task,
// landing in build/generated/contract/ as WireVocabulary.kt. Historical
// note that lived with the hand table: the v1 kinds `ack`, `error`,
// `ping`, `pong`, `auth.challenge`, `session.welcome`,
// `capability.result`, and `queue.drained` dissolved into JSON-RPC
// structure — challenges and welcomes are handshake *responses*,
// capability results and drain summaries are their requests' responses,
// and acks stopped existing.

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
            return RpcMalformed(EbpError.PARSE_ERROR, "unparseable frame: ${e.message}")
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
