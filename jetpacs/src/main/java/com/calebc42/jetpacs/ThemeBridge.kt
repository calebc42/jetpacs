package com.calebc42.jetpacs

import androidx.compose.material3.ColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import org.json.JSONArray
import org.json.JSONObject

/**
 * Emacs-driven theming (SPEC §7 `theme.set`).
 *
 * The client may push a palette extracted from the running Emacs theme —
 * `{dark, colors, syntax}` — and the companion mirrors it: [buildEmacsColorScheme]
 * overlays the `colors` roles onto a shell-provided base scheme, and
 * [rememberSyntaxColors] swaps the editor's token colors for the `syntax` set.
 * Every value is optional; anything absent keeps the base, so a sparse palette
 * from a spartan theme still yields a complete, legible scheme.
 *
 * The payload persists in prefs (see [JetpacsRuntime.setEmacsTheme]) — like a
 * cached surface, the phone keeps looking like your Emacs while Emacs is away.
 */

private fun JSONObject.color(key: String): Color? =
    optString(key).takeIf { it.isNotEmpty() }
        ?.let { parseHexColor(it).takeIf { c -> c != Color.Unspecified } }

/**
 * [base] with every role present in [payload]'s `colors` object replaced.
 * Role keys are the snake_case theme tokens of SPEC §9 (`primary`,
 * `surface_variant`, …). The `surface_container*` tones, which themes never
 * name, are re-derived from the pushed surface/surface_variant pair so
 * token-colored nodes sit on the pushed surface rather than the base's.
 */
fun buildEmacsColorScheme(payload: JSONObject, base: ColorScheme): ColorScheme {
    val c = payload.optJSONObject("colors") ?: return base
    val surface = c.color("surface") ?: base.surface
    val surfaceVariant = c.color("surface_variant") ?: base.surfaceVariant
    return base.copy(
        primary = c.color("primary") ?: base.primary,
        onPrimary = c.color("on_primary") ?: base.onPrimary,
        primaryContainer = c.color("primary_container") ?: base.primaryContainer,
        onPrimaryContainer = c.color("on_primary_container") ?: base.onPrimaryContainer,
        secondary = c.color("secondary") ?: base.secondary,
        onSecondary = c.color("on_secondary") ?: base.onSecondary,
        secondaryContainer = c.color("secondary_container") ?: base.secondaryContainer,
        onSecondaryContainer = c.color("on_secondary_container") ?: base.onSecondaryContainer,
        tertiary = c.color("tertiary") ?: base.tertiary,
        onTertiary = c.color("on_tertiary") ?: base.onTertiary,
        tertiaryContainer = c.color("tertiary_container") ?: base.tertiaryContainer,
        onTertiaryContainer = c.color("on_tertiary_container") ?: base.onTertiaryContainer,
        error = c.color("error") ?: base.error,
        onError = c.color("on_error") ?: base.onError,
        errorContainer = c.color("error_container") ?: base.errorContainer,
        onErrorContainer = c.color("on_error_container") ?: base.onErrorContainer,
        background = c.color("background") ?: c.color("surface") ?: base.background,
        onBackground = c.color("on_background") ?: c.color("on_surface") ?: base.onBackground,
        surface = surface,
        onSurface = c.color("on_surface") ?: base.onSurface,
        surfaceVariant = surfaceVariant,
        onSurfaceVariant = c.color("on_surface_variant") ?: base.onSurfaceVariant,
        outline = c.color("outline") ?: base.outline,
        surfaceContainerLow = lerp(surface, surfaceVariant, 0.25f),
        surfaceContainer = lerp(surface, surfaceVariant, 0.5f),
        surfaceContainerHigh = lerp(surface, surfaceVariant, 0.75f),
    )
}

/** Non-null when the pushed theme declares its own polarity. */
fun emacsThemeDark(payload: JSONObject): Boolean? =
    if (payload.has("dark")) payload.optBoolean("dark") else null

/**
 * The companion scheme a non-mirroring `theme.set` forces: `"material"` or
 * `"default"` (SPEC §7 `base`). Null when the payload mirrors a palette (its
 * `colors` win instead) or when it is a bare clear carrying no `base`.
 */
fun emacsThemeBase(payload: JSONObject): String? =
    if (payload.optJSONObject("colors") == null)
        payload.optString("base").takeIf { it.isNotEmpty() }
    else null

private fun JSONArray.colorList(fallback: List<Color>): List<Color> {
    val parsed = (0 until length()).mapNotNull { i ->
        optString(i).takeIf { it.isNotEmpty() }
            ?.let { parseHexColor(it).takeIf { c -> c != Color.Unspecified } }
    }
    return parsed.ifEmpty { fallback }
}

/** [SyntaxColors] from a `syntax` payload, holes filled from [fallback]. */
fun emacsSyntaxColors(syntax: JSONObject, fallback: SyntaxColors): SyntaxColors =
    SyntaxColors(
        comment = syntax.color("comment") ?: fallback.comment,
        string = syntax.color("string") ?: fallback.string,
        keyword = syntax.color("keyword") ?: fallback.keyword,
        function = syntax.color("function") ?: fallback.function,
        constant = syntax.color("constant") ?: fallback.constant,
        number = syntax.color("number") ?: fallback.number,
        link = syntax.color("link") ?: fallback.link,
        meta = syntax.color("meta") ?: fallback.meta,
        todo = syntax.color("todo") ?: fallback.todo,
        done = syntax.color("done") ?: fallback.done,
        heading = syntax.optJSONArray("heading")?.colorList(fallback.heading)
            ?: fallback.heading,
        paren = syntax.optJSONArray("paren")?.colorList(fallback.paren)
            ?: fallback.paren,
    )

/**
 * The editor token palette in effect: the pushed Emacs `syntax` colors when a
 * theme is synced, else the static set for [dark] surfaces. The one entry
 * point for every code/org field in the renderer.
 */
@Composable
fun rememberSyntaxColors(dark: Boolean): SyntaxColors {
    val theme by JetpacsRuntime.emacsTheme.collectAsState()
    return remember(dark, theme) {
        val fallback = SyntaxColors.forBackground(dark)
        theme?.optJSONObject("syntax")?.let { emacsSyntaxColors(it, fallback) }
            ?: fallback
    }
}
