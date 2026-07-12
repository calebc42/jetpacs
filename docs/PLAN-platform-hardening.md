# Plan: platform hardening — make jetpacs-core a foundation others build on

**UPDATE (2026-07-12): Phase G appended — reopened for one hardening pass.**
The plan below was completed 2026-07-09; **Phase G** (a foundation-owned
`~/.emacs.d/jetpacs/` root + a one-line `init.el` seam) is a new,
self-contained addition in the same "make jetpacs-core a foundation others
build on" thesis. It is ~90% *formalizing* patterns already shipped
(Glasspane's config-dir verbs, the `elisp/` adopt logic, the `after-init`
connect hook) plus one genuine latent-bug fix — the multi-app isolation
seams are clobberable top-level `setq`s. See **Phase G** at the bottom.
Phase G status: **in progress (2026-07-12)**.

**STATUS (2026-07-09): ALL PHASES DONE — this plan is complete.** Phase F
(the repo split) executed 2026-07-09: this repo is the standalone
jetpacs foundation + companion; Glasspane lives in
[its own repo](https://github.com/calebc42/glasspane) (pure elisp,
vendoring this repo as a submodule; test partition 63 core / 72 app).
The eabp → jetpacs rename landed the same day. Retained as the record
of how the platform was hardened. Originally produced from an audit of
`emacs/core/`, `jetpacs/src/main/java/com/calebc42/jetpacs/` (the
`:jetpacs` renderer), `test/widgets.golden`, and the existing plan docs.

**VERIFIED (2026-07-09):** full suite green on Emacs 30.1 — 135/135 main +
54/54 primitives, core-isolation guard OK, bundles current. The "5
pre-existing failures" cited in the phase records below (glasspane
org-table / vulpea-notes / detail) were an **environment artifact on the
2026-07-07 authoring machine** (org/vulpea version skew), not defects — they
pass on 30.1 and in CI. The green/failing counts in the phase notes are kept
as-written for historical record; this note is the correct baseline.

Phase E landed 2026-07-07 (Tasks 14–15) — multi-tenant hardening:
- Ownership machinery in `jetpacs-surfaces.el`: `jetpacs-current-owner`,
  `with-jetpacs-owner`, `jetpacs--claim` (warn / error-under-
  `jetpacs-strict-namespaces` on a cross-owner name clash, silent same-owner
  re-registration for live reload). Wired into `jetpacs-defaction`,
  `jetpacs-shell-define-view`, `jetpacs-settings-register-section`, and
  `jetpacs-defapp` (attributes its `:views`).
- `jetpacs-app-unregister` tears down an app's owned actions, views, settings
  sections, and UI-state/subscriptions in one call (live reload +
  uninstall). `jetpacs-settings-remove-section` and `jetpacs-on-state-change-clear`
  added to support it.
- 2 tests (collision + teardown); API-STABILITY + BUILDING-TIER1 (§7)
  updated. Suite 134 / 129 green (same 5 pre-existing); pure elisp, no
  Kotlin/wire change.

Phase D landed 2026-07-07 (Tasks 11–13) — the visualization ladder:
- Rung 1 `chart` (`SduiChart.kt`, elisp `jetpacs-chart`/`jetpacs-chart-series`):
  data-in, animated Canvas draw, closed `kind` enum
  (line/bar/area/sparkline), `on_point_tap` value injection, a11y summary.
- Rung 2 `canvas` (`SduiCanvas.kt`, elisp `jetpacs-canvas` + `jetpacs-draw-*`):
  a closed draw-op interpreter (line/rect/circle/path/text) in node-local
  coords, no animation/interaction, unknown ops skipped.
- Rung 3 `docs/CONTRIBUTING-NODES.md`: the Kotlin-contribution checklist +
  the "earns a curated primitive" rule (the alternative path, never
  required of app authors).
- Both nodes in `SDUI_NODE_TYPES` + `jetpacs-lint-node-types`; golden +2
  (53–54); SPEC §9 Visualization family added. Suite 132 / 127 green
  (same 5 pre-existing); `:jetpacs` Kotlin compiles clean.

