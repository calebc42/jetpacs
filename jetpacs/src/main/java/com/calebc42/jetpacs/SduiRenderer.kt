package com.calebc42.jetpacs

import android.content.Context
import android.content.Intent
import coil.compose.AsyncImage
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Every node type this build renders — the exact set of `when (type)`
 * cases in [SduiNode], published to the client in `session.welcome` as
 * `node_types` (SPEC §3, §9) so a newer client can detect a node this
 * companion predates and render a fallback instead of relying on the
 * unknown-node degradation.
 *
 * INVARIANT: this set and the `when` in [SduiNode] change together. The
 * `SduiRendererNodeTypesTest` fails if a `when` case is added without a
 * matching entry here.
 */
val SDUI_NODE_TYPES: Set<String> = setOf(
    // Layout containers
    "column", "row", "box", "surface", "card", "collapsible",
    "lazy_column", "flow_row", "divider", "spacer", "scaffold",
    "reorderable_list", "table", "tabs",
    // Content
    "text", "rich_text", "date_stamp", "menu", "section_header",
    "empty_state", "icon", "image", "progress",
    // Visualization
    "chart", "canvas", "month_grid",
    // Input
    "text_input", "editor", "checkbox", "switch", "enum_list",
    "date_button", "time_button", "slider", "button", "icon_button",
    "chip", "assist_chip", "badge",
)

