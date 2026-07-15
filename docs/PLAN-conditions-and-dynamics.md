# Plan: conditions, dynamics, and the Easer catalog batch

**STATUS (2026-07-15): CODE COMPLETE (Phases 0–5) on branch
`claude/conditions-dynamics-plan-e82758`; Phase 6 (on-device
acceptance) pending a live phone.** api 1.13.0; suites green per phase
(ERT 190/190; Kotlin adds OnFireInterpolationTest, StateSamplerWhenTest,
TimeWindowPredicateTest, TriggerParseValidationTest, CalendarBoundaryTest,
SmsCallMatchTest — all passing; `:jetpacs`/`:app` assemble). SPEC-CHANGES
#3–#7 filed (reviewed-by cells await the owner). `docs/contract.json`
regenerated its `api_version` only, as predicted (no kind_schema change).
Phase 0 items 2–3 (the PLAN-device-and-surfaces telephony-reject
amendment and the ROADMAP item-6 cross-reference) ride the owner's
pending untracked docs revision and were not duplicated. Remaining:
run the on-device checklist below, flip this STATUS, file follow-ups.

Produced from a survey
of [Easer](https://github.com/renyuneyun/Easer) (renyuneyun/Easer, the
closest open-source Tasker-class app) the way
[PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md) was produced
from the Termux survey: a decade-vetted reference read for the design
lessons it proves, not the catalog it ships. Three lessons land **in the
foundation** (§10/§11), not in a Tier-1 app. Cross-plan ownership: the
hardware-gated `wifi.ssid`/`bluetooth.device` batch and the
`notification.posted` listener stay owned by
[PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md) (Tasks 1, 3);
this plan is designed so they slot in as state-predicate types when they
land. This plan **amends that plan's telephony reject** (see its Rejects
row) for exactly two items: `sms.received` and `call.state`.

## Why this plan exists

The §11 engine is edge-only. A trigger fires an event; elisp runs the
logic; the companion-local `on_fire` response is a deliberately
logic-free flat list. That is the right spine — *rich server, thin
client* — but three things Easer has are pure additive leverage on it,
and two of them are needed for the engine to be useful while Emacs is
dead (the whole reason `on_fire` exists):

1. **Conditions.** Easer models each signal once and exposes it as both
   an edge *Event* (a `Slot` emitting transitions) and a level
   *Condition* (a `Tracker` with a sample-able `Boolean state()`) — the
   "USource" pattern. jetpacs has only the edge half. Without the level
   half, "notify me at 07:00 **but only on weekdays and only when not
   charging**" is impossible Emacs-dead: `on_fire` cannot ask a
   question. A flat, AND-ed **`when` gate** of state predicates fixes
   that without becoming a rule language.
2. **Dynamics.** Easer interpolates event-produced data (the SMS sender,
   the connected SSID, the battery level) into operation parameters via
   placeholders. jetpacs already carries that data to elisp in the
   `trigger.fired` event, but `on_fire` — the Emacs-dead path — is
   static. `${data.field}` interpolation into `on_fire` strings closes
   the gap, flat substitution only, data-not-code.
3. **Catalog.** Easer's source vocabulary is broad; five entries map
   onto real jetpacs needs and aren't owned elsewhere: `wifi.enabled`,
   `bluetooth.enabled` (adapter states, permission-free), `calendar.event`
   (a synced org agenda made reactive), and `sms.received` / `call.state`
   (the telephony pair, the dynamics showcase).

## Repo conventions (read first — carried from PLAN-device-and-surfaces.md)

Suite gates: `wsl -d Debian -- test/run-tests.sh` (from Windows; in WSL
just `test/run-tests.sh`) and `gradlew :jetpacs:testDebugUnitTest
:jetpacs:assembleDebug :app:assembleDebug`. Bundle regen after any
`emacs/` change (`emacs --batch -l emacs/build-bundle.el`). One
[SPEC-CHANGES.md](SPEC-CHANGES.md) row per amendment, same commit;
§10/§11 grow additively by design. Every new wire action is
allowlisted, validated, documented in SPEC §5's namespace discipline.
Battery gate: every task below states its background cost. LF; stage
explicitly. `docs/contract.json` needs **no regen** — `state.get` rides
the existing `capability.invoke` kind and `when` rides a `triggers.set`
entry, so no kind_schema payload key changes (verified: `triggers.set`
required `(triggers)`; `capability.invoke` required `(cap)` optional
`(args)`). Only `test/frames.golden` is regenerated, twice.

