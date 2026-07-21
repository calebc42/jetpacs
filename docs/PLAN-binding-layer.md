# Plan: the core binding layer + engine-pack model (three-repo interoperability)

**STATUS (2026-07-13): ALL STAGES (0–4) LANDED — the binding-layer program is complete.**
Stages 0–2 are merged into jetpacs `main` (api **1.5.0**, merge `40d4972`) and pushed.
Stage 3 landed on Glasspane `main` in **re-scoped form**: the engine sources
(`glasspane.org`, vulpea-backed `glasspane.notes`), the annotated action catalog,
`glasspane-pack.el` + dependency-aware `glasspane-pack.json`, and the internal-poke drops
all shipped — but the planned `:spec` migrations of Glasspane's rich card surfaces were
**rejected** by `DECISION-no-binding-template-dsl.md` (rich rendering stays
in elisp `:builder`s; `:spec` stays the minimal composer-facing grammar; no template DSL,
no api 1.6.0). **Stage 4 (composer pack targeting) executed 2026-07-13** on the composer
branch `claude/stage-4-pack-targeting` (S4.0–S4.6; see the companion's EXECUTED status
header for commits and gates): unknown-source preservation on both parsers, the
PackManifest store + manifest-driven pickers, **FORMAT 4** (see the renumbering note
below), the fail-closed runtime binding + closed `crud.pack.action` dispatch, the
manifest-driven Deployer, and the batch-side acceptance recreating the Glasspane
saved-views/journal/backlinks against `glasspane-pack.json` (on-device rows pending in
Glasspane `TESTING-ON-DEVICE.md` §20). Core added **no pack registry**, as locked. This
doc remains the cross-repo master; stage details below are kept as the record of what
shipped.

**Locked design choices (audit):**
- `:spec` describes a **complete tab or navigation view** (chrome + body) via a **raw
  closed-data template AST** — not a body fragment.
- `contract.json` holds **authoritative static vocabularies only** — never inferred per-node
  schemas, never live registrations.
- Core provides **source and action registries but no pack registry**.
- Stage 3 emits a **standalone `glasspane-pack.el`**; Composer owns pack installation,
  dependency, and version handling in Stage 4.
- Glasspane migrates **only the surfaces the v1 grammar can reproduce faithfully**.

**Companion deliverables:**
- **Stage 3** → `Glasspane/docs/PLAN-binding-adoption.md` — exists, executed (see its status
  header), re-scoped by `DECISION-no-binding-template-dsl.md`.
- **Stage 4** → `jetpacs-composer/docs/PLAN-pack-targeting.md` — **executed 2026-07-13**
  (see its EXECUTED status header for the commit list and batch gates; cross-linked from
  `jetpacs-composer/docs/PLAN-nocobase-horizons.md`). One renumbering against this doc's
  Stage 4 text: the shipped writer already emitted FORMAT 3 unconditionally, so
  **pack-backed documents are FORMAT 4** (accept ≤4, emit 3 unless pack-backed, reject
  >4) — same gating intent, current numbering; `jetpacs-composer/docs/FORMAT.md` is the
  v4 contract. The follow-on targets are surveyed in
  `jetpacs-composer/docs/AUDIT-engine-packs.md`.
- **Reconcile** `docs/PLAN-org-extraction.md` — done 2026-07-13 (its status header now names
  the surviving core `jetpacs-org-*` entry points).

## Context

Jetpacs today has a clean authoring contract for *static* UI — widget node trees, action objects,
and app/toolbar/trigger specs are all pure data. But the two load-bearing seams — a **view**
(`:builder` function, `jetpacs-shell.el:50`) and an **action** (`jetpacs-defaction` handler,
`jetpacs-surfaces.el:189`) — require elisp. Every data-bound surface in the reference app
(Glasspane) is hand-written as `query(params) → mapcar #'card-template → lazy-column | board |
calendar`, duplicated 7+ times, and the no-code editor (composer) hand-mirrors jetpacs's wire
semantics with no machine-readable contract to check against. There is no declarative/reactive
binding in core; state is imperative (handler-mutates-then-repush on the 0.5s idle-repush debounce,
`jetpacs-shell--schedule-repush`).

**The goal (locked decisions).**
1. **Engine-pack model.** Glasspane's engines become an installable elisp pack exposing **named
   data sources + named actions with machine-readable metadata**; composer binds its views/cards
   to pack-provided sources/actions. "Recreate Glasspane" = compose its UI over the glasspane
   engine pack. Composer's no-arbitrary-layout / no-code discipline stays.
2. **Binding layer lives in jetpacs core.** Shell views accept a declarative data-view **`:spec`**
   (source + params + layout + template + chrome + group-by + empty-state) *alongside* `:builder`;
   both Glasspane and composer's runtime (`jetpacs-crud.el`) refactor onto it.
