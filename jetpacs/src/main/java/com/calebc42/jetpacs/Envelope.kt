package com.calebc42.jetpacs

import org.json.JSONObject

/** Protocol version the companion speaks. */
const val JETPACS_PROTOCOL_VERSION = 1

/** Namespaced message kinds. Extended as later phases land. */
object Kind {
    const val SESSION_HELLO = "session.hello"
    const val SESSION_WELCOME = "session.welcome"
    const val AUTH_CHALLENGE = "auth.challenge"
    const val AUTH_RESPONSE = "auth.response"
    const val ACK = "ack"
    const val ERROR = "error"
    const val PING = "ping"
    const val PONG = "pong"
    const val STATE_CHANGED = "state.changed"
    const val DIALOG_SHOW = "dialog.show"
    const val DIALOG_DISMISS = "dialog.dismiss"
    const val PIE_MENU_SHOW = "pie_menu.show"
    const val PIE_MENU_DISMISS = "pie_menu.dismiss"
    const val TOAST_SHOW = "toast.show"
    const val COMPLETIONS_SHOW = "completions.show"
    const val EDIT_RESYNC = "edit.resync"
    const val EDIT_APPLY = "edit.apply"
    const val DIAGNOSTICS_SHOW = "diagnostics.show"
    const val ELDOC_SHOW = "eldoc.show"
    const val FONTIFY_SHOW = "fontify.show"
    const val CAPABILITY_INVOKE = "capability.invoke"
    const val CAPABILITY_RESULT = "capability.result"
    // Emacs-theme mirroring (SPEC §7); routed to [JetpacsRuntime.setEmacsTheme].
    const val THEME_SET = "theme.set"
    // SPEC §11 replace-set; routed to [TriggerHost.replaceSet].
    const val TRIGGERS_SET = "triggers.set"
}

/**
 * One Jetpacs frame: { v, id, reply_to, kind, payload }.
 *
 * A thin wrapper over [JSONObject] so later phases can read payload fields
 * directly without a serialization framework.
 */
class Frame(
    val kind: String,
    val payload: JSONObject = JSONObject(),
    val id: String = nextId(),
    val replyTo: String? = null,
    val v: Int = JETPACS_PROTOCOL_VERSION,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("v", v)
        put("id", id)
        put("reply_to", replyTo ?: JSONObject.NULL)
        put("kind", kind)
        put("payload", payload)
    }

    /** Compact, single-line JSON — required so NDJSON framing stays safe. */
    override fun toString(): String = toJson().toString()

    companion object {
        private var counter = 0L

        @Synchronized
        fun nextId(): String =
            "m-${(counter++).toString(16)}-${(0..0xffff).random().toString(16)}"

        fun fromJson(obj: JSONObject): Frame {
            val replyRaw = obj.opt("reply_to")
            val replyTo = if (replyRaw == null || replyRaw === JSONObject.NULL) null
            else replyRaw.toString()
            return Frame(
                kind = obj.optString("kind"),
                payload = obj.optJSONObject("payload") ?: JSONObject(),
                id = obj.optString("id"),
                replyTo = replyTo,
                v = obj.optInt("v", JETPACS_PROTOCOL_VERSION),
            )
        }
    }
}