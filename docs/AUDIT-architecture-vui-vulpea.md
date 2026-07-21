# Audit: jetpacs architecture against vui.el and vulpea v2.6

**STATUS (2026-07-16): findings + roadmap, approved by the owner.** A
source-grounded architecture review of the jetpacs ecosystem against two
reference packages — [vui.el](https://github.com/d12frosted/vui.el)
(React-like declarative UI for Emacs buffers, read at 5,836 lines) and
[vulpea](https://github.com/d12frosted/vulpea) v2.6.0 (async-first
SQLite database layer for org notes) — plus the current state of
glasspane and jetpacs-composer. Unlike
[AUDIT-vui-dsl-guidance.md](AUDIT-vui-dsl-guidance.md) (which this doc
extends, not replaces), the prior decisions were **re-litigated, not
assumed**: each Tier-D rejection and each claim of the standing
`Glasspane/docs/PLAN-vulpea-ecosystem-exploration.md` gets an explicit
verdict below.

Headline: four concrete defects found, one prior decision partially
overturned (the "Emacs-side reconciliation is wasted work" phrasing),
several upheld with new carve-outs, and a tiered roadmap whose Tier 3
stays behind the measurement gates — which Tier 1 finally makes
satisfiable.

## Verified defects

1. **`glasspane-vulpea.el` crashes at load whenever vulpea is
   installed.** It passes `:batch-insert-fn`/`:delete-fn` to
   `make-vulpea-extractor` (`Glasspane/emacs/apps/glasspane/glasspane-vulpea.el:45-59`)
   — slots that do not exist in vulpea 2.6 (current slots: `name version
   schema priority extract-fn requires-ast worker-safe worker-lib`,
   `vulpea-db-extract.el:263-270`); a cl-defstruct constructor signals
   on unknown keywords. The `fboundp` guard *passes* when vulpea is
   loaded, and `glasspane-org.el:581` requires the file when
   `(featurep 'vulpea)`. The schema is also the pre-v2 flat format with
   no cascade FK. *(Static analysis; confirm by loading glasspane with
   vulpea present.)*
2. **The composer's vulpea extractor silently indexes nothing under
   vulpea 2.6.** `jetpacs-crud-vulpea--extract` maps
   `(vulpea-parse-ctx-ast ctx)` for org tables + checklist items, but
   registers **without `:requires-ast t`**
   (`jetpacs-composer/elisp/jetpacs-crud-vulpea.el:568-580`). Vulpea
   2.6's contract: an undeclared AST reader "always receives a context
   whose AST slot is nil — so an undeclared AST reader visibly extracts
   nothing" (`vulpea-db-extract.el:240-250`, enforced by
   `vulpea-db--effective-granularity` at `:372-382`). The file was
   written against older semantics where the AST was always populated;
   the `table`/`checklist` kinds are dead against current vulpea. The
   fix's cost is real and must be documented at the fix site:
   `:requires-ast t` forces object-granularity parses (2–3x slower) and
   disqualifies the async worker.
3. **Ghost pushes from swept async entries.** `jetpacs-async--settle`
   ([jetpacs-async.el:87-93](../emacs/core/jetpacs-async.el))
   unconditionally schedules the coalesced push even for an entry
   already swept from the cache — the docstring calls it "harmless",
   but on a full-tree-resend system each ghost push is a complete
   rebuild + reserialize + radio wake. A battery defect, not hygiene.
4. **Snackbar lost on failed push.** `jetpacs-shell-push` consumes
   `jetpacs-shell--snackbar` via `prog1`
   ([jetpacs-shell.el:551-552](../emacs/core/jetpacs-shell.el)) before
   `jetpacs-surface-push` can error; the error handler does not restore
   it.

## Challenging the prior decisions

### Tier-D rejections (AUDIT-vui-dsl-guidance.md) — verdicts

