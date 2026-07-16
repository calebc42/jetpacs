package com.calebc42.jetpacs

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import org.json.JSONArray
import org.json.JSONObject

/**
 * Content-family SDUI nodes: styled/highlighted text, rich-text spans,
 * the date-stamp chip card, the overflow menu, section headers, and the
 * empty-state placeholder.
 */

/** Map a named text style ("title"/"headline"/"caption"/"label"/"mono") to a TextStyle. */
@Composable
internal fun textStyleForName(name: String): TextStyle = when (name) {
    "title" -> MaterialTheme.typography.titleLarge
    "headline" -> MaterialTheme.typography.headlineSmall
    "caption" -> MaterialTheme.typography.bodySmall
    "label" -> MaterialTheme.typography.labelMedium
    "mono" -> MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace)
    else -> MaterialTheme.typography.bodyLarge
}

@Composable
internal fun SduiText(node: JSONObject, modifier: Modifier) {
    val text = node.optString("text")
    val styleStr = node.optString("style", "body")
    val style = textStyleForName(styleStr)
    val syntax = node.optString("syntax")
    val selectable = node.optBoolean("selectable", false)
    val content: @Composable () -> Unit = {
        if (syntax.isNotEmpty()) {
            val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
            val sc = rememberSyntaxColors(dark)
            val mono = syntax.lowercase() != "org"
            val annotated = remember(text, syntax, sc) {
                when (syntax.lowercase()) {
                    "org" -> highlightOrg(text, sc)
                    "elisp", "emacs-lisp", "lisp" -> highlightElisp(text, sc)
                    else -> AnnotatedString(text)
                }
            }
            Text(
                text = annotated,
                style = if (mono) style.copy(fontFamily = FontFamily.Monospace) else style,
                modifier = modifier
            )
        } else {
            Text(text = text, style = style, modifier = modifier)
        }
    }
    // `selectable` enables long-press selection/copy (used by the Messages
    // view and eval results); plain labels stay non-selectable so taps on
    // surrounding cards aren't intercepted.
    if (selectable) SelectionContainer { content() } else content()
}

/**
 * Org content that Emacs has already parsed into styled spans: each span
 * carries emphasis flags (bold/italic/underline/strike/code), an optional
 * color, a `tag` flag (themed like a #hashtag), and an optional `on_tap`
 * action (rendered as a clickable link). Building the styling here — rather
 * than re-parsing org on-device — keeps Emacs the single source of truth.
 */
@Composable
internal fun SduiRichText(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val style = textStyleForName(node.optString("style", "body"))
    val annotated = buildSpanString(
        node.optJSONArray("spans"),
        MaterialTheme.colorScheme.primary,
        MaterialTheme.colorScheme.tertiary,
        dispatch
    )
    Text(text = annotated, style = style, modifier = modifier)
}

/**
 * Build an [AnnotatedString] from a `spans` array — the shared span
 * vocabulary of `rich_text` and `table` cells. Build per-composition
 * (bodies are small): the click lambdas close over [dispatch], so
 * memoizing risks a stale dispatcher.
 */
