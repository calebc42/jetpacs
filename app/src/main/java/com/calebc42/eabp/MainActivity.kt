package com.calebc42.eabp

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import com.calebc42.eabp.ui.theme.EabpTheme
import kotlinx.coroutines.delay
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        BridgeService.start(this)
        setContent { EabpTheme { BridgeScreen() } }
    }
}

private const val DASHBOARD_SURFACE = "app:dashboard"

@Composable
private fun BridgeScreen() {
    val context = LocalContext.current

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) EabpRuntime.surfaceManager?.renderAllCached()
    }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !hasNotifPermission(context)) {
            launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    var surfaceManager by remember { mutableStateOf<SurfaceManager?>(null) }
    LaunchedEffect(Unit) {
        while (surfaceManager == null) {
            surfaceManager = EabpRuntime.surfaceManager
            delay(100)
        }
    }

    var version by remember { mutableIntStateOf(0) }
    LaunchedEffect(surfaceManager) {
        surfaceManager?.version?.collect { version = it }
    }

    val dashboardRecord = remember(version, surfaceManager) {
        surfaceManager?.getRecord(DASHBOARD_SURFACE)
    }
    val currentView = remember(version, surfaceManager) {
        surfaceManager?.currentView(DASHBOARD_SURFACE)
    }

    /**
     * Central action dispatch.
     *
     * `view.switch` builtins are the local-navigation fast path: the view
     * flips immediately from cache (works with Emacs dead), and Emacs is
     * merely *informed* via a drop-policy `view.switched` event so it can
     * push fresher data for that view in the background. Everything else
     * goes through the normal ActionReceiver pipeline (live / queue / wake).
     */
    val dispatch = { action: JSONObject ->
        if (action.optString("builtin") == "view.switch") {
            val view = action.optString("view")
            if (view.isNotEmpty()) {
                surfaceManager?.setCurrentView(DASHBOARD_SURFACE, view)
                val notify = JSONObject().apply {
                    put("action", "view.switched")
                    put("args", JSONObject().apply {
                        put("surface", DASHBOARD_SURFACE)
                        put("view", view)
                    })
                    put("when_offline", "drop")
                }
                context.sendBroadcast(actionIntent(context, notify, dashboardRecord?.revision ?: 0))
            }
        } else {
            context.sendBroadcast(actionIntent(context, action, dashboardRecord?.revision ?: 0))
        }
    }

    // PATCH: the dashboard's view spec is ALREADY a `scaffold` node, which the
    // SDUI renderer turns into its own Material3 Scaffold. The previous code
    // wrapped that in an outer Scaffold + a (non-fill-height) Column, so the
    // inner Scaffold had no bounded height and collapsed — top bar, bottom bar,
    // and body rendered broken or empty. Render the SDUI tree as the top-level
    // content inside a fill-size Box and let the scaffold node own the layout.
    Box(modifier = Modifier.fillMaxSize()) {
        if (dashboardRecord == null) {
            WaitingScreen()
        } else {
            val spec = dashboardRecord.resolveSpec(currentView)
            RenderChildren(
                spec.optJSONArray("children"),
                DASHBOARD_SURFACE,
                dashboardRecord.revision,
                dispatch
            )
        }
    }

    val dialogSpec by EabpRuntime.dialogState.currentDialog.collectAsState()
    if (dialogSpec != null) {
        Dialog(onDismissRequest = {
            // Notify Emacs if this was a prompt dialog (fires prompt.dismiss action).
            EabpRuntime.dialogState.onDismissed?.invoke()
            EabpRuntime.dialogState.dismiss()
        }) {
            Surface(
                shape = MaterialTheme.shapes.medium,
                color = MaterialTheme.colorScheme.surface,
                modifier = Modifier.fillMaxWidth()
            ) {
                SduiNode(
                    node = dialogSpec!!,
                    surfaceId = "dialog",
                    revision = 0,
                    modifier = Modifier.padding(16.dp),
                    onAction = dispatch
                )
            }
        }
    }

    val pieMenuSpec by EabpRuntime.pieMenuState.currentMenu.collectAsState()
    if (pieMenuSpec != null) {
        RadialMenu(
            spec = pieMenuSpec!!,
            onAction = { action ->
                dispatch(action)
                // Emacs answers every keymap action with pie_menu.show (a live
                // transient re-showing) or pie_menu.dismiss — but only while
                // connected. Offline, nothing will ever answer: close locally.
                if (!EabpRuntime.connected.value) EabpRuntime.pieMenuState.dismiss()
            },
            onDismiss = { EabpRuntime.pieMenuState.dismiss() },
        )
    }
}

private fun actionIntent(context: Context, action: JSONObject, revision: Int): Intent =
    Intent(context, ActionReceiver::class.java).apply {
        this.action = ActionReceiver.ACTION_TAP
        putExtra(ActionReceiver.EXTRA_SURFACE, DASHBOARD_SURFACE)
        putExtra(ActionReceiver.EXTRA_REVISION, revision)
        putExtra(ActionReceiver.EXTRA_ACTION, action.toString())
    }

@Composable
private fun WaitingScreen() {
    Column(modifier = Modifier.padding(16.dp)) {
        Text("Waiting for Emacs…", style = MaterialTheme.typography.headlineMedium)
        // PATCH: actionable guidance. The companion is the server and can only
        // listen — Emacs is the client and must dial in. Until it does, taps
        // here are queued and Emacs sees nothing.
        Text(
            "The bridge is listening. Now connect from Emacs (on this device):\n\n" +
                    "    (require 'eabp-org-ui)\n" +
                    "    M-x eabp-connect\n\n" +
                    "Watch *Messages* for \"EABP: handshake ok\". This screen updates " +
                    "automatically once the handshake completes.",
            style = MaterialTheme.typography.bodyMedium
        )

        var isConnected by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) {
            while (true) {
                isConnected = EabpRuntime.server?.connection()?.helloComplete == true
                delay(1000)
            }
        }
        StatusRow("Connection", if (isConnected) "Connected" else "Listening", isConnected)
    }
}

@Composable
private fun StatusRow(label: String, value: String, ok: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(if (ok) "●" else "○", color = if (ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
        Column {
            Text(label, style = MaterialTheme.typography.labelLarge)
            Text(value, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

private fun hasNotifPermission(context: Context): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        ContextCompat.checkSelfPermission(
            context, Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    } else true