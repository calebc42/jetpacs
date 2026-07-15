package com.calebc42.jetpacs

import android.Manifest
import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * The `calendar.event` engine (SPEC §11): a synced org agenda — or any
 * device calendar — made reactive, with **zero polling**. Mechanism per
 * Easer's CalendarTracker: one [ContentObserver] on
 * `CalendarContract.Instances` plus, per registration, one AlarmManager
 * alarm parked at the *next boundary* — the current instance's end when
 * one is ongoing, the next matching start when idle, a re-scan fallback
 * when the lookahead window is empty. On observer change or alarm:
 * re-query, fire the edge if the ongoing side flipped, re-arm.
 *
 * Both views of the signal live here: the edge trigger (started/ended)
 * and the level predicate ([predicateHolds], the `when`/`state.get`
 * face). Everything is runtime-permission-gated on READ_CALENDAR:
 * ungranted means skip-with-a-log and predicates that never hold —
 * fail closed, never fire garbage.
 *
 * The boundary/matching *math* is pure and JVM-tested
 * (CalendarBoundaryTest); only the query and alarm plumbing touch
 * Android.
 */
object CalendarTriggers {

    private const val TAG = "JetpacsCalendarTriggers"
    private const val PREFS = "jetpacs_calendar_triggers"
    private const val KEY_ALARM_IDS = "alarm_ids"

    /** How far ahead the boundary query looks for the next matching
     * start; an empty window parks a re-scan alarm this far out. */
    internal const val LOOKAHEAD_MS = 7L * 24 * 60 * 60 * 1000

    /** One calendar instance, reduced to what matching needs. */
    data class CalInstance(
        val beginMs: Long,
        val endMs: Long,
        val title: String?,
        val calendar: String?,
    )

    // ── Pure matching & boundary math (JVM-tested) ───────────────────────────

    /** True when an instance with [title] in [calendar] matches the
     * registration's `params`: `title_contains` is a case-insensitive
     * substring, `calendar` matches the display name exactly. */
    internal fun instanceMatches(
        params: JSONObject, title: String?, calendar: String?,
    ): Boolean {
        val wantCal = params.optString("calendar")
        if (wantCal.isNotEmpty() && wantCal != (calendar ?: "")) return false
        val wantTitle = params.optString("title_contains")
        if (wantTitle.isNotEmpty() &&
            !(title ?: "").lowercase().contains(wantTitle.lowercase())
        ) return false
        return true
    }

    /**
     * Split matching [instances] into the boundary-relevant pair:
     * the ongoing instance whose end comes first (null when idle), and
     * the not-yet-started instance whose begin comes first (null when
     * nothing is ahead in the window).
     */
    internal fun classify(
        instances: List<CalInstance>, nowMs: Long,
    ): Pair<CalInstance?, CalInstance?> {
        val ongoing = instances
            .filter { it.beginMs <= nowMs && nowMs < it.endMs }
            .minByOrNull { it.endMs }
        val next = instances
            .filter { it.beginMs > nowMs }
            .minByOrNull { it.beginMs }
        return ongoing to next
    }

    /** The next moment worth waking at: the ongoing instance's end,
     * else the next start, else a lookahead re-scan fallback. */
    internal fun nextBoundaryMs(
        nowMs: Long, ongoing: CalInstance?, next: CalInstance?,
    ): Long = when {
        ongoing != null -> ongoing.endMs
        next != null -> next.beginMs
        else -> nowMs + LOOKAHEAD_MS
    }

    // ── Query plumbing ───────────────────────────────────────────────────────

