# FOLLOW-UP: what's left in Jetpacs after the grocy hardening + dogfood

## Where this comes from

`docs/PLAN-grocy-hardening.md` was executed on branch
`claude/grocy-hardening-plan-95e71f` (jetpacs API 1.12 → 1.17, 215 tests),
then the **grocy** app was refactored end-to-end onto the new surface to
dogfood it (grocy worktree commit `2698abc`, 54/54 tests, byte-compile
clean, run against this jetpacs via `GROCY_JETPACS_DIR`). This document
records the jetpacs work that exercise still leaves open — grounded in
concrete findings, ranked by cost and who has to build it.

## What is already validated (so it isn't re-litigated)

- **Backward compatibility is proven.** grocy passed 54/54 against
  jetpacs 1.17 *before* being refactored (the card/box/surface `&rest`
  change, keyword `jetpacs-text`, and everything else are additive).
- **The whole new surface works in a real ~2,000-line app**: the five
  composites, declarative forms, and route params all carry grocy's five
  screens, seven dialogs, and drill-in navigation.
- **Three real gaps the dogfood surfaced were already closed** in
  `e598f21`: `jetpacs-stepper :format`, `jetpacs-stat
  :fill-fraction`/`:width`, `jetpacs-segmented :spacing`/`:run-spacing`.
  Do not re-report these.

## A. Companion-side — needs a Kotlin / on-device build

1. **`:confirm` on action descriptors (plan #12).** A declarative
   `:confirm "Delete X?"` on `jetpacs-action` → a native confirm dialog
   before dispatch, ideally paired with the existing
   `jetpacs-snackbar-action` undo convention. grocy's destructive actions
   (delete entry / ingredient / meal, remove shopping item) currently
   dispatch with no confirmation. This is the one plan item that
   genuinely requires the companion.
2. **On-device visual smoke of the new composites/forms/routes.**
   Everything landed is pure-elisp composition of *existing* wire nodes,
   so the risk is low and no `SDUI_NODE_TYPES` changed — but nothing has
   been seen on a device. Confirm: form field errors render inline; the
   date picker write-through (`jetpacs.form.set`) round-trips; a
   param-routed detail survives a reconnect; stat tiles wrap at
   `fill_fraction`. This folds into the still-pending on-device build the
   original plan already flagged for the row/column `fill` + `badge`
   Compose edits.

## B. Pure-elisp gaps the dogfood surfaced (small, additive, deferred)

These were noticed while refactoring grocy and worked around rather than
fixed, to keep the API pass bounded. Each is a clean, contained addition.

1. **`jetpacs-form-render` `:on-submit`.** grocy's consume/inventory form
   used to submit on the keyboard "done" key (the amount field carried an
   `:on-submit` action); the form layer only submits via a button, so
   that affordance was lost. Let a single-field (or the last) field
   dispatch the submit on done — e.g. a `:submit-action` the field-node
   threads into `jetpacs-text-input`'s `:on-submit`.
2. **`jetpacs-field :multi-line`.** grocy's new-recipe *description* was a
   multi-line box (`:multi-line t :min-lines 2`); a form-spec `text` field
   renders single-line only, so it regressed. Add `:multi-line` /
   `:min-lines` on `jetpacs-field`, passed through to `jetpacs-text-input`.
3. **`jetpacs-kv` nil value.** `(jetpacs-kv "Location" nil)` puts a `nil`
   child in the row (a `[null]` on the wire); grocy had to write
   `(or value "—")` at every call site. Either render a nil value as an
   em-dash/empty, or document that the value must be a string/node.
4. **A convenience for the form shape.** Every grocy form repeats
   `(apply #'jetpacs-column (append (list title) (jetpacs-form-render …)
   (list :spacing 12)))` inside a card, plus a submit button. A
   `jetpacs-form-view` (title + rendered fields + submit button, in a card)
   would erase that last bit of plumbing — the natural completion of the
   form layer.

## C. Route params — one documented limitation to resolve

1. **Active-view for *nested* drill-ins.** `jetpacs-shell--active-view`
   returns the first `:overlay` predicate that fires (registry `:order`),
   so a two-level route (product → purchase, both param-set) is
   ambiguous: a fresh push (reconnect) can land on the wrong level. grocy
   sidesteps this by using **switch-to only, no overlays** — which works,
   but means a reconnect mid-drill lands on the tab, not the detail.
   Options: (a) track the most-recently-navigated route and let it win
   for `active-view` (a small route stack/timestamp); or (b) bless the
   switch-to pattern in the docs and leave overlays for single-level
   details. Decide and document either way.
2. **Single-param update.** `jetpacs-shell-navigate` replaces *all* of a
   view's params. Updating one (grocy's servings stepper, which must keep
   the recipe id) meant re-passing the whole alist. A
   `jetpacs-shell-navigate`-with-merge (or a `jetpacs-shell-set-route-param`)
   would be tidier. Minor.

