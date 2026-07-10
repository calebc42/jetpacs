package com.calebc42.jetpacs

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * The data-driven editor toolbar (SPEC §9, "Editor toolbars"): renders an
 * `editor` node's `toolbar` *array* — the server composes items, this
 * interprets them. Each item carries exactly one op:
 *
 *  - `snippet` — local text insertion with the closed placeholder set
 *    (`${selection}`, `${cursor}`, `${input:Prompt}`, `${date}`, `${time}`)
 *    and optional `placement` (`cursor`/`line-start`/`block`);
 *  - `line` — a builtin line op (`promote`/`demote`/`move-up`/`move-down`);
 *  - `on_tap` — an ordinary action object, dispatched verbatim (the Emacs
 *    escape hatch);
 *  - `menu` — a dropdown of sub-items (label + one of the above).
 *
 * `long_press` on an item is a secondary op of the same shapes. Unknown
 * placeholders insert literally and unknown `line` names no-op — never a
 * crash, the §12 rule.
 *
 * [value] is a getter, read only when a button fires: the editor's buffer
 * materializes a string copy per tap, never per keystroke, and the toolbar
 * never recomposes while the user types. Every op goes back through
 * [onValueChange] as one [TextFieldValue] — the editor's bridge applies it
 * as one minimal splice, so each tap is one undo step.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SduiToolbar(
    items: JSONArray,
    value: () -> TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    dispatch: (JSONObject) -> Unit,
) {
    // An op whose snippet carries ${input:…} parks here while its dialog shows.
    var pendingInput by remember { mutableStateOf<JSONObject?>(null) }

    val runOp: (JSONObject) -> Unit = { op ->
        val tap = op.optJSONObject("on_tap")
        val line = op.optString("line")
        val snippet = if (op.has("snippet")) op.optString("snippet") else null
        when {
            tap != null -> dispatch(tap)
            line.isNotEmpty() -> lineOp(line, value())?.let(onValueChange)
            snippet != null ->
                if (snippet.contains("\${input:")) pendingInput = op
                else onValueChange(
                    applySnippet(value(), snippet, op.optString("placement"), null)
                )
        }
    }

    Surface(
        tonalElevation = 3.dp,
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 4.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                ToolbarItem(item, runOp)
            }
        }
    }

    pendingInput?.let { op ->
        SnippetInputDialog(
            prompt = inputPrompt(op.optString("snippet")),
            onDismiss = { pendingInput = null },
            onConfirm = { entry ->
                pendingInput = null
                onValueChange(
                    applySnippet(value(), op.optString("snippet"), op.optString("placement"), entry)
                )
            }
        )
    }
}

/** One toolbar item: a chip, a chip with a long-press secondary, or a menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ToolbarItem(item: JSONObject, runOp: (JSONObject) -> Unit) {
    val icon = item.optString("icon")
    val label = item.optString("label")
    val menu = item.optJSONArray("menu")
    val longPress = item.optJSONObject("long_press")
    when {
        menu != null -> {
            var expanded by remember { mutableStateOf(false) }
            Box {
                ToolbarChip(icon = icon, label = label, onClick = { expanded = true })
                DropdownMenu(
                    expanded = expanded,
                    onDismissRequest = { expanded = false }
                ) {
                    for (i in 0 until menu.length()) {
                        val sub = menu.optJSONObject(i) ?: continue
                        DropdownMenuItem(
                            text = { Text(sub.optString("label")) },
                            onClick = {
                                expanded = false
                                runOp(sub)
                            }
                        )
                    }
                }
            }
        }
        longPress != null -> {
            // ToolbarChip has no long-press slot; same Surface treatment the
            // org toolbar's cookie/timestamp buttons used.
            val haptic = LocalHapticFeedback.current
            Surface(
                shape = MaterialTheme.shapes.small,
                tonalElevation = 1.dp,
                modifier = Modifier.combinedClickable(
                    onClick = { runOp(item) },
                    onLongClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        runOp(longPress)
                    }
                )
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Icon(
                        IconMap.get(icon),
                        contentDescription = label,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(label, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        else -> ToolbarChip(icon = icon, label = label, onClick = { runOp(item) })
    }
}

/** The one companion-local dialog behind `${input:Prompt}` — free text only;
 *  preset choices are the app's `menu` items, not this. */
