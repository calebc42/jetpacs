# Plan: point/region on the editor surface — DWIM commands

## Why

Emacs's killer commands are DWIM: `comment-dwim`, `fill-paragraph`, `upcase-dwim`,
`org-todo` on the heading at point — commands whose behavior reads point, region,
and thing-at-point. Jetpacs cannot run any of them today because editing is
client-side (the phone owns the text to avoid round-tripping) and Emacs has no
live point or region.

The obvious fix — "invent a buffer abstraction" — is unnecessary. **Jetpacs
already has buffers: the sync sessions in `jetpacs-sync.el`.** Every `editor`
surface keeps a live per-file Emacs buffer (the real file buffer under eglot,
a hidden shadow otherwise) mirrored by seq-numbered incremental deltas, with the
standing safety rule: *wrong state can only cause a missing feature, never a
wrong edit*. Completion, diagnostics, fontify, and eldoc already run inside it.

What DWIM actually needs is three extensions of that layer, plus two subtleties:

1. **Selection never crosses the wire.** `edit.caret` carries only `cursor`, and
   only when the selection is collapsed (gate in `SduiInputNodes.kt`, the
   debounced collector).
2. **Point/mark aren't persisted server-side.** The `edit.caret` handler
   (`jetpacs-sync.el`) uses the cursor transiently for eldoc inside
   `save-excursion`.
3. **No server→device edit channel.** Deltas flow device→Emacs only;
   `fontify.show`/`diagnostics.show` push styling, never text. A command that
   mutates the session buffer has no way to hand the result back to the phone's
   `TextFieldState`.
4. *(Subtlety)* **The seq stream becomes two-writer.** A server-authored edit
   racing phone typing must resolve through the existing resync machinery — the
   DWIM result is dropped, never mis-applied.
5. *(Subtlety)* **Any persisted caret is stale by construction** (the caret rides
   a 300 ms debounce), so the command frame itself must carry cursor + selection
   explicitly, exactly as `edit.complete` already carries `cursor`. Persisted
   session point/mark are best-effort fallback only (future global flows).

Two existing assets do the heavy lifting: `jetpacs--on-action` runs every handler
inside the minibuffer bridge, so a prompting DWIM command (`org-todo`,
`query-replace`) bridges to phone dialogs for free; and
`jetpacs-buffer-call-shimmed` (`jetpacs-buffer.el`) already runs
`call-interactively` headless with window-display shims.

## Wire protocol

All changes are additive; `contract_format` stays 3; `reference_api_version`
bumps to the next minor at merge time.

### `edit.caret` gains optional selection

Action args only — action legs are deliberately not enumerated in
`kind_schema`, so this is SPEC-prose plus implementations:

```
companion → client  event.action {action:"edit.caret",
                                  args:{file, session, seq, cursor,
                                        sel_start?, sel_end?}}
```

`sel_start ≤ sel_end`, 0-based Unicode code points, present only when the
selection is non-collapsed. `cursor` remains required and equals one end (the
moving caret), so Emacs derives mark as the other end. Old clients ignore the
unknown keys; old companions simply never send them.

### New action `edit.command` (companion → client)

Same "sync text first, then query" discipline as `edit.complete`:

```
companion → client  event.action {action:"edit.command",
                                  args:{file, session, seq, cursor,
                                        sel_start?, sel_end?, command?}}
```

- Gate identical to the slim completion path: `jetpacs-sync-session-buffer`
  must match, else one `edit.resync` and nothing runs.
- `command` is an Emacs command name string. **When omitted, the client prompts
  `completing-read` over `commandp`** through the bridged picker — M-x scoped to
  the editor, with zero device-side command knowledge.
- Coordinates are carried explicitly, not read from persisted state (staleness,
  above).

### New frame kind `edit.apply` (client → companion)

The reverse edit channel. Two shapes, one kind:

```
client → companion  edit.apply {id, session, seq, cursor,
                                start?, del?, text?, len?,
                                sel_start?, sel_end?}
```