/**
 * The SDUI dispatcher: routes a spec node by its `t` discriminator.
 *
 * Layout containers and trivial one-liner controls render inline here;
 * the substantial node families live in sibling files —
 * [SduiInputNodes.kt] (text fields, editor, toggles, pickers) and
 * [SduiContentNodes.kt] (text, rich text, date stamp, menu, headers).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SduiNode(node: JSONObject, surfaceId: String = "", revision: Int = 0, modifier: Modifier = Modifier, onAction: ((JSONObject) -> Unit)? = null) {
    val context = LocalContext.current
    val type = node.optString("t")

    val rawDispatch = onAction ?: { action: JSONObject ->
        val intent = Intent(context, ActionReceiver::class.java).apply {
            this.action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, surfaceId)
            putExtra(ActionReceiver.EXTRA_REVISION, revision)
            putExtra(ActionReceiver.EXTRA_ACTION, action.toString())
        }
        context.sendBroadcast(intent)
    }
    // SPEC §5 ordering guarantee: every diverged stateful-node value reaches
    // the wire as `state.changed` BEFORE any `event.action` that might read
    // it. The debounced publishers (text_input, editor publish_state)
    // register flushers by node id; draining them here — synchronously, on
    // the same thread that sends the action — preserves order at the
    // receiver, so a handler reading `jetpacs-ui-state` never races the
    // 250ms debounce.
    val dispatch = { action: JSONObject ->
        PendingStateFlush.flushAll()
        rawDispatch(action)
    }

    val baseModifier = modifier.then(
        if (node.has("padding")) Modifier.padding(node.optInt("padding").dp) else Modifier
    )

    when (type) {
        // ── Layout containers ────────────────────────────────────────────
        "column" -> {
            val scrollable = node.optBoolean("scroll", false)
            // Columns/rows fill the parent width by default so alignment has a
            // width to work in; `fill:false` opts out (wrapContent) for a
            // content-sized column nested in a row — the alternative to giving
            // it a `weight`.
            val fill = node.optBoolean("fill", true)
            val mod = (if (fill) baseModifier.fillMaxWidth() else baseModifier).let {
                if (scrollable) it.verticalScroll(rememberScrollState()) else it
            }
            Column(
                modifier = mod,
                verticalArrangement = Arrangement.spacedBy(node.optInt("spacing", 8).dp),
                horizontalAlignment = when (node.optString("align")) {
                    "center" -> Alignment.CenterHorizontally
                    "end" -> Alignment.End
                    else -> Alignment.Start
                }
            ) {
                WeightedChildren(node.optJSONArray("children"), surfaceId, revision, dispatch) { weight ->
                    Modifier.weight(weight)
                }
            }
        }
        "row" -> {
            // `scroll` keeps the children on one line and pans sideways on
            // overflow (a chip rail). Weights are meaningless with unbounded
            // width, so a scrolling row renders its children unweighted.
            val scroll = node.optBoolean("scroll")
            val fill = node.optBoolean("fill", true)   // `fill:false` -> wrapContent
            Row(
                modifier = if (scroll)
                    baseModifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                else if (fill) baseModifier.fillMaxWidth()
                else baseModifier,
                horizontalArrangement = Arrangement.spacedBy(node.optInt("spacing", 8).dp),
                verticalAlignment = when (node.optString("align")) {
                    "top" -> Alignment.Top
                    "bottom" -> Alignment.Bottom
                    else -> Alignment.CenterVertically
                }
            ) {
                if (scroll) {
                    RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
                } else {
                    WeightedChildren(node.optJSONArray("children"), surfaceId, revision, dispatch) { weight ->
                        Modifier.weight(weight)
                    }
                }
            }
        }
        "box" -> {
            val alignRaw = node.optString("alignment", "top_start")
            val actionJson = node.optJSONObject("on_tap")
            val alignment = when (alignRaw) {
                "center" -> Alignment.Center
                "center_start" -> Alignment.CenterStart
                "center_end" -> Alignment.CenterEnd
                "top_center" -> Alignment.TopCenter
                "bottom_center" -> Alignment.BottomCenter
                else -> Alignment.TopStart
            }
            val boxModifier = (if (actionJson != null) {
                baseModifier.clickable { dispatch(actionJson) }
            } else baseModifier).then(containerModifier(node, RectangleShape))
            Box(modifier = boxModifier, contentAlignment = alignment) {
                RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
            }
        }
        "surface" -> {
            // color (theme token or hex), shape, elevation, and fill were
            // silently ignored for a long time — the month grid's selected-day
            // highlight never rendered because of it.
            val color = resolveColor(node.optString("color"))
                .takeIf { it != Color.Unspecified } ?: MaterialTheme.colorScheme.surface
            val shape = when (node.optString("shape")) {
                "rounded" -> RoundedCornerShape(8.dp)
                "rounded_small" -> RoundedCornerShape(4.dp)
                "circle" -> CircleShape
                else -> RectangleShape
            }
            val fillMod = if (node.optBoolean("fill")) Modifier.fillMaxWidth() else Modifier
            Surface(
                modifier = baseModifier.then(fillMod).then(containerModifier(node, shape)),
                color = color,
                shape = shape,
                tonalElevation = node.optInt("elevation", 0).dp
            ) {
                RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
            }
        }
        "card" -> {
            val actionJson = node.optJSONObject("on_tap")
            val swipeJson = node.optJSONObject("on_swipe")
            // Per-side swipe actions (SPEC §9): {icon, label, color?,
            // on_trigger}. When present they win over the legacy
            // single-action on_swipe.
            val swipeStart = node.optJSONObject("swipe_start")
            val swipeEnd = node.optJSONObject("swipe_end")
            val cardContent: @Composable () -> Unit = {
                androidx.compose.material3.ElevatedCard(
                    modifier = baseModifier
                        .fillMaxWidth()
                        .then(containerModifier(node, RoundedCornerShape(12.dp)))
                        .clickable(enabled = actionJson != null) { if (actionJson != null) dispatch(actionJson) }
                ) {
                    Box(modifier = Modifier.padding(16.dp)) {
                        RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
                    }
                }
            }
            if (swipeStart != null || swipeEnd != null) {
                SwipeActionCard(swipeStart, swipeEnd, dispatch) { cardContent() }
            } else if (swipeJson != null) {
                val density = LocalDensity.current
                val thresholdPx = with(density) { 80.dp.toPx() }
                var offsetX by remember { mutableStateOf(0f) }
                var dispatched by remember { mutableStateOf(false) }
                val animatedOffset by animateFloatAsState(
                    targetValue = offsetX,
                    animationSpec = tween(durationMillis = if (dispatched) 200 else 0),
                    label = "swipe-offset"
                )
                val bgAlpha = (abs(animatedOffset) / thresholdPx).coerceIn(0f, 1f)
                Box {
                    // Background hint
                    Box(
                        Modifier
                            .matchParentSize()
                            .padding(vertical = 4.dp)
                            .background(
                                Color(0xFF4CAF50).copy(alpha = bgAlpha * 0.8f),
                                RoundedCornerShape(8.dp)
                            )
                            .padding(horizontal = 20.dp),
                        contentAlignment = if (animatedOffset >= 0) Alignment.CenterStart else Alignment.CenterEnd
                    ) {
                        if (bgAlpha > 0.01f) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "Cycle TODO",
                                tint = Color.White.copy(alpha = bgAlpha)
                            )
                        }
                    }
                    // Card with drag offset
                    Box(
                        modifier = Modifier
                            .offset { IntOffset(animatedOffset.roundToInt(), 0) }
                            .pointerInput(swipeJson) {
                                detectHorizontalDragGestures(
                                    onDragEnd = {
                                        offsetX = 0f
                                        dispatched = false
                                    },
                                    onDragCancel = {
                                        offsetX = 0f
                                        dispatched = false
                                    },
                                    onHorizontalDrag = { _, dragAmount ->
                                        if (!dispatched) {
                                            offsetX += dragAmount
                                            if (abs(offsetX) > thresholdPx) {
                                                dispatched = true
                                                dispatch(swipeJson)
                                                offsetX = 0f
                                            }
                                        }
                                    }
                                )
                            }
                    ) {
                        cardContent()
                    }
                }
            } else {
                cardContent()
            }
        }
        "collapsible" -> {
            SduiCollapsible(node, surfaceId, revision, baseModifier, dispatch)
        }
        "tabs" -> {
            SduiTabs(node, surfaceId, revision, baseModifier, dispatch)
        }
        "month_grid" -> {
            SduiMonthGrid(node, baseModifier, dispatch)
        }
        "lazy_column" -> {
            val children = node.optJSONArray("children")
            if (children != null) {
                // scroll_here: the server marks one child as the scroll
                // target (a REPL's input row, a search hit's line). The
                // list scrolls there on first show and whenever the
                // target's index changes (new transcript output shifting
                // the input row down); a re-push that leaves the index
                // unchanged never disturbs the user's scroll position.
                var scrollTarget = -1
                for (i in 0 until children.length()) {
                    if (children.optJSONObject(i)?.optBoolean("scroll_here") == true) {
                        scrollTarget = i
                        break
                    }
                }
                val listState = rememberLazyListState()
                if (scrollTarget >= 0) {
                    LaunchedEffect(scrollTarget) {
                        listState.scrollToItem(scrollTarget)
                    }
                }
                // Stable per-child keys so structural pushes preserve each
                // row's identity (focus, scroll, in-flight edits) instead of
                // reusing slot compositions by position. See lazyChildKeys.
                val keys = remember(children) { lazyChildKeys(children) }
                LazyColumn(state = listState, modifier = baseModifier.fillMaxSize()) {
                    items(count = children.length(), key = { keys[it] }) { i ->
                        val child = children.optJSONObject(i)
                        // animateItem: with stable keys (above), inserts/removes/
                        // moves animate instead of popping, and unchanged rows on a
                        // re-push don't animate at all (K1b payoff).
                        if (child != null) SduiNode(child, surfaceId, revision, Modifier.animateItem(), dispatch)
                    }
                }
            }
        }
        "flow_row" -> {
            // Like `row`, but children wrap onto new lines instead of running
            // off-screen — the right container for chip/tag rows.
            val spacing = node.optInt("spacing", 8)
            FlowRow(
                modifier = baseModifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(spacing.dp),
                verticalArrangement = Arrangement.spacedBy(node.optInt("run_spacing", spacing).dp)
            ) {
                RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
            }
        }
        "divider" -> {
            HorizontalDivider(
                modifier = baseModifier.padding(vertical = 8.dp),
                thickness = 1.dp,
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
            )
        }
        "spacer" -> {
            val w = node.optInt("width", 0).coerceAtLeast(0)
            val h = node.optInt("height", 0).coerceAtLeast(0)
            Spacer(modifier = baseModifier.size(width = w.dp, height = h.dp))
        }
        "scaffold" -> {
            SduiScaffold(spec = node, onAction = dispatch)
        }
        "reorderable_list" -> {
            ReorderableList(node = node, dispatch = dispatch, modifier = baseModifier)
        }
        "table" -> SduiTable(node, baseModifier, dispatch)
        "chart" -> SduiChart(node, baseModifier, dispatch)
        "canvas" -> SduiCanvas(node, baseModifier)

        // ── Content nodes (SduiContentNodes.kt) ─────────────────────────
        "text" -> SduiText(node, baseModifier)
        "rich_text" -> SduiRichText(node, baseModifier, dispatch)
        "date_stamp" -> SduiDateStamp(node, baseModifier)
        "menu" -> SduiMenu(node, baseModifier, dispatch)
        "section_header" -> SduiSectionHeader(node, surfaceId, revision, baseModifier, dispatch)
        "empty_state" -> SduiEmptyState(node, baseModifier, dispatch)

        // ── Input nodes (SduiInputNodes.kt) ─────────────────────────────
        "text_input" -> SduiTextInput(node, baseModifier, dispatch)
        "editor" -> SduiEditor(node, baseModifier, dispatch)
        "checkbox" -> SduiCheckbox(node, baseModifier, dispatch)
        "switch" -> SduiSwitch(node, baseModifier, dispatch)
        "enum_list" -> SduiEnumList(node, baseModifier, dispatch)
        "date_button" -> SduiDateButton(node, baseModifier, dispatch)
        "time_button" -> SduiTimeButton(node, baseModifier, dispatch)
        "slider" -> {
            // A continuous value input (progress is display-only). Dispatches
            // on_change once, on release, with the value injected into args
            // (SPEC §9); the position tracks locally during the drag so a
            // drag never floods the wire.
            val min = node.optDouble("min", 0.0).toFloat()
            val max = node.optDouble("max", 1.0).toFloat()
            val onChange = node.optJSONObject("on_change")
            var pos by remember(node.optString("id"), revision) {
                mutableFloatStateOf(node.optDouble("value", min.toDouble()).toFloat())
            }
            Slider(
                value = pos,
                onValueChange = { pos = it },
                onValueChangeFinished = {
                    if (onChange != null) dispatchWithValue(dispatch, onChange, pos.toDouble())
                },
                valueRange = min..max,
                steps = node.optInt("steps", 0),
                modifier = baseModifier.fillMaxWidth()
            )
        }

        // ── Simple controls ──────────────────────────────────────────────
        "button" -> {
            val label = node.optString("label")
            val actionJson = node.optJSONObject("on_tap")
            val variant = node.optString("variant", "filled")
            // Single line, ellipsis over wrap: a weight-constrained row of
            // buttons (the SRS ratings) must never break a label mid-word
            // ("Agai\nn").  Trimmed horizontal padding lets short labels
            // like "Again" fit their slot without truncating.
            val content = @Composable {
                Text(label, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis)
            }
            val pad = PaddingValues(horizontal = 12.dp, vertical = 8.dp)

            when (variant) {
                "text" -> TextButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier, contentPadding = pad) { content() }
                "outlined" -> OutlinedButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier, contentPadding = pad) { content() }
                "tonal" -> FilledTonalButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier, contentPadding = pad) { content() }
                else -> Button(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier, contentPadding = pad) { content() }
            }
        }
        "icon_button" -> {
            val actionJson = node.optJSONObject("on_tap")
            val iconName = node.optString("icon", "help_outline")
            IconButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier) {
                JetpacsBadged(node) {
                    Icon(IconMap.get(iconName), contentDescription = null)
                }
            }
        }
        "icon" -> {
            // size and color were ignored too — every icon drew at 24dp in
            // the ambient tint (agenda type icons, month-grid dots, reader
            // checkboxes all specify sizes/colors).
            val iconName = node.optString("name", "help_outline")
            val size = node.optInt("size", 0)
            val tint = resolveColor(node.optString("color"))
                .takeIf { it != Color.Unspecified } ?: LocalContentColor.current
            JetpacsBadged(node) {
                Icon(
                    IconMap.get(iconName),
                    contentDescription = null,
                    tint = tint,
                    modifier = baseModifier.then(
                        if (size > 0) Modifier.size(size.dp) else Modifier
                    )
                )
            }
        }
        "chip" -> {
            val label = node.optString("label")
            val selected = node.optBoolean("selected", false)
            val actionJson = node.optJSONObject("on_tap")
            val iconName = node.optString("icon", "")
            FilterChip(
                selected = selected,
                onClick = { if (actionJson != null) dispatch(actionJson) },
                label = { Text(label) },
                leadingIcon = if (iconName.isNotEmpty()) { { Icon(IconMap.get(iconName), null) } } else null,
                modifier = baseModifier
            )
        }
        "assist_chip" -> {
            val label = node.optString("label")
            val actionJson = node.optJSONObject("on_tap")
            val iconName = node.optString("icon", "")
            AssistChip(
                onClick = { if (actionJson != null) dispatch(actionJson) },
                label = { Text(label) },
                leadingIcon = if (iconName.isNotEmpty()) {
                    { Icon(IconMap.get(iconName), null, Modifier.size(18.dp)) }
                } else null,
                modifier = baseModifier
            )
        }
        "badge" -> {
            // A compact, non-interactive status pill: a tonal COLOR-tinted
            // container with a colored optional leading icon + label. Intrinsic
            // width (the Surface wraps its content), so it sits safely as a
            // trailing row child — unlike a nested icon+label row, which would
            // render fillMaxWidth. Additive node: an older companion falls
            // through to `else` and renders the fallback `text` child (the
            // colored label), so callers need not gate on node_types.
            val label = node.optString("label")
            val iconName = node.optString("icon", "")
            val color = resolveColor(node.optString("color"))
                .takeIf { it != Color.Unspecified }
                ?: MaterialTheme.colorScheme.onSurfaceVariant
            Surface(
                modifier = baseModifier,
                shape = RoundedCornerShape(percent = 50),
                color = color.copy(alpha = 0.12f),
                contentColor = color
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (iconName.isNotEmpty()) {
                        Icon(IconMap.get(iconName), null, Modifier.size(14.dp))
                    }
                    if (label.isNotEmpty()) {
                        Text(label, style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
        "progress" -> {
            val variant = node.optString("variant", "circular")
            if (node.has("value")) {
                val value = node.optDouble("value").toFloat()
                if (variant == "linear") LinearProgressIndicator(progress = { value }, modifier = baseModifier)
                else CircularProgressIndicator(progress = { value }, modifier = baseModifier)
            } else {
                if (variant == "linear") LinearProgressIndicator(modifier = baseModifier)
                else CircularProgressIndicator(modifier = baseModifier)
            }
        }
        "image" -> {
            // Loaded via Coil from whatever URI Emacs supplies: an http(s) URL,
            // or a file:// path that the companion can read.
            val url = node.optString("url")
            val desc = node.optString("content_description")
            if (url.isNotEmpty()) {
                var m = baseModifier
                val w = if (node.has("width")) safeDp(node.optInt("width")) else null
                val h = if (node.has("height")) safeDp(node.optInt("height")) else null
                if (w != null) m = m.width(w.dp)
                if (h != null) m = m.height(h.dp)
                if (node.has("aspect_ratio")) safeAspect(node.optDouble("aspect_ratio"))?.let { m = m.aspectRatio(it) }
                // Default to full-width only when the server gave no explicit
                // (valid) sizing; a malformed width falls through to fill.
                m = when {
                    w != null -> m
                    node.has("fill_fraction") ->
                        safeFraction(node.optDouble("fill_fraction"))?.let { m.fillMaxWidth(it) } ?: m.fillMaxWidth()
                    else -> m.fillMaxWidth()
                }
                val scale = when (node.optString("content_scale")) {
                    "crop" -> ContentScale.Crop
                    "fill" -> ContentScale.FillBounds
                    else -> ContentScale.Fit
                }
                AsyncImage(
                    model = url,
                    contentDescription = desc.ifEmpty { null },
                    modifier = m,
                    contentScale = scale
                )
            }
        }

        // Forward-compat (SPEC §12): a node type this build doesn't know —
        // e.g. a newer client using a node this companion predates. Render
        // its `children` if it has any (a new *container* degrades to a plain
        // stack of its contents instead of vanishing) or nothing if it's a
        // leaf. Never a crash. Node-vocabulary negotiation (the welcome's
        // `node_types`) lets a client avoid reaching here at all.
        else -> {
            node.optJSONArray("children")?.let { children ->
                RenderChildren(children, surfaceId, revision, dispatch)
            }
        }
    }
}

/**
 * Defensive clamps for wire-supplied numbers that feed Compose modifiers
 * with preconditions. Malformed data (a `0` aspect ratio, a `>1` fraction, a
 * negative dp) would otherwise throw *during composition* — and Compose has
 * no clean way to recover from that, so a single bad node would blank the
 * whole surface. Returning null (skip the modifier) instead of throwing is
 * the reachable form of an error boundary here (see
 * docs/PLAN-renderer-reconciliation.md, K2). Split out as pure functions so
 * they are unit-testable on the JVM without instrumentation.
 */
