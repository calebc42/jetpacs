package com.calebc42.eabp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.format.DateFormat
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Date

/**
 * Home-screen agenda widget (from the cached `widget:agenda` surface Emacs
 * pushes alongside the dashboard). Each item is its own tappable row:
 * tapping the row opens the app at that heading (via MainActivity's
 * widget-action trampoline), tapping the leading circle cycles the item's
 * TODO state without leaving the home screen. Renders straight from the
 * surface cache, so it shows the last-known agenda whether or not Emacs is
 * connected; the "Synced HH:MM" caption makes that freshness visible.
 *
 * Rows are fixed slots rather than a RemoteViews collection: a collection
 * allows only one PendingIntent template per list, which cannot express
 * "row opens an activity, toggle fires a broadcast" without a trampoline
 * that background-activity-launch restrictions would break.
 */
class EabpWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        // A launcher-driven update (widget added, reboot) may cold-start the
        // process: fall back to a fresh SurfaceManager reading the cache file.
        val record = (EabpRuntime.surfaceManager ?: SurfaceManager(context))
            .getRecord(SURFACE)
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, buildViews(context, record))
        }
    }

    companion object {
        const val SURFACE = "widget:agenda"

        private val ROW_IDS = intArrayOf(
            R.id.widget_item0, R.id.widget_item1, R.id.widget_item2,
            R.id.widget_item3, R.id.widget_item4, R.id.widget_item5,
            R.id.widget_item6, R.id.widget_item7)
        private val TOGGLE_IDS = intArrayOf(
            R.id.widget_item0_toggle, R.id.widget_item1_toggle, R.id.widget_item2_toggle,
            R.id.widget_item3_toggle, R.id.widget_item4_toggle, R.id.widget_item5_toggle,
            R.id.widget_item6_toggle, R.id.widget_item7_toggle)
        private val TEXT_IDS = intArrayOf(
            R.id.widget_item0_text, R.id.widget_item1_text, R.id.widget_item2_text,
            R.id.widget_item3_text, R.id.widget_item4_text, R.id.widget_item5_text,
            R.id.widget_item6_text, R.id.widget_item7_text)

        // PendingIntent request codes must be unique app-wide: identical
        // broadcast intents only stay distinct through the request code.
        private const val REQUEST_OPEN_APP = 2001
        private const val REQUEST_REFRESH = 2002
        private const val REQUEST_CAPTURE = 2003
        private const val REQUEST_ROW_BASE = 2100
        private const val REQUEST_TOGGLE_BASE = 2200

        /** Re-render every widget instance from RECORD (surface.update path). */
        fun renderAll(context: Context, record: SurfaceRecord?) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, EabpWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = buildViews(context, record)
            for (id in ids) mgr.updateAppWidget(id, views)
        }

        private fun buildViews(context: Context, record: SurfaceRecord?): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_eabp_actions)
            val spec = record?.resolveSpec(null)
            val revision = record?.revision ?: -1

            views.setTextViewText(
                R.id.widget_title,
                spec?.optString("title")?.ifEmpty { null }
                    ?: context.getString(R.string.widget_title_default))

            val items = spec?.optJSONArray("items")
            val count = items?.length() ?: 0
            for (i in ROW_IDS.indices) {
                val item = if (i < count) items?.optJSONObject(i) else null
                if (item == null) {
                    views.setViewVisibility(ROW_IDS[i], View.GONE)
                    continue
                }
                views.setViewVisibility(ROW_IDS[i], View.VISIBLE)
                views.setTextViewText(TEXT_IDS[i], formatItem(item))
                val ref = item.optJSONObject("ref")
                views.setOnClickPendingIntent(
                    ROW_IDS[i], openHeadingIntent(context, ref, i, revision))
                if (item.has("todo")) {
                    views.setViewVisibility(TOGGLE_IDS[i], View.VISIBLE)
                    views.setImageViewResource(
                        TOGGLE_IDS[i],
                        if (item.optBoolean("done")) R.drawable.ic_todo_done
                        else R.drawable.ic_todo_open)
                    views.setOnClickPendingIntent(
                        TOGGLE_IDS[i],
                        actionIntent(context, "heading.todo-cycle", ref,
                            REQUEST_TOGGLE_BASE + i, revision))
                } else {
                    views.setViewVisibility(TOGGLE_IDS[i], View.GONE)
                }
            }

            if (count == 0) {
                // "Never synced" and "synced, but free" read differently.
                views.setTextViewText(
                    R.id.widget_empty,
                    context.getString(
                        if (record == null) R.string.widget_no_data
                        else R.string.widget_empty))
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_empty, View.GONE)
            }

            if (record != null) {
                views.setTextViewText(
                    R.id.widget_updated,
                    context.getString(
                        R.string.widget_synced_at,
                        DateFormat.getTimeFormat(context)
                            .format(Date(record.updatedAt))))
                views.setViewVisibility(R.id.widget_updated, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_updated, View.GONE)
            }

            // Tapping outside the rows opens the app on whatever view is
            // current.
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, REQUEST_OPEN_APP,
                    Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))

            // Force sync: the shell's explicit "bypass memos and re-push".
            // No app open; `wake` posts the tap-to-open-Emacs notification
            // when Emacs is dead. Feedback is the Synced caption bumping
            // (glasspane resets the widget memo on explicit refreshes).
            views.setOnClickPendingIntent(
                R.id.widget_refresh,
                actionIntent(context, "dashboard.refresh", null,
                    REQUEST_REFRESH, revision, whenOffline = "wake"))

            // Capture needs a keyboard, so it trampolines into the app and
            // opens the template picker there.
            views.setOnClickPendingIntent(
                R.id.widget_capture,
                trampolineIntent(context, "org.capture.show", null,
                    REQUEST_CAPTURE, revision))
            return views
        }

        /** One row: bold "HH:MM" lead, headline struck through when done. */
        private fun formatItem(item: JSONObject): CharSequence {
            val sb = SpannableStringBuilder()
            val time = item.optString("time")
            if (time.isNotEmpty()) {
                sb.append(time)
                sb.setSpan(
                    StyleSpan(Typeface.BOLD), 0, sb.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                sb.append("  ")
            }
            val start = sb.length
            sb.append(item.optString("headline").ifEmpty { "Untitled" })
            if (item.optBoolean("done")) {
                sb.setSpan(
                    StrikethroughSpan(), start, sb.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            return sb
        }

        /**
         * Row tap: open MainActivity carrying the `heading.tap` action; the
         * activity rebroadcasts it through ActionReceiver (same trampoline as
         * the share sheet), so Emacs pushes the detail view into the app the
         * user is now looking at. Offline it queues and the app opens on the
         * cached view.
         */
        private fun openHeadingIntent(
            context: Context,
            ref: JSONObject?,
            slot: Int,
            revision: Int
        ): PendingIntent = trampolineIntent(
            context, "heading.tap", ref ?: JSONObject(),
            REQUEST_ROW_BASE + slot, revision)

        /**
         * An action that must land in a visible app (navigation, dialogs):
         * open MainActivity with the action embedded; it rebroadcasts through
         * ActionReceiver on arrival.
         */
        private fun trampolineIntent(
            context: Context,
            actionName: String,
            args: JSONObject?,
            requestCode: Int,
            revision: Int
        ): PendingIntent {
            val actionJson = JSONObject().apply {
                put("action", actionName)
                put("when_offline", "queue")
                if (args != null) put("args", args)
            }
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_WIDGET_ACTION, actionJson.toString())
                putExtra(MainActivity.EXTRA_WIDGET_REVISION, revision)
            }
            return PendingIntent.getActivity(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        /** A broadcast action that never opens the app (todo-cycle, refresh). */
        private fun actionIntent(
            context: Context,
            actionName: String,
            args: JSONObject?,
            requestCode: Int,
            revision: Int,
            whenOffline: String = "queue"
        ): PendingIntent {
            val actionJson = JSONObject().apply {
                put("action", actionName)
                put("when_offline", whenOffline) // Stash in Room if Emacs is dead
                if (args != null) put("args", args)
            }
            val intent = Intent(context, ActionReceiver::class.java).apply {
                action = ActionReceiver.ACTION_TAP
                putExtra(ActionReceiver.EXTRA_SURFACE, SURFACE)
                putExtra(ActionReceiver.EXTRA_REVISION, revision)
                putExtra(ActionReceiver.EXTRA_ACTION, actionJson.toString())
            }
            return PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}