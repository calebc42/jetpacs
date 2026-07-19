package com.calebc42.jetpacs

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The conflating bounded queue (SPEC-2 §5, receiver side): latest-wins
 * traffic collapses to one slot per key, ordered/event traffic never
 * conflates, and the bound reports exhaustion instead of growing.
 */
class InboundPipelineTest {

    private fun note(method: String, vararg pairs: Pair<String, Any>): RpcNotification =
        RpcNotification(method, JSONObject().apply { pairs.forEach { put(it.first, it.second) } })

    private fun surfaceUpdate(surface: String, revision: Int): RpcNotification =
        note(Method.SURFACE_UPDATE, "surface" to surface, "revision" to revision)

    private fun revisionOf(msg: RpcIn?): Int =
        ((msg as RpcNotification).params).getInt("revision")

    @Test
    fun sameKeyConflatesToLatest() {
        val q = InboundPipeline()
        assertTrue(q.offer(surfaceUpdate("app:x", 1), "surface/app:x"))
        assertTrue(q.offer(surfaceUpdate("app:x", 2), "surface/app:x"))
        assertTrue(q.offer(surfaceUpdate("app:x", 3), "surface/app:x"))
        q.close()
        // Only the newest survives; revisions 1 and 2 were never processed.
        assertEquals(3, revisionOf(q.take()))
        assertNull(q.take())
        assertEquals(2L, q.conflated)
    }

    @Test
    fun distinctKeysDoNotConflate() {
        val q = InboundPipeline()
        q.offer(surfaceUpdate("app:x", 1), "surface/app:x")
        q.offer(surfaceUpdate("app:y", 1), "surface/app:y")
        q.close()
        assertEquals("app:x", (q.take() as RpcNotification).params.getString("surface"))
        assertEquals("app:y", (q.take() as RpcNotification).params.getString("surface"))
        assertNull(q.take())
        assertEquals(0L, q.conflated)
    }

    @Test
    fun conflatedReplacementLandsAtTailBehindIntervening() {
        // update(x,1) … remove(x) … update(x,2): the newest update must be
        // processed AFTER the remove, or the surface resurrects wrongly.
        val q = InboundPipeline()
        q.offer(surfaceUpdate("app:x", 1), "surface/app:x")
        q.offer(note(Method.SURFACE_REMOVE, "surface" to "app:x"), null)
        q.offer(surfaceUpdate("app:x", 2), "surface/app:x")
        q.close()
        assertEquals(Method.SURFACE_REMOVE, (q.take() as RpcNotification).method)
        assertEquals(2, revisionOf(q.take()))
        assertNull(q.take())
    }

    @Test
    fun unkeyedTrafficIsNeverConflated() {
        // Events are class-3 traffic: every one matters, in order.
        val q = InboundPipeline()
        repeat(5) { i -> q.offer(note(Method.EVENT_ACTION, "action" to "tap.$i"), null) }
        q.close()
        val seen = generateSequence { q.take() }
            .map { (it as RpcNotification).params.getString("action") }.toList()
        assertEquals(listOf("tap.0", "tap.1", "tap.2", "tap.3", "tap.4"), seen)
    }

    @Test
    fun keyReusableAfterTake() {
        val q = InboundPipeline()
        q.offer(surfaceUpdate("app:x", 1), "surface/app:x")
        assertEquals(1, revisionOf(q.take()))
        // A new frame for the same key after processing is a fresh entry,
        // not a tombstone casualty.
        q.offer(surfaceUpdate("app:x", 2), "surface/app:x")
        q.close()
        assertEquals(2, revisionOf(q.take()))
        assertNull(q.take())
    }

    @Test
    fun boundReportsExhaustion() {
        val q = InboundPipeline(capacity = 3)
        assertTrue(q.offer(note(Method.EVENT_ACTION, "action" to "a"), null))
        assertTrue(q.offer(note(Method.EVENT_ACTION, "action" to "b"), null))
        assertTrue(q.offer(note(Method.EVENT_ACTION, "action" to "c"), null))
        assertFalse(q.offer(note(Method.EVENT_ACTION, "action" to "d"), null))
    }

    @Test
    fun conflationKeepsTheBoundFlat() {
        // A push-storm of one surface occupies ONE slot no matter how long
        // it runs — the essence of §5 rule 1.
        val q = InboundPipeline(capacity = 4)
        for (rev in 1..100) {
            assertTrue(q.offer(surfaceUpdate("app:x", rev), "surface/app:x"))
        }
        q.close()
        assertEquals(100, revisionOf(q.take()))
        assertNull(q.take())
        assertEquals(99L, q.conflated)
    }
}
