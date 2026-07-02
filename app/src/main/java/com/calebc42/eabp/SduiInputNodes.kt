package com.calebc42.eabp

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone

/**
 * Input-family SDUI nodes: text fields, the file editor, toggles, the
 * enum-chip list, and the date/time picker buttons. All local state is
 * seed-guarded (see [rememberSeeded]) so background surface re-pushes
 * never stomp what the user is typing.
 */

/**
 * Seed-guarded local state for stateful nodes.
 *
 * Background surface pushes re-deliver specs constantly (multi-view
 * dashboard refreshes), so a node's local state must only adopt a new
 * spec value when the user hasn't diverged from the last seed — otherwise
 * a refresh stomps text mid-typing. Returns (state, lastSeed).
 */
@Composable
internal fun rememberSeeded(id: String, specValue: String): Pair<MutableState<String>, MutableState<String>> {
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
internal fun rememberSeededBool(id: String, specValue: Boolean): Pair<MutableState<Boolean>, MutableState<Boolean>> {
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
internal fun SduiTextInput(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val context = LocalContext.current
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

    // Debounced state.changed: a broadcast per keystroke flooded the
    // bridge (one frame — or one queue insert offline — per character,
    // and a full dialog re-push from the live-filter picker). 250ms
    // after typing pauses is fresh enough.
    var lastSent by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(text) {
        if (lastSent == null) {
            lastSent = text          // initial composition: nothing typed yet
            return@LaunchedEffect
        }
        if (text == lastSent) return@LaunchedEffect
        delay(250)
        if (text != lastSent) {
            lastSent = text
            dispatchStateChanged(context, id, JSONObject.quote(text))
        }
    }

    OutlinedTextField(
        value = text,
        onValueChange = { text = it },
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
        modifier = modifier.fillMaxWidth(),
        keyboardOptions = KeyboardOptions(
            imeAction = if (singleLine) ImeAction.Done else ImeAction.Default
        ),
        keyboardActions = KeyboardActions(onDone = {
            if (onSubmit != null) dispatchWithValue(dispatch, onSubmit, text)
            // Flush immediately; the debounce may still be pending.
            lastSent = text
            dispatchStateChanged(context, id, JSONObject.quote(text))
        })
    )
}

/**
 * Full-height plain-text editor with modified-tracking. The save button
 * dispatches `on_save` with the full text injected into args as `value`.
 * Note: action delivery rides a broadcast intent, so very large files
 * must arrive read_only from Emacs.
 *
 * Uses TextFieldValue (not plain String) so the formatting toolbar can
 * read/set cursor position and selection for smart insertions.
 */
@Composable
internal fun SduiEditor(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
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

    // ── Emacs-backed completion (see eabp-complete.el) ───────────
    // Strictly event-driven and battery-shaped: fires only on a text
    // change (never a bare cursor move), debounced, only with a
    // completable token at a collapsed cursor, and straight down the
    // live socket — never through the broadcast/queue/wake path, so
    // offline typing sends nothing and persists nothing.
    val completeEnabled = node.optBoolean("complete", false) && !readOnly
    var completionReq by remember(id) { mutableStateOf(0) }
    if (completeEnabled) {
        var lastCompletedFor by remember(id) { mutableStateOf(specValue) }
        LaunchedEffect(tfv.text) {
            if (tfv.text == lastCompletedFor) return@LaunchedEffect
            delay(COMPLETION_DEBOUNCE_MS)
            lastCompletedFor = tfv.text
            val sel = tfv.selection
            if (sel.start != sel.end) return@LaunchedEffect
            val prefix = wordPrefixAt(tfv.text, sel.start)
            if (prefix.length < COMPLETION_MIN_PREFIX) return@LaunchedEffect
            val req = ++completionReq
            val text = tfv.text
            withContext(Dispatchers.IO) {
                sendCompletionRequest(id, text, sel.start, req)
            }
        }
        // A reply arriving after the editor is gone must not linger for
        // the next editor composition.
        DisposableEffect(id) {
            onDispose { EabpRuntime.completionState.clear() }
        }
    }

    Column(modifier = modifier.fillMaxSize().imePadding()) {
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
                        dispatchWithValue(dispatch, onSave, tfv.text)
                        seed = tfv.text
                    }
                },
                enabled = modified && !readOnly && onSave != null
            ) { Text("Save") }
        }
        val lineNumbers = node.optString("line_numbers")
        if (lineNumbers.isEmpty()) {
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
        } else {
            // Gutter mode. BasicTextField exposes onTextLayout, which gives
            // accurate per-logical-line Y positions even when long lines
            // soft-wrap; gutter and field share ONE scroll container so they
            // can never desynchronize.
            var textLayout by remember(id) { mutableStateOf<TextLayoutResult?>(null) }
            val scrollState = rememberScrollState()
            val lineStarts = remember(tfv.text) {
                buildList {
                    add(0)
                    tfv.text.forEachIndexed { i, c -> if (c == '\n') add(i + 1) }
                }
            }
            val cursorLine = lineStarts.indexOfLast { it <= tfv.selection.start }
                .coerceAtLeast(0)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(scrollState)
                    .padding(8.dp)
            ) {
                EditorGutter(
                    lineStarts = lineStarts,
                    cursorLine = cursorLine,
                    relative = lineNumbers == "relative",
                    layout = textLayout
                )
                BasicTextField(
                    value = tfv,
                    onValueChange = { if (!readOnly) tfv = it },
                    readOnly = readOnly,
                    visualTransformation = highlight,
                    onTextLayout = { textLayout = it },
                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                        fontFamily = FontFamily.Monospace,
                        lineHeight = 1.4.em,
                        color = MaterialTheme.colorScheme.onSurface
                    ),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.weight(1f)
                )
            }
        }
        // Completion suggestion strip — the mobile-native "posframe":
        // keyboard-adjacent chips, tap to accept (the phone's TAB).
        // Insertion is applied locally via the toolbar path so each
        // acceptance is one undo point; no round trip to Emacs.
        if (completeEnabled) {
            CompletionStrip(
                editorId = id,
                requestId = completionReq,
                tfv = tfv,
                onAccept = onToolbarChange
            )
        }
        // Org formatting toolbar — sits at the bottom of the editor,
        // just above the soft keyboard (keyboard-adjacent, à la Orgro).
        if (isOrg && !readOnly) {
            OrgEditToolbar(value = tfv, onValueChange = onToolbarChange)
        }
    }
}

