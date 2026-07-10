package com.calebc42.jetpacs

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/**
 * The latest `completions.show` payload from Emacs, observed by the editor's
 * suggestion strip. Purely ephemeral: never persisted, never queued — a reply
 * that arrives after the user moved on is simply superseded or ignored (the
 * strip validates the payload's request_id and prefix against current editor
 * state before showing anything).
 */
class JetpacsCompletionState {
    private val _current = MutableStateFlow<JSONObject?>(null)
    val current: StateFlow<JSONObject?> = _current.asStateFlow()

    fun show(payload: JSONObject) { _current.value = payload }
    fun clear() { _current.value = null }
}
