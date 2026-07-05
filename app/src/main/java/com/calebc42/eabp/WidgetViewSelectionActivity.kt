package com.calebc42.eabp

import android.app.Activity
import android.app.AlertDialog
import android.content.res.Configuration
import android.os.Bundle
import android.view.ContextThemeWrapper

/**
 * The agenda widget's view selector (Orgzly's saved-search dropdown): a
 * floating list of the views Emacs pushed inside the `widget:agenda` spec
 * ("today" plus one per custom agenda). Picking one is companion-local —
 * setCurrentView + re-render from cache — so it works with Emacs dead;
 * Emacs's next push simply carries all views again.
 */
class WidgetViewSelectionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val manager = EabpRuntime.surfaceManager ?: SurfaceManager(applicationContext)
        val record = manager.getRecord(EabpWidgetProvider.SURFACE)
        val views = record?.spec?.optJSONObject("views")
        if (views == null || views.length() == 0) {
            finish()
            return
        }
        val names = views.keys().asSequence().toList()
        val labels = names.map { name ->
            if (name == "today") getString(R.string.widget_today) else name
        }.toTypedArray()

        // Plain Activity has no dialog theming of its own; wrap in the
        // DeviceDefault alert theme matching the current night mode.
        val night = (resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val themed = ContextThemeWrapper(
            this,
            if (night) android.R.style.Theme_DeviceDefault_Dialog_Alert
            else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert)

        AlertDialog.Builder(themed)
            .setTitle(R.string.widget_view_selector_title)
            .setItems(labels) { _, which ->
                manager.setCurrentView(EabpWidgetProvider.SURFACE, names[which])
                EabpWidgetProvider.renderAll(this, record)
                finish()
            }
            .setOnCancelListener { finish() }
            .show()
    }
}