package com.calebc42.jetpacs

/**
 * The bounded, conflating queue between the socket reader and the
 * dispatcher — the receiver half of SPEC-2 §5's overload rules.
 *
 * Latest-wins traffic (surface snapshots, theme, annotations) is offered
 * with a conflation key: a queued-but-unprocessed message with the same
 * key is discarded — never validated, persisted, or rendered — because a
 * newer frame made it officially worthless (revision guard / seq / LWW).
 * Obsolescence as backpressure. Everything else queues FIFO; ordered and
 * event traffic is never conflated.
 *
 * A conflating replacement enters at the TAIL: for latest-wins traffic
 * the newest frame is the truth wherever it lands, and tail placement
 * keeps it ordered after a `surface.remove` that arrived in between.
 *
 * The queue is bounded (§5 rule 4 — no conforming implementation buffers
 * unboundedly): [offer] reports exhaustion so the connection can refuse
 * with `1401 overloaded` and fail closed at the connection level instead
 * of failing open at the process level. Conflation keeps latest-wins
 * traffic at one slot per key, so only a peer flooding the un-droppable
 * classes can exhaust the bound.
 */
class InboundPipeline(private val capacity: Int = DEFAULT_CAPACITY) {

    private class Entry(val msg: RpcIn, val key: String?) {
        var dropped = false
    }

    private val lock = Object()
    private val queue = ArrayDeque<Entry>()
    private val byKey = HashMap<String, Entry>()
    private var live = 0
    private var closed = false

    /** Frames superseded in-queue and never processed. */
    var conflated = 0L
        private set

    /**
     * Enqueue a message, conflating on KEY when given. Returns false when
     * the bound is exhausted — the caller refuses `1401` and closes.
     */
    fun offer(msg: RpcIn, key: String? = null): Boolean {
        synchronized(lock) {
            if (closed) return true
            if (key != null) byKey.remove(key)?.let {
                it.dropped = true
                live--
                conflated++
            }
            val entry = Entry(msg, key)
            queue.addLast(entry)
            if (key != null) byKey[key] = entry
            live++
            lock.notifyAll()
            return live <= capacity
        }
    }

    /** Blocks for the next live message; null once closed and drained. */
    fun take(): RpcIn? {
        synchronized(lock) {
            while (true) {
                val entry = queue.removeFirstOrNull()
                if (entry == null) {
                    if (closed) return null
                    lock.wait()
                    continue
                }
                if (entry.dropped) continue
                live--
                if (entry.key != null && byKey[entry.key] === entry) byKey.remove(entry.key)
                return entry.msg
            }
        }
    }

    /** Stop accepting and wake the dispatcher; queued messages still drain. */
    fun close() {
        synchronized(lock) {
            closed = true
            lock.notifyAll()
        }
    }

    companion object {
        const val DEFAULT_CAPACITY = 256
    }
}
