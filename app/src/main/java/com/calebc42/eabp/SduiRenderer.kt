package com.calebc42.eabp

import android.content.Context
import android.content.Intent
import coil.compose.AsyncImage
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone
import kotlinx.coroutines.delay

/**
 * Seed-guarded local state for stateful nodes.
 *
 * Background surface pushes re-deliver specs constantly now (multi-view
 * dashboard refreshes), so a node's local state must only adopt a new
 * spec value when the user hasn't diverged from the last seed — otherwise
 * a refresh stomps text mid-typing. Returns (state, lastSeed).
 */
@Composable
private fun rememberSeeded(id: String, specValue: String): Pair<MutableState<String>, MutableState<String>> {
    val state = remember(id) { mutableStateOf(specValue) }
    val seed = remember(id) { mutableStateOf(specValue) }
    LaunchedEffect(specValue) {
        if (specValue != seed.value) {
            if (state.value == seed.value) state.value = specValue
            seed.value = specValue
        }
    }
    return state to seed
}

@Composable
private fun rememberSeededBool(id: String, specValue: Boolean): Pair<MutableState<Boolean>, MutableState<Boolean>> {
    val state = remember(id) { mutableStateOf(specValue) }
    val seed = remember(id) { mutableStateOf(specValue) }
    LaunchedEffect(specValue) {
        if (specValue != seed.value) {
            if (state.value == seed.value) state.value = specValue
            seed.value = specValue
        }
    }
    return state to seed
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
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
        "column" -> {
            Column(
                modifier = baseModifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(node.optInt("spacing", 8).dp)
            ) {
                val children = node.optJSONArray("children")
                if (children != null) {
                    for (i in 0 until children.length()) {
                        val child = children.optJSONObject(i)
                        if (child != null) {
                            val weight = child.optDouble("weight", 0.0).toFloat()
                            val childModifier = if (weight > 0) Modifier.weight(weight) else Modifier
                            SduiNode(child, surfaceId, revision, childModifier, dispatch)
                        }
                    }
                }
            }
        }
        "row" -> {
            Row(
                modifier = baseModifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(node.optInt("spacing", 8).dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val children = node.optJSONArray("children")
                if (children != null) {
                    for (i in 0 until children.length()) {
                        val child = children.optJSONObject(i)
                        if (child != null) {
                            val weight = child.optDouble("weight", 0.0).toFloat()
                            val childModifier = if (weight > 0) Modifier.weight(weight) else Modifier
                            SduiNode(child, surfaceId, revision, childModifier, dispatch)
                        }
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
            val modifier = if (actionJson != null) {
                baseModifier.clickable { dispatch(actionJson) }
            } else baseModifier
            Box(modifier = modifier, contentAlignment = alignment) {
                RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
            }
        }
        "surface" -> {
            Surface(modifier = baseModifier) {
                RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
            }
        }
        "text" -> {
            val text = node.optString("text")
            val styleStr = node.optString("style", "body")
            val style = textStyleForName(styleStr)
            val syntax = node.optString("syntax")
            if (syntax.isNotEmpty()) {
                val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
                val sc = remember(dark) { SyntaxColors.forBackground(dark) }
                val mono = syntax.lowercase() != "org"
                val annotated = remember(text, syntax, sc) {
                    when (syntax.lowercase()) {
                        "org" -> highlightOrg(text, sc)
                        "elisp", "emacs-lisp", "lisp" -> highlightElisp(text, sc)
                        else -> AnnotatedString(text)
                    }
                }
                Text(
                    text = annotated,
                    style = if (mono) style.copy(fontFamily = FontFamily.Monospace) else style,
                    modifier = baseModifier
                )
            } else {
                Text(text = text, style = style, modifier = baseModifier)
            }
        }
        "button" -> {
            val label = node.optString("label")
            val actionJson = node.optJSONObject("on_tap")
            val variant = node.optString("variant", "filled")
            val content = @Composable { Text(label) }

            when (variant) {
                "text" -> TextButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier) { content() }
                "outlined" -> OutlinedButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier) { content() }
                "tonal" -> FilledTonalButton(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier) { content() }
                else -> Button(onClick = { if (actionJson != null) dispatch(actionJson) }, modifier = baseModifier) { content() }
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
            val iconName = node.optString("name", "help_outline")
            Icon(IconMap.get(iconName), contentDescription = null, modifier = baseModifier)
        }
        "text_input" -> {
            val id = node.optString("id")
            val (textState, _) = rememberSeeded(id, node.optString("value", ""))
            var text by textState
            val hint = node.optString("hint")
            val label = node.optString("label")
            val onSubmit = node.optJSONObject("on_submit")
            val singleLine = node.optBoolean("single_line", true)
            val minLines = node.optInt("min_lines", 1)
            val maxLines = node.optInt("max_lines", if (singleLine) 1 else Int.MAX_VALUE)
            val syntax = node.optString("syntax")
            val monospace = node.optBoolean("monospace", false) || syntax.isNotEmpty()
            val highlight = if (syntax.isNotEmpty()) {
                val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
                val sc = remember(dark) { SyntaxColors.forBackground(dark) }
                remember(syntax, sc) { SyntaxTransformation(syntax, sc) }
            } else VisualTransformation.None

            OutlinedTextField(
                value = text,
                onValueChange = {
                    text = it
                    dispatchStateChanged(context, id, JSONObject.quote(it))
                },
                label = if (label.isNotEmpty()) { { Text(label) } } else null,
                placeholder = if (hint.isNotEmpty()) { { Text(hint) } } else null,
                singleLine = singleLine,
                minLines = minLines,
                maxLines = maxLines,
                visualTransformation = highlight,
                textStyle = if (monospace)
                    LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace)
                else LocalTextStyle.current,
                // A multi-line field needs Enter for newlines, so it can't also
                // submit on Enter — multi-line callers submit via a button whose
                // action reads the value back from `eabp--ui-state`.
                modifier = baseModifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(
                    imeAction = if (singleLine) ImeAction.Done else ImeAction.Default
                ),
                keyboardActions = KeyboardActions(onDone = {
                    if (onSubmit != null) {
                        val payload = JSONObject(onSubmit.toString()).apply {
                            put("args", (onSubmit.optJSONObject("args") ?: JSONObject()).apply { put("value", text) })
                        }
                        dispatch(payload)
                    }
                    dispatchStateChanged(context, id, JSONObject.quote(text))
                })
            )
        }
        "editor" -> {
            // Full-height plain-text editor with modified-tracking. The save
            // button dispatches `on_save` with the full text injected into
            // args as `value`. Note: action delivery rides a broadcast
            // intent, so very large files must arrive read_only from Emacs.
            //
            // Uses TextFieldValue (not plain String) so the formatting toolbar
            // can read/set cursor position and selection for smart insertions.
            val id = node.optString("id")
            val readOnly = node.optBoolean("read_only", false)
            val onSave = node.optJSONObject("on_save")
            // Syntax defaults to the file's extension when Emacs doesn't say.
            val syntax = node.optString("syntax").ifEmpty { syntaxForPath(id) }
            val isOrg = syntax.lowercase() == "org"

            // TextFieldValue-based state for cursor/selection support.
            val specValue = node.optString("value", "")
            var tfv by remember(id) { mutableStateOf(TextFieldValue(specValue)) }
            var seed by remember(id) { mutableStateOf(specValue) }
            // Adopt new spec values only when the user hasn't diverged
            // (same seed-guard logic as rememberSeeded, but for TextFieldValue).
            LaunchedEffect(specValue) {
                if (specValue != seed) {
                    if (tfv.text == seed) {
                        tfv = TextFieldValue(specValue)
                    }
                    seed = specValue
                }
            }
            val modified = tfv.text != seed
            val fileName = id.substringAfterLast('/').ifEmpty { "untitled" }

            // ── Undo / Redo ──────────────────────────────────────────────
            // Stacks store *previous* text snapshots. Current state = tfv.
            val undoStack = remember(id) { mutableListOf<String>() }
            val redoStack = remember(id) { mutableListOf<String>() }
            var canUndo by remember(id) { mutableStateOf(false) }
            var canRedo by remember(id) { mutableStateOf(false) }
            var lastSnapshot by remember(id) { mutableStateOf(specValue) }
            var undoRedoActive by remember(id) { mutableStateOf(false) }

            // Debounced snapshot: after the user stops typing for 600ms,
            // push the *previous* text as an undo point.
            LaunchedEffect(tfv.text) {
                if (!undoRedoActive && tfv.text != lastSnapshot) {
                    delay(600)
                    if (tfv.text != lastSnapshot) {
                        undoStack.add(lastSnapshot)
                        if (undoStack.size > 100) undoStack.removeAt(0)
                        redoStack.clear()
                        lastSnapshot = tfv.text
                        canUndo = true
                        canRedo = false
                    }
                }
                undoRedoActive = false
            }

            // Toolbar changes create immediate undo points (one action = one undo).
            val onToolbarChange: (TextFieldValue) -> Unit = { newValue ->
                if (tfv.text != newValue.text) {
                    undoStack.add(tfv.text)
                    if (undoStack.size > 100) undoStack.removeAt(0)
                    redoStack.clear()
                    lastSnapshot = newValue.text
                    canUndo = true
                    canRedo = false
                }
                tfv = newValue
            }

            val highlight = if (syntax.isNotEmpty()) {
                val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
                val sc = remember(dark) { SyntaxColors.forBackground(dark) }
                remember(syntax, sc) { SyntaxTransformation(syntax, sc) }
            } else VisualTransformation.None

            Column(modifier = baseModifier.fillMaxSize().imePadding()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            fileName,
                            style = MaterialTheme.typography.titleSmall,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1
                        )
                        Text(
                            when {
                                readOnly -> "read-only"
                                modified -> "● modified"
                                else -> "saved"
                            },
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    // Undo / Redo
                    IconButton(
                        onClick = {
                            if (undoStack.isNotEmpty()) {
                                undoRedoActive = true
                                redoStack.add(tfv.text)
                                val prev = undoStack.removeLast()
                                tfv = TextFieldValue(prev)
                                lastSnapshot = prev
                                canUndo = undoStack.isNotEmpty()
                                canRedo = true
                            }
                        },
                        enabled = canUndo && !readOnly
                    ) { Icon(IconMap.get("undo"), contentDescription = "Undo") }
                    IconButton(
                        onClick = {
                            if (redoStack.isNotEmpty()) {
                                undoRedoActive = true
                                undoStack.add(tfv.text)
                                val next = redoStack.removeLast()
                                tfv = TextFieldValue(next)
                                lastSnapshot = next
                                canUndo = true
                                canRedo = redoStack.isNotEmpty()
                            }
                        },
                        enabled = canRedo && !readOnly
                    ) { Icon(IconMap.get("redo"), contentDescription = "Redo") }
                    TextButton(
                        onClick = {
                            undoStack.add(tfv.text)
                            canUndo = true
                            redoStack.clear()
                            canRedo = false
                            tfv = TextFieldValue(seed)
                            lastSnapshot = seed
                        },
                        enabled = modified && !readOnly
                    ) { Text("Revert") }
                    Button(
                        onClick = {
                            if (onSave != null) {
                                val payload = JSONObject(onSave.toString()).apply {
                                    put("args", (onSave.optJSONObject("args") ?: JSONObject()).apply {
                                        put("value", tfv.text)
                                    })
                                }
                                dispatch(payload)
                                seed = tfv.text
                            }
                        },
                        enabled = modified && !readOnly && onSave != null
                    ) { Text("Save") }
                }
                OutlinedTextField(
                    value = tfv,
                    onValueChange = { if (!readOnly) tfv = it },
                    readOnly = readOnly,
                    visualTransformation = highlight,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                        fontFamily = FontFamily.Monospace,
                        lineHeight = 1.4.em
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(8.dp)
                )
                // Org formatting toolbar — sits at the bottom of the editor,
                // just above the soft keyboard (keyboard-adjacent, à la Orgro).
                if (isOrg && !readOnly) {
                    OrgEditToolbar(value = tfv, onValueChange = onToolbarChange)
                }
            }
        }
        "collapsible" -> {
            // Outline/drawer folding handled entirely on-device: Emacs ships the
            // whole subtree once, we just show/hide children locally (snappy,
            // works offline). Fold state is keyed by `id` so it survives the
            // frequent background re-pushes.
            val id = node.optString("id")
            val collapsed = node.optBoolean("collapsed", false)
            val (expandedState, _) = rememberSeededBool(id, !collapsed)
            var expanded by expandedState
            val header = node.optJSONObject("header")
            val longTapAction = node.optJSONObject("on_long_tap")

            // A single chevron that rotates between right (collapsed) and
            // down (expanded), and a vertically-expanding reveal, so folding
            // animates instead of snapping.
            val chevron by animateFloatAsState(
                targetValue = if (expanded) 0f else -90f,
                label = "chevron"
            )

            Column(modifier = baseModifier.fillMaxWidth()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
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
        "date_button" -> {
            val label = node.optString("label")
            val onPick = node.optJSONObject("on_pick")
            val initial = node.optString("value")
            var show by remember { mutableStateOf(false) }

            OutlinedButton(onClick = { show = true }, modifier = baseModifier) { Text(label) }

            if (show) {
                val initialMillis = remember(initial) { parseIsoDateUtc(initial) }
                val pickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
                DatePickerDialog(
                    onDismissRequest = { show = false },
                    confirmButton = {
                        TextButton(onClick = {
                            val millis = pickerState.selectedDateMillis
                            show = false
                            if (millis != null && onPick != null) {
                                val date = isoDateFromUtcMillis(millis)
                                val payload = JSONObject(onPick.toString()).apply {
                                    put("args", (onPick.optJSONObject("args") ?: JSONObject()).apply {
                                        put("value", date)
                                    })
                                }
                                dispatch(payload)
                            }
                        }) { Text("OK") }
                    },
                    dismissButton = {
                        TextButton(onClick = { show = false }) { Text("Cancel") }
                    }
                ) {
                    DatePicker(state = pickerState)
                }
            }
        }
        "checkbox" -> {
            val id = node.optString("id")
            val (checkedState, _) = rememberSeededBool(id, node.optBoolean("checked", false))
            var checked by checkedState
            val label = node.optString("label")

            Row(verticalAlignment = Alignment.CenterVertically, modifier = baseModifier) {
                Checkbox(checked = checked, onCheckedChange = {
                    checked = it
                    dispatchStateChanged(context, id, it.toString())
                })
                if (label.isNotEmpty()) Text(label, modifier = Modifier.padding(start = 8.dp))
            }
        }
        "switch" -> {
            val id = node.optString("id")
            val (checkedState, _) = rememberSeededBool(id, node.optBoolean("checked", false))
            var checked by checkedState
            val label = node.optString("label")

            Row(verticalAlignment = Alignment.CenterVertically, modifier = baseModifier) {
                if (label.isNotEmpty()) Text(label, modifier = Modifier.weight(1f))
                Switch(checked = checked, onCheckedChange = {
                    checked = it
                    dispatchStateChanged(context, id, it.toString())
                })
            }
        }
        "card" -> {
            val actionJson = node.optJSONObject("on_tap")
            ElevatedCard(
                modifier = baseModifier
                    .fillMaxWidth()
                    .clickable(enabled = actionJson != null) { if (actionJson != null) dispatch(actionJson) }
            ) {
                Box(modifier = Modifier.padding(16.dp)) {
                    RenderChildren(node.optJSONArray("children"), surfaceId, revision, dispatch)
                }
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
        "lazy_column" -> {
            val children = node.optJSONArray("children")
            if (children != null) {
                LazyColumn(modifier = baseModifier.fillMaxSize()) {
                    items(children.length()) { i ->
                        val child = children.optJSONObject(i)
                        if (child != null) SduiNode(child, surfaceId, revision, Modifier, dispatch)
                    }
                }
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
        "time_button" -> {
            val label = node.optString("label")
            val onPick = node.optJSONObject("on_pick")
            val initial = node.optString("value")
            var show by remember { mutableStateOf(false) }

            OutlinedButton(onClick = { show = true }, modifier = baseModifier) { Text(label) }

            if (show) {
                val (initialHour, initialMinute) = remember(initial) { parseHm(initial) }
                val pickerState = rememberTimePickerState(
                    initialHour = initialHour,
                    initialMinute = initialMinute
                )
                AlertDialog(
                    onDismissRequest = { show = false },
                    confirmButton = {
                        TextButton(onClick = {
                            show = false
                            if (onPick != null) {
                                val time = String.format("%02d:%02d", pickerState.hour, pickerState.minute)
                                val payload = JSONObject(onPick.toString()).apply {
                                    put("args", (onPick.optJSONObject("args") ?: JSONObject()).apply {
                                        put("value", time)
                                    })
                                }
                                dispatch(payload)
                            }
                        }) { Text("OK") }
                    },
                    dismissButton = {
                        TextButton(onClick = { show = false }) { Text("Cancel") }
                    },
                    text = { TimePicker(state = pickerState) }
                )
            }
        }
        "rich_text" -> {
            // Org content that Emacs has already parsed into styled spans: each
            // span carries emphasis flags (bold/italic/underline/strike/code),
            // an optional color, a `tag` flag (themed like a #hashtag), and an
            // optional `on_tap` action (rendered as a clickable link). Building
            // the styling here — rather than re-parsing org on-device — keeps
            // Emacs the single source of truth.
            val style = textStyleForName(node.optString("style", "body"))
            val spans = node.optJSONArray("spans")
            val linkColor = MaterialTheme.colorScheme.primary
            val tagColor = MaterialTheme.colorScheme.tertiary
            // Built per-composition (bodies are small): the click lambdas close
            // over `dispatch`, so memoizing risks a stale dispatcher.
            val annotated = buildAnnotatedString {
                    if (spans != null) {
                        for (i in 0 until spans.length()) {
                            val s = spans.optJSONObject(i) ?: continue
                            val text = s.optString("text")
                            if (text.isEmpty()) continue

                            val decorations = buildList {
                                if (s.optBoolean("underline")) add(TextDecoration.Underline)
                                if (s.optBoolean("strike")) add(TextDecoration.LineThrough)
                            }
                            val isTag = s.optBoolean("tag")
                            val colorHex = s.optString("color")
                            val explicitColor = if (colorHex.isNotEmpty()) parseHexColor(colorHex) else Color.Unspecified
                            val baseline = s.optString("baseline")
                            val span = SpanStyle(
                                fontWeight = if (s.optBoolean("bold") || isTag) FontWeight.Bold else null,
                                fontStyle = if (s.optBoolean("italic")) FontStyle.Italic else null,
                                // `code` carries inline-code semantics; `mono` is a plain
                                // monospace run (generic buffer renderer) — both just set
                                // the font family here.
                                fontFamily = if (s.optBoolean("code") || s.optBoolean("mono")) FontFamily.Monospace else null,
                                textDecoration = if (decorations.isNotEmpty()) TextDecoration.combine(decorations) else null,
                                baselineShift = when (baseline) {
                                    "super" -> BaselineShift.Superscript
                                    "sub" -> BaselineShift.Subscript
                                    else -> null
                                },
                                fontSize = if (baseline.isNotEmpty()) 0.8.em else TextUnit.Unspecified,
                                color = when {
                                    explicitColor != Color.Unspecified -> explicitColor
                                    isTag -> tagColor
                                    else -> Color.Unspecified
                                }
                            )

                            val onTap = s.optJSONObject("on_tap")
                            if (onTap != null) {
                                val linkSpan = if (span.color == Color.Unspecified) span.copy(color = linkColor) else span
                                withLink(
                                    LinkAnnotation.Clickable(
                                        tag = "span$i",
                                        styles = TextLinkStyles(style = linkSpan)
                                    ) { dispatch(onTap) }
                                ) { append(text) }
                            } else {
                                withStyle(span) { append(text) }
                            }
                        }
                    }
                }
            Text(text = annotated, style = style, modifier = baseModifier)
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
        "enum_list" -> {
            val id = node.optString("id")
            val allowAdd = node.optBoolean("allow_add", false)
            val multiSelect = node.optBoolean("multi_select", false)
            val onChange = node.optJSONObject("on_change")
            val optionsJson = node.optJSONArray("options")
            val initialOptions = remember(optionsJson) {
                val list = mutableListOf<String>()
                if (optionsJson != null) {
                    for (i in 0 until optionsJson.length()) {
                        list.add(optionsJson.optString(i))
                    }
                }
                list
            }
            var options by remember(initialOptions) { mutableStateOf(initialOptions) }

            val valueJson = node.optJSONArray("value")
            val seedSelected = remember(valueJson) {
                val set = mutableSetOf<String>()
                if (valueJson != null) {
                    for (i in 0 until valueJson.length()) {
                        set.add(valueJson.optString(i))
                    }
                }
                set
            }
            val selectedState = remember(id) { mutableStateOf(seedSelected) }
            val seed = remember(id) { mutableStateOf(seedSelected) }
            LaunchedEffect(seedSelected) {
                if (seedSelected != seed.value) {
                    if (selectedState.value == seed.value) selectedState.value = seedSelected
                    seed.value = seedSelected
                }
            }
            var selected by selectedState

            var showAddDialog by remember { mutableStateOf(false) }

            FlowRow(
                modifier = baseModifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                options.forEach { opt ->
                    FilterChip(
                        selected = selected.contains(opt),
                        onClick = {
                            val newSet = selected.toMutableSet()
                            if (newSet.contains(opt)) {
                                newSet.remove(opt)
                            } else {
                                if (!multiSelect) newSet.clear()
                                newSet.add(opt)
                            }
                            selected = newSet
                            dispatchStateChanged(context, id, JSONArray(newSet).toString())
                            if (onChange != null) {
                                val payload = JSONObject(onChange.toString()).apply {
                                    put("args", (onChange.optJSONObject("args") ?: JSONObject()).apply {
                                        put("value", JSONArray(newSet))
                                    })
                                }
                                dispatch(payload)
                            }
                        },
                        label = { Text(opt) }
                    )
                }
                if (allowAdd) {
                    AssistChip(
                        onClick = { showAddDialog = true },
                        label = { Text("+ Add") }
                    )
                }
            }

            if (showAddDialog) {
                var newOption by remember { mutableStateOf("") }
                AlertDialog(
                    onDismissRequest = { showAddDialog = false },
                    title = { Text("Add Option") },
                    text = {
                        OutlinedTextField(
                            value = newOption,
                            onValueChange = { newOption = it },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = {
                                if (newOption.isNotBlank() && !options.contains(newOption.trim())) {
                                    val opt = newOption.trim()
                                    options = (options + opt).toMutableList()
                                    val newSet = selected.toMutableSet()
                                    if (!multiSelect) newSet.clear()
                                    newSet.add(opt)
                                    selected = newSet
                                    dispatchStateChanged(context, id, JSONArray(newSet).toString())
                                    if (onChange != null) {
                                        val payload = JSONObject(onChange.toString()).apply {
                                            put("args", (onChange.optJSONObject("args") ?: JSONObject()).apply {
                                                put("value", JSONArray(newSet))
                                            })
                                        }
                                        dispatch(payload)
                                    }
                                }
                                showAddDialog = false
                            })
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            if (newOption.isNotBlank() && !options.contains(newOption.trim())) {
                                val opt = newOption.trim()
                                options = (options + opt).toMutableList()
                                val newSet = selected.toMutableSet()
                                if (!multiSelect) newSet.clear()
                                newSet.add(opt)
                                selected = newSet
                                dispatchStateChanged(context, id, JSONArray(newSet).toString())
                                if (onChange != null) {
                                    val payload = JSONObject(onChange.toString()).apply {
                                        put("args", (onChange.optJSONObject("args") ?: JSONObject()).apply {
                                            put("value", JSONArray(newSet))
                                        })
                                    }
                                    dispatch(payload)
                                }
                            }
                            showAddDialog = false
                        }) { Text("Add") }
                    },
                    dismissButton = {
                        TextButton(onClick = { showAddDialog = false }) { Text("Cancel") }
                    }
                )
            }
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
        "section_header" -> {
            val title = node.optString("title")
            val trailing = node.optJSONObject("trailing")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = baseModifier
                    .fillMaxWidth()
                    .padding(top = 8.dp, bottom = 2.dp)
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.weight(1f)
                )
                if (trailing != null) {
                    SduiNode(trailing, surfaceId, revision, Modifier, dispatch)
                }
            }
        }
        "empty_state" -> {
            val iconName = node.optString("icon", "inbox")
            val title = node.optString("title")
            val caption = node.optString("caption")
            val actionJson = node.optJSONObject("on_tap")
            val actionLabel = node.optString("action_label")
            Column(
                modifier = baseModifier
                    .fillMaxWidth()
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    IconMap.get(iconName),
                    contentDescription = null,
                    modifier = Modifier.size(48.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                )
                if (title.isNotEmpty()) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center
                    )
                }
                if (caption.isNotEmpty()) {
                    Text(
                        caption,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        textAlign = TextAlign.Center
                    )
                }
                if (actionJson != null && actionLabel.isNotEmpty()) {
                    OutlinedButton(onClick = { dispatch(actionJson) }) { Text(actionLabel) }
                }
            }
        }
        "date_stamp" -> {
            DateStamp(node, baseModifier)
        }
        "menu" -> {
            // An overflow icon that opens a dropdown of items; each item
            // dispatches its action and closes the menu.
            val iconName = node.optString("icon", "more_vert")
            var menuOpen by remember { mutableStateOf(false) }
            val items = node.optJSONArray("items")
            Box(modifier = baseModifier) {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(IconMap.get(iconName), contentDescription = "More")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (items != null) {
                        for (i in 0 until items.length()) {
                            val item = items.optJSONObject(i) ?: continue
                            val label = item.optString("label")
                            val itemIcon = item.optString("icon", "")
                            val action = item.optJSONObject("on_tap")
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    menuOpen = false
                                    if (action != null) dispatch(action)
                                },
                                leadingIcon = if (itemIcon.isNotEmpty()) {
                                    { Icon(IconMap.get(itemIcon), null, Modifier.size(18.dp)) }
                                } else null
                            )
                        }
                    }
                }
            }
        }
        "scaffold" -> {
            SduiScaffold(spec = node, onAction = dispatch)
        }
    }
}

