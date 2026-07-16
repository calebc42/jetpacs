package com.calebc42.jetpacs

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.provider.Telephony
import android.telephony.TelephonyManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The companion as a durable *event source* (SPEC §11): a persisted
 * trigger table, context-registered receivers riding the [BridgeService]
 * foreground process, exact alarms for `time` triggers, and a firing
 * pipeline that reuses the offline queue exactly as [ActionReceiver]
 * does — connected ⇒ deliver, else queue / drop / wake per the
 * registration's policy. There is no second event channel.
 *
 * Battery discipline: every listener here is a broadcast or an alarm
 * (≈ free); the one high-frequency source, ACTION_BATTERY_CHANGED, is
 * registered only while a `battery.level` trigger exists and is reduced
 * host-side to threshold edge-crossings — raw readings never cross the
 * wire. Per-trigger `throttle_s` is enforced in [fireRow].
 */
class TriggerHost(private val context: Context) {

    /** In-memory mirror of the persisted set, for broadcast-time matching
     * without a DB read per broadcast. */
    @Volatile
    private var rows: List<TriggerRow> = emptyList()

    private val registered = mutableListOf<BroadcastReceiver>()

    /** battery.level hysteresis: trigger id -> last side (true = above). */
    private val batterySide = ConcurrentHashMap<String, Boolean>()

    // ── The wire entry point ─────────────────────────────────────────────────

    /**
     * SPEC §11 replace-set: persist, then re-arm. Returns an error string
     * for the connection to relay, or null on success. Runs on the
     * connection's read thread (Room is happy there).
     */
    fun replaceSet(triggers: JSONArray?): String? {
        val dao = JetpacsRuntime.database?.triggerDao() ?: return "trigger store unavailable"
        val (parsed, err) = parseTriggerRows(triggers)
        if (parsed == null) return err
        dao.replaceAll(parsed)
        arm(parsed)
        Log.i(TAG, "Trigger set replaced: ${parsed.size} trigger(s) armed")
        return null
    }

    /** Re-arm from the persisted table (service start, after boot). */
    fun armFromDatabase() {
        arm(JetpacsRuntime.database?.triggerDao()?.getAll() ?: emptyList())
    }

    /** Unregister everything (service teardown — receivers must not leak). */
    // Synchronized like arm(): teardown races a replace-set on the read
    // thread, and the receiver list must not be mutated from both sides.
    @Synchronized
    fun shutdown() {
        disarmReceivers()
        armNetworkCallback(false)
        CalendarTriggers.disarm(context)
        rows = emptyList()
    }

    // ── Arming ───────────────────────────────────────────────────────────────

    private fun disarmReceivers() {
        registered.forEach { runCatching { context.unregisterReceiver(it) } }
        registered.clear()
    }

