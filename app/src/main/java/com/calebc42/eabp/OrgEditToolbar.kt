package com.calebc42.eabp

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
import java.util.Calendar

/**
 * A keyboard-adjacent formatting toolbar for org-mode editing.
 *
 * Sits at the bottom of the editor (just above the soft keyboard) and provides
 * quick-insert buttons for common org structural elements: headings, lists,
 * checkboxes, source blocks, properties drawers, inline emphasis, links, and
 * timestamps. All insertions happen locally on the [TextFieldValue] — no
 * Emacs round-trip is needed; the user saves the full text as before.
 *
 * Selection-aware: inline emphasis buttons (bold/italic/code/strike) wrap the
 * current selection when text is selected; otherwise they insert paired markers
 * with the cursor positioned between them.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OrgEditToolbar(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit
) {
    var showSrcDialog by remember { mutableStateOf(false) }
    var showHeadingMenu by remember { mutableStateOf(false) }

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
            // ── Heading (dropdown for levels) ────────────────────────────
            Box {
                ToolbarChip(
                    icon = "title",
                    label = "H",
                    onClick = { showHeadingMenu = true }
                )
                DropdownMenu(
                    expanded = showHeadingMenu,
                    onDismissRequest = { showHeadingMenu = false }
                ) {
                    for (level in 1..6) {
                        DropdownMenuItem(
                            text = { Text("${"*".repeat(level)} Heading $level") },
                            onClick = {
                                showHeadingMenu = false
                                onValueChange(insertAtLineStart(value, "${"*".repeat(level)} "))
                            }
                        )
                    }
                }
            }

            // ── Promote (remove one * or indent level) ──────────────────
            ToolbarChip(
                icon = "format_indent_decrease",
                label = "←",
                onClick = { onValueChange(promoteHeading(value)) }
            )

            // ── Demote (add one * or indent level) ──────────────────────
            ToolbarChip(
                icon = "format_indent_increase",
                label = "→",
                onClick = { onValueChange(demoteHeading(value)) }
            )

            // ── Move line up ────────────────────────────────────────────
            ToolbarChip(
                icon = "arrow_upward",
                label = "↑",
                onClick = { onValueChange(moveLineUp(value)) }
            )

            // ── Move line down ──────────────────────────────────────────
            ToolbarChip(
                icon = "arrow_downward",
                label = "↓",
                onClick = { onValueChange(moveLineDown(value)) }
            )

            // ── Checkbox list item ───────────────────────────────────────
            ToolbarChip(
                icon = "checklist",
                label = "☐",
                onClick = { onValueChange(insertAtLineStart(value, "- [ ] ")) }
            )

            // ── Progress cookie: tap = [/], long-press = [%] ────────────
            val progressHaptic = LocalHapticFeedback.current
            Surface(
                shape = MaterialTheme.shapes.small,
                tonalElevation = 1.dp,
                modifier = Modifier.combinedClickable(
                    onClick = {
                        onValueChange(insertAtCursor(value, "[/]"))
                    },
                    onLongClick = {
                        progressHaptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        onValueChange(insertAtCursor(value, "[%]"))
                    }
                )
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Icon(
                        IconMap.get("data_object"),
                        contentDescription = "Progress cookie",
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("[/]", style = MaterialTheme.typography.labelSmall)
                }
            }

            // ── Plain list item ──────────────────────────────────────────
            ToolbarChip(
                icon = "format_list_bulleted",
                label = "•",
                onClick = { onValueChange(insertAtLineStart(value, "- ")) }
            )

            // ── Numbered list item ───────────────────────────────────────
            ToolbarChip(
                icon = "format_list_numbered",
                label = "1.",
                onClick = { onValueChange(insertAtLineStart(value, "1. ")) }
            )

            // ── Source block (language picker) ───────────────────────────
            ToolbarChip(
                icon = "code",
                label = "Src",
                onClick = { showSrcDialog = true }
            )

            // ── Properties drawer ────────────────────────────────────────
            ToolbarChip(
                icon = "data_object",
                label = "Props",
                onClick = {
                    onValueChange(
                        insertBlock(value, ":PROPERTIES:\n:END:")
                    )
                }
            )

            // ── Bold ─────────────────────────────────────────────────────
            ToolbarChip(
                icon = "format_bold",
                label = "B",
                onClick = { onValueChange(wrapSelection(value, "*", "*")) }
            )

            // ── Italic ───────────────────────────────────────────────────
            ToolbarChip(
                icon = "format_italic",
                label = "I",
                onClick = { onValueChange(wrapSelection(value, "/", "/")) }
            )

            // ── Code ─────────────────────────────────────────────────────
            ToolbarChip(
                icon = "code",
                label = "~",
                onClick = { onValueChange(wrapSelection(value, "~", "~")) }
            )

            // ── Strikethrough ────────────────────────────────────────────
            ToolbarChip(
                icon = "format_strikethrough",
                label = "S",
                onClick = { onValueChange(wrapSelection(value, "+", "+")) }
            )

            // ── Link ─────────────────────────────────────────────────────
            ToolbarChip(
                icon = "link",
                label = "Link",
                onClick = { onValueChange(insertLink(value)) }
            )

            // ── Timestamp: tap = inactive [date], long-press = active <date> ──
            val haptic = LocalHapticFeedback.current
            Surface(
                shape = MaterialTheme.shapes.small,
                tonalElevation = 1.dp,
                modifier = Modifier.combinedClickable(
                    onClick = {
                        // Inactive timestamp: [YYYY-MM-DD Day]
                        onValueChange(insertTimestamp(value, active = false))
                    },
                    onLongClick = {
                        // Active timestamp: <YYYY-MM-DD Day>
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        onValueChange(insertTimestamp(value, active = true))
                    }
                )
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Icon(
                        IconMap.get("schedule"),
                        contentDescription = "Timestamp",
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("TS", style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }

    // ── Source block language picker dialog ───────────────────────────────
    if (showSrcDialog) {
        SrcLanguageDialog(
            onDismiss = { showSrcDialog = false },
            onSelect = { lang ->
                showSrcDialog = false
                val block = "#+begin_src $lang\n\n#+end_src"
                onValueChange(insertBlock(value, block, cursorLineOffset = 1))
            }
        )
    }
}

/**
 * A small chip-button for the toolbar.
 */
