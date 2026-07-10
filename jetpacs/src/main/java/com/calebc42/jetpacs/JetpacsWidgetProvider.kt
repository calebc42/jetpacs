package com.calebc42.jetpacs

import com.calebc42.jetpacs.core.R
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Date

/**
 * Home-screen agenda widget (from the cached `widget:agenda` surface Emacs
 * pushes alongside the dashboard). Items render in a scrollable ListView
 * ([AgendaWidgetService]): tapping a row opens the app at that heading,
 * tapping the leading circle cycles the item's TODO state without leaving
 * the home screen — both routed through the single collection template via
 * [ActionTrampolineActivity]. Renders straight from the surface cache, so
 * it shows the last-known agenda whether or not Emacs is connected; the
 * "Synced HH:MM" caption makes that freshness visible.
 */
class JetpacsWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        // A launcher-driven update (widget added, reboot) may cold-start the
        // process: fall back to a fresh SurfaceManager reading the cache file.
        val record = (JetpacsRuntime.surfaceManager ?: SurfaceManager(context))
            .getRecord(SURFACE)
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, buildViews(context, record))
        }
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_list)
    }

    companion object {
        const val SURFACE = "widget:agenda"

        // PendingIntent request codes must be unique app-wide: identical
        // intents only stay distinct through the request code.
        private const val REQUEST_OPEN_APP = 2001
        private const val REQUEST_REFRESH = 2002
        private const val REQUEST_HEADER_ACTION = 2003
        private const val REQUEST_VIEW_SELECT = 2005
        private const val REQUEST_LIST_TEMPLATE = 2300

        /** Re-render every widget instance from RECORD (surface.update path). */
        fun renderAll(context: Context, record: SurfaceRecord?) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, JetpacsWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = buildViews(context, record)
            for (id in ids) mgr.updateAppWidget(id, views)
            // The header updated above; this makes the factory re-read the
            // cache so the rows follow.
            mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
        }

        private fun buildViews(context: Context, record: SurfaceRecord?): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_jetpacs_agenda)
            val spec = widgetResolvedSpec(context, SURFACE, record)
            val revision = record?.revision ?: -1

            views.setTextViewText(
                R.id.widget_title,
                spec?.optString("title")?.ifEmpty { null }
                    ?: context.getString(R.string.widget_title_default))

            // View selector (Orgzly's saved-search dropdown): only when the
            // spec actually offers a choice.
            val viewCount = record?.spec?.optJSONObject("views")?.length() ?: 0
            if (viewCount > 1) {
                views.setViewVisibility(R.id.widget_title_arrow, View.VISIBLE)
                views.setOnClickPendingIntent(
                    R.id.widget_title_area,
                    PendingIntent.getActivity(
                        context, REQUEST_VIEW_SELECT,
                        Intent(context, WidgetViewSelectionActivity::class.java).apply {
                            data = Uri.fromParts("jetpacswidget", SURFACE, "select")
                            putExtra(WidgetViewSelectionActivity.EXTRA_SURFACE, SURFACE)
                        },
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                views.setViewVisibility(R.id.widget_title_arrow, View.GONE)
            }

            // The rows: adapter reads the cache, the one allowed template
            // routes row/toggle taps through the trampoline.
            @Suppress("DEPRECATION")
            views.setRemoteAdapter(
                R.id.widget_list,
                Intent(context, JetpacsWidgetListService::class.java).apply {
                    data = Uri.fromParts("jetpacswidget", SURFACE, null)
                })
            views.setPendingIntentTemplate(
                R.id.widget_list,
                PendingIntent.getActivity(
                    context, REQUEST_LIST_TEMPLATE,
                    Intent(context, ActionTrampolineActivity::class.java),
                    // Mutable: collection fill-in intents must be merged in.
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
            // ListView toggles this automatically when the adapter is empty.
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)
            // "Never synced" and "synced, but free" read differently.
            views.setTextViewText(
                R.id.widget_empty,
                context.getString(
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

            // Tapping the header area (outside the buttons) opens the app.
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, REQUEST_OPEN_APP,
                    JetpacsLaunch.openAppIntent(context),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))

            // Force sync: the shell's explicit "bypass memos and re-push".
            // No app open; `wake` posts the tap-to-open-Emacs notification
            // when Emacs is dead. Feedback is the Synced caption bumping
            // (glasspane resets the widget memo on explicit refreshes).
            views.setOnClickPendingIntent(
                R.id.widget_refresh,
                actionIntent(context, "dashboard.refresh", null,
                    REQUEST_REFRESH, revision, whenOffline = "wake"))

            // The header "+" button is server-driven data (SPEC §4
            // `header_action`), so the library carries no app opinion about
            // what it does. It trampolines into the app because header
            // actions are for flows that need the visible app (capture
            // needs a keyboard). Read from the top-level spec, not the
            // resolved view: chrome is view-independent.
            wireHeaderAction(views, context, SURFACE, record?.spec, revision)
            return views
        }

        /**
         * An action that must land in a visible app (navigation, dialogs):
         * open the host app with the pushed ACTION embedded verbatim; its
         * launcher activity rebroadcasts through ActionReceiver on arrival
         * (the JetpacsLaunch extras contract). SURFACE keys the intent's
         * data URI: extras don't count toward PendingIntent identity, so
         * per-surface header actions must stay distinct through the data.
         */
        private fun trampolineIntent(
            context: Context,
            surface: String,
            action: JSONObject,
            revision: Int
        ): PendingIntent {
            val intent = JetpacsLaunch.openAppIntent(context, action.toString(), revision)
                .apply { data = Uri.fromParts("jetpacswidget", surface, "header") }
            return PendingIntent.getActivity(
                context, REQUEST_HEADER_ACTION, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        /** Show or hide the header "+" from SPEC's top-level `header_action`. */
        internal fun wireHeaderAction(
            views: RemoteViews,
            context: Context,
            surface: String,
            spec: JSONObject?,
            revision: Int
        ) {
            val headerAction = spec?.optJSONObject("header_action")
            if (headerAction != null) {
                views.setViewVisibility(R.id.widget_header_action, View.VISIBLE)
                views.setOnClickPendingIntent(
                    R.id.widget_header_action,
                    trampolineIntent(context, surface, headerAction, revision))
            } else {
                views.setViewVisibility(R.id.widget_header_action, View.GONE)
            }
        }

        /** A broadcast action that never opens the app (refresh). */
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