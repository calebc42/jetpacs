# Plan: Device automation (Tasker parity) & the Glasspane launcher

**STATUS (2026-07-05): in progress — Phase P (Tasks 1–2) landed
2026-07-05; everything else not started.** Note: Kotlin file paths below
predate the `:eabp`/`:app` module split — protocol code now lives under
`eabp/src/main/java/com/calebc42/eabp/` (rule: protocol → `:eabp`,
opinion → `:app`).

Produced 2026-07-05 from an audit of the repo against two visions:

1. **Automation** — elisp + Glasspane tied into Android internals deeply
   enough to replace Tasker with a fully FOSS stack.
2. **Launcher** — one installed Glasspane hosting many user-authored
   "builds" (Tier 1 apps), AppSheet-style: pick an app from a launcher,
   pin it to the home screen, install new ones without touching Kotlin.

Each task is self-contained: goal, files, implementation notes,
pitfalls, acceptance. The two tracks (A = automation, L = launcher) are
independent after the shared protocol phase; tasks within a phase are
independent unless noted.

---

## Audit part 1 — what already exists (do not rebuild)

The happy surprise of this audit: **most of Tasker is already here**,
because elisp is a better task language than Tasker's, and the surface
system is a better scene system. The protocol even reserved the missing
seams: `"triggers"` and `"capabilities"` are negotiated in the handshake
on both sides (`emacs/core/eabp.el` `eabp-wants`,
`EabpConnection.kt:45`) but explicitly stubbed — `Envelope.kt:29`:
"capability.\*, trigger.\*, … arrive later."

| Tasker concept | eabp status |
|---|---|
| Tasks (action sequences) | ✅ elisp functions — strictly superior |
| Variables / state | ✅ elisp |
| Scripting (JS/shell escape hatch) | ✅ the whole system *is* the escape hatch |
| Scenes (custom UI) | ✅ surfaces + dialogs + widget vocabulary |
| HTTP request / REST | ✅ `url.el` / `plz` in Emacs, no bridge needed |
| File operations | ✅ Emacs (+ Termux-shared storage) |
| Time triggers / alarms | 🟡 `reminders.set` fires **notifications** via exact alarms; can't yet fire *actions* |
| Notifications (post/update/ongoing) | ✅ notification surfaces |
| Quick Settings tiles | ✅ capture tile + 5 elisp-composed slots |
| Home-screen widgets | ✅ agenda + clock + 5 elisp-composed slots |
| Share-sheet intake | ✅ ACTION_SEND text/plain → capture |
| Clipboard set | ✅ `clipboard.copy` builtin |
| Run-when-device-was-offline | ✅ offline queue + replay + `wake` policy |
| **Profiles (event/state triggers)** | ❌ the big one — no device→Emacs event path |
| **Device actions (launch app, toggle, TTS, …)** | ❌ no Emacs→device effector path |
| **Run with Emacs dead** | 🟡 wake = tap-a-notification; nothing runs unattended |
| **Boot persistence** | ❌ no `BOOT_COMPLETED` receiver (alarms silently die on reboot until the next Emacs connect re-pushes) |

For the launcher vision:

| AppSheet concept | eabp status |
|---|---|
| Apps defined as data/config, not APKs | ✅ Tier 1 = elisp packages; live-reload dev loop |
| Host renders any app | ✅ shell view registry + multi-view surfaces |
| Managed config on device | ✅ `glasspane-config.el` (sync/ensure contract) |
| Package discovery/install UI | 🟡 package browser exists (ELPA), no Tier 1 story |
| **App identity / one-app-at-a-time chrome** | ❌ all registered views merge into ONE tab bar |
| **Launcher home + per-app entry points** | ❌ no home grid, no shortcuts, no pinning |
| **Install a build from a file/link** | ❌ no import flow, no consent UX |
| **Non-programmer app authoring** | ❌ (the org-parser is the natural substrate — see Task 19) |

## Audit part 2 — the four deltas per track

**Track A (automation):**
- **A1. Effectors** — `capability.invoke`: Emacs fires device actions
  (intents, volume, flashlight, TTS, …). Cheap, high value, each one small.
- **A2. Trigger host** — the companion becomes a durable event source
  the same way it is a durable UI server: persisted trigger table,
  receivers riding the existing foreground service, delivery through
  the *existing* event queue.
- **A3. Emacs-dead execution** — companion-local responses attached to
  triggers, plus an honest wake story.
- **A4. Authoring UX** — `eabp-deftrigger`, an Automations view,
  org-file-defined rules.

**Track L (launcher):**
- **L0. App identity** — group views into named apps; launcher home
  view; per-app chrome. Almost pure elisp.
- **L1. OS entry points** — pinned/dynamic shortcuts per app; slot
  assignment for widgets/tiles.
- **L2. Distribution** — single-file build bundles, import with real
  consent, installed-apps registry.
- **L3. Declarative org apps** — the actual AppSheet analog: an app
  authored as an org document, no elisp required.

## Hard constraints (Android realities — read before estimating)

