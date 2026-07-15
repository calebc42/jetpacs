package com.calebc42.jetpacs

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat

/**
 * Android-owned settings that must remain reachable with Emacs offline.
 * Emacs/Tier-1 defcustoms stay on the server-rendered settings surface; this
 * screen owns grants, system deep-links, cached-state visibility and pairing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun JetpacsSettingsScreen(
    dashboardUpdatedAt: Long?,
    cachedSurfaceCount: Int,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val connected by JetpacsRuntime.connected.collectAsState()
    val queuedCount by JetpacsRuntime.queuedCount.collectAsState()
    var refreshKey by remember { mutableIntStateOf(0) }
    var showPairing by remember { mutableStateOf(false) }

    val settingsLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { refreshKey++ }
    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { refreshKey++ }
    val automationPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { refreshKey++ }

    val permissions = remember(refreshKey) { DeviceCapabilities.permissionMap(context) }
    val launchSettings: (Intent) -> Unit = { intent ->
        runCatching { settingsLauncher.launch(intent) }
            .onFailure {
                Toast.makeText(context, "This settings screen is unavailable", Toast.LENGTH_SHORT).show()
            }
    }
    val packageUri = Uri.parse("package:${context.packageName}")

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Jetpacs Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SettingsSection("Status") {
                JetpacsSettingRow(
                    icon = Icons.Default.Cable,
                    title = "Emacs connection",
                    summary = if (connected) "Live bridge session" else "Listening on this device",
                    status = if (connected) "Connected" else "Offline",
                    granted = connected,
                    actionLabel = if (connected) null else "Open Emacs",
                    onAction = if (connected) null else {{ openEmacs(context) }},
                )
                HorizontalDivider()
                JetpacsSettingRow(
                    icon = Icons.Default.Storage,
                    title = "Offline data",
                    summary = buildString {
                        append("$cachedSurfaceCount cached surfaces")
                        dashboardUpdatedAt?.let { append(" · dashboard ${relativeAge(it)}") }
                    },
                    status = if (queuedCount == 0) "No actions waiting" else "$queuedCount actions waiting",
                    granted = queuedCount == 0,
                )
            }

            SettingsSection("Android access") {
                JetpacsSettingRow(
                    icon = Icons.Default.Notifications,
                    title = "Notifications",
                    summary = "Reminders, automation results, and Emacs wake requests",
                    status = permissionStatus(permissions, "post_notifications"),
                    granted = permissions.optBoolean("post_notifications"),
                    actionLabel = "Manage",
                    onAction = {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            !hasJetpacsNotificationPermission(context)
                        ) {
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            launchSettings(appNotificationSettingsIntent(context))
                        }
                    },
                )
                HorizontalDivider()
                JetpacsSettingRow(
                    icon = Icons.Default.Notifications,
                    title = "Exact alarms",
                    summary = "On-time reminders and scheduled triggers",
                    status = permissionStatus(permissions, "exact_alarms"),
                    granted = permissions.optBoolean("exact_alarms"),
                    actionLabel = if (permissions.optBoolean("exact_alarms")) null else "Grant",
                    onAction = if (permissions.optBoolean("exact_alarms")) null else {{
                        launchSettings(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri))
                    }},
                )
                HorizontalDivider()
                JetpacsSettingRow(
                    icon = Icons.Default.Security,
                    title = "Modify system settings",
                    summary = "Allows brightness automation",
                    status = permissionStatus(permissions, "write_settings"),
                    granted = permissions.optBoolean("write_settings"),
                    actionLabel = if (permissions.optBoolean("write_settings")) null else "Grant",
                    onAction = if (permissions.optBoolean("write_settings")) null else {{
                        launchSettings(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, packageUri))
                    }},
                )
                HorizontalDivider()
                JetpacsSettingRow(
                    icon = Icons.Default.Security,
                    title = "Do Not Disturb access",
                    summary = "Allows ringer, volume, and DND automation",
                    status = permissionStatus(permissions, "notification_policy"),
                    granted = permissions.optBoolean("notification_policy"),
                    actionLabel = if (permissions.optBoolean("notification_policy")) null else "Grant",
                    onAction = if (permissions.optBoolean("notification_policy")) null else {{
                        launchSettings(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
                    }},
                )
                HorizontalDivider()
                val sensorsGranted = permissions.optBoolean("fine_location") &&
                    permissions.optBoolean("bluetooth_connect")
                JetpacsSettingRow(
                    icon = Icons.Default.Security,
                    title = "Automation sensors",
                    summary = "Optional access for Wi-Fi SSID and Bluetooth device triggers",
                    status = if (sensorsGranted) "Granted" else "Optional",
                    granted = sensorsGranted,
                    actionLabel = if (sensorsGranted) null else "Choose",
                    onAction = if (sensorsGranted) null else {{
                        automationPermissions.launch(automationRuntimePermissions())
                    }},
                )
            }

            SettingsSection("Notifications and surfaces") {
                JetpacsActionRow(
                    icon = Icons.Default.Notifications,
                    title = "Notification categories",
                    summary = "Choose sound, vibration, visibility, and interruption level",
                    actionLabel = "Open",
                    onAction = { launchSettings(appNotificationSettingsIntent(context)) },
                )
                HorizontalDivider()
                JetpacsActionRow(
                    icon = Icons.Default.Widgets,
                    title = "Widgets and Quick Settings tiles",
                    summary = "Add them from the launcher or system shade; Emacs assigns their content",
                )
            }

            SettingsSection("Pairing and diagnostics") {
                JetpacsActionRow(
                    icon = Icons.Default.Key,
                    title = "Pair another Emacs",
                    summary = "Show the local pairing token and ready-to-copy configuration line",
                    actionLabel = "Show",
                    onAction = { showPairing = true },
                )
                HorizontalDivider()
                JetpacsActionRow(
                    icon = Icons.Default.Security,
                    title = "Android app settings",
                    summary = "Permissions, battery use, storage, and defaults managed by Android",
                    actionLabel = "Open",
                    onAction = {
                        launchSettings(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
                    },
                )
                HorizontalDivider()
                val version = remember { jetpacsVersion(context) }
                JetpacsActionRow(
                    icon = Icons.Default.Cable,
                    title = "Jetpacs information",
                    summary = "Jetpacs $version · protocol $JETPACS_PROTOCOL_VERSION · Android ${Build.VERSION.SDK_INT}",
                )
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    if (showPairing) {
        Dialog(onDismissRequest = { showPairing = false }) {
            Surface(shape = MaterialTheme.shapes.medium) {
                Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState())) {
                    Text("Pair another Emacs", style = MaterialTheme.typography.titleMedium)
                    PairingTokenBlock(Modifier.padding(top = 12.dp))
                    TextButton(
                        onClick = { showPairing = false },
                        modifier = Modifier.align(Alignment.End),
                    ) { Text("Done") }
                }
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
        Card(Modifier.fillMaxWidth()) { Column { content() } }
    }
}

@Composable
private fun JetpacsSettingRow(
    icon: ImageVector,
    title: String,
    summary: String,
    status: String,
    granted: Boolean,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = {
            Column {
                Text(summary)
                Row(
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        if (granted) Icons.Default.CheckCircle else Icons.Default.ErrorOutline,
                        contentDescription = null,
                        tint = if (granted) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.error,
                    )
                    Text(status, style = MaterialTheme.typography.labelSmall)
                }
            }
        },
        leadingContent = { Icon(icon, contentDescription = null) },
        trailingContent = {
            if (actionLabel != null && onAction != null) {
                OutlinedButton(onClick = onAction) { Text(actionLabel) }
            }
        },
    )
}

@Composable
private fun JetpacsActionRow(
    icon: ImageVector,
    title: String,
    summary: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(summary) },
        leadingContent = { Icon(icon, contentDescription = null) },
        trailingContent = {
            if (actionLabel != null && onAction != null) {
                OutlinedButton(onClick = onAction) { Text(actionLabel) }
            }
        },
    )
}

private fun permissionStatus(perms: org.json.JSONObject, key: String): String =
    if (perms.optBoolean(key)) "Granted" else "Not granted"

private fun hasJetpacsNotificationPermission(context: Context): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
        PackageManager.PERMISSION_GRANTED

private fun automationRuntimePermissions(): Array<String> = buildList {
    add(Manifest.permission.ACCESS_COARSE_LOCATION)
    add(Manifest.permission.ACCESS_FINE_LOCATION)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
}.toTypedArray()

private fun appNotificationSettingsIntent(context: Context): Intent =
    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    }

private fun openEmacs(context: Context) {
    val launch = context.packageManager.getLaunchIntentForPackage(EmacsWaker.EMACS_PACKAGE)
    if (launch == null) {
        Toast.makeText(context, "Emacs is not installed", Toast.LENGTH_SHORT).show()
    } else {
        context.startActivity(launch)
    }
}

@Suppress("DEPRECATION")
private fun jetpacsVersion(context: Context): String =
    context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "?"
