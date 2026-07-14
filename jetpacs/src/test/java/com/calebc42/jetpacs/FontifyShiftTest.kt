package com.calebc42.jetpacs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [shiftRuns] maps Emacs fontify runs across one local edit so the theme
 * survives the keystroke-to-fontify-push gap; [splice] feeds it. The cases
 * pin down the boundary conventions: a run the edit lands inside stretches
 * over typed text, a run ending exactly at the cursor does not, and a run
 * starting exactly at the cursor slides right. This test belongs beside the
 * library internals it exercises so Kotlin's test friend path can access them.
 */
class FontifyShiftTest {
    private fun run(b: Int, e: Int) = FontifyRun(
        start = b, end = e, color = null, bg = null,
        bold = false, italic = false, underline = false, strike = false,
    )

    @Test
    fun spliceComparesByContentAcrossCharSequenceTypes() {
        assertNull(splice("hello", StringBuilder("hello")))
    }

    @Test
    fun insertionInsideRunStretchesIt() {
        val shifted = shiftRuns(listOf(run(2, 8)), Splice(5, 0, "xx"))
        assertEquals(listOf(run(2, 10)), shifted)
    }

    @Test
    fun insertionAtRunEndDoesNotExtendIt() {
        val shifted = shiftRuns(listOf(run(2, 8)), Splice(8, 0, "xx"))
        assertEquals(listOf(run(2, 8)), shifted)
    }

    @Test
    fun insertionAtRunStartSlidesItRight() {
        val shifted = shiftRuns(listOf(run(2, 8)), Splice(2, 0, "xx"))
        assertEquals(listOf(run(4, 10)), shifted)
    }

    @Test
    fun runAfterDeletionShiftsLeft() {
        val shifted = shiftRuns(listOf(run(5, 9)), Splice(0, 3, ""))
        assertEquals(listOf(run(2, 6)), shifted)
    }

    @Test
    fun runSwallowedByDeletionDrops() {
        val shifted = shiftRuns(listOf(run(3, 7)), Splice(2, 6, ""))
        assertEquals(emptyList<FontifyRun>(), shifted)
    }

    @Test
    fun deletionClipsRunTail() {
        val shifted = shiftRuns(listOf(run(2, 6)), Splice(4, 4, ""))
        assertEquals(listOf(run(2, 4)), shifted)
    }

    @Test
    fun deletionClipsRunHeadToAfterInsertion() {
        // Replace [2, 5) with "AB": the run's head is gone, its survivor
        // starts right after the inserted text.
        val shifted = shiftRuns(listOf(run(3, 8)), Splice(2, 3, "AB"))
        assertEquals(listOf(run(4, 7)), shifted)
    }

    @Test
    fun replacementInsideStraddlingRunResizesIt() {
        val shifted = shiftRuns(listOf(run(1, 8)), Splice(3, 2, "XYZ"))
        assertEquals(listOf(run(1, 9)), shifted)
    }

    @Test
    fun typingMidCommentViaRealSpliceKeepsBothRuns() {
        val old = ";; hello\n(defun f ())"
        val new = ";; helXlo\n(defun f ())"
        val sp = splice(old, new)!!
        val shifted = shiftRuns(listOf(run(0, 8), run(10, 15)), sp)
        assertEquals(listOf(run(0, 9), run(11, 16)), shifted)
    }
}