// ─── Completion strip ────────────────────────────────────────────────────────

private const val COMPLETION_DEBOUNCE_MS = 300L
private const val COMPLETION_MIN_PREFIX = 2
/** Text window shipped with a request: enough context for capf/dabbrev
 *  without paying full-file serialization on every pause in typing. */
private const val COMPLETION_WINDOW_BEFORE = 8_000
private const val COMPLETION_WINDOW_AFTER = 1_000

/** Token characters for the completion prefix; mirrors the Emacs-side
 *  word/symbol syntax closely enough for lisp-case and snake_case. */
private fun isTokenChar(c: Char) = c.isLetterOrDigit() || c == '-' || c == '_'

/** The word/symbol token ending at CURSOR, or "" when none. */
internal fun wordPrefixAt(text: String, cursor: Int): String {
    val end = cursor.coerceIn(0, text.length)
    var i = end
    while (i > 0 && isTokenChar(text[i - 1])) i--
    return text.substring(i, end)
}

/**
 * Fire one `edit.complete` action straight down the live socket.
 *
 * Deliberately NOT routed through [ActionReceiver]: completion is ephemeral
 * and latency-bound, so it must never enter the offline Room queue, never
 * wake Emacs, and never cost a broadcast round-trip. No handshaked
 * connection → no request. Call from a background dispatcher (socket write).
 */
