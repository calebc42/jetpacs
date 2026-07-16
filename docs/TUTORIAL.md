# Hello world, step by step — your first Tier 1

[BUILDING-TIER1.md](BUILDING-TIER1.md) is the *map* of every extension
surface; this document is the *walk*. Starting from a connected,
core-only session, you will build a small but complete app — a tab, a
button that round-trips, a text input, a list of cards, and an app
identity — understanding every line as you write it. About thirty
minutes, zero Kotlin, and the whole thing happens live against your
phone.

The companion documents, for when you outgrow this one:

- [BUILDING-TIER1.md](BUILDING-TIER1.md) — every extension surface
  (buffer skins, tablist skins, editor toolbars, settings, launcher
  icons), read next.
- [WIDGETS.md](WIDGETS.md) — the reference for every node constructor
  used below.
- [SPEC.md](https://github.com/calebc42/eabp/blob/main/SPEC.md) — the
  wire protocol (normative, in the eabp repo — the `eabp/` submodule),
  §5 especially.
- [API-STABILITY.md](API-STABILITY.md) — exactly what a Tier 1 may
  depend on.

## 0. What you need

1. The companion APK installed and paired, per the
   [README](../README.md#getting-started).
2. Emacs with the foundation loaded — `jetpacs-core.el` on the bundle
   path, or the `emacs/core/` sources. **No app**: the phone should
   show only the core tabs (Files / Eval / Tools).
3. A live connection — `M-x jetpacs-ping` to check.

Open a new file, `guestbook.el`, with lexical binding (the builders
below are closures):

```elisp
;;; guestbook.el --- tutorial Tier 1 -*- lexical-binding: t; -*-

(require 'jetpacs-shell)     ; views, tabs, push, snackbar
(require 'jetpacs-apps)      ; app identity + teardown
(require 'jetpacs-widgets)   ; the node constructors
(require 'jetpacs-surfaces)  ; jetpacs-defaction, with-jetpacs-owner
```

These `require`s are already satisfied whether you loaded the bundle
or the individual sources — they just document what the file uses.

## 1. A tab appears

Add this and `M-x eval-buffer`:

```elisp
(jetpacs-shell-define-view "guestbook"
  :builder (lambda (snackbar)
             (jetpacs-shell-tab-view "guestbook"
                                     (jetpacs-text "Hello, phone!" 'title)
                                     :snackbar snackbar))
  :tab '(:icon "menu_book" :label "Guests"))
```

A **Guests** tab appears in the phone's bottom bar, next to Files /
Eval / Tools — no restart, no explicit push. Registering a view on a
live session schedules the refresh itself; that reactivity *is* the
development loop. Change `"Hello, phone!"`, evaluate again, and the
phone follows.

The pieces:

- `jetpacs-shell-define-view` puts a named view in the shell's
  registry. The registry replaces by name, which is why re-evaluating
  updates in place.
- `:builder` is a function from the pending snackbar text (or nil) to
  a complete view. It runs on **every** push — a view is a plain
  function of Emacs state, rebuilt fresh each time. No diffing, no
  retained widgets on your side.
- `jetpacs-shell-tab-view` wraps your body in the standard tab chrome:
  top bar, drawer, bottom bar, pull-to-refresh. (Its sibling
  `jetpacs-shell-nav-view` gives back-arrow chrome for drill-in
  screens.)
- `:tab` puts the view in the bottom bar; an optional `:order` sorts
  it among the other tabs.

## 2. What just went over the wire

Every constructor in `jetpacs-widgets.el` builds a plain alist.
Evaluate in `*scratch*`:

```elisp
(jetpacs-text "Hello, phone!" 'title)
;; ⇒ ((t . "text") (text . "Hello, phone!") (style . "title"))
```

`t` is the node type; nil options are simply omitted. `json-serialize`
turns it into `{"t":"text","text":"Hello, phone!","style":"title"}`,
and the companion — a generic renderer with no application logic —
walks the tree and draws Compose widgets. A node type it doesn't
recognise renders its children (or nothing, for a leaf); never a
crash.

Nodes compose into trees. Give the body its own function and make it
a card:

```elisp
(defun guestbook--body ()
  (jetpacs-column
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text "The guestbook" 'title)
           (jetpacs-text (format "Rendered by %s" (emacs-version))
                         'caption))))))

(jetpacs-shell-define-view "guestbook"
  :builder (lambda (snackbar)
             (jetpacs-shell-tab-view "guestbook" (guestbook--body)
                                     :snackbar snackbar))
  :tab '(:icon "menu_book" :label "Guests"))
```

Evaluate; the phone now shows a card, with your running Emacs version
in the caption — live proof the spec is built *inside Emacs*, not
parsed from a file. The full constructor vocabulary — layout, inputs,
charts, tables — is catalogued in [WIDGETS.md](WIDGETS.md).

## 3. A button, an action, a round trip

Interaction crosses the wire under one rule ([SPEC
§5](https://github.com/calebc42/eabp/blob/main/SPEC.md#5-events-the-semantic-action-boundary)): **a tap never
names code**. The spec embeds an action *name*; Emacs holds an
allowlist mapping names to handlers. The wire can only ask for things
you explicitly offered.

```elisp
(defvar guestbook--count 0)

(defun guestbook--body ()
  (jetpacs-column
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text "The guestbook" 'title)
           (jetpacs-text (format "Rendered by %s" (emacs-version))
                         'caption))))
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text (format "Guests so far: %d" guestbook--count)
                         'headline)
           (jetpacs-button "Check in"
                           (jetpacs-action "guestbook.checkin")))))))

(jetpacs-defaction "guestbook.checkin"
  (lambda (_args _payload)
    (setq guestbook--count (1+ guestbook--count))
    (jetpacs-shell-notify "Checked in!")
    (jetpacs-shell-push)))
```

Evaluate, tap **Check in** on the phone: the count climbs and a
snackbar confirms it. The cycle:

1. The tap sends `event.action` with `{action: "guestbook.checkin"}`.
2. `jetpacs-defaction`'s handler runs in Emacs and mutates real state.
3. `jetpacs-shell-notify` stages a snackbar for the next push.
4. `jetpacs-shell-push` re-runs every registered view builder and
   ships the result.

A handler that signals an error is caught and echoed in `*Messages*` —
it never takes the bridge down. Two habits to start now: namespace
your action names (`guestbook.checkin`, never `checkin`), and validate
`args` in the handler rather than trusting the wire.

Taps also work when Emacs is away: the companion queues them and
replays on reconnect. The default policy (`:when-offline "queue"`) is
right for mutations; pass `"drop"` for navigation and refreshes, and
give repeated mutations a `:dedupe` key ([SPEC
§6](https://github.com/calebc42/eabp/blob/main/SPEC.md#6-offline-queue)).

## 4. Own your names

Every session assumes it may host more than one app, so an app wraps
**all** of its registrations in `with-jetpacs-owner`:

```elisp
(with-jetpacs-owner "guestbook"

  (jetpacs-defaction "guestbook.checkin"
    (lambda (_args _payload)
      (setq guestbook--count (1+ guestbook--count))
      (jetpacs-shell-notify "Checked in!")
      (jetpacs-shell-push)))

  (jetpacs-shell-define-view "guestbook"
    :builder (lambda (snackbar)
               (jetpacs-shell-tab-view "guestbook" (guestbook--body)
                                       :snackbar snackbar))
    :tab '(:icon "menu_book" :label "Guests")))
```

Three payoffs. If another app claims one of your names you get a
warning (an error under `jetpacs-strict-namespaces`) instead of a
silent clobber. Owned chrome — drawer items, top actions, settings
sections — shows only while your app is current, so apps never bleed
into each other. And one call tears everything down:

```elisp
(jetpacs-app-unregister "guestbook")
```

Evaluate that: the tab vanishes from the phone. `eval-buffer` brings
it back. Same-owner re-registration is deliberately silent, so the
edit–evaluate loop stays quiet. From here on, everything the app
registers lives inside the owner block — unowned registrations are for
the core's own chrome, not for apps.

## 5. Become an app

One more form, inside the owner block, gives the views an identity:

```elisp
  (jetpacs-defapp "guestbook" :label "Guestbook" :icon "menu_book"
                  :views '("guestbook"))
```

With a single app registered nothing visible changes — the phone boots
straight into it. From the second app on, a home grid appears, each
app keeps its own tab bar, and ownership starts scoping chrome — which
is why you wrapped everything in step 4 *before* it mattered. Two
naming rules travel with this: a single-view app may name its view
bare (`"guestbook"`), a bigger one namespaces every view
(`"guestbook.stats"`), because the view registry is global and
replaces by name.

**Checkpoint.** What you have written so far is, shape for shape,
[`emacs/apps/jetpacs-hello.el`](../emacs/apps/jetpacs-hello.el) — the
repo's minimal example (~60 commented lines). Skim it now; it should
read as review. The rest of the tutorial goes past it.

## 6. Input: sign the book

Replace the counter with a real feature — a text input and a list of
cards. Replace `guestbook--body` and the actions:

```elisp
(defvar guestbook--guests nil
  "Signed names, most recent first.")

(defun guestbook--guest-card (name)
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-text name 'body 1)  ; weight 1 — take the free width
          (jetpacs-icon-button
           "delete"
           (jetpacs-action "guestbook.remove" :args `((name . ,name))))))))

