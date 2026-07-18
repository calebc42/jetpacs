# Conversion kit: the ebp wire on JSON-RPC 2.0

**Status: Claude-authored reference sketch for the hand rebuild. Not code, not
spec.** This kit maps every wire kind of the old envelope onto JSON-RPC 2.0 so
the owner can hand-write the new envelope layer and spec prose from it. Sketch
policy: tables, shapes, and described exercises — no finished implementations.

**Verification note:** JSON-RPC 2.0 facts are against the frozen 2010 spec
(jsonrpc.org). `jsonrpc.el` facts were verified 2026-07-18 against the
library source, **v1.0.29** (`:N` line references below cite that file). The
formerly ✓-marked items are confirmed except where the text now says
otherwise — three original claims were wrong and are corrected in place
(§1 stack note, §3 first paragraph, §4 items 1–2). The manual node stays the
learning companion: `C-h i m elisp RET m jsonrpc RET`.

## 1. Governing decision and the layer stack

Decision log #2: the wire speaks JSON-RPC 2.0 — requests (carry `id`, answered
exactly once), notifications (no `id`, never answered), standard error objects.
Framing: `Content-Length` headers, so the Emacs side uses core `jsonrpc.el`
unmodified — for transport, framing, and id bookkeeping; the one caveat
(Emacs-outbound error `data`, §3) uses a supported subclass seam, not a fork.
Kept from ebp as conventions: dot-namespaced method names, the per-method
direction table in the contract, readable string codes inside `error.data`,
and the forward-compat rule (unknown method → method-not-found error / logged
drop — implemented in *your* dispatchers, §3–§4; what the library gives you is
only that the connection survives a handler error).

```
your vocabulary     methods, payload schemas, direction rules, handshake,
 (hand-written)     surfaces, queue, editor sync, capabilities, triggers
─────────────────────────────────────────────────────────────────────────
message shape       JSON-RPC 2.0 (rented spec)
─────────────────────────────────────────────────────────────────────────
framing             Content-Length: N \r\n \r\n {json}   (rented convention)
─────────────────────────────────────────────────────────────────────────
transport           loopback TCP (v0) → Unix domain socket (1.0 target)
```

JSON-RPC shapes for reference:

```json
request       {"jsonrpc":"2.0", "id": 7, "method": "capability.invoke", "params": {...}}
notification  {"jsonrpc":"2.0", "method": "surface.update", "params": {...}}
result        {"jsonrpc":"2.0", "id": 7, "result": {...}}
error         {"jsonrpc":"2.0", "id": 7, "error": {"code": -32601, "message": "...", "data": {...}}}
```

## 2. The complete kind mapping (all 29 old kinds accounted for)

Direction column: C→ = client(Emacs) sends, K→ = companion sends.

### 2.1 Dissolved kinds (7) — they stop existing as methods

| old kind | fate |
|---|---|
| `ack` | gone — a request is answered by its response; a notification is never answered. The old "may be answered with a bare ack" ambiguity ceases to exist. |
| `auth.challenge` | becomes the **response** to `session.hello` |
| `session.welcome` | becomes the **response** to `auth.response` |
| `capability.result` | becomes the **response** to `capability.invoke` (the dead `ok:false` state disappears — failures are error objects) |
| `queue.drained` | becomes the **response** to `queue.replay` (`duplicate_request` folds into it) |
| `completions.show` | becomes the **response** to `edit.complete` *if* editor-sync legs are promoted to methods (recommended — see 2.4); its hand-rolled `request_id` dies |
| `error` | becomes JSON-RPC error objects on requests. Open decision 5.3 covers unsolicited errors. |

### 2.2 Requests (expect exactly one answer)

| method | dir | params → result |
|---|---|---|
| `session.hello` | C→ | `{protocol, client, wants, features?}` → `{nonce}` (the challenge) |
| `auth.response` | C→ | `{nonce, mac}` → the welcome `{server_proof, granted, node_types, surfaces, queued_events, protocol?, server?, device?}`. **Fail-closed dispatcher rule (normative): until this exchange succeeds, every other method is refused.** |
| `capability.invoke` | C→ | `{cap, args?}` → `{result?}`; failures = typed errors (§3) |
| `queue.replay` | C→ | `{}` → `{delivered, expired, duplicate_request?}` |
| `dialog.show` | C→ | the node-tree payload (the one special-schema kind) → **the user's answer** — this dissolves the old spec's never-specified `prompt.reply`, and stacked prompts become multiple outstanding requests: the no-nesting defect dies structurally |
| `triggers.set` | C→ | `{triggers}` → acceptance `{}`; wholesale rejection = typed error (fixes the old codeless rejection) |
| `reminders.set` | C→ | `{reminders, owner?}` → `{}` — promoted to request so set acceptance is typed (was fire-and-forget) |

