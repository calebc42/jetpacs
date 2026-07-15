# Jetpacs — the Emacs–Android Bridge Protocol

Spec: **1.0-rc** · Wire protocol: **`v: 1`** · Framing: **NDJSON** (one
JSON object per line) · Status: release candidate — matches the
reference implementations in `emacs/core/` and `app/`

Jetpacs connects a live Emacs to a mobile *companion* that renders
server-driven UI. The design premise: **Emacs is the source of truth; the
companion is a thin pane of glass.** The companion holds no application
logic — it renders the specs it is sent, caches them for offline display,
and reports user interactions back as semantic events.

This document is the contract a third-party implementation writes against:
a new companion (another platform, another toolkit) or a new client
(something other than the reference Elisp). Anything not marked
**(optional)** is required for a conforming implementation.

**Freeze surface.** As of 1.0-rc the following are frozen — changing any
of them is an amendment (policy below), and a breaking change bumps the
envelope `v`: the envelope (§2), the handshake and pairing auth (§3),
and the semantics of surfaces (§4), the semantic-action boundary (§5),
and the offline queue (§6). Everything in §7–§11 is negotiated or
optional and grows additively. The widget node vocabulary (§9) also
grows additively, through `node_types` negotiation (§3): a new node
type is *not* a version bump.

**Amendment policy.** Every normative change to this document — anything
that alters what a conforming implementation must do — lands in the same
commit as one entry in [SPEC-CHANGES.md](SPEC-CHANGES.md) recording the
date, section, change, fixtures regenerated, and reviewer. No entry, no
amendment.

## 1. Roles and transport

- The **companion is the durable server**: it listens, survives Emacs
  restarts, caches the last-known UI, and queues user actions while Emacs
  is away.
- **Emacs is the client**: it dials in — the same inversion `emacsclient`
  uses on the desktop, because on Android the OS routinely pauses Emacs
  and kills its sockets.
- v0 transport: loopback TCP `127.0.0.1:8765`. The 1.0 target is a Unix
  domain socket in a shared-signature directory. Only the connection
  bootstrap changes; every layer above the socket is transport-agnostic.
- Encoding is UTF-8. One frame per `\n`-terminated line. Blank lines are
  ignored. A receiver must tolerate partial lines across reads.

## 2. Envelope

Every frame is one JSON object:

```json
{"v": 1, "id": "m-1a-04f2", "reply_to": null, "kind": "surface.update", "payload": { ... }}
```

| field      | type           | meaning                                                        |
|------------|----------------|----------------------------------------------------------------|
| `v`        | int            | protocol version the sender speaks (currently `1`)             |
| `id`       | string         | sender-unique message id                                       |
| `reply_to` | string \| null | the `id` this frame answers; `null` for top-level messages     |
| `kind`     | string         | frame type, dot-namespaced (`surface.update`, `event.action`)  |
| `payload`  | object         | kind-specific body (`{}` when empty)                           |

Request/reply correlation is by `reply_to`. Fire-and-forget frames may be
answered with a bare `ack`; a sender that needs the reply keeps its own
pending map keyed by `id`. Unknown `kind`s must not kill the connection —
log and continue (this is the forward-compat rule).

Errors travel as `kind: "error"` with `{code, detail}`.

## 3. Handshake and pairing auth

```
Emacs → companion   session.hello    {protocol, client, features?, wants: [capability...]}
companion → Emacs   auth.challenge   {nonce: SNONCE}
Emacs → companion   auth.response    {nonce: CNONCE, mac}
companion → Emacs   session.welcome  {server_proof, granted, node_types, device?, surfaces, queued_events, protocol?, server?}
```

The welcome's optional `protocol` (the companion's wire version) and
`server` (an implementation/version string, mirroring `hello`'s
`client`) are informational — for logging skew, never gated on.

- **Pairing token.** The companion generates a secret token shown once in
  its pairing UI; the user copies it into their Emacs init. The token
  itself never crosses the wire.
- **Mutual proof (HMAC-SHA256, lowercase hex, keyed by the token):**
  - client `mac`  = `HMAC(token, "jetpacs1:client:" + SNONCE + ":" + CNONCE)`
  - `server_proof` = `HMAC(token, "jetpacs1:server:" + CNONCE + ":" + SNONCE)`
  - Nonces need uniqueness, not secrecy. Both sides fail closed: a wrong
    client mac is refused before any state is trusted; a missing or wrong
    `server_proof` makes the client drop the connection (a rogue app
    squatting the port cannot impersonate the companion).
- **Capability negotiation.** `wants` is the capability set the client
  requests; the companion grants the intersection with what it supports
  (`granted` in the welcome). Unrecognised capabilities are silently not
  granted. v0 capability names: `surfaces.widget`, `surfaces.notification`,
  `surfaces.dialog`, `capabilities`, `triggers`, `queue.replay`, `theme`.
- **Node vocabulary.** `node_types` is the flat list of widget node `t`
  discriminators (§9) this companion renders — always present, since
  serving `app:*` surfaces is core rather than a negotiated capability. A
  client SHOULD gate a node it cannot assume is universal against this
  list and render a fallback when absent, exactly as it filters triggers
  against `device.trigger_types`. A client that receives *no* `node_types`
  (an older companion) treats every node as supported — negotiation is
  positive knowledge, never a denylist. This is the companion-side half of
  the §9 forward-compat rule: unknown nodes never crash, and `node_types`
  lets the client avoid emitting an invisible one in the first place.
- **Build-feature report.** `features` is the flat list of optional
  compile-time features the client's Emacs binary actually has
  (`sqlite`, `treesit`, `native-comp`, `libxml`) — positive knowledge,
  since a version floor is not a build guarantee. Additive and purely
  informational: the companion never gates on it (like the `client`
  string, it exists so build skew shows up in logs the way version skew
  already does), and a companion that predates the field ignores it.
  Like all wire vocabulary it is negotiated by presence, not
  version-gated — mirror of the `node_types` rule.
- **Revision snapshot.** `surfaces` maps each cached surface id to the
  revision the companion holds, so a client whose revision counter was
  lost (fresh machine, deleted state) can raise it above the cache floor
  before pushing. `queued_events` is the number of offline events waiting
  for replay.
- **Device report.** When `capabilities` is granted, the welcome carries
  a `device` object — the invocable capability names and the device
  permission map. See §10.

### Versioning

Two independent version numbers, deliberately not conflated:

