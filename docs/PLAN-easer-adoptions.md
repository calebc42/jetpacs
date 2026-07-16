# Plan: Easer adoptions, second pass — firing history, manual triggers, state edges

**STATUS (2026-07-16): DRAFTED (not executed)** on branch
`claude/easer-jetpacs-learnings-d47310`. No code has changed; every
seam, name, and line cited below was verified against this worktree
(and the Easer checkout) on the drafting date. Item A flags a **live,
pre-existing crash bug** — it should land ahead of (or independent of)
everything else here.

This is the **second pass** over
[Easer](https://github.com/renyuneyun/Easer) (renyuneyun/Easer, the
closest open-source Tasker-class app). The first pass produced
[PLAN-conditions-and-dynamics.md](PLAN-conditions-and-dynamics.md)
(`when` gates, `${data.*}` dynamics, catalog batch: adapter states +
calendar + telephony — all landed). This pass mines what remains: the
condition *machinery* (not just the gate), the activity log, the
button-as-trigger, and the permission-surfacing contract. Same reading
discipline: a decade-vetted reference read for the design lessons it
proves, not the catalog it ships. Cross-plan ownership is unchanged —
`wifi.ssid`, `bluetooth.device`, and `notification.posted` stay owned
by PLAN-device-and-surfaces Tasks 1–3; the `state.edge` design below
is shaped so they slot in as drivers when they land.

## Study summary — Easer in one page

Source surveyed at `C:\Users\caleb\AndroidStudioProjects\Easer`
(package root `app/src/main/java/ryey/easer`). Terminology has
drifted across its 16 data-format versions: old *Scenario* = current
*Event*, old *Event* = current *Script*.

- **A Script binds exactly one trigger (Event XOR Condition) to one
  Profile** (a multimap of operations), plus flow flags
  (`reverse`, `repeatable`, `persistent`) and DAG in-edges
  (`predecessors`) — `core/data/ScriptStructure.java`.
- **Event vs Condition is edge vs level.** An Event is a one-shot
  `Slot` (`commons/local_skill/eventskill/Slot`); a Condition is a
  stateful `Tracker` with a sample-able `state()`
  (`commons/local_skill/conditionskill/Tracker`). The **`USourceSkill`**
  interface (`commons/local_skill/usource/USourceSkill.java`) lets one
  phenomenon implement both faces once — time, wifi, battery, screen,
  power, etc. all register into *both* catalogs via default adapters.
- **`condition_event`** (`skills/event/condition_event/`) bridges a
  Condition's level flips into edge Events — the mechanism behind
  "combine conditions into custom complex events". This one skill is
  most of the reason Easer's condition machinery pays rent.
- **The Lotus runtime**: each active Script gets a `Lotus`
  (`core/Lotus.java`) listening on a private broadcast URI; on
  satisfaction it triggers its Profile and *activates its successors*
  (demand-driven arming — children only listen while a parent is
  satisfied). Elegant idea, troubled execution: the runtime graph
  lives in **three** parallel structures the author never unified
  (`EHService.lotusMap` + `LogicGraph` + per-node status; repeated
  `//TODO: merge into LiveLogicGraph`), with `//FIXME concurrent`
  markers and a `Thread.sleep(1000)` polling watcher in
  `ProfileLoaderService`.
- **Skills are ~5 small files** (skill/data/factory/view-fragment/
  slot-or-tracker) plus one line in `skills/LocalSkillRegistry.java`.
  Per-skill contract includes `isCompatible(ctx)` and
  `checkPermissions(ctx)` → the registry hides incompatible skills
  and the UI surfaces missing permissions.
- **Storage** is one JSON file per item with a `createdVersion`;
  parsers branch on version (16 revisions survived, documented in
  `docs/en/DATA.md`). Migration = bulk read-old-rewrite-current.
- **Dynamics**: `<<PLACEHOLDER>>` substitution of event extras + core
  values into operation strings (`skills/operation/
  DynamicsEnabledString.java`). Flat substitution; their FEATURES.md
  admits no user variables and no predecessor data.
- **Activity log is in-memory only** (`core/log/ActivityLogService.kt`,
  a `LinkedList` lost on process death) — their known weakness.
- **Widget-as-trigger**: `skills/event/widget/UserActionWidget` — a
  home-screen button whose tap *is* an event source.
