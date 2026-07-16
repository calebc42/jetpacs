package com.calebc42.jetpacs

import android.content.Context
import android.content.Intent
import java.util.UUID

/**
 * The library's only way to "open the app": resolve the HOST's launcher
 * activity through the package manager instead of naming an activity class.
 * This keeps the module host-agnostic (the Glasspane shell in :app is one
 * host) — the same seam discipline as [JetpacsToolbars].
 *
 * The extras contract: the host's launcher activity must rebroadcast
 * [EXTRA_WIDGET_ACTION] / [EXTRA_WIDGET_REVISION] through [ActionReceiver]
 * on arrival, so trampolined actions (widget row taps, QS capture, pinned
 * shortcuts) join the normal live/queue/wake pipeline (see
 * MainActivity.handleWidgetIntent in :app) — but only after [verifyToken]
 * passes. A launcher activity is exported by definition, so any installed
 * app can send it an intent with a forged [EXTRA_WIDGET_ACTION]; the
 * per-install token proves the intent was composed by this app (directly,
 * or replayed by the launcher from a pinned shortcut we composed) — the
 * termux-widget shortcut-token idiom. On a missing or wrong token the host
 * opens normally and drops the action. The token never rotates: launchers
 * persist pinned-shortcut intents, and rotation would strand every pin.
 */
object JetpacsLaunch {
    const val EXTRA_WIDGET_ACTION = "widget_action"
    const val EXTRA_WIDGET_REVISION = "widget_revision"
    const val EXTRA_LAUNCH_TOKEN = "launch_token"

    private const val PREFS = "jetpacs"
    private const val KEY_TOKEN = "launch_token"

    /** Intent opening the host app's launcher activity. */
    fun openAppIntent(context: Context): Intent =
        requireNotNull(
            context.packageManager.getLaunchIntentForPackage(context.packageName)
        ) { "Jetpacs host app declares no launcher activity" }.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }

    /** Open the host app with an embedded action for its trampoline. */
    fun openAppIntent(context: Context, actionJson: String, revision: Int): Intent =
        openAppIntent(context).apply {
            putExtra(EXTRA_WIDGET_ACTION, actionJson)
            putExtra(EXTRA_WIDGET_REVISION, revision)
            putExtra(EXTRA_LAUNCH_TOKEN, token(context))
        }

    /**
     * True when [intent] carries this install's token, i.e. this app
     * composed it. Hosts MUST gate the action rebroadcast on this.
     */
    fun verifyToken(context: Context, intent: Intent): Boolean =
        tokenMatches(token(context), intent.getStringExtra(EXTRA_LAUNCH_TOKEN))

    /** Pure core of [verifyToken]: an absent token is a mismatch. */
    internal fun tokenMatches(expected: String, presented: String?): Boolean =
        presented != null && presented == expected

    /** Per-install random token, generated on first use (app-private prefs). */
    private fun token(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_TOKEN, null)?.let { return it }
        val fresh = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_TOKEN, fresh).apply()
        return fresh
    }
}
