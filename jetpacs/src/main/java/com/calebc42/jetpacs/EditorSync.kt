package com.calebc42.jetpacs

import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import org.json.JSONObject
import kotlin.random.Random

/**
 * One editor's live sync channel to Emacs (see jetpacs-sync.el).
 *
 * The engine mirrors the editor's text into a per-file shadow buffer on the
 * Emacs side: `open` ships the full document once, `update` diffs against the
 * last synced snapshot and ships one splice, `requestCompletions` rides the
 * synced state with a bare cursor offset. All offsets cross the wire as
 * Unicode code points (= Emacs buffer characters), converted here from
 * Kotlin's UTF-16 indices, so the Emacs side never does encoding math.
 *
 * Everything goes straight down the live socket (never the broadcast/queue/
 * wake path — sync is ephemeral and latency-bound). A failed send drops
 * [lastSynced], which forces a fresh `open` on the next update; combined with
 * Emacs's seq verification and `edit.resync` replies, desync always converges
 * back to a full-text reseed and can never produce a wrong shadow.
 *
 * Not thread-safe by design: one engine belongs to one editor composition and
 * is driven from its single debounced effect (plus a fire-and-forget close).
 *
 * [sender] defaults to the live socket ([sendEditAction]); unit tests inject
 * a stub so engine state machinery is testable off-device.
 */