@Composable
private fun ToolbarChip(
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

/**
 * Dialog for picking the language of a source block.
 */
@Composable
private fun SrcLanguageDialog(
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit
) {
    val languages = listOf(
        "emacs-lisp", "python", "shell", "kotlin", "java",
        "javascript", "sql", "c", "rust", "go", "org", "text"
    )
    var customLang by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Source Block Language") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                languages.forEach { lang ->
                    TextButton(
                        onClick = { onSelect(lang) },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(lang, modifier = Modifier.fillMaxWidth())
                    }
                }
                HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
                OutlinedTextField(
                    value = customLang,
                    onValueChange = { customLang = it },
                    label = { Text("Custom") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { if (customLang.isNotBlank()) onSelect(customLang.trim()) },
                enabled = customLang.isNotBlank()
            ) { Text("Use Custom") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

// ─── Text manipulation helpers ───────────────────────────────────────────────

/**
 * Insert [text] at the current cursor position.
 */
private fun insertAtCursor(value: TextFieldValue, insert: String): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)
    val newText = text.substring(0, cursor) + insert + text.substring(cursor)
    return TextFieldValue(newText, TextRange(cursor + insert.length))
}

/**
 * Insert [prefix] at the start of the current line (the line containing the cursor).
 * If the line already starts with the same prefix, it's a no-op to avoid doubling.
 */
private fun insertAtLineStart(value: TextFieldValue, prefix: String): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    // Find line start
    val lineStart = text.lastIndexOf('\n', cursor - 1) + 1

    // Check if line already starts with this prefix (after optional whitespace)
    val lineContent = text.substring(lineStart, minOf(lineStart + prefix.length + 10, text.length))
    val trimmedLine = lineContent.trimStart()
    if (trimmedLine.startsWith(prefix.trimStart())) {
        return value // already has it
    }

    val newText = text.substring(0, lineStart) + prefix + text.substring(lineStart)
    val newCursor = cursor + prefix.length
    return TextFieldValue(newText, TextRange(newCursor))
}

/**
 * Wrap the current selection with [before] and [after].
 * If nothing is selected, insert the pair with cursor between them.
 */