internal fun safeAspect(v: Double): Float? = v.toFloat().takeIf { it.isFinite() && it > 0f }
internal fun safeFraction(v: Double): Float? = v.toFloat().takeIf { it.isFinite() && it > 0f && it <= 1f }
internal fun safeDp(v: Int): Int? = v.takeIf { it >= 0 }

/**
 * Stable, unique reconciliation keys for a lazy list's children (K1a in
 * docs/PLAN-renderer-reconciliation.md). Without keys, `LazyColumn` keys
 * items by position, so a structural push (insert/reorder/delete) reuses a
 * slot's composition for a different node — scrambling the id-keyed
 * `rememberSeeded` inside and losing an in-flight edit, focus, or scroll on a
 * shifted row. We prefer an explicit `key`, then a stateful child's `id`
 * (text_input, collapsible, editor all carry one); keyless leaves fall back
 * to a namespaced index (status-quo positional behaviour, harmless for
 * stateless content). Duplicate bases (author error: two children sharing an
 * id) are disambiguated with a `#n` suffix so Compose never sees a duplicate
 * key — which would crash the list. Pure and JVM-testable.
 */
internal fun lazyChildKeys(children: JSONArray): List<String> {
    val seen = HashMap<String, Int>()
    return (0 until children.length()).map { i ->
        val c = children.optJSONObject(i)
        val explicit = c?.optString("key").orEmpty()
        val id = c?.optString("id").orEmpty()
        val base = when {
            explicit.isNotEmpty() -> "k:$explicit"
            id.isNotEmpty() -> "id:$id"
            else -> "i:$i"
        }
        val n = seen.getOrDefault(base, 0)
        seen[base] = n + 1
        if (n == 0) base else "$base#$n"
    }
}

