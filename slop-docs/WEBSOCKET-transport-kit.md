# Transport kit: EBP 2 over WebSocket (websocket.el, read not remembered)

**Status: Claude-authored reference sketch. Not code, not spec.** This kit
records a full source read of `websocket.el` and what an EBP 2 WebSocket
transport profile would have to say — the browser-companion door. Sketch
policy matches the JSON-RPC conversion kit: verified facts with line
references, described exercises, no finished implementations.

**Verification note:** every `:N` reference below is against
`websocket.el` **v1.16** (git 2195e12, ahyatt/emacs-websocket, cloned at
`~/pkb/resources/emacs/emacs-websocket`), read end to end 2026-07-19.
The companion evidence file is `~/pkb/resources/emacs/browsel` (dmg's
browsel v0.93), a production Emacs-as-WS-server bridge over this library
— cited where it independently confirms a finding. One cosmetic drift
inside the library itself: the package header says 1.16 (:8) while the
`websocket-version` defvar still says "1.12" (:105-106) — pin the
package version, not the defvar.

## 1. Why this kit exists

A browser extension or page cannot hold a raw TCP socket; WebSocket is
its only bidirectional transport. The ebp README's "a web view is just
as conformant" claim is therefore false under the current §1 transport
row — a browser companion needs a WS profile, and `websocket.el` is the
elisp side of one: pure-elisp RFC 6455, client AND server mode, no
dependencies beyond cl-lib (:9).

The load-bearing observation: **EBP roles and transport roles decouple.**
EBP 2 keeps Emacs as the protocol client (it sends `session.hello`) and
the renderer as the companion, regardless of who dialed the socket. The
only inversion a WS profile makes is *who listens*: the extension can
only dial out, so Emacs runs `websocket-server` and the companion
connects — the durability story flips with it, correctly, because on a
desktop Emacs is the durable end (the phone-side "companion is the
durable server" logic was Android-lifecycle reasoning, not protocol
reasoning).

## 2. What the library actually does (source-verified)