- **Silent background launch of a dead Emacs is not available.**
  Background-activity-launch is blocked; notification trampolines are
  banned on targetSdk 31+. `EmacsWaker` already does the two compliant
  things (opportunistic launch + tap-to-open notification). Plan
  accordingly: A3 is about *not needing* Emacs for the common cases,
  not about magic wakes. Task 11 timeboxes the remaining options.
- **Implicit-broadcast restrictions (API 26+)** kill manifest receivers
  for most events (battery, screen, connectivity). They must be
  **context-registered on a live process** — and `BridgeService` is
  already a persistent special-use FGS, so trigger listening rides it
  for free. This is an architectural advantage: Tasker pays the same
  FGS cost; we already paid it.
- **Wi-Fi SSID requires `ACCESS_FINE_LOCATION`** + location services on
  (Android's SSID-as-location rule). Connect/disconnect without SSID is
  permission-free via `ConnectivityManager` callbacks.
- **Wi-Fi and Bluetooth cannot be toggled programmatically** on modern
  Android (Q+ / T+). The compliant effector is the system **settings
  panel** (`Settings.Panel.ACTION_WIFI` etc.) — one tap, not zero. Say
  so in the docs rather than pretending.
- **Special-access permissions** each need a user trip to Settings:
  `WRITE_SETTINGS` (brightness), notification-policy access (DND),
  notification-listener access (Task 9), usage stats (explicit
  non-goal). The handshake already reports `canScheduleExactAlarms`;
  Task 2 generalizes that into a device-permission map so elisp can
  degrade gracefully and deep-link to the right settings page.
- **Battery is the first-order constraint** (see user memory: pure
  elisp over binaries, unprofiled battery is the top concern).
  Classification: broadcast/callback triggers ≈ free; alarms ≈ free;
  polling, sensors, and location are opt-in and each fire wakes Emacs
  → the trigger host must throttle (per-trigger min interval,
  hysteresis on battery-level thresholds).
- **FOSS constraint:** no Play Services. Geofencing = platform
  `LocationManager` only (proximity alerts / manual fencing), no fused
  provider, no FCM (irrelevant — everything is local anyway).
- **SMS / call-log permissions** are Play-Store-hostile but fine on
  F-Droid. Deferred to the non-goals section pending a distribution
  decision.

## Repo conventions (read first)

- Sources live in `emacs/core/` and `emacs/apps/`; root `eabp-core.el`
  and `glasspane.el` are **generated** — regenerate with
  `emacs --batch -l emacs/build-bundle.el` after edits.
- Tests: `emacs -Q --batch -l test/eabp-tests.el -f
  ert-run-tests-batch-and-exit`; regen `test/widgets.golden` only on
  intentional wire changes.
- **Command-dispatch boundary (SPEC §5) still rules.** Triggers deliver
  as ordinary `event.action` frames whose names Emacs registered —
  the wire still never names code. `capability.invoke` flows the
  *other* direction (Emacs → device); Emacs is already the trusted
  party post-handshake (it drives notifications and reminders), so
  effectors are consistent with the existing trust model. New action
  namespaces to reserve in SPEC §5: `trigger.*`, `app.*`.
- Core stays org-free (`test/core-load-test.el` enforces). The trigger
  plumbing is core (`eabp-triggers.el`); org-rule parsing is Tier 1
  (`glasspane-automations.el`).
- New org-syntax parsing (Tasks 13, 19) follows the case conventions:
  keywords/drawers case-insensitive with explicit `case-fold-search t`,
  and every new regex gets a case test.
- Wire additions must be additive (unknown kinds/attrs ignored) when
  the Kotlin counterpart can't land in the same pass.

---

## Phase P — protocol groundwork (paper first, both tracks blocked on it)

### Task 1: Specify `triggers.set` and trigger delivery ✅ (2026-07-05)

**Landed:** SPEC §11; `emacs/core/eabp-triggers.el` (registry,
replace-set push gated on the `triggers` grant, `trigger.fired`
dispatch); `test/frames.golden` pins the frame shape; ERT covers
push/gate/fire. The companion deliberately stopped claiming `triggers`
in its supported set until Task 6 lands, so the client's grant gate
holds.

**Goal:** a spec section (SPEC §11) both sides implement against.

**Files:** `docs/SPEC.md`, `emacs/core/eabp.el` (kind constants only).

**Implementation:**
- `triggers.set {triggers: [{id, type, params, policy, throttle_s?,
  on_fire?}]}` — client → companion, **replace-set semantics exactly
  like `reminders.set`** (the set replaces the previous set, so removed
  triggers never fire stale). Gated on the already-negotiated
  `triggers` capability.
- Firing delivers an ordinary `event.action {action: "trigger.fired",
  args: {id, type, data, at_ms}}` — reusing the entire existing
  offline-queue / replay / dedupe / wake machinery. `policy` is the
  standard `when_offline` vocabulary (`queue` | `drop` | `wake`).
  A battery-level trigger wants `drop` or a `dedupe` key; a
  "phone started charging, sync now" trigger wants `wake`.
- `on_fire` (optional) is the companion-local response for A3 — see
  Task 10; spec it now, implement later.

**Pitfalls:** don't invent a second event channel; the queue semantics
(dedupe, expiry, replay-after-snapshot) were hard-won. Trigger `data`
is plain JSON (SSID string, battery pct) — never anything executable.

**Acceptance:** SPEC §11 merged; golden-file test for the new frame
shape; `eabp-triggers.el` can send a set and receive a fire against a
fake server in ERT.

### Task 2: `capability.invoke` + device-permission report ✅ (2026-07-05)

**Landed:** SPEC §10; `eabp-capability-invoke` / `eabp-device-can-p` /
`eabp-device-cap-p` / `eabp-granted-p` in `emacs/core/eabp.el`;
`DeviceCapabilities.kt` dispatch seam with `settings.open` as the first
capability; welcome carries `device: {caps, perms}` (7-key perm map,
gated on the `capabilities` grant), replacing the old ad-hoc
`permissions` object.

**Goal:** the Emacs → device effector channel, with graceful degrade.

**Files:** `docs/SPEC.md`, `emacs/core/eabp.el`,
`app/src/main/java/com/calebc42/eabp/EabpConnection.kt`.

**Implementation:**
- `capability.invoke {cap, args}` client → companion, replied with
  `{ok, result?}` or `error {code: "cap-unsupported" |
  "cap-permission" | "cap-failed", detail}`.
- Extend `session.welcome` with `device: {caps: [names…], perms:
  {write_settings: bool, notification_policy: bool, notification_
  listener: bool, fine_location: bool, bluetooth_connect: bool, …}}`
  — the `canScheduleExactAlarms` precedent, generalized. Elisp helper
  `eabp-device-can-p` reads it; a `cap-permission` error carries the
  settings deep-link the companion can open on request
  (`capability.invoke {cap: "settings.open", args: {panel}}` is itself
  the first capability).

**Acceptance:** spec merged; invoking an unknown cap round-trips a
clean error; welcome carries the perm map end-to-end.

---

## Phase A1 — effectors (small Kotlin, big Tasker coverage)

New file `app/src/main/java/com/calebc42/eabp/DeviceCapabilities.kt`
(dispatch table keyed by cap name), called from `EabpConnection`.
Elisp counterpart `eabp-device.el`: one thin defun per cap
(`eabp-device-intent`, `eabp-device-flashlight`, …), all funneling
through one `eabp-device--invoke`.

### Task 3: `intent.start` — the universal escape hatch ✅ (2026-07-05)

**Landed:** `intent.start` (activity/broadcast/service, plain-data
extras), `app.launch`, `apps.list` in `DeviceCapabilities.kt`; the
`<queries>` element in the `:eabp` manifest; elisp
`emacs/core/eabp-device.el` (`eabp-device-intent`,
`eabp-device-app-launch`, `eabp-device-apps-list`, interactive
`eabp-device-launch-app` picker); SPEC §10 catalog table; arg shapes
pinned in `test/frames.golden`. On-device REPL check pending.

**Goal:** launch apps, deep links, share targets, anything with an
Intent — this alone covers the largest slice of Tasker's action list.

**Implementation:** `{cap: "intent.start", args: {action?, data?,
package?, class_name?, mime?, extras?, mode: "activity" | "broadcast" |
"service"}}`. Extras restricted to string/int/bool/float (plain data).
Activity mode adds `FLAG_ACTIVITY_NEW_TASK`. Also `app.launch {package}`
sugar via `getLaunchIntentForPackage` (the `EmacsWaker` pattern), and
`apps.list` (query launchable packages → label + package) so elisp can
build a `completing-read` app picker.

**Pitfalls:** Android 11 package-visibility — add a `<queries>` element
(`ACTION_MAIN`/`CATEGORY_LAUNCHER`) or `apps.list` returns nothing.
Background-activity-launch limits apply to *us* too: activity intents
fired while Glasspane is backgrounded may be dropped; document that
activity-mode effectors are reliable from foreground/notification
contexts, best-effort otherwise.

**Acceptance:** from the eval REPL on the phone,
`(eabp-device-intent :action "android.intent.action.VIEW" :data
"https://…")` opens the browser; `apps.list` feeds a picker.

### Task 4: permission-free effector batch ✅ (2026-07-05)

**Landed:** `vibrate`, `tts.speak` (lazy engine, 60 s idle release),
`volume.set`, `ringer.mode` (silent → `cap-permission` + DND
deep-link), `flashlight`, `media.key`, `clipboard.read`
(main-thread-hopped, foreground-only → typed error, never logged),
`settings.open`, `screen.keep_on` (window flag via
`EabpRuntime.keepScreenOn`, applied in `SduiScaffold` so it can't pin
the device from the background). VIBRATE permission added to the
`:eabp` manifest. Per-cap elisp wrappers in `eabp-device.el`; golden
covers every arg shape. On-device REPL pass pending.

**Goal:** the everyday Tasker verbs that need no special access.

**Implementation:** `vibrate {ms | pattern}` (VibratorManager),
`tts.speak {text, pitch?, rate?}` (TextToSpeech, lazy-init, release
after idle), `volume.set {stream, level}` + `ringer.mode {mode}`
(AudioManager; note ringer→silent needs DND access on some OEMs —
report `cap-permission`), `flashlight {on}` (CameraManager torch),
`media.key {key}` (AudioManager dispatchMediaKeyEvent),
`clipboard.read` (works only while Glasspane is foreground on 10+ —
return `cap-permission`-style error otherwise; never log contents),
`settings.open {panel}` (Wi-Fi/BT/volume panels — the compliant
"toggle"), `screen.keep_on {on}` (window flag, foreground only).

**Acceptance:** each cap exercised from the REPL; ungranted/unavailable
paths return typed errors, not crashes; golden test for arg shapes.

### Task 5: special-access effector batch ✅ (2026-07-06)

**Landed** (pulled forward from H4 the day on-device testing hit the
DND wall on `ringer.mode`): `brightness.set` + `dnd.set` behind their
grants with `cap-permission` deep-links, `settings.open {panel:
"app"}` for the app-info page (runtime grants), and the "Device
permissions" settings card → dialog in eabp-device.el listing every
perm from the welcome map with a Grant button (map refreshes on
reconnect). Same pass fixed the launch-app picker (companion dialog —
a desktop `completing-read` both fails to bridge from an async reply
and leaves Glasspane backgrounded, where Android drops the launch)
and made TTS engine-init failure visible as a toast.

**Goal:** brightness and DND, with the grant flow held to the same
standard as the rest of the UX.

**Implementation:** `brightness.set {level}` behind
`Settings.System.canWrite` → else `cap-permission` +
`ACTION_MANAGE_WRITE_SETTINGS` deep link; `dnd.set {mode}` behind
`isNotificationPolicyAccessGranted` → else deep link. Elisp side: a
Settings section "Device permissions" (via the existing
`eabp-settings-register-section`) listing each perm from the Task 2
map with an "open settings" action.

**Acceptance:** deny → invoke → typed error → open settings → grant →
invoke succeeds, no restart needed (re-check at invoke time, cached
perm map refreshed on reconnect).

---

## Phase A2 — the trigger host (the heart of Tasker parity)

### Task 6: companion trigger table + firing pipeline ✅ (2026-07-05)

**Landed:** `triggers` Room table (schema v3) + `TriggerHost.kt`
(replace-set persist → re-arm; one context-registered receiver per
armed type; fire path mirrors `ActionReceiver` — live send else
queue/drop/wake with dedupe; per-trigger `throttle_s`; battery
edge-crossing hysteresis into the configured side only);
`TriggerAlarmReceiver` reads the table at fire time so stale alarms
die with the set; `BootReceiver` fires `boot` triggers, re-arms `time`
alarms, reschedules the now-persisted reminder set (the reboot gap),
and restarts the bridge. `EabpConnection` handles `triggers.set` and
grants `triggers` again. On-device acceptance (screen toggle, kill
Emacs + replay, reboot rearm) pending.

**Goal:** triggers persist, survive reboots, and fire into the
existing event queue.

**Files:** `EabpDatabase.kt` (new `triggers` table),
new `TriggerHost.kt`, `BridgeService.kt` (host lifecycle),
new `BootReceiver.kt` + manifest (`RECEIVE_BOOT_COMPLETED`),
`EabpConnection.kt` (handle `triggers.set`).

**Implementation:**
- `triggers.set` → persist set (replace), then arm: for each distinct
  trigger *type* register one context-registered receiver / callback /
  alarm on the BridgeService process. Disarm listeners no trigger
  needs.
- Fire path: build `event.action {action: "trigger.fired", …}` and
  hand it to the **same code path** connected events and the offline
  queue already share — connected ⇒ deliver, else per `policy`.
- Boot receiver: rearm from the table (also fixes the existing
  reminder gap — reschedule persisted reminders while at it).
- Throttle: per-trigger `throttle_s` honored host-side; battery-level
  triggers get hysteresis (fire on edge crossing, not on every
  BATTERY_CHANGED).

**Pitfalls:** BATTERY_CHANGED is high-frequency — never forward raw;
compute edges host-side. Receivers must be unregistered on service
teardown or you leak. Don't hold wakelocks; the FGS process is the
lifetime.

**Acceptance:** register a screen-off trigger from ERT-driven elisp
against the device; toggle screen; `trigger.fired` arrives; kill
Emacs, toggle again, reconnect ⇒ replayed. Reboot ⇒ triggers rearm
(log-verified).

### Task 7: trigger catalog, batch 1 (permission-free) ✅ (2026-07-05)

**Landed with Task 6** (same arming mechanism): `time` ({at_ms} |
{every_s ≥ 60, re-armed per fire}), `power` (+plug type), `battery.level`
(above/below edges), `screen` (on/off/unlocked), `headset` (sticky
replay guarded), `airplane`, `boot`, `timezone.changed`, `package`
(update-replacing filtered). SPEC §11 catalog table documents every
type's params + data. Deviation from plan: no cron-ish `{at, window}`
grammar — `at_ms`/`every_s` covers the need until org-defined
automations (Task 13) want richer schedules. Per-type on-device checks
(adb broadcast injection) pending.

**Goal:** the workhorse contexts.

**Types:** `time` (one-shot + repeating: exact alarm, generalizing the
Reminders scheduling; cron-ish `{at | every, window?}`), `power`
(connected/disconnected/charging-type), `battery.level {above|below}`,
`screen {on|off|unlocked}` (ACTION_USER_PRESENT), `headset
{plugged|unplugged}`, `airplane {on|off}`, `boot`, `timezone.changed`,
`package {added|removed}`.

**Acceptance:** each type has a host-side unit test (broadcast
injected via `adb shell am broadcast` where possible) and one
end-to-end elisp test; SPEC §11 table lists every shipped type + its
`data` shape.

### Task 8: trigger catalog, batch 2 (runtime-permissioned) 🟡 (network landed 2026-07-05)

**Landed:** the permission-free half — `network {event, transport?}`
via `registerDefaultNetworkCallback` (transport remembered per network
so `lost` can carry it; fires once per gain/loss). **Still open,
deliberately hardware-gated:** `wifi.ssid` and `bluetooth.device` —
their value IS the permission-degrade flow (fine location /
BLUETOOTH_CONNECT grant loops), which can't be iterated without a
device.

**Goal:** connectivity contexts — the classic "at home / at work"
profiles.

**Types:** `network {available|lost, transport}` via
`ConnectivityManager.registerNetworkCallback` (permission-free),
`wifi.ssid {connected|disconnected, ssid}` (needs fine location —
request flow via the Task 5 settings section; degrade to
transport-only when ungranted), `bluetooth.device
{connected|disconnected, mac?}` (`BLUETOOTH_CONNECT` runtime
permission, ACL_CONNECTED broadcasts).

**Pitfalls:** SSID reads return `<unknown ssid>` without location —
detect and surface as `cap-permission`, don't fire garbage. MAC params
matched host-side so the queue isn't spammed by every device.

**Acceptance:** "SSID = Home" trigger fires exactly once per connect;
without location permission the registration round-trips a typed
error the Automations view can render.

### Task 9: notification listener (own task — special access + privacy)

**Goal:** react to any app's notifications (Tasker's most-loved
trigger) and act on them.

