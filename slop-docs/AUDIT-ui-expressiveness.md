# Audit: UI expressiveness — granular Jetpack Compose control over the wire

**Status: Claude-authored reference audit for the hand rebuild. Not code, not
spec — the owner's spec and implementation supersede this document wherever
they diverge.** Produced 2026-07-18 by a three-reader audit: the ebp
SPEC/contract at `99d2895` (wire surface), the PoC Compose renderer at jetpacs
`@HEAD` `6795e5a` (implementation truth — its file:line cites are
archaeology), and the elisp authoring DSL at the same `@HEAD`. The synthesis
was checked against the full Jetpack Compose capability surface.

**How to read this on the rebuild path:** the PoC renderer is the frozen fork
— its "fixes" (Bucket 1, and the renderer items in Bucket 5) are notes for
the *future* companion, not work orders. The live, actionable-now half is the
SPEC/contract side: new keys, normative enum documentation, and the conflicts
registry, all governed by amendment #14's classification — styling keys are
cosmetic and safely additive; the flagged exceptions (`enabled`, date clamps,
`lazy_row` as a new node type) are named where they occur.

---

# ebp UI-Expressiveness Gap Analysis: Proposal Buckets

Philosophy frame (all buckets comply): closed-vocabulary data only; cosmetic keys = additive (ignored by old companions, SPEC.md:448-453); new node types negotiate via `node_types`; constraining keys need their own negotiation channel (amendment #14). Ranked by value-for-effort for a phone UI authored from Emacs.

---

## Bucket 1 — ROT FIXES: keys already on the wire that the renderer silently drops
**What it adds:** nothing to the wire — pure renderer repairs. Zero spec/negotiation cost, immediate author-visible wins.

| Key | Evidence | Fix |
|---|---|---|
| `text.color` | contract.json:56-69 + widgets.el jetpacs-text both carry it; renderer never consults resolveColor for text (SduiContentNodes.kt:68-100 gap: "NO color attribute") | pass through `resolveColor` |
| `text.max_lines` | schema + DSL carry it; Text() gap list says "no maxLines" | `maxLines` + `overflow=Ellipsis` params |
| 3-digit hex | lint accepts `#fff` (lint.el:372); parseHexColor accepts only 6/8 (SduiContentNodes.kt:335-346) → lint-clean color renders ambient | widen parseHexColor to 3/4/6/8 |
| role tokens in spans | resolveColor works for surface/icon/badge/chart/canvas/border, but rich_text + table spans go through parseHexColor only (SduiContentNodes.kt:145,147) | route span color/bg through resolveColor. **Conflict:** SPEC.md:484 prose says span colors are hex-only — amend prose (pure widening, hex still valid) |
| `mono` text style | renderer maps it (textStyleForName SduiContentNodes.kt:59-66); SPEC/goldens never mention it | document the 6th enum value |
| jetpacs-text `:syntax` / jetpacs-markup `:color` etc. | wire "text" row allows style+weight+color+selectable+max_lines+syntax together (lint.el:134-135); no constructor emits all | merge kwargs into jetpacs-text, keep jetpacs-markup as sugar |
| `resolveColor` missing tokens | omits on_secondary/on_tertiary/on_error/background/inverse* though ThemeBridge carries them (Kotlin notable #4) | add them |

**Safety:** cosmetic; the wire already promises these. **Effort: XS** (renderer + one elisp constructor). This is the documented recurring failure mode ("color/shape/elevation/fill were silently ignored for a long time", SduiRenderer.kt:217-219) — fixing it also motivates Bucket 2's central modifier builder.

---

## Bucket 2 — UNIVERSAL BOX-MODEL keys (extend the `"*"` row; build the missing central `buildModifier`)
**What it adds** (any node; today the `"*"` row is only scroll_here/key/dialog_style, contract.json:48-55, and padding is per-node opt-in single-dp):

- `pad` — object `{start,top,end,bottom,horizontal,vertical}` dp (specific wins over axis). Keep scalar `padding` untouched for compat. Compose: `Modifier.padding(start=…,…)`.
- `width`/`height`/`min_width`/`max_width`/`min_height`/`max_height` (dp) — promote from box/surface/card-only (containerModifier SduiRenderer.kt:663-675) to universal. Compose: `size/widthIn/heightIn` (widthIn already used internally, SduiScaffold.kt:152).
- `fill_fraction` universal (exists, box/surface/card/image only).
- `bg` — hex-or-role → `Modifier.background(color, shape)`. Fills the "box has no background" hole (box gap; SPEC per_node box).
- `corner` — number dp OR `{tl,tr,bl,br}` → `RoundedCornerShape`. Also becomes the shape `border` and `bg` clip to (today box border strokes a shape you can't set — RectangleShape fixed, SduiRenderer.kt:211 context).
- `border` `{width,color}` universal (exists on 3 nodes).
- `alpha` — 0–1 float → `Modifier.alpha`, clamped via existing safeFraction discipline (SduiRenderer.kt:622-624).
- `clip` — bool (clip content to corner shape).

**Deliberately excluded:** `margin` (Compose has none; pad suffices), universal `elevation` (stays surface's monopoly — see Conflicts), `offset` (see MUST-NOT).

**Compose mapping:** one `buildModifier(node)` replacing the three partial pipelines (baseModifier :141-143, containerModifier :663-675, WeightedChildren :781-796) — the Kotlin report's notable #1 says no central builder exists; this bucket is the reason to build one, and it structurally prevents future rot.

**Safety:** all cosmetic. Degradation: old companion ignores → prior spacing/plain background; content intact. One caveat: lint should warn on `alpha < 0.1` (using alpha to *hide* load-bearing content would make an ignoring companion show it — that usage pattern is constraining; the key itself is cosmetic).

**Effort: M** (schema `"*"` row + SPEC §9 prose + buildModifier refactor + lint numeric-class additions + a golden). Highest structural payoff.

---

## Bucket 3 — CONTAINER granularity
**What it adds:**

- `arrange` on row/column/flow_row — closed enum `start|center|end|space_between|space_around|space_evenly` → `Arrangement.*` (already imported, only spacedBy used — Kotlin notable #5). Coexists with `spacing` (arrange wins when both set; lint-warn the combo).
- `padding`/`pad` on row/column — today absent entirely (SPEC row/column gaps; workaround = box wrap or spacers). Falls out of Bucket 2 for free.
- `align_self` — per-child cross-axis override (string, same vocab as parent's `align`) → `Modifier.align` in scope; sits beside per-child `weight`.
- `align: "baseline"` — new value for row → `alignByBaseline`.
- lazy_column `spacing` (→ `Arrangement.spacedBy`) and `content_padding` (dp or pad-object → `contentPadding`) — today lazy_column has *zero* optional keys (contract.json:143-148).
- flow_row `align` (cross-axis of items in a run).
- `aspect_ratio` promoted universal (image-only today, safeAspect exists).
- box `alignment` completed to all 9 positions (only 6 mapped, SduiRenderer.kt:198-215) + enum finally documented in SPEC prose.

**Safety:** cosmetic. `space_between` ignored → old default `spacedBy(8)` start-packed: readable, just denser. `align_self` ignored → parent alignment. **Effort: S** — most values are "one import away" per the Kotlin report.

---

## Bucket 4 — TEXT granularity (beyond the 5-name style enum)
**What it adds** (text, rich_text node level, and spans where marked):

- `style` enum widened to the full M3 scale: `display_large|display|display_small|headline_large|headline|headline_small|title_large|title|title_small|body_large|body|body_small|label_large|label|label_small` (old 5 names stay as aliases). Degradation is already perfect: unknown style hits the renderer's `else bodyLarge` branch.
- `size` (sp number, clamped 8–96) — also on spans. Fixes rich_text "no span font size" and super/sub fixed 0.8em (SduiContentNodes.kt:162).
- `font_weight` — closed enum `normal|medium|semibold|bold` (NOT `weight` — see Conflicts).
- `italic` bool at node level (today requires a rich_text span).
- `align` on text/rich_text — `start|center|end|justify` → `textAlign` (same vocab as table `aligns`, SPEC.md:521-522 — reuse, don't invent a fifth alignment enum).
- `line_height` (float em) and `letter_spacing` (float sp) — clamped.
- `overflow` — `ellipsis|clip` (pairs with existing `max_lines`).
- `mono` bool at node level (exists as style value; a bool composes with other styles).
- span `style` and span role-token colors (Bucket 1 delivers tokens).

**Explicitly not:** `font_family` (arbitrary families = asset transfer + fingerprint surface; `mono` is the only family switch, matching text_input's `monospace`).

**Safety:** all cosmetic; ignored → current style rendering. **Effort: S-M** (Text params exist; schema + lint numeric class + jetpacs-text kwargs + SPEC finally enumerating `style` normatively — closing the "goldens are the de-facto vocabulary" gap, SPEC notable (a)).

---

## Bucket 5 — COLOR system unification (roles-first)
theme.set already pushes ~23 roles live-overlaid by ThemeBridge (buildEmacsColorScheme lerps surface_container tones) — so **every role token is theme-adaptive for free; hex is not**. Proposals:

- Everywhere a color is accepted, accept role-or-hex uniformly (Bucket 1 fixes spans; audit date_stamp/table for stragglers). DSL docstrings + lint should nudge roles over hex (lint info-level on hex where a standard role name is near, e.g. `#b3261e`≈error — optional).
- Promote `success`/`warning` from renderer-invented luminance-switched hex (SduiContentNodes.kt:320-321) to real pushed roles in theme.el's role alist; hardcoded pairs remain the fallback when the pushed palette lacks them. Cosmetic; old companion keeps its hex pair.
- Theme-role the renderer's literal hexes: chart fallback palette (SduiChart.kt:43-46) → derived from primary/secondary/tertiary + containers; connection-dot Nord greens/reds (SduiScaffold.kt:103-104) → success/error roles; legacy swipe green 0xFF4CAF50 (SduiRenderer.kt:278-287) → delete the legacy path (see Conflicts); editor diag warning 0xFFC08A00 (SduiInputNodes.kt:283) → warning role. Renderer-only, no wire change.
- New per-node keys: `divider.color`, `progress.color`/`progress.track_color`, `chip.color`, `button.color` (container role; content auto via on_* pairing), `tabs.indicator_color`, `image.tint` — all role-or-hex, all cosmetic, all M3 slot params that already exist.

**Safety:** cosmetic throughout. **Effort: S** (theme.el + renderer; per-node keys ride Bucket 6's schema touches).

---

## Bucket 6 — COMPONENT knobs (cherry-picked; renderer params mostly already there)
Cheap-first, per the Kotlin "capabilities present but unexposed" list:

- **divider**: `thickness` (dp), `color`, `inset` (dp), `vertical` (bool → VerticalDivider). Params "sit unused right there" (SduiRenderer.kt:386-388). Cosmetic, XS.
- **progress**: `color`, `track_color`, `thickness` (linear) / `size`+`stroke` (circular); document the `variant` enum + indeterminate rule (value absent = indeterminate) in SPEC prose. Cosmetic, XS.
- **surface**: `corner` (number dp) as the escape from the closed 3-shape enum (RoundedCornerShape(n.dp) "trivially parameterizable", SduiRenderer.kt:222-227); `shadow` (dp → shadowElevation, distinct from existing tonal `elevation`). Cosmetic, XS.
- **button**: `color` role, `icon` leading slot (schema already has `icon` — verify plumbing), `variant` enum finally documented normatively. **Defer `enabled`** — constraining: an ignoring companion leaves the button tappable and *over-acts*. If wanted, ship per amendment #14 with its own negotiation (e.g. a `caps` entry in welcome) or author-side pattern "omit on_tap when disabled" (degrades to non-tappable label — safe today).
- **image**: `corner` (clip), `tint` (role/hex), `alpha`, `placeholder_icon` (icon name shown pre-load/error). Cosmetic, S.
- **icon**: `rotate` (degrees, clamped), `mirror_rtl` (bool), `alpha`; fix contentDescription always-null (SduiRenderer.kt:475-493) by wiring existing `content_description`. Cosmetic, XS.
- **card**: give it `color`/`elevation`/`corner` = the surface trio. **Philosophy conflict** — see Conflicts table; recommendation: do it (owner wants granularity; degradation is the fixed ElevatedCard look, harmless).
- **table**: `col_widths` (list of dp-or-`{weight:n}`-or-`"auto"`), cell `bg` (role/hex), `striped` (bool). Cosmetic; ignored → intrinsic sizing (SPEC.md:522-523). M (custom Layout measuring changes).
- **collapsible**: `indent` (dp, default 24), `icon` (chevron name). Cosmetic, XS.
- **tabs**: `initial` default 0 documented; indicator/container colors (Bucket 5). XS.
- **scaffold**: `top_bar.color`, `top_bar.scroll` (`pin|collapse|none` → TopAppBar scrollBehavior — closed enum), `drawer.width_fraction` (0–1, default 0.75). Cosmetic, S.
- **toast**: `duration` (`short|long`). Cosmetic, XS.
- **chip**: honor the universal `badge` attribute (today "chips honor neither", Kotlin notable #8). Cosmetic, XS.
- **date/time_button**: add `padding` (only leaf inputs with zero layout keys) + `min`/`max` ISO clamps. Clamps are borderline-constraining (ignoring lets the user pick out-of-range → server must validate anyway, which SPEC philosophy already demands) → classify rate-shaping, safe with server-side re-validation noted in prose.
- **slider**: add `padding` (sole padding-less input, lint.el:193). XS.

**Effort: S overall if ridden on Bucket 2's schema pass.**

---

## Bucket 7 — ANIMATION-as-data (closed, companion-interpreted)
Animation is companion-owned today (chart "animated" SPEC.md:551; canvas "no animation... earn a curated primitive" SPEC.md:556-557). Honor that: authors get *requests*, never timelines.

- `animate_size` (bool, any container) → `Modifier.animateContentSize()`. Cosmetic; ignored → snap.
- `appear` — closed enum `fade|slide_up|slide_down|expand|none` (+ optional `duration_ms` clamped 0–1000) on any node newly entering a keyed lazy_column / AnimatedVisibility site. Cosmetic.
- `crossfade` (bool) on a container whose single child's `key` changes → `Crossfade`. Cosmetic.
- collapsible `animate:false` opt-out (currently AnimatedVisibility default spec hardcoded, SduiRenderer.kt:703-706). Cosmetic.
- **Not** on chart/canvas — both codebases carry explicit constraints against it (SduiChart.kt:36-37, SduiCanvas.kt:26-28). A future animated-drawing need = new negotiated node type, per the "earned primitive" rule.

**Safety:** cosmetic (worst case: no animation, or default animation). **Effort: M** (renderer state machinery), value moderate → ranked low.

---

## Bucket 8 — SCROLL/INSETS extras (smallest, mostly defer)
- `lazy_row` — new NODE TYPE (horizontal lazy list) → negotiate via node_types with `children` fallback = scroll-row (matches the tabs/month_grid ladder pattern, SPEC.md:568-576).
- `sticky` (bool) on section_header children of lazy_column → `stickyHeader`. Cosmetic (ignored → scrolls away).
- `scroll_here` gains optional `{position: "top"|"center"}`. Cosmetic.
- ime/insets: already handled (imePadding, consumeWindowInsets in scaffold body) — nothing to expose.

---

## MUST-NOT-TRANSFER
| Capability | Reason |
|---|---|
| Arbitrary modifier chains / modifier lists on the wire | open-ended language = code; violates the closed-vocabulary invariant |
| Lambdas, expressions, format strings with logic | wire is data-only, terminating |
| Custom Layout / measure policies | Turing-complete layout; table/flow_row/grid-via-flow_row are the curated answers (SPEC.md:533-534) |
| z-index / offset stacking games | invites overlay/spoofing UI (covering real controls); box+alignment covers legitimate cases |
| Gesture configs (swipe thresholds, velocities, long-press timings) | companion-owned feel; also the current px/dp inconsistency (±150f vs 80.dp vs 60.dp, SduiRenderer.kt:719/:262, SduiMonthGrid.kt:107) is a renderer bug to fix, not expose |
| Arbitrary font families / font assets | asset transfer + inconsistent device availability; `mono` bool is the ladder |
| Per-frame animation control (keyframes, easing curves as data) | timeline = program; closed appear/crossfade enums only |
| Gradients/brushes (incl. canvas) | listed as deliberate canvas gap; a gradient op would creep toward a drawing language — revisit as a single closed `{gradient:{from,to,angle}}` bg extension only if demanded |
| Semantics overrides beyond content_description | a11y spoofing surface |
| enabled:false as shipped-now universal key | constraining (old companion leaves control live); needs amendment-#14 negotiation first |

---

## CONFLICTS registry (name → resolution)
1. **`weight` name collision** — `weight` = flex share on any row/column child (contract.json:48-55 area; WeightedChildren :781-796). Text font weight MUST be `font_weight`. Never overload.
2. **`padding` scalar vs per-side** — `padding` is a lint numeric class (lint.el:266-271); changing its type breaks every author. Resolution: new `pad` object key; `pad` wins when both present; scalar stays forever.
3. **Four alignment vocabularies** (row top/center/bottom, column start/center/end, box 9-pos, table start/center/end — SPEC notable (c)). Resolution: freeze them as-is (renaming = constraining); all NEW align-ish keys (`align_self`, text `align`) reuse the parent's existing vocab or table's start/center/end. Document all four in one SPEC subsection.
4. **card fillMaxWidth + fixed look** — card hardcodes fillMaxWidth/12.dp corner/16.dp padding (SduiRenderer.kt:249-253) and SPEC deliberately gives card no color/shape/elevation while surface has all three. Adding the trio to card erodes the surface/card distinction. Resolution: accept erosion (owner's stated goal); wire `width`/`fill:false` must suppress the hardcoded fillMaxWidth (apply containerModifier *before* the default, or make default conditional). Also delete legacy `on_swipe` + its baked green "Cycle TODO" org-opinion (contract.json:167 vs SPEC.md:507-508 supersession) in the same pass.
5. **box border shape vs new `corner`** — border currently strokes RectangleShape on box; once `corner` exists, border/bg/clip must all use it. Define order: corner → clip → bg → border.
6. **`bg` key name** — already used for rich_text/table SPAN background (SPEC.md:484). Node-level `bg` (Bucket 2) is a different scope on different nodes; no wire ambiguity, but SPEC must state "span `bg` ≠ node `bg`". Alternative: name the node key `background`; recommend keeping `bg` for brevity + span consistency.
7. **`size` on icon vs text** — both per-node keys; no collision on the wire, but lint's numeric class already lists `size` — fine. Canvas text-op `size` unchanged.
8. **`spacing` vs `arrange`** — both control main axis. Resolution: `arrange` ≠ start ignores `spacing`; lint warns when both set.
9. **surface `shape` enum vs `corner`** — both set corner geometry. Resolution: `corner` (number) wins over `shape` (enum); `shape:"circle"` has no corner equivalent, keep it.
10. **`elevation` monopoly** — surface is "the ONLY node with author-set elevation" (SPEC per_node). Bucket 2 deliberately does NOT universalize it; Bucket 6 extends it to card only. Universal shadow via `shadow` key deferred.
11. **success/warning tokens** — client-invented hex pairs (SduiContentNodes.kt:320-321) vs theme.set roles. Resolution: pushed role wins; hex pair = fallback. Doc in SPEC §7.
12. **badge node vs badge attribute** (contract.json:375-385 vs SPEC.md:583-586; different renderings, Kotlin notable #8). Resolution: keep both, SPEC gets a disambiguation note; extend the *attribute* to chips.
13. **connection dot + queued count injected into top_bar title** (SduiScaffold.kt:98-125) — not spec-controllable; collides with any future `top_bar.color`/actions layout. Resolution: keep injection (companion chrome prerogative) but theme-role its colors (Bucket 5); optionally `top_bar.status_dot:false` opt-out (cosmetic).
14. **Undocumented enums as de-facto goldens** (text style, button variant, progress variant, surface shape, box alignment, editor line_numbers — SPEC notable (a)). Every bucket that touches one MUST land its normative enumeration in SPEC prose; otherwise new values have no compat story.
15. **fill default true is renderer-side** (widgets.el:157-159 comment) — Bucket 2's universal `width` on row/column must interact with the fillMaxWidth default the same conditional way as card (see #4).
16. **lint unknown-key = warning** (lint.el:197-206) — every new key must be added to jetpacs-lint-node-schema + numeric/color classes in the SAME commit as the constructor, or authors get spurious warnings; make this a checklist item in the amendment.

---

## Ranking (value-for-effort, phone UI from Emacs)
1. **Bucket 1** rot fixes — XS effort, unblocks promises already made
2. **Bucket 3** container granularity (arrange/padding/lazy_column spacing) — daily layout pain, S
3. **Bucket 2** universal box-model + central buildModifier — M, biggest structural win, prevents future rot
4. **Bucket 5** color roles-first unification — S, compounds the existing theme.set investment
5. **Bucket 4** text granularity — S-M
6. **Bucket 6** component knobs (cheap subset first: divider/progress/surface-corner/icon/slider-padding) — S
7. **Bucket 8** lazy_row + sticky (only negotiated node-type work here)
8. **Bucket 7** animation-as-data — M effort, nice-to-have

Everything above except `enabled`, date clamps (rate-shaping), and the lazy_row node type is **cosmetic-additive**: shippable without negotiation, degrading to today's rendering on old companions.
