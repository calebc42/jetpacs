# Building your own Tier 1

The core (`jetpacs-core.el`) is deliberately unopinionated: it will render
any buffer, palette any keymap, and bridge any prompt — but it has no
idea what *your* workflow looks like. That layer is yours.
[Glasspane](https://github.com/calebc42/glasspane) (the org app, in its
own repo) is one opinion; this guide is the map for writing another, at
whatever size fits: a single buffer skin, a curated pie menu, or a full
app with its own tabs.

Everything below assumes `(require 'jetpacs-emacs-ui)` or the `jetpacs-core.el`
bundle is loaded. Nothing here requires Glasspane.

Two companion documents: [TUTORIAL.md](TUTORIAL.md) builds a first app
line by line — if this is your first Tier 1, do that walk before
reading this map — and [WIDGETS.md](WIDGETS.md) is the reference for
every node constructor the examples below use.

## Zero to Hello (five minutes)

Prove the loop before reading further — a Tier 1 is developed *live*
against a running phone, and feeling that loop is the best argument for
building one:

1. Install the companion APK and pair, per the
   [README](../README.md#getting-started). Load `jetpacs-core.el` only —
   no app.
2. The phone shows the core tabs (Files / Eval / Tools). From **the
   phone's own Eval tab** — or any Emacs REPL — evaluate:

   ```elisp
   (load "/path/to/jetpacs/emacs/apps/jetpacs-hello.el")
   ```

3. A **Hello** tab appears in the bottom bar, without a restart or an
   explicit push. Open [`jetpacs-hello.el`](../emacs/apps/jetpacs-hello.el)
   (~60 lines, heavily commented), change the card text, re-evaluate —
   the phone follows.

That file demonstrates the whole shape of a Tier 1: a view builder made
of widget constructors ([WIDGETS.md](WIDGETS.md) catalogues them all),
one allowlisted action, a tab registration, and an app identity.
Everything else in this guide is that pattern at larger sizes; the
guided version of this loop — with an input round trip and a list —
is [TUTORIAL.md](TUTORIAL.md).

## The extension surfaces, smallest first

Most data-bound screens can be a **declarative `:spec`** — a named source plus
a card template, no elisp view function — see [BINDING.md](BINDING.md). The
surfaces below are the general escape hatch for when you need code.

### 1. A buffer skin — restyle one major mode

Register a function that turns a buffer into a list of widget nodes, and
every appearance of that mode (the Buffers tab, the Files view, a skin
that opens it) uses your rendering instead of the generic one:

```elisp
(require 'jetpacs-buffer)
(require 'jetpacs-widgets)

(defun my/proced-cards (buffer)
  (with-current-buffer buffer
    (mapcar (lambda (line) (jetpacs-card (list (jetpacs-text line 'mono))))
            (split-string (buffer-string) "\n" t))))

(jetpacs-render-buffer-register 'proced-mode #'my/proced-cards)
```

Fall through is automatic: modes you don't register keep the faithful
Tier 0 rendering, so a skin is pure polish, never a prerequisite.

Special case, zero code: if your package's buffers are **shr-rendered
HTML** (a feed reader, an EPUB reader, a docs browser), don't write a skin
at all — ride the hypertext substrate, which renders headings, tappable
links, real images, and native tables:

```elisp
(with-eval-after-load 'my-reader
  (jetpacs-hypertext-register-shr-mode 'my-reader-mode))
```

(elfeed-show, nov, and devdocs are already wired this way in the core;
eww, help, and Info render as documents out of the box.)

### 2. A tablist skin — specialize the table renderer

Anything derived from `tabulated-list-mode` already renders as sortable
cards. To specialize without replacing the walk, set entries in the three
hook alists — header (filters, bulk actions), row (custom card), filter
(which rows show). **The worked example is
[`jetpacs-package-browser.el`](../emacs/core/jetpacs-package-browser.el)**
(it ships in the core as stock chrome): ~230 lines that
turn the stock package menu into a searchable browser with
install/delete — read it top to bottom, it demonstrates every hook plus
the action rules below.

### 3. A curated pie menu

The command palette is the Tier 0 default for raw keymaps; the radial pie
is reserved for menus with human-written labels and ≤ ~10 items. Live
transient sessions get a pie automatically (jetpacs-keymap syncs it); for a
hand-curated pie over a mode, see
[`jetpacs-magit.el`](https://github.com/calebc42/glasspane/blob/main/emacs/apps/jetpacs-magit.el)
(glasspane repo) — pure data plus key dispatch through the existing
allowlisted action.

### 4. Shell views — your own tabs

The shell (`jetpacs-shell.el`) owns the phone's app scaffold: bottom-bar
tabs, drawer, top bar, snackbar, pull-to-refresh, and the push that ships
every view in one multi-view surface. An app is a set of registered
views.

Tier 1 development is **live**: registering or removing a view on a
connected session schedules a push automatically, so `eval-buffer` (or
`load`) against a running phone updates the app in place — and a builder
that signals renders as an error view instead of breaking the push. The
smallest runnable example is
[`emacs/apps/jetpacs-hello.el`](../emacs/apps/jetpacs-hello.el) — load it into
a core-only session and a Hello tab appears. A larger one:

```elisp
(require 'jetpacs-shell)

(defun my/bookmarks-body ()
  (apply #'jetpacs-lazy-column
         (mapcar (lambda (bm)
                   (jetpacs-card (list (jetpacs-text (car bm) 'body))
                              :on-tap (jetpacs-action "marks.jump"
                                                   :args `((name . ,(car bm))))))
                 bookmark-alist)))