internal class EditorSyncEngine(
    private val file: String,
    private val sender: (String, JSONObject) -> Boolean = ::sendEditAction,
) {
    /** Phone-chosen session id; Emacs echoes it in resync/diagnostics frames. */
    val session: Int = Random.nextInt(1, Int.MAX_VALUE)

    /** Last delta sequence number Emacs should have applied. */
    var seq: Int = 0
        private set

    private var lastSynced: String? = null

    /** Ship the full text, resetting the session to seq 0. */
    fun open(text: String): Boolean {
        val ok = sender("edit.open", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("text", text)
        })
        lastSynced = if (ok) text else null
        if (ok) seq = 0
        return ok
    }

    /** Diff against the last synced snapshot and ship one splice. */
    fun update(text: String): Boolean {
        val old = lastSynced ?: return open(text)
        val s = splice(old, text) ?: return true
        val ok = sender("edit.delta", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("seq", seq + 1)
            put("start", old.codePointCount(0, s.start))
            put("del", old.codePointCount(s.start, s.start + s.deleted))
            put("text", s.inserted)
            put("len", text.codePointCount(0, text.length))
        })
        if (ok) {
            seq += 1
            lastSynced = text
        } else {
            lastSynced = null
        }
        return ok
    }

    /**
     * Slim completion request: syncs [text] first if needed, then sends only
     * the cursor (as a code-point offset) plus session/seq so Emacs can prove
     * its shadow matches before completing.
     */
    fun requestCompletions(text: String, cursorUtf16: Int, requestId: Int): Boolean {
        if (lastSynced != text && !update(text)) return false
        val cursorCp = text.codePointCount(0, cursorUtf16.coerceIn(0, text.length))
        return sender("edit.complete", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("seq", seq)
            put("request_id", requestId)
            put("cursor", cursorCp)
        })
    }

    /**
     * Report the caret — and, when non-collapsed, the selection — for eldoc
     * and Emacs's best-effort point/region record. Syncs first if the text
     * moved, sends nothing when offline, and Emacs silently ignores a report
     * that raced a delta — the next pause resends fresh state. Selection
     * bounds are optional args (SPEC §8): absent when collapsed, so an
     * Emacs predating them sees exactly the old frame.
     */
    fun caret(
        text: String,
        cursorUtf16: Int,
        selStartUtf16: Int = cursorUtf16,
        selEndUtf16: Int = cursorUtf16,
    ): Boolean {
        if (lastSynced != text && !update(text)) return false
        val cursorCp = text.codePointCount(0, cursorUtf16.coerceIn(0, text.length))
        return sender("edit.caret", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("seq", seq)
            put("cursor", cursorCp)
            if (selStartUtf16 != selEndUtf16) {
                put("sel_start", text.codePointCount(0, selStartUtf16.coerceIn(0, text.length)))
                put("sel_end", text.codePointCount(0, selEndUtf16.coerceIn(0, text.length)))
            }
        })
    }

    /**
     * Run an Emacs command in the synced session at the phone's exact
     * point/region (SPEC §8 `edit.command`). [name] is the command; null
     * asks Emacs to prompt through its bridged M-x chooser. Same discipline
     * as [requestCompletions]: sync the text first, then send coordinates
     * against the proven seq. The result, if any, comes back as an
     * `edit.apply` frame validated by [applyExternal].
     */
    fun command(
        text: String,
        cursorUtf16: Int,
        selStartUtf16: Int,
        selEndUtf16: Int,
        name: String?,
    ): Boolean {
        if (lastSynced != text && !update(text)) return false
        return sender("edit.command", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("seq", seq)
            put("cursor", text.codePointCount(0, cursorUtf16.coerceIn(0, text.length)))
            if (selStartUtf16 != selEndUtf16) {
                put("sel_start", text.codePointCount(0, selStartUtf16.coerceIn(0, text.length)))
                put("sel_end", text.codePointCount(0, selEndUtf16.coerceIn(0, text.length)))
            }
            if (name != null) put("command", name)
        })
    }

    /**
     * Validate an `edit.apply` payload against [currentText] and, on
     * success, advance the engine and return the UTF-16 edit for the caller
     * to apply to its TextFieldState in the same breath. Null = drop the
     * frame (any of: wrong session, editor text has moved past [lastSynced],
     * wrong seq, malformed splice, resulting-length mismatch) — safe by
     * construction, because a drop leaves the seq streams disagreeing and
     * the next delta round trips the ordinary resync recovery.
     *
     * Text-changing frames (splice keys present) must arrive at exactly
     * seq+1 and bump [seq]/[lastSynced]; move-only frames must match the
     * current seq and touch neither. Like every engine entry point, call
     * from the editor's own effect chain — the engine is single-driver.
     */
    fun applyExternal(payload: JSONObject, currentText: String): ExternalEdit? {
        if (payload.optInt("session") != session) return null
        if (currentText != lastSynced) return null
        val hasSplice = payload.has("start")
        val seqIn = payload.optInt("seq", -1)
        if (seqIn != if (hasSplice) seq + 1 else seq) return null
        val cpTotal = currentText.codePointCount(0, currentText.length)
        if (!hasSplice) {
            val idx = CodePointIndex(currentText)
            val caret = idx.toUtf16(payload.optInt("cursor").coerceIn(0, cpTotal))
            val (anchor, end) = selectionUtf16(payload, currentText, cpTotal, caret)
            return ExternalEdit(false, 0, 0, "", anchor, end)
        }
        val startCp = payload.optInt("start", -1)
        val delCp = payload.optInt("del", -1)
        val inserted = payload.optString("text")
        if (startCp < 0 || delCp < 0 || startCp + delCp > cpTotal) return null
        val idx = CodePointIndex(currentText)
        val start16 = idx.toUtf16(startCp)
        val end16 = idx.toUtf16(startCp + delCp)
        val newText = buildString {
            append(currentText, 0, start16)
            append(inserted)
            append(currentText, end16, currentText.length)
        }
        val newTotal = newText.codePointCount(0, newText.length)
        if (payload.optInt("len", -1) != newTotal) return null
        val newIdx = CodePointIndex(newText)
        val caret = newIdx.toUtf16(payload.optInt("cursor").coerceIn(0, newTotal))
        val (anchor, end) = selectionUtf16(payload, newText, newTotal, caret)
        seq = seqIn
        lastSynced = newText
        return ExternalEdit(true, start16, end16 - start16, inserted, anchor, end)
    }

    /** (anchor, caret) in UTF-16 from a payload's optional selection keys. */
    private fun selectionUtf16(
        payload: JSONObject,
        text: String,
        cpTotal: Int,
        caret: Int,
    ): Pair<Int, Int> {
        if (!payload.has("sel_start") || !payload.has("sel_end")) return caret to caret
        val idx = CodePointIndex(text)
        val a = idx.toUtf16(payload.optInt("sel_start").coerceIn(0, cpTotal))
        val b = idx.toUtf16(payload.optInt("sel_end").coerceIn(0, cpTotal))
        // The caret is one end; the anchor is the other, preserving direction.
        return if (caret == a) b to caret else a to caret
    }

    /**
     * True when an Emacs payload stamped (session, seq) describes exactly
     * [text]. The gate for rendering diagnostics: during the debounce gap
     * between typing and the next delta, [lastSynced] trails the editor and
     * this returns false — stale squiggles hide instead of mis-drawing.
     */
    fun isCurrent(text: String, session: Int, seq: Int): Boolean =
        session == this.session && seq == this.seq && text == lastSynced

    /** Tear down the Emacs-side session. Fire-and-forget. */
    fun close() {
        sender("edit.close", JSONObject().apply {
            put("file", file)
            put("session", session)
        })
        lastSynced = null
    }
}

