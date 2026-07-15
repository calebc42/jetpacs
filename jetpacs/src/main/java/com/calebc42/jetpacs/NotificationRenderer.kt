package com.calebc42.jetpacs

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import org.json.JSONArray
import org.json.JSONObject

/**
 * Renders a `notification:*` surface spec into a posted Android notification.
 *
 * Reads the spec's `meta` block (channel / ongoing / chronometer / priority /
 * category) and walks the UI-tree body (text / row / button subset) into a
 * title and text lines. Action buttons come from `meta.actions` (SPEC §9);
 * when that is absent, `button` nodes in the body are honored as the older
 * implicit form.
 */
class NotificationRenderer(private val context: Context) {

    private val manager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun render(record: SurfaceRecord) {
        val spec = record.spec
        val meta = spec.optJSONObject("meta") ?: JSONObject()
        val channelId = meta.optString("channel", "jetpacs_default").ifEmpty { "jetpacs_default" }
        val priority = meta.optString("priority", "default")
        ensureChannel(channelId, priority)

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(meta.optBoolean("ongoing", false))
            .setOnlyAlertOnce(true)
            .setPriority(toCompatPriority(priority))

        meta.optString("category").takeIf { it.isNotEmpty() }?.let { builder.setCategory(it) }

        // Chronometer: base_ms (epoch millis) + optional count_down.
        meta.optJSONObject("chronometer")?.let { chrono ->
            val baseMs = chrono.optLong("base_ms", 0L)
            if (baseMs > 0L) {
                builder.setUsesChronometer(true)
                builder.setShowWhen(true)
                builder.setWhen(baseMs)   // Android translates epoch -> elapsedRealtime
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    builder.setChronometerCountDown(chrono.optBoolean("count_down", false))
                }
            }
        }

        // Walk the body: first title-styled text -> contentTitle, other text ->
        // content lines. Rows/columns are flattened. Collect any body `button`
        // nodes too, for the legacy fallback when meta carries no `actions`.
        var title: String? = null
        val lines = mutableListOf<String>()
        val bodyButtons = mutableListOf<NotifAction>()
        forEachLeaf(spec.optJSONArray("children")) { node ->
            when (node.optString("t")) {
                "text" -> {
                    val text = node.optString("text")
                    if (node.optString("style") == "title" && title == null) title = text
                    else if (text.isNotEmpty()) lines.add(text)
                }
                "button" -> NotifAction.fromButton(node)?.let(bodyButtons::add)
            }
        }

        builder.setContentTitle(title ?: record.name)
        if (lines.isNotEmpty()) builder.setContentText(lines.joinToString("  "))

        // meta.actions is canonical; body buttons are the fallback (SPEC §9).
        val actions = meta.optJSONArray("actions")
            ?.let { NotifAction.fromMetaActions(it) }
            ?: bodyButtons
        for (action in actions) addAction(builder, record, action)

