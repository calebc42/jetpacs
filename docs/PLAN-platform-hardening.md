# Plan: platform hardening — make eabp-core a foundation others build on

**STATUS (2026-07-07): Phases A + B DONE; Phase C next.** Produced from an
audit of `emacs/core/`, `eabp/src/main/java/com/calebc42/eabp/` (the
`:eabp` renderer), `test/widgets.golden`, and the existing plan docs.

Phase B landed 2026-07-07 (**Task 4**): new `emacs/core/eabp-lint.el` —
`eabp-lint-spec` (validate a node tree: unknown `t`, malformed actions,
non-serializable / mistyped attrs), `eabp-render-to-json` (headless wire
round-trip so views are ERT-able with no phone), and `eabp-lint-sanitize-spec`
behind the opt-in `eabp-lint-on-push` (invalid node → inline `empty_state`
error, wired into `eabp-surface-update`). `eabp-lint-node-types` mirrors
`SDUI_NODE_TYPES`; the drift test `eabp-lint-types-cover-golden` fails if a
constructor ships a `t` the linter/renderer don't know. 7 tests added (131
total, all core green). Added to `build-bundle.el` + `core-load-test.el`.
The deferred Phase-A acceptance tests are now cheap follow-ups on this base
(the golden drift test already covers the elisp↔renderer node-type sync;
still open: a Kotlin-side `NODE_TYPES` unit test and an `API-STABILITY.md`
`fboundp` sweep).

Phase A landed 2026-07-07:
- **Task 1** — `eabp-api-version` (defconst "1.0.0") + `eabp-protocol-version`
  clarified in `eabp.el`, echoed in `hello`'s `client`; `docs/API-STABILITY.md`
  (frozen public-symbol list + the two rules); SPEC §3 "Versioning".
- **Task 2** — `SDUI_NODE_TYPES` in `SduiRenderer.kt` (32 types, kept beside
  the `when`), published in `session.welcome` as `node_types`
  (`EabpConnection.kt`); `eabp-node-supported-p` in `eabp.el` (permissive
  when catalog absent); SPEC §3 + §9 deltas.
- **Task 3** — the `else` fallback in `SduiRenderer.kt` (unknown container →
  its children, leaf → nothing, never a crash); SPEC §9/§12 now match.
- Tests: `eabp-node-supported-negotiation` + `eabp-api-version-bound` added
  (124 tests, all core green). Bundle regenerated. **Pre-existing** 5
  failures remain (glasspane org-table/vulpea-notes/detail — confirmed
  identical with these changes stashed; org/vulpea env skew, not this work).
- Follow-ups deferred from acceptance: the Kotlin `SduiRendererNodeTypesTest`
  drift guard and an `API-STABILITY.md`-parsing `fboundp` test both need
  test-harness scaffolding — do them alongside Phase B's Task 4 (which builds
  the elisp validator/lint infrastructure anyway).

**Framing (2026-07-07): this is the handoff track.** The owner is
optimizing for *adoptability by a future maintainer*, not personal
ownership — the intent is to harden the core, then hand it off / let a
more qualified person fork it. Bias every task toward a standalone core,
complete docs, and clean seams a stranger can onboard against. The
end-state adds **Phase F: split the repo** — extract the hardened core
into its own repository, leaving Glasspane as a separate reference-app
repo (finally executing the deferred split; the Gradle `:eabp`/`:app`
boundary and the org-free-by-contract core already make the core cleanly
extractable). Do Phase F **last**, so the new maintainer inherits a
finished platform.

## Why this plan exists

Today the only Tier 1 author is us. Everything below is what changes when
the builder is *someone else*: cross-version robustness, multi-tenant
isolation, and third-party testability. The motivating end-state is a
concrete promise:

> **A third party expresses any UI as an elisp tree of existing
> primitives, and never has to write Kotlin. The reference companion's
> Kotlin is a complete, versioned, negotiable vocabulary. Shipping Kotlin
> is the *alternative* (a welcome contribution), never the happy path.**

