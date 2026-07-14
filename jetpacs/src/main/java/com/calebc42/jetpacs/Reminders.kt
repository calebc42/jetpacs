package com.calebc42.jetpacs

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONArray

/**
 * Exact-alarm reminders for timed org items (SCHEDULED/DEADLINE with a
 * clock time). Emacs computes the upcoming set and sends `reminders.set`
 * on every dashboard push (deduplicated Emacs-side).
 *
 * Sets are partitioned by OWNER (the app-id in the wire payload; a blank
 * owner is the unowned/core bucket). A `reminders.set` REPLACES only its
 * owner's previous set, so two coexisting apps never cancel each other's
 * alarms — the safety `jetpacs-reminders-owner-set` promises. Request codes
 * are hashed with the owner, so distinct apps can't collide.
 *
 * Each owner's set is persisted so [BootReceiver] can reschedule every
 * owner after a reboot (alarms don't survive one); the next Emacs
 * connection replaces them again anyway.
 */
object ReminderScheduler {
    private const val TAG = "JetpacsReminders"
    private const val PREFS = "jetpacs_reminders"
    private const val KEY_OWNERS = "owners"
    // Pre-owner global keys, migrated away (cancelled + cleared) on first use.
    private const val LEGACY_CODES = "codes"
    private const val LEGACY_SET = "set"

    private fun setKey(owner: String) = "set:$owner"
    private fun codesKey(owner: String) = "codes:$owner"

    /**
     * Replace OWNER's reminder set, leaving every other owner's alarms armed.
     * A null/blank [owner] is the unowned "" bucket (a legacy global set,
     * or an owner-unaware Emacs, lands here). Only this owner's
     * previously-armed alarms are cancelled and replaced.
     */
    fun replaceAll(context: Context, owner: String?, reminders: JSONArray?) {
        val key = owner?.takeIf { it.isNotEmpty() } ?: ""
        migrateLegacy(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .putString(setKey(key), reminders?.toString() ?: "[]")
            .putStringSet(KEY_OWNERS, prefs.getStringSet(KEY_OWNERS, emptySet())!! + key)
            .apply()
        arm(context, key, reminders)
    }

    /** Re-arm every owner's persisted set ([BootReceiver]); past items drop. */
    fun rescheduleAfterBoot(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (owner in prefs.getStringSet(KEY_OWNERS, emptySet())!!) {
            val stored = prefs.getString(setKey(owner), null) ?: continue
            arm(context, owner, runCatching { JSONArray(stored) }.getOrNull())
        }
    }

    /**
     * One-time move off the pre-owner global keys: cancel their alarms (the
     * new per-owner codes wouldn't match them) and clear the keys. A no-op
     * once done.
     */
    private fun migrateLegacy(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val legacy = prefs.getStringSet(LEGACY_CODES, null) ?: return
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        legacy.forEach { code ->
            code.toIntOrNull()?.let { am.cancel(pending(context, it, null, null)) }
        }
        prefs.edit().remove(LEGACY_CODES).remove(LEGACY_SET).apply()
    }

    private fun arm(context: Context, owner: String, reminders: JSONArray?) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        // Cancel only THIS owner's previous alarms (stable per-owner codes).
        prefs.getStringSet(codesKey(owner), emptySet())!!.forEach { code ->
            code.toIntOrNull()?.let { am.cancel(pending(context, it, null, null)) }
        }

        val codes = mutableSetOf<String>()
        if (reminders != null) {
            val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            for (i in 0 until reminders.length()) {
                val r = reminders.optJSONObject(i) ?: continue
                val at = r.optLong("at_ms")
                if (at <= System.currentTimeMillis()) continue
                val code = requestCode(owner, r.optString("id"))
                val pi = pending(context, code, r.optString("title"), r.optString("body"))
                if (canExact) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                } else {
                    // Permission revoked: inexact is better than nothing.
                    am.set(AlarmManager.RTC_WAKEUP, at, pi)
                }
                codes.add(code.toString())
            }
            Log.i(TAG, "Armed ${codes.size} reminder(s) for owner='$owner', exact=$canExact")
        }
        prefs.edit().putStringSet(codesKey(owner), codes).apply()
    }

    /** Owner-scoped, stable request code so distinct apps never collide. */
    private fun requestCode(owner: String, id: String) = java.util.Objects.hash(owner, id)

    private fun pending(context: Context, code: Int, title: String?, body: String?): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = "com.calebc42.jetpacs.REMINDER"
            putExtra("title", title)
            putExtra("body", body)
            putExtra("code", code)
        }
        return PendingIntent.getBroadcast(
            context, code, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/** Fires at the reminder time; posts a heads-up notification. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra("title") ?: return
        val body = intent.getStringExtra("body") ?: ""
        val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL, "Org reminders", NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
        val open = PendingIntent.getActivity(
            context, 0,
            JetpacsLaunch.openAppIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .build()
        mgr.notify(intent.getIntExtra("code", 0), notification)
    }

    companion object { private const val CHANNEL = "jetpacs_reminders" }
}
