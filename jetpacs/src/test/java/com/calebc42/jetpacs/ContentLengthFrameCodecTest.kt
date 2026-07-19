package com.calebc42.jetpacs

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/**
 * The framing layer's own guarantees (SPEC-2 §2.2): byte-accurate
 * Content-Length bodies, tolerated unknown headers, and both halves of
 * the frame cap — the receiver-side byte-exact skip and the sender-side
 * local refusal.
 */
class ContentLengthFrameCodecTest {

    private fun framed(json: String): ByteArray {
        val body = json.toByteArray(Charsets.UTF_8)
        return "Content-Length: ${body.size}\r\n\r\n".toByteArray(Charsets.ISO_8859_1) + body
    }

    private fun reader(bytes: ByteArray, max: Int = JETPACS_MAX_FRAME_BYTES) =
        ContentLengthFrameCodec(ByteArrayInputStream(bytes), ByteArrayOutputStream(), max)

    @Test
    fun bodyLengthIsBytesNotChars() {
        // Multibyte content: the length is UTF-8 bytes, not chars — an
        // org snippet's dashes and CJK must not shift the frame boundary
        // for the frame BEHIND it.
        val out = ByteArrayOutputStream()
        val writer = ContentLengthFrameCodec(ByteArrayInputStream(ByteArray(0)), out)
        writer.write(Rpc.notification(
            Method.TOAST_SHOW, JSONObject().put("text", "ναι — 進捗 ✓")))
        writer.write(Rpc.notification(Method.TOAST_SHOW, JSONObject().put("text", "b")))
        val codec = reader(out.toByteArray())
        val first = codec.read()
        assertTrue(first is RpcNotification)
        assertEquals("ναι — 進捗 ✓", (first as RpcNotification).params.getString("text"))
        val second = codec.read()
        assertTrue(second is RpcNotification)
        assertEquals("b", (second as RpcNotification).params.getString("text"))
        assertEquals(null, codec.read())
    }

    @Test
    fun unknownHeaderLinesAreIgnored() {
        val body = """{"jsonrpc":"2.0","method":"event.action","params":{}}"""
        val bytes = ("Content-Type: application/json\r\n" +
            "Content-Length: ${body.length}\r\n" +
            "X-Flisbo: 7\r\n\r\n" + body).toByteArray(Charsets.ISO_8859_1)
        val msg = reader(bytes).read()
        assertTrue(msg is RpcNotification)
        assertEquals(Method.EVENT_ACTION, (msg as RpcNotification).method)
    }

    @Test
    fun oversizedInboundBodyIsSkippedByteExactly() {
        // A 100-byte body against a 64-byte cap, then a normal frame: the
        // oversize surfaces as RpcOversize and the NEXT frame still parses
        // — the connection outlives the refusal.
        val big = "x".repeat(100)
        val next = """{"jsonrpc":"2.0","method":"event.action","params":{}}"""
        val bytes = ("Content-Length: 100\r\n\r\n$big").toByteArray(Charsets.ISO_8859_1) +
            framed(next)
        val codec = reader(bytes, max = 64)
        val first = codec.read()
        assertTrue("expected RpcOversize, got $first", first is RpcOversize)
        assertEquals(100L, (first as RpcOversize).bytes)
        assertEquals(64, first.max)
        val second = codec.read()
        assertTrue(second is RpcNotification)
        assertEquals(null, codec.read())
    }

    @Test
    fun oversizedOutboundFrameIsRefusedLocally() {
        val out = ByteArrayOutputStream()
        val codec = ContentLengthFrameCodec(ByteArrayInputStream(ByteArray(0)), out, 64)
        try {
            codec.write(Rpc.notification(
                Method.SURFACE_UPDATE, JSONObject().put("blob", "y".repeat(200))))
            fail("expected FrameTooLargeException")
        } catch (e: FrameTooLargeException) {
            assertTrue(e.bytes > 64)
        }
        // Nothing partial reached the stream, and it still works after.
        assertEquals(0, out.size())
        codec.write(Rpc.notification(Method.TOAST_SHOW, JSONObject().put("text", "ok")))
        assertTrue(out.size() > 0)
    }

    @Test
    fun cleanEofBetweenFramesIsNull() {
        val codec = reader(framed("""{"jsonrpc":"2.0","method":"rpc.cancel","params":{"id":1}}"""))
        assertTrue(codec.read() is RpcNotification)
        assertEquals(null, codec.read())
    }

    @Test
    fun garbageHeaderFailsClosed() {
        // A header section with no Content-Length is a framing desync:
        // there is no way to find the next frame, so the read loop dies
        // rather than guessing (fail closed).
        val codec = reader("Flisbo: 9\r\n\r\n{}".toByteArray(Charsets.ISO_8859_1))
        try {
            codec.read()
            fail("expected IOException")
        } catch (expected: java.io.IOException) {
            // pass
        }
    }
}