## The critical hazard (drives the whole negotiation design)

**Verified against source:** `TriggerHost.replaceSet` reads known trigger
keys via `opt*` and **silently ignores unknown keys inside a trigger
entry** — it does *not* whole-set-reject them (it rejects only unknown
*types*). So a companion predating this work, handed a `when`-carrying
registration, would arm the trigger **ungated**: "notify below 20%"
silently becomes "notify always." That is strictly worse than a
rejection.

Therefore the negotiation is **client-side and mandatory**: a client may
push a `when`-carrying registration only when **every** predicate's
`type` appears in the session's new `device.state_types` report;
otherwise it skips the whole registration with a message (the existing
`jetpacs-triggers--supported-p` skip idiom). It must **never** strip
`when` and push the rest — that reproduces the ungated-arm. The SPEC
states this rule normatively; a new companion additionally validates
`when` in `replaceSet` and whole-set-rejects garbage. New trigger types
are **not** added to the frozen `jetpacs-triggers-supported-types`
batch-1 fallback; they negotiate via `device.trigger_types` only.

## Design decisions (all resolved; owner-locked 2026-07-14)

- **a. `when` gates the entire fire.** A failed gate means the fire never
  happened: no `event.action`, no `on_fire`, no throttle bookkeeping,
  local `Log.d` only. The check runs **before** the throttle block in
  `fireRow` so a suppressed fire doesn't consume the `lastFired` slot. An
  unevaluable predicate (ungranted permission, unknown type) counts as
  **not holding** — fail closed, never fire garbage. Rationale: the layer
  exists for Emacs-dead operation; gating only `on_fire` while still
  queueing the `event.action` puts a stale, already-failed state snapshot
  in the replay queue and adds nothing elisp can't already do in a
  handler. `jetpacs-trigger-test-fire` stays local and bypasses gates
  (documented in its docstring — it tests the dispatch path, not the
  gate).
- **b. Negotiation.** New `device.state_types` welcome field under the
  `triggers` grant (the sample-able predicate catalog); `state.get`
  appears in `device.caps` automatically under the `capabilities` grant.
  Client rule as above. Separate from `trigger_types` because
  sample-ability ≠ trigger-ability: `boot`/`time`/`timezone.changed`/
  `package`/`sms.received` are edge-only; `time.window` is
  predicate-only. Same *name vocabulary* where a signal has both views
  (USource), separately *negotiated catalogs*.
- **c. Vocabulary.** `device.state_types` after all phases:
  `airplane, battery.level, bluetooth.enabled, calendar.event,
  call.state, headset, network, power, screen, time.window,
  wifi.enabled`. Predicates are flat objects: `type` + type-specific
  match fields reusing the §11 `params` vocabulary. `time.window
  {after?, before?, days?}` is predicate-only and the single most useful
  gate (wraps midnight when `after > before`; absent bound = open; absent
  `days` = all). No negation operator — predicates are two-valued, so the
  complement is expressed by flipping the value.
- **d. Interpolation syntax: `${…}`** — SPEC §9's snippet-placeholder
  grammar verbatim (`${id}`, `${type}`, `${data.FIELD}`). Single pass
  (substituted text never re-scanned); unknown/unresolvable tokens stay
  literal; the result is always a string (numbers/booleans render in JSON
  form); no escaping mechanism (§9-consistent). Applies to every string
  in `{notify:{title,text}}` and recursively in a `{cap,args}` entry's
  `args` (nested objects/arrays, e.g. `intent.start` extras). The `cap`
  name itself never interpolates.