- **Protocol version** (`protocol` in `session.hello`, the envelope `v`,
  this document's version) — the wire contract. Bumped only on a
  wire-breaking change.
- **API version** — the client library's Tier 1 surface (the Elisp
  constructors and seams; reference: `jetpacs-api-version`, semver). Carried
  informationally in `hello`'s `client` string
  (`emacs/30.1 jetpacs.el/1.0.0`) for logging skew. A companion never gates
  on it — the API surface is a client-side concern.

Node-vocabulary growth is **not** a protocol bump: new node types are
additive and negotiated per-connection (§3 capability set + the welcome's
`node_types`, §9), so an old companion and a new client interoperate by
each side ignoring what it doesn't know.

## 4. Surfaces

A *surface* is a named, cacheable UI target. The id namespace tells the
companion where it renders:

| id pattern       | renders as                              | capability              |
|------------------|------------------------------------------|-------------------------|
| `app:*`          | full-screen in-app UI                    | core                    |
| `notification:*` | system notification                      | `surfaces.notification` |
| `widget:*`       | home-screen widget                       | `surfaces.widget`       |

```
surface.update   {surface, revision, spec, ttl_s?, stale_spec?, current_view?}
surface.remove   {surface}
```

- **Revisions are monotonically increasing per client** and persist across
  restarts; the companion rejects a non-newer revision for a cached
  surface. This makes updates idempotent and replay-safe.
- The companion **persists the latest spec** per surface and renders it
  while Emacs is disconnected (that is the offline story).
- **Multi-view surfaces.** A spec of the shape
  `{views: {name: viewSpec, ...}, initial_view: name}` ships several named
  views at once; the companion switches between them locally via the
  `view.switch` builtin, so navigation never round-trips. `current_view`
  on the update forces the companion onto a view — used only when the push
  *is* the navigation; background refreshes must never yank the user.
- **Widget surfaces.** A `widget:*` spec (or each of its views) carries
  `title`, `items` (rows of the home-widget row schema, emitted by the
  `jetpacs-widget-item` / `jetpacs-widget-divider` constructors), and
  optional `empty` (the no-rows caption).
  One **top-level** key — a sibling of `views`/`initial_view`, since
  chrome is view-independent — is `header_action`: an ordinary §5 action
  object rendered as the widget header's "+" button. Tapping it opens
  the app with the action embedded (header actions are for flows that
  need the visible app, e.g. a capture dialog needs a keyboard); the
  object dispatches verbatim, `when_offline` included. Absent, the
  button is hidden. The companion hardcodes no header action of its own.

## 5. Events: the semantic-action boundary

User interactions reach the client as:

```
event.action    {action, args?, surface?, revision_seen?, fields?, queued_at?}
state.changed   {id, value}
```

`surface` and `revision_seen` are the context the interaction happened
in (which surface, at which cached revision); `queued_at` (epoch ms) is
stamped onto events delivered from the offline queue (§6) and absent on
live ones; `fields` carries values a companion collected as part of the
interaction — presently only an inline-reply notification action's typed
text as `{key: text}` (§9) — and is `null` when the interaction gathered
none. The
`when_offline`/`dedupe`/`ttl_s` fields an author writes on an action
object (below) are queue policy: the companion consumes them when the
event is queued and does not echo them in the delivered frame.

**The allowlist principle (normative).** An `action` is a *name* the
client explicitly registered a handler for; `args` are plain data the
handler validates. The wire must never carry code, command names to
funcall, file paths outside the client's own guards, or anything else
that turns the companion into a remote eval. A client receiving an action
with no registered handler logs and drops it. The single sanctioned
escape hatch is an M-x–style action whose handler runs the client's own
interactive command dispatch *with its prompts bridged to the user* — the
user, not the wire, chooses the command.

Actions are dot-namespaced `noun.verb` (`heading.todo-set`,
`files.rename`, `packages.install`). Namespaces belong to the module that
registers the handler; the core reserves `jetpacs.*`, `nav.*`, `view.*`,
`dialog.*`, `edit.*`, `tablist.*`, `settings.*`, `prompt.*`,
`dashboard.*`, `files.*`, `emacs.*`, `packages.*`, `customize.*`,
`transient.*`, `share.*`, `demo.*`, `witheditor.*`, `comint.*`,
`imenu.*`, `tools.*`, `trigger.*` (device-trigger fires, §11), `app.*`
(launcher app switching, jetpacs-apps.el), `device.*` (device-effector
UI: the app-launch picker, the permissions screen — jetpacs-device.el).

- `when_offline` is the queue policy the *spec author* chose for the
  control: `"queue"` (default — persist and replay), `"drop"` (meaningless
  later, e.g. navigation), `"wake"` (try to start Emacs, then queue).
- `dedupe`: a queued action replaces any queued action with the same
  dedupe key (e.g. repeated saves of one file collapse to the last).
- `state.changed` carries widget state (text as typed, switch flips,
  multi-select values) keyed by widget `id`; the client mirrors these into
  a UI-state store its handlers read back. It is not an action and runs no
  handler-side effects beyond per-id subscriptions.

**Companion-local builtins.** An action object with `builtin` instead of
`action` is handled on-device and works with Emacs dead:
`{"builtin": "view.switch", "view": v}` (flips a multi-view surface, then
informs the client with a drop-policy `view.switched` event) and
`{"builtin": "clipboard.copy", "text": s}`, and
`{"builtin": "jetpacs.settings.open"}` (opens Android-owned Jetpacs settings
for permissions, notifications, offline state, pairing, and diagnostics).

## 6. Offline queue

While disconnected the companion persists queue-policy events. After the
welcome, the client requests `queue.replay`; the companion streams the
queued `event.action` frames in order and finishes with:

```
queue.drained   {delivered, expired}
```

The client should request replay only after it has absorbed the revision
snapshot and pushed initial surfaces, so replayed events land on coherent
state, and should re-push after the drain (replayed events usually
mutated state the cached views no longer reflect).

## 7. Dialogs, toasts, pies, reminders