Phase C landed 2026-07-07 (Tasks 5–10): `row`/`column`/`flow_row` take
`:spacing` and `:align` (splitter `jetpacs--children-and-opts` keeps
`(jetpacs-row a b c)` callers working); cross-axis alignment consumed in the
renderer; `box`/`surface`/`card` gain `:width`/`:height`/`:fill-fraction`/
`:border` (via `jetpacs-border`) through a shared Kotlin `containerModifier`;
`image` gains sizing + `aspect_ratio` + `content_scale`; new `slider`
input node (elisp `jetpacs-slider`, renderer `Slider`, in `SDUI_NODE_TYPES` +
`jetpacs-lint-node-types`). Task 10: grid = compose a `flow_row` of sized
cells (no dedicated node, per the accepted default). Golden +5 additive
lines (48–52); SPEC §9 updated. Suite 131 tests / 126 green (same 5
pre-existing); `:jetpacs` Kotlin compiles clean.

Phase B landed 2026-07-07 (**Task 4**): new `emacs/core/jetpacs-lint.el` —
`jetpacs-lint-spec` (validate a node tree: unknown `t`, malformed actions,
non-serializable / mistyped attrs), `jetpacs-render-to-json` (headless wire
round-trip so views are ERT-able with no phone), and `jetpacs-lint-sanitize-spec`
behind the opt-in `jetpacs-lint-on-push` (invalid node → inline `empty_state`
error, wired into `jetpacs-surface-update`). `jetpacs-lint-node-types` mirrors
`SDUI_NODE_TYPES`; the drift test `jetpacs-lint-types-cover-golden` fails if a
constructor ships a `t` the linter/renderer don't know. 7 tests added (131
total, all core green). Added to `build-bundle.el` + `core-load-test.el`.
The deferred Phase-A acceptance tests are now cheap follow-ups on this base
(the golden drift test already covers the elisp↔renderer node-type sync;
still open: a Kotlin-side `NODE_TYPES` unit test and an `API-STABILITY.md`
`fboundp` sweep).

Phase A landed 2026-07-07:
- **Task 1** — `jetpacs-api-version` (defconst "1.0.0") + `jetpacs-protocol-version`
  clarified in `jetpacs.el`, echoed in `hello`'s `client`; `docs/API-STABILITY.md`
  (frozen public-symbol list + the two rules); SPEC §3 "Versioning".
- **Task 2** — `SDUI_NODE_TYPES` in `SduiRenderer.kt` (32 types, kept beside
  the `when`), published in `session.welcome` as `node_types`
  (`JetpacsConnection.kt`); `jetpacs-node-supported-p` in `jetpacs.el` (permissive
  when catalog absent); SPEC §3 + §9 deltas.
- **Task 3** — the `else` fallback in `SduiRenderer.kt` (unknown container →
  its children, leaf → nothing, never a crash); SPEC §9/§12 now match.
