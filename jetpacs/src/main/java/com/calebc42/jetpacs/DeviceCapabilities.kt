package com.calebc42.jetpacs

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.core.graphics.drawable.toBitmap
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

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
 * A dispatch table keyed by capability name: [JetpacsConnection] routes
 * `capability.invoke` here, and the session welcome reports [names] as
 * `device.caps` and [permissionMap] as `device.perms` so the client can
 * degrade gracefully — grey out a control, deep-link to the grant screen —
 * instead of invoking blind. Failures are typed, never crashes: an
 * ungranted permission is a normal answer.
 *
 * The catalog grows by one map entry + one function per effector; every
 * entry must be documented in SPEC §10's catalog table when it ships.
 * Special-access effectors (brightness, DND) are the automation plan's
 * Task 5.
 */
object DeviceCapabilities {

    private const val TAG = "JetpacsDeviceCaps"
    private const val DND_SETTINGS = "android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS"

    private val handlers: Map<String, (Context, JSONObject) -> JSONObject> = mapOf(
        "settings.open" to ::settingsOpen,
        "intent.start" to ::intentStart,
        "app.launch" to ::appLaunch,
        "apps.list" to ::appsList,
        "shortcut.pin" to ::shortcutPin,
        "shortcuts.set" to ::shortcutsSet,
        "vibrate" to ::vibrate,
        "tts.speak" to ::ttsSpeak,
        "volume.set" to ::volumeSet,
        "ringer.mode" to ::ringerMode,
        "flashlight" to ::flashlight,
        "media.key" to ::mediaKey,
        "clipboard.read" to ::clipboardRead,
        "screen.keep_on" to ::screenKeepOn,
        "brightness.set" to ::brightnessSet,
        "dnd.set" to ::dndSet,
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

    // ── settings ─────────────────────────────────────────────────────────────

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
            // The app-info page: where the OS puts this app's runtime
            // permission grants (notifications, location, nearby devices).
            panel == "app" -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            panel.startsWith("android.settings.") -> panel
            panel.isEmpty() ->
                throw CapabilityException("cap-failed", "settings.open: missing 'panel'")
            else ->
                throw CapabilityException("cap-failed", "settings.open: unknown panel '$panel'")
        }
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Screens that support a per-app deep link get one — landing on
        // this app's own toggle instead of a list to hunt through. (The
        // DND-access screen takes no package and always shows the list.)
        if (panel == "app" ||
            action == "android.settings.action.MANAGE_WRITE_SETTINGS" ||
            action == "android.settings.REQUEST_SCHEDULE_EXACT_ALARM"
        ) intent.data = Uri.parse("package:${context.packageName}")
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw CapabilityException("cap-failed", "settings.open: no activity for '$action'")
        }
        return JSONObject()
    }

    // ── Special-access effectors (automation plan Task 5) ────────────────────

    /** `brightness.set {level}` — 0–255, behind the write-settings grant. */
    private fun brightnessSet(context: Context, args: JSONObject): JSONObject {
        if (!args.has("level"))
            throw CapabilityException("cap-failed", "brightness.set: missing 'level'")
        if (!Settings.System.canWrite(context))
            throw CapabilityException("cap-permission",
                "brightness.set needs the modify-system-settings grant",
                perm = "write_settings",
                settings = "android.settings.action.MANAGE_WRITE_SETTINGS")
        val level = args.optInt("level").coerceIn(0, 255)
        val resolver = context.contentResolver
        Settings.System.putInt(resolver,
            Settings.System.SCREEN_BRIGHTNESS_MODE,
            Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
        Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, level)
        return JSONObject()
    }

    /** `dnd.set {mode}` — on | off | priority, behind DND access. */
    private fun dndSet(context: Context, args: JSONObject): JSONObject {
        val nm = notificationManager(context)
        if (!nm.isNotificationPolicyAccessGranted)
            throw CapabilityException("cap-permission",
                "dnd.set needs Do Not Disturb access",
                perm = "notification_policy", settings = DND_SETTINGS)
        val filter = when (val m = args.optString("mode")) {
            "on" -> NotificationManager.INTERRUPTION_FILTER_NONE
            "priority" -> NotificationManager.INTERRUPTION_FILTER_PRIORITY
            "off" -> NotificationManager.INTERRUPTION_FILTER_ALL
            else -> throw CapabilityException("cap-failed", "dnd.set: unknown mode '$m'")
        }
        nm.setInterruptionFilter(filter)
        return JSONObject()
    }

    // ── intents (the universal escape hatch) ─────────────────────────────────

    /**
     * `intent.start {action?, data?, package?, class_name?, mime?, extras?,
     * mode?}` — this alone covers the largest slice of Tasker's action
     * list. Extras are plain data only (string/number/boolean): the wire
     * never carries anything executable. Activity mode is best-effort
     * while backgrounded (Android background-activity-launch limits).
     */
    private fun intentStart(context: Context, args: JSONObject): JSONObject {
        val action = args.optString("action")
        val data = args.optString("data")
        val pkg = args.optString("package")
        val className = args.optString("class_name")
        val mime = args.optString("mime")
        if (action.isEmpty() && className.isEmpty() && pkg.isEmpty())
            throw CapabilityException("cap-failed",
                "intent.start: needs 'action', 'package', or 'package'+'class_name'")
        if (className.isNotEmpty() && pkg.isEmpty())
            throw CapabilityException("cap-failed",
                "intent.start: 'class_name' needs 'package'")

        val intent = Intent()
        if (action.isNotEmpty()) intent.action = action
        when {
            data.isNotEmpty() && mime.isNotEmpty() ->
                intent.setDataAndType(Uri.parse(data), mime)
            data.isNotEmpty() -> intent.data = Uri.parse(data)
            mime.isNotEmpty() -> intent.type = mime
        }
        when {
            className.isNotEmpty() -> intent.component = ComponentName(pkg, className)
            pkg.isNotEmpty() -> intent.setPackage(pkg)
        }
        args.optJSONObject("extras")?.let { extras ->
            for (key in extras.keys()) {
                when (val v = extras.get(key)) {
                    is String -> intent.putExtra(key, v)
                    is Boolean -> intent.putExtra(key, v)
                    is Int -> intent.putExtra(key, v)
                    is Long -> intent.putExtra(key, v)
                    is Double -> intent.putExtra(key, v)
                    else -> throw CapabilityException("cap-failed",
                        "intent.start: extra '$key' must be a string, number, or boolean")
                }
            }
        }
        when (val mode = args.optString("mode", "activity")) {
            "activity" -> {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                } catch (e: ActivityNotFoundException) {
                    throw CapabilityException("cap-failed", "intent.start: no activity matches")
                }
            }
            "broadcast" -> context.sendBroadcast(intent)
            "service" -> context.startService(intent)
                ?: throw CapabilityException("cap-failed", "intent.start: no service matches")
            else -> throw CapabilityException("cap-failed", "intent.start: unknown mode '$mode'")
        }
        return JSONObject()
    }

    /** `app.launch {package}` — the [EmacsWaker] launch pattern for any app. */
    private fun appLaunch(context: Context, args: JSONObject): JSONObject {
        val pkg = args.optString("package")
        if (pkg.isEmpty()) throw CapabilityException("cap-failed", "app.launch: missing 'package'")
        val intent = context.packageManager.getLaunchIntentForPackage(pkg)
            ?: throw CapabilityException("cap-failed",
                "app.launch: no launchable activity for '$pkg' (installed and visible?)")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return JSONObject()
    }

    /**
     * `apps.list` → `{apps: [{label, package}]}` — launchable packages, so
     * elisp can build a `completing-read` picker. Requires the library
     * manifest's `<queries>` element (Android 11 package visibility).
     */
    private fun appsList(context: Context, @Suppress("UNUSED_PARAMETER") args: JSONObject): JSONObject {
        val pm = context.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val apps = pm.queryIntentActivities(launcher, 0)
            .map { info ->
                JSONObject()
                    .put("label", info.loadLabel(pm).toString())
                    .put("package", info.activityInfo.packageName)
            }
            .sortedBy { it.optString("label").lowercase() }
        return JSONObject().put("apps", JSONArray(apps))
    }

    // ── launcher shortcuts ───────────────────────────────────────────────────

    /**
     * `shortcut.pin {id, label, action, icon_png?, long_label?}` — request
     * a home-screen pinned shortcut whose tap opens the host app with
     * `action` embedded (the [JetpacsLaunch] extras contract, so it joins
     * the live/queue pipeline exactly like a widget row tap). This is how
     * an Elisp-composed app gets launcher identity without its own APK:
     * `icon_png` supplies the logo and Android persists it inside the pin.
     * Re-pinning an existing id updates label/icon/action in place, no
     * confirmation dialog — a distro shipping a logo refresh just calls
     * again. A fresh pin goes through the launcher's confirm dialog; the
     * reply means "requested", not "placed" (Android exposes no reliable
     * completion signal).
     */
    private fun shortcutPin(context: Context, args: JSONObject): JSONObject {
        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(context))
            throw CapabilityException("cap-failed",
                "shortcut.pin: this launcher does not support pinned shortcuts")
        val info = buildShortcut(context, args, "shortcut.pin")
        val alreadyPinned = ShortcutManagerCompat
            .getShortcuts(context, ShortcutManagerCompat.FLAG_MATCH_PINNED)
            .any { it.id == info.id }
        if (alreadyPinned) {
            ShortcutManagerCompat.updateShortcuts(context, listOf(info))
            return JSONObject().put("updated", true)
        }
        ShortcutManagerCompat.requestPinShortcut(context, info, null)
        return JSONObject()
    }

    /**
     * `shortcuts.set {shortcuts: [{id, label, action, icon_png?,
     * long_label?}]}` — replace-set of the app icon's long-press (dynamic)
     * shortcuts, the same whole-set discipline as `triggers.set`. An empty
     * list clears them. A set larger than the launcher's per-activity max
     * is refused outright rather than silently truncated.
     */
    private fun shortcutsSet(context: Context, args: JSONObject): JSONObject {
        val list = args.optJSONArray("shortcuts")
            ?: throw CapabilityException("cap-failed", "shortcuts.set: missing 'shortcuts'")
        val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
        if (list.length() > max)
            throw CapabilityException("cap-failed",
                "shortcuts.set: ${list.length()} shortcuts exceed this launcher's max of $max")
        val infos = (0 until list.length()).map { i ->
            buildShortcut(context,
                list.optJSONObject(i) ?: throw CapabilityException("cap-failed",
                    "shortcuts.set: shortcuts[$i] is not an object"),
                "shortcuts.set")
        }
        if (infos.isEmpty()) ShortcutManagerCompat.removeAllDynamicShortcuts(context)
        else ShortcutManagerCompat.setDynamicShortcuts(context, infos)
        return JSONObject()
    }

    /** One shortcut entry → [ShortcutInfoCompat]; [cap] names the caller in errors. */
    private fun buildShortcut(
        context: Context, args: JSONObject, cap: String,
    ): ShortcutInfoCompat {
        val id = args.optString("id")
        val label = args.optString("label")
        val action = args.optJSONObject("action")
        if (id.isEmpty()) throw CapabilityException("cap-failed", "$cap: missing 'id'")
        if (label.isEmpty()) throw CapabilityException("cap-failed", "$cap: missing 'label'")
        if (action == null) throw CapabilityException("cap-failed", "$cap: missing 'action'")
        val builder = ShortcutInfoCompat.Builder(context, id)
            .setShortLabel(label)
            .setIcon(shortcutIcon(context, args.optString("icon_png"), cap))
            // Revision -1: a shortcut outlives any surface revision, like a
            // share intent. The action string round-trips untouched.
            .setIntent(JetpacsLaunch.openAppIntent(context, action.toString(), -1))
        args.optString("long_label").takeIf { it.isNotEmpty() }
            ?.let { builder.setLongLabel(it) }
        return builder.build()
    }

    /**
     * Base64 PNG → an adaptive icon the launcher masks to its shape; empty
     * → the host app's own icon. Oversized bitmaps are scaled down before
     * crossing the binder (the system persists pinned-shortcut icons).
     */
    private fun shortcutIcon(context: Context, iconB64: String, cap: String): IconCompat {
        if (iconB64.isEmpty()) {
            return IconCompat.createWithBitmap(
                context.packageManager.getApplicationIcon(context.packageName).toBitmap())
        }
        val bytes = try {
            Base64.decode(iconB64, Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            throw CapabilityException("cap-failed", "$cap: 'icon_png' is not valid base64")
        }
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw CapabilityException("cap-failed",
                "$cap: 'icon_png' did not decode as an image")
        val maxDim = 512
        if (bitmap.width > maxDim || bitmap.height > maxDim) {
            val scale = maxDim.toFloat() / maxOf(bitmap.width, bitmap.height)
            bitmap = Bitmap.createScaledBitmap(bitmap,
                (bitmap.width * scale).toInt().coerceAtLeast(1),
                (bitmap.height * scale).toInt().coerceAtLeast(1), true)
        }
        return IconCompat.createWithAdaptiveBitmap(bitmap)
    }

    // ── permission-free effectors ────────────────────────────────────────────

    /** `vibrate {ms?}` or `{pattern: [offMs, onMs, …]}`. */
    private fun vibrate(context: Context, args: JSONObject): JSONObject {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager)
                .defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrator.hasVibrator())
            throw CapabilityException("cap-failed", "vibrate: no vibrator on this device")
        val pattern = args.optJSONArray("pattern")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (pattern != null) {
                vibrator.vibrate(VibrationEffect.createWaveform(
                    LongArray(pattern.length()) { pattern.optLong(it) }, -1))
            } else {
                vibrator.vibrate(VibrationEffect.createOneShot(
                    args.optLong("ms", 200L), VibrationEffect.DEFAULT_AMPLITUDE))
            }
        } else {
            @Suppress("DEPRECATION")
            if (pattern != null) {
                vibrator.vibrate(LongArray(pattern.length()) { pattern.optLong(it) }, -1)
            } else {
                vibrator.vibrate(args.optLong("ms", 200L))
            }
        }
        return JSONObject()
    }

    /**
     * `tts.speak {text, pitch?, rate?}` — asynchronous best-effort: the
     * engine lazy-inits on first use (utterances queue during init) and is
     * released after ~60s idle so no speech service lingers. Everything
     * runs on the main looper, so no locking.
     */
    private fun ttsSpeak(context: Context, args: JSONObject): JSONObject {
        if (args.optString("text").isEmpty())
            throw CapabilityException("cap-failed", "tts.speak: missing 'text'")
        mainHandler.post { ttsSpeakOnMain(context.applicationContext, args) }
        return JSONObject()
    }

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val ttsPending = mutableListOf<JSONObject>()

    private fun ttsSpeakOnMain(context: Context, args: JSONObject) {
        val engine = tts
        when {
            engine != null && ttsReady -> ttsSpeakNow(engine, args)
            engine != null -> ttsPending.add(args)
            else -> {
                ttsPending.add(args)
                tts = TextToSpeech(context) { status ->
                    mainHandler.post {
                        if (status == TextToSpeech.SUCCESS) {
                            ttsReady = true
                            tts?.let { e -> ttsPending.forEach { ttsSpeakNow(e, it) } }
                        } else {
                            // The invoke already ACKed (speak is async), so
                            // the failure must be visible some other way.
                            Log.w(TAG, "tts.speak: engine init failed ($status)")
                            android.widget.Toast.makeText(context,
                                "Text-to-speech engine unavailable",
                                android.widget.Toast.LENGTH_SHORT).show()
                            tts?.shutdown()
                            tts = null
                        }
                        ttsPending.clear()
                    }
                }
            }
        }
        scheduleTtsRelease()
    }

    private fun ttsSpeakNow(engine: TextToSpeech, args: JSONObject) {
        engine.setPitch(args.optDouble("pitch", 1.0).toFloat())
        engine.setSpeechRate(args.optDouble("rate", 1.0).toFloat())
        engine.speak(args.optString("text"), TextToSpeech.QUEUE_ADD, null,
            "jetpacs-tts-${System.nanoTime()}")
    }

    private val ttsRelease = Runnable {
        val e = tts
        // Pending utterances mean the engine is still initializing —
        // releasing now would swallow them, so wait another period.
        if (e != null && !e.isSpeaking && ttsPending.isEmpty()) {
            e.shutdown()
            tts = null
            ttsReady = false
        } else if (e != null) {
            scheduleTtsRelease()
        }
    }

    private fun scheduleTtsRelease() {
        mainHandler.removeCallbacks(ttsRelease)
        mainHandler.postDelayed(ttsRelease, 60_000)
    }

    /** `volume.set {stream, level}` → `{max}`; DND policy can refuse. */
    private fun volumeSet(context: Context, args: JSONObject): JSONObject {
        val am = audioManager(context)
        val stream = when (val s = args.optString("stream", "music")) {
            "music" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "call" -> AudioManager.STREAM_VOICE_CALL
            "system" -> AudioManager.STREAM_SYSTEM
            else -> throw CapabilityException("cap-failed", "volume.set: unknown stream '$s'")
        }
        if (!args.has("level"))
            throw CapabilityException("cap-failed", "volume.set: missing 'level'")
        val max = am.getStreamMaxVolume(stream)
        try {
            am.setStreamVolume(stream, args.optInt("level").coerceIn(0, max), 0)
        } catch (e: SecurityException) {
            throw CapabilityException("cap-permission",
                "volume.set: blocked by the Do Not Disturb policy",
                perm = "notification_policy", settings = DND_SETTINGS)
        }
        return JSONObject().put("max", max)
    }

    /** `ringer.mode {mode}` — normal | vibrate | silent (silent needs DND access). */
    private fun ringerMode(context: Context, args: JSONObject): JSONObject {
        val mode = when (val m = args.optString("mode")) {
            "normal" -> AudioManager.RINGER_MODE_NORMAL
            "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
            "silent" -> AudioManager.RINGER_MODE_SILENT
            else -> throw CapabilityException("cap-failed", "ringer.mode: unknown mode '$m'")
        }
        if (mode == AudioManager.RINGER_MODE_SILENT &&
            !notificationManager(context).isNotificationPolicyAccessGranted
        ) {
            throw CapabilityException("cap-permission",
                "ringer.mode: silent needs Do Not Disturb access",
                perm = "notification_policy", settings = DND_SETTINGS)
        }
        try {
            audioManager(context).ringerMode = mode
        } catch (e: SecurityException) {
            throw CapabilityException("cap-permission",
                "ringer.mode: blocked by the Do Not Disturb policy",
                perm = "notification_policy", settings = DND_SETTINGS)
        }
        return JSONObject()
    }

    /** `flashlight {on}` — torch mode of the first flash-capable camera. */
    private fun flashlight(context: Context, args: JSONObject): JSONObject {
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: throw CapabilityException("cap-failed", "flashlight: no camera with a flash unit")
        cm.setTorchMode(id, args.optBoolean("on"))
        return JSONObject()
    }

    /** `media.key {key}` — a media key down+up through the audio service. */
    private fun mediaKey(context: Context, args: JSONObject): JSONObject {
        val code = when (val key = args.optString("key")) {
            "play_pause" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "stop" -> KeyEvent.KEYCODE_MEDIA_STOP
            "fast_forward" -> KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
            "rewind" -> KeyEvent.KEYCODE_MEDIA_REWIND
            else -> throw CapabilityException("cap-failed", "media.key: unknown key '$key'")
        }
        val am = audioManager(context)
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
        return JSONObject()
    }

    /**
     * `clipboard.read` → `{text}`. Android 10+ only exposes the clipboard
     * to the focused app, so this works while the companion is
     * foregrounded and returns a typed error otherwise. The contents must
     * never be logged (the invoke path only logs codes, not payloads).
     */
    private fun clipboardRead(context: Context, @Suppress("UNUSED_PARAMETER") args: JSONObject): JSONObject =
        onMainBlocking("clipboard.read") {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip == null || clip.itemCount == 0)
                throw CapabilityException("cap-permission",
                    "clipboard.read: empty, or unreadable while the companion " +
                        "is backgrounded (Android 10+)")
            JSONObject().put("text", clip.getItemAt(0).coerceToText(context).toString())
        }

    /**
     * `screen.keep_on {on}` — flips [JetpacsRuntime.keepScreenOn]; the SDUI
     * scaffold applies it as the window's keep-screen-on flag, so it only
     * holds while Jetpacs UI is actually on screen and clears when it leaves.
     */
    private fun screenKeepOn(@Suppress("UNUSED_PARAMETER") context: Context, args: JSONObject): JSONObject {
        JetpacsRuntime.setKeepScreenOn(args.optBoolean("on"))
        return JSONObject()
    }

    // ── the device permission report ─────────────────────────────────────────

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

    private fun audioManager(context: Context): AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    // ── main-thread plumbing ─────────────────────────────────────────────────

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Run [block] on the main looper and wait for its value — for the few
     * platform services that are main-thread-only. The invoke path calls
     * from the connection's read thread; a 2s ceiling turns a wedged main
     * thread into a typed error instead of a dead read loop.
     */
    private fun onMainBlocking(cap: String, block: () -> JSONObject): JSONObject {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var out: JSONObject? = null
        var err: Throwable? = null
        mainHandler.post {
            try {
                out = block()
            } catch (t: Throwable) {
                err = t
            }
            latch.countDown()
        }
        if (!latch.await(2, TimeUnit.SECONDS))
            throw CapabilityException("cap-failed", "$cap: timed out on the main thread")
        err?.let { throw it }
        return out ?: throw CapabilityException("cap-failed", "$cap: no result")
    }
}
