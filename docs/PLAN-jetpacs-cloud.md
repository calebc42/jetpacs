# Plan: jetpacs-cloud — the browser companion, first prototype on EBP 2

**STATUS (2026-07-19): proposed.** The first thing built *on* the new
wire rather than *for* it. Builds on the envelope swap (`06f83fe`,
SPEC-2 amendment #27), `ebp/slop-docs/WEBSOCKET-transport-kit.md` (the
websocket.el v1.16 source read), and browsel as prior art
(`~/pkb/resources/emacs/browsel`). This plan is also the answer to the
kit's §4 question: the WS transport profile's spec text **waits for
this working companion** — prototype first, then the SPEC-2 §1 row.

## Why (plain language)

A traditional server-client model at last: Emacs listens, and the
jetpacs-cloud page — a browser tab — dials in. Four reasons this is the
right first 2.0 prototype:

1. **It is the second conforming companion**, built from
   `ebp/contract.json` (format 5) + SPEC-2 + the goldens, in a language
   and runtime that share nothing with the Kotlin reference. That is
   the whole point of the contract repo, exercised for real: if a
   browser page can reach rung 4 from the published artifacts, the
   format-5 contract earns its keep.
2. **It proves the role/transport decoupling.** EBP roles do not
   invert: Emacs stays the protocol client (it sends `session.hello`)
   even as the WS listener; only the dial direction flips, and on a
   desktop the durable end IS Emacs. If the handshake runs unchanged
   over this topology, §3 is transport-clean.
3. **It is the §5 overload lab.** A browser is the perfect drowning
   companion: DevTools CPU throttling makes "the phone can't keep up"
   reproducible on demand. Rung 3 is a live demonstration of both
   conflation halves and the `revision_seen` lag gauge stretching the
   coalescing window — the backpressure work, visible.
4. **Iteration speed.** No mobile toolchain, no deploy loop; the wire
   inspector is the Network tab. Protocol katas land in minutes.

The name is the endgame: a page that can be served from anywhere (the
cloud) yet renders *your* Emacs, because it dials `ws://127.0.0.1` —
the data never leaves the machine. The prototype starts local
(file:// / localhost); the hosted page is the stretch goal, gated on
the mixed-content nuance below.

## What it is not

- **Not browser control.** No tabs, no page scraping, no extension
  APIs — that is browsel's lane (and why jetpacs-cloud needs no
  extension at all; a plain page can open a loopback WebSocket).
- **Not multi-companion.** One active session, supersede-on-accept —
  exactly `JetpacsServer`'s single-client model. Phone + browser on one
  Emacs concurrently is a separate plan with known hard parts
  (per-connection session/grants, broadcast pushes; note the global
  monotonic revision counter already makes LWW hold across companions).
- **Not the org app.** It renders whatever surfaces Emacs pushes
  (`app:dashboard` first); it adds no vocabulary.

## Repo shape

`cloud/` at the llm-poc root, mirroring `app/` (the Android companion's
home):

| file | role |
|---|---|
| `cloud/jetpacs-cloud.el` | Emacs side: `websocket-server` lifecycle, accept/supersede, Origin gate, the on-message → `jetpacs--handle-frame` bridge |
| `cloud/index.html` + `cloud/jetpacs-cloud.js` | the companion: envelope, handshake (Web Crypto HMAC-SHA256), DOM renderer, event dispatch, localStorage cache + offline queue |
| `cloud/README.md` | pairing walkthrough + the rungs' test recipes |

`jetpacs-cloud.el` requires `websocket` (the external package) and
therefore lives **outside** `emacs/core/` and outside the bundle: the
core's package-vc install path stays dependency-free, and
core-load-test never sees it. Users load it explicitly.

## The one core change: the transport seam

jetpacs.el is already transport-neutral above two lines: inbound,
`jetpacs--handle-frame` takes decoded JSON text (WS on-message can call
it directly); outbound, every sender funnels through the
Content-Length encoder. The seam is three function cells, TCP defaults
preserved byte-for-byte:

1. `jetpacs--send-message MESSAGE` — one funnel under `jetpacs-send` /
   `jetpacs-request` / `jetpacs--respond` / `jetpacs--respond-error`,
   dispatching through a `jetpacs-transport-send-function` defvar
   (default: today's encode-frame + raw-send; cloud: utf-8 pre-encode +
   `websocket-send-text`, per kit §3.6).
2. A transport-live predicate replacing the two inline
   `(process-live-p jetpacs--process)` checks.
3. The hello trigger: the TCP sentinel keeps calling
   `jetpacs--send-hello` on "open"; jetpacs-cloud calls the same
   function from the server's per-connection on-open.

