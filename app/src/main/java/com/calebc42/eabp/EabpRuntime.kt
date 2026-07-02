package com.calebc42.eabp

/**
 * Process-wide access point for the live server and surface manager, so a
 * BroadcastReceiver (notification button taps) can reach the same instances the
 * foreground service created. Populated in [BridgeService.onCreate]; the
 * foreground service keeps the process — and therefore these references — alive.
 */
import android.annotation.SuppressLint
import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

@SuppressLint("StaticFieldLeak")
object EabpRuntime {
    var server: EabpServer? = null

    // StateFlow-backed so the UI can react to the service coming up instead
    // of polling; the plain property keeps non-Compose callers unchanged.
    private val _surfaceManager = MutableStateFlow<SurfaceManager?>(null)
    val surfaceManagerFlow: StateFlow<SurfaceManager?> = _surfaceManager.asStateFlow()
    var surfaceManager: SurfaceManager?
        get() = _surfaceManager.value
        set(value) { _surfaceManager.value = value }

    var database: EabpDatabase? = null
    val dialogState = EabpDialogState()
    val pieMenuState = EabpPieMenuState()

    /**
     * Whether a handshaked Emacs connection is currently live. Driven by the
     * connection lifecycle ([EabpConnection.handleHello] flips it true,
     * connection close flips it false) and observed by the UI for the status
     * dot. Client-side because a disconnected Emacs can't push its own absence.
     */
    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()

    fun setConnected(value: Boolean) {
        _connected.value = value
    }

    fun initialize(context: Context) {
        if (database == null) {
            database = EabpDatabase.getDatabase(context)
        }
    }
}