3. **Full staged master plan** across all three repos, stage-gated, each stage independently
   landable.

**The inviolable constraint (SPEC §5, `docs/SPEC.md:164-171`, verbatim):**
> *The wire must never carry code, command names to funcall, file paths outside the client's own
> guards, or anything else that turns the companion into a remote eval.*

So the binding/template language is **closed-vocabulary DATA** — field accessors + named transforms
only, **no expressions/lambdas** on the wire or in `app.org`; actions referenced by **name** only.
The *only* funcall a `:spec` triggers is the source's locally-registered `:query` thunk (the name is
data; the function is registered server-side, never serialized). Lint proves closed serializable
data and registered names; handlers still validate refs/paths/args at dispatch.

**Where the grammar is documented.** The binding grammar is a *local authoring* concern — it
compiles to ordinary wire nodes/actions. It does **not** go into the wire SPEC. It gets a new
authoring reference (`docs/BINDING.md`) plus deltas to `ARCHITECTURE.md`, `BUILDING-TIER1.md`,
`API-STABILITY.md`, and `ROADMAP.md`. SPEC receives only **existing wire corrections** (the
missing action-hook keys `on_point_tap`/`on_button`, §9) and a one-line note that compiled `:spec`
output still obeys §5/§9.

## Grounding & sequencing (verified 2026-07-12 against `main` @ `f4cb47a`)

- **Phase G is essentially done.** Tasks 17–20 are on `main`: Task 17 `jetpacs-config.el` +
  `jetpacs-apply-foundation-defaults`; Task 18 structural invariants (`jetpacs--install-invariants`,
  `apps.el:202`); Task 19 the seam entry file `docs/jetpacs-init.el` (staged as an APK asset, not a
  bundled core module — hence absent from `emacs/core/`) + rewritten `docs/starter-init.el`; Task 20
  onboarding staging (`e8a4fad feat: onboarding stages the jetpacs-init seam`). **Only Glasspane
  Task 21 (config rebase, in the Glasspane repo) remains.** There is **no** jetpacs-side Phase-G
  blocker for Stage 2, and no reserved 1.5.0 for Phase G.
  (Note: `docs/PLAN-platform-hardening.md`'s "Phase G status: in progress / Tasks 19–21 pending"
  header is stale — flag for a follow-up status edit; out of scope for this doc.)

## Version discipline

- `jetpacs-api-version` is **`"1.3.0"`** (`emacs/core/jetpacs.el:41`). **1.3.0 exposes two
  independently landed API batches under one version:** commit `7494345` (owner-scoped reminders,
  `jetpacs-reminders-owner-set`) and `a9dae1c` (Phase-G foundation root + structural invariants).
  A Tier-1 checking `(version<= "1.3.0" …)` cannot tell them apart — a baked-in ambiguity.
- **Policy: one minor bump per *independently landed API batch*** (not per individual addition).
- **Stage 1 → `1.4.0`. Stage 2 → `1.5.0`.** If any other public-API release lands between them,
  Stage 2 deterministically takes the **next unused minor**. Add one line to
  `docs/API-STABILITY.md` recording the 1.3.0 double-exposure and this policy.

## Repo conventions (read first)

- **jetpacs:** edit `emacs/core/*.el`; the root `jetpacs-core.el` is a **generated bundle** — never
  hand-edit; regen `emacs --batch -l emacs/build-bundle.el`. Regen `test/widgets.golden` **only**
  on an intentional wire change. Kotlin touch → build the Android modules before commit. One commit
  per task. The command-dispatch boundary (SPEC §5): the wire never names code to run.
- **Glasspane:** app bundle `glasspane.el` via its own `emacs/build-bundle.el` (opens with
  `(require 'jetpacs-core)` — core must be on load-path). Its ERT suite is run in a POSIX
  environment (e.g. `bash test/run-tests.sh`, invoked under WSL Debian on the dev machine — an
  **environment-specific example**, not a verified local capability). Gate = **all tests pass;
  pre-change baseline is 78, plus the new source/spec/manifest/teardown/mutation tests.**
- **composer:** `BundleExporter` concatenates `jetpacs-crud.el` + `jetpacs-crud-orgapp.el` +
  `(jetpacs-crud-install "<id>" "<org string>")`; the composer/runtime pair is kept honest **only**
  by the shared corpus (`elisp/test/fixtures/parser-parity.manifest` run against BOTH the elisp
  parser and Kotlin `OrgCodec`, + `hello-world.org` kitchen sink + goldens). Any format/contract
  change extends the corpus on both sides or the parsers diverge and ship apps that never appear
  on-device.

---

## Stage 0 — Documentation preflight

**Goal:** land the plan docs cleanly, with no code changes, before any implementation.

- The working tree currently has **two independent doc changes**: this new `docs/PLAN-binding-layer.md`
  (untracked) and a modified `docs/PLAN-platform-hardening.md` (the +166-line Phase H append).
