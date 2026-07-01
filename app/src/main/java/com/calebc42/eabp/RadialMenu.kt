package com.calebc42.eabp

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer

import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** Max segments visible per radial level before auto-pagination kicks in. */
private const val MAX_SEGMENTS_PER_LEVEL = 10

/**
 * If [items] has more than [MAX_SEGMENTS_PER_LEVEL] entries, return the first
 * (MAX-1) real items plus a synthetic "More ▸" entry whose `children` array
 * contains the overflow.  Otherwise return [items] unchanged.
 */
private fun paginate(items: List<JSONObject>): List<JSONObject> {
    if (items.size <= MAX_SEGMENTS_PER_LEVEL) return items
    val visible = items.take(MAX_SEGMENTS_PER_LEVEL - 1)
    val overflow = items.drop(MAX_SEGMENTS_PER_LEVEL - 1)
    val moreEntry = JSONObject().apply {
        put("key", "…")
        put("label", "More")
        put("is_prefix", true)
        put("children", JSONArray().apply {
            overflow.forEach { put(it) }
        })
    }
    return visible + moreEntry
}

/**
 * Full-screen radial pie menu overlay.
 *
 * Two modes:
 * 1. **Speed Dial** — category circles arranged in a semicircle from the bottom-right.
 * 2. **Pie Menu** — radial segments for bindings within a selected category.
 */
@Composable
fun RadialMenu(
    spec: JSONObject,
    onAction: (JSONObject) -> Unit,
    onDismiss: () -> Unit,
) {
    val categories = remember(spec) { spec.optJSONArray("categories") ?: JSONArray() }
    val centerLabel = remember(spec) { spec.optString("center_label", "") }

    // Navigation state: null = speed dial, non-null = pie menu for that category
    var activeCategory by remember { mutableStateOf<JSONObject?>(null) }
    // Stack for drill-in (prefix keys with children)
    val navStack = remember { mutableStateListOf<List<JSONObject>>() }
    var currentBindings by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var currentTitle by remember { mutableStateOf("") }

    // --- Mode transitions ---
    val showSpeedDial = activeCategory == null
    val showPie = activeCategory != null

    Box(modifier = Modifier.fillMaxSize()) {
        // Scrim (visual only — dismiss is handled by SpeedDial/PieMenu)
        Canvas(modifier = Modifier.fillMaxSize()) {
            drawRect(Color.Black.copy(alpha = 0.5f))
        }

        // --- Speed Dial Mode ---
        AnimatedVisibility(
            visible = showSpeedDial,
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(150)),
        ) {
            SpeedDial(
                categories = categories,
                onCategoryTap = { cat ->
                    activeCategory = cat
                    navStack.clear()
                    currentBindings = paginate(cat.optJSONArray("bindings").toBindingList())
                    currentTitle = cat.optString("label", "")
                },
                onDismiss = onDismiss,
            )
        }

        // --- Pie Menu Mode ---
        AnimatedVisibility(
            visible = showPie,
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(150)),
        ) {
            if (activeCategory != null) {
                PieMenu(
                    bindings = currentBindings,
                    title = currentTitle,
                    centerLabel = centerLabel,
                    canGoBack = navStack.isNotEmpty(),
                    onSegmentTap = { binding ->
                        val isPrefix = binding.optBoolean("is_prefix", false)
                        val children = binding.optJSONArray("children")
                        if (isPrefix && children != null && children.length() > 0) {
                            // Drill in: push current level, swap to children
                            navStack.add(currentBindings)
                            currentBindings = paginate(children.toBindingList())
                            currentTitle = binding.optString("label", currentTitle)
                        } else {
                            val action = binding.optJSONObject("action")
                            if (action != null) onAction(action)
                        }
                    },
                    onCenterTap = {
                        if (navStack.isNotEmpty()) {
                            // Pop back
                            currentBindings = navStack.removeLast()
                            currentTitle = activeCategory!!.optString("label", "")
                        } else {
                            // Back to speed dial
                            activeCategory = null
                        }
                    },
                    onOutsideTap = onDismiss,
                )
            }
        }
    }
}

// ────────────────────────────────────────────────────────────────
// Speed Dial
// ────────────────────────────────────────────────────────────────