(defun guestbook--body ()
  (apply #'jetpacs-lazy-column
         (jetpacs-card
          (list (jetpacs-column
                 (jetpacs-text "Sign the guestbook" 'title)
                 ;; The id keys the field's client-side text. Rotating
                 ;; it — here, whenever the list grows — is how the
                 ;; server clears the field after a successful sign.
                 (jetpacs-text-input
                  (format "guestbook.name.%d" (length guestbook--guests))
                  :hint "Your name"
                  :on-submit (jetpacs-action "guestbook.sign")))))
         (mapcar #'guestbook--guest-card guestbook--guests)))

(with-jetpacs-owner "guestbook"

  (jetpacs-defaction "guestbook.sign"
    (lambda (args _payload)
      (let ((name (string-trim (or (alist-get 'value args) ""))))
        (if (string-empty-p name)
            (jetpacs-shell-notify "A name, please")
          (push name guestbook--guests)
          (jetpacs-shell-notify (format "Welcome, %s!" name)))
        (jetpacs-shell-push))))

  (jetpacs-defaction "guestbook.remove"
    (lambda (args _payload)
      (let ((name (alist-get 'name args)))
        (when (y-or-n-p (format "Remove %s? " name))
          (setq guestbook--guests (delete name guestbook--guests))
          (jetpacs-shell-notify "Removed"))
        (jetpacs-shell-push)))))
```

Evaluate, type a name on the phone, hit the keyboard's done key. The
name lands in `guestbook--guests` — ordinary Emacs state you can
inspect from the desktop — and the list grows a card. This step packs
the three idioms every real app is made of:

- **Value injection.** Value-carrying callbacks (`:on-submit`,
  `:on-change`, `:on-save`, `:on-pick`) dispatch their action with the
  widget's current value injected into `args` as `value`. Args arrive
  as an alist: `(alist-get 'value args)`.
- **Server-baked args.** Each delete button carries *its own* row's
  name, baked into the action at build time — the client adds nothing.
  Building per-row actions in a `mapcar` is the standard list pattern.
- **Prompts are free.** The `y-or-n-p` in the remove handler becomes a
  native dialog on the phone. So do `read-string` and
  `completing-read` — write handlers as if the user were at the
  keyboard.

Also note the container change: `jetpacs-lazy-column` is the scrolling
list a tab body wants. One scroll container per view — they don't
nest.

## 7. When something breaks

- A **builder** that signals renders as an error view on the phone
  (the push itself never breaks); the message is in `*Messages*`.
- A **handler** that signals is caught and echoed in `*Messages*`.
- `jetpacs-lint-spec` validates a node tree (unknown keys, malformed
  actions, toolbar vocabulary) — call it from ERT.
- `jetpacs-render-to-json` round-trips a tree through the real
  serializer and back, returning exactly what the companion would
  parse — assert on your views in batch, no phone required.

## 8. The finished file

```elisp
;;; guestbook.el --- a tiny Tier 1, from docs/TUTORIAL.md -*- lexical-binding: t; -*-

(require 'jetpacs-shell)
(require 'jetpacs-apps)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)

(defvar guestbook--guests nil
  "Signed names, most recent first.")

(defun guestbook--guest-card (name)
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-text name 'body 1)
          (jetpacs-icon-button
           "delete"
           (jetpacs-action "guestbook.remove" :args `((name . ,name))))))))

(defun guestbook--body ()
  (apply #'jetpacs-lazy-column
         (jetpacs-card
          (list (jetpacs-column
                 (jetpacs-text "Sign the guestbook" 'title)
                 (jetpacs-text (format "%d signatures so far"
                                       (length guestbook--guests))
                               'caption)
                 (jetpacs-text-input
                  (format "guestbook.name.%d" (length guestbook--guests))
                  :hint "Your name"
                  :on-submit (jetpacs-action "guestbook.sign")))))
         (mapcar #'guestbook--guest-card guestbook--guests)))

(with-jetpacs-owner "guestbook"

  (jetpacs-defaction "guestbook.sign"
    (lambda (args _payload)
      (let ((name (string-trim (or (alist-get 'value args) ""))))
        (if (string-empty-p name)
            (jetpacs-shell-notify "A name, please")
          (push name guestbook--guests)
          (jetpacs-shell-notify (format "Welcome, %s!" name)))
        (jetpacs-shell-push))))

  (jetpacs-defaction "guestbook.remove"
    (lambda (args _payload)
      (let ((name (alist-get 'name args)))
        (when (y-or-n-p (format "Remove %s? " name))
          (setq guestbook--guests (delete name guestbook--guests))
          (jetpacs-shell-notify "Removed"))
        (jetpacs-shell-push))))

  (jetpacs-shell-define-view "guestbook"
    :builder (lambda (snackbar)
               (jetpacs-shell-tab-view "guestbook" (guestbook--body)
                                       :snackbar snackbar))
    :tab '(:icon "menu_book" :label "Guests"))

  (jetpacs-defapp "guestbook" :label "Guestbook" :icon "menu_book"
                  :views '("guestbook")))

(provide 'guestbook)
;;; guestbook.el ends here
```

## 9. Where next

You now hold the whole Tier 1 pattern: node trees built by pure
functions, an allowlist of named actions, ownership, and an app
identity. Everything else is that pattern on a bigger surface:

- **The map** — [BUILDING-TIER1.md](BUILDING-TIER1.md): buffer skins,
  tablist skins, curated pie menus, per-file-type editors and keyboard
  toolbars, settings sections, badges, a home-screen icon of your own
  (`jetpacs-device-shortcut-pin`) — plus the platform beyond the
  screen: device effectors and triggers, home-screen widgets and QS
  tiles, notification surfaces, and theme mirroring.
- **The vocabulary** — [WIDGETS.md](WIDGETS.md): every constructor,
  including tables, charts, the month grid, the full editor node, and
  home-screen widgets/tiles.
- **Shipping** — [BUILDING-TIER1.md §Shipping
  it](BUILDING-TIER1.md#shipping-it): a Tier 1 is an ordinary Emacs
  package; the [glasspane repo](https://github.com/calebc42/glasspane)
  is the worked example of a standalone app repo, built to be copied.
- **The contract** — [API-STABILITY.md](API-STABILITY.md): everything
  this tutorial used is on the stable public surface.