**Files:** new `EabpNotificationListener.kt`
(NotificationListenerService) + manifest; `TriggerHost.kt`;
`DeviceCapabilities.kt` (`notification.dismiss {key}`,
`notification.click {key}`, `notifications.active` query).

**Implementation:** trigger type `notification.posted {package?,
title_regex?}` — matching happens **host-side** from the registration
params; only matches cross to Emacs, carrying `{package, key, title,
text}`. Listener enabled = special access; report in the Task 2 perm
map; the service does nothing until a trigger set references it.

**Pitfalls:** never persist other apps' notification content in the
queue longer than delivery requires; exclude Glasspane's own package
(feedback loop); regex from the wire is matched with a timeout-safe
matcher (bounded input, no catastrophic patterns — use simple substring
unless anchored-regex proves necessary).

**Acceptance:** "when Signal posts, log the title to an org file" works
end-to-end; disabling the special access degrades to a typed error.

---

## Phase A3 — running while Emacs is dead

### Task 10: companion-local responses (`on_fire`) ✅ (2026-07-05)

**Landed:** `TriggerHost.executeOnFire` — `{cap, args}` entries run
through `DeviceCapabilities.invoke` (failures logged, never fatal),
`{notify: {title?, text?}}` posts on an "Automations" channel; executed
before the queued `trigger.fired`, which still delivers. Builtin
entries stay reserved (documented). SPEC §11 on_fire updated from
reserved to shipped subset. On-device acceptance (force-stop Emacs,
plug power, flashlight + notification, replay on reconnect) pending.

