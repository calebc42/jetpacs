package com.calebc42.eabp

import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject

class EabpPieMenuState {
    val currentMenu = MutableStateFlow<JSONObject?>(null)

    fun show(spec: JSONObject) {
        currentMenu.value = spec
    }

    fun dismiss() {
        currentMenu.value = null
    }
}
