package com.calebc42.jetpacs

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration

/**
 * Token colours for code highlighting. The static palettes below (Nord-derived
 * accents, keyed only on surface luminance so they stay legible on any
 * Material You wallpaper scheme) are the fallback; when the client syncs its
 * Emacs theme, [rememberSyntaxColors] overlays the pushed `syntax` colors so
 * the editor reads like the user's actual desktop theme.
 */
data class SyntaxColors(
    val comment: Color,
    val string: Color,
    val keyword: Color,
    val function: Color,
    val constant: Color,
    val number: Color,
    val link: Color,
    val meta: Color,
    val todo: Color,
    val done: Color,
    val heading: List<Color>,
    val paren: List<Color>,
) {
    companion object {
        fun forBackground(dark: Boolean): SyntaxColors =
            if (dark) {
                SyntaxColors(
                    comment = Color(0xFF616E88),
                    string = Color(0xFFA3BE8C),
                    keyword = Color(0xFF81A1C1),
                    function = Color(0xFF88C0D0),
                    constant = Color(0xFFB48EAD),
                    number = Color(0xFFB48EAD),
                    link = Color(0xFF88C0D0),
                    meta = Color(0xFF7B88A1),
                    todo = Color(0xFFBF616A),
                    done = Color(0xFFA3BE8C),
                    heading = listOf(
                        Color(0xFF88C0D0), Color(0xFF81A1C1), Color(0xFFB48EAD),
                        Color(0xFFA3BE8C), Color(0xFFEBCB8B), Color(0xFFD08770),
                    ),
                    paren = listOf(
                        Color(0xFF81A1C1), Color(0xFFB48EAD), Color(0xFFA3BE8C),
                        Color(0xFFEBCB8B), Color(0xFFD08770), Color(0xFF88C0D0),
                    ),
                )
            } else {
                SyntaxColors(
                    comment = Color(0xFF7B88A1),
                    string = Color(0xFF4F6F3F),
                    keyword = Color(0xFF3B5B8C),
                    function = Color(0xFF2E6E7E),
                    constant = Color(0xFF8A4B82),
                    number = Color(0xFF8A4B82),
                    link = Color(0xFF2E6E7E),
                    meta = Color(0xFF5E6B82),
                    todo = Color(0xFFA01F2C),
                    done = Color(0xFF4F6F3F),
                    heading = listOf(
                        Color(0xFF2E6E7E), Color(0xFF3B5B8C), Color(0xFF8A4B82),
                        Color(0xFF4F6F3F), Color(0xFF9A7A1E), Color(0xFFA85A36),
                    ),
                    paren = listOf(
                        Color(0xFF3B5B8C), Color(0xFF8A4B82), Color(0xFF4F6F3F),
                        Color(0xFF9A7A1E), Color(0xFFA85A36), Color(0xFF2E6E7E),
                    ),
                )
            }
    }
}

/**
 * Best-effort client-side span styles for [src] in [language]. The single
 * tokenizer entry point behind both [SyntaxTransformation] (legacy fields)
 * and the editor's output transformation.
 *
 * Highlighting is capped at [maxChars]; past that the tail renders plain so a
 * large config file can't lag every keystroke. Any tokeniser hiccup falls back
 * to no styles rather than crashing the field.
 */
fun highlightSpans(
    language: String,
    src: String,
    colors: SyntaxColors,
    maxChars: Int = 20_000,
): List<AnnotatedString.Range<SpanStyle>> = runCatching {
    when (language.lowercase()) {
        "elisp", "emacs-lisp", "lisp" -> highlightElisp(src, colors, maxChars)
        "org" -> highlightOrg(src, colors, maxChars)
        "python", "py" -> highlightCode(
            src, colors, pythonKeywords,
            lineComment = "#", singleQuoteStrings = true, maxChars = maxChars)
        "rust", "rs" -> highlightCode(
            src, colors, rustKeywords,
            lineComment = "//", singleQuoteStrings = false, maxChars = maxChars)
        "shell", "sh", "bash" -> highlightCode(
            src, colors, shellKeywords,
            lineComment = "#", singleQuoteStrings = true, maxChars = maxChars)
        "c", "cpp" -> highlightCode(
            src, colors, cKeywords,
            lineComment = "//", singleQuoteStrings = false, maxChars = maxChars)
        else -> null
    }?.spanStyles ?: emptyList()
}.getOrElse { emptyList() }

