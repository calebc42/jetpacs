# Harvest: what Phoenix LiveView teaches the ebp rebuild

**Status: Claude-authored reference sketch for the hand rebuild. Not code, not
spec — the owner's spec and implementation supersede this document wherever
they diverge.** Sketch policy: tables, wire shapes, and posed decisions; no
finished implementations. Old-PoC citations are `@HEAD` — the pre-fork tree at
`6795e5a`, kept for archaeology, not for copying.

**Sources & verification note.** Every LiveView fact below was read this
session from the source checkout at `C:\Users\caleb\phoenix_live_view`
(commit `fea0306b`, six commits past the v1.2.7 tag) — cited as `file:line`
under that root. Every ebp
fact is from `SPEC.md` / `contract.json` at ebp commit `99d2895`. Nothing in
this document is from memory of LiveView's documentation; where a judgment is
mine rather than a sourced fact, it is phrased as a recommendation or a
question.

**Why LiveView.** Phoenix LiveView is a decade-old, heavily deployed answer to
the same bet ebp makes: state lives on the server, the client is a thin
renderer over a persistent socket, and user interactions travel as small
semantic events rather than as code. It is the closest thing this architecture
has to a production-hardened older sibling. The harvest sorts into: things ebp
already independently converged on (§1 — take the confidence), four things
worth taking now (§3–§6), two things to file behind the measurement gate
(§7), and a warning about what must not transfer (§8).

**Two ground rules before any take:**

1. **Every take below amends a frozen section.** §§4–6 of the SPEC are frozen
   at 1.0-rc; changing them is an amendment, and every amendment lands in the
   same commit as a SPEC-CHANGES.md entry (SPEC.md:20-33). Each take therefore
   ends with the one-line changelog entry it would need. Writing that line is
   part of the hand-rebuild discipline, not paperwork.
2. **These shapes are envelope-agnostic.** They are quoted against the 1.0-rc
   NDJSON kinds (`surface.update`, `event.action`, …) because that is what
   SPEC.md documents, but all four takes are payload-level. They re-home
   unchanged onto the JSON-RPC 2.0 envelope the rebuild chose (decision #2;
   see `JSONRPC-conversion-kit.md` §1) — a `surface.update` notification
   carries the same params either way.

---

## 1. Convergences — take the confidence, adopt nothing

Walking LiveView's client vocabulary next to the SPEC is almost eerie. None of
these rows needs importing; together they are the strongest external evidence
yet that the architecture's core shape is sound. When a critic asks "can a
server-authoritative thin client work in production," LiveView is the
citation.

