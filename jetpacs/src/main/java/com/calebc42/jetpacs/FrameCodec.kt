package com.calebc42.jetpacs

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** Default frame cap in body bytes (SPEC-2 §2.2). */
const val JETPACS_MAX_FRAME_BYTES = 4 * 1024 * 1024

/**
 * Thrown by [FrameCodec.write] for a body over the cap — the sender-side
 * half of SPEC-2 §2.2: refuse the frame locally, keep the connection.
 */
class FrameTooLargeException(val bytes: Int, val max: Int) :
    IOException("frame body $bytes bytes exceeds the $max-byte cap")

/**
 * Reads and writes JSON-RPC messages over a byte stream.
 *
 * Keeping this an interface is the whole point of the layer stack: the
 * envelope, handshake, connection, and surface code all talk to
 * [FrameCodec], so swapping the loopback socket for a Unix domain socket
 * — or the framing itself — is a one-class change with no ripple.
 */
interface FrameCodec {
    /** Blocks until a full message arrives; returns null on clean EOF. */
    fun read(): RpcIn?
    fun write(message: JSONObject)
    fun close()
}

/**
 * EBP 2 framing: `Content-Length: <bytes>\r\n\r\n<body>`, byte-accurate
 * UTF-8 (SPEC-2 §2.2). All reads are byte-level — a Reader would decode
 * ahead of the header's byte count and lose the body boundary. Unknown
 * header lines are tolerated and ignored; a header section without
 * Content-Length, or one that never ends, is a framing desync and kills
 * the read loop (fail closed — there is no way to find the next frame).
 *
 * The frame cap, receiver side: an oversized body is skipped byte-exactly
 * — never buffered, never parsed — and surfaced as [RpcOversize] so the
 * connection can refuse it with `1400 frame-too-large` and live on. This
 * cheap refusal is a dividend of length-prefixed framing: newline framing
 * could not skip without scanning every byte.
 */
class ContentLengthFrameCodec(
    input: InputStream,
    output: OutputStream,
    private val maxFrameBytes: Int = JETPACS_MAX_FRAME_BYTES,
) : FrameCodec {

    private val inp = BufferedInputStream(input)
    private val out = BufferedOutputStream(output)

    override fun read(): RpcIn? {
        val length = readHeaders() ?: return null
        if (length > maxFrameBytes) {
            skipExactly(length)
            return RpcOversize(length, maxFrameBytes)
        }
        val body = ByteArray(length.toInt())
        var off = 0
        while (off < body.size) {
            val n = inp.read(body, off, body.size - off)
            if (n < 0) return null // EOF mid-body: the peer died; treat as closed
            off += n
        }
        return Rpc.parse(String(body, Charsets.UTF_8))
    }

    /** Parses one header section; the Content-Length, or null on EOF between frames. */
    private fun readHeaders(): Long? {
        var contentLength: Long? = null
        var first = true
        while (true) {
            val line = readHeaderLine(atFrameBoundary = first) ?: return null
            first = false
            if (line.isEmpty()) {
                return contentLength
                    ?: throw IOException("frame header without Content-Length")
            }
            HEADER_RE.matchEntire(line)?.let { contentLength = it.groupValues[1].toLong() }
            // Anything else: an unknown header line, tolerated and ignored.
        }
    }

    /**
     * One LF-terminated header line as ASCII, CR stripped. Null on EOF
     * only when [atFrameBoundary] and no byte was consumed — a clean
     * close between frames; EOF anywhere else is a truncated frame.
     */
    private fun readHeaderLine(atFrameBoundary: Boolean): String? {
        val sb = StringBuilder()
        while (true) {
            val b = inp.read()
            if (b < 0) {
                if (atFrameBoundary && sb.isEmpty()) return null
                throw IOException("EOF inside frame header")
            }
            if (b == '\n'.code) {
                if (sb.isNotEmpty() && sb.last() == '\r') sb.setLength(sb.length - 1)
                return sb.toString()
            }
            sb.append(b.toInt().toChar())
            if (sb.length > MAX_HEADER_BYTES) throw IOException("unbounded frame header")
        }
    }

    /** Discards exactly N body bytes — the oversize skip. */
    private fun skipExactly(n: Long) {
        var remaining = n
        while (remaining > 0) {
            val skipped = inp.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
                continue
            }
            if (inp.read() < 0) throw IOException("EOF while skipping oversized frame")
            remaining--
        }
    }

    @Synchronized
    override fun write(message: JSONObject) {
        val body = message.toString().toByteArray(Charsets.UTF_8)
        if (body.size > maxFrameBytes) throw FrameTooLargeException(body.size, maxFrameBytes)
        out.write("Content-Length: ${body.size}\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
        out.write(body)
        out.flush()
    }

    override fun close() {
        runCatching { inp.close() }
        runCatching { out.close() }
    }

    companion object {
        /** Sanity bound on the header section — headers are one short line. */
        private const val MAX_HEADER_BYTES = 8 * 1024

        /** Length capped at 12 digits so a hostile header can't overflow Long. */
        private val HEADER_RE = Regex("""(?i)content-length:\s*(\d{1,12})\s*""")
    }
}
