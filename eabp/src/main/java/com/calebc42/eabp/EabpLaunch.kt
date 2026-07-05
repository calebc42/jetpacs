package com.calebc42.eabp

import android.content.Context
import android.content.Intent

/**
 * The library's only way to "open the app": resolve the HOST's launcher
 * activity through the package manager instead of naming an activity class.
 * This keeps the module host-agnostic (the Glasspane shell in :app is one
 * host) — the same seam discipline as [EabpToolbars].
 *
 * The extras contract: the host's launcher activity must rebroadcast
 * [EXTRA_WIDGET_ACTION] / [EXTRA_WIDGET_REVISION] through [ActionReceiver]
 * on arrival, so trampolined actions (widget row taps, QS capture) join
 * the normal live/queue/wake pipeline (see MainActivity.handleWidgetIntent
 * in :app).
 */
object EabpLaunch {
    const val EXTRA_WIDGET_ACTION = "widget_action"
    const val EXTRA_WIDGET_REVISION = "widget_revision"

    /** Intent opening the host app's launcher activity. */
    fun openAppIntent(context: Context): Intent =
        requireNotNull(
            context.packageManager.getLaunchIntentForPackage(context.packageName)
        ) { "EABP host app declares no launcher activity" }.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }

    /** Open the host app with an embedded action for its trampoline. */
    fun openAppIntent(context: Context, actionJson: String, revision: Int): Intent =
        openAppIntent(context).apply {
            putExtra(EXTRA_WIDGET_ACTION, actionJson)
            putExtra(EXTRA_WIDGET_REVISION, revision)
        }
}
