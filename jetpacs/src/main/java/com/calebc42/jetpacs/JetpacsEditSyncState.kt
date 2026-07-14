package com.calebc42.jetpacs

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/**
 * Editor-sync frames pushed by Emacs, observed by the live editor.
 *
 * [diagnostics] holds the latest `diagnostics.show` payload (flymake results
 * for a synced file); [resync] the latest `edit.resync` request (Emacs lost
 * or mistrusts its shadow and wants a fresh full-text edit.open). Both are
 * ephemeral like completion payloads: never persisted, never queued, and
 * self-validating — the editor checks id/session/seq before acting, so a
 * frame for a closed editor is simply ignored.
 */
class JetpacsEditSyncState {
    private val _diagnostics = MutableStateFlow<JSONObject?>(null)
    val diagnostics: StateFlow<JSONObject?> = _diagnostics.asStateFlow()

    private val _resync = MutableStateFlow<JSONObject?>(null)
    val resync: StateFlow<JSONObject?> = _resync.asStateFlow()

    private val _eldoc = MutableStateFlow<JSONObject?>(null)
    val eldoc: StateFlow<JSONObject?> = _eldoc.asStateFlow()

    private val _fontify = MutableStateFlow<JSONObject?>(null)
    val fontify: StateFlow<JSONObject?> = _fontify.asStateFlow()

    fun showDiagnostics(payload: JSONObject) { _diagnostics.value = payload }
    fun requestResync(payload: JSONObject) { _resync.value = payload }
    fun showEldoc(payload: JSONObject) { _eldoc.value = payload }
    fun showFontify(payload: JSONObject) { _fontify.value = payload }

    fun clear() {
        _diagnostics.value = null
        _resync.value = null
        _eldoc.value = null
        _fontify.value = null
    }
}