| LiveView | ebp | Where |
|---|---|---|
| Semantic events with author-attached values: `phx-click` + `phx-value-*` attributes collected into the payload (`assets/js/phoenix_live_view/view.ts:1641-1675`) | Actions as names + plain-data `args`, validated by an allowlisted handler | SPEC §5:206-214 |
| Keyed list reconciliation: `:key` on comprehensions for identity across updates | `lazy_column` child `key` — reconciliation identity preserving state, scroll, animation | SPEC §9:439-444 |
| Numbered in-flight refs; an old ack can never clear a newer event (`element_ref.ts:96-103`) | Monotonic per-client surface revisions; a non-newer revision is rejected | SPEC §4:162-166 |
| Named client extension hooks, registered client-side, unique-id enforced (`view.ts:950-997`) | Host-registered native toolbars — the companion registers by name, the wire carries only the name | SPEC §9 "Editor toolbars" |
| `live_patch` navigation without remount | Multi-view surfaces + companion-local `view.switch` — navigation never round-trips | SPEC §4:167-172 |
| Crash recovery: client shows a degraded treatment and rejoins | The companion persists and renders the latest spec while Emacs is disconnected (the reference client's reconnect backoff is client policy, not SPEC text) | SPEC §4:165-166 |
| Form recovery: on rejoin the client re-sends each form's current values as its change event (`view.ts:2282-2311`; opt-out `phx-auto-recover="ignore"`) | `state.changed` mirroring + §6 queue replay — **but see below** | SPEC §5:239-242, §6 |

**The last row earns its place as a discovered gap, not trivia.** §6 queues
and replays *only* `event.action` frames (SPEC.md:252-265). The spec is silent
on whether `state.changed` mirroring survives an offline gap: text typed into
a `text_input` while Emacs is dead updates the companion's UI state, but if no
queued action ever carries it (via `fields` or a submit), does the client's
UI-state store ever learn of it after reconnect? LiveView answers "yes,
automatically, per form, with an opt-out." Your rebuilt spec should answer the
question deliberately — even if the answer is "typed-but-never-dispatched text
is ephemeral by design." An open item for your §5/§6 equivalents.
*(Resolved 2026-07-18: ebp amendment #16 — the welcome's `input_state`
snapshot, absorb→push→replay.)*

---

## 2. Before the takes: three kinds of wire field

Every field proposed below should pass through one test first, because the
SPEC's additive-evolution story is not one rule but three, depending on what
ignoring the field does to an old companion:

- **Cosmetic** — ignoring it loses polish, nothing else. The SPEC's own
  template: `badge` is "cosmetic, never load-bearing, silently ignored by
  older companions" (SPEC.md:529-532). Cosmetic fields are safely additive.
- **QoS** — ignoring it changes *rates or timing*, never *what happens*.
  Also safely additive, but worth naming as its own class because the safety
  argument is different: every frame is still honest, just differently paced.
- **Constraining** — an old companion that ignores it **over-acts**: it does
  something the author's field was meant to prevent. The SPEC's template is
  the §11 `when`-strip law: a client must never strip an unsupported `when`
  gate and push the rest, because "notify below 20%" would silently become
  "notify always" (SPEC.md:754-762). Constraining fields are *not* safely
  additive — they need a catalog to gate on and a skip-the-whole-thing rule.

Each take below is a worked example of applying this test. One discovered
asymmetry to fix while you are here: §9's unknown-key tolerance ("unknown keys
must be ignored", SPEC.md:394-395) is written for **node** keys. Nothing in
the SPEC says unknown keys on an **action object** are ignored — `confirm`
(1.23.0) relied on that behavior as folklore, and take 1 would too. The rule
should be written down; take 1 carries it. *(Resolved 2026-07-18: ebp
amendment #14 writes the tolerance rule plus the constraining-fields law.)*

---

## 3. Take 1 — declarative pending presentation (`pending_label`, `pending_disable`)

**The gap.** Between the user's tap and the next photograph arriving, the SPEC
has nothing: the tapped control sits inert, looking as if the tap didn't
register. LiveView solved this declaratively — the element itself declares its
pending look.

**What LiveView actually does (verified).** An element may carry
`phx-disable-with="Saving..."`. When its event goes in flight, the client
stashes the original text in `data-phx-disable-with-restore`, swaps in the
pending text (only if non-empty), stashes the prior disabled state, and sets
`disabled` (`view.ts:1427-1520`, the apply at :1476-1491). On form submit,
inputs additionally become `readonly` (`view.ts:1951-2002`). Every affected
element also gets a per-event-type class — `phx-click-loading`,
`phx-submit-loading`, … (`constants.ts:6-15`) — for CSS styling. Three
semantics worth copying exactly:

- **Restore happens on server acknowledgement, not on error**
  (`element_ref.ts:133-180`): the pending look honestly persists until the
  server has actually processed the event.
- **In-flight refs are numbered**, so an older ack can never prematurely clear
  a newer pending state (`element_ref.ts:96-103, 191-196`).
- **An element awaiting an ack ignores further taps**
  (`live_socket.ts:1279-1282`) — pending is also double-submit prevention.

**The steal — proposed shape.** Two optional keys on the §5 action object,
beside `when_offline` / `dedupe` / `ttl_s` / `confirm`:

```json
{"action": "heading.todo-set", "args": {...},
 "when_offline": "queue",
 "pending_label": "Saving…",
 "pending_disable": true}
```

Companion behavior sketch: on dispatch, the control rendering this action
swaps its label to `pending_label` (if present) and, if `pending_disable`,
stops dispatching further taps. The pending state clears when a
`surface.update` with a **newer revision** for the containing surface arrives
— ebp's equivalent of LiveView's ack, since the server's response to an action
*is* the next photograph. While the event sits in the offline queue, "pending"
is honest — arguably the most truthful UI the disconnected state can show.
Both fields are author-side policy: like the existing quartet, the companion
consumes them and never echoes them in `event.action` — they join the
enumeration at SPEC.md:200-204.

**The classification test — posed, not resolved.** `pending_label` is
cosmetic, full stop. `pending_disable` is the honest fork of this take:

- Read as *presentation* ("grey it while we wait"), it is cosmetic; ignoring
  it costs polish. Correctness then rests where it already rests today:
  `dedupe` collapsing repeat taps in the queue, idempotent handlers, and
  `revision_seen` letting the client discount stale interactions.
- Read as *double-submit prevention* (LiveView's reading — the ref no-op is a
  correctness mechanism), it is **constraining**: an old companion that
  ignores it happily dispatches the duplicate taps the author meant to
  suppress. And unlike nodes, there is no catalog to gate on — `node_types`
  covers `t` discriminators (SPEC.md:100-109), not action-object fields.

**Decisions this take needs from you:**

1. The fork above: is `pending_disable` cosmetic-with-correctness-delegated,
   or constraining-and-needs-negotiation? (If constraining: what channel? A
   welcome field? A capability name? This is the same question take 4 hits.)
2. **Placement: action-side or node-side?** LiveView puts the attribute on the
   *element*. An action-side field is uniform but under-defined for actions on
   a `box`, a `table` cell, a `rich_text` tap link, a card swipe, or a
   notification `meta.actions` button — what does "swap the label" mean there?
   A node-side attribute (the `badge` precedent) is LiveView-faithful and only
   meaningful where it is defined. Pick one and say what the other contexts do.
3. **What clears pending when no photograph will ever come?** A drop-policy
   action with Emacs dead; a queued event that expires via queue `ttl_s`; an
   action that never mutates its own surface (e.g. it only posts a
   notification). Timeout fallback? LiveView deliberately does *not* clear on
   error — adopt that honesty or soften it?
4. **Interaction with `confirm`:** does pending start at tap, or only after
   the native dialog is accepted? (Declining is a clean no-op — the control
   must not be left stuck pending.)
5. On `builtin` objects (`view.switch` — no round trip at all): are
   `pending_*` ignored, or a client-side lint error?
6. Scope of the pending state: per control instance, per action name, per
   surface? (LiveView: per element, per event ref.)
7. Where the missing tolerance rule lands: "a companion ignores unknown keys
   on an action object and never echoes them" — one sentence in §5, written
   at the same time as this amendment, so the next `confirm`-shaped addition
   stands on contract instead of folklore.

**Changelog line it needs:** `§5: action objects gain pending_label /
pending_disable (author-side pending presentation; consumed, never echoed);
unknown-action-object-key tolerance made normative.`

---

## 4. Take 2 — `debounce_ms` (the worked example of a safe QoS field)

**The gap.** The PoC hardcodes input rate policy in the companion: 250 ms
between a keystroke and the `state.changed` broadcast (`@HEAD`
SduiInputNodes.kt:169, and :412 for the editor pipeline), 300 ms for the
completion strip (:648). The author of the control can neither see nor tune
the number that governs how their UI feels.

**What LiveView actually does (verified).** Rate policy lives in the markup,
per input: `phx-debounce` / `phx-throttle` (`dom.ts:322-420`). The exact
semantics are worth copying because they hide two subtleties:

- Attribute **absent** → events fire immediately (no hidden default rate).
  Attribute present but empty → default **300 ms** (`constants.ts:107-110`).
  Integer → that many ms. `"blur"` → defer until focus leaves the field.
- **Debounce is trailing-edge** (fire after quiet), **throttle is
  leading-edge** (fire now, then rate-limit). Key *repeats* are throttled but
  *distinct* keys pass immediately (`dom.ts:368-373`).
- **The flush rules are the load-bearing part:** a pending debounced value is
  flushed when the field blurs, and pending timers are reset on form submit so
  a submit never races its own stale change (`dom.ts:394-418`). Debounce
  without flush-on-commit loses the user's final keystrokes; LiveView never
  does.

**The steal — proposed shape.** One optional key on `text_input` (and
`editor`), squarely a *node* key and therefore already covered by §9's
unknown-key rule — this take sits on firm normative ground:

```json
{"t": "text_input", "id": "note-title", "value": "...",
 "debounce_ms": 500,
 "on_change": {"action": "note.title-set"}}
```

Absent → the companion's default (today 250). The companion flushes a pending
value whenever the field's committing action fires (`on_submit`), mirroring
LiveView's rule.

**Why it is additive-safe — the QoS argument, spelled out.** An old companion
ignoring `debounce_ms` sends `state.changed` at its own hardcoded rate: more
or fewer frames than the author tuned for, but *every frame reports real typed
state*. Mis-tuned, never over-acting. Contrast `pending_disable` in take 1 —
that is the difference between the QoS class and the constraining class, and
this pair is the cleanest teaching example of the test in §2.

One caveat sentence for the spec text: **debounce is never a correctness
mechanism.** An author must not reason "only the final value arrives";
flush-on-commit is the correctness path, debounce only shapes the traffic in
between.

**Decisions this take needs from you:**

1. **Scope — the PoC has three rates; the field must say which it governs.**
   `state.changed` mirroring only? The `on_change` action dispatch too? The §8
   `edit.delta` stream and the completion strip's 300 ms: in or out (out is
   defensible — §8 is its own sub-protocol)?
2. Absent means "companion default, unpinned" or "normatively 250"? (LiveView
   pins 300 for the present-but-empty case; ebp has no present-but-empty
   case, so this collapses to: do you pin the default in the spec or leave it
   companion-tunable?)
3. Flush triggers beyond `on_submit`: focus loss? `on_save` on `editor`?
   `view.switch` away? App backgrounded? Connection drop (so the client's
   mirror is coherent at the moment of disconnect)?
4. Is `0` legal (per-keystroke)? Clamped? (Precedent: `every_s` clamps to
   ≥ 60, SPEC.md:806 — a spec that clamps once can clamp again.)
5. Throttle (leading-edge) is deliberately **not** taken — text inputs want
   trailing-edge. Record the decision, so a future `throttle_ms` arrives as a
   considered addition, not scope creep.

**Changelog line it needs:** `§9: text_input/editor gain debounce_ms (QoS;
absent = companion default; flush on commit).`

---

## 5. Take 3 — `ttl_s` / `stale_spec` get their written meaning

**The gap — this one resolves an open ledger item.** `surface.update` already
carries `ttl_s?` and `stale_spec?` (SPEC.md:158; contract.json:577-578) — ghost
fields, present in the schema with no written semantics. "If it's only in the
schema, it doesn't exist" (decision #2's prose-semantics rule): today these
fields literally do not exist. LiveView hands you the meaning to write.