/** One text splice: replace [start, start+deleted) (UTF-16 units) with [inserted]. */
internal data class Splice(val start: Int, val deleted: Int, val inserted: String)

/**
 * A validated server-authored edit (SPEC §8 `edit.apply`), converted to
 * UTF-16 and ready to apply in one `TextFieldState.edit {}` block — one
 * undo step. [hasSplice] false = move-only: position the caret/selection,
 * touch no text. [selAnchor]/[selCaret] preserve selection direction
 * (equal when collapsed); apply as `TextRange(selAnchor, selCaret)`.
 */
internal data class ExternalEdit(
    val hasSplice: Boolean,
    val start: Int,
    val deleted: Int,
    val inserted: String,
    val selAnchor: Int,
    val selCaret: Int,
)

/**
 * Minimal single-splice diff via common prefix/suffix. Any burst of edits
 * between two snapshots collapses to one splice. Boundaries are nudged off
 * surrogate pairs so the code-point conversion above never splits an astral
 * character. Returns null when the contents are equal (by content, so mixed
 * CharSequence implementations compare correctly).
 */
internal fun splice(old: CharSequence, new: CharSequence): Splice? {
    if (old.contentEquals(new)) return null
    var p = 0
    val maxP = minOf(old.length, new.length)
    while (p < maxP && old[p] == new[p]) p++
    // Never cut between a surrogate pair: widening the splice by one unit is
    // always correct, splitting a code point is never representable.
    if (p > 0 && old[p - 1].isHighSurrogate()) p--
    var so = old.length
    var sn = new.length
    while (so > p && sn > p && old[so - 1] == new[sn - 1]) {
        so--
        sn--
    }
    if (so < old.length && old[so].isLowSurrogate()) {
        so++
        sn++
    }
    return Splice(start = p, deleted = so - p, inserted = new.subSequence(p, sn).toString())
}

/** One fontification run from Emacs: UTF-16 offsets into the editor text. */
internal data class FontifyRun(
    val start: Int,
    val end: Int,
    val color: Color?,
    val bg: Color?,
    val bold: Boolean,
    val italic: Boolean,
    val underline: Boolean,
    val strike: Boolean,
)

/** Emacs font-lock runs pinned to the exact [text] they were computed over. */
internal class FontifySet(val text: String, val runs: List<FontifyRun>)

/** One diagnostic to render: UTF-16 offsets into the editor text. */
internal data class DiagRange(
    val start: Int,
    val end: Int,
    val severity: String,
    val message: String,
)

/** Flymake diagnostics pinned to the exact [text] they were computed over. */
internal class DiagSet(val text: String, val ranges: List<DiagRange>)

/**
 * Sequential code-point → UTF-16 offset converter. Payload offsets arrive
 * sorted, so each conversion walks forward from the previous one — a whole
 * payload converts in one O(n) pass instead of O(runs × n) rescans from the
 * string head. An out-of-order target restarts from the beginning.
 * Targets must already be clamped to the text's code-point count.
 */
internal class CodePointIndex(private val text: String) {
    private var cp = 0
    private var utf16 = 0
    fun toUtf16(targetCp: Int): Int {
        if (targetCp < cp) {
            cp = 0
            utf16 = 0
        }
        utf16 = text.offsetByCodePoints(utf16, targetCp - cp)
        cp = targetCp
        return utf16
    }
}

/**
 * Parse a `fontify.show` payload against the CURRENT editor text, or null.
 * Gated like the old render path: the payload must belong to this editor's
 * session AND the engine must confirm [text] is exactly what its seq was
 * computed over. Parsing happens once per push (off the main thread), not
 * once per keystroke; the result stays valid for as long as the editor text
 * content-matches [FontifySet.text].
 */