- **Do:** commit them as **separate doc-only commits** on a topic branch — one for the Phase H
  append (`docs: append Phase H (30.1-baseline hardening) …`), one for this master plan
  (`docs: add binding-layer master plan`). Run `git diff --check` on each (no whitespace errors).
- **Acceptance:** `git status` clean; **no code diff** in either commit.

---

## Stage 1 — Static contract + public seam promotion (jetpacs) — *no dependency; land now*

Additive → **bump `jetpacs-api-version` "1.3.0" → "1.4.0"**; regen bundle; add "since 1.4.0"
entries to `docs/API-STABILITY.md`.

### T1.1 — Lift inline vocabularies to defconsts + close the action-hook set
- **Files:** `emacs/core/jetpacs-lint.el`.
- **Do:**
  - Lift the inline enums to defconsts: `jetpacs-lint--when-offline-values '("queue" "drop" "wake")`
    (referenced at `:112`); `jetpacs-lint-action-fields '(action builtin args when_offline dedupe)`;
    `jetpacs-lint-action-builtins '("view.switch" "clipboard.copy" "jetpacs.settings.open")`.
  - **Add the missing action-hook keys** to `jetpacs-lint--action-keys`: `on_point_tap` (chart,
    `widgets.el:417`) and `on_button` (widget-item, `widgets.el:689`) — both are real embedded
    action objects rendered on-device (`SduiChart.kt`, `JetpacsWidgetListService.kt`) but absent
    from the current list.
  - Extend `jetpacs-lint--check-action` into a **discriminated builtin check**: an **unknown
    builtin** and a **malformed builtin payload** (e.g. `view.switch` without `view`,
    `clipboard.copy` without `text`) become authoring-lint errors, per the schema in T1.2.
- **Pitfall:** the defconsts must contain *exactly* the current inline set (plus the two genuinely
  missing keys); no other behavior change.
- **Acceptance:** existing lint tests green; a `view.switch` builtin missing `view`, and an unknown
  builtin, each lint-fail; `on_point_tap`/`on_button` are recognized action keys.

### T1.2 — Contract generator (`contract_format: 1`, static vocabularies only)
- **Files:** new `emacs/build-contract.el` (sibling of `build-bundle.el`, **not** bundled); output
  committed at `docs/contract.json`.
- **Contents — authoritative *static* vocabularies only:**
  ```
  { contract_format: 1,
    api_version, protocol_version,
    node_types,                      ; the 38 from jetpacs-lint-node-types
    action_hook_keys,                ; jetpacs-lint--action-keys (incl. on_point_tap, on_button)
    offline_policies,                ; jetpacs-lint--when-offline-values (+ default "queue")
    toolbar: { ops, placements, line_ops },
    action_schema: {                 ; a DISCRIMINATED union
      remote:                 { action, args?, when_offline?, dedupe? },
      "view.switch":          { builtin, view* },
      "clipboard.copy":       { builtin, text* },
      "jetpacs.settings.open":{ builtin } } }
  ```
- **Omit `per_node_attrs` entirely.** The golden examples are incomplete and cannot support strict
  per-node schema validation; live node compatibility remains governed by the connection's
  `node_types` (SPEC §3), not the contract.
- **Canonical generation:** a pure in-memory builder + a writer with **stable nested key ordering,
  JSON arrays emitted as vectors, UTF-8/LF, exactly one terminal newline**, so the artifact is
  byte-stable across runs.
- **Acceptance:** regeneration is byte-identical; the discriminated `action_schema` matches the
  lint defconsts; all 38 node types present; no `per_node_attrs` key.

