package com.calebc42.eabp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlin.concurrent.thread

/**
 * Reboot persistence: alarms do not survive a reboot, and neither do
 * context-registered receivers, so this receiver (a) fires `boot`
 * triggers and re-arms `time` alarms from the persisted trigger table,
 * (b) reschedules the persisted reminder set — closing the old
 * reminders-die-on-reboot gap — and (c) starts [BridgeService], whose
 * [TriggerHost] re-arms the broadcast-driven trigger types.
 *
 * BOOT_COMPLETED is on the FGS background-start exemption list, so the
 * service start is compliant.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        Log.i(TAG, "Boot: restoring triggers and reminders")
        EabpRuntime.initialize(context.applicationContext)

        val pending = goAsync()
        thread(name = "EabpBoot") {
            try {
                TriggerHost.onBoot(context.applicationContext)
                ReminderScheduler.rescheduleAfterBoot(context.applicationContext)
            } catch (e: Exception) {
                Log.e(TAG, "Boot restore failed", e)
            } finally {
                pending.finish()
            }
        }

        runCatching { BridgeService.start(context) }
            .onFailure { Log.w(TAG, "Bridge start after boot failed: ${it.message}") }
    }

    companion object { private const val TAG = "EabpBootReceiver" }
}
