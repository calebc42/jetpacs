package com.calebc42.eabp

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

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
        val dao = EabpRuntime.database?.triggerDao() ?: return "trigger store unavailable"
        val parsed = mutableListOf<TriggerRow>()
        if (triggers != null) {
            for (i in 0 until triggers.length()) {
                val t = triggers.optJSONObject(i) ?: continue
                val id = t.optString("id")
                val type = t.optString("type")
                if (id.isEmpty() || type.isEmpty())
                    return "trigger ${i}: missing id or type"
                if (type !in SUPPORTED_TYPES)
                    return "trigger '$id': unknown type '$type'"
                parsed.add(TriggerRow(
                    id = id,
                    type = type,
                    params = (t.optJSONObject("params") ?: JSONObject()).toString(),
                    policy = t.optString("policy", "queue"),
                    dedupe = t.optString("dedupe").ifEmpty { null },
                    throttleS = if (t.has("throttle_s")) t.optLong("throttle_s") else null,
                    onFire = t.optJSONArray("on_fire")?.toString(),
                ))
            }
        }
        dao.replaceAll(parsed)
        arm(parsed)
        Log.i(TAG, "Trigger set replaced: ${parsed.size} trigger(s) armed")
        return null
    }

    /** Re-arm from the persisted table (service start, after boot). */
    fun armFromDatabase() {
        arm(EabpRuntime.database?.triggerDao()?.getAll() ?: emptyList())
    }

    /** Unregister everything (service teardown — receivers must not leak). */
    fun shutdown() {
        disarmReceivers()
        armNetworkCallback(false)
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
        if ("package" in types) register(packageReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addDataScheme("package")
        })
        armNetworkCallback("network" in types)
        // `boot` triggers arm nothing here — BootReceiver fires them.
        armTimeAlarms(context, newRows.filter { it.type == "time" })
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
            val transport = transportName(caps)
            val first = networkTransports.put(network, transport) == null
            if (first) fireNetwork("available", transport)
        }

        override fun onLost(network: Network) {
            fireNetwork("lost", networkTransports.remove(network))
        }
    }

    private fun transportName(caps: NetworkCapabilities): String = when {
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
        else -> "other"
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
        private const val TAG = "EabpTriggerHost"
        private const val PREFS = "eabp_triggers"
        private const val KEY_ALARM_CODES = "alarm_codes"
        /** Repeating time triggers never fire more often than this. */
        private const val MIN_EVERY_S = 60L

        val SUPPORTED_TYPES = setOf(
            "time", "power", "battery.level", "screen", "headset",
            "airplane", "boot", "timezone.changed", "package", "network",
        )

        /** Per-trigger last-fire clock for `throttle_s` (process-lifetime;
         * the FGS process IS the trigger host's lifetime). */
        private val lastFired = ConcurrentHashMap<String, Long>()

        /**
         * The firing pipeline — deliberately the same shape as
         * [ActionReceiver.handleTap]: live connection ⇒ send the
         * `event.action`, else the offline queue per policy. Static so the
         * alarm and boot receivers can fire without a host instance.
         */
        fun fireRow(context: Context, row: TriggerRow, data: JSONObject) {
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
            row.onFire?.let { executeOnFire(context, row.id, it) }

            val payload = JSONObject().apply {
                put("action", "trigger.fired")
                put("args", JSONObject().apply {
                    put("id", row.id)
                    put("type", row.type)
                    put("data", data)
                    put("at_ms", now)
                })
            }

            val conn = EabpRuntime.server?.connection()
            if (conn != null && conn.helloComplete &&
                conn.send(Frame(kind = "event.action", payload = payload))
            ) {
                Log.d(TAG, "Fired ${row.id} live")
                return
            }
            when (row.policy) {
                "drop" -> Log.d(TAG, "Dropped fire ${row.id} (policy=drop)")
                else -> {
                    EabpRuntime.database?.eventDao()?.insert(QueuedEvent(
                        kind = "event.action",
                        payload = payload.toString(),
                        dedupeKey = row.dedupe,
                    ))
                    EabpRuntime.refreshQueuedCount()
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
         */
        private fun executeOnFire(context: Context, id: String, onFireJson: String) {
            val list = runCatching { JSONArray(onFireJson) }.getOrNull() ?: return
            for (i in 0 until list.length()) {
                val entry = list.optJSONObject(i) ?: continue
                when {
                    entry.has("cap") -> {
                        val cap = entry.optString("cap")
                        try {
                            DeviceCapabilities.invoke(
                                context, cap, entry.optJSONObject("args") ?: JSONObject())
                            Log.d(TAG, "on_fire[$id]: $cap ok")
                        } catch (e: CapabilityException) {
                            Log.w(TAG, "on_fire[$id]: $cap failed: ${e.code} (${e.message})")
                        }
                    }
                    entry.has("notify") ->
                        postOnFireNotification(
                            context, id, entry.optJSONObject("notify") ?: JSONObject())
                    else -> Log.d(TAG, "on_fire[$id]: ignoring unknown entry $i")
                }
            }
        }

        private const val NOTIFY_CHANNEL = "eabp_automations"

        private fun postOnFireNotification(context: Context, id: String, spec: JSONObject) {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mgr.createNotificationChannel(NotificationChannel(
                    NOTIFY_CHANNEL, "Automations", NotificationManager.IMPORTANCE_DEFAULT))
            }
            val open = PendingIntent.getActivity(
                context, 0, EabpLaunch.openAppIntent(context),
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
            val rows = EabpRuntime.database?.triggerDao()?.getAll() ?: return
            for (row in rows.filter { it.type == "boot" }) {
                fireRow(context, row, JSONObject())
            }
            armTimeAlarms(context, rows.filter { it.type == "time" })
            Log.i(TAG, "Boot: rearmed ${rows.size} trigger(s)")
        }

        /**
         * (Re)arm exact alarms for the `time` triggers: cancel the previous
         * set (stable request codes in prefs, the [ReminderScheduler]
         * pattern), then arm `{at_ms}` one-shots and `{every_s}` repeats
         * (first fire one period from now; each fire re-arms the next —
         * `setRepeating` has been inexact since KitKat).
         */
        internal fun armTimeAlarms(context: Context, timeRows: List<TriggerRow>) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.getStringSet(KEY_ALARM_CODES, emptySet())!!.forEach { code ->
                code.toIntOrNull()?.let { am.cancel(alarmPending(context, it, "")) }
            }
            val codes = mutableSetOf<String>()
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
                codes.add(row.id.hashCode().toString())
            }
            prefs.edit().putStringSet(KEY_ALARM_CODES, codes).apply()
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
                action = "com.calebc42.eabp.TRIGGER_ALARM"
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
 * Fires `time` triggers. Reads the registration from the persisted table
 * (the process may have been cold-started by the alarm), so a stale alarm
 * whose trigger left the set is silently ignored — replace-set semantics
 * hold across process death.
 */
class TriggerAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("trigger_id") ?: return
        EabpRuntime.initialize(context.applicationContext)
        val pending = goAsync()
        kotlin.concurrent.thread(name = "EabpTriggerAlarm") {
            try {
                val dao = EabpRuntime.database?.triggerDao() ?: return@thread
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