| Rejection | Verdict | Evidence & consequence |
|---|---|---|
| **Component instances + `use-state`/`use-effect`/`use-ref`** | **HOLDS** — but the pain it waved off is real | The companion *is* the instance tree (id-keyed `rememberSeeded`); an elisp copy would be a second state model. However, composite/view-private state today lands in stringly global ui-state keys with hand-rolled prefix conventions — `"search-filter-*"` + `(jetpacs-ui-state-clear "search-filter-")` (`glasspane-search.el:54-58,218`), twelve `"file-prop-*"` keys (`glasspane-detail.el:1127-1145`), `"agenda-*"` (`glasspane-agenda.el`). Remedy is **namespacing sugar, not instances**: a view-scoped accessor (`jetpacs-ui-state-scope` returning get/put/clear closures over a prefix, or a `with-` macro). Roadmap 2.6. |
| **Lifecycle `:on-mount`/`:on-unmount`** | **HOLDS for components; a real gap at VIEW level the audit never considered** | Rejecting *component* lifecycle was correct ("no mount/unmount event in a pure-rebuild model"). But views *do* have an enter event: `jetpacs-shell-view-switched-hook` fires with the view name ([jetpacs-shell.el:542,607](../emacs/core/jetpacs-shell.el)), and consumers already hook it globally and hand-filter (`jetpacs-files.el:556`, `jetpacs-emacs-ui.el:627`). Per-view `:on-enter`/`:on-leave` options on `jetpacs-shell-define-view` are honest sugar over an existing event — and become load-bearing once visibility gating (2.5) gives views a real "not being looked at" state. Roadmap 2.7. |
| **"Emacs-side reconciliation is wasted work"** | **PARTIALLY OVERTURNED — the phrasing conflates two different things** | Correct half: don't duplicate Compose's *state* reconciliation (K1 keys feed it identity). Wrong half: Compose cannot diff what hasn't crossed the wire yet — **wire-payload minimization is exclusively the server's job**, and elisp comparing successive trees to emit deltas is not duplicated work; it is the only place that work can happen. vui contains the worked design: the experimental incremental patcher (`vui.el:3961-4170`) and, sharper, stream nodes (`vui.el:4271+`, `vui.el/docs/design/vui-stream-nodes.org`) — stable ids + append/replace/finalize verbs, finalize bounding the live set by *concurrency*, not length. Reclassified from "do NOT adopt" to **measurement-gated** (roadmap 3.1/3.2); the Tier-D wording in AUDIT-vui-dsl-guidance.md is amended accordingly. |
| **No `vui-defcontext`; dynamic vars are context** | **HOLDS — with one documented caveat** | Right call for the synchronous build pass. The caveat vui learned the hard way (`vui-with-async-context`, `vui.el:1777`): a `let`-bound dynvar is **gone** by the time a `jetpacs-async` loader's resolve callback or a timer fires — loaders must capture what they need lexically. One paragraph in the docs, no API. |
| **No `jetpacs-defcomponent` macro** | **MOSTLY HOLDS — the metadata argument is real but currently has no consumer** | Machine-readable catalogs already exist for sources/actions — `glasspane-pack.json` is *generated* from `jetpacs-source-catalog` + `jetpacs-action-catalog` (`jetpacs-composer/docs/AUDIT-engine-packs.md`). That is the ecosystem's precedent for "registry with typed metadata". But the composer composes at *view-kind* level (FORMAT), not widget level, so a composite-metadata registry would ship with zero consumers. Re-open only if the composer grows a widget palette; until then composite prop validation stays with `jetpacs-lint` at push time. |

### Standing vulpea plan (Glasspane/docs/PLAN-vulpea-ecosystem-exploration.md) — verdicts

