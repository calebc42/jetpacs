# Plan: data-driven editor toolbars — close the last Kotlin-only seam

**STATUS (2026-07-10): approved, not started.** Produced and approved in a
planning session; this document is self-contained for a fresh
implementation session. Read the whole thing before the first edit —
the "Context from the planning session" section carries facts that were
verified against the code and both repos.

## Why

The foundation's promise is "any UI in elisp, never Kotlin" — but editor
toolbars break it: `JetpacsToolbars`
(`jetpacs/src/main/java/com/calebc42/jetpacs/JetpacsToolbars.kt`) is a
*name → Kotlin composable* registry, so a pure-elisp app (Glasspane,
orgzly-native) can only select toolbars its host compiled in. The org
toolbar is hardcoded Kotlin in the foundation's `:app`
(`app/src/main/java/com/calebc42/jetpacs/OrgEditToolbar.kt`) — org
opinion the foundation repo isn't supposed to carry (flagged in commit
`b044532`).

The fix follows the established ladder doctrine (SPEC §9 visualization
family; `docs/CONTRIBUTING-NODES.md`): **curated primitive + closed
data-only vocabulary + Kotlin as the welcome alternative**. The radial
pie is the precedent — `RadialMenu.kt` renders data, `jetpacs-magit.el`
(glasspane repo) is pure elisp driving it. The toolbar becomes the same
kind of primitive.

Reading `OrgEditToolbar.kt`, all ~17 buttons reduce to a small closed op
set, and its private helper functions become the interpreter nearly
verbatim. End state: the org toolbar is reimplemented as pure elisp in
the **glasspane repo**, `OrgEditToolbar.kt` is deleted from `:app`, and
any app composes toolbars with zero Kotlin.

## The wire design (SPEC §9 delta)

`editor`'s `toolbar` attribute becomes **string | array**:

- **string** — a host-registered native toolbar (`JetpacsToolbars`,
  unchanged; the documented Kotlin-alternative path; the library ships
  none and after this plan neither does `:app`).
- **array of toolbar items** — the new data-driven form. Each item:

```json
{"icon": "format_bold", "label": "B",
 ...exactly ONE of:
 "snippet": "*${selection}*",        // text op (placeholders below)
 "line": "promote",                  // builtin: promote|demote|move-up|move-down
 "on_tap": { action object },        // ordinary §5 dispatch — the Emacs escape hatch
 "menu": [ {label + one-of fields}… ], // dropdown of sub-items
 ...optional:
 "placement": "cursor|line-start|block", // snippet only; default cursor
 "long_press": { one-of fields }          // secondary op
}
```

**Snippet placeholders (closed, companion-local):**

