package com.calebc42.jetpacs

import com.calebc42.jetpacs.core.R
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Org clock quick-action widget: clock in (last) / clock out, split out of
 * the agenda widget. Static — no surface backs it, so there is nothing to
 * re-render on surface updates; taps ride the normal action pipeline and
 * queue in Room when Emacs is dead.
 */
class JetpacsClockWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_jetpacs_clock)
        views.setOnClickPendingIntent(
            R.id.btn_clock_in_last,
            buildActionIntent(context, "org.clock.in-last", 1001))
        views.setOnClickPendingIntent(
            R.id.btn_clock_out,
            buildActionIntent(context, "org.clock.out", 1002))
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
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
            putExtra(ActionReceiver.EXTRA_SURFACE, SURFACE)
            putExtra(ActionReceiver.EXTRA_REVISION, -1)
            putExtra(ActionReceiver.EXTRA_ACTION, actionJson.toString())
        }
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        // No surface pushes to this name; it only labels where taps came from.
        const val SURFACE = "widget:clock"
    }
}