- **Battery model is naive**: a foreground service, inexact alarms,
  no JobScheduler/WorkManager, no battery-optimization handling; a
  TODO wants receiver-sharing "to reduce battery consumption".

## Where jetpacs is already ahead (do not "adopt" regressions)

Verified point-by-point; future readers should not import any of
these back:

- **Whole-set validation** — `parseTriggerRows` rejects the entire
  `triggers.set` on one bad row; Easer loads items independently and
  limps.
- **Negotiated catalogs** — welcome's `device.trigger_types` /
  `device.state_types` let an old companion degrade by *skipping
  client-side* (`jetpacs-triggers--supported-p`); Easer has no
  equivalent (single APK, no wire).
- **Fires never fail silently** — live send, else offline queue with
  `policy: drop|queue|wake` + dedupe + replay on reconnect. Easer
  fires into the void if a Profile fails mid-way (hand-rolled
  `LoadWatcher`).
- **Exact alarms + boot rearm from persisted rows** — alarm receivers
  cold-read Room by id, so stale alarms self-ignore; Easer uses
  inexact/deferrable alarms only.
- **Battery discipline** — receivers exist only while an armed row
  pays for them (`arm()` keys on the row set); `battery.level` is
  reduced host-side to hysteresis edge-crossings; calendar is
  observer + boundary alarms, zero polling. This is the receiver
  sharing Easer's TODO wishes for.
- **Rules-as-elisp** — `jetpacs-deftrigger` in init files *is* the
  import/export/versioning story Easer lacks entirely.
- **Single source of truth** — the Room trigger table, replace-set
  the only writer; no Lotus-style triple bookkeeping.

## The critical hazard (Item A; a live crash, verified)

`TriggerHost`'s context-registered receivers are registered with no
handler (`ContextCompat.registerReceiver(context, receiver, filter,
RECEIVER_NOT_EXPORTED)`, TriggerHost.kt `arm()`), so `onReceive` runs
on the **main thread**. `fireRow`'s offline branch calls
`JetpacsRuntime.database?.eventDao()?.insert(QueuedEvent(...))`
directly (TriggerHost.kt ~599), and `JetpacsDatabase.getDatabase`
does **not** set `allowMainThreadQueries()` (JetpacsDatabase.kt
`databaseBuilder`). Therefore: any broadcast-driven trigger (power,
screen, headset, airplane, package, adapter states…) firing with
`policy: queue|wake` (queue is the **default**) while Emacs is
disconnected throws Room's `IllegalStateException` inside `onReceive`
→ **companion process crash**. The alarm path (`TriggerAlarmReceiver`)
and the wire path (read thread) hop threads deliberately; the receiver
path never did. It survived the suites because JVM tests don't run
receivers and Phase-6 on-device acceptance is still pending.

## Design decisions

1. **The bridge type is named `state.edge`, never `state.changed`.**
   `Kind.STATE_CHANGED = "state.changed"` already exists (Envelope.kt,
   the widget-input frame); reusing the string would be a permanent
   grep/docs/log footgun. "Edge" is also the precise word: it is a
   level→edge bridge.
2. **No `not` operator, still** (upholds PLAN-conditions-and-dynamics
   decision c). The audit found the two spots where "flip the value"
   is currently impossible — `network` cannot express *disconnected*
   and `screen` cannot express *locked* — so Item D completes the
   vocabulary instead of adding an operator.
3. **Trackable subset for `state.edge`** = `STATE_TYPES` −
   {`time.window`, `calendar.event`}. Both exclusions cost zero
   expressiveness: a time-window *edge* is a `time` trigger at the
   boundary; a calendar *edge* is the existing `calendar.event` type
   (CalendarTriggers.kt). Excluding them means `state.edge` needs no
   new alarm machinery at all — every driver is a receiver/callback
   `arm()` already owns.
4. **Row-level `when` stays legal on a `state.edge` row** and keeps
   its existing meaning (an additional fire-time gate); the tracked
   conjunction lives in `params.when`. Lint *warns* (not errors) when
   the same predicate type appears in both.
5. **New trigger types negotiate via the welcome only**; the frozen
   batch-1 fallback list in jetpacs-triggers.el is never touched
   (pinned by the `jetpacs-triggers-new-types-not-in-fallback` ERT
   test).
6. **History is persisted** (Room), capped by a ring buffer — the
   direct fix of Easer's in-memory weakness, and the debugging tool
   Phase-6 on-device acceptance wants anyway.

