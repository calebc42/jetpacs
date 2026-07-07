package com.calebc42.eabp

import android.content.Context
import android.content.Intent
import coil.compose.AsyncImage
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
    "reorderable_list", "table",
    // Content
    "text", "rich_text", "date_stamp", "menu", "section_header",
    "empty_state", "icon", "image", "progress",
    // Input
    "text_input", "editor", "checkbox", "switch", "enum_list",
    "date_button", "time_button", "button", "icon_button", "chip",
    "assist_chip",
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

    val dispatch = onAction ?: { action: JSONObject ->
        val intent = Intent(context, ActionReceiver::class.java).apply {
            this.action = ActionReceiver.ACTION_TAP
            putExtra(ActionReceiver.EXTRA_SURFACE, surfaceId)
            putExtra(ActionReceiver.EXTRA_REVISION, revision)
            putExtra(ActionReceiver.EXTRA_ACTION, action.toString())
        }
        context.sendBroadcast(intent)
    }

    val baseModifier = modifier.then(
        if (node.has("padding")) Modifier.padding(node.optInt("padding").dp) else Modifier
    )

    when (type) {
        // ── Layout containers ────────────────────────────────────────────
        "column" -> {
            val scrollable = node.optBoolean("scroll", false)
            val mod = baseModifier.fillMaxWidth().let {
                if (scrollable) it.verticalScroll(rememberScrollState()) else it
            }
            Column(
                modifier = mod,
                verticalArrangement = Arrangement.spacedBy(node.optInt("spacing", 8).dp)
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
            Row(
                modifier = if (scroll)
                    baseModifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                else baseModifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(node.optInt("spacing", 8).dp),
                verticalAlignment = Alignment.CenterVertically
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
            val boxModifier = if (actionJson != null) {
                baseModifier.clickable { dispatch(actionJson) }
            } else baseModifier
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
                modifier = baseModifier.then(fillMod),
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
            val cardContent: @Composable () -> Unit = {
                androidx.compose.material3.ElevatedCard(
                    modifier = baseModifier
                        .fillMaxWidth()
                        .clickable(enabled = actionJson != null) { if (actionJson != null) dispatch(actionJson) }
                ) {
                    Box(modifier = Modifier.padding(16.dp)) {
                        RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
                    }
                }
            }
            if (swipeJson != null) {
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
                LazyColumn(state = listState, modifier = baseModifier.fillMaxSize()) {
                    items(children.length()) { i ->
                        val child = children.optJSONObject(i)
                        if (child != null) SduiNode(child, surfaceId, revision, Modifier, dispatch)
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
            val w = node.optInt("width", 0)
            val h = node.optInt("height", 0)
            Spacer(modifier = baseModifier.size(width = w.dp, height = h.dp))
        }
        "scaffold" -> {
            SduiScaffold(spec = node, onAction = dispatch)
        }
        "reorderable_list" -> {
            ReorderableList(node = node, dispatch = dispatch, modifier = baseModifier)
        }
        "table" -> SduiTable(node, baseModifier, dispatch)

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
        "checkbox" -> SduiCheckbox(node, baseModifier)
        "switch" -> SduiSwitch(node, baseModifier)
        "enum_list" -> SduiEnumList(node, baseModifier, dispatch)
        "date_button" -> SduiDateButton(node, baseModifier, dispatch)
        "time_button" -> SduiTimeButton(node, baseModifier, dispatch)

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
                Icon(IconMap.get(iconName), contentDescription = null)
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
            Icon(
                IconMap.get(iconName),
                contentDescription = null,
                tint = tint,
                modifier = baseModifier.then(
                    if (size > 0) Modifier.size(size.dp) else Modifier
                )
            )
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
                AsyncImage(
                    model = url,
                    contentDescription = desc.ifEmpty { null },
                    modifier = baseModifier.fillMaxWidth()
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
