package com.calebc42.jetpacs

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.input.TextFieldValue

/**
 * Host-registered editor toolbars, keyed by the server-requested name (the
 * string form of the `toolbar` attribute on editor specs, SPEC §9). This is
 * the native-alternative seam: the default path is the data-driven item
 * array interpreted by [SduiToolbar], and a host that wants richer behavior
 * registers a Kotlin toolbar here by name. Nothing ships registered; an
 * unknown name renders nothing, the same forward-compat rule as unknown
 * widget nodes.
 *
 * The value parameter is a getter so a toolbar reads the buffer only when
 * a button fires, never per keystroke (see [SduiToolbar]'s doc).
 */
object JetpacsToolbars {
    private val registry =
        mutableMapOf<String, @Composable (() -> TextFieldValue, (TextFieldValue) -> Unit) -> Unit>()

    fun register(
        name: String,
        toolbar: @Composable (() -> TextFieldValue, (TextFieldValue) -> Unit) -> Unit,
    ) {
        registry[name] = toolbar
    }

    @Composable
    fun Render(
        name: String,
        value: () -> TextFieldValue,
        onValueChange: (TextFieldValue) -> Unit,
    ) {
        registry[name]?.invoke(value, onValueChange)
    }
}
