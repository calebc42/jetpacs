package com.calebc42.eabp

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * Typed capability failure (SPEC §10): [code] is one of `cap-unsupported` |
 * `cap-permission` | `cap-failed`. A cap-permission failure carries [perm]
 * (the missing `device.perms` key) and, when one exists, [settings] — a
 * value the client can pass back to `settings.open` to reach the grant
 * screen.
 */
class CapabilityException(
    val code: String,
    message: String,
    val perm: String? = null,
    val settings: String? = null,
) : Exception(message)

/**
 * The Emacs → device effector channel (SPEC §10).
 *
 * A dispatch table keyed by capability name: [EabpConnection] routes
 * `capability.invoke` here, and the session welcome reports [names] as
 * `device.caps` and [permissionMap] as `device.perms` so the client can
 * degrade gracefully — grey out a control, deep-link to the grant screen —
 * instead of invoking blind. Failures are typed, never crashes: an
 * ungranted permission is a normal answer.
 *
 * The catalog grows by one map entry + one function per effector
 * (`intent.start`, `vibrate`, `tts.speak`, … — the automation plan's
 * Tasks 3–5). Every entry must be documented in SPEC §10 when it ships.
 */
object DeviceCapabilities {

    private val handlers: Map<String, (Context, JSONObject) -> JSONObject> = mapOf(
        "settings.open" to ::settingsOpen,
    )

    /** Invocable capability names, for the welcome's `device.caps`. */
    fun names(): List<String> = handlers.keys.sorted()

    /**
     * Run capability [cap] with plain-data [args]; returns the result
     * object (empty for pure effectors).
     * @throws CapabilityException with a typed code on any failure.
     */
    fun invoke(context: Context, cap: String, args: JSONObject): JSONObject {
        val handler = handlers[cap]
            ?: throw CapabilityException("cap-unsupported", "unknown capability '$cap'")
        return try {
            handler(context, args)
        } catch (e: CapabilityException) {
            throw e
        } catch (e: Exception) {
            throw CapabilityException("cap-failed", "$cap: ${e.message}")
        }
    }

    /**
     * `settings.open {panel}` — the compliant "toggle" for radios Android
     * no longer lets apps flip directly. Named panels use the floating
     * [Settings.Panel] where the platform has one, the full settings
     * screen otherwise. Arbitrary `android.settings.*` action strings
     * pass through (settings screens only — this never becomes a general
     * intent escape hatch; that is `intent.start` with its own spec entry).
     * Best-effort while backgrounded: Android may drop the launch.
     */
    private fun settingsOpen(context: Context, args: JSONObject): JSONObject {
        val panel = args.optString("panel")
        val floating = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val action = when {
            panel == "wifi" ->
                if (floating) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS
            panel == "internet" ->
                if (floating) Settings.Panel.ACTION_INTERNET_CONNECTIVITY
                else Settings.ACTION_WIRELESS_SETTINGS
            panel == "volume" ->
                if (floating) Settings.Panel.ACTION_VOLUME else Settings.ACTION_SOUND_SETTINGS
            panel == "nfc" ->
                if (floating) Settings.Panel.ACTION_NFC else Settings.ACTION_NFC_SETTINGS
            panel == "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            panel.startsWith("android.settings.") -> panel
            panel.isEmpty() ->
                throw CapabilityException("cap-failed", "settings.open: missing 'panel'")
            else ->
                throw CapabilityException("cap-failed", "settings.open: unknown panel '$panel'")
        }
        try {
            context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            throw CapabilityException("cap-failed", "settings.open: no activity for '$action'")
        }
        return JSONObject()
    }

    /**
     * The device permission map for the welcome's `device.perms` — the
     * `canScheduleExactAlarms` precedent generalized. A welcome-time
     * snapshot; capabilities re-check at invoke time, so staleness can
     * only cause a typed error, never a wrong action.
     */
    fun permissionMap(context: Context): JSONObject = JSONObject().apply {
        put("post_notifications",
            granted(context, Manifest.permission.POST_NOTIFICATIONS,
                Build.VERSION_CODES.TIRAMISU))
        put("exact_alarms", canScheduleExactAlarms(context))
        put("write_settings", Settings.System.canWrite(context))
        put("notification_policy",
            notificationManager(context).isNotificationPolicyAccessGranted)
        put("notification_listener",
            NotificationManagerCompat.getEnabledListenerPackages(context)
                .contains(context.packageName))
        put("fine_location", granted(context, Manifest.permission.ACCESS_FINE_LOCATION))
        put("bluetooth_connect",
            granted(context, Manifest.permission.BLUETOOTH_CONNECT, Build.VERSION_CODES.S))
    }

    /** True when [permission] is granted (or the device predates [sinceSdk]). */
    private fun granted(context: Context, permission: String, sinceSdk: Int = 0): Boolean =
        if (Build.VERSION.SDK_INT >= sinceSdk) {
            ContextCompat.checkSelfPermission(context, permission) ==
                PackageManager.PERMISSION_GRANTED
        } else true

    private fun canScheduleExactAlarms(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
                .canScheduleExactAlarms()
        } else true

    private fun notificationManager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