| token | behavior |
|---|---|
| `${selection}` | replaced by the selection; empty selection → cursor lands there (reproduces `wrapSelection`'s both branches) |
| `${cursor}` | explicit final cursor position |
| `${input:Prompt}` | one companion-local text dialog, substituted in (src-block language) |
| `${date}` | `YYYY-MM-DD Day` (companion clock) |
| `${time}` | `HH:MM` |

Rules: unknown `${…}` tokens insert **literally** (visible, never
fatal). `line-start` placement no-ops when the line already starts with
the literal prefix (dedupe, existing behavior). `block` placement =
own-line insertion with `insertBlock` semantics. Exactly one op field
per item (lint enforces).

**Expressibility check (done button-by-button against OrgEditToolbar):**
heading levels = `menu` of six line-start snippets; promote/demote/
move-up/move-down = `line` ops; checkbox/bullet/numbered = line-start
snippets (`"- [ ] "`, `"- "`, `"1. "`); progress cookies = snippet
`"[/]"` + `long_press` `"[%]"`; src block = `menu` of language snippets
plus one `${input:Language}` item, `block` placement,
`"#+begin_src ${input:Language}\n${cursor}\n#+end_src"`; properties
drawer = block snippet `":PROPERTIES:\n:END:"`; bold/italic/code/strike
= `${selection}` wraps with `*`, `/`, `~`, `+`; link =
`"[[${cursor}][${selection}]]"`; timestamps = `"[${date}]"` +
`long_press` `"<${date}>"`. Anything smarter round-trips to Emacs via
`on_tap` — that is the toolbar's "canvas".

**Forward compat:** additive attr change — an old companion reads
`optString("toolbar")`, sees an array as empty, renders no toolbar.
**Item key is `on_tap`, not `action`** — deliberate: it reuses
`jetpacs-lint--action-keys` and §9's action-embedding convention, and
avoids colliding with the `action` *field inside* action objects (which
lint validates as a string).

## Tasks — jetpacs repo

1. **`docs/SPEC.md`** — update the §9 `editor` bullet (`toolbar` is
   string | array); add an "Editor toolbars" subsection at the end of §9
   with the item table, placeholder table, and rules above; note the
   string form as the native alternative.
2. **NEW `jetpacs/src/main/java/com/calebc42/jetpacs/SduiToolbar.kt`** —
   the interpreter. Move the pure helpers from `OrgEditToolbar.kt`
   nearly verbatim: `insertAtCursor`, `insertAtLineStart` (keep its
   dedupe), `insertBlock` (keep `cursorLineOffset` semantics via
   `${cursor}`), `promoteHeading`, `demoteHeading`, `moveLineUp`,
   `moveLineDown`, and the timestamp date formatting; generalize
   `wrapSelection`/`insertLink` into one snippet-substitution engine.
   Render a `horizontalScroll` `Row` of `ToolbarChip`s (`ToolbarChip.kt`
   already lives in `:jetpacs`); `combinedClickable` + haptic for
   `long_press` (copy the pattern from OrgEditToolbar's cookie/timestamp
   buttons); `DropdownMenu` for `menu`; one `AlertDialog` for
   `${input:}` (free-text only — preset lists are the app's `menu`
   items). `on_tap` items go through the editor's `dispatch`.
3. **`SduiInputNodes.kt`** — line ~227 currently
   `val toolbar = node.optString("toolbar")`; also read
   `node.optJSONArray("toolbar")`. At the render site (~line 619:
   `if (toolbar.isNotEmpty() && !readOnly) JetpacsToolbars.Render(…)`)
   branch: array → `SduiToolbar(items, readValue, applyValue, dispatch)`;
   non-empty string → `JetpacsToolbars.Render` unchanged. The
   `readValue`/`applyValue` TextFieldValue bridge (lines ~247–253) is
   reused as-is — one splice per op, one undo step (its comment explains).
4. **`:app`** — delete `OrgEditToolbar.kt`; remove the registration in
   `MainActivity.kt` (lines ~61–65,
   `JetpacsToolbars.register("org") { … }`) and update the comment:
   toolbars are server-driven data; the registry remains as the
   native-alternative seam, shipping empty.
5. **`emacs/core/jetpacs-widgets.el`** — `jetpacs-toolbar-item`
   constructor: `(cl-defun jetpacs-toolbar-item (icon label &key snippet
   placement line on-tap long-press menu))` emitting via `jetpacs--node
   nil` (`menu` and item vectors via `vconcat`). `jetpacs-editor`'s
   `:toolbar` accepts a string (unchanged) or a list (emit
   `(vconcat toolbar)`).
6. **`emacs/core/jetpacs-lint.el`** — toolbar-item validation: exactly
   one of `snippet`/`line`/`on_tap`/`menu`; `placement` ∈ {cursor,
   line-start, block}; `line` ∈ {promote, demote, move-up, move-down};
   recurse into `menu` and `long_press`; `on_tap` is already covered by
   `jetpacs-lint--action-keys`.
7. **Tests (`test/jetpacs-tests.el`)** — constructor shape test; lint
   tests (a valid toolbar passes; an item with two op fields and a bad
   `placement` are flagged); regen `test/widgets.golden` — an
   **intentional** additive change adding the `jetpacs-toolbar-item`
   line (`emacs -Q --batch -l test/jetpacs-tests.el -f
   jetpacs-tests-regen-widget-golden`).
8. **Docs** — `BUILDING-TIER1.md` §5 (per-file-type editor behaviour):
   a "your own keyboard toolbar" example in elisp;
   `API-STABILITY.md`: add `jetpacs-toolbar-item` to the public surface;
   `ARCHITECTURE.md`: the `JetpacsToolbars` seam row + the two host-
   agnostic-seams paragraph → data-driven toolbars are the default,
   the registry is the native alternative.
9. Regen `jetpacs-core.el` (`emacs --batch -l emacs/build-bundle.el`);
   full battery (see Verification); commit.

## Tasks — glasspane repo (WSL `~/pkb/projects/Glasspane`)

10. **NEW `emacs/apps/glasspane/glasspane-org-toolbar.el`** — a
    `glasspane-org-toolbar` function returning the item list reproducing
    every OrgEditToolbar button (the expressibility list above is the
    spec). Add the file to `emacs/build-bundle.el`'s `app-files` (before
    `glasspane-ui.el`) and a `(require 'glasspane-org-toolbar)` where
    the bundle's dependency order needs it.