private fun wrapSelection(value: TextFieldValue, before: String, after: String): TextFieldValue {
    val text = value.text
    val sel = value.selection

    return if (sel.collapsed) {
        // No selection: insert pair and place cursor between
        val pos = sel.start.coerceIn(0, text.length)
        val newText = text.substring(0, pos) + before + after + text.substring(pos)
        TextFieldValue(newText, TextRange(pos + before.length))
    } else {
        // Wrap selection
        val start = sel.min.coerceIn(0, text.length)
        val end = sel.max.coerceIn(0, text.length)
        val selected = text.substring(start, end)
        val newText = text.substring(0, start) + before + selected + after + text.substring(end)
        // Select the wrapped content (excluding markers)
        TextFieldValue(
            newText,
            TextRange(start + before.length, end + before.length)
        )
    }
}

/**
 * Insert a multi-line [block] at the cursor on its own line(s).
 * If the cursor isn't at a line start, a newline is prepended.
 * [cursorLineOffset] controls which line within the block the cursor lands on
 * (0 = after the block, 1 = the second line, etc.).
 */
private fun insertBlock(value: TextFieldValue, block: String, cursorLineOffset: Int = 0): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    // Ensure we're on a fresh line
    val needsLeadingNewline = cursor > 0 && text[cursor - 1] != '\n'
    val needsTrailingNewline = cursor < text.length && text[cursor] != '\n'

    val insert = buildString {
        if (needsLeadingNewline) append('\n')
        append(block)
        if (needsTrailingNewline) append('\n')
    }

    val newText = text.substring(0, cursor) + insert + text.substring(cursor)

    // Position cursor inside the block
    val insertStart = cursor + if (needsLeadingNewline) 1 else 0
    val blockLines = block.split('\n')
    val targetLine = cursorLineOffset.coerceIn(0, blockLines.size - 1)
    var newCursorPos = insertStart
    for (i in 0 until targetLine) {
        newCursorPos += blockLines[i].length + 1 // +1 for \n
    }
    // Place cursor at end of the target line
    newCursorPos += blockLines[targetLine].length

    return TextFieldValue(newText, TextRange(newCursorPos))
}

/**
 * Insert an org link template `[[url][description]]` at the cursor.
 * If text is selected, use it as the description.
 */
private fun insertLink(value: TextFieldValue): TextFieldValue {
    val text = value.text
    val sel = value.selection

    return if (sel.collapsed) {
        val pos = sel.start.coerceIn(0, text.length)
        val template = "[[]]"
        val newText = text.substring(0, pos) + template + text.substring(pos)
        // Cursor inside the first [[...
        TextFieldValue(newText, TextRange(pos + 2))
    } else {
        val start = sel.min.coerceIn(0, text.length)
        val end = sel.max.coerceIn(0, text.length)
        val selected = text.substring(start, end)
        val template = "[[url][$selected]]"
        val newText = text.substring(0, start) + template + text.substring(end)
        // Select "url" for easy replacement
        TextFieldValue(newText, TextRange(start + 2, start + 5))
    }
}

/**
 * Insert a timestamp at the cursor.
 * [active] = true → `<YYYY-MM-DD Day>`, false → `[YYYY-MM-DD Day]`.
 */
private fun insertTimestamp(value: TextFieldValue, active: Boolean): TextFieldValue {
    val text = value.text
    val cursor = value.selection.start.coerceIn(0, text.length)

    val cal = Calendar.getInstance()
    val dayNames = arrayOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
    val dayOfWeek = dayNames[cal.get(Calendar.DAY_OF_WEEK) - 1]
    val dateStr = String.format(
        "%04d-%02d-%02d %s",
        cal.get(Calendar.YEAR),
        cal.get(Calendar.MONTH) + 1,
        cal.get(Calendar.DAY_OF_MONTH),
        dayOfWeek
    )
    val stamp = if (active) "<$dateStr>" else "[$dateStr]"

    val newText = text.substring(0, cursor) + stamp + text.substring(cursor)
    return TextFieldValue(newText, TextRange(cursor + stamp.length))
}

/**
 * Promote the current line: remove one heading level (*) or one indent level (2 spaces).
 * At top level (* or no indent), this is a no-op.
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
 * Demote the current line: add one heading level (*) or one indent level (2 spaces).
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

/**
 * Move the current line up (swap with the line above).
 */
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

/**
 * Move the current line down (swap with the line below).
 */
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