/**
 * Sizing and border modifiers shared by the container nodes (box, surface,
 * card): explicit width/height in dp, fill_fraction (0..1 of the parent's
 * width), and an optional {width,color} border stroked with the container's
 * SHAPE. All additive — an absent key changes nothing, so a plain container
 * is unaffected. Out-of-range numbers are skipped, not applied (see safe*).
 */
@Composable
private fun containerModifier(node: JSONObject, shape: Shape): Modifier {
    var m: Modifier = Modifier
    if (node.has("width")) safeDp(node.optInt("width"))?.let { m = m.width(it.dp) }
    if (node.has("height")) safeDp(node.optInt("height"))?.let { m = m.height(it.dp) }
    if (node.has("fill_fraction")) safeFraction(node.optDouble("fill_fraction"))?.let { m = m.fillMaxWidth(it) }
    node.optJSONObject("border")?.let { b ->
        val c = resolveColor(b.optString("color")).takeIf { it != Color.Unspecified }
            ?: MaterialTheme.colorScheme.outline
        m = m.border(BorderStroke(b.optInt("width", 1).coerceAtLeast(0).dp, c), shape)
    }
    return m
}

/**
 * Outline/drawer folding handled entirely on-device: Emacs ships the whole
 * subtree once, we just show/hide children locally (snappy, works offline).
 * Fold state is keyed by `id` so it survives the frequent background
 * re-pushes.
 */