private fun sendCompletionRequest(file: String, text: String, cursor: Int, requestId: Int) {
    val conn = EabpRuntime.server?.connection() ?: return
    if (!conn.helloComplete) return
    val wStart = (cursor - COMPLETION_WINDOW_BEFORE).coerceAtLeast(0)
    val wEnd = (cursor + COMPLETION_WINDOW_AFTER).coerceAtMost(text.length)
    val payload = JSONObject().apply {
        put("surface", "editor")
        put("revision_seen", -1)
        put("action", "edit.complete")
        put("args", JSONObject().apply {
            put("file", file)
            put("request_id", requestId)
            put("text", text.substring(wStart, wEnd))
            put("cursor", cursor - wStart)
        })
        put("fields", JSONObject.NULL)
        put("queued_at", JSONObject.NULL)
    }
    conn.send(Frame(kind = "event.action", payload = payload))
}

/**
 * Horizontal chip row of completion candidates from the latest
 * `completions.show` payload. Self-validating: renders nothing unless the
 * payload matches this editor and request AND the completed prefix still
 * sits immediately before the cursor. Characters typed after the request
 * narrow the list client-side instead of waiting on another round trip.
 */
@Composable
private fun CompletionStrip(
    editorId: String,
    requestId: Int,
    tfv: TextFieldValue,
    onAccept: (TextFieldValue) -> Unit,
) {
    val payload by EabpRuntime.completionState.current.collectAsState()
    val p = payload ?: return
    if (p.optString("id") != editorId || p.optInt("request_id") != requestId) return
    val candidates = p.optJSONArray("candidates") ?: return
    if (candidates.length() == 0) return
    if (tfv.selection.start != tfv.selection.end) return
    val cursor = tfv.selection.start
    val base = p.optString("prefix")
    if (base.isEmpty()) return
    val word = wordPrefixAt(tfv.text, cursor)
    // The effective prefix to replace: the current token when the user kept
    // typing it, the original when capf chose wider boundaries (e.g. paths),
    // nothing when the token changed — then the reply is stale, show nothing.
    val effective = when {
        word.startsWith(base) -> word
        cursor >= base.length &&
            tfv.text.regionMatches(cursor - base.length, base, 0, base.length) -> base
        else -> return
    }
    val visible = buildList {
        for (i in 0 until candidates.length()) {
            val c = candidates.optJSONObject(i) ?: continue
            val label = c.optString("label")
            if (label.startsWith(effective) && label != effective) add(c)
        }
    }
    if (visible.isEmpty()) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        visible.forEach { c ->
            val label = c.optString("label")
            val annotation = c.optString("annotation")
            AssistChip(
                onClick = {
                    val start = cursor - effective.length
                    val newText = tfv.text.substring(0, start) + label +
                        tfv.text.substring(cursor)
                    onAccept(TextFieldValue(newText, TextRange(start + label.length)))
                    EabpRuntime.completionState.clear()
                },
                label = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            label,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall
                        )
                        if (annotation.isNotEmpty()) {
                            Text(
                                " $annotation",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            )
        }
    }
}

@Composable
internal fun SduiCheckbox(node: JSONObject, modifier: Modifier) {
    val context = LocalContext.current
    val id = node.optString("id")
    val (checkedState, _) = rememberSeededBool(id, node.optBoolean("checked", false))
    var checked by checkedState
    val label = node.optString("label")

    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        Checkbox(checked = checked, onCheckedChange = {
            checked = it
            dispatchStateChanged(context, id, it.toString())
        })
        if (label.isNotEmpty()) Text(label, modifier = Modifier.padding(start = 8.dp))
    }
}

