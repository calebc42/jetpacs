package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SPEC §11 `when` gate semantics ([StateSampler.evaluateWhen] /
 * [StateSampler.validateWhen]), on the JVM with no Android context —
 * which is itself the fail-closed contract: an unevaluable predicate
 * never holds. The context-backed samplers are on-device acceptance
 * (PLAN-conditions-and-dynamics Phase 6).
 */
class StateSamplerWhenTest {

    @Test fun absentGateHolds() {
        assertTrue(StateSampler.evaluateWhen(null, null))
        assertTrue(StateSampler.evaluateWhen(null, ""))
    }

    @Test fun emptyGateHolds() {
        assertTrue(StateSampler.evaluateWhen(null, "[]"))
    }

    @Test fun unparseableGateFailsClosed() {
        assertFalse(StateSampler.evaluateWhen(null, "not json"))
        assertFalse(StateSampler.evaluateWhen(null, """[42]"""))
    }

    @Test fun unknownTypeFailsClosed() {
        assertFalse(StateSampler.evaluateWhen(null, """[{"type":"martian"}]"""))
    }

    @Test fun unsampleableWithoutContextFailsClosed() {
        // A legal predicate the JVM cannot sample (no Context) must not
        // hold — never fire garbage.
        assertFalse(StateSampler.evaluateWhen(null, """[{"type":"power"}]"""))
    }

    @Test fun timeWindowNeedsNoContextAndGateIsAnded() {
        // A boundless window always holds …
        assertTrue(StateSampler.evaluateWhen(null, """[{"type":"time.window"}]"""))
        // … and one failing predicate fails the AND-ed whole.
        assertFalse(StateSampler.evaluateWhen(
            null, """[{"type":"time.window"},{"type":"martian"}]"""))
    }

    @Test fun validateWhenAcceptsTheCatalogShapes() {
        assertNull(StateSampler.validateWhen(JSONArray(
            """[{"type":"power","state":"disconnected"},
                {"type":"battery.level","below":20},
                {"type":"time.window","after":"22:00","before":"07:00",
                 "days":["mon","sun"]}]""")))
    }

    @Test fun validateWhenRejectsGarbageWithAMessage() {
        assertEquals("when[0] is not an object",
            StateSampler.validateWhen(JSONArray("""[42]""")))
        assertEquals("when[0]: missing 'type'",
            StateSampler.validateWhen(JSONArray("""[{"state":"on"}]""")))
        assertEquals("when[0]: unknown state type 'martian'",
            StateSampler.validateWhen(JSONArray("""[{"type":"martian"}]""")))
        assertEquals("when[0]: battery.level needs 'above' or 'below'",
            StateSampler.validateWhen(JSONArray("""[{"type":"battery.level"}]""")))
        assertEquals("when[0]: 'after' must be \"HH:MM\"",
            StateSampler.validateWhen(JSONArray(
                """[{"type":"time.window","after":"25:00"}]""")))
        assertEquals("when[0]: unknown day 'monday'",
            StateSampler.validateWhen(JSONArray(
                """[{"type":"time.window","days":["monday"]}]""")))
    }

    @Test fun holdsRejectsBatteryPredicateWithoutBounds() {
        // Belt under the validateWhen suspenders: even if a boundless
        // battery.level predicate reached evaluation, it must not hold.
        assertFalse(StateSampler.holds(null, JSONObject("""{"type":"battery.level"}""")))
    }
}
