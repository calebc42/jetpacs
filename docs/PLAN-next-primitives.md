# Plan: next primitives — an advisory ranking of the vocabulary's next rungs

**STATUS (2026-07-10): advisory, approved; Tier A IMPLEMENTED same day**
(A1–A5 additive attrs, A6 `tabs`, A7 `month_grid` — three commits, each
following the 8-step checklist in
[CONTRIBUTING-NODES.md](CONTRIBUTING-NODES.md): renderer →
`SDUI_NODE_TYPES` → constructor → lint → golden → SPEC → API-STABILITY
→ bundles. One wire delta from the sketch below: `month_grid` clamps
with `min_month`/`max_month`, since bare `min`/`max` are the slider's
lint-typed numeric attrs). Tiers B/C and the polish list remain
advisory; each item graduates to its own plan doc when picked up.
Everything here is protocol-version-neutral per SPEC §3: additive
attributes degrade silently, new nodes negotiate via `node_types`.

## Why

With the hardening phases done (composition knobs, the viz ladder) and
the org decoupling landed (`e51783b`, `55b5a23` — org Kotlin is zero),
the question is what the foundation should offer *next* so it looks
complete to a third-party app author. The audit behind this doc found
the untouched frontier is **discrete Material interaction widgets**:
none of tabs, pager, bottom sheet, search bar, badge, segmented button,
banner, avatar, carousel, stepper, rating, or skeleton exist or are
planned — and the M3 components for them (`ModalBottomSheet`, `TabRow`,
`HorizontalPager`, `SwipeToDismissBox`, `Badge`, `SegmentedButton`,
`SearchBar`, `TooltipBox`, `NavigationRail`) already ship in the
pinned BOM with **zero imports**. Nothing below adds a dependency.