internal fun parseFontify(
    payload: JSONObject?,
    editorId: String,
    engine: EditorSyncEngine,
    text: String,
): FontifySet? {
    val p = payload ?: return null
    if (p.optString("id") != editorId) return null
    if (!engine.isCurrent(text, p.optInt("session"), p.optInt("seq"))) return null
    val arr = p.optJSONArray("runs") ?: return null
    val cpTotal = text.codePointCount(0, text.length)
    val idx = CodePointIndex(text)
    val runs = buildList {
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            val begCp = r.optInt("b").coerceIn(0, cpTotal)
            val endCp = r.optInt("e").coerceIn(begCp, cpTotal)
            val beg = idx.toUtf16(begCp)
            val end = idx.toUtf16(endCp)
            if (end <= beg) continue
            val color = r.optString("c").takeIf { it.isNotEmpty() }?.let { hex ->
                runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrNull()
            }
            val bg = r.optString("bg").takeIf { it.isNotEmpty() }?.let { hex ->
                runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrNull()
            }
            add(FontifyRun(
                start = beg, end = end, color = color, bg = bg,
                bold = r.optBoolean("bold"),
                italic = r.optBoolean("italic"),
                underline = r.optBoolean("underline"),
                strike = r.optBoolean("strike"),
            ))
        }
    }
    return FontifySet(text, runs)
}

/** Parse a `diagnostics.show` payload against the CURRENT editor text, or
 *  null. Same gating and lifetime as [parseFontify]. */
internal fun parseDiagnostics(
    payload: JSONObject?,
    editorId: String,
    engine: EditorSyncEngine,
    text: String,
): DiagSet? {
    val p = payload ?: return null
    if (p.optString("id") != editorId) return null
    if (!engine.isCurrent(text, p.optInt("session"), p.optInt("seq"))) return null
    val arr = p.optJSONArray("diags") ?: return null
    val cpTotal = text.codePointCount(0, text.length)
    val idx = CodePointIndex(text)
    val ranges = buildList {
        for (i in 0 until arr.length()) {
            val d = arr.optJSONObject(i) ?: continue
            val begCp = d.optInt("beg").coerceIn(0, cpTotal)
            val endCp = d.optInt("end").coerceIn(begCp, cpTotal)
            var beg = idx.toUtf16(begCp)
            var end = idx.toUtf16(endCp)
            // Zero-width diagnostics still deserve a visible mark.
            if (end == beg) {
                if (end < text.length) end++ else if (beg > 0) beg--
            }
            if (end > beg) {
                add(DiagRange(beg, end,
                    d.optString("type", "warning"), d.optString("text")))
            }
        }
    }
    return DiagSet(text, ranges)
}

/**
 * Editor text more than this many changed chars away from the last Emacs
 * fontify push falls back to the client tokenizer instead of run shifting.
 * Keystrokes, IME batches, and toolbar inserts sit far below this; a big
 * paste is where approximate re-tokenizing beats a large unstyled hole.
 */
internal const val FONTIFY_SHIFT_MAX_EDIT = 256

/**
 * [runs] shifted across one local edit, so Emacs colors survive the gap
 * between a keystroke and the next fontify push instead of flapping to the
 * client-side palette. Runs before the splice keep their offsets, runs
 * after it slide by the length delta, and a run the edit lands inside
 * stretches over the typed text — characters typed mid-comment stay
 * comment-colored. Runs the deletion swallowed drop out; a run clipped at
 * one end keeps its survivor. Purely cosmetic and possibly wrong (typing
 * `"` won't restyle the rest of the line) — exactly as wrong as the
 * tokenizer it replaces, but stable, and Emacs's reply corrects both.
 */
internal fun shiftRuns(runs: List<FontifyRun>, s: Splice): List<FontifyRun> {
    val delta = s.inserted.length - s.deleted
    val delEnd = s.start + s.deleted
    return buildList {
        for (r in runs) {
            val b = when {
                r.start < s.start -> r.start
                r.start >= delEnd -> r.start + delta
                else -> s.start + s.inserted.length
            }
            val e = when {
                r.end <= s.start -> r.end
                r.end >= delEnd -> r.end + delta
                else -> s.start
            }
            if (e > b) add(if (b == r.start && e == r.end) r else r.copy(start = b, end = e))
        }
    }
}