| Plan claim / item | Verdict | Evidence |
|---|---|---|
| "No DB-change hook / revision counter" (A.1) | **STALE in worker mode** | `vulpea-db-worker-done-functions` — abnormal hook, `(PATH STATUS COUNT)`, STATUS ∈ applied/unchanged/stale/requeued/missing/error (`vulpea-db-worker.el:159-168`) — is exactly the live-refresh seam. Sync (non-worker) mode still has no hook → the plan's count+mtime token remains the fallback. `vulpea-buffer-meta-change-functions` also exists for buffer-level meta edits. |
| A.4.4 "prototype one domain extractor" | **ALREADY DISCHARGED — in the composer, and it carries defect 2** | `jetpacs-crud-vulpea.el` *is* that prototype: correct v2 registration, column-vector schema, cascade FKs, id-adoption, per-note scoping (`:519-581`). The action item flips from "prototype one" to "fix `:requires-ast` + crown it the documented reference extractor". |
| Caveat: a version bump won't ALTER (own additive migrations) | **CONFIRMED still true** | `vulpea-db--apply-plugin-schema` only does `:create-table :if-not-exists` then records the version (`vulpea-db-extract.el:1218-1230`). |
| Part C "composer installs engines" | **PARTIALLY EXECUTED — update the plan, don't redo it** | The crud runtime now self-provisions its closed engine pair (org-ql + vulpea) with an idle-timer attempt + Install button + trust boundary ("app data can never trigger an install", `jetpacs-crud-vulpea.el:99-127,191-258`). |
| "Reads are synchronous and fast, safe in `:query` at push time" | **CONFIRMED** | Still direct blocking emacsql over builtin SQLite in 2.6. |
| Not covered (plan predates vulpea 2.4/2.6) | **NEW SURFACE** | Schema validation + flymake + collection health; the async worker (`:worker-safe`/`:worker-lib` — a pack-shipped extractor should declare these or knowingly opt out); unlinked-mentions; `vulpea-propagate-title-change`. Feeds roadmap 2.3/2.4. |

## What transfers from the reference packages

- **From vui.el:** the measurement discipline (vui ships an inspector +
  timing profiler; jetpacs has zero live instrumentation, so its own
  K3/C2 "measure first" gates are currently unsatisfiable); the
  stream-nodes design as a ready spec for transcript deltas; the async
  no-op-if-unmounted guarantee (fixes defect 3); the non-settling-loop
  detector. **Not transferable:** buffer mechanics (markers, cursor
  math, the text-button fast path), and — per Tier-D, upheld above —
  instances/hooks/context-API.
- **From vulpea:** the **engine role, not the schema** — do not port
  the hybrid materialized/normalized pattern into `jetpacs-org` (it
  *is* what vulpea already provides; `jetpacs-org`'s date+mtime memo
  cache stays the engine-free fallback). Schema validation → typed
  phone forms + health views; diagnostics queries → free sources; the
  worker-done hook → live refresh.

## Roadmap

### Tier 1 — do now (all S)

| # | Item | Repo |
|---|------|------|
| 1.1 | **Rewrite `glasspane-vulpea.el` against v2.6** — crib from `jetpacs-crud-vulpea.el` (the in-ecosystem reference): extract-fn inserts inside the shared transaction, cascade FK replaces `delete-fn`, column-vector schema. Its props-only extraction needs **no AST** → declare `:requires-ast nil` (+ `:worker-safe t :worker-lib 'glasspane-vulpea`) and it stays worker-eligible. Fixes defect 1. | glasspane |
| 1.2 | **Fix the composer extractor**: add `:requires-ast t` (it genuinely maps table-cells, which are org-element *objects*) + a comment on the object-granularity/worker cost; bump `jetpacs-crud-vulpea--extractor-version`. Fixes defect 2. | jetpacs-composer |
| 1.3 | **CI load-smoke with engines present** — install vulpea and `require` glasspane (and run one crud table-kind extraction in composer CI). Defects 1 and 2 were both invisible to engine-absent test suites; this closes the class. | glasspane + composer |
| 1.4 | **Instrumentation/devtools** — retain the last pushed spec per view; wall-clock each builder around `jetpacs-shell--build-view`; log serialized bytes per push at the `jetpacs-surface-update` seam; push-rate log with a non-settling warning (vui loop-limit analog — catches e.g. a builder minting a fresh `jetpacs-async` key every build). `M-x jetpacs-devtools-report`. **Unblocks every gate below.** No wire change. | jetpacs core |
| 1.5 | **Async settle hardening** — resolve/reject no-op (no mutation, no push) unless the entry is still current in the cache; guard double-settle. Fixes defect 3; vui's unmount guarantee in ~10 lines. | jetpacs core |
| 1.6 | **C1: explicit `:key` DSL attr** on card/row/list-item — the renderer already reads it (K1a landed); the additive 8-step checklist is written ([PLAN-renderer-reconciliation.md](PLAN-renderer-reconciliation.md) §K1b/C1). | jetpacs core |
| — | Fold in the snackbar restore in the push error handler (defect 4, one line). | jetpacs core |