/** Map a named text style ("title"/"headline"/"caption"/"label"/"mono") to a TextStyle. */
@Composable
private fun textStyleForName(name: String): TextStyle = when (name) {
    "title" -> MaterialTheme.typography.titleLarge
    "headline" -> MaterialTheme.typography.headlineSmall
    "caption" -> MaterialTheme.typography.bodySmall
    "label" -> MaterialTheme.typography.labelMedium
    "mono" -> MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace)
    else -> MaterialTheme.typography.bodyLarge
}

/** Parse "HH:MM" into an (hour, minute) pair, clamped; defaults to 09:00. */
private fun parseHm(s: String): Pair<Int, Int> {
    val parts = s.split(":")
    val h = parts.getOrNull(0)?.toIntOrNull() ?: 9
    val m = parts.getOrNull(1)?.toIntOrNull() ?: 0
    return h.coerceIn(0, 23) to m.coerceIn(0, 59)
}

/** Parse "#RRGGBB" or "#AARRGGBB" to a Color; Color.Unspecified on failure. */
private fun parseHexColor(hex: String): Color {
    val h = hex.removePrefix("#")
    return try {
        val v = h.toLong(16)
        when (h.length) {
            6 -> Color(0xFF000000L or v)
            8 -> Color(v)
            else -> Color.Unspecified
        }
    } catch (e: NumberFormatException) {
        Color.Unspecified
    }
}