@Composable
private fun SpeedDial(
    categories: JSONArray,
    onCategoryTap: (JSONObject) -> Unit,
    onDismiss: () -> Unit,
) {
    val count = categories.length()
    // Staggered appearance flags
    val visible = remember { mutableStateListOf<Boolean>().apply { repeat(count) { add(false) } } }
    LaunchedEffect(count) {
        for (i in 0 until count) {
            visible[i] = true
            delay(50)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTapGestures { onDismiss() }
            },
    ) {
        for (i in 0 until count) {
            val cat = categories.getJSONObject(i)
            val label = cat.optString("label", "?")

            // Quarter-circle arc from left (PI) to up (3*PI/2),
            // anchored at bottom-right so items fan upward-left.
            val angleRange = PI / 2  // 90° arc
            val startAngle = PI      // start at left
            val step = if (count > 1) angleRange / (count - 1) else 0.0
            val angle = startAngle + step * i

            val radius = 140.dp
            val density = LocalDensity.current
            val radiusPx = with(density) { radius.toPx() }

            // Offset from anchor (bottom-right corner)
            val dx = (cos(angle) * radiusPx).toFloat()
            val dy = (sin(angle) * radiusPx).toFloat()

            val scale by animateFloatAsState(
                targetValue = if (visible.getOrElse(i) { false }) 1f else 0f,
                animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMedium),
                label = "speedDial_$i",
            )

            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 24.dp, bottom = 24.dp)
                    .offset {
                        IntOffset(
                            x = dx.roundToInt(),
                            y = dy.roundToInt(),
                        )
                    }
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        alpha = scale
                    },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = label,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    SmallFloatingActionButton(
                        onClick = { onCategoryTap(cat) },
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    ) {
                        val icon = cat.optString("icon", "")
                        if (icon.isNotEmpty()) {
                            androidx.compose.material3.Icon(
                                imageVector = IconMap.get(icon),
                                contentDescription = label,
                            )
                        } else {
                            Text(
                                text = label.take(2),
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                }
            }
        }
    }
}

// ────────────────────────────────────────────────────────────────
// Pie Menu
// ────────────────────────────────────────────────────────────────

