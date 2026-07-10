package com.calebc42.jetpacs.ui.theme

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

import androidx.compose.ui.graphics.Color

private val DarkColorScheme = darkColorScheme(
    primary = Color(0xFF81A1C1),
    secondary = Color(0xFF88C0D0),
    tertiary = Color(0xFFB48EAD),
    background = Color(0xFF2E3440),
    surface = Color(0xFF3B4252),
    onPrimary = Color(0xFF2E3440),
    onSecondary = Color(0xFF2E3440),
    onTertiary = Color(0xFF2E3440),
    onBackground = Color(0xFFD8DEE9),
    onSurface = Color(0xFFECEFF4)
)

private val LightColorScheme = lightColorScheme(
    primary = Color(0xFF5E81AC),
    secondary = Color(0xFF81A1C1),
    tertiary = Color(0xFFB48EAD),
    background = Color(0xFFECEFF4),
    surface = Color(0xFFE5E9F0),
    onPrimary = Color.White,
    onSecondary = Color.White,
    onTertiary = Color.White,
    onBackground = Color(0xFF2E3440),
    onSurface = Color(0xFF3B4252)
)

@Composable
fun JetpacsTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Material You by default; falls back to the Nord scheme below on
    // pre-Android-12 devices (where dynamic color isn't available). Syntax
    // highlighting is unaffected — its token colors are fixed (Nord) and keyed
    // only on the surface's luminance, so they stay legible on any wallpaper
    // palette. Pass `dynamicColor = false` to force Nord everywhere.
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
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