internal fun buildSpanString(
    spans: JSONArray?,
    linkColor: Color,
    tagColor: Color,
    dispatch: (JSONObject) -> Unit,
): AnnotatedString = buildAnnotatedString {
    if (spans != null) {
        for (i in 0 until spans.length()) {
            val s = spans.optJSONObject(i) ?: continue
            val text = s.optString("text")
            if (text.isEmpty()) continue

            val decorations = buildList {
                if (s.optBoolean("underline")) add(TextDecoration.Underline)
                if (s.optBoolean("strike")) add(TextDecoration.LineThrough)
            }
            val isTag = s.optBoolean("tag")
            val colorHex = s.optString("color")
            val explicitColor = if (colorHex.isNotEmpty()) parseHexColor(colorHex) else Color.Unspecified
            val bgHex = s.optString("bg")
            val bgColor = if (bgHex.isNotEmpty()) parseHexColor(bgHex) else Color.Unspecified
            val baseline = s.optString("baseline")
            val span = SpanStyle(
                fontWeight = if (s.optBoolean("bold") || isTag) FontWeight.Bold else null,
                fontStyle = if (s.optBoolean("italic")) FontStyle.Italic else null,
                // `code` carries inline-code semantics; `mono` is a plain
                // monospace run (generic buffer renderer) — both just set
                // the font family here.
                fontFamily = if (s.optBoolean("code") || s.optBoolean("mono")) FontFamily.Monospace else null,
                textDecoration = if (decorations.isNotEmpty()) TextDecoration.combine(decorations) else null,
                baselineShift = when (baseline) {
                    "super" -> BaselineShift.Superscript
                    "sub" -> BaselineShift.Subscript
                    else -> null
                },
                fontSize = if (baseline.isNotEmpty()) 0.8.em else TextUnit.Unspecified,
                // `bg` carries a face background (diff shading, hl-line,
                // region, isearch) so semantic backgrounds survive.
                background = bgColor,
                color = when {
                    explicitColor != Color.Unspecified -> explicitColor
                    isTag -> tagColor
                    else -> Color.Unspecified
                }
            )

            val onTap = s.optJSONObject("on_tap")
            if (onTap != null) {
                val linkSpan = if (span.color == Color.Unspecified) span.copy(color = linkColor) else span
                withLink(
                    LinkAnnotation.Clickable(
                        tag = "span$i",
                        styles = TextLinkStyles(style = linkSpan)
                    ) { dispatch(onTap) }
                ) { append(text) }
            } else {
                withStyle(span) { append(text) }
            }
        }
    }
}

@Composable
internal fun SduiSectionHeader(
    node: JSONObject,
    surfaceId: String,
    revision: Int,
    modifier: Modifier,
    dispatch: (JSONObject) -> Unit,
) {
    val title = node.optString("title")
    val trailing = node.optJSONObject("trailing")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 8.dp, bottom = 2.dp)
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.weight(1f)
        )
        if (trailing != null) {
            SduiNode(trailing, surfaceId, revision, Modifier, dispatch)
        }
    }
}

@Composable
internal fun SduiEmptyState(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val iconName = node.optString("icon", "inbox")
    val title = node.optString("title")
    val caption = node.optString("caption")
    val actionJson = node.optJSONObject("on_tap")
    val actionLabel = node.optString("action_label")
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            IconMap.get(iconName),
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
        )
        if (title.isNotEmpty()) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
        if (caption.isNotEmpty()) {
            Text(
                caption,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                textAlign = TextAlign.Center
            )
        }
        if (actionJson != null && actionLabel.isNotEmpty()) {
            OutlinedButton(onClick = { dispatch(actionJson) }) { Text(actionLabel) }
        }
    }
}

/**
 * An overflow icon that opens a dropdown of items; each item dispatches
 * its action and closes the menu.
 */
@Composable
internal fun SduiMenu(node: JSONObject, modifier: Modifier, dispatch: (JSONObject) -> Unit) {
    val iconName = node.optString("icon", "more_vert")
    var menuOpen by remember { mutableStateOf(false) }
    val items = node.optJSONArray("items")
    Box(modifier = modifier) {
        IconButton(onClick = { menuOpen = true }) {
            Icon(IconMap.get(iconName), contentDescription = "More")
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            if (items != null) {
                for (i in 0 until items.length()) {
                    val item = items.optJSONObject(i) ?: continue
                    val label = item.optString("label")
                    val itemIcon = item.optString("icon", "")
                    val action = item.optJSONObject("on_tap")
                    DropdownMenuItem(
                        text = { Text(label) },
                        onClick = {
                            menuOpen = false
                            if (action != null) dispatch(action)
                        },
                        leadingIcon = if (itemIcon.isNotEmpty()) {
                            { Icon(IconMap.get(itemIcon), null, Modifier.size(18.dp)) }
                        } else null
                    )
                }
            }
        }
    }
}

/**
 * Resolve a spec color attribute: a Material theme token name (adapts to
 * light/dark) or a "#RRGGBB"/"#AARRGGBB" hex literal. Color.Unspecified
 * when empty or unresolvable — callers supply their own default.
 */
