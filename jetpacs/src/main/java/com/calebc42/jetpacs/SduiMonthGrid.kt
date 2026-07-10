package com.calebc42.jetpacs

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import java.text.DateFormatSymbols
import java.util.Calendar

/**
 * The `month_grid` node (SPEC §9): the agenda calendar — a curated,
 * data-driven month view, "the `chart` of time".
 *
 *   {"t": "month_grid", "month": "YYYY-MM",
 *    "marks": {"YYYY-MM-DD": {"dots": N, "color"?}, …},
 *    "selected"?, "min_month"?, "max_month"?,
 *    "on_day_tap"?, "on_month_change"?}
 *
 * Month navigation (chevrons or a horizontal swipe) is companion-local
 * between `min_month`/`max_month`; `on_month_change` reports the newly
 * shown month as `value` so the client can push fresh marks — marks for
 * unfetched months are simply absent, never blocking. `on_day_tap`
 * dispatches with the tapped ISO date as `value`. Today is outlined,
 * `selected` is filled, and a day's `dots` (capped at 3) render under
 * its number. A re-push with a different `month` adopts it; re-pushes
 * that only change marks leave the user's shown month alone.
 */
@Composable
internal fun SduiMonthGrid(
    node: JSONObject,
    modifier: Modifier,
    dispatch: (JSONObject) -> Unit,
) {
    val specMonth = node.optString("month").takeIf { it.matches(Regex("\\d{4}-\\d{2}")) }
        ?: return
    val marks = node.optJSONObject("marks")
    val selected = node.optString("selected")
    val minMonth = node.optString("min_month").ifEmpty { null }
    val maxMonth = node.optString("max_month").ifEmpty { null }
    val onDayTap = node.optJSONObject("on_day_tap")
    val onMonthChange = node.optJSONObject("on_month_change")

    // Companion-local shown month, re-seeded when the spec's month changes
    // (the push IS the navigation then); mark-only re-pushes leave it alone.
    var shownMonth by remember(specMonth) { mutableStateOf(specMonth) }

    val changeMonth: (Int) -> Unit = { delta ->
        val next = monthAdd(shownMonth, delta)
        // "YYYY-MM" compares correctly as a string.
        if ((minMonth == null || next >= minMonth) &&
            (maxMonth == null || next <= maxMonth)
        ) {
            shownMonth = next
            onMonthChange?.let { dispatchWithValue(dispatch, it, next) }
        }
    }

    val year = shownMonth.substring(0, 4).toInt()
    val month = shownMonth.substring(5, 7).toInt() // 1-12
    val cal = Calendar.getInstance()
    val weekStart = cal.firstDayOfWeek // locale: SUNDAY=1 or MONDAY=2
    cal.clear()
    cal.set(year, month - 1, 1)
    val daysInMonth = cal.getActualMaximum(Calendar.DAY_OF_MONTH)
    val leadingBlanks = (cal.get(Calendar.DAY_OF_WEEK) - weekStart + 7) % 7
    val today = Calendar.getInstance().let {
        String.format(
            "%04d-%02d-%02d",
            it.get(Calendar.YEAR), it.get(Calendar.MONTH) + 1,
            it.get(Calendar.DAY_OF_MONTH)
        )
    }
    val symbols = remember { DateFormatSymbols() }

    val density = LocalDensity.current
    val swipeThresholdPx = with(density) { 60.dp.toPx() }
    var dragTotal by remember { mutableFloatStateOf(0f) }

    Column(modifier = modifier.fillMaxWidth()) {
        // ── Header: ‹ Month Year › ───────────────────────────────────────
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            IconButton(
                onClick = { changeMonth(-1) },
                enabled = minMonth == null || monthAdd(shownMonth, -1) >= minMonth
            ) { Icon(IconMap.get("chevron_left"), contentDescription = "Previous month") }
            Text(
                "${symbols.months[month - 1]} $year",
                style = MaterialTheme.typography.titleMedium,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f)
            )
            IconButton(
                onClick = { changeMonth(1) },
                enabled = maxMonth == null || monthAdd(shownMonth, 1) <= maxMonth
            ) { Icon(IconMap.get("chevron_right"), contentDescription = "Next month") }
        }
        // ── Weekday labels, from the locale's first day of week ──────────
        Row(Modifier.fillMaxWidth()) {
            for (i in 0 until 7) {
                val dow = (weekStart - 1 + i) % 7 + 1 // Calendar.SUNDAY..SATURDAY
                Text(
                    symbols.shortWeekdays[dow].take(2),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f)
                )
            }
        }
        // ── Day cells; the grid swipes between months ────────────────────
        Column(
            Modifier
                .fillMaxWidth()
                .pointerInput(shownMonth) {
                    detectHorizontalDragGestures(
                        onDragStart = { dragTotal = 0f },
                        onDragEnd = {
                            when {
                                dragTotal <= -swipeThresholdPx -> changeMonth(1)
                                dragTotal >= swipeThresholdPx -> changeMonth(-1)
                            }
                        },
                        onHorizontalDrag = { _, amount -> dragTotal += amount }
                    )
                }
        ) {
            val cells = leadingBlanks + daysInMonth
            val weeks = (cells + 6) / 7
            for (week in 0 until weeks) {
                Row(Modifier.fillMaxWidth()) {
                    for (col in 0 until 7) {
                        val day = week * 7 + col - leadingBlanks + 1
                        if (day < 1 || day > daysInMonth) {
                            Spacer(Modifier.weight(1f).aspectRatio(1f))
                        } else {
                            val date = String.format("%s-%02d", shownMonth, day)
                            MonthGridDay(
                                day = day,
                                date = date,
                                mark = marks?.optJSONObject(date),
                                isToday = date == today,
                                isSelected = date == selected,
                                onTap = onDayTap?.let {
                                    { dispatchWithValue(dispatch, it, date) }
                                },
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MonthGridDay(
    day: Int,
    date: String,
    mark: JSONObject?,
    isToday: Boolean,
    isSelected: Boolean,
    onTap: (() -> Unit)?,
    modifier: Modifier,
) {
    val dots = (mark?.optInt("dots", 0) ?: 0).coerceIn(0, 3)
    val dotColor = resolveColor(mark?.optString("color") ?: "")
        .takeIf { it != Color.Unspecified } ?: MaterialTheme.colorScheme.primary
    val desc = date + if (dots > 0) ", $dots marked" else ""
    Box(
        modifier
            .aspectRatio(1f)
            .padding(2.dp)
            .clip(CircleShape)
            .then(
                when {
                    isSelected -> Modifier.background(MaterialTheme.colorScheme.primary)
                    isToday -> Modifier.border(
                        1.5.dp, MaterialTheme.colorScheme.primary, CircleShape
                    )
                    else -> Modifier
                }
            )
            .then(
                if (onTap != null) Modifier.clickable { onTap() } else Modifier
            )
            .semantics { contentDescription = desc },
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                day.toString(),
                style = MaterialTheme.typography.bodySmall,
                color = if (isSelected) MaterialTheme.colorScheme.onPrimary
                else MaterialTheme.colorScheme.onSurface
            )
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                repeat(dots) {
                    Box(
                        Modifier
                            .size(4.dp)
                            .clip(CircleShape)
                            .background(
                                if (isSelected) MaterialTheme.colorScheme.onPrimary
                                else dotColor
                            )
                    )
                }
            }
        }
    }
}

/** MONTH ("YYYY-MM") shifted by DELTA months. */
internal fun monthAdd(month: String, delta: Int): String {
    val y = month.substring(0, 4).toInt()
    val m = month.substring(5, 7).toInt()
    val total = y * 12 + (m - 1) + delta
    return String.format("%04d-%02d", total / 12, total % 12 + 1)
}
