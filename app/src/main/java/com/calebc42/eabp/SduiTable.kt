package com.calebc42.eabp

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import org.json.JSONObject

/**
 * The `table` node: an org-table grid Emacs has already parsed. Columns
 * size to their widest cell (cross-row alignment a stack of `row`s can't
 * give) and a wide grid pans horizontally on-device — the whole table
 * ships once. Rule rows (org hlines) draw as in-grid dividers, header
 * rows render emphasized, and `on_add_row` / `on_add_col` actions grow
 * slim "+" affordances below / to the right of the grid. Every embedded
 * action dispatches verbatim; the server bakes file/position into args.
 */

/** Parsed shape of one wire row: a rule line or a run of cells. */
private sealed interface TableRowSpec
private data class CellsSpec(val cells: List<JSONObject>, val header: Boolean) : TableRowSpec
private data class RuleSpec(val afterHeader: Boolean) : TableRowSpec

@Composable
internal fun SduiTable(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val rowsJson = node.optJSONArray("rows") ?: return
    val specs = buildList {
        var prevHeader = false
        for (i in 0 until rowsJson.length()) {
            val row = rowsJson.optJSONObject(i) ?: continue
            if (row.optBoolean("rule")) {
                add(RuleSpec(afterHeader = prevHeader))
                prevHeader = false
            } else {
                val cellsJson = row.optJSONArray("cells") ?: continue
                val cells = buildList {
                    for (c in 0 until cellsJson.length()) cellsJson.optJSONObject(c)?.let { add(it) }
                }
                add(CellsSpec(cells, row.optBoolean("header")))
                prevHeader = row.optBoolean("header")
            }
        }
    }
    if (specs.none { it is CellsSpec && it.cells.isNotEmpty() }) return
    val alignsJson = node.optJSONArray("aligns")
    val aligns = buildList {
        if (alignsJson != null) for (i in 0 until alignsJson.length()) add(alignsJson.optString(i))
    }
    val onAddRow = node.optJSONObject("on_add_row")
    val onAddCol = node.optJSONObject("on_add_col")

    Column(modifier = modifier) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.horizontalScroll(rememberScrollState())
        ) {
            TableGrid(specs, aligns, dispatch)
            if (onAddCol != null) AddAffordance("Add column") { dispatch(onAddCol) }
        }
        // Outside the horizontal scroll, so it stays visible when panned.
        if (onAddRow != null) AddAffordance("Add row") { dispatch(onAddRow) }
    }
}

@Composable
private fun AddAffordance(description: String, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(32.dp)) {
        Icon(
            IconMap.get("add"),
            contentDescription = description,
            tint = MaterialTheme.colorScheme.outline,
            modifier = Modifier.size(18.dp)
        )
    }
}

@Composable
private fun TableGrid(
    specs: List<TableRowSpec>,
    aligns: List<String>,
    dispatch: (JSONObject) -> Unit,
) {
    val ruleColor = MaterialTheme.colorScheme.outlineVariant
    Layout(content = {
        specs.forEach { spec ->
            when (spec) {
                is RuleSpec -> HorizontalDivider(
                    thickness = if (spec.afterHeader) 2.dp else 1.dp,
                    color = ruleColor
                )
                is CellsSpec -> spec.cells.forEach { TableCell(it, spec.header, dispatch) }
            }
        }
    }) { measurables, _ ->
        // Cells measure unconstrained first (their intrinsic size sets the
        // column widths); rules wait until the total width is known.
        val loose = Constraints()
        var m = 0
        val cellRows = arrayOfNulls<List<Placeable>>(specs.size)
        val pendingRules = mutableListOf<Pair<Int, Int>>() // spec index -> measurable index
        specs.forEachIndexed { r, spec ->
            when (spec) {
                is RuleSpec -> pendingRules.add(r to m++)
                is CellsSpec -> cellRows[r] = spec.cells.map { measurables[m++].measure(loose) }
            }
        }
        val ncols = specs.filterIsInstance<CellsSpec>().maxOf { it.cells.size }
        val colW = IntArray(ncols)
        cellRows.forEach { row ->
            row?.forEachIndexed { c, p -> if (p.width > colW[c]) colW[c] = p.width }
        }
        val totalW = colW.sum()
        val rules = arrayOfNulls<Placeable>(specs.size)
        pendingRules.forEach { (r, mi) ->
            rules[r] = measurables[mi].measure(Constraints.fixedWidth(totalW))
        }
        val rowH = IntArray(specs.size) { r ->
            rules[r]?.height ?: (cellRows[r]?.maxOfOrNull { it.height } ?: 0)
        }
        layout(totalW, rowH.sum()) {
            var y = 0
            specs.forEachIndexed { r, _ ->
                rules[r]?.placeRelative(0, y)
                cellRows[r]?.let { row ->
                    var x = 0
                    row.forEachIndexed { c, p ->
                        val slack = colW[c] - p.width
                        val dx = when (aligns.getOrNull(c)) {
                            "end" -> slack
                            "center" -> slack / 2
                            else -> 0
                        }
                        p.placeRelative(x + dx, y + (rowH[r] - p.height) / 2)
                        x += colW[c]
                    }
                }
                y += rowH[r]
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TableCell(cell: JSONObject, header: Boolean, dispatch: (JSONObject) -> Unit) {
    val onTap = cell.optJSONObject("on_tap")
    val onLongTap = cell.optJSONObject("on_long_tap")
    val annotated = buildSpanString(
        cell.optJSONArray("spans"),
        MaterialTheme.colorScheme.primary,
        MaterialTheme.colorScheme.tertiary,
        dispatch
    )
    val base = MaterialTheme.typography.bodyMedium
    val clickMod = if (onTap != null || onLongTap != null) {
        Modifier.combinedClickable(
            onClick = { onTap?.let(dispatch) },
            onLongClick = onLongTap?.let { { dispatch(it) } }
        )
    } else Modifier
    Box(
        // The min size keeps empty cells tappable — the add-row-then-fill
        // flow depends on it.
        modifier = clickMod
            .defaultMinSize(minWidth = 28.dp, minHeight = 24.dp)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Text(annotated, style = if (header) base.copy(fontWeight = FontWeight.SemiBold) else base)
    }
}
