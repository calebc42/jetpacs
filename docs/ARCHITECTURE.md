# Architecture: the tiers and where the boundary runs

EABP is layered so that everything below the app line is generic — it
works for any Emacs buffer, mode, or package with zero per-package code —
and everything above it is one replaceable opinion.

## The tiers

- **Tier 0 — the generic bridge.** Any Emacs buffer renders on the phone
  by walking its text and text/overlay properties; any keymap surfaces as
  a searchable command palette; any minibuffer prompt becomes a native
  dialog; M-x works. No package-specific code anywhere on the path.
- **Tier 0.5 — declarative-framework renderers.** Some Emacs UI frameworks
  are data, not text: `tabulated-list-mode` (columns + rows) and
  `transient` (layouts of infixes/suffixes). One renderer per framework
  covers every package built on it.
- **Tier 1 — apps and skins.** Opinionated, curated experiences built on
  the core seams: the Glasspane org app, the magit radial menu, the
  package browser. This tier is the replaceable part — the whole point of
  the project is that you can write your own (see
  [BUILDING-TIER1.md](BUILDING-TIER1.md)).

Input follows the same split: the **command palette** is the Tier 0
default for raw keymaps (machine-made labels want live filtering); the
**radial pie menu** is reserved for Tier 1 material — curated specs and
live transients, where a bounded set of human-written labels fits a pie.

## Emacs side

### `emacs/core/` — the EABP foundation (`eabp-*`)

| module | role |
|---|---|
| `eabp.el` | transport: NDJSON framing, handshake, pairing auth, reconnect backoff |
| `eabp-widgets.el` | the widget constructors (wire shapes in `test/widgets.golden`) |
| `eabp-surfaces.el` | surface push + monotonic revisions, action dispatch table, UI-state store |
| `eabp-triggers.el` | device-trigger registry: `triggers.set` replace-set push (gated on the `triggers` grant), `trigger.fired` dispatch (SPEC §11) |
| `eabp-device.el` | device effectors: one thin defun per SPEC §10 capability (`eabp-device-intent`, `-flashlight`, `-tts`, …) through the `eabp-device--invoke` funnel |
| `eabp-minibuffer.el` | prompt bridge: `y-or-n-p` / `completing-read` / … → dialogs, only inside action handlers |
| `eabp-buffer.el` | **Tier 0 renderer**: any buffer → spans + tappable regions; the major-mode→skin registry |
| `eabp-shell.el` | the app shell: view registry, tab/drawer/top-bar chrome, snackbar, connect/refresh pushes |
| `eabp-apps.el` | app identity over the shell: `eabp-defapp` groups views, launcher home grid, per-app tab bars (inert until a second app registers) |
| `eabp-tablist.el` | **Tier 0.5**: generic `tabulated-list-mode` renderer + skin hook alists |
| `eabp-comint.el` | **Tier 0.5**: generic `comint-mode` renderer — transcript tail + input row, `comint.send` scoped to the buffer's own live process |
| `eabp-transient.el` | **Tier 0.5**: transient prefixes as touch dialogs (advice on `transient-setup`) |
| `eabp-keymap.el` | command palette over any buffer's keymap; live-transient pie plumbing |
| `eabp-sync.el` | editor shadow buffers: delta sync, flymake diagnostics, eldoc, fontify pushes |
| `eabp-complete.el` | capf bridge: the phone's completion strip, answered from the shadow |
| `eabp-settings.el` | schema-driven settings from `defcustom` metadata; registry = the allowlist |
| `eabp-files.el` | file browser (a dired skin) + plain editor + content search, root-confined; app hooks for file types |
| `eabp-emacs-ui.el` | buffers / eval REPL / *Messages* views, M-x, imenu section drill-in, message→toast mirror |

The core is org-free by contract; `test/core-load-test.el` loads only
this directory and fails if an app feature or org itself sneaks in.

### `emacs/apps/` — Tier 1

