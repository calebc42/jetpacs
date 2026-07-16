package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * SPEC §11 on_fire placeholder dynamics
 * ([PLAN-conditions-and-dynamics.md](../../../../../../../docs/PLAN-conditions-and-dynamics.md)
 * Phase 1): the pure interpolation helpers behind [TriggerHost.executeOnFire].
 * The §9 snippet-grammar rules are pinned here — substitution, literal
 * pass-through, JSON-form rendering, single pass, recursion — and the wire
 * pass-through of un-interpolated tokens is pinned by
 * `ebp/goldens/frames.golden` line 00 (via the ERT
 * `jetpacs-frames-wire-format`).
 */
class OnFireInterpolationTest {

    private fun data(vararg pairs: Pair<String, Any?>) =
        JSONObject().apply { for ((k, v) in pairs) put(k, v) }

    @Test fun knownTokensSubstitute() {
        val d = data("plug" to "ac")
        assertEquals(
            "power ac / power-sync",
            TriggerHost.interpolate("\${type} \${data.plug} / \${id}", "power-sync", "power", d))
    }

    @Test fun unknownAndMissingTokensStayLiteral() {
        val d = data("plug" to "ac")            // no "level" field
        assertEquals(
            "\${bogus} \${data.level} \${data.} ac",
            TriggerHost.interpolate("\${bogus} \${data.level} \${data.} \${data.plug}",
                "id0", "power", d))
    }

    @Test fun explicitJsonNullStaysLiteral() {
        val d = data("plug" to JSONObject.NULL)
        assertEquals("\${data.plug}", TriggerHost.interpolate("\${data.plug}", "id0", "power", d))
    }

    @Test fun numbersAndBooleansRenderAsJsonText() {
        val d = data("level" to 63, "charging" to true)
        assertEquals("63 true",
            TriggerHost.interpolate("\${data.level} \${data.charging}", "id0", "battery.level", d))
    }

    @Test fun substitutionIsSinglePassNoRescan() {
        // A field whose VALUE looks like a token must not be re-expanded.
        val d = data("plug" to "\${id}")
        assertEquals("\${id}", TriggerHost.interpolate("\${data.plug}", "real-id", "power", d))
    }

    @Test fun recursionCoversNestedArgsAndArrays() {
        val d = data("plug" to "ac")
        val args = JSONObject().apply {
            put("title", "\${id}")
            put("nested", JSONObject().put("k", "plug=\${data.plug}"))
            put("list", JSONArray().put("\${type}").put(7))
        }
        val out = TriggerHost.interpolateValue(args, "power-sync", "power", d) as JSONObject
        assertEquals("power-sync", out.getString("title"))
        assertEquals("plug=ac", out.getJSONObject("nested").getString("k"))
        assertEquals("power", out.getJSONArray("list").getString(0))
        assertEquals(7, out.getJSONArray("list").getInt(1))     // non-strings untouched
    }

    @Test fun objectKeysAreNotInterpolated() {
        // interpolateValue rebuilds objects interpolating VALUES only, keys
        // verbatim — the structural reason a `cap` name (a sibling field the
        // executor never routes through interpolate) is safe.
        val d = data("x" to "SUBSTITUTED")
        val obj = JSONObject().put("\${data.x}", "\${data.x}")
        val out = TriggerHost.interpolateValue(obj, "id0", "t", d) as JSONObject
        assertEquals("SUBSTITUTED", out.getString("\${data.x}"))   // key unchanged
        assertEquals(null, out.opt("SUBSTITUTED"))                 // key was not rewritten
    }
}