@Composable
private fun SnippetInputDialog(
    prompt: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var entry by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(prompt) },
        text = {
            OutlinedTextField(
                value = entry,
                onValueChange = { entry = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        },
        confirmButton = {
            TextButton(
                onClick = { if (entry.isNotBlank()) onConfirm(entry.trim()) },
                enabled = entry.isNotBlank()
            ) { Text("OK") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

// ─── Snippet engine ──────────────────────────────────────────────────────────

/** The rendered form of a snippet: placeholder-substituted [text] plus the
 *  offsets the position tokens resolved to (-1 = token absent). */
private class RenderedSnippet(
    val text: String,
    val cursor: Int,
    val selStart: Int,
    val selEnd: Int,
)

/**
 * Substitute the closed placeholder set in [snippet]. [selText] fills
 * `${selection}` (its first occurrence records the selection range);
 * [input] fills `${input:…}` when the dialog already ran. The first
 * `${cursor}` records the final cursor offset. Unknown tokens — and any
 * repeats of the position tokens — stay literal (visible, never fatal).
 */
private fun renderSnippet(snippet: String, selText: String, input: String?): RenderedSnippet {
    val sb = StringBuilder()
    var cursor = -1
    var selStart = -1
    var selEnd = -1
    var i = 0
    while (i < snippet.length) {
        val start = snippet.indexOf("\${", i)
        if (start < 0) {
            sb.append(snippet, i, snippet.length)
            break
        }
        sb.append(snippet, i, start)
        val end = snippet.indexOf('}', start)
        if (end < 0) {
            sb.append(snippet, start, snippet.length)
            break
        }
        val token = snippet.substring(start + 2, end)
        when {
            token == "selection" && selStart < 0 -> {
                selStart = sb.length
                sb.append(selText)
                selEnd = sb.length
            }
            token == "selection" -> sb.append(selText)
            token == "cursor" && cursor < 0 -> cursor = sb.length
            token == "date" -> sb.append(dateStamp())
            token == "time" -> sb.append(timeStamp())
            token.startsWith("input:") && input != null -> sb.append(input)
            else -> sb.append(snippet, start, end + 1) // literal, never fatal
        }
        i = end + 1
    }
    return RenderedSnippet(sb.toString(), cursor, selStart, selEnd)
}

/** The `${input:Prompt}` dialog title, from the snippet's first input token. */
private fun inputPrompt(snippet: String): String {
    val start = snippet.indexOf("\${input:")
    if (start < 0) return "Input"
    val end = snippet.indexOf('}', start)
    if (end < 0) return "Input"
    return snippet.substring(start + 8, end).ifEmpty { "Input" }
}

/** Render [snippet] against the current selection and apply it per [placement]. */
private fun applySnippet(
    value: TextFieldValue,
    snippet: String,
    placement: String,
    input: String?,
): TextFieldValue {
    val text = value.text
    val sel = value.selection
    val selText =
        if (sel.collapsed) ""
        else text.substring(sel.min.coerceIn(0, text.length), sel.max.coerceIn(0, text.length))
    val r = renderSnippet(snippet, selText, input)
    return when (placement) {
        "line-start" -> insertAtLineStart(value, r.text)
        "block" -> insertBlock(value, r)
        else -> insertAtCursor(value, r)
    }
}

/**
 * Default (`cursor`) placement. A snippet with `${selection}` replaces the
 * selection (the wrap case) and leaves the substituted content selected; with
 * an empty selection the cursor lands at the token — the two branches the org
 * toolbar's wrapSelection had. A snippet without it inserts at the cursor and
 * leaves any selection's text alone. `${cursor}` wins when present; with no
 * position token the cursor ends after the insertion.
 */
private fun insertAtCursor(value: TextFieldValue, r: RenderedSnippet): TextFieldValue {
    val text = value.text
    val sel = value.selection
    val consume = r.selStart >= 0 && !sel.collapsed
    val start = (if (consume) sel.min else sel.start).coerceIn(0, text.length)
    val end = (if (consume) sel.max else start).coerceIn(0, text.length)
    val newText = text.substring(0, start) + r.text + text.substring(end)
    val selection = when {
        r.cursor >= 0 -> TextRange(start + r.cursor)
        r.selStart in 0 until r.selEnd -> TextRange(start + r.selStart, start + r.selEnd)
        r.selStart >= 0 -> TextRange(start + r.selStart)
        else -> TextRange(start + r.text.length)
    }
    return TextFieldValue(newText, selection)
}

/**
 * `line-start` placement: insert the rendered snippet at the start of the
 * cursor's line. If the line already starts with the same prefix, it's a
 * no-op to avoid doubling (the dedupe the org toolbar had).
 */
private fun insertAtLineStart(value: TextFieldValue, prefix: String): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    val lineStart = text.lastIndexOf('\n', cursor - 1) + 1

    // Check if line already starts with this prefix (after optional whitespace)
    val lineContent = text.substring(lineStart, minOf(lineStart + prefix.length + 10, text.length))
    val trimmedLine = lineContent.trimStart()
    if (prefix.trimStart().isNotEmpty() && trimmedLine.startsWith(prefix.trimStart())) {
        return value // already has it
    }

    val newText = text.substring(0, lineStart) + prefix + text.substring(lineStart)
    return TextFieldValue(newText, TextRange(cursor + prefix.length))
}

/**
 * `block` placement: insert the rendered snippet on its own line(s), adding
 * newlines around it as needed. `${cursor}` picks the position inside the
 * block (the generalized cursorLineOffset); without it the cursor lands
 * after the block.
 */
private fun insertBlock(value: TextFieldValue, r: RenderedSnippet): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    val needsLeadingNewline = cursor > 0 && text[cursor - 1] != '\n'
    val needsTrailingNewline = cursor < text.length && text[cursor] != '\n'

    val insert = buildString {
        if (needsLeadingNewline) append('\n')
        append(r.text)
        if (needsTrailingNewline) append('\n')
    }

    val newText = text.substring(0, cursor) + insert + text.substring(cursor)
    val insertStart = cursor + if (needsLeadingNewline) 1 else 0
    val pos = insertStart + if (r.cursor >= 0) r.cursor else r.text.length
    return TextFieldValue(newText, TextRange(pos))
}

// ─── Builtin line ops ────────────────────────────────────────────────────────

/** Dispatch a builtin `line` op; null for an unknown name (no-op, §12). */
private fun lineOp(name: String, value: TextFieldValue): TextFieldValue? = when (name) {
    "promote" -> promoteHeading(value)
    "demote" -> demoteHeading(value)
    "move-up" -> moveLineUp(value)
    "move-down" -> moveLineDown(value)
    else -> null
}

/**
 * Promote the current line: remove one heading level (*) or one indent level
 * (2 spaces). At top level (* or no indent), this is a no-op.
 */
private fun promoteHeading(value: TextFieldValue): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)
    val lineStart = text.lastIndexOf('\n', cursor - 1) + 1
    val lineEnd = text.indexOf('\n', cursor).let { if (it == -1) text.length else it }
    val line = text.substring(lineStart, lineEnd)

    val newLine = when {
        // Heading with 2+ stars: remove one *
        line.startsWith("**") -> line.removePrefix("*")
        // Indented content: remove one level of indent (2 spaces)
        line.startsWith("  ") -> line.substring(2)
        // Already at top level — can't promote further
        else -> return value
    }

    val shift = newLine.length - line.length
    val newText = text.substring(0, lineStart) + newLine + text.substring(lineEnd)
    return TextFieldValue(newText, TextRange((cursor + shift).coerceAtLeast(lineStart)))
}

