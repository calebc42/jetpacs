package com.calebc42.jetpacs

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Pins the renderer's `when (type)` dispatch to [SDUI_NODE_TYPES]: a case added
 * without a matching set entry (or an entry with no case) fails here. This is
 * the Kotlin leg of the node-type mirror. The elisp leg (`jetpacs-node-types-mirror`
 * in `test/jetpacs-tests.el`) pins [SDUI_NODE_TYPES] to the lint table and the
 * wire golden, so together: lint = golden = set = dispatch.
 *
 * It reads the renderer source rather than reflecting, because a `when`'s string
 * labels are not introspectable at runtime. Only the dispatch's own case labels
 * are collected (the shallowest case indent inside the `when`); nested `when`s
 * for alignment/shape/variant sit deeper and are ignored.
 */
class SduiRendererNodeTypesTest {

    private val relPath = "src/main/java/com/calebc42/jetpacs/SduiRenderer.kt"

    private fun rendererSource(): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            for (candidate in listOf(File(dir, relPath), File(dir, "jetpacs/$relPath"))) {
                if (candidate.isFile) return candidate.readText()
            }
            dir = dir.parentFile
        }
        error("SduiRenderer.kt not found from ${System.getProperty("user.dir")}")
    }

    private fun dispatchTypes(src: String): Set<String> {
        val lines = src.lines()
        val start = lines.indexOfFirst { it.contains("when (type)") }
        require(start >= 0) { "dispatch `when (type)` not found" }
        val label = Regex("""^(\s+)"[a-z_]+"(\s*,\s*"[a-z_]+")*\s*->""")
        val quoted = Regex(""""([a-z_]+)"""")
        val types = sortedSetOf<String>()
        var depth = 0
        var started = false
        var caseIndent = -1
        for (i in start until lines.size) {
            val line = lines[i]
            depth += line.count { it == '{' } - line.count { it == '}' }
            if (!started) {
                if (depth >= 1) started = true
                continue
            }
            label.find(line)?.let { m ->
                val indent = m.groupValues[1].length
                if (caseIndent < 0) caseIndent = indent
                if (indent == caseIndent) {
                    quoted.findAll(line.substringBefore("->"))
                        .forEach { types += it.groupValues[1] }
                }
            }
            if (depth <= 0) break
        }
        return types
    }

    @Test
    fun dispatchMatchesPublishedNodeTypes() {
        assertEquals(SDUI_NODE_TYPES.toSortedSet(), dispatchTypes(rendererSource()))
    }
}
