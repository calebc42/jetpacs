package com.calebc42.eabp

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import com.calebc42.eabp.ui.theme.EabpTheme
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        BridgeService.start(this)
        // savedInstanceState guard: a rotation must not re-fire the share.
        if (savedInstanceState == null) handleShareIntent(intent)
        setContent { EabpTheme { BridgeScreen() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    /**
     * Android share sheet → org capture. The shared text rides the normal
     * action pipeline with queue policy, so sharing works with Emacs dead:
     * the capture dialog appears on the next replay.
     */
    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        if (intent.type?.startsWith("text/") != true) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        if (text.isNullOrBlank() && subject.isNullOrBlank()) return
        val action = JSONObject().apply {
            put("action", "org.capture.share")
            put("when_offline", "queue")
            put("args", JSONObject().apply {
                put("text", text ?: "")
                put("subject", subject ?: "")
            })
        }
        sendBroadcast(Intent(this, ActionReceiver::class.java).apply {
            this.action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, "share")
            putExtra(ActionReceiver.EXTRA_REVISION, -1)
            putExtra(ActionReceiver.EXTRA_ACTION, action.toString())
        })
        Toast.makeText(this, "Sent to Emacs capture", Toast.LENGTH_SHORT).show()
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

    // Reactive, not polled: the flow fires when BridgeService publishes the
    // manager (and again if the service is ever recreated).
    val surfaceManager by EabpRuntime.surfaceManagerFlow.collectAsState()

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
     * Builtins are the companion-local fast path (they work with Emacs dead):
     * `view.switch` flips the view immediately from cache and merely informs
     * Emacs via a drop-policy `view.switched` event; `clipboard.copy` puts
     * the action's `text` on the device clipboard. Everything else goes
     * through the normal ActionReceiver pipeline (live / queue / wake).
     */
    val dispatch = { action: JSONObject ->
        when (action.optString("builtin")) {
            "view.switch" -> {
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
            }
            "clipboard.copy" -> {
                val text = action.optString("text")
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("eabp", text))
                // Android 13+ shows its own clipboard confirmation overlay.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                }
            }
            else -> context.sendBroadcast(actionIntent(context, action, dashboardRecord?.revision ?: 0))
        }
    }

    // PATCH: the dashboard's view spec is ALREADY a `scaffold` node, which the
    // SDUI renderer turns into its own Material3 Scaffold. The previous code
    // wrapped that in an outer Scaffold + a (non-fill-height) Column, so the
    // inner Scaffold had no bounded height and collapsed — top bar, bottom bar,
    // and body rendered broken or empty. Render the SDUI tree as the top-level
    // content inside a fill-size Box and let the scaffold node own the layout.
    val connected by EabpRuntime.connected.collectAsState()
    val pairedEver by EabpRuntime.pairedEver.collectAsState()

    Box(modifier = Modifier.fillMaxSize()) {
        // Until an Emacs has paired at least once, the pairing screen wins even
        // over a cached dashboard — otherwise a stale surface from a pre-auth
        // session would hide the token the user needs to pair.
        if (dashboardRecord == null || !pairedEver) {
            PairingScreen()
        } else {
            val spec = dashboardRecord.resolveSpec(currentView)
            RenderChildren(
                spec.optJSONArray("children"),
                DASHBOARD_SURFACE,
                dashboardRecord.revision,
                dispatch
            )
            // Paired but Emacs is away: a discreet key to re-view the token
            // (e.g. to pair a new machine) without wiping app data.
            if (!connected) {
                TokenReveal(modifier = Modifier.align(Alignment.TopEnd).padding(8.dp))
            }
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
private fun PairingScreen() {
    Column(modifier = Modifier.padding(16.dp)) {
        Text("Waiting for Emacs…", style = MaterialTheme.typography.headlineMedium)
        // The companion is the server and can only listen — Emacs is the client
        // and must dial in. Until it does, taps here are queued and Emacs sees
        // nothing.
        Text(
            "The bridge is listening. Pair Emacs (on this device) by adding the " +
                    "line below to your init, then:\n\n" +
                    "    (require 'eabp-org-ui)\n" +
                    "    M-x eabp-connect\n\n" +
                    "Watch *Messages* for \"EABP: handshake ok\". This screen updates " +
                    "automatically once the handshake completes.",
            style = MaterialTheme.typography.bodyMedium
        )

        PairingTokenBlock(modifier = Modifier.padding(top = 16.dp))

        val isConnected by EabpRuntime.connected.collectAsState()
        StatusRow("Connection", if (isConnected) "Connected" else "Listening", isConnected)
    }
}

/**
 * The pairing token plus its ready-to-paste setq line (tap to copy). Shown on
 * the pairing screen and inside [TokenReveal]. Displaying it is no more
 * exposed than the token already is in app-private prefs or the user's init —
 * its job is to keep OTHER APPS from completing the handshake, not to hide
 * from someone holding an unlocked phone.
 */
@Composable
private fun PairingTokenBlock(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val token = remember { EabpAuth.token(context) }
    val setqLine = "(setq eabp-auth-token \"$token\")"
    Column(modifier = modifier) {
        Text("Pairing token", style = MaterialTheme.typography.labelLarge)
        Text(token, style = MaterialTheme.typography.headlineSmall, fontFamily = FontFamily.Monospace)
        Text(
            setqLine,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .padding(top = 4.dp)
                .clickable {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("eabp-token", setqLine))
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                    }
                }
        )
        Text(
            "Tap the line to copy it. Any app on this phone can reach the " +
                    "bridge port; only a paired Emacs completes the handshake.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp)
        )
    }
}

/**
 * A compact "🔑 Pair" chip that opens the token in a dialog. Overlaid on the
 * dashboard only while Emacs is disconnected, so an already-paired user can
 * still retrieve the token (to pair another machine, or after editing init)
 * without clearing app data to force the pairing screen back.
 */
@Composable
private fun TokenReveal(modifier: Modifier = Modifier) {
    var show by remember { mutableStateOf(false) }
    Surface(
        shape = MaterialTheme.shapes.small,
        color = MaterialTheme.colorScheme.secondaryContainer,
        tonalElevation = 3.dp,
        modifier = modifier.clickable { show = true }
    ) {
        Text(
            "🔑 Pair",
            style = MaterialTheme.typography.labelMedium,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
        )
    }
    if (show) {
        Dialog(onDismissRequest = { show = false }) {
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("Pair another Emacs", style = MaterialTheme.typography.titleMedium)
                    PairingTokenBlock(modifier = Modifier.padding(top = 12.dp))
                }
            }
        }
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