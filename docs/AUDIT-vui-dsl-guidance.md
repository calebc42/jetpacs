# Audit: vui.el as guidance for the jetpacs DSL and API

**STATUS (2026-07-15): advisory, not yet approved.** A survey of
[vui.el](https://github.com/d12frosted/vui.el) — d12frosted's
React-like declarative UI framework for Emacs — read for what it can
teach **both** halves of jetpacs: the elisp authoring surface
(`jetpacs-widgets.el`, `jetpacs-surfaces.el`, the composites) *and* the
Kotlin/Compose renderer (`SduiRenderer.kt` and siblings), since jetpacs
splits across the wire what vui does in one place. No code follows from this doc
directly; each adopted candidate graduates to its own change (a
composite lands same-day per the pattern at
[`jetpacs-widgets.el` §Composites](../emacs/core/jetpacs-widgets.el);
a wire-level item gets a plan doc and the
[CONTRIBUTING-NODES.md](CONTRIBUTING-NODES.md) checklist). Everything
here is weighed against the standing thesis — *rich server, thin
client* ([ROADMAP.md](ROADMAP.md),
`DECISION-no-binding-template-dsl.md`): expressiveness
comes from Emacs, never from widening the wire grammar.

## Why

vui.el and jetpacs solve overlapping problems — "describe a UI as a
function of state, in elisp" — from opposite ends. vui is a mature,
MELPA-shipped, real-world-used framework with a considered design doc,
so it is a good mirror: the places where its vocabulary is richer than
ours are candidate gaps, and the places where its machinery is heavier
than ours are a check that we haven't under-built. The goal is to take
what improves jetpacs's ergonomics **without importing machinery that
exists only to serve vui's architecture**, which is not ours.

## The paradigm gap — read this first

| | **vui.el** | **jetpacs** |
|---|---|---|
| Render target | Local Emacs buffer (`widget.el` / `button.el`) | Android companion (Compose), over the wire |
| State location | **Local component instances** — `:state`, hooks | Plain `defvar`s in Emacs; a little client-side state keyed by `id` (text-input, collapsible, tabs) |
| Update model | `vui-set-state` → **reconcile/diff** the vtree, preserve cursor | Mutate defvar → `jetpacs-shell-push` → **rebuild the whole tree**, companion diffs |
| Node identity | Component instances + `:key` reconciliation | Position; no keys (except the `id`-keyed client state above) |
| Author unit | `vui-defcomponent` (props + state + lifecycle + `:render`) | Pure builder `defun` + composites |
| Async | `use-async` hook, status state machine | Ad-hoc: stash in a defvar, push again |

**The load-bearing observation.** vui's central machinery —
component *instances*, hooks (`use-state`/`use-effect`/`use-ref`),
`:on-mount`/`:on-update`/`:should-update`, tree reconciliation, cursor
preservation — all exists to manage **retained local state across
diffed re-renders of a live buffer**. jetpacs deliberately has almost
none of that: a view is a pure function rebuilt on every push, the
phone owns the diffing, and what little retained state exists lives on
the *companion* keyed by `id`, not in an Emacs instance tree. So the
wrong lesson from vui is "grow hooks and instances in Emacs." The
right lessons are the parts of vui that are **pure authoring
ergonomics** or **stateless declarative helpers** — and those port
cleanly onto the mechanism jetpacs already uses for composites: *a
pure function of the primitive nodes, adding no `t` to the
vocabulary.*

## What jetpacs already took (so we don't relitigate)

Several vui ideas are already in the tree, arrived at independently:

- **Higher-level components** (vui `vui-collapsible`, `vui-typed-field`,
  semantic text) ≈ jetpacs **composites** — `jetpacs-list-item`,
  `jetpacs-stat`, `jetpacs-kv`, `jetpacs-sectioned-list`,
  `jetpacs-stepper`, `jetpacs-segmented` (since 1.13.0).
- **Typed fields with inline validation** (vui `vui-integer-field`,
  `:min`/`:max`/`:show-error`) ≈ jetpacs **declarative forms** —
  `jetpacs-field TYPE` + `:validate` + `jetpacs-form-submit`'s parsed,
  typed values and inline errors (since 1.14.0).
- **Collapsible sections** — both have one; jetpacs's `collapsible`
  folds client-side without a round trip.
- **Batching** — vui's `vui-batch` collapses many `set-state`s into one
  render; jetpacs batches *by construction* (mutate defvars, then one
  `jetpacs-shell-push`).

The frontier below is what's left.

## Method

Each candidate is argued against four tests, in order:

1. **Architecture fit** — does it respect *rich server, thin client*?
   Pure-elisp helpers pass freely; anything touching the wire must also
   pass CONTRIBUTING-NODES.md's three-part test (high-frequency,
   interaction/polish-sensitive, small closed parameterization).
