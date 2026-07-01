package com.calebc42.eabp

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * INTERIM offline stash for action events that couldn't be delivered live.
 *
 * Append-only NDJSON: no dedupe, no TTL, just append order. The queue phase
 * replaces this wholesale with a Room-backed FIFO queue carrying dedupe keys
 * and the formal queue.replay protocol. Kept deliberately tiny so it's painless
 * to delete later — its only job today is "don't silently lose a tap."
 */
object PendingActionStash {
    private const val FILE = "pending-actions.ndjson"

    @Synchronized
    fun append(context: Context, event: JSONObject) {
        File(context.filesDir, FILE).appendText(event.toString() + "\n")
    }

    @Synchronized
    fun count(context: Context): Int {
        val f = File(context.filesDir, FILE)
        if (!f.exists()) return 0
        return f.readLines().count { it.isNotBlank() }
    }

    @Synchronized
    fun drainAll(context: Context): List<JSONObject> {
        val f = File(context.filesDir, FILE)
        if (!f.exists()) return emptyList()
        val out = f.readLines().filter { it.isNotBlank() }.map { JSONObject(it) }
        f.delete()
        return out
    }
}