package com.calebc42.eabp

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.graphics.vector.ImageVector

object IconMap {
    fun get(name: String): ImageVector {
        return when (name) {
            "add" -> Icons.Outlined.Add
            "arrow_back" -> Icons.Outlined.ArrowBack
            "arrow_upward" -> Icons.Outlined.ArrowUpward
            "refresh" -> Icons.Outlined.Refresh
            "search" -> Icons.Outlined.Search
            "more_vert" -> Icons.Outlined.MoreVert
            "close" -> Icons.Outlined.Close
            "check" -> Icons.Outlined.Check
            "edit" -> Icons.Outlined.Edit
            "visibility" -> Icons.Outlined.Visibility
            "play_arrow" -> Icons.Outlined.PlayArrow
            "stop" -> Icons.Outlined.Stop
            "event" -> Icons.Outlined.Event
            "checklist" -> Icons.Outlined.Checklist
            "folder" -> Icons.Outlined.Folder
            "folder_open" -> Icons.Outlined.FolderOpen
            "description" -> Icons.Outlined.Description
            "schedule" -> Icons.Outlined.Schedule
            "done" -> Icons.Outlined.Done
            "keyboard_arrow_down" -> Icons.Outlined.KeyboardArrowDown
            "keyboard_arrow_right" -> Icons.Outlined.KeyboardArrowRight
            "keyboard_arrow_up" -> Icons.Outlined.KeyboardArrowUp
            "terminal" -> Icons.Outlined.Terminal
            "code" -> Icons.Outlined.Code
            "send" -> Icons.Outlined.Send
            "info" -> Icons.Outlined.Info
            "delete" -> Icons.Outlined.Delete
            "content_copy" -> Icons.Outlined.ContentCopy
            "menu" -> Icons.Outlined.Menu
            "save" -> Icons.Outlined.Save
            "sync" -> Icons.Outlined.Sync
            "settings" -> Icons.Outlined.Settings
            "home" -> Icons.Outlined.Home
            "inbox" -> Icons.Outlined.Inbox
            "event_busy" -> Icons.Outlined.EventBusy
            "task_alt" -> Icons.Outlined.TaskAlt
            "today" -> Icons.Outlined.Today
            "history" -> Icons.Outlined.History
            "label" -> Icons.Outlined.Label
            "flag" -> Icons.Outlined.Flag
            "more_horiz" -> Icons.Outlined.MoreHoriz
            "image" -> Icons.Outlined.Image
            "access_time" -> Icons.Outlined.AccessTime
            "manage_search" -> Icons.Outlined.ManageSearch
            "keyboard" -> Icons.Outlined.Keyboard
            "format_bold" -> Icons.Outlined.FormatBold
            "format_italic" -> Icons.Outlined.FormatItalic
            "format_list_bulleted" -> Icons.Outlined.FormatListBulleted
            "format_list_numbered" -> Icons.Outlined.FormatListNumbered
            "format_strikethrough" -> Icons.Outlined.FormatStrikethrough
            "title" -> Icons.Outlined.Title
            "link" -> Icons.Outlined.Link
            "data_object" -> Icons.Outlined.DataObject
            "circle" -> Icons.Outlined.Circle
            "check_box" -> Icons.Outlined.CheckBox
            "check_box_outline_blank" -> Icons.Outlined.CheckBoxOutlineBlank
            "indeterminate_check_box" -> Icons.Outlined.IndeterminateCheckBox
            "format_indent_decrease" -> Icons.Outlined.FormatIndentDecrease
            "format_indent_increase" -> Icons.Outlined.FormatIndentIncrease
            "arrow_downward" -> Icons.Outlined.ArrowDownward
            "undo" -> Icons.Outlined.Undo
            "redo" -> Icons.Outlined.Redo
            "swap_vert" -> Icons.Outlined.SwapVert
            "drag_handle" -> Icons.Outlined.DragHandle
            else -> Icons.Outlined.HelpOutline
        }
    }
}