**Goal:** the "flashlight when power connects" class of rules works
with Emacs gone — the same design move as builtins and multi-view
switching: *data, not code, executed on-device*.

**Implementation:** `on_fire` on a trigger registration is a list of
{builtin} objects and/or `{cap, args}` invocations and/or a
notification spec to post: e.g. `[{cap: "flashlight", args: {on:
true}}, {notify: {title: "…", body-nodes…}}]`. Executed host-side on
fire, *in addition to* the queued `trigger.fired` (Emacs still learns
about it on reconnect and stays the source of truth).

**Pitfalls:** this is the one place the companion "acts on its own" —
keep the vocabulary strictly the existing builtin + capability set,
document in SPEC §11 that `on_fire` carries no conditionals and no
loops. If someone needs logic Emacs-dead, that's the line where we say
"keep Emacs alive" rather than growing a rule language in Kotlin.

**Acceptance:** force-stop Emacs; plug in power; flashlight toggles
and a notification posts; on reconnect the queued fire replays.

### Task 11: the wake story — spike, timeboxed 🟡 (docs half 2026-07-05)

**Landed:** the "Execution model" section in ARCHITECTURE.md — the
four-layer story (resident Emacs baseline + keep-alive recipe →
on_fire → queue → wake notification). **Still open:** the item-2
device spike (Termux `RunCommandService` / exported start vector in
the Emacs APK) — needs hardware; record the result in that section
either way.

