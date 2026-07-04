# EABP — the Emacs–Android Bridge Protocol

Version: **1 (draft)** · Status: matches the reference implementations in
`emacs/core/` and `app/` · Framing: **NDJSON** (one JSON object per line)

EABP connects a live Emacs to a mobile *companion* that renders
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
companion → Emacs   session.welcome  {server_proof, granted, surfaces, queued_events}
```

- **Pairing token.** The companion generates a secret token shown once in
  its pairing UI; the user copies it into their Emacs init. The token
  itself never crosses the wire.
- **Mutual proof (HMAC-SHA256, lowercase hex, keyed by the token):**
  - client `mac`  = `HMAC(token, "eabp1:client:" + SNONCE + ":" + CNONCE)`
  - `server_proof` = `HMAC(token, "eabp1:server:" + CNONCE + ":" + SNONCE)`
  - Nonces need uniqueness, not secrecy. Both sides fail closed: a wrong
    client mac is refused before any state is trusted; a missing or wrong
    `server_proof` makes the client drop the connection (a rogue app
    squatting the port cannot impersonate the companion).
- **Capability negotiation.** `wants` is the capability set the client
  requests; the companion grants the intersection with what it supports
  (`granted` in the welcome). Unrecognised capabilities are silently not
  granted. v0 capability names: `surfaces.widget`, `surfaces.notification`,
  `surfaces.dialog`, `capabilities`, `triggers`, `queue.replay`.
- **Revision snapshot.** `surfaces` maps each cached surface id to the
  revision the companion holds, so a client whose revision counter was
  lost (fresh machine, deleted state) can raise it above the cache floor
  before pushing. `queued_events` is the number of offline events waiting
  for replay.

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
registers the handler; the core reserves `eabp.*`, `nav.*`, `view.*`,
`dialog.*`, `edit.*`, `tablist.*`, `settings.*`, `prompt.*`,
`dashboard.*`, `files.*`, `emacs.*`, `packages.*`, `transient.*`,
`share.*`, `demo.*`, `witheditor.*`.

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
| `reminders.set`                   | → comp.   | `{reminders: [{title, body, at_ms, ...}]}` — the set **replaces** the previous one, so cancelled items never fire stale | optional |

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
client → companion   completions.show {id, request_id, prefix, candidates: [{label, annotation?}]}
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

## 9. Widget vocabulary

Specs are trees of nodes; every node is `{"t": type, ...}` and unknown
keys must be ignored (forward compat). Actions embed as objects under
`on_tap` / `on_change` / `on_submit` / `on_save` / `on_pick` /
`on_reorder` / `on_refresh` / `nav_action`.

The normative, machine-checked reference for every node's wire shape is
[`test/widgets.golden`](../test/widgets.golden) — one JSON line per
constructor, kept honest by the ERT suite. Summary by family:

- **Content**: `text` (style/color/syntax/selectable), `rich_text` +
  styled `spans` (emphasis, `color`/`bg` hex overrides, `mono`, tap
  links), `icon`, `image`, `date_stamp`, `divider`, `section_header`,
  `empty_state`, `progress`.
- **Layout**: `row`, `column`, `flow_row`, `lazy_column`, `box` (weight /
  alignment / tap), `surface` (tonal container), `card`, `spacer`,
  `collapsible` (folds on-device), `reorderable_list` (drag to reorder,
  reports via `on_reorder`).
- **Input**: `button`, `icon_button`, `chip`, `assist_chip`, `menu`,
  `checkbox`, `switch`, `text_input` (optional `password` masks entry and
  requests a password keyboard; such values must not be logged or
  retained), `enum_list` (single/multi select, optional free-add),
  `date_button` / `time_button` (native pickers),
  `editor` (full editor: save/undo header, optional `syntax`, gutter
  `line_numbers`, `complete` for the completion strip, `chromeless`,
  `publish_state`, and a server-chosen `toolbar` — `"org"` today).
- **Chrome**: `scaffold` (top_bar / bottom_bar / fab / drawer / snackbar /
  pull-to-refresh), `top_bar`, `bottom_bar` + `nav_item`, `drawer` +
  `drawer_item`, `fab`.
- **Notification specs** add `meta` (channel, ongoing, category, priority,
  `chronometer: {base_ms}`) above a body of content nodes.

## 10. Conformance

A minimal companion implements: the envelope, the handshake with pairing
auth, `surface.update`/`surface.remove` with revision + cache semantics
for `app:*` surfaces, `event.action`/`state.changed`, the offline queue
with `queue.replay`/`queue.drained`, the two builtins, and the widget
families under §9 it can render (unknown nodes render as their children
or nothing, never as a crash). Everything in §7–§8 is negotiated or
optional.

A minimal client implements: the envelope, the handshake (failing closed
on a bad `server_proof`), monotonic revisions with snapshot absorption,
and the allowlist rule of §5.
