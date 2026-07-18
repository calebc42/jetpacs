package com.calebc42.jetpacs

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [EditorSyncEngine.applyExternal] is the companion-side gate for SPEC §8
 * `edit.apply` — a server-authored edit applies only against the exact text
 * and seq it was computed from, else it drops and the ordinary resync round
 * converges. These tests pin the gates (seq, session, text identity, length
 * verification), the code-point → UTF-16 conversion across astral chars,
 * and the no-echo property: after an accepted apply the engine's snapshot
 * already matches the new text, so the debounce collector's next `update`
 * diffs to nothing.
 */
class EditorApplyTest {
    /** Engine with a stub socket: every send succeeds, frames are recorded. */
    private fun engine(file: String = "t.txt"): Pair<EditorSyncEngine, MutableList<Pair<String, JSONObject>>> {
        val sent = mutableListOf<Pair<String, JSONObject>>()
        val e = EditorSyncEngine(file) { action, args ->
            sent.add(action to args)
            true
        }
        return e to sent
    }

    private fun splicePayload(
        e: EditorSyncEngine,
        seq: Int,
        start: Int,
        del: Int,
        text: String,
        len: Int,
        cursor: Int,
    ) = JSONObject().apply {
        put("id", "t.txt")
        put("session", e.session)
        put("seq", seq)
        put("cursor", cursor)
        put("start", start)
        put("del", del)
        put("text", text)
        put("len", len)
    }

    @Test
    fun acceptsSpliceAtSeqPlusOneAndAdvances() {
        val (e, _) = engine()
        e.open("hello world")
        val ext = e.applyExternal(splicePayload(e, 1, 0, 5, "HELLO", 11, 5), "hello world")
        assertNotNull(ext)
        assertTrue(ext!!.hasSplice)
        assertEquals(0, ext.start)
        assertEquals(5, ext.deleted)
        assertEquals("HELLO", ext.inserted)
        assertEquals(5, ext.selCaret)
        assertEquals(1, e.seq)
    }

    @Test
    fun noEchoAfterAcceptedApply() {
        val (e, sent) = engine()
        e.open("hello world")
        assertNotNull(e.applyExternal(splicePayload(e, 1, 0, 5, "HELLO", 11, 5), "hello world"))
        sent.clear()
        // The debounce collector fires with the applied text; update must
        // send nothing (no edit.delta echo loop).
        assertTrue(e.update("HELLO world"))
        assertTrue(sent.isEmpty())
        assertEquals(1, e.seq)
    }

    @Test
    fun rejectsWrongSeq() {
        val (e, _) = engine()
        e.open("abc")
        assertNull(e.applyExternal(splicePayload(e, 2, 0, 1, "X", 3, 1), "abc"))
        assertNull(e.applyExternal(splicePayload(e, 0, 0, 1, "X", 3, 1), "abc"))
        assertEquals(0, e.seq)
    }

    @Test
    fun rejectsWrongSession() {
        val (e, _) = engine()
        e.open("abc")
        val p = splicePayload(e, 1, 0, 1, "X", 3, 1).put("session", e.session + 1)
        assertNull(e.applyExternal(p, "abc"))
    }

    @Test
    fun rejectsWhenEditorTextMovedPastLastSynced() {
        val (e, _) = engine()
        e.open("hello world")
        // The user typed during the round-trip: current text ≠ lastSynced.
        assertNull(e.applyExternal(splicePayload(e, 1, 0, 5, "HELLO", 11, 5), "hello worlds"))
        assertEquals(0, e.seq)
    }

    @Test
    fun rejectsLengthMismatch() {
        val (e, _) = engine()
        e.open("hello world")
        assertNull(e.applyExternal(splicePayload(e, 1, 0, 5, "HELLO", 12, 5), "hello world"))
        assertEquals(0, e.seq)
    }

