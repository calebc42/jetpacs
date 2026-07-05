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
 * Adapter behind the agenda widget's scrollable ListView. Reads items from
 * the cached `widget:agenda` surface record, so it works whether or not
 * Emacs is connected; renderAll's notifyAppWidgetViewDataChanged triggers
 * [AgendaRemoteViewsFactory.onDataSetChanged] after each surface update.
 *
 * Rows follow Orgzly's list-widget anatomy: a title line with the open
 * TODO keyword colored, a metadata line (type icon + the agenda's own
 * qualifier or time + file name), the todo toggle on the right, and bold
 * "Overdue"/"Today" divider rows when overdue items exist.
 */
class AgendaWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        AgendaRemoteViewsFactory(applicationContext)
}

private class AgendaRemoteViewsFactory(
    private val context: Context
) : RemoteViewsService.RemoteViewsFactory {

    private sealed class Row {
        class Divider(val label: String) : Row()
        class Note(val item: JSONObject) : Row()
    }

    private var rows: List<Row> = emptyList()
    private var revision = -1

    override fun onCreate() = onDataSetChanged()

    override fun onDataSetChanged() {
        val record = (EabpRuntime.surfaceManager ?: SurfaceManager(context))
            .getRecord(EabpWidgetProvider.SURFACE)
        revision = record?.revision ?: -1
        val arr = EabpWidgetProvider.resolvedSpec(context, record)?.optJSONArray("items")
        val items = if (arr == null) emptyList()
        else (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }

        val (overdue, current) = items.partition { it.optBoolean("overdue") }
        rows = if (overdue.isEmpty()) {
            current.map { Row.Note(it) }
        } else {
            buildList {
                add(Row.Divider(context.getString(R.string.widget_overdue)))
                overdue.forEach { add(Row.Note(it)) }
                if (current.isNotEmpty()) {
                    add(Row.Divider(context.getString(R.string.widget_today)))
                    current.forEach { add(Row.Note(it)) }
                }
            }
        }
    }

    override fun getViewAt(position: Int): RemoteViews =
        when (val row = rows.getOrNull(position)) {
            is Row.Divider ->
                RemoteViews(context.packageName, R.layout.widget_eabp_agenda_divider)
                    .apply {
                        setTextViewText(R.id.item_divider_text, row.label)
                        // No fill-in: the template fires without an action
                        // and the trampoline no-ops.
                    }
            is Row.Note -> noteView(row.item)
            null -> RemoteViews(context.packageName, R.layout.widget_eabp_agenda_divider)
        }

    private fun noteView(item: JSONObject): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_eabp_agenda_item)
        views.setTextViewText(R.id.item_text, formatTitle(item))

        val meta = item.optString("meta")
        if (meta.isNotEmpty()) {
            views.setTextViewText(R.id.item_meta_text, meta)
            views.setImageViewResource(R.id.item_meta_icon, metaIcon(item.optString("type")))
            views.setViewVisibility(R.id.item_meta, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.item_meta, View.GONE)
        }

        val ref = item.optJSONObject("ref")

        // Fill-ins merge into the ActionTrampolineActivity template; TYPE
        // picks silent-broadcast vs open-app inside the trampoline.
        views.setOnClickFillInIntent(
            R.id.item_root,
            trampolineFillIn(
                ActionTrampolineActivity.TYPE_OPEN_APP, "heading.tap", ref))

        if (item.has("todo")) {
            views.setViewVisibility(R.id.item_toggle, View.VISIBLE)
            views.setImageViewResource(
                R.id.item_toggle,
                if (item.optBoolean("done")) R.drawable.ic_todo_done
                else R.drawable.ic_todo_open)
            views.setOnClickFillInIntent(
                R.id.item_toggle,
                trampolineFillIn(
                    ActionTrampolineActivity.TYPE_BROADCAST,
                    "heading.todo-cycle", ref))
        } else {
            views.setViewVisibility(R.id.item_toggle, View.GONE)
        }
        return views
    }

    /** Deadline-ish → alarm, scheduled-ish → calendar, else clock. */
    private fun metaIcon(type: String): Int = when {
        type.contains("deadline") -> R.drawable.ic_meta_deadline
        type.contains("scheduled") -> R.drawable.ic_meta_scheduled
        else -> R.drawable.ic_meta_event
    }

    /**
     * Title line: open items get their TODO keyword as a colored prefix
     * (Orgzly-style); done items get a plain struck-through headline.
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
        sb.append(item.optString("headline").ifEmpty { "Untitled" })
        if (done) {
            sb.setSpan(
                StrikethroughSpan(), start, sb.length,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return sb
    }

    private fun trampolineFillIn(
        type: String,
        actionName: String,
        args: JSONObject?
    ): Intent {
        val actionJson = JSONObject().apply {
            put("action", actionName)
            put("when_offline", "queue")
            put("args", args ?: JSONObject())
        }
        return Intent().apply {
            putExtra(ActionTrampolineActivity.EXTRA_TYPE, type)
            putExtra(ActionTrampolineActivity.EXTRA_ACTION, actionJson.toString())
            putExtra(ActionTrampolineActivity.EXTRA_REVISION, revision)
        }
    }

    override fun getCount() = rows.size
    override fun getViewTypeCount() = 2
    override fun getItemId(position: Int) = position.toLong()
    override fun hasStableIds() = false
    override fun getLoadingView(): RemoteViews? = null
    override fun onDestroy() {}
}