- Tests: `jetpacs-node-supported-negotiation` + `jetpacs-api-version-bound` added
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
repo (finally executing the deferred split; the Gradle `:jetpacs`/`:app`
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
  root `jetpacs-core.el` / `glasspane.el` are **generated bundles** — never
  hand-edit. Regenerate: `emacs --batch -l emacs/build-bundle.el`.
- Tests: `emacs -Q --batch -l test/jetpacs-tests.el -f
  ert-run-tests-batch-and-exit`. Regenerate the wire golden only after an
  **intentional** wire change: `-f jetpacs-tests-regen-widget-golden`.
- **Command-dispatch boundary (SPEC §5):** the wire never names code to
  run. New actions are narrow, validated, and documented in SPEC.
- Wire-format additions need a Kotlin counterpart in
  `jetpacs/src/main/java/com/calebc42/jetpacs/` (renderer nodes live in
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

**Files:** `emacs/core/jetpacs.el`, `docs/SPEC.md`, a new
`docs/API-STABILITY.md`.

**Implementation:**

- `(defconst jetpacs-api-version "1.0.0")` in `jetpacs.el` — the elisp Tier 1
  API surface version (semver; bump minor on additive, major on breaking).
- `(defconst jetpacs-spec-version 1)` — the wire/vocabulary version, echoed
  in `session.hello`'s `client` object so a companion can log skew.
- `docs/API-STABILITY.md`: the frozen public-symbol list (the ~40
  constructors in `jetpacs-widgets.el` + the seams in
  [ARCHITECTURE.md](ARCHITECTURE.md)'s seam table), the `jetpacs--`
  double-dash = internal convention stated normatively, and the
  deprecation policy (a symbol is removed only on a major bump, one minor
  cycle after a `make-obsolete` marker).
- SPEC delta: §2 header notes `spec_version`; add a short "Versioning"
  subsection to §3.

**Pitfalls:** don't retro-freeze internals — audit `jetpacs-widgets.el`
exports first and mark anything not meant to be public with `--` before
publishing the list, or you've promised stability you don't want.

**Acceptance:** `jetpacs-api-version` / `jetpacs-spec-version` bound; a test
asserts every symbol named in `API-STABILITY.md` is `fboundp`; `hello`
carries `spec_version` (extend the handshake test).

### Task 2: Node-type negotiation (the linchpin)

**Goal:** a Tier 1 can detect whether the connected companion renders a
given node and branch to a fallback — the same courtesy triggers already
get via `device.trigger_types`. Without this, every Phase C/D addition
silently breaks older companions.

**Files:** Kotlin `JetpacsConnection` (welcome builder) + a node-catalog
constant near `SduiRenderer`; elisp `jetpacs.el` (welcome parsing ~line 290,
alongside `jetpacs-granted-p`); `docs/SPEC.md` §3 + §9.

**Implementation:**

- Kotlin: publish a `SduiRenderer.NODE_TYPES` set (the exact `when (type)`
  cases — keep it beside the `when` with a comment tying them together so
  they can't drift) and include it in `session.welcome` as
  `node_types: [...]`, under the existing `capabilities` grant (it rides
  the same `device` object, or a sibling — pick one and spec it).
- elisp: `(jetpacs-node-supported-p 'chart)` predicate mirroring
  `jetpacs-granted-p`, reading the welcome's `node_types`; returns `t`
  (permissively) when the companion sent no catalog at all (an older
  companion that predates this task — the constructor's own additive
  safety still applies).
- SPEC delta: §3 documents `node_types` in the welcome; §9 states that a
  client SHOULD gate newer nodes on it.

**Pitfalls:** the permissive-when-absent default is deliberate — a
companion from before this task sends no catalog and must not be treated
as "supports nothing." Support is *positive* knowledge only.

**Acceptance:** welcome round-trips `node_types`; `jetpacs-node-supported-p`
returns nil for an absent type when a catalog is present, `t` when no
catalog was sent; handshake test extended.

### Task 3: Unknown nodes degrade to their children (spec conformance)

**Goal:** close the gap between SPEC §12 ("unknown nodes render as their
children or nothing") and the renderer, which today renders **nothing** —
the top-level `when (type)` in `SduiRenderer.kt:436` has no `else`, so an
unknown *container* type silently swallows its whole subtree. This is the
exact failure Task 2 guards against, but the fallback must be graceful
even when a Tier 1 didn't gate.

**Files:** `jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt` (add the
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

**Files:** new `emacs/core/jetpacs-lint.el` (add to `build-bundle.el`
core-files + `core-load-test.el`); test helpers in `test/`.

**Implementation:**

- `jetpacs-lint-spec` walks a node tree and checks each node against a
  schema derived from the golden reference: `t` is a known type (from a
  table that must stay in sync with `widgets.golden` — assert this in a
  test), required attrs present, attr value types correct (a `color` is a
  hex string or a known token, `spacing` is a number, an action object
  has `action` xor `builtin`). Returns a list of `(path . problem)`; nil
  = clean.
- Wire the linter into the *serialize* path as an opt-in guard
  (`jetpacs-lint-on-push`, default nil in production, t in tests): when on,
  a node that fails lint is replaced in place by an inline `empty_state`
  error node naming the problem, so **one bad subtree degrades to a
  visible error instead of dropping the whole push**. This pushes the
  builder-level isolation in `jetpacs-shell` down to the node level.
- Headless render assertion helper: `jetpacs-render-to-json` (build a view,
  serialize, parse back) so ERT tests assert on structure without a
  companion. Fold the existing `jetpacs-render-buffer` fixtures onto it.

**Pitfalls:** the schema table is a maintenance liability if it drifts
from `widgets.golden`. Make the golden the source of truth — derive or
cross-check the linter's known-type/attr set against it in a test that
fails when a constructor is added without a schema entry.

**Acceptance:** `jetpacs-lint-spec` flags a `text` node missing `text`, a
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

**Files:** `emacs/core/jetpacs-widgets.el`; regen `widgets.golden`.

**Implementation:** add `:spacing` and `:scroll` keys to `jetpacs-row` /
`jetpacs-column` (and confirm `flow_row`). No Kotlin change. Regen golden
(intentional additive wire change).

**Acceptance:** golden lines for row/column carry the new attrs when
passed; renderer already consumes them (no Kotlin diff).

### Task 6: Cross-axis alignment on row/column

**Goal:** a `column` that centers its children, a `row` with top-aligned
children. Today `row` hardcodes `CenterVertically` and `column` defaults
`Start` (`SduiRenderer.kt:128`).

**Files:** `SduiRenderer.kt`, `jetpacs-widgets.el`; regen golden.

**Implementation:** `:align` on both, mapping to `horizontalAlignment`
(column) / `verticalAlignment` (row): `start|center|end`. Keep current
defaults when absent.

**Acceptance:** golden carries `align`; a centered column renders
centered (headless structural check + one Compose spot-check).

### Task 7: Explicit sizing on containers and images

**Goal:** box something to a fixed size; size an image. Today no
container takes width/height and `image` hardcodes `fillMaxWidth()`
(`SduiRenderer.kt:432`).

**Files:** `SduiRenderer.kt`, `jetpacs-widgets.el`; regen golden.

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

**Files:** `SduiRenderer.kt`, `jetpacs-widgets.el`; regen golden.

**Implementation:** `:border` as `{width, color}` (color = hex or token)
→ `Modifier.border(width.dp, resolveColor(color), shape)`, reusing the
node's existing `shape` where present.

**Acceptance:** golden carries `border`; an outlined surface renders a
stroke (Compose spot-check).

### Task 9: `slider` input

**Goal:** a continuous 0–1 (or ranged) input — `progress` is display-only,
so any "set a value" UI is currently blocked.

**Files:** new `SduiInputNodes.kt` entry + dispatch in `SduiRenderer.kt`;
`jetpacs-widgets.el` constructor; SPEC §9; regen golden.

**Implementation:** `{t:"slider", id, value, min?, max?, steps?,
on_change}` → Compose `Slider`, dispatching `on_change` with `value`
injected (the §9 value-carrying-callback rule). Register the node in
Task 2's `NODE_TYPES`.

**Pitfalls:** debounce `on_change` during drag (dispatch on
`onValueChangeFinished`, mirror to UI-state continuously) so a drag
doesn't flood the wire.

**Acceptance:** golden line; slider dispatches once on release with the
final value; `jetpacs-node-supported-p 'slider` reflects the catalog.

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

**Files:** new `jetpacs/src/main/java/com/calebc42/jetpacs/SduiChart.kt` +
dispatch; `jetpacs-widgets.el` (`jetpacs-chart`); SPEC §9; regen golden;
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
a point tap dispatches injected data; `jetpacs-node-supported-p 'chart`
gates a fallback (e.g. a `table` of the same series) on older companions.

### Task 12: `canvas` draw-ops interpreter (rung 2 — the escape hatch)

**Goal:** the elisp-only escape hatch for any visual no curated primitive
covers — a progress ring, a custom badge, a bespoke diagram. The Tier 1
computes geometry in elisp and emits a draw program; the Kotlin
interprets it and never changes again.

**Files:** new `SduiCanvas.kt` + dispatch; `jetpacs-widgets.el`
(`jetpacs-canvas` + op helpers); SPEC §9; regen golden; `NODE_TYPES`.

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
`jetpacs-widgets.el`; add a `widgets.golden` line + a lint schema entry
(Task 4); document in SPEC §9; state the "earns a curated primitive"
rule (Task 11) so contributions clear the same bar we hold ourselves to.
Cross-link from ARCHITECTURE.md's seam table.

**Acceptance:** a doc a contributor can follow end-to-end; the existing
`chart`/`slider` tasks serve as worked examples it points at.

---

## Phase E — multi-tenant hardening (parallel, no ordering dependency)

### Task 14: Ownership + collision detection across the registration surface

**Goal:** two coexisting Tier 1 apps can't silently clobber each other's
action, view, surface, or settings symbol. Today `jetpacs-defaction`
(`jetpacs-surfaces.el:118`) is a bare `puthash` (last-writer-wins,
silent); only `jetpacs-defapp` detects view collisions, and only as a
`message` (`jetpacs-apps.el:42`). Actions are the security boundary, so a
silent clobber is both a bug and a trust surprise (app B answering app
A's namespaced action).

**Files:** `emacs/core/jetpacs-surfaces.el` (`jetpacs-defaction`),
`emacs/core/jetpacs-shell.el` (`jetpacs-shell-define-view`),
`emacs/core/jetpacs-apps.el`, `emacs/core/jetpacs-settings.el`.

**Implementation:**

- Thread an owner token through every registration. Simplest ergonomic
  form: a dynamic `jetpacs-current-app` bound by `jetpacs-defapp` (or a
  `with-jetpacs-app` macro) that registrations capture. Record `(name .
  owner)` alongside each handler/view/section.
- On a re-registration by a *different* owner, `warn` (a real
  `display-warning`, not a swallowed `message`) — or refuse behind a
  `jetpacs-strict-namespaces` defcustom. Same-owner re-registration is the
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

**Files:** `emacs/core/jetpacs-apps.el` (+ the registries it must reach:
`jetpacs-surfaces.el`, `jetpacs-shell.el`, `jetpacs-settings.el`).

**Implementation:**

- Given the owner token from Task 14, `jetpacs-app-unregister` walks each
  registry and removes entries owned by the app (actions, views,
  drawer/top-action chrome, settings sections, `on-state-change`
  subscriptions), then `jetpacs-shell--schedule-repush`.
- Provide an `unload-feature` hook shim so `(unload-feature 'my-app)`
  routes through it.

**Pitfalls:** state subscriptions (`jetpacs-on-state-change`) and UI-state
keys are easy to miss and leak secrets/values — clear both by owner
prefix (there's already `jetpacs-ui-state-clear` by prefix in
`jetpacs-surfaces.el:175` to model on).

**Acceptance:** register an app with an action + view + state sub,
`jetpacs-app-unregister`, assert all three registries no longer hold its
entries and a repush was scheduled.

---

## Phase F — split the repo (last)

### Task 16: Extract the core into its own repository

**Goal:** two repos — a standalone **core platform** (the wire, the Tier 0
renderer, the `:jetpacs` Android library, `jetpacs-core.el`, the docs a
third-party writes against) and a separate **Glasspane reference-app**
repo (the org app, `:app` shell, `glasspane.el`). The core repo is what a
new maintainer adopts; Glasspane is one worked example that depends on it.

**Do last**, after A–E: extracting a *finished* core is a clean cut;
extracting a half-hardened one just moves the work.

**Implementation (sketch — detail at execution time):**

- The seams already exist: `emacs/core/` vs `emacs/apps/`, the
  `core-load-test.el` org-free tripwire, the Gradle `:jetpacs` (namespace
  `com.calebc42.jetpacs.core`) vs `:app` split, and the two host-agnostic
  seams (`JetpacsLaunch`, `JetpacsToolbars`). So this is packaging, not
  re-architecting.
- Core repo contents: `emacs/core/`, `jetpacs/` (the `:jetpacs` module) promoted
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
and the full test suite, and builds the `:jetpacs` library with no reference
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
   lives behind an opt-in `jetpacs-strict-namespaces` defcustom (default off).

## Suggested sequencing

A (1→2→3) then B (4) are the gate and must come first. C (5–10) and D
(11–13) then proceed on the negotiable, lintable base — C before D since
D leans on C's sizing/border for chart/canvas layout. E (14–15) runs in
parallel throughout. One commit per task, `feat:`/`fix:` style; regen
bundles + golden per the conventions above; build the app on any
Kotlin-touching task before committing.

---

## Phase G — foundation-owned root + one-line init seam (appended 2026-07-12)

**Why reopen a finished plan.** Doom Emacs raised the question: should
Jetpacs abstract module/dependency loading? The answer landed as a *middle
ground* — not Doom's takeover of `~/.emacs.d`, but a namespaced root Jetpacs
owns (`~/.emacs.d/jetpacs/`) plus a single `init.el` seam line, analogous to
`(load custom-file)`. If you use Jetpacs you are a Jetpacs user first, and
the foundation should *structurally* own the handful of things a good UX
depends on — without ever touching the user's own libraries or config.

Grounding (verified 2026-07-12) showed this is mostly formalization:
`~/.emacs.d/elisp/` is already a de-facto managed install dir
(`starter-init.el` adopts bundles into it, newest-wins); `custom-file` is
already parked safely at `~/.emacs.d/custom.el`; and `glasspane-config.el`
already implements the full `sync`/`ensure`/`load` + DO-NOT-EDIT + soft-merge
ownership contract. The one genuinely new thing is closing a latent bug.

### The two design axes (write these into contributor docs)

The design turns on separating two axes that were being conflated:

1. **File-ownership tier** — who owns the *bytes on disk*:
   `sync-overwrite` (regenerated freely, DO-NOT-EDIT banner) ·
   `create-once` (written once, never clobbered) · `user` (never touched).
   Reuses Glasspane's `sync`/`ensure`/`load` verbs verbatim.
2. **Invariant class** — whether a *running user form* can break it:
   **INVARIANT** = `defun` / registry-hash mutation / hook (setq-proof) ·
   **DEFAULT** = `defcustom` (intentionally `setq`-overridable).

**The axes are orthogonal.** "Jetpacs must own this" is encoded in *symbol
type*, independent of which file tier the code ships in. The verified kicker:
today's four isolation seams (`jetpacs-shell-view-filter-function`,
`-chrome-filter-function`, `-view-resolver-function`,
`jetpacs-settings-section-filter-function`) are plain top-level `setq`s
(`jetpacs-apps.el:192/198/200/212`), so `(setq jetpacs-shell-view-filter-function nil)`
anywhere after core loads silently defeats multi-app isolation. Putting the
*file* in the sync tier would not help — the vulnerability is a live symbol.
The fix is **lifecycle re-assertion**: `jetpacs-connect` already runs on
`after-init-hook` (`jetpacs.el:521-523`), i.e. after the user's whole init;
re-install the seam functions as its first step and a mid-init `setq` is
overwritten before the first frame is served.

### The target tree

```
~/.emacs.d/
├── init.el            [user]        one seam line (near top) + pasted (setq jetpacs-auth-token …)
├── custom.el          [user/once]   custom-file — STAYS here, OUTSIDE jetpacs/
└── jetpacs/           ══ FOUNDATION ROOT (replaces the mis-named elisp/) ══
    ├── jetpacs-init.el [sync]       entry file the seam loads; core self-heals it via VERSION
    ├── VERSION         [sync]       stamp core checks before rewriting jetpacs-init.el
    ├── apps.el         [once]       jetpacs-installed-bundles — user-editable app list
    ├── user.el         [once]       override escape hatch, loaded LAST (user wins)
    ├── lib/            [sync]       adopted flattened bundles, one require each
    │   ├── jetpacs-core.el
    │   └── glasspane.el
    └── apps/<id>/                   per-app config subtrees (promotes elisp/glasspane/)
        ├── *.el (managed) [sync]    jetpacs-app-config-sync overwrites (APP-MANAGED banner)
        └── *.el (seeds)   [once]    jetpacs-app-config-ensure creates once (merge-by-key)
```

The steady-state seam (first executable form in `init.el`):

```elisp
(load (expand-file-name "jetpacs/jetpacs-init.el" user-emacs-directory) t)
```

First run needs a self-adopting wrapper because the companion is a separate
UID and *cannot* write into the Emacs/Termux sandbox (`Onboarding.kt:64-74`)
— it only stages to `/sdcard`. So the wizard pastes a form that copies the
staged entry file in once, then loads it; thereafter core self-heals it via a
`VERSION` stamp, so the user's `init.el` never changes again.

### Two data-loss traps (both easy to get wrong — call them out)

1. **The installed-app list is `create-once` (`apps.el`), never `sync`.** If
   regenerated, a refresh wipes user-added third-party apps *and* installing a
   downloaded bundle would mean hand-editing a DO-NOT-EDIT file the companion
   can't restage. `apps.el` is the faithful successor of today's user-edited
   `dolist` (`starter-init.el:23`).
2. **`custom-file` stays outside `jetpacs/`, plus a new guard.** A phone
   Settings save is `customize-save-variable` rewriting whatever `custom-file`
   names and reporting success *blind to the dir's sync policy*
   (`jetpacs-settings.el:79-98`) — so `custom-file` under a sync dir = silent
   revert on every restart.

### Task 17: `jetpacs-config.el` — the foundation-owned root + app-config verbs

**Goal:** one core module owns the root paths and generalizes Glasspane's
config-dir contract, keyed by app-id.

**Files:** new `emacs/core/jetpacs-config.el` (add to `build-bundle.el`
`core-files` immediately after `core/jetpacs.el`).

**Implementation:** `jetpacs-root` / `jetpacs-lib-dir` defconsts;
`jetpacs-app-dir` (keyed by the same app-id as views `ID.*` and UI-state
`"ID."`); `jetpacs-app-config-{sync,ensure,load}` promoted from
`glasspane-config.el` — `sync` overwrites `(FILENAME . CONTENT)` files then
loads; `load` loads every `.el` in name order, error-guarded; `ensure` is
create-once then load. No per-app version/deps manifest (none exists today; a
`;; Jetpacs-Bundle: FEATURE KIND VER` header covers require-ordering).

**Acceptance:** batch ERT for `sync`/`ensure`/`load` (sync overwrites; ensure
seeds once then only loads; missing subtree is a no-op); bundle rebuilds.

### Task 18: Structural invariants + custom-file guard + api bump

**Goal:** make the isolation seams `setq`-proof and close the settings-save
data-loss window.

**Files:** `jetpacs-apps.el`, `jetpacs.el`, `jetpacs-settings.el`.

**Implementation:** add `jetpacs-before-connect-hook` (defvar in `jetpacs.el`)
and `(run-hooks 'jetpacs-before-connect-hook)` as the first form of
`jetpacs-connect`. Convert the four isolation `setq`s into an idempotent
`jetpacs--install-invariants`; call it at load time and register it on the
hook (so it re-asserts after all user init). Give the seam vars "internal —
do not set" docstrings (no defcustom, no Settings entry). Add a
`display-warning :error` (once) in `jetpacs-settings-save-variable` if
`custom-file` resolves under `jetpacs-root`. Bump `jetpacs-api-version`
1.2.0 → 1.3.0 (additive).

**Pitfalls:** the settings-section filter var loads *after* `jetpacs-apps.el`
in the bundle — keep the `with-eval-after-load 'jetpacs-settings` initial set,
and guard the installer's settings line with `boundp`.

**Acceptance:** a test that `setq`s a seam var to nil, runs
`jetpacs-before-connect-hook`, and asserts it's restored; the custom-file
guard fires for a path under `jetpacs-root` and not for `~/.emacs.d/custom.el`.

### Task 19: The seam — `jetpacs-init.el`, VERSION self-heal, starter-init rewrite

**Goal:** shrink `init.el` to one line; move the boilerplate into a
Jetpacs-owned, self-healing entry file.

**Files:** new `jetpacs-init.el` (staged asset + written under `jetpacs/`);
`jetpacs-apply-foundation-defaults` + the VERSION self-heal writer in core;
rewrite `docs/starter-init.el`; define the `apps.el` (`jetpacs-installed-bundles`)
format; on-device migration shim.

**Implementation:** load order inside `jetpacs-init.el` — `load-path += lib/`
→ adopt+`(require 'jetpacs-core)` (hardcoded, NOT in `apps.el`, so an app-list
edit can't disable the foundation) → load `apps.el` then adopt+require each
app → `jetpacs-apply-foundation-defaults` (the old starter-init touch/hygiene
body, now defcustom-backed) → `custom.el` → `user.el` → return to user init →
`after-init` connect re-asserts invariants. Migration shim (idempotent,
guarded by `jetpacs/lib/jetpacs-core.el` existing): copy `elisp/` bundles →
`lib/`, move `elisp/glasspane/` → `apps/glasspane/`, leave `custom.el` and
`elisp/` untouched.

**Acceptance:** on-device — fresh whole-init paste, BYO stanza-append, a phone
Settings save survives restart, a `user.el` override beats a default, and a
broken `user.el` does NOT stop the bridge (proves the after-init structural
boot). Batch-testable: the migration shim is idempotent.

### Task 20: Onboarding wizard

**Goal:** deliver the seam through the wizard's clipboard/stage model.

**Files:** `app/src/main/java/com/calebc42/jetpacs/Onboarding.kt`.

**Implementation:** stage `jetpacs-init.el` to `/sdcard/Documents` alongside
the core bundle; fresh path pastes an `init.el` whose first form is the seam;
collapse `byoSnippet` to the first-run seam form + token; drop the emitted
`custom-file` line (the entry file sets the default); "Get apps" card copy →
"add it to `~/.emacs.d/jetpacs/apps.el`". Build `:app` before committing.

**Acceptance:** the wizard writes both staged files; the pasted snippets load
cleanly on a fresh Emacs and a BYO Emacs.

### Task 21: Rebase Glasspane onto the core verbs (Glasspane repo)

**Goal:** the reference app uses the promoted foundation contract.

**Files:** Glasspane repo (`~/pkb/projects/Glasspane`) `glasspane-config.el`.

**Implementation:** call `(jetpacs-app-config-ensure "glasspane" glasspane-config--files)`
rooted at `(jetpacs-app-dir "glasspane")` instead of the hardcoded
`elisp/glasspane/`; wrap `jetpacs-defapp` + `config-ensure` in
`with-jetpacs-owner "glasspane"`; ship the bundle to `jetpacs/lib/glasspane.el`;
add `glasspane` to a sample `apps.el`. **Bundles must upgrade together.**

**Acceptance:** Glasspane's config seeds into `jetpacs/apps/glasspane/`; the
app registers and its views/chrome/settings scope correctly under the id.

### Sequencing

17 → 18 are the self-contained core increment (testable headless on the dev
machine, no device). 19 is the user-facing seam; 20 delivers it; 21 migrates
the reference app. 18's invariant fix is worth doing regardless of the
directory work — it fixes a real isolation bug. One commit per task; regen the
bundle (`emacs --batch -l emacs/build-bundle.el`) on any core touch; build
`:app` on the Kotlin task. Bundles upgrade together (per the multi-app
isolation contract).
