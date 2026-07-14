package com.calebc42.jetpacs.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.calebc42.jetpacs.JetpacsRuntime
import com.calebc42.jetpacs.buildEmacsColorScheme
import com.calebc42.jetpacs.emacsThemeDark

// Static fallback schemes seeded from the Emacs logo purple (see Color.kt).
// Roles not derived from the logo keep Material 3 baseline values — the
// baseline is itself a purple theme, so its neutrals and containers already
// harmonize with the Emacs primary.

private val DarkColorScheme = darkColorScheme(
    primary = EmacsPurpleLight,
    onPrimary = EmacsPurpleDim,
    primaryContainer = EmacsPurpleDeep,
    onPrimaryContainer = Color(0xFFEDDCFF),
    secondary = Color(0xFFCCC2DC),
    onSecondary = Color(0xFF332D41),
    secondaryContainer = Color(0xFF4A4458),
    onSecondaryContainer = Color(0xFFE8DEF8),
    tertiary = EmacsIndigoLight,
    onTertiary = Color(0xFF2A2A6A),
    tertiaryContainer = Color(0xFF414082),
    onTertiaryContainer = Color(0xFFE2DFFF),
    background = Color(0xFF141218),
    surface = Color(0xFF141218),
    onBackground = Color(0xFFE7E0E8),
    onSurface = Color(0xFFE7E0E8),
    surfaceVariant = Color(0xFF49454F),
    onSurfaceVariant = Color(0xFFCAC4D0),
    outline = Color(0xFF948F99),
)

private val LightColorScheme = lightColorScheme(
    primary = EmacsPurple,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFEDDCFF),
    onPrimaryContainer = Color(0xFF30104E),
    secondary = Color(0xFF645B70),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFE8DEF8),
    onSecondaryContainer = Color(0xFF1E192B),
    tertiary = EmacsIndigo,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFE2DFFF),
    onTertiaryContainer = Color(0xFF12105B),
    background = Color(0xFFFDF7FF),
    surface = Color(0xFFFDF7FF),
    onBackground = Color(0xFF1D1B20),
    onSurface = Color(0xFF1D1B20),
    surfaceVariant = Color(0xFFE7E0EB),
    onSurfaceVariant = Color(0xFF49454F),
    outline = Color(0xFF7A757F),
)

@Composable
fun JetpacsTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Material You by default; falls back to the Emacs-purple scheme above on
    // pre-Android-12 devices (where dynamic color isn't available) or with
    // `dynamicColor = false`. When the paired Emacs has pushed its own theme
    // (`theme.set`, opt-in client-side via `jetpacs-theme-sync`), that wins
    // over both — the phone mirrors the desktop, including the theme's own
    // light/dark polarity. Syntax highlighting follows the same rule: pushed
    // Emacs token colors when synced, a fixed luminance-keyed set otherwise.
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val emacsTheme by JetpacsRuntime.emacsTheme.collectAsState()
    val colorScheme = when {
        emacsTheme != null -> {
            val payload = emacsTheme!!
            // The pushed theme's polarity beats the system setting: mirroring
            // a dark modus-vivendi onto a light-mode phone should look dark.
            val dark = emacsThemeDark(payload) ?: darkTheme
            val base = if (dark) DarkColorScheme else LightColorScheme
            remember(payload, dark) { buildEmacsColorScheme(payload, base) }
        }
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