2. **No new wire node if avoidable** — the composite bar: compose
   existing primitives, render on every companion with no change.
3. **Ergonomic leverage** — how much hand-rolled boilerplate it erases
   across real apps (grocy, glasspane are the witnesses).
4. **Concept cost** — does it add a concept an author must learn, and
   is that concept worth its weight given jetpacs's model?

## Tier A — pure-elisp sugar, ship now

No wire change, no companion release; lands as composites beside the
existing ones. Highest confidence, lowest cost.

### A1. Semantic text shorthands

vui ships `vui-heading`/`-N`, `vui-strong`, `vui-italic`, `vui-muted`,
`vui-code`, `vui-error`, `vui-warning`, `vui-success` — thin wrappers
over `vui-text` with customizable faces. jetpacs has raw styles
(`title`/`headline`/`body`/`caption`/`label`) and theme color tokens
(`error`, `primary`, `on_surface_variant`, …) but **no semantic
layer**, so every screen re-derives "an error is `body` +
`:color "error"`", "muted is `caption` + `on_surface_variant`". Add:

```elisp
(jetpacs-error   "Out of stock")        ; ⇒ (jetpacs-text … :color "error")
(jetpacs-warning "Low battery")
(jetpacs-success "Synced")
(jetpacs-muted   "3 items")             ; caption + on_surface_variant
(jetpacs-heading "Section" :level 2)    ; maps level → title/headline/…
```

Centralizes the theme decision in one place (change the token once,
every call follows), reads at intent level, and is trivially
lint/golden-testable. Lowest-risk item in the doc.

### A2. `jetpacs-try` — a sub-tree error boundary

jetpacs catches errors at **whole-builder** granularity: a builder
that signals renders as an error view, a handler that signals is
echoed to `*Messages*` (TUTORIAL §7). vui's `vui-error-boundary`
catches at **sub-tree** granularity, so one broken child renders a
fallback while its siblings live. On a dashboard of independent cards
(`jetpacs-stat` tiles, a viz card, a data card) that difference is the
gap between "one card shows an error chip" and "the whole screen is
the error view." Since jetpacs builds pure values, this is just
`condition-case` in the builder, wrapped for readability:

```elisp
(jetpacs-try (risky-card data)
  :fallback (lambda (err)
              (jetpacs-empty-state :title "Couldn't load" :caption err)))
```

A macro, not a wire node. Pairs naturally with A3.

### A3. Standalone typed field (maybe)

vui offers `vui-integer-field` / `vui-float-field` as **single** typed
inputs, independent of any form. jetpacs's typed validation lives only
inside the `jetpacs-form` registry — good for multi-field capture, but
heavyweight for a lone "quantity" field that wants `number` typing +
`:min`/`:max` and one inline error. A thin `jetpacs-number-field`
(parse, clamp, inline error, inject the *typed* number) would close
that. **Lower priority** — the form path already covers the common
case; add only if the one-field friction shows up in practice.