That promise is unreachable until the vocabulary is *versioned* and
*negotiable* — so this plan is ordered by dependency, not severity.

```
Phase A (the gate)        #1 API/spec version + #2 node negotiation
Phase B (safety)          #4 spec validator + headless render harness
Phase C (composition)     6a — close the parameterization gaps
Phase D (visualization)   6b — the curated/canvas/contribution ladder
Phase E (multi-tenant)    #3 ownership/collision + #5 teardown  (parallel)
```

Phases A→D are strictly ordered: **you must not grow the vocabulary
(C, D) until it is negotiable (A) and lintable (B)**, or every addition
silently breaks older installs. Phase E has no ordering dependency and
can land alongside any other phase.

## Repo conventions (read first — carried from PLAN-primitive-completeness.md)

- Edit sources under `emacs/core/` (and `emacs/apps/` for Tier 1). The
  root `eabp-core.el` / `glasspane.el` are **generated bundles** — never
  hand-edit. Regenerate: `emacs --batch -l emacs/build-bundle.el`.
- Tests: `emacs -Q --batch -l test/eabp-tests.el -f
  ert-run-tests-batch-and-exit`. Regenerate the wire golden only after an
  **intentional** wire change: `-f eabp-tests-regen-widget-golden`.
- **Command-dispatch boundary (SPEC §5):** the wire never names code to
  run. New actions are narrow, validated, and documented in SPEC.
- Wire-format additions need a Kotlin counterpart in
  `eabp/src/main/java/com/calebc42/eabp/` (renderer nodes live in
  `SduiRenderer.kt` + `SduiContentNodes.kt` / `SduiInputNodes.kt`). If the
  Kotlin can't land in the same pass, the elisp side must be
  additive-only (unknown attrs/nodes are ignored by the client) and the
  task notes the follow-up.
- Build the app before committing a Kotlin-touching task:
  `gradlew :app:assembleDebug`.

---

## Phase A — the gate: version and negotiate the vocabulary

### Task 1: Version the API and the spec

**Goal:** a third party (and the negotiation in Task 2) has a number to
check. Today the wire says `v: 1` but there is no elisp API version and no
spec/vocabulary version anywhere (grep of `emacs/core/` finds none).

**Files:** `emacs/core/eabp.el`, `docs/SPEC.md`, a new
`docs/API-STABILITY.md`.

**Implementation:**

- `(defconst eabp-api-version "1.0.0")` in `eabp.el` — the elisp Tier 1
  API surface version (semver; bump minor on additive, major on breaking).
- `(defconst eabp-spec-version 1)` — the wire/vocabulary version, echoed
  in `session.hello`'s `client` object so a companion can log skew.