@Composable
internal fun SduiSwitch(node: JSONObject, modifier: Modifier) {
    val context = LocalContext.current
    val id = node.optString("id")
    val (checkedState, _) = rememberSeededBool(id, node.optBoolean("checked", false))
    var checked by checkedState
    val label = node.optString("label")

    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        if (label.isNotEmpty()) Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = {
            checked = it
            dispatchStateChanged(context, id, it.toString())
        })
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SduiEnumList(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val context = LocalContext.current
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

    // Shared commit path for chip toggles and newly added options.
    val applySelection: (MutableSet<String>) -> Unit = { newSet ->
        selected = newSet
        dispatchStateChanged(context, id, JSONArray(newSet).toString())
        if (onChange != null) dispatchWithValue(dispatch, onChange, JSONArray(newSet))
    }

    FlowRow(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        options.forEach { opt ->
            FilterChip(
                selected = selected.contains(opt),
                onClick = {
                    val newSet = selected.toMutableSet()
                    if (!newSet.remove(opt)) {
                        if (!multiSelect) newSet.clear()
                        newSet.add(opt)
                    }
                    applySelection(newSet)
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
        val addOption = {
            val opt = newOption.trim()
            if (opt.isNotEmpty() && !options.contains(opt)) {
                options = (options + opt).toMutableList()
                val newSet = selected.toMutableSet()
                if (!multiSelect) newSet.clear()
                newSet.add(opt)
                applySelection(newSet)
            }
            showAddDialog = false
        }
        AlertDialog(
            onDismissRequest = { showAddDialog = false },
            title = { Text("Add Option") },
            text = {
                OutlinedTextField(
                    value = newOption,
                    onValueChange = { newOption = it },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { addOption() })
                )
            },
            confirmButton = {
                TextButton(onClick = addOption) { Text("Add") }
            },
            dismissButton = {
                TextButton(onClick = { showAddDialog = false }) { Text("Cancel") }
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SduiDateButton(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val label = node.optString("label")
    val onPick = node.optJSONObject("on_pick")
    val initial = node.optString("value")
    var show by remember { mutableStateOf(false) }

    OutlinedButton(onClick = { show = true }, modifier = modifier) { Text(label) }

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
                        dispatchWithValue(dispatch, onPick, isoDateFromUtcMillis(millis))
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SduiTimeButton(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val label = node.optString("label")
    val onPick = node.optJSONObject("on_pick")
    val initial = node.optString("value")
    var show by remember { mutableStateOf(false) }

    OutlinedButton(onClick = { show = true }, modifier = modifier) { Text(label) }

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
                        dispatchWithValue(
                            dispatch, onPick,
                            String.format("%02d:%02d", pickerState.hour, pickerState.minute)
                        )
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

/**
 * The editor's line-number gutter: one Canvas whose height matches the text
 * layout, drawing each logical line's number at that line's real Y position
 * (so soft-wrapped lines simply leave a numberless gap, like Emacs).
 * Relative mode counts distance from the cursor line, which shows its
 * absolute number highlighted — vim's hybrid style.
 */
@Composable
private fun EditorGutter(
    lineStarts: List<Int>,
    cursorLine: Int,
    relative: Boolean,
    layout: TextLayoutResult?,
) {
    val measurer = rememberTextMeasurer()
    val dim = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
    val current = MaterialTheme.colorScheme.primary
    val style = TextStyle(fontSize = 11.sp, fontFamily = FontFamily.Monospace)
    val density = LocalDensity.current
    val digits = lineStarts.size.toString().length.coerceAtLeast(2)
    val gutterWidth = ((digits * 8) + 10).dp
    val heightDp = with(density) { (layout?.size?.height ?: 0).toDp() }

    Canvas(modifier = Modifier.width(gutterWidth).height(heightDp)) {
        val lr = layout ?: return@Canvas
        val maxOffset = lr.layoutInput.text.length
        for (i in lineStarts.indices) {
            val off = lineStarts[i].coerceAtMost(maxOffset)
            val top = lr.getLineTop(lr.getLineForOffset(off))
            val num = if (relative && i != cursorLine) kotlin.math.abs(i - cursorLine) else i + 1
            val measured = measurer.measure(num.toString(), style)
            drawText(
                measured,
                color = if (i == cursorLine) current else dim,
                topLeft = Offset(size.width - measured.size.width - 6.dp.toPx(), top)
            )
        }
    }
}

/** Parse "HH:MM" into an (hour, minute) pair, clamped; defaults to 09:00. */
private fun parseHm(s: String): Pair<Int, Int> {
    val parts = s.split(":")
    val h = parts.getOrNull(0)?.toIntOrNull() ?: 9
    val m = parts.getOrNull(1)?.toIntOrNull() ?: 0
    return h.coerceIn(0, 23) to m.coerceIn(0, 59)
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