## Tier B — the one real capability gap

### B1. `jetpacs-async` — declarative pending/ready/error

This is the highest-leverage borrowing in the doc. vui's `use-async`
turns "load data, show a spinner, then the result or an error" into a
keyed state machine returned from render. In jetpacs today this is
hand-rolled in every data-backed app: an action handler kicks off the
work (a `make-process`, an org-ql query, a network call), stashes the
result in a defvar, and calls `jetpacs-shell-push` again; the builder
reads the defvar and hand-writes the three display states.

It maps *perfectly* onto jetpacs precisely because the loader lives
**outside** the pure builder — the builder only reads cache state:

```elisp
;; in the view builder — a pure read of cache state
(pcase (jetpacs-async (list 'stock product-id)
                      (lambda (resolve reject)
                        (grocy--fetch-stock product-id resolve reject)))
  (`(pending . ,_) (jetpacs-progress))
  (`(error   . ,e) (jetpacs-error e))
  (`(ready   . ,d) (stock-card d)))
```

Semantics, mirroring `use-async`:

- Keyed by `KEY` (compared `equal`). First builder call for a fresh
  key starts `LOADER` once and returns `pending`; `LOADER` calls
  `resolve`/`reject`, which store the result and schedule one
  `jetpacs-shell-push`. Subsequent calls return `ready`/`error` from
  cache. A changed key supersedes (and cancels) the prior load.
- **The one controlled impurity.** Calling `jetpacs-async` in a
  builder may *start* a load — the sole place a builder has a side
  effect. It is idempotent per key (start-once), exactly as vui's
  `use-async` fires from within `render`. This is acceptable and worth
  documenting loudly.
- **Lifecycle / eviction** is the only non-trivial design point.
  vui evicts on instance unmount; jetpacs has no instances. Options,
  cheapest first: (a) owner-scoped cache cleared by
  `jetpacs-app-unregister` (coarse but simple); (b) a per-push
  generation stamp — mark keys touched during a push, sweep untouched
  entries after (precise, mirrors mount/unmount). Start with (a); (b)
  if stale loads bite.

Removes reinvented plumbing from every app and gives one uniform
loading UX. No wire change — `progress`/`text` already exist.

## Tier C — wire/companion level (roadmap, needs Android work)

These need a companion release, so they are plans, not patches, and
must clear CONTRIBUTING-NODES.md's three-part test.

### C1. List keys — `:key`-based reconciliation

vui's sharpest **correctness** lesson is `:key`: `vui-list` reconciles
by a per-item key so inserts/deletes/reorders preserve the right
instance's state instead of smearing by position. jetpacs already
trusts exactly this idiom for client-side state — `collapsible`,
`tabs`, and `text-input` all key their retained state by `id`, and the
documented rule "push a new id to reset" *is* keyed reconciliation.
But **list rows carry no key**, so the companion diffs a `lazy_column`
by position; reordering or inserting can hand row N's client state,
scroll anchoring, or enter/exit animation to the wrong row.

The principled fix is an optional `:key` on `card` / `row` /
`list-item` that the companion uses as the reconciliation identity —
the natural extension of an idiom jetpacs already relies on. It clears
the three-part test (high-frequency: every dynamic list;
interaction-sensitive: animation and preserved scroll are native-only;
closed: one optional string attr). Cost is real (Compose `key {}` in
the lazy list, protocol note, negotiation), so it earns its own plan.
**But the substantive work — and the current correctness bug — live in
the renderer, not the DSL: see K1 below.**

### C2. Streaming / delta push (low priority)

vui-stream appends transcript rows above a persistent input without a
full re-render. jetpacs re-serializes the whole tree on every push,
so a long REPL/agent transcript pays full freight each frame.
`jetpacs-scroll-here` already solves the *scroll* UX; this is purely a
**perf** optimization (append-only delta frames) and a large protocol
change. Park it until a transcript app makes the serialization cost
measurable.

## Tier D — explicitly do NOT adopt

Rejected because they serve vui's architecture, not ours. Recording
the *why* so they aren't re-proposed:

- **Local component instances + hooks** (`use-state`, `use-effect`,
  `use-ref`, hooks-as-call-order-identity). These manage retained
  local state across diffed renders. jetpacs has no instance tree and
  no Emacs-side diff; state is defvars + companion `id` state. Adding
  them would build a second, redundant state model.
- **Lifecycle** (`:on-mount`/`:on-update`/`:on-unmount`). There is no
  mount/unmount event in a pure-rebuild model. The nearest real needs —
  "run a load once" and "tear down on app unregister" — are served by
  B1's start-once semantics and `jetpacs-app-unregister`.
- **Emacs-side *state* reconciliation + cursor preservation.** The
  companion reconciles; C1 gives it the keys to do so correctly.
  Duplicating that diff in Emacs is wasted work. **Scope note
  (2026-07-16,
  [AUDIT-architecture-vui-vulpea.md](AUDIT-architecture-vui-vulpea.md)):**
  this rejection covers *state* reconciliation only. Comparing
  successive trees in Emacs to shrink the *wire payload* (C2 delta
  frames, background build reuse) is not duplicated work — Compose
  cannot diff what hasn't crossed the wire — and stays a
  measurement-gated roadmap item there, not a Tier-D rejection.
- **`vui-defcontext` provider/consumer.** Elisp dynamic variables
  (`defvar` + `let`) already *are* context — a deeply nested builder
  can read a `let`-bound dynamic var with zero new machinery. Adopt the
  *pattern* (document "bind a dynamic var to thread config/theme/owner
  through a builder tree"); do **not** add a context API. **Caveat:**
  the dynamic binding only spans the synchronous build pass — it is
  gone by the time a `jetpacs-async` loader's resolve callback or a
  timer fires, so loaders must capture what they need lexically (the
  problem vui's `vui-with-async-context` exists to solve).
- **A `jetpacs-defcomponent` macro.** Without instances or lifecycle it
  would only add prop-validation sugar over a plain `defun` (which is
  already how composites are written). Not worth the concept.

**Footnote — `:should-update` has a distant cousin.** vui's
`:should-update` skips a subtree's re-render. jetpacs rebuilds *every*
registered view on *every* `jetpacs-shell-push` (TUTORIAL §3), so
there's a latent perf question — memoize a builder when its inputs are
unchanged, or push only the current view. That's a jetpacs-internal
optimization (cf. `jetpacs-org-with-cache`), **not** a vui borrowing;
noted here only so the `:should-update` idea isn't mistaken for one.

**Footnote — dev tools.** vui ships an inspector, a state view, and a
timing profiler. jetpacs has *test-time* introspection
(`jetpacs-lint-spec`, `jetpacs-render-to-json`,
`jetpacs-test-visible-text`, `jetpacs-lint-views`) but no *live* "dump
the last pushed tree" or "which builder is slow" tool. A small
pretty-printer over the last push and a timing wrapper around the
builder loop would be cheap DX wins if push latency ever becomes a
question. Optional, unranked.

## The Kotlin renderer — where vui's reconciliation lessons land

The Tiers above are about the elisp *authoring* surface. But vui does
in **one** place what jetpacs splits across **two**: vui builds the
tree, reconciles it, and paints it, all inside Emacs; jetpacs has Emacs
*build* the tree and the Kotlin companion *reconcile and paint* it.
So vui's entire reconciliation family of lessons — keys, cursor/focus
preservation, `should-update`/memoization, error boundaries — **does
not map to the DSL at all. It maps to the Compose renderer**
([`SduiRenderer.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt)
and its node-family siblings). This is the other half of "use vui as
guidance," and arguably the higher-stakes half: a DSL wart costs an
author some typing; a reconciliation wart costs the *user* a lost edit
or a scroll jump.