**Goal:** an honest, documented answer to "how alive must Emacs be?"

**Implementation (investigation, outcome = a docs section + at most a
small patch):**
1. Baseline: document the keep-alive recipe (battery-optimization
   exemption for the Emacs APK, dontkillmyapp-style OEM notes) — for
   this project's user profile Emacs *is* the phone's brain and should
   simply stay resident.
2. Spike: whether the Termux-signed Emacs can be started silently —
   Termux `RunCommandService` (`com.termux.permission.RUN_COMMAND`) to
   start a daemon, or any exported service/activity-alias in the Emacs
   APK usable as a compliant start vector. May well dead-end; that
   result is worth writing down too.
3. Confirm the layered fallback reads coherently in docs: on_fire
   (instant, dumb) → queue (eventual, smart) → wake notification
   (user-assisted, existing `EmacsWaker`).

**Acceptance:** a "Execution model" section in ARCHITECTURE.md a new
user can follow; spike results recorded either way.

---

## Phase A4 — authoring UX (pure Tier 1 polish)

### Task 12: `eabp-deftrigger` + the Automations view ✅ (2026-07-05)

**Landed:** `eabp-deftrigger` macro + enable/disable
(`eabp-triggers-disabled` defcustom; disabled = excluded from the
pushed set, persisted via `eabp-settings-save-variable`), last-fired
bookkeeping, `eabp-trigger-test-fire` (interactive + `trigger.test`
action), `trigger.toggle` — all in core eabp-triggers.el (trigger.* is
core's namespace; the view is pure rendering). View in
`emacs/apps/eabp-automations.el`: per-trigger cards (switch, wire
summary, last fired, Fire now), settings-link entry (satellite screen
per the drawer contract), re-render via `eabp-triggers-changed-hook`.
Deviation: deliberately NOT an `eabp-defapp` — that would flip the
launcher into multi-app mode for the sole user. On-device pass
(define/disable/re-enable/test-fire from the phone) pending.

**Goal:** registering an automation feels like `eabp-defaction`, and
the phone gets a management surface.

**Files:** new `emacs/core/eabp-triggers.el` (registry, set-push on
connect/change, `trigger.fired` dispatch to per-id handlers), new
`emacs/apps/eabp-automations.el` (view).

**Implementation:**
```elisp
(eabp-deftrigger my/charge-sync
  :type "power" :params '((state . "connected")) :policy "wake"
  :handler (lambda (data) (my/org-sync)))
```
Registry pushes the full `triggers.set` on any change and on connect
(replace-set makes this idempotent). The Automations view (via
`eabp-shell-define-view`) lists triggers with enable/disable switches
(disabled = excluded from the pushed set, persisted via Customize per
the settings seam), last-fired timestamps (from handler bookkeeping),
and a "fire now" test button per trigger.

**Acceptance:** define, disable, re-enable, test-fire from the phone;
restart Emacs and the set re-pushes identically.

### Task 13: org-defined automations ✅ (2026-07-05)

**Landed:** `emacs/apps/glasspane/glasspane-automations.el` —
automations.org (in `org-directory`) parsed with org-element: one
heading per rule, `:TRIGGER:` shorthand ("power connected",
"battery.level below 20") + raw `:PARAMS:`/`:ON_FIRE:` for anything
richer, `:POLICY:`/`:DEDUPE:`/`:THROTTLE:`, first elisp src block =
handler with `data`/`args` in scope (init.el trust, never
wire-sourced), DONE = removed from the set. Reloads on phone-side
save (`eabp-files-after-save-hook`) and via
`M-x glasspane-automations-reload`; unknown trigger types are skipped
with a message (the companion rejects whole sets). Case test pins a
lowercase drawer. On-device pass pending.

**Goal:** automations as literate org — readable, editable on the
phone with the org editor that already exists, version-controllable.

**Files:** new `emacs/apps/glasspane/glasspane-automations.el`.

**Implementation:** an `automations.org` in `org-directory`: one
heading per rule; a property drawer holds the trigger
(`:TRIGGER: power connected`, `:POLICY: wake`, …); the body's first
elisp src block is the handler. Parsed with the existing org layer
(org-element), loaded through the `glasspane-config.el` contract
(user file wins, never overwritten), re-parsed via the cache-
invalidation seam on save. TODO-state DONE ⇒ rule disabled — org
semantics as the enable switch.

**Pitfalls:** property drawers are case-insensitive (case-convention
tests required); the src block is *user-authored code from the user's
own file* — same trust as init.el, but it must never be sourced from
anything that arrived over the wire or the share sheet.

**Acceptance:** add a rule heading on the phone in the org editor,
save, pull-to-refresh ⇒ the trigger set updates; mark DONE ⇒ removed
from the pushed set. Case test: `:trigger:` lowercase drawer parses.

---

## Phase L0 — app identity (mostly elisp; do Task 14 early, it's cheap)

### Task 14: `eabp-defapp` + launcher home + per-app chrome ✅ (2026-07-05)

**Landed:** new `emacs/core/eabp-apps.el` (registry, home grid view,
`app.open` action, conditional "Apps" drawer entry) over a new shell
seam `eabp-shell-view-filter-function` (also honored by the bottom
bar, default tab, and overlay pick). Decisions taken: ungrouped views
show in **every** app — an explicit `(eabp-defapp "system" …)` contains
them, so it's user policy, not core policy; single-vs-multi app is
decided by registry size, so Glasspane alone changes nothing;
action-name collision warning implemented for *view* claims at defapp
time (lambda identity makes handler-level warnings too noisy).
Glasspane is the first `eabp-defapp` (glasspane-ui.el); eabp-hello.el
now declares the second. Home switching is a drop-policy action —
Task 15 upgrades it to a companion-local builtin for offline. Docs in
BUILDING-TIER1.md §4½. On-device two-card check pending.

**Goal:** views group into named apps; a home view launches them; the
bottom bar shows one app at a time. This is the AppSheet feel and it
is almost entirely shell logic.

**Files:** `emacs/core/eabp-shell.el`, new `emacs/core/eabp-apps.el`
(or in-shell), `docs/BUILDING-TIER1.md`.

**Implementation:**
- `(eabp-defapp "glasspane" :label "Glasspane" :icon "calendar"
  :views (…))` — sugar over the existing registry: each member view
  gets an `:app` property; `eabp-shell-current-app` gates tabs the way
  `:when` predicates already do. Ungrouped views (core tabs: Files,
  Emacs, Tools) belong to a built-in "system" app or show everywhere —
  decide and document.
- Home = one more registered view: a grid of app cards (icon, label,
  badge) with `on_tap` → `app.open {app}` action (namespace `app.*`
  reserved). Drawer keeps the everyday-nav contract (per the drawer UX
  decisions): apps list lives in home, satellite screens stay behind
  settings links.
- One app's views per multi-view push keeps payloads small; switching
  apps is an action → set current app → push.

**Pitfalls:** Glasspane itself must become the first `eabp-defapp` with
zero behavior change when it's the only app installed (single-app ⇒
skip home, boot straight in — AppSheet does the same). Action-name
collisions between apps: the registry warns when two apps register the
same action name.

