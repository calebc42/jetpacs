# EABP — Emacs–Android Bridge Protocol

[![CI](https://github.com/calebc42/glasspane/actions/workflows/ci.yml/badge.svg)](https://github.com/calebc42/glasspane/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**Don't approximate Emacs — connect to it.**

LLM-Generated Proof of Concept

Every mobile org app parses the org file and reconstructs what Emacs would
have computed. That works, but the file is a serialization format, not a
specification: the canonical computation lives in Emacs. Custom TODO
sequences, agenda skip functions, `org-ql` queries, capture hooks, clock
behavior — a parser can only approximate them.

EABP takes a different premise. The phone is a thin pane of glass; Emacs
is the source of truth behind it.

```
  ┌─────────────────────────────────┐
  │  Android companion (the pane)   │
  │  • Foreground service           │
  │  • Renders whatever Emacs sends │
  │  • Caches last-known UI state   │
  │  • Queues offline actions       │
  └──────────────┬──────────────────┘
                 │  EABP: NDJSON bridge
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

This repo is **the EABP foundation + its Android companion**. The
Glasspane reference Tier 1 lives in its own repo (it `(require 's this
core); the boundary is enforced by the build on both sides:

- **EABP, the foundation** (this repo) — a written protocol
  ([docs/SPEC.md](docs/SPEC.md)), the core Emacs client
  (`emacs/core/`, bundled as `eabp-core.el`), and the app-agnostic
  Android renderer + companion (the `:eabp` Gradle library in `eabp/`
  and the `:app` companion shell). The foundation renders *any* buffer,
  palettes *any* keymap, bridges *any* minibuffer prompt, and gives apps
  a shell (tabs, drawer, snackbar), an editor bridge (completion,
  diagnostics, eldoc), and a schema-driven settings machinery. It
  contains no org code and names no host app — a guard test enforces the
  first, the module boundary the second. `emacs/apps/eabp-hello.el` is
  the minimal worked Tier-1 example.
- **Glasspane, the reference Tier 1** — one opinionated org app built on
  those seams, in the **separate `glasspane` repo** (pure elisp; it
  vendors this repo as a submodule and `(require 's `eabp-core`). It
  exists to prove the foundation and to be copied from — not to be the
  one true mobile Emacs.

The tier model, module map, and every extension seam are documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). If you want to build your
own Tier 1 — your own tabs, skins, and workflow — start at
[docs/BUILDING-TIER1.md](docs/BUILDING-TIER1.md).

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
task breakdown in its own plan document:

- **Device automation, FOSS Tasker-style**
  ([docs/PLAN-automation-and-launcher.md](docs/PLAN-automation-and-launcher.md))
  — the protocol already reserves `triggers` and `capabilities` in the
  handshake; the plan fills them in: Android events (time, power,
  screen, connectivity, notifications) delivered to Emacs through the
  existing offline queue, device effectors (intents, flashlight, TTS,
  volume) invocable from elisp, and automations authored in org files.
  Elisp is the task language; that's the point.
- **One app, many builds, AppSheet-style** (same plan, track L) — views
  group into named apps behind a launcher home; builds travel as single
  elisp files (installed with explicit code-trust consent) or as
  **declarative org documents** with no code at all; any of them pins to
  the home screen as its own icon.
- **Converting Obsidian / Logseq / Notion users**
  ([docs/PLAN-pkm-conversion.md](docs/PLAN-pkm-conversion.md)) — org
  already subsumes their data models; the gap is UX abstraction:
  wikilinks + backlinks, a daily-note landing surface, concealed live
  editing, saved org-ql queries as table/board/calendar views, and vault
  importers. The bar for every one of those tasks: a convert never sees
  Emacs and never sees raw org syntax unless they ask.
- **Beyond Android** (same plan, track K) — the companion is a thin
  renderer by contract, so a Kotlin Multiplatform port (Compose Desktop,
  iOS against a remote Emacs) is "port the pane, keep the brain." The
  `:eabp` / `:app` module split is the extraction seam.

## Status

Proof of concept. Working today: the org dashboard, clock notification,
minibuffer bridge, offline action queue, live editor sync with
completion/diagnostics/eldoc, the tablist and transient renderers, and
the pairing handshake.

Known limitations:

- **Local-only.** The v0 transport is a loopback TCP socket
  (`127.0.0.1:8765`) guarded by a mutual HMAC pairing handshake. The 1.0
  target adds a Unix domain socket option — see the transport note in the
  [spec](docs/SPEC.md#1-roles-and-transport).
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

- [`eabp-core.el`](eabp-core.el) — the EABP foundation, for building or
  running a Tier 1:

  ```elisp
  (add-to-list 'load-path "~/.emacs.d/elisp") ; wherever you put the file
  (require 'eabp-core)
  ```

  For the full Glasspane org-app experience, also install `glasspane.el`
  from the separate [`glasspane`](../glasspane) repo and
  `(require 'glasspane)` after `eabp-core` (it depends on this core).
  `emacs/apps/eabp-hello.el` is the minimal Tier-1 example bundled here.

**Option B — the individual sources.** Clone the repo and put the source
directories on your `load-path`:

```elisp
(add-to-list 'load-path "~/src/eabp/emacs/core")
(add-to-list 'load-path "~/src/eabp/emacs/apps")   ; eabp-hello, the minimal example
(require 'eabp-core)   ; or just the core features you want
```

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
`(setq eabp-auth-token ...)` line — tap it to copy, add it to your init,
then:

```
M-x eabp-connect
```

Emacs auto-connects on startup (`after-init-hook`), so if the app was
already running when Emacs launched you may already be connected — check
with `M-x eabp-ping`. The dashboard should now appear on the phone.

> **v0 is local-only.** The loopback socket assumes Emacs and the
> companion run on the same device (Emacs via the Android Emacs port, or
> an emulator sharing the host loopback).

## Layout

- `docs/` — [SPEC.md](docs/SPEC.md) (the wire protocol),
  [ARCHITECTURE.md](docs/ARCHITECTURE.md) (tiers, modules, seams),
  [BUILDING-TIER1.md](docs/BUILDING-TIER1.md) (extension guide),
  [ROADMAP.md](docs/ROADMAP.md) (prioritized plan) and the `PLAN-*.md`
  audits it draws from.
- `emacs/core/` — the EABP Elisp client (`eabp-*.el`): transport, shell,
  generic renderers, minibuffer bridge, editor sync, settings machinery.
- `emacs/apps/` — Tier 1: `glasspane/` (the org app), `eabp-magit.el`,
  `eabp-package-browser.el`.
- `eabp/` — the `:eabp` Android library (Kotlin / Jetpack Compose):
  protocol, renderer, offline queue, widgets/tiles/notifications.
- `app/` — the `:app` Glasspane shell: branding, launcher activity, the
  org capture tile and keyboard toolbar.
- `test/` — ERT suite, the widget wire-format golden, and the
  core-isolation guard.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the test suites, and
the standing rules (the wire-safety boundary chief among them).

The foundation is the part meant to outlive any single app. Most valuable
right now: a second companion (desktop? e-ink?) written against the spec,
the signed-socket transport, the offline/hybrid fallback layer, and more
worked Tier 1 examples. If you build on the seams and something is
missing or leaky, that's a bug in the foundation — file it as one.

## License

EABP and Glasspane are free software, licensed under the **GNU General
Public License, version 3 or later** ([GPL-3.0-or-later](LICENSE)).
Copyright (C) 2026 calebc42 and contributors.

GPLv3 is the natural home for this project: the Emacs side is built on
GNU Emacs and org-mode (themselves GPLv3+), and the Android side combines
cleanly with it (its libraries are Apache-2.0, which GPLv3 permits). The
license covers the *code* in this repository; the **wire protocol itself**
([docs/SPEC.md](docs/SPEC.md)) is an interface anyone may implement — a
clean-room companion or client written against the spec carries no
obligation from this repo's license.
