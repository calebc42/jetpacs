# PLAN: Grocy-driven hardening of the Jetpacs core

## Context

Grocy — a real Tier-1 household-stock app (products, FIFO stock, shopping,
recipes with serving-scaling, a meal-plan calendar), built on jetpacs +
vulpea — was written end to end specifically to **stress-test the foundation
by composing a non-trivial, non-org app**. This document records what that
exercise surfaced and tracks the fixes to closure. It complements (does not
duplicate) `ROADMAP.md`, which is infrastructure-focused (onboarding, MELPA,
transport, battery).

The findings were originally ranked in four tiers (expressiveness → widgets
→ ergonomics → tooling); the tier list is retained below as the historical
record. **The status ledger is the current truth.**

## Status ledger (as of 1.23.0)

### Closed

| finding | shipped as | API |
|---|---|---|
| layout footgun (`fillMaxWidth` swallow; the one true *bug*) | `jetpacs-list-item`, `:weight`/`:fill` on row/column, lint heuristic, `badge` node | pre-1.13 batch (`506b0b5`, `31ad60e`) |
| #1 declarative forms | `jetpacs-field` (text/number/decimal/date/enum/bool, `:id`-keyed) + `-form-render` / `-form-parse` / `-form-submit`, inline per-field errors | 1.14.0 (`ed825bf`) |
| #2 parameterized navigation | `jetpacs-shell-navigate`, `jetpacs-route-param`, `jetpacs-shell-route-params`, 2-arg builders | (`290fea4`) |
| #4–#8 composites | `jetpacs-stepper` `-segmented` `-stat` `-kv` `-sectioned-list` | 1.13.0 (`fcab3c5`), polished by the grocy dogfood (`e598f21`) |
| #9 children list-vs-&rest inconsistency | `card`/`box`/`surface` accept both | 1.13.0 (`5b75497`) |
| #10 `jetpacs-text` positional nils | keyword options | 1.13.0 (`5b75497`) |
| #11 typed action args | composites bake typed values server-side; **`jetpacs-action-with-arg` promoted public** | 1.13.0 + 1.23.0 |
| #12 `:confirm` on actions | `:confirm` on `jetpacs-action` — an **Emacs-side dispatch gate** through the bridged `y-or-n-p` (native dialog); companion-opaque, no wire change. Undo-snackbar convention documented (WIDGETS.md Actions) | 1.23.0 |
| #13 additive-fallback convention | `jetpacs-additive` (the badge's self-describing degrade child, generalized to the leaf additive nodes; `tabs` keeps the explicit gate) | 1.23.0 |
| #14 test helpers | `jetpacs-test-visible-text`, `jetpacs-test-view-ok` | 1.16.0 (`bd62417`) |
| #15 app-wide lint | `jetpacs-lint-views` (+ `errors-only` CI gate) | 1.16.0 |
| *(new)* test-fixture seam | `jetpacs-test-reset-state` — grocy's suite had to let-bind four `--` internals (`jetpacs--ui-state`, `--state-handlers`, `--forms`, `jetpacs-shell--route-params`); per API-STABILITY rule 1 that *is* the bug report | 1.23.0 |

Beyond the plan, the same dogfooding period also produced the semantic-text
shorthands + `jetpacs-try` (1.19.0), `jetpacs-async` (1.20.0), devtools
(1.21.0), and `:key` lazy-list reconciliation (1.22.0).

### Open

- **#3 — the declarative-source spike on grocy (the north star).** Grocy is
  still 100% imperative; it has never exercised `jetpacs-defsource` +
  `:spec` views (list/board/calendar). Expressing products/stock/recipes as
  sources and rendering the stock list declaratively is the strongest
  remaining validation of the binding layer against a non-org domain, and
  will surface its gaps the way the imperative build surfaced these.
- **Release-pinning discipline (process, not code).** Grocy at one point
  pinned an interim *side-squash* commit ("1.17.0") that was never on
  `main`'s history: unfetchable for anyone cloning, and its signatures then
  silently diverged (`jetpacs-field` `:name`→`:id`; snackbar → inline form
  errors, with the interim-only `jetpacs-form-notify-function` seam
  vanishing without deprecation; composite keyword drift). **Policy:**
  downstream pins point at commits reachable from `main` (ideally tags);
  interim API snapshots are branches, never orphan squashes; any seam that
  ships in a pinned snapshot gets the normal `make-obsolete` path even if
  "pre-release".
- **Kotlin-side verification residue.** The Compose halves of the layout
  batch (row/column `fill`, the `badge` composable) and the `:key`
  reconciliation want an on-device build pass; the drift-guard test pinning
  `SDUI_NODE_TYPES` against the renderer's `when` cases (ROADMAP near-term
  #2) is the standing guard to extend with each node.

## Validation

Every closed item above is dogfooded by grocy (the app that surfaced it):
54-test suite (model + views + bundle-staleness) run headlessly via
`jetpacs-render-to-json` + `jetpacs-lint-spec` against the pinned submodule,
plus `jetpacs-lint-views` as the app-wide gate. The 1.23.0 batch closes the
loop the same way — grocy adopts `:confirm` on its destructive actions,
`jetpacs-test-reset-state` in its fixture, and `jetpacs-test-view-ok` in its
view suite.

---

## The original findings (historical record, 2026-07-15)

Ranked toward *expressiveness*: what would make composing apps like grocy
easier, more consistent, and more expressive.

### Tier 1 — Expressiveness (biggest wins)

1. **Declarative forms** *[CLOSED 1.14.0]* — the single biggest boilerplate
   in grocy: seven hand-rolled forms each repeating field ids, string→number
   parsing, validation, reset.
2. **Parameterized navigation / routes** *[CLOSED]* — grocy drilled into
   detail screens through module-level state vars plus set-and-switch
   actions; route params make a detail view a pure function of its args.
3. **The declarative data-source + layout layer, applied to a real domain**
   *[OPEN — the north star]* — see Status ledger.

### Tier 2 — Reusable widgets

4. **`jetpacs-stepper`** *[CLOSED 1.13.0]* — grocy hand-rolled the servings
   stepper twice.
5. **`jetpacs-segmented`** *[CLOSED 1.13.0]* — every filter row was a manual
   flow-row of selected chips.
6. **`jetpacs-stat`** *[CLOSED 1.13.0]* — the dashboard metric tile.
7. **`jetpacs-kv`** *[CLOSED 1.13.0]* — the detail-screen property row.
8. **Sectioned list with built-in empty state** *[CLOSED 1.13.0]* —
   `jetpacs-sectioned-list` erased the `append`/`apply` plumbing.

### Tier 3 — Ergonomics / consistency

9. **Children-API inconsistency** *[CLOSED 1.13.0]* — list *or* variadic
   everywhere.
10. **`jetpacs-text` positional options** *[CLOSED 1.13.0]* — keywords.
11. **Typed action args** *[CLOSED 1.13.0/1.23.0]* — composites bake typed
    values; `jetpacs-action-with-arg` public.
12. **`:confirm` on action descriptors** *[CLOSED 1.23.0]* — with the
    undo-snackbar convention documented.
13. **Additive-node fallback convention** *[CLOSED 1.23.0]* —
    `jetpacs-additive`.

### Tier 4 — Tooling for Tier-1 authors

14. **Test helpers** *[CLOSED 1.16.0]* — `jetpacs-test-visible-text`,
    `jetpacs-test-view-ok`.
15. **Whole-app lint audit** *[CLOSED 1.16.0]* — `jetpacs-lint-views`.
