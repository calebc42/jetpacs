package com.calebc42.jetpacs

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionStatusTest {
    private val now = 10_000_000L

    @Test
    fun relativeAgeUsesReadableBoundaries() {
        assertEquals("just now", relativeAge(now - 59_000L, now))
        assertEquals("1 minute ago", relativeAge(now - 60_000L, now))
        assertEquals("2 hours ago", relativeAge(now - 2 * 60 * 60_000L, now))
        assertEquals("1 day ago", relativeAge(now - 24 * 60 * 60_000L, now))
    }

    @Test
    fun offlineSummaryIncludesCacheAgeAndQueue() {
        assertEquals(
            "Saved 5 minutes ago · 1 saved action waiting",
            connectionSummary(connected = false, queuedCount = 1, age = "5 minutes ago"),
        )
    }

    @Test
    fun reconnectSummaryExplainsPendingReplay() {
        assertEquals(
            "3 saved actions waiting to sync",
            connectionSummary(connected = true, queuedCount = 3, age = "just now"),
        )
        assertEquals(
            "Up to date",
            connectionSummary(connected = true, queuedCount = 0, age = "just now"),
        )
    }
}