@Composable
private fun SduiCollapsible(
    node: JSONObject,
    surfaceId: String,
    revision: Int,
    modifier: Modifier,
    dispatch: (JSONObject) -> Unit,
) {
    val id = node.optString("id")
    val collapsed = node.optBoolean("collapsed", false)
    val (expandedState, _) = rememberSeededBool(id, !collapsed)
    var expanded by expandedState
    val header = node.optJSONObject("header")
    val longTapAction = node.optJSONObject("on_long_tap")
    val swipeJson = node.optJSONObject("on_swipe")
    var swipeOffset by remember { mutableFloatStateOf(0f) }

    // A single chevron that rotates between right (collapsed) and
    // down (expanded), and a vertically-expanding reveal, so folding
    // animates instead of snapping.
    val chevron by animateFloatAsState(
        targetValue = if (expanded) 0f else -90f,
        label = "chevron"
    )

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (swipeJson != null) {
                        Modifier
                            .pointerInput(swipeJson) {
                                detectHorizontalDragGestures(
                                    onDragEnd = {
                                        if (swipeOffset < -150f || swipeOffset > 150f) {
                                            dispatch(swipeJson)
                                        }
                                        swipeOffset = 0f
                                    },
                                    onDragCancel = { swipeOffset = 0f },
                                    onHorizontalDrag = { change, dragAmount ->
                                        change.consume()
                                        swipeOffset += dragAmount
                                    }
                                )
                            }
                            .offset { androidx.compose.ui.unit.IntOffset(swipeOffset.roundToInt(), 0) }
                    } else Modifier
                )
                .then(
                    if (longTapAction != null) {
                        @OptIn(ExperimentalFoundationApi::class)
                        Modifier.combinedClickable(
                            onClick = { expanded = !expanded },
                            onLongClick = { dispatch(longTapAction) }
                        )
                    } else {
                        Modifier.clickable { expanded = !expanded }
                    }
                )
        ) {
            Icon(
                IconMap.get("keyboard_arrow_down"),
                contentDescription = if (expanded) "Collapse" else "Expand",
                modifier = Modifier.rotate(chevron)
            )
            if (header != null) {
                Box(modifier = Modifier.weight(1f)) {
                    SduiNode(header, surfaceId, revision, Modifier, dispatch)
                }
            }
        }
        AnimatedVisibility(visible = expanded) {
            Column(modifier = Modifier.padding(start = 24.dp, top = 2.dp)) {
                RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
            }
        }
    }
}

