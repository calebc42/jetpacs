package com.calebc42.eabp

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.onSizeChanged
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
import kotlin.concurrent.thread

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
    val context = LocalContext.current
    val id = node.optString("id")
    val readOnly = node.optBoolean("read_only", false)
    val onSave = node.optJSONObject("on_save")
    // Chromeless: no filename/undo/save header, compact height — an inline
    // field with the full bridge (the eval REPL input).
    val chrome = !node.optBoolean("chromeless", false)
    // Syntax defaults to the file's extension when Emacs doesn't say.
    val syntax = node.optString("syntax").ifEmpty { syntaxForPath(id) }
    // The formatting toolbar is server-driven: the spec names it (or omits
    // it), so this renderer carries no per-app file-type knowledge.
    val toolbar = node.optString("toolbar")

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

    // ── Emacs-backed sync + completion (eabp-sync.el / eabp-complete.el) ──
    // One engine per editor keeps a shadow buffer on the Emacs side current
    // via incremental deltas; completion requests then carry only a cursor.
    // Strictly event-driven and battery-shaped: fires only on a text change
    // (never a bare cursor move), debounced, and straight down the live
    // socket — never through the broadcast/queue/wake path, so offline
    // typing sends nothing and persists nothing.
    val completeEnabled = node.optBoolean("complete", false) && !readOnly
    var completionReq by remember(id) { mutableStateOf(0) }
    val syncEngine = remember(id) { EditorSyncEngine(id) }
    if (completeEnabled) {
        // Seed (or reseed) the session whenever a handshaked connection is
        // available — covers first composition, reconnects, Emacs restarts.
        val connected by EabpRuntime.connected.collectAsState()
        LaunchedEffect(connected) {
            if (connected) withContext(Dispatchers.IO) { syncEngine.open(tfv.text) }
        }
        // Emacs asks for a full-text reseed after any seq mismatch.
        val resyncReq by EabpRuntime.editSyncState.resync.collectAsState()
        LaunchedEffect(resyncReq) {
            val r = resyncReq ?: return@LaunchedEffect
            if (r.optString("id") == id && r.optInt("session") == syncEngine.session) {
                withContext(Dispatchers.IO) { syncEngine.open(tfv.text) }
            }
        }
        // The debounced pipeline: delta first, then (token permitting) the
        // slim completion request, then the caret report for eldoc. All
        // ride one ordered socket, so Emacs always answers against the
        // text the user is looking at. Bare cursor moves skip the delta
        // and completion but still report the caret.
        var lastHandled by remember(id) { mutableStateOf(specValue) }
        LaunchedEffect(tfv.text, tfv.selection) {
            val textChanged = tfv.text != lastHandled
            delay(COMPLETION_DEBOUNCE_MS)
            lastHandled = tfv.text
            val text = tfv.text
            val sel = tfv.selection
            val collapsed = sel.start == sel.end
            val prefix = if (collapsed) wordPrefixAt(text, sel.start) else ""
            // LSP-style trigger characters: right after "." (member access)
            // or ":" (keywords, paths) completion is wanted with no token.
            val triggered = collapsed && prefix.isEmpty() && sel.start > 0 &&
                text[sel.start - 1] in COMPLETION_TRIGGER_CHARS
            val wantCompletion = textChanged &&
                (prefix.length >= COMPLETION_MIN_PREFIX || triggered)
            val req = if (wantCompletion) ++completionReq else completionReq
            withContext(Dispatchers.IO) {
                if (wantCompletion) syncEngine.requestCompletions(text, sel.start, req)
                else if (textChanged) syncEngine.update(text)
                if (collapsed) syncEngine.caret(text, sel.start)
            }
        }
        // Tear down the Emacs-side session on dispose. The shared push slots
        // (diagnostics/fontify/eldoc) are deliberately NOT cleared: every
        // consumer gates by editor id + session, so a stale payload is inert
        // — whereas clearing here raced pushes meant for the editor being
        // switched TO (two editors are live now: files + the eval REPL).
        DisposableEffect(id) {
            onDispose {
                EabpRuntime.completionState.clear()
                thread(name = "EabpEditClose") { syncEngine.close() }
            }
        }
    }

    // Flymake diagnostics from the synced shadow. Rendered only while the
    // payload's session/seq match the engine AND the text hasn't moved on —
    // squiggles are hidden during the debounce gap rather than mis-drawn.
    val diagPayload by EabpRuntime.editSyncState.diagnostics.collectAsState()
    val diagRanges = if (completeEnabled)
        remember(diagPayload, tfv.text) {
            diagnosticRanges(diagPayload, id, syncEngine, tfv.text)
        }
    else emptyList()
    val diagColors = mapOf(
        "error" to MaterialTheme.colorScheme.error,
        "warning" to Color(0xFFC08A00),
        "note" to MaterialTheme.colorScheme.outline,
    )

    // Emacs-pushed fontification: when current, it REPLACES the client-side
    // highlighter (the user's real theme, every mode Emacs knows); while a
    // keystroke is in flight it goes stale and the client highlighter
    // bridges the gap. Diagnostics compose on top of either.
    val fontifyPayload by EabpRuntime.editSyncState.fontify.collectAsState()
    val fontifyRuns = if (!completeEnabled) emptyList() else
        remember(fontifyPayload, tfv.text) {
            fontifyRuns(fontifyPayload, id, syncEngine, tfv.text)
        }
    val baseTransformation = if (fontifyRuns.isEmpty()) highlight
        else remember(fontifyRuns) { FontifyTransformation(fontifyRuns) }
    val fieldTransformation = if (diagRanges.isEmpty()) baseTransformation
        else remember(baseTransformation, diagRanges, diagColors) {
            DiagnosticsTransformation(baseTransformation, diagRanges, diagColors)
        }

    // publish_state: mirror the text into ui-state like a text_input, so
    // button-driven forms (the Eval button) can read it back.
    if (node.optBoolean("publish_state", false)) {
        var lastPublished by remember(id) { mutableStateOf<String?>(null) }
        LaunchedEffect(tfv.text) {
            if (lastPublished == null) {
                lastPublished = tfv.text
                return@LaunchedEffect
            }
            if (tfv.text == lastPublished) return@LaunchedEffect
            delay(250)
            if (tfv.text != lastPublished) {
                lastPublished = tfv.text
                dispatchStateChanged(context, id, JSONObject.quote(tfv.text))
            }
        }
    }

    // Eldoc content for the caret position (e.g. an elisp signature).
    // Session-gated; benign staleness (≤ one debounce) is acceptable here,
    // unlike squiggles, since it's advisory text rather than a text overlay.
    val eldocPayload by EabpRuntime.editSyncState.eldoc.collectAsState()
    val eldocText = if (!completeEnabled) "" else
        eldocPayload?.takeIf {
            it.optString("id") == id && it.optInt("session") == syncEngine.session
        }?.optString("text").orEmpty()

    Column(
        modifier = modifier.then(
            if (chrome) Modifier.fillMaxSize().imePadding() else Modifier.fillMaxWidth()
        )
    ) {
        if (chrome) Row(
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
            // Full-chrome editors own the screen (weight); chromeless ones
            // size like a large input field within their parent layout.
            val sizing = if (chrome) Modifier.weight(1f)
                else Modifier.heightIn(min = 96.dp, max = 200.dp)
            OutlinedTextField(
                value = tfv,
                onValueChange = { if (!readOnly) tfv = it },
                readOnly = readOnly,
                visualTransformation = fieldTransformation,
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = FontFamily.Monospace,
                    lineHeight = 1.4.em
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .then(sizing)
                    .padding(if (chrome) 8.dp else 2.dp)
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
            // Keep the caret visible. BasicTextField inside an EXTERNAL scroll
            // container never scrolls its own cursor into view — so typing
            // below the fold, or the IME opening (which shrinks the viewport
            // via imePadding), left the caret hidden behind the keyboard.
            var viewportHeight by remember(id) { mutableStateOf(0) }
            LaunchedEffect(tfv.selection, textLayout, viewportHeight) {
                val lr = textLayout ?: return@LaunchedEffect
                if (viewportHeight <= 0) return@LaunchedEffect
                val off = tfv.selection.start.coerceIn(0, lr.layoutInput.text.length)
                val line = lr.getLineForOffset(off)
                val top = lr.getLineTop(line).toInt()
                val bottom = lr.getLineBottom(line).toInt()
                val margin = (bottom - top).coerceAtLeast(1) * 2 // ≈ two lines
                when {
                    bottom + margin > scrollState.value + viewportHeight ->
                        scrollState.animateScrollTo(
                            (bottom + margin - viewportHeight).coerceAtLeast(0))
                    top - margin < scrollState.value ->
                        scrollState.animateScrollTo((top - margin).coerceAtLeast(0))
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .onSizeChanged { viewportHeight = it.height }
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
                    visualTransformation = fieldTransformation,
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
        // The doc line — mobile eldoc: a diagnostic under the cursor takes
        // precedence; otherwise the eldoc content for the caret (an elisp
        // signature, a variable docstring) shows here, above the keyboard.
        if (completeEnabled && tfv.selection.start == tfv.selection.end) {
            val cursor = tfv.selection.start
            val hit = diagRanges.firstOrNull { cursor >= it.start && cursor <= it.end }
            when {
                hit != null -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)
                ) {
                    Text(
                        "● ",
                        style = MaterialTheme.typography.labelSmall,
                        color = diagColors[hit.severity] ?: diagColors["warning"]!!
                    )
                    Text(
                        hit.message,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2
                    )
                }
                eldocText.isNotEmpty() -> Text(
                    eldocText,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)
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
        // Server-requested formatting toolbar — sits at the bottom of the
        // editor, just above the soft keyboard (keyboard-adjacent, à la
        // Orgro). "org" is the only toolbar this renderer ships today.
        if (toolbar == "org" && !readOnly) {
            OrgEditToolbar(value = tfv, onValueChange = onToolbarChange)
        }
    }
}

// ─── Completion strip ────────────────────────────────────────────────────────

private const val COMPLETION_DEBOUNCE_MS = 300L
private const val COMPLETION_MIN_PREFIX = 2
private const val COMPLETION_TRIGGER_CHARS = ".:"

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
 * Convert a `diagnostics.show` payload into renderable ranges against the
 * CURRENT editor text. Returns nothing unless the payload belongs to this
 * editor's session AND the engine confirms the text is exactly what that
 * seq was computed over — stale squiggles are dropped, never mis-drawn.
 * Offsets arrive as code points (Emacs chars) and convert to UTF-16 here.
 */
private fun diagnosticRanges(
    payload: JSONObject?,
    editorId: String,
    engine: EditorSyncEngine,
    text: String,
): List<DiagRange> {
    val p = payload ?: return emptyList()
    if (p.optString("id") != editorId) return emptyList()
    if (!engine.isCurrent(text, p.optInt("session"), p.optInt("seq"))) return emptyList()
    val arr = p.optJSONArray("diags") ?: return emptyList()
    val cpTotal = text.codePointCount(0, text.length)
    return buildList {
        for (i in 0 until arr.length()) {
            val d = arr.optJSONObject(i) ?: continue
            val begCp = d.optInt("beg").coerceIn(0, cpTotal)
            val endCp = d.optInt("end").coerceIn(begCp, cpTotal)
            var beg = text.offsetByCodePoints(0, begCp)
            var end = text.offsetByCodePoints(0, endCp)
            // Zero-width diagnostics still deserve a visible mark.
            if (end == beg) {
                if (end < text.length) end++ else if (beg > 0) beg--
            }
            if (end > beg) {
                add(DiagRange(beg, end,
                    d.optString("type", "warning"), d.optString("text")))
            }
        }
    }
}

/**
 * Convert a `fontify.show` payload into renderable runs against the CURRENT
 * editor text — same gating as diagnostics: session/seq/text must all match,
 * so stale colors are dropped (the client highlighter bridges the gap),
 * never smeared across moved text. Offsets arrive as code points.
 */
private fun fontifyRuns(
    payload: JSONObject?,
    editorId: String,
    engine: EditorSyncEngine,
    text: String,
): List<FontifyRun> {
    val p = payload ?: return emptyList()
    if (p.optString("id") != editorId) return emptyList()
    if (!engine.isCurrent(text, p.optInt("session"), p.optInt("seq"))) return emptyList()
    val arr = p.optJSONArray("runs") ?: return emptyList()
    val cpTotal = text.codePointCount(0, text.length)
    return buildList {
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            val begCp = r.optInt("b").coerceIn(0, cpTotal)
            val endCp = r.optInt("e").coerceIn(begCp, cpTotal)
            val beg = text.offsetByCodePoints(0, begCp)
            val end = text.offsetByCodePoints(0, endCp)
            if (end <= beg) continue
            val color = r.optString("c").takeIf { it.isNotEmpty() }?.let { hex ->
                runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrNull()
            }
            add(FontifyRun(
                start = beg, end = end, color = color,
                bold = r.optBoolean("bold"),
                italic = r.optBoolean("italic"),
                underline = r.optBoolean("underline"),
                strike = r.optBoolean("strike"),
            ))
        }
    }
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
    // base may legitimately be empty: trigger-character completion (right
    // after ".") replaces nothing and inserts at the cursor.
    val base = p.optString("prefix")
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