| module | role |
|---|---|
| `glasspane/glasspane-org.el` | org data extraction (agenda/tasks/clock/search), memoised behind `glasspane-org-cache-invalidate` |
| `glasspane/glasspane-org-rich.el` | org → styled `rich_text` spans via `org-element` |
| `glasspane/glasspane-org-reader.el` | foldable org outline → `collapsible` trees |
| `glasspane/glasspane-clock.el` | org-clock chronometer notification |
| `glasspane/glasspane-ui.el` | the org app: agenda/tasks/clock/search/detail/settings views + heading actions + capture |
| `glasspane/glasspane-demo.el` | the mobile-IDE tour files |
| `glasspane/glasspane.el` | aggregate entry point: `(require 'glasspane)` |
| `eabp-magit.el` | curated magit radial menu (pure data + key dispatch) |
| `eabp-package-browser.el` | package-menu skin for the tablist renderer — the worked example |
| `eabp-customize.el` | customize browser: the defgroup tree + `custom-type` schemas as native controls (gate: `custom-variable-p`) |
| `eabp-tools.el` | tools hub: bookmark/process/timer entry points (free via the tablist renderer), kill-ring browser, `M-x shell` entry |
| `eabp-automations.el` | device-trigger management view (enable switches, last-fired, test-fire) over core eabp-triggers.el; settings-link satellite |

### Bundles

`emacs/build-bundle.el` emits two single-file bundles at the repo root:
**`eabp-core.el`** (the foundation only — what a third-party Tier 1
depends on) and **`glasspane.el`** (core + reference apps).

## Android side: two Gradle modules

The elisp core/apps boundary has a Kotlin mirror, enforced by the build
(split 2026-07-05 — the module boundary is the future repo boundary,
and the KMP extraction seam):

**`eabp/` — the `:eabp` library** (namespace `com.calebc42.eabp.core`;
Kotlin package stays `com.calebc42.eabp`). Everything a host companion
needs short of its own identity: `EabpServer` / `EabpConnection` /
`FrameCodec` / `Envelope` / `EabpAuth` (transport, handshake, pairing),
`EabpDatabase` (offline queue + surface cache), `SurfaceStore` /
`SurfaceManager`, `SduiRenderer` / `SduiContentNodes` / `SduiInputNodes`
/ `SduiScaffold` (spec → Compose), `SyntaxHighlight`, `EditorSync` /
`EabpCompletionState` / `EabpDialogState`, `NotificationRenderer`,
`Reminders`, `DeviceCapabilities` (the `capability.invoke` effector
dispatch + device-permission report, SPEC §10), `TriggerHost` +
`BootReceiver` (the persisted device-trigger table, context-registered
listeners riding the FGS, exact `time` alarms, and reboot re-arming,
SPEC §11), the widget providers + tile slots, `RadialMenu` /
`EabpPieMenuState`, `ActionReceiver`, `BridgeService`, `EmacsWaker` —
plus their manifest entries, permissions, and widget resources, which
merge into any host app.

**`app/` — the Glasspane shell**: `MainActivity` (pairing screen,
dashboard host, share/widget trampoline), `CaptureTileService`,
`OrgEditToolbar`, theme/branding, and string overrides that rebrand the
library's host-neutral defaults (app resources win the merge).

**The two seams that keep the library host-agnostic** (the rule: the
library names no host class):

- `EabpLaunch` — "open the app" resolves the host's launcher activity
  via the package manager and carries the trampoline-extras contract
  the host's activity must honor.
- `EabpToolbars` — editor toolbars are host-registered by name; the
  library ships none. Glasspane registers `"org"` → `OrgEditToolbar`.
  An unregistered name renders nothing (the unknown-node rule).

## The seams (how Tier 1 plugs in)

| seam | owner | what registers there |
|---|---|---|
| `eabp-render-buffer-functions` | eabp-buffer | per-major-mode buffer skins (dired cards, tablist) |
| `eabp-shell-define-view` / drawer / top-action / default-FAB | eabp-shell | app views, tabs, and global chrome |
| `eabp-shell-view-switched/refresh/after-push-hook` | eabp-shell | app state resets, cache drops, piggyback pushes |
| `eabp-tablist-{header,row,filter}-functions` | eabp-tablist | per-mode tablist skins |
| `eabp-files-editor-{body,actions,toolbar}` + open/after-save hooks | eabp-files | per-file-type editor behaviour |
| `eabp-settings-register-section` / `eabp-settings-after-set-hook` | eabp-settings | app settings exposure (the wire allowlist) |
| `eabp-keymap` pie plumbing | eabp-keymap | curated Tier 1 pies (see eabp-magit.el) |
| `eabp-defaction` | eabp-surfaces | every semantic action handler (allowlist rule: [SPEC §5](SPEC.md)) |
| `eabp-buffer-refresh-function` / `eabp-tablist-view-buffer-function` | core | host navigation — already pointed at the shell |

