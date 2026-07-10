package com.calebc42.jetpacs

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.input.TextFieldValue

/**
 * Host-registered editor toolbars, keyed by the server-requested name (the
 * `toolbar` attribute on editor specs, SPEC §9). The library ships none:
 * attaching a toolbar to a file type is an app opinion — the Glasspane
 * shell registers "org" (OrgEditToolbar). Unknown names render nothing,
 * the same forward-compat rule as unknown widget nodes.
 *
 * The value parameter is a getter so a toolbar reads the buffer only when
 * a button fires, never per keystroke (see OrgEditToolbar's doc in :app).
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
