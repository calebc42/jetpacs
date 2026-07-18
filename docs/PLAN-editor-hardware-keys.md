# Plan: external keyboards — TAB, prefix arguments, and full chord passthrough

## Why (plain language)

Plug a Bluetooth keyboard into the phone today and the Tab key types a tab
character — it never accepts a completion and never re-indents, because the
Android text field swallows the key before Jetpacs sees it. Ctrl-chords are
either handled locally (copy/paste) or silently dropped: `C-c C-c` is
literally "copy, copy." And independently of keyboards, many Emacs commands
do something extra when *prefixed* (`C-u M-x`, `C-u C-c C-c`, `M-3 M-f`) —
the phone has no way to say that at all.

Three deliverables, two phases:

- **Phase 1** teaches the editor a handful of keys (Tab, Shift+Tab, Esc,
  Ctrl+S, completion-strip navigation) and adds the **touch prefix-argument
  affordance**: a "C-u" chip on the editor toolbar you arm before tapping a
  command chip, hold-a-chip-to-run-with-C-u, and a numeric-count dialog.
  Protocol-light: one optional `prefix` arg on existing actions, one new
  toolbar op.
- **Phase 2** forwards **arbitrary chords** (`C-c C-c`, `M-<`, `<f5>`…) to
  Emacs as key-description strings, resolved by the buffer's own keymaps,
  run on the 1.26 DWIM machinery, results spliced back as `edit.apply`.