11. **`glasspane-ui.el`** — two sites: `:toolbar "org"` (~line 1297, the
    detail-view editor) and `jetpacs-files-editor-toolbar-function`
    (~line 2696, returns `"org"` for .org files) → both return
    `(glasspane-org-toolbar)`. The core seam
    (`emacs/core/jetpacs-files.el:83–86, :394`) passes the value through
    untouched — strings and lists both ride the same `:toolbar` key.
12. **Tests** — lint the toolbar (`jetpacs-lint-spec` over an editor
    node carrying it, via `jetpacs-render-to-json`); regen
    `glasspane.el`; suite green. **Bump the `jetpacs` submodule pin** to
    the toolbar commit — a deliberate, reviewed bump per the repo's
    standing rule (pin → regen → suite → commit).

## Out of scope (flagged, not forgotten)

- The **org capture tile** (`CaptureTileService` in `:app`) — the other
  org affordance in the shell; separate decision (QS tiles already have
  elisp-composed slots: `jetpacs-tile` / `tile:customN`).
- orgzly-native's toolbar — it gets the capability for free; its items
  are its repo's business.
- The launcher icon is still Glasspane art (needs artwork, unrelated).

## Context from the planning session (verified facts)

- **Repos:** jetpacs = `C:\Users\caleb\AndroidStudioProjects\jetpacs`
  (Windows; Gradle + elisp). Glasspane = WSL Debian
  `~/pkb/projects/Glasspane` (pure elisp; vendors jetpacs as the
  `jetpacs` git submodule, relative url `../jetpacs`). Both live on
  GitHub under calebc42. **Pushes happen only from the user's
  Emacs-in-WSL** (SSH agent + passphrase live there; Windows-side
  shells cannot auth — commit locally, let the user push).
- **Glasspane repo commits from Windows:** run git through
  `wsl -d Debian -- sh -c 'cd ~/pkb/projects/Glasspane && …'` (plain
  `wsl git -C /home/...` gets mangled by MSYS path conversion).
- **Emacs on Windows** is not on PATH:
  `"/c/Program Files/Emacs/emacs-30.1/bin/emacs.exe"`. Test battery:
  `emacs -Q --batch -l test/core-load-test.el`, `… -l
  test/jetpacs-tests.el -f ert-run-tests-batch-and-exit` (63 tests
  pre-plan), `… -l test/jetpacs-primitives-test.el …` (54).
  Glasspane: `… -l test/glasspane-tests.el …` (72) run from the repo
  root with the submodule checked out.
- **Golden regen is intentional-only** and this plan is one of the
  intentional cases (+1 constructor line). `frames.golden` is
  unaffected.
- **Goldens contain no app strings** — verified zero `glasspane`/legacy
  hits; don't expect collateral churn.
- **The `readValue`/`applyValue` bridge** in the editor
  (`SduiInputNodes.kt:247–253`) materializes a `TextFieldValue` per tap
  (never per keystroke) and applies each op as one minimal splice = one
  undo step. `SduiToolbar` must keep that contract (read the comment
  there before wiring).
- **CRLF warnings** from git on this Windows checkout are constant
  noise; ignore them.
- **House commit style:** `feat:`/`fix:`/`refactor:` + body, trailer
  `Co-Authored-By: Claude <relevant model> <noreply@anthropic.com>`.
  One commit per repo for this plan is fine; the jetpacs commit is the
  wire change (SPEC + Kotlin + elisp + goldens together), the glasspane
  commit is the migration + submodule bump.
- **Recent history for orientation:** `b044532` made onboarding
  foundation-only and flagged the toolbar gap this plan closes;
  `c17e486` made deploy scripts multi-bundle; the distribution model
  (jetpacs ships no app; apps self-distribute elisp bundles) is a firm
  user decision — nothing in this plan may reintroduce app opinion into
  the foundation beyond the empty registry seam.

## Verification

- **jetpacs:** core-load guard OK; main suite green including the new
  tests; primitives 54/54; goldens regenerated and committed;
  `./gradlew :jetpacs:assembleDebug :app:assembleDebug` green — which
  also proves `:app` builds *without* `OrgEditToolbar.kt`.
- **glasspane:** suite green against the bumped submodule;
  `glasspane.el` regenerated (contains `glasspane-org-toolbar`);
  `jetpacs` submodule pin = the jetpacs toolbar commit.
- **On-device (user):** open an org file in the phone editor → the
  elisp-driven toolbar renders; spot-check: a `${selection}` wrap, a
  line op, the long-press timestamp, the src dialog with a custom
  language. Add these to the glasspane repo's TESTING-ON-DEVICE list.
