package com.calebc42.jetpacs

import android.util.Log
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Redo
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.graphics.vector.ImageVector
import java.util.concurrent.ConcurrentHashMap

object IconMap {
    private val cache = ConcurrentHashMap<String, ImageVector>()

    init {
        // Pre-populate some common icons to avoid reflection overhead for standard UI elements
        cache["add"] = Icons.Outlined.Add
        cache["arrow_back"] = Icons.Outlined.ArrowBack
        cache["arrow_upward"] = Icons.Outlined.ArrowUpward
        cache["refresh"] = Icons.Outlined.Refresh
        cache["search"] = Icons.Outlined.Search
        cache["more_vert"] = Icons.Outlined.MoreVert
        cache["close"] = Icons.Outlined.Close
        cache["check"] = Icons.Outlined.Check
        cache["edit"] = Icons.Outlined.Edit
        cache["visibility"] = Icons.Outlined.Visibility
        cache["play_arrow"] = Icons.Outlined.PlayArrow
        cache["stop"] = Icons.Outlined.Stop
        cache["event"] = Icons.Outlined.Event
        cache["checklist"] = Icons.Outlined.Checklist
        cache["folder"] = Icons.Outlined.Folder
        cache["folder_open"] = Icons.Outlined.FolderOpen
        cache["description"] = Icons.Outlined.Description
        cache["schedule"] = Icons.Outlined.Schedule
        cache["done"] = Icons.Outlined.Done
        cache["keyboard_arrow_down"] = Icons.Outlined.KeyboardArrowDown
        cache["keyboard_arrow_right"] = Icons.Outlined.KeyboardArrowRight
        cache["keyboard_arrow_up"] = Icons.Outlined.KeyboardArrowUp
        cache["chevron_left"] = Icons.Outlined.ChevronLeft
        cache["chevron_right"] = Icons.Outlined.ChevronRight
        cache["call_split"] = Icons.Outlined.CallSplit
        cache["view_list"] = Icons.Outlined.ViewList
        cache["archive"] = Icons.Outlined.Archive
        cache["drive_file_move"] = Icons.Outlined.DriveFileMove
        cache["note_add"] = Icons.Outlined.NoteAdd
        cache["terminal"] = Icons.Outlined.Terminal
        cache["code"] = Icons.Outlined.Code
        cache["send"] = Icons.Outlined.Send
        cache["info"] = Icons.Outlined.Info
        cache["delete"] = Icons.Outlined.Delete
        cache["content_copy"] = Icons.Outlined.ContentCopy
        cache["menu"] = Icons.Outlined.Menu
        cache["save"] = Icons.Outlined.Save
        cache["sync"] = Icons.Outlined.Sync
        cache["settings"] = Icons.Outlined.Settings
        cache["home"] = Icons.Outlined.Home
        cache["inbox"] = Icons.Outlined.Inbox
        cache["event_busy"] = Icons.Outlined.EventBusy
        cache["task_alt"] = Icons.Outlined.TaskAlt
        cache["today"] = Icons.Outlined.Today
        cache["history"] = Icons.Outlined.History
        cache["label"] = Icons.Outlined.Label
        cache["flag"] = Icons.Outlined.Flag
        cache["more_horiz"] = Icons.Outlined.MoreHoriz
        cache["image"] = Icons.Outlined.Image
        cache["access_time"] = Icons.Outlined.AccessTime
        cache["manage_search"] = Icons.Outlined.ManageSearch
        cache["keyboard"] = Icons.Outlined.Keyboard
        cache["format_bold"] = Icons.Outlined.FormatBold
        cache["format_italic"] = Icons.Outlined.FormatItalic
        cache["format_list_bulleted"] = Icons.Outlined.FormatListBulleted
        cache["format_list_numbered"] = Icons.Outlined.FormatListNumbered
        cache["format_strikethrough"] = Icons.Outlined.FormatStrikethrough
        cache["title"] = Icons.Outlined.Title
        cache["link"] = Icons.Outlined.Link
        cache["data_object"] = Icons.Outlined.DataObject
        cache["circle"] = Icons.Outlined.Circle
        cache["check_box"] = Icons.Outlined.CheckBox
        cache["check_box_outline_blank"] = Icons.Outlined.CheckBoxOutlineBlank
        cache["indeterminate_check_box"] = Icons.Outlined.IndeterminateCheckBox
        cache["format_indent_decrease"] = Icons.Outlined.FormatIndentDecrease
        cache["format_indent_increase"] = Icons.Outlined.FormatIndentIncrease
        cache["arrow_downward"] = Icons.Outlined.ArrowDownward
        cache["undo"] = Icons.AutoMirrored.Outlined.Undo
        cache["redo"] = Icons.AutoMirrored.Outlined.Redo
        cache["swap_vert"] = Icons.Outlined.SwapVert
        cache["drag_handle"] = Icons.Outlined.DragHandle
        cache["timer"] = Icons.Outlined.Timer
        cache["timer_off"] = Icons.Outlined.TimerOff
        cache["tune"] = Icons.Outlined.Tune
    }

    fun get(name: String): ImageVector {
        return cache.getOrPut(name) {
            val pascalName = name.split('_').joinToString("") { part ->
                part.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
            }

            // Try Outlined
            var icon = resolveIcon("androidx.compose.material.icons.outlined.${pascalName}Kt", "get$pascalName", Icons.Outlined)
            
            // Try AutoMirrored Outlined
            if (icon == null) {
                icon = resolveIcon("androidx.compose.material.icons.automirrored.outlined.${pascalName}Kt", "get$pascalName", Icons.AutoMirrored.Outlined)
            }
            
            // Try Filled
            if (icon == null) {
                icon = resolveIcon("androidx.compose.material.icons.filled.${pascalName}Kt", "get$pascalName", Icons.Filled)
            }

            if (icon == null) {
                Log.w("IconMap", "Icon not found: $name (tried $pascalName)")
                Icons.Outlined.HelpOutline
            } else {
                icon
            }
        }
    }

    private fun resolveIcon(className: String, methodName: String, receiver: Any): ImageVector? {
        return try {
            val clazz = Class.forName(className)
            val method = clazz.getMethod(methodName, receiver.javaClass)
            method.invoke(null, receiver) as? ImageVector
        } catch (e: Exception) {
            null
        }
    }
}