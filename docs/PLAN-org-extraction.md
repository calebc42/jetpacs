# Migration Plan: Adopting `jetpacs-org.el` Core Primitives

**STATUS (2026-07-13): EXECUTED — both halves.** The composer deleted its parser/matcher and
routes through the canonical functions (its record *scan* path was further superseded by the
vulpea index read — `jetpacs-composer/docs/PLAN-vulpea-rearchitecture.md`). Glasspane's
adoption ran the same day (`Glasspane/docs/PLAN-glasspane-org-adoption.md` has the full
record): `glasspane-org.el` sheds its cache/refs/parser/matchers (~616 net lines) and stands
on `jetpacs-org-*` under the `glasspane` namespace, including the canonical vulpea note
matcher. One deliberate §1 deviation: Glasspane's mutation funnel (`glasspane-ui--at-ref`)
was **kept** rather than rebased onto `jetpacs-org-set-property`/`-toggle-todo`/
`-set-planning` — the audit of this plan's open question confirmed the core's idle-timer
deferred save breaks Glasspane's synchronous-save/refresh-suppression policy and read-back
flows; the funnel already consumes the canonical resolve + cache-invalidate, which was the
actual duplication.

**Surviving entry points (the reconcile required by `PLAN-binding-layer.md`):** the one query
grammar lives in core — `jetpacs-org-parse-query`, `jetpacs-org-entry-matches-p` (point
accessor), `jetpacs-org-note-matches-p` (vulpea-note accessor, guarded), and
`jetpacs-org-query` — and `defsource` thunks bind to those.

With the robust core primitives established in the Jetpacs foundation, the next step is to eliminate the duplicated logic in both Glasspane (Tier 1) and jetpacs-composer (`jetpacs-crud.el` runtime) and standardize their architecture on the foundation.

## 1. Glasspane Refactor

Glasspane currently owns its own implementations of caching, query interpretation, heading reference mapping, and search fallbacks. These will all be ripped out in favor of the core.

### [MODIFY] `glasspane-org.el`
- **Delete Duplicated Parsers & Interpreters**: Remove `glasspane-org--parse-query`, `glasspane-org--query-match-p`, and all associated normalization helpers.
- **Delete Duplicated Identity Maps**: Remove `glasspane-org--heading-ref` and `glasspane-org--resolve-ref`.
- **Delete Custom Caching Layer**: Remove `glasspane-org--cache`, `glasspane-org--with-cache`, and `glasspane-org-cache-invalidate`.
- **Adopt High-Level Query**: Refactor `glasspane-org--query` to simply wrap `(jetpacs-org-query 'glasspane tree #'glasspane-org--heading-item-at)`.
- **Adopt Cache Macro**: Update `glasspane-org--agenda-items` and other custom extractions (like tags/todos) to wrap their bodies in `(jetpacs-org-with-cache 'glasspane ...)`.

### [MODIFY] All Other Glasspane Files
- Replace all calls to `(glasspane-org-cache-invalidate)` with `(jetpacs-org-cache-invalidate 'glasspane)`.
- Replace calls to `glasspane-org--heading-ref` / `glasspane-org--resolve-ref` with `jetpacs-org-heading-ref` / `jetpacs-org-resolve-ref`.
- Refactor manual property and todo mutations (e.g. inside `glasspane-detail.el` and `glasspane-capture.el`) to utilize `jetpacs-org-set-property`, `jetpacs-org-toggle-todo`, and `jetpacs-org-set-planning`. These will automatically defer saves and invalidate the `'glasspane` cache.

## 2. Composer Runtime (`jetpacs-crud.el`) Refactor

The composer's runtime engine evaluates org-queries and extracts typed fields. It also duplicates the query parser.

### [MODIFY] `jetpacs-crud.el`
- **Delete Duplicated Parsers & Interpreters**: Remove `jetpacs-crud--parse-query`, `jetpacs-crud--entry-matches-p`, and all associated normalization helpers.
- **Adopt Core Matching in Scanner**: Update `jetpacs-crud--scan-records` to map over subtrees using `jetpacs-org-parse-query` and `jetpacs-org-entry-matches-p`.
- **Adopt Typed Extraction**: Update `jetpacs-crud--scan-records` to extract record fields utilizing `jetpacs-org-entry-typed-value` rather than raw `org-entry-get`.
- **Adopt Mutation Primitives**: Update all `crud.*` action handlers (e.g., `crud.action.apply`, `crud.field.edit`, `crud.record.add`) to use the safe `jetpacs-org-set-property`, `jetpacs-org-toggle-todo`, and `jetpacs-org-set-planning` primitives (passing `'jetpacs-crud` as the cache namespace).

## Open Questions

- By removing Glasspane's internal caching and moving mutations to the core, Glasspane's manual `save-buffer` calls and `after-save-hook` refresh suppression (`glasspane-org--inhibit-save-refresh`) might need careful auditing. The core uses an idle timer (`run-with-idle-timer`) to batch saves. Does this async saving model fit the Glasspane workflow, particularly around immediate sync or capture finalizing?
- `jetpacs-crud.el` currently doesn't use a cache mechanism for its subtree scans (`jetpacs-crud--scan-records`). Should I wrap these scans in `jetpacs-org-with-cache 'jetpacs-crud` to drastically improve no-code app performance on mobile devices?
