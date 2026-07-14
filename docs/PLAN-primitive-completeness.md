# Plan: Emacs primitive completeness

**STATUS (2026-07-04): all phases ✅ implemented and verified.** P0–P5
done; two items intentionally deferred as low-risk follow-ups — inline
images in Task 10, and the optional Task 15 (point/region indication).
`test/jetpacs-primitives-test.el` is the 48-test regression net. Deferred
follow-ups are the only remaining work; each is described in its task
body below. On-device verification (magit commit end-to-end, diff
shading, live compile refresh) is the last thing left that can't be done
headless.

**REVIEW PASS (2026-07-04, post-implementation):** an independent audit
of the implementation confirmed the work sound and fixed four findings:
(1) docs/SPEC.md was never updated — §5 now reserves `witheditor.*`, §7
documents the with-editor dialog flow, §9 documents the `password` and
span-`bg` attrs; (2) `map-y-or-n-p` PROMPTER contract — a non-string
truthy return now acts without asking (subr.el semantics; previously
only `t` did); (3) desktop commits no longer pop an uninvited dialog on
the phone — `jetpacs-witheditor--maybe-bridge` gates on a recent phone
action (`jetpacs--last-action-time` in jetpacs-surfaces,
`jetpacs-witheditor-action-window` = 30s); (4) a session finished/cancelled
from the desktop now dismisses the phone dialog via
`with-editor-post-finish/cancel-hook`. Also: non-commit editor buffers
(rebase todos) title by buffer name. 3 regression tests added. Cleared
during review: overlay-splice ordering, raw-event guards, tab/column
math, password scrubbing, live-refresh lifecycle, menu-mining eval
semantics, no external callers of changed internals, Kotlin dialog path
renders `editor` nodes, full-core byte-compile clean.

