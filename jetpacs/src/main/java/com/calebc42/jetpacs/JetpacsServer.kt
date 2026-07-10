package com.calebc42.jetpacs

import android.content.Context
import android.util.Log
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/**
 * The companion is the durable server now — the inversion at the heart of Jetpacs.
 *
 * v0 binds a loopback TCP socket (127.0.0.1 only, so nothing off-device can
 * reach it; that loopback binding is the v0 stand-in for the spec's
 * filesystem-permission auth). The target transport is a Unix domain socket in
 * a shared-signature dir; that swaps in right here without touching
 * [JetpacsConnection], [FrameCodec], or the Elisp side.
 */
class JetpacsServer(
    private val context: Context,
    private val surfaces: SurfaceManager,
    private val port: Int = DEFAULT_PORT,
) {
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var running = false
    @Volatile private var current: JetpacsConnection? = null

    fun start() {
        if (running) return
        running = true
        thread(name = "jetpacs-accept") {
            try {
                val ss = ServerSocket(port, 1, InetAddress.getByName("127.0.0.1"))
                serverSocket = ss
                Log.i(TAG, "Jetpacs listening on 127.0.0.1:$port")
                while (running) {
                    val socket = ss.accept()
                    Log.i(TAG, "Emacs connected from ${socket.inetAddress}")
                    // Single-client model: a fresh connection supersedes the old.
                    current?.shutdown()
                    val conn = JetpacsConnection(context, socket, surfaces) { closed ->
                        if (current === closed) current = null
                        JetpacsRuntime.setConnected(false)
                        Log.i(TAG, "Emacs disconnected")
                    }
                    current = conn
                    conn.start()
                }
            } catch (e: Exception) {
                if (running) Log.e(TAG, "Accept loop failed", e)
            }
        }
    }

    fun stop() {
        running = false
        current?.shutdown()
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    /** The current live connection, if any — for pushing surfaces / actions. */
    fun connection(): JetpacsConnection? = current

    companion object {
        const val DEFAULT_PORT = 8765
        private const val TAG = "JetpacsServer"
    }
}