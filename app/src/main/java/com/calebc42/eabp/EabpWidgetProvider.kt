package com.calebc42.eabp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject

class EabpWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        // Update all instances of this widget on the home screen
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_eabp_actions)

            // 1. Wire up "Clock In (Last)"
            views.setOnClickPendingIntent(
                R.id.btn_clock_in_last,
                buildActionIntent(context, "org.clock.in-last", 1001)
            )

            // 2. Wire up "Clock Out"
            views.setOnClickPendingIntent(
                R.id.btn_clock_out,
                buildActionIntent(context, "org.clock.out", 1002)
            )

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private fun buildActionIntent(context: Context, actionName: String, requestCode: Int): PendingIntent {
        // Construct the exact JSON payload the ActionReceiver expects
        val actionJson = JSONObject().apply {
            put("action", actionName)
            put("when_offline", "queue") // Stash in Room if Emacs is dead
        }

        val intent = Intent(context, ActionReceiver::class.java).apply {
            action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, "widget:home")
            putExtra(ActionReceiver.EXTRA_REVISION, -1) // Widgets are static, no revision needed
            putExtra(ActionReceiver.EXTRA_ACTION, actionJson.toString())
        }

        return PendingIntent.getBroadcast(
            context,
            requestCode, // Unique request code per button to prevent intent collision
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}