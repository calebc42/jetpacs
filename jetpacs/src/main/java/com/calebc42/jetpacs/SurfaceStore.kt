package com.calebc42.jetpacs

import android.content.Context
import org.json.JSONObject
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** One cached surface: the latest spec the companion holds for a surface id. */
data class SurfaceRecord(
    val surface: String,            // "<type>:<name>"
    val revision: Int,
    val spec: JSONObject,
    val ttlS: Int? = null,
    val staleSpec: JSONObject? = null,
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val type: String get() = surface.substringBefore(':', "")
    val name: String get() = surface.substringAfter(':', surface)

    /** True once ttl_s has elapsed since the last update. */
    fun isStale(now: Long = System.currentTimeMillis()): Boolean {
        val ttl = ttlS ?: return false
        return now - updatedAt > ttl * 1000L
    }

    /**
     * Resolve the effective spec for rendering.
     *
     * A spec may define named sub-views:
     *   { "views": { "agenda": {..}, "tasks": {..} }, "initial_view": "agenda" }
     * in which case the view selected by [currentView] (falling back to
     * initial_view, then any view) is returned. A bare single-tree spec is
     * shorthand for one anonymous view and is returned as-is.
     */
    fun resolveSpec(currentView: String?): JSONObject {
        val views = spec.optJSONObject("views") ?: return spec
        val pick = currentView?.takeIf { views.has(it) }
            ?: spec.optString("initial_view").takeIf { it.isNotEmpty() && views.has(it) }
            ?: views.keys().asSequence().firstOrNull()
            ?: return spec
        return views.optJSONObject(pick) ?: spec
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("surface", surface)
        put("revision", revision)
        put("spec", spec)
        put("ttl_s", ttlS ?: JSONObject.NULL)
        put("stale_spec", staleSpec ?: JSONObject.NULL)
        put("updated_at", updatedAt)
    }

    companion object {
        fun fromJson(o: JSONObject) = SurfaceRecord(
            surface = o.getString("surface"),
            revision = o.optInt("revision"),
            spec = o.optJSONObject("spec") ?: JSONObject(),
            ttlS = if (o.isNull("ttl_s")) null else o.optInt("ttl_s"),
            staleSpec = if (o.isNull("stale_spec")) null else o.optJSONObject("stale_spec"),
            updatedAt = o.optLong("updated_at", System.currentTimeMillis()),
        )
    }
}

/**
 * Persistent latest-spec-per-surface cache, plus the current sub-view per
 * surface (so reopening the app lands on the tab you left).
 *
 * File-backed JSON (atomic write). File layout v2:
 *   { "records": { "<surface>": {..} }, "current_views": { "<surface>": "tasks" } }
 * A v1 file (flat surface->record map) is migrated transparently on load.
 */
class SurfaceStore(context: Context) {
    private val file = File(context.filesDir, "surfaces.json")
    private val cache = linkedMapOf<String, SurfaceRecord>()
    private val currentViews = mutableMapOf<String, String>()

    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version

    init { load() }

    @Synchronized
    private fun load() {
        if (!file.exists()) return
        runCatching {
            val root = JSONObject(file.readText())
            val records = root.optJSONObject("records")
            if (records != null) {
                records.keys().forEach { k ->
                    cache[k] = SurfaceRecord.fromJson(records.getJSONObject(k))
                }
                root.optJSONObject("current_views")?.let { cv ->
                    cv.keys().forEach { k -> currentViews[k] = cv.getString(k) }
                }
            } else {
                // v1 layout: the root itself was the record map.
                root.keys().forEach { k ->
                    cache[k] = SurfaceRecord.fromJson(root.getJSONObject(k))
                }
            }
        }
    }

    @Synchronized
    private fun persist() {
        val records = JSONObject()
        cache.forEach { (k, v) -> records.put(k, v.toJson()) }
        val cv = JSONObject()
        currentViews.forEach { (k, v) -> cv.put(k, v) }
        val root = JSONObject().apply {
            put("records", records)
            put("current_views", cv)
        }
        val tmp = File(file.parentFile, "surfaces.json.tmp")
        tmp.writeText(root.toString())
        tmp.renameTo(file)
        _version.value += 1
    }

    /**
     * Apply an incoming update. Returns the stored record, or null if the
     * update was rejected because its revision is not newer than what we hold
     * (a benign out-of-order delivery after a reconnect).
     */
    @Synchronized
    fun apply(record: SurfaceRecord): SurfaceRecord? {
        val existing = cache[record.surface]
        if (existing != null && record.revision <= existing.revision) return null
        cache[record.surface] = record
        persist()
        return record
    }

    @Synchronized fun get(surface: String): SurfaceRecord? {
        val record = cache[surface] ?: return null
        if (record.isStale() && record.staleSpec != null) {
            return record.copy(spec = record.staleSpec)
        }
        return record
    }

    @Synchronized fun remove(surface: String): SurfaceRecord? {
        val r = cache.remove(surface)
        if (r != null) {
            currentViews.remove(surface)
            persist()
        }
        return r
    }

    @Synchronized fun all(): List<SurfaceRecord> = cache.values.toList()

    @Synchronized fun currentView(surface: String): String? = currentViews[surface]

    /** Set the active sub-view for SURFACE. No-op if unchanged. */
    @Synchronized
    fun setCurrentView(surface: String, view: String) {
        if (currentViews[surface] == view) return
        currentViews[surface] = view
        persist()
    }
}