package com.calebc42.eabp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import kotlinx.coroutines.delay
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
