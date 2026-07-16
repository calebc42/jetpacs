package com.calebc42.jetpacs

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * On-device, `java.util.regex` delegates to ICU, which is stricter than the
 * host JVM's engine: a bare `{` or `}` that is not part of an interval
 * quantifier is a [java.util.regex.PatternSyntaxException] on Android but
 * compiles fine on the desktop JVM — so the unit suite stays green while the
 * app dies at class-init (TriggerHost's `PLACEHOLDER` did exactly this).
 * Running the patterns here can't reproduce that, so this test scans every
 * `Regex(...)` literal in main sources and fails on any unescaped brace
 * outside a character class or a valid `{n}` / `{n,}` / `{n,m}` quantifier.
 */
class RegexIcuPortabilityTest {

    private fun mainSourceRoots(): List<File> {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val roots = listOf("jetpacs/src/main", "app/src/main", "src/main")
                .map { File(dir, it) }.filter { it.isDirectory }
            if (roots.isNotEmpty()) return roots
            dir = dir.parentFile
        }
        error("no src/main found from ${System.getProperty("user.dir")}")
    }

    private val rawLiteral =
        Regex("""Regex\(\s*"{3}(.*?)"{3}""", RegexOption.DOT_MATCHES_ALL)
    private val escapedLiteral = Regex("""Regex\(\s*"((?:[^"\\]|\\.)*)"""")

    /** Kotlin escaped-string source text -> the pattern the compiler produces. */
    private fun unescape(src: String): String {
        val sb = StringBuilder()
        var i = 0
        while (i < src.length) {
            val c = src[i]
            if (c == '\\' && i + 1 < src.length) {
                when (val n = src[i + 1]) {
                    '\\', '"', '$', '\'' -> sb.append(n)
                    'n' -> sb.append('\n'); 't' -> sb.append('\t'); 'r' -> sb.append('\r')
                    else -> { sb.append(c); sb.append(n) }
                }
                i += 2
            } else {
                sb.append(c); i++
            }
        }
        return sb.toString()
    }

    private val quantifier = Regex("""^\{\d+(,\d*)?\}""")

    /** Index of the first brace ICU would reject, or -1 if the pattern is clean. */
    private fun bareBraceAt(pattern: String): Int {
        var i = 0
        while (i < pattern.length) {
            when (pattern[i]) {
                '\\' -> i += 2
                '[' -> {
                    i++
                    if (i < pattern.length && pattern[i] == '^') i++
                    if (i < pattern.length && pattern[i] == ']') i++
                    while (i < pattern.length && pattern[i] != ']') {
                        if (pattern[i] == '\\') i++
                        i++
                    }
                    i++
                }
                '{' -> {
                    val q = quantifier.find(pattern.substring(i)) ?: return i
                    i += q.value.length
                }
                '}' -> return i
                else -> i++
            }
        }
        return -1
    }

    @Test
    fun mainSourceRegexLiteralsHaveNoBareBraces() {
        val violations = mutableListOf<String>()
        for (root in mainSourceRoots()) {
            for (file in root.walkTopDown().filter { it.extension == "kt" }) {
                val src = file.readText()
                val patterns =
                    rawLiteral.findAll(src).map { it.groupValues[1] } +
                    escapedLiteral.findAll(src).map { unescape(it.groupValues[1]) }
                for (pattern in patterns) {
                    val at = bareBraceAt(pattern)
                    if (at >= 0) violations +=
                        "${file.name}: unescaped `${pattern[at]}` at index $at in Regex(\"\"\"$pattern\"\"\") — ICU (Android) rejects it"
                }
            }
        }
        assertEquals("", violations.joinToString("\n"))
    }

    @Test
    fun scannerCatchesTheTriggerHostShape() {
        // The exact pattern that shipped the crash, and its fixed form.
        assertEquals(35, bareBraceAt("""\$\{(id|type|data\.([A-Za-z0-9_]+))}"""))
        assertEquals(-1, bareBraceAt("""\$\{(id|type|data\.([A-Za-z0-9_]+))\}"""))
        // Interval quantifiers stay legal; classes may hold braces.
        assertEquals(-1, bareBraceAt("""\d{4}-\d{2}"""))
        assertEquals(-1, bareBraceAt("""[{}]+"""))
    }
}