| kind                              | direction | body                                                | capability |
|-----------------------------------|-----------|-----------------------------------------------------|------------|
| `dialog.show` / `dialog.dismiss`  | → comp.   | a UI-tree spec rendered modally                     | `surfaces.dialog` |
| `toast.show`                      | → comp.   | `{text}` transient toast                            | optional |
| `pie_menu.show` / `.dismiss`      | → comp.   | radial menu spec (curated, ≤ ~10 items)             | optional |
| `reminders.set`                   | → comp.   | `{owner?, reminders: [{id, title, body, at_ms}]}` — **replaces** only `owner`'s set (blank/absent = the unowned bucket), so cancelled items never fire stale and coexisting apps never cancel each other; the companion persists each owner's set across reboots | `reminders.owner` for scoping |
| `theme.set`                       | → comp.   | `{dark, colors, syntax}` to mirror the client's theme, or `{base}` (no `colors`) to force one of the companion's own schemes | `theme` |

A `dialog.show` spec's **root node** may carry `dialog_style`:
`"sheet"` / `"sheet_full"` render the same tree as a modal bottom sheet
(collapsed / fully expanded — the native idiom for pickers and action
menus); anything else, or its absence, keeps the centered dialog window.
Additive: an old companion ignores the key and centers the dialog. The
elisp side sets it per-call (`jetpacs-send-dialog`'s STYLE) or globally
(`jetpacs-dialog-style`).

**Owner-scoped reminders.** `reminders.set` carries an optional `owner` (an
app-id string). The companion partitions armed alarms by owner, so a set
replaces only that owner's previous alarms; a blank/absent `owner` is the
unowned/core bucket, and request codes are hashed with the owner so distinct
apps never collide. This lets two Tier 1 apps arm reminders without one's
set cancelling the other's — a bare owner-less set could not. A companion
advertising the `reminders.owner` capability is owner-aware:
`jetpacs-reminders-owner-set` sends the scoped set only when it is granted,
and otherwise degrades — a plain global set when only one app is registered,
else it warns and arms nothing rather than clobber another app. Additive: an
old companion ignores `owner` (treating every set as the one global set).

`theme.set` lets the client's theme win over the companion's own scheme
(Material You, or its static fallback). `colors` maps Material color-role
names — the same snake_case tokens §9 nodes use (`primary`,
`surface_variant`, `on_primary_container`, …) — to `#rrggbb` strings;
`syntax` maps editor token names (`comment`, `keyword`, `heading` /
`paren` as arrays, …) the same way; `dark` declares the theme's polarity,
which overrides the device's day/night setting while mirroring. Every key
is optional — the companion fills holes from its fallback scheme. Each
push replaces the last and is persisted like a cached surface (the phone
keeps the client's look while the client is away); `colors: null` clears
the mirror and the persisted palette. When a push carries no `colors`, an
optional `base` string instead selects which of the companion's *own*
schemes to force: `"material"` (Material You, where the device supports it)
or `"default"` (the companion's built-in scheme). This lets the client
drive a companion that isn't mirroring — the app's theme becomes a
three-way client choice (default / material / mirror-the-client) rather
than a device-only default. A companion that predates `base` sees a push
with no `colors`, treats it as the clear, and falls back to its own scheme
chain — so `base` degrades to "the companion decides."

The reference client extracts the palette from the running Emacs theme
(`jetpacs-theme.el`), and its `jetpacs-theme-mode` (`default` / `material`
/ `emacs`) drives exactly the above: `emacs` mirrors, the others send the
matching `base`. Mirroring leans on the modus-themes palette API when a
modus-family theme is active and on resolved face attributes otherwise.
"modus-family" is detected through `modus-themes-get-current-theme`, so it
covers not just the `modus-*` originals but anything built on the modus 5.0
derivative API (the ef-themes, standard-themes, third-party skins); the
client reads that theme's *semantic* palette roles (`accent-0`, `err`,
`prose-todo`, `fg-heading-N`, …) with the user's palette overrides applied,
which keeps the mirror faithful across derivatives and the deuteranopia/
tritanopia color-vision variants.

The minibuffer bridge rides on dialogs: when a client action handler hits
a prompting call (`y-or-n-p`, `completing-read`, `read-passwd`,
`map-y-or-n-p`, raw event reads, …) it sends the prompt as a dialog and
blocks for the answering `prompt.reply` / `prompt.dismiss` action,
exactly as the original function would block for keyboard input.

Editor-callback sessions (with-editor: commit messages, rebase todos)
ride on dialogs too, but asynchronously — the buffer appears after the
originating action handler has returned, so the client pushes an editor
dialog and later receives `witheditor.finish {buffer}` (splices the
edited message, runs `with-editor-finish`) or `witheditor.cancel
{buffer}`.  Both handlers validate that `buffer` names a live
with-editor session before acting — never arbitrary dispatch — and the
client should only bridge sessions plausibly initiated from the
companion (e.g. shortly after a dispatched action), so a desktop commit
never pops a dialog on the phone.

## 8. Editor sync sub-protocol (optional)

Turns the companion's text editor into a live client of Emacs — the basis
for completion, diagnostics, eldoc, and fontification. All offsets are
**Unicode code points** (= Emacs buffer positions; the companion converts
from its UTF-16 indices, so the client never does encoding math).

The companion → client legs are §5 *actions* riding `event.action`
frames (they hit the same allowlist as every other interaction); the
client → companion legs are frame kinds of their own. Offsets named
`start`/`cursor` are code points; `seq` stamps which delta state a
message was computed against.

```
companion → client   event.action {action: "edit.open",     args: {file, session, text}}   seed / reseed (seq 0)
companion → client   event.action {action: "edit.delta",    args: {file, session, seq, start, del, text, len}}
companion → client   event.action {action: "edit.caret",    args: {file, session, seq, cursor}}
companion → client   event.action {action: "edit.close",    args: {file, session}}
companion → client   event.action {action: "edit.complete", args: {file, session, seq, request_id, cursor}}   pure query
client → companion   completions.show {id, request_id, prefix, candidates: [{label, annotation?, insert?}]}
client → companion   diagnostics.show {id, session, seq, diags: [{beg, end, type, text}]}
client → companion   eldoc.show       {id, session, text}
client → companion   fontify.show     {id, session, seq, runs}
client → companion   edit.resync      {id, session}
```

In the client → companion frames `id` is the editor id (the synced
file); `seq` on `diagnostics.show`/`fontify.show` lets the companion
refuse to draw squiggles or highlights over text that has moved on.

Deltas are `seq`-numbered and each carries the expected resulting length;
on any mismatch (dropped frame, client restart) the client marks the
session stale and sends one `edit.resync`, which the companion answers
with a fresh `edit.open`. Invariant: **wrong state can only ever cause a
missing feature, never a wrong edit** — the shadow never writes to disk,
and completion insertion happens companion-side.

A candidate's optional `insert` is what lands in the buffer when it
differs from the display `label` (a wikilink chip shows `[[Title` but
inserts `[[id:…][Title]]`). Candidates carrying `insert` were matched
by client-side rules of their own — a wikilink capf matches note
titles by **substring** — so the companion narrows them by
contains-prefix rather than the starts-with rule it applies to plain
code-completion candidates.

## 9. Widget vocabulary

Specs are trees of nodes; every node is `{"t": type, ...}` and unknown
keys must be ignored (forward compat). A node whose `t` a companion does
not recognise renders its `children` if it has any (a new container
degrades to a plain stack of its contents) or nothing if it is a leaf —
never a crash (§12). The welcome's `node_types` (§3) is the companion's
catalog of the `t` values it *does* render, so a client can gate a newer
node and emit a fallback rather than depend on this degradation. Actions embed as objects under
a node's action key — `on_tap`, `on_change`, `on_submit`, `on_save`,
`on_pick`, `on_reorder`, `on_refresh`, `nav_action`, `on_point_tap`,
`on_button`, and the rest (the full set is `action_hook_keys` in
[`docs/contract.json`](contract.json)). Value-carrying callbacks
(`on_change`, `on_submit`, `on_save`, `on_pick`, `on_point_tap`) dispatch their
action with the widget's current value injected into `args` as `value` — a
switch's `on_change` arrives with `args.value` true/false, a text
input's `on_submit` with the text.

Declarative data-views (API 1.5.0) compile *on the client* to exactly these
nodes and actions. Their authoring grammar — `:spec` views, named sources,
closed template placeholders — is a local concern documented in
[BINDING.md](BINDING.md), **not** a wire addition; the compiled output obeys
this section and the §5 allowlist like any other node tree.

The normative, machine-checked reference for every node's wire shape is
[`test/widgets.golden`](../test/widgets.golden) — one JSON line per
constructor, kept honest by the ERT suite. Since 1.0-rc,
[`docs/contract.json`](contract.json) (contract_format 2) additionally
publishes the authored per-node key schema (`node_schema`: required and
optional keys per type, plus the `"*"` row of keys legal on any node)
and the frame-kind schema (`kind_schema`: sender direction and payload
keys per kind) — the machine-readable form of this section and of the
frame sketches in §§2–8, 10–11, consumed by both conformance suites.
Summary by family:

- **Content**: `text` (style/color/syntax/selectable), `rich_text` +
  styled `spans` (emphasis, `color`/`bg` hex overrides, `mono`, tap
  links), `icon`, `image`, `date_stamp`, `divider`, `section_header`,
  `empty_state`, `progress`.
- **Layout**: `row`, `column` (both take `spacing` in dp between children
  and `align` for the cross axis — row `top`/`center`/`bottom`, column
  `start`/`center`/`end`), `flow_row`, `lazy_column` (a child may
  carry `scroll_here: true` — the list scrolls to it on first show and
  whenever its index changes, e.g. a REPL input row pushed down by new
  output; an update that leaves the index unchanged never disturbs the
  user's scroll position), `box` (weight / alignment / tap), `surface`
  (tonal container), `card`, `spacer`, `collapsible` (folds on-device),
  `reorderable_list` (drag to reorder, reports via `on_reorder`),
  `card` additionally takes `swipe_start` / `swipe_end` — per-side swipe
  actions `{icon, label, color?, on_trigger}`: dragging reveals the
  side's icon/label, a full swipe dispatches `on_trigger` once and the
  card springs back (the server answers with the updated list); they
  supersede the legacy single-action `on_swipe`, and because an old
  companion renders no gesture, a swipe action must also be reachable
  by tap or menu. `tabs` — an intra-view tab row over swipeable pages:
  parallel `items` (`{label, icon?}`) and `children` (the pages),
  `initial` index, `scrollable` for many tabs, `pager_only` to drop the
  row for pure swipe-through content (e.g. flashcard review). Switching
  is companion-local (the `view.switch` philosophy); optional
  `on_change` dispatches with the settled page index injected as
  `value`. The user's page survives re-pushes; an optional `id` keys
  that state — a push carrying a new `id` resets to `initial` (a fresh
  flashcard lands on its question page). An additive node — negotiate
  via `node_types` (§3); a companion that predates it stacks the
  pages, so the documented fallback is a chip row plus the selected
  child.
  `table` (org-table grid: `rows` of span-bearing `cells`, plus `rule`
  rows for hlines and `header` rows rendered emphasized; per-column
  `aligns` of `start`/`center`/`end`; columns size to their widest cell
  and a wide grid pans horizontally on-device. Cells may carry
  `on_tap`/`on_long_tap`; `on_add_row`/`on_add_col` on the node make
  the client draw slim "+" append affordances below the last row /
  after the last column. All embedded actions dispatch verbatim — the
  server bakes file/position into the args, the client adds nothing).
- **Container sizing** (additive, all optional): `box`/`surface`/`card`
  accept `width`/`height` in dp, `fill_fraction` (0–1 of the parent's
  width), and `border` (`{width, color}`, stroked with the node's shape);
  `image` accepts `width`/`height`, `aspect_ratio`, and `content_scale`
  (`fit`/`crop`/`fill`). Absent keys preserve the prior behaviour. A
  fixed-column grid is composed as a `flow_row` of `width`- or
  `fill_fraction`-sized cells — there is no dedicated grid node.
- **Input**: `button`, `icon_button`, `chip`, `assist_chip`, `menu`,
  `checkbox`, `switch`, `slider` (continuous value; `min`/`max` default
  0/1, `steps` for discrete; dispatches `on_change` once on release with
  the value injected), `text_input` (optional `password` masks entry and
  requests a password keyboard — such values must not be logged or
  retained; optional `keyboard` picks the IME from the closed enum
  `number`/`decimal`/`email`/`phone`/`uri`, unknown or absent → text,
  `password` wins), `enum_list` (single/multi select, optional free-add),
  `date_button` / `time_button` (native pickers),
  `editor` (full editor: save/undo header, optional `syntax`, gutter
  `line_numbers`, `complete` for the completion strip, `chromeless`,
  `publish_state`, and a server-chosen `toolbar` — a string naming a
  host-registered native toolbar, or an array of data-driven toolbar
  items; see "Editor toolbars" below).
- **Visualization** (the ladder): `chart` — data-driven, the client emits
  `series` of `points` and picks a `kind` (`line`/`bar`/`area`/`sparkline`);
  the companion draws it animated and theme-coloured, dispatching
  `on_point_tap` with the tapped point. A closed enum on purpose — a need
  outside this shape belongs on `canvas`, not a new `chart` attribute.
  `canvas` — the escape hatch: `{width, height, ops}` where each op is a
  closed, data-only draw primitive (`line`/`rect`/`circle`/`path`/`text`)
  in the node's coordinate space. No animation, no interaction (those earn
  a curated primitive); unknown ops are skipped, never fatal.
  `month_grid` — the agenda calendar, the `chart` of time:
  `{month: "YYYY-MM", marks: {"YYYY-MM-DD": {dots, color?}, …},
  selected?, min_month?, max_month?, on_day_tap?, on_month_change?}`.
  Month navigation (chevrons, horizontal swipe) is companion-local and
  clamped to `min_month`/`max_month`; `on_month_change` dispatches with
  the newly shown month as `value` so the client can push fresh marks —
  marks for unfetched months are simply absent, never blocking.
  `on_day_tap` dispatches with the tapped ISO date as `value`; today is
  outlined, `selected` filled, up to 3 `dots` render under a day. A
  re-push with a different `month` adopts it; mark-only re-pushes leave
  the user's shown month alone. All three are additive nodes —
  negotiate via `node_types` (§3) and fall back (a `table`, or for
  `month_grid` a `flow_row` of `fill_fraction` day boxes) on a
  companion that predates them.
- **Chrome**: `scaffold` (top_bar / bottom_bar / fab / drawer / snackbar /
  pull-to-refresh), `top_bar`, `bottom_bar` + `nav_item`, `drawer` +
  `drawer_item`, `fab`. The scaffold's `snackbar` string may be
  accompanied by `snackbar_action` `{label, on_tap}` — an action button
  on the snackbar (the undo affordance) that dispatches only on a user
  tap, never on timeout; old companions show the plain message. A
  `badge` attribute on `nav_item` / `drawer_item` / `icon` /
  `icon_button` overlays a count (numbers cap at 99+ on-device; the
  empty string renders a bare attention dot) — cosmetic, never
  load-bearing, silently ignored by older companions.
- **Notification specs** add `meta` (channel, ongoing, category, priority,
  `chronometer: {base_ms}`) above a body of content nodes. `meta.actions`
  is an ordered array of action buttons rendered as the platform
  notification's own actions (the OS caps how many are shown — author the
  most important first). Each entry carries `label` (required) and
  `on_tap` (required — a §5 action object dispatched when the button is
  tapped), plus optional:
  - `icon` — a §9 icon name, best-effort. A companion maps it to a
    platform glyph; note that Android ≥ 7 does not draw action icons in
    the shade (label only), so never make the icon load-bearing. Absent
    or unresolvable → a default glyph.
  - `dismiss` — when true, tapping the button cancels the notification
    (the Done / Snooze affordance).
  - `input` — `{hint?, key?}`; turns the button into an inline text
    reply. The typed text rides back in the dispatched `event.action`'s
    `fields` as `{key: text}` (`key` defaults to `reply`), so the same
    action handler reads the reply from the payload. Pair it with
    `dismiss` to clear the notification once the reply is sent.

  `meta.actions` is additive — a companion that predates it ignores the
  unknown meta key and posts the notification with no action buttons; it
  never fails. (A `button` node placed directly in the body is still
  honored as an action when `meta.actions` is absent, the older implicit
  form.) Emit via `jetpacs-notification-action` / `jetpacs-notification-spec
  :actions`.

### Editor toolbars

`editor`'s `toolbar` attribute is **string | array**:

- **string** — the name of a host-registered native toolbar
  (`JetpacsToolbars` in the companion; the Kotlin-alternative path per
  the ladder doctrine, §9 visualization family). The library registers
  none; an unknown name renders nothing.
- **array of toolbar items** — the data-driven form. The companion
  interprets the items locally (`SduiToolbar`); every op is one minimal
  splice on the buffer = one undo step, no Emacs round-trip. Each item:

  | key | value |
  |---|---|
  | `icon` | icon name for the chip |
  | `label` | short chip label |
  | `snippet` | *op:* text to insert (placeholders below) |
  | `line` | *op:* builtin line op — `promote` \| `demote` \| `move-up` \| `move-down` |
  | `on_tap` | *op:* an ordinary §5 action object — the Emacs escape hatch |
  | `menu` | *op:* array of sub-items (`label` + exactly one of `snippet`/`line`/`on_tap`; menus don't nest) |
  | `placement` | optional, `snippet` only: `cursor` (default) \| `line-start` \| `block` |
  | `long_press` | optional secondary op: an object with exactly one of `snippet`/`line`/`on_tap` |

  Exactly **one** op field (`snippet`/`line`/`on_tap`/`menu`) per item
  (`jetpacs-lint` enforces).

  **Snippet placeholders** (closed, companion-local):

  | token | behavior |
  |---|---|
  | `${selection}` | replaced by the current selection; the result stays selected. With an empty selection the cursor lands there — so `*${selection}*` reproduces both wrap-selection branches |
  | `${cursor}` | explicit final cursor position (wins over `${selection}`'s cursor rule) |
  | `${input:Prompt}` | one companion-local free-text dialog titled *Prompt*; the entry substitutes in (e.g. a src-block language). Preset choices are the app's `menu` items, not this |
  | `${date}` | `YYYY-MM-DD Day` (companion clock) |
  | `${time}` | `HH:MM` |

  Rules: unknown `${…}` tokens insert **literally** (visible, never
  fatal). `line-start` placement inserts at the start of the cursor's
  line and no-ops when the line already starts with the literal prefix
  (dedupe). `block` placement inserts the snippet on its own line(s),
  adding newlines around it as needed; without `${cursor}` the cursor
  lands after the block. A snippet without `${selection}` inserts at the
  cursor and leaves any selection's text alone.

  **Forward compat:** the array form is additive. An old companion that
  predates it treats the value as an unknown toolbar name and renders no
  toolbar; it never crashes. Emit via `jetpacs-toolbar-item` /
  `jetpacs-editor :toolbar` and lint with `jetpacs-lint-spec`.

## 10. Device capabilities (optional)

The Emacs → device *effector* channel: the client invokes device-side
actions (open a settings panel; later: intents, flashlight, TTS, …).
Negotiated under the `capabilities` capability name.

```
capability.invoke    {cap, args?}      client → companion
capability.result    {ok, result?}     companion → client (reply)
```

- `cap` names an entry in the welcome's `device.caps` list; `args` is a
  plain-data object whose shape belongs to the capability. On success
  the companion replies `capability.result` with `ok: true` and, for
  querying capabilities, a `result` object. A failed or unknown invoke
  is answered with a standard `error` frame (`reply_to` set) whose
  `code` is one of:

  | code              | meaning                                               |
  |-------------------|-------------------------------------------------------|
  | `cap-unsupported` | this companion has no such capability                 |
  | `cap-permission`  | needs a device permission the user has not granted    |
  | `cap-failed`      | supported and permitted, but the device action failed |

  A `cap-permission` error additionally carries `perm` (the missing
  `device.perms` key) and, when one exists, `settings` — a value the
  client can pass straight back as `capability.invoke {cap:
  "settings.open", args: {panel: …}}` to take the user to the right
  grant screen.

- **Device report.** When `capabilities` or `triggers` is granted,
  `session.welcome` carries a `device` object:

  ```json
  "device": {"caps": ["settings.open"],
             "perms": {"post_notifications": true, "exact_alarms": true,
                       "write_settings": false, "notification_policy": false,
                       "notification_listener": false, "fine_location": false,
                       "bluetooth_connect": false, "read_calendar": false,
                       "receive_sms": false, "read_phone_state": false,
                       "read_call_log": false},
             "trigger_types": ["airplane", "battery.level", "boot", "..."],
             "state_types": ["airplane", "battery.level", "headset", "..."]}
  ```

  `caps` is the invocable capability set. `perms` reports the runtime
  and special-access permissions effectors and triggers depend on, so
  the client can degrade gracefully — grey out a control, deep-link to
  the grant screen — instead of invoking blind. The map is a snapshot
  at welcome time; the companion re-checks at invoke time, so a stale
  map can only cause a typed error, never a wrong action.
  `trigger_types` (under the `triggers` grant, §11) is this
  companion's trigger-type catalog: because `triggers.set` rejects a
  set wholesale on an unknown type, the client uses this list to skip
  a too-new registration instead of poisoning the push.
  `state_types` (also under the `triggers` grant) is the
  state-predicate catalog — what a §11 `when` gate may reference and
  `state.get` can sample; the client-side rule it drives is normative
  in §11's `when` bullet.

- **Trust model.** This flows in the already-trusted direction: the
  post-handshake client drives notifications, reminders, and dialogs,
  and effectors are consistent with that. `args` are plain data,
  validated per capability. Capabilities that launch activities are
  best-effort while the companion is backgrounded (Android
  background-launch limits); they are reliable from foreground and
  notification contexts.

### Capability catalog

| cap | args | result | notes |
|---|---|---|---|
| `settings.open` | `{panel}` | — | `panel` = `wifi` \| `internet` \| `bluetooth` \| `volume` \| `nfc` \| `app` (the companion's own app-info page — runtime-permission grants live there), or any `android.settings.*` action string; anything else → `cap-failed`. The compliant "toggle" for radios apps can't flip; floating panels where the platform has them |
| `intent.start` | `{action?, data?, package?, class_name?, mime?, extras?, mode?}` | — | the universal escape hatch. `extras` values are strings/numbers/booleans only — never anything executable. `mode` = `activity` (default, adds `FLAG_ACTIVITY_NEW_TASK`) \| `broadcast` \| `service`. Activity mode is best-effort while the companion is backgrounded |
| `app.launch` | `{package}` | — | the package's launcher activity, or `cap-failed` |
| `apps.list` | — | `{apps: [{label, package}]}` | launchable packages sorted by label — feeds a client-side picker. Empty without the companion's package-visibility `<queries>` |
| `shortcut.pin` | `{id, label, action, icon_png?, long_label?}` | `{updated?}` | requests a home-screen pinned shortcut (launcher confirm dialog; the OS badges it with the companion's icon). `action` is a standard action object (§5) fired through the normal tap pipeline when the shortcut opens the companion; `icon_png` is a base64 PNG the launcher masks to its adaptive shape (square full-bleed, ≥432 px recommended), defaulting to the companion's own icon. Re-pinning an existing `id` updates it in place with no dialog → `{updated: true}`. Launcher refusal → `cap-failed` |
| `shortcuts.set` | `{shortcuts: [{id, label, action, icon_png?, long_label?}]}` | — | replace-set of the companion icon's long-press (dynamic) shortcuts, `triggers.set` discipline: empty list clears, a set above the launcher's per-activity max → `cap-failed` (never silently truncated). Entry fields as in `shortcut.pin` |
| `vibrate` | `{ms?}` or `{pattern: [off, on, … ms]}` | — | `ms` defaults to 200; `pattern` wins when both given |
| `tts.speak` | `{text, pitch?, rate?}` | — | asynchronous best-effort; engine lazy-inits (utterances queue during init) and releases after ~60 s idle |
| `volume.set` | `{stream, level}` | `{max}` | `stream` = `music` \| `ring` \| `alarm` \| `notification` \| `call` \| `system`; `level` clamps to `0..max`. DND policy can refuse → `cap-permission` |
| `ringer.mode` | `{mode}` | — | `normal` \| `vibrate` \| `silent`; silent needs DND access → `cap-permission` with the grant deep-link |
| `flashlight` | `{on}` | — | torch of the first flash-capable camera; none → `cap-failed` |
| `media.key` | `{key}` | — | `play_pause` \| `play` \| `pause` \| `next` \| `previous` \| `stop` \| `fast_forward` \| `rewind` |
| `clipboard.read` | — | `{text}` | Android 10+ exposes the clipboard only to the focused app → `cap-permission` while backgrounded. Contents must never be logged or persisted companion-side |
| `screen.keep_on` | `{on}` | — | a window flag held only while the companion's Jetpacs UI is on screen — it cannot pin the device awake from the background |
| `brightness.set` | `{level}` | — | 0–255, switches to manual brightness; ungranted → `cap-permission` (`write_settings` + the grant deep-link) |
| `dnd.set` | `{mode}` | — | `on` \| `off` \| `priority`; ungranted → `cap-permission` (`notification_policy` + the grant deep-link) |
| `state.get` | `{types?, when?}` | `{states, unavailable?, holds?}` | sample the §11 state predicates. `states` maps each requested type (default: every `device.state_types` entry) to its current state object (shapes in §11 "State predicates & sampling"); a type that cannot be sampled lands in `unavailable` as its typed failure code, never failing the batch. `when` — a §11 predicate array — adds `holds`, evaluated by the same code path that gates fires, so a gate is testable from Emacs before it ships; a malformed `when` → `cap-failed` |

## 11. Device triggers (optional)

The device → Emacs *event source* path: the companion watches device
state (time, power, screen, connectivity, …) and reports changes the
client subscribed to — durable the same way its UI serving is durable.
Negotiated under the `triggers` capability name; a companion that
cannot host triggers does not grant it, and a client must not send
`triggers.set` without the grant.

```
triggers.set   {triggers: [{id, type, params?, when?, policy?, dedupe?,
                            throttle_s?, on_fire?}]}        client → companion
```

- **Replace-set semantics**, exactly like `reminders.set`: each set
  replaces the previous one in full, so a removed trigger can never
  fire stale, and re-pushing the current set on reconnect is
  idempotent. The registered set persists on the companion and is
  re-armed after reboots.
- `id` is the client's stable name for the registration; `type` names
  an entry in the trigger-type catalog below; `params` is the
  plain-data, type-specific match configuration (an SSID, a battery
  threshold, a clock time).
- **Firing is an ordinary event.** A firing trigger delivers

  ```
  event.action   {action: "trigger.fired",
                  args: {id, type, data, at_ms}}
  ```

  through the exact machinery of §5–§6: connected ⇒ delivered,
  disconnected ⇒ queued / dropped / woken per the registration's
  `policy` (the §5 `when_offline` vocabulary; default `queue`), with
  `dedupe` collapsing queued fires that share the key. There is no
  second event channel. The allowlist rule holds: the companion may
  fire only ids present in the currently registered set — names the
  client itself registered — and `data` is plain JSON shaped per
  trigger type (an SSID string, a battery percentage), never anything
  executable.
- `throttle_s` is a host-side minimum interval between fires of one
  trigger. Threshold types (e.g. battery level) must fire on edge
  crossings computed host-side, never on every underlying broadcast.
- `when` — an optional state gate: a flat array of state predicates
  (see "State predicates & sampling" below), ANDed at fire time. The
  gate guards the **entire** fire: when any predicate does not hold,
  the fire never happened — no `event.action` is queued or delivered,
  no `on_fire` runs, and no `throttle_s` bookkeeping is consumed (the
  gate is checked before the throttle, so a suppressed fire cannot eat
  the slot of a real one). A predicate that cannot be evaluated — an
  ungranted permission, an unknown type — counts as **not holding**:
  fail closed, never fire garbage. There is no OR, no nesting, no
  negation: predicates are two-valued, so a complement is expressed by
  flipping the value; a rule that needs OR is two registrations, or
  logic in Emacs. Companions that support `when` validate it and
  reject the whole set on a malformed gate, like any unknown type.

  **Client rule (normative).** A client may include `when` in a
  registration only when **every** predicate's `type` appears in the
  session's `device.state_types` report (§10). Otherwise it must skip
  the whole registration (with a message) — it must **never** strip
  `when` and push the rest. Rationale: a companion that predates this
  field ignores unknown keys *inside* a trigger entry rather than
  rejecting the set, so a pushed-anyway gate would arm the trigger
  ungated — "notify below 20%" silently becomes "notify always",
  strictly worse than a skip.
- `on_fire` — the companion-local response, executed at fire time even
  with Emacs dead, **in addition to** the `trigger.fired` event (which
  still queues and delivers, so the client always learns of the fire
  and stays the source of truth). A flat list, executed in order, of:

  - `{cap, args?}` — a §10 capability invocation
    (`{"cap": "flashlight", "args": {"on": true}}`);
  - `{notify: {title?, text?}}` — post a simple notification.

  Builtin entries are reserved. This is the one place the companion
  acts on its own, so the vocabulary is deliberately closed: **no
  conditionals, no loops** — a rule that needs logic while Emacs is
  dead means "keep Emacs alive", not a rule language in the companion.
  (`when` is not a conditional in this sense: it is a declarative
  state gate — sampled device state ANDed at fire time — not control
  flow inside the response.) Unknown entries and failing capabilities
  are logged and skipped, never fatal.

  **Placeholders.** String values inside `notify` and inside a `cap`
  entry's `args` (recursively — nested objects and arrays, so
  `intent.start` extras are covered) are interpolated at fire time
  against this fire, using §9's snippet-placeholder grammar:
  `${id}` and `${type}` are the registration's id and type, and
  `${data.FIELD}` is a field of this fire's `data` (e.g.
  `${data.level}`, `${data.ssid}`). The §9 rules apply verbatim —
  substitution is a single pass (substituted text is never re-scanned),
  unknown or unresolvable `${…}` tokens (including a `data.FIELD` that
  is absent or JSON null) are left literal, and the result is always a
  string (a numeric or boolean field renders in its JSON form, `63` /
  `true`). The `cap` name itself never interpolates — capability
  selection is not data-driven. There is no escape mechanism: a literal
  `${id}` in authored text is unrepresentable, as in §9.

### Trigger-type catalog

An empty or absent `params` field means "match every event of the
type". Registering an unknown type is refused (the whole set is
rejected with an error, so the client never half-arms) — which is why
the welcome's `device.trigger_types` (§10) exists: the client filters
its push against that report and skips what this companion can't host.

| type | params | data | notes |
|---|---|---|---|
| `time` | `{at_ms}` one-shot, or `{every_s}` repeating | `{}` | exact alarms (inexact when the exact-alarm permission is revoked); `every_s` clamps to ≥ 60 and re-arms after each fire; survives reboots |
| `power` | `{state?}` — `connected` \| `disconnected` | `{state, plug?}` | `plug` = `ac` \| `usb` \| `wireless` on connect |
| `battery.level` | `{above: pct}` or `{below: pct}` | `{level}` | host-side hysteresis: fires only when the level **crosses into** the configured side, never per raw reading |
| `screen` | `{state?}` — `on` \| `off` \| `unlocked` | `{state}` | `unlocked` = ACTION_USER_PRESENT |
| `headset` | `{state?}` — `plugged` \| `unplugged` | `{state, name?}` | wired audio (ACTION_HEADSET_PLUG); Bluetooth devices are the connectivity batch |
| `airplane` | `{state?}` — `on` \| `off` | `{state}` | |
| `boot` | — | `{}` | fires once per boot from the boot receiver; typically `policy: "queue"` or `"wake"` |
| `timezone.changed` | — | `{tz}` | the new zone id |
| `package` | `{event?, package?}` — `added` \| `removed` | `{event, package}` | update-replacing broadcasts are filtered out |
| `network` | `{event?, transport?}` — `available` \| `lost`; `wifi` \| `cellular` \| `ethernet` \| `vpn` \| `bluetooth` | `{event, transport?}` | the default-network callback (permission-free); fires once per network gain/loss |
| `wifi.enabled` | `{enabled?}` | `{enabled}` | the Wi-Fi *adapter* state — enabled/disabled edges only, transitional states are not edges. Distinct from `network` (radio on ≠ connected) and from the reserved `wifi.ssid`. Install-time `ACCESS_WIFI_STATE`, no runtime grant |
| `bluetooth.enabled` | `{enabled?}` | `{enabled}` | the Bluetooth *adapter* state, same edge discipline. Install-time legacy `BLUETOOTH` (≤ API 30) only; a device without Bluetooth simply never fires it. Distinct from the reserved `bluetooth.device` |
| `calendar.event` | `{event?, calendar?, title_contains?}` — `started` \| `ended`; exact calendar display name; case-insensitive title substring | `{event, title?, begin_ms?, end_ms?}` | a synced calendar (e.g. an org agenda) made reactive, with **zero polling**: one ContentObserver on the instances table plus one alarm per registration parked at the *next boundary* (the ongoing instance's end, else the next matching start, else a lookahead re-scan). Editing an event re-arms via the observer; reboots re-arm from the persisted set; the last ongoing side persists so a boundary alarm in a cold process still fires the flip. Runtime `READ_CALENDAR`: ungranted registrations are skipped with a log — never garbage fires |
| `sms.received` | `{from?, contains?, include_body?}` — `from`/`contains` are substrings; `include_body` defaults false | `{from, body?}` | opt-in, fail-closed privacy: `contains` reads the body to match but `body` rides only under `include_body: true`. Runtime `RECEIVE_SMS`; multipart segments are concatenated. Content is never logged; under `policy: "queue"` the `data` sits in the app-private queue DB, so `policy: "drop"` is recommended for body-carrying rules. Edge-only (no predicate) |
| `call.state` | `{state?, number?, include_number?}` — `ringing` \| `offhook` \| `idle`; `number` a substring; `include_number` defaults false | `{state, number?}` | runtime `READ_PHONE_STATE` for the state edges. **The number needs `READ_CALL_LOG` in addition** (Android 9+): without it a `number`-filtered rule never fires and `include_number` yields no field. Duplicate broadcasts (per phone account, and again with the number) are deduped to one fire. Same never-logged discipline as `sms.received` |

`wifi.ssid` and `bluetooth.device` are the remaining connectivity
batch; each will document its runtime-permission behavior here
(SSID needs fine location — degrade to `network`'s transport-only
matching when ungranted, never fire garbage).

### State predicates & sampling

Some device signals are useful as *levels* (sample-able booleans), not
only as edges. The welcome's `device.state_types` (under the `triggers`
grant, §10) is this companion's catalog of state-predicate types — the
shared vocabulary of `when` gates (above) and `state.get` (§10). It is
negotiated separately from `trigger_types` because sample-ability and
trigger-ability differ: `boot` / `time` / `timezone.changed` /
`package` are edge-only, and `time.window` is predicate-only. Where a
signal has both views it carries the same name in both catalogs, and
sampling costs nothing standing: every sampler is a cached-system-state
read — no listeners, no polling.

A predicate is a flat object: `type` plus type-specific match fields
reusing the trigger catalog's `params` vocabulary. A predicate with no
match fields asserts the type's *natural state*, noted per row:

| type | fields | holds when |
|---|---|---|
| `power` | `{state?}` | the power state equals `state` (default `connected`) |
| `battery.level` | `{above: pct}` or `{below: pct}` | the level is strictly above / below the threshold; exactly the trigger's threshold vocabulary, one bound required |
| `screen` | `{state?}` | `on` / `off` — the screen is interactive or not (default `on`); `unlocked` — the keyguard is dismissed |
| `airplane` | `{state?}` | airplane mode equals `state` (default `on`) |
| `network` | `{transport?}` | a network is connected, and its transport matches when given |
| `headset` | `{state?}` | wired or USB audio output present (`plugged`, the default) or absent (`unplugged`) |
| `wifi.enabled` | `{enabled?}` | the Wi-Fi adapter state equals `enabled` (default `true`) |
| `bluetooth.enabled` | `{enabled?}` | the Bluetooth adapter state equals `enabled` (default `true`); no adapter → unevaluable, so never holds |
| `calendar.event` | `{calendar?, title_contains?}` | a matching calendar instance is ongoing right now; ungranted `READ_CALENDAR` → unevaluable, so never holds |
| `call.state` | `{state?}` | the telephony call state equals `state` (default `offhook`, i.e. on a call); ungranted `READ_PHONE_STATE` → unevaluable, so never holds. `sms.received` has no predicate — a message arrival is an edge, not a level |
| `time.window` | `{after?, before?, days?}` | the local clock is inside the window. `after`/`before` are `"HH:MM"` strings, half-open `[after, before)`; the window wraps midnight when `after` > `before`; an absent bound is open. `days` is an array of `mon`…`sun` filtering on the calendar day of the moment tested; absent = every day. Predicate-only: it has no edge trigger, and `state.get` reports it under `unavailable` |

Sampled state objects (`state.get`'s `states` values) are shaped like
the type's trigger `data` column above, with the level-view
substitutions: `screen` adds `locked` (boolean), `network` reports
`{connected, transport?}` instead of an event, `calendar.event`
reports `{ongoing, title?, end_ms?, next_begin_ms?}`, and `call.state`
reports `{state}` (each ungranted → `unavailable` as `cap-permission`).

## 12. Conformance

A minimal companion implements: the envelope, the handshake with pairing
auth, `surface.update`/`surface.remove` with revision + cache semantics
for `app:*` surfaces, `event.action`/`state.changed`, the offline queue
with `queue.replay`/`queue.drained`, the two builtins, and the widget
families under §9 it can render (unknown nodes render as their children
or nothing, never as a crash). Everything in §7–§8 and §10–§11 is
negotiated or optional.

A minimal client implements: the envelope, the handshake (failing closed
on a bad `server_proof`), monotonic revisions with snapshot absorption,
and the allowlist rule of §5.