Two standing contracts worth knowing before you build:

1. **The command-dispatch boundary.** Nothing on the wire names code to
   run. Handlers are registered by name and validate their args; the M-x
   action is the single documented exception (the user picks the command
   through a bridged prompt).
2. **The cache contract.** App views may memoise expensive extractions
   (Glasspane memoises its org reads); every mutation path must drop the
   memo — actions do it directly, and the shell's `refresh` hook covers
   pull-to-refresh and queue drains.

## Execution model: how alive must Emacs be?

Android will not let one app silently start another: background
activity launches are blocked and notification trampolines are banned
(targetSdk 31+). `EmacsWaker` already does the two compliant things —
an opportunistic launch when the app is foregrounded, and a
tap-to-open notification otherwise. Everything else is designed around
*not needing* Emacs for the common cases, in four layers:

1. **Resident Emacs (the baseline).** For this project's user profile,
   Emacs is the phone's brain and should simply stay running: give the
   Emacs APK a battery-optimization exemption (Settings → Apps → Emacs
   → Battery → Unrestricted) and check dontkillmyapp.com for
   OEM-specific killers. The bridge reconnects with backoff whenever
   the OS pauses sockets, so a resident Emacs feels always-on.
2. **`on_fire` (instant, dumb).** A trigger registration can carry a
   flat companion-local response — capability invocations and a
   notification — executed at fire time with Emacs dead (SPEC §11).
   Deliberately no conditionals and no loops: when a rule needs logic
   Emacs-dead, the answer is layer 1, not a rule language in Kotlin.
3. **The offline queue (eventual, smart).** Every fire and every tap
   with `queue` policy persists and replays on reconnect, so full-Emacs
   logic always runs *eventually* — the companion never becomes the
   source of truth.
4. **The wake notification (user-assisted).** `wake` policy posts the
   `EmacsWaker` notification; one tap brings Emacs up, and the queue
   drains into it.

**Open spike (timeboxed, needs hardware):** whether the Termux-signed
Emacs exposes a compliant silent-start vector — Termux's
`RunCommandService` (`com.termux.permission.RUN_COMMAND`) starting a
daemonized Emacs, or an exported service/activity-alias in the Emacs
APK. May well dead-end; the result gets recorded here either way.

## Kotlin conformance checklist (the contract tripwire)

The companion stays a portable renderer by construction: **every
Kotlin behavior must be traceable to a SPEC section**, and new Kotlin
lands in `:eabp` only if it is protocol, in `:app` if it is opinion.
Audit this table whenever a Kotlin wave lands (last audited
2026-07-05, after the automation wave AUTO 6–10):

| Kotlin surface | SPEC section |
|---|---|
| `FrameCodec` / `Envelope` (NDJSON, envelope, ids) | §1–§2 |
| `EabpAuth` + handshake in `EabpConnection` | §3 |
| `session.welcome` `device` report | §3, §10 |
| `SurfaceStore` / `SurfaceManager` (revisions, cache, multi-view) | §4 |
| `ActionReceiver` (actions, policies, dedupe), `dispatchWithValue` value injection | §5 |
| Builtins (`view.switch`, `clipboard.copy`) | §5 |
| Offline queue + replay (`EabpDatabase`, replay loop) | §6 |
| Dialogs, toasts, pies (`EabpDialogState`, `EabpPieMenuState`) | §7 |
| `ReminderScheduler` (replace-set, reboot persistence) | §7 |
| `EditorSync` / completion / diagnostics / eldoc / fontify | §8 |
| `SduiRenderer` + node files (shapes pinned by `test/widgets.golden`) | §9 |
| `DeviceCapabilities` (catalog + perm map), `EabpRuntime.keepScreenOn` | §10 |
| `TriggerHost` / `TriggerAlarmReceiver` / `BootReceiver` (types, throttle, hysteresis, `on_fire`, reboot rearm) | §11 |
| `EmacsWaker` | §5 (`wake` policy), execution model above |
| Widgets / tiles / notification rendering | §4 surfaces (`widget:*`, `notification:*`) |

Divergence rule: a behavior with no SPEC home gets spec'd or removed —
the 2026-07-05 audit found one (the `value` injection on change
callbacks) and spec'd it into §9. The only org knowledge outside
`:app` remains **none**; `:app`'s `OrgEditToolbar` is the single
org-aware Kotlin class, opt-in by toolbar name (§9 `editor`).
