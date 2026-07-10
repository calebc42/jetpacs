# Jetpacs — the Emacs–Android Bridge Protocol

Version: **1 (draft)** · Status: matches the reference implementations in
`emacs/core/` and `app/` · Framing: **NDJSON** (one JSON object per line)

Jetpacs connects a live Emacs to a mobile *companion* that renders
server-driven UI. The design premise: **Emacs is the source of truth; the
companion is a thin pane of glass.** The companion holds no application
logic — it renders the specs it is sent, caches them for offline display,
and reports user interactions back as semantic events.

This document is the contract a third-party implementation writes against:
a new companion (another platform, another toolkit) or a new client
(something other than the reference Elisp). Anything not marked
**(optional)** is required for a conforming implementation.

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
Emacs → companion   session.hello    {protocol, client, wants: [capability...]}
companion → Emacs   auth.challenge   {nonce: SNONCE}
Emacs → companion   auth.response    {nonce: CNONCE, mac}
companion → Emacs   session.welcome  {server_proof, granted, node_types, device?, surfaces, queued_events}
```

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
  `surfaces.dialog`, `capabilities`, `triggers`, `queue.replay`.
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
event.action    {action, args?, when_offline?, dedupe?, surface?, revision?}
state.changed   {id, value}
```

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
`{"builtin": "clipboard.copy", "text": s}`.

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
| `reminders.set`                   | → comp.   | `{reminders: [{title, body, at_ms, ...}]}` — the set **replaces** the previous one, so cancelled items never fire stale; the companion persists it across reboots | optional |

A `dialog.show` spec's **root node** may carry `dialog_style`:
`"sheet"` / `"sheet_full"` render the same tree as a modal bottom sheet
(collapsed / fully expanded — the native idiom for pickers and action
menus); anything else, or its absence, keeps the centered dialog window.
Additive: an old companion ignores the key and centers the dialog. The
elisp side sets it per-call (`jetpacs-send-dialog`'s STYLE) or globally
(`jetpacs-dialog-style`).

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

```
companion → client   edit.open      {file, session, text}                    seed / reseed (seq 0)
companion → client   edit.delta     {file, session, seq, start, del, text, len}
companion → client   edit.caret     {file, session, pos}
companion → client   edit.close     {file, session}
companion → client   edit.complete  {id, session, pos, request_id, ...}      pure query
client → companion   completions.show {id, request_id, prefix, candidates: [{label, annotation?, insert?}]}
client → companion   diagnostics.show {id, session, diags: [{start, end, type, text}]}
client → companion   eldoc.show       {id, session, text}
client → companion   fontify.show     {id, session, runs}
client → companion   edit.resync      {file, session}
```

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
`on_tap` / `on_change` / `on_submit` / `on_save` / `on_pick` /
`on_reorder` / `on_refresh` / `nav_action`. Value-carrying callbacks
(`on_change`, `on_submit`, `on_save`, `on_pick`) dispatch their action
with the widget's current value injected into `args` as `value` — a
switch's `on_change` arrives with `args.value` true/false, a text
input's `on_submit` with the text.

The normative, machine-checked reference for every node's wire shape is
[`test/widgets.golden`](../test/widgets.golden) — one JSON line per
constructor, kept honest by the ERT suite. Summary by family:

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
  `value`. An additive node — negotiate via `node_types` (§3); a
  companion that predates it stacks the pages, so the documented
  fallback is a chip row plus the selected child.
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
  a curated primitive); unknown ops are skipped, never fatal. Both are
  additive nodes — negotiate them via `node_types` (§3) and fall back
  (e.g. a `table`) on a companion that predates them.
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
  `chronometer: {base_ms}`) above a body of content nodes.

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
                       "bluetooth_connect": false},
             "trigger_types": ["airplane", "battery.level", "boot", "..."]}
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

## 11. Device triggers (optional)

The device → Emacs *event source* path: the companion watches device
state (time, power, screen, connectivity, …) and reports changes the
client subscribed to — durable the same way its UI serving is durable.
Negotiated under the `triggers` capability name; a companion that
cannot host triggers does not grant it, and a client must not send
`triggers.set` without the grant.

```
triggers.set   {triggers: [{id, type, params?, policy?, dedupe?,
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
  Unknown entries and failing capabilities are logged and skipped,
  never fatal.

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

`wifi.ssid` and `bluetooth.device` are the remaining connectivity
batch; each will document its runtime-permission behavior here
(SSID needs fine location — degrade to `network`'s transport-only
matching when ungranted, never fire garbage).

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
