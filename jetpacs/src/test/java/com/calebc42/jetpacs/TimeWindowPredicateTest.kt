package com.calebc42.jetpacs

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure `time.window` evaluator ([StateSampler.timeWindowHolds])
 * with an injected clock: minutes-of-day 0..1439, day index 0=Monday.
 * Half-open bounds `[after, before)`; wrap-midnight when after > before;
 * an absent bound is open; `days` filters the current calendar day.
 */
class TimeWindowPredicateTest {

    private fun p(json: String) = JSONObject(json)

    private val monday = 0
    private val sunday = 6

    @Test fun insideAndOutsideAPlainWindow() {
        val w = p("""{"type":"time.window","after":"07:00","before":"09:00"}""")
        assertTrue(StateSampler.timeWindowHolds(7 * 60, monday, w))       // 07:00 in
        assertTrue(StateSampler.timeWindowHolds(8 * 60 + 59, monday, w))  // 08:59 in
        assertFalse(StateSampler.timeWindowHolds(9 * 60, monday, w))      // 09:00 out
        assertFalse(StateSampler.timeWindowHolds(6 * 60 + 59, monday, w)) // 06:59 out
    }

    @Test fun wrapsMidnightWhenAfterExceedsBefore() {
        val w = p("""{"type":"time.window","after":"22:00","before":"07:00"}""")
        assertTrue(StateSampler.timeWindowHolds(23 * 60, monday, w))      // 23:00 in
        assertTrue(StateSampler.timeWindowHolds(1 * 60, monday, w))       // 01:00 in
        assertFalse(StateSampler.timeWindowHolds(12 * 60, monday, w))     // noon out
        assertFalse(StateSampler.timeWindowHolds(7 * 60, monday, w))      // 07:00 out
    }

    @Test fun openBounds() {
        val afterOnly = p("""{"type":"time.window","after":"18:00"}""")
        assertTrue(StateSampler.timeWindowHolds(23 * 60, monday, afterOnly))
        assertFalse(StateSampler.timeWindowHolds(12 * 60, monday, afterOnly))
        val beforeOnly = p("""{"type":"time.window","before":"09:00"}""")
        assertTrue(StateSampler.timeWindowHolds(0, monday, beforeOnly))
        assertFalse(StateSampler.timeWindowHolds(9 * 60, monday, beforeOnly))
        val boundless = p("""{"type":"time.window"}""")
        assertTrue(StateSampler.timeWindowHolds(0, monday, boundless))
    }

    @Test fun daysFilter() {
        val weekdaysOnly = p(
            """{"type":"time.window","days":["mon","tue","wed","thu","fri"]}""")
        assertTrue(StateSampler.timeWindowHolds(12 * 60, monday, weekdaysOnly))
        assertFalse(StateSampler.timeWindowHolds(12 * 60, sunday, weekdaysOnly))
        // days AND the clock window must both hold.
        val monMorning = p(
            """{"type":"time.window","after":"07:00","before":"09:00","days":["mon"]}""")
        assertTrue(StateSampler.timeWindowHolds(8 * 60, monday, monMorning))
        assertFalse(StateSampler.timeWindowHolds(8 * 60, sunday, monMorning))
        assertFalse(StateSampler.timeWindowHolds(12 * 60, monday, monMorning))
    }
}