**What LiveView actually does (verified).** Connection state is a visual,
CSS-addressable fact on the LiveView container: `phx-connected` when live;
`phx-loading` while disconnected; `phx-error` plus `phx-client-error` or
`phx-server-error` on failure (`constants.ts:36-40`, applied in
`view.ts:281-315, 1267-1276`). And one precedent that matters most here:
the disconnected treatment is applied only after a **500 ms grace delay**
(`DISCONNECTED_TIMEOUT`, `constants.ts:99`, used at `view.ts:1278-1282`) — a
socket blip never flashes the UI. That grace delay is a tiny hardcoded `ttl`;
ebp's `ttl_s` is the same idea, author-tunable per surface.

**The steal — proposed semantics (SHOULD-strength).** After the companion has
been disconnected for `ttl_s` seconds, it renders the surface *visibly stale*
— dimmed, marked, styled by the companion's convention — and, if `stale_spec`
is present, renders `stale_spec` in place of the cached `spec`. The ghost
fields become the spec's honesty feature: the pane of glass admitting the
picture is old. Absent `ttl_s` → never marked stale (today's behavior, which
is why an old companion ignoring both fields is already conformant — it just
shows cached-fresh forever).

**The governing line, which makes this take safe:** *staleness is
presentation, never a correctness boundary.* The correctness boundary already
exists — `revision_seen` on `event.action` (SPEC.md:190-196) tells the client
which photograph an interaction was made against, so the client can discount
stale taps. An author must never use `stale_spec` to *remove dangerous
controls*, because an old companion will not render it and will over-act —
that would smuggle a constraining field in through a cosmetic door.

