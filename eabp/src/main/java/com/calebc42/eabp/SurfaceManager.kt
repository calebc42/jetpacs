package com.calebc42.eabp

import android.content.Context
import android.util.Log
import org.json.JSONObject
import kotlinx.coroutines.flow.StateFlow

/**
 * Orchestrates the surface cache: validates and persists `surface.update`s,
 * applies `surface.remove`s, and renders by surface type. Crucially it can
 * render straight from cache (e.g. at service start), so surfaces appear whether
 * or not Emacs is connected — design principle #1.
 */
class SurfaceManager(private val context: Context) {
    private val store = SurfaceStore(context)
    private val notifications = NotificationRenderer(context)

    val version: StateFlow<Int> get() = store.version

    /**
     * Apply a `surface.update` payload. Returns null on success (including a
     * benign stale-revision no-op), or an error detail string for an `error`
     * reply.
     */
    fun update(payload: JSONObject): String? {
        val surface = payload.optString("surface")
        if (surface.isEmpty()) return "missing surface id"
        if (':' !in surface) return "surface id must be '<type>:<name>'"

        val record = SurfaceRecord(
            surface = surface,
            revision = payload.optInt("revision"),
            spec = payload.optJSONObject("spec") ?: JSONObject(),
            ttlS = if (payload.isNull("ttl_s")) null else payload.optInt("ttl_s"),
            staleSpec = if (payload.isNull("stale_spec")) null
            else payload.optJSONObject("stale_spec"),
        )

        val applied = store.apply(record)

        // Emacs may force a view change with the update (e.g. opening a
        // heading detail). Applied regardless of revision acceptance so a
        // pure navigation hint still works.
        payload.optString("current_view").takeIf { it.isNotEmpty() }?.let {
            store.setCurrentView(surface, it)
        }

        if (applied == null) {
            Log.d(TAG, "Ignored non-newer revision ${record.revision} for $surface")
            return null
        }
        render(applied)
        return null
    }

    fun remove(surface: String) {
        store.remove(surface)?.let { clear(it) }
    }

    /** Safely expose a cached record to the UI without exposing the entire store */
    fun getRecord(surface: String): SurfaceRecord? {
        return store.get(surface)
    }

    fun currentView(surface: String): String? = store.currentView(surface)

    /** Local navigation: the `view.switch` builtin lands here. */
    fun setCurrentView(surface: String, view: String) {
        store.setCurrentView(surface, view)
    }

    /** Re-render every cached surface — the "render regardless of Emacs" path. */
    fun renderAllCached() {
        store.all().forEach { render(it) }
    }

    /**
     * `{surface: revision}` for every cached surface. Sent in `session.welcome`
     * so a fresh Emacs (lost revision file, new machine) can resume its
     * monotonic counter from reality instead of being silently rejected.
     */
    fun revisionSnapshot(): JSONObject = JSONObject().apply {
        store.all().forEach { put(it.surface, it.revision) }
    }

    private fun render(record: SurfaceRecord) {
        when (record.type) {
            "notification" -> notifications.render(record)
            "app", "dialog" -> { /* Polled/Observed by MainActivity */ }
            "widget" -> renderWidgetSurface(context, record)
            // Tiles pull from cache when the system binds them; this just
            // pokes the system to rebind (ACTIVE_TILE contract).
            "tile" -> EabpTileSlots.requestUpdate(context, record.surface)
            else -> Log.w(TAG, "No renderer for surface type '${record.type}'")
        }
    }

    private fun clear(record: SurfaceRecord) {
        when (record.type) {
            "notification" -> notifications.clear(record.surface)
            // Rebind → getRecord returns null → the slot parks as grayed.
            "tile" -> EabpTileSlots.requestUpdate(context, record.surface)
            else -> {}
        }
    }

    companion object { private const val TAG = "SurfaceManager" }
}