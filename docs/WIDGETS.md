# The widget DSL — node constructors for Tier 1 authors

Every view a Tier 1 pushes is a tree of nodes, and every node is built
by a constructor from [`jetpacs-widgets.el`](../emacs/core/jetpacs-widgets.el).
This document is the elisp-facing reference: what exists, what each
constructor is for, and the keywords worth knowing. Three companions
outrank it in their own domains:

- **Per-symbol authority** — the docstrings (`C-h f jetpacs-card`).
  They carry every keyword's full semantics; this page summarizes.
- **Normative wire shapes** — [SPEC §9](SPEC.md#9-widget-vocabulary)
  plus [`test/widgets.golden`](../test/widgets.golden), one JSON line
  per constructor, pinned by the ERT suite.
- **The stability contract** — [API-STABILITY.md](API-STABILITY.md).
  Every constructor named here is on the stable public surface.

New to all of this? Do [TUTORIAL.md](TUTORIAL.md) first.

## How a node works

A constructor returns a plain alist with a `t` type key; nil options
are omitted from the wire entirely:

```elisp
(jetpacs-text "Hello" 'title)
;; ⇒ ((t . "text") (text . "Hello") (style . "title"))
```

Trees are pure values — build them fresh in your view builder on every
push. Where a constructor takes children, pass a **list** of nodes (the
constructor handles JSON array conversion). The companion walks the
tree and renders; a node type it doesn't recognise renders its
children, or nothing for a leaf — never a crash.

**Additive nodes** (`tabs`, `chart`, `canvas`, `month_grid`, and
whatever arrives next) are negotiated per connection: gate on
`(jetpacs-node-supported-p 'tabs)` and emit the documented fallback
when it returns nil rather than relying on degradation.

## Conventions shared across constructors

- **`:padding`** — dp, on nearly every node.
- **`:weight`** — flex share inside a `row`/`column`; a weighted child
  takes its share of the free space. **Load-bearing caveat:** a `row`/`column`
  renders `fillMaxWidth`, so an *unweighted* one placed inside a row fills the
  whole row and pushes the later siblings off-screen. For a "content + trailing
  control" row, give the flexible child a `:weight` (a `spacer` weight does not
  help — the unweighted content is measured first and already fills the row), or
  use **`jetpacs-list-item`**, which is correct by construction. `jetpacs-lint-spec`
  warns on the unweighted-flex-before-trailing pattern.
- **Sizing** — `:width`/`:height` in dp; `:fill-fraction` (0.0–1.0) of
  the parent's width; `:border` an `jetpacs-border` spec. Available on
  `box`/`surface`/`card` (and `image` for width/height).
- **Colors** — a hex string (`"#7E55B3"`) or a Material theme token
  (`"primary"`, `"surface_container"`, `"primary_container"`, …) that
  adapts to the device's light/dark theme. Prefer tokens.
- **Icons** — snake_case Material icon names (`"menu_book"`,
  `"format_bold"`, `"waving_hand"`). The companion resolves Outlined →
  AutoMirrored → Filled; an unknown name renders a placeholder glyph,
  never an error.
- **Text styles** — `title` / `headline` / `body` / `caption` /
  `label`.
- **Badges** — `:badge` on `nav-item`/`drawer-item`/`icon`/
  `icon-button`: a number (capped at 99+ on-device), `""` for a bare
  attention dot, nil for none. Cosmetic, never load-bearing.
- **Value injection** — value-carrying callbacks (`:on-change`,
  `:on-submit`, `:on-save`, `:on-pick`) dispatch their action with the
  widget's current value injected into `args` as `value`.

## Actions