### T1.3 — Drift gates (ERT + Kotlin) — three legs
- **Files:** `test/jetpacs-tests.el`; the Android test module.
- **Do:**
  1. **Cross-language leg (keep):** assert three sets equal — `jetpacs-lint-node-types` ≡ distinct
     `t` in `test/widgets.golden` ≡ `SDUI_NODE_TYPES` parsed from `SduiRenderer.kt:101-115` (read as
     text; region between `setOf(` and `)`; collect `"([a-z_]+)"`; strip `//` lines). Plus a
     contract-artifact-current test: regenerate in-memory, byte-compare to committed
     `docs/contract.json`.
  2. **Add the missing Kotlin dispatcher-vs-`SDUI_NODE_TYPES` test:** assert the renderer's `when
     (type)` dispatch cases equal the published `SDUI_NODE_TYPES` set (they can silently drift today).
  3. **Add the missing public-API binding sweep:** every symbol named in `docs/API-STABILITY.md` is
     `fboundp`/`boundp` (extends the existing stability check to a full sweep).
- **Acceptance:** editing any one of the three node-type sources without the others fails CI;
  a renderer `when` case with no `SDUI_NODE_TYPES` entry fails; an API-STABILITY symbol that isn't
  bound fails.

### T1.4 — Promote the 4 internal seams Glasspane pokes + `jetpacs-ui-state-list`
All additive. (ui-state accessors are `jetpacs-ui-state` / `jetpacs-ui-state-put` /
`jetpacs-ui-state-clear` — there is no `-get`/`-set`.)

| Internal (poke site) | Public API | Behavior | File |
|---|---|---|---|
| `jetpacs-shell--current-tab` (`shell.el:113`; glasspane journal.el:217) | keep reader `jetpacs-shell-current-tab` (`shell.el:119`) **+** add a setter | setter **rejects unknown/non-tab names** and routes a successful change through `jetpacs-shell-push` (never setq the internal) | `jetpacs-shell.el` |
| `jetpacs-files--file` (`files.el:78`; glasspane ui.el:523) | `jetpacs-files-current-file` (getter) + `jetpacs-files-open` | `jetpacs-files-open` **preserves the readable / root-containment guards**, runs a new `jetpacs-files-open-hook`, and returns the expanded path or nil; **refactor the existing `files.open` remote action to delegate to it** | `jetpacs-files.el` |
| `jetpacs--month-abbrevs` (`widgets.el:634`; glasspane agenda.el:206) | `jetpacs-month-abbrev` | **bounds-checked** 1..12 → "Jan".."Dec"; keep the defconst internal | `jetpacs-widgets.el` |
| `jetpacs--in-action-handler` (dynamic, `minibuffer.el:28`; glasspane ui.el:601) | `jetpacs-in-action-p` | **move the defvar's ownership to `jetpacs-surfaces.el`** and expose the predicate (raw flag; async continuations see nil — document) | `jetpacs-surfaces.el` |
| multi-select coercion (dup at `widgets.el:547`, `minibuffer.el:669`, glasspane `ui.el:117`) | `jetpacs-ui-state-list` | **precise:** plain string → one item; vector/list → **retain only string members**; a valid JSON-array string → decoded; **malformed JSON and non-string members are discarded** | `jetpacs-surfaces.el` |

- **Pitfalls:** `jetpacs-in-action-p` returns the *raw* flag (correct for the synchronous
  double-push guard); the time-window variant (`jetpacs-witheditor--phone-initiated-p`) stays
  internal. Regenerate `jetpacs-core.el`; do not hand-edit.
- **Acceptance:** the tab setter rejects a non-tab name; `jetpacs-files-open` refuses an
  out-of-root path and runs its hook; `jetpacs-ui-state-list` discards a non-string vector member;
  `test/core-load-test.el` byte-compiles; the T1.3 API sweep binds every new symbol.

### T1.5 — Composer vendors the artifact (`jetpacs-composer`)
> Cross-repo task; tracked here for the interface, executed in the composer repo.
- **Do:** during its build, **copy `docs/contract.json` from the pinned jetpacs submodule and
  verify byte equality** (a drift test). Use the artifact to validate composer's **emitted wire
  nodes/actions** (and, in Stage 4, node-fallback awareness) against the authoritative wire
  vocabulary. **Do NOT** use the contract to replace composer-owned `ViewKind` / `ColType` /
  `ActionDef` — those are *FORMAT* vocabularies, not wire vocabularies, and stay hand-owned with
  their `Unknown` forward-degrade sentinels.
- **Acceptance:** a byte mismatch between the vendored copy and the pinned submodule's
  `contract.json` fails the composer build; existing `OrgCodecTest` + parser-parity green.

---

## Stage 2 — Source registry + complete declarative views (jetpacs) — *after Stage 1*

Additive → **bump api to `1.5.0`** (or the next unused minor). Two new modules in `build-bundle.el`
`core-files`: `jetpacs-source.el` **after the ownership machinery**; `jetpacs-spec.el` **after
`jetpacs-shell`**. `jetpacs-shell.el` reaches the compiler via an **autoload / lazy `require`**
(not `declare-function` alone) to avoid a load-order cycle; **both features are added to the
core-load guard** (`core-load-test.el`). **No new node types → no protocol bump; widget goldens
unchanged.**

### T2.1 — `jetpacs-defsource`: named, owned, engine-agnostic source registry
- **Files:** new `emacs/core/jetpacs-source.el`.
- **Metadata:** string identifiers; params + fields typed from the **domain-neutral** set
  `text | number | boolean | date | string-list | enum | ref` (an `enum` field/param **requires a
  values vector**). **Params are validated and canonicalized before the query runs.**
- **Ownership:** sources use the **existing owner claims** (`jetpacs--claim`), same-owner
  replacement, the cross-owner collision policy, and owner teardown (`jetpacs-app-unregister`) —
  identical to actions/views.
- **Caching:** **uncached by default.** Supplying a **local `cache-key` callback** enables **one
  cached result per (source, canonical-params) tuple + freshness token**; **errors are never
  cached**. Add `jetpacs-source-invalidate`; re-registration, refresh, and unregister clear the
  affected cache entries. **Remove any implicit day-long / global caching** — the memo key is the
  app-supplied freshness token only.
- **The `:query` thunk is the sole funcall** — app-supplied, server-side, never serialized (§5-safe:
  the name is data, the fn is local). It returns items already normalized to the declared field
  types (see T2.3).
- **Acceptance:** ERT — an uncached source re-queries every call; with a `cache-key` it memoises per
  params + token and never caches an error; `jetpacs-source-invalidate` + teardown clear entries;
  `jetpacs-source-catalog` (metadata only) round-trips through `jetpacs-render-to-json`.

### T2.2 — Complete declarative views: `:spec` on `jetpacs-shell-define-view`
- **Files:** `emacs/core/jetpacs-shell.el`; new `emacs/core/jetpacs-spec.el`.
- **Require exactly one of `:builder` and `:spec`.** Branch inside `jetpacs-shell--build-view`
  (`:354`), still within the existing `condition-case` so a broken spec degrades to the shell's
  error view in place.
- **A `:spec` describes a COMPLETE view** — chrome + body:
  ```elisp
  (:source "…" :params (…) :layout list|board|calendar
   :template <RAW-NODE-AST> :header <RAW-NODE-AST>?
   :group-by (:field F :order …)? :empty-state (…)?
   :chrome (:kind "tab"  :title T :icon I :label L  :fab <static>? :actions <static>?)   ; OR
           (:kind "nav"  :title T :back <target>    :fab <static>? :actions <static>?))
  ```
  - `"tab"` chrome supplies title/icon/label + optional **static** FAB/actions.
  - `"nav"` chrome supplies title + back target + optional **static** FAB/actions.
  - **Dynamic `:when` and `:overlay` predicates remain registration-level elisp seams** (they are
    code, not data) — passed to `jetpacs-shell-define-view` as today.
- **Template AST = raw wire-shaped node data** (alists with string identifiers/enum values,
  **sequences as vectors**). Ordinary widget constructors are **not** promised to preserve
  placeholders, so templates are authored as raw nodes (or via a raw-node helper), never via
  `jetpacs-card`/etc.
- **Placeholders have the exact form** `((bind . "field") (as . "transform"))`.
- **Registration side effects preserved:** `:spec` reuses `jetpacs-shell-define-view` verbatim, so
  `jetpacs--claim` + `:order` sort + `jetpacs-shell--schedule-repush` all fire (app-isolation and
  teardown keep working). The per-push snackbar still threads to the built view.
- **Acceptance:** a `:spec` tab/nav view renders complete chrome + body byte-equal to the equivalent
  hand-rolled view for a fixed item set; a `:spec`-and-`:builder` (or neither) registration errors;
  empty items → the `:empty-state` node.

### T2.3 — Template compilation: closed transforms, domain-neutral; source-side normalization
- **Files:** `emacs/core/jetpacs-spec.el`, `emacs/core/jetpacs-lint.el`.
- **Closed, domain-neutral transform set** (the `as` value): `raw` (identity) · `string`
  (string conversion) · `date` (ISO-date validation) · `date-label` ("Mon D") · `string-list`
  (normalization) · `count` · `bool` (JSON boolean) · `ref` (ref-object validation). **No org
  semantics in core:** **sources normalize Org timestamps / TODO / tags into the canonical field
  types before core sees them** — the `date`/`date-label` transforms operate on already-canonical
  ISO dates, `string-list` on already-canonical lists.
- **Action args:** a **single closed spread form** merges a bound `ref` object with literal args;
  **key collisions are rejected**. An **optional** missing value removes its containing
  attribute/child; a **required** missing field fails with a precise path.
- **Two-phase validation:** **structural lint before querying** (`jetpacs-lint-view-spec`: unknown
  spec/chrome key; `:layout` ∈ layouts; every `((bind . F))` names a field the bound source
  declares; every `(as . X)` ∈ transforms; embedded actions reuse the discriminated action check;
  `:group-by :field` is a declared field). Then at render time: **resolve source/field/action names,
  compile every placeholder away, and run the existing wire-node lint** on the result. Any failure
  stays inside the shell's error-view degradation. Lint proves closed serializable data + registered
  names; **handlers still validate refs/paths/args** at dispatch.
- **Acceptance:** ERT — a bad field / bad `as` / unknown action / colliding spread key / missing
  required field each fails `jetpacs-lint-view-spec` with a precise path; a valid template compiles
  to a node tree identical to the hand-rolled one.

### T2.4 — Deterministic layouts
| Layout | Compilation |
|---|---|
| `list` | optional `:header`, then **one instantiated template per item** in a lazy column |
| `board` | horizontal grouped columns; **explicit / source-enum order first, unseen groups appended deterministically, the empty group last** |
| `calendar` | **ISO-date groups sorted ascending**, flattened as date headers + item templates in a lazy column |

- Layout arity is intrinsic: `list`/`board` yield one root; `calendar` yields a flattened node
  stream spliced into the lazy column. Group order is **explicit vector or source enum, never
  hash-iteration order**; the empty/"none" group is always last.
- **Acceptance:** golden tests pin each layout's node tree for a fixed item set, including the
  empty-group-last and ascending-date invariants.

### T2.5 — Action metadata catalog (`cl-defun` upgrade)
- **Files:** `emacs/core/jetpacs-surfaces.el`.
- **Do:** change `jetpacs-defaction` compatibly to `(cl-defun jetpacs-defaction (name fn &key args
  doc) …)`; **clear stale metadata on legacy re-registration and on teardown**. `jetpacs-action-catalog`
  **accepts an owner filter** and contains **metadata only, never handler functions**.
- **Pitfall:** existing positional `(jetpacs-defaction name (lambda …))` calls keep working; do not
  gate dispatch on the catalog.
- **Acceptance:** ERT — an action with `:args` appears (owner-filtered) in the catalog and
  round-trips through JSON; a legacy 2-arg registration still dispatches; re-registration replaces
  metadata.

### T2.6 — Form lifecycle registry
- **Files:** `emacs/core/jetpacs-surfaces.el`.
- **Do:** an **owner + namespace-keyed** registry with **monotonic generations** and exact public
  functions: lookup, field-id, value, **seed-if-absent**, reset, **dispose**. **Reset/dispose clear
  UI state and subscriptions; `jetpacs-app-unregister` removes owned forms.** This replaces the
  hand-rolled "rotate a `%d`-suffixed widget id + `jetpacs-ui-state-clear`" idiom — the id rotation
  is why the on-device field actually empties.
- **Acceptance:** ERT — seed-if-absent doesn't clobber a live value; reset clears state + subs and
  bumps the generation (field id changes); app teardown disposes owned forms.

### T2.7 — Fallback primitive + api bump + docs + bundle + contract extension
- **Files:** `emacs/core/jetpacs.el` (`jetpacs-node-or`), `docs/BINDING.md` (new authoring
  reference), `docs/ARCHITECTURE.md`, `docs/BUILDING-TIER1.md`, `docs/API-STABILITY.md`,
  `docs/ROADMAP.md`, `docs/SPEC.md` (wire corrections only), `emacs/build-contract.el`,
  `emacs/build-bundle.el`.
- **`jetpacs-node-or`** stays the local fallback primitive over `jetpacs-node-supported-p`:
  **disconnected → fallback; connected legacy companion with no catalog → primary; catalog present
  but node omitted → fallback.** Keep it a macro (local eval, one branch runs); **remove the
  underspecified data-layout registry extension** floated earlier.
- **Docs:** `BINDING.md` is the binding grammar's authoring reference (sources, `:spec`, chrome,
  template AST, placeholders, transforms, layouts, fallbacks); cross-link from ARCHITECTURE /
  BUILDING-TIER1; add the new public symbols to API-STABILITY; note the capability on ROADMAP.
  **SPEC gets only** the `on_point_tap`/`on_button` §9 action-key correction and a line that
  compiled `:spec` output still obeys §5/§9 — **the grammar itself is not in SPEC**.
- **Contract extension:** `contract.json` gains **static binding keys, layouts, transforms, chrome
  kinds, ordering modes, and metadata type vocabularies** — still static only. **API → 1.5.0;
  protocol version and widget goldens unchanged.** Regenerate `jetpacs-core.el`.
- **Sequencing within Stage 2:** T2.1 → T2.5, T2.6 → T2.2 → T2.3 → T2.4 → T2.7.
- **Acceptance:** bundle byte-compiles (core-load guard covers both new features); the API sweep
  binds every new symbol; the extended contract regenerates byte-stable.

---

## Stage 3 — Glasspane binding-layer adoption (companion doc: `Glasspane/docs/PLAN-binding-adoption.md`)

Full task detail belongs in the Glasspane companion doc (a **required deliverable**, not yet
present). Summary + the load-bearing interface:

- **Sequence:** `Glasspane/docs/PLAN-glasspane-org-adoption.md` runs **first** and Glasspane **Task
  21** (config rebase) can run alongside it; Stage 3 follows Stage 2. Org-adoption swaps the query
  *implementation* onto core `jetpacs-org` while keeping an app-facing query entry point that Stage
  3's `defsource` `:query` thunk binds to. **This is the point PLAN-org-extraction.md must be
  reconciled** so the surviving entry point is unambiguous. Both org-adoption and Stage 3 edit the
  same view files → **serialize; one plan owns a file at a time; submodule bumps are monotonic.**
  Task 21 touches only `glasspane-config.el` (file-disjoint) and interleaves freely.
- **Standalone engine pack:** create `glasspane-pack.el`, `glasspane-pack-version`, and
  `glasspane-pack.json` (`pack_format`, pack id/version, **minimum Jetpacs API**, a provided
  `feature`/version symbol, layouts, and **owner-filtered** source/action metadata). **`glasspane.el`
  requires this standalone engine bundle.**
- **Migration matrix (migrate only what v1 reproduces faithfully):** migrate saved **list / board /
  calendar** views and **faithful read-only collection screens** — journal *history*, backlinks,
  search results, agenda *collections* — onto `:spec` + `defsource`. **Keep builder-based:** detail
  sheets, **capture/edit forms**, SRS review, dialogs, and any other specialized/interactive screen
  the v1 grammar cannot represent. Record every surface's disposition in the matrix.
- **Also:** register the `"glasspane.org"` source (owned, with named fields that emit canonical
  types); drop the 4 internal pokes for the Stage-1 public APIs; adopt the Stage-2 form registry for
  any migrated forms; annotate `jetpacs-defaction` sites with catalog metadata.
- **Gate:** every task regens `glasspane.el` and runs the full suite (**all pass; baseline 78 +
  new source/spec-equivalence, manifest, teardown, and mutation tests**) as a single commit.

---

## Stage 4 — Composer targeting (companion doc: `jetpacs-composer/docs/PLAN-pack-targeting.md`) — DONE 2026-07-13

Executed per the companion doc (its EXECUTED header carries the commit list); the summary
below is the record of the bar it met, with the FORMAT renumbering (2→3 became 3→4) noted
in the companion-deliverables section above. Composer **owns pack lifecycle; core added no
pack registry.** Summary:

- **Runtime refactor:** factor the `jetpacs-crud--kinds` scan → filter → bind → render pipeline onto
  the Stage-2 binding layer where the grammar covers it; **keep specialized composer view kinds on
  their existing builders when the v1 grammar cannot represent them.** Preserve the load-bearing
  invariants: positional `COLTYPES`/`SCHEMA` alignment, save→repush + fresh-parse-every-render,
  closed `crud.*` vocab + server-side `--resolve`, title-matched redeploy merge.
- **FORMAT + pack references:** add `#+JETPACS_PACK` dependency declarations and `pack:<id>/<local-name>`
  source/action references. **Composer accepts FORMAT 2 and 3, emits 2 when no pack feature is used,
  emits 3 only for pack-backed documents, and rejects versions above 3.** **Add safe unknown-source
  preservation on both parsers *before* enabling v3 output.**
