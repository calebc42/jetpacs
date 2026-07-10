package com.calebc42.jetpacs

import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.OutputStreamWriter

/**
 * Reads and writes Jetpacs frames over a byte stream.
 *
 * Keeping this an interface is the whole point of the v0/1.0 split: the
 * envelope, handshake, connection, and (later) surface code all talk to
 * [FrameCodec], so swapping NDJSON for the spec's 4-byte length-prefix framing
 * — or swapping the loopback socket for a Unix domain socket — is a one-class
 * change with no ripple.
 */
interface FrameCodec {
    /** Blocks until a full frame arrives; returns null on clean EOF. */
    fun read(): Frame?
    fun write(frame: Frame)
    fun close()
}

/**
 * v0 framing: newline-delimited JSON.
 *
 * Safe because both ends compact-encode: a literal newline never survives
 * inside a JSON document (it is escaped as \n within strings), so splitting on
 * '\n' cleanly separates frames.
 */
class NdjsonFrameCodec(
    input: InputStream,
    output: OutputStream,
) : FrameCodec {

    private val reader: BufferedReader =
        BufferedReader(InputStreamReader(input, Charsets.UTF_8))
    private val writer: BufferedWriter =
        BufferedWriter(OutputStreamWriter(output, Charsets.UTF_8))

    override fun read(): Frame? {
        while (true) {
            val line = reader.readLine() ?: return null
            if (line.isBlank()) continue          // tolerate keep-alive blanks
            return Frame.fromJson(JSONObject(line))
        }
    }

    @Synchronized
    override fun write(frame: Frame) {
        writer.write(frame.toString())
        writer.write("\n")
        writer.flush()
    }

    override fun close() {
        runCatching { reader.close() }
        runCatching { writer.close() }
    }
}