@Composable
fun RenderChildren(children: JSONArray?, surfaceId: String, revision: Int, onAction: (JSONObject) -> Unit) {
    if (children == null) return
    for (i in 0 until children.length()) {
        val child = children.optJSONObject(i)
        if (child != null) {
            SduiNode(child, surfaceId, revision, Modifier, onAction)
        }
    }
}

/**
 * Render children honouring an optional per-child `weight`, mapping it to a
 * scope-specific weight modifier via [weightModifier] (Row and Column expose
 * distinct, incompatible `Modifier.weight` receivers).
 */
@Composable
private fun WeightedChildren(
    children: JSONArray?,
    surfaceId: String,
    revision: Int,
    dispatch: (JSONObject) -> Unit,
    weightModifier: (Float) -> Modifier,
) {
    if (children == null) return
    for (i in 0 until children.length()) {
        val child = children.optJSONObject(i) ?: continue
        val weight = child.optDouble("weight", 0.0).toFloat()
        val childModifier = if (weight > 0) weightModifier(weight) else Modifier
        SduiNode(child, surfaceId, revision, childModifier, dispatch)
    }
}

/**
 * Registry of pending debounced `state.changed` flushes (SPEC §5).
 *
 * Stateful nodes that publish on a debounce (text_input; editor with
 * publish_state) register a flush lambda; the action-dispatch path drains
 * the registry synchronously before sending any `event.action`, so a
 * diverged value always precedes on the wire the action that might read
 * it. A flusher must be idempotent and cheap: it re-sends nothing when the
 * last published value is already current.
 *
 * Keyed by an opaque per-composition token, NOT by widget id: two live
 * compositions can legitimately carry the same id (a dialog and the main
 * surface both rendering `note`), and id keying let the second registration
 * clobber the first — after which either one's disposal removed the
 * survivor's flusher too, silently restoring the debounce race this exists
 * to close.
 */
