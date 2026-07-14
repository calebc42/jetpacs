package com.calebc42.jetpacs

import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import kotlin.concurrent.thread

class JetpacsDialogState {
    val currentDialog = MutableStateFlow<JSONObject?>(null)

    /**
     * Optional callback invoked when the user dismisses the dialog by pressing
     * back or tapping outside.  Set by [show] from the payload's `prompt_id`
     * (if present) so the Emacs prompt bridge learns the user cancelled.
     */
    var onDismissed: (() -> Unit)? = null
        private set

    fun show(spec: JSONObject) {
        // If the dialog payload carries a prompt_id, wire up an on-dismiss
        // callback that sends a prompt.dismiss action back to Emacs.
        val promptId = findPromptId(spec)
        onDismissed = if (promptId != null) {
            {
                val action = JSONObject().apply {
                    put("action", "prompt.dismiss")
                    put("args", JSONObject().apply { put("prompt_id", promptId) })
                }
                val frame = Frame(
                    kind = "event.action",
                    payload = action,
                )
                // Invoked from the dialog's onDismissRequest, i.e. the main
                // thread — a socket write there throws
                // NetworkOnMainThreadException and kills the app.
                thread(name = "JetpacsPromptDismiss") {
                    JetpacsRuntime.server?.connection()?.send(frame)
                }
            }
        } else null
        currentDialog.value = spec
    }

    fun dismiss() {
        onDismissed = null
        currentDialog.value = null
    }

    /**
     * Walk the SDUI tree looking for the first `prompt_id` in any action's
     * args.  This is how jetpacs-minibuffer.el tags its dialogs.
     */
    private fun findPromptId(node: JSONObject): String? {
        // Check direct args
        node.optJSONObject("args")?.optString("prompt_id")?.takeIf { it.isNotEmpty() }?.let { return it }
        // Check on_tap / on_submit actions
        for (key in listOf("on_tap", "on_submit")) {
            node.optJSONObject(key)?.optJSONObject("args")
                ?.optString("prompt_id")?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        // Recurse into children
        node.optJSONArray("children")?.let { children ->
            for (i in 0 until children.length()) {
                children.optJSONObject(i)?.let { child ->
                    findPromptId(child)?.let { return it }
                }
            }
        }
        return null
    }
}