**The frame.** Compose *is* the reconciler here — the analog of vui's
diff engine. The renderer's job is not to reimplement diffing (that
would be the Kotlin-side version of the Tier-D mistake); it is to give
Compose what a good reconciler needs: **stable identity, a skippable
model, and boundaries around failure.** vui had to build all three by
hand; jetpacs gets them from Compose *if* it feeds Compose correctly.
Today it half does.

**What the renderer already gets right** (so we don't "fix" it):

- **Seed-guarded local state** — `rememberSeeded(id, …)`
  ([`SduiInputNodes.kt:104`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiInputNodes.kt))
  adopts a new spec value *only* when the user hasn't diverged since
  the last seed, so a background re-push never stomps text
  mid-typing. This solves a problem vui's model doesn't even have
  (constant server re-pushes racing user input) — jetpacs is *ahead*
  of vui here, and the pattern should be guarded jealously.
- **Explicit reset identity** — `remember(id, revision)` (the slider,
  `SduiRenderer.kt:423`) makes "push a new id/revision to reset" a
  first-class, vui-`:key`-aligned mechanism.
- **Graceful degradation** — the `else` branch renders an unknown
  node's `children` (`SduiRenderer.kt:594`), never crashing on a node
  a companion predates. This is vui's "unknown renders its children,"
  arrived at independently.

The gaps, tiered like the DSL side:

### K1. `LazyColumn` item keys — the correctness core of C1

`lazy_column` renders `items(children.length()) { i -> … }`
([`SduiRenderer.kt:358`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt))
— **indexed by position, no `key`**. Compose therefore treats item
*identity* as *slot index*. On a structural push (insert a row at the
top, reorder, delete) every following item shifts index; Compose
reuses slot N's composition for a *different* node, and the id-keyed
`rememberSeeded` inside re-seeds against the wrong slot. Concretely:

- A text field being edited when a background push inserts a row above
  it loses focus / has its in-flight text re-seeded — the exact class
  of bug `rememberSeeded` was built to prevent, reintroduced one level
  up by the missing list key.
- Scroll position can't anchor across insert/delete (it jumps).
- `Modifier.animateItem()` (enter/exit/move animation) is impossible
  without stable keys, so lists pop instead of animate.

This is vui's sharpest **correctness** lesson (`:key`), and the fix
is almost entirely renderer-side: give `items` a
`key = { i -> childKey(i) }`. **The in-repo precedent already exists** —
`ReorderableList.kt:84` keys its `itemsIndexed` by
`"${pos}_${file}_$index"`; the general list path simply never adopted
it. The DSL affordance (C1's optional `:key`) is the *source* of a
good key, but even before that ships, the renderer can derive a
stable key from a stateful child's existing `id` (text_input,
collapsible, editor all carry one) and fall back to index only for
keyless leaves. So K1 splits into: (a) renderer derives keys from
existing `id`s **now** (no wire change, fixes the edit-loss bug); (b)
C1 adds explicit `:key` for rows that have no natural `id`.

### K2. Per-node error boundary — vui's `error-boundary`, Kotlin side

The `when (type)` dispatch has **no failure boundary** — the only
`try/catch` in the render path is a `NumberFormatException` guard on a
color/number parse (`SduiContentNodes.kt:330`). A composable that
throws while rendering one node (a `0f` aspect ratio, a negative size,
a throw from any sub-renderer) propagates up and takes down the
**whole surface** composition, not just the bad card. vui places
`error-boundary` at *subtrees* precisely so one failure is contained.
The Kotlin analog is cheap and purely renderer-side: wrap each node's
render in a boundary that, on throw, emits a small fallback (a muted
"⚠ node" chip) and reports it, so a single malformed node degrades to
a broken card instead of a blank screen. Pairs with the DSL's
`jetpacs-try` (A2) — same lesson, applied at the two ends of the wire.
Highest-value robustness item on the Kotlin side; no protocol change.

### K3. Recomposition skipping — vui's `should-update`, Kotlin side

Every push swaps the root `JSONObject` and the **entire** `SduiNode`
tree recomposes top to bottom: nodes read their values through
`optString`/`optInt`/etc. on a raw, non-`@Stable` `JSONObject`, so
Compose has **no skippable boundary** and cannot prove any subtree
unchanged. On a small screen this is invisible; on a large dashboard
pushed several times a second (a live agenda, a streaming REPL) it is
the jank ceiling — the renderer-side face of jetpacs rebuilding every
view on every push (the DSL-side footnote in Tier D). vui's answer was
`should-update`; Compose's equivalent is **a skippable model**: parse
the wire tree once into `@Immutable` node data classes (or hash each
subtree and short-circuit when the hash is unchanged) so Compose skips
recomposition of untouched subtrees. This is the largest item in the
doc and the least urgent — it is an architecture change to the
renderer's input model, worth a plan only once push latency is
*measured* to bite. Do **not** pre-optimize it.

### K-not: do not build a differ in Kotlin

The Kotlin-side twin of the Tier-D rejections: do not reimplement
tree diffing, a virtual DOM, or manual widget recycling in the
renderer. Compose already reconciles; K1–K3 are about *feeding it
correctly* (keys, boundaries, a skippable model), not replacing it.
A hand-rolled differ would fight the framework the same way an
Emacs-side hooks layer would fight jetpacs's pure-rebuild model.

## Recommendation

The work now spans two surfaces; sequence them by value-per-cost.

**Elisp / DSL track** — land **Tier A (A1 + A2)** and **Tier B1
(`jetpacs-async`)** first — all pure elisp, all through the proven
composite/helper mechanism, no companion release — since together they
close the ergonomic gaps vui most clearly exposes (semantic intent,
sub-tree resilience, async as a first-class shape). Hold A3 pending
real friction; treat C2 and both footnotes as unscheduled.

**Kotlin / renderer track** — the higher-stakes half, because these
are *user*-facing correctness/robustness, not authoring polish:

1. **K2 (per-node error boundary)** — cheapest, purely renderer-side,
   turns any surface-wide render crash into one broken card. Do first.
2. **K1a (derive `LazyColumn` keys from existing `id`s)** — fixes the
   edit-loss / focus-jump / scroll-jump bug on stateful lists with no
   wire change, reusing the `ReorderableList.kt` key pattern already in
   the tree. Then **K1b / C1** adds the explicit `:key` DSL affordance
   for keyless rows and unlocks `animateItem()`.
3. **K3 (skippable model)** — a renderer-input architecture change;
   plan it only when push latency on a large surface is *measured* to
   jank. Not now.

The two tracks are independent and can proceed in parallel: A1/A2/B1
touch only `emacs/core/`, K1/K2 only the Kotlin renderer.

## References

- vui.el — `C:\Users\caleb\vui.el` (README.org, docs/01-design-doc.org,
  docs/guide/, docs/examples/).
- jetpacs authoring surface — [WIDGETS.md](WIDGETS.md),
  [TUTORIAL.md](TUTORIAL.md),
  [`jetpacs-widgets.el`](../emacs/core/jetpacs-widgets.el) (composites
  at §Composites).
- jetpacs renderer — [`SduiRenderer.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt)
  (dispatch + `lazy_column` at ~L358), [`SduiInputNodes.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiInputNodes.kt)
  (`rememberSeeded`), [`ReorderableList.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/ReorderableList.kt)
  (the in-repo keyed-list precedent).
- Standing decisions — [ROADMAP.md](ROADMAP.md) (*rich server, thin
  client*), [CONTRIBUTING-NODES.md](CONTRIBUTING-NODES.md) (the
  three-part test for a new wire node),
  [API-STABILITY.md](API-STABILITY.md).
