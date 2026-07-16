# Audit: Termux as guidance for the jetpacs API — the survey delta

**STATUS (2026-07-16): advisory, not yet approved.** A second read of
the four Termux checkouts (`termux-api`, `termux-app`, `termux-gui`,
`termux-widget`, siblings of this repo under
`../termux/`), this time for **API mechanics** rather than catalog.
The 2026-07-14 Termux survey already produced three plan docs —
[PLAN-transport-profiles.md](PLAN-transport-profiles.md),
[PLAN-battery-discipline.md](PLAN-battery-discipline.md),
[PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md) — which at
the time of writing are **untracked WIP in the primary checkout's
`docs/`** (this worktree cannot see them; the links resolve once they
land). This audit is the *delta*: what a fresh source pass found that
those plans did not bank, plus a drift check on their citations.
Nothing here re-litigates a banked decision; every candidate below was
first tested against the three plans and rejected as "already covered"
or admitted as new. One item (A3) is a **defect-class finding**, not a
borrowing.

## Why

The 2026-07-14 survey read Termux for its *catalog* (which effectors,
triggers, and surfaces earn their permission and battery cost) and its
*transport* (UDS, peer credentials, fd-passing). This pass reads it
for the connective tissue between catalog entries: how results return,
how permissions get requested mid-call, how errors are typed into the
contract, how exported entry points are guarded against forged
intents, and what a bounded stream looks like. Termux is the
decade-tested prior art for exactly the seams jetpacs is about to
harden — Transport 1.0, external ingress, the second-companion
conformance push — so the mechanics deserve their own pass before
those plans execute.

## What the 2026-07-14 survey already banked (so we don't relitigate)

| Banked idea | Where it lives |
|---|---|
| UDS listener + SO_PEERCRED TOFU pin (termux-api `SocketListener.java:46` idiom) | transport plan S0–S3 |
| SCM_RIGHTS fd-passing / shared-memory buffers (termux-gui `addBuffer`, `WithAncillaryFd`) | transport plan S7 memo (uds-only, negotiated) |
| Rejects: protobuf dual wire, `sharedUserId`, filesystem-namespace UDS (NDK cost), native TLS | transport plan Rejects |
| Idle self-stop, opt-in wakelock on the FGS notification, screen-state throttle (`TermuxService.java:305-355`, `~853`) | battery plan B1–B3 |
| notification-listener source, JobScheduler constraint triggers, Keystore secrets, speech input | device plan Tasks 1, 2, 4, 5 |
| RUN_COMMAND-posture allowlisted ingress (permission + default-off master setting) | device plan Task 6 |
| Device Controls slots; PiP/overlay/lockscreen activity modes | device plan Tasks 7–8 |
| Lifecycle semantics pinned as normative SPEC text (termux-gui `Protocol.md` as the model) | device plan Task 9 |
| Full 37-API sweep rejected (menu, not mandate); `sms.received`/`call.state` exercised item-by-item | device plan Rejects + [PLAN-conditions-and-dynamics.md](PLAN-conditions-and-dynamics.md) (that batch has since **landed** — `TriggerHost.kt:452-460`) |

The frontier below is what's left.

## Method

Each candidate is argued against four tests, in order:

1. **Delta only** — not already banked in the three plans, ROADMAP, or
   landed code. (This is the test the vui audit didn't need; here it
   kills most of what a naive Termux read would propose.)
2. **Architecture fit** — *rich server, thin client*; the SPEC §5
   command-dispatch boundary (nothing on the wire names code); the
   standing battery gate; fail-closed privacy.
3. **Wire cost** — nothing new on the wire unless additive and
   negotiated; companion-local behavior preferred.
4. **Concept cost** — what an author or companion-implementer must
   newly learn.

## Tier A — adopt now (no wire change)

### A1. Runtime-permission auto-request — the `TermuxApiPermissionActivity` pattern

termux-api handles a missing permission in one motion
(`termux-api/.../activities/TermuxApiPermissionActivity.java:30-58`):
`checkAndRequestPermissions` **returns the machine-readable error to
the caller immediately** and, in the same breath, launches a
no-display Activity that calls `requestPermissions(...)` and
finishes — so the *next* invocation succeeds without the user ever
visiting Settings.

