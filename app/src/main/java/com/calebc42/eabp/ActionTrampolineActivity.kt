package com.calebc42.eabp

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Invisible click router for the agenda widget's list rows.
 *
 * A RemoteViews collection allows exactly one PendingIntent template, but
 * our rows need two behaviors: the todo toggle must fire silently while the
 * row itself opens the app. So the template targets this Theme.NoDisplay
 * activity (the same pattern Jetpack Glance uses for widget lists) and the
 * fill-in intent's TYPE extra picks the path. Activity trampolines are the
 * sanctioned kind — the Android 12+ trampoline ban covers broadcasts and
 * services starting activities, not this.
 */
class ActionTrampolineActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val actionJson = intent.getStringExtra(EXTRA_ACTION)
        val revision = intent.getIntExtra(EXTRA_REVISION, -1)
        val surface = intent.getStringExtra(EXTRA_SURFACE)
            ?: EabpWidgetProvider.SURFACE
        if (actionJson != null) {
            when (intent.getStringExtra(EXTRA_TYPE)) {
                TYPE_BROADCAST -> sendBroadcast(
                    Intent(this, ActionReceiver::class.java).apply {
                        action = ActionReceiver.ACTION_TAP
                        putExtra(ActionReceiver.EXTRA_SURFACE, surface)
                        putExtra(ActionReceiver.EXTRA_REVISION, revision)
                        putExtra(ActionReceiver.EXTRA_ACTION, actionJson)
                    })
                TYPE_OPEN_APP -> startActivity(
                    Intent(this, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        putExtra(MainActivity.EXTRA_WIDGET_ACTION, actionJson)
                        putExtra(MainActivity.EXTRA_WIDGET_REVISION, revision)
                    })
            }
        }
        // Theme.NoDisplay requires finishing before onResume completes.
        finish()
    }

    companion object {
        const val EXTRA_TYPE = "trampoline_type"
        const val EXTRA_ACTION = "trampoline_action"
        const val EXTRA_SURFACE = "trampoline_surface"
        const val EXTRA_REVISION = "trampoline_revision"
        const val TYPE_BROADCAST = "broadcast"
        const val TYPE_OPEN_APP = "open_app"
    }
}