# Plan: DSL ergonomics — semantic text, sub-tree error boundary, async

**STATUS (2026-07-15): drafted, not started.** The elisp / authoring
track derived from [AUDIT-vui-dsl-guidance.md](AUDIT-vui-dsl-guidance.md)
(Tiers A1, A2, B1). All three items are **pure elisp**, land as
composites/helpers beside the existing ones at
[`jetpacs-widgets.el` §Composites](../emacs/core/jetpacs-widgets.el),
add **no `t` to the wire vocabulary**, and need **no companion
release** — except the `success`/`warning` semantic colors, which
depend on the two tokens added by the renderer track's **K0**
([PLAN-renderer-reconciliation.md](PLAN-renderer-reconciliation.md));
see Phase 1. The companion partner is [ROADMAP.md](ROADMAP.md)'s *rich
server, thin client*: expressiveness in Emacs, never a wider grammar.

## Why

vui exposes three ergonomic gaps in the jetpacs authoring surface
(the audit's method + evidence are there; this is the execution):

- **A1** — no *semantic* text layer. Every screen re-derives "an error
  is `body` + `:color "error"`", "muted is `caption` +
  `on_surface_variant`". vui ships `vui-error`/`-muted`/`-heading`/… as
  face wrappers.
- **A2** — error handling is whole-builder granular; one thrown card
  blanks the view. vui's `error-boundary` contains failure at a
  subtree.
- **B1** — async data is hand-rolled per app (kick off in a handler,
  stash in a defvar, re-push, hand-write the three display states).
  vui's `use-async` makes it one keyed state machine.

## Conventions this plan follows

Each new symbol: a `cl-defun` in `jetpacs-widgets.el` (semantics/errors)
or a small new section for `jetpacs-async` (it has runtime state, so it
may warrant its own `jetpacs-async.el` — see Phase 3); a golden line in
[`test/widgets.golden`](../test/widgets.golden) if it emits a fixed
shape; an ERT test asserting `jetpacs-render-to-json` round-trips and
`jetpacs-test-visible-text` sees the text; an entry in
[API-STABILITY.md](API-STABILITY.md); a `C-h f` docstring carrying the
full semantics (the docstring is the per-symbol authority, per
[WIDGETS.md](WIDGETS.md)). No SPEC change — these emit existing nodes.

## Phase 1 — A1: semantic text shorthands

Thin composites over `jetpacs-text` / `jetpacs-rich-text`. Each is a
pure function returning an existing node; the win is one place to
change the theme decision and intent-level call sites.

```elisp
(cl-defun jetpacs-heading (text &key (level 1) padding)
  "A heading at LEVEL (1→title, 2→headline, ≥3→body)."
  (jetpacs-text text
                :style (pcase level (1 'title) (2 'headline) (_ 'body))
                :padding padding))

(cl-defun jetpacs-muted (text &key (style 'caption) padding)
  "De-emphasized TEXT (STYLE, tinted on_surface_variant)."
  (jetpacs-text text :style style :color "on_surface_variant" :padding padding))

(cl-defun jetpacs-error (text &key padding)
  (jetpacs-text text :color "error" :padding padding))

(cl-defun jetpacs-warning (text &key padding)
  ;; Uses the additive `warning' token (renderer K0); resolveColor
  ;; falls back to onSurfaceVariant on a companion predating it, so the
  ;; text still renders (just untinted). No node_types gate needed.
  (jetpacs-text text :color "warning" :padding padding))

(cl-defun jetpacs-success (text &key padding)
  (jetpacs-text text :color "success" :padding padding))   ; renderer K0

(cl-defun jetpacs-strong (text &key padding)
  "Bold TEXT (a one-span rich_text, since plain text has no bold)."
  (jetpacs-rich-text (list (jetpacs-span text :bold t)) :padding padding))

(cl-defun jetpacs-code (text &key padding)
  "Inline monospace/code TEXT (a one-span rich_text)."
  (jetpacs-rich-text (list (jetpacs-span text :code t)) :padding padding))
```

**The one cross-surface dependency.** `error` and the M3 tokens exist
today; **`success` and `warning` do not** (`resolveColor` in
`SduiContentNodes.kt` has no such cases). So `jetpacs-success` /
`jetpacs-warning` are theme-adaptive **only after** the renderer track
lands **K0** (add `success`/`warning` to `resolveColor`, additive —
old companions fall through to `parseHexColor` → `Unspecified` →
ambient color, so the text still shows). Two orderings, pick one:

1. **Ship K0 first** (trivial Kotlin), then all of A1 is theme-correct.
   *Recommended* — K0 is ~6 lines and useful beyond this.
2. **Ship A1 now**, mapping `warning`→`"tertiary"` and dropping
   `success` until K0, then swap the tokens. More churn.

Everything else in A1 (`heading`/`muted`/`error`/`strong`/`code`) has
zero companion dependency and can land immediately.

**Tests.** Golden lines for each; an ERT that
`(jetpacs-test-visible-text (jetpacs-error "x"))` contains `"x"` and
that the color/style keys serialize. Lint stays green (no new keys).

## Phase 2 — A2: `jetpacs-try` sub-tree error boundary

A builder that signals blanks the whole view. `jetpacs-try` wraps a
fragment so a throw becomes a local fallback node, the siblings
survive — the shape a dashboard of independent cards wants.

```elisp
(defmacro jetpacs-try (body &rest keys)
  "Evaluate BODY (a node-producing form); on error return the :fallback node.
KEYS: :fallback FN — a function of the error object returning a node
      (default: a muted `jetpacs-empty-state').  The error is also
      logged to *Messages* so it is never swallowed silently."
  (declare (indent 1))
  (let ((fb (plist-get keys :fallback)))
    `(condition-case err
         ,body
       (error
        (message "jetpacs-try: %s" (error-message-string err))
        ,(if fb
             `(funcall ,fb err)
           `(jetpacs-empty-state
             :title "Couldn't render"
             :caption (error-message-string err)))))))