**Decisions this take needs from you:**

1. **When does the clock start** — at disconnect, or at the last
   `surface.update` received? They diverge badly: a connected-but-idle Emacs
   (nothing changed for an hour) must not see its surfaces marked stale under
   the per-update reading. LiveView's model is connection-state, which argues
   for disconnect. But a surface last updated a week ago is arguably stale
   the moment the connection drops. Recommendation to consider:
   disconnect-based, because "connected" *means* "the photograph would have
   been re-taken if anything changed."
2. **What clears it** — the welcome (connection restored), or only a fresh
   `surface.update`? Note: reconnect does not imply a re-push — the §3
   revision snapshot may show the companion already current, so waiting for a
   fresh update could leave a current surface marked stale forever.
3. **Persistence across companion process death:** the stale clock must
   derive from a *persisted* last-connected timestamp, and `ttl_s` +
   `stale_spec` must persist with the cached spec (SPEC.md:165-166), or
   Android killing the app resets every surface to fresh.
4. **Multi-view surfaces:** does `stale_spec` replace the entire
   `{views, initial_view}` structure? If so, `view.switch` targets vanish
   while stale — intended? Or is `stale_spec` per-view?
5. Are actions inside `stale_spec` live (tap → queue as normal)? Presumably
   yes — a stale screen that can still capture a note is the whole point of
   the offline story — but say so.