## Items (each independently landable; suite gates green per item)

### Item A — `fireExecutor` in `fireRow` (bug fix; land first, or spin off)

Add a single-thread executor to `TriggerHost`'s companion object; move
the `eventDao().insert(QueuedEvent(...))` + `refreshQueuedCount()`
block onto it (`EmacsWaker.requestWake` can stay in place). That is
the whole fix. Items B and E route more traffic through `fireRow`
from receivers, so they *depend* on this landing.

- Tests: none runnable on plain JVM (no Robolectric in this repo);
  acceptance row: fire a `power` trigger with Emacs disconnected,
  `policy: queue` — process must survive, event must replay on
  reconnect.
- Battery: nil. Wire/SPEC: none.

### Item B — persisted firing history (`triggers.history`)

Easer's ActivityLog, done durably.

- **Room** (JetpacsDatabase.kt): new `trigger_firings` entity —
  `id` (autogen), `triggerId`, `type`, `atMs`, `outcome`
  (`fired|queued|dropped|suppressed_when|throttled`), `detail?`
  (e.g. the first `on_fire` failure string). DAO: `insert`, `recent
  (limit)`, and a `@Transaction record()` that inserts + prunes to
  200 (`DELETE … WHERE id NOT IN (SELECT id … ORDER BY atMs DESC
  LIMIT 200)`). DB version 4→5, migration = one `CREATE TABLE IF NOT
  EXISTS`.
- **TriggerHost**: `recordFiring(...)` submitting to Item A's
  `fireExecutor`; instrument `fireRow`'s five exits (gate-fail,
  throttle, live-send, drop, queue). Have `executeOnFire` return its
  first failure (or null) for `detail`.
- **DeviceCapabilities**: handler `"triggers.history"` — args
  `{limit?}` (default 50, clamp 1..200) → `{firings: [{id, type,
  at_ms, outcome, detail?}]}`. Rides `capability.invoke` on the read
  thread (Room-legal); auto-appears in `device.caps`, so negotiation
  is free and old companions need nothing.
- **Elisp**: `jetpacs-triggers-history` wrapper (invoke-style, like
  `jetpacs-device-*`); a History affordance in
  emacs/core/jetpacs-automations.el using the fetch-then-dialog
  pattern of `jetpacs-device-launch-app` (jetpacs-device.el), gated
  on `(jetpacs-device-cap-p "triggers.history")`. Bundle regen.
- **Wire/SPEC**: no new kind, **no contract.json change**. SPEC §10
  row for the capability + the outcome vocabulary; SPEC-CHANGES row;
  optional golden line (`capability.invoke` case) — all in the ebp
  submodule checkout.
- **Tests**: JVM — arg clamping + `detail` composition as pure
  functions (DAO/prune SQL goes on the acceptance checklist, noted).
  ERT — wrapper shape via the send-capture idiom; History affordance
  absent without the cap.
- **Battery**: zero standing cost (writes at fire time, reads on
  demand).

### Item C — `manual` trigger type + `trigger.fire` builtin

Easer's widget-as-trigger, generalized; Tasker "task shortcut"
parity; works Emacs-dead.

- **TriggerHost**: `SUPPORTED_TYPES += "manual"` (welcome-negotiated
  per decision 5). `arm()` registers nothing for it. New
  `fireManual(context, id, source): String?` — looks the row up in
  Room, guards `type == "manual"`, then runs the **full** `fireRow`
  pipeline (when-gate, throttle, on_fire, history, event/queue), with
  fire data `{source}`. A disabled manual trigger is absent from the
  table and cannot fire — replace-set semantics for free.
- **ActionReceiver.handleTap** (already on the background dispatch
  thread — Room-legal): before the remote-forward, intercept parsed
  action JSON with `builtin == "trigger.fire"` → `fireManual(ctx,
  id, "tap")`. This one seam covers every Emacs-dead surface — QS
  tiles, custom widgets, pinned shortcuts, notification actions, and
  in-app taps (MainActivity's unknown-builtin `else` falls through to
  the same broadcast).
- **DeviceCapabilities**: `"trigger.fire"` handler, args `{id}` →
  `fireManual(context, id, "emacs")` (the elisp-initiated path that
  *does* run `on_fire`, unlike `jetpacs-trigger-test-fire`, which
  stays Emacs-local and keeps its job for other types).