- **Text-changing**: `start/del/text/len` present — splice semantics identical
  to `edit.delta` with direction reversed. `seq` is the **new** seq: the client
  bumps its session seq when emitting. The phone applies iff
  `seq == engine.seq + 1` AND its current text still equals `lastSynced` AND no
  IME composition is active; any failed gate drops the frame silently (the next
  inbound delta mismatches and the normal resync round converges).
- **Move-only** (the command moved point / changed the region without editing —
  `forward-paragraph`, `mark-defun`): splice fields absent, `seq` unchanged;
  same gates.
- The phone applies via one `TextFieldState.edit {}` block → exactly **one undo
  step**; undoing it emits an ordinary `edit.delta` back to Emacs — no special
  casing anywhere.
- IME rule: if a composition region is active, drop the apply. Splicing under a
  live composition can corrupt it; dropping degrades to "missing feature".

## Implementation

### 1. Elisp core — `emacs/core/jetpacs-sync.el`

- Extend the session plist (`jetpacs-sync--sessions` docstring) with `:point`,
  `:sel-start`, `:sel-end`. Persist them in the `edit.caret` handler under the
  existing `jetpacs-sync-session-buffer` gate (so stored state is always
  coherent with stored seq); skip the eldoc run when a non-collapsed selection
  is reported.
- New `jetpacs-sync--splice (old new)` → `(START DEL INSERTED)` or nil —
  common-prefix/suffix scan mirroring `splice()` in `EditorSync.kt`, simpler
  because Emacs buffer positions *are* code points.
- New `jetpacs-sync-run-command (file session seq command cursor sel-start sel-end)`:
  1. Gate via `jetpacs-sync-session-buffer`; on mismatch
     `jetpacs-sync-request-resync` and stop (the `jetpacs-complete-in-session`
     pattern).
  2. Resolve the command: empty/nil → bridged `completing-read "M-x " obarray
     #'commandp t`; then `intern-soft` + predicate check; failure → toast.
  3. In the session buffer: snapshot text; `goto-char (1+ cursor)` (clamped);
     when a selection came in, `set-mark` at the non-cursor end + `activate-mark`
     with `transient-mark-mode` let-bound to t so `use-region-p` answers yes;
     otherwise `deactivate-mark`.
  4. Run through an **error-reporting variant of `jetpacs-buffer-call-shimmed`**
     — the current one swallows errors; a failing DWIM command must toast, not
     vanish. Returns `(DEST-BUF . DEST-POS)`.
  5. Post-run:
     - Text changed (splice non-nil): bump `:seq` **first**, emit `edit.apply`
       with the splice, new point, and region if it survived — then re-arm
       diagnostics and push fontify (both stamp from `:seq`, so bump-then-push
       makes the phone render them immediately after applying).
     - Only point/region moved: move-only `edit.apply`, seq unchanged.
     - Nothing changed: send nothing.
     - Command landed in another buffer (xref, help): no navigation on the
       phone; still diff the session text (it may have changed) and emit if so.
  6. Eglot real-file sessions are correct by construction — the command edits
     the real buffer, change hooks fire, incremental didChange happens; the
     phone's explicit Save still owns persistence (autosave already disabled).
- Register `(jetpacs-defaction "edit.command" ...)` with `edit.delta`-style
  type validation. Security posture equals the existing `emacs.mx.show`
  (arbitrary `call-interactively` over the authenticated socket); add a
  `jetpacs-sync-command-predicate` defcustom (default `commandp`) as the
  hardening/escape valve.
- `emacs.mx.show` is left alone; a focused-editor registry for global M-x is a
  small follow-up once a use case appears.

### 2. Contract / lint / SPEC (lint table first — contract.json is generated from it)

- `emacs/core/jetpacs-lint.el`: after the `edit.resync` row add
  `("edit.apply" client (id session seq cursor) (start del text len sel_start sel_end))`;
  add `command` to `jetpacs-lint--toolbar-ops` and to the one-op-per-item
  exclusive set; update the §8 comment block.
