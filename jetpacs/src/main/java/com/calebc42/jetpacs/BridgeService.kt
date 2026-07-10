package com.calebc42.jetpacs

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Long-lived host for [JetpacsServer] and the [SurfaceManager].
 *
 * A foreground service is the realistic way to keep a socket listener alive on
 * modern Android, and it matches the spec's "companion is the durable party":
 * the OS keeps this around so it can answer notification actions and render
 * cached surfaces whether or not Emacs is connected.
 */
class BridgeService : Service() {

    private lateinit var server: JetpacsServer
    private lateinit var surfaces: SurfaceManager

    override fun onCreate() {
        super.onCreate()

        // The queue is only as alive as this call.
        JetpacsRuntime.initialize(applicationContext)

        surfaces = SurfaceManager(applicationContext)
        server = JetpacsServer(applicationContext, surfaces)

        // Expose to the BroadcastReceiver that handles notification taps.
        JetpacsRuntime.surfaceManager = surfaces
        JetpacsRuntime.server = server

        // Trigger listening rides this always-on process — the FGS cost is
        // already paid; receivers arm from the persisted table below.
        val triggers = TriggerHost(applicationContext)
        JetpacsRuntime.triggerHost = triggers

        startForeground(NOTIF_ID, buildNotification())

        // Render anything we already hold BEFORE Emacs connects — principle #1.
        surfaces.renderAllCached()

        // Off-main: Room forbids the main thread for both of these.
        Thread {
            JetpacsRuntime.refreshQueuedCount()
            triggers.armFromDatabase()
        }.start()

        server.start()
    }

    // Sticky so the OS restarts the bridge if it's ever killed.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_STICKY

    override fun onDestroy() {
        server.stop()
        JetpacsRuntime.server = null
        // Receivers must not leak past the process's trigger-hosting span.
        JetpacsRuntime.triggerHost?.shutdown()
        JetpacsRuntime.triggerHost = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Jetpacs Bridge", NotificationManager.IMPORTANCE_MIN),
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Jetpacs bridge")
            .setContentText("Listening for Emacs")
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "jetpacs_bridge"
        private const val NOTIF_ID = 7711

        /** Start the bridge (foreground-aware). Call once from your Activity. */
        fun start(context: Context) {
            val intent = Intent(context, BridgeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}