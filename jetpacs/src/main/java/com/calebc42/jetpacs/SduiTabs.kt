package com.calebc42.jetpacs

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Icon
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * The `tabs` node (SPEC §9): an intra-view tab row over swipeable pages —
 * the missing pattern between a chip row (no gesture) and `view.switch`
 * (whole-surface navigation).
 *
 *   {"t": "tabs", "items": [{"label", "icon"?}…], "children": [page…],
 *    "initial": 0, "scrollable": false, "pager_only": false, "on_change"?}
 *
 * Switching is companion-local (the `view.switch` philosophy): tab taps
 * and swipes never round-trip to Emacs unless the spec asks with
 * `on_change`, which dispatches with the settled page index injected as
 * `value`. `pager_only` drops the tab row for pure swipe-through content
 * (flashcard review); `scrollable` lets many tabs pan instead of cramming.
 */
@Composable
internal fun SduiTabs(
    node: JSONObject,
    surfaceId: String,
    revision: Int,
    modifier: Modifier,
    dispatch: (JSONObject) -> Unit,
) {
    val items = node.optJSONArray("items")
    val children = node.optJSONArray("children") ?: return
    val pageCount = children.length()
    if (pageCount == 0) return
    val initial = node.optInt("initial", 0).coerceIn(0, pageCount - 1)
    val scrollable = node.optBoolean("scrollable", false)
    val pagerOnly = node.optBoolean("pager_only", false)
    val onChange = node.optJSONObject("on_change")

    val pagerState = rememberPagerState(initialPage = initial) { pageCount }
    val scope = rememberCoroutineScope()

    // Report only user-driven settles, never the initial composition — and
    // only once per page, however the user got there (tap or swipe).
    var lastReported by remember { mutableIntStateOf(initial) }
    LaunchedEffect(pagerState.settledPage) {
        if (pagerState.settledPage != lastReported) {
            lastReported = pagerState.settledPage
            onChange?.let { dispatchWithValue(dispatch, it, pagerState.settledPage) }
        }
    }

    Column(modifier = modifier.fillMaxWidth()) {
        if (!pagerOnly && items != null) {
            val selected = pagerState.currentPage.coerceIn(0, pageCount - 1)
            val tabs: @Composable () -> Unit = {
                for (i in 0 until minOf(items.length(), pageCount)) {
                    val item = items.optJSONObject(i) ?: continue
                    val icon = item.optString("icon")
                    Tab(
                        selected = selected == i,
                        onClick = { scope.launch { pagerState.animateScrollToPage(i) } },
                        text = { Text(item.optString("label")) },
                        icon = if (icon.isNotEmpty()) {
                            { Icon(IconMap.get(icon), contentDescription = null) }
                        } else null
                    )
                }
            }
            if (scrollable) {
                ScrollableTabRow(selectedTabIndex = selected) { tabs() }
            } else {
                TabRow(selectedTabIndex = selected) { tabs() }
            }
        }
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top
        ) { page ->
            children.optJSONObject(page)?.let {
                SduiNode(it, surfaceId, revision, onAction = dispatch)
            }
        }
    }
}
