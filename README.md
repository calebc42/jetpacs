# Glasspane

**Don't approximate Emacs — connect to it.**

Every mobile org app parses the org file and reconstructs what Emacs would have
computed. That works, but the file is a serialization format, not a
specification: the canonical computation lives in Emacs. Custom TODO sequences,
agenda skip functions, `org-ql` queries, capture hooks, clock behavior — a
parser can only approximate them.

Glasspane takes a different premise. The phone is a thin pane of glass; Emacs is
the source of truth behind it.

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
renders cached surfaces when Emacs is backgrounded, and replays queued actions
when Emacs resumes. Emacs dials in as the client — the same inversion
`emacsclient` uses on the desktop.

## Two tiers

- **Tier 0 — generic buffer rendering.** Any Emacs buffer renders on the phone
  by walking its text properties (`face`, `display`, `invisible`, `keymap`,
  `button`). No package-specific code — `magit-status`, `dired`, `*Org Agenda*`
  all work, as a beautiful, tappable Emacs buffer. Minibuffer prompts
  (`completing-read`, `y-or-n-p`, …) are forwarded as native dialogs.
- **Tier 1 — polished per-mode skins.** A registry maps a major mode to a custom
  surface builder that replaces the generic render with a native-feeling UI
  (e.g. an org-agenda skin that builds Material3 cards). Existing org-parsing
  work fits here — now on top of a live Emacs instead of an approximated one.

## What this makes possible

Things a file parser can't do, no matter how good it is:

- Run the user's actual capture templates (`:function` entries, hooks, `%(elisp)`).
- Run `org-ql-select` across the whole org-roam graph.
- Reflect the real `org-todo-keywords` sequence.
- `org-clock-in` with correct hooks and modeline behavior.
- Trigger any interactive command — M-x on the phone.

When Emacs isn't connected, the file-parsing approach is still the right answer.
The interesting design is the hybrid: parse offline, upgrade to the live bridge
transparently when Emacs comes online.

## Status

Proof of concept. Working today: the org dashboard, clock notification,
minibuffer bridge, and offline action queue.

Known limitations:

- **Local-only.** The v0 transport is a loopback TCP socket
  (`127.0.0.1:8765`) — any process on the device can connect to it. The 1.0
  target is a Unix domain socket protected by a `signature`-level permission, so
  only the co-signed Emacs and companion APKs can reach it. That model
  deliberately excludes remote Emacs over the network.
- **Android-only.** iOS has no Emacs port to connect to. The protocol (EABP) is
  platform-agnostic; the companion is not.
- **Unprofiled.** Bridge latency and the foreground-service battery cost have not
  been measured.

## Getting started

You need two halves running: the **Emacs client** and the **Android companion**.
The companion listens; Emacs dials in.

### 1. Load the Emacs client

Requires Emacs 28+ (for the C-level JSON functions).

**Option A — single-file bundle (simplest).** Grab the pre-built
[`glasspane.el`](glasspane.el) from the repo root, drop it somewhere on your
`load-path`, and load it from your `init.el`:

```elisp
(add-to-list 'load-path "~/.emacs.d/elisp") ; wherever you put the file
(require 'glasspane)
```

**Option B — the individual sources.** Clone the repo and copy the source files
onto your `load-path`:

```sh
git clone https://github.com/YOUR_USER/eabp
mkdir -p ~/.emacs.d/elisp
cp eabp/emacs/eabp-*.el ~/.emacs.d/elisp/
```

```elisp
(add-to-list 'load-path "~/.emacs.d/elisp")
(require 'eabp-org-ui)   ; pulls in the transport, surfaces, and skins
```

> The bundle is generated from `emacs/eabp-*.el` by `emacs/build-bundle.el`.
> Regenerate it with `emacs --batch -l emacs/build-bundle.el` after editing the
> sources.

### 2. Build and install the companion APK

Open the project in **Android Studio** (Giraffe or newer):

1. `File → Open` and select the repo root. Let Gradle sync finish.
2. Plug in a device (or start an emulator) and press **Run ▶** on the `app`
   configuration — this builds a debug APK and installs it.

Prefer the command line? From the repo root:

```sh
./gradlew installDebug     # build + install the debug APK on a connected device
# or just build the APK, output under app/build/outputs/apk/debug/
./gradlew assembleDebug
```

Launch the companion app; it starts the foreground service and listens on
`127.0.0.1:8765`.

### 3. Connect

With the companion running, connect from Emacs:

```
M-x eabp-connect
```

Emacs auto-connects on startup (`after-init-hook`), so if the app was already
running when Emacs launched you may already be connected — check with
`M-x eabp-ping`. The org dashboard should now appear on the phone.

> **v0 is local-only.** The loopback socket assumes Emacs and the companion run
> on the same device (Emacs via the Android Emacs port, or an emulator sharing
> the host loopback). Remote/desktop Emacs is not supported yet — see the
> transport note under [Status](#status).

## Layout

- `emacs/` — the Elisp client (`eabp*.el`): transport, surfaces, generic buffer
  renderer, minibuffer bridge, org skins. `build-bundle.el` concatenates them
  into the top-level `glasspane.el`.
- `app/` — the Android companion (Kotlin / Jetpack Compose).

This is one vibe-coder's implementation of an architecture that could be much
larger. Contributions welcome — the generic buffer renderer, the offline/hybrid
fallback layer, the signed-socket transport, and the skin registration API are
the pieces most worth building out.