**Acceptance:** load `eabp-hello.el` next to Glasspane ⇒ home shows two
cards; switching swaps tab bars; with only Glasspane loaded nothing
looks different from today.

### Task 15: offline app switching (design decision + companion cache)

**Goal:** the launcher works with Emacs disconnected — the cached-UI
story extended to multiple apps.

**Implementation:** decide between (a) one `app:main` surface carrying
home + current app (simple, switch needs Emacs) and (b) per-app
surfaces `app:main` (home) + `app:<id>` with a
`{builtin: "app.switch"}` companion-local navigation (launcher fully
works offline, like `view.switch` does today). Recommendation: (b) —
it is the same pattern as multi-view surfaces, and the offline story
is the project's signature move. Requires: companion surface routing
by id (exists), a new builtin, and eviction rules for uninstalled
apps (`surface.remove` on app removal).

**Acceptance:** kill Emacs; open Glasspane; home renders from cache;
switching into an app shows its last-known views; taps queue as they
already do.

---

## Phase L1 — OS entry points

### Task 16: shortcuts + pinning + share routing

**Goal:** each app pinnable to the home screen with its own icon —
the "installed app" illusion.

**Files:** `MainActivity.kt`, new `ShortcutPublisher.kt`,
`SurfaceManager.kt` (publish on app-manifest change).

