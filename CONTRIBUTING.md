# Contributing

**This file is about changing the foundation** — the wire, the core
elisp, the `:jetpacs` renderer library, the reference companion shell.
Most people who arrive here want one of the other three doors, none of
which needs any buy-in from this repo:

- **Building your own app** (a Tier 1) on top of the foundation →
  [docs/TUTORIAL.md](docs/TUTORIAL.md), then
  [docs/BUILDING-TIER1.md](docs/BUILDING-TIER1.md).
- **Building your own companion** (another platform's renderer) against
  the wire →
  [BUILDING-COMPANION.md](https://github.com/calebc42/ebp/blob/main/BUILDING-COMPANION.md)
  in the [ebp protocol repo](https://github.com/calebc42/ebp).
- **Contributing to Glasspane** (the reference org app) → it lives in
  [its own repo](https://github.com/calebc42/glasspane); file issues
  and PRs there.

Still here to change the foundation? The conceptual half is
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (tiers, modules, seams) and
[SPEC.md](https://github.com/calebc42/ebp/blob/main/SPEC.md) (the wire
contract — the `ebp/` submodule); below is the practical half — setup,
tests, and the standing rules.

## What's most valuable

The prioritized queue is [docs/ROADMAP.md](docs/ROADMAP.md). Standing
highest: the signed-socket transport (the 1.0 transport target), a
second companion written against the spec (see BUILDING-COMPANION —
the goldens are your conformance fixtures), MELPA packaging of the
elisp client, and profiling the bridge's battery cost.

If you build on the extension seams and something is missing or leaky,
that's a bug in the foundation — file it as one. The same goes for the
docs: if BUILDING-TIER1 or BUILDING-COMPANION left you stuck, the
gap is a foundation bug.

## Setup

Clone with `--recurse-submodules` — the wire contract (SPEC, the
machine-readable `contract.json`, the golden fixtures) lives in the
`ebp/` submodule, and the test suites read it from there.

**Emacs side** (Emacs 28+, tested on 30.x): nothing to install — the
sources under `emacs/` run from a checkout. Batch tests below.

**Android side**: Android Studio (or JDK 17+ and the command line).
Two Gradle modules: `:jetpacs` (the library — protocol, renderer, OS
surfaces) and `:app` (the reference companion shell). `./gradlew
installDebug` builds and installs on a connected device.

## Tests — run these before any PR

```sh
# 1. Core isolation guard: emacs/core must load with no app layer, no org.
emacs -Q --batch -l test/core-load-test.el

# 2. The main ERT suite (widgets, surfaces, protocol, renderers).
emacs -Q --batch -l test/jetpacs-tests.el -f ert-run-tests-batch-and-exit

# 3. The primitives suite (minibuffer bridge, buffer walk, transient).
emacs -Q --batch -l test/jetpacs-primitives-test.el -f ert-run-tests-batch-and-exit

# 4. Kotlin: both modules build.
./gradlew :jetpacs:assembleDebug :app:assembleDebug
```

CI (`.github/workflows/ci.yml`) runs exactly these, plus a check that
the generated `jetpacs-core.el` bundle is current.

## The standing rules

These are load-bearing; PRs that break them will be asked to change,
however good the feature.

1. **The command-dispatch boundary (normative,
   [SPEC §5](https://github.com/calebc42/ebp/blob/main/SPEC.md#5-events-the-semantic-action-boundary)).**
   Nothing on the wire names code to run. An action is a name the Emacs
   side explicitly registered (`jetpacs-defaction`); its handler validates
   its args and performs one narrow operation. Never write a handler
   that funcalls, evals, or opens paths straight off the wire. New
   actions get documented in SPEC §5, in their module's namespace.
2. **The core is org-free.** `emacs/core/` must load without org or any
   app feature — `test/core-load-test.el` enforces it. Org knowledge
   lives in the Glasspane app (its own repo).
3. **The Kotlin mirror: protocol → `:jetpacs`, opinion → `:app`.** The
   library names no host class — app launches go through `JetpacsLaunch`,
   editor toolbars through the `JetpacsToolbars` registry. If your library
   change needs to know about Glasspane, it's cut at the wrong altitude.
4. **The bundle is generated.** Root `jetpacs-core.el` comes from
   `emacs --batch -l emacs/build-bundle.el` — never edit it by hand;
   regenerate after any `emacs/` source change and commit the result.
5. **The goldens are the wire truth, and they live in the ebp
   submodule.** `ebp/goldens/widgets.golden` is the machine-checked
   shape of every node constructor; `ebp/goldens/frames.golden` pins
   the trigger/capability frame payloads (SPEC §10–§11); the elisp
   lint tables project into `ebp/contract.json`. Regenerate them only
   for an INTENTIONAL wire change
   (`emacs -Q --batch -l test/jetpacs-tests.el -f jetpacs-tests-regen-widget-golden`
   / `-f jetpacs-tests-regen-frame-golden` /
   `emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write`),
   and document the change in SPEC §9 (widgets) or the frame's own
   section. The release flow is two commits, one direction: edit the
   elisp tables/constructors here → regenerate into `ebp/` → commit in
   the ebp repo (tag it if the spec or protocol version moved) → bump
   the submodule pointer in this repo. Wire additions must be
   additive — unknown kinds/attrs are ignored, never fatal. If the
   Kotlin counterpart can't land in the same PR, the elisp side must
   degrade cleanly without it.
6. **Degrade, don't hang.** If a bridged flow can't be represented on
   the phone, signal `quit` (renders as "cancelled") rather than
   blocking. A cancelled prompt beats a frozen phone.
7. **Battery is a feature.** Event-driven over polling, elisp over
   spawned binaries, no timers where a hook exists. If your change adds
   background work, say what it costs.

(App-authoring rules — org case conventions, the view-cache contract —
live where the apps do: [BUILDING-TIER1.md](docs/BUILDING-TIER1.md) and
the [glasspane repo](https://github.com/calebc42/glasspane).)

## Style

Match the file you're in — both sides of this repo have a distinct
voice (heavily commented, comments explain *why* and cite the OS or
protocol constraint). Commit messages follow the existing log:
`feat:` / `refactor:` / short imperative subject, body only when the
diff doesn't speak for itself.

## License

The project is licensed **GPL-3.0-or-later** (see [LICENSE](LICENSE)).
By submitting a contribution you agree it is licensed under those same
terms (inbound = outbound) — no separate CLA. Don't paste in code under
an incompatible license; Apache-2.0 / MIT / BSD sources are fine
(GPLv3 can absorb them), but keep their notices intact.

## Security

The pairing handshake (mutual HMAC over a never-transmitted token) is
the trust boundary between the companion and whatever speaks the
protocol; the action allowlist is the boundary between the wire and
Emacs. If you believe you've found a hole in either, open a private
security advisory on GitHub rather than a public issue.
