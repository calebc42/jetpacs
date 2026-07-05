package com.calebc42.eabp

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import org.json.JSONObject

/**
 * Quick Settings tile: org capture from anywhere. Opens the app with the
 * `org.capture.show` action embedded — the same MainActivity trampoline the
 * agenda widget's + button uses — because capture needs a keyboard, so it
 * must land in the visible app. Offline the action queues and the template
 * picker appears on the next reconnect, same as share-sheet capture.
 *
 * This is a static action tile, not a surface-backed one; the `tile:`
 * surface type (live state tiles, e.g. the running clock) remains its own
 * later phase.
 */
class CaptureTileService : TileService() {

    override fun onStartListening() {
        qsTile?.apply {
            // An action tile, not a toggle: always "available", never dimmed.
            state = Tile.STATE_ACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        // Capture types into the app, so get the keyguard out of the way
        // first; unlockAndRun no-ops when already unlocked but isLocked
        // keeps the prompt off the common path.
        if (isLocked) unlockAndRun { launchCapture() } else launchCapture()
    }

    private fun launchCapture() {
        val actionJson = JSONObject().apply {
            put("action", "org.capture.show")
            put("when_offline", "queue")
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EabpLaunch.EXTRA_WIDGET_ACTION, actionJson.toString())
            putExtra(EabpLaunch.EXTRA_WIDGET_REVISION, -1)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, REQUEST_TILE_CAPTURE, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        } else {
            // The Intent overload throws on targetSdk 34+, hence the branch.
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    companion object {
        // Unique app-wide with the widget request codes (2001-2003, 21xx, 22xx).
        private const val REQUEST_TILE_CAPTURE = 2004
    }
}