internal object PendingStateFlush {
    private val flushers = java.util.concurrent.ConcurrentHashMap<Any, () -> Unit>()
    fun register(token: Any, flush: () -> Unit) {
        flushers[token] = flush
    }
    fun unregister(token: Any) {
        flushers.remove(token)
    }
    fun flushAll() {
        flushers.values.forEach { it() }
    }
}

/**
 * Clone [action], inject [value] into its args, and hand it to [dispatch] —
 * the shared tail of every value-carrying widget callback (submit, save,
 * date/time pick, selection change).
 */
internal fun dispatchWithValue(dispatch: (JSONObject) -> Unit, action: JSONObject, value: Any) {
    val payload = JSONObject(action.toString()).apply {
        put("args", (optJSONObject("args") ?: JSONObject()).apply { put("value", value) })
    }
    dispatch(payload)
}

internal fun dispatchStateChanged(context: Context, id: String, valueJson: String) {
    if (id.isEmpty()) return
    val intent = Intent(context, ActionReceiver::class.java).apply {
        action = ActionReceiver.ACTION_STATE_CHANGED
        putExtra(ActionReceiver.EXTRA_ID, id)
        putExtra(ActionReceiver.EXTRA_VALUE_JSON, valueJson)
    }
    context.sendBroadcast(intent)
}

