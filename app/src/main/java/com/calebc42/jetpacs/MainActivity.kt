package com.calebc42.jetpacs

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.window.Dialog
import com.calebc42.jetpacs.ui.theme.JetpacsTheme
import org.json.JSONObject
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Editor toolbars are server-driven data (SPEC §9 "Editor toolbars"):
        // the app's elisp composes the items. JetpacsToolbars remains as the
        // native-alternative seam — a host that wants a Kotlin toolbar
        // registers it here by name; this shell ships none.
        BridgeService.start(this)
        // savedInstanceState guard: a rotation must not re-fire the share.
        if (savedInstanceState == null) {
            handleShareIntent(intent)
            handleWidgetIntent(intent)
        }
        setContent { JetpacsTheme { BridgeScreen() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
        handleWidgetIntent(intent)
    }

    /**
     * Android share sheet → Emacs. Emitted as the app-agnostic `share.text`
     * action; whatever Tier 1 is loaded decides what receiving shared text
     * means (Glasspane answers with org capture). The shared text rides the
     * normal action pipeline with queue policy, so sharing works with Emacs
     * dead: the handler runs on the next replay.
     */
    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        if (intent.type?.startsWith("text/") != true) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        if (text.isNullOrBlank() && subject.isNullOrBlank()) return
        val action = JSONObject().apply {
            put("action", "share.text")
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
        Toast.makeText(this, "Sent to Emacs", Toast.LENGTH_SHORT).show()
    }

    /**
     * External-entry trampoline: widget row taps, the widget header's
     * server-driven `header_action` button, and in-app QS tiles open the
     * app with an action embedded (all composed by the loaded Tier 1 —
     * this shell hardcodes none). Rebroadcast through ActionReceiver so it
     * shares the live/queue pipeline; Emacs answers by pushing the target
     * view or dialog into the now-visible app. Offline, the action queues
     * and the app opens on the cached view.
     */
    private fun handleWidgetIntent(intent: Intent?) {
        val actionJson = intent?.getStringExtra(JetpacsLaunch.EXTRA_WIDGET_ACTION) ?: return
        // Relaunching from recents redelivers the original intent — that is a
        // "reopen the app" gesture, not a fresh row tap; don't re-navigate.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        sendBroadcast(Intent(this, ActionReceiver::class.java).apply {
            action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, JetpacsWidgetProvider.SURFACE)
            putExtra(
                ActionReceiver.EXTRA_REVISION,
                intent.getIntExtra(JetpacsLaunch.EXTRA_WIDGET_REVISION, -1))
            putExtra(ActionReceiver.EXTRA_ACTION, actionJson)
        })
    }
}

private const val DASHBOARD_SURFACE = "app:dashboard"