- **e. SMS/call privacy.** Opt-in payload, fail-closed, never logged.
  `sms.received {from?, contains?, include_body?=false}` → data
  `{from, body?}` (`body` only with `include_body:true`; `contains`
  matching reads the body but does not emit it). `call.state {state?,
  number?, include_number?=false}` → data `{state, number?}`; Android ≥9:
  the number needs READ_CALL_LOG **in addition to** READ_PHONE_STATE —
  without it a `number`-filtered rule never fires and `include_number`
  yields no field. Content is never logged/persisted companion-side
  except as the `trigger.fired` data itself, which under `policy:"queue"`
  sits in the app-private queue DB — `policy:"drop"` is recommended for
  body-carrying rules. (Verified: the current pipeline already logs only
  ids and cap names, never data/args — the clipboard.read discipline.)
- **f. Calendar: both views, zero polling.** Trigger (edge: matching
  event started/ended) and predicate (ongoing). Mechanism = Easer's
  CalendarTracker: a `ContentObserver` on
  `CalendarContract.Instances.CONTENT_URI` plus one AlarmManager alarm
  parked at the next boundary (next matching start when idle; current end
  when ongoing); on observer change or alarm, re-query, fire the edge if
  crossed, re-arm. Boot re-arm via `TriggerHost.onBoot`; a manifest
  `CalendarAlarmReceiver` follows the `TriggerAlarmReceiver` cold-read
  idiom.
- **g. Kotlin structure.** New `StateSampler.kt` (an `object` like
  `DeviceCapabilities`, context passed per call — not methods on
  TriggerHost, because `fireRow` is static, samplers are stateless
  system-service reads, and `state.get` dispatches from
  DeviceCapabilities). The gate hook is one line at the top of `fireRow`.
  `TriggerRow` gains `val whenJson: String? = null` (property name
  sidesteps the SQL `WHEN` keyword); DB `version = 4`, `MIGRATION_3_4 =
  ALTER TABLE triggers ADD COLUMN whenJson TEXT`.
- **h. Elisp API.** `:when` keyword on `jetpacs-trigger-register` (and
  thus `jetpacs-deftrigger`): a list of predicate alists, serialized as a
  `when` vector in the spec. `jetpacs-device-state` — callback-based
  `(cl-defun jetpacs-device-state (callback &key types when))`, matching
  every other querying wrapper (there is no synchronous
  `capability.invoke` wrapper anywhere; keep it that way). The automations
  view renders gates. `jetpacs-lint-trigger` (advisory, lint/CI-time)
  validates `when` shapes, on_fire exactly-one-of `cap`/`notify`, and
  `${…}` token grammar, plus a `defconst jetpacs-lint-state-predicate-types`
  mirroring `StateSampler.STATE_TYPES` ("extend both together", the
  existing `jetpacs-triggers-supported-types` comment idiom).

## SPEC amendment sketches

**§11** — signature gains `when?`; new `when` bullet (flat AND-ed
state-predicate list, whole-fire gating, fail-closed, no
OR/nesting/negation, **the normative client rule** from "The critical
hazard" above); the on_fire "no conditionals, no loops" sentence gains
the carve-out *"(`when` is not a conditional in this sense: it is a
declarative state gate — sampled data ANDed at fire time — not control
flow inside the response)"*; new **Placeholders** bullet inside on_fire
(§9 snippet rules); new subsection **State predicates & sampling** (the
decision-c table); trigger-type rows added per phase.

**§10** — `state.get` catalog row (`args {types?, when?}` → result
`{states, unavailable?, holds?}`; per-type failures land in
`unavailable`, never failing the batch; `when` uses the same evaluator
`fireRow` uses, so a gate is testable from Emacs before it ships); the
device-report example gains `state_types` (under the `triggers` grant)
and the perm keys `read_calendar, receive_sms, read_phone_state,
read_call_log`.

**SPEC-CHANGES rows** (one per landing commit, same commit): #2 on_fire
dynamics (fixtures: `frames.golden`) · #3 `when` + state catalog +
`state.get` (fixtures: `frames.golden`) · #4 adapter-state types (none) ·
#5 calendar (none) · #6 sms/call (none).

## Phases (each independently landable; suite gates green per phase)

### Phase 0 — docs only

1. This file.
2. Amend [PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md)
   Rejects (telephony row): the "revisit item-by-item on demand" clause
   is exercised for exactly two items — `sms.received` + `call.state`
   land as §11 types; the rest of the telephony class stays rejected.
