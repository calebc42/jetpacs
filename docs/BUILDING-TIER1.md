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
of widget constructors, one allowlisted action, a tab registration, and
an app identity. Everything else in this guide is that pattern at
larger sizes.

## The extension surfaces, smallest first

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

### 2. A tablist skin — specialize the table renderer

Anything derived from `tabulated-list-mode` already renders as sortable
cards. To specialize without replacing the walk, set entries in the three
hook alists — header (filters, bulk actions), row (custom card), filter
(which rows show). **The worked example is
[`jetpacs-package-browser.el`](https://github.com/calebc42/glasspane/blob/main/emacs/apps/jetpacs-package-browser.el)**
(in the glasspane repo, where the reference apps live): ~230 lines that
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
                              :on-tap (jetpacs-action "my.bookmark.jump"
                                                   :args `((name . ,(car bm))))))
                 bookmark-alist)))

(jetpacs-shell-define-view "bookmarks"
  :builder (lambda (snackbar)
             (jetpacs-shell-tab-view "bookmarks" (my/bookmarks-body)
                                  :snackbar snackbar))
  :tab '(:icon "bookmark" :label "Marks")
  :order 15)

(jetpacs-defaction "my.bookmark.jump"
  (lambda (args _)
    (when-let ((bm (assoc (alist-get 'name args) bookmark-alist)))
      (bookmark-jump (car bm)))
    (jetpacs-shell-notify "Jumped")   ; snackbar on the next push
    (jetpacs-shell-push)))            ; re-render everything (cheap: memoise!)
```

That's a complete Tier 1: load it next to `jetpacs-core.el` and the phone
grows a Marks tab between Agenda-less core tabs. The pieces:

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
- `jetpacs-shell-add-drawer-item` / `jetpacs-shell-add-top-action` add global
  chrome; `jetpacs-shell-default-fab-function` offers your app's signature
  affordance on tab views (Glasspane uses it for Capture).
- Hooks: `jetpacs-shell-view-switched-hook` (reset drill-in state),
  `jetpacs-shell-refresh-hook` (drop your memo caches — pull-to-refresh and
  queue drains run it), `jetpacs-shell-after-push-hook` (piggyback cheap,
  memo-guarded sends: home-screen widgets, reminders).

### 4½. Group your views into an app (`jetpacs-defapp`)

One `jetpacs-defapp` call gives your views an identity in the launcher:

```elisp
(jetpacs-defapp "marks" :label "Marks" :icon "bookmark"
             :views '("bookmarks"))
```

While only one app is registered nothing changes — the phone boots
straight into it, exactly as today. From the second app on, a **home
grid** appears (an "Apps" drawer entry navigates to it, offline-capable
via the multi-view switch), each card opens its app, and the bottom bar
shows one app's tabs at a time. Views no app claims — the core Files /
Eval / Tools tabs — show in every app; claim them in an explicit app of
their own (say `"system"`) to contain them. The first `:tab` view in
`:views` is the app's landing tab.

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

Expose defcustoms to the phone with
`(jetpacs-settings-register-section TITLE ENTRIES)`. The registry is a
security boundary: only listed symbols can be set from the wire, values
are validated against the `custom-type` schema, and persistence goes
through Customize. Register cache-invalidation on
`jetpacs-settings-after-set-hook`.

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
5. **Prompts are free.** Inside an action handler, plain `y-or-n-p`,
   `read-string`, and `completing-read` are automatically bridged to
   native dialogs on the phone. Write handlers as if the user were at the
   keyboard.

### 7. Owning your registrations (optional, for coexistence)

If your Tier 1 might share a session with another, wrap its registrations
so its names are attributed to it:

```elisp
(with-jetpacs-owner "marks"
  (jetpacs-defaction "marks.jump" #'my/jump)
  (jetpacs-shell-define-view "marks" :builder #'my/marks-body :tab '(:icon "bookmark")))
```

Two payoffs. First, if another app registers the same action, view, or
settings name, you get a warning (or an error under
`jetpacs-strict-namespaces`) instead of a silent clobber — actions are the
wire's security boundary, so a collision is worth surfacing. Same-owner
re-registration stays silent, so `eval-buffer` during live development is
never noisy. Second, `(jetpacs-app-unregister "marks")` then tears down
everything owned by the app — its actions, views, settings sections, and
UI-state — in one call, for clean live reload or a genuine uninstall.
`jetpacs-defapp` already attributes its `:views` to the app id.

## Shipping it

A Tier 1 is an ordinary Emacs package that requires the core features it
uses. Users load `jetpacs-core.el` (or the individual `emacs/core/` files)
plus your package. If you want a single-file artifact, mimic
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