@OptIn(ExperimentalMaterial3Api::class) // ModalBottomSheet (sheet-style dialogs)
@Composable
private fun BridgeScreen() {
    val context = LocalContext.current
    var showJetpacsSettings by remember { mutableStateOf(false) }

    // Reactive, not polled: the flow fires when BridgeService publishes the
    // manager (and again if the service is ever recreated).
    val surfaceManager by JetpacsRuntime.surfaceManagerFlow.collectAsState()

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
            "jetpacs.settings.open" -> {
                JetpacsRuntime.dialogState.dismiss()
                JetpacsRuntime.pieMenuState.dismiss()
                showJetpacsSettings = true
            }
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
                cm.setPrimaryClip(ClipData.newPlainText("jetpacs", text))
                // Android 13+ shows its own clipboard confirmation overlay.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                }
            }
            else -> context.sendBroadcast(actionIntent(context, action, dashboardRecord?.revision ?: 0))
        }
    }

    val activeViewKey = remember(dashboardRecord, currentView) {
        if (dashboardRecord == null) null
        else {
            val views = dashboardRecord.spec.optJSONObject("views")
            if (views == null) null
            else {
                currentView?.takeIf { views.has(it) }
                    ?: dashboardRecord.spec.optString("initial_view").takeIf { it.isNotEmpty() && views.has(it) }
                    ?: views.keys().asSequence().firstOrNull()
            }
        }
    }

    var viewStack by remember { mutableStateOf(listOf<String>()) }

    LaunchedEffect(activeViewKey) {
        if (activeViewKey != null) {
            val views = dashboardRecord?.spec?.optJSONObject("views")
            val initial = dashboardRecord?.spec?.optString("initial_view")?.takeIf { it.isNotEmpty() && views?.has(it) == true }
                ?: views?.keys()?.asSequence()?.firstOrNull()
            
            if (activeViewKey == initial) {
                viewStack = listOf(activeViewKey)
            } else if (viewStack.lastOrNull() != activeViewKey) {
                if (viewStack.size > 1 && activeViewKey == viewStack[viewStack.size - 2]) {
                    viewStack = viewStack.dropLast(1)
                } else {
                    viewStack = viewStack + activeViewKey
                }
            }
        }
    }

    BackHandler(enabled = !showJetpacsSettings && viewStack.size > 1) {
        val previousView = viewStack[viewStack.size - 2]
        dispatch(JSONObject().apply {
            put("builtin", "view.switch")
            put("view", previousView)
        })
    }

    // PATCH: the dashboard's view spec is ALREADY a `scaffold` node, which the
    // SDUI renderer turns into its own Material3 Scaffold. The previous code
    // wrapped that in an outer Scaffold + a (non-fill-height) Column, so the
    // inner Scaffold had no bounded height and collapsed — top bar, bottom bar,
    // and body rendered broken or empty. Render the SDUI tree as the top-level
    // content inside a fill-size Box and let the scaffold node own the layout.
    val connected by JetpacsRuntime.connected.collectAsState()
    val pairedEver by JetpacsRuntime.pairedEver.collectAsState()
    val queuedCount by JetpacsRuntime.queuedCount.collectAsState()

    BackHandler(enabled = showJetpacsSettings) { showJetpacsSettings = false }

    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        if (showJetpacsSettings) {
            JetpacsSettingsScreen(
                dashboardUpdatedAt = dashboardRecord?.updatedAt,
                cachedSurfaceCount = surfaceManager?.revisionSnapshot()?.length() ?: 0,
                onBack = { showJetpacsSettings = false },
            )
        } else Box(modifier = Modifier.fillMaxSize()) {
            // Until an Emacs has paired at least once, the pairing screen wins even
            // over a cached dashboard — otherwise a stale surface from a pre-auth
            // session would hide the token the user needs to pair.
            if (dashboardRecord == null || !pairedEver) {
                OnboardingFlow()
            } else {
            val spec = dashboardRecord.resolveSpec(currentView)
            RenderChildren(
                spec.optJSONArray("children"),
                DASHBOARD_SURFACE,
                dashboardRecord.revision,
                dispatch
            )
            // Paired but Emacs is away: make the cached/offline state explicit
            // and keep pairing details available without making the token the
            // primary dashboard affordance.
            if (!connected || queuedCount > 0) {
                ConnectionStatusBanner(
                    connected = connected,
                    queuedCount = queuedCount,
                    updatedAt = dashboardRecord.updatedAt,
                    modifier = Modifier.align(Alignment.BottomCenter),
                )
            }
        }
    }
}

    val dialogSpec by JetpacsRuntime.dialogState.currentDialog.collectAsState()
    if (!showJetpacsSettings && dialogSpec != null) {
        val onDismiss = {
            // Notify Emacs if this was a prompt dialog (fires prompt.dismiss action).
            JetpacsRuntime.dialogState.onDismissed?.invoke()
            JetpacsRuntime.dialogState.dismiss()
        }
        // Presentation is server-chosen (SPEC §7): the spec's root may carry
        // `dialog_style` — "sheet"/"sheet_full" render the same subtree in a
        // modal bottom sheet; anything else keeps the centered dialog, which
        // is also what an older companion shows (unknown keys are ignored).
        when (dialogSpec!!.optString("dialog_style")) {
            "sheet", "sheet_full" -> ModalBottomSheet(
                onDismissRequest = onDismiss,
                sheetState = rememberModalBottomSheetState(
                    skipPartiallyExpanded =
                        dialogSpec!!.optString("dialog_style") == "sheet_full"
                )
            ) {
                SduiNode(
                    node = dialogSpec!!,
                    surfaceId = "dialog",
                    revision = 0,
                    modifier = Modifier.padding(16.dp),
                    onAction = dispatch
                )
            }
            else -> Dialog(onDismissRequest = onDismiss) {
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
    }

    val pieMenuSpec by JetpacsRuntime.pieMenuState.currentMenu.collectAsState()
    if (!showJetpacsSettings && pieMenuSpec != null) {
        RadialMenu(
            spec = pieMenuSpec!!,
            onAction = { action ->
                dispatch(action)
                // Emacs answers every keymap action with pie_menu.show (a live
                // transient re-showing) or pie_menu.dismiss — but only while
                // connected. Offline, nothing will ever answer: close locally.
                if (!JetpacsRuntime.connected.value) JetpacsRuntime.pieMenuState.dismiss()
            },
            onDismiss = { JetpacsRuntime.pieMenuState.dismiss() },
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

/** Generic pairing guidance, used when the screen is shown outside onboarding. */
private const val DEFAULT_PAIR_INSTRUCTIONS =
    "The bridge is listening. Pair Emacs (on this device) by adding the " +
        "line below to your init, then:\n\n" +
        "    (require 'jetpacs-core)\n" +
        "    M-x jetpacs-connect\n\n" +
        "Watch *Messages* for \"Jetpacs: handshake ok\". This screen updates " +
        "automatically once the handshake completes."

@Composable
internal fun PairingScreen(instructions: String = DEFAULT_PAIR_INSTRUCTIONS) {
    val isConnected by JetpacsRuntime.connected.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = Icons.Default.Cable,
            contentDescription = null,
            modifier = Modifier
                .size(64.dp)
                .padding(bottom = 16.dp),
            tint = MaterialTheme.colorScheme.primary
        )

        Text("Waiting for Emacs…", style = MaterialTheme.typography.headlineMedium)
        
        Text(
            instructions,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 16.dp, bottom = 32.dp),
            textAlign = TextAlign.Center
        )

        Surface(
            shape = RoundedCornerShape(16.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier.fillMaxWidth()
        ) {
            PairingTokenBlock(modifier = Modifier.padding(24.dp))
        }

        Spacer(modifier = Modifier.height(32.dp))
        StatusRow("Connection", if (isConnected) "Connected" else "Listening", isConnected)
    }
}

/**
 * The pairing token plus its ready-to-paste setq line (tap to copy). Shown on
 * the pairing screen and inside [ConnectionStatusBanner]. Displaying it is no more
 * exposed than the token already is in app-private prefs or the user's init —
 * its job is to keep OTHER APPS from completing the handshake, not to hide
 * from someone holding an unlocked phone.
 */
@Composable
internal fun PairingTokenBlock(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val token = remember { JetpacsAuth.token(context) }
    val setqLine = "(setq jetpacs-auth-token \"$token\")"
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Pairing token", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
        Text(token, style = MaterialTheme.typography.headlineSmall, fontFamily = FontFamily.Monospace, modifier = Modifier.padding(vertical = 8.dp))
        Text(
            setqLine,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.primary,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .clickable {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("jetpacs-token", setqLine))
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                    }
                }
        )
        Text(
            "Tap the line to copy it. Any app on this phone can reach the bridge port; only a paired Emacs completes the handshake.",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 16.dp)
        )
    }
}

