package com.calebc42.eabp

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.text.input.TextFieldState
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
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.snapshotFlow
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
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
    val password = node.optBoolean("password", false)
    val monospace = node.optBoolean("monospace", false) || syntax.isNotEmpty()
    val highlight = when {
        // A masked field takes precedence: never highlight (or reveal) a secret.
        password -> PasswordVisualTransformation()
        syntax.isNotEmpty() -> {
            val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
            val sc = remember(dark) { SyntaxColors.forBackground(dark) }
            remember(syntax, sc) { SyntaxTransformation(syntax, sc) }
        }
        else -> VisualTransformation.None
    }

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
            keyboardType = if (password) KeyboardType.Password else KeyboardType.Text,
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
 * Built on [TextFieldState]: the IME edits the buffer directly instead of
 * round-tripping value/onValueChange through recomposition, so a slow frame
 * can no longer drop or double characters — and styling runs once per text
 * change (as an OutputTransformation) instead of per layout pass.
 */
@OptIn(ExperimentalFoundationApi::class) // undoState
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

    val specValue = node.optString("value", "")
    val state = remember(id) { TextFieldState(specValue) }
    var seed by remember(id) { mutableStateOf(specValue) }
    // Adopt new spec values only when the user hasn't diverged
    // (same seed-guard logic as rememberSeeded, but against the buffer).
    LaunchedEffect(specValue) {
        if (specValue != seed) {
            if (state.text.contentEquals(seed)) {
                state.edit { replace(0, length, specValue) }
            }
            seed = specValue
        }
    }
    // The O(n) compare reruns per keystroke, but derivedStateOf means the
    // chrome recomposes only when the flag actually flips.
    val modified by remember(id) { derivedStateOf { !state.text.contentEquals(seed) } }
    val fileName = id.substringAfterLast('/').ifEmpty { "untitled" }

    // Bridge for the TextFieldValue-based helpers (toolbar inserts,
    // completion acceptance): read on demand — never during typing — and
    // apply as one minimal splice, so each action is one undoable edit
    // with the cursor where the helper put it.
    val readValue: () -> TextFieldValue = {
        TextFieldValue(state.text.toString(), state.selection)
    }
    val applyValue: (TextFieldValue) -> Unit = { new ->
        val s = splice(state.text.toString(), new.text)
        state.edit {
            if (s != null) replace(s.start, s.start + s.deleted, s.inserted)
            selection = new.selection
        }
    }

    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    val sc = remember(dark) { SyntaxColors.forBackground(dark) }
    val diagColors = mapOf(
        "error" to MaterialTheme.colorScheme.error,
        "warning" to Color(0xFFC08A00),
        "note" to MaterialTheme.colorScheme.outline,
    )

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

    // Emacs-pushed styling, parsed ONCE per push (off the main thread) and
    // pinned to the exact text it describes. [EditorStyles] applies a set
    // exactly on a content match and splice-shifted while typing has moved
    // the buffer a small local edit away, so the palette never flaps —
    // and an undo back to synced text restores exact Emacs colors.
    var fontifySet by remember(id) { mutableStateOf<FontifySet?>(null) }
    var diagSet by remember(id) { mutableStateOf<DiagSet?>(null) }

    if (completeEnabled) {
        // Seed (or reseed) the session whenever a handshaked connection is
        // available — covers first composition, reconnects, Emacs restarts.
        val connected by EabpRuntime.connected.collectAsState()
        LaunchedEffect(connected) {
            if (connected) withContext(Dispatchers.IO) {
                syncEngine.open(state.text.toString())
            }
        }
        // Emacs asks for a full-text reseed after any seq mismatch.
        val resyncReq by EabpRuntime.editSyncState.resync.collectAsState()
        LaunchedEffect(resyncReq) {
            val r = resyncReq ?: return@LaunchedEffect
            if (r.optString("id") == id && r.optInt("session") == syncEngine.session) {
                withContext(Dispatchers.IO) { syncEngine.open(state.text.toString()) }
            }
        }
        val fontifyPayload by EabpRuntime.editSyncState.fontify.collectAsState()
        LaunchedEffect(fontifyPayload) {
            val p = fontifyPayload ?: return@LaunchedEffect
            val text = state.text.toString()
            withContext(Dispatchers.Default) {
                parseFontify(p, id, syncEngine, text)
            }?.let { fontifySet = it }
        }
        val diagPayload by EabpRuntime.editSyncState.diagnostics.collectAsState()
        LaunchedEffect(diagPayload) {
            val p = diagPayload ?: return@LaunchedEffect
            val text = state.text.toString()
            withContext(Dispatchers.Default) {
                parseDiagnostics(p, id, syncEngine, text)
            }?.let { diagSet = it }
        }
        // The debounced pipeline: delta first, then (token permitting) the
        // slim completion request, then the caret report for eldoc. All
        // ride one ordered socket, so Emacs always answers against the
        // text the user is looking at. Bare cursor moves skip the delta
        // and completion but still report the caret. collectLatest restarts
        // the debounce on every buffer or cursor change, exactly like the
        // old per-value effect keying — but the full string materializes
        // only once per pause, not once per keystroke.
        LaunchedEffect(id) {
            var lastHandled: CharSequence = state.text
            snapshotFlow { state.text to state.selection }
                .collectLatest { (textSeq, sel) ->
                    val textChanged = !textSeq.contentEquals(lastHandled)
                    delay(COMPLETION_DEBOUNCE_MS)
                    val text = textSeq.toString()
                    lastHandled = text
                    val collapsed = sel.collapsed
                    val prefix = if (collapsed) wordPrefixAt(text, sel.start) else ""
                    // LSP-style trigger characters: right after "." (member
                    // access) or ":" (keywords, paths) completion is wanted
                    // with no token.
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

    // Diagnostics for the doc line, valid only while the buffer still holds
    // the exact text they were computed over (contentEquals rejects on
    // length first, so the per-keystroke cost is trivial). The squiggles
    // themselves are drawn by [EditorStyles] under the same content gate.
    val diagRanges by remember(id) {
        derivedStateOf {
            val ds = diagSet
            if (ds != null && state.text.contentEquals(ds.text)) ds.ranges
            else emptyList()
        }
    }

    // The whole styling pipeline — Emacs runs when current or shiftable,
    // client-side tokenizer for first paint and big edits, diagnostics on
    // top — as one transformation, recreated once per Emacs push (not per
    // keystroke).
    val outputTx = remember(fontifySet, diagSet, syntax, sc, diagColors) {
        EditorStyles(fontifySet, diagSet, syntax, sc, diagColors)
    }

    // publish_state: mirror the text into ui-state like a text_input, so
    // button-driven forms (the Eval button) can read it back.
    if (node.optBoolean("publish_state", false)) {
        LaunchedEffect(id) {
            var lastPublished: CharSequence = state.text
            snapshotFlow { state.text }
                .collectLatest { t ->
                    if (t.contentEquals(lastPublished)) return@collectLatest
                    delay(250)
                    val s = t.toString()
                    lastPublished = s
                    dispatchStateChanged(context, id, JSONObject.quote(s))
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
            // Undo / Redo — the field's built-in history: the platform
            // groups IME edits into natural units, and every programmatic
            // state.edit block (toolbar action, completion acceptance,
            // revert) records as exactly one step.
            IconButton(
                onClick = { state.undoState.undo() },
                enabled = state.undoState.canUndo && !readOnly
            ) { Icon(IconMap.get("undo"), contentDescription = "Undo") }
            IconButton(
                onClick = { state.undoState.redo() },
                enabled = state.undoState.canRedo && !readOnly
            ) { Icon(IconMap.get("redo"), contentDescription = "Redo") }
            TextButton(
                onClick = {
                    val s = seed
                    state.edit { replace(0, length, s) }
                },
                enabled = modified && !readOnly
            ) { Text("Revert") }
            Button(
                onClick = {
                    if (onSave != null) {
                        val text = state.text.toString()
                        dispatchWithValue(dispatch, onSave, text)
                        seed = text
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
                state = state,
                readOnly = readOnly,
                outputTransformation = outputTx,
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
            // can never desynchronize. The state-based onTextLayout hands
            // over a getter for the latest layout instead of the result
            // itself; it reads snapshot state, so readers auto-invalidate.
            var textLayout by remember(id) {
                mutableStateOf<(() -> TextLayoutResult?)?>(null)
            }
            val scrollState = rememberScrollState()
            // derivedStateOf: the O(n) line scan reruns per edit, but the
            // gutter recomposes only when line starts actually shift.
            val lineStarts by remember(id) {
                derivedStateOf {
                    val t = state.text
                    buildList {
                        add(0)
                        for (i in t.indices) if (t[i] == '\n') add(i + 1)
                    }
                }
            }
            val cursorLine by remember(id) {
                derivedStateOf {
                    lineStarts.indexOfLast { it <= state.selection.start }
                        .coerceAtLeast(0)
                }
            }
            // Keep the caret visible. BasicTextField inside an EXTERNAL scroll
            // container never scrolls its own cursor into view — so typing
            // below the fold, or the IME opening (which shrinks the viewport
            // via imePadding), left the caret hidden behind the keyboard.
            var viewportHeight by remember(id) { mutableStateOf(0) }
            LaunchedEffect(id) {
                snapshotFlow {
                    Triple(state.selection, viewportHeight, textLayout?.invoke())
                }.collectLatest { (sel, vh, lr) ->
                    if (lr == null || vh <= 0) return@collectLatest
                    val off = sel.start.coerceIn(0, lr.layoutInput.text.length)
                    val line = lr.getLineForOffset(off)
                    val top = lr.getLineTop(line).toInt()
                    val bottom = lr.getLineBottom(line).toInt()
                    val margin = (bottom - top).coerceAtLeast(1) * 2 // ≈ two lines
                    when {
                        bottom + margin > scrollState.value + vh ->
                            scrollState.animateScrollTo(
                                (bottom + margin - vh).coerceAtLeast(0))
                        top - margin < scrollState.value ->
                            scrollState.animateScrollTo((top - margin).coerceAtLeast(0))
                    }
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
                    layout = textLayout?.invoke()
                )
                BasicTextField(
                    state = state,
                    readOnly = readOnly,
                    outputTransformation = outputTx,
                    onTextLayout = { getResult -> textLayout = getResult },
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
        if (completeEnabled && state.selection.collapsed) {
            val cursor = state.selection.start
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
        // Insertion is applied locally as one undoable edit; no round
        // trip to Emacs.
        if (completeEnabled) {
            CompletionStrip(
                editorId = id,
                requestId = completionReq,
                state = state
            )
        }
        // Server-requested formatting toolbar — sits at the bottom of the
        // editor, just above the soft keyboard (keyboard-adjacent, à la
        // Orgro). Toolbars are host-registered ([EabpToolbars]); the library
        // ships none, and an unregistered name renders nothing — the same
        // forward-compat rule as unknown widget nodes.
        if (toolbar.isNotEmpty() && !readOnly) {
            EabpToolbars.Render(toolbar, readValue, applyValue)
        }
    }
}

// ─── Completion strip ────────────────────────────────────────────────────────

private const val COMPLETION_DEBOUNCE_MS = 300L
private const val COMPLETION_MIN_PREFIX = 2
// "." member access, ":" keywords/paths, "[" org wikilinks ("[[" fires
// note completion — the Emacs-side capf decides what the brackets mean).
private const val COMPLETION_TRIGGER_CHARS = ".:["

/** Token characters for the completion prefix; mirrors the Emacs-side
 *  word/symbol syntax closely enough for lisp-case and snake_case. */
private fun isTokenChar(c: Char) = c.isLetterOrDigit() || c == '-' || c == '_'

/** The word/symbol token ending at CURSOR, or "" when none. */
internal fun wordPrefixAt(text: CharSequence, cursor: Int): String {
    val end = cursor.coerceIn(0, text.length)
    var i = end
    while (i > 0 && isTokenChar(text[i - 1])) i--
    return text.subSequence(i, end).toString()
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
    state: TextFieldState,
) {
    val payload by EabpRuntime.completionState.current.collectAsState()
    val p = payload ?: return
    if (p.optString("id") != editorId || p.optInt("request_id") != requestId) return
    val candidates = p.optJSONArray("candidates") ?: return
    if (candidates.length() == 0) return
    if (!state.selection.collapsed) return
    val text = state.text
    val cursor = state.selection.start
    // base may legitimately be empty: trigger-character completion (right
    // after ".") replaces nothing and inserts at the cursor.
    val base = p.optString("prefix")
    val word = wordPrefixAt(text, cursor)
    // The effective prefix to replace: the current token when the user kept
    // typing it, the original when capf chose wider boundaries (e.g. paths),
    // nothing when the token changed — then the reply is stale, show nothing.
    val effective = when {
        word.startsWith(base) -> word
        cursor >= base.length &&
            text.subSequence(cursor - base.length, cursor).toString() == base -> base
        else -> return
    }
    val visible = buildList {
        for (i in 0 until candidates.length()) {
            val c = candidates.optJSONObject(i) ?: continue
            val label = c.optString("label")
            // Case-insensitive narrowing — completion-strip convention;
            // the accepted candidate restores the canonical case anyway.
            if (label.startsWith(effective, ignoreCase = true) &&
                !label.equals(effective, ignoreCase = false)
            ) add(c)
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
                    // `insert` (SPEC §8): what lands in the buffer when it
                    // differs from the display label — e.g. a wikilink chip
                    // shows "[[Title" but inserts "[[id:…][Title]]".
                    val insert = c.optString("insert").ifEmpty { label }
                    val start = cursor - effective.length
                    state.edit {
                        replace(start, cursor, insert)
                        selection = TextRange(start + insert.length)
                    }
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