@Composable
private fun PieMenu(
    bindings: List<JSONObject>,
    title: String,
    centerLabel: String,
    canGoBack: Boolean,
    onSegmentTap: (JSONObject) -> Unit,
    onCenterTap: () -> Unit,
    onOutsideTap: () -> Unit,
) {
    val segmentCount = bindings.size
    if (segmentCount == 0) {
        onCenterTap()
        return
    }

    val primaryContainer = MaterialTheme.colorScheme.primaryContainer
    val primary = MaterialTheme.colorScheme.primary
    val onPrimary = MaterialTheme.colorScheme.onPrimary
    val onPrimaryContainer = MaterialTheme.colorScheme.onPrimaryContainer
    val surface = MaterialTheme.colorScheme.surface
    val onSurface = MaterialTheme.colorScheme.onSurface

    val textMeasurer = rememberTextMeasurer()

    // Animate scale for open
    var targetScale by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) { targetScale = 1f }
    val scale by animateFloatAsState(
        targetValue = targetScale,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMedium),
        label = "pieScale",
    )

    // Track tapped segment for highlight
    var tappedSegment by remember { mutableIntStateOf(-1) }

    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .pointerInput(bindings) {
                detectTapGestures { offset ->
                    val cx = size.width / 2f
                    val cy = size.height / 2f
                    val dx = offset.x - cx
                    val dy = offset.y - cy
                    val dist = sqrt(dx * dx + dy * dy)

                    val outerRadius = min(size.width, size.height) * 0.38f
                    val innerRadius = outerRadius * 0.25f

                    if (dist < innerRadius) {
                        onCenterTap()
                        return@detectTapGestures
                    }
                    if (dist > outerRadius) {
                        onOutsideTap()
                        return@detectTapGestures
                    }

                    // Convert to angle (degrees), clockwise from top
                    var angleDeg = Math.toDegrees(atan2(dy.toDouble(), dx.toDouble()))
                        .toFloat()
                    // Shift so 0° = top (our start is -90°)
                    angleDeg = (angleDeg + 90f + 360f) % 360f

                    val gapDeg = 2f
                    val sweepDeg = 360f / segmentCount - gapDeg
                    val segIdx = (angleDeg / (360f / segmentCount)).toInt()
                        .coerceIn(0, segmentCount - 1)

                    tappedSegment = segIdx
                    onSegmentTap(bindings[segIdx])
                }
            },
    ) {
        val cx = size.width / 2f
        val cy = size.height / 2f
        val outerRadius = min(size.width, size.height) * 0.38f
        val innerRadius = outerRadius * 0.25f
        val gapDeg = 2f
        val sweepPerSegment = 360f / segmentCount
        val sweepDeg = sweepPerSegment - gapDeg

        // Draw arc segments
        for (i in 0 until segmentCount) {
            // Start angle: -90 (top) + i * sweepPerSegment + gap/2
            val startAngle = -90f + i * sweepPerSegment + gapDeg / 2f
            val color = if (i == tappedSegment) primary else primaryContainer

            drawArc(
                color = color,
                startAngle = startAngle,
                sweepAngle = sweepDeg,
                useCenter = true,
                topLeft = Offset(cx - outerRadius, cy - outerRadius),
                size = Size(outerRadius * 2, outerRadius * 2),
            )

            // Cut out inner circle by drawing over with the scrim color
            // (We'll draw the center circle on top anyway)
        }

        // Inner circle (center button)
        drawCircle(
            color = surface,
            radius = innerRadius,
            center = Offset(cx, cy),
        )

        // Draw labels on each segment
        for (i in 0 until segmentCount) {
            val binding = bindings[i]
            val key = binding.optString("key", "")
            val label = binding.optString("label", "")
            val isPrefix = binding.optBoolean("is_prefix", false)
            val midAngle = -90f + i * sweepPerSegment + sweepPerSegment / 2f
            val midAngleRad = Math.toRadians(midAngle.toDouble())
            val labelRadius = outerRadius * 0.65f
            val lx = cx + (cos(midAngleRad) * labelRadius).toFloat()
            val ly = cy + (sin(midAngleRad) * labelRadius).toFloat()

            val textColor = if (i == tappedSegment) onPrimary else onPrimaryContainer

            // Key in bold
            val keyText = if (isPrefix) "$key ▸" else key
            drawSegmentLabel(
                textMeasurer = textMeasurer,
                key = keyText,
                label = label,
                center = Offset(lx, ly),
                textColor = textColor,
            )
        }

        // Center label
        val centerText = if (canGoBack) "← Back" else title.ifEmpty { centerLabel }
        val centerStyle = TextStyle(
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            textAlign = TextAlign.Center,
            color = onSurface,
        )
        val measured = textMeasurer.measure(
            text = centerText,
            style = centerStyle,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            constraints = androidx.compose.ui.unit.Constraints(
                maxWidth = (innerRadius * 1.6f).toInt(),
            ),
        )
        drawText(
            textLayoutResult = measured,
            topLeft = Offset(
                cx - measured.size.width / 2f,
                cy - measured.size.height / 2f,
            ),
        )
    }
}

private fun DrawScope.drawSegmentLabel(
    textMeasurer: TextMeasurer,
    key: String,
    label: String,
    center: Offset,
    textColor: Color,
) {
    val keyStyle = TextStyle(
        fontSize = 14.sp,
        fontWeight = FontWeight.Bold,
        textAlign = TextAlign.Center,
        color = textColor,
    )
    val labelStyle = TextStyle(
        fontSize = 10.sp,
        fontWeight = FontWeight.Normal,
        textAlign = TextAlign.Center,
        color = textColor,
    )

    val maxW = 80

    val keyMeasured = textMeasurer.measure(
        text = key,
        style = keyStyle,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        constraints = androidx.compose.ui.unit.Constraints(maxWidth = (maxW * density).toInt()),
    )
    val labelMeasured = textMeasurer.measure(
        text = label,
        style = labelStyle,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        constraints = androidx.compose.ui.unit.Constraints(maxWidth = (maxW * density).toInt()),
    )

    val totalH = keyMeasured.size.height + labelMeasured.size.height + 2
    val topY = center.y - totalH / 2f

    drawText(
        textLayoutResult = keyMeasured,
        topLeft = Offset(center.x - keyMeasured.size.width / 2f, topY),
    )
    drawText(
        textLayoutResult = labelMeasured,
        topLeft = Offset(
            center.x - labelMeasured.size.width / 2f,
            topY + keyMeasured.size.height + 2f,
        ),
    )
}

// ────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────

private fun JSONArray?.toBindingList(): List<JSONObject> {
    if (this == null) return emptyList()
    return (0 until length()).map { getJSONObject(it) }
}