### Tier 2 — next

- **2.1 Execute standing-plan A.4 items 1–3 as amended** (glasspane,
  S-M, deps 1.1): `:cache-key` freshness token on `glasspane.notes`;
  extra sources (tags, backlink-counts, by-directory, by-created-date);
  headless `notes.create`/`notes.select` actions. Skip A.4.4
  (discharged — see verdicts); the plan doc's status markers are
  updated instead.
- **2.2 DB-change → repush seam** (glasspane, S, deps 2.1): worker mode
  — hook `vulpea-db-worker-done-functions` (filter STATUS=`applied`,
  debounce into `jetpacs-shell--schedule-repush` via source
  invalidation); sync mode — the count+mtime token on a slow idle
  timer. Makes the phone live; 1.4's storm detector is the safety net.
- **2.3 Schema-driven forms + note-health view** (glasspane, M, deps
  1.1): map `vulpea-schema` typed fields onto `jetpacs-field`
  form-specs (lambda-valued `:required`/`:one-of` evaluated
  server-side, shipped resolved); render
  `vulpea-schema-collection-health` as a spec list view; ship a
  glasspane note-class schema. The mapping stays in glasspane; core
  never learns vulpea.
- **2.4 Notion-like database views** (glasspane, S-M, deps 2.1):
  vulpea-meta-grouped sources feeding the *existing* `jetpacs-spec`
  board/list layouts; diagnostics sources (dead-links, orphans, stale)
  feed the same layouts. Add spec machinery (a table layout) only when
  a concrete view demands it.
- **2.5 Visibility-gated pushes** (core + renderer, S-M, additive
  inbound `app.lifecycle` event; owner sign-off on the wire addition):
  no foreground/background signal exists today, so background refreshes
  rebuild + resend while the companion UI is hidden. Suppress
  background pushes while hidden, one catch-up push on resume. No
  rendering-grammar change. Quantify with 1.4.
- **2.6 View-scoped ui-state sugar** (jetpacs core, S — from the
  instances-rejection challenge): a prefix-scoped accessor/macro
  formalizing the convention glasspane already hand-rolls. No new state
  model.
- **2.7 Per-view `:on-enter`/`:on-leave`** (jetpacs core, S — from the
  lifecycle challenge): options on `jetpacs-shell-define-view`,
  dispatched from the existing `view-switched` seam; pairs with 2.5 for
  pause/resume of view-scoped work.

### Tier 3 — gated on Tier-1 measurements (do not start early)

- **3.1 Background-refresh build reuse** (core, M; gate: 1.4 shows
  builder time/bytes matter): rebuild only the active view on
  background refreshes, reuse last-built trees for the rest.
  **Precondition:** the `jetpacs-async` generation sweep would cancel
  skipped views' loaders
  ([jetpacs-async.el:178-190](../emacs/core/jetpacs-async.el)) — make
  the sweep view-aware first; land as one change. Reject the
  dependency-tracking variant (Tier-D through the side door).