/**
 * Demote the current line: add one heading level (*) or one indent level
 * (2 spaces).
 */
private fun demoteHeading(value: TextFieldValue): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)
    val lineStart = text.lastIndexOf('\n', cursor - 1) + 1
    val lineEnd = text.indexOf('\n', cursor).let { if (it == -1) text.length else it }
    val line = text.substring(lineStart, lineEnd)

    val newLine = when {
        // Heading: add one *
        line.startsWith("*") -> "*$line"
        // List item or indented content: add indent
        line.trimStart().let { it.startsWith("-") || it.matches(Regex("\\d+[.)].*")) } -> "  $line"
        // Plain text — don't auto-convert
        else -> return value
    }

    val shift = newLine.length - line.length
    val newText = text.substring(0, lineStart) + newLine + text.substring(lineEnd)
    return TextFieldValue(newText, TextRange(cursor + shift))
}

/** Move the current line up (swap with the line above). */
private fun moveLineUp(value: TextFieldValue): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    // Current line bounds
    val lineStart = text.lastIndexOf('\n', cursor - 1) + 1
    if (lineStart == 0) return value // Already at first line
    val lineEnd = text.indexOf('\n', cursor).let { if (it == -1) text.length else it }

    // Previous line bounds
    val prevLineStart = text.lastIndexOf('\n', lineStart - 2) + 1
    val prevLineEnd = lineStart - 1 // the \n before current line

    val currentLine = text.substring(lineStart, lineEnd)
    val prevLine = text.substring(prevLineStart, prevLineEnd)

    val newText = text.substring(0, prevLineStart) +
            currentLine + "\n" + prevLine +
            text.substring(lineEnd)

    val cursorInLine = cursor - lineStart
    return TextFieldValue(newText, TextRange(prevLineStart + cursorInLine))
}