/** NODE's `badge` value as display text (SPEC §9): a number renders as a
 *  count capped at "99+", the empty string as a bare dot badge; null when
 *  the node carries no badge. */
internal fun jetpacsBadgeText(node: JSONObject): String? {
    if (!node.has("badge")) return null
    return when (val raw = node.opt("badge")) {
        is Number -> raw.toInt().let { if (it > 99) "99+" else it.toString() }
        is String -> raw
        else -> ""
    }
}

/** Wrap CONTENT in a [BadgedBox] when NODE carries a `badge` attribute —
 *  the shared treatment for icons, icon buttons, and nav items. */
@Composable
internal fun JetpacsBadged(node: JSONObject, content: @Composable () -> Unit) {
    val text = jetpacsBadgeText(node)
    if (text == null) {
        content()
        return
    }
    BadgedBox(badge = { if (text.isEmpty()) Badge() else Badge { Text(text) } }) {
        content()
    }
}

/**
 * Per-side card swipe actions (SPEC §9): dragging reveals the side's
 * icon/label on its (optionally hex-colored) background; a full swipe past
 * the threshold fires `on_trigger` once, with a haptic tick, and the card
 * springs back — the client answers by pushing the updated list, the same
 * contract as the legacy single-action `on_swipe`.
 */
@Composable
private fun SwipeActionCard(
    swipeStart: JSONObject?,
    swipeEnd: JSONObject?,
    dispatch: (JSONObject) -> Unit,
    content: @Composable () -> Unit,
) {
    val haptic = LocalHapticFeedback.current
    val state = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            val side = when (value) {
                SwipeToDismissBoxValue.StartToEnd -> swipeStart
                SwipeToDismissBoxValue.EndToStart -> swipeEnd
                else -> null
            }
            side?.optJSONObject("on_trigger")?.let {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                dispatch(it)
            }
            // Never settle dismissed: the card stays until the server's
            // refreshed list removes it (or doesn't — a schedule action
            // legitimately keeps the row).
            false
        }
    )
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = swipeStart != null,
        enableDismissFromEndToStart = swipeEnd != null,
        backgroundContent = {
            val side = when (state.dismissDirection) {
                SwipeToDismissBoxValue.StartToEnd -> swipeStart
                SwipeToDismissBoxValue.EndToStart -> swipeEnd
                else -> null
            } ?: return@SwipeToDismissBox
            val bg = resolveColor(side.optString("color"))
                .takeIf { it != Color.Unspecified }
                ?: MaterialTheme.colorScheme.secondaryContainer
            val fg = if (bg.luminance() < 0.5f) Color.White else Color(0xFF1A1A1A)
            val label = side.optString("label")
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(vertical = 4.dp)
                    .background(bg, RoundedCornerShape(12.dp))
                    .padding(horizontal = 20.dp),
                contentAlignment =
                    if (state.dismissDirection == SwipeToDismissBoxValue.StartToEnd)
                        Alignment.CenterStart
                    else Alignment.CenterEnd
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        IconMap.get(side.optString("icon", "help_outline")),
                        contentDescription = label.ifEmpty { null },
                        tint = fg
                    )
                    if (label.isNotEmpty()) {
                        Spacer(Modifier.width(6.dp))
                        Text(label, color = fg, style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
        }
    ) {
        content()
    }
}
