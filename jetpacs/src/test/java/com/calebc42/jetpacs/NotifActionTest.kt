package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Off-device unit coverage for the notification action-button parser
 * ([NotifAction], SPEC §9). The renderer's Android surface (PendingIntent /
 * RemoteInput) still needs a device, but the wire-shape parsing — the part
 * that mirrors the spec — is pure data and checked here.
 */
class NotifActionTest {

    private fun action(name: String) = JSONObject().put("action", name)

    @Test
    fun parsesFullMetaEntry() {
        val arr = JSONArray().put(
            JSONObject()
                .put("label", "Done")
                .put("on_tap", action("a.b"))
                .put("icon", "check")
                .put("dismiss", true)
        )
        val actions = NotifAction.fromMetaActions(arr)
        assertEquals(1, actions.size)
        val a = actions[0]
        assertEquals("Done", a.label)
        assertEquals("a.b", a.onTap.getString("action"))
        assertEquals("check", a.icon)
        assertTrue(a.dismiss)
        assertNull(a.inputKey)
        assertNull(a.inputHint)
    }

    @Test
    fun inlineReplyDefaultsKeyToReply() {
        // An empty `input` object still enables inline reply, key defaulting.
        val arr = JSONArray().put(
            JSONObject().put("label", "Reply").put("on_tap", action("a.c"))
                .put("input", JSONObject())
        )
        val a = NotifAction.fromMetaActions(arr).single()
        assertEquals("reply", a.inputKey)
        assertNull(a.inputHint)
    }

    @Test
    fun inlineReplyHonorsHintAndKey() {
        val arr = JSONArray().put(
            JSONObject().put("label", "Reply").put("on_tap", action("a.c"))
                .put("input", JSONObject().put("hint", "Note").put("key", "note"))
        )
        val a = NotifAction.fromMetaActions(arr).single()
        assertEquals("note", a.inputKey)
        assertEquals("Note", a.inputHint)
    }

    @Test
    fun skipsEntriesWithoutOnTapOrLabel() {
        val arr = JSONArray()
            .put(JSONObject().put("label", "No action"))          // no on_tap
            .put(JSONObject().put("on_tap", action("a.b")))       // no label
            .put(JSONObject().put("label", "Ok").put("on_tap", action("a.b")))
        val actions = NotifAction.fromMetaActions(arr)
        assertEquals(1, actions.size)
        assertEquals("Ok", actions[0].label)
    }

    @Test
    fun defaultsAbsentIconAndDismiss() {
        val arr = JSONArray().put(
            JSONObject().put("label", "Go").put("on_tap", action("a.b"))
        )
        val a = NotifAction.fromMetaActions(arr).single()
        assertNull(a.icon)
        assertFalse(a.dismiss)
        assertNull(a.inputKey)
    }

    @Test
    fun legacyBodyButtonNeverDismissesOrReplies() {
        val button = JSONObject().put("t", "button")
            .put("label", "Open").put("on_tap", action("a.b")).put("icon", "folder")
        val a = NotifAction.fromButton(button)!!
        assertEquals("Open", a.label)
        assertEquals("folder", a.icon)
        assertFalse(a.dismiss)
        assertNull(a.inputKey)
        // A button with no action is not an action button.
        assertNull(NotifAction.fromButton(JSONObject().put("t", "button").put("label", "x")))
    }
}