3. [ROADMAP.md](ROADMAP.md) item 6: one cross-reference sentence.

### Phase 1 — on_fire dynamics (smallest; no negotiation needed)

`TriggerHost.kt`: companion-object `interpolate(template, id, type,
data)` (regex `\$\{(id|type|data\.([A-Za-z0-9_]+))\}`, missing → literal)
and `interpolateValue(value, …)` (recursive over JSONObject/JSONArray);
`executeOnFire` signature becomes `(context, row: TriggerRow, data:
JSONObject)`, applying `interpolateValue` to each entry's `notify` and
`args` before dispatch; update the `fireRow` call site. SPEC §11
Placeholders bullet + SPEC-CHANGES #2. Golden: add a `${…}`-token
on_fire entry to the existing `power-sync` case in
`jetpacs-tests--frame-cases`, regen
(`emacs --batch -l test/jetpacs-tests.el --eval
"(jetpacs-tests-regen-frame-golden)"`), review the line-1 diff (tokens
are inert strings on the wire — the golden pins pass-through). New
Kotlin `OnFireInterpolationTest.kt`: `knownTokensSubstitute`,
`unknownAndMissingStayLiteral`, `jsonFormRendering`,
`singlePassNoRescan`, `recursionCoversNestedArgs`,
`capNameNeverInterpolated`. **Battery: zero standing cost** (fire-time
string ops only).

### Phase 2 — conditions core (`when` + StateSampler + `state.get` + time.window)

New `StateSampler.kt`: `STATE_TYPES = {power, battery.level, screen,
airplane, network, headset, time.window}`; `sample(context, type)`
(sticky battery intent; PowerManager/KeyguardManager; Settings.Global;
ConnectivityManager active-network + caps; AudioManager wired-output
scan; `time.window` → `cap-failed "predicate-only"`); `holds(context,
predicate)` (any exception/unknown → false + `Log.w`);
`evaluateWhen(context, whenJson)` (null → true, AND-fold);
`validateWhen(arr)` (shape errors as strings); pure
`timeWindowHolds(minutesOfDay, dayIndex, predicate)` (injected clock,
wrap-midnight); move `transportName(caps)` here (TriggerHost delegates).
`TriggerHost.kt`: `fireRow` prepends `if
(!StateSampler.evaluateWhen(context, row.whenJson)) { Log.d(…); return
}` before the throttle block; extract `parseTriggerRows(triggers):
Pair<List<TriggerRow>?, String?>` (unit-testable without Room) and
validate/store `whenJson` there (whole-set reject on garbage).
`JetpacsDatabase.kt`: `whenJson` column, v4, `MIGRATION_3_4`.
`DeviceCapabilities.kt`: `"state.get"` handler (per-type
`CapabilityException` → `unavailable`; `when` present → validate then
`holds`). `JetpacsConnection.kt`: welcome adds
`state_types = StateSampler.STATE_TYPES.sorted()` under the `triggers`
grant. Elisp: `:when` keyword + docstring; `jetpacs-triggers--when-supported-p`
(no static fallback — docstring explains the ungated-arm hazard); specs
emit/skip; `jetpacs-trigger-test-fire` + `jetpacs-triggers-supported-types`
docstring updates; `jetpacs-device-state`; automations gate rendering;
`jetpacs-lint-trigger` + predicate-types defconst. Bundle regen.
Goldens: `when`-carrying registration in frame-cases + a `state.get`
`capability.invoke` golden line. ERT: `jetpacs-triggers-when-serialized`,
`jetpacs-triggers-when-negotiation-skip` (3-way: no report / partial /
full — mirror `jetpacs-triggers-unsupported-type-skipped`),
`jetpacs-device-state-wrapper-shapes`, `jetpacs-automations-view-shows-gates`,
`jetpacs-lint-trigger-registration`. Kotlin: `StateSamplerWhenTest`,
`TimeWindowPredicateTest` (inside/wrapsMidnight/openBounds/daysFilter),
`TriggerParseValidationTest` (whenStoredOnRow/badWhenRejectsWholeSet).
SPEC §10+§11 + SPEC-CHANGES #3. **Battery: zero standing cost**
(fire-time evaluation of cached system state; `state.get` on demand; no
new listeners, no polling).

