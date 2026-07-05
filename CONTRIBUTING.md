# Contributing

Thanks for looking under the hood. This file is the practical half —
setup, tests, and the standing rules. The conceptual half is
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (tiers, modules, seams) and
[docs/SPEC.md](docs/SPEC.md) (the wire contract); if you want to build
your own app on the foundation rather than change the foundation, start
at [docs/BUILDING-TIER1.md](docs/BUILDING-TIER1.md) instead — that's the
happy path, and it needs no buy-in from this repo at all.

## What's most valuable

A second companion (desktop? e-ink?) written against the spec, the
signed-socket transport, more worked Tier 1 examples, and anything on
[docs/ROADMAP.md](docs/ROADMAP.md) — the roadmap is the prioritized
queue, and its plan documents (`docs/PLAN-*.md`) break each item into
self-contained tasks with files, pitfalls, and acceptance criteria.

If you build on the extension seams and something is missing or leaky,
that's a bug in the foundation — file it as one.

## Setup

**Emacs side** (Emacs 28+, tested on 30.x): nothing to install — the
sources under `emacs/` run from a checkout. Batch tests below.

**Android side**: Android Studio (or JDK 17+ and the command line).
Two Gradle modules: `:eabp` (the library — protocol, renderer, OS
surfaces) and `:app` (the Glasspane shell). `./gradlew installDebug`
builds and installs on a connected device.

## Tests — run these before any PR

```sh
# 1. Core isolation guard: emacs/core must load with no app layer, no org.
emacs -Q --batch -l test/core-load-test.el

# 2. The main ERT suite (widgets, surfaces, protocol, renderers).
emacs -Q --batch -l test/eabp-tests.el -f ert-run-tests-batch-and-exit

# 3. The primitives suite (minibuffer bridge, buffer walk, transient).
emacs -Q --batch -l test/eabp-primitives-test.el -f ert-run-tests-batch-and-exit

# 4. Kotlin: both modules build.
./gradlew :eabp:assembleDebug :app:assembleDebug
```

CI (`.github/workflows/ci.yml`) runs exactly these, plus a check that
the generated bundles are current.

## The standing rules

These are load-bearing; PRs that break them will be asked to change,
however good the feature.

1. **The command-dispatch boundary (normative, [SPEC §5](docs/SPEC.md)).**
   Nothing on the wire names code to run. An action is a name the Emacs
   side explicitly registered (`eabp-defaction`); its handler validates
   its args and performs one narrow operation. Never write a handler
   that funcalls, evals, or opens paths straight off the wire. New
   actions get documented in SPEC §5, in their module's namespace.
2. **The core is org-free.** `emacs/core/` must load without org or any
   app feature — `test/core-load-test.el` enforces it. Org knowledge
   lives in `emacs/apps/glasspane/`.
3. **The Kotlin mirror: protocol → `:eabp`, opinion → `:app`.** The
   library names no host class — app launches go through `EabpLaunch`,
   editor toolbars through the `EabpToolbars` registry. If your library
   change needs to know about Glasspane, it's cut at the wrong altitude.
4. **Bundles are generated.** Root `eabp-core.el` and `glasspane.el`
   come from `emacs --batch -l emacs/build-bundle.el` — never edit them
   by hand; regenerate after any `emacs/` source change and commit the
   result.
5. **The goldens are the wire truth.** `test/widgets.golden` is the
   machine-checked shape of every node constructor; `test/frames.golden`
   pins the trigger/capability frame payloads (SPEC §10–§11). Regenerate
   them only for an INTENTIONAL wire change
   (`emacs -Q --batch -l test/eabp-tests.el -f eabp-tests-regen-widget-golden`
   / `-f eabp-tests-regen-frame-golden`), and document the change in
   SPEC §9 (widgets) or the frame's own section. Wire additions must be
   additive — unknown kinds/attrs are ignored, never fatal. If the
   Kotlin counterpart can't land in the same PR, the elisp side must
   degrade cleanly without it.
6. **Org case conventions.** Keywords, blocks, and drawers are
   recognized case-insensitively (bind `case-fold-search` explicitly);
   TODO keywords and tags are case-sensitive; display preserves file
   case. Every new org-syntax regex ships with a case test.
7. **The cache contract.** App views may memoise expensive extraction;
   every mutation path must invalidate — directly in the action handler,
   plus the shell's refresh hook for pull-to-refresh and queue drains.
8. **Degrade, don't hang.** If a bridged flow can't be represented on
   the phone, signal `quit` (renders as "cancelled") rather than
   blocking. A cancelled prompt beats a frozen phone.
9. **Battery is a feature.** Event-driven over polling, elisp over
   spawned binaries, no timers where a hook exists. If your change adds
   background work, say what it costs.

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