## D. The one plan item not attempted — the north-star

**Declarative data-source spike (plan #3).** This pass did the
*imperative* dogfood (forms, routes, composites); it did **not** touch
`jetpacs-defsource` / `jetpacs-spec`. Grocy is now the ideal subject and
is unblocked (present and freshly refactored): model products/stock/
recipes/shopping/meals as sources and rebuild the stock list as a
declarative `:spec` list/board view, and the meal plan as a calendar
view. This is the real test of the binding layer against a non-org
domain — it will surface what `jetpacs-source`/`jetpacs-spec` are missing
(computed/derived fields like product *status*, filtering, grouping,
actions embedded in templates) and get board/calendar layouts "for free."
Treat it as a dedicated spike, not a refactor.

**Additive-node convention (plan #13).** Generalize the badge's
self-describing fallback child into a documented convention or a
`jetpacs-additive` wrapper (primary + fallback), so future additive nodes
degrade uniformly. Pure-elisp but speculative — badge is the only current
consumer; defer until a second additive node needs it.

**Typed action args (plan #11)** is effectively delivered: the form layer
hands handlers typed values, and `jetpacs-stepper`/`jetpacs-segmented`
bake typed args server-side. No separate work needed.

## E. Integration path

1. **Merge & version.** Land the jetpacs branch on main; the six commits
   are self-contained and each regenerates `contract.json` +
   `jetpacs-core.el`.
2. **Bump grocy's submodule.** grocy's `jetpacs` submodule still points at
   the pre-1.17 core; bump it to the merged commit so grocy runs on these
   APIs for real (the suite currently runs against this worktree via
   `GROCY_JETPACS_DIR`).
3. **Adopt across the core skins.** The composites and form/route layers
   want to be used by the ~25 stock skins (`jetpacs-project`,
   `jetpacs-sql`, `jetpacs-tools`, the tablist/results/hypertext
   substrates, …), which still hand-roll rows, kv pairs, and set-and-switch
   navigation. This is the subject of the separate
   skins-DSL-adoption plan; the grocy branch is a worked reference.
4. **A downstream-app CI gate.** The dogfood's most valuable check —
   "does app X still pass against jetpacs HEAD" — was run by hand
   (`GROCY_JETPACS_DIR=<jetpacs> bash grocy/test/run-tests.sh`). Wiring
   that into CI would catch a backward-incompatible core change the moment
   it lands.

## Priority

- **First:** B1–B4 (small, complete the form layer's ergonomics) and the
  C1 decision (document or fix the nested-drill active-view). All
  pure-elisp, all cheap.
- **Then:** the #3 declarative-source spike — the highest-signal remaining
  expressiveness test, now that grocy is available.
- **Companion track:** #12 `:confirm` + the on-device smoke, whenever the
  next companion build happens.
- **Integration:** merge → submodule bump → skin adoption, per the
  skins-DSL plan.