/**
 * A [VisualTransformation] that recolours a code field in place. It never
 * changes character count, so the offset mapping is the identity — the cursor,
 * selection, and IME all keep working exactly as on a plain field.
 */
class SyntaxTransformation(
    private val language: String,
    private val colors: SyntaxColors,
    private val maxChars: Int = 20_000,
) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val spans = highlightSpans(language, text.text, colors, maxChars)
        val styled = if (spans.isEmpty()) AnnotatedString(text.text)
            else AnnotatedString(text.text, spanStyles = spans)
        return TransformedText(styled, OffsetMapping.Identity)
    }
}

/** Best-effort language guess from a file path's extension. */
fun syntaxForPath(path: String): String =
    when (path.substringAfterLast('.', "").lowercase()) {
        "el", "elc" -> "elisp"
        "org" -> "org"
        "py" -> "python"
        "rs" -> "rust"
        "sh", "bash" -> "shell"
        "c", "h" -> "c"
        "cc", "cpp", "hpp" -> "cpp"
        else -> ""
    }

private fun isSymbolChar(ch: Char): Boolean =
    !ch.isWhitespace() && ch !in "()[]{}\"';`,#"

private val elispKeywords = setOf(
    "defun", "defmacro", "defvar", "defconst", "defcustom", "defgroup", "defface",
    "cl-defun", "cl-defmacro", "cl-defstruct", "cl-defmethod", "define-minor-mode",
    "let", "let*", "letrec", "lambda", "if", "when", "unless", "cond", "case",
    "pcase", "pcase-let", "while", "dolist", "dotimes", "cl-loop", "cl-dolist",
    "setq", "setq-default", "setf", "push", "pop", "progn", "prog1", "prog2",
    "and", "or", "not", "function", "quote", "interactive", "save-excursion",
    "save-restriction", "save-match-data", "with-current-buffer", "with-temp-buffer",
    "condition-case", "unwind-protect", "catch", "throw", "ignore-errors",
    "require", "provide", "declare-function", "add-hook", "remove-hook",
    "mapcar", "mapc", "mapconcat", "dolist", "cl-remove-if", "cl-remove-if-not",
)

fun highlightElisp(src: String, c: SyntaxColors, maxChars: Int = 20_000): AnnotatedString =
    buildAnnotatedString {
        append(src)
        val n = minOf(src.length, maxChars)
        var i = 0
        var depth = 0
        while (i < n) {
            val ch = src[i]
            when {
                ch == ';' -> {
                    var j = i
                    while (j < src.length && src[j] != '\n') j++
                    addStyle(SpanStyle(color = c.comment, fontStyle = FontStyle.Italic), i, minOf(j, n))
                    i = j
                }
                ch == '"' -> {
                    var j = i + 1
                    while (j < src.length) {
                        when (src[j]) {
                            '\\' -> j += 2
                            '"' -> { j++; break }
                            else -> j++
                        }
                    }
                    addStyle(SpanStyle(color = c.string), i, minOf(j, n))
                    i = j
                }
                ch == '?' -> {
                    var j = i + 1
                    if (j < src.length && src[j] == '\\') j++
                    if (j < src.length) j++
                    addStyle(SpanStyle(color = c.string), i, minOf(j, n))
                    i = j
                }
                ch == '(' || ch == '[' -> {
                    addStyle(SpanStyle(color = c.paren[depth % c.paren.size]), i, i + 1)
                    depth++
                    i++
                    if (ch == '(') {
                        var j = i
                        while (j < src.length && src[j] == ' ') j++
                        var k = j
                        while (k < src.length && isSymbolChar(src[k])) k++
                        if (k > j) {
                            val sym = src.substring(j, k)
                            val style = if (sym in elispKeywords)
                                SpanStyle(color = c.keyword, fontWeight = FontWeight.Bold)
                            else SpanStyle(color = c.function)
                            if (j < n) addStyle(style, j, minOf(k, n))
                            i = k
                        }
                    }
                }
                ch == ')' || ch == ']' -> {
                    depth = maxOf(0, depth - 1)
                    addStyle(SpanStyle(color = c.paren[depth % c.paren.size]), i, i + 1)
                    i++
                }
                ch == ':' -> {
                    var j = i + 1
                    while (j < src.length && isSymbolChar(src[j])) j++
                    addStyle(SpanStyle(color = c.constant), i, minOf(j, n))
                    i = j
                }
                ch == '\'' || ch == '`' -> {
                    addStyle(SpanStyle(color = c.constant), i, i + 1)
                    i++
                }
                ch.isDigit() && (i == 0 || !isSymbolChar(src[i - 1])) -> {
                    var j = i
                    while (j < src.length && (src[j].isDigit() || src[j] == '.')) j++
                    addStyle(SpanStyle(color = c.number), i, minOf(j, n))
                    i = j
                }
                else -> i++
            }
        }
    }

