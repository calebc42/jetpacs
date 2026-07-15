package com.calebc42.jetpacs

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Off-device coverage for the `theme.set` `base` directive (SPEC §7): the
 * wire-shape parsing that decides whether a payload mirrors an Emacs palette
 * or forces one of the companion's own schemes (Material You / the Emacs-purple
 * default). The scheme is applied by a composable ([JetpacsTheme]) that needs a
 * device; the parsing that mirrors the spec is pure data and checked here.
 */
class ThemeBaseTest {

    @Test
    fun materialBaseWhenNoColors() {
        assertEquals("material", emacsThemeBase(JSONObject().put("base", "material")))
    }

    @Test
    fun defaultBaseWhenNoColors() {
        assertEquals("default", emacsThemeBase(JSONObject().put("base", "default")))
    }

    @Test
    fun mirrorPayloadHasNoBase() {
        // A palette push wins as a mirror; any base beside it is irrelevant.
        val mirror = JSONObject()
            .put("colors", JSONObject().put("primary", "#3fbf6f"))
            .put("base", "material")
        assertNull(emacsThemeBase(mirror))
    }

    @Test
    fun bareClearHasNoBase() {
        // `colors: null` with no base is the legacy clear — companion auto-picks.
        assertNull(emacsThemeBase(JSONObject()))
    }

    @Test
    fun emptyBaseStringIsNull() {
        assertNull(emacsThemeBase(JSONObject().put("base", "")))
    }
}