```

Usage:

```elisp
(jetpacs-column
 (jetpacs-try (stat-cards data))
 (jetpacs-try (chart-card data)
   :fallback (lambda (e) (jetpacs-error (format "Chart failed: %s" e)))))
```

**Notes.** Macro, not a node — it just chooses which node to emit, so
it needs no wire/lint change. Pairs with the renderer's **K2**
(defensive rendering): `jetpacs-try` stops a *builder* throw from
blanking the view; K2 stops a *malformed-node* throw from blanking the
surface. Same lesson, both ends of the wire.

**Tests.** ERT: `(jetpacs-try (error "boom"))` returns an
`empty_state` node (assert via `jetpacs-render-to-json`) and does not
signal; with `:fallback`, returns the fallback's node.

## Phase 3 — B1: `jetpacs-async` declarative loading

The highest-leverage item. A keyed loader whose result is cached and
whose completion schedules one `jetpacs-shell-push`; the builder only
*reads* the cache. Mirrors vui's `use-async` state machine, adapted to
jetpacs's pure-rebuild model (the loader lives outside the builder).

### 3a. The API

```elisp
(cl-defun jetpacs-async (key loader &key owner)
  "Return the async state for KEY as (STATUS . PAYLOAD).
STATUS is `pending', `ready', or `error'.  On the first call for a
fresh KEY (compared `equal'), start LOADER once and return
`(pending)'.  LOADER is (lambda (resolve reject) …): call RESOLVE with
the value or REJECT with an error string; either stores the result and
schedules a single `jetpacs-shell-push'.  Later calls return
`(ready . VALUE)' / `(error . MESSAGE)' from cache.  A KEY not seen in
a given push is swept (its load cancelled) after that push — so a view
that stops asking for data stops paying for it.  OWNER scopes the
cache entry to an app for teardown (defaults to the current
`with-jetpacs-owner')."
  …)
```

Builder use (pure read; the *start* is the sole controlled impurity,
idempotent per key — documented loudly, exactly as vui's `use-async`
fires from within `render`):

```elisp
(pcase (jetpacs-async (list 'stock product-id)
                      (lambda (resolve reject)
                        (grocy--fetch-stock product-id resolve reject)))
  (`(pending . ,_) (jetpacs-progress))
  (`(error   . ,e) (jetpacs-error e))
  (`(ready   . ,d) (stock-card d)))
```

### 3b. Internals

- **Cache** — a hash table `KEY → entry`, entry = `(status value
  loader gen owner cancel)`. `status` ∈ pending/ready/error; `gen` is
  the push-generation stamp for the sweep; `cancel` an optional thunk
  the loader registered (kill a process, cancel a timer).
- **resolve/reject** are closures over the entry that (1) set
  status+value, (2) call `jetpacs-shell-push` *once* (debounced so a
  burst of completions in one tick coalesces).
- **Sweep (eviction)** — the audit's open design point. Start with the
  **generation stamp**: `jetpacs-shell-push` bumps a global generation
  before rebuilding; each `jetpacs-async` call stamps its entry with
  the current gen; after the rebuild, entries whose gen is stale are
  swept (run `cancel`, drop). This is the precise mirror of vui's
  mount/unmount and avoids leaking loads for keys a view stopped
  asking about. If the push loop can't host the post-rebuild sweep
  cleanly, fall back to **owner-scoped teardown only** (cleared by
  `jetpacs-app-unregister`) — coarser but trivial, and acceptable for
  v1.
- **Errors** — a LOADER that throws synchronously is caught and turned
  into `(error . MESSAGE)` (never takes down the push, matching the
  handler contract in TUTORIAL §7).
- **Placement** — this carries mutable runtime state and a push
  dependency, unlike the pure composites; put it in a new
  `jetpacs-async.el` required by `jetpacs-shell`, not in
  `jetpacs-widgets.el` (which stays pure-value-only).

### 3c. Tests

- Synchronous loader: `resolve` called inline → first
  `jetpacs-async` returns `(ready . v)` on the *second* call, `(pending)`
  on the first; assert the transition and that exactly one push was
  scheduled (stub `jetpacs-shell-push`, count calls).
- `reject` → `(error . msg)`.
- Throwing loader → `(error . …)`, no signal escapes.
- Sweep: a key asked in push N but not N+1 has its `cancel` run after
  N+1's rebuild.
- Key change supersedes: asking key A then key B leaves A swept.

## Sequencing

1. **Phase 1 minus success/warning** — immediate, zero dependency.
2. **Phase 2** (`jetpacs-try`) — immediate, independent.
3. **Renderer K0** (tokens) → finish Phase 1 (`success`/`warning`).
4. **Phase 3** (`jetpacs-async`) — the substantial one; independent of
   1–3, can proceed in parallel.

Dogfood target after landing: convert one hand-rolled async spot and a
few `:color "error"` sites in the grocy/glasspane apps to the new
helpers, confirming the boilerplate actually shrinks (the audit's test
4 — ergonomic leverage — verified in practice).

## References

- [AUDIT-vui-dsl-guidance.md](AUDIT-vui-dsl-guidance.md) — the source
  analysis (Tiers A1/A2/B1).
- [PLAN-renderer-reconciliation.md](PLAN-renderer-reconciliation.md) —
  the Kotlin track; **K0** (color tokens) is Phase 1's dependency.
- [WIDGETS.md](WIDGETS.md), [API-STABILITY.md](API-STABILITY.md),
  [`jetpacs-widgets.el`](../emacs/core/jetpacs-widgets.el).