6. `ttl_s: 0` means "stale the instant we disconnect"? And absent = never
   stale (required for compatibility). Is a small grace floor (LiveView's
   500 ms instinct) worth writing in, so authors can't accidentally make
   every socket blip flash the UI?
7. **The name collision, posed explicitly:** `ttl_s` already means *queue
   expiry* on action objects (SPEC.md:201) and would now also mean *stale
   clock* on `surface.update` (SPEC.md:158). Two meanings, one name, two
   objects. Keep (context disambiguates) or rename (`stale_after_s`?) — your
   call, but make it a decision, not an accident.

**Changelog line it needs:** `§4: ttl_s/stale_spec semantics written —
disconnected-for-ttl_s surfaces render visibly stale, stale_spec replaces
spec; presentation only, revision_seen remains the correctness boundary.`
*(Adopted 2026-07-18: ebp amendment #15 — semantics as drafted, and the
name-collision question (decision 7) resolved by renaming to
`stale_after_s`.)*

---

## 6. Take 4 — a closed effects vocabulary (decision-log material, not a drafted amendment)

**Why this one is the favorite.** LiveView faced exactly the "just one
conditional" pressure ebp's decision #5 anticipates — users wanting client
behavior without round-trips — and answered with exactly decision #5's shape:
a closed, composable vocabulary of client effects encoded as *data*, attached
server-side, and it has **held closed for a decade** under that pressure.

**What LiveView actually does (verified).** `Phoenix.LiveView.JS` is a struct
holding an ordered op list; every builder appends one `[op, args]` pair and
strips nil args (`lib/phoenix_live_view/js.ex:1280-1283`). It serializes into
the HTML attribute as a plain JSON array:

```json
[["push", {"event": "inc", "loading": ".thermo"}],
 ["add_class", {"names": ["warmer"], "to": ".thermo"}]]
```

Exactly **20 ops** exist in this checkout (show, hide, toggle, add_class,
remove_class, toggle_class, transition, set_attr, remove_attr, toggle_attr,
ignore_attrs, focus, focus_first, push_focus, pop_focus, dispatch, exec,
push, patch, navigate). The client dispatches `exec_${kind}` with **no
registry for user-defined ops** (`assets/js/phoenix_live_view/js.js:9-30`) —
the vocabulary is closed; `dispatch`/`exec` are the only sanctioned escape
hatches. Only `push`/`patch`/`navigate` touch the server; everything else is
a pure client effect. Ops run in composition order without awaiting acks
(js.ex:193-207), and unknown *options* are rejected server-side at build time
(`js.ex:1299-1326`) — authoring errors die in authoring, not on the client.