- **3.2 C2: transcript delta frames** (core + renderer, L; gate: 1.4
  shows transcript frames dominate): stable ids + a closed verb set
  append/replace/finalize per vui stream nodes. The gate is nearer than
  the DSL audit assumed — `jetpacs-comint.el` is a transcript app in
  core *today*, and the battery argument beats the original jank
  framing. Needs its own plan doc + degradation story.
- **3.3 K3: renderer skippable model** (renderer, L; gate: jank
  persisting after 3.1/3.2): deliberately last — 3.1/3.2 may remove its
  motivation; it is the most invasive item (every node family +
  goldens).

### Do NOT do

- No elisp component instances / hooks / lifecycle / VDOM / context API
  / `defcomponent` — **upheld on the merits above**, with the three
  carve-outs now in the roadmap (2.6 state sugar, 2.7 view lifecycle,
  3.1/3.2 wire deltas), which are *not* those machineries.
- No wire template DSL; 3.2's verbs stay a closed enumerated set
  (`DECISION-no-binding-template-dsl.md`).
- Do not port vulpea's hybrid schema into `jetpacs-org`; engine, not
  blueprint.
- Do not vendor/depend on vui.el in core (the additive vui companion
  stays a roadmap item) — adopt mechanisms, never the library.
- No element-handle/introspection API mirroring renderer state in elisp
  (no consumer; the salvageable kernel — tree-query helpers over the
  last pushed spec — belongs in 1.4).
- No new wire surface for ordinary-view deltas before 3.1's
  no-wire-change variant ships and is measured.

### Dependency spine

1.1 → 2.1 → {2.2, 2.3, 2.4} · 1.4 gates {3.1, 3.2, 3.3}, quantifies
2.5 · 1.2/1.3/1.5/1.6/2.6/2.7 independent. Land 1.1/1.2 first
(defects), 1.4 second.

## Critical files

- `Glasspane/emacs/apps/glasspane/glasspane-vulpea.el` (rewrite;
  reference: `jetpacs-composer/elisp/jetpacs-crud-vulpea.el:519-581`),
  `glasspane-org.el:581`
- `jetpacs-composer/elisp/jetpacs-crud-vulpea.el:568-580`
  (`:requires-ast t`)
- [jetpacs-async.el](../emacs/core/jetpacs-async.el) `:87-108` (settle),
  `:178-190` (sweep, later view-awareness)
- [jetpacs-shell.el](../emacs/core/jetpacs-shell.el) `:527-572`
  (snackbar, instrumentation, per-view lifecycle at `:542/:607`),
  [jetpacs-surfaces.el](../emacs/core/jetpacs-surfaces.el)
  (`jetpacs-surface-update`: byte logging; ui-state scope near
  `:326-342`)
- [jetpacs-widgets.el](../emacs/core/jetpacs-widgets.el) (`:key`),
  [jetpacs-lint.el](../emacs/core/jetpacs-lint.el) /
  [jetpacs-spec.el](../emacs/core/jetpacs-spec.el) (lint typing)
- Companion docs amended with this audit:
  [AUDIT-vui-dsl-guidance.md](AUDIT-vui-dsl-guidance.md) (Tier-D
  reconciliation wording + context async caveat),
  `Glasspane/docs/PLAN-vulpea-ecosystem-exploration.md` (status
  markers)
- Design reference for 3.2: `vui.el/docs/design/vui-stream-nodes.org`

## Verification (per Tier-1 item)

1.1 — load glasspane with vulpea 2.6 present: the extractor registers,
`glasspane_mobile` populates, cascade cleans rows on file delete. 1.2 —
a crud `table` view renders rows from the index again (currently empty
against 2.6). 1.3 — CI red on the old files, green after. 1.4 —
`jetpacs-devtools-report` shows per-builder ms + push bytes on a live
session. 1.5 — ERT: a late resolve after the sweep schedules no push;
double-settle no-ops. 1.6 — golden line + `jetpacs-lint-spec` accepts
`:key`; suites stay green (242 jetpacs elisp, glasspane 118, composer
105).