### Phase 3 — adapter states (`wifi.enabled`, `bluetooth.enabled`)

`TriggerHost`: `SUPPORTED_TYPES` += both; `arm()` registers
`WifiManager.WIFI_STATE_CHANGED_ACTION` /
`BluetoothAdapter.ACTION_STATE_CHANGED` receivers (ENABLED/DISABLED
edges only, ignore transitional states, param match on `enabled`).
`StateSampler` += both (`isWifiEnabled` / `adapter?.isEnabled`; null
adapter → `cap-failed`). Manifest: `ACCESS_WIFI_STATE` + `BLUETOOTH
maxSdkVersion=30` (both install-time; currently undeclared — verified).
Lint defconst += both. ERT: `jetpacs-triggers-new-types-not-in-fallback`
(pins the frozen batch-1 rule). SPEC rows + SPEC-CHANGES #4. **Battery:
receivers armed only while a matching row exists; ≈ free.**

### Phase 4 — `calendar.event` (trigger + predicate; READ_CALENDAR degrade)

New `CalendarTriggers.kt`: the observer + boundary-alarm engine
(decision f); pure helpers `matchingInstance(resolver, params, nowMs)`
and `nextBoundaryMs(...)`; per-row last-side memory (edges fire once).
Manifest `CalendarAlarmReceiver` (`exported=false`, TriggerAlarmReceiver
idiom: cold-read row by id, recompute, fire + re-arm, stale rows
self-ignore). `TriggerHost`: `SUPPORTED_TYPES` += `calendar.event`;
`arm()` delegates calendar rows **only when READ_CALENDAR granted** (else
`Log.w` + skip); `shutdown()` disarms; `onBoot` re-arms. `StateSampler`
+= `calendar.event` (ungranted → `cap-permission` perm=`read_calendar`).
`DeviceCapabilities.permissionMap` += `read_calendar`. Manifest:
`READ_CALENDAR` + the receiver. Elisp `jetpacs-device--perm-info` +=
`(read_calendar "Calendar (calendar.event triggers)" "app")`; lint +=
type. Kotlin `CalendarBoundaryTest.kt` (pure boundary math:
idle→next-start, ongoing→current-end, none→fallback). SPEC row +
SPEC-CHANGES #5. **Battery: one ContentObserver + ≤1 alarm per
registration, boundary-armed; zero polling.**

### Phase 5 — `sms.received` + `call.state`

`TriggerHost`: `SUPPORTED_TYPES` += both. `smsReceiver`
(`Telephony.Sms.Intents.SMS_RECEIVED_ACTION`, registered only when
RECEIVE_SMS granted; `getMessagesFromIntent`, concat multipart; substring
match on `from`/`contains`; data per `include_body`). `callStateReceiver`
(`ACTION_PHONE_STATE_CHANGED`, only when READ_PHONE_STATE granted; dedupe
duplicate broadcasts via last-state transition memory — the broadcast
arrives once per phone account and again with the number under
READ_CALL_LOG; a `number`-filtered row without an available number never
fires; `include_number` gates the data field). KDoc: context-registered,
so these are live only while the FGS runs (deliberate — dead bridge =
deaf app). `StateSampler` += `call.state` (sms is edge-only, stays out).
`permissionMap` += `receive_sms, read_phone_state, read_call_log`.
Manifest: the three permissions. `jetpacs-device--perm-info` += three
rows; lint += `call.state`. Kotlin `SmsCallMatchTest.kt` (pure matchers:
`smsRowMatches`, `buildSmsData` body-omitted-by-default, `callStateDedupe`
transitions). SPEC rows + privacy caveats + SPEC-CHANGES #6. **Battery:
two permission-gated receivers, armed only with matching rows; zero
standing cost beyond the FGS.**

### Phase 6 — hardware acceptance + closeout

Flip this file's STATUS; run the checklist below; file follow-ups.

## On-device acceptance checklist

Emulator first (`adb emu power ac on/off`, `adb emu sms send`,
`adb emu gsm call/accept/cancel`, quick-settings wifi/airplane, AOSP
Calendar): Phases 1–2 fully; wifi.enabled/calendar/sms/call functionally.
Hardware pass:

