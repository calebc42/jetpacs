package com.calebc42.jetpacs

import androidx.compose.foundation.layout.size
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * A small chip-button for keyboard-adjacent toolbars. Shared vocabulary:
 * the renderer's editor chrome (SduiScaffold), the data-driven toolbar
 * interpreter (SduiToolbar), and host-registered native toolbars
 * (JetpacsToolbars) all build from it.
 */
@Composable
fun ToolbarChip(
    icon: String,
    label: String,
    onClick: () -> Unit
) {
    AssistChip(
        onClick = onClick,
        label = { Text(label, style = MaterialTheme.typography.labelSmall) },
        leadingIcon = {
            Icon(
                IconMap.get(icon),
                contentDescription = label,
                modifier = Modifier.size(18.dp)
            )
        }
    )
}