- **Lifecycle & safety (fail closed):** export only against a **selected, locally installed
  manifest**; the generated *trusted* code may `require` that manifest's fixed feature, but **app
  data can never choose an arbitrary feature, download code, or trigger package installation**
  (SPEC §5). **Missing, incompatible, or duplicate packs fail closed** with an unavailable-view
  diagnostic and **no mutation dispatch**.
- **Contract/pack-driven UI:** drive accept/reject and the source/action pickers from the vendored
  `contract.json` (Stage 1, byte-verified) + the selected `glasspane-pack.json` (Stage 3); fold the
  node→fallback awareness into `ModelOps.validate` as *warnings* (never blocks; `node_types` is
  per-connection/on-device and permissive when absent).
- **Acceptance:** recreate real Glasspane views against the pack — saved-views **list/board/calendar**,
  **journal history**, **backlinks** — export, deploy on-device with the pack installed, verify each
  renders + one mutation round-trips; extend the shared parser-parity corpus + exporter-equivalence
  + pack present/missing/incompatible fixtures in lockstep.

---

## Cross-repo order (the real critical path)

Documentation preflight (**Stage 0**) → **Stage 1** (core static contract + seam promotion,
api 1.4.0) → **Glasspane Task 21 + Org adoption** (Glasspane housekeeping; can proceed in parallel
with Stage 1, both prerequisites for Stage 3) → **Stage 2** (core binding layer, api 1.5.0) →
**Stage 3** (standalone Glasspane pack + adoption) → **Stage 4** (composer runtime + pack lifecycle
+ FORMAT 3) → **on-device recreation**.