- Regenerate `ebp/contract.json` via `emacs/build-contract.el`.
- `ebp/SPEC.md` §8: frame-table rows for the caret keys, the `edit.command`
  action leg, and `edit.apply`; prose for the two-writer seq rule, the
  IME-composition drop rule, and a restatement of the invariant. SPEC-CHANGES
  entry.
- `ebp/goldens/frames.golden`: add both `edit.apply` shapes (the file currently
  has no editor-sync frames, so nothing existing breaks); regenerate
  `widgets.golden` if the toolbar golden gains a `command` item
  (`emacs -Q --batch -l test/jetpacs-tests.el -f jetpacs-tests-regen-widget-golden`).
- Working-copy trap: this worktree's `ebp/` submodule is empty — make ebp edits
  in the primary checkout, commit there, and bump the submodule pointer via
  local fetch in the same series. Fetch any ebp commits living only in other
  worktrees' clones before merging.

### 3. Kotlin plumbing — `jetpacs/src/main/java/com/calebc42/jetpacs/`

- `Envelope.kt`: `EDIT_APPLY = "edit.apply"`.
- `JetpacsConnection.kt`: route the kind to `editSyncState.showApply(payload)` +
  ACK — the `FONTIFY_SHOW` ephemeral pattern.
- `JetpacsEditSyncState.kt`: an `apply` StateFlow slot, copied from `fontify`.
- `EditorSync.kt` (`EditorSyncEngine`):
  - `caret(...)` gains selection parameters; emit `sel_start`/`sel_end`
    (code-point converted) when non-collapsed.
  - `command(text, cursorUtf16, selStartUtf16, selEndUtf16, name?)` — clone of
    `requestCompletions`: sync via `update()` first, then
    `sendEditAction("edit.command", ...)`; omit the `command` key when name is
    null (→ M-x prompt).
  - `applyExternal(payload, currentText): ExternalEdit?` — pure validation +
    conversion: session match; `currentText == lastSynced`; seq gate (+1 for
    splice, == for move-only); code point → UTF-16 via `CodePointIndex`; verify
    `len`; on success advance `seq`/`lastSynced` and return UTF-16 splice +
    selection for the caller to apply.

### 4. Kotlin editor — `SduiInputNodes.kt`, `SduiToolbar.kt`

- Remove the collapsed-only caret gate in the debounced collector:
  `syncEngine.caret(text, sel.start, sel.min, sel.max)` unconditionally. Same
  debounce, so cadence and battery shape are unchanged; a selection drag settles
  to one frame per pause. Completion-prefix logic stays collapsed-only.
- New `LaunchedEffect(applyPayload)` beside the fontify one, on the **main**
  thread (it mutates `state`): gate on editor `id` and
  `state.composition == null`, call `applyExternal`, then one
  `state.edit { replace(...); selection = ... }`. That edit re-fires the
  collector, but `lastSynced` was already advanced, so `update()` diffs to null
  — **no echo loop** (pin with a unit test).
- `SduiToolbar.runOp`: `item.has("command") → onCommand?.invoke(name-or-null)`.
  `SduiEditor` supplies the lambda via a `mutableStateOf` request consumed by a
  `LaunchedEffect` calling `syncEngine.command(...)` on `Dispatchers.IO` (the
  resync-effect pattern). Pass null / skip rendering when the editor has no
  `:complete` sync bridge. No focus registry: the command op lives on the
  editor's own toolbar, so the target session is structurally implicit.

### 5. DSL — `emacs/core/jetpacs-widgets.el`

`jetpacs-toolbar-item` gains `:command` (an Emacs command name string, or `""`
for the M-x prompt); menu and long-press sub-items get it automatically since
they reuse the item shape. Dogfood:

```elisp
(jetpacs-editor "notes.org" text :complete t
  :toolbar (list (jetpacs-toolbar-item "check" "TODO" :command "org-todo")
                 (jetpacs-toolbar-item "text" "Fill" :command "fill-paragraph")
                 (jetpacs-toolbar-item "code" "M-x" :command "")))
```