/** Month-tinted (header, header-text) color pair for a 1–12 month index. */
@Composable
private fun monthColors(monthIndex: Int): Pair<Color, Color> {
    val cs = MaterialTheme.colorScheme
    return when (((monthIndex - 1).coerceAtLeast(0)) % 6) {
        0 -> cs.primary to cs.onPrimary
        1 -> cs.secondary to cs.onSecondary
        2 -> cs.tertiary to cs.onTertiary
        3 -> cs.primaryContainer to cs.onPrimaryContainer
        4 -> cs.secondaryContainer to cs.onSecondaryContainer
        else -> cs.tertiaryContainer to cs.onTertiaryContainer
    }
}

/**
 * A compact date (and optional time) chip-card.
 * DTStampView: a month-tinted header, a large day number, and the year.
 * Fields: day, month (short label), year, optional time ("HH:MM"), and
 * month_index (1–12) which drives the header color.
 */
@Composable
private fun DateStamp(node: JSONObject, modifier: Modifier) {
    val day = node.optString("day")
    val month = node.optString("month")
    val year = node.optString("year")
    val time = node.optString("time")
    val (headerColor, headerText) = monthColors(node.optInt("month_index", 0))

    Column(modifier = modifier) {
        ElevatedCard(shape = RoundedCornerShape(6.dp), modifier = Modifier.width(64.dp)) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
            ) {
                if (month.isNotEmpty()) {
                    Text(
                        month,
                        style = MaterialTheme.typography.labelMedium,
                        color = headerText,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(headerColor, RoundedCornerShape(topStart = 6.dp, topEnd = 6.dp))
                            .padding(vertical = 2.dp)
                    )
                }
                Text(
                    day,
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(vertical = 2.dp)
                )
                if (year.isNotEmpty()) {
                    Text(
                        year,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                        modifier = Modifier.padding(bottom = 2.dp)
                    )
                }
            }
        }
        if (time.isNotEmpty()) {
            ElevatedCard(
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.width(64.dp).padding(top = 6.dp)
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Text(
                        "TIME",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.primary)
                            .padding(vertical = 2.dp)
                    )
                    Text(
                        time,
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(top = 4.dp, bottom = 2.dp)
                    )
                }
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

/** Parse "YYYY-MM-DD" to UTC-midnight millis for seeding the date picker; null if blank/invalid. */
private fun parseIsoDateUtc(iso: String): Long? {
    val parts = iso.split("-")
    if (parts.size != 3) return null
    val y = parts[0].toIntOrNull() ?: return null
    val m = parts[1].toIntOrNull() ?: return null
    val d = parts[2].toIntOrNull() ?: return null
    return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(y, m - 1, d)
    }.timeInMillis
}

/** Format the picker's UTC-midnight millis back to "YYYY-MM-DD" (no java.time; minSdk 24). */
private fun isoDateFromUtcMillis(millis: Long): String {
    val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = millis }
    return String.format(
        "%04d-%02d-%02d",
        cal.get(Calendar.YEAR), cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH)
    )
}

private fun dispatchStateChanged(context: Context, id: String, valueJson: String) {
    if (id.isEmpty()) return
    val intent = Intent(context, ActionReceiver::class.java).apply {
        action = ActionReceiver.ACTION_STATE_CHANGED
        putExtra(ActionReceiver.EXTRA_ID, id)
        putExtra(ActionReceiver.EXTRA_VALUE_JSON, valueJson)
    }
    context.sendBroadcast(intent)
}