        manager.notify(notifId(record.surface), builder.build())
    }

    fun clear(surface: String) = manager.cancel(notifId(surface))

    private fun addAction(
        builder: NotificationCompat.Builder,
        record: SurfaceRecord,
        action: NotifAction,
    ) {
        val intent = Intent(context, ActionReceiver::class.java).apply {
            this.action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, record.surface)
            putExtra(ActionReceiver.EXTRA_REVISION, record.revision)
            putExtra(ActionReceiver.EXTRA_ACTION, action.onTap.toString())
            if (action.dismiss) putExtra(ActionReceiver.EXTRA_DISMISS, true)
            action.inputKey?.let { putExtra(ActionReceiver.EXTRA_INPUT_KEY, it) }
        }
        // Distinct request code per (surface,label) so buttons don't collide.
        val rc = "${record.surface}/${action.label}".hashCode()
        // An inline-reply action needs a MUTABLE PendingIntent so the platform
        // can inject the RemoteInput results; everything else stays immutable.
        val mutability = if (action.inputKey != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        } else {
            PendingIntent.FLAG_IMMUTABLE
        }
        val pi = PendingIntent.getBroadcast(
            context, rc, intent, PendingIntent.FLAG_UPDATE_CURRENT or mutability,
        )
        val actionBuilder =
            NotificationCompat.Action.Builder(notifIconRes(action.icon), action.label, pi)
        if (action.inputKey != null) {
            val remoteInput = RemoteInput.Builder(action.inputKey)
                .apply { action.inputHint?.let { setLabel(it) } }
                .build()
            actionBuilder.addRemoteInput(remoteInput)
        }
        builder.addAction(actionBuilder.build())
    }

    private fun ensureChannel(id: String, priority: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val importance = when (priority) {
                "min" -> NotificationManager.IMPORTANCE_MIN
                "low" -> NotificationManager.IMPORTANCE_LOW
                "high" -> NotificationManager.IMPORTANCE_HIGH
                else -> NotificationManager.IMPORTANCE_DEFAULT
            }
            // Idempotent for an existing id (importance won't downgrade silently).
            manager.createNotificationChannel(NotificationChannel(id, id, importance))
        }
    }

    private fun toCompatPriority(priority: String): Int = when (priority) {
        "min" -> NotificationCompat.PRIORITY_MIN
        "low" -> NotificationCompat.PRIORITY_LOW
        "high" -> NotificationCompat.PRIORITY_HIGH
        else -> NotificationCompat.PRIORITY_DEFAULT
    }

    /**
     * Best-effort icon-name -> platform drawable for a notification action.
     * A small curated set of the `android.R.drawable` glyphs; anything else
     * (including a null/absent icon) falls back to a neutral default. Note
     * Android >= 7 does not draw these in the shade, so this is cosmetic
     * where the platform shows action icons at all (SPEC §9).
     */
    private fun notifIconRes(name: String?): Int = when (name) {
        "close", "cancel", "clear", "dismiss" -> android.R.drawable.ic_menu_close_clear_cancel
        "delete", "trash" -> android.R.drawable.ic_menu_delete
        "edit" -> android.R.drawable.ic_menu_edit
        "send", "reply" -> android.R.drawable.ic_menu_send
        "add" -> android.R.drawable.ic_menu_add
        "share" -> android.R.drawable.ic_menu_share
        "save", "done", "check" -> android.R.drawable.ic_menu_save
        "snooze", "schedule", "alarm", "access_time", "timer" ->
            android.R.drawable.ic_popup_reminder
        "history" -> android.R.drawable.ic_menu_recent_history
        "info" -> android.R.drawable.ic_menu_info_details
        "search" -> android.R.drawable.ic_menu_search
        "pause" -> android.R.drawable.ic_media_pause
        "next" -> android.R.drawable.ic_media_next
        "previous", "prev" -> android.R.drawable.ic_media_previous
        else -> android.R.drawable.ic_media_play
    }

    /** Visit text/button leaves, descending through row/column/box containers. */
    private fun forEachLeaf(children: JSONArray?, visit: (JSONObject) -> Unit) {
        if (children == null) return
        for (i in 0 until children.length()) {
            val node = children.optJSONObject(i) ?: continue
            when (node.optString("t")) {
                "row", "column", "box" -> forEachLeaf(node.optJSONArray("children"), visit)
                else -> visit(node)
            }
        }
    }

    companion object {
        /**
         * Stable per-surface notification id. Also used by [ActionReceiver]
         * to cancel the notification when an action carries `dismiss`.
         */
        fun notifId(surface: String): Int = surface.hashCode()
    }
}

/**
 * A notification action button, normalized from a `meta.actions` entry or a
 * legacy body `button` node (SPEC §9). Pure data — no Android types — so the
 * parse can be unit-tested off-device.
 */
data class NotifAction(
    val label: String,
    val onTap: JSONObject,
    val icon: String?,
    val dismiss: Boolean,
    /** Non-null iff this is an inline text reply: the `fields` key the typed
     *  text is delivered under (SPEC §9, default "reply"). */
    val inputKey: String?,
    val inputHint: String?,
) {
    companion object {
        /** Parse a `meta.actions` array into ordered action descriptors. */
        fun fromMetaActions(arr: JSONArray): List<NotifAction> =
            (0 until arr.length()).mapNotNull { fromMetaEntry(arr.optJSONObject(it)) }

        private fun fromMetaEntry(entry: JSONObject?): NotifAction? {
            val onTap = entry?.optJSONObject("on_tap") ?: return null
            val label = entry.optString("label")
            if (label.isEmpty()) return null
            val input = entry.optJSONObject("input")
            return NotifAction(
                label = label,
                onTap = onTap,
                icon = entry.optString("icon").ifEmpty { null },
                dismiss = entry.optBoolean("dismiss", false),
                inputKey = input?.let { it.optString("key").ifEmpty { "reply" } },
                inputHint = input?.optString("hint")?.ifEmpty { null },
            )
        }

        /** The legacy implicit form: a `button` node in the notification body. */
        fun fromButton(button: JSONObject): NotifAction? {
            val onTap = button.optJSONObject("on_tap") ?: return null
            val label = button.optString("label")
            if (label.isEmpty()) return null
            return NotifAction(
                label = label,
                onTap = onTap,
                icon = button.optString("icon").ifEmpty { null },
                dismiss = false,
                inputKey = null,
                inputHint = null,
            )
        }
    }
}