1. Gate correctness: `battery.level below 20` gated on `{power
   state=disconnected}` — no fire while charging across the threshold;
   unplug + cross → one fire; the suppression did **not** consume
   `throttle_s`.
2. `time.window`: a `time every_s` trigger gated to a 2-minute window;
   fires inside, silent outside; the wrap-midnight case once.
3. `state.get` round trip from desktop Emacs: coherent `states` +
   `holds`; ungranted calendar shows in `unavailable`, not an error.
4. Dynamics: an on_fire notification shows substituted `${data.*}`;
   unknown token renders literally.
5. `bluetooth.enabled` on hardware (no emulator BT stack): edges both
   directions + predicate samples correctly.
6. Calendar on a synced account: start fires within alarm tolerance;
   ongoing predicate holds mid-event, releases at end; editing the event
   re-arms (observer path); reboot mid-event re-arms; Doze spot-check
   with exact-alarms granted vs revoked.
7. SMS/call on a real SIM: multipart body assembled; `include_body` off →
   no body on the wire (inspect the frame / queue DB); dual-SIM duplicate
   broadcasts fire once; number present only with READ_CALL_LOG +
   `include_number`.
8. Permission degrade, every gated type: revoke while armed → no garbage
   fires, `Log.w` only; perms map correct on the next welcome;
   automations + permissions UI accurate; grant → re-arm on the next
   `triggers.set` / service restart.
9. Old-companion simulation: the previous APK against new elisp with a
   `when`-carrying registration → the registration is skipped client-side
   (message); nothing ungated arms.
10. Migration: upgrade over a v3 DB with armed triggers → the set
    survives, re-arms, `whenJson` null-safe.

## Rejects (and what serves instead)

- **Rule graphs / predecessors** (Easer's Scripts, the reverse/negation
  edges) — composition lives in elisp; Emacs is the brain. A `when` gate
  is a leaf condition, not a graph.
- **OR / nesting / negation operators in `when`** — flat AND only; the
  complement of a two-valued predicate is the flipped value; a gate
  needing OR is two registrations, or "keep Emacs alive."
- **Generic broadcast / arbitrary-intent trigger type** — an unvetted
  vocabulary that violates §11's closed-catalog discipline; ingress from
  other apps is [PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md)
  Task 6's job, action-name-only.
- **on_fire trigger-toggling / self-mutation** — the companion never
  edits its own trigger table; replace-set stays the only writer.
- **Expressions / format specifiers in dynamics** — flat substitution
  only; no `${data.level:%03d}`, no arithmetic. Formatting is
  presentation logic and belongs in Emacs.
- **Re-planning `wifi.ssid`, `bluetooth.device`, `notification.posted`,
  JobScheduler constraints** — owned by PLAN-device-and-surfaces Tasks
  1–3; the predicate catalog is designed so they slot in as `state_types`
  entries when they land.
- **The rest of the telephony class** — READ_CONTACTS name resolution,
  outgoing SMS, call-log queries, telephony effectors. Only the two
  overriding items land; the reject otherwise stands.

## Resolved decisions (proposed defaults — owner accepts or overrides)

1. Land **in the foundation** (§10/§11 + `:jetpacs`), not a Tier-1 app —
   these are protocol/effector/trigger growth, the same class as every
   other §10/§11 entry.
2. **`when` gates the whole fire** (decision a), not just `on_fire`.
3. **Client-side skip is mandatory** (the critical hazard); no
   strip-and-push, ever.
4. **SMS/call Play-hostility is accepted cost** — this is a personal-use,
   F-Droid-class companion (ROADMAP item 10 is F-Droid anyway). Recorded
   here and in the PLAN-device-and-surfaces amendment.

## Suggested sequencing

Phase 1 first (smallest, no negotiation). Phase 2 is the keystone
(everything after it is catalog growth against the `when`/`state_types`
machinery it builds). Phases 3–5 are mutually independent; Phase 5 last
if the Play-hostile permissions are a distribution concern. Phase 6 needs
hardware. Nothing here blocks or is blocked by the transport, battery, or
device-and-surfaces plans except by choice.
