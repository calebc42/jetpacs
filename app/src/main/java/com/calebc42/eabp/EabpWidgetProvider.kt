package com.calebc42.eabp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen widget: today's agenda (from the cached `widget:agenda`
 * surface Emacs pushes alongside the dashboard) plus the clock in/out
 * quick actions. Renders straight from the surface cache, so it shows
 * the last-known agenda whether or not Emacs is connected — the same
 * design principle as every other surface.
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
            val spec = record?.spec
            views.setTextViewText(
                R.id.widget_title,
                spec?.optString("title")?.ifEmpty { null } ?: "Agenda")
            val lines = spec?.optJSONArray("lines")
            val text = if (lines == null || lines.length() == 0) {
                "Nothing scheduled"
            } else {
                (0 until lines.length()).joinToString("\n") { lines.optString(it) }
            }
            views.setTextViewText(R.id.widget_lines, text)

            // Tapping the agenda area opens the app.
            views.setOnClickPendingIntent(
                R.id.widget_lines,
                PendingIntent.getActivity(
                    context, 2001,
                    Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))

            views.setOnClickPendingIntent(
                R.id.btn_clock_in_last,
                buildActionIntent(context, "org.clock.in-last", 1001))
            views.setOnClickPendingIntent(
                R.id.btn_clock_out,
                buildActionIntent(context, "org.clock.out", 1002))
            return views
        }

        private fun buildActionIntent(
            context: Context,
            actionName: String,
            requestCode: Int
        ): PendingIntent {
            val actionJson = JSONObject().apply {
                put("action", actionName)
                put("when_offline", "queue") // Stash in Room if Emacs is dead
            }
            val intent = Intent(context, ActionReceiver::class.java).apply {
                action = ActionReceiver.ACTION_TAP
                putExtra(ActionReceiver.EXTRA_SURFACE, "widget:home")
                putExtra(ActionReceiver.EXTRA_REVISION, -1)
                putExtra(ActionReceiver.EXTRA_ACTION, actionJson.toString())
            }
            return PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
