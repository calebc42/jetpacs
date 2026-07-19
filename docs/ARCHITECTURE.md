# Architecture: the tiers and where the boundary runs

Jetpacs is layered so that everything below the app line is generic — it
works for any Emacs buffer, mode, or package with zero per-package code —
and everything above it is one replaceable opinion.

## The tiers

- **Tier 0 — the generic bridge.** Any Emacs buffer renders on the phone
  by walking its text and text/overlay properties; any keymap surfaces as
  a searchable command palette; any minibuffer prompt becomes a native
  dialog; M-x works. No package-specific code anywhere on the path.
- **Tier 0.5 — declarative-framework renderers.** Some Emacs UI frameworks
  are data, not text: `tabulated-list-mode` (columns + rows), `comint`
  (transcript + prompt), the `next-error`/loci protocol (results lists),
  rendered hypertext documents (shr/eww, help, Info — headings, links,
  images, tables), the `magit-section` tree (magit, forge, kubernetes.el,
  taxy riders), and `transient` (layouts of infixes/suffixes). One
  renderer per framework covers every package built on it.
- **Tier 1 — apps and skins.** Opinionated, curated experiences built on
  the core seams: the [Glasspane](https://github.com/calebc42/glasspane)
  org app and the magit radial menu (in the glasspane repo; this repo
  ships `jetpacs-hello.el` as the minimal example). This tier is the
  replaceable part — the whole point of the project is that you can
  write your own (see [BUILDING-TIER1.md](BUILDING-TIER1.md); data-bound
  screens can be declarative `:spec` views — [BINDING.md](BINDING.md)). A few
  Tier-1-shaped screens ship in the core itself — the package browser,
  the customize browser, the tools hub, and the automations view —
  because they are chrome every app's user needs, not app opinion.

Input follows the same split: the **command palette** is the Tier 0
default for raw keymaps (machine-made labels want live filtering); the
**radial pie menu** is reserved for Tier 1 material — curated specs and
live transients, where a bounded set of human-written labels fits a pie.

## Emacs side

### `emacs/core/` — the Jetpacs foundation (`jetpacs-*`)

| module | role |
|---|---|
| `jetpacs.el` | transport: JSON-RPC 2.0 envelope, Content-Length framing + frame cap, handshake, pairing auth, reconnect backoff |
| `jetpacs-widgets.el` | the widget constructors (wire shapes in `ebp/goldens/widgets.golden`) |
| `jetpacs-surfaces.el` | surface push + monotonic revisions, action dispatch table, UI-state store |
| `jetpacs-triggers.el` | device-trigger registry: `triggers.set` replace-set push (gated on the `triggers` grant), `trigger.fired` dispatch (SPEC §11) |
| `jetpacs-device.el` | device effectors: one thin defun per SPEC §10 capability (`jetpacs-device-intent`, `-flashlight`, `-tts`, …) through the `jetpacs-device--invoke` funnel |
| `jetpacs-theme.el` | companion theme: `jetpacs-theme-mode` (default / material / emacs) → `theme.set`; `emacs` mirrors the running theme's palette + syntax colors (modus API or resolved faces), the others force a `base` scheme (SPEC §7) |
| `jetpacs-minibuffer.el` | prompt bridge: `y-or-n-p` / `completing-read` / … → dialogs, only inside action handlers |
| `jetpacs-witheditor.el` | with-editor bridge: commit-message / rebase buffers → a phone editor dialog, `witheditor.finish` / `.cancel` (SPEC §7) |
| `jetpacs-buffer.el` | **Tier 0 renderer**: any buffer → spans + tappable regions; the major-mode→skin registry |
| `jetpacs-shell.el` | the app shell: view registry, tab/drawer/top-bar chrome, snackbar, connect/refresh pushes |
| `jetpacs-apps.el` | app identity over the shell: `jetpacs-defapp` groups views, launcher home grid, per-app tab bars (inert until a second app registers) |
| `jetpacs-tablist.el` | **Tier 0.5**: generic `tabulated-list-mode` renderer + skin hook alists |
| `jetpacs-comint.el` | **Tier 0.5**: generic `comint-mode` renderer — transcript tail + input row, `comint.send` scoped to the buffer's own live process |
| `jetpacs-results.el` | **Tier 0.5**: generic results/loci navigator — occur/compilation/grep/xref as tappable cards, the mode's own goto under a display shim, prev/next stepper |
| `jetpacs-hypertext.el` | **Tier 0.5**: generic document renderer — eww/help/Info (and any shr-rendered mode via `jetpacs-hypertext-register-shr-mode`) as cards: headings, tappable links, real images (write-once content cache), native tables, `hypertext.nav` toolbar |
| `jetpacs-sections.el` | **Tier 0.5**: generic `magit-section` renderer — the section tree (magit, forge, kubernetes.el, taxy-magit-section) as client-side collapsible cards, Emacs fold state mirrored, long-press = the section's own key bindings as a bridged menu (`sections.menu`) |
| `jetpacs-transient.el` | **Tier 0.5**: transient prefixes as touch dialogs (advice on `transient-setup`) |
| `jetpacs-keymap.el` | command palette over any buffer's keymap; live-transient pie plumbing |
| `jetpacs-sync.el` | editor shadow buffers: delta sync, flymake diagnostics, eldoc, fontify pushes |
| `jetpacs-complete.el` | capf bridge: the phone's completion strip, answered from the shadow |
| `jetpacs-settings.el` | schema-driven settings from `defcustom` metadata; registry = the allowlist |
| `jetpacs-files.el` | file browser (a dired skin) + plain editor + content search, root-confined; app hooks for file types |
| `jetpacs-emacs-ui.el` | buffers / eval REPL / *Messages* views, M-x, imenu section drill-in, message→toast mirror |
| `jetpacs-package-browser.el` | stock package browser (the tablist worked example): search/status chips, install/delete, archive refresh |
| `jetpacs-customize.el` | customize browser over the defgroup tree; `customize.set`/`.reset` gated on `custom-variable-p` (SPEC §5) |
| `jetpacs-modus.el` | control screen for the built-in modus themes (a stock satellite beside packages/customize): theme picker with palette swatches, style-option switches, Toggle/Rotate; dovetails with `jetpacs-theme-mode` (mirror-on-tap) |
| `jetpacs-tools.el` | tools hub: bookmarks, kill ring, shell, processes, timers — entry points over the tablist/comint substrates |
| `jetpacs-hosts.el` | remote hosts hub: TRAMP endpoints (explicit + ssh-config discovered) as cards — Files/Shell/Services/Disconnect over the existing substrates, connection state read (never probed), `tramp-connection-timeout` clamped |
| `jetpacs-automations.el` | management view over the `jetpacs-triggers.el` registry: enable switch, wire summary, last-fired, "Fire now" |
| `jetpacs-demo.el` | onboarding: the first-run Start tab (teaches the M-x button, retires once the tour exists) + `jetpacs-setup-demo`, which writes the guided tour (`walkthrough.org` — the whole app, screen by screen; `org-basics.org` — org for Obsidian/Logseq switchers; `hello-app.el` — a live Tier 1 to edit and reload) into `~/jetpacs-demo/` and opens it |

The core is org-free by contract; `test/core-load-test.el` loads only
this directory and fails if an app feature or org itself sneaks in.

### `emacs/apps/` — Tier 1

This repo ships exactly one Tier 1: `jetpacs-hello.el`, the smallest
complete app (~60 commented lines: one view, one action, one tab, one
`jetpacs-defapp`), written to be loaded into a live session and mutated.

The real Tier-1 apps live in the
**[glasspane repo](https://github.com/calebc42/glasspane)**: the
Glasspane org app plus the magit pie. Its README carries their module
map. That repo is also the worked example of *shipping* a Tier 1: pure
elisp, this repo as a git submodule, its own app-only bundle.

### The bundle

`emacs/build-bundle.el` emits one single-file bundle at the repo root:
**`jetpacs-core.el`** — the foundation, what a third-party Tier 1
depends on. App repos build their own bundles that open with
`(require 'jetpacs-core)` (see Glasspane's `build-bundle.el`).

## Android side: two Gradle modules

The elisp core/apps boundary has a Kotlin mirror, enforced by the build
(the module boundary is the future repo boundary, and the KMP
extraction seam):

**`jetpacs/` — the `:jetpacs` library** (namespace `com.calebc42.jetpacs.core`;
Kotlin package stays `com.calebc42.jetpacs`). Everything a host companion
needs short of its own identity: `JetpacsServer` / `JetpacsConnection` /
`FrameCodec` / `Envelope` / `JetpacsAuth` (transport, handshake, pairing),
`JetpacsDatabase` (offline queue + surface cache), `SurfaceStore` /
`SurfaceManager`, `SduiRenderer` / `SduiContentNodes` / `SduiInputNodes`
/ `SduiScaffold` (spec → Compose), `SyntaxHighlight`, `EditorSync` /
`JetpacsCompletionState` / `JetpacsDialogState`, `NotificationRenderer`,
`Reminders`, `DeviceCapabilities` (the `capability.invoke` effector
dispatch + device-permission report, SPEC §10), `TriggerHost` +
`BootReceiver` (the persisted device-trigger table, context-registered
listeners riding the FGS, exact `time` alarms, and reboot re-arming,
SPEC §11), the widget providers + tile slots, `RadialMenu` /
`JetpacsPieMenuState`, `ActionReceiver`, `BridgeService`, `EmacsWaker` —
plus their manifest entries, permissions, and widget resources, which
merge into any host app.

**`app/` — the reference companion shell**: `MainActivity` (pairing
screen, dashboard host, share/widget trampoline), onboarding,
theme/branding, and string overrides that rebrand the library's
host-neutral defaults (app resources win the merge). A third-party
companion is this module re-imagined: depend on `:jetpacs`, provide
your own identity.

**The two seams that keep the library host-agnostic** (the rule: the
library names no host class):

- `JetpacsLaunch` — "open the app" resolves the host's launcher activity
  via the package manager and carries the trampoline-extras contract
  the host's activity must honor.
- `JetpacsToolbars` — the native-alternative seam for editor toolbars.
  The default path is data: an editor spec's `toolbar` array is
  interpreted by the library's `SduiToolbar` (SPEC §9 "Editor
  toolbars"), so apps compose toolbars in elisp with zero Kotlin. A
  host that wants richer native behaviour registers a composable here
  by name and the spec selects it as a string; nothing ships
  registered, and an unregistered name renders nothing (the
  unknown-node rule).

## The seams (how Tier 1 plugs in)

| seam | owner | what registers there |
|---|---|---|
| `jetpacs-render-buffer-functions` | jetpacs-buffer | per-major-mode buffer skins (dired cards, tablist) |
| `jetpacs-shell-define-view` / drawer / top-action / default-FAB | jetpacs-shell | app views, tabs, and global chrome |
| `jetpacs-shell-view-switched/refresh/after-push-hook` | jetpacs-shell | app state resets, cache drops, piggyback pushes |
| `jetpacs-tablist-{header,row,filter}-functions` | jetpacs-tablist | per-mode tablist skins |
| `jetpacs-hypertext-register-shr-mode` | jetpacs-hypertext | one-line riders for shr-rendered modes (elfeed-show, nov, devdocs) |
| `jetpacs-files-editor-{body,actions,toolbar}` + open/after-save hooks | jetpacs-files | per-file-type editor behaviour |
| `jetpacs-settings-register-section` / `jetpacs-settings-after-set-hook` | jetpacs-settings | app settings exposure (the wire allowlist) |
| `jetpacs-keymap` pie plumbing | jetpacs-keymap | curated Tier 1 pies (see jetpacs-magit.el) |
| `jetpacs-defaction` | jetpacs-surfaces | every semantic action handler (allowlist rule: [SPEC §5](https://github.com/calebc42/ebp/blob/main/SPEC.md#5-events-the-semantic-action-boundary)) |
| `jetpacs-device-*` / `jetpacs-capability-invoke` | jetpacs-device, jetpacs.el | device side-effects from handlers and triggers (SPEC §10) |
| `jetpacs-deftrigger` / `jetpacs-trigger-register` | jetpacs-triggers | device events → elisp handlers, plus companion-local `on_fire` (SPEC §11) |
| `jetpacs-surface-push` (`notification:*`, `widget:customN`, `tile:customN`) | jetpacs-surfaces | surfaces beyond the app: notifications, home-screen widgets, QS tiles |
| `jetpacs-theme-mode` / `jetpacs-theme-send` | jetpacs-theme | pick the companion scheme (default / material / mirror Emacs) onto chrome and editor |
| `jetpacs-node-supported-p` / `jetpacs-granted-p` / `jetpacs-device-cap-p` | jetpacs.el | per-connection negotiation — gate additive nodes, capabilities, and effectors |
| `jetpacs-buffer-refresh-function` / `jetpacs-tablist-view-buffer-function` | core | host navigation — already pointed at the shell |

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
lands in `:jetpacs` only if it is protocol, in `:app` if it is opinion.
Audit this table whenever a Kotlin wave lands (last audited
2026-07-05). Writing a companion
of your own? This table doubles as your build map — see
[BUILDING-COMPANION.md](https://github.com/calebc42/ebp/blob/main/BUILDING-COMPANION.md)
in the ebp protocol repo:

| Kotlin surface | SPEC section |
|---|---|
| `FrameCodec` / `Envelope` (Content-Length framing, JSON-RPC messages, error codes) + `InboundPipeline` (SPEC-2 §5 conflation) | SPEC-2 §§1–2, §5 |
| `JetpacsAuth` + handshake in `JetpacsConnection` | §3 |
| `session.welcome` `device` report | §3, §10 |
| `SurfaceStore` / `SurfaceManager` (revisions, cache, multi-view) | §4 |
| `ActionReceiver` (actions, policies, dedupe), `dispatchWithValue` value injection | §5 |
| Builtins (`view.switch`, `clipboard.copy`, `jetpacs.settings.open`) | §5 |
| Offline queue + replay (`JetpacsDatabase`, replay loop) | §6 |
| Dialogs, toasts, pies (`JetpacsDialogState`, `JetpacsPieMenuState`) | §7 |
| `ReminderScheduler` (replace-set, reboot persistence) | §7 |
| `EditorSync` / completion / diagnostics / eldoc / fontify | §8 |
| `SduiRenderer` + node files (shapes pinned by `ebp/goldens/widgets.golden`) | §9 |
| `SduiToolbar` (data-driven editor toolbars, snippet placeholders) | §9 "Editor toolbars" |
| `DeviceCapabilities` (catalog + perm map), `JetpacsRuntime.keepScreenOn` | §10 |
| `TriggerHost` / `TriggerAlarmReceiver` / `BootReceiver` (types, throttle, hysteresis, `on_fire`, reboot rearm) | §11 |
| `EmacsWaker` | §5 (`wake` policy), execution model above |
| Widgets / tiles / notification rendering | §4 surfaces (`widget:*`, `notification:*`) |

Divergence rule: a behavior with no SPEC home gets spec'd or removed.
Org knowledge in Kotlin is **zero**, in both modules: the org keyboard
toolbar is elisp data interpreted by `SduiToolbar` (§9 "Editor
toolbars"), the agenda widget's header button dispatches a
server-pushed `header_action` (§4), and the org-clock widget and
org-capture QS tile are elisp-composed `widget:customN` /
`tile:customN` slot pushes in the glasspane repo.