**ebp already owns the embryo — and the doctrine.** The §5 builtins
(`view.switch`, `clipboard.copy`, `jetpacs.settings.open`, SPEC.md:244-250)
are one-op effects. And the house style for a closed effect list is already
written, in §11 `on_fire`: a flat list, executed in order, deliberately
closed — "**no conditionals, no loops** — a rule that needs logic while Emacs
is dead means 'keep Emacs alive', not a rule language in the companion";
unknown entries "logged and skipped, never fatal" (SPEC.md:763-779). `canvas`
ops set the same per-op-skip precedent for draw primitives (SPEC.md:500-503).
A tap-effects vocabulary would be the third instance of a pattern the spec
already trusts, with LiveView as external proof the pattern survives a decade
of user pressure.

**Sketch of the shape (one of two):**

```json
{"action": "note.archive", "args": {"id": 42},
 "effects": [{"op": "focus", "target": "note-search"},
             {"op": "scroll_to", "target": "note-list-top"}]}
```

**The tensions to resolve before this becomes an amendment — which is why it
is decision-log material:**

1. **Structural conflict with `builtin`.** §5 makes `builtin` exclusive-or
   with `action` ("an action object with `builtin` *instead of* `action`",
   SPEC.md:244-245). An `effects` array *beside* `action` quietly breaks that
   clean structure. Two shapes: (a) LiveView's — the dispatch itself becomes
   an op in the list (`{"op": "dispatch"}` plays the role of `JS.push`),
   giving full ordering control but restructuring §5; (b) the sibling array
   above — simpler, but then the order of effects relative to the dispatch
   must be defined by fiat. Does `{builtin: ...}` become sugar for a one-op
   effects list?
2. **Negotiation channel.** New ops need positive-knowledge negotiation like
   everything else. A new welcome field (`effect_ops`, mirroring
   `node_types`)? A §3 capability name? This is the same missing
   action-object-catalog problem take 1 hit — solving it once serves both.
3. **Per-op skip or whole-list drop?** `on_fire` skips unknown entries;
   `triggers.set` rejects whole sets. The test from §2 decides: a purely
   cosmetic op (scroll, focus) can be skipped; an op like *dismiss-dialog* or
   *clear-input* is `pending_disable`-shaped — ignoring it invites re-tap
   duplicates — so a list containing one may need drop-whole-list. Classify
   each op as it is admitted.
4. **Which ops earn admission?** Candidates in current need: focus-field,
   scroll-to, toggle-node-visibility (the collapsible dance), haptic tick.
   Everything else waits for a real need, like `chart`'s closed enum did.
5. **Offline behavior:** effects run at tap time, Emacs-dead-capable (that is
   their point — builtins already work this way), and **never at queue
   replay** — replaying a week-old scroll-to would be absurd.
