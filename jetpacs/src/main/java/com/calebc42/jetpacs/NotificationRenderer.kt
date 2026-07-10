package com.calebc42.jetpacs

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Renders a `notification:*` surface spec into a posted Android notification.
 *
 * Reads the spec's `meta` block (channel / ongoing / chronometer / priority /
 * category) and walks the UI-tree body (text / row / button subset) into a
 * title, text lines, and notification actions.
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
        // content lines, buttons -> actions. Rows/columns are flattened.
        var title: String? = null
        val lines = mutableListOf<String>()
        forEachLeaf(spec.optJSONArray("children")) { node ->
            when (node.optString("t")) {
                "text" -> {
                    val text = node.optString("text")
                    if (node.optString("style") == "title" && title == null) title = text
                    else if (text.isNotEmpty()) lines.add(text)
                }
                "button" -> addAction(builder, record, node)
            }
        }

        builder.setContentTitle(title ?: record.name)
        if (lines.isNotEmpty()) builder.setContentText(lines.joinToString("  "))

        manager.notify(notifId(record.surface), builder.build())
    }

    fun clear(surface: String) = manager.cancel(notifId(surface))

    private fun addAction(
        builder: NotificationCompat.Builder,
        record: SurfaceRecord,
        button: JSONObject,
    ) {
        val action = button.optJSONObject("on_tap") ?: return
        val label = button.optString("label")
        val intent = Intent(context, ActionReceiver::class.java).apply {
            this.action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, record.surface)
            putExtra(ActionReceiver.EXTRA_REVISION, record.revision)
            putExtra(ActionReceiver.EXTRA_ACTION, action.toString())
        }
        // Distinct request code per (surface,label) so buttons don't collide.
        val rc = "${record.surface}/$label".hashCode()
        val pi = PendingIntent.getBroadcast(
            context, rc, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        builder.addAction(android.R.drawable.ic_media_play, label, pi)
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

    private fun notifId(surface: String): Int = surface.hashCode()
}