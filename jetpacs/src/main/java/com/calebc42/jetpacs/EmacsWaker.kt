package com.calebc42.jetpacs

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * The `wake` offline policy: get Emacs running so the queued event can be
 * delivered.
 *
 * Modern Android blocks background activity launches, and notification
 * trampolines (broadcast -> startActivity) are banned on targetSdk 31+,
 * so a guaranteed silent wake isn't available to us. Strategy:
 *
 *  1. Opportunistically attempt a direct launch (succeeds in the few
 *     contexts where we hold a background-activity-launch grant).
 *  2. Always post a high-priority "tap to open Emacs" notification whose
 *     content intent launches Emacs directly — fully compliant, one tap.
 *
 * The notification is cleared automatically when Emacs completes the
 * handshake ([JetpacsConnection.handleHello] calls [clear]); queued events
 * then flow via the normal replay.
 */
object EmacsWaker {
    /** Package of the Termux-signed Emacs build. */
    const val EMACS_PACKAGE = "org.gnu.emacs"

    private const val CHANNEL_ID = "jetpacs_wake"
    private const val NOTIF_ID = 7712
    private const val TAG = "EmacsWaker"

    fun requestWake(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(EMACS_PACKAGE)
        if (launch == null) {
            Log.w(TAG, "Emacs ($EMACS_PACKAGE) not installed; cannot wake")
            return
        }

        // 1. Opportunistic direct launch (may be silently dropped by the OS).
        runCatching {
            context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { Log.d(TAG, "Direct launch blocked: ${it.message}") }

        // 2. Compliant fallback: tap-to-open notification.
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Emacs wake requests",
                    NotificationManager.IMPORTANCE_HIGH,
                )
            )
        }
        val pi = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Emacs needed")
            .setContentText("An action is waiting — tap to open Emacs and deliver it.")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        manager.notify(NOTIF_ID, notification)
    }

    /** Called when the handshake completes: the wake succeeded. */
    fun clear(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIF_ID)
    }
}