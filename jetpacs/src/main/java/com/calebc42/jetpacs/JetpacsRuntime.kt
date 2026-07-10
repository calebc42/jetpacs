package com.calebc42.jetpacs

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
import org.json.JSONObject

@SuppressLint("StaticFieldLeak")
object JetpacsRuntime {
    var server: JetpacsServer? = null

    // StateFlow-backed so the UI can react to the service coming up instead
    // of polling; the plain property keeps non-Compose callers unchanged.
    private val _surfaceManager = MutableStateFlow<SurfaceManager?>(null)
    val surfaceManagerFlow: StateFlow<SurfaceManager?> = _surfaceManager.asStateFlow()
    var surfaceManager: SurfaceManager?
        get() = _surfaceManager.value
        set(value) { _surfaceManager.value = value }

    var database: JetpacsDatabase? = null

    /** The device-trigger host (SPEC §11), alive with [BridgeService]. */
    var triggerHost: TriggerHost? = null

    val dialogState = JetpacsDialogState()
    val pieMenuState = JetpacsPieMenuState()
    val completionState = JetpacsCompletionState()
    val editSyncState = JetpacsEditSyncState()

    /**
     * Whether a handshaked Emacs connection is currently live. Driven by the
     * connection lifecycle ([JetpacsConnection.handleHello] flips it true,
     * connection close flips it false) and observed by the UI for the status
     * dot. Client-side because a disconnected Emacs can't push its own absence.
     */
    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()

    fun setConnected(value: Boolean) {
        _connected.value = value
    }

    /**
     * Whether any Emacs has ever paired on this device. Seeded from prefs in
     * [initialize] and flipped true the moment a handshake completes, so the
     * pairing screen can reactively give way to the dashboard. Until it's
     * true, a not-yet-paired user sees the pairing token rather than a stale
     * cached dashboard.
     */
    private val _pairedEver = MutableStateFlow(false)
    val pairedEver: StateFlow<Boolean> = _pairedEver.asStateFlow()

    fun setPaired() {
        _pairedEver.value = true
    }

    /**
     * The `screen.keep_on` effector's state (SPEC §10). Set by
     * [DeviceCapabilities]; [SduiScaffold] applies it as the window's
     * keep-screen-on flag, so it only holds while Jetpacs UI is on screen.
     */
    private val _keepScreenOn = MutableStateFlow(false)
    val keepScreenOn: StateFlow<Boolean> = _keepScreenOn.asStateFlow()

    fun setKeepScreenOn(value: Boolean) {
        _keepScreenOn.value = value
    }

    /**
     * The last `theme.set` payload from Emacs, or null when none was ever
     * pushed (or the client cleared it). Persisted in prefs like a cached
     * surface: the app keeps the Emacs look across restarts while Emacs is
     * away. The shell's theme composable collects this and, when non-null,
     * lets it win over Material You / the static fallback.
     */
    private val _emacsTheme = MutableStateFlow<JSONObject?>(null)
    val emacsTheme: StateFlow<JSONObject?> = _emacsTheme.asStateFlow()

    fun setEmacsTheme(context: Context, payload: JSONObject) {
        // `colors: null` (or no colors at all) is the documented clear: the
        // client stops mirroring and the companion falls back to its own
        // scheme chain.
        val cleared = payload.optJSONObject("colors") == null
        _emacsTheme.value = if (cleared) null else payload
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .apply {
                if (cleared) remove(KEY_EMACS_THEME)
                else putString(KEY_EMACS_THEME, payload.toString())
            }
            .apply()
    }

    /**
     * Number of offline events waiting in the Room queue, for the top-bar
     * badge. Refresh from a background thread only (Room forbids main).
     */
    private val _queuedCount = MutableStateFlow(0)
    val queuedCount: StateFlow<Int> = _queuedCount.asStateFlow()

    fun refreshQueuedCount() {
        _queuedCount.value = database?.eventDao()?.count() ?: 0
    }

    fun initialize(context: Context) {
        if (database == null) {
            database = JetpacsDatabase.getDatabase(context)
        }
        if (JetpacsAuth.hasPaired(context)) _pairedEver.value = true
        if (_emacsTheme.value == null) {
            _emacsTheme.value = context
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_EMACS_THEME, null)
                ?.let { runCatching { JSONObject(it) }.getOrNull() }
        }
    }

    // Same prefs file as [JetpacsAuth]: one "jetpacs" store for small
    // durable companion state.
    private const val PREFS = "jetpacs"
    private const val KEY_EMACS_THEME = "emacs_theme"
}