    @Test
    fun rejectsOutOfRangeSplice() {
        val (e, _) = engine()
        e.open("abc")
        assertNull(e.applyExternal(splicePayload(e, 1, 2, 5, "X", 3, 1), "abc"))
    }

    @Test
    fun convertsCodePointsAcrossAstralChars() {
        val (e, _) = engine()
        // "a😀bc" — 😀 is one code point, two UTF-16 units.
        val text = "a😀bc"
        e.open(text)
        // Replace one code point at cp offset 2 ('b') with "XY": result a😀XYc.
        val ext = e.applyExternal(splicePayload(e, 1, 2, 1, "XY", 5, 4), text)
        assertNotNull(ext)
        assertEquals(3, ext!!.start)      // after the surrogate pair
        assertEquals(1, ext.deleted)
        assertEquals("XY", ext.inserted)
        assertEquals(5, ext.selCaret)     // cp 4 in "a😀XYc" = utf16 5 (before 'c')
    }

    @Test
    fun moveOnlyMatchesCurrentSeqAndTouchesNothing() {
        val (e, _) = engine()
        e.open("hello world")
        val p = JSONObject().apply {
            put("id", "t.txt")
            put("session", e.session)
            put("seq", 0)
            put("cursor", 11)
            put("sel_start", 6)
            put("sel_end", 11)
        }
        val ext = e.applyExternal(p, "hello world")
        assertNotNull(ext)
        assertFalse(ext!!.hasSplice)
        assertEquals(6, ext.selAnchor)    // caret == sel_end → anchor = sel_start
        assertEquals(11, ext.selCaret)
        assertEquals(0, e.seq)
    }

    @Test
    fun moveOnlyRejectsBumpedSeq() {
        val (e, _) = engine()
        e.open("abc")
        val p = JSONObject().apply {
            put("id", "t.txt")
            put("session", e.session)
            put("seq", 1)
            put("cursor", 1)
        }
        assertNull(e.applyExternal(p, "abc"))
    }

    @Test
    fun selectionDirectionPreserved() {
        val (e, _) = engine()
        e.open("hello world")
        // Caret at sel_start (backwards selection): anchor must be sel_end.
        val p = JSONObject().apply {
            put("id", "t.txt")
            put("session", e.session)
            put("seq", 0)
            put("cursor", 6)
            put("sel_start", 6)
            put("sel_end", 11)
        }
        val ext = e.applyExternal(p, "hello world")!!
        assertEquals(11, ext.selAnchor)
        assertEquals(6, ext.selCaret)
    }

    @Test
    fun caretFrameCarriesSelectionOnlyWhenNonCollapsed() {
        val (e, sent) = engine()
        e.open("hello")
        sent.clear()
        e.caret("hello", 2)
        assertFalse(sent.last().second.has("sel_start"))
        e.caret("hello", 2, 0, 2)
        assertTrue(sent.last().second.has("sel_start"))
        assertEquals(0, sent.last().second.getInt("sel_start"))
        assertEquals(2, sent.last().second.getInt("sel_end"))
    }

    @Test
    fun commandSyncsThenSendsCoordinates() {
        val (e, sent) = engine()
        e.open("hello world")
        sent.clear()
        // Unsynced text first: command must ship the delta, then the frame.
        e.command("hello worlds", 5, 0, 5, "upcase-region")
        assertEquals(listOf("edit.delta", "edit.command"), sent.map { it.first })
        val args = sent.last().second
        assertEquals(1, args.getInt("seq"))
        assertEquals(5, args.getInt("cursor"))
        assertEquals(0, args.getInt("sel_start"))
        assertEquals(5, args.getInt("sel_end"))
        assertEquals("upcase-region", args.getString("command"))
    }

    @Test
    fun commandOmitsNameForMxPrompt() {
        val (e, sent) = engine()
        e.open("abc")
        sent.clear()
        e.command("abc", 0, 0, 0, null)
        assertFalse(sent.last().second.has("command"))
    }
}
