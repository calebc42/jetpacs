# Plan: renderer reconciliation — keys, defensive rendering, skippable model

**STATUS (2026-07-15): drafted; K0 + K2 + K1a in progress.** The Kotlin
/ Compose-renderer track from
[AUDIT-vui-dsl-guidance.md](AUDIT-vui-dsl-guidance.md) (§"The Kotlin
renderer"). These are *user*-facing correctness/robustness, not
authoring polish, so this track carries the higher stakes. Files:
[`SduiRenderer.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt)
and siblings.

## Frame (do not skip)

jetpacs splits across the wire what vui does in one place: Emacs
**builds** the tree, Compose **reconciles and paints** it. So vui's
reconciliation family — keys, cursor/focus preservation,
`should-update`, error boundaries — is a renderer concern, not a DSL
one. **Compose *is* the reconciler.** The job is to feed it what a good
reconciler needs — stable identity, a skippable model, contained
failure — **not** to reimplement diffing in Kotlin (that is the
Kotlin-side twin of the audit's Tier-D rejections: no virtual DOM, no
manual recycling).

What the renderer already gets right and must not regress: seed-guarded
local state (`rememberSeeded(id, …)`,
[`SduiInputNodes.kt:104`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiInputNodes.kt))
— it already beats vui at the re-push-vs-user-input race; `(id,
revision)` reset identity; unknown-node → render-children degradation
(`SduiRenderer.kt:594`).

## K0 — `success` / `warning` color tokens (tiny, additive)

`resolveColor` (`SduiContentNodes.kt:301`) maps M3 tokens but has **no
`success` or `warning`** case, so the DSL track's `jetpacs-success` /
`jetpacs-warning` (A1) have no adaptive color. Add two cases:

```kotlin
"success" -> Color(if (dark) 0xFF7CC77C else 0xFF2E7D32)  // theme-aware green
"warning" -> Color(if (dark) 0xFFE0B252 else 0xFFB26A00)  // amber
```

(or derive from the scheme if a palette source exists). Additive and
degradation-safe: an older companion never sees the token (the DSL only
emits it), and if it did it falls through to `parseHexColor` →
`Unspecified` → ambient color, so text still renders. This is the
DSL track's one dependency; land it first so A1 is theme-correct.
**No SPEC change** (color values are a closed companion concern), but
note the two token names in [WIDGETS.md](WIDGETS.md)'s color list.

## K2 — defensive rendering (the reachable error boundary)

**Honesty first:** Compose has no clean React-style error boundary — an
exception thrown *during composition* can corrupt the slot table, and
try/catch around a `@Composable` call is unsafe. So the architecturally
correct translation of vui's `error-boundary` is **prevent the throw at
the source**, because in jetpacs's model the crash vector is *malformed
numeric wire data hitting a Compose precondition*, not arbitrary logic.
Colors are already safe (`parseHexColor` returns `Unspecified`, never
throws). The real throw sites, all "bad number → Compose precondition":

| Site (`SduiRenderer.kt`) | Precondition | Bad input |
|---|---|---|
| `aspectRatio(fraction)` ~L566 | `> 0` | `0`, negative |
| `width(dp)` / `height(dp)` ~L564, containerModifier ~L613 | `>= 0` | negative |
| `fillMaxWidth(fraction)` ~L571, L614 | `(0, 1]` | `0`, `>1`, negative |
| `size(w, h)` spacer ~L387 | `>= 0` | negative |

### K2 implementation

1. **Safe modifier helpers** in `SduiRenderer.kt` (pure, JVM-testable
   logic split from the composable application):

   ```kotlin
   internal fun safeAspect(v: Double): Float? = v.toFloat().takeIf { it.isFinite() && it > 0f }
   internal fun safeFraction(v: Double): Float? = v.toFloat().takeIf { it.isFinite() && it > 0f && it <= 1f }
   internal fun safeDp(v: Int): Int? = v.takeIf { it >= 0 }
   ```

   Apply each only when it returns non-null; otherwise skip the modifier
   (render unsized rather than crash). Route the image node,
   `containerModifier`, and `spacer` through these.

2. **A root guard** in `MainActivity` around the surface render
   (`RenderChildren(spec…)`, ~L276): this cannot catch composition
   throws either, but it *can* validate the top-level spec is a
   well-formed object before rendering and fall back to a "This screen
   couldn't render — Emacs pushed a malformed view" message that keeps
   Settings/pairing reachable, instead of a blank surface. Belt to K2's
   braces.

3. **Lint parity** — extend elisp `jetpacs-lint-spec` and the Kotlin
   `WireGoldenConformanceTest` to flag out-of-range numeric attrs
   (`aspect_ratio <= 0`, `fill_fraction ∉ (0,1]`, negative dp) so a bad
   view is caught in CI, not on-device. This is where the "boundary"
   truly pays off: prevention + detection.

### K2 tests (JVM)

`safeAspect`/`safeFraction`/`safeDp` unit tests (0, negative, >1, NaN,
valid) in `jetpacs/src/test/…`. No instrumentation needed — the point
of splitting the logic out is JVM-testability.

## K1 — `LazyColumn` stable keys

`lazy_column` renders `items(children.length()) { i -> … }`
(`SduiRenderer.kt:358`) — **position-keyed**. On a structural push
(insert/reorder/delete) Compose reuses slot N's composition for a
different node; the id-keyed `rememberSeeded` inside re-seeds against
the wrong slot, so an in-flight edit / focus / scroll on a shifted row
is lost — the exact bug the seed guard was built to prevent, one level
up. The in-repo fix pattern already exists: `ReorderableList.kt:84`
keys `itemsIndexed`.

### K1a — derive keys from existing `id`s (no wire change)

1. A pure helper (JVM-testable), unique-by-construction:

   ```kotlin
   /** Stable, unique per-child keys for a lazy list. Prefer an explicit
    *  `key`, then a stateful child's `id`; fall back to a namespaced
    *  index for keyless leaves. Collisions (author error: duplicate id)
    *  are disambiguated with an index suffix so Compose never sees a
    *  duplicate key (which would crash). */
   internal fun lazyChildKeys(children: JSONArray): List<String> {
       val seen = HashMap<String, Int>()
       return (0 until children.length()).map { i ->
           val c = children.optJSONObject(i)
           val base = c?.optString("key").orEmpty().ifEmpty { c?.optString("id").orEmpty() }
               .let { if (it.isEmpty()) "i:$i" else "k:$it" }
           val n = seen.getOrDefault(base, 0)
           seen[base] = n + 1
           if (n == 0) base else "$base#$n"
       }
   }
   ```

2. In the `lazy_column` block, precompute `val keys =
   lazyChildKeys(children)` and use
   `items(count = children.length(), key = { keys[it] })`. Keyless
   leaves keep index keys (status quo); stateful rows now keep their
   identity across structural pushes — fixing edit/focus/scroll loss.

**Interaction with `scroll_here`:** unchanged — the scroll target is
still found by the `scroll_here` flag's index; keys only change how
Compose recycles item compositions.

### K1b / C1 — explicit `:key` DSL affordance + `animateItem()`

Once K1a proves out, add the wire affordance for rows with no natural
`id`, following the CONTRIBUTING-NODES.md 8-step checklist:

1. renderer already reads `key` (K1a's helper prefers it) →
2. add `"key"` to the allowed attrs / lint typing →
3. elisp: optional `:key` on `jetpacs-card` / `jetpacs-row` /
   `jetpacs-list-item` →
4. `jetpacs-lint-spec` accepts it →
5. golden line →
6. SPEC §9 note (additive attr, degrades to position-keying) →
7. API-STABILITY entry →
8. bundles.

Then enable `Modifier.animateItem()` on the keyed child so
insert/remove/move animate instead of popping — the visible payoff of
having identity. Gate nothing: `animateItem` is a companion-local
render detail.

**This is C1 in the audit** — but the correctness core is K1a
(renderer, no wire), and only the ergonomic affordance is a wire
change. Sequence accordingly.

## K3 — skippable model (largest, least urgent)

Every push swaps the root `JSONObject`; the whole `SduiNode` tree
recomposes because nodes read a raw, non-`@Stable` `JSONObject` and
Compose has no skippable boundary. On a large dashboard pushed rapidly
this is the jank ceiling — the renderer face of jetpacs rebuilding
every view each push. vui's answer was `should-update`; Compose's is a
**skippable model**: parse the wire tree once into `@Immutable` node
data classes (or hash each subtree and short-circuit when the hash is
unchanged), so Compose skips untouched subtrees.

This is an architecture change to the renderer's *input model* (touches
every node family and the golden/conformance tests), so it earns its
own plan and is worth doing **only when push latency on a real large
surface is measured to jank** — not pre-emptively. Deferred; recorded
here so the reasoning survives.

## Sequencing & verification

1. **K0** (tokens) — unblocks DSL A1; ~6 lines.
2. **K2** (safe modifiers + root guard + lint parity) — cheapest
   user-facing win; one throwing node no longer blanks the surface.
3. **K1a** (keys from ids) — fixes the edit/focus/scroll-loss bug.
4. **K1b / C1** (explicit `:key` + `animateItem`) — the wire affordance
   and animation payoff.
5. **K3** — deferred until measured.

**Verification.** Pure helpers (`safe*`, `lazyChildKeys`) get JVM unit
tests under `jetpacs/src/test/…` and run with
`./gradlew :jetpacs:testDebugUnitTest` (the existing conformance tests
live there). Composition behavior (focus survives a structural push,
items animate) is on-device acceptance — add to
`docs/TESTING-ON-DEVICE.md`. Keep `SduiRendererNodeTypesTest` green
(no `when`-case / `SDUI_NODE_TYPES` drift; K0–K1 add no node types).

## References

- [AUDIT-vui-dsl-guidance.md](AUDIT-vui-dsl-guidance.md) — §"The Kotlin
  renderer" (K1/K2/K3).
- [PLAN-dsl-ergonomics.md](PLAN-dsl-ergonomics.md) — the DSL track;
  A1's `success`/`warning` depend on **K0** here.
- [CONTRIBUTING-NODES.md](CONTRIBUTING-NODES.md) — the 8-step checklist
  for K1b's wire attr. [SPEC.md](SPEC.md) §9.
