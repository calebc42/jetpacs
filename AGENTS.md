# Repository Guidelines

## Project Structure & Module Organization

This repository holds the research and hand rewrite; the POC and its dependencies are separate sibling repositories. `../jetpacs-poc/` is the standalone Jetpacs POC repository. The sibling EBP POC repositories are: `ebp/` owns the protocol specification, `ebp.el/` the Emacs implementation, `ebp-kmp/` the Kotlin implementation, `ebp-compose/` the neutral Compose renderer, and `ebp-org/` the reusable Org integration. Developer utilities live in `../jetpacs-poc/jetpacs-platform-tools/` and `../jetpacs-poc/jetpacs-applet-mcp/`; `../glasspane/` is an applet. Root-level `.org` files are research and planning notes.

Before editing a child tree, read its nearest `AGENTS.md` and check its own `git status`. Historical Jetpacs versions live at the `poc/v1`, `poc/v2`, and `poc/v3-pre-split` tags rather than in worktrees.

## Build, Test, and Development Commands

Run commands from the owning project:

```sh
(cd ../ebp && python3 validate.py) # Validate contract and golden fixtures
(cd ../jetpacs-poc && ./test/run-tests.sh) # Full Elisp/Python suite
(cd ../jetpacs-poc/companion && ./gradlew testDebugUnitTest assembleDebug)
(cd ../jetpacs-poc/jetpacs-platform-tools && ./gradlew clean test installDist)
```

Use each checked-in Gradle wrapper. Prefer a focused ERT or Gradle test before running the broader suite.

## Coding Style & Naming Conventions

Emacs Lisp uses lexical binding, two-space indentation, public docstrings, and feature prefixes such as `ebp-`, `jetpacs-`, or `glasspane-`. Name ERT files `*-test.el`. Kotlin uses four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, and `*Test.kt` test classes; add KDoc at public or architectural boundaries. Keep generated vocabulary synchronized through its generator—do not hand-edit projections.

## Testing Guidelines

Add regression tests beside the owning layer: ERT under `test/`, Kotlin tests under `src/test/kotlin`, and protocol fixtures under `../ebp/goldens/`. There is no numeric coverage threshold; cover success, malformed input, boundary, and determinism cases. Protocol changes must update the governing spec, contract projection, fixtures, and amendment log together. UI or persistence behavior crossing the Android boundary needs a device check when practical.

## Commit & Pull Request Guidelines

The root repository owns research and hand-rewrite notes only. Child histories
favor concise imperative subjects and Conventional Commit forms such as
`feat(core): ...`, `fix(app): ...`, `docs: ...`, and `chore: ...`. Commit within
the repository that owns the change and keep unrelated artifacts out. PRs
should explain the affected invariant, list exact tests run, link relevant
issues/spec sections, and include screenshots for visible UI changes. State
explicitly when device testing was not performed.

## Security & Generated Artifacts

Never commit SDK paths or secrets from `local.properties`. Exclude `.gradle/`, `.idea/`, build outputs, backup files, and source-tree `.elc` files. Preserve pre-existing worktree changes and generated artifacts you do not own.
