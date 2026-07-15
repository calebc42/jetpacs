package com.calebc42.jetpacs

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SPEC §11 replace-set parsing ([TriggerHost.parseTriggerRows], the
 * Room-free extraction): whole-set semantics, and the `when` gate's
 * validate-or-reject rule — a malformed gate must reject the set, never
 * be dropped (dropping would arm the trigger ungated, the §11 critical
 * hazard).
 */
class TriggerParseValidationTest {

    @Test fun whenStoredOnRow() {
        val (rows, err) = TriggerHost.parseTriggerRows(JSONArray(
            """[{"id":"gated","type":"power",
                 "when":[{"type":"time.window","after":"22:00"}]},
                {"id":"plain","type":"screen"}]"""))
        assertNull(err)
        assertNotNull(rows)
        assertEquals(2, rows!!.size)
        val gated = rows.first { it.id == "gated" }
        assertNotNull(gated.whenJson)
        assertTrue(gated.whenJson!!.contains("time.window"))
        assertNull(rows.first { it.id == "plain" }.whenJson)
    }

    @Test fun badWhenRejectsWholeSet() {
        val (rows, err) = TriggerHost.parseTriggerRows(JSONArray(
            """[{"id":"fine","type":"screen"},
                {"id":"gated","type":"power","when":[{"type":"martian"}]}]"""))
        assertNull(rows)
        assertEquals("trigger 'gated': when[0]: unknown state type 'martian'", err)
    }

    @Test fun unknownTypeStillRejectsWholeSet() {
        val (rows, err) = TriggerHost.parseTriggerRows(JSONArray(
            """[{"id":"x","type":"warp.drive"}]"""))
        assertNull(rows)
        assertEquals("trigger 'x': unknown type 'warp.drive'", err)
    }

    @Test fun missingIdRejects() {
        val (rows, err) = TriggerHost.parseTriggerRows(JSONArray(
            """[{"type":"power"}]"""))
        assertNull(rows)
        assertEquals("trigger 0: missing id or type", err)
    }

    @Test fun nullSetParsesEmpty() {
        val (rows, err) = TriggerHost.parseTriggerRows(null)
        assertNull(err)
        assertEquals(0, rows!!.size)
    }
}