private val pythonKeywords = setOf(
    "def", "class", "return", "if", "elif", "else", "for", "while",
    "import", "from", "as", "with", "try", "except", "finally", "raise",
    "pass", "break", "continue", "lambda", "yield", "global", "nonlocal",
    "assert", "in", "is", "not", "and", "or", "None", "True", "False",
    "async", "await", "match", "case", "del",
)

private val rustKeywords = setOf(
    "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use",
    "mod", "crate", "match", "if", "else", "for", "while", "loop",
    "return", "break", "continue", "const", "static", "ref", "move",
    "async", "await", "dyn", "where", "type", "unsafe", "as", "in",
    "self", "Self", "super", "true", "false",
)

private val shellKeywords = setOf(
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
    "done", "case", "esac", "in", "function", "local", "return", "exit",
    "export", "readonly", "shift", "break", "continue", "echo", "read",
    "declare", "set", "unset", "source", "trap", "true", "false",
)

private val cKeywords = setOf(
    "if", "else", "for", "while", "do", "switch", "case", "default",
    "break", "continue", "return", "goto", "typedef", "struct", "union",
    "enum", "static", "extern", "const", "volatile", "inline", "sizeof",
    "void", "char", "short", "int", "long", "float", "double", "signed",
    "unsigned", "bool", "true", "false", "NULL", "include", "define",
    "class", "namespace", "template", "public", "private", "protected",
    "new", "delete", "nullptr", "auto", "using",
)

private fun isIdentChar(ch: Char): Boolean = ch.isLetterOrDigit() || ch == '_'

/**
 * Generic keyword/string/comment/number highlighter for C-family-ish
 * languages, parameterized by keyword set and line-comment token. Not a
 * parser — block comments and f-string interiors render approximately —
 * but the same class of best-effort colouring as [highlightElisp].
 * [singleQuoteStrings] is on for Python and off for Rust, where a bare
 * apostrophe is a lifetime, not a string.
 */
fun highlightCode(
    src: String,
    c: SyntaxColors,
    keywords: Set<String>,
    lineComment: String,
    singleQuoteStrings: Boolean,
    maxChars: Int = 20_000,
): AnnotatedString = buildAnnotatedString {
    append(src)
    val n = minOf(src.length, maxChars)
    var i = 0
    while (i < n) {
        val ch = src[i]
        when {
            src.startsWith(lineComment, i) -> {
                var j = i
                while (j < src.length && src[j] != '\n') j++
                addStyle(SpanStyle(color = c.comment, fontStyle = FontStyle.Italic), i, minOf(j, n))
                i = j
            }
            ch == '"' || (singleQuoteStrings && ch == '\'') -> {
                var j = i + 1
                while (j < src.length) {
                    when (src[j]) {
                        '\\' -> j += 2
                        ch -> { j++; break }
                        '\n' -> break   // unterminated: stop at line end
                        else -> j++
                    }
                }
                addStyle(SpanStyle(color = c.string), i, minOf(j, n))
                i = j
            }
            ch.isDigit() && (i == 0 || !isIdentChar(src[i - 1])) -> {
                var j = i
                while (j < src.length && (isIdentChar(src[j]) || src[j] == '.')) j++
                addStyle(SpanStyle(color = c.number), i, minOf(j, n))
                i = j
            }
            ch.isLetter() || ch == '_' -> {
                var j = i
                while (j < src.length && isIdentChar(src[j])) j++
                val word = src.substring(i, j)
                when {
                    word in keywords ->
                        addStyle(SpanStyle(color = c.keyword, fontWeight = FontWeight.Bold), i, minOf(j, n))
                    j < src.length && src[j] == '(' ->
                        addStyle(SpanStyle(color = c.function), i, minOf(j, n))
                }
                i = j
            }
            else -> i++
        }
    }
}