| # | Repo | Work | Gated by |
|---|------|------|----------|
| 0 | jetpacs | Stage 0 doc preflight (2 doc-only commits) | — |
| 1 | jetpacs | Stage 1 — contract + seam promotion (api 1.4.0) | 0 |
| 1c | composer | T1.5 — vendor + byte-verify contract | 1 |
| 2a | glasspane | Task 21 + Org adoption (reconcile PLAN-org-extraction) | core pin (org-adoption's staged bump) |
| 2 | jetpacs | Stage 2 — source registry + `:spec` (api 1.5.0) | 1 |
| 3 | glasspane | Stage 3 — standalone pack + migration matrix | 2, 2a |
| 4 | composer | Stage 4 — runtime + lifecycle + FORMAT 4 — **done** | 2, 3 (pack), 1c |
| 5 | on-device | recreate views + one mutation round-trip — batch half done; device rows = Glasspane TESTING-ON-DEVICE §20 | 3, 4 |

---

## Risks

- **Schema drift across three repos.** *Mitigation:* the T1.3 three-leg gate (elisp↔golden↔Kotlin
  set, Kotlin dispatcher↔set, contract byte-stability) + the composer's byte-equality vendor check;
  the shared parser-parity corpus for the composer↔runtime leg. The contract is static-only, so
  there is no inferred-schema surface to drift.
- **1.3.0 double-exposure.** *Mitigation:* one minor bump per independently landed API batch;
  Stage 1 → 1.4.0, Stage 2 → 1.5.0 (or next unused); one-line API-STABILITY record.
- **Doc contradiction with `PLAN-org-extraction.md`.** *Mitigation:* reconcile it before Stage 3 so
  the `defsource` thunk binds to the surviving `jetpacs-org-*` entry point, not a retired symbol.
- **org-adoption's atomic commit.** *Mitigation:* land it (and Task 21) before Stage 3 opens shared
  files; one plan owns a file at a time; monotonic submodule pins.
- **Version-gate brick (composer).** *Mitigation:* add unknown-source preservation on both parsers
  before emitting v3; emit v3 only for pack-backed docs; reject > 3.
- **Pack safety.** *Mitigation:* export only against a locally installed manifest; app data never
  selects a feature, downloads code, or installs packages; missing/incompatible/duplicate packs
  fail closed with no mutation.
- **Battery / cache contract.** *Mitigation:* sources are uncached by default; opt-in caching is
  keyed on an app-supplied freshness token (no implicit day-long cache); node-building stays outside
  the cache; reuse the 0.5s idle-repush debounce; no polling.

## Verification — the exact CI batteries

- **jetpacs:** the `core-load` guard; **both ERT suites**; bundle-drift (regenerated
  `jetpacs-core.el` matches sources); the T1.3 contract + node-mirror + API-sweep gates; **both
  Android modules' unit tests / lint / build** (`:jetpacs` and `:app`).
- **Glasspane:** the complete ERT suite (**all pass; baseline 78 + new tests**) plus new
  source/spec-**equivalence**, **manifest**, **teardown**, and **mutation** tests; regen
  `glasspane.el`; grep-for-zero on the promoted internal symbols.
- **composer:** `elisp/test/run-tests.sh`; `./gradlew build`; the shared **parser-parity** fixtures;
  **exporter-equivalence**; and **pack present / missing / incompatible** cases.
- **On-device (deferred):** **create `docs/TESTING-ON-DEVICE.md` if still absent**; record the
  recreated **saved views, journal, backlinks** and **one successful mutation round-trip**.

## Critical files (by repo)

- **jetpacs:** `emacs/core/jetpacs-lint.el` (vocab lifts, `on_point_tap`/`on_button`, discriminated
  builtin check, `jetpacs-lint-view-spec`), new `emacs/build-contract.el` + `docs/contract.json`,
  `test/jetpacs-tests.el` + the Android test module (three drift legs),
  `emacs/core/jetpacs-shell.el` (`:spec` branch + tab setter), new `emacs/core/jetpacs-source.el` +
  `emacs/core/jetpacs-spec.el`, `emacs/core/jetpacs-surfaces.el` (`jetpacs-in-action-p` +
  ownership move, `jetpacs-ui-state-list`, form registry, action catalog),
  `emacs/core/jetpacs-files.el` / `jetpacs-widgets.el` (seam promotions), `emacs/core/jetpacs.el`
  (`jetpacs-node-or`, api bump), new `docs/BINDING.md` + `ARCHITECTURE.md` / `BUILDING-TIER1.md` /
  `API-STABILITY.md` / `ROADMAP.md` deltas, `docs/SPEC.md` (wire corrections only),
  `emacs/build-bundle.el`; **reconcile** `docs/PLAN-org-extraction.md`.
- **Glasspane:** `glasspane-org.el` + a source registration, the migrated view files
  (`glasspane-views.el` first as reference), new `glasspane-pack.el` + `glasspane-pack.json` +
  generator, `glasspane-config.el` (Task 21); new `docs/PLAN-binding-adoption.md` (**deliverable**).
- **composer:** `elisp/jetpacs-crud.el` (binding-layer refactor where covered), `OrgCodec.kt` /
  `ModelOps.kt` / `AppSpec.kt` (contract-verified emission, v3 gate + unknown-source preservation,
  pack references), `BundleExporter.kt`, contract-vendor step, `docs/FORMAT.md` (v3 + non-goal
  reconciliation), `elisp/test/fixtures/*`; new `docs/PLAN-pack-targeting.md` (**deliverable**).
