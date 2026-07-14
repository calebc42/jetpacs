package com.calebc42.jetpacs

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Conformance leg A of the Spec 1.0 kit (PLAN-spec-freeze S2): the Kotlin
 * side replays the committed golden corpus against `docs/contract.json`
 * (contract_format 2) — the same artifact the ERT suite generates and
 * validates — so the frozen contract is machine-checked by two independent
 * implementations.
 *
 * Legs:
 *  - `test/frames.golden`: every line parses via [Frame.fromJson], defaults
 *    to protocol v1, names a schema-registered kind sent in the client
 *    direction, and its payload keys satisfy the kind's required/optional
 *    sets; the envelope round-trips through compact single-line NDJSON.
 *  - `test/widgets.golden` and `test/hypertext.golden`: every typed node
 *    validates against `node_schema` (type known, required keys present,
 *    no key outside the schema) and every embedded action against the
 *    discriminated `action_schema`.
 *  - [NdjsonFrameCodec] re-reads the whole corpus as one byte stream,
 *    tolerating blank keep-alive lines.
 *  - Seeded corruptions fail, so the validators demonstrably bite.
 *
 * Deliberately no `main/` changes: this test consumes only public wire
 * types ([Frame], [NdjsonFrameCodec], [SDUI_NODE_TYPES]) plus repo files,
 * discovered with the directory-walk idiom of [SduiRendererNodeTypesTest].
 */
class WireGoldenConformanceTest {

    // ── Repo-file discovery ──────────────────────────────────────────────