(with-jetpacs-owner "marks"

  (jetpacs-shell-define-view "marks.bookmarks"
    :builder (lambda (snackbar)
               (jetpacs-shell-tab-view "marks.bookmarks" (my/bookmarks-body)
                                    :snackbar snackbar))
    :tab '(:icon "bookmark" :label "Marks")
    :order 15)

  (jetpacs-defaction "marks.jump"
    (lambda (args _)
      (when-let ((bm (assoc (alist-get 'name args) bookmark-alist)))
        (bookmark-jump (car bm)))
      (jetpacs-shell-notify "Jumped")   ; snackbar on the next push
      (jetpacs-shell-push))))           ; re-render everything (cheap: memoise!)
```

That's a complete Tier 1: load it next to `jetpacs-core.el` and the phone
grows a Marks tab next to the core tabs. **Two naming rules make
your app safe next to any other:** view names live in your app's
namespace (`"<appid>.<view>"`, or bare `"<appid>"` for a single-view
app) because the registry replaces by name; and registrations run inside
`with-jetpacs-owner` so they're attributed to you (§7). The pieces:

- `jetpacs-shell-define-view NAME :builder FN` — FN gets the snackbar text
  (or nil) and returns a scaffold view. Use `jetpacs-shell-tab-view` (tab
  chrome: drawer, bottom bar, pull-to-refresh) or `jetpacs-shell-nav-view`
  (back-arrow chrome) rather than hand-building scaffolds.
- `:tab '(:icon I :label L)` puts it in the bottom bar; add
  `:badge FN` (a nullary function, called per push) to overlay a count
  on the tab icon — return a number (99+ caps on-device), `""` for a
  bare dot, or nil for none; errors render no badge, never a broken
  push. `:when PRED` includes it only sometimes (an editor view while a
  file is open); `:overlay PRED` makes it the active view while the
  predicate holds (a detail drill-in) without being a tab.
- `jetpacs-shell-add-drawer-item` / `jetpacs-shell-add-top-action` add
  chrome. Registered under `with-jetpacs-owner`, chrome belongs to your
  app: it shows only while yours is the current app (once a second app
  exists). `(jetpacs-apps-set-default-fab "appid" FN)` offers your app's
  signature affordance on its tab views (Glasspane uses it for Capture)
  without leaking onto anyone else's.
- Hooks: `jetpacs-shell-view-switched-hook` (reset drill-in state),
  `jetpacs-shell-refresh-hook` (drop your memo caches — pull-to-refresh and
  queue drains run it), `jetpacs-shell-after-push-hook` (piggyback cheap,
  memo-guarded sends: home-screen widgets, reminders).

### 4½. Group your views into an app (`jetpacs-defapp`)

One `jetpacs-defapp` call gives your views an identity in the launcher:

```elisp
(jetpacs-defapp "marks" :label "Marks" :icon "bookmark"
             :views '("marks.bookmarks"))
```

While only one app is registered nothing changes — the phone boots
straight into it, exactly as today. From the second app on, a **home
grid** appears (an "Apps" drawer entry navigates to it, offline-capable
via the multi-view switch), each card opens its app, and the bottom bar
shows one app's tabs at a time. Views no app claims — the core Files /
Eval / Tools tabs — show in every app; claim them in an explicit app of
their own (say `"system"`) to contain them. The first `:tab` view in
`:views` is the app's landing tab.

**A home-screen icon of its own.** An app — or a whole distro — can put
its logo on the Android home screen, no APK and no Kotlin:

```elisp
(jetpacs-device-shortcut-pin
 "marks" "Marks"
 (jetpacs-action "app.open" :args '((app . "marks")))
 :icon-file "~/marks/logo.png")
```

Tapping the pin opens the companion and fires the action through the
normal tap pipeline — `app.open` lands on your app's landing tab, but
any action works. The PNG is masked to the launcher's adaptive-icon
shape (square and full-bleed, 432 px or larger, keep the mark inside
the middle two-thirds); Android badges the pin with the companion's
own icon (OS-enforced) and asks the user to confirm the first pin.
Re-pinning the same id updates logo, label, and action in place — how
you ship a logo refresh. `jetpacs-device-shortcuts-set` fills the
companion icon's long-press menu the same way (both SPEC §10).

### 5. Per-file-type editor behaviour

`jetpacs-files.el` owns the Files tab and the plain editor; your app teaches
it about a file type without the core learning anything:

- `jetpacs-files-editor-body-functions` — return a replacement body for FILE
  (Glasspane returns its foldable org reader), or nil to keep the editor.
- `jetpacs-files-editor-actions-functions` — add top-bar buttons for FILE.
- `jetpacs-files-editor-toolbar-function` — return a keyboard toolbar the
  companion should attach: a list of `jetpacs-toolbar-item`s (data the
  companion interprets locally — no Kotlin, no Emacs round-trip per tap),
  or a string naming a toolbar the host registered natively (the
  reference companion registers none).
- `jetpacs-files-open-hook` / `jetpacs-files-after-save-hook` — set per-type
  state on open; drop caches after a phone-side save.

**Your own keyboard toolbar** is a few items (SPEC §9 "Editor
toolbars"): each carries exactly one op — `:snippet` (local insertion
with `${selection}`/`${cursor}`/`${input:Prompt}`/`${date}`/`${time}`
placeholders and optional `:placement`), `:line` (builtin
promote/demote/move-up/move-down), `:on-tap` (any action — the Emacs
escape hatch), or `:menu` (a dropdown of sub-items):

```elisp
(defun my-md-toolbar ()
  (list
   (jetpacs-toolbar-item "format_bold" "B" :snippet "**${selection}**")
   (jetpacs-toolbar-item "format_list_bulleted" "•"
                      :snippet "- " :placement "line-start")
   (jetpacs-toolbar-item "title" "H" :menu
                      (list (jetpacs-toolbar-item nil "# H1"
                                               :snippet "# " :placement "line-start")
                            (jetpacs-toolbar-item nil "## H2"
                                               :snippet "## " :placement "line-start")))
   (jetpacs-toolbar-item "schedule" "TS" :snippet "${date}"
                      :long-press (jetpacs-toolbar-item nil nil :snippet "${time}"))))

(add-function :before-until jetpacs-files-editor-toolbar-function
              (lambda (file)
                (and (string-suffix-p ".md" file) (my-md-toolbar))))
```

`jetpacs-lint-spec` validates the item vocabulary in your tests, and the
whole toolbar rides the ordinary `:toolbar` key of `jetpacs-editor`, so
detail views outside the Files tab attach it the same way.

### 6. Settings

The foundation provides two drawer destinations: native **Jetpacs
Settings**, which works offline, and the stock `"settings"` view under
**Emacs Settings**, which renders every registered section and satellite
link. You register content, not chrome:

- `(jetpacs-settings-register-section TITLE ENTRIES)` exposes
  defcustoms; they appear on the stock screen rendered from their
  `custom-type` schemas. The registry is a security boundary: only
  listed symbols can be set from the wire, values are validated against
  the schema, and persistence goes through Customize. Register
  cache-invalidation on `jetpacs-settings-after-set-hook`.
- `(jetpacs-settings-add-link ORDER BUILDER)` adds a navigation card to
  a satellite screen (Customize, a package browser, tools) under the
  trailing "Emacs Settings" section.
- `(jetpacs-settings-add-native-link ORDER BUILDER)` adds a card to
  the leading "Jetpacs Settings" section. Its action should be a local
  builtin so Android configuration remains reachable with Emacs offline;
  `jetpacs-native-settings-action` opens the
  stock native destination.

The screen ships with native Jetpacs Settings and an Emacs Settings group
whose Bridge subsection contains theme mirroring, dialog style, and
auto-reconnect. Register your sections
under `with-jetpacs-owner` (§7): owned sections and links show only while
your app is current, so two apps' settings never interleave.

An app that needs controls the schema renderer can't express defines its
own `"<appid>.settings"` view and splices `(jetpacs-settings-sections)` at
the end of its own scrollable body so registered sections and links keep
appearing:

```elisp
(apply #'jetpacs-lazy-column
       (append (list my-controls…)
               (jetpacs-settings-sections)))
```

The Emacs Settings drawer entry resolves to `"<appid>.settings"` while
your app is current (`jetpacs-shell-resolve-view`), so you register no
drawer entry and never touch the stock view. Do **not** redefine the
stock `"settings"` view by name — with several apps loaded, the last
registration would hijack the screen for all of them. (`jetpacs-shell-settings-body` is that lazy column with *only*
the sections — use it as an entire body, never nested inside your own
lazy column; scroll containers don't nest.)

### 7. Owning your registrations

Every session assumes it may host more than one app, so wrap your
registrations — views, actions, settings sections and links, drawer
items, top actions — in `with-jetpacs-owner`:

```elisp
(with-jetpacs-owner "marks"
  (jetpacs-defaction "marks.jump" #'my/jump)
  (jetpacs-shell-define-view "marks" :builder #'my/marks-body :tab '(:icon "bookmark")))
```

Three payoffs. First, if another app registers the same action, view, or
settings name, you get a warning (or an error under
`jetpacs-strict-namespaces`) instead of a silent clobber — actions are the
wire's security boundary, so a collision is worth surfacing. Same-owner
re-registration stays silent, so `eval-buffer` during live development is
never noisy. Second, ownership is what scopes your chrome to your app:
owned drawer items, top actions, and settings content show only while
your app is current — unowned ones show everywhere, which is right for
the core and wrong for an app. Third, `(jetpacs-app-unregister "marks")`
tears down everything owned by the app — its actions, views, chrome,
settings content, FAB, and UI-state — in one call, for clean live reload
or a genuine uninstall. `jetpacs-defapp` already attributes its `:views`
to the app id; the owner wrap covers everything else.

## The platform beyond the screen

An app is more than its tabs. Everything in this part ships in the
core and is negotiated per connection: `jetpacs-granted-p` tells you
whether the session carries a capability, `jetpacs-device-cap-p`
whether the companion has a given effector, `jetpacs-device-can-p`
whether a runtime permission is granted, and `jetpacs-node-supported-p`
whether a widget node exists ([WIDGETS.md](WIDGETS.md) shows the
gating pattern). Degrade, don't assume.

### 8. Drive the device (effectors)

`jetpacs-device.el` wraps every
[SPEC §10](SPEC.md#10-device-capabilities-optional) capability in one
thin defun, callable from any action handler, trigger handler, or the
Eval tab:

- `jetpacs-device-intent` — fire any Android intent
  (activity / broadcast / service); the universal escape hatch.
- `jetpacs-device-app-launch`, `jetpacs-device-apps-list`, and the
  interactive `jetpacs-device-launch-app` picker.
- `jetpacs-device-shortcut-pin` / `jetpacs-device-shortcuts-set` —
  the launcher icons of §4½.
- `jetpacs-device-vibrate`, `-tts`, `-flashlight`, `-media-key`.
- `jetpacs-device-volume-set`, `-ringer-mode`, `-dnd`, `-brightness`,
  `-settings-open`, `-keep-screen-on`.
- `jetpacs-device-clipboard-read` (takes a callback; the OS exposes
  the clipboard only to the focused app).
- `jetpacs-device-permissions-dialog` — the interactive permission
  report, with deep links to each grant screen.

```elisp
(jetpacs-defaction "myapp.focus"
  (lambda (_args _)
    (jetpacs-device-dnd "priority")
    (jetpacs-device-tts "Focus mode on")
    (jetpacs-shell-notify "Focus until you say otherwise")))
```

Failures come back typed, never silent: a `cap-permission` error names
the missing permission and carries a settings deep link. Gate optional
controls on `jetpacs-device-cap-p` / `jetpacs-device-can-p`, and reach
for raw `jetpacs-capability-invoke` only when no wrapper exists yet.

### 9. React to the device (triggers & automations)

The other direction — Android events delivered to elisp
([SPEC §11](SPEC.md#11-device-triggers-optional)):

```elisp
(jetpacs-deftrigger myapp/on-charge
  :type "power" :params '((state . "connected")) :policy "wake"
  :handler (lambda (_data _args) (myapp-sync)))
```

- Ten trigger types: `time` (one-shot or repeating, exact alarms),
  `power`, `battery.level` (edge-crossing hysteresis), `screen`,
  `headset`, `airplane`, `boot`, `timezone.changed`, `package`,
  `network`. A type this companion can't host is skipped
  per-registration, never poisoning the set.
- Fires arrive as ordinary actions through the offline queue — pick
  `:policy` (`"queue"` / `"drop"` / `"wake"`), `:dedupe`, and
  `:throttle-s` exactly as you would for a button.
- `:on-fire` runs **with Emacs dead**: a companion-local vector of
  capability invocations and/or a notification, deliberately without
  conditionals or loops —

  ```elisp
  :on-fire [((cap . "flashlight") (args . ((on . t))))
            ((notify . ((title . "Charger connected"))))]
  ```
- The registered set persists on-device and re-arms after reboot;
  replace-set semantics mean an unregistered trigger can never fire
  stale.
- Users manage every registration on the stock **Automations** screen
  (enable switch — persisted, wire summary, last fired, "Fire now"),
  and `jetpacs-trigger-test-fire` exercises the same dispatch path
  from the desktop.

### 10. Surfaces beyond the app: notifications, widgets, tiles

`jetpacs-shell-push` serves the `app:*` surface; `jetpacs-surface-push`
serves every other namespace ([SPEC §4](SPEC.md#4-surfaces)) with
automatic monotonic revisions, and the companion keeps rendering the
last push while Emacs is away.

A live notification — ongoing, with a running chronometer (the shape
of a clock or timer) and a *Done* action button that clears it:

```elisp
(jetpacs-surface-push "notification:myapp.brew"
  (jetpacs-notification-spec
   :channel "myapp" :ongoing t
   :chronometer `((base_ms . ,(truncate (* 1000 (float-time)))))
   :body (list (jetpacs-text "Tea steeping" 'title))
   :actions (list (jetpacs-notification-action
                   "Done" (jetpacs-action "myapp.brew-done")
                   :icon "check" :dismiss t))))
;; later: (jetpacs-surface-remove "notification:myapp.brew")
```

Action buttons live in `:actions` ([SPEC §9](SPEC.md#9-widget-vocabulary));
each dispatches its action like any tap. `:dismiss t` clears the
notification when tapped (the Done/Snooze affordance), and `:reply t`
(with an optional `:reply-hint`) turns a button into an inline text
reply whose typed text arrives in the action's `event.action` `fields`.

Five blank home-screen widget slots (`widget:custom1` … `custom5`)
render lists of `jetpacs-widget-item` rows; `header_action` is the
widget header's "+" button:

```elisp
(jetpacs-surface-push "widget:custom1"
  `((title . "Inbox")
    (header_action . ,(jetpacs-action "myapp.capture"))
    (items . ,(vconcat (mapcar #'myapp--widget-row (myapp-items))))
    (empty . "All clear")))
```

Five Quick Settings tile slots (`tile:custom1` … `custom5`) take a
`jetpacs-tile` spec the same way — and a tile without `:in-app` fires
from the shade with the phone still locked, so compose accordingly.
Refresh these surfaces from `jetpacs-shell-after-push-hook`,
memo-guarded, so they ride pushes you were making anyway. Persistent
reminders (`reminders.set`,
[SPEC §7](SPEC.md#7-dialogs-toasts-pies-reminders)) ride the same
connection and survive reboots; the core has no elisp wrapper for them
yet.

### 11. Look like the user's Emacs (theme mirroring)

`(setq jetpacs-theme-sync t)` extracts a Material palette and editor
syntax colors from the running Emacs theme (the modus-themes palette
API when one is active, resolved face attributes otherwise) and
mirrors them onto the companion — chrome, widgets, and highlighting
alike, persisted while Emacs is away. `M-x jetpacs-theme-send` pushes
once without opting in; `M-x jetpacs-theme-clear` hands the companion
back to Material You. The ladder: synced Emacs theme, else Material
You, else the built-in fallback.

### 12. The editor bridge, end to end

Every `jetpacs-editor` on a connected session can carry the full
bridge with zero app code: Emacs-backed completion (`:complete`),
flymake squiggles (`jetpacs-sync-diagnostics`), an eldoc line
(`jetpacs-sync-eldoc`), and Emacs-faithful highlighting
(`jetpacs-sync-fontify`) — plus opt-in LSP via `jetpacs-sync-eglot`
and `jetpacs-sync-eglot-modes`, and `jetpacs-sync-shadow-setup-hook`
for per-shadow-buffer setup. The sync invariant is worth repeating to
your users: the shadow buffer never writes to disk, so a lost frame
can only cost a feature, never corrupt an edit.

`jetpacs-witheditor.el` extends the bridge to editor *callbacks*: a
`git commit` or interactive rebase started from a phone action pops
the message buffer as a phone editor with Commit / Cancel — magit
works end-to-end with no app code.

### 13. What the core already ships

Chrome every app inherits — link to it, don't rebuild it:

- **Files** — a root-confined browser (`jetpacs-files-roots`), the
  plain editor with your per-type seams (§5), and a pure-elisp content
  search with bounded cost (the `jetpacs-files-grep-*` defcustoms).
- **Eval** — a REPL with history and the full editor bridge on its
  input row.
- **Buffers / Messages** — any buffer rendered via Tier 0 with imenu
  section drill-in; a live *Messages* tail; a `message` → toast mirror
  (`jetpacs-forward-messages`).
- **M-x** — the one sanctioned arbitrary-command path, prompts
  bridged.
- **Tools** — bookmarks, the kill ring (companion-local copy, works
  offline), a shell, process and timer lists. Any `comint` buffer
  renders as transcript + input row (`jetpacs-comint-render`), so
  ielm and language REPLs come free.
- **Settings satellites** — the package browser (§2's worked example),
  the customize browser (every `custom-variable-p` symbol rendered
  from its schema — `M-x customize` parity), and the Automations
  screen (§9).
- **Documents** — eww, help, and Info render as document cards
  (headings, tappable links, real images, native tables); any other
  shr-rendered mode rides in one line (§1's
  `jetpacs-hypertext-register-shr-mode`).
- **Section buffers** — anything built on the `magit-section` library
  (magit, forge, kubernetes.el, `taxy-magit-section` consumers) renders
  as collapsible cards: instant client-side folding, row taps that
  follow into the region view, long-press for the section's own key
  bindings as a menu. Nothing to register — the base mode covers every
  derivative.
- **Remote hosts** — a card per TRAMP endpoint (your `jetpacs-hosts`
  entries plus `~/.ssh/config` discoveries): browse its files, open a
  shell on it, glance at its services (`daemons.el`), disconnect. The
  ssh password prompt is a phone dialog; everything opened rides the
  substrates above, so remote dired/magit/compile need nothing new.

## The rules that keep the wire safe

Read [SPEC §5](SPEC.md#5-events-the-semantic-action-boundary) before
defining actions. In short:

1. **Actions are an allowlist.** `jetpacs-defaction` registers a name; the
   handler validates its args and performs one specific operation. Never
   write a handler that runs code, commands, or paths straight off the
   wire.
2. **Namespace your actions** (`my.bookmark.jump`, not `jump`). Core
   namespaces are listed in the spec.
3. **Choose queue policies deliberately.** `:when-offline "queue"` for
   mutations (they replay), `"drop"` for navigation and refreshes,
   `"wake"` for things worth starting Emacs over. Give repeated mutations
   a `:dedupe` key.
4. **Honor the cache contract.** If your views memoise, every mutation
   path must invalidate — your own actions directly, plus a handler on
   `jetpacs-shell-refresh-hook` for pull-to-refresh and queue replays.
5. **Prompts are free.** Inside an action handler the whole prompt zoo
   is bridged to native dialogs: `y-or-n-p` / `yes-or-no-p` /
   `map-y-or-n-p`, `read-string` / `read-from-minibuffer`,
   `read-passwd` (a masked field), `completing-read` and
   `completing-read-multiple`, `read-char-choice` /
   `read-multiple-choice` / `read-answer`, even raw `read-event` and
   `read-key-sequence` — with `jetpacs-prompt-timeout` bounding a
   prompt left unanswered. Write handlers as if the user were at the
   keyboard. Dialogs you send yourself (`jetpacs-send-dialog`) can
   render as bottom sheets via `jetpacs-dialog-style` or the per-call
   STYLE.

## Shipping it

A Tier 1 is an ordinary Emacs package that requires the core features it
uses. Users load `jetpacs-core.el` (or the individual `emacs/core/` files)
plus your package. On desktop the core installs as a package straight
from git — no MELPA wait:
`(package-vc-install '(jetpacs :url "https://github.com/calebc42/jetpacs" :lisp-dir "emacs/core"))`
(see the [README](../README.md#getting-started) for when that path
applies; the phone path stays bundle adoption). If you want a
single-file artifact, mimic
`emacs/build-bundle.el` — concatenation in dependency order is the whole
trick. Glasspane's own
[`build-bundle.el`](https://github.com/calebc42/glasspane/blob/main/emacs/build-bundle.el)
is the worked example of an *app* bundle: app sources only, opening with
`(require 'jetpacs-core)` instead of inlining the core.

Distributing your app as its own repo? Copy Glasspane's shape wholesale —
it vendors this repo as a git submodule for its load-path and CI, keeps
zero Kotlin, and its
[workflow](https://github.com/calebc42/glasspane/blob/main/.github/workflows/ci.yml)
runs ERT against the submodule core with `submodules: recursive`. That
whole repo exists to be copied from.
