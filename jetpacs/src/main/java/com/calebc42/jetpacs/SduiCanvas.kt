package com.calebc42.jetpacs

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

/**
 * The `canvas` draw-ops interpreter (rung 2 of the visualization ladder,
 * SPEC §9): the client computes geometry in Elisp and emits a closed,
 * data-only draw program — `line`/`rect`/`circle`/`path`/`text` — that
 * this build interprets and never has to change again. The escape hatch
 * for visuals no curated primitive covers, kept deliberately dumb: no
 * animation, no interaction. When a use wants those it has earned a
 * curated primitive (rung 1), not a bigger op vocabulary.
 *
 * Coordinates are in the node's own `width`×`height` space (= dp).
 * Unknown ops are skipped, never fatal.
 */
@Composable
fun SduiCanvas(node: JSONObject, modifier: Modifier) {
    val wDp = node.optInt("width", 100)
    val hDp = node.optInt("height", 100)
    val ops = node.optJSONArray("ops") ?: JSONArray()
    val fallback = MaterialTheme.colorScheme.onSurface

    // Resolve every op's colour here — the draw lambda below is a DrawScope,
    // not a composable, so it can't read the theme for tokens like "primary".
    val colors: List<Color> = (0 until ops.length()).map { i ->
        val name = ops.optJSONObject(i)?.optString("color").orEmpty()
        if (name.isEmpty()) fallback
        else resolveColor(name).takeIf { it != Color.Unspecified } ?: fallback
    }

    Canvas(modifier = modifier.size(wDp.dp, hDp.dp)) {
        fun px(v: Double): Float = v.toFloat().dp.toPx()
        for (i in 0 until ops.length()) {
            val o = ops.optJSONObject(i) ?: continue
            val color = colors[i]
            val filled = o.optBoolean("fill", false)
            val strokeW = px(o.optDouble("stroke", 1.0))
            when (o.optString("op")) {
                "line" -> drawLine(
                    color,
                    Offset(px(o.optDouble("x1")), px(o.optDouble("y1"))),
                    Offset(px(o.optDouble("x2")), px(o.optDouble("y2"))),
                    strokeWidth = strokeW,
                )
                "rect" -> {
                    val tl = Offset(px(o.optDouble("x")), px(o.optDouble("y")))
                    val sz = Size(px(o.optDouble("w")), px(o.optDouble("h")))
                    val radius = px(o.optDouble("radius", 0.0))
                    if (radius > 0f) {
                        val cr = androidx.compose.ui.geometry.CornerRadius(radius, radius)
                        if (filled) drawRoundRect(color, tl, sz, cr)
                        else drawRoundRect(color, tl, sz, cr, style = Stroke(strokeW))
                    } else {
                        if (filled) drawRect(color, tl, sz)
                        else drawRect(color, tl, sz, style = Stroke(strokeW))
                    }
                }
                "circle" -> {
                    val center = Offset(px(o.optDouble("cx")), px(o.optDouble("cy")))
                    val r = px(o.optDouble("r"))
                    if (filled) drawCircle(color, r, center)
                    else drawCircle(color, r, center, style = Stroke(strokeW))
                }
                "path" -> {
                    val pts = o.optJSONArray("points") ?: JSONArray()
                    if (pts.length() >= 2) {
                        val path = Path()
                        for (j in 0 until pts.length()) {
                            val p = pts.optJSONArray(j) ?: continue
                            val x = px(p.optDouble(0)); val y = px(p.optDouble(1))
                            if (j == 0) path.moveTo(x, y) else path.lineTo(x, y)
                        }
                        if (o.optBoolean("closed", false)) path.close()
                        if (filled) drawPath(path, color)
                        else drawPath(path, color, style = Stroke(strokeW))
                    }
                }
                "text" -> drawIntoCanvas { c ->
                    val paint = Paint().apply {
                        this.color = color.toArgb()
                        textSize = px(o.optDouble("size", 12.0))
                        isAntiAlias = true
                        textAlign = when (o.optString("align")) {
                            "center" -> Paint.Align.CENTER
                            "end" -> Paint.Align.RIGHT
                            else -> Paint.Align.LEFT
                        }
                    }
                    c.nativeCanvas.drawText(
                        o.optString("text"), px(o.optDouble("x")), px(o.optDouble("y")), paint,
                    )
                }
                // Unknown op: skip, never fatal.
                else -> {}
            }
        }
    }
}
