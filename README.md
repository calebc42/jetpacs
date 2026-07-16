# Jetpacs — Emacs–Android Bridge Protocol

[![CI](https://github.com/calebc42/jetpacs/actions/workflows/ci.yml/badge.svg)](https://github.com/calebc42/jetpacs/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**Don't approximate Emacs — connect to it.**

LLM-Generated Proof of Concept

Every mobile org app parses the org file and reconstructs what Emacs would
have computed. That works, but the file is a serialization format, not a
specification: the canonical computation lives in Emacs. Custom TODO
sequences, agenda skip functions, `org-ql` queries, capture hooks, clock
behavior — a parser can only approximate them.

Jetpacs takes a different premise. The phone is a thin pane of glass; Emacs
is the source of truth behind it.

```
  ┌─────────────────────────────────┐
  │  Android companion (the pane)   │
  │  • Foreground service           │
  │  • Renders whatever Emacs sends │
  │  • Caches last-known UI state   │
  │  • Queues offline actions       │
  └──────────────┬──────────────────┘
                 │  Jetpacs: NDJSON bridge
                 │  (loopback socket → signed Unix socket)
  ┌──────────────┴──────────────────┐
  │  Emacs (the source of truth)    │
  │  • Pushes native UI specs       │
  │  • Handles user action events   │
  │  • Runs all the actual logic    │
  └─────────────────────────────────┘
```

The companion is a generic renderer with no application logic. It listens,
renders cached surfaces when Emacs is backgrounded, and replays queued
actions when Emacs resumes. Emacs dials in as the client — the same
inversion `emacsclient` uses on the desktop.

## The foundation and the reference app

This repo is **the Jetpacs foundation + its Android companion**. The
Glasspane reference Tier 1 lives in its own repo (it `require`s this
core); the boundary is enforced by the build on both sides:

- **Jetpacs, the foundation** (this repo) — a written protocol
  ([SPEC.md](https://github.com/calebc42/ebp/blob/main/SPEC.md), which
  lives in its own [ebp repo](https://github.com/calebc42/ebp) and is
  pinned here as the `ebp/` submodule), the core Emacs client
  (`emacs/core/`, bundled as `jetpacs-core.el`), and the app-agnostic
  Android renderer + companion (the `:jetpacs` Gradle library in `jetpacs/`
  and the `:app` companion shell). The foundation renders *any* buffer,
  palettes *any* keymap, bridges *any* minibuffer prompt, and gives apps
  a shell (tabs, drawer, snackbar), an editor bridge (completion,
  diagnostics, eldoc), a device layer (effectors out, triggers in,
  home-screen widgets, tiles, notifications, reminders), and a
  schema-driven settings machinery. It
  contains no org code and names no host app — a guard test enforces the
  first, the module boundary the second. `emacs/apps/jetpacs-hello.el` is
  the minimal worked Tier-1 example.
- **Glasspane, the reference Tier 1** — one opinionated org app built on
  those seams, in the **separate [`glasspane` repo](https://github.com/calebc42/glasspane)** (pure elisp; it
  vendors this repo as a submodule and `require`s `jetpacs-core`). It
  exists to prove the foundation and to be copied from — not to be the
  one true mobile Emacs.

The tier model, module map, and every extension seam are documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). If you want to build your
own Tier 1 — your own tabs, skins, and workflow — start with the
hands-on walkthrough in [docs/TUTORIAL.md](docs/TUTORIAL.md), then the
map of every extension surface in
[docs/BUILDING-TIER1.md](docs/BUILDING-TIER1.md) and the widget-DSL
reference in [docs/WIDGETS.md](docs/WIDGETS.md).

### The tiers in one breath

- **Tier 0** — any Emacs buffer renders on the phone by walking its text
  properties; minibuffer prompts become native dialogs; any keymap is a
  searchable command palette; M-x works. Zero per-package code.
- **Tier 0.5** — one renderer per declarative Emacs UI framework:
  `tabulated-list-mode` (every package menu/process list/bookmark table)
  and `transient` (all of magit's menus) render as native touch UI.
- **Tier 1** — curated apps and skins on top. Glasspane is one. Yours is
  the point.

## What this makes possible

Things a file parser can't do, no matter how good it is:

- Run the user's actual capture templates (`:function` entries, hooks, `%(elisp)`).
- Run `org-ql-select` across the whole org-roam graph.
- Reflect the real `org-todo-keywords` sequence.
- `org-clock-in` with correct hooks and modeline behavior.
- Trigger any interactive command — M-x on the phone.

When Emacs isn't connected, the file-parsing approach is still the right
answer. The interesting design is the hybrid: parse offline, upgrade to
the live bridge transparently when Emacs comes online.

## Where this is going

The prioritized plan across everything below is
[docs/ROADMAP.md](docs/ROADMAP.md); each direction has a full audit and
task breakdown in its own plan document (the app-level plans live in
the glasspane repo):

- **Finishing the automation surface**
  ([PLAN-automation-and-launcher.md](https://github.com/calebc42/glasspane/blob/main/docs/PLAN-automation-and-launcher.md),
  in the glasspane repo) — device triggers, effectors, and the
  multi-app launcher ship today (see Status below and
  [BUILDING-TIER1](docs/BUILDING-TIER1.md#the-platform-beyond-the-screen));
  what remains is the hardware-gated connectivity batch (`wifi.ssid`,
  `bluetooth.device`) and a notification-listener event source. Elisp
  is the task language; that's the point.
- **Declarative app builds** (same plan, track L) — apps already
  travel as single elisp files installed with explicit code-trust
  consent, grouped behind the launcher home with their own pinned
  icons; the next step is builds as **declarative org documents** with
  no code at all.
- **Converting Obsidian / Logseq / Notion users**
  ([PLAN-pkm-conversion.md](https://github.com/calebc42/glasspane/blob/main/docs/PLAN-pkm-conversion.md),
  in the glasspane repo) — org
  already subsumes their data models; the gap is UX abstraction:
  wikilinks + backlinks, a daily-note landing surface, concealed live
  editing, saved org-ql queries as table/board/calendar views, and vault
  importers. The bar for every one of those tasks: a convert never sees
  Emacs and never sees raw org syntax unless they ask.
- **Beyond Android** (same plan, track K) — the companion is a thin
  renderer by contract, so a Kotlin Multiplatform port (Compose Desktop,
  iOS against a remote Emacs) is "port the pane, keep the brain." The
  `:jetpacs` / `:app` module split is the extraction seam.

## Status

Proof of concept, but a broad one — everything in
[SPEC.md](https://github.com/calebc42/ebp/blob/main/SPEC.md) is
implemented on both sides. Working today:

- **Rendering** — any buffer (Tier 0); the tabulated-list, transient,
  and comint renderers (Tier 0.5); the full SPEC §9 widget vocabulary
  through tables, charts, canvas, and the agenda month grid.
- **The app shell** — multi-app launcher home with per-app tabs,
  chrome, and settings; the package browser, customize browser, tools
  hub, and automations screen as stock chrome.
- **Interaction** — the semantic-action allowlist, the offline queue
  with replay and dedupe, the full minibuffer-prompt bridge, dialogs
  and bottom sheets, radial pie menus, toasts.
- **Editing** — live editor sync with completion, flymake diagnostics,
  eldoc, and fontification, opt-in eglot; data-driven keyboard
  toolbars; the with-editor bridge (`git commit` from the phone).
- **The device** — effectors callable from elisp (intents, TTS, torch,
  volume/DND/brightness, media keys, clipboard, launcher shortcuts);
  device triggers with companion-local `on_fire` and reboot re-arm;
  home-screen widget and QS-tile slots; notification surfaces with a
  live chronometer; persistent reminders; Emacs-theme mirroring.
- **Transport** — mutual HMAC pairing, reconnect backoff, monotonic
  surface revisions with offline rendering from cache.

Known limitations:

- **Local-only.** The v0 transport is a loopback TCP socket
  (`127.0.0.1:8765`) guarded by a mutual HMAC pairing handshake. The 1.0
  target adds a Unix domain socket option — see the transport note in the
  [spec](https://github.com/calebc42/ebp/blob/main/SPEC.md#1-roles-and-transport).
- **Android-only companion.** iOS has no Emacs port to connect to. The
  protocol is platform-agnostic and now written down precisely so other
  companions can exist.
- **Unprofiled.** Bridge latency and the foreground-service battery cost
  have not been measured.

## Getting started

You need two halves running: the **Emacs client** and the **Android
companion**. The companion listens; Emacs dials in.

### 1. Load the Emacs client

Requires Emacs 28+ (for the C-level JSON functions).

**Option A — single-file bundle (simplest).** Grab the pre-built
foundation bundle from the repo root, drop it somewhere on your
`load-path`, and load it from your `init.el`:

- [`jetpacs-core.el`](jetpacs-core.el) — the Jetpacs foundation, for building or
  running a Tier 1:

  ```elisp
  (add-to-list 'load-path "~/.emacs.d/elisp") ; wherever you put the file
  (require 'jetpacs-core)
  ```

  For the full Glasspane org-app experience, also install `glasspane.el`
  from the separate [`glasspane`](https://github.com/calebc42/glasspane) repo and
  `(require 'glasspane)` after `jetpacs-core` (it depends on this core).
  `emacs/apps/jetpacs-hello.el` is the minimal Tier-1 example bundled here.

**Option B — the individual sources.** Clone the repo and put the source
directories on your `load-path`:

```elisp
(add-to-list 'load-path "~/src/jetpacs/emacs/core")
(add-to-list 'load-path "~/src/jetpacs/emacs/apps")   ; jetpacs-hello, the minimal example
(require 'jetpacs-core)   ; or just the core features you want
```

**Option C — install as a package, straight from git.** No MELPA
needed: `package-vc-install` (Emacs 29+; this repo's floor is 30.1)
clones, byte-compiles, and generates autoloads at install time, and
`M-x package-vc-upgrade` tracks upstream from then on:

```elisp
(package-vc-install
 '(jetpacs :url "https://github.com/calebc42/jetpacs"
           :lisp-dir "emacs/core"))
```

This is the **desktop / fork-maintainer** path. `:lisp-dir` scopes the
install to the multi-file core — package.el never sees the generated
root bundle, and the repo layout doesn't change. It installs the
*individual features*, not the bundle's `jetpacs-core` umbrella: require
what you use (`jetpacs-shell` pulls the transport + app scaffold; the
optional surfaces — `jetpacs-tools`, `jetpacs-automations`,
`jetpacs-org`, … — are each their own feature). The **phone path stays
bundle adoption** (Option A, what the companion's wizard stages):
on-device `package-vc` would need git and network inside Emacs —
possible via the Termux signature share, but that's the advanced
footnote, not the default.

> The bundle is generated from the sources by `emacs/build-bundle.el`.
> Regenerate it with `emacs --batch -l emacs/build-bundle.el` after
> editing.

### 2. Build and install the companion APK

Open the project in **Android Studio** (Giraffe or newer):

1. `File → Open` and select the repo root. Let Gradle sync finish.
2. Plug in a device (or start an emulator) and press **Run ▶** on the
   `app` configuration — this builds a debug APK and installs it.

Prefer the command line? From the repo root:

```sh
./gradlew installDebug     # build + install the debug APK on a connected device
# or just build the APK, output under app/build/outputs/apk/debug/
./gradlew assembleDebug
```

Launch the companion app; it starts the foreground service and listens on
`127.0.0.1:8765`.

### 3. Pair and connect

The companion's screen shows a pairing token as a ready-made
`(setq jetpacs-auth-token ...)` line — tap it to copy, add it to your init,
then:

```
M-x jetpacs-connect
```

Emacs auto-connects on startup (`after-init-hook`), so if the app was
already running when Emacs launched you may already be connected — check
with `M-x jetpacs-ping`. The dashboard should now appear on the phone.

> **v0 is local-only.** The loopback socket assumes Emacs and the
> companion run on the same device (Emacs via the Android Emacs port, or
> an emulator sharing the host loopback).

## Layout

- `ebp/` — the wire contract as a submodule of the
  [ebp repo](https://github.com/calebc42/ebp): SPEC.md (the protocol),
  contract.json (the machine-readable vocabulary), the golden conformance
  corpus, and BUILDING-COMPANION.md (build your own companion/renderer).
  Pin that repo, not this one, to implement the protocol.
- `docs/` — [ARCHITECTURE.md](docs/ARCHITECTURE.md) (tiers, modules, seams),
  [TUTORIAL.md](docs/TUTORIAL.md) (hello world, step by step),
  [BUILDING-TIER1.md](docs/BUILDING-TIER1.md) (build your own app),
  [WIDGETS.md](docs/WIDGETS.md) (the widget-DSL reference),
  [ROADMAP.md](docs/ROADMAP.md) (the foundation
  roadmap) and the foundation-side `PLAN-*.md` records (the app-level
  plans live in the glasspane repo).
- `emacs/core/` — the Jetpacs Elisp client (`jetpacs-*.el`): transport, shell,
  generic renderers, minibuffer bridge, editor sync, settings machinery.
- `emacs/apps/` — `jetpacs-hello.el`, the minimal worked Tier-1 example.
  The real Tier-1 apps live in the glasspane repo.
- `jetpacs/` — the `:jetpacs` Android library (Kotlin / Jetpack Compose):
  protocol, renderer, offline queue, widgets/tiles/notifications.
- `app/` — the `:app` Glasspane shell: branding, launcher activity, the
  org capture tile and keyboard toolbar.
- `test/` — the main and primitives ERT suites and the core-isolation
  guard (`core-load-test.el`); the wire-format goldens live in `ebp/`.

## Contributing

Three doors, and only the last needs buy-in from this repo:

- **Build your own app** on the foundation — start at
  [docs/TUTORIAL.md](docs/TUTORIAL.md), then
  [docs/BUILDING-TIER1.md](docs/BUILDING-TIER1.md).
- **Build your own companion** against the wire —
  [BUILDING-COMPANION.md](https://github.com/calebc42/ebp/blob/main/BUILDING-COMPANION.md)
  in the ebp repo.
- **Change the foundation itself** — [CONTRIBUTING.md](CONTRIBUTING.md)
  (setup, test suites, and the standing rules, the wire-safety boundary
  chief among them). Contributions to Glasspane go to
  [its repo](https://github.com/calebc42/glasspane).

The foundation is the part meant to outlive any single app. Most
valuable right now: a second companion written against the spec, the
signed-socket transport, and MELPA packaging — see
[docs/ROADMAP.md](docs/ROADMAP.md). If you build on the seams and
something is missing or leaky, that's a bug in the foundation — file it
as one.

## License

Jetpacs and Glasspane are free software, licensed under the **GNU General
Public License, version 3 or later** ([GPL-3.0-or-later](LICENSE)).
Copyright (C) 2026 calebc42 and contributors.

GPLv3 is the natural home for this project: the Emacs side is built on
GNU Emacs and org-mode (themselves GPLv3+), and the Android side combines
cleanly with it (its libraries are Apache-2.0, which GPLv3 permits). The
license covers the *code* in this repository; the **wire protocol itself**
([SPEC.md](https://github.com/calebc42/ebp/blob/main/SPEC.md) in the
ebp repo) is an interface anyone may implement — a
clean-room companion or client written against the spec carries no
obligation from this repo's license.
