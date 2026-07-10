package com.calebc42.jetpacs

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The curated `chart` primitive (rung 1 of the visualization ladder,
 * SPEC §9): the client emits *data* — series of points — and gets an
 * animated, theme-reactive chart with no draw ops. `kind` is a small
 * closed enum (`line`/`bar`/`area`/`sparkline`); anything that needs a
 * knob outside this shape belongs on the `canvas` node, not a new
 * `chart` attribute.
 *
 * Wire shape:
 *   {t:"chart", kind, height?, y_range?:[min,max], summary?,
 *    series:[{label?, color?, points:[{y} | {x,y}]}], on_point_tap?}
 */
private val CHART_PALETTE = listOf(
    Color(0xFF4C6FFF), Color(0xFF00A676), Color(0xFFFF8A3D),
    Color(0xFFB05CE6), Color(0xFFE64980), Color(0xFF12B5CB),
)

private class ChartSeries(val ys: DoubleArray, val color: Color)

@Composable
fun SduiChart(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val kind = node.optString("kind", "line")
    val seriesArr = node.optJSONArray("series") ?: JSONArray()
    val onPointTap = node.optJSONObject("on_point_tap")
    val heightDp = node.optInt("height", 160)

    val series = ArrayList<ChartSeries>()
    var yMin = Double.POSITIVE_INFINITY
    var yMax = Double.NEGATIVE_INFINITY
    var maxLen = 0
    for (s in 0 until seriesArr.length()) {
        val so = seriesArr.optJSONObject(s) ?: continue
        val pts = so.optJSONArray("points") ?: JSONArray()
        val ys = DoubleArray(pts.length())
        for (i in 0 until pts.length()) {
            // A point is {y} / {x,y}, or a bare number.
            val y = pts.optJSONObject(i)?.optDouble("y", 0.0) ?: pts.optDouble(i, 0.0)
            ys[i] = y
            if (y < yMin) yMin = y
            if (y > yMax) yMax = y
        }
        maxLen = maxOf(maxLen, ys.size)
        val color = resolveColor(so.optString("color")).takeIf { it != Color.Unspecified }
            ?: CHART_PALETTE[s % CHART_PALETTE.size]
        series.add(ChartSeries(ys, color))
    }

    node.optJSONArray("y_range")?.let {
        if (it.length() == 2) { yMin = it.optDouble(0, yMin); yMax = it.optDouble(1, yMax) }
    }
    // Bars and areas read against a zero baseline when the data allows.
    if ((kind == "bar" || kind == "area") && yMin > 0.0) yMin = 0.0
    if (!yMin.isFinite() || !yMax.isFinite()) { yMin = 0.0; yMax = 1.0 }
    if (yMax == yMin) yMax += 1.0

    // Entrance animation: grow from the baseline on first show.
    var started by remember(node.toString()) { mutableStateOf(false) }
    LaunchedEffect(Unit) { started = true }
    val progress by animateFloatAsState(
        targetValue = if (started) 1f else 0f,
        animationSpec = tween(600),
        label = "chart-grow",
    )

    var tapModifier = modifier.fillMaxWidth().height(heightDp.dp)
    if (onPointTap != null) {
        tapModifier = tapModifier.pointerInput(node.toString()) {
            detectTapGestures { off ->
                val s0 = series.firstOrNull() ?: return@detectTapGestures
                val n = s0.ys.size
                if (n == 0) return@detectTapGestures
                val idx = if (n == 1) 0
                    else ((off.x / size.width.toFloat()) * (n - 1)).roundToInt().coerceIn(0, n - 1)
                val value = JSONObject().apply { put("index", idx); put("y", s0.ys[idx]) }
                dispatchWithValue(dispatch, onPointTap, value)
            }
        }
    }
    val desc = node.optString("summary").ifEmpty { "$kind chart" }

    Canvas(modifier = tapModifier.semantics { contentDescription = desc }) {
        val w = size.width
        val h = size.height
        val n = maxLen
        fun xLine(i: Int): Float = if (n <= 1) w / 2f else w * i / (n - 1)
        fun yAt(v: Double): Float {
            val t = ((v - yMin) / (yMax - yMin)).toFloat().coerceIn(0f, 1f)
            return h - t * h
        }
        val baseY = yAt(if (yMin <= 0.0 && yMax >= 0.0) 0.0 else yMin)

        for (cs in series) {
            if (cs.ys.isEmpty()) continue
            when (kind) {
                "bar" -> {
                    val slot = w / cs.ys.size
                    val bw = slot * 0.6f
                    for (i in cs.ys.indices) {
                        val cx = slot * (i + 0.5f)
                        val top = baseY + (yAt(cs.ys[i]) - baseY) * progress
                        drawRect(
                            color = cs.color,
                            topLeft = Offset(cx - bw / 2f, minOf(top, baseY)),
                            size = Size(bw, abs(baseY - top)),
                        )
                    }
                }
                else -> {  // line, area, sparkline
                    val path = Path()
                    for (i in cs.ys.indices) {
                        val x = xLine(i)
                        val y = baseY + (yAt(cs.ys[i]) - baseY) * progress
                        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                    }
                    if (kind == "area") {
                        val fill = Path().apply {
                            addPath(path)
                            lineTo(xLine(cs.ys.size - 1), baseY)
                            lineTo(xLine(0), baseY)
                            close()
                        }
                        drawPath(fill, color = cs.color.copy(alpha = 0.18f))
                    }
                    val stroke = if (kind == "sparkline") 2.dp.toPx() else 2.5.dp.toPx()
                    drawPath(path, color = cs.color, style = Stroke(width = stroke))
                }
            }
        }
    }
}