/**
 * The editor's whole styling pipeline as one [OutputTransformation], which
 * the text field applies once per text change — not per frame per layout
 * pass like the legacy VisualTransformation chain.
 *
 * Emacs's own font-lock runs (the user's real theme, every mode Emacs can
 * highlight) apply whenever the buffer content-matches the text they were
 * computed over — and, splice-shifted via [shiftRuns], whenever it's within
 * one small local edit of it, which keeps the palette stable while a
 * keystroke is in flight. The client-side tokenizer covers the rest: first
 * paint, big pastes, and files Emacs skipped. Content matching (not seq
 * matching) means undoing back to synced text restores exact Emacs colors
 * instantly. Diagnostics draw on top under a strict content gate: underline
 * + translucent severity tint standing in for the desktop's wavy squiggle,
 * hidden rather than mis-drawn while text is in flight.
 */
internal class EditorStyles(
    private val fontify: FontifySet?,
    private val diags: DiagSet?,
    private val language: String,
    private val colors: SyntaxColors,
    private val diagColors: Map<String, Color>,
) : OutputTransformation {
    override fun TextFieldBuffer.transformOutput() {
        val text = asCharSequence()
        val n = length
        val runs = fontify?.let { f ->
            val sp = splice(f.text, text)
            when {
                sp == null -> f.runs
                sp.deleted + sp.inserted.length <= FONTIFY_SHIFT_MAX_EDIT ->
                    shiftRuns(f.runs, sp)
                else -> null
            }
        }
        if (runs != null) {
            for (r in runs) {
                val s = r.start.coerceIn(0, n)
                val e = r.end.coerceIn(s, n)
                if (e > s) addStyle(runStyle(r), s, e)
            }
        } else if (language.isNotEmpty()) {
            for (span in highlightSpans(language, text.toString(), colors)) {
                val s = span.start.coerceIn(0, n)
                val e = span.end.coerceIn(s, n)
                if (e > s) addStyle(span.item, s, e)
            }
        }
        if (diags != null && text.contentEquals(diags.text)) {
            for (d in diags.ranges) {
                val s = d.start.coerceIn(0, n)
                val e = d.end.coerceIn(s, n)
                if (e > s) {
                    val c = diagColors[d.severity] ?: diagColors["warning"] ?: Color.Red
                    addStyle(
                        SpanStyle(
                            textDecoration = TextDecoration.Underline,
                            background = c.copy(alpha = 0.15f),
                        ),
                        s, e,
                    )
                }
            }
        }
    }

    private fun runStyle(r: FontifyRun) = SpanStyle(
        color = r.color ?: Color.Unspecified,
        background = r.bg ?: Color.Unspecified,
        fontWeight = if (r.bold) FontWeight.Bold else null,
        fontStyle = if (r.italic) FontStyle.Italic else null,
        textDecoration = when {
            r.underline && r.strike -> TextDecoration.combine(
                listOf(TextDecoration.Underline, TextDecoration.LineThrough))
            r.underline -> TextDecoration.Underline
            r.strike -> TextDecoration.LineThrough
            else -> null
        },
    )
}

/**
 * Send one editor action as an event.action frame straight down the live
 * socket. Deliberately NOT routed through [ActionReceiver]: editor sync and
 * completion are ephemeral and latency-bound, so they must never enter the
 * offline Room queue, never wake Emacs, and never cost a broadcast. No
 * handshaked connection → no frame, false returned. Call from a background
 * dispatcher (blocking socket write).
 */
internal fun sendEditAction(action: String, args: JSONObject): Boolean {
    val conn = JetpacsRuntime.server?.connection() ?: return false
    if (!conn.helloComplete) return false
    val payload = JSONObject().apply {
        put("surface", "editor")
        put("revision_seen", -1)
        put("action", action)
        put("args", args)
        put("fields", JSONObject.NULL)
        put("queued_at", JSONObject.NULL)
    }
    return conn.notify(Method.EVENT_ACTION, payload)
}