Regenerate the root `jetpacs-core.el` bundle (it is generated — never edit or
textually merge it).

## Out of scope

- **`text_input`** — no sync session, no seq stream; the whole point of the
  widget is that it's cheap. Apps needing DWIM use `editor :chromeless`.
- **Region selection on Tier-0 read-only buffers** — a gesture/rendering
  project (long-press selection over `rich_text` spans), orthogonal to the sync
  layer. Tap-driven point already works there (`jetpacs.buffer.act {buffer pos}`).
- **mark-ring / `exchange-point-and-mark`** — the phone has one selection and
  no affordance for more; session `:sel-start`/`:sel-end` model exactly what
  the phone can show.
- **Global M-x editor context** — follow-up once a real use case appears.

## Verification

- **ERT** (`test/jetpacs-tests.el`; run
  `emacs -Q --batch -l test/jetpacs-tests.el -f ert-run-tests-batch-and-exit </dev/null`
  — the redirect because any unbridged prompt hangs batch Emacs). Follow the
  `jetpacs-sync-open-and-delta` idiom: `cl-letf` `jetpacs-send` to capture
  frames. New tests:
  - `edit.caret` persists `:point`/`:sel-start`/`:sel-end`; mismatched seq
    persists nothing.
  - `jetpacs-sync--splice`: insert / delete / replace / equal / multibyte.
  - Region command: seed text, selection over a word, `upcase-dwim` → captured
    `edit.apply` has the correct splice, seq = old+1, plist seq bumped.
  - Point-only command (`forward-word`) → move-only apply, seq unchanged.
  - Seq mismatch → exactly one `edit.resync`, no apply.
  - Erroring command → toast frame, no apply, session not stale.
  - Buffer-switching command → no apply against the session.
- **Kotlin**: `EditorApplyTest.kt` beside `FontifyShiftTest.kt`: seq gating
  (accept +1 splice, accept == move-only, reject others), `lastSynced` mismatch
  rejection, astral-char code-point↔UTF-16 conversion, `len` verification,
  engine state after accept, and the no-echo-after-apply property.
  `WireGoldenConformanceTest` picks up the new golden lines automatically.
- **On-device** (add to the device-testing checklist):
  - Org file, TODO toolbar chip → tapping cycles the heading's TODO within one
    round-trip.
  - Select two words → Fill / upcase chips act on the region.
  - Type *during* a slow command → text is never corrupted; the command result
    is dropped and colors/squiggles return after resync.
  - Undo reverts a DWIM edit in one step and Emacs converges.
  - IME mid-composition + command → the composition survives (apply dropped).
  - Eglot file → diagnostics stay coherent after a DWIM edit.

## Risks

- **Two-writer seq race**: typing during the round-trip loses the DWIM result
  via reseed — correct but potentially surprising; later mitigation is a toast
  on the dropped apply.
- **Echo loop** if `lastSynced` isn't advanced before `state.edit` — pinned by
  a unit test.
- **Unbridgeable commands** (recursive edit, raw `read-event` loops) can hang
  the handler; the minibuffer bridge covers ordinary prompts, and
  `jetpacs-sync-command-predicate` is the escape valve.
- **Staleness ordering**: fontify/diagnostics must be pushed *after* the seq
  bump or the phone hides them until the next keystroke.

## Order

1. Elisp: `jetpacs-sync--splice` + caret/selection persistence (self-contained, ERT-able).
2. Elisp: `jetpacs-sync-run-command` + `edit.command` action + `edit.apply`
   emission + error-reporting call-shimmed variant.
3. Lint table + SPEC §8 + contract regen + goldens (primary ebp checkout,
   submodule bump).
4. Kotlin plumbing + `applyExternal` + unit tests.
5. Kotlin caret un-gate + toolbar `command` op + editor effects.
6. DSL `:command` + bundle regen + a dogfood toolbar in an app under `emacs/apps/`.
7. Device pass.
