package com.calebc42.jetpacs

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Scaffold spec renderer.
 *
 * The optional `drawer` block renders a ModalNavigationDrawer whose
 * open/close state is purely companion-local (like view switching, a
 * drawer gesture must never round-trip to Emacs). Drawer items dispatch
 * their action and close the drawer.
 *
 *   "drawer": {
 *     "header": "Jetpacs",
 *     "items": [ {"icon": "folder_open", "label": "Files",
 *                 "on_tap": {"builtin": "view.switch", "view": "files"}} ]
 *   }
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SduiScaffold(spec: JSONObject, onAction: (JSONObject) -> Unit) {
    val topBar = spec.optJSONObject("top_bar")
    val fab = spec.optJSONObject("fab")
    val bottomBar = spec.optJSONObject("bottom_bar")
    val drawer = spec.optJSONObject("drawer")
    val snackbar = spec.optString("snackbar", "")
    val body = spec.optJSONObject("body") ?: JSONObject()

    val snackbarHostState = remember { SnackbarHostState() }
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()

    // The screen.keep_on effector (SPEC §10): a window flag, held only
    // while this scaffold is composed — leaving Jetpacs UI clears it.
    val keepScreenOn by JetpacsRuntime.keepScreenOn.collectAsState()
    val hostView = androidx.compose.ui.platform.LocalView.current
    DisposableEffect(keepScreenOn, hostView) {
        hostView.keepScreenOn = keepScreenOn
        onDispose { hostView.keepScreenOn = false }
    }

    LaunchedEffect(snackbar) {
        if (snackbar.isNotEmpty()) {
            snackbarHostState.showSnackbar(snackbar)
        }
    }

    val scaffold: @Composable () -> Unit = {
        Scaffold(
            snackbarHost = { SnackbarHost(snackbarHostState) },
            topBar = {
                if (topBar != null) {
                    TopAppBar(
                        title = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                // Client-side connection dot: green when a
                                // handshaked Emacs is live, red when it's gone
                                // (cached surfaces still render while down).
                                val connected by JetpacsRuntime.connected.collectAsState()
                                Box(
                                    modifier = Modifier
                                        .size(10.dp)
                                        .clip(CircleShape)
                                        .background(
                                            if (connected) Color(0xFFA3BE8C)
                                            else Color(0xFFBF616A)
                                        )
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    text = topBar.optString("title", ""),
                                    maxLines = 1,
                                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false)
                                )
                                // Offline actions waiting in the Room queue:
                                // visible so queued taps aren't a mystery.
                                val queued by JetpacsRuntime.queuedCount.collectAsState()
                                if (queued > 0) {
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        "· $queued queued",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1
                                    )
                                }
                            }
                        },
                        navigationIcon = {
                            val navIcon = topBar.optString("nav_icon", "")
                            val navAction = topBar.optJSONObject("nav_action")
                            when {
                                navIcon.isNotEmpty() -> {
                                    IconButton(onClick = { if (navAction != null) onAction(navAction) }) {
                                        Icon(IconMap.get(navIcon), contentDescription = "Navigate")
                                    }
                                }
                                drawer != null -> {
                                    // Drawer present and no explicit nav icon:
                                    // show the hamburger, toggled locally.
                                    IconButton(onClick = { scope.launch { drawerState.open() } }) {
                                        Icon(IconMap.get("menu"), contentDescription = "Menu")
                                    }
                                }
                            }
                        },
                        actions = {
                            val actionsArray = topBar.optJSONArray("actions")
                            if (actionsArray != null) {
                                val config = androidx.compose.ui.platform.LocalConfiguration.current
                                Row(
                                    modifier = Modifier
                                        .widthIn(max = (config.screenWidthDp * 0.55).dp)
                                        .horizontalScroll(rememberScrollState())
                                ) {
                                    for (i in 0 until actionsArray.length()) {
                                        val actionObj = actionsArray.optJSONObject(i) ?: continue
                                        val icon = actionObj.optString("icon", "")
                                        val action = actionObj.optJSONObject("on_tap")
                                        if (icon.isNotEmpty()) {
                                            IconButton(onClick = { if (action != null) onAction(action) }) {
                                                Icon(IconMap.get(icon), contentDescription = "Action")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    )
                }
            },
            floatingActionButton = {
                if (fab != null) {
                    val icon = fab.optString("icon", "")
                    val label = fab.optString("label", "")
                    val action = fab.optJSONObject("on_tap")
                    val extended = fab.optBoolean("extended", false)
                    if (extended && label.isNotEmpty()) {
                        ExtendedFloatingActionButton(
                            onClick = { if (action != null) onAction(action) },
                            icon = { Icon(IconMap.get(icon), contentDescription = null) },
                            text = { Text(label) }
                        )
                    } else if (icon.isNotEmpty()) {
                        FloatingActionButton(onClick = { if (action != null) onAction(action) }) {
                            Icon(IconMap.get(icon), contentDescription = null)
                        }
                    }
                }
            },
            bottomBar = {
                Column {
                    val floatingToolbar = spec.optJSONArray("floating_toolbar")
                    if (floatingToolbar != null) {
                        Surface(
                            tonalElevation = 3.dp,
                            shadowElevation = 4.dp,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier
                                    .horizontalScroll(rememberScrollState())
                                    .padding(horizontal = 4.dp, vertical = 2.dp),
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                for (i in 0 until floatingToolbar.length()) {
                                    val item = floatingToolbar.optJSONObject(i) ?: continue
                                    val icon = item.optString("icon", "")
                                    val label = item.optString("label", "")
                                    val action = item.optJSONObject("on_tap")
                                    ToolbarChip(
                                        icon = icon,
                                        label = label,
                                        onClick = { if (action != null) onAction(action) }
                                    )
                                }
                            }
                        }
                    }
                    if (bottomBar != null) {
                        NavigationBar {
                            val items = bottomBar.optJSONArray("items")
                            if (items != null) {
                                for (i in 0 until items.length()) {
                                    val item = items.optJSONObject(i) ?: continue
                                    val icon = item.optString("icon", "")
                                    val label = item.optString("label", "")
                                    val action = item.optJSONObject("on_tap")
                                    val selected = item.optBoolean("selected", false)
                                    NavigationBarItem(
                                        selected = selected,
                                        onClick = { if (action != null) onAction(action) },
                                        icon = { Icon(IconMap.get(icon), contentDescription = null) },
                                        label = if (label.isNotEmpty()) { { Text(label) } } else null
                                    )
                                }
                            }
                        }
                    }
                }
            }
        ) { innerPadding ->
            // With edge-to-edge on, the window never resizes for the soft
            // keyboard, and Scaffold's innerPadding only accounts for its own
            // bars — so keyboard-adjacent body content (the eval input, the
            // completion strip, doc line) would sit UNDER the IME. imePadding
            // lifts the body clear of the keyboard while the bottom bar stays
            // put behind it; consumeWindowInsets keeps descendants with their
            // own imePadding (the full-chrome editor) from double-padding.
            val bodyModifier = Modifier
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .imePadding()
            val onRefresh = spec.optJSONObject("on_refresh")
            if (onRefresh != null) {
                // Pull-to-refresh on tab views. There's no completion signal
                // from Emacs, so the spinner self-clears after a beat — the
                // refreshed surface push lands in roughly the same window.
                var refreshing by remember { mutableStateOf(false) }
                LaunchedEffect(refreshing) {
                    if (refreshing) {
                        delay(1200)
                        refreshing = false
                    }
                }
                PullToRefreshBox(
                    isRefreshing = refreshing,
                    onRefresh = {
                        refreshing = true
                        onAction(onRefresh)
                    },
                    modifier = bodyModifier
                ) {
                    SduiNode(node = body, onAction = onAction)
                }
            } else {
                SduiNode(
                    node = body,
                    modifier = bodyModifier,
                    onAction = onAction
                )
            }
        }
    }

    if (drawer != null) {
        ModalNavigationDrawer(
            drawerState = drawerState,
            drawerContent = {
                ModalDrawerSheet(modifier = Modifier.fillMaxWidth(0.75f)) {
                    val header = drawer.optString("header", "")
                    if (header.isNotEmpty()) {
                        Text(
                            header,
                            style = MaterialTheme.typography.titleLarge,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                    val items = drawer.optJSONArray("items")
                    if (items != null) {
                        for (i in 0 until items.length()) {
                            val item = items.optJSONObject(i) ?: continue
                            val icon = item.optString("icon", "")
                            val label = item.optString("label", "")
                            val action = item.optJSONObject("on_tap")
                            val selected = item.optBoolean("selected", false)
                            NavigationDrawerItem(
                                label = { Text(label) },
                                selected = selected,
                                icon = if (icon.isNotEmpty()) {
                                    { Icon(IconMap.get(icon), contentDescription = null) }
                                } else null,
                                onClick = {
                                    scope.launch { drawerState.close() }
                                    if (action != null) onAction(action)
                                }
                            )
                        }
                    }
                }
            }
        ) { scaffold() }
    } else {
        scaffold()
    }
}