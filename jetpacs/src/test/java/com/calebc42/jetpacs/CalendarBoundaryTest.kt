package com.calebc42.jetpacs

import com.calebc42.jetpacs.CalendarTriggers.CalInstance
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure `calendar.event` math ([CalendarTriggers]): instance
 * matching, ongoing/next classification, and the boundary-alarm rule —
 * ongoing → its end, idle → the next start, empty window → the
 * lookahead re-scan fallback. The observer/alarm plumbing is on-device
 * acceptance (PLAN-conditions-and-dynamics Phase 6).
 */
class CalendarBoundaryTest {

    private val now = 1_000_000L
    private val hour = 60L * 60 * 1000

    private fun inst(begin: Long, end: Long, title: String? = null, cal: String? = null) =
        CalInstance(begin, end, title, cal)

    @Test fun idleParksAtNextMatchingStart() {
        val (ongoing, next) = CalendarTriggers.classify(
            listOf(inst(now + 3 * hour, now + 4 * hour),
                   inst(now + hour, now + 2 * hour)),
            now)
        assertNull(ongoing)
        assertEquals(now + hour, next!!.beginMs)
        assertEquals(now + hour, CalendarTriggers.nextBoundaryMs(now, ongoing, next))
    }

    @Test fun ongoingParksAtCurrentEnd() {
        val (ongoing, next) = CalendarTriggers.classify(
            listOf(inst(now - hour, now + hour),          // ongoing
                   inst(now - hour, now + 2 * hour),      // ongoing, later end
                   inst(now + 3 * hour, now + 4 * hour)), // future
            now)
        // The earliest end among ongoing instances is the next boundary.
        assertEquals(now + hour, ongoing!!.endMs)
        assertEquals(now + hour, CalendarTriggers.nextBoundaryMs(now, ongoing, next))
    }

    @Test fun emptyWindowFallsBackToRescan() {
        val (ongoing, next) = CalendarTriggers.classify(emptyList(), now)
        assertNull(ongoing)
        assertNull(next)
        assertEquals(now + CalendarTriggers.LOOKAHEAD_MS,
            CalendarTriggers.nextBoundaryMs(now, ongoing, next))
    }

    @Test fun boundariesAreHalfOpen() {
        // At the exact begin the instance is ongoing; at the exact end
        // it is not — so an alarm parked at a boundary lands on the far
        // side of the flip it was parked for.
        val i = inst(now, now + hour)
        assertEquals(i, CalendarTriggers.classify(listOf(i), now).first)
        assertNull(CalendarTriggers.classify(listOf(i), now + hour).first)
    }

    @Test fun matchingFiltersTitleAndCalendar() {
        val standup = JSONObject("""{"title_contains":"standup"}""")
        assertTrue(CalendarTriggers.instanceMatches(standup, "Team STANDUP call", null))
        assertFalse(CalendarTriggers.instanceMatches(standup, "1:1", null))
        assertFalse(CalendarTriggers.instanceMatches(standup, null, null))

        val work = JSONObject("""{"calendar":"Work"}""")
        assertTrue(CalendarTriggers.instanceMatches(work, "anything", "Work"))
        assertFalse(CalendarTriggers.instanceMatches(work, "anything", "Personal"))

        val both = JSONObject("""{"calendar":"Work","title_contains":"standup"}""")
        assertTrue(CalendarTriggers.instanceMatches(both, "Standup", "Work"))
        assertFalse(CalendarTriggers.instanceMatches(both, "Standup", "Personal"))

        // No match fields = every instance matches.
        assertTrue(CalendarTriggers.instanceMatches(JSONObject(), null, null))
    }
}