    private fun repoFile(relPath: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relPath)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        error("$relPath not found from ${System.getProperty("user.dir")}")
    }

    /** Golden lines with their "NN " index prefix stripped. */
    private fun goldenLines(relPath: String): List<String> =
        repoFile(relPath).readLines()
            .filter { it.isNotBlank() }
            .map { it.substringAfter(' ') }

    private val contract: JSONObject by lazy {
        JSONObject(repoFile("docs/contract.json").readText())
    }

    // ── Schema accessors over contract.json (format 2) ───────────────────

    private fun names(arr: JSONArray): Set<String> =
        (0 until arr.length()).map { arr.getString(it) }.toSet()

    private val nodeTypes: Set<String> by lazy { names(contract.getJSONArray("node_types")) }
    private val nodeSchema: JSONObject by lazy { contract.getJSONObject("node_schema") }
    private val kindSchema: JSONObject by lazy { contract.getJSONObject("kind_schema") }
    private val actionHookKeys: Set<String> by lazy { names(contract.getJSONArray("action_hook_keys")) }
    private val actionSchema: JSONObject by lazy { contract.getJSONObject("action_schema") }
    private val commonNodeKeys: Set<String> by lazy {
        names(nodeSchema.getJSONObject("*").getJSONArray("optional"))
    }

    /**
     * Key-order-independent canonical text of a JSON value, for equality
     * checks (the SDK's compile-time org.json stub lacks `similar`).
     */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted()
            .joinToString(",", prefix = "{", postfix = "}") {
                "\"$it\":" + canonical(value.opt(it))
            }
        is JSONArray -> (0 until value.length())
            .joinToString(",", prefix = "[", postfix = "]") { canonical(value.opt(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString() // numbers, booleans, JSONObject.NULL
    }

    // ── Validators ───────────────────────────────────────────────────────

    /** Validate an embedded action object against the discriminated schema. */
    private fun validateAction(obj: JSONObject, path: String, problems: MutableList<String>) {
        val hasAction = obj.has("action")
        val hasBuiltin = obj.has("builtin")
        if (hasAction == hasBuiltin) {
            problems += "$path: action needs exactly one of `action`/`builtin`"
            return
        }
        val entry = if (hasAction) {
            actionSchema.getJSONObject("remote")
        } else {
            actionSchema.optJSONObject(obj.getString("builtin"))
                ?: run { problems += "$path: unknown builtin `${obj.getString("builtin")}`"; return }
        }
        val required = names(entry.getJSONArray("required"))
        val optional = names(entry.getJSONArray("optional"))
        for (req in required) {
            // "remote"'s required names the discriminator as "action"; a
            // builtin's required names "builtin" plus its payload keys.
            if (!obj.has(req)) problems += "$path: action missing required `$req`"
        }
        for (key in obj.keys()) {
            if (key !in required && key !in optional) {
                problems += "$path: unknown action field `$key`"
            }
        }
    }

    /** Recursively validate a widget tree: node types, key schema, actions. */
    private fun validateNode(value: Any?, path: String, problems: MutableList<String>) {
        when (value) {
            is JSONArray ->
                for (i in 0 until value.length()) validateNode(value.opt(i), "$path[$i]", problems)
            is JSONObject -> {
                val type = value.optString("t", "")
                if (value.has("t")) {
                    if (type !in nodeTypes) {
                        problems += "$path: unknown node type `$type`"
                        return
                    }
                    val row = nodeSchema.getJSONObject(type)
                    val required = names(row.getJSONArray("required"))
                    val optional = names(row.getJSONArray("optional"))
                    for (req in required) {
                        if (!value.has(req)) problems += "$path: $type missing required `$req`"
                    }
                    for (key in value.keys()) {
                        if (key != "t" && key !in required && key !in optional &&
                            key !in commonNodeKeys
                        ) {
                            problems += "$path: unknown key `$key` on $type"
                        }
                    }
                }
                for (key in value.keys()) {
                    val child = value.opt(key)
                    if (key in actionHookKeys && child is JSONObject) {
                        validateAction(child, "$path.$key", problems)
                    } else {
                        validateNode(child, "$path.$key", problems)
                    }
                }
            }
            else -> Unit // scalars carry no schema
        }
    }

    /** Validate a frame's payload keys against the kind schema. */
    private fun validatePayload(kind: String, payload: JSONObject, problems: MutableList<String>) {
        val entry = kindSchema.optJSONObject(kind)
        if (entry == null) {
            problems += "unknown frame kind `$kind`"
            return
        }
        if (entry.optString("payload") == "node") {
            validateNode(payload, kind, problems)
            return
        }
        val required = names(entry.getJSONArray("required"))
        val optional = names(entry.getJSONArray("optional"))
        for (req in required) {
            if (!payload.has(req)) problems += "$kind: missing required `$req`"
        }
        for (key in payload.keys()) {
            if (key !in required && key !in optional) {
                problems += "$kind: unknown payload key `$key`"
            }
        }
    }

    // ── The contract artifact itself ─────────────────────────────────────

    @Test
    fun contractIsFormatTwoAndCoherent() {
        assertEquals(2, contract.getInt("contract_format"))
        assertEquals(Jetpacs_PROTOCOL_VERSION, contract.getInt("protocol_version"))
        assertTrue(contract.getString("spec_version").isNotEmpty())
        // The third mirror leg: the published node vocabulary is exactly the
        // renderer's (elisp already pins lint = golden = SDUI_NODE_TYPES).
        assertEquals(SDUI_NODE_TYPES.toSortedSet(), nodeTypes.toSortedSet())
        // Every Kind constant the companion compiles against is registered.
        val kinds = kindSchema.keys().asSequence().toSet()
        for (k in listOf(
                Kind.SESSION_HELLO, Kind.SESSION_WELCOME, Kind.AUTH_CHALLENGE,
                Kind.AUTH_RESPONSE, Kind.ACK, Kind.ERROR, Kind.PING, Kind.PONG,
                Kind.STATE_CHANGED, Kind.DIALOG_SHOW, Kind.DIALOG_DISMISS,
                Kind.PIE_MENU_SHOW, Kind.PIE_MENU_DISMISS, Kind.TOAST_SHOW,
                Kind.COMPLETIONS_SHOW, Kind.EDIT_RESYNC, Kind.DIAGNOSTICS_SHOW,
                Kind.ELDOC_SHOW, Kind.FONTIFY_SHOW, Kind.CAPABILITY_INVOKE,
                Kind.CAPABILITY_RESULT, Kind.THEME_SET, Kind.TRIGGERS_SET,
        )) {
            assertTrue("Kind `$k` missing from kind_schema", k in kinds)
        }
    }

    // ── frames.golden ────────────────────────────────────────────────────

    @Test
    fun framesGoldenConformsToKindSchema() {
        val lines = goldenLines("test/frames.golden")
        assertTrue(lines.isNotEmpty())
        for (line in lines) {
            val frame = Frame.fromJson(JSONObject(line))
            assertEquals(Jetpacs_PROTOCOL_VERSION, frame.v) // defaulted: golden pins payloads
            assertTrue(frame.kind.isNotEmpty())
            val entry = kindSchema.optJSONObject(frame.kind)
            assertTrue("kind `${frame.kind}` not in schema", entry != null)
            // The frame corpus is client-emitted (elisp is the sender).
            assertTrue(entry!!.getString("direction") in setOf("client", "both"))
            val problems = mutableListOf<String>()
            validatePayload(frame.kind, frame.payload, problems)
            assertEquals("$line -> $problems", emptyList<String>(), problems)
        }
    }

    @Test
    fun framesGoldenRoundTripsStably() {
        for (line in goldenLines("test/frames.golden")) {
            val obj = JSONObject(line)
            val sent = Frame(kind = obj.getString("kind"), payload = obj.getJSONObject("payload"))
            val wire = sent.toString()
            assertTrue("NDJSON frame must be single-line", '\n' !in wire)
            val received = Frame.fromJson(JSONObject(wire))
            assertEquals(sent.kind, received.kind)
            assertEquals(sent.id, received.id)
            assertEquals(sent.v, received.v)
            assertEquals(null, received.replyTo)
            assertEquals("payload drifted through the wire round-trip",
                canonical(sent.payload), canonical(received.payload))
        }
    }

    // ── widgets.golden / hypertext.golden ────────────────────────────────

    @Test
    fun widgetsGoldenConformsToNodeSchema() {
        var typedNodes = 0
        for (line in goldenLines("test/widgets.golden")) {
            val obj = JSONObject(line)
            val problems = mutableListOf<String>()
            if (obj.has("t")) typedNodes++
            if (obj.has("action") || obj.has("builtin")) {
                validateAction(obj, "line", problems) // the bare-action lines
            } else {
                validateNode(obj, "line", problems)
            }
            assertEquals("$line -> $problems", emptyList<String>(), problems)
        }
        assertTrue(typedNodes > 30) // sanity: the corpus actually parsed
    }

    @Test
    fun hypertextGoldenConformsToNodeSchema() {
        var nodes = 0
        for (line in goldenLines("test/hypertext.golden")) {
            val arr = JSONArray(line)
            nodes += arr.length()
            val problems = mutableListOf<String>()
            validateNode(arr, "line", problems)
            assertEquals("$line -> $problems", emptyList<String>(), problems)
        }
        assertTrue(nodes > 8)
    }

    // ── NdjsonFrameCodec corpus replay ───────────────────────────────────

    @Test
    fun codecRereadsGoldenCorpusAsByteStream() {
        val frames = goldenLines("test/frames.golden").map {
            val obj = JSONObject(it)
            Frame(kind = obj.getString("kind"), payload = obj.getJSONObject("payload"))
        }
        // Interleave blank keep-alive lines: the codec must skip them.
        val stream = frames.joinToString("\n\n", postfix = "\n") { it.toString() }
        val codec = NdjsonFrameCodec(
            ByteArrayInputStream(stream.toByteArray(Charsets.UTF_8)),
            ByteArrayOutputStream(),
        )
        val read = generateSequence { codec.read() }.toList()
        assertEquals(frames.size, read.size)
        for ((sent, received) in frames.zip(read)) {
            assertEquals(sent.kind, received.kind)
            assertEquals(canonical(sent.payload), canonical(received.payload))
        }
        // And the write side emits exactly one line per frame.
        val out = ByteArrayOutputStream()
        val writer = NdjsonFrameCodec(ByteArrayInputStream(ByteArray(0)), out)
        frames.forEach(writer::write)
        val written = out.toString(Charsets.UTF_8.name()).trim().lines()
        assertEquals(frames.size, written.size)
    }

    // ── Seeded corruptions: the validators bite ──────────────────────────

    @Test
    fun seededCorruptionsFail() {
        // A renamed required payload key on a real golden line.
        val line = JSONObject(goldenLines("test/frames.golden").first())
        val payload = line.getJSONObject("payload")
        payload.put("triggerz", payload.remove("triggers"))
        val p1 = mutableListOf<String>()
        validatePayload(line.getString("kind"), payload, p1)
        assertTrue(p1.isNotEmpty())

        // An unknown frame kind.
        val p2 = mutableListOf<String>()
        validatePayload("flisbo.kind", JSONObject(), p2)
        assertTrue(p2.isNotEmpty())

        // An unknown node type, a missing required key, an unknown node key.
        val p3 = mutableListOf<String>()
        validateNode(JSONObject("""{"t":"flisbo"}"""), "seed", p3)
        assertTrue(p3.isNotEmpty())
        val p4 = mutableListOf<String>()
        validateNode(JSONObject("""{"t":"text"}"""), "seed", p4)
        assertTrue(p4.isNotEmpty())
        val p5 = mutableListOf<String>()
        validateNode(JSONObject("""{"t":"text","text":"hi","flisbo":1}"""), "seed", p5)
        assertTrue(p5.isNotEmpty())

        // A malformed embedded action (both discriminators).
        val p6 = mutableListOf<String>()
        validateAction(JSONObject("""{"action":"a.b","builtin":"clipboard.copy"}"""), "seed", p6)
        assertTrue(p6.isNotEmpty())
    }
}
