package com.calebc42.eabp

import com.calebc42.eabp.core.R
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import org.json.JSONObject

/**
 * Blank Quick Settings tile slots, the tile twin of [EabpCustomWidgetProvider]:
 * five pre-registered tiles composed entirely from Emacs by pushing a
 * `tile:customN` surface built with `eabp-tile'. The services are declared
 * as ACTIVE_TILE, so the system only refreshes them when [requestUpdate]
 * runs — which SurfaceManager calls on every tile surface update. An
 * un-pushed slot parks as a grayed-out (unavailable) tile.
 */
object EabpTileSlots {
    val SLOTS: Map<String, Class<out EabpTileSlotService>> = mapOf(
        "tile:custom1" to EabpTile1::class.java,
        "tile:custom2" to EabpTile2::class.java,
        "tile:custom3" to EabpTile3::class.java,
        "tile:custom4" to EabpTile4::class.java,
        "tile:custom5" to EabpTile5::class.java)

    /** Ask the system to rebind SURFACE's tile so it re-reads the cache. */
    fun requestUpdate(context: Context, surface: String) {
        val cls = SLOTS[surface]
        if (cls == null) {
            Log.w(TAG, "No tile slot for surface '$surface'")
            return
        }
        // No-op when the user hasn't added the tile to the shade.
        TileService.requestListeningState(context, ComponentName(context, cls))
    }

    private const val TAG = "EabpTiles"
}

abstract class EabpTileSlotService : TileService() {

    abstract val surface: String

    override fun onStartListening() {
        val spec = widgetManager(this).getRecord(surface)?.spec
        qsTile?.apply {
            if (spec == null) {
                // Uncomposed slot: parked until Emacs pushes something.
                state = Tile.STATE_UNAVAILABLE
            } else {
                spec.optString("label").takeIf { it.isNotEmpty() }?.let { label = it }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    subtitle = spec.optString("subtitle").ifEmpty { null }
                }
                state = when (spec.optString("state")) {
                    "active" -> Tile.STATE_ACTIVE
                    "unavailable" -> Tile.STATE_UNAVAILABLE
                    else -> Tile.STATE_INACTIVE
                }
                icon = Icon.createWithResource(
                    this@EabpTileSlotService, tileIcon(spec.optString("icon")))
            }
            updateTile()
        }
    }

    override fun onClick() {
        val record = widgetManager(this).getRecord(surface) ?: return
        val action = record.spec.optJSONObject("on_tap") ?: return
        if (record.spec.optBoolean("tap_in_app")) {
            // Ends in the app with a keyboard/UI, so clear the keyguard.
            if (isLocked) unlockAndRun { openInApp(action, record.revision) }
            else openInApp(action, record.revision)
        } else {
            // Silent shade action: fires without unlocking, like the
            // flashlight tile. The Elisp side chooses what to expose here.
            sendBroadcast(Intent(this, ActionReceiver::class.java).apply {
                this.action = ActionReceiver.ACTION_TAP
                putExtra(ActionReceiver.EXTRA_SURFACE, surface)
                putExtra(ActionReceiver.EXTRA_REVISION, record.revision)
                putExtra(ActionReceiver.EXTRA_ACTION, action.toString())
            })
        }
    }

    private fun openInApp(action: JSONObject, revision: Int) {
        val intent = EabpLaunch.openAppIntent(this, action.toString(), revision)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    // hashCode as request code: unique per slot, stable.
                    this, surface.hashCode(), intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        } else {
            // The Intent overload throws on targetSdk 34+, hence the branch.
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun tileIcon(name: String): Int = when (name) {
        "todo_open" -> R.drawable.ic_todo_open
        "todo_done" -> R.drawable.ic_todo_done
        "refresh" -> R.drawable.ic_widget_refresh
        "scheduled" -> R.drawable.ic_meta_scheduled
        "deadline" -> R.drawable.ic_meta_deadline
        "event" -> R.drawable.ic_meta_event
        "folder" -> R.drawable.ic_meta_folder
        else -> R.drawable.ic_widget_add
    }
}

class EabpTile1 : EabpTileSlotService() { override val surface = "tile:custom1" }
class EabpTile2 : EabpTileSlotService() { override val surface = "tile:custom2" }
class EabpTile3 : EabpTileSlotService() { override val surface = "tile:custom3" }
class EabpTile4 : EabpTileSlotService() { override val surface = "tile:custom4" }
class EabpTile5 : EabpTileSlotService() { override val surface = "tile:custom5" }