### 2.3 Notifications (fire-and-forget, no id)

| method | dir | notes |
|---|---|---|
| `surface.update` | C→ | stays a notification on purpose: revision-guarded idempotence is the application-level answer; a per-push ack would add chatter for nothing |
| `surface.remove` | C→ | (log the old defect: still unversioned — your spec decides) |
| `event.action` | K→ | taps, `trigger.fired`, `view.switched` — all still payloads of this one method, not methods themselves |
| `state.changed` | K→ | (old defect stands for your spec: no surface context on it) |
| `theme.set`, `toast.show` | C→ | |
| `pie_menu.show`, `pie_menu.dismiss` | C→ | schema still owed by the spec |
| `dialog.dismiss` | C→ | reinterpreted: **cancellation of the outstanding `dialog.show` request**. JSON-RPC has no standard cancel; LSP's `$/cancelRequest` notification is the precedent to copy. |
| `diagnostics.show`, `eldoc.show`, `fontify.show` | C→ | seq-stamped annotation pushes; `fontify.show`'s `runs` shape is still owed by the spec |
| `edit.resync` | C→ | as a notification — but see open decision 5.1 (request variant is better) |
| `ping` / `pong` | — | **recommend: drop both.** No written semantics existed. If liveness matters, a trivial `ping` request (`{} → {}`) is self-correlating; transport keepalive is the alternative. |

### 2.4 Recommended promotion: editor-sync legs become methods

Old §8 rode companion→client legs as `event.action` payloads (`edit.open`,
`edit.delta`, `edit.caret`, `edit.close`, `edit.complete`). Recommendation:
promote all five to first-class methods (K→ notifications, except
`edit.complete` K→ **request** → completions as its response). Why: they're a
protocol, not user intents; promoting gives `edit.complete` real correlation
and lets `edit.resync` (C→) become a request whose response **is the reseed**
(fresh full text) — the "swallow deltas until reseed" window becomes simply
"while my request is outstanding." Cost: they leave the §5 allowlist's single
door; your spec must give methods the same registered-handler discipline.

## 3. Error objects

JSON-RPC reserves `-32768..-32000` (notably `-32601` method-not-found — the
new face of "unknown kind: log and continue"). **Correction (source-verified):
`jsonrpc.el` does NOT answer `-32601` for you** — the code appears nowhere in
the library. Both default dispatchers are `#'ignore` (:57-66), so an unhandled
request returns a success-shaped `null` result (:344-346) — fail-*open* — and
notifications are all handed to your dispatcher with no known/unknown
distinction (:366). Your request dispatcher hand-rolls `-32601` for unknown
methods and your notification dispatcher logs-and-drops unknowns; neither is
free. Application codes live outside the reserved range; keep the readable
string codes as data:

```json
{"code": 1001, "message": "capability not supported",
 "data": {"kind": "cap-unsupported"}}
{"code": 1002, "message": "permission required",
 "data": {"kind": "cap-permission", "perm": "notification_policy",
          "settings": {"panel": "..."}}}
{"code": 1003, "message": "device action failed", "data": {"kind": "cap-failed"}}
{"code": 1101, "message": "trigger set rejected",
 "data": {"kind": "triggers-unknown-type", "type": "wifi.ssid"}}
```

The `cap-permission` error keeps its best feature: the remedy rides in `data`
(`settings` passes straight back to `capability.invoke {cap: "settings.open"}`).
Recommendation carried over from the walk: extend typed errors spec-wide —
revision rejection and set rejection get codes too.

**Caveat — Emacs-outbound error `data` (source-verified).** Every example
above is *companion*-emitted (Kotlin side) and unaffected, and inbound
`error.data` reaches Emacs intact (:486-491). But when an *Emacs* handler
signals `jsonrpc-error`, the library's reply path emits only `:code` and
`:message` — `:data` is stripped in the dispatch loop before any overridable
generic runs (:347-358). Under this kit that bites only `edit.complete`
responses (§2.4) and direction-enforcement errors (§5.5). If those ever need
typed `data`: stash it handler-side (a dynamic variable or connection slot is
safe — the reply is emitted synchronously within the dispatch extent) and
re-attach it in a `jsonrpc-convert-to-endpoint` override (:170-188) — a
supported subclass seam, not a fork. Two code landmines while here: never use
code `32000` (a jsonrpc.el sentinel meaning "no error" — it transmutes your
error into a *result*, :352-355), and `-1` is the library's own local "Server
died". Courtesy toward the wider ecosystem: also stay outside LSP's reserved
`-32899..-32800` (RequestFailed `-32803`, ContentModified `-32801`,
RequestCancelled `-32800`). The kit's `1001+` codes are clean on all counts.

