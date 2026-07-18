# Audit: crdt.el pair editing in a Tier-1 app (Glasspane)

**STATUS (2026-07-17): assessment only — no code follows from this doc.**
An adoption audit of [crdt.el](https://elpa.gnu.org/packages/crdt.html)
(GNU ELPA, Qiantan Hong; LogootSplit CRDT, pure elisp) answering: what
would real-time collaborative editing entail for a Tier-1 app, and where
would it break? The recommended scope, if this is ever built, is
**pair editing** — two humans, two Emacsen, one shared org buffer — and
nothing wider. No jetpacs core, companion, or wire change is required;
that is the headline finding, not an omission.

## Verdict

Feasible as an opt-in Glasspane feature, surprisingly cheap on the
jetpacs side, and architecturally clean — because collaboration is a
**brain↔brain** concern and ebp is a **brain↔face** protocol. crdt.el
synchronizes buffers between Emacs processes on its own TCP channel;
jetpacs never sees the CRDT traffic, only its effects (ordinary buffer
modifications), which the existing rendering paths already propagate to
the phone. The wire's surface revisions are strictly-newer
last-write-wins per client ([ebp/SPEC.md](../ebp/SPEC.md) §4) — the
opposite of merge semantics — so CRDT framing must never ride ebp, and
with crdt.el it never needs to.

crdt.el is the **wrong tool for single-user multi-device sync**:
sessions are ephemeral, the host must be up, and it shares *buffers*,
not files or vaults. Own-device sync stays with file sync (Syncthing
across N brain+face pairs, working today) or TRAMP. Pair editing —
a deliberate "share this note with a person for this hour" — is what
LogootSplit is for, and what this audit scopes to.

## What the phone would show, for free

The Tier-0 buffer renderer already carries everything crdt.el paints:

- [`jetpacs-buffer.el:3-16`](../emacs/core/jetpacs-buffer.el) renders
  any buffer from its text plus text/overlay properties (face, display,
  invisible, button, mouse-face). crdt.el's author coloring is
  text-property faces and its remote cursors/selections are
  background-styled overlays — both land in the same extraction.
- [`jetpacs-buffer.el:129-155`](../emacs/core/jetpacs-buffer.el)
  (`jetpacs-buffer--span-style`) emits `:color` *and* `:bg` whenever
  they differ from the default face, exactly the shape of author tints
  and cursor blocks. No new node types, no wire change.
- [`jetpacs-emacs-ui.el:170-247`](../emacs/core/jetpacs-emacs-ui.el):
  while a buffer is drilled into, a 1 s timer compares
  `buffer-chars-modified-tick` and re-pushes on change. A remote peer's
  edit is an ordinary buffer modification → it appears on the phone
  within the poll interval. Caveat: an **overlay-only** change (remote
  cursor moved without typing) bumps no tick and triggers no push, so
  cursor positions on the phone update only when text next changes.
  Acceptable at two peers; do not "fix" it with overlay hooks — that
  would trade a cosmetic lag for poll-storm risk.

So the passive experience — watching a pair-editing session live from
the phone, author colors and all — costs **zero** new code. That is the
impressive demo, and it falls out of the existing architecture.

## Where it bites

### 1. The phone editor vs. remote edits (resync churn)

The §8 shadow-buffer sync deliberately has **no after-change hook**:
external mutation of a synced buffer is caught *lazily*, when the next
phone delta's expected-length check fails →
`jetpacs-sync-request-resync` → the phone answers with a fresh
`edit.open` ([`jetpacs-sync.el:13-17,244-255,641-665`](../emacs/core/jetpacs-sync.el)).
The invariant holds — "wrong state can only ever cause a missing
feature, never a wrong edit" — but a live phone-editor session on a
buffer a remote peer is actively typing into converges by **repeated
full reseeds**, each one yanking the phone's editor state. Usable
pattern: the phone is a *viewer* (Tier-0 live buffer view) of a shared
note; a full editor session on a shared note should warn or refuse.
That guard is future work, named here, not designed.

### 2. Glasspane's save model vs. concurrent edits (lost updates)

The detail editor extracts the subtree as plain text and saves it back
as a full-text replace
([`glasspane-detail.el:512-527`](file://wsl.localhost/Debian/home/calebc42/pkb/projects/Glasspane/emacs/apps/glasspane/glasspane-detail.el),
`on_save` → `detail.save` through the app's one mutation funnel
[`glasspane-ui--at-ref`, `glasspane-ui.el:286-317`](file://wsl.localhost/Debian/home/calebc42/pkb/projects/Glasspane/emacs/apps/glasspane/glasspane-ui.el)).
Open-edit-save spans minutes; every remote edit to that subtree inside
the window is silently overwritten on save. The fine-grained at-ref
mutations (`org-todo`, `org-schedule`, tags) are near-atomic and safe.
A pair-editing feature must either scope shared notes out of the
full-replace path or accept last-save-wins with eyes open.

### 3. Files, saves, and the double-channel rule

Host-side deferred saves
([`jetpacs-org.el:452-460`](../emacs/core/jetpacs-org.el)) are safe:
in a crdt session only the host owns the file; clients edit a network
buffer. Hard rule: **never share a note over crdt and Syncthing at the
same time** — two sync channels for one file is how silent conflict
loops are built. If the pair partner also holds the vault via file
sync, the shared buffer must be treated as the single live copy for the
session's duration.

## Topology, battery, trust

- crdt.el defaults to **Emacs-as-TCP-server** (port 6530) — hostile on
  Android for the exact reason ebp inverted its dial direction (the OS
  kills listeners). Realistic shapes: desktop Emacs hosts and the
  phone's Termux Emacs dials out; or both peers tunnel via SSH/VPS
  (crdt.el's tuntox integration is the decentralized fallback, with
  ~30 s connection setup).
- Battery: a persistent second socket plus edit-churn re-renders. Per
  the roadmap's standing battery gate, this is a *measure-first*
  feature — the devtools push metrics already capture the re-render
  side.
- Trust: a separate channel that never touches the ebp action allowlist
  or the nothing-on-the-wire-is-code doctrine. crdt.el session auth is
  password-only, so recommend tunneled transport by default; do not
  extend sharing to comint buffers (the known history-ring risk class
  from crdt.el's own docs).

## Risks

| Risk | Exposure at N=2 | Notes |
|---|---|---|
| Elisp CRDT math + GC pauses | Low | crdt.el's documented ceiling is many peers / huge docs; a pair on an org note is its easy case. Emacs slowness degrades the *phone* to staleness, never jank. |
| Overlay proliferation | Low | Two cursors, two selections. The pathological cases need dense multi-user sessions. |
| `crdt-org-sync-overlay-mode` vs. Glasspane fold model | Untested | Both want to own org visibility state; the reader's client-side folding may fight synced overlays. Off by default if built. |
| Upstream health | Medium | Single-author ELPA package; mirror current as of 2026-06. An adoption should pin and smoke-test against the Emacs 30 floor's predicates, not assume. |
| Editor-id stability | Low | The detail editor keys on buffer position (`detail-<pos>`); remote structural edits shift positions between pushes. Refs resolve robustly, but worth a test if built. |

## Non-goals

- **No CRDT framing on ebp, ever.** The wire stays snapshot + LWW
  revisions; collaboration effects reach the phone as ordinary frames.
- **No multi-user jetpacs surfaces** — one owner per brain; the peer
  brings their own Emacs.
- **No own-device sync via crdt** — that's file sync's job.
- If pair editing is ever built, it is a Glasspane opt-in command pair
  (share/unshare) wrapping `crdt-share-buffer` at the
  `glasspane-ui--at-ref` funnel, plus the phone-editor guard from §1
  above. Named as the seam; deliberately not designed further here.