    internal fun granted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    /** Query the instances window around now and classify it for
     * [params]. Requires READ_CALENDAR. */
    private fun queryState(
        resolver: ContentResolver, params: JSONObject, nowMs: Long,
    ): Pair<CalInstance?, CalInstance?> {
        val matches = mutableListOf<CalInstance>()
        val projection = arrayOf(
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
        )
        // The window starts a day back so an ongoing multi-hour/all-day
        // instance is still in view.
        CalendarContract.Instances.query(
            resolver, projection,
            nowMs - 24L * 60 * 60 * 1000, nowMs + LOOKAHEAD_MS,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val title = cursor.getString(2)
                val calendar = cursor.getString(3)
                if (instanceMatches(params, title, calendar)) {
                    matches.add(CalInstance(
                        cursor.getLong(0), cursor.getLong(1), title, calendar))
                }
            }
        }
        return classify(matches, nowMs)
    }

    /** The SPEC §11 `calendar.event` predicate: a matching instance is
     * ongoing right now. Ungranted READ_CALENDAR or a failing query →
     * false (fail closed), with a log. */
    fun predicateHolds(context: Context, predicate: JSONObject): Boolean = try {
        if (!granted(context)) {
            Log.w(TAG, "calendar.event predicate: READ_CALENDAR ungranted — not holding")
            false
        } else {
            queryState(context.contentResolver, predicate,
                System.currentTimeMillis()).first != null
        }
    } catch (e: Exception) {
        Log.w(TAG, "calendar.event predicate unevaluable: ${e.message}")
        false
    }

    /** The `state.get` sample: `{ongoing, title?, end_ms?, next_begin_ms?}`.
     * @throws CapabilityException `cap-permission` when READ_CALENDAR is
     * ungranted. */
    fun sample(context: Context): JSONObject {
        if (!granted(context))
            throw CapabilityException("cap-permission",
                "calendar.event needs the calendar permission",
                perm = "read_calendar", settings = "app")
        val (ongoing, next) = queryState(
            context.contentResolver, JSONObject(), System.currentTimeMillis())
        return JSONObject().apply {
            put("ongoing", ongoing != null)
            ongoing?.let {
                it.title?.let { t -> put("title", t) }
                put("end_ms", it.endMs)
            }
            next?.let { put("next_begin_ms", it.beginMs) }
        }
    }

    // ── The armed engine ─────────────────────────────────────────────────────

    /** Rows currently armed (snapshot for the observer path). */
    @Volatile
    private var armedRows: List<TriggerRow> = emptyList()

    /** Per-row last ongoing side, persisted in prefs so a boundary alarm
     * firing in a COLD process (the FGS died mid-event) still knows the
     * side it left and can fire the flip — the same durability the
     * trigger table itself has. Edges fire only on a side flip; the
     * first computation after (re)arming seeds silently. */
    private fun putSide(context: Context, id: String, ongoing: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean("side/$id", ongoing).apply()
    }

    private fun getSide(context: Context, id: String): Boolean? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return if (prefs.contains("side/$id")) prefs.getBoolean("side/$id", false)
               else null
    }

    private fun clearSides(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val edit = prefs.edit()
        prefs.all.keys.filter { it.startsWith("side/") }.forEach { edit.remove(it) }
        edit.apply()
    }

    /** Process-lifetime cache of the instance that defined a row's
     * ongoing side, so an `ended` fire can still describe what ended.
     * Best-effort only — a cold-process `ended` carries just the event. */
    private val lastInstance = ConcurrentHashMap<String, CalInstance>()

    private var observer: ContentObserver? = null

    /**
     * (Re)arm for [rows] (the calendar.event slice of the trigger set;
     * caller has verified READ_CALENDAR): register the single observer,
     * seed each row's side, park each row's boundary alarm. Idempotent —
     * replace-set discipline.
     */
    @Synchronized
    fun arm(context: Context, rows: List<TriggerRow>) {
        disarm(context)
        if (rows.isEmpty()) return
        armedRows = rows
        val obs = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                // An edit can move a boundary either way: recompute every
                // armed row, firing edges the change itself crossed.
                for (row in armedRows) recompute(context, row, mayFire = true)
            }
        }
        try {
            context.contentResolver.registerContentObserver(
                CalendarContract.Instances.CONTENT_URI, true, obs)
            observer = obs
        } catch (e: Exception) {
            Log.w(TAG, "calendar observer failed: ${e.message}")
        }
        for (row in rows) recompute(context, row, mayFire = false)
        Log.i(TAG, "calendar.event armed: ${rows.size} row(s)")
    }

    /** Unregister the observer, cancel the boundary alarms, clear memory. */
    @Synchronized
    fun disarm(context: Context) {
        observer?.let { runCatching { context.contentResolver.unregisterContentObserver(it) } }
        observer = null
        armedRows = emptyList()
        lastInstance.clear()
        clearSides(context)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getStringSet(KEY_ALARM_IDS, emptySet())!!.forEach { id ->
            am.cancel(alarmPending(context, id))
        }
        prefs.edit().putStringSet(KEY_ALARM_IDS, emptySet()).apply()
    }

    /** The boundary alarm fired for [row] (possibly in a cold process):
     * recompute, fire a crossed edge, re-arm. */
    fun onAlarm(context: Context, row: TriggerRow) {
        if (!granted(context)) {
            Log.w(TAG, "calendar alarm for ${row.id}: READ_CALENDAR revoked — not re-arming")
            return
        }
        recompute(context, row, mayFire = true)
    }

    private fun recompute(context: Context, row: TriggerRow, mayFire: Boolean) {
        val params = runCatching { JSONObject(row.params) }.getOrDefault(JSONObject())
        val now = System.currentTimeMillis()
        val (ongoing, next) = try {
            queryState(context.contentResolver, params, now)
        } catch (e: Exception) {
            Log.w(TAG, "calendar query failed for ${row.id}: ${e.message}")
            return
        }
        val nowOngoing = ongoing != null
        val previous = getSide(context, row.id)
        putSide(context, row.id, nowOngoing)
        val previousInstance = lastInstance[row.id]
        if (ongoing != null) lastInstance[row.id] = ongoing
        if (mayFire && previous != null && previous != nowOngoing) {
            val event = if (nowOngoing) "started" else "ended"
            val want = params.optString("event")
            if (want.isEmpty() || want == event) {
                val subject = if (nowOngoing) ongoing else previousInstance
                val data = JSONObject().put("event", event)
                subject?.let {
                    it.title?.let { t -> data.put("title", t) }
                    data.put("begin_ms", it.beginMs)
                    data.put("end_ms", it.endMs)
                }
                TriggerHost.fireRow(context, row, data)
            }
        }
        armBoundary(context, row.id, nextBoundaryMs(now, ongoing, next))
    }

    private fun armBoundary(context: Context, id: String, atMs: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = alarmPending(context, id)
        val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            am.canScheduleExactAlarms()
        if (canExact) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pi)
        } else {
            am.set(AlarmManager.RTC_WAKEUP, atMs, pi)
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val ids = prefs.getStringSet(KEY_ALARM_IDS, emptySet())!!.toMutableSet()
        if (ids.add(id)) prefs.edit().putStringSet(KEY_ALARM_IDS, ids).apply()
    }

    private fun alarmPending(context: Context, id: String) =
        android.app.PendingIntent.getBroadcast(
            context, id.hashCode(),
            Intent(context, CalendarAlarmReceiver::class.java).apply {
                action = "com.calebc42.jetpacs.CALENDAR_ALARM"
                // The data URI participates in filterEquals (the
                // TriggerAlarmReceiver idiom): colliding hashCodes still
                // get distinct PendingIntents.
                data = Uri.parse("jetpacs-calendar:" + Uri.encode(id))
                putExtra("trigger_id", id)
            },
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )
}

/**
 * Fires `calendar.event` boundary alarms. The TriggerAlarmReceiver
 * cold-read idiom: the registration is read from the persisted table
 * (the process may have been cold-started), so a stale alarm whose
 * trigger left the set self-ignores — replace-set semantics hold across
 * process death.
 */
class CalendarAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("trigger_id") ?: return
        JetpacsRuntime.initialize(context.applicationContext)
        val pending = goAsync()
        kotlin.concurrent.thread(name = "JetpacsCalendarAlarm") {
            try {
                val dao = JetpacsRuntime.database?.triggerDao() ?: return@thread
                val row = dao.byId(id) ?: return@thread  // stale: not in the set
                if (row.type != "calendar.event") return@thread
                CalendarTriggers.onAlarm(context, row)
            } finally {
                pending.finish()
            }
        }
    }
}