private val orgHeadingRe = Regex("""^(\*+)\s+(.*)$""")
private val orgTodoRe = Regex("""^(TODO|NEXT|STARTED|WAIT|WAITING|HOLD|DOING)\b""")
private val orgDoneRe = Regex("""^(DONE|CANCELLED|CANCELED|KILL)\b""")
private val orgTagsRe = Regex("""(:[\w@#%:]+:)\s*$""")
private val orgListRe = Regex("""^(\s*)([-+]|\d+[.)])\s""")
private val orgLinkRe = Regex("""\[\[[^\]]*](\[[^\]]*])?]""")
private val orgBoldRe = Regex("""(?<![\w*])\*(\S(?:[^*\n]*\S)?)\*(?![\w*])""")
private val orgItalicRe = Regex("""(?<![\w/])/(\S(?:[^/\n]*\S)?)/(?![\w/])""")
private val orgCodeRe = Regex("""(?<![\w~])~([^~\n]+)~(?![\w~])""")
private val orgVerbatimRe = Regex("""(?<![\w=])=([^=\n]+)=(?![\w=])""")

fun highlightOrg(src: String, c: SyntaxColors, maxChars: Int = 40_000): AnnotatedString =
    buildAnnotatedString {
        append(src)
        val n = minOf(src.length, maxChars)
        var lineStart = 0
        while (lineStart < n) {
            var lineEnd = src.indexOf('\n', lineStart)
            if (lineEnd == -1 || lineEnd > n) lineEnd = n
            styleOrgLine(src.substring(lineStart, lineEnd), lineStart, c)
            lineStart = lineEnd + 1
        }
    }

private fun androidx.compose.ui.text.AnnotatedString.Builder.span(
    base: Int, range: IntRange, style: SpanStyle,
) {
    addStyle(style, base + range.first, base + range.last + 1)
}

private fun androidx.compose.ui.text.AnnotatedString.Builder.styleOrgLine(
    line: String, base: Int, c: SyntaxColors,
) {
    val trimmed = line.trimStart()
    when {
        // Block delimiters and #+KEYWORD: metadata.
        trimmed.startsWith("#+") -> {
            addStyle(SpanStyle(color = c.keyword), base, base + line.length)
            return
        }
        // Outline headings: colour + bold by level, with TODO/DONE keyword and
        // trailing :tags: picked out.
        line.startsWith("*") -> {
            val m = orgHeadingRe.find(line) ?: return
            val level = m.groupValues[1].length
            val color = c.heading[(level - 1) % c.heading.size]
            addStyle(SpanStyle(color = color, fontWeight = FontWeight.Bold), base, base + line.length)
            val titleStart = m.groups[2]!!.range.first
            val title = m.groupValues[2]
            orgTodoRe.find(title)?.let { span(base + titleStart, it.range, SpanStyle(color = c.todo, fontWeight = FontWeight.Bold)) }
            orgDoneRe.find(title)?.let { span(base + titleStart, it.range, SpanStyle(color = c.done, fontWeight = FontWeight.Bold)) }
            orgTagsRe.find(line)?.let { span(base, it.groups[1]!!.range, SpanStyle(color = c.meta)) }
            return
        }
        // Line comments: "# " at start.
        trimmed.startsWith("# ") -> {
            addStyle(SpanStyle(color = c.comment, fontStyle = FontStyle.Italic), base, base + line.length)
            return
        }
        // Tables.
        trimmed.startsWith("|") -> {
            addStyle(SpanStyle(color = c.meta), base, base + line.length)
            return
        }
    }
    // List markers.
    orgListRe.find(line)?.let { span(base, it.groups[2]!!.range, SpanStyle(color = c.constant, fontWeight = FontWeight.Bold)) }
    // Inline markup (links first so their brackets aren't re-decorated).
    for (m in orgLinkRe.findAll(line)) span(base, m.range, SpanStyle(color = c.link, textDecoration = TextDecoration.Underline))
    for (m in orgCodeRe.findAll(line)) span(base, m.range, SpanStyle(color = c.string))
    for (m in orgVerbatimRe.findAll(line)) span(base, m.range, SpanStyle(color = c.string))
    for (m in orgBoldRe.findAll(line)) span(base, m.range, SpanStyle(fontWeight = FontWeight.Bold))
    for (m in orgItalicRe.findAll(line)) span(base, m.range, SpanStyle(fontStyle = FontStyle.Italic))
}