@Composable
internal fun resolveColor(attr: String): Color {
    if (attr.isEmpty()) return Color.Unspecified
    val cs = MaterialTheme.colorScheme
    return when (attr) {
        "primary" -> cs.primary
        "on_primary" -> cs.onPrimary
        "primary_container" -> cs.primaryContainer
        "on_primary_container" -> cs.onPrimaryContainer
        "secondary" -> cs.secondary
        "secondary_container" -> cs.secondaryContainer
        "tertiary" -> cs.tertiary
        "tertiary_container" -> cs.tertiaryContainer
        "error" -> cs.error
        "error_container" -> cs.errorContainer
        // M3 defines no success/warning roles; supply theme-aware pairs so the
        // DSL's `jetpacs-success'/`jetpacs-warning' semantic text has an
        // adaptive color. Additive: an older companion never emits these (the
        // client owns the names), and an unknown token falls through to
        // parseHexColor -> Unspecified -> ambient, so text still renders.
        "success" -> if (cs.surface.luminance() < 0.5f) Color(0xFF7CC77C) else Color(0xFF2E7D32)
        "warning" -> if (cs.surface.luminance() < 0.5f) Color(0xFFE0B252) else Color(0xFFB26A00)
        "surface" -> cs.surface
        "surface_variant" -> cs.surfaceVariant
        "surface_container" -> cs.surfaceContainer
        "surface_container_low" -> cs.surfaceContainerLow
        "surface_container_high" -> cs.surfaceContainerHigh
        "on_surface" -> cs.onSurface
        "on_surface_variant" -> cs.onSurfaceVariant
        "outline" -> cs.outline
        else -> parseHexColor(attr)
    }
}

/** Parse "#RRGGBB" or "#AARRGGBB" to a Color; Color.Unspecified on failure. */
internal fun parseHexColor(hex: String): Color {
    val h = hex.removePrefix("#")
    return try {
        val v = h.toLong(16)
        when (h.length) {
            6 -> Color(0xFF000000L or v)
            8 -> Color(v)
            else -> Color.Unspecified
        }
    } catch (e: NumberFormatException) {
        Color.Unspecified
    }
}

/** Month-tinted (header, header-text) color pair for a 1–12 month index. */
@Composable
private fun monthColors(monthIndex: Int): Pair<Color, Color> {
    val cs = MaterialTheme.colorScheme
    return when (((monthIndex - 1).coerceAtLeast(0)) % 6) {
        0 -> cs.primary to cs.onPrimary
        1 -> cs.secondary to cs.onSecondary
        2 -> cs.tertiary to cs.onTertiary
        3 -> cs.primaryContainer to cs.onPrimaryContainer
        4 -> cs.secondaryContainer to cs.onSecondaryContainer
        else -> cs.tertiaryContainer to cs.onTertiaryContainer
    }
}

/**
 * A compact date (and optional time) chip-card.
 * DTStampView: a month-tinted header, a large day number, and the year.
 * Fields: day, month (short label), year, optional time ("HH:MM"), and
 * month_index (1–12) which drives the header color.
 */
@Composable
internal fun SduiDateStamp(node: JSONObject, modifier: Modifier) {
    val day = node.optString("day")
    val month = node.optString("month")
    val year = node.optString("year")
    val time = node.optString("time")
    val (headerColor, headerText) = monthColors(node.optInt("month_index", 0))

    Column(modifier = modifier) {
        ElevatedCard(shape = RoundedCornerShape(6.dp), modifier = Modifier.width(64.dp)) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
            ) {
                if (month.isNotEmpty()) {
                    Text(
                        month,
                        style = MaterialTheme.typography.labelMedium,
                        color = headerText,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(headerColor, RoundedCornerShape(topStart = 6.dp, topEnd = 6.dp))
                            .padding(vertical = 2.dp)
                    )
                }
                Text(
                    day,
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(vertical = 2.dp)
                )
                if (year.isNotEmpty()) {
                    Text(
                        year,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                        modifier = Modifier.padding(bottom = 2.dp)
                    )
                }
            }
        }
        if (time.isNotEmpty()) {
            ElevatedCard(
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.width(64.dp).padding(top = 6.dp)
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Text(
                        "TIME",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.primary)
                            .padding(vertical = 2.dp)
                    )
                    Text(
                        time,
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(top = 4.dp, bottom = 2.dp)
                    )
                }
            }
        }
    }
}