Actions are descriptors, not code — the wire names an allowlisted
handler registered with `jetpacs-defaction`
([SPEC §5](SPEC.md#5-events-the-semantic-action-boundary)).

- **`(jetpacs-action ACTION &key args when-offline dedupe)`** — the
  descriptor embedded under `:on-tap` and friends. `:args` is an alist
  baked in at build time; the handler receives it parsed back
  (`(alist-get 'key args)`). `:when-offline` is `"queue"` (default —
  mutations, replayed on reconnect), `"drop"` (navigation, refreshes),
  or `"wake"` (worth starting Emacs over). `:dedupe` collapses repeats
  of the same key in the offline queue.
- **`(jetpacs-clipboard-action TEXT)`** — companion-local copy to the
  device clipboard. No round trip, works offline.

## Text & content

- **`(jetpacs-text TEXT &optional STYLE WEIGHT COLOR SELECTABLE
  MAX-LINES PADDING)`** — a plain label. The one positional-options
  constructor: `(jetpacs-text name 'body 1)` is body style, weight 1.
- **`(jetpacs-markup TEXT &key syntax style padding)`** — read-only
  text with client-side highlighting (`:syntax "org"` / `"elisp"`).
  For displaying code or org source; plain labels use `jetpacs-text`.
- **`(jetpacs-rich-text SPANS &key style padding)`** — styled runs from
  **`(jetpacs-span TEXT &key bold italic underline strike code tag
  baseline color bg on-tap mono)`**. For content Emacs already parsed
  into runs: emphasis, links (`:on-tap`), `#tags` (`:tag`),
  super/subscript (`:baseline`), diff/hl-line shading (`:bg`), and
  `:mono` for column-aligned fixed-width runs.
- **`(jetpacs-icon NAME &key size color padding badge)`** — an icon.
- **`(jetpacs-image URL &key content-description padding width height
  aspect-ratio content-scale)`** — an image from an http(s) URL or
  readable `file://` path; `:content-scale` is `fit` (default) /
  `crop` / `fill`.
- **`(jetpacs-date-stamp &key date day month month-index year time
  padding)`** — a compact date chip-card; `:date "YYYY-MM-DD"` derives
  the fields, `:time "HH:MM"` adds a second card.
- **`(jetpacs-divider)`** — a horizontal rule.
- **`(jetpacs-section-header TITLE &key trailing padding)`** — a styled
  section label; `:trailing` is an optional end node (a count, an
  `jetpacs-icon-button`).
- **`(jetpacs-empty-state &key icon title caption on-tap action-label
  padding)`** — a centered placeholder; with both `:on-tap` and
  `:action-label`, an outlined button appears beneath the text.
- **`(jetpacs-progress &key variant value padding)`** — `circular` /
  `linear`; `:value` 0.0–1.0 (nil for indeterminate).

## Layout

- **`(jetpacs-row &rest CHILDREN... :spacing :align :scroll :weight :fill)`** /
  **`(jetpacs-column &rest CHILDREN... :spacing :align :scroll :weight :fill)`** —
  the workhorses. Children first, then optional trailing keywords:
  `:spacing` in dp, `:align` for the cross axis (row:
  `"top"`/`"center"`/`"bottom"`; column: `"start"`/`"center"`/`"end"`),
  `:scroll` to pan/scroll on overflow, `:weight` — this container's own
  flex share when it is itself a child of a row/column (this is how you make a
  nested column flex rather than swallow its row; see the weight caveat above),
  and `:fill` — `nil` opts out of the default `fillMaxWidth` so the container
  sizes to its content (the other way to keep a nested column from swallowing
  its row: `:fill nil` for content-sized, `:weight` for take-the-rest).
- **`(jetpacs-scroll-row &rest CHILDREN)`** /
  **`(jetpacs-scroll-column &rest CHILDREN)`** — the pre-scrolled
  variants. A scrolling row ignores child weights.
- **`(jetpacs-flow-row &rest CHILDREN... :spacing :run-spacing)`** — a
  row that wraps onto new lines; the right container for chip/tag rows.
  A fixed-column grid is a flow-row of `:width`- or
  `:fill-fraction`-sized cells — there is no grid node.
- **`(jetpacs-lazy-column &rest CHILDREN)`** — the scrolling list a tab
  body wants. One scroll container per view; they don't nest.
- **`(jetpacs-scroll-here NODE)`** — marks NODE as its enclosing
  lazy-column's scroll target: the list scrolls to it on first show
  and whenever its index changes (a REPL input row pushed down by new
  output); an index-stable re-push never disturbs the user's position.
- **`(jetpacs-box CHILDREN &key alignment padding weight on-tap width
  height fill-fraction border)`** — a plain container.
- **`(jetpacs-surface CHILDREN &key color shape elevation padding fill
  width height fill-fraction border)`** — a tonal container; `:shape`
  is `"rounded"` / `"rounded_small"` / `"circle"`, `:fill` stretches
  full width (zebra rows).
- **`(jetpacs-card CHILDREN &key on-tap padding weight swipe-start
  swipe-end width height fill-fraction border)`** — the elevated card.
  `:swipe-start`/`:swipe-end` take an
  **`(jetpacs-swipe-action ICON LABEL ACTION &key color)`** revealed by
  dragging; a full swipe fires once and the card springs back. Rule:
  old companions render no gesture, so a swipe action must also be
  reachable by tap or menu.
- **`(jetpacs-list-item &key leading title subtitle overline trailing on-tap
  swipe-start swipe-end padding spacing)`** — the standard list row
  ("leading · title/subtitle · trailing"), correct by construction: an
  elevated card whose middle text column carries the flex `:weight`, so the
  `TRAILING` controls (a status badge, icon buttons) are never pushed
  off-screen — the trap a bare `(jetpacs-row (jetpacs-column …) …)` falls into.
  `TRAILING` is one node or a list; prefer intrinsic-width leaves there (a
  `jetpacs-text` badge, `jetpacs-icon-button`). Composes existing nodes
  (`card` > `row` > weighted `column`) — no new wire type, so it needs no
  companion support.
- **`(jetpacs-border &key width color)`** — the spec `:border` takes.
- **`(jetpacs-spacer &key height width weight)`** — fixed or flex gap.
- **`(jetpacs-collapsible ID HEADER CHILDREN &key collapsed on-long-tap
  on-swipe)`** — a fold section. ID keys the client-side fold state;
  folding never round-trips. `:on-long-tap` fires on the header.
- **`(jetpacs-reorderable-list ITEMS &key on-reorder)`** — drag to
  reorder (vertical) or promote/demote (horizontal). Items are alists
  with at least `label` and `level`; `:on-reorder` dispatches with
  `from_pos` / `after_pos` / `new_level` added to its args.
- **`(jetpacs-tabs ITEMS CHILDREN &key initial scrollable pager-only
  on-change id)`** — an intra-view tab row over swipeable pages.
  ITEMS from **`(jetpacs-tab-item LABEL &key icon)`**, CHILDREN the
  same-length page list. Switching is companion-local; `:on-change`
  optionally reports the settled index as `value`. The user's page
  survives re-pushes; `:id` keys that state — pushing a *new* id
  resets to `:initial`. `:pager-only` drops the tab row (flashcard
  review). Additive: gate on `jetpacs-node-supported-p`; fallback is a
  chip row plus the selected child.
- **`(jetpacs-table ROWS &key aligns on-add-row on-add-col padding)`**
  — an org-table grid; columns size to their widest cell and the grid
  pans horizontally on-device. ROWS from
  **`(jetpacs-table-row CELLS &key header)`** and
  **`(jetpacs-table-rule)`** (an hline); cells from
  **`(jetpacs-table-cell SPANS &key on-tap on-long-tap)`** rendering
  `jetpacs-span`s. `:on-add-row`/`:on-add-col` draw slim "+" append
  affordances. All embedded actions dispatch verbatim — bake the
  file/position into the args yourself.

## Buttons & inputs

- **`(jetpacs-button LABEL ACTION &key icon variant weight padding)`**
  — `:variant` is `filled` / `outlined` / `text` / `tonal`.
- **`(jetpacs-icon-button ICON ACTION &key content-description padding
  badge)`** — an icon-only button.
- **`(jetpacs-chip LABEL &key on-tap selected icon padding)`** — a
  *filter* chip (has selected state).
- **`(jetpacs-assist-chip LABEL &key on-tap icon padding)`** — a flat
  tappable suggestion chip (a `#tag`); pair with `jetpacs-flow-row`.
- **`(jetpacs-badge LABEL &key icon color padding)`** — a compact,
  non-interactive status pill: an optional leading icon and label on a
  `color`-tinted container (`color` a hex or a theme token like `"error"`).
  Intrinsic width, so it is the safe trailing element in a `jetpacs-list-item`
  (a nested icon+label `row` would render `fillMaxWidth`). Additive node — it
  embeds a fallback colored-text child, so a companion predating `badge`
  degrades to a colored label; no `jetpacs-node-supported-p` gate needed.
- **`(jetpacs-menu ITEMS &key icon padding)`** — an overflow dropdown
  of **`(jetpacs-menu-item LABEL ACTION &key icon)`**; opens
  on-device, icon defaults to the vertical ellipsis.
- **`(jetpacs-checkbox ID &key checked label on-change padding)`** /
  **`(jetpacs-switch ID &key checked label on-change padding)`** —
  `:on-change` arrives with `args.value` true/false.
- **`(jetpacs-slider ID ON-CHANGE &key value min max steps)`** — fires
  once on release with the position as `value`; `:min`/`:max` default
  0.0/1.0, `:steps` > 0 makes it discrete.
- **`(jetpacs-text-input ID &key value hint label on-submit multi-line
  min-lines max-lines monospace syntax password keyboard padding)`** —
  single-line by default (`:on-submit` fires on the keyboard's done
  key); `:multi-line` accepts newlines, so pair it with a submit
  button. The typed text lives companion-side under ID — push a *new*
  id to clear the field. `:password` masks entry (never log such
  values); `:keyboard` picks the IME from `number` / `decimal` /
  `email` / `phone` / `uri`.
- **`(jetpacs-enum-list ID OPTIONS &key value multi-select allow-add
  on-change padding)`** — single or multi select over strings;
  `:allow-add` shows a free-text add affordance.
- **`(jetpacs-date-button LABEL ON-PICK &key value)`** /
  **`(jetpacs-time-button LABEL ON-PICK &key value)`** — native
  pickers; `value` injected as `"YYYY-MM-DD"` / `"HH:MM"`.

## The editor

- **`(jetpacs-editor ID VALUE &key on-save read-only syntax
  line-numbers complete chromeless publish-state toolbar)`** — a
  full-height plain-text editor. Unsaved state lives companion-side
  under ID; `:on-save` receives the full text as `value`. `:syntax`
  forces highlighting (else inferred from the file extension in ID);
  `:line-numbers` is `"absolute"` / `"relative"`. `:complete` turns on
  the Emacs-backed completion strip (see `jetpacs-complete.el`);
  `:chromeless` drops the filename/undo/save header for inline fields
  (the eval REPL input); `:publish-state` mirrors the text into
  `jetpacs-ui-state` via debounced `state.changed`, for button-driven
  forms.
- **`(jetpacs-toolbar-item ICON LABEL &key snippet placement line
  on-tap long-press menu)`** — one keyboard-toolbar chip, passed as a
  list to `:toolbar`. Exactly **one op** per item: `:snippet` (local
  insertion; placeholders `${selection}` `${cursor}` `${input:Prompt}`
  `${date}` `${time}`; `:placement` `cursor`/`line-start`/`block`),
  `:line` (`promote`/`demote`/`move-up`/`move-down`), `:on-tap` (an
  ordinary action — the Emacs escape hatch), or `:menu` (sub-items;
  menus don't nest). `:long-press` adds a secondary op.
  `jetpacs-lint-spec` enforces the vocabulary; full semantics in
  [SPEC §9 "Editor toolbars"](SPEC.md#editor-toolbars).

## Visualization — the ladder

Data in, drawing out; each rung is deliberately closed
([CONTRIBUTING-NODES.md](CONTRIBUTING-NODES.md) explains why). All
three nodes are additive — gate on `jetpacs-node-supported-p`.

- **`(jetpacs-chart SERIES &key kind height y-range summary
  on-point-tap)`** — rung 1. SERIES from
  **`(jetpacs-chart-series POINTS &key label color)`**, where points
  are numbers or `(X Y)` pairs; `:kind` is `line` (default) / `bar` /
  `area` / `sparkline`. The companion draws it animated and
  theme-colored. `:summary` is the accessibility label.
- **`(jetpacs-canvas WIDTH HEIGHT OPS)`** — rung 2, the escape hatch
  for visuals no curated node covers. OPS from
  **`jetpacs-draw-line`** `(X1 Y1 X2 Y2 &key color stroke)`,
  **`jetpacs-draw-rect`** `(X Y W H &key color fill stroke radius)`,
  **`jetpacs-draw-circle`** `(CX CY R &key color fill stroke)`,
  **`jetpacs-draw-path`** `(POINTS &key color fill stroke closed)`,
  **`jetpacs-draw-text`** `(X Y TEXT &key color size align)` —
  data-only, no animation or interaction, unknown ops skipped.
- **`(jetpacs-month-grid MONTH &key marks selected min-month max-month
  on-day-tap on-month-change)`** — the agenda calendar. MONTH is
  `"YYYY-MM"`; `:marks` an alist of `("YYYY-MM-DD" . SPEC)` where SPEC
  is a dot count (1–3) or `((dots . N) (color . "#hex"))`. Month
  navigation is companion-local, clamped by `:min-month`/`:max-month`;
  answer `:on-month-change` by pushing fresh marks. Fallback: a
  flow-row of `fill_fraction`-sized day boxes.

## Scaffold & chrome

Inside the shell you rarely build these yourself —
`jetpacs-shell-tab-view` / `jetpacs-shell-nav-view` assemble the
scaffold, drawer, and bottom bar for you. They matter when you push a
custom surface with `jetpacs-surface-push` or build your own shell.

- **`(jetpacs-scaffold &key top-bar fab body bottom-bar
  floating-toolbar snackbar snackbar-action drawer on-refresh)`** —
  the app frame. `:snackbar` is the transient message;
  **`(jetpacs-snackbar-action LABEL ACTION)`** adds a button to it
  that fires only on tap, never on timeout — the undo affordance.
- **`(jetpacs-top-bar TITLE &key nav-icon nav-action actions)`** —
  `:actions` is a list of `jetpacs-icon-button` / `jetpacs-menu`.
- **`(jetpacs-bottom-bar ITEMS)`** of
  **`(jetpacs-nav-item ICON LABEL ACTION &key selected badge)`**.
- **`(jetpacs-drawer ITEMS &key header)`** of
  **`(jetpacs-drawer-item ICON LABEL ACTION &key selected badge)`**.
- **`(jetpacs-fab ICON &key label on-tap extended)`** — prefer
  `jetpacs-apps-set-default-fab` for an app-wide FAB.

## Home-screen surfaces

Rows for `widget:*` (home-screen list widgets) and `tile:customN`
(Quick Settings) surfaces, rendered with RemoteViews — the vocabulary
is deliberately small. See [BUILDING-TIER1
§10](BUILDING-TIER1.md#10-surfaces-beyond-the-app-notifications-widgets-tiles)
for wiring them up.

- **`(jetpacs-widget-item TEXT &key todo done meta icon on-tap in-app
  button on-button)`** — a two-line row. `:todo` renders a colored
  state prefix, `:done` strikes through; `:icon` is `scheduled` /
  `deadline` / `event` / `folder`. `:in-app` routes the tap through
  the opened companion; `:button` (`todo_open` / `todo_done` / `add`)
  adds a trailing button that fires `:on-button` silently.
- **`(jetpacs-widget-divider LABEL)`** — a bold section row
  ("Overdue", "Today").
- **`(jetpacs-tile LABEL &key subtitle icon state on-tap in-app)`** — a
  QS tile; `:state` is `active` / `inactive` / `unavailable`. Without
  `:in-app` the tap fires silently from the shade, **no unlock
  required** — compose accordingly.

## Testing your trees

- **`(jetpacs-lint-spec SPEC)`** — validates a tree: unknown keys,
  malformed actions, the toolbar-op rules.
- **`(jetpacs-render-to-json SPEC &optional object-type)`** —
  serializes through the real wire path and parses back exactly what a
  companion receives; signals the same error a live push would. Assert
  on your views in batch — no phone needed.
- [`test/widgets.golden`](../test/widgets.golden) — the pinned wire
  shape of every constructor, if you need to see the exact JSON.
