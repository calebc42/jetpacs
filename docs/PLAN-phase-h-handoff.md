# Handoff: execute platform-hardening Phase H (Tasks 22–24)

**EXECUTED 2026-07-13 — Phase H is done** (one commit per task, order
23 → 22 → 24, then the api-1.7.0 finalize commit; suite 141/141 + 54/54;
on-device rows pending in the glasspane repo's TESTING-ON-DEVICE.md
§18–§19). Kept as the record of the execution grounding.

**Written 2026-07-13 for a fresh chat.** The task SPECS live in
[PLAN-platform-hardening.md](PLAN-platform-hardening.md) § Phase H — read
them first; they are complete and audit-grounded. This doc adds only what
that master can't know: the verified current state, the execution order,
the version/artifact discipline, and the gotchas recent sessions paid for.
**Re-verify everything below before editing — the owner develops live.**

## Current state (verified 2026-07-13, evening)

- jetpacs `main` is at api **1.6.0** (`jetpacs-org` note-index batch), all
  pushed; suite **136/136** (`sh test/run-tests.sh` under WSL Debian) +
  **54/54** primitives + core-load guard + contract/bundle drift gates.
- Phases A–G are DONE (G landed both repos, incl. Glasspane Task 21).
  **Phase H: none of it is started** — no `load-prefer-newer` or
  `byte-compile` in `docs/jetpacs-init.el` (60 lines, the Task 19 adopt
  seam) or `emacs/core/jetpacs-config.el`; no `jetpacs-build-features`
  anywhere; no `Version:`/`Package-Requires:` headers on
  `emacs/core/jetpacs.el`.
- The repo is LF-normalized (`.gitattributes` `* text=auto eol=lf`,
  commit `602bac3`). Consumers (Glasspane, jetpacs-composer) pin the
  submodule at `5c84a68`+; bump them only if Phase H must be consumed
  there (it shouldn't — all three tasks are foundation-local).

## Execution order

**Task 23 → Task 22 → Task 24** (the master says why: 23's probe is
reporting-only and unblocks 22's native-comp decision *and* the queued
SQLite org-index direction; 22 rides the Task 19 adopt seam; 24 is
independent docs+headers work, do it last as the cheap win).

## Grounding the master spec doesn't have

### Task 23 (feature probe)
- The `hello` `client` object is built at `emacs/core/jetpacs.el:473`
  (`(client . ,(format "emacs/%s jetpacs.el/%s" …))` inside the hello
  payload) — add the sibling `features` field there.
- **`test/frames.golden` does NOT pin the client object** (verified:
  zero `client` hits) — the new wire field should need no golden regen,
  but run the suite and believe it over this note.
- The Bridge settings section lives in `emacs/core/jetpacs-settings.el`
  (grep for the section registration — the exact symbol wasn't captured;
  it's the section Phase F/theming gave the foundation). One row, matrix
  as check/dash.
- SPEC §3 gets the additive `features` note (wire vocabulary is
  negotiated, not version-gated — mirror how `node_types` is described).

### Task 22 (byte-compile at adopt)
- The adopt/sync verbs are `jetpacs-app-config-{sync,ensure}` +
  `jetpacs-config-{adopt,bootstrap}` in `emacs/core/jetpacs-config.el`;
  `docs/jetpacs-init.el` is where `load-prefer-newer t` goes.
- Batch-test against a temp `jetpacs-root` — the Phase G tests in
  `test/jetpacs-tests.el` (`jetpacs-config-*`, `jetpacs-install-*`)
  show the temp-root binding pattern to copy.
- Remember `.gitignore` already ignores `*.elc` — on-device artifacts
  only, keep it that way.

### Task 24 (package-vc path)
- `Version:` header must equal `jetpacs-api-version` — add the
  drift-pin test the master asks for next to
  `jetpacs-api-version-bound` in `test/jetpacs-tests.el`.
- The "don't let package.el see the generated root `jetpacs-core.el`"
  pitfall: the root bundle lives OUTSIDE `emacs/core/`, and
  `:lisp-dir "emacs/core"` scopes the install — verify, then say so in
  the README section instead of inventing machinery.

## Version & artifact discipline (this bites every time)

- New public elisp surface (`jetpacs-build-features`, `jetpacs-feature-p`)
  ⇒ **api bump 1.6.0 → 1.7.0** in `emacs/core/jetpacs.el` (one minor per
  landed batch — all of Phase H is one batch) ⇒ **API-STABILITY.md**
  section entry. That doc is machine-checked: every backticked
  `jetpacs-*` symbol under "The public surface" must be bound
  (`jetpacs-api-stability-symbols-bound`), so name only real symbols.
- **contract.json embeds the api version** — after the bump, regenerate:
  `emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write`
  (the drift test goes red otherwise).
- **Regenerate the bundle** after any `emacs/` change:
  `emacs --batch -l emacs/build-bundle.el` (CI diffs it).
- Test gate, after every task: WSL Debian —
  `wsl -d Debian bash -c "cd /mnt/c/Users/caleb/AndroidStudioProjects/jetpacs && sh test/run-tests.sh"`
  plus the primitives suite (`-l test/jetpacs-primitives-test.el`).

## Session gotchas (paid for recently — don't re-learn)

- **No SSH/GitHub creds in agent sessions** (Git Bash, PowerShell, and
  WSL all fail publickey) — commit locally; the owner pushes.
- **Git Bash pipes strip `\r` before grep sees it** — do byte-level
  checks via `git grep`/`tr` or inside WSL.
- Keep working files LF; `gradlew.bat` is the one CRLF file (policy in
  `.gitattributes`).
- Docs are **current state, never changelog narrative** (standing owner
  rule). When Phase H lands, flip PLAN-platform-hardening.md's status
  line and this doc's, in the same commit.
- On-device acceptance items go to `docs/TESTING-ON-DEVICE.md` as new
  sections (Tasks 22/23 each add one); they stay pending until hardware.

## Definition of done

All three tasks landed on jetpacs `main` with the master's acceptance
criteria satisfied batch-side (on-device rows recorded as pending in
TESTING-ON-DEVICE.md); api 1.7.0 + API-STABILITY + contract + bundle all
regenerated and green; PLAN-platform-hardening.md reads "A–H done";
ROADMAP's MELPA bullet gains the package-vc middle-path line.