/** Move the current line down (swap with the line below). */
private fun moveLineDown(value: TextFieldValue): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    // Current line bounds
    val lineStart = text.lastIndexOf('\n', cursor - 1) + 1
    val lineEnd = text.indexOf('\n', cursor)
    if (lineEnd == -1) return value // Already at last line

    // Next line bounds
    val nextLineStart = lineEnd + 1
    val nextLineEnd = text.indexOf('\n', nextLineStart).let { if (it == -1) text.length else it }

    val currentLine = text.substring(lineStart, lineEnd)
    val nextLine = text.substring(nextLineStart, nextLineEnd)

    val newText = text.substring(0, lineStart) +
            nextLine + "\n" + currentLine +
            text.substring(nextLineEnd)

    val cursorInLine = cursor - lineStart
    val newLineStart = lineStart + nextLine.length + 1
    return TextFieldValue(newText, TextRange(newLineStart + cursorInLine))
}

// ─── Timestamps ──────────────────────────────────────────────────────────────

/** `YYYY-MM-DD Day` from the companion clock — the `${date}` placeholder. */
private fun dateStamp(): String {
    val cal = Calendar.getInstance()
    val dayNames = arrayOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
    val dayOfWeek = dayNames[cal.get(Calendar.DAY_OF_WEEK) - 1]
    return String.format(
        "%04d-%02d-%02d %s",
        cal.get(Calendar.YEAR),
        cal.get(Calendar.MONTH) + 1,
        cal.get(Calendar.DAY_OF_MONTH),
        dayOfWeek
    )
}

/** `HH:MM` from the companion clock — the `${time}` placeholder. */
private fun timeStamp(): String {
    val cal = Calendar.getInstance()
    return String.format("%02d:%02d", cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE))
}
