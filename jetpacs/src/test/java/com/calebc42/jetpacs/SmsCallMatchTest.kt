package com.calebc42.jetpacs

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure `sms.received` / `call.state` matchers (SPEC §11, Phase 5):
 * substring matching, opt-in payload (body omitted by default even when
 * `contains` read it), and the duplicate-broadcast dedupe. The
 * permission-gated receiver plumbing is on-device acceptance
 * (PLAN-conditions-and-dynamics Phase 6).
 */
class SmsCallMatchTest {

    private fun p(json: String) = JSONObject(json)

    // ── sms.received matching ────────────────────────────────────────────────

    @Test fun smsRowMatchesFromAndContains() {
        val fromBank = p("""{"from":"+1555"}""")
        assertTrue(TriggerHost.smsRowMatches(fromBank, "+15551234", "hi"))
        assertFalse(TriggerHost.smsRowMatches(fromBank, "+19998888", "hi"))
        assertFalse(TriggerHost.smsRowMatches(fromBank, null, "hi"))

        val otp = p("""{"contains":"code"}""")
        assertTrue(TriggerHost.smsRowMatches(otp, "anyone", "your code is 123"))
        assertFalse(TriggerHost.smsRowMatches(otp, "anyone", "hello there"))

        // No filters = every message matches.
        assertTrue(TriggerHost.smsRowMatches(JSONObject(), "anyone", "anything"))
    }

    @Test fun buildSmsDataOmitsBodyByDefault() {
        // The privacy contract: matching on `contains` reads the body,
        // but only include_body:true puts it on the wire.
        val matchOnly = p("""{"contains":"secret"}""")
        val data = TriggerHost.buildSmsData(matchOnly, "+1555", "the secret is 42")
        assertEquals("+1555", data.getString("from"))
        assertFalse(data.has("body"))

        val withBody = p("""{"include_body":true}""")
        val data2 = TriggerHost.buildSmsData(withBody, "+1555", "hello")
        assertEquals("hello", data2.getString("body"))

        // A null sender simply omits `from` (never a JSON null).
        val data3 = TriggerHost.buildSmsData(JSONObject(), null, "x")
        assertFalse(data3.has("from"))
    }

    // ── call.state dedupe ────────────────────────────────────────────────────

    @Test fun callStateDedupePlainFiresOncePerTransition() {
        val d = CallStateDedupe()
        // First ringing broadcast (no number): plain fires.
        assertEquals(true to false, d.classify("ringing", hasNumber = false))
        // The duplicate ringing broadcast: plain suppressed.
        assertEquals(false to false, d.classify("ringing", hasNumber = false))
        // A new transition fires plain again.
        assertEquals(true to false, d.classify("idle", hasNumber = false))
    }

    @Test fun callStateDedupeNumberedRidesTheNumberedDuplicate() {
        val d = CallStateDedupe()
        // Number-less broadcast first: plain fires, numbered waits.
        assertEquals(true to false, d.classify("ringing", hasNumber = false))
        // The number-carrying duplicate (READ_CALL_LOG): numbered fires once.
        assertEquals(false to true, d.classify("ringing", hasNumber = true))
        // Any further duplicate: nothing.
        assertEquals(false to false, d.classify("ringing", hasNumber = true))
    }

    @Test fun callStateDedupeNumberOnFirstBroadcastFiresBoth() {
        val d = CallStateDedupe()
        // When the very first broadcast already carries the number, plain
        // and numbered both fire on it, and the duplicate is silent.
        assertEquals(true to true, d.classify("offhook", hasNumber = true))
        assertEquals(false to false, d.classify("offhook", hasNumber = true))
    }
}