jetpacs has the first half exactly right: a typed `cap-permission`
error carrying the permission name and a Settings deep-link
([`DeviceCapabilities.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/DeviceCapabilities.kt)
§41-42, thrown at e.g. 171, 524, 596), surfaced by the Device
permissions dialog
([`jetpacs-device.el`](../emacs/core/jetpacs-device.el) §305-373). But
the *only* grant path is the deep-link. That is correct — and forced —
for **special-access** permissions (write-settings, DND access,
notification-listener: Android never pops a dialog for those). It is
needlessly indirect for **runtime-dangerous** permissions
(post_notifications, fine_location, read_calendar, receive_sms,
read_phone_state, read_call_log — six of the eleven in
`permissionMap`, `DeviceCapabilities.kt:656-674`), where the platform
*wants* to pop its own dialog and jetpacs never asks.

Adopt the pattern for the runtime-dangerous subset: on
`cap-permission`, the companion still fails the invoke immediately
(never park a `capability.result` on a human), and *additionally*
launches a transparent trampoline activity requesting the permission.
The manifest already has the trampoline idiom to copy
(the `noHistory`/`singleInstance` activity at
[`AndroidManifest.xml:120-127`](../jetpacs/src/main/AndroidManifest.xml)).
Special-access permissions keep the deep-link; the elisp dialog stays
as the offline/overview surface.

One consequence to flag, not design here: the welcome's `perms` map is
a snapshot, refreshed only on reconnect. An in-flow grant makes the
staleness visible (Emacs still believes the permission is missing).
Options when it bites: re-report perms via an existing push kind, or
let elisp retry-on-error rather than gate-on-map. The retry idiom
costs nothing today.

Tests: delta ✓ (no plan touches the grant *flow*); fit ✓
(companion-local UX, fail-closed unchanged); wire ✓ (zero — the error
contract is untouched); concept ✓ (one activity, invisible to
authors).

### A2. Error codes become contract vocabulary

termux-gui ships its error taxonomy **in the schema**: a protobuf
`enum Error` with documented, stable values — `ACTIVITY_STOPPED`,
`INVALID_ACTIVITY`, `INTERNAL_ERROR`, … (`termux-gui/.../GUIProt0.proto:243+`).
A client can program against failure modes; a second implementation
cannot invent its own spelling.

jetpacs has typed codes in prose and code — `cap-unsupported` /
`cap-permission` / `cap-failed` (SPEC §10;
`DeviceCapabilities.kt:41-42`) plus whatever the envelope-level
`error` frame carries — but the contract pins only the error frame's
*keys*, not its *values*: `("error" both (code) (detail perm settings))`
([`jetpacs-lint.el:210`](../emacs/core/jetpacs-lint.el)). `contract.json`
has no error-code list at all
([`build-contract.el:103-131`](../emacs/build-contract.el)). A
clean-room companion learns the vocabulary by reading Kotlin.

Adopt: an `error_codes` key in `jetpacs-contract`, sourced from a new
lint table (the same single-source pattern as every other vocabulary
in that file), enumerating the envelope codes and the three `cap-*`
codes. That is a `contract_format` 3→4 bump by the file's own
precedent (format 2 added `spec_version`; format 3 renamed a key —
`build-contract.el:33-39`), so it belongs beside the in-flight
spec-freeze track, landing with its SPEC-CHANGES row and a goldens
note. Cheap, additive, and exactly the kind of thing the conformance
kit exists to pin.

Tests: delta ✓; fit ✓; wire — no frame changes, contract file only;
concept ✓ (codifies what already exists).

### A3. The shortcut trampoline accepts forged actions — adopt termux-widget's token

**The finding.** This audit walked jetpacs' companion-side entry
points against termux-widget's threat model:

- `ActionReceiver` — `exported="false"`, targeted directly by
  app-owned PendingIntents. Safe.
- QS tile services — `exported="true"` but bind-gated by the
  system-only `BIND_QUICK_SETTINGS_TILE` permission. Safe.
- Widget providers — standard `AppWidgetProvider` posture. Safe.
- **The launch trampoline — open.** Pinned/dynamic shortcuts embed
  their semantic action as a plain string extra on an intent that
  targets the host's *launcher activity*
  (`JetpacsLaunch.openAppIntent`,
  [`JetpacsLaunch.kt:31-35`](../jetpacs/src/main/java/com/calebc42/jetpacs/JetpacsLaunch.kt);
  built at `DeviceCapabilities.kt:362-370`). A launcher activity is
  exported by definition. On arrival,
  `MainActivity.handleWidgetIntent`
  ([`MainActivity.kt:124-137`](../app/src/main/java/com/calebc42/jetpacs/MainActivity.kt))
  rebroadcasts `EXTRA_WIDGET_ACTION` into the live/queue/wake pipeline
  with **no check of who sent the intent**. Any installed
  zero-permission app can therefore synthesize a tap on *any*
  §5-allowlisted action.

The blast radius is bounded — the §5 boundary holds (only registered
actions with validated args execute; never code), and launching an
activity brings jetpacs visibly to the foreground — but "any app can
fire any allowlisted action" is exactly the exposure termux-widget
judged worth closing in the identical structural situation (launcher
shortcuts can only start activities, so the entry *must* be an
exported activity). Their fix is three lines per side: a per-install
`UUID.randomUUID()` stored in prefs, stamped into every shortcut
intent at creation (`termux-widget/.../ShortcutFile.java:91`), and
compared on arrival — mismatch drops the execution
(`TermuxWidgetProvider.java:241-242`).

Adopt verbatim: generate the token once in the `:jetpacs` library,
stamp it in `buildShortcut` (and the widget-row/QS trampoline path,
which flows through the same `handleWidgetIntent`), verify in the
trampoline before rebroadcast; on mismatch open the app without firing
the action. Like termux-widget, never rotate the token (the launcher
persists pinned-shortcut intents; rotation would brick old pins).

Tests: delta ✓ (no plan covers app-side entry hardening); fit ✓
(strengthens §5 rather than bypassing it); wire ✓ (zero — the token
lives inside companion-composed intents, invisible to Emacs); concept
✓. **Do first; it is the only item here that closes a hole rather than
adds a nicety.**

**Landed 2026-07-16** (same branch, commit after this audit): token
generated once in `JetpacsLaunch`, stamped by the action-carrying
`openAppIntent` overload (covering shortcuts, widget rows, QS tiles,
and the trampoline in one place), verified by
`MainActivity.handleWidgetIntent` before rebroadcast. Absent or
mismatched token opens the app without firing — which also means
pinned shortcuts created *before* the token existed degrade to
open-only and need a re-pin. (Correction, same day: Glasspane ships no
shell of its own — it is elisp-only — so this repo's `:app` is the
only `JetpacsLaunch` host and is already gated. Any *future* host must
add the same `verifyToken` gate per the `JetpacsLaunch` contract doc.)

## Tier B — amendment notes for the existing plans

These are not new work items; they are findings the owner may fold
into the (currently untracked) plan docs they refine.

### B1. Ingress result-return, and the violation notification (→ device plan Task 6)

Task 6's ingress surface is fire-only, which is right for v1. When a
Tasker-class caller eventually needs an *answer*, Termux already
designed the arms-length shape twice over: the caller hands a
`PendingIntent` and gets a result bundle (`stdout`/`stderr`/
`exit_code`/`err`/`errmsg`, plus original-length keys for truncation
honesty), **or** names a result directory and gets files —
per-request, caller's choice (`TermuxConstants.java:1169-1176`;
`TermuxPluginUtils.setPluginResultPendingIntentVariables`,
`.../plugins/TermuxPluginUtils.java:209`). Record that as the v2
result channel so nobody invents a socket for it.

Second, the posture detail that makes the default-off master setting
trustworthy: when an external app attempts ingress while the property
is off, termux **force-shows a notification** naming the caller
(`checkIfAllowExternalAppsPolicyIsViolated`,
`TermuxPluginUtils.java:457`) — the refusal is visible, so a user
who *wants* the integration discovers the setting, and one who
doesn't learns someone knocked. Task 6's "refuses everything" should
refuse *loudly*.

### B2. The wake-Emacs spike is runnable today (→ ARCHITECTURE.md's open spike)

[ARCHITECTURE.md](ARCHITECTURE.md) §"Execution model" leaves a
timeboxed spike open: can the companion silently start a
Termux-signed Emacs? The RUN_COMMAND read turns that from research
into a recipe:

- **Caller side (one manifest line):** the companion declares
  `<uses-permission android:name="com.termux.permission.RUN_COMMAND"/>`
  (`TermuxConstants.java:886`). It is a normal-ish dangerous
  permission granted at install for same-cert or via the permission
  screen.
- **Termux side (one property):** `allow-external-apps=true` in
  `~/.termux/termux.properties` — the same gate the Emacs-APK
  ecosystem already documents for Tasker.
- **The intent:** action `com.termux.RUN_COMMAND`
  (`TermuxConstants.java:1135`) as a **service** intent to
  `com.termux/.app.RunCommandService`, extras
  `RUN_COMMAND_PATH` (an absolute path to a start-emacs script under
  the Termux prefix), optional `RUN_COMMAND_ARGUMENTS` (String[]),
  `RUN_COMMAND_RUNNER = "app-shell"` (background, no terminal UI).
- **The kicker:** jetpacs' existing `intent.start {mode: "service"}`
  capability can fire exactly this intent — so once the manifest line
  lands, the *entire spike is an elisp expression* plus on-device
  observation. What the spike actually measures is the Android-12+
  question: whether a background companion (its own FGS running,
  or woken by an alarm/receiver) may start another app's
  foreground-service-starting service — the OS may throw
  `ForegroundServiceStartNotAllowedException` on the Termux side.
  That's the result worth recording either way, per the spike's own
  terms.

### B3. Bounded streams, when the continuous-sensor story wakes (→ device plan Rejects note)

The device plan parks streams ("belong to a future continuous-sensor
story"). When that story wakes, termux-api already shows the
battery-respecting shape, worth recording now so the future design
starts bounded:

- `SensorAPI`: one request is either SINGLE or CONTINUOUS with an
  explicit `delay` (ms between readouts) **and** `limit` (max
  readouts) — the writer thread self-terminates at the limit
  (`SensorAPI.java:338-344, 406-415`).
- `LocationAPI` `updates` mode: streams fixes, then **auto-terminates
  after 30 s** (`LocationAPI.java:95, 127`).

The rule to bank: every continuous source is bounded in count and/or
duration, terminates itself, and renewal is the client's explicit
re-request; delivery rides `event.action` like `trigger.fired` does.
An unbounded subscription never enters the vocabulary.

### B4. Lifecycle numbers for the SPEC pinning (→ device plan Task 9)

Task 9 already names termux-gui's `Protocol.md` as the model. The
specific rules worth transposing, with their numbers:

- Value-returning methods **fail** when the target isn't visible; up
  to **100** fire-and-forget methods queue and replay on visibility
  (`Protocol.md:6-7,148`). The nuance: only fire-and-forget can queue —
  a request/response method must fail fast (jetpacs already lives
  this: `capability.invoke` fails typed, `surface.update` is
  fire-and-forget against a cache).
- The event queue toward the client is **bounded (10000) and drops on
  overflow** (`ConnectionHandler.kt:48-49`). Jetpacs' offline queue
  should get an explicit pinned bound + overflow policy in §6 when
  Task 9 writes the rules — today the bound is implicit.

## Tier C — new capability candidates (menu, on demand)

Additions to SPEC §10's open set — each additive, negotiated by
presence in the welcome's `caps`, and idle until a story demands it.

### C1. `biometric.auth` — presence attestation for the locked-notes story

termux-api's `FingerprintAPI` wraps the biometric prompt as a
one-shot call. The jetpacs shape: `biometric.auth {title?, subtitle?}`
→ `{ok}` over `BiometricPrompt`; `USE_BIOMETRIC` is a *normal*
permission (no grant UX at all); zero background cost. The story it
serves is already on the books: org-crypt is an open orgro-parity
gap, and "unlock this subtree on the phone" wants a device-side
presence check before Emacs pushes decrypted content. Honest limit,
stated up front: Emacs holds the plaintext, so this is an *attestation
gate*, not a cryptographic one — which is exactly right for a
same-person, two-device PKM flow.

### C2. Share-target capture (inbound share sheet → `event.action`)

termux-api's `ShareAPI` registers as an ACTION_SEND target and hands
shared files/text to scripts. The jetpacs analog closes a *named* gap
(orgzly-parity: image share): the `:app` shell registers as a share
target; a received `content://` payload is copied to an app-owned
cache file (the hypertext image cache,
[`jetpacs-hypertext.el`](../emacs/core/jetpacs-hypertext.el), is the
in-repo precedent for content-addressed, size-capped file handoff);
then a `share.received {path, mime, text?}` **semantic action** rides
the ordinary live/queue/wake pipeline. No new frame kind — it is §5
registry vocabulary, like `trigger.fired`. Unlike Task 6's
machine-to-machine ingress, no master setting is needed: the system
share sheet *is* the user's consent, per interaction.

### C3. Capture-to-caller-path — the binary convention, recorded once

termux-api never streams a photo or a recording over the control
socket: `CameraPhotoAPI` and `MicRecorderAPI` write to a file and
return status. jetpacs independently converged on the same shape
(hypertext images land in a cache dir; the wire carries a `file://`
URL). If camera/mic/screenshot capabilities ever join §10, the
convention is already proven on both sides: **binary goes to a
companion-readable path; the wire carries the path.** One paragraph in
the device plan (or CONTRIBUTING-NODES) makes it standing policy
instead of a rediscovery. On the `tcp-remote` profile the path story
changes (no shared filesystem) — which is precisely why it should be
recorded as a *convention with a profile caveat*, not folklore.

## Tier D — explicitly do NOT adopt

Recording the *why* so they aren't re-proposed:

- **A second wire format.** Already rejected (transport plan Rejects);
  this pass adds the reinforcing evidence from inside termux-gui
  itself: the JSON handler opens with "Sorry for this mess. New
  features will likely only be in the protobuf protocol"
  (`V0Json.kt:30-31`; echoed at `Protocol.md:26`). Maintaining two
  wire grammars froze one of them within a single project's lifetime.
  NDJSON stays the contract.
- **`am`-string ingress grammar.** termux-api's persistent listener
  reconstructs typed intent extras by *regex-parsing an `am` command
  line* (`SocketListener.java:24-31`) — expedient for shell
  compatibility, brittle everywhere else. Recorded so Task 6's ingress
  never grows an "am-style" string payload; typed extras / typed JSON
  only.
- **The versioned-constants-file contract.** `TermuxConstants.java`
  (v0.53.0) is a hand-maintained changelog header plus per-constant
  `// Default:` value comments — their whole contract in one Java
  file. jetpacs' machine-generated `contract.json` + SPEC-CHANGES rows
  are the stronger mechanism; the one borrowable habit is the
  `// Default:` annotation style for constants like `Envelope.kt`'s
  kinds. Doc hygiene at most.
- **Parallel per-surface APIs.** termux-gui exposes three disjoint
  view systems (Activity Views, RemoteViews for widgets, custom
  notifications), each with its own create/manipulate vocabulary.
  jetpacs' single node grammar rendered across surface classes
  (`app:*` / `widget:*` / `tile:*` / `notification:*` / dialog) is the
  strictly better design — an author learns one tree. Keep it;
  never import the split.

## Plan-citation drift notes

Read-only observations for the owner (the three plans are their
untracked WIP; nothing here was staged or edited). Verified 2026-07-16
against this worktree's source. The drift is concentrated in the
device plan and post-dates it honestly: the conditions-and-dynamics
batch landed after it was written, moving `TriggerHost.kt` around.

| Doc | Citation as written | Current source |
|---|---|---|
| device plan | `DeviceCapabilities.handlers` "74–91, ~19 caps" | 74–92, **17** caps |
| device plan | "permission map at 619–633" | `permissionMap` at 656–674 |
| device plan | `TriggerHost.SUPPORTED_TYPES` "342–345" | 452–460 (15 types, incl. the landed `sms.received`/`call.state`) |
| device plan | "`arm()` arm (109–147)" | `arm(` at 98 |
| device plan | "`fireRow()` (357–403)" | `fireRow` at 555 |

Checked and still accurate: transport plan's `JetpacsServer.kt:32`,
`JetpacsConnection.kt` `handleHello`/`handleAuthResponse` (213/237),
`SocketListener.java:24-31, 46`; battery plan's `BridgeService.kt`
72 / 86–99 and `TermuxService.java` 305–355 / ~853. The device plan's
STATUS ("nothing landed") remains true *for its own tasks*; only its
"state of the world" line numbers aged.

## Recommendation

Ordered by value-per-cost:

1. **A3 (trampoline token)** — the one defect-class item; the fix is
   termux-widget's three-lines-per-side idiom, entirely
   companion-local. Do first.
2. **B2 (wake-Emacs spike)** — one manifest line turns an open
   architecture question into an elisp one-liner plus an evening of
   on-device observation; the answer (either way) unblocks the
   execution-model story.
3. **A1 (permission auto-request)** — small companion change, real UX
   win on six of eleven mapped permissions.
4. **A2 (`error_codes` in the contract)** — rides the spec-freeze /
   conformance track; land it beside a contract regen so the format
   bump pays for itself.
5. **B1/B3/B4** — one-evening amendment notes for the owner to fold
   into the plan docs they already maintain.
6. **Tier C** — stays a menu. C2 (share-target) has the clearest
   demand signal (a named parity gap); C1 waits for the org-crypt
   story; C3 is a paragraph of policy whenever the device plan next
   opens.

## References

- Termux checkouts —
  `C:\Users\caleb\AndroidStudioProjects\termux\{termux-api, termux-app, termux-gui, termux-widget}`:
  `TermuxApiPermissionActivity.java`, `SocketListener.java`,
  `SensorAPI.java`, `LocationAPI.java`, `FingerprintAPI.java`,
  `ShareAPI.java`, `CameraPhotoAPI.java`, `MicRecorderAPI.java`
  (termux-api); `RunCommandService.java`, `TermuxService.java`,
  `TermuxConstants.java`, `TermuxPluginUtils.java` (termux-app);
  `Protocol.md`, `GUIProt0.proto`, `V0Json.kt`, `ConnectionHandler.kt`
  (termux-gui); `TermuxWidgetProvider.java`, `ShortcutFile.java`
  (termux-widget).
- The 2026-07-14 survey plans (untracked WIP in the primary checkout) —
  [PLAN-transport-profiles.md](PLAN-transport-profiles.md),
  [PLAN-battery-discipline.md](PLAN-battery-discipline.md),
  [PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md).
- jetpacs — [`DeviceCapabilities.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/DeviceCapabilities.kt),
  [`JetpacsLaunch.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/JetpacsLaunch.kt),
  [`MainActivity.kt`](../app/src/main/java/com/calebc42/jetpacs/MainActivity.kt),
  [`TriggerHost.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/TriggerHost.kt),
  [`build-contract.el`](../emacs/build-contract.el),
  [`jetpacs-lint.el`](../emacs/core/jetpacs-lint.el),
  [`jetpacs-device.el`](../emacs/core/jetpacs-device.el),
  [ARCHITECTURE.md](ARCHITECTURE.md), [ROADMAP.md](ROADMAP.md).
- Standing decisions — *rich server, thin client*
  ([ROADMAP.md](ROADMAP.md)), the §5 command-dispatch boundary
  ([ARCHITECTURE.md](ARCHITECTURE.md)),
  [CONTRIBUTING-NODES.md](CONTRIBUTING-NODES.md).
