package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure renderer helpers introduced by the reconciliation
 * track (docs/PLAN-renderer-reconciliation.md): the K2 defensive clamps and
 * the K1a lazy-list key derivation. These are deliberately split out of the
 * composables so they can be exercised on the plain JVM.
 */
class SduiRendererHelpersTest {

    // ── K2: safe numeric clamps ──────────────────────────────────────────

    @Test fun safeAspectRejectsNonPositiveAndNonFinite() {
        assertNull(safeAspect(0.0))
        assertNull(safeAspect(-1.5))
        assertNull(safeAspect(Double.NaN))
        assertNull(safeAspect(Double.POSITIVE_INFINITY))
        assertEquals(1.5f, safeAspect(1.5)!!, 0f)
    }

    @Test fun safeFractionAcceptsOnlyZeroToOneExclusiveOfZero() {
        assertNull(safeFraction(0.0))
        assertNull(safeFraction(-0.2))
        assertNull(safeFraction(1.0001))
        assertNull(safeFraction(Double.NaN))
        assertEquals(0.5f, safeFraction(0.5)!!, 0f)
        assertEquals(1.0f, safeFraction(1.0)!!, 0f)
    }

    @Test fun safeDpRejectsNegative() {
        assertNull(safeDp(-1))
        assertEquals(0, safeDp(0))
        assertEquals(12, safeDp(12))
    }

    // ── K1a: lazy-list key derivation ────────────────────────────────────

    private fun arr(vararg nodes: JSONObject): JSONArray =
        JSONArray().apply { nodes.forEach { put(it) } }

    private fun node(vararg kv: Pair<String, String>): JSONObject =
        JSONObject().apply { kv.forEach { (k, v) -> put(k, v) } }

    @Test fun keysPreferExplicitKeyThenIdThenIndex() {
        val keys = lazyChildKeys(
            arr(
                node("key" to "explicit"),
                node("id" to "field1"),
                node("t" to "text"),           // keyless leaf
            )
        )
        assertEquals(listOf("k:explicit", "id:field1", "i:2"), keys)
    }

    @Test fun explicitKeyWinsOverId() {
        val keys = lazyChildKeys(arr(node("key" to "K", "id" to "I")))
        assertEquals(listOf("k:K"), keys)
    }

    @Test fun duplicateBasesAreDisambiguatedSoKeysStayUnique() {
        val keys = lazyChildKeys(
            arr(node("id" to "dup"), node("id" to "dup"), node("id" to "dup"))
        )
        assertEquals(listOf("id:dup", "id:dup#1", "id:dup#2"), keys)
        assertEquals(keys.size, keys.toSet().size) // all unique
    }

    @Test fun keyCountAlwaysMatchesChildCountAndIsUnique() {
        val children = arr(
            node("id" to "a"),
            node("key" to "a"),   // same raw string, different namespace -> distinct
            node("t" to "divider"),
            node("id" to "a"),    // collides with first -> suffixed
        )
        val keys = lazyChildKeys(children)
        assertEquals(children.length(), keys.size)
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test fun statefulRowKeyIsStableAcrossReorder() {
        // Two "pushes" of the same rows in different order: the id-keyed rows
        // keep the same key, which is what lets Compose move (not rebuild)
        // their composition and preserve focus/scroll.
        val before = lazyChildKeys(arr(node("id" to "a"), node("id" to "b"), node("id" to "c")))
        val after = lazyChildKeys(arr(node("id" to "c"), node("id" to "a"), node("id" to "b")))
        assertTrue("id:a" in before && "id:a" in after)
        assertTrue("id:b" in before && "id:b" in after)
        assertTrue("id:c" in before && "id:c" in after)
    }
}