| concern | verdict | evidence |
|---|---|---|
| server mode | yes — `websocket-server`, per-client `websocket` structs via the accept log-fn, binary coding set per client | :872-895, :910-940 |
| bind address | `:host` plist, `'local` = loopback; **`:family 'ipv4` hardcoded** — no Unix-domain-socket option | :884-894 |
| server TLS | none (plain `make-network-process` only; wss exists client-side only) | :884-894 vs :713-719 |
| handshake, server side | requires HTTP/1.1, Host, Upgrade, Sec-WebSocket-Key, Version 13; bad handshake → 400 + close | :1054-1089, :1041-1043 |
| **Origin** | parsed and stored on the struct, **never validated** — any web page may connect to a local port | :1087-1088, :1038 |
| ping/pong | **auto-pong with echoed payload, inside the library** — transport-level liveness is free | :523-528 |
| close | inbound close → bare `delete-process`; outbound close frame carries no status code (`websocket-check` forbids close payloads) | :529-530, :566-568 |
| masking | client→server frames unmasked are **accepted** (RFC 6455 says a server MUST fail them); masking itself is a per-byte elisp loop | :388-390, :316-325 |
| fragmentation | **not reassembled** — continuation frames reach `on-message` raw with a `completep` flag; the caller accumulates (browsel's `rx-buffers` exists precisely for this) | :533-546, :309, browsel.el:319-340 |
| receive-side size cap | **none.** `websocket-frame-too-large` is send-side only; a declared 64-bit length simply accumulates in `inflight-input` until parseable — one hostile frame header balloons the heap below any caller-level check | :456-459, :249-258, :280-307, :792, :1018 |
| text encoding | send is `raw-text` of the payload (:553-554), receive decodes utf-8 (:311-314) — round-trips for Unicode text, but the profile should pre-encode utf-8 explicitly and treat `websocket-send-text` as byte-pass-through of a unibyte string |
| send buffering | `bufferedAmount` unimplemented and the struct doc says why: *"there is no elisp API to get the buffered amount from the subprocess"* — the library itself testifies that transport-level sender backpressure is unmeasurable in elisp | :71-75 |
| big-frame perf | frame loop re-`substring`s the remaining accumulation per frame; unmasking is per-byte elisp — multi-MB frames are O(big) in the interpreter where our Content-Length filter does two substrings and no per-byte work | :533-546, :316-325 |

## 3. The profile sketch (what a SPEC-2 §1 transport row would say)

1. **Mapping.** One JSON-RPC 2.0 message per WS **text message** (not per
   frame). No `Content-Length` header — WS frames itself; §2.2's framing
   paragraph is superseded by this row, everything else in §2 carries.
   Batch prohibition, id rules, error objects: unchanged.
2. **Who listens.** Emacs serves on loopback (`:host 'local` — bind
   nothing else), companion dials `ws://127.0.0.1:<port>`. EBP roles
   unchanged: Emacs still opens with `session.hello` once the socket is
   up (on-open fires server-side per connection, :1039-1040).
3. **Auth is unchanged and is the real gate.** Any web page can open a
   socket to a loopback port (the library checks no Origin) — the §3
   HMAC pairing already fail-closes drive-by pages: they can be
   challenged and cannot MAC. The profile should additionally REQUIRE
   the server to check `websocket-origin` against an allowlist at
   on-open and close on mismatch — cheap, and it keeps unpaired-port
   probing out of the logs. Origin is on the struct (:1038); one
   `assoc`-and-close in on-open.
4. **The frame cap becomes a message-accumulation cap** — and the skip
   dividend is partly recoverable. Reassembly is the caller's job
   anyway (§2 table), so the profile rule is: accumulate fragments per
   connection; if the accumulation would exceed the cap, drop the
   accumulator, set a discard-until-FIN flag, report `1400
   frame-too-large` on `log.error`, and **keep the connection** —
   strictly better than browsel's disconnect (browsel.el:146-153), and
   the same observable behavior as the TCP profile's byte-exact skip.
   Residual gap, stated honestly: a single giant *frame* (not message)
   accumulates inside the library's `inflight-input` before the caller
   ever sees it; with an authenticated loopback peer this is a
   negligible risk, and a paranoid deployment bounds it with a one-line
   advice on `websocket-outer-filter`/`websocket-server-filter`. The
   1401 bounded-queue rule and the whole of §5 port verbatim — WS above
   TCP has no application flow control either, and the library's own
   bufferedAmount note (:71-75) is independent confirmation that
   `revision_seen` remains the only real sender-side gauge.
5. **Liveness returns, at the right layer.** SPEC-2 dropped app-level
   ping/pong; the WS profile gets transport keepalive free
   (auto-pong, :523-528) — exactly the "transport keepalive is the
   alternative" the method table anticipated.
6. **Encoding rule.** Serialize JSON, `encode-coding-string` utf-8,
   hand the unibyte string to `websocket-send-text` (raw-text of
   unibyte = pass-through, :548-555). Never hand it multibyte text with
   exotic content — the library would emit its internal encoding.
7. **What this profile cannot offer:** the 1.0 Unix-domain-socket
   target (`:family 'ipv4` hardcoded, :887) and server-side TLS. Both
   fine on loopback; neither acceptable off-box — which the profile
   should simply forbid (bind `'local`, full stop).

## 4. Where it goes

Not the manifesto: one new row in SPEC-2 §1's transport line
(`loopback TCP (v0) → Unix domain socket (1.0 target) | WebSocket
(browser-companion profile)`), one short paragraph per §3 above in the
transport section, and a new §16 owner decision: *"7. Whether the
browser-companion WS profile ships as spec text or waits for a working
extension companion (this kit is the quarry either way)."* The overload
section needs zero changes — that is the layer stack paying out again.

## 5. Exercises (the katas, described not implemented)

1. **Echo over WS:** `websocket-server` in one Emacs, `websocket-open`
   in another, one text message each way; watch `websocket-debug`
   buffers. (Feel the auto-pong by sending a ping.)
2. **Handshake kata:** the browser side is 15 lines of extension
   background-script JS: `new WebSocket("ws://127.0.0.1:8765")`, send
   the EBP hello *as the companion expects to receive it* — i.e. wait
   for Emacs's `session.hello` request and answer `{nonce}`. This kata
   is where the role/transport decoupling clicks.
3. **The cap kata:** send a 3-fragment message with the middle fragment
   pushing past a 1 KiB test cap; verify discard-until-FIN keeps the
   connection and the next message dispatches — the same shape as
   `ContentLengthFrameCodecTest.oversizedInboundBodyIsSkippedByteExactly`.
4. **The drive-by kata:** from an arbitrary web page's devtools console,
   `new WebSocket("ws://127.0.0.1:8765")` — confirm the Origin check
   closes it at on-open, and that without the check it parks unpaired at
   the 1200 wall.
