package com.calebc42.jetpacs

import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject

class JetpacsPieMenuState {
    val currentMenu = MutableStateFlow<JSONObject?>(null)

    fun show(spec: JSONObject) {
        currentMenu.value = spec
    }

    fun dismiss() {
        currentMenu.value = null
    }
}
