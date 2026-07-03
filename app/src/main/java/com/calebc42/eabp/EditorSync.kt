package com.calebc42.eabp

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import org.json.JSONObject
import kotlin.random.Random

/**
 * One editor's live sync channel to Emacs (see eabp-sync.el).
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
 */
internal class EditorSyncEngine(private val file: String) {
    /** Phone-chosen session id; Emacs echoes it in resync/diagnostics frames. */
    val session: Int = Random.nextInt(1, Int.MAX_VALUE)

    /** Last delta sequence number Emacs should have applied. */
    var seq: Int = 0
        private set

    private var lastSynced: String? = null

    /** Ship the full text, resetting the session to seq 0. */
    fun open(text: String): Boolean {
        val ok = sendEditAction("edit.open", JSONObject().apply {
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
        val ok = sendEditAction("edit.delta", JSONObject().apply {
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
        return sendEditAction("edit.complete", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("seq", seq)
            put("request_id", requestId)
            put("cursor", cursorCp)
        })
    }

    /**
     * Report the caret position for eldoc. Best-effort: syncs first if the
     * text moved, sends nothing when offline, and Emacs silently ignores a
     * report that raced a delta — the next pause resends fresh state.
     */
    fun caret(text: String, cursorUtf16: Int): Boolean {
        if (lastSynced != text && !update(text)) return false
        val cursorCp = text.codePointCount(0, cursorUtf16.coerceIn(0, text.length))
        return sendEditAction("edit.caret", JSONObject().apply {
            put("file", file)
            put("session", session)
            put("seq", seq)
            put("cursor", cursorCp)
        })
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
        sendEditAction("edit.close", JSONObject().apply {
            put("file", file)
            put("session", session)
        })
        lastSynced = null
    }
}

/** One text splice: replace [start, start+deleted) (UTF-16 units) with [inserted]. */
internal data class Splice(val start: Int, val deleted: Int, val inserted: String)

/**
 * Minimal single-splice diff via common prefix/suffix. Any burst of edits
 * between two snapshots collapses to one splice. Boundaries are nudged off
 * surrogate pairs so the code-point conversion above never splits an astral
 * character. Returns null when the strings are equal.
 */
internal fun splice(old: String, new: String): Splice? {
    if (old == new) return null
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
    return Splice(start = p, deleted = so - p, inserted = new.substring(p, sn))
}

/** One fontification run from Emacs: UTF-16 offsets into the editor text. */
internal data class FontifyRun(
    val start: Int,
    val end: Int,
    val color: Color?,
    val bold: Boolean,
    val italic: Boolean,
    val underline: Boolean,
    val strike: Boolean,
)

/**
 * Renders Emacs's own font-lock runs — the user's real theme, every mode
 * Emacs can highlight — in place of the client-side approximation. Length-
 * preserving with identity mapping, so [DiagnosticsTransformation] composes
 * on top unchanged.
 */
internal class FontifyTransformation(
    private val runs: List<FontifyRun>,
) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val n = text.text.length
        val styled = buildAnnotatedString {
            append(text.text)
            for (r in runs) {
                val s = r.start.coerceIn(0, n)
                val e = r.end.coerceIn(s, n)
                if (e > s) {
                    addStyle(
                        SpanStyle(
                            color = r.color ?: Color.Unspecified,
                            fontWeight = if (r.bold) FontWeight.Bold else null,
                            fontStyle = if (r.italic) FontStyle.Italic else null,
                            textDecoration = when {
                                r.underline && r.strike -> TextDecoration.combine(
                                    listOf(TextDecoration.Underline, TextDecoration.LineThrough))
                                r.underline -> TextDecoration.Underline
                                r.strike -> TextDecoration.LineThrough
                                else -> null
                            },
                        ),
                        s, e,
                    )
                }
            }
        }
        return TransformedText(styled, OffsetMapping.Identity)
    }
}

/** One diagnostic to render: UTF-16 offsets into the editor text. */
internal data class DiagRange(
    val start: Int,
    val end: Int,
    val severity: String,
    val message: String,
)

/**
 * Overlays diagnostic underlines on top of a base transformation (the syntax
 * highlighter, or None). The base must be length-preserving with an identity
 * offset mapping — true of [SyntaxTransformation] — so diagnostic offsets in
 * original-text coordinates apply directly to the transformed string.
 * Underline + a translucent severity-tinted background stands in for the
 * desktop's wavy squiggle, which Compose spans can't draw.
 */
internal class DiagnosticsTransformation(
    private val base: VisualTransformation,
    private val ranges: List<DiagRange>,
    private val colors: Map<String, Color>,
) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val t = base.filter(text)
        val n = t.text.length
        val styled = buildAnnotatedString {
            append(t.text)
            for (r in ranges) {
                val s = r.start.coerceIn(0, n)
                val e = r.end.coerceIn(s, n)
                if (e > s) {
                    val c = colors[r.severity] ?: colors["warning"] ?: Color.Red
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
        return TransformedText(styled, t.offsetMapping)
    }
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
    val conn = EabpRuntime.server?.connection() ?: return false
    if (!conn.helloComplete) return false
    val payload = JSONObject().apply {
        put("surface", "editor")
        put("revision_seen", -1)
        put("action", action)
        put("args", args)
        put("fields", JSONObject.NULL)
        put("queued_at", JSONObject.NULL)
    }
    return conn.send(Frame(kind = "event.action", payload = payload))
}
