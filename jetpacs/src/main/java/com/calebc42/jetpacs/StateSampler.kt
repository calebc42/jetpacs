package com.calebc42.jetpacs

import android.app.KeyguardManager
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * The *level* half of the device-signal vocabulary (SPEC §11 "State
 * predicates & sampling"): where [TriggerHost] watches signals as edges,
 * this samples them as booleans — the Easer USource pattern. Two
 * consumers share it: the `when` gate [TriggerHost.fireRow] evaluates
 * before a fire (via [evaluateWhen]), and the `state.get` capability
 * (DeviceCapabilities) that makes a gate testable from Emacs.
 *
 * A stateless `object` like [DeviceCapabilities]: every sampler is a
 * cached-system-state read (sticky broadcast, system service getter) —
 * no listeners, no polling, zero standing battery cost.
 *
 * Fail-closed discipline: a predicate that cannot be evaluated (an
 * ungranted permission, an unknown type, a dead service) does NOT hold.
 * Suppressing a fire is recoverable; firing garbage is not.
 */
object StateSampler {

    private const val TAG = "JetpacsStateSampler"

    /** Best-effort [Log.w]: the gate's fail-closed paths run in plain-JVM
     * unit tests where android.util.Log throws — a warning must never be
     * the thing that breaks "never fire garbage". */
    private fun warn(msg: String) {
        runCatching { Log.w(TAG, msg) }
    }

    /** The sample-able predicate catalog, reported in the welcome as
     * `device.state_types` (under the `triggers` grant). Mirrors
     * `jetpacs-lint-state-predicate-types` (jetpacs-lint.el) and SPEC
     * §11's predicate table; extend all three together. */
    val STATE_TYPES = setOf(
        "power", "battery.level", "screen", "airplane", "network",
        "headset", "time.window", "wifi.enabled", "bluetooth.enabled",
        "calendar.event",
    )

    private val DAY_NAMES = listOf("mon", "tue", "wed", "thu", "fri", "sat", "sun")
    private val TIME_RE = Regex("""([01]?\d|2[0-3]):[0-5]\d""")

    // ── Sampling (state.get) ─────────────────────────────────────────────────

    /**
     * Sample state [type] → its current state object, shaped like the
     * type's trigger `data` where one exists (SPEC §11).
     * @throws CapabilityException `cap-unsupported` for an unknown type,
     * `cap-failed` for `time.window` (predicate-only) or a dead read.
     */
    fun sample(context: Context, type: String): JSONObject = when (type) {
        "power" -> {
            val sticky = stickyBattery(context)
            val plugged = sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            JSONObject().apply {
                put("state", if (plugged != 0) "connected" else "disconnected")
                when (plugged) {
                    BatteryManager.BATTERY_PLUGGED_AC -> put("plug", "ac")
                    BatteryManager.BATTERY_PLUGGED_USB -> put("plug", "usb")
                    BatteryManager.BATTERY_PLUGGED_WIRELESS -> put("plug", "wireless")
                }
            }
        }
        "battery.level" -> {
            val sticky = stickyBattery(context)
            val level = sticky?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = sticky?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            if (level < 0 || scale <= 0)
                throw CapabilityException("cap-failed", "battery level unreadable")
            JSONObject().put("level", level * 100 / scale)
        }
        "screen" -> {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            JSONObject()
                .put("state", if (pm.isInteractive) "on" else "off")
                .put("locked", km.isKeyguardLocked)
        }
        "airplane" -> JSONObject().put(
            "state",
            if (Settings.Global.getInt(
                    context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0
            ) "on" else "off")
        "network" -> {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager
            val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
            JSONObject().apply {
                put("connected", caps != null)
                caps?.let { put("transport", transportName(it)) }
            }
        }
        "headset" -> {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val wired = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                    it.type == AudioDeviceInfo.TYPE_USB_HEADSET
            }
            JSONObject().apply {
                put("state", if (wired != null) "plugged" else "unplugged")
                wired?.productName?.let { put("name", it.toString()) }
            }
        }
        "wifi.enabled" -> {
            val wm = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: throw CapabilityException("cap-failed", "no Wi-Fi service")
            JSONObject().put("enabled", wm.isWifiEnabled)
        }
        "bluetooth.enabled" -> {
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE)
                as? BluetoothManager)?.adapter
                ?: throw CapabilityException(
                    "cap-failed", "no Bluetooth adapter on this device")
            JSONObject().put("enabled", adapter.isEnabled)
        }
        "calendar.event" -> CalendarTriggers.sample(context)
        "time.window" -> throw CapabilityException(
            "cap-failed", "time.window is predicate-only — it has no sampled state")
        else -> throw CapabilityException(
            "cap-unsupported", "unknown state type '$type'")
    }

    private fun stickyBattery(context: Context): Intent? =
        context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))

    /** Human transport name for [caps] — the §11 `network` vocabulary.
     * Shared with [TriggerHost]'s network-edge data. */
    fun transportName(caps: NetworkCapabilities): String = when {
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
        else -> "other"
    }

    // ── The `when` gate ──────────────────────────────────────────────────────

    /**
     * SPEC §11 `when`: true when every predicate in [whenJson] (a JSON
     * array, null/empty = no gate) holds right now. Any unparseable gate
     * or unevaluable predicate fails the whole gate — closed, with a
     * `Log.w`, never an exception. [context] may be null (JVM tests):
     * only `time.window` is evaluable then.
     */
    fun evaluateWhen(context: Context?, whenJson: String?): Boolean {
        if (whenJson.isNullOrEmpty()) return true
        val arr = runCatching { JSONArray(whenJson) }.getOrNull() ?: run {
            warn("when: unparseable gate — failing closed")
            return false
        }
        for (i in 0 until arr.length()) {
            val p = arr.optJSONObject(i) ?: run {
                warn("when[$i]: not an object — failing closed")
                return false
            }
            if (!holds(context, p)) return false
        }
        return true
    }

    /** True when the single [predicate] holds; anything unevaluable —
     * unknown type, missing context, a throwing sampler — is false. */
    fun holds(context: Context?, predicate: JSONObject): Boolean = try {
        when (val type = predicate.optString("type")) {
            "time.window" -> {
                val cal = Calendar.getInstance()
                timeWindowHolds(
                    cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE),
                    (cal.get(Calendar.DAY_OF_WEEK) + 5) % 7, // MONDAY(2) → 0
                    predicate)
            }
            !in STATE_TYPES -> {
                warn("when: unknown state type '$type' — not holding")
                false
            }
            // The calendar predicate's match fields parameterize the QUERY
            // (not a post-hoc comparison), so it evaluates itself — with
            // the same ungranted-means-false discipline.
            "calendar.event" ->
                if (context == null) {
                    warn("when: no context to sample '$type' — not holding")
                    false
                } else CalendarTriggers.predicateHolds(context, predicate)
            else ->
                if (context == null) {
                    warn("when: no context to sample '$type' — not holding")
                    false
                } else stateMatches(type, sample(context, type), predicate)
        }
    } catch (e: Exception) {
        warn("when: '${predicate.optString("type")}' unevaluable: ${e.message}")
        false
    }

    /** Match a sampled [state] against [p]'s type-specific fields. A
     * field-less predicate asserts the type's natural state (SPEC §11:
     * power connected, screen on, airplane on, headset plugged, any
     * network connected). */
    private fun stateMatches(type: String, state: JSONObject, p: JSONObject): Boolean =
        when (type) {
            "power" -> state.optString("state") == p.optString("state", "connected")
            "battery.level" -> {
                val level = state.optInt("level", -1)
                when {
                    p.has("above") -> level > p.optInt("above")
                    p.has("below") -> level < p.optInt("below")
                    else -> false // shape error; validateWhen rejects it upstream
                }
            }
            "screen" -> when (val want = p.optString("state", "on")) {
                "on", "off" -> state.optString("state") == want
                "unlocked" -> !state.optBoolean("locked", true)
                else -> false
            }
            "airplane" -> state.optString("state") == p.optString("state", "on")
            "network" -> state.optBoolean("connected") &&
                (p.optString("transport").isEmpty() ||
                    p.optString("transport") == state.optString("transport"))
            "headset" -> state.optString("state") == p.optString("state", "plugged")
            "wifi.enabled", "bluetooth.enabled" ->
                state.optBoolean("enabled") == p.optBoolean("enabled", true)
            else -> false
        }

    /**
     * Pure `time.window` evaluation with an injected clock:
     * [minutesOfDay] is 0..1439, [dayIndex] 0=Monday..6=Sunday. Bounds
     * are half-open `[after, before)`; an absent bound is open; the
     * window wraps midnight when `after` > `before`. `days` filters on
     * the calendar day of the moment being tested.
     */
    internal fun timeWindowHolds(
        minutesOfDay: Int, dayIndex: Int, predicate: JSONObject,
    ): Boolean {
        predicate.optJSONArray("days")?.let { days ->
            var match = false
            for (j in 0 until days.length())
                if (DAY_NAMES.indexOf(days.optString(j)) == dayIndex) match = true
            if (!match) return false
        }
        val after = parseMinutes(predicate.optString("after"))
        val before = parseMinutes(predicate.optString("before"))
        return when {
            after == null && before == null -> true
            after == null -> minutesOfDay < before!!
            before == null -> minutesOfDay >= after
            after > before -> minutesOfDay >= after || minutesOfDay < before
            else -> minutesOfDay >= after && minutesOfDay < before
        }
    }

    private fun parseMinutes(s: String): Int? {
        if (TIME_RE.matchEntire(s) == null) return null
        val (h, m) = s.split(":")
        return h.toInt() * 60 + m.toInt()
    }

    // ── Registration-time validation ─────────────────────────────────────────

    /**
     * Shape-check a registration's `when` array; the first problem as a
     * human string, or null when clean. [TriggerHost.parseTriggerRows]
     * whole-set-rejects on it — a malformed gate must never be stored,
     * and (the critical hazard) never silently dropped.
     */
    fun validateWhen(arr: JSONArray): String? {
        for (i in 0 until arr.length()) {
            val p = arr.optJSONObject(i) ?: return "when[$i] is not an object"
            val type = p.optString("type")
            if (type.isEmpty()) return "when[$i]: missing 'type'"
            if (type !in STATE_TYPES) return "when[$i]: unknown state type '$type'"
            when (type) {
                "battery.level" ->
                    if (!p.has("above") && !p.has("below"))
                        return "when[$i]: battery.level needs 'above' or 'below'"
                "time.window" -> {
                    for (bound in listOf("after", "before"))
                        if (p.has(bound) && TIME_RE.matchEntire(p.optString(bound)) == null)
                            return "when[$i]: '$bound' must be \"HH:MM\""
                    p.optJSONArray("days")?.let { days ->
                        for (j in 0 until days.length())
                            if (days.optString(j) !in DAY_NAMES)
                                return "when[$i]: unknown day '${days.optString(j)}'"
                    }
                }
            }
        }
        return null
    }
}