**Implementation:** the Task 14 push carries an app manifest; the
companion publishes dynamic shortcuts (≤4 visible) and offers pinning
(`requestPinShortcut`) for any app from a long-press or an in-app
"add to home screen" action. Shortcut intent = MainActivity + extra
`app_id` → performs the Task 15 offline switch before/without connect.
Icons: start with the launcher icon + themed monogram of the app label
(adaptive-icon layer), real per-app icons later. Share sheet: when >1
app registers a share handler, route ACTION_SEND through a chooser
dialog (an `app.share` action per app); today's direct-to-capture
stays the single-app fast path.

**Acceptance:** pin Hello; tap its home-screen icon with Emacs dead ⇒
Glasspane opens straight into Hello's cached view.

### Task 17: widget & tile slot assignment

**Goal:** the 5 custom widget and 5 tile slots become per-app
assignable from a picker instead of ad-hoc elisp.

**Implementation:** apps declare offered compositions
(`:widgets ((id label builder))` on `eabp-defapp`); a settings section
(existing seam) maps `widget:customN` / `tile:customN` → offering;
persisted via Customize; the shell's after-push hook renders assigned
builders into their slots (the mechanism the slots already use).

**Acceptance:** assign Hello's counter widget to slot 2 from the phone
settings; it renders; reassignment takes effect on next push.

---

## Phase L2 — distribution of builds

### Task 18: build bundles + import with consent

**Goal:** a build travels as one `.el` file; installing it on the
phone is explicit, inspectable, and reversible.