    @Synchronized
    private fun arm(newRows: List<TriggerRow>) {
        rows = newRows
        batterySide.clear()
        disarmReceivers()

        fun register(receiver: BroadcastReceiver, filter: IntentFilter) {
            ContextCompat.registerReceiver(
                context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
            registered.add(receiver)
        }

        val types = newRows.map { it.type }.toSet()
        if ("power" in types) register(powerReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        })
        if ("battery.level" in types)
            register(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if ("screen" in types) register(screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        })
        if ("headset" in types)
            register(headsetReceiver, IntentFilter(AudioManager.ACTION_HEADSET_PLUG))
        if ("airplane" in types)
            register(airplaneReceiver, IntentFilter(Intent.ACTION_AIRPLANE_MODE_CHANGED))
        if ("timezone.changed" in types)
            register(timezoneReceiver, IntentFilter(Intent.ACTION_TIMEZONE_CHANGED))
        if ("wifi.enabled" in types)
            register(wifiStateReceiver,
                IntentFilter(WifiManager.WIFI_STATE_CHANGED_ACTION))
        if ("bluetooth.enabled" in types)
            register(bluetoothStateReceiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        // The telephony pair is runtime-permission-gated: ungranted rows
        // are skipped with a log (they stay stored and arm on the next
        // replace-set / service restart after granting). Both receivers
        // are context-registered, so they are live only while the FGS
        // runs — deliberate: a dead bridge is a deaf app, not a manifest
        // receiver silently accumulating other people's messages.
        if ("sms.received" in types) {
            if (runtimeGranted(Manifest.permission.RECEIVE_SMS))
                register(smsReceiver,
                    IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION))
            else Log.w(TAG, "sms.received registered but RECEIVE_SMS ungranted — skipping")
        }
        if ("call.state" in types) {
            if (runtimeGranted(Manifest.permission.READ_PHONE_STATE))
                register(callStateReceiver,
                    IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED))
            else Log.w(TAG, "call.state registered but READ_PHONE_STATE ungranted — skipping")
        }
        if ("package" in types) register(packageReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addDataScheme("package")
        })
        armNetworkCallback("network" in types)
        // `boot` triggers arm nothing here — BootReceiver fires them.
        armTimeAlarms(context, newRows.filter { it.type == "time" })
        armCalendar(context, newRows)
    }

    // ── Connectivity (callback API, permission-free) ─────────────────────────

    /** Last-known transport per network id: onLost gives a bare [Network],
     * so the transport is remembered from its onCapabilitiesChanged. */
    private val networkTransports = ConcurrentHashMap<Network, String>()
    private var networkCallbackArmed = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            // Transport arrives via onCapabilitiesChanged just after;
            // fire from there so `data` can carry it.
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            // Transport naming lives with the level samplers (StateSampler),
            // so the edge and the predicate can never disagree on vocabulary.
            val transport = StateSampler.transportName(caps)
            val first = networkTransports.put(network, transport) == null
            if (first) fireNetwork("available", transport)
        }

        override fun onLost(network: Network) {
            fireNetwork("lost", networkTransports.remove(network))
        }
    }

    private fun fireNetwork(event: String, transport: String?) {
        val data = JSONObject().put("event", event)
        transport?.let { data.put("transport", it) }
        for (row in rowsOf("network")) {
            val p = row.param()
            val wantEvent = p.optString("event")
            val wantTransport = p.optString("transport")
            if ((wantEvent.isEmpty() || wantEvent == event) &&
                (wantTransport.isEmpty() || wantTransport == transport)
            ) fireRow(context, row, data)
        }
    }

    private fun armNetworkCallback(wanted: Boolean) {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
        if (wanted && !networkCallbackArmed) {
            networkTransports.clear()
            runCatching { cm.registerDefaultNetworkCallback(networkCallback) }
                .onSuccess { networkCallbackArmed = true }
                .onFailure { Log.w(TAG, "network callback failed: ${it.message}") }
        } else if (!wanted && networkCallbackArmed) {
            runCatching { cm.unregisterNetworkCallback(networkCallback) }
            networkCallbackArmed = false
        }
    }

    // ── Matching helpers ─────────────────────────────────────────────────────

    private fun rowsOf(type: String) = rows.filter { it.type == type }

    private fun TriggerRow.param(): JSONObject =
        runCatching { JSONObject(params) }.getOrDefault(JSONObject())

    /** Fire every ROW of TYPE whose optional `state` param matches STATE. */
    private fun fireStateRows(type: String, state: String, data: JSONObject) {
        for (row in rowsOf(type)) {
            val want = row.param().optString("state")
            if (want.isEmpty() || want == state) fireRow(context, row, data)
        }
    }

    /** Fire every ROW of an adapter-state TYPE whose optional boolean
     * `enabled` param matches ENABLED (absent = both edges). */
    private fun fireEnabledRows(type: String, enabled: Boolean) {
        val data = JSONObject().put("enabled", enabled)
        for (row in rowsOf(type)) {
            val p = row.param()
            if (!p.has("enabled") || p.optBoolean("enabled") == enabled)
                fireRow(context, row, data)
        }
    }

    // ── Receivers ────────────────────────────────────────────────────────────

    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val state = when (intent.action) {
                Intent.ACTION_POWER_CONNECTED -> "connected"
                Intent.ACTION_POWER_DISCONNECTED -> "disconnected"
                else -> return
            }
            val data = JSONObject().put("state", state)
            if (state == "connected") plugType(c)?.let { data.put("plug", it) }
            fireStateRows("power", state, data)
        }
    }

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            // High-frequency broadcast: reduce to per-trigger edge crossings;
            // the raw stream never leaves this method.
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
            if (level < 0 || scale <= 0) return
            val pct = level * 100 / scale
            for (row in rowsOf("battery.level")) {
                val p = row.param()
                val wantAbove = p.has("above")
                if (!wantAbove && !p.has("below")) continue
                val above = if (wantAbove) pct > p.optInt("above")
                            else !(pct < p.optInt("below"))
                val previous = batterySide.put(row.id, above)
                // First reading seeds the side silently; a fire needs a
                // crossing INTO the configured side (an `above` trigger
                // stays quiet on the way back down, and vice versa).
                if (previous != null && previous != above && above == wantAbove) {
                    fireRow(c, row, JSONObject().put("level", pct))
                }
            }
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val state = when (intent.action) {
                Intent.ACTION_SCREEN_ON -> "on"
                Intent.ACTION_SCREEN_OFF -> "off"
                Intent.ACTION_USER_PRESENT -> "unlocked"
                else -> return
            }
            fireStateRows("screen", state, JSONObject().put("state", state))
        }
    }

    private val headsetReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            // Sticky: the registration-time replay must not fire.
            if (isInitialStickyBroadcast) return
            val state = if (intent.getIntExtra("state", 0) == 1) "plugged" else "unplugged"
            val data = JSONObject().put("state", state)
            intent.getStringExtra("name")?.let { data.put("name", it) }
            fireStateRows("headset", state, data)
        }
    }

    private val airplaneReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val state = if (intent.getBooleanExtra("state", false)) "on" else "off"
            fireStateRows("airplane", state, JSONObject().put("state", state))
        }
    }

    private val wifiStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            // WIFI_STATE_CHANGED is sticky: the registration-time replay
            // must not fire (the headsetReceiver discipline).
            if (isInitialStickyBroadcast) return
            when (intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE,
                    WifiManager.WIFI_STATE_UNKNOWN)) {
                WifiManager.WIFI_STATE_ENABLED -> fireEnabledRows("wifi.enabled", true)
                WifiManager.WIFI_STATE_DISABLED -> fireEnabledRows("wifi.enabled", false)
                // ENABLING / DISABLING / UNKNOWN are transitions, not edges.
            }
        }
    }

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE,
                    BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON ->
                    fireEnabledRows("bluetooth.enabled", true)
                BluetoothAdapter.STATE_OFF ->
                    fireEnabledRows("bluetooth.enabled", false)
                // TURNING_ON / TURNING_OFF are transitions, not edges.
            }
        }
    }

    private val timezoneReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val data = JSONObject()
                .put("tz", intent.getStringExtra(Intent.EXTRA_TIMEZONE)
                    ?: java.util.TimeZone.getDefault().id)
            for (row in rowsOf("timezone.changed")) fireRow(c, row, data)
        }
    }

    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            // Skip the remove half of an update (the add half re-fires anyway).
            if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return
            val event = when (intent.action) {
                Intent.ACTION_PACKAGE_ADDED -> "added"
                Intent.ACTION_PACKAGE_REMOVED -> "removed"
                else -> return
            }
            val pkg = intent.data?.schemeSpecificPart ?: return
            val data = JSONObject().put("event", event).put("package", pkg)
            for (row in rowsOf("package")) {
                val p = row.param()
                val wantEvent = p.optString("event")
                val wantPkg = p.optString("package")
                if ((wantEvent.isEmpty() || wantEvent == event) &&
                    (wantPkg.isEmpty() || wantPkg == pkg)
                ) fireRow(c, row, data)
            }
        }
    }

    private fun runtimeGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * `sms.received` (SPEC §11, opt-in payload, fail-closed): multipart
     * segments are concatenated before matching; `contains` reads the
     * body but only `include_body: true` emits it; nothing here is ever
     * logged (the clipboard.read discipline — content crosses the wire
     * as trigger data or not at all).
     */
    private val smsReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
            if (msgs.isEmpty()) return
            val from = msgs[0]?.displayOriginatingAddress
            val body = msgs.joinToString("") { it?.messageBody ?: "" }
            for (row in rowsOf("sms.received")) {
                val p = row.param()
                if (smsRowMatches(p, from, body))
                    fireRow(c, row, buildSmsData(p, from, body))
            }
        }
    }

    private val callDedupe = CallStateDedupe()

    /**
     * `call.state` (SPEC §11): the phone-state broadcast arrives once
     * per phone account and — under READ_CALL_LOG — again carrying the
     * number, so [CallStateDedupe] reduces the stream to one fire per
     * transition per row class. Rows that want the number (a `number`
     * filter or `include_number`) ride the number-carrying duplicate
     * when READ_CALL_LOG is granted; a `number`-filtered row without an
     * available number never fires (fail closed), and `include_number`
     * without one simply omits the field.
     */
    private val callStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val state = when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
                TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
                TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"
                TelephonyManager.EXTRA_STATE_IDLE -> "idle"
                else -> return
            }
            @Suppress("DEPRECATION")
            val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
            val (firePlain, fireNumbered) = callDedupe.classify(state, number != null)
            val hasCallLog = runtimeGranted(Manifest.permission.READ_CALL_LOG)
            for (row in rowsOf("call.state")) {
                val p = row.param()
                val want = p.optString("state")
                if (want.isNotEmpty() && want != state) continue
                val filter = p.optString("number")
                val wantsNumber = filter.isNotEmpty() || p.optBoolean("include_number")
                if (!(if (wantsNumber && hasCallLog) fireNumbered else firePlain)) continue
                if (filter.isNotEmpty() &&
                    (number == null || !number.contains(filter))) continue
                val data = JSONObject().put("state", state)
                if (p.optBoolean("include_number") && number != null)
                    data.put("number", number)
                fireRow(c, row, data)
            }
        }
    }

    private fun plugType(c: Context): String? {
        val sticky = c.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return when (sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)) {
            BatteryManager.BATTERY_PLUGGED_AC -> "ac"
            BatteryManager.BATTERY_PLUGGED_USB -> "usb"
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"
            else -> null
        }
    }

    companion object {
        private const val TAG = "JetpacsTriggerHost"
        private const val PREFS = "jetpacs_triggers"
        private const val KEY_ALARM_IDS = "alarm_ids"
        /** Repeating time triggers never fire more often than this. */
        private const val MIN_EVERY_S = 60L

        val SUPPORTED_TYPES = setOf(
            "time", "power", "battery.level", "screen", "headset",
            "airplane", "boot", "timezone.changed", "package", "network",
            // Post-batch-1 types negotiate via the welcome's trigger_types
            // report only; the client's static fallback list stays frozen
            // at batch 1 (see jetpacs-triggers-supported-types).
            "wifi.enabled", "bluetooth.enabled", "calendar.event",
            "sms.received", "call.state",
        )

        /** Pure `sms.received` matcher (SPEC §11): `from` is a substring
         * of the originating address, `contains` a substring of the
         * concatenated body. Reading the body to match `contains` does
         * not imply emitting it (see [buildSmsData]). */
        internal fun smsRowMatches(params: JSONObject, from: String?, body: String): Boolean {
            val wantFrom = params.optString("from")
            if (wantFrom.isNotEmpty() && (from == null || !from.contains(wantFrom)))
                return false
            val wantContains = params.optString("contains")
            if (wantContains.isNotEmpty() && !body.contains(wantContains))
                return false
            return true
        }

        /** The `sms.received` fire data: `{from, body?}`. `body` rides
         * only under `include_body: true` — opt-in, fail-closed, so a
         * `contains`-matched message never leaks its body by default. */
        internal fun buildSmsData(params: JSONObject, from: String?, body: String): JSONObject =
            JSONObject().apply {
                from?.let { put("from", it) }
                if (params.optBoolean("include_body")) put("body", body)
            }

        /** Delegate the `calendar.event` slice of [newRows] to
         * [CalendarTriggers] — only under READ_CALENDAR (else skip with a
         * log; the rows stay stored and arm on a re-set after granting). */
        private fun armCalendar(context: Context, newRows: List<TriggerRow>) {
            val calRows = newRows.filter { it.type == "calendar.event" }
            when {
                calRows.isEmpty() -> CalendarTriggers.disarm(context)
                CalendarTriggers.granted(context) ->
                    CalendarTriggers.arm(context, calRows)
                else -> {
                    Log.w(TAG, "calendar.event registered but READ_CALENDAR " +
                        "ungranted — skipping ${calRows.size} row(s)")
                    CalendarTriggers.disarm(context)
                }
            }
        }

        /** Per-trigger last-fire clock for `throttle_s` (process-lifetime;
         * the FGS process IS the trigger host's lifetime). */
        private val lastFired = ConcurrentHashMap<String, Long>()

        /** Queue writes must leave the caller's thread: the context-
         * registered receivers deliver [fireRow] on the MAIN thread and
         * Room refuses main-thread queries. One thread keeps queued
         * fires in arrival order; the alarm and wire callers are already
         * off-main and the extra hop is harmless. */
        private val queueExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "JetpacsTriggerQueue")
        }

        /**
         * SPEC §11 replace-set parsing and validation, extracted from
         * [replaceSet] so it is unit-testable without Room: the parsed
         * rows, or (null, error). Whole-set semantics — one bad entry
         * (unknown type, malformed `when`) rejects everything, so the
         * client never half-arms. A malformed `when` in particular must
         * reject rather than be dropped: a trigger stored without its
         * gate would fire UNGATED, the §11 critical hazard.
         */
        internal fun parseTriggerRows(
            triggers: JSONArray?,
        ): Pair<List<TriggerRow>?, String?> {
            val parsed = mutableListOf<TriggerRow>()
            if (triggers != null) {
                for (i in 0 until triggers.length()) {
                    val t = triggers.optJSONObject(i) ?: continue
                    val id = t.optString("id")
                    val type = t.optString("type")
                    if (id.isEmpty() || type.isEmpty())
                        return null to "trigger ${i}: missing id or type"
                    if (type !in SUPPORTED_TYPES)
                        return null to "trigger '$id': unknown type '$type'"
                    val whenArr = t.optJSONArray("when")
                    if (whenArr != null) {
                        StateSampler.validateWhen(whenArr)?.let {
                            return null to "trigger '$id': $it"
                        }
                    }
                    parsed.add(TriggerRow(
                        id = id,
                        type = type,
                        params = (t.optJSONObject("params") ?: JSONObject()).toString(),
                        policy = t.optString("policy", "queue"),
                        dedupe = t.optString("dedupe").ifEmpty { null },
                        throttleS = if (t.has("throttle_s")) t.optLong("throttle_s") else null,
                        onFire = t.optJSONArray("on_fire")?.toString(),
                        whenJson = whenArr?.toString(),
                    ))
                }
            }
            return parsed to null
        }

        /**
         * The firing pipeline — deliberately the same shape as
         * [ActionReceiver.handleTap]: live connection ⇒ send the
         * `event.action`, else the offline queue per policy. Static so the
         * alarm and boot receivers can fire without a host instance.
         */
        fun fireRow(context: Context, row: TriggerRow, data: JSONObject) {
            // SPEC §11 `when`: the state gate guards the ENTIRE fire — a
            // failed gate means the fire never happened (no event.action,
            // no on_fire, and, because this runs before the throttle
            // bookkeeping, no consumed lastFired slot).
            if (!StateSampler.evaluateWhen(context, row.whenJson)) {
                Log.d(TAG, "Gated ${row.id}: `when` does not hold")
                return
            }
            val now = System.currentTimeMillis()
            row.throttleS?.let { t ->
                val last = lastFired[row.id]
                if (last != null && now - last < t * 1000) {
                    Log.d(TAG, "Throttled ${row.id} (throttle_s=$t)")
                    return
                }
            }
            lastFired[row.id] = now

            // The companion-local response runs first (instant, dumb) and
            // IN ADDITION to the event below — Emacs still learns of the
            // fire on (re)connect and stays the source of truth.
            executeOnFire(context, row, data)

            val payload = JSONObject().apply {
                put("action", "trigger.fired")
                put("args", JSONObject().apply {
                    put("id", row.id)
                    put("type", row.type)
                    put("data", data)
                    put("at_ms", now)
                })
            }

            val conn = JetpacsRuntime.server?.connection()
            if (conn != null && conn.helloComplete &&
                conn.send(Frame(kind = "event.action", payload = payload))
            ) {
                Log.d(TAG, "Fired ${row.id} live")
                return
            }
            when (row.policy) {
                "drop" -> Log.d(TAG, "Dropped fire ${row.id} (policy=drop)")
                else -> {
                    queueExecutor.execute {
                        JetpacsRuntime.database?.eventDao()?.insert(QueuedEvent(
                            kind = "event.action",
                            payload = payload.toString(),
                            dedupeKey = row.dedupe,
                        ))
                        JetpacsRuntime.refreshQueuedCount()
                    }
                    Log.d(TAG, "Queued fire ${row.id} (policy=${row.policy})")
                    if (row.policy == "wake") EmacsWaker.requestWake(context)
                }
            }
        }

        /**
         * SPEC §11 `on_fire` (automation plan Task 10): the companion-local
         * response — a flat list of `{cap, args}` capability invocations
         * (SPEC §10) and `{notify: {title?, text?}}` notification posts,
         * executed in order at fire time even with Emacs dead. This is the
         * one place the companion acts on its own, so the vocabulary is
         * deliberately closed: no conditionals, no loops — a rule that
         * needs logic Emacs-dead means "keep Emacs alive", not a rule
         * language in Kotlin. Unknown entries and capability failures are
         * logged and skipped, never fatal (additive rule).
         *
         * String values inside `notify` and inside a `cap` entry's `args`
         * are interpolated against this fire's `data` first ([interpolate]);
         * the `cap` name itself is never interpolated — capability selection
         * is not data-driven.
         */
        private fun executeOnFire(context: Context, row: TriggerRow, data: JSONObject) {
            val list = runCatching { JSONArray(row.onFire ?: return) }.getOrNull() ?: return
            val id = row.id
            for (i in 0 until list.length()) {
                val entry = list.optJSONObject(i) ?: continue
                when {
                    entry.has("cap") -> {
                        val cap = entry.optString("cap")
                        val args = interpolateValue(
                            entry.optJSONObject("args") ?: JSONObject(),
                            id, row.type, data) as JSONObject
                        try {
                            DeviceCapabilities.invoke(context, cap, args)
                            Log.d(TAG, "on_fire[$id]: $cap ok")
                        } catch (e: CapabilityException) {
                            Log.w(TAG, "on_fire[$id]: $cap failed: ${e.code} (${e.message})")
                        }
                    }
                    entry.has("notify") -> {
                        val notify = interpolateValue(
                            entry.optJSONObject("notify") ?: JSONObject(),
                            id, row.type, data) as JSONObject
                        postOnFireNotification(context, id, notify)
                    }
                    else -> Log.d(TAG, "on_fire[$id]: ignoring unknown entry $i")
                }
            }
        }

        /**
         * SPEC §11 on_fire placeholders / §9 snippet grammar: substitute
         * `${id}`, `${type}`, and `${data.FIELD}` in [template] against this
         * fire. A single pass — substituted text is never re-scanned — and
         * unknown or unresolvable tokens are left literal (a `data.FIELD`
         * that is absent or JSON null stays as the raw `${…}`). The result
         * is always a string: a numeric or boolean field renders in its JSON
         * form (`63`, `true`).
         */
        internal fun interpolate(
            template: String, id: String, type: String, data: JSONObject
        ): String =
            PLACEHOLDER.replace(template) { m ->
                when (val token = m.groupValues[1]) {
                    "id" -> id
                    "type" -> type
                    else -> {
                        val field = m.groupValues[2] // token == "data.$field"
                        val v = if (data.has(field)) data.opt(field) else null
                        if (v == null || v === JSONObject.NULL) m.value else v.toString()
                    }
                }
            }

        /**
         * Recurse [interpolate] over any on_fire value: strings are
         * interpolated, objects/arrays are rebuilt with interpolated
         * members (so `intent.start` extras are covered), everything else
         * passes through unchanged.
         */
        internal fun interpolateValue(
            value: Any?, id: String, type: String, data: JSONObject
        ): Any? = when (value) {
            is String -> interpolate(value, id, type, data)
            is JSONObject -> JSONObject().also { out ->
                for (key in value.keys())
                    out.put(key, interpolateValue(value.get(key), id, type, data))
            }
            is JSONArray -> JSONArray().also { out ->
                for (i in 0 until value.length())
                    out.put(interpolateValue(value.get(i), id, type, data))
            }
            else -> value
        }

        private val PLACEHOLDER = Regex("""\$\{(id|type|data\.([A-Za-z0-9_]+))}""")

        private const val NOTIFY_CHANNEL = "jetpacs_automations"

        private fun postOnFireNotification(context: Context, id: String, spec: JSONObject) {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mgr.createNotificationChannel(NotificationChannel(
                    NOTIFY_CHANNEL, "Automations", NotificationManager.IMPORTANCE_DEFAULT))
            }
            val open = PendingIntent.getActivity(
                context, 0, JetpacsLaunch.openAppIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification = NotificationCompat.Builder(context, NOTIFY_CHANNEL)
                .setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle(spec.optString("title").ifEmpty { id })
                .setContentText(spec.optString("text"))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .build()
            runCatching { mgr.notify("on_fire/$id".hashCode(), notification) }
                .onFailure { Log.w(TAG, "on_fire[$id]: notify failed: ${it.message}") }
        }

        /**
         * Boot entry point ([BootReceiver]): fire `boot` triggers and
         * re-arm `time` alarms from the persisted table. Context-registered
         * listeners re-arm when [BridgeService] starts the host.
         */
        fun onBoot(context: Context) {
            val rows = JetpacsRuntime.database?.triggerDao()?.getAll() ?: return
            for (row in rows.filter { it.type == "boot" }) {
                fireRow(context, row, JSONObject())
            }
            armTimeAlarms(context, rows.filter { it.type == "time" })
            armCalendar(context, rows)
            Log.i(TAG, "Boot: rearmed ${rows.size} trigger(s)")
        }

        /**
         * (Re)arm exact alarms for the `time` triggers: cancel the previous
         * set (the armed trigger IDS persist in prefs, the
         * [ReminderScheduler] pattern), then arm `{at_ms}` one-shots and
         * `{every_s}` repeats (first fire one period from now; each fire
         * re-arms the next — `setRepeating` has been inexact since KitKat).
         */
        internal fun armTimeAlarms(context: Context, timeRows: List<TriggerRow>) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            // Cancellation must rebuild the exact PendingIntent, so the
            // full ids are stored — a request code alone can't reproduce
            // the data URI that keeps colliding hashCodes apart.
            prefs.getStringSet(KEY_ALARM_IDS, emptySet())!!.forEach { id ->
                am.cancel(alarmPending(context, id.hashCode(), id))
            }
            val ids = mutableSetOf<String>()
            val now = System.currentTimeMillis()
            for (row in timeRows) {
                val p = runCatching { JSONObject(row.params) }.getOrDefault(JSONObject())
                val at = when {
                    p.has("at_ms") -> p.optLong("at_ms")
                    p.has("every_s") ->
                        now + p.optLong("every_s").coerceAtLeast(MIN_EVERY_S) * 1000
                    else -> continue
                }
                if (at <= now) continue
                scheduleAlarm(context, am, row.id, at)
                ids.add(row.id)
            }
            prefs.edit().putStringSet(KEY_ALARM_IDS, ids).apply()
        }

        internal fun scheduleAlarm(context: Context, am: AlarmManager, id: String, at: Long) {
            val pi = alarmPending(context, id.hashCode(), id)
            val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            if (canExact) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.set(AlarmManager.RTC_WAKEUP, at, pi)
            }
        }

        private fun alarmPending(context: Context, code: Int, id: String): PendingIntent {
            val intent = Intent(context, TriggerAlarmReceiver::class.java).apply {
                action = "com.calebc42.jetpacs.TRIGGER_ALARM"
                // The data URI participates in filterEquals (extras don't),
                // so two ids whose hashCodes collide still get distinct
                // PendingIntents instead of silently sharing one.
                if (id.isNotEmpty()) data = Uri.parse("jetpacs-trigger:" + Uri.encode(id))
                putExtra("trigger_id", id)
            }
            return PendingIntent.getBroadcast(
                context, code, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}

/**
 * Reduces the duplicated `call.state` broadcast stream to one fire per
 * transition per row class (SPEC §11). ACTION_PHONE_STATE_CHANGED
 * arrives once per phone account, and again carrying the incoming
 * number when READ_CALL_LOG is granted. [classify] returns, for one
 * broadcast, whether to fire the number-indifferent rows and whether to
 * fire the number-wanting rows: the former fire on the first broadcast
 * of a new state, the latter on the (possibly same) broadcast that
 * first carries the number.
 */
internal class CallStateDedupe {
    private var lastState: String? = null
    private var numberedFired = false

    @Synchronized
    fun classify(state: String, hasNumber: Boolean): Pair<Boolean, Boolean> {
        if (state != lastState) {
            lastState = state
            numberedFired = hasNumber
            return true to hasNumber   // new transition: plain fires now
        }
        // A duplicate of the current state: plain already fired; let the
        // number-wanting rows fire once, when the number first appears.
        val fireNumbered = hasNumber && !numberedFired
        if (fireNumbered) numberedFired = true
        return false to fireNumbered
    }
}

/**
 * Fires `time` triggers. Reads the registration from the persisted table
 * (the process may have been cold-started by the alarm), so a stale alarm
 * whose trigger left the set is silently ignored — replace-set semantics
 * hold across process death.
 */
class TriggerAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("trigger_id") ?: return
        JetpacsRuntime.initialize(context.applicationContext)
        val pending = goAsync()
        kotlin.concurrent.thread(name = "JetpacsTriggerAlarm") {
            try {
                val dao = JetpacsRuntime.database?.triggerDao() ?: return@thread
                val row = dao.byId(id) ?: return@thread  // stale: not in the set
                TriggerHost.fireRow(context, row, JSONObject())
                // Re-arm a repeating trigger for its next period.
                val p = runCatching { JSONObject(row.params) }.getOrDefault(JSONObject())
                if (p.has("every_s")) {
                    val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                    TriggerHost.scheduleAlarm(
                        context, am, row.id,
                        System.currentTimeMillis() +
                            p.optLong("every_s").coerceAtLeast(60) * 1000,
                    )
                }
            } finally {
                pending.finish()
            }
        }
    }
}