## 4. `jsonrpc.el` learning ladder

Concepts, in learning order (each maps to a manual section ✓):

1. **The connection object** — `jsonrpc-process-connection`, wrapping an Emacs
   process (a `make-network-process` TCP stream works). You supply two
   functions — a request dispatcher and a notification dispatcher — and each
   *is* the handler, not a router: called `(CONN METHOD PARAMS)` with the
   method as an interned symbol and the params as a plist, it returns the
   result directly or signals `jsonrpc-error` (:345-346, :366). Your
   fail-closed rule and your allowlist both live in these two dispatchers —
   and they must, because the defaults are `#'ignore`: an unhandled request
   silently returns a success-shaped `null` (:344-346), which is fail-*open*.
   Until the handshake succeeds, explicitly signal a typed error for every
   method; hand-roll `-32601` for unknown ones (§3).
2. **Sending** — `jsonrpc-notify` (fire-and-forget), `jsonrpc-request`
   (blocks; `:timeout`, default 10 s, :550-555; `:deferred` holds the send
   until `jsonrpc-connection-ready-p` returns non-nil — the default method
   always says ready, so deferral works only once you specialize it to mean
   "handshake done", and pending sends are re-tried after each inbound
   message: polled, not signalled, :158-167, :984-1004),
   `jsonrpc-async-request` (`:success-fn` / `:error-fn` / `:timeout-fn`).
3. **The events buffer** — every frame in/out, timestamped, human-readable.
   This replaces the old NDJSON "debug with netcat" story and is the single
   biggest quality-of-life win of renting.
4. **Framing** (companion side, any language, ~10 lines of logic): read header
   lines until a blank line; parse `Content-Length: N`; read exactly N bytes;
   parse JSON; repeat. Writing is the mirror: serialize, measure byte length,
   emit header + blank line + body.

Exercise sequence (described, not implemented — these are the hand-rebuild's
first katas):

1. Read the JSONRPC manual node end to end once.
2. **Echo:** one Emacs listens (`make-network-process :server t` on loopback,
   wrapping each accepted connection in a `jsonrpc-process-connection`), a
   second Emacs dials and calls method `echo`. Success = the events buffers on
   both sides showing the four frames.
3. **Feel the framing:** connect with a terminal client and type one request
   by hand, counting bytes for the header. (The point is to never fear the
   framing again.)
4. **Hello/challenge:** implement the two handshake request/response pairs
   with a dispatcher that refuses everything else until proof — your first
   real spec section, running.

## 5. Open decisions (yours, flagged)

1. **`edit.resync` as request** with the reseed as its response (recommended,
   see 2.4) vs. keeping the old notification + `edit.open` dance.
2. **Envelope id lifetime** — `jsonrpc.el` manages ids per connection
   (confirmed: :97-100, first id 1 at :968), and the library already makes
   outstanding requests die with the connection — every pending continuation
   receives error `-1 "Server died"` when the process ends (:760-785). Your
   spec should still state the rule (the old spec never did).
3. **Unsolicited errors** — with `error` dissolved into responses, does the
   companion ever need to report a fault outside any request? If yes, define
   a `log.error` notification; do not resurrect a bare error frame.
4. **JSON-RPC batch arrays** — the 2.0 spec allows them; recommend your spec
   prohibits them (one frame, one message — batching complicates the
   dispatcher for zero need on a local socket).
5. **Direction enforcement** — the contract's per-method direction table is a
   convention JSON-RPC doesn't know; your dispatchers enforce it (a client
   receiving a client-only method = protocol error). Say so normatively.

## 6. Bookkeeping the rewrite inherits (unchanged decisions)

Revision-guarded surfaces, the offline queue's policy vocabulary, capability
negotiation by presence, `node_types` positive knowledge, the weak-language
invariant, HMAC pairing (now as two request/response pairs) — none of these
are touched by the envelope swap. That's the point of the layer stack: the
constitution above the envelope survives the envelope's replacement intact.
