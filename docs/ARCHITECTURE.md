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
| `eabp-minibuffer.el` | prompt bridge: `y-or-n-p` / `completing-read` / … → dialogs, only inside action handlers |
| `eabp-buffer.el` | **Tier 0 renderer**: any buffer → spans + tappable regions; the major-mode→skin registry |
| `eabp-shell.el` | the app shell: view registry, tab/drawer/top-bar chrome, snackbar, connect/refresh pushes |
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
`Reminders`, the widget providers + tile slots, `RadialMenu` /
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