Everything above the seam — pending table, request/response
correlation, dispatch, fail-closed refusals, handshake, hooks, surface
conflation, the lag gauge, the frame observer — is untouched and
shared. The existing ERT suite pins the TCP default; the seam refactor
must land green with zero golden churn before `cloud/` begins.

## The wire, as exercised (nothing new; everything fresh)

- **Envelope/handshake:** full §2 + §3 over WS text messages, one
  JSON-RPC message per message, no Content-Length (kit §3.1). Pairing
  UX mirrors the Android screen: the page shows a token field; the
  token lives in localStorage, never on the wire; MAC via
  `crypto.subtle` (secure context: file:// and localhost both qualify).
- **Grants:** the browser `wants` little and is granted less —
  `{queue.replay, theme}` to start (no triggers, no device
  capabilities; rendering `app:*` surfaces is core, not negotiated).
  The negotiation model absorbs a radically weaker companion with zero
  protocol changes — worth stating in the demo notes.
- **Frame cap:** the kit §3.4 rule — per-connection fragment
  accumulation, over-cap → drop accumulator, discard-until-FIN, report
  `1400` on `log.error`, keep the connection. Both sides.
- **Overload:** §5 verbatim. Browser-side conflation is nearly free:
  render through a `requestAnimationFrame`-coalesced latest-spec slot
  per surface (the StateFlow idiom in DOM clothes).
- **Security:** bind `'local` only; Origin allowlist at on-open
  (default: the page's own origin; note file:// presents Origin
  `null` — allow it only when explicitly configured); the HMAC wall
  stays the real gate (a drive-by page parks at the 1200 refusals,
  unpaired and unMAC'd).

## Rungs (each ends runnable; BUILDING-COMPANION.md's ladder, re-rooted)

- **Rung 0 — dial + handshake.** Page connects, answers
  `session.hello` with the nonce challenge, verifies `auth.response`'s
  MAC, responds with the welcome (`server_proof`, `granted`,
  `node_types` = the DOM renderer's actual catalog, empty `surfaces`,
  `queued_events` 0). Exit: `jetpacs-connected-p` true, granted set on
  screen, `*Messages*` shows the paired handshake.
- **Rung 1 — render + cache.** `surface.update` → DOM for a starter
  node subset (`text`, `rich_text`/spans, `row`, `column`, `card`,
  `button`, `section_header`, `lazy_column`, `divider`); revision guard;
  spec cache in localStorage rendered **before** connecting (design
  principle #1: Emacs gone is the default state, not an error);
  unknown node types degrade per §11. Exit: `app:dashboard` renders;
  reload shows it offline.
- **Rung 2 — events + queue.** `on_tap` → `event.action`
  `{surface, revision_seen, action, args}`; `when_offline`
  queue/drop in localStorage with `dedupe` collapse and `ttl_s`;
  serve `queue.replay` (oldest-first, delete-after-write, drain
  summary as the response). Exit: a dashboard button round-trips live;
  the same tap offline replays on reconnect.
- **Rung 3 — the overload lab.** DevTools CPU throttle ×6 + a
  deliberate push storm from Emacs (the devtools tripwire's own
  threshold as the storm source). Watch: browser conflation counter
  climbing, `revision_seen` trailing, `jetpacs-surfaces--lag-streak`
  stretching the window, recovery snapping it back. Exit: the demo
  writes its numbers into `cloud/README.md`.
- **Rung 4 — conformance.** Every `widgets.golden` line through the DOM
  renderer (render or degrade, never throw); every `frames.golden` line
  through the JS envelope parser (id-ness matches class, params keys
  validate against the contract). Node-runnable so CI can carry it
  later. Exit: the third implementation is held to the same truth.

Then, and only then: the SPEC-2 §1 transport row + §16 decision 7 get
written from evidence, and SPEC-CHANGES logs it with this plan and the
kit as sources.

## Risks

- **websocket.el's receive-side gap** (kit §2): a single hostile frame
  header balloons `inflight-input` below our accumulation cap. On an
  authenticated loopback this is accepted for the prototype; the
  one-line advice bound is noted in the kit if it ever isn't.
- **file:// Origin `null`** weakens the allowlist to
  explicitly-opted-in; the HMAC wall carries the load (as designed).
- **Hosted-page mixed content:** an https page opening `ws://127.0.0.1`
  is allowed by modern Chrome/Firefox (loopback is potentially
  trustworthy) but not guaranteed everywhere — which is why hosted
  stays a stretch goal, not a rung.
- **Seam regression in core:** mitigated by landing the seam alone
  first, against the untouched test suite.

## Order

1. The transport seam in jetpacs.el (tiny, green, zero golden churn).
2. `cloud/` rung 0 → 4, in order; each rung a commit.
3. Spec text (SPEC-2 §1 row, §16 decision 7 resolved, SPEC-CHANGES row)
   written from the working prototype.