Everything rides the point/region layer (amendment #14): commands run at
your real point/region in the sync session, and the §8 invariant extends
end-to-end — wrong state loses a keystroke's *effect*, never corrupts text.

**Design provenance**: two independent designs + an adversarial review that
empirically tested the subtle elisp mechanics in batch Emacs 30.1. Two
original mechanisms were disproven and are corrected below (marked ⚠).

## Shared foundations (both phases)

### One key-decision ladder

A single shared `Modifier.onPreviewKeyEvent` on both `SduiEditor` field
branches ([SduiInputNodes.kt:532-544](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiInputNodes.kt), :611-623),
`KeyDown` only, built as a **pure decision function** (JUnit-testable) plus
a thin effectful wrapper. Precedence, fixed now so the phases never fight:

1. `readOnly` → intercept nothing.
2. `state.composition != null` (IME mid-composition) → intercept nothing.
3. **Completion strip visible** → strip keys win: Tab accepts the
   highlighted candidate (companion-side insertion, normative), Ctrl-N/P
   cycle, arrows cycle *only after* the strip is engaged by a first
   Tab/Ctrl-N (plain ArrowDown must keep moving the caret), Esc dismisses.
4. **Unmodified Tab** → Phase-1 path *in both phases*: route
   `indent-for-tab-command` through the `pendingCommand` seam (only when
   `completeEnabled && connected && client ≥ 1.26`, else fall through and
   insert `\t` as today). Phase 2 never forwards bare Tab — forwarding
   `<tab>` in an org shadow resolves `org-cycle`, whose fold change renders
   nothing on the phone: an invisible no-op that erodes trust.
5. **Ctrl+S** → the Save-button body (both phases; never forwarded — the
   shadow never writes disk, §8 invariant). Consume always; dispatch
   `on_save` only when `modified` (the button's own gate); mirror
   `seed = text`. Chromeless/no-`on_save` editors: fall through.
6. **Shift+Tab** → strip visible: cycle back; else consume-as-noop
   (a literal `\t` is never right; org outline cycling renders nothing
   phone-side — revisit when fold state can render).
7. **Phase 2 only, kill-switch on, client ≥ 1.28**: the chord-forwarding
   policy below.
8. Everything else → `false` (Compose defaults: local clipboard, undo,
   caret motion, typing).

### One prefix encoding (⚠ corrected)

One wire encoding for `current-prefix-arg` across **all** carriers
(`edit.command`, `edit.key`, `jetpacs.keymap.run`, `emacs.mx.show`):
absent = none · JSON integer = count · `"u"`/`"uu"`/`"uuu"` = raw
C-u×1/2/3 → `'(4)`/`'(16)`/`'(64)` · `"-"` = bare negative. One shared
decoder `jetpacs-decode-prefix` in jetpacs.el; unknown values decode to
nil. *The original Phase-2 draft used a one-element JSON array for raw C-u
— dead on arrival: inbound frames parse with `:array-type 'list`
([jetpacs.el:312](../emacs/core/jetpacs.el)), so `[4]` arrives as a list
and a vector check never matches. Strings only.*

### Version / amendment numbering

Phase 1 = next api minor + next SPEC amendment; Phase 2 = the ones after.
Nominally 1.27.0/#15 and 1.28.0/#16 **on this branch's ebp lineage** (ours
ends at #14 = point/region) — but amendment numbers are now contested
across three in-flight branches (fluid-editing's #14, ours, the
liveview-gap #14–16), so treat numbers as *next-free at merge time*, and
rebase Phase 2's diffs on Phase 1's (both edit jetpacs-sync.el and
jetpacs-lint.el).

---

## Phase 1 — keyboard basics + prefix arguments

### 1a. Completion-strip keyboard selection

- Hoist the strip's visible-list computation
  ([SduiInputNodes.kt:726-765](../jetpacs/src/main/java/com/calebc42/jetpacs/SduiInputNodes.kt))
  into a pure `completionVisible(...)` helper; hoist a `highlighted` index
  (reset on payload/request change; default 0 so bare Tab accepts the top
  suggestion); factor the chip `onClick` body (:778-789) into
  `acceptCompletion(state, view, index)` — tap and Tab share it, one
  `state.edit {}` = one undo step. Highlighted chip renders selected
  (`FilterChip(selected=…)`).
- Enter deliberately untouched (accept-on-Enter causes accidental accepts;
  "the phone's TAB" comment becomes literal).

### 1b. Prefix arguments — wire and elisp

- `prefix` (encoding above) as an optional arg on `edit.command`,
  `jetpacs.keymap.run`, `emacs.mx.show`. Args are unenumerated in the
  contract → SPEC-prose + implementations; old Emacs ignores the key
  (command runs unprefixed — document under §12 compat).
- **`edit.command`** ([jetpacs-sync.el](../emacs/core/jetpacs-sync.el)
  `jetpacs-sync-run-command`): bind `current-prefix-arg` around the whole
  execution block *including* the bridged M-x `completing-read` (matches
  desktop `C-u M-x foo`; make code and prose agree — the binding is read
  by `call-interactively`, verified empirically: recorder saw the prefix).
- **`emacs.mx.show`** ([jetpacs-emacs-ui.el:519-540](../emacs/core/jetpacs-emacs-ui.el)):
  handler gains args; bind `current-prefix-arg` around its
  `call-interactively`.
- **`jetpacs.keymap.run`** (⚠ corrected): the original design bound
  `prefix-arg` around `execute-kbd-macro` — **empirically dead**: batch
  Emacs 30.1 shows `command_loop_1` clears `prefix-arg` at entry before the
  macro's first command, so *no* let-binding (of either variable) reaches a
  macro-dispatched command. Fix: when a prefix is present, resolve the key
  via `key-binding` and dispatch with
  `(let ((current-prefix-arg …)) (call-interactively cmd))` — which as a
  side effect also keeps the minibuffer bridge alive (the macro path trips
  the `executing-kbd-macro` fence). The no-prefix path stays on
  `execute-kbd-macro` unchanged. Transient branches bind
  `current-prefix-arg` around their direct `call-interactively`.

### 1c. Prefix arguments — touch UX

Recommend **(b) armed chip + (d) numeric long-press + (a) chip long-press**;
defer (c) top-bar button (the shell M-x icon_button has no long-press slot;
the wire support ships now, so it's a later pure-UI patch):

- **`prefix_arm` toolbar op** (new, linted): renders a `FilterChip`; tap
  arms plain C-u (visually loud, label shows the armed value), tap again
  disarms; **long-press opens a numeric dialog** (leading `-` allowed) that
  arms a count. Armed state lives companion-side in `SduiToolbar`,
  **auto-disarms on any command dispatch** (not on apply — a no-op command
  sends no apply and would wedge an apply-gated disarm). Non-command ops
  leave it armed. Note: `remember` state resets only when the toolbar
  leaves composition (editor recreation), not on background re-pushes —
  keep the SPEC prose accurate about that.
- **Long-press on a command chip = run with C-u** — the existing
  long-press idiom; an explicit authored `long_press` op keeps precedence,
  so no existing toolbar changes behavior. This directly answers
  "C-u M-x": **hold the M-x chip**.
- `jetpacs-files-dwim-toolbar` appends the `C-u` chip.

### 1d. Phase-1 file list

Kotlin: `SduiInputNodes.kt` (key modifier + decision fn, strip
selection/accept helpers, `pendingCommand` gains a prefix slot, Ctrl+S
lambda shared with the Save button), `SduiToolbar.kt` (armed state,
`prefix_arm` branch, implicit long-press-C-u, `onCommand` arity),
`EditorSync.kt` (`command()` prefix param — ints as JSON numbers, raw
forms as strings).
Elisp: `jetpacs.el` (version + `jetpacs-decode-prefix`), `jetpacs-sync.el`,
`jetpacs-keymap.el` (⚠ fix above), `jetpacs-emacs-ui.el`,
`jetpacs-widgets.el` (`:prefix-arm`), `jetpacs-files.el`,
`jetpacs-lint.el` (`prefix_arm` in toolbar ops + boolean check).
Spec: SPEC §8 prefix paragraph + §9 toolbar rows — **§9's op table is
stale: it still lacks 1.26's `command` op; repair it in the same
amendment**. Contract + widgets.golden regen; bundle regen.

### 1e. Phase-1 tests

ERT: decode table; `edit.command`+`"u"`→ recorder sees `'(4)`;
integer→`(interactive "p")` sees count; no-prefix regression;
`jetpacs.keymap.run` with prefix (pins the ⚠ key-binding+call-interactively
mechanism — *not* the macro path); `emacs.mx.show` prefix; lint
exactly-one-op/type; golden regen; version pin.
Kotlin: `editorKeyDecision` matrix (Tab×{strip, complete±connected, plain,
readOnly, composing}, S-Tab, Esc, Ctrl+S×{chrome, !modified}, arrows
engagement-gated); `completionVisible`/`acceptCompletion` cases; `command()`
prefix emission.
On-device: BT keyboard attach (activity recreation — **verify unsaved
editor text survives**; `TextFieldState` is not `rememberSaveable`), Tab
accept + Tab indent round-trip, armed C-u → org-todo cycles backward,
hold M-x → `C-u M-x`.

---

## Phase 2 — full chord passthrough

### 2a. Capture policy (extends the shared ladder, step 7)

Forward (consume, KeyDown): chords with Ctrl/Alt/Meta; F1–F12; while a
sequence is pending, *everything* except Esc (which cancels locally).
Never forward: plain printables/Enter/Backspace/arrows/Home/End/PgUp/PgDn
unmodified (local editing + existing delta/caret sync); Ctrl+V (Android
clipboard is the only paste source); **non-collapsed Ctrl+C = local copy**
(⚠ but **Ctrl+X always passes** — `C-x`-prefixed region commands like
`C-x C-u` are exactly what an Emacs user types with an active region; the
original local-cut DWIM destroyed the selection on the first keypress);
Ctrl+Z/Shift+Z (phone undo is the single authority; `C-z` headless =
suspend-emacs disaster); bare **Ctrl+S stays Save** (also
default-denylisted server-side, see 2d); Esc and C-g (local dismiss
ladder; nothing to quit — each chord runs synchronously);
`C-u`/`M-<digit>`/`M--` (accumulated locally into the prefix state — ⚠ not
because forwarding "would hang": `universal-argument` returns fine, but
its transient-map effect is *lost* between independent action frames).
**`C-x C-s`** → intercepted **at dequeue/send time** (⚠ not capture time —
the pending echo hasn't returned yet on a fast second keystroke): clear
pending, run the Save path.
Kill-switch: companion-side toggle, default on, in the Android settings
screen; **capture arms only when the welcome's client version ≥ this
phase's version** (⚠ else every chord and Tab dies in a timeout against an
old Emacs that drops the unknown action — gate on
`session.welcome.client`, already carried).

### 2b. Normalization (`KeyChordNormalizer.kt`, new, pure)

Emacs `key-description` conventions; modifiers in canonical order
(Ctrl→`C-`, Alt→`M-`, Meta/Win→`s-`); letters keep lowercase base +
`S-` when shifted; shifted symbol-row keys use the shifted char with no
`S-` (Ctrl+Shift+1 = `C-!`). Special-key table: `<tab>` `<return>`
`<backspace>` `<deletechar>` `<up>`… `<home>` `<end>` `<prior>` `<next>`
`<f1>`–`<f12>` `<insert>`, modified Space = `SPC`. Sequences space-joined
(`"C-x h"`). ⚠ Drop the `<escape>` row (unreachable — Esc is always
local); ⚠ add `S-<tab>` → `<backtab>` to the server twin table (GUI Emacs
delivers `<backtab>`; raw `key-binding` does no function-key-map
translation, and modes bind `<backtab>`). ⚠ Do **not** advertise `C-SPC`
mark-setting: `set-mark-command` leaves mark == point (no selection keys in
the reply) and the next chord's `place-region` deactivates the mark —
region selection is **phone-owned**; region commands work by selecting on
screen first, then typing the chord (`C-x C-u`, `C-w`).

### 2c. Wire: `edit.key` action + `edit.pending` frame + correlated ack

```
companion → client  event.action {action:"edit.key",
                                  args:{file, session, seq, cursor,
                                        sel_start?, sel_end?,
                                        key,        // FULL sequence so far: "C-x h"
                                        req,        // phone-chosen int, echoed in replies
                                        prefix?}}
client → companion  edit.pending {id, session, seq, key, req}          // NEW kind
client → companion  edit.apply   {…existing…, req?}                    // req present iff answering edit.key
```

- Separate action, not a `key?` arg on `edit.command`: different reply
  contract (pending/ack), and it keeps the two §5 postures cleanly
  audited — `edit.command` is the reviewed named-command exception;
  `edit.key` is key replay resolved by the client's own keymaps, the
  `jetpacs.keymap.run`/sections precedent ("no command names on the
  wire"), with the honest amendment note that it's a wider aperture than
  echo-back (any bound command, no per-key pick), bounded by the same
  authenticated socket + the post-resolution predicate/denylist seam.
- **Sequences**: phone keeps only the accumulated string; every frame
  carries the full sequence; the server resolves statelessly per frame.
  `keymapp` → `edit.pending` (echo; phone enters capture-all, shows the
  pending chord in the doc-line row); command → run; nil → toast + ack.
  Wins on staleness (nothing server-side to rot), delta interleaving
  (each frame gates on send-time seq), and future which-key
  (`edit.pending` can additively grow `continuations`).
- **Ack rule (normative)**: every *gated* `edit.key` gets exactly one
  reply carrying its `req` — splice `edit.apply`, move-only `edit.apply`
  (now sent **even when nothing changed** — the pure ack; also after
  undefined/refused keys, beside their toast), or `edit.pending`. Gate
  failure → `edit.resync` (no req — clears the whole queue). ⚠ The `req`
  echo is what makes serialization race-free: without it, a toolbar-chip
  apply on the same file falsely acks a chord in flight (`edit.apply`
  carries only the file id). `jetpacs-sync--emit-apply` gains
  `force-ack`/`req` params; `edit.command` callers pass nil — zero
  behavior change there.
- **Phone-side `KeyChordQueue`**: FIFO; send only when not awaiting; each
  frame built at send time from then-current text/selection/seq; matching
  `req` (or resync, or 2 s timeout) pops and fires the next. Soft-keyboard
  typing between chords is safe (hardware-only capture; the IME delta
  bumps seq; the next frame reads fresh state). Risk note: this adds a
  third driver to an engine documented single-driver — route all engine
  calls through the editor's effect chain on one dispatcher.

### 2d. Server execution (`jetpacs-sync-run-key`, sibling of run-command)

Gate → place point/region **first** → resolve
`(key-binding kv t nil (point))` (position-aware: char-property keymaps at
point) → angle→ASCII twin retry (`<tab>`→`TAB`, `<return>`→`RET`,
`<backspace>`→`DEL`, `S-<tab>`→`<backtab>`; generalizes
[jetpacs-buffer.el:677](../emacs/core/jetpacs-buffer.el)) →
- `keymapp` → `edit.pending`.
- `commandp` → hardening gates: `jetpacs-sync-command-predicate` on the
  resolved symbol, plus new `jetpacs-sync-key-denylist`, default:
  save family (`save-buffer` `save-some-buffers` `write-file` — §8: the
  phone's `on_save` owns persistence, and eglot sessions are REAL buffers
  where `save-buffer` genuinely writes disk), suspend/kill family,
  `quoted-insert` (unadvised `read-char` blocks the handler), and ⚠
  **`isearch-forward`/`isearch-backward`** — empirically they *error*
  headless (`move-to-window-line called from unrelated buffer`) and any
  partially-installed isearch state hijacks `key-binding` for every later
  chord via `overriding-terminal-local-map`, with no phone-side C-g to
  escape. Refusal → toast + ack.
- Run via `jetpacs-buffer-call-shimmed` with `current-prefix-arg` bound
  from the decoded prefix (call-interactively path — prompts stay
  bridged; the macro path would trip the `executing-kbd-macro` fence).
- nil → toast "KEY is undefined" + ack.

### 2e. Fidelity limitation (docs + amendment)

Major-mode maps resolve exactly in hidden shadows (`use-local-map` runs
under `delay-mode-hooks`); **hook-installed minor-mode maps are absent**
(smartparens/evil/user hooks) — `jetpacs-sync-shadow-setup-hook` is the
opt-back-in, with an example in user docs. Eglot files resolve
desktop-identically (real buffers, full hooks). Fundamental fallback =
global map only.

### 2f. Phase-2 file list

Kotlin: `KeyChordNormalizer.kt` (new), `EditorSync.kt`
(`key(...)` sender + req), `Envelope.kt`/`JetpacsConnection.kt`/
`JetpacsEditSyncState.kt` (`edit.pending` slot), `SduiInputNodes.kt`
(ladder step 7, prefix accumulator + indicator, `KeyChordQueue`, pending
UI in the doc-line row, ack hooks in the apply/resync collectors),
settings screen toggle.
Elisp: `jetpacs-sync.el` (`run-key`, twins, denylist, decode share,
`emit-apply` req/force-ack, `edit.key` defaction), `jetpacs-lint.el`
(`edit.pending` kind row; `req` optional on `edit.apply`), `jetpacs.el`
version.
Spec: amendment row (ack rule, aperture note, prefix table, save/suspend
carve-out, additivity — old client drops `edit.key`, old companion never
sees `edit.pending`/pure-acks); contract + frames.golden (+`edit.pending`,
+a req-carrying apply) regen; bundle regen. ebp store rule: **fetch into
`.git/modules/ebp`, never push**.

### 2g. Phase-2 tests

ERT: splice via `"M-u"`; TAB duality (`<tab>` → org-cycle via twin, ack
arrives as pure move-only); `"C-c C-c"` org checkbox flip; `"C-x"` →
exactly one pending, seq unchanged; undefined → toast + ack; pure-ack
branch; prefix decode incl. `"u"` string forms on `M-f` with count;
denylist (`save-buffer` never runs — cl-letf-count), isearch refusal;
wrong seq → one resync only; char-property keymap at point; predicate
seam; req echoed in every reply.
Kotlin: normalizer table (incl. `C-!`, ordering, `<backtab>` absence
client-side, null for plain keys); `key()` frame shape (astral cursor
conversion, prefix forms, req); `KeyChordQueue` (no send while awaiting;
pending grows; resync clears; timeout; **apply-without-req is not an
ack**); `applyExternal` accepts a pure-ack move-only.
On-device: `C-c C-c` on an org checkbox; `C-x C-u` on a selection;
type-during-chord (chord lost, text intact, converges); kill-switch off →
Phase-1 behavior; old-Emacs skew (capture stays off).

## Risks

- **Two empirical traps already burned once** (macro prefix binding, JSON
  array decode) — both pinned by ERT tests that fail if the mechanism
  regresses.
- **Round-trip latency** on Tab-indent and chords; typing during flight
  loses the keystroke's effect, never text (§8 extended). Pure-ack keeps
  the queue honest; 2 s timeout is the dead-Emacs net.
- **Amendment/version contention** across three in-flight ebp lineages —
  renumber at merge.
- **Engine concurrency**: chord traffic heats a pre-existing
  multi-effect hazard on `EditorSyncEngine`; confine engine calls to one
  effect chain.
- **BT attach recreates the activity** (no `configChanges`): verify
  editor-text survival on device before Phase 1 ships; Ctrl+S makes the
  failure cheap either way.
- **Muscle-memory surprises** (collapsed C-c → Emacs; C-x passes even
  with a selection): the kill-switch and undefined-key toasts keep
  misfires visible; document.

## Order

1. Phase 1 Kotlin ladder + strip selection + Ctrl+S (no protocol).
2. Phase 1 prefix: decoder + three elisp carriers (⚠ keymap.run fix) +
   toolbar `prefix_arm`/long-press + SPEC/goldens/bundle.
3. Device pass 1 (incl. the activity-recreation check).
4. Phase 2 normalizer + wire + queue + `run-key` + denylist.
5. SPEC amendment + goldens + version gate.
6. Device pass 2 (org `C-c C-c` is the acceptance test).