**On-device finding (magit status, 2026-07-04):** Task 9 leaked the
placeholder text of offscreen display specs — magit's section indicators
are `(propertize "fringe" 'display '(left-fringe BITMAP FACE))` and its
margin overlays `(propertize "o" 'display '((margin right-margin)
DATE))`, so "fringe"/"o" littered the render and folded commit lines
survived as lone "o" rows. Fixed with
`jetpacs-buffer--offscreen-display-p`: text covered by a fringe/margin
display spec renders nothing, applied in both the buffer walk and
`jetpacs-buffer--string-spans` (which also gained string-internal space-spec
handling). 4 regression tests reproduce the magit idioms (52 total).
Confirmed working-as-intended in the same screenshot: relative line
numbers (user's `jetpacs-line-numbers` setting) and section-highlight
backgrounds (the new span `bg`).

**On-device finding #2 (magit commit crashed, 2026-07-04):** tapping
Commit ran `jetpacs.keymap.run c` → `magit-commit` → the `transient-setup`
advice → `jetpacs-transient--groups`, which did `dolist` over
`transient--layout` assuming a LIST of 4-slot `[LEVEL CLASS PLIST
CHILDREN]` group vectors with nested-plist leaves (transient 0.7.x, what
Emacs 30 bundles).  The phone's newer transient stores a single ROOT
VECTOR `[2 nil (…)]` with 3-slot `[CLASS PLIST CHILDREN]` groups and
inline-plist leaves `(transient-switch :key … )` → crash.  Root cause:
`jetpacs-transient.el` (dialog) and `jetpacs-keymap.el` (pie) had independently
written, diverging layout walkers; only the pie handled the new shape.
Fixed by making `jetpacs-transient--groups` version-robust (helpers
`--vec-plist`/`--vec-children`/`--leaf-plist`; dispatch on list-vs-vector
root).  A SECOND crash followed on-device — `Wrong type argument: listp,
""` — because the new layout interleaves bare "" separator children and
`--leaf-plist` ran `(car c)` on a string (a guard bug in the first fix);
fixed by gating on `(consp c)`.  Verified against the REAL new magit
(magit/transient 20260701 in WSL): `magit-commit` now parses to 6 groups,
all children mapped, "" skipped.  Regression test carries the ""
separator.  NOTE: the full commit chain (transient dialog → Commit →
save-some-buffers bridge → with-editor bridge) is unblocked at parse
level but still not re-tested on-device end-to-end.

Produced 2026-07-04 from a full audit of `emacs/core/`. Each task is
self-contained: goal, files, implementation notes, pitfalls, acceptance
test. Work top to bottom — phases are ordered by severity (P0 = hangs,
P1 = correctness, P2 = render fidelity, P3 = liveness, P4 = polish,
P5 = tests). Tasks within a phase are independent unless noted.

**Known user-visible bug this plan fixes:** committing from the phone via
magit hangs. The chain is `magit-commit-create` →
`magit-maybe-save-repository-buffers` → `save-some-buffers` →
`map-y-or-n-p` → raw `read-event`, which the minibuffer bridge never
intercepts (Task 1). Even past that, the commit-message buffer
(with-editor) has no bridged flow (Task 3). Tasks 1 + 2 + 3 together fix
the commit path.

## Repo conventions (read first)

- Edit sources under `emacs/core/` (and `emacs/apps/` for Tier 1). The
  root files `jetpacs-core.el` and `glasspane.el` are **generated bundles**
  — never edit them by hand. After any source edit, regenerate:
  `emacs --batch -l emacs/build-bundle.el`
- Run tests: `emacs -Q --batch -l test/jetpacs-tests.el -f ert-run-tests-batch-and-exit`
  (or `test/run-tests.sh`). The widget wire-format golden
  (`test/widgets.golden`) must be regenerated after an INTENTIONAL wire
  change: `emacs -Q --batch -l test/jetpacs-tests.el -f jetpacs-tests-regen-widget-golden`.
- **Command-dispatch boundary (normative, docs/SPEC.md §5):** the phone
  may only invoke Emacs through allowlisted semantic actions. Any new
  wire action added here must be a narrow, validated operation — never
  "run this command by name" — and must be documented in docs/SPEC.md.
- **Advice pattern:** every prompt interception in
  `emacs/core/jetpacs-minibuffer.el` is `:around` advice that passes
  through untouched unless `jetpacs--in-action-handler` is non-nil (bound
  by `jetpacs--on-action` in `emacs/core/jetpacs-surfaces.el`). Desktop
  keyboard use must be completely unaffected. Follow this pattern for
  all new advice.
- **Degrade, don't hang:** if a bridged flow can't be represented,
  signal `quit` (the action dispatcher catches it and reports
  "cancelled") rather than blocking. A cancelled prompt beats a frozen
  phone.
- Wire-format additions (new widget attributes, new frame kinds) need a
  Kotlin counterpart in `app/src/main/java/com/calebc42/jetpacs/` —
  primarily `SduiRenderer.kt`. Tasks below say when this applies. If the
  Android side can't be done in the same pass, the elisp side must be
  additive-only (unknown attrs are ignored by the client) and the task
  notes the follow-up.

---

## P0 — Hang fixes (the magit-commit path) — ✅ DONE (2026-07-04)

Tasks 1–3 implemented and verified: `emacs/core/jetpacs-minibuffer.el`
gained the `map-y-or-n-p` bridge and the raw-event-reader advice;
`emacs/core/jetpacs-witheditor.el` (new, wired into `build-bundle.el`,
`core-load-test.el`, and required from `jetpacs-emacs-ui.el`) bridges the
commit-message buffer. Regression tests in
`test/jetpacs-primitives-test.el` (14 tests, all green); existing suites
(core-load, 45-test main) still green; bundles regenerated; widget
golden unchanged (no wire change). Not yet exercised on-device — the
one remaining verification is the live magit-commit end-to-end.

### Task 1: Bridge `map-y-or-n-p`

**Goal:** `save-some-buffers` (and everything else built on
`map-y-or-n-p`) prompts on the phone instead of hanging.

**File:** `emacs/core/jetpacs-minibuffer.el`

**Implementation:** `:around` advice on `map-y-or-n-p`, active only when
`jetpacs--in-action-handler`. Do NOT try to feed events to the original —
reimplement the loop:

- Signature: `(map-y-or-n-p PROMPTER ACTOR LIST &optional HELP
  ACTION-ALIST NO-CURSOR-IN-ECHO-AREA)`.
- LIST is either a list of objects or a generator function of no args
  returning the next object (or nil when done). Handle both.
- PROMPTER is a format string (apply `format` with the object) or a
  function of the object. A function may return: a string (prompt with
  it), `t` (act without asking), or nil (skip without asking).
- For each prompted object show a dialog (reuse
  `jetpacs--send-prompt-dialog` / `jetpacs--wait-for-prompt` /
  `jetpacs--prompt-id`, same as `jetpacs--y-or-n-p-advice` at
  jetpacs-minibuffer.el:151) with buttons: **Yes**, **No**, **Yes to all**,
  **Quit**. "Yes to all" sets a flag: call ACTOR on the current and
  every remaining object without further prompts. "Quit"/dismiss/timeout
  stops the loop (remaining objects skipped).
- ACTION-ALIST entries `(CHAR FUNCTION HELP)` may be rendered as extra
  buttons (call FUNCTION on the object; if it returns nil re-prompt same
  object) — optional, fine to skip in v1.
- Return the number of objects acted on (this is the contract; callers
  check it).

**Pitfalls:** ACTOR must be called exactly once per accepted object, in
the same dynamic context (don't wrap in `save-excursion` etc. — the
original doesn't). Keep the unwind-protect → `jetpacs--cleanup-prompt`
pattern so a dismissed dialog can't leak.

**Acceptance:** ERT test with `jetpacs--in-action-handler` bound to t,
`jetpacs--send-prompt-dialog` stubbed to capture, `jetpacs--wait-for-prompt`
stubbed to return canned replies; assert ACTOR calls and return count
for yes / no / yes-to-all / quit sequences. Live: modify two file
buffers, then from the phone REPL eval `(save-some-buffers)` — dialogs
appear per buffer.

### Task 2: Hang-proof the raw event readers

**Goal:** `read-event`, `read-key`, `read-key-sequence`,
`read-key-sequence-vector` during an action handler never block forever.

**File:** `emacs/core/jetpacs-minibuffer.el`

**Implementation:** one shared `:around` advice applied to all four.
Pass through (call orig) when ANY of:

- `jetpacs--in-action-handler` is nil (as always);
- `executing-kbd-macro` is non-nil — `jetpacs-keymap--execute-key`
  (emacs/core/jetpacs-keymap.el:499) drives commands via
  `execute-kbd-macro`, whose events come from the macro, not a real
  keyboard. Intercepting here would break the whole keymap palette;
- `unread-command-events` is non-nil (events are already queued; no
  hang possible);
- for `read-event` specifically: the SECONDS arg (3rd) is non-nil —
  that's `sit-for` and friends using read-event as a timeout sleep.

Otherwise: show a dialog via the existing `read-from-minibuffer` bridge
(prompt = the PROMPT arg or "Key input expected") asking for a key
description. Parse the reply with `(kbd reply)` inside `condition-case`;
for `read-event`/`read-key` return the first event of the parsed
sequence (`(aref (kbd reply) 0)` — note `kbd` may return a string or
vector; `aref` works on both); for `read-key-sequence` return the `kbd`
result as a string, for `read-key-sequence-vector` coerce with
`(vconcat ...)`. Empty/cancelled/unparseable reply → `keyboard-quit`.

This is deliberately crude: it converts hangs into an answerable (or
cancellable) prompt. `query-replace` becomes usable — each y/n/!/q is
typed as a character.

**Pitfalls:** `read-char`/`read-char-exclusive` are already advised
(jetpacs-minibuffer.el:512) — don't double-advise those. Test that the
keymap palette still executes bindings (regression: the
`executing-kbd-macro` passthrough).

**Acceptance:** ERT: with handler bound and wait stubbed, `(read-event)`
returns the parsed event for reply "y" and signals quit for cancel; with
`executing-kbd-macro` bound non-nil the orig is called. Live: from phone
REPL eval `(read-event "Press: ")` — dialog appears, no freeze.

### Task 3: Bridge with-editor / the commit-message buffer

**Goal:** after Tasks 1–2, `magit-commit` from the phone reaches the
COMMIT_EDITMSG buffer; the user must be able to write the message and
finish/cancel the commit from the phone.

**Files:** new `emacs/core/jetpacs-witheditor.el` (add to
`emacs/build-bundle.el` core-files list after `jetpacs-emacs-ui.el`), or
extend `emacs/apps/jetpacs-magit.el` if a core module feels too heavy —
prefer core, since with-editor is not magit-specific.

**Implementation:**

- Hook `git-commit-setup-hook` AND `with-editor-mode-hook` (guard
  against double-fire with a buffer-local flag). Gate on
  `(jetpacs-connected-p)` — NOT on `jetpacs--in-action-handler`: magit runs
  git asynchronously, so the editor buffer appears from a process
  filter/server callback *after* the originating action handler has
  returned.
- When fired, push a dialog (or better, a shell overlay view — see
  `jetpacs-shell-define-view` `:overlay` in emacs/core/jetpacs-shell.el:44)
  containing: a multiline `jetpacs-text-input` (or chromeless `jetpacs-editor`
  with `:publish-state t`, following the eval-REPL pattern in
  emacs/core/jetpacs-emacs-ui.el:223) seeded with the buffer's current
  content (usually empty above the scissors line), plus **Commit** and
  **Cancel** buttons.
- Two new allowlisted actions, e.g. `witheditor.finish` and
  `witheditor.cancel`. Validation: the handler must verify the target
  buffer (identified by buffer name carried in args) still exists AND
  has `with-editor-mode` enabled — refuse anything else. finish: replace
  the buffer text above any trailing comment/scissors section with the
  submitted value, then call `with-editor-finish`; cancel calls
  `with-editor-cancel`. Both `(jetpacs-shell-push)` after.
- Document both actions in docs/SPEC.md §5.

**Pitfalls:** with-editor needs `server-start` (or its sleeping-editor
fallback) to receive git's editor callback — verify it works in the
target setup and surface a clear toast if the buffer never appears.
Don't clobber the trailing `# Please enter the commit message...`
comment block when splicing the message in; simplest correct approach:
`erase-buffer` is WRONG — instead insert the message at `point-min` and
delete only the old message region (everything before the first line
matching `^#` or the scissors line).

**Acceptance:** live end-to-end: phone → Buffers → magit-status buffer →
keyboard FAB → palette → `magit-commit` → transient dialog → Commit →
(Task 1 dialog if unsaved buffers) → message dialog → type "test:
bridged commit" → Commit → `git log -1` shows it. Also test Cancel
leaves no commit and no stuck git process.

---

## P1 — Prompt routing correctness — ✅ DONE (2026-07-04)

Tasks 4–8 implemented and verified. `jetpacs--on-action`
(`emacs/core/jetpacs-surfaces.el`) now pins `completing-read-function` /
`read-file-name-function` / `read-buffer-function` /
`disabled-command-function` to built-ins for the duration of a handler
(Tasks 4, 8). `completing-read` honours INITIAL-INPUT by seeding the
filter field on the first render only (Task 5). `read-passwd` gets a
dedicated masked-field bridge that skips context cards and scrubs the
secret from `jetpacs--ui-state`/`jetpacs--state-handlers` afterward, with a
new `password` attribute on `text_input` wired through the Kotlin
renderer (`SduiInputNodes.kt`: `PasswordVisualTransformation` +
`KeyboardType.Password`) (Task 6). `read-answer` and
`read-char-from-minibuffer` render as buttons (Task 7). 7 new tests in
`test/jetpacs-primitives-test.el` (21 total, all green); main suite still
45/45 including the widget golden (the `password` attr is additive, so
no golden regen needed); Kotlin `:app:compileDebugKotlin` clean; bundles
regenerated. Note: CRM INITIAL-INPUT intentionally NOT seeded — its
comma-separated preselection semantics don't map to a filter query.

### Task 4: Neutralize completion-framework redirection during handlers

**Goal:** user configs using ivy/counsel/consult overrides can't route
prompts around the bridge.

**File:** `emacs/core/jetpacs-surfaces.el` — `jetpacs--on-action` (line ~124).

**Implementation:** in the `let` that binds `jetpacs--in-action-handler`,
also bind:

```elisp
(completing-read-function #'completing-read-default)
(read-file-name-function #'read-file-name-default)
(read-buffer-function nil)
```

(The `completing-read` advice fires regardless; these bindings cover
packages that dispatch through the `*-function` vars *before* reaching
the advised primitives — counsel overrides both file and buffer
functions.)

**Acceptance:** ERT: bind `read-file-name-function` to a lambda that
errors, run a stub action handler that calls `read-file-name` with the
dialog machinery stubbed — the picker path is taken, no error.

### Task 5: Honor INITIAL-INPUT in `completing-read`

**Goal:** `read-file-name` starts in its DIR argument instead of
wherever `default-directory` happens to point. (read-file-name passes
the directory as completing-read's INITIAL-INPUT.)

**File:** `emacs/core/jetpacs-minibuffer.el` —
`jetpacs--completing-read-advice` (line ~277).

**Implementation:** read `(nth 2 args)`; it is a string or a
`(STRING . POS)` cons — take the string part. Use it as the initial
query: `(funcall render initial)` instead of `(funcall render "")`, and
seed the filter `jetpacs-text-input` with `:value initial` **on the first
render only** (subsequent re-renders must stay uncontrolled — the
comment at jetpacs-minibuffer.el:352 explains why: a `:value` on re-render
stomps the user's cursor). Easiest: make `render` take a `seed` flag, or
build the first dialog specially. Also update the empty-submit fallback:
with initial input present and an empty reply, prefer the top match for
the initial query before falling back to DEF.

**Pitfalls:** the CRM advice (line ~411) takes the same args — apply the
same seeding there for consistency. Static-collection filtering
(`jetpacs-minibuffer--filter`) treats the query as substring tokens, which
is fine for initial input too.

**Acceptance:** ERT: stub the dialog send to capture the first spec;
`(completing-read "F: " #'read-file-name-internal nil nil "~/some/dir/")`
must render candidates from `~/some/dir/`, and the captured text_input
carries the seed. Live: phone REPL `(read-file-name "Find: " "~/")`.

### Task 6: `read-passwd` — masked input, no retention

**Goal:** TRAMP/GPG/auth-source passphrase prompts get a masked field;
the secret never lingers in UI state and never renders as plaintext.

**Files:** `emacs/core/jetpacs-minibuffer.el`,
`emacs/core/jetpacs-widgets.el`, Android:
`app/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt` (grep for
`text_input` / `single_line` to find the field renderer).

**Implementation:**

- `jetpacs-text-input`: new `:password` key emitting `'password t`.
- Dedicated `:around` advice on `read-passwd` (do not rely on the
  read-string advice — intercept before it): dialog with a
  `:password t` single-line input, OK/Cancel. Skip the context cards
  (`jetpacs--send-prompt-dialog` prepends them; call `jetpacs-send-dialog`
  directly here). After the reply: `remhash` the input id from BOTH
  `jetpacs--state-handlers` and `jetpacs--ui-state` so the secret isn't
  retained. Handle the CONFIRM arg by prompting twice and comparing
  (loop on mismatch with a "passwords differ" retry, max 3 tries →
  quit).
- Android: when `password` is true, apply
  `PasswordVisualTransformation`, `KeyboardType.Password`, and make sure
  the value isn't echoed into any debug logging.
- Regenerate `test/widgets.golden` (wire change).

**Acceptance:** ERT: advice returns the stubbed reply; ui-state hash
does not contain the input id afterwards. Live: phone REPL
`(read-passwd "Pass: ")` shows dots.

### Task 7: `read-answer` and `read-char-from-minibuffer` as buttons

**Goal:** modern core prompts ("y, n, q" style) render as buttons, not a
free-text box.

**File:** `emacs/core/jetpacs-minibuffer.el`

**Implementation:**

- `read-char-from-minibuffer (PROMPT &optional CHARS HISTORY)`: when
  CHARS is non-nil, reuse the `jetpacs--read-char-choice-advice` button
  pattern (line ~530); when nil, delegate to the read-char advice.
- `read-answer (QUESTION ANSWERS)`: ANSWERS is a list of
  `(LONG-ANSWER CHAR HELP)`. Render one button per entry labeled
  LONG-ANSWER with HELP as a caption row; return the chosen LONG-ANSWER
  **string** (that's read-answer's contract), quit on cancel.

**Acceptance:** ERT for both with stubbed dialog/wait; verify return
types (char vs string).

### Task 8: Skip the novice.el disabled-command prompt

**Goal:** commands marked disabled don't raw-read a char (hang) when
invoked from the phone.

**File:** `emacs/core/jetpacs-surfaces.el` — same `let` as Task 4: bind
`(disabled-command-function nil)` (nil = run the command normally).

**Acceptance:** mark a test command disabled, invoke via a stub handler,
no hang, command runs.

---

## P2 — Tier 0 renderer fidelity — ✅ DONE (2026-07-04), one sub-item deferred

Tasks 9, 11, 12, 13 fully done; Task 10 partially (space specs done,
inline images deferred — see below). All in `emacs/core/jetpacs-buffer.el`
unless noted.

- Task 9 (overlay before/after-strings): `jetpacs-buffer--overlay-strings`
  collects them, `jetpacs-buffer--string-spans` renders the propertized
  strings, and `jetpacs-buffer--line-spans` splices them into the run at
  the right column.
- Task 10 (display specs): `(space :width/:align-to …)` specs now become
  padding spaces (`jetpacs-buffer--space-width`). **DEFERRED: inline
  images.** They are block-level (an `jetpacs-image` node after the line),
  needing a separate render-region scan + file I/O, and `:data` images
  need a temp file — too much to fold into this pass safely. Tracked as
  a follow-up (see Task 10 body). `line-spans` currently renders the
  underlying text under an image display prop.
- Task 11 (face `:background`): `jetpacs-buffer--span-style` resolves
  `:background` (vs a new `jetpacs-buffer--default-bg-hex`) into a `:bg`
  span attr; `jetpacs-span` carries `bg`; `jetpacs-sync--fontify-runs` emits
  `(bg . HEX)`. Kotlin: `SduiContentNodes.kt` span `background` +
  `EditorSync.kt` `FontifyRun.bg`/`runStyle`.
- Task 12 (`line-prefix`): prepended as a dim gutter span in
  `render-region`.
- Task 13: font-lock-face fallback (line-spans + fontify), TAB expansion
  (`jetpacs-buffer--expand-tabs`, column-tracked), form-feed → divider,
  anonymous face plist `:inherit` (`jetpacs-buffer--ref-attr`).

9 new render tests in `test/jetpacs-primitives-test.el` (30 total, green);
main suite 45/45 including the widget golden (the `bg` attr is additive,
no regen); Kotlin `:app:compileDebugKotlin` clean; bundles regenerated.

### Task 9: Render overlay `before-string` / `after-string`

**Goal:** virtual text injected via overlays (flymake/flycheck inline
hints, diff-hl, annotations) stops silently vanishing.

**File:** `emacs/core/jetpacs-buffer.el` — `jetpacs-buffer--line-spans` /
`jetpacs-buffer--render-region`.

**Implementation:** these are OVERLAY properties, not char properties —
the existing `get-char-property` walk never sees them. Per rendered
line: `(overlays-in bol (min (1+ eol) (point-max)))`; for each overlay,
if it has a `before-string` and `(overlay-start ov)` ∈ [bol, eol],
schedule that string at overlay-start; `after-string` at
`(overlay-end ov)` likewise. Skip overlays that are currently invisible
(`invisible` prop that `invisible-p`). The strings are propertized:
render them through a small helper that walks
`next-single-property-change` over the STRING (string indices, not
buffer positions) mapping `face` via the existing
`jetpacs-buffer--span-style`. Merge: collect `(POS . SPANS)` insertions
first, then splice while walking the normal spans (emit pending
insertions whose POS ≤ current walk position).

**Pitfalls:** an overlay can span many lines — only emit its
before-string on the line containing overlay-start (use `memq`-style
dedupe or the position check above; `overlays-in` returns the same
overlay for every line it covers). Zero-length overlays (start = end)
are common for inline hints — the [bol, eol] check handles them.

**Acceptance:** ERT: temp buffer, zero-length overlay with a propertized
`before-string`, assert the rendered node list contains the injected
span with its style; same for `after-string` at line end; multi-line
overlay emits each string exactly once.

### Task 10: `display` specs beyond plain strings

**Goal:** inline images and spacing specs stop degrading to raw text /
collapsed alignment.

**File:** `emacs/core/jetpacs-buffer.el` — `jetpacs-buffer--line-spans`
(the `(stringp disp)` branch at line ~226).

**Implementation:** extend the display handling (a `display` value can
also be a list/vector OF specs — normalize to a list of specs first):

- **Image** (`(image . PLIST)` per `imagep` / spec with `:file` or
  `:data`): if `:file` exists and is readable, remember it; after the
  line's rich_text node is pushed, append an `jetpacs-image` node with
  `(concat "file://" (expand-file-name file))` (the client supports
  file:// per `jetpacs-image`'s docstring). Skip the covered buffer text
  (the display prop replaces it). `:data` images: skip in v1 (would need
  a temp file or a data URL — note as TODO).
- **Space** (`(space . PROPS)`): `:width N` → emit N spaces (round);
  `:align-to COL` → pad with spaces up to COL if the current rendered
  line length is tracked, else one space. Approximation is fine.
- Anything else non-string (e.g. `(raise ...)`, slices): fall through to
  the underlying buffer text as today.

**Pitfalls:** org inline images live on OVERLAYS with a `display` prop —
`get-char-property` already returns those, so this works once the spec
branch exists; verify with `org-display-inline-images`. Keep
`jetpacs-buffer-max-lines` cost in mind: no image file I/O beyond
`file-readable-p`.

**Acceptance:** ERT: buffer with `(put-text-property … 'display
'(space :width 4))` renders 4 spaces; a display image spec with a real
temp PNG emits an image node. Live: org file with an inline image →
image on phone.

### Task 11: Carry face `:background` (wire + client change)

**Goal:** diff hunk shading, hl-line, region, isearch, org-block
backgrounds survive the bridge. Highest-value fidelity item.

**Files:** `emacs/core/jetpacs-buffer.el` (`jetpacs-buffer--span-style`,
line ~115), `emacs/core/jetpacs-widgets.el` (`jetpacs-span`),
`emacs/core/jetpacs-sync.el` (`jetpacs-sync--fontify-runs`, line ~559),
Android: `app/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt` (grep
`underline` to find span style application) and wherever `fontify.show`
runs are applied (grep `fontify` under `app/src/`).

**Implementation:**

- `jetpacs-buffer--span-style`: resolve `:background` like `:foreground`;
  compute `jetpacs-buffer--default-bg-hex` alongside the fg default (bind
  it in `jetpacs-buffer--render-region` AND in `jetpacs-sync--push-fontify`)
  and only emit `:bg` when it differs.
- `jetpacs-span`: new `:bg` key → `'bg` attr. Fontify runs: add
  `(bg . HEX)`.
- Kotlin: `SpanStyle(background = Color(...))` for span `bg`; same for
  editor fontify runs.
- Regenerate `test/widgets.golden`.

**Acceptance:** ERT: face with only a background yields a span carrying
`bg` and no `color`. Live: magit diff on phone shows added/removed line
shading.

### Task 12: `line-prefix` text property

**Goal:** org-indent-mode's virtual indentation stops disappearing.

**File:** `emacs/core/jetpacs-buffer.el` — `jetpacs-buffer--render-region`.

**Implementation:** at each line's bol, read
`(get-char-property bol 'line-prefix)`; if it's a string, prepend it as
a dim mono span (styled like the line-number gutter). Non-string
prefixes (display specs): emit their `:width`-equivalent spaces if
trivially computable, else skip. Ignore `wrap-prefix` (device wraps at
different columns anyway).

**Acceptance:** ERT: buffer with a string `line-prefix` property renders
the prefix span first (after any line number).

### Task 13: Small fidelity batch

**File:** `emacs/core/jetpacs-buffer.el` (+ `jetpacs-sync.el` for the first
item).

One commit each, all small:

1. **`font-lock-face` fallback** — some log/process buffers set
   `font-lock-face` without font-lock-mode, so the `face` lookup misses:
   `(or (get-char-property pos 'face) (get-char-property pos
   'font-lock-face))` in `jetpacs-buffer--line-spans`; same in
   `jetpacs-sync--fontify-runs`.
2. **Tab expansion** — TABs ship raw and the phone's tab stops won't
   match `tab-width`. While walking spans, track the rendered column and
   replace each `\t` with spaces up to the next `tab-width` stop.
3. **Form feed** — a line consisting of `^L` (check via
   `display-table`-independent char test) renders as `(jetpacs-divider)`
   instead of a raw control char.
4. **Anonymous face plists with `:inherit`** —
   `jetpacs-buffer--ref-attr` plist branch ignores `:inherit`; when the
   plist lacks ATTR but has `:inherit`, recurse into the inherited
   face(s).

**Acceptance:** one ERT test per item (buffer fixture → rendered span
assertions).

---

## P3 — Liveness — ✅ Task 14 DONE (2026-07-04); Task 15 deferred (optional)

Task 14 implemented in `emacs/core/jetpacs-emacs-ui.el`: a "Live buffer
refresh" section adds a tick-comparison poll (`jetpacs-emacs-ui--live-poll`,
interval `jetpacs-emacs-ui-live-interval` default 1.0s, toggled by
`jetpacs-emacs-ui-live-refresh`) that re-pushes while a buffer is drilled
into. `jetpacs-emacs-ui--reconcile-live-watch` runs on
`jetpacs-shell-after-push-hook`, so the watch follows
`jetpacs-emacs-ui--viewing-buffer` however it changed; the poll self-stops
on disconnect, buffer death, or navigation away, and re-reads the tick
AFTER pushing so viewing *Messages* can't self-loop. Pure elisp — no
wire/Kotlin change. 2 new tests (32 total, green); main suite 45/45;
bundles regenerated.

Scope notes: the watch covers the drilled-in buffer case (compilation,
grep, async shell, and *Messages* when opened as a buffer from the
Buffers list). The dedicated "messages" nav-view keeps its manual
refresh button (it isn't server-trackable as the active view). Rendering
still shows the FIRST `jetpacs-buffer-max-lines`, not a tail — fine for
*Messages*/grep, less ideal for a long streaming compile; tail-rendering
is a possible follow-up.

**Task 15 (point/region indication) DEFERRED** — explicitly optional; it
re-touches the hot `line-spans' path (span-splitting at point) for modest
value on a read-mostly view. Left as a clean follow-up.

### Task 14: Live re-push for self-updating buffers

**Goal:** compilation/grep/async-shell/*Messages* buffers viewed on the
phone update as they change, instead of freezing at tap-time.

**Files:** `emacs/core/jetpacs-emacs-ui.el` (owns
`jetpacs-emacs-ui--viewing-buffer`), possibly a small helper in
`emacs/core/jetpacs-buffer.el`.

**Implementation:**

- When `jetpacs-emacs-ui--viewing-buffer` is set (see
  `emacs.buffer.view` action and `jetpacs-tablist-view-buffer-function`
  wiring at jetpacs-emacs-ui.el:29), add a buffer-local
  `after-change-functions` hook to that buffer plus a repeating ~1s
  timer comparing `buffer-chars-modified-tick` (belt-and-braces for
  insertions that dodge change hooks).
- Both paths funnel into one debounced re-push: an idle/one-shot timer
  (~0.5s, re-armed on further changes) calling `jetpacs-shell-push` —
  matching the debounce pattern of `jetpacs-shell--schedule-repush`
  (emacs/core/jetpacs-shell.el:261).
- Detach (remove hook, cancel timers) when: the viewing buffer changes,
  the view is left (`jetpacs-shell-view-switched-hook` already clears
  `jetpacs-emacs-ui--viewing-buffer` at jetpacs-emacs-ui.el:396 — detach
  there too), the buffer is killed (`kill-buffer-hook`, buffer-local),
  or the connection drops.
- Apply the same subscription to `*Messages*` while the "messages" view
  is current (track via the same view-switched hook). Guard against
  feedback: a push logs nothing by itself, but the message→toast advice
  plus this could interact — keep the debounce and add an
  equal-content memo (skip the push when the rendered tail is unchanged).

**Pitfalls:** never re-push from inside `after-change-functions`
directly (the change may be mid-command, and pushes are not reentrant) —
always via the timer. Cap: respect `jetpacs-buffer-max-lines`; for
compilation-style buffers consider tailing (render the LAST max-lines,
not the first) — acceptable to defer, but note it.

**Acceptance:** live: phone → Buffers → run `(compile "ping -n 5
127.0.0.1")` from the REPL → open the compilation buffer → output
streams in. ERT: with a fake connected state (stub `jetpacs-connected-p`
and capture `jetpacs-shell-push` calls), mutate the viewed buffer, run
timers via `(ert-run-idle-timers)` / manual `timer-event-handler`,
assert exactly one debounced push.

### Task 15 (optional): Point / region indication

**Goal:** the buffer view shows where point is; once Task 11 lands,
show the active region with a background.

**File:** `emacs/core/jetpacs-buffer.el`.

**Implementation:** in `jetpacs-buffer--line-spans`, when rendering the
line containing `(point)` of the source buffer, split the span at
point and insert a thin cursor span (e.g. `"▎"` colored via a theme
token). Region: when `(use-region-p)`, apply `:bg` (Task 11) to spans
within the region range. Gate both behind a defcustom
(`jetpacs-buffer-show-point`, default t).

**Acceptance:** ERT: point mid-line yields the cursor span at the right
split; region start/end mid-span splits correctly.

---

## P4 — Discovery & picker polish — ✅ DONE (2026-07-04)

Tasks 16–17 implemented and verified, both pure elisp (no wire/Kotlin
change).

- Task 16 (`emacs/core/jetpacs-keymap.el`): mines local + minor-mode
  menu-bar keymaps (not the generic global menu) into palette entries —
  `jetpacs-keymap--menu-entries` walks submenus with breadcrumb labels
  ("MyMenu ▸ Greet — Say hi"), honouring `:enable`/`:visible`/`:filter`
  and dropping separators. Palette candidates now carry a `(key . …)` or
  `(command . …)` TARGET; `jetpacs-keymap--execute-command` runs
  menu-derived commands by symbol through the same pie-sync + refresh
  path. Deduped by command, capped by `jetpacs-keymap-menu-max-items`.
- Task 17 (`emacs/core/jetpacs-minibuffer.el`): the picker now honours
  `affixation-function` (M-x key hints, marginalia columns — computed
  once over the shown batch) and `group-function` (section-header
  dividers when the group changes). New helpers
  `jetpacs-minibuffer--decorations`/`--picker-cards`/`--group-fn`;
  affixation PREFIXES are preserved verbatim (their separator spacing is
  intentional), SUFFIXES trimmed to captions. CRM keeps the simpler
  annotator path.

4 new tests (34 total, green); main suite 45/45 including keymap-labels
and the widget golden (no new widget constructors → no regen); bundles
regenerated.

### Task 16: Mine menu-bar keymaps for the command palette

**Goal:** human-curated labels/help from mode menus (the one place
authors write real labels) feed the palette, instead of being filtered
out (emacs/core/jetpacs-keymap.el:81 excludes all menu-bar bindings).

**File:** `emacs/core/jetpacs-keymap.el`.

**Implementation:** new extractor: walk
`(lookup-key (current-active-maps) [menu-bar])`; for each `menu-item`
entry collect label, `:help`, the command, honoring `:enable` /
`:visible` predicates (evaluate in `condition-case`, exclude on nil) and
resolving `:filter` functions (call with the item, `condition-case`).
Recurse into submenus, building breadcrumb labels ("File ▸ Save As…").
Feed these into `jetpacs-keymap--palette-candidates` as additional entries
— display `"LABEL — HELP"` mapping to the command symbol. Execution:
palette currently executes a KEY via `jetpacs-keymap--execute-key`; menu
items may have no key, so extend the palette to carry either a key or a
command symbol, and for commands `call-interactively` them through the
same post-execution path (`jetpacs-keymap--sync-pie` + refresh). This stays
within the existing dispatch boundary — the palette already executes
arbitrary buffer-local bindings; menu items are the same class of
curated, mode-owned commands.

**Acceptance:** ERT: in a `text-mode` temp buffer the candidates include
menu-derived entries with breadcrumb labels; `:enable`-nil items
excluded. Live: palette in an org buffer shows the Org menu's labeled
entries.

### Task 17: `affixation-function` + `group-function` in the picker

**Goal:** captions/grouping parity with modern completion UIs
(marginalia's and `describe-*`'s metadata).

**File:** `emacs/core/jetpacs-minibuffer.el` —
`jetpacs-minibuffer--annotator` (line ~262) and the render closures.

**Implementation:** in the annotator resolution, also check metadata /
`completion-extra-properties` for `affixation-function`. Affixation
takes the candidate LIST and returns `(CAND PREFIX SUFFIX)` triples —
call it once per render on the shown page (≤50 candidates), use SUFFIX
as the annotation and prepend PREFIX to the label. `group-function`:
when present in metadata, `(funcall gf cand nil)` per shown candidate;
insert an `jetpacs-section-header` whenever the group title changes
(candidates are already sorted; group order = first appearance).

**Acceptance:** ERT: a collection with metadata providing each function
renders headers and affixed labels (stub dialog capture).

---

## P5 — Regression net — ✅ DONE (2026-07-04)

Task 18 complete. The gauntlet grew incrementally across P0–P4 and P5
filled the gaps: `test/jetpacs-primitives-test.el` is now **45 tests**,
test-only (no production change). P5 added the pre-existing prompt
bridges (`y-or-n-p`, `yes-or-no-p`, `read-from-minibuffer`/`read-string`,
`read-char`, `read-char-choice`, `read-multiple-choice`, static + dynamic
`completing-read` pick, `completing-read-multiple`) plus two more render
substrates (collapsed outline fold affordance, tabulated-list cards).

Coverage now spans: every advised prompt primitive (return-value contract
+ dialog shape via the stub harness), and the render substrates
background-only face, font-lock-face, anonymous `:inherit`, line-prefix,
TAB, form-feed, overlay before/after-strings, display space, folded
outline, and tabulated-list. Left out (heavier fixtures, low regression
risk): a full Customize widget buffer and a dired temp-dir listing —
their code paths (widget button/field detection, the dired card skin)
are exercised in the running app.

### Task 18: The primitive gauntlet

**Goal:** every gap fixed above becomes a permanent regression test;
every primitive claimed as "covered" is asserted, not assumed.

**File:** new `test/jetpacs-primitives-test.el` (mirror the header/load
pattern of `test/jetpacs-tests.el`; make sure `test/run-tests.sh` picks it
up or add the invocation there).

**Structure:**

- **Render fixtures** — one `ert-deftest` per substrate, each building a
  buffer and asserting on `(jetpacs-render-buffer buf)` output: plain
  fontified elisp; folded outline (fold affordance spans); dired over a
  temp dir (cards via the skin); `tabulated-list-mode` fixture (tablist
  cards); Customize-style widget buffer (button + field spans); overlay
  before/after-strings; display space + image; background-only face;
  `font-lock-face` buffer; TAB alignment; line-prefix.
- **Prompt harness** — a macro that binds `jetpacs--in-action-handler`,
  stubs `jetpacs--send-prompt-dialog` (capturing specs) and
  `jetpacs--wait-for-prompt` (returning scripted replies), then one test
  per advised function: `y-or-n-p`, `yes-or-no-p`,
  `read-from-minibuffer`, `read-string`, `completing-read` (static +
  dynamic + INITIAL-INPUT + DEF fallback), `completing-read-multiple`,
  `read-char`, `read-char-choice`, `read-multiple-choice`,
  `map-y-or-n-p`, `read-event`/`read-key-sequence` (incl. the
  `executing-kbd-macro` passthrough), `read-passwd` (masked flag, state
  scrubbed), `read-answer`, `read-char-from-minibuffer`.
- Assert both the RETURN VALUE contract and key dialog-spec properties
  (e.g. password flag present, buttons labeled from ANSWERS).

**Acceptance:** suite green in batch mode on Emacs 28+; deliberately
reverting one fix (e.g. the bg span) fails exactly its test.

---

## Suggested commit sequence

One commit per task, message style matching the log (`feat:`/`fix:`
prefixes seen in `git log`). After each elisp change: regenerate bundles
(`emacs --batch -l emacs/build-bundle.el`), run the test suite, and
regenerate the widget golden only when the wire format intentionally
changed (Tasks 6, 11). Android-touching tasks (6, 11) should build the
app (`gradlew :app:assembleDebug`) before committing.
