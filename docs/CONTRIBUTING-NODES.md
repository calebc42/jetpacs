# Extending the node vocabulary (the Kotlin path)

**You almost certainly don't need this.** The point of the platform is
that a Tier 1 expresses any UI in Elisp from the existing primitives —
compose `row`/`column`/`box`/`surface`/`card` with sizing and borders, and
for anything pixel-computed reach for `canvas` (draw ops) or the curated
`chart`. Writing Kotlin is the *alternative*, not the happy path. Read
[BUILDING-TIER1.md](BUILDING-TIER1.md) first; try `canvas` second.

This doc is for the rarer case: you want to add a **new curated node** to
the reference companion — a native, polished, reusable widget that earns
its place in the frozen vocabulary. Contributions are welcome; they hold
to the same bar the maintainers do.

## When a pattern earns a curated primitive

A new curated node is justified only when the pattern is:

1. **high-frequency** — many Tier 1s want it, not a one-off;
2. **polish- or interaction-sensitive** — it wants animation, touch, or
   accessibility semantics that `canvas` can't give (canvas is
   deliberately static and non-interactive); and
3. **small and stable in its parameterization** — a closed `kind` enum and
   a handful of data attributes, not an open-ended styling surface.

If it fails any of these, it belongs on `canvas`. Resisting "just one more
attribute" on `chart` is how the vocabulary stays a foundation instead of
a widget zoo. Every curated node is permanent surface and permanent
maintenance.

## The checklist

Adding a node type `foo`:

1. **Renderer** — add a `"foo" -> SduiFoo(node, baseModifier, dispatch)`
   case to the `when (type)` in
   [`SduiRenderer.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt),
   and write `SduiFoo` (a sibling file like `SduiChart.kt` for anything
   substantial). Value-carrying callbacks dispatch through
   `dispatchWithValue` so the current value lands in `args.value` (SPEC §9).
2. **Negotiation** — add `"foo"` to `SDUI_NODE_TYPES` in the same file (the
   set sits right beside the `when` so they can't drift). This is what puts
   `foo` in the welcome's `node_types` so a client can detect support.
3. **Constructor** — add `jetpacs-foo` to
   [`jetpacs-widgets.el`](../emacs/core/jetpacs-widgets.el), funnelled through
   `jetpacs--node` (nil attrs drop out).
4. **Linter** — add `"foo"` to `jetpacs-lint-node-types` in
   [`jetpacs-lint.el`](../emacs/core/jetpacs-lint.el), and any numeric/colour
   attributes to the typed-attribute lists so a malformed `foo` is caught
   before the wire.
5. **Golden** — add a representative `(jetpacs-foo …)` case to
   `jetpacs-tests--widget-cases` in [`test/jetpacs-tests.el`](../test/jetpacs-tests.el)
   and regenerate:
   `emacs -Q --batch -l test/jetpacs-tests.el -f jetpacs-tests-regen-widget-golden`.
   The `jetpacs-lint-types-cover-golden` test fails if a golden `t` has no
   linter entry — so it keeps steps 2 and 4 honest.
6. **Spec** — document `foo`'s wire shape under the right family in
   [SPEC.md](SPEC.md) §9.
7. **Public API** — if `jetpacs-foo` is meant for third parties, list it in
   [API-STABILITY.md](API-STABILITY.md).
8. **Build** — regenerate the bundles
   (`emacs --batch -l emacs/build-bundle.el`), run the suite, and build the
   app (`gradlew :app:assembleDebug`).

## Worked examples

- **`slider`** — the smallest end-to-end addition: one inline `when` case,
  one constructor, one golden line. Read it as the minimal template.
- **`chart`** ([`SduiChart.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiChart.kt))
  — a substantial curated node: its own file, an animated Canvas draw, a
  closed `kind` enum, `on_point_tap` value injection, and a
  `contentDescription` for accessibility. The model for a real widget.
- **`canvas`** ([`SduiCanvas.kt`](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiCanvas.kt))
  — a *closed interpreter*: before adding a curated node, ask whether the
  need is really a `canvas` draw program driven from Elisp. Usually it is.