**Files:** `emacs/build-bundle.el` (parameterize for third-party
bundles), `emacs/core/eabp-files.el` or new `eabp-app-store.el`
(import flow + installed registry), `MainActivity.kt` (accept `.el` /
`text/x-emacs-lisp` via SEND/VIEW), `docs/BUILDING-TIER1.md`
(“Shipping it” grows the phone-install path).

**Implementation:**
- Convention: a build = single `.el` with a header line
  (`;;; Glasspane-App: name version …`) → installed into
  `~/.emacs.d/elisp/glasspane/apps/<name>.el`, loaded at
  `glasspane-config-ensure` time and immediately on install. The
  managed-dir contract extends: `apps/` is user-installed, never
  overwritten by `config.sync`.
- Import flow: receiving a file ⇒ a consent dialog that says what this
  is honestly — *this is Emacs Lisp; it runs with full access to your
  Emacs and files* — shows the header metadata and the source
  (scrollable, syntax-highlighted — the editor node does this), and
  requires an explicit Install tap. No auto-load of anything that
  arrived over the wire, ever (this is the same trust line as
  Task 13).
- Installed-apps registry view: version, enable/disable
  (`eabp-defapp` gate), remove (delete file + `surface.remove` +
  unpublish shortcut).

**Pitfalls:** don't build a package manager — one file, one dir,
package.el remains the recommendation for anything with dependencies
(the package browser already exists for that).

**Acceptance:** share `eabp-hello.el` to the phone from another app ⇒
consent → install → home shows Hello → remove → gone, shortcut too.

---

## Phase L3 — declarative org apps (the true AppSheet analog)

### Task 19: org-authored apps, no elisp required

**Goal:** a non-programmer authors an app as an org document — the
org-parser investment becomes the citizen-developer substrate the way
spreadsheets are for AppSheet.

**Files:** new `emacs/apps/glasspane/glasspane-orgapp.el`.

**Implementation (safe declarative subset — no code):**
- An `app.org` file: `#+GLASSPANE_APP: name` keyword; top-level
  headings = views (tab per heading); tables render via the existing
  table node (`on_add_row` already exists — a table *is* an editable
  datasource); plain lists with checkboxes = task lists; property
  drawers on headings configure the view (icon, order, filters using
  the org-ql query builder that already landed).
- The action vocabulary is **closed**: built-in org mutations only
  (checkbox toggle, TODO cycle, row append/edit, capture into a
  target) — all actions that already exist behind the allowlist.
  Because there is no code, an org app is safe to share and install
  *without* the Task 18 code-trust warning (its own lighter consent).
- Loading: an org file in a watched dir (or installed via the Task 18
  flow with the lighter consent path) registers an `eabp-defapp` whose
  builders render org-element data through existing glasspane-org
  extractors, memoised behind the standard cache-invalidate seam.

**Pitfalls:** scope discipline — no conditionals, no formulas in v1
(org spreadsheet formulas are a tempting rabbit hole; a later task if
ever). Keyword/drawer parsing: case-insensitive + case tests. Respect
the cache contract on every mutation path.

**Acceptance:** a 20-line `app.org` with an Inventory table view and a
capture-to-heading FAB installs from the share sheet, renders, edits
rows from the phone, and survives Emacs restart; the demo doc gains a
worked example.

---

## Sequencing

```
P:  Task 1 ──► A2 (6,7,8,9) ──► A3 (10) ──► A4 (12,13)
    Task 2 ──► A1 (3,4,5) ──────┘   A3 (11) anytime
L:  Task 14 ──► 15 ──► 16 ──► 18 ──► 19
                        17 ────┘  (after 14)
```

- **Start with Tasks 1–2** (a day of spec + stubs; everything hangs
  off them).
- **Quick wins for momentum:** Task 3–4 (effectors are small and
  instantly gratifying from the eval REPL) and Task 14 (pure elisp,
  visible immediately, zero risk while single-app).
- The two tracks don't share files after Phase P — parallelizable.
- Battery check-in after Phase A2 lands: profile a day with a
  screen/power/network trigger set active before building A4 on top
  (the FGS is already always-on, so the expectation is ≈0 delta, but
  the project rule is measure, don't assume).

## Explicit non-goals (decided now so they don't creep)

- **App-launch detection / UI automation** (Tasker's accessibility
  tricks): requires accessibility-service or usage-stats access;
  invasive, battery-relevant, and against the "usable, not IDE"
  spirit. Revisit only on real demand.
- **Geofencing v1:** platform proximity alerts only if ever; location
  polling is the single worst battery item in Tasker. `wifi.ssid` +
  `bluetooth.device` cover most "at home / in car" profiles for free.
- **SMS / call triggers and actions:** fine on F-Droid, hostile on
  Play — deferred until the distribution channel is decided.
- **A companion-side rule language** beyond Task 10's flat `on_fire`
  list: conditionals live in Emacs, period.
- **A Kotlin plugin system:** new device surfaces stay elisp-composed
  (the widget/tile-slot precedent); builds never ship Kotlin.
