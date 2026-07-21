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
 * Conformance leg A of the spec kit, on the EBP 2 wire: the Kotlin side
 * replays the committed golden corpus against `ebp/contract.json`
 * (contract_format 5, in the ebp protocol submodule) — the same artifact
 * the ERT suite generates and validates — so the contract is
 * machine-checked by two independent implementations.
 *
 * Legs:
 *  - `ebp/goldens/frames.golden`: every line parses via [Rpc.parse] into
 *    a request or notification, names a `methods`-registered method sent
 *    in the client direction, matches its registered request/notification
 *    class (requests carry ids, notifications never), and its params keys
 *    satisfy the method's required/optional sets; each message
 *    round-trips through [ContentLengthFrameCodec].
 *  - `ebp/goldens/widgets.golden` and `hypertext.golden`: every typed node
 *    validates against `node_schema` (type known, required keys present,
 *    no key outside the schema) and every embedded action against the
 *    discriminated `action_schema`.
 *  - Seeded corruptions fail, so the validators demonstrably bite.
 *
 * Deliberately no `main/` changes: this test consumes only public wire
 * types ([Rpc], [Method], [ContentLengthFrameCodec], [SDUI_NODE_TYPES])
 * plus repo files, discovered with the directory-walk idiom of
 * [SduiRendererNodeTypesTest].
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
        JSONObject(repoFile("ebp/contract.json").readText())
    }

    // ── Schema accessors over contract.json (format 5) ───────────────────

    private fun names(arr: JSONArray): Set<String> =
        (0 until arr.length()).map { arr.getString(it) }.toSet()

    private val nodeTypes: Set<String> by lazy { names(contract.getJSONArray("node_types")) }
    private val nodeSchema: JSONObject by lazy { contract.getJSONObject("node_schema") }
    private val methods: JSONObject by lazy { contract.getJSONObject("methods") }
    private val errorCodes: JSONObject by lazy { contract.getJSONObject("error_codes") }
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

    /** Validate a message's params keys against the method table. */
    private fun validateParams(method: String, params: JSONObject, problems: MutableList<String>) {
        val entry = methods.optJSONObject(method)
        if (entry == null) {
            problems += "unknown method `$method`"
            return
        }
        if (entry.optString("params") == "node") {
            validateNode(params, method, problems)
            return
        }
        val row = entry.getJSONObject("params")
        val required = names(row.getJSONArray("required"))
        val optional = names(row.getJSONArray("optional"))
        for (req in required) {
            if (!params.has(req)) problems += "$method: missing required `$req`"
        }
        for (key in params.keys()) {
            if (key !in required && key !in optional) {
                problems += "$method: unknown params key `$key`"
            }
        }
    }

    // ── The contract artifact itself ─────────────────────────────────────

    @Test
    fun contractIsFormatFiveAndCoherent() {
        assertEquals(5, contract.getInt("contract_format"))
        assertEquals(JETPACS_PROTOCOL_VERSION, contract.getInt("protocol_version"))
        assertTrue(contract.getString("spec_version").isNotEmpty())
        // Build-wiring witness: SDUI_NODE_TYPES is generated from this same
        // contract, so inequality here means a stale generated file, not a
        // hand-copy drifting (there is no hand copy left to drift).
        assertEquals(SDUI_NODE_TYPES.toSortedSet(), nodeTypes.toSortedSet())
        // Build-wiring witness: Method is generated from this same contract's
        // `methods` table, so a mismatch here means a stale generated file,
        // not a hand table drifting.
        val registered = methods.keys().asSequence().toSet()
        val all = Method.REQUESTS + Method.CLIENT_NOTIFICATIONS + Method.COMPANION_SENDS
        for (m in all) {
            assertTrue("Method `$m` missing from contract methods", m in registered)
            val declaredType = methods.getJSONObject(m).getString("type")
            val expected = if (m in Method.REQUESTS) "request" else "notification"
            assertEquals("Method `$m` class drifted", expected, declaredType)
        }
        // Every request method declares a result schema; notifications none.
        for (m in registered) {
            val entry = methods.getJSONObject(m)
            assertEquals("`$m` result presence vs type",
                entry.getString("type") == "request", entry.has("result"))
        }
        // The codes the companion's emission sites actually use, present in
        // the vocabulary (EbpError is generated from it, so this doubles as
        // the build-wiring witness for the error leg).
        for (code in listOf(
                EbpError.PARSE_ERROR, EbpError.INVALID_REQUEST, EbpError.METHOD_NOT_FOUND,
                EbpError.CAP_UNSUPPORTED, EbpError.CAP_PERMISSION, EbpError.CAP_FAILED,
                EbpError.TRIGGERS_REJECTED, EbpError.NOT_AUTHENTICATED,
                EbpError.SPEC_INVALID, EbpError.PROTO_VERSION, EbpError.AUTH_FAILED,
                EbpError.REQUEST_CANCELLED, EbpError.FRAME_TOO_LARGE, EbpError.OVERLOADED,
        )) {
            assertTrue("error code $code missing from error_codes",
                errorCodes.has(code.toString()))
        }
    }

    // ── frames.golden ────────────────────────────────────────────────────

    @Test
    fun framesGoldenConformsToMethodSchema() {
        val lines = goldenLines("ebp/goldens/frames.golden")
        assertTrue(lines.isNotEmpty())
        for (line in lines) {
            val msg = Rpc.parse(line)
            val (method, params, hasId) = when (msg) {
                is RpcRequest -> Triple(msg.method, msg.params, true)
                is RpcNotification -> Triple(msg.method, msg.params, false)
                else -> { assertTrue("$line -> not a request/notification", false); return }
            }
            val entry = methods.optJSONObject(method)
            assertTrue("method `$method` not in contract", entry != null)
            // The frame corpus is client-emitted (elisp is the sender)…
            assertTrue(entry!!.getString("direction") in setOf("client", "both"))
            // …and each line's id-ness matches its registered class.
            assertEquals("$line -> id vs class",
                entry.getString("type") == "request", hasId)
            val problems = mutableListOf<String>()
            validateParams(method, params, problems)
            assertEquals("$line -> $problems", emptyList<String>(), problems)
        }
    }

    @Test
    fun framesGoldenRoundTripsThroughCodec() {
        for (line in goldenLines("ebp/goldens/frames.golden")) {
            val obj = JSONObject(line)
            val out = ByteArrayOutputStream()
            ContentLengthFrameCodec(ByteArrayInputStream(ByteArray(0)), out).write(obj)
            val wire = out.toByteArray()
            val header = String(wire.takeWhile { it != '{'.code.toByte() }.toByteArray())
            assertTrue("missing Content-Length header", header.startsWith("Content-Length: "))
            val received = ContentLengthFrameCodec(ByteArrayInputStream(wire), ByteArrayOutputStream()).read()
            val (method, params) = when (received) {
                is RpcRequest -> received.method to received.params
                is RpcNotification -> received.method to received.params
                else -> { assertTrue("did not round-trip: $received", false); return }
            }
            assertEquals(obj.getString("method"), method)
            assertEquals("params drifted through the wire round-trip",
                canonical(obj.getJSONObject("params")), canonical(params))
        }
    }

    // ── widgets.golden / hypertext.golden ────────────────────────────────

    @Test
    fun widgetsGoldenConformsToNodeSchema() {
        var typedNodes = 0
        for (line in goldenLines("ebp/goldens/widgets.golden")) {
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
        for (line in goldenLines("ebp/goldens/hypertext.golden")) {
            val arr = JSONArray(line)
            nodes += arr.length()
            val problems = mutableListOf<String>()
            validateNode(arr, "line", problems)
            assertEquals("$line -> $problems", emptyList<String>(), problems)
        }
        assertTrue(nodes > 8)
    }

    // ── ContentLengthFrameCodec corpus replay ────────────────────────────

    @Test
    fun codecReplaysGoldenCorpusAsOneByteStream() {
        val messages = goldenLines("ebp/goldens/frames.golden").map { JSONObject(it) }
        val out = ByteArrayOutputStream()
        val writer = ContentLengthFrameCodec(ByteArrayInputStream(ByteArray(0)), out)
        messages.forEach(writer::write)
        val reader = ContentLengthFrameCodec(
            ByteArrayInputStream(out.toByteArray()), ByteArrayOutputStream())
        val read = generateSequence { reader.read() }.toList()
        assertEquals(messages.size, read.size)
        for ((sent, received) in messages.zip(read)) {
            val params = when (received) {
                is RpcRequest -> received.params
                is RpcNotification -> received.params
                else -> { assertTrue("unexpected: $received", false); return }
            }
            assertEquals(canonical(sent.getJSONObject("params")), canonical(params))
        }
    }

    // ── Seeded corruptions: the validators bite ──────────────────────────

    @Test
    fun seededCorruptionsFail() {
        // A renamed required params key on a real golden line.
        val line = JSONObject(goldenLines("ebp/goldens/frames.golden").first())
        val params = line.getJSONObject("params")
        params.put("triggerz", params.remove("triggers"))
        val p1 = mutableListOf<String>()
        validateParams(line.getString("method"), params, p1)
        assertTrue(p1.isNotEmpty())

        // An unknown method.
        val p2 = mutableListOf<String>()
        validateParams("flisbo.method", JSONObject(), p2)
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

        // The envelope parser refuses batches, junk, and versionless frames.
        assertTrue(Rpc.parse("[]") is RpcMalformed)
        assertTrue(Rpc.parse("not json") is RpcMalformed)
        assertTrue(Rpc.parse("""{"method":"x.y","params":{}}""") is RpcMalformed)
        assertTrue(
            Rpc.parse("""{"jsonrpc":"2.0","id":true,"method":"x.y","params":{}}""")
                is RpcMalformed)
    }
}