- **Elisp**: `jetpacs-trigger-fire-action` node builder in
  jetpacs-widgets.el (beside `jetpacs-clipboard-action`);
  `jetpacs-trigger-fire` capability wrapper in jetpacs-triggers.el;
  in the automations card, manual rows swap the "Fire now"
  `trigger.test` button for the `trigger.fire` **builtin** (works
  with Emacs dead).
- **Wire/SPEC**: `jetpacs-lint-action-builtins += ("trigger.fire"
  id)` — **the one contract.json-touching change in this plan** →
  regen + `jetpacs-contract-artifact-current` need the submodule
  checkout. SPEC §5 builtin row, §11 `manual` type row (no params;
  data `{source}`; `${data.source}`), §10 capability row;
  SPEC-CHANGES row; golden optionally.
- **Tests**: JVM — `manual` parses with empty params; pure guard
  `manualFireError(row?, id)` truth table. ERT — lint accepts the
  builtin with `id` / rejects without; automations card renders the
  builtin for manual rows; contract drift (submodule checkout).
- **Battery**: zero standing cost; nothing armed.

### Item D — catalog parity: `ringer.mode` + the two negation gaps

The USource lesson applied as an audit rule — *every phenomenon
decides edge, level, or both, deliberately*. The audit found
`headset`, `network` transport, and calendar-as-level already exist;
what's left:

- **`ringer.mode`** (permission-free, both faces): state predicate
  `{type:"ringer.mode", mode: normal|vibrate|silent}` sampling
  `AudioManager.ringerMode`; edge trigger type via
  `RINGER_MODE_CHANGED_ACTION` receiver (guard
  `isInitialStickyBroadcast` like `headsetReceiver`). The receiver
  doubles as a `state.edge` driver. Pairs with the existing
  `ringer.mode`/`dnd.set` effectors.
- **Negation gap 1 — `network`**: `stateMatches` currently *requires*
  a connection; add the `connected` field so
  `{"type":"network","connected":false}` matches no-active-network.
- **Negation gap 2 — `screen`**: add `"locked"` to the state
  vocabulary, complementing the existing `"unlocked"`.
- **Deferred**: `dnd` as a level (`currentInterruptionFilter` read is
  permission-free; driver `ACTION_INTERRUPTION_FILTER_CHANGED`) —
  cheap but second-order; a follow-up row, not a blocker.
- Extend-all-three discipline per the STATE_TYPES comment:
  `StateSampler.STATE_TYPES` + `jetpacs-lint-state-predicate-types`
  + SPEC §11 predicate table (and `TriggerHost.SUPPORTED_TYPES` for
  the edge face; never the frozen elisp batch-1 list).
- **Tests**: `StateSamplerWhenTest` additions (ringer match; network
  `connected:false`; screen locked); lint predicate fields; ERT
  negotiation skip for the new edge type. SPEC-CHANGES row.
- **Battery**: receiver only while a `ringer.mode` row is armed;
  predicates are sample-on-demand.

### Item E — `state.edge` trigger type (the keystone)

Easer's entire Condition/Tracker/`condition_event` machinery,
collapsed into one trigger type over the existing `StateSampler` —
no Tracker objects, no graph, no new listeners.

Registration shape (rides `triggers.set`; no new frame kind):

```json
{"id": "net-lost", "type": "state.edge",
 "params": {"when": [{"type": "network", "connected": false}],
            "edge": "rise"},
 "on_fire": [{"notify": {"title": "Offline",
                          "text": "${data.edge} at ${id}"}}]}
```

- `params.when` — a predicate list in the **exact** §11 `when`
  vocabulary; reuse `StateSampler.validateWhen`/`evaluateWhen`
  verbatim so the vocabulary can never fork. `params.edge` ∈
  `rise` (false→true, default) | `fall` | `both`. Fire data:
  `{holds, edge}` → `${data.holds}`, `${data.edge}`.
- **Trackable subset** per decision 3; `parseTriggerRows` whole-set
  rejects a `state.edge` row whose predicates stray outside it (same
  discipline as malformed `when`).