- `docs/API-STABILITY.md`: the frozen public-symbol list (the ~40
  constructors in `eabp-widgets.el` + the seams in
  [ARCHITECTURE.md](ARCHITECTURE.md)'s seam table), the `eabp--`
  double-dash = internal convention stated normatively, and the
  deprecation policy (a symbol is removed only on a major bump, one minor
  cycle after a `make-obsolete` marker).
- SPEC delta: §2 header notes `spec_version`; add a short "Versioning"
  subsection to §3.

**Pitfalls:** don't retro-freeze internals — audit `eabp-widgets.el`
exports first and mark anything not meant to be public with `--` before
publishing the list, or you've promised stability you don't want.

**Acceptance:** `eabp-api-version` / `eabp-spec-version` bound; a test
asserts every symbol named in `API-STABILITY.md` is `fboundp`; `hello`
carries `spec_version` (extend the handshake test).

### Task 2: Node-type negotiation (the linchpin)

**Goal:** a Tier 1 can detect whether the connected companion renders a
given node and branch to a fallback — the same courtesy triggers already
get via `device.trigger_types`. Without this, every Phase C/D addition
silently breaks older companions.

**Files:** Kotlin `EabpConnection` (welcome builder) + a node-catalog
constant near `SduiRenderer`; elisp `eabp.el` (welcome parsing ~line 290,
alongside `eabp-granted-p`); `docs/SPEC.md` §3 + §9.

**Implementation:**

- Kotlin: publish a `SduiRenderer.NODE_TYPES` set (the exact `when (type)`
  cases — keep it beside the `when` with a comment tying them together so
  they can't drift) and include it in `session.welcome` as
  `node_types: [...]`, under the existing `capabilities` grant (it rides
  the same `device` object, or a sibling — pick one and spec it).
- elisp: `(eabp-node-supported-p 'chart)` predicate mirroring
  `eabp-granted-p`, reading the welcome's `node_types`; returns `t`
  (permissively) when the companion sent no catalog at all (an older
  companion that predates this task — the constructor's own additive
  safety still applies).
- SPEC delta: §3 documents `node_types` in the welcome; §9 states that a
  client SHOULD gate newer nodes on it.

**Pitfalls:** the permissive-when-absent default is deliberate — a
companion from before this task sends no catalog and must not be treated
as "supports nothing." Support is *positive* knowledge only.

**Acceptance:** welcome round-trips `node_types`; `eabp-node-supported-p`
returns nil for an absent type when a catalog is present, `t` when no
catalog was sent; handshake test extended.

### Task 3: Unknown nodes degrade to their children (spec conformance)

**Goal:** close the gap between SPEC §12 ("unknown nodes render as their
children or nothing") and the renderer, which today renders **nothing** —
the top-level `when (type)` in `SduiRenderer.kt:436` has no `else`, so an
unknown *container* type silently swallows its whole subtree. This is the
exact failure Task 2 guards against, but the fallback must be graceful
even when a Tier 1 didn't gate.

**Files:** `eabp/src/main/java/com/calebc42/eabp/SduiRenderer.kt` (add the
terminal `else`), `docs/SPEC.md` §12.

**Implementation:**

- Add `else -> { node.optJSONArray("children")?.let {
  RenderChildren(it, surfaceId, revision, dispatch) } }`. An unknown
  container degrades to a plain column of its contents; an unknown leaf
  still renders nothing. No crash either way (already true).
- SPEC delta: §12 states the reference behavior precisely — unknown node
  **with** `children` renders them; without, renders nothing.

**Pitfalls:** do NOT log-spam per unmatched node during a big push (a new
vocabulary on an old client would flood). One debug-level line per
distinct unknown `t` per surface is plenty.

**Acceptance:** a `{t:"totally-new", children:[text]}` node renders the
text; a `{t:"totally-new"}` leaf renders nothing; neither throws. Add to
the Compose UI test set if one exists, else a headless assertion via
Task 4's harness.

---

## Phase B — safety: make composition testable and unbreakable

### Task 4: Spec validator + headless render harness

**Goal:** a Tier 1 author validates a node tree *before the wire* and
unit-tests their views with no phone attached; a malformed node fails at
lint time, never blanks a surface on the device.

**Files:** new `emacs/core/eabp-lint.el` (add to `build-bundle.el`
core-files + `core-load-test.el`); test helpers in `test/`.

**Implementation:**

- `eabp-lint-spec` walks a node tree and checks each node against a
  schema derived from the golden reference: `t` is a known type (from a
  table that must stay in sync with `widgets.golden` — assert this in a
  test), required attrs present, attr value types correct (a `color` is a
  hex string or a known token, `spacing` is a number, an action object
  has `action` xor `builtin`). Returns a list of `(path . problem)`; nil
  = clean.
- Wire the linter into the *serialize* path as an opt-in guard
  (`eabp-lint-on-push`, default nil in production, t in tests): when on,
  a node that fails lint is replaced in place by an inline `empty_state`
  error node naming the problem, so **one bad subtree degrades to a
  visible error instead of dropping the whole push**. This pushes the
  builder-level isolation in `eabp-shell` down to the node level.
- Headless render assertion helper: `eabp-render-to-json` (build a view,
  serialize, parse back) so ERT tests assert on structure without a
  companion. Fold the existing `eabp-render-buffer` fixtures onto it.

**Pitfalls:** the schema table is a maintenance liability if it drifts
from `widgets.golden`. Make the golden the source of truth — derive or
cross-check the linter's known-type/attr set against it in a test that
fails when a constructor is added without a schema entry.

**Acceptance:** `eabp-lint-spec` flags a `text` node missing `text`, a
bad color, an action with both `action` and `builtin`; a lint-guarded
push of a bad node emits the inline error node; a drift test fails if a
golden line has no schema entry.

---

## Phase C — 6a: close the composition gaps

Grounding from the renderer audit — the vocabulary is more parameterized
than `widgets.golden` shows, so several of these are "expose in elisp,"
not "new Kotlin." Every task here is additive and MUST land after Phase A
(gate) so older companions degrade instead of breaking.

### Task 5: Expose existing layout knobs in elisp

**Goal:** `row`/`column` already honor `spacing` and `scroll` in the
renderer (`SduiRenderer.kt:111,127`), but the elisp constructors don't
emit them. Surface the capability.

**Files:** `emacs/core/eabp-widgets.el`; regen `widgets.golden`.

**Implementation:** add `:spacing` and `:scroll` keys to `eabp-row` /
`eabp-column` (and confirm `flow_row`). No Kotlin change. Regen golden
(intentional additive wire change).

**Acceptance:** golden lines for row/column carry the new attrs when
passed; renderer already consumes them (no Kotlin diff).

### Task 6: Cross-axis alignment on row/column

**Goal:** a `column` that centers its children, a `row` with top-aligned
children. Today `row` hardcodes `CenterVertically` and `column` defaults
`Start` (`SduiRenderer.kt:128`).

**Files:** `SduiRenderer.kt`, `eabp-widgets.el`; regen golden.

**Implementation:** `:align` on both, mapping to `horizontalAlignment`
(column) / `verticalAlignment` (row): `start|center|end`. Keep current
defaults when absent.

**Acceptance:** golden carries `align`; a centered column renders
centered (headless structural check + one Compose spot-check).

### Task 7: Explicit sizing on containers and images

**Goal:** box something to a fixed size; size an image. Today no
container takes width/height and `image` hardcodes `fillMaxWidth()`
(`SduiRenderer.kt:432`).

**Files:** `SduiRenderer.kt`, `eabp-widgets.el`; regen golden.

**Implementation:**

- `:width` / `:height` (dp) and `:fill-fraction` (0.0–1.0 →
  `fillMaxWidth(fraction)`) on `box` / `surface` / `card`.
- `image`: `:width` / `:height` / `:aspect-ratio` / `:content-scale`
  (`fit|crop|fill`). Drop the hardcoded `fillMaxWidth` in favor of an
  explicit default only when no size given.

**Pitfalls:** sizing + `weight` conflict — a fixed width inside a
weighted row is contradictory; document that explicit size wins and
weight is ignored when both are set (mirrors Compose).

**Acceptance:** golden carries the attrs; a 120dp image renders at 120dp
(Compose spot-check); a sized box measures correctly.

### Task 8: Border / stroke on surface/box/card

**Goal:** an outlined container (a very common look with no primitive
today).

**Files:** `SduiRenderer.kt`, `eabp-widgets.el`; regen golden.

**Implementation:** `:border` as `{width, color}` (color = hex or token)
→ `Modifier.border(width.dp, resolveColor(color), shape)`, reusing the
node's existing `shape` where present.

**Acceptance:** golden carries `border`; an outlined surface renders a
stroke (Compose spot-check).

### Task 9: `slider` input

**Goal:** a continuous 0–1 (or ranged) input — `progress` is display-only,
so any "set a value" UI is currently blocked.

**Files:** new `SduiInputNodes.kt` entry + dispatch in `SduiRenderer.kt`;
`eabp-widgets.el` constructor; SPEC §9; regen golden.

**Implementation:** `{t:"slider", id, value, min?, max?, steps?,
on_change}` → Compose `Slider`, dispatching `on_change` with `value`
injected (the §9 value-carrying-callback rule). Register the node in
Task 2's `NODE_TYPES`.

**Pitfalls:** debounce `on_change` during drag (dispatch on
`onValueChangeFinished`, mirror to UI-state continuously) so a drag
doesn't flood the wire.

**Acceptance:** golden line; slider dispatches once on release with the
final value; `eabp-node-supported-p 'slider` reflects the catalog.

### Task 10 (decision): grid vs. flow_row

**Goal:** fixed-column grids (e.g. a launcher). Decide whether
`flow_row` + sizing (Tasks 5–7) already covers it or a `lazy_grid` is
worth the permanent surface.

**Implementation:** first try to build the launcher home grid with
`flow_row` + fixed-width cards. If it reads well, **close this as
won't-do** and document flow_row as the grid idiom. Only add
`{t:"lazy_grid", columns, children}` if the flow approach visibly fails
(uneven last row, no column alignment). Bias: don't add surface you can
compose.

**Acceptance:** either a documented flow_row grid recipe in
BUILDING-TIER1.md, or a `lazy_grid` node with golden + negotiation entry.

---

## Phase D — 6b: the visualization ladder

Three rungs, chosen by *frequency × polish-sensitivity*, all sharing
Phase A negotiation and Phase B linting. The governing rule (write it into
the doc so the vocabulary can't bloat):

> **A pattern earns a curated Kotlin primitive only when it is (a)
> high-frequency, (b) polish/interaction-sensitive (wants animation, tap,
> a11y), and (c) has a small, stable parameterization. Everything else
> stays on `canvas`.**

### Task 11: Curated `chart` primitive (rung 1 — the happy path)

**Goal:** a third party emits *data*, not draw ops, and gets an animated,
tappable, theme-reactive chart. This is where ~95% of real visualization
need lands and where the polish lives.

**Files:** new `eabp/src/main/java/com/calebc42/eabp/SduiChart.kt` +
dispatch; `eabp-widgets.el` (`eabp-chart`); SPEC §9; regen golden;
`NODE_TYPES`.

**Implementation:**

- Wire shape: `{t:"chart", kind:"line|bar|area|sparkline",
  series:[{label?, color?, points:[{x?, y}]}], x_labels?, y_range?,
  on_point_tap?}`. Data-in, theme-out: series colors default to the
  Material categorical ramp; axis/grid use theme tokens.
- Compose: native drawing with `Canvas`/Compose primitives *internally*,
  but the surface a Tier 1 sees is semantic. Animate series on first
  appearance; `on_point_tap` dispatches with the point's data injected;
  set `contentDescription` from a server-suppliable summary for a11y.
- Keep `kind` a small closed enum — resist "just one more chart type";
  each is permanent surface.

**Pitfalls:** don't smuggle styling knobs in one at a time until `chart`
becomes a charting library. If a request needs a knob outside this shape,
that's a signal it belongs on `canvas`, not a new `chart` attr.

**Acceptance:** golden line; a 2-series line chart renders and animates;
a point tap dispatches injected data; `eabp-node-supported-p 'chart`
gates a fallback (e.g. a `table` of the same series) on older companions.

### Task 12: `canvas` draw-ops interpreter (rung 2 — the escape hatch)

**Goal:** the elisp-only escape hatch for any visual no curated primitive
covers — a progress ring, a custom badge, a bespoke diagram. The Tier 1
computes geometry in elisp and emits a draw program; the Kotlin
interprets it and never changes again.

**Files:** new `SduiCanvas.kt` + dispatch; `eabp-widgets.el`
(`eabp-canvas` + op helpers); SPEC §9; regen golden; `NODE_TYPES`.

**Implementation:**

- `{t:"canvas", width, height, ops:[...]}` where each op is closed,
  data-only: `{op:"line", x1,y1,x2,y2, color?, stroke?}`,
  `{op:"rect", x,y,w,h, color?, fill?, stroke?, radius?}`,
  `{op:"circle", cx,cy,r, color?, fill?, stroke?}`,
  `{op:"path", points:[[x,y]...], color?, fill?, stroke?, closed?}`,
  `{op:"text", x,y, text, color?, size?, align?}`. Colors are hex or
  token; coords in the node's own `width`×`height` space (or add a
  `viewbox` if you want scaling — decide in review).
- **Deliberately no animation and no interaction sublanguage.** The
  moment a canvas use wants those, it has earned a curated primitive
  (rung 1). Say so in the docstring.
- Unknown ops are skipped, never fatal (mirror the §11 `on_fire`
  closed-vocabulary discipline).

**Pitfalls:** this is a mini-interpreter — it MUST go through the Task 4
linter (op names, required coords) or a malformed op list blanks the
node. Add canvas ops to the lint schema in the same PR.

**Acceptance:** golden line; a hand-written ring (arc via path or
circle+rect mask) renders; a bad op is skipped, not fatal; the linter
flags a missing coord.

### Task 13: Document the Kotlin-contribution path (rung 3 — the alternative)

**Goal:** make "add a curated primitive in Kotlin" a well-lit *optional*
path, so the vocabulary can grow from outside without the maintainers
being a bottleneck — while keeping elisp-only the default.

**Files:** `docs/BUILDING-TIER1.md` (a new "Extending the vocabulary"
section) or a dedicated `docs/CONTRIBUTING-NODES.md`.

**Implementation:** a checklist for a new node: add the `when (type)`
case; register it in `NODE_TYPES` (Task 2); add a constructor to
`eabp-widgets.el`; add a `widgets.golden` line + a lint schema entry
(Task 4); document in SPEC §9; state the "earns a curated primitive"
rule (Task 11) so contributions clear the same bar we hold ourselves to.
Cross-link from ARCHITECTURE.md's seam table.

**Acceptance:** a doc a contributor can follow end-to-end; the existing
`chart`/`slider` tasks serve as worked examples it points at.

---

## Phase E — multi-tenant hardening (parallel, no ordering dependency)

### Task 14: Ownership + collision detection across the registration surface

**Goal:** two coexisting Tier 1 apps can't silently clobber each other's
action, view, surface, or settings symbol. Today `eabp-defaction`
(`eabp-surfaces.el:118`) is a bare `puthash` (last-writer-wins,
silent); only `eabp-defapp` detects view collisions, and only as a
`message` (`eabp-apps.el:42`). Actions are the security boundary, so a
silent clobber is both a bug and a trust surprise (app B answering app
A's namespaced action).

**Files:** `emacs/core/eabp-surfaces.el` (`eabp-defaction`),
`emacs/core/eabp-shell.el` (`eabp-shell-define-view`),
`emacs/core/eabp-apps.el`, `emacs/core/eabp-settings.el`.

**Implementation:**

- Thread an owner token through every registration. Simplest ergonomic
  form: a dynamic `eabp-current-app` bound by `eabp-defapp` (or a
  `with-eabp-app` macro) that registrations capture. Record `(name .
  owner)` alongside each handler/view/section.
- On a re-registration by a *different* owner, `warn` (a real
  `display-warning`, not a swallowed `message`) — or refuse behind a
  `eabp-strict-namespaces` defcustom. Same-owner re-registration is the
  normal live-reload case and stays silent.
- Optionally validate that an app's action/view/surface names begin with
  its declared `:namespace`, turning the SPEC §5 naming *convention* into
  an enforced *contract*.

**Pitfalls:** live reload (`eval-buffer`) re-registers constantly — the
same-owner-silent rule is what keeps that noise-free. Don't warn on it.

**Acceptance:** registering two different owners on one action name
warns; same owner is silent; namespace validation (if built) rejects a
mis-prefixed name.

### Task 15: App-scoped teardown / unload

**Goal:** unloading or reloading a Tier 1 tears down its actions, views,
settings, and state subscriptions atomically — no stale handlers
accumulate across live-dev reloads, and an app can be genuinely removed.

**Files:** `emacs/core/eabp-apps.el` (+ the registries it must reach:
`eabp-surfaces.el`, `eabp-shell.el`, `eabp-settings.el`).

**Implementation:**

- Given the owner token from Task 14, `eabp-app-unregister` walks each
  registry and removes entries owned by the app (actions, views,
  drawer/top-action chrome, settings sections, `on-state-change`
  subscriptions), then `eabp-shell--schedule-repush`.
- Provide an `unload-feature` hook shim so `(unload-feature 'my-app)`
  routes through it.

**Pitfalls:** state subscriptions (`eabp-on-state-change`) and UI-state
keys are easy to miss and leak secrets/values — clear both by owner
prefix (there's already `eabp-ui-state-clear` by prefix in
`eabp-surfaces.el:175` to model on).

**Acceptance:** register an app with an action + view + state sub,
`eabp-app-unregister`, assert all three registries no longer hold its
entries and a repush was scheduled.

---

## Phase F — split the repo (last)

### Task 16: Extract the core into its own repository

**Goal:** two repos — a standalone **core platform** (the wire, the Tier 0
renderer, the `:eabp` Android library, `eabp-core.el`, the docs a
third-party writes against) and a separate **Glasspane reference-app**
repo (the org app, `:app` shell, `glasspane.el`). The core repo is what a
new maintainer adopts; Glasspane is one worked example that depends on it.

**Do last**, after A–E: extracting a *finished* core is a clean cut;
extracting a half-hardened one just moves the work.

**Implementation (sketch — detail at execution time):**

- The seams already exist: `emacs/core/` vs `emacs/apps/`, the
  `core-load-test.el` org-free tripwire, the Gradle `:eabp` (namespace
  `com.calebc42.eabp.core`) vs `:app` split, and the two host-agnostic
  seams (`EabpLaunch`, `EabpToolbars`). So this is packaging, not
  re-architecting.
- Core repo contents: `emacs/core/`, `eabp/` (the `:eabp` module) promoted
  to a standalone Gradle project with its own minimal host harness for
  testing, `test/`, and `docs/{SPEC,ARCHITECTURE,BUILDING-TIER1,
  API-STABILITY,CONTRIBUTING-NODES}.md` + the relevant PLAN docs.
- Glasspane repo: `emacs/apps/`, `app/`, its own docs, and a dependency
  declaration on a tagged core release (git submodule or a published
  bundle — decide at execution).
- Keep `build-bundle.el` in the core repo; Glasspane's build pulls the
  core bundle in.
- History: prefer `git filter-repo` to preserve per-file history in each
  new repo over a flat copy.

**Acceptance:** the core repo byte-compiles, passes `core-load-test.el`
and the full test suite, and builds the `:eabp` library with no reference
to Glasspane or `:app`; the Glasspane repo builds against the tagged core.

## Resolved decisions (2026-07-07 — owner accepted all defaults)

The owner deferred these to the recommended defaults (explicitly not
wanting to make domain calls they're unsure of). Locked:

1. **Task 10 (grid):** compose with `flow_row`; add `lazy_grid` only if it
   visibly fails.
2. **Task 11 curated set:** `chart` only for v1; `progress_ring` must earn
   its place later or fall to `canvas`.
3. **Task 12 canvas coords:** node-local `width`×`height`; no `viewbox` in
   v1.
4. **Task 14 strictness:** warn on cross-owner collision; a refuse mode
   lives behind an opt-in `eabp-strict-namespaces` defcustom (default off).

## Suggested sequencing

A (1→2→3) then B (4) are the gate and must come first. C (5–10) and D
(11–13) then proceed on the negotiable, lintable base — C before D since
D leans on C's sizing/border for chart/canvas layout. E (14–15) runs in
parallel throughout. One commit per task, `feat:`/`fix:` style; regen
bundles + golden per the conventions above; build the app on any
Kotlin-touching task before committing.