**Method.** Every candidate is argued against CONTRIBUTING-NODES.md's
three-part test — (1) high-frequency, (2) interaction/polish-sensitive
(what static `canvas` can't give), (3) small **closed** parameterization
— ranked by fit to the target ecosystem first (org/PKM apps: lists,
agenda, capture, review), generic mobile polish second. Standing
decisions stay decided (`PLAN-platform-hardening.md`, resolved
decisions): no `lazy_grid` (compose with `flow_row`), `progress_ring`
deferred to `canvas`, no canvas animation/interaction, no new `chart`
kinds or attributes.

## Tier A — add now (in cost order)

### A1. `snackbar_action` on scaffold — the undo affordance

Undo-after-mutation (complete todo, archive heading, delete capture) is
the canonical mobile forgiveness pattern, and every mutating list app
needs it. Passes all three tests trivially: two keys, timed dismissal
and a11y announcement are native-only, `SnackbarResult` is currently
discarded (`SduiScaffold.kt` ~line 70).

```json
"snackbar": "Task archived",
"snackbar_action": {"label": "Undo", "on_tap": {action…}}
```

Deliberately an additive **sibling**, not a string|object union on
`snackbar` itself: the renderer reads `optString("snackbar")`, which
coerces an object to literal JSON text on old companions. The sibling
degrades perfectly — old companion shows the message, undo simply
unavailable.

### A2. `keyboard` attr on text_input

Any numeric/email/URL field currently gets the full QWERTY keyboard.
Closed enum `number | decimal | email | phone | uri`; absent/unknown →
text; `password` keeps precedence. IME selection is native-only; a few
lines on `KeyboardOptions`.

### A3. `style: "sheet"` on the `dialog.show` frame

Action pickers, capture menus, and the whole `completing-read`
minibuffer bridge instantly read native as bottom sheets — the dominant
modal idiom on mobile. One closed enum on an existing frame:
`style` ∈ `dialog` (default) | `sheet` | `sheet_full`, rendering the
same SDUI subtree in a `ModalBottomSheet`. Unknown/absent → today's
window Dialog: perfect degradation, no negotiation needed. Cheapest
item with the biggest perceived-quality jump.

### A4. `badge` attr on nav_item / drawer_item / icon / icon_button

Due-count on Agenda, inbox count on Capture, due-SRS count on Review —
counts on navigation are the PKM heartbeat and universal mobile
grammar. `"badge": 12` (number) or `""` (dot); rides `BadgedBox` with
its 99+ capping and a11y semantics. Cosmetic, never load-bearing —
silent degrade.

### A5. `swipe_start` / `swipe_end` on card

Swipe-to-complete / swipe-to-schedule is the core gesture of the todo
genre (orgzly-native's whole category). Per-side closed object, riding
`SwipeToDismissBox` (reveal affordance, threshold haptics, a11y custom
actions — maximally test-2):

```json
{"t": "card", "children": […],
 "swipe_start": {"icon": "check", "label": "Done", "color?": "#4CAF50",
                 "on_trigger": {action…}},
 "swipe_end":   {"icon": "schedule", "label": "Later", "on_trigger": {action…}}}
```

Full swipe past the threshold triggers; the client pushes the updated
list (the same contract as the existing single-action `on_swipe`, which
stays honored for compat). Old companions ignore both attrs — so the
BUILDING-TIER1 rule: swipe actions must also be reachable by tap/menu.

### A6. `tabs` node — the missing intra-view pattern

`view.switch` covers app-level navigation, but in-view section
switching has no answer: agenda Day/Week/Month, a note's
Outline/Content, and SRS review as a swipe-through pager. Swipe physics,
indicator animation, and nested-scroll coordination are the definition
of test 2. New node, negotiated:

```json
{"t": "tabs", "items": [{"label": "Day", "icon?": "…"}, …],
 "children": [<page0>, <page1>, …], "initial": 0,
 "scrollable": false, "pager_only": false,
 "on_change?": {action…, value = index}}
```

Client-side switching by default (zero round-trips, the `view.switch`
philosophy); `pager_only: true` drops the tab row (flashcard review:
pure swipe). Rides `PrimaryTabRow` + `HorizontalPager`. Unknown-node
degradation stacks all children — visible but wrong, so gate on
`node_types`; the canonical elisp fallback is a chip row + single child
(ship the recipe with the node).

### A7. `month_grid` node — the agenda calendar, "the `chart` of time"

The single most conspicuous missing primitive for an agenda-centric
ecosystem (agenda nav, journal, habit heat-map-lite, SRS forecast; the
Obsidian/Logseq converts of PLAN-pkm-conversion all expect one). Month
swipe, today/selection states, 44dp touch targets, and a11y grid
semantics are what a `flow_row` composition can't give. Same curated,
data-driven, closed shape as `chart`:

```json
{"t": "month_grid", "month": "2026-07",
 "marks": {"2026-07-10": {"dots": 3, "color?": "#…"}, …},
 "selected?": "2026-07-10", "min?": "2020-01", "max?": "2027-12",
 "on_day_tap": {action…, value = "YYYY-MM-DD"},
 "on_month_change": {action…, value = "YYYY-MM"}}
```

Month swipe is companion-local; `on_month_change` lets the client push
fresh marks, and marks for unfetched months are simply absent — never
blocking. No M3 piece (DatePicker is a picker, not an agenda grid):
custom Compose à la `SduiChart.kt`, the costliest item in the tier —
staged last, but the one that makes the foundation look complete to an
agenda-app author. Fallback recipe: `flow_row` of `fill_fraction`-sized
`box` cells with `on_tap` (works today, unpolished).

## Tier B — strong, wait for a second concrete demand

- **FAB speed-dial** — additive `items: [{icon, label, on_tap}]` inside
  scaffold's existing `fab` object; old companions show the plain FAB.
  Capture-heavy apps want "note / todo / journal" off one FAB. Verify
  the M3 FAB-menu component exists in the pinned BOM before committing.
- **Zoomable image** — `zoom: true` on `image`: tap opens a full-screen
  pinch-zoom lightbox, companion-local. Vault images and attached
  screenshots will demand it eventually; no M3 piece (custom
  `Modifier.transformable`), so wait for the demand.
- **Scaffold `search` slot** — `{hint, on_change?, on_submit}` rendering
  an M3 `SearchBar` in the top bar. Composable today as `text_input` +
  list; the curated win is the expand animation and suggestion overlay.
  Wait until a Tier 1 actually builds type-ahead.
- **`variant: "segmented"` on enum_list** — `SingleChoiceSegmentedButtonRow`
  when single-select and ≤ ~5 options; silent degrade to the FilterChip
  row. Pure aesthetics; add when the design gap is felt.
- **`tooltip` attr on icon_button** — rides `TooltipBox`, a11y-positive,
  one string. Waits: long-press is contended surface, and top-bar
  actions can get tooltips zero-wire from their existing `label` (see
  Polish below).

## Tier C — capability-coupled (§10 split; the widget side is mostly free)

- **Voice capture** (flagged app wish). Capability
  `audio.record {max_s?, format?} → {file, duration_ms}` — the
  companion owns the mic UI; Emacs is on-device, so a shared-storage
  path returns. Widget side: nothing new — a `button` starts it, the
  result lands as an org attachment link. Playback: `audio.play {file}`
  / `audio.stop` fire-and-forget (MediaPlayer, no media3 dep); a
  curated scrub-bar `audio_player` node waits for real demand — a
  play/pause `icon_button` + `progress` composes the interim.
- **Camera capture** — `camera.capture {mode: "photo"} → {file}`.
  `intent.start` can't return results, so this earns a capability; the
  existing `image` node displays the result. Serves journal photos,
  attachments, and QR below.
- **QR** — split per doctrine. *Display* is static-drawable → a
  **canvas recipe** (elisp encodes to `rect` ops; also solves pairing
  display). *Scan* needs the camera → capability `qr.scan → {text}`;
  FOSS constraint means an embedded ZXing-core decode — a real
  dependency, flag it explicitly against the pure-data preference.
- **Inbound share target for images/files** (flagged app wish) — not a
  capability (inbound, not an effector): the companion declares the
  share target and delivers `share.received {mime, text?, file?}`
  through the §5–§6 queue machinery, gated on a registered handler
  (the allowlist rule holds). Needs its own small SPEC section; no
  widget vocabulary change.
- **Speech-to-text** — `stt.listen → {text}` via `SpeechRecognizer`;
  availability and FOSS-ness vary by ROM. Document degradation to
  `cap-unsupported`; keep it last.

## Rejects (and the recipe that serves instead)

- **banner / inline alert** — fails test 2 (static): `card` + `icon` +
  `button`. → BUILDING-TIER1 recipe.
- **avatar** — fails 2 and 3: `image` sizing covers it; an
  initials-avatar is a `canvas` circle + text. → recipe.
- **skeleton/shimmer** — fails test 1 *in this architecture*: surfaces
  are offline-first cached, so there is no loading state to skeleton.
  Reject outright.
- **rating stars** — fails 1 here (SRS grading is buttons); a `row` of
  `icon_button`s composes it. → recipe.
- **stepper-as-node (numeric ±)** — fails 2:
  `row [icon_button "-", text, icon_button "+"]`; A2's
  `keyboard: "number"` covers direct entry. → recipe.
- **carousel** — fails 1 (media galleries are rare in PKM) and 3 (M3
  Carousel's item-sizing strategy is an open styling surface); A6's
  pager covers swipe browsing.
- **ListItem** — a styling convenience: leading/trailing/overline slots
  are an open surface (fails 3); `card`/`row` compose it. → recipe.
- **video player** — heavy dep (media3), battery gate, fails 1;
  `intent.start` to the user's player. → recipe.
- **map** — FOSS/no-Google constraint + heavy dep; `intent.start` with
  a `geo:` URI. → recipe.
- **webview / html node** — violates the plain-data trust boundary
  (§5) categorically. Never.
- **markdown node** — conversion is the client's job: org/md →
  `rich_text` spans, already the pattern.
- **tag-input node** — `enum_list` with `allow_add` + `multi_select`
  already is one.
- **timeline / accordion / labeled divider** — compose (`column` +
  `canvas` rail; `collapsible`; `row [divider, text, divider]`).
  → recipes.
- **lazy_grid, progress_ring, canvas animation, chart growth** —
  previously decided; unchanged.

## Zero-wire renderer polish (no vocabulary change, no negotiation cost)

1. **Honest pull-to-refresh:** clear the spinner on the next
   `surface.update` for the surface instead of the blind 1200 ms timer
   (keep the timer as fallback).
2. **Adaptive width:** at ≥600 dp render `bottom_bar` items as a
   `NavigationRail` and the drawer permanent — same wire data;
   tablet/foldable ready.
3. **view.switch transitions:** cross-fade/slide on view swaps +
   predictive back.
4. **Top-bar action tooltips:** actions already carry `label` beside
   `icon` — long-press `TooltipBox` from existing data.
5. **Bottom-bar overflow:** > 5 `nav_item`s → a "More" overflow instead
   of cramped tabs.
6. **Coil polish:** crossfade + themed placeholder/error states on
   `image`.
7. **Haptics pass:** consistent feedback on swipe thresholds,
   long-presses, and reorder pickup.

## Sequencing

A1 + A2 are each an afternoon in existing files; then A3, A4, A5; the
two genuinely new nodes (A6 `tabs`, A7 `month_grid`) last, each as its
own plan doc. Zero-wire polish items are fair game any time — they
need no spec work and no bundle coordination.