- **Driver derivation**: `arm()` computes a *drivers* set = edge
  types ∪ (each `state.edge` row's predicate types), mapped to the
  receivers `arm()` already owns — power/battery → battery receivers,
  screen, airplane, headset, adapter-state receivers, the network
  callback, the call-state receiver (same permission skip-with-log
  rule). Each existing `if ("power" in types)` keys on drivers
  instead. **No listener exists that an armed row didn't pay for** —
  the standing battery constraint holds by construction.
- **Edge detection**: per-row `edgeSide` map (the `batterySide`
  idiom, cleared in `arm()`); seed silently at arm time (arm already
  runs off-main); `reevaluateStateEdges(changedType)` appended to
  each driver's delivery point re-evaluates only rows referencing
  that type; a flip matching `edge` calls `fireRow`. First-seen side
  seeds silently → **no fire on re-arm/reboot**. Missed flips
  self-heal at the next driving event. Extract pure
  `edgeFires(previous: Boolean?, now, edge)` for JVM tests.
- **Elisp**: belt-and-braces client skip — a `state.edge` row is
  skipped whole unless its `params.when` types pass the state-catalog
  check (an old companion already never advertises `state.edge`, so
  this covers only a companion whose state catalog lags its trigger
  catalog); lint check for `params` shape + the duplicate-predicate
  warning (decision 4); automations card renders the tracked gate via
  the existing gate-summary helper.
- **Wire/SPEC**: §11 type row + a "tracked-state edges" paragraph
  (trackable subset, driver rule, seeding rule, two-gate
  relationship); SPEC-CHANGES row; one golden registration line,
  regen twice per convention. No contract.json change.
- **Tests**: JVM — `edgeFires` truth table; parse validation
  (missing `when`, untrackable `time.window` predicate, bad `edge` —
  each rejects the whole set); pure driver-set derivation. ERT —
  3-way negotiation skip; lint; automations rendering. Acceptance —
  airplane edge both directions Emacs-dead (on_fire notify); no fire
  on reboot; battery-predicate edge doesn't spam under charge
  fluctuation.
- **Battery**: no polling; re-evaluation only on events an armed row
  already pays for; `battery.level` predicates re-introduce the
  `ACTION_BATTERY_CHANGED` receiver *only while such a row exists* —
  the same accepted cost as today's `battery.level` edge type.
- Depends on Item A (receiver-driven `fireRow` traffic).

### Item F — per-type availability reporting (`trigger_unavailable`)

Easer's per-skill `checkPermissions` contract, translated to the
wire.

- **TriggerHost**: `unavailableTypes(granted: (String) -> Boolean):
  Map<String, String>` — supported-but-unarmable types → perm key in
  the existing `device.perms` vocabulary (`sms.received` →
  `receive_sms`, `call.state` → `read_phone_state`,
  `calendar.event` → `read_calendar`). Injected predicate =
  JVM-testable.
- **JetpacsConnection** (`handleAuthResponse`, the `"triggers" in
  granted` block that already puts `trigger_types`/`state_types`):
  add `trigger_unavailable` only when non-empty. The welcome's
  `device` payload key is already schema-optional — **no
  contract.json change**.
- **Revoked-while-armed**, documented normatively in §11: revocation
  kills the process; on restart `arm()` skips ungranted receivers
  with a log (existing behavior) and predicates fail closed — no
  garbage fire; the next welcome reports the type unavailable.
  Recommended (rides Item B): `arm()` writes an `arm_skipped` history
  row with the perm key, so History answers "why didn't my SMS rule
  fire".
- **Elisp**: `jetpacs-trigger-unavailable-reason` reading the session
  device report. **Push discipline unchanged** — the row is still
  pushed; the companion stores it and arms after grant (the existing,
  correct degrade). Automations card gains "Needs permission: LABEL"
  + a Grant button via the existing `jetpacs-device--perm-info` table
  and `device.perm.open` action (jetpacs-device.el; load order in
  build-bundle.el already puts jetpacs-device before
  jetpacs-automations).
- **Tests**: JVM — injected-predicate truth table. ERT — reason
  lookup from a stubbed session; card shows/hides the Grant row.
- **Battery**: nil.

## Rejects (and what serves instead)

- **The Lotus DAG — rule graphs, predecessors, demand-driven child
  arming** — Easer's most distinctive machinery and where its debt
  concentrates (three parallel runtime representations, concurrency
  FIXMEs, the double-activation bug its `livePredecessors` papers
  over). Flat `when` gates + `state.edge` cover the real use cases;
  composition is elisp's job; Emacs is the brain. (Re-affirms the
  first pass's reject with the second pass's evidence.)
- **Trackers as objects / a condition registry** — `state.edge` is a
  row, not a subsystem; `StateSampler` stays listener-free and
  sample-on-demand.
