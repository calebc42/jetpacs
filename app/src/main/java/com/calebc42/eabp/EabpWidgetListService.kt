package com.calebc42.eabp

import android.content.Context
import android.content.Intent
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.text.style.StrikethroughSpan
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONObject

/**
 * The one adapter behind every scrollable widget list (the agenda widget
 * and the blank `widget:customN` slots — the surface rides in the adapter
 * intent's data URI). A dumb renderer: rows arrive as the generic schema
 * built by `eabp-widget-item' / `eabp-widget-divider' Emacs-side, actions
 * included, so nothing app-specific lives here.
 *
 * Row schema: text, todo (colored prefix while open), done (strike),
 * meta + icon (scheduled|deadline|event|folder), on_tap (+ tap_in_app to
 * route through the opened app), button (todo_open|todo_done|add) firing
 * on_button silently, or {divider: label} for a bold section header.
 */
class EabpWidgetListService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        WidgetListFactory(
            applicationContext,
            intent.data?.schemeSpecificPart ?: EabpWidgetProvider.SURFACE)
}

private class WidgetListFactory(
    private val context: Context,
    private val surface: String
) : RemoteViewsService.RemoteViewsFactory {

    private var items: List<JSONObject> = emptyList()
    private var revision = -1

    override fun onCreate() = onDataSetChanged()

    override fun onDataSetChanged() {
        val record = widgetManager(context).getRecord(surface)
        revision = record?.revision ?: -1
        val arr = widgetResolvedSpec(context, surface, record)?.optJSONArray("items")
        items = if (arr == null) emptyList()
        else (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
    }

    override fun getViewAt(position: Int): RemoteViews {
        val item = items.getOrNull(position)
            ?: return RemoteViews(context.packageName, R.layout.widget_eabp_agenda_divider)
        return if (item.has("divider")) {
            RemoteViews(context.packageName, R.layout.widget_eabp_agenda_divider).apply {
                setTextViewText(R.id.item_divider_text, item.optString("divider"))
                // No fill-in: the template fires without an action and the
                // trampoline no-ops.
            }
        } else {
            rowView(item)
        }
    }

    private fun rowView(item: JSONObject): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_eabp_agenda_item)
        views.setTextViewText(R.id.item_text, formatTitle(item))

        val meta = item.optString("meta")
        if (meta.isNotEmpty()) {
            views.setTextViewText(R.id.item_meta_text, meta)
            val icon = metaIcon(item.optString("icon"))
            if (icon != null) {
                views.setImageViewResource(R.id.item_meta_icon, icon)
                views.setViewVisibility(R.id.item_meta_icon, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.item_meta_icon, View.GONE)
            }
            views.setViewVisibility(R.id.item_meta, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.item_meta, View.GONE)
        }

        item.optJSONObject("on_tap")?.let { action ->
            views.setOnClickFillInIntent(
                R.id.item_root,
                trampolineFillIn(
                    if (item.optBoolean("tap_in_app"))
                        ActionTrampolineActivity.TYPE_OPEN_APP
                    else ActionTrampolineActivity.TYPE_BROADCAST,
                    action))
        }

        val button = buttonIcon(item.optString("button"))
        if (button != null) {
            views.setViewVisibility(R.id.item_toggle, View.VISIBLE)
            views.setImageViewResource(R.id.item_toggle, button)
            item.optJSONObject("on_button")?.let { action ->
                views.setOnClickFillInIntent(
                    R.id.item_toggle,
                    trampolineFillIn(ActionTrampolineActivity.TYPE_BROADCAST, action))
            }
        } else {
            views.setViewVisibility(R.id.item_toggle, View.GONE)
        }
        return views
    }

    private fun metaIcon(name: String): Int? = when (name) {
        "scheduled" -> R.drawable.ic_meta_scheduled
        "deadline" -> R.drawable.ic_meta_deadline
        "event" -> R.drawable.ic_meta_event
        "folder" -> R.drawable.ic_meta_folder
        else -> null
    }

    private fun buttonIcon(name: String): Int? = when (name) {
        "todo_open" -> R.drawable.ic_todo_open
        "todo_done" -> R.drawable.ic_todo_done
        "add" -> R.drawable.ic_widget_add
        else -> null
    }

    /**
     * Title line: open items get their TODO keyword as a colored prefix
     * (Orgzly-style); done items get a plain struck-through title.
     */
    private fun formatTitle(item: JSONObject): CharSequence {
        val sb = SpannableStringBuilder()
        val todo = item.optString("todo")
        val done = item.optBoolean("done")
        if (todo.isNotEmpty() && !done) {
            sb.append(todo)
            sb.setSpan(
                ForegroundColorSpan(context.getColor(R.color.widget_todo)),
                0, sb.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            sb.append(' ')
        }
        val start = sb.length
        sb.append(item.optString("text").ifEmpty { "Untitled" })
        if (done) {
            sb.setSpan(
                StrikethroughSpan(), start, sb.length,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return sb
    }

    private fun trampolineFillIn(type: String, action: JSONObject): Intent =
        Intent().apply {
            putExtra(ActionTrampolineActivity.EXTRA_TYPE, type)
            putExtra(ActionTrampolineActivity.EXTRA_ACTION, action.toString())
            putExtra(ActionTrampolineActivity.EXTRA_SURFACE, surface)
            putExtra(ActionTrampolineActivity.EXTRA_REVISION, revision)
        }

    override fun getCount() = items.size
    override fun getViewTypeCount() = 2
    override fun getItemId(position: Int) = position.toLong()
    override fun hasStableIds() = false
    override fun getLoadingView(): RemoteViews? = null
    override fun onDestroy() {}
}