package com.calebc42.eabp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.DateFormat
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Date

/** The runtime surface manager when the service lives, else a cache read. */
internal fun widgetManager(context: Context): SurfaceManager =
    EabpRuntime.surfaceManager ?: SurfaceManager(context)

/** RECORD's spec resolved against the view currently selected on SURFACE. */
internal fun widgetResolvedSpec(
    context: Context,
    surface: String,
    record: SurfaceRecord?
): JSONObject? =
    record?.resolveSpec(widgetManager(context).currentView(surface))

/** Route a widget surface re-render to whichever provider owns it. */
fun renderWidgetSurface(context: Context, record: SurfaceRecord) {
    when {
        record.surface == EabpWidgetProvider.SURFACE ->
            EabpWidgetProvider.renderAll(context, record)
        record.surface in EabpCustomWidgetProvider.SLOTS ->
            EabpCustomWidgetProvider.renderAll(context, record)
        else -> Log.w("EabpWidgets", "No widget renderer for '${record.surface}'")
    }
}

/**
 * Blank widget slots, Tasker-style: five pre-registered home-screen widgets
 * with no built-in content. Emacs composes each one by pushing a
 * `widget:customN` surface (rows built with `eabp-widget-item' /
 * `eabp-widget-divider'); the companion just renders. Multi-view specs get
 * the same header dropdown as the agenda widget.
 */
abstract class EabpCustomWidgetProvider : AppWidgetProvider() {

    abstract val surface: String

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val record = widgetManager(context).getRecord(surface)
        val views = buildViews(context, surface, record)
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_list)
    }

    companion object {
        val SLOTS: Map<String, Class<out EabpCustomWidgetProvider>> = mapOf(
            "widget:custom1" to EabpCustomWidget1::class.java,
            "widget:custom2" to EabpCustomWidget2::class.java,
            "widget:custom3" to EabpCustomWidget3::class.java,
            "widget:custom4" to EabpCustomWidget4::class.java,
            "widget:custom5" to EabpCustomWidget5::class.java)

        fun renderAll(context: Context, record: SurfaceRecord?) {
            val surface = record?.surface ?: return
            val cls = SLOTS[surface] ?: return
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, cls))
            if (ids.isEmpty()) return
            val views = buildViews(context, surface, record)
            for (id in ids) mgr.updateAppWidget(id, views)
            mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
        }

        private fun buildViews(
            context: Context,
            surface: String,
            record: SurfaceRecord?
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_eabp_agenda)
            val spec = widgetResolvedSpec(context, surface, record)

            views.setTextViewText(
                R.id.widget_title,
                spec?.optString("title")?.ifEmpty { null }
                    ?: context.getString(R.string.app_name))

            // The refresh/capture header buttons are agenda-widget chrome.
            views.setViewVisibility(R.id.widget_refresh, View.GONE)
            views.setViewVisibility(R.id.widget_capture, View.GONE)

            views.setRemoteAdapter(
                R.id.widget_list,
                Intent(context, EabpWidgetListService::class.java).apply {
                    data = Uri.fromParts("eabpwidget", surface, null)
                })
            views.setPendingIntentTemplate(
                R.id.widget_list,
                PendingIntent.getActivity(
                    context, 2300,
                    Intent(context, ActionTrampolineActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)
            views.setTextViewText(
                R.id.widget_empty,
                spec?.optString("empty")?.ifEmpty { null }
                    ?: context.getString(
                        if (record == null) R.string.widget_no_data
                        else R.string.widget_empty))

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

            val viewCount = record?.spec?.optJSONObject("views")?.length() ?: 0
            if (viewCount > 1) {
                views.setViewVisibility(R.id.widget_title_arrow, View.VISIBLE)
                views.setOnClickPendingIntent(
                    R.id.widget_title_area,
                    PendingIntent.getActivity(
                        context, 2005,
                        Intent(context, WidgetViewSelectionActivity::class.java).apply {
                            // Distinct data per surface: extras don't count
                            // toward PendingIntent identity.
                            data = Uri.fromParts("eabpwidget", surface, "select")
                            putExtra(WidgetViewSelectionActivity.EXTRA_SURFACE, surface)
                        },
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                views.setViewVisibility(R.id.widget_title_arrow, View.GONE)
            }

            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, 2001,
                    Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            return views
        }
    }
}

class EabpCustomWidget1 : EabpCustomWidgetProvider() { override val surface = "widget:custom1" }
class EabpCustomWidget2 : EabpCustomWidgetProvider() { override val surface = "widget:custom2" }
class EabpCustomWidget3 : EabpCustomWidgetProvider() { override val surface = "widget:custom3" }
class EabpCustomWidget4 : EabpCustomWidgetProvider() { override val surface = "widget:custom4" }
class EabpCustomWidget5 : EabpCustomWidgetProvider() { override val surface = "widget:custom5" }