- **Logic in `on_fire`** — unchanged. `state.edge` does not weaken
  this: edge detection is declarative signal tracking in the
  registration, not control flow in the response — the same carve-out
  §11 already makes for `when`.
- **Companion self-mutation** — Easer's `state_control` operation
  lets rules toggle rules ("dirty hack" per its own comments). The
  Room table has one writer: replace-set.
- **In-memory history** — Easer's dies with the process; Item B
  persists (that's the adoption *and* the correction).
- **`<<NAME>>`-style free placeholders / format specifiers** — the
  first pass's dynamics reject stands; `${data.*}` flat substitution
  only.
- **Skill-style plugin packaging / remote-plugin IPC** — jetpacs'
  extension seam is the wire contract + elisp, not APK plugins.

## Mechanics appendix (post-extraction paths — differs from the first pass)

Since the ebp extraction, the wire spec artifacts live in the **`ebp/`
git submodule** (SPEC.md, SPEC-CHANGES.md, contract.json,
goldens/frames.golden), not `docs/`. The submodule is typically
**uninitialized in worktrees** (gitlink `4ab79e2`,
`spec-1.0-rc-2-g4ab79e2` in the primary checkout at
`C:\Users\caleb\AndroidStudioProjects\jetpacs\ebp`); initialize via
local fetch from the primary checkout — no SSH in agent sessions,
owner pushes.

- Contract regen: `emacs --batch -l emacs/build-contract.el -f
  jetpacs-contract-write` — only Item C changes contract.json (the
  lint builtin table feeds `action_schema`); trigger/state types
  negotiate via the welcome and are not in the contract.
- Golden regen: `emacs --batch -l test/jetpacs-tests.el --eval
  "(jetpacs-tests-regen-frame-golden)"` (cases in
  `jetpacs-tests--frame-cases`); regen twice per convention. Note
  `WireGoldenConformanceTest` (JVM) **cannot run without the
  submodule** — CI/suite gates need a full checkout.
- One SPEC-CHANGES row per amendment, same commit, in the submodule;
  gitlink bump in jetpacs.
- Suite gates: `wsl -d Debian -- test/run-tests.sh` and `gradlew
  :jetpacs:testDebugUnitTest :jetpacs:assembleDebug
  :app:assembleDebug`. Bundle regen after any `emacs/` change
  (`emacs --batch -l emacs/build-bundle.el`; root jetpacs-core.el is
  GENERATED — no new modules are added by this plan, so only regen).
- LF endings; stage explicitly (never `git add -A` — owner WIP docs).

## Risks

1. **Main-thread Room writes** (Item A's bug): until it lands, Items
   B/E add receiver-driven `fireRow` traffic onto a crash path. Land
   A first; regression-test on device (power trigger, Emacs
   disconnected, policy queue).
2. **`ACTION_BATTERY_CHANGED` frequency** under `battery.level`
   `state.edge` predicates: each broadcast costs one `evaluateWhen`
   (binder reads, no I/O). Bounded — the receiver exists only while
   such a row is armed, same as today's edge type.
3. **Receiver-vs-sticky-sample races** in `state.edge` (a broadcast
   arriving before the sampled level settles): per-row side memory
   makes a missed flip self-heal at the next driving event; covered
   by the acceptance checklist, not extra machinery.
4. **DB migration 4→5** over live trigger sets — pure CREATE TABLE,
   low risk; acceptance-checklist it anyway.
5. **Contract/golden drift** — Item C's regen is only checkable in a
   full checkout (submodule); a worktree-only session will pass
   locally and fail the drift tests elsewhere.
6. **Naming** — if `state.changed` is ever preferred over
   `state.edge`, the `Kind.STATE_CHANGED` collision must be called
   out in SPEC §11 and Envelope.kt; default remains `state.edge`.

## Suggested sequencing

**A → B → C → D → E → F.** A is a standalone crash fix and B/E depend
on it. B (history) lands next so C/D/E firings are observable during
their own on-device checks. C and D are independent of each other and
of E; D before E only because `ringer.mode` then arrives as a
`state.edge` driver for free. F is pure reporting and can land any
time after B (for the `arm_skipped` rider). Nothing here blocks, or
is blocked by, the PLAN-device-and-surfaces Tasks 1–3 batch — when
`wifi.ssid`/`bluetooth.device`/`notification.posted` land, they extend
the driver map and the availability map by one row each.
