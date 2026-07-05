package com.calebc42.eabp

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * A drag-to-reorder list for org headings in refile mode.
 *
 * Vertical drag → reorder among siblings.
 * Horizontal drag → promote (left) / demote (right), shown as indent change.
 * On drop the `on_reorder` action is dispatched with `from_pos`, `after_pos`,
 * and `new_level`.
 */
@Composable
fun ReorderableList(
    node: JSONObject,
    dispatch: (JSONObject) -> Unit,
    modifier: Modifier = Modifier
) {
    val onReorder = node.optJSONObject("on_reorder") ?: return
    val itemsArray = node.optJSONArray("items") ?: return

    data class HeadingItem(
        val label: String,
        val level: Int,
        val pos: Int,
        val file: String
    )

    // Parse items from JSON — re-parse when the node changes
    var items by remember(itemsArray.toString()) {
        mutableStateOf(List(itemsArray.length()) { i ->
            val obj = itemsArray.getJSONObject(i)
            HeadingItem(
                label = obj.optString("label"),
                level = obj.optInt("level", 1),
                pos = obj.optInt("pos"),
                file = obj.optString("file")
            )
        })
    }

    val listState = rememberLazyListState()
    val haptic = LocalHapticFeedback.current
    val density = LocalDensity.current

    // Horizontal distance (in px) that equals one level change
    val levelStepPx = with(density) { 40.dp.toPx() }

    // ── Drag state ──────────────────────────────────────────────────────────
    var draggedIndex by remember { mutableStateOf<Int?>(null) }
    var dragOffsetY by remember { mutableFloatStateOf(0f) }
    var dragOffsetX by remember { mutableFloatStateOf(0f) }
    // The original level when dragging started (before horizontal adjustments)
    var dragOriginalLevel by remember { mutableIntStateOf(1) }

    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 4.dp)
    ) {
        itemsIndexed(items, key = { _, item -> "${item.pos}_${item.file}" }) { index, item ->
            val isDragged = draggedIndex == index

            // Calculate visual level for horizontal drag feedback
            val visualLevel = if (isDragged) {
                (dragOriginalLevel + (dragOffsetX / levelStepPx).toInt()).coerceIn(1, 10)
            } else {
                item.level
            }

            val elevation by animateDpAsState(
                targetValue = if (isDragged) 8.dp else 0.dp,
                label = "drag_elevation"
            )

            val startPadding = ((visualLevel - 1) * 24).dp

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(
                        if (isDragged) {
                            Modifier
                                .offset { IntOffset(0, dragOffsetY.roundToInt()) }
                                .zIndex(1f)
                        } else {
                            Modifier.animateItem()
                        }
                    )
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .shadow(elevation, RoundedCornerShape(8.dp))
                        .background(
                            if (isDragged) MaterialTheme.colorScheme.surfaceContainerHigh
                            else MaterialTheme.colorScheme.surface,
                            RoundedCornerShape(8.dp)
                        )
                        .padding(start = startPadding)
                ) {
                // ── Drag handle ─────────────────────────────────────────────
                Icon(
                    IconMap.get("drag_handle"),
                    contentDescription = "Drag to reorder",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .pointerInput(index) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = {
                                    draggedIndex = index
                                    dragOriginalLevel = item.level
                                    dragOffsetY = 0f
                                    dragOffsetX = 0f
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                },
                                onDrag = { change, dragAmount ->
                                    change.consume()
                                    dragOffsetY += dragAmount.y
                                    dragOffsetX += dragAmount.x

                                    // ── Vertical swap detection ─────────────
                                    val dragged = draggedIndex ?: return@detectDragGesturesAfterLongPress
                                    val layoutInfo = listState.layoutInfo
                                    val draggedInfo = layoutInfo.visibleItemsInfo
                                        .firstOrNull { it.index == dragged }
                                        ?: return@detectDragGesturesAfterLongPress

                                    val draggedCenter = draggedInfo.offset + draggedInfo.size / 2 + dragOffsetY.roundToInt()

                                    // Find the item whose area the dragged center falls in
                                    val targetInfo = layoutInfo.visibleItemsInfo.firstOrNull { info ->
                                        info.index != dragged &&
                                            draggedCenter in info.offset..(info.offset + info.size)
                                    }

                                    if (targetInfo != null && targetInfo.index != dragged) {
                                        val targetIndex = targetInfo.index
                                        val changeInBaseOffset = if (targetIndex < dragged) {
                                            targetInfo.offset - draggedInfo.offset
                                        } else {
                                            (targetInfo.offset + targetInfo.size) - (draggedInfo.offset + draggedInfo.size)
                                        }
                                        
                                        items = items.toMutableList().apply {
                                            add(targetIndex, removeAt(dragged))
                                        }
                                        // Adjust offset so the item doesn't jump
                                        dragOffsetY -= changeInBaseOffset
                                        draggedIndex = targetIndex
                                    }
                                },
                                onDragEnd = {
                                    val droppedIndex = draggedIndex
                                    if (droppedIndex != null) {
                                        val droppedItem = items[droppedIndex]
                                        val newLevel = (dragOriginalLevel + (dragOffsetX / levelStepPx).toInt()).coerceIn(1, 10)

                                        // Build the after_pos: position of the heading
                                        // just before the drop position, or 0 for first
                                        val afterPos = if (droppedIndex > 0) {
                                            items[droppedIndex - 1].pos
                                        } else {
                                            0
                                        }

                                        // Dispatch the action with reorder details
                                        val action = JSONObject(onReorder.toString())
                                        val args = action.optJSONObject("args") ?: JSONObject()
                                        args.put("from_pos", droppedItem.pos)
                                        args.put("after_pos", afterPos)
                                        args.put("new_level", newLevel)
                                        action.put("args", args)
                                        dispatch(action)

                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    }
                                    draggedIndex = null
                                    dragOffsetY = 0f
                                    dragOffsetX = 0f
                                },
                                onDragCancel = {
                                    draggedIndex = null
                                    dragOffsetY = 0f
                                    dragOffsetX = 0f
                                }
                            )
                        }
                        .padding(12.dp)
                )

                // ── Heading text ────────────────────────────────────────────
                Text(
                    text = item.label,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .weight(1f)
                        .padding(vertical = 14.dp, horizontal = 8.dp)
                )
            }

                }
                
                // Subtle divider between items
                if (index < items.size - 1) {
                    HorizontalDivider(
                        modifier = Modifier.padding(start = startPadding + 48.dp),
                        color = if (isDragged) Color.Transparent else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)
                    )
                }
            }
    }
}
