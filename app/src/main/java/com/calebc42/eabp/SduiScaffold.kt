package com.calebc42.eabp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
 *     "header": "EABP",
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
                                val connected by EabpRuntime.connected.collectAsState()
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
                                Text(topBar.optString("title", ""))
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
        ) { innerPadding ->
            SduiNode(
                node = body,
                modifier = Modifier.padding(innerPadding),
                onAction = onAction
            )
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