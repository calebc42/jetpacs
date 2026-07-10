package com.calebc42.jetpacs.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * The Emacs purple, from the official logo (etc/images/icons/.../emacs.svg):
 * the gradient runs #8381C5 → #7E55B3 with #5B2A85/#411F5D in the shadows.
 * The fallback schemes below seed Material 3's baseline tonal roles from
 * these instead of the baseline's #6750A4, so a pre-Android-12 device (or
 * `dynamicColor = false`) reads as Emacs, not as the Compose template.
 */
val EmacsPurple = Color(0xFF7E55B3)        // logo midtone — light primary
val EmacsPurpleLight = Color(0xFFD3BCF6)   // toward the #8381C5 stop — dark primary
val EmacsPurpleDeep = Color(0xFF5B2A85)    // logo shadow stop — dark primaryContainer
val EmacsPurpleDim = Color(0xFF411F5D)     // logo darkest stop — dark onPrimary
val EmacsIndigo = Color(0xFF5955A9)        // logo's blue-purple — light tertiary
val EmacsIndigoLight = Color(0xFFC2C1FF)   // its tone-80 lift — dark tertiary