6. **Named non-transfers:** `JS.dispatch` (dispatch an arbitrary DOM event —
   in ebp terms, an unallowlisted action: §5 breach), `JS.exec` (execute
   commands stored in another attribute — indirection the weak-language
   invariant exists to forbid), and the transition/timing ops (animation is
   the companion's own concern, per the theming philosophy).

**Changelog line, when its day comes:** `§5: action objects gain effects — a
closed, ordered, catalog-negotiated list of companion-local ops; per-op
classification cosmetic/constraining decides skip vs drop.`

---

## 7. Behind the measurement gate

Decision #4 keeps surfaces whole-snapshot and reserves `surface.patch` as a
negotiated capability, gated on devtools *measurement* showing snapshots
actually hurting. LiveView's ten years suggest the gate, when it opens, should
open onto something much smaller than general tree patching.

### 7a. Streams — the right first bite of the delta apple

LiveView's answer to huge collections is *not* tree diffing — it is keyed list
operations. The server API is `stream_insert(socket, name, item, at:, limit:)`
/ `stream_delete` / reset (`lib/phoenix_live_view.ex:1990-2199`); on the wire
a stream rides the diff as:

```
[ref, [[dom_id, at, limit, update_only], ...], [deleted_dom_id, ...]]      + true for reset
```

(`lib/phoenix_live_view/live_stream.ex:79-92`). `at: -1` appends, `0`
prepends, an existing id updates in place; positive `limit` trims the tail,
negative the head. And the load-bearing property: **the server drops the
collection from its own state immediately after render** — an after-render
hook prunes the inserts/deletes every cycle (`lib/phoenix_live_view.ex:
2241-2251`) — so the *client* owns the rendered list and the server pays
neither memory nor diffing for it. That last property is tailor-made for a
brain that must be cheap while asleep.

The ebp translation, if the ledger's "no ceiling on list size" item ever
turns red: keyed-list splice operations over the reconciliation identity §9
*already normativizes* (`lazy_column` child `key`, SPEC.md:439-444) — insert
this child after key X, delete key Y, never re-send the list. Trivially
mergeable, revision-guardable per list, and a far smaller bite than
`surface.patch`'s general tree diffs. **The reserved sentence to hand-write
now, building nothing:** *"A future negotiated capability may add keyed-list
splice operations scoped to a `lazy_column`'s `key` space; until measurement
demands it, lists ride in snapshots."*

### 7b. Change tracking — never diff output trees

If general deltas ever do happen, steal LiveView's deepest trick *in
principle*: it never compares rendered output. Templates compile so that each
dynamic slot knows exactly which assigns feed it; at render time a slot whose
dependencies are absent from the `__changed__` map emits `nil`, and `nil`
slots are simply omitted from the sparse diff
(`lib/phoenix_live_view/engine.ex:682-700, 1418-1425`;
`lib/phoenix_live_view/diff.ex:683-691`). Static template chrome ships once
per structural fingerprint (`engine.ex:1347-1358`) and never again. "What
changed" is **bookkeeping at write time, not comparison at send time**.

The elisp translation: builders declaring their data dependencies, so the
client knows a heading edit dirties the agenda view without re-rendering and
diffing it. (The old PoC's memoized-source machinery was unknowingly groping
toward this.) File under architecture-of-the-far-future — but file it,
because post-hoc tree diffing is the naive version, and the older sibling
already learned better.

---

## 8. What must not transfer

LiveView stands on the BEAM: a process per client, preemptive scheduling,
supervision trees, "let it crash" as a design principle, distributed pub/sub
for free. Every LiveView design decision silently assumes concurrency is free
and process death is routine, isolated, and supervised. Emacs is one
cooperative, single-threaded process that is *allowed to be asleep* — ebp
survives because the companion caches and queues around a brain that stops,
not because the brain is supervised. Import LiveView's wire ideas and
authoring vocabulary; never its process architecture. Any page of its docs
that says "just spawn a process" is where the analogy ends. (Presence and
multi-user, its crown jewels, stay rejected by standing decision: one brain,
by thesis — see `collab-crdt` positioning.)

Three specific escape hatches ebp deliberately lacks, and must keep lacking:

- **`phx-hook` bodies.** LiveView hooks run arbitrary client JavaScript. The
  convergent ebp seam (named native registrations — toolbars) shares the
  *registration* idea while the wire carries only names; keep it that way.
- **`JS.dispatch` / `JS.exec`.** Arbitrary event dispatch and
  attribute-indirection are precisely the holes the §5 allowlist and the
  weak-language invariant exist to close. LiveView can afford them; a
  companion that must stay un-programmable cannot.
- **DOM patching (morphdom).** LiveView morphs the real DOM in place; ebp
  renders whole snapshots and lets the renderer reconcile by key. Patching
  the client's tree from the wire is reserved-`surface.patch` territory —
  behind the same measurement gate as §7, and no sooner.

---

*Practical upshot, unchanged from the session that proposed this harvest:
takes 1–3 are one-or-two-key amendments you could draft into your §4/§5/§9
equivalents whenever those sections land; take 4 deserves a decision-log
entry when its tensions are resolved; §7 is two reserved sentences and zero
code. Fold the shapes into your hand-written sections directly — this
document is the quarry, not the wall.*
