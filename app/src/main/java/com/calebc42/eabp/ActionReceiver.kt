package com.calebc42.eabp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Turns UI interactions (notification buttons, dashboard taps, widget
 * presses, state changes) into EABP frames.
 *
 * This receiver can be the app's only living entry point — a notification
 * tap may cold-start the process — so it bootstraps the runtime (database)
 * and resurrects the bridge service before doing anything else.
 */
class ActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // Bootstrap: without this the queue is dead code on cold start.
        EabpRuntime.initialize(context.applicationContext)
        // A user interaction is the perfect moment to resurrect a killed
        // bridge. PendingIntent delivery grants a temporary FGS-start
        // exemption; the runCatching covers contexts where it doesn't.
        runCatching { BridgeService.start(context) }
            .onFailure { Log.w(TAG, "Bridge resurrection failed: ${it.message}") }

        val pendingResult = goAsync()

        thread(name = "EabpActionDispatch") {
            try {
                when (intent.action) {
                    ACTION_STATE_CHANGED -> handleStateChanged(context, intent)
                    ACTION_TAP -> handleTap(context, intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to dispatch action", e)
            } finally {
                // We MUST call finish() when the background thread is done.
                pendingResult.finish()
            }
        }
    }

    private fun handleStateChanged(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val valueRaw = intent.getStringExtra(EXTRA_VALUE_JSON) ?: "null"
        val value = org.json.JSONTokener(valueRaw).nextValue()
        val payload = JSONObject().apply {
            put("id", id)
            put("value", value)
        }

        val conn = EabpRuntime.server?.connection()
        if (conn != null && conn.helloComplete &&
            conn.send(Frame(kind = Kind.STATE_CHANGED, payload = payload))
        ) {
            Log.d(TAG, "Delivered state.changed for '$id'")
        } else {
            // Shape-preserving queue insert. Dedupe per widget id: only the
            // final value of an offline editing burst gets replayed.
            EabpRuntime.database?.eventDao()?.insert(
                QueuedEvent(
                    kind = Kind.STATE_CHANGED,
                    payload = payload.toString(),
                    dedupeKey = "state/$id",
                )
            )
            EabpRuntime.refreshQueuedCount()
            Log.d(TAG, "Queued state.changed for '$id'")
        }
    }

    private fun handleTap(context: Context, intent: Intent) {
        val surface = intent.getStringExtra(EXTRA_SURFACE) ?: return
        val revision = intent.getIntExtra(EXTRA_REVISION, -1)
        val actionRaw = intent.getStringExtra(EXTRA_ACTION) ?: return
        val action = runCatching { JSONObject(actionRaw) }.getOrNull() ?: return
        val actionName = action.optString("action")
        val argsObject = action.optJSONObject("args") ?: JSONObject()

        val event = JSONObject().apply {
            put("surface", surface)
            put("revision_seen", revision)
            put("action", actionName)
            put("args", argsObject)
            put("fields", JSONObject.NULL)
            put("queued_at", JSONObject.NULL)
        }

        val conn = EabpRuntime.server?.connection()
        if (conn != null && conn.helloComplete &&
            conn.send(Frame(kind = "event.action", payload = event))
        ) {
            Log.d(TAG, "Delivered '$actionName' live")
            return
        }

        when (val policy = action.optString("when_offline", "queue")) {
            "drop" -> Log.d(TAG, "Dropped offline action '$actionName' (drop)")
            else -> {
                // queue, wake, and (for now) local all persist the event.
                EabpRuntime.database?.eventDao()?.insert(
                    QueuedEvent(
                        kind = "event.action",
                        payload = event.toString(),
                        dedupeKey = action.optString("dedupe").ifEmpty { null },
                        ttlS = if (action.has("ttl_s")) action.optLong("ttl_s") else null,
                    )
                )
                EabpRuntime.refreshQueuedCount()
                Log.d(TAG, "Queued offline action '$actionName' (policy=$policy)")
                if (policy == "wake") EmacsWaker.requestWake(context)
            }
        }
    }

    companion object {
        const val ACTION_TAP = "com.calebc42.eabp.ACTION_TAP"
        const val ACTION_STATE_CHANGED = "com.calebc42.eabp.ACTION_STATE_CHANGED"
        const val EXTRA_SURFACE = "surface"
        const val EXTRA_REVISION = "revision"
        const val EXTRA_ACTION = "action"
        const val EXTRA_ID = "id"
        const val EXTRA_VALUE_JSON = "value_json"
        private const val TAG = "EabpActionReceiver"
    }
}