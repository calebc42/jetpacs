package com.calebc42.jetpacs

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Off-device coverage for the launch-token gate ([JetpacsLaunch.tokenMatches]).
 * The prefs round-trip and intent plumbing need a device; the decision that
 * matters — an ABSENT token is a mismatch, so a forger can't bypass the gate
 * by omitting the extra (and pre-token pinned shortcuts degrade to open-only
 * rather than firing) — is pure and pinned here.
 */
class LaunchTokenTest {

    @Test
    fun absentTokenIsRejected() {
        assertFalse(JetpacsLaunch.tokenMatches("expected", null))
    }

    @Test
    fun wrongTokenIsRejected() {
        assertFalse(JetpacsLaunch.tokenMatches("expected", "forged"))
        assertFalse(JetpacsLaunch.tokenMatches("expected", ""))
    }

    @Test
    fun matchingTokenIsAccepted() {
        assertTrue(JetpacsLaunch.tokenMatches("expected", "expected"))
    }
}
