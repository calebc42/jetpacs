package com.calebc42.eabp

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
 * on every dashboard push (deduplicated Emacs-side); each set REPLACES
 * the previous one, so cancelled/rescheduled items never fire stale.
 *
 * The set is persisted so [BootReceiver] can reschedule after a reboot
 * (alarms don't survive one); the next Emacs connection replaces it
 * again anyway.
 */
object ReminderScheduler {
    private const val TAG = "EabpReminders"
    private const val PREFS = "eabp_reminders"
    private const val KEY_CODES = "codes"
    private const val KEY_SET = "set"

    fun replaceAll(context: Context, reminders: JSONArray?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_SET, reminders?.toString() ?: "[]").apply()
        arm(context, reminders)
    }

    /** Re-arm the persisted set ([BootReceiver]); past items just drop. */
    fun rescheduleAfterBoot(context: Context) {
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_SET, null) ?: return
        arm(context, runCatching { JSONArray(stored) }.getOrNull())
    }

    private fun arm(context: Context, reminders: JSONArray?) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        // Cancel everything from the previous set (stable request codes).
        prefs.getStringSet(KEY_CODES, emptySet())!!.forEach { code ->
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
                val code = r.optString("id").hashCode()
                val pi = pending(context, code, r.optString("title"), r.optString("body"))
                if (canExact) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                } else {
                    // Permission revoked: inexact is better than nothing.
                    am.set(AlarmManager.RTC_WAKEUP, at, pi)
                }
                codes.add(code.toString())
            }
            Log.i(TAG, "Armed ${codes.size} reminder(s), exact=$canExact")
        }
        prefs.edit().putStringSet(KEY_CODES, codes).apply()
    }

    private fun pending(context: Context, code: Int, title: String?, body: String?): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = "com.calebc42.eabp.REMINDER"
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
            EabpLaunch.openAppIntent(context),
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

    companion object { private const val CHANNEL = "eabp_reminders" }
}