/**
 * Snackbar-style lifecycle status. Offline it identifies the age of the cached
 * dashboard and any queued actions; immediately after reconnect it stays up
 * until those actions have drained. Details offers recovery without making
 * pairing the primary dashboard affordance.
 */
@Composable
private fun ConnectionStatusBanner(
    connected: Boolean,
    queuedCount: Int,
    updatedAt: Long,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var show by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(updatedAt) {
        now = System.currentTimeMillis()
        while (true) {
            delay(60_000)
            now = System.currentTimeMillis()
        }
    }
    val containerColor = if (connected) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.inverseSurface
    }
    val contentColor = if (connected) {
        MaterialTheme.colorScheme.onPrimaryContainer
    } else {
        MaterialTheme.colorScheme.inverseOnSurface
    }
    val age = relativeAge(updatedAt, now)
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = containerColor,
        shadowElevation = 6.dp,
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                Icons.Default.Cable,
                contentDescription = null,
                tint = contentColor,
            )
            Column(Modifier.weight(1f)) {
                Text(
                    if (connected) "Connected to Emacs" else "Emacs is offline",
                    style = MaterialTheme.typography.labelLarge,
                    color = contentColor,
                )
                Text(
                    connectionSummary(connected, queuedCount, age),
                    style = MaterialTheme.typography.bodySmall,
                    color = contentColor.copy(alpha = 0.75f),
                )
            }
            TextButton(onClick = { show = true }) {
                Text(
                    "Details",
                    color = if (connected) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.inversePrimary,
                )
            }
        }
    }
    if (show) {
        Dialog(onDismissRequest = { show = false }) {
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface) {
                Column(modifier = Modifier.padding(16.dp).verticalScroll(rememberScrollState())) {
                    Text("Connection details", style = MaterialTheme.typography.titleMedium)
                    StatusRow("Bridge", if (connected) "Connected" else "Listening", connected)
                    StatusRow("Dashboard", "Saved $age", true)
                    StatusRow(
                        "Offline actions",
                        if (queuedCount == 0) "None waiting"
                        else "$queuedCount waiting to sync",
                        queuedCount == 0,
                    )
                    if (!connected) {
                        Button(
                            onClick = {
                                val launch = context.packageManager
                                    .getLaunchIntentForPackage(EmacsWaker.EMACS_PACKAGE)
                                if (launch == null) {
                                    Toast.makeText(context, "Emacs is not installed", Toast.LENGTH_SHORT).show()
                                } else {
                                    context.startActivity(launch)
                                }
                            },
                            modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                        ) {
                            Text("Open Emacs")
                        }
                    }
                    Text(
                        "To connect a different Emacs, copy this pairing line into its configuration.",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 16.dp),
                    )
                    PairingTokenBlock(modifier = Modifier.padding(top = 12.dp))
                }
            }
        }
    }
}

internal fun relativeAge(updatedAt: Long, now: Long = System.currentTimeMillis()): String {
    val seconds = ((now - updatedAt).coerceAtLeast(0L) / 1000L)
    if (seconds < 60) return "just now"
    val minutes = seconds / 60
    if (minutes < 60) return "$minutes ${if (minutes == 1L) "minute" else "minutes"} ago"
    val hours = minutes / 60
    if (hours < 24) return "$hours ${if (hours == 1L) "hour" else "hours"} ago"
    val days = hours / 24
    return "$days ${if (days == 1L) "day" else "days"} ago"
}

internal fun connectionSummary(connected: Boolean, queuedCount: Int, age: String): String {
    val actions = "$queuedCount saved ${if (queuedCount == 1) "action" else "actions"}"
    return when {
        connected && queuedCount > 0 -> "$actions waiting to sync"
        connected -> "Up to date"
        queuedCount > 0 -> "Saved $age · $actions waiting"
        else -> "Showing content saved $age"
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

