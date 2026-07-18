;;; jetpacs-demo.el --- First-run welcome tab and on-device walkthrough -*- lexical-binding: t; -*-

;; The foundation's own onboarding.  Two pieces:
;;
;;   1. A "Start" tab that exists only before the walkthrough has ever
;;      been generated (and can be dismissed for good).  It teaches the
;;      single most important control on the screen — the M-x button —
;;      by making the user's first M-x invocation the thing that creates
;;      the rest of the tour.
;;
;;   2. `jetpacs-setup-demo', which writes a two-file guided tour into
;;      `jetpacs-demo-directory' and opens it in the phone editor:
;;      walkthrough.org (the tour itself, exercising Files, M-x,
;;      Buffers, editing, completion, and Eval) and hello-app.el (a
;;      complete beginner-commented Tier 1 app to load, tap, edit, and
;;      reload).
;;
;; The files ship *inside the bundle* as string constants rather than as
;; repo files because Emacs's home on Android is app-private storage —
;; adb can't push into it, but Emacs itself can write there.  Setup
;; always overwrites its own two files (and touches nothing else), so a
;; mangled tour resets to pristine by running the command again.
;;
;; The welcome tab needs no persisted "seen it" flag: it shows while
;; `jetpacs-demo-directory' does not exist and `jetpacs-demo-show-welcome'
;; is non-nil.  Generating the tour retires the tab; deleting the demo
;; folder brings it back; the skip button persists the defcustom off.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-files)
(require 'jetpacs-settings)

(defcustom jetpacs-demo-directory "~/jetpacs-demo/"
  "Directory `jetpacs-setup-demo' writes the walkthrough files into.
Must lie within `jetpacs-files-roots' to be reachable from the phone's
Files browser (the default is inside the Home root).  While this
directory does not exist, the first-run welcome tab is offered."
  :type 'directory :group 'jetpacs)

(defcustom jetpacs-demo-show-welcome t
  "When non-nil, offer the first-run Start tab until the tour exists.
The tab's skip button persists this to nil; the tour itself stays
available either way via \\[jetpacs-setup-demo]."
  :type 'boolean :group 'jetpacs)

;; ─── The walkthrough files ───────────────────────────────────────────────────

(defconst jetpacs-demo--files
  '(("walkthrough.org" . "\
#+title: Jetpacs walkthrough

Welcome!  This file is real: it lives on this device, in a
jetpacs-demo folder inside Emacs's home directory, and the
screen you are reading it on is built — and kept up to date —
by the Emacs you paired with.

You created this file yourself a moment ago by running a
command.  That is how everything works here, so let's start
there.

* 1. M-x — run anything by name

Emacs is thousands of small commands, each with a name.  The
terminal-shaped button in the top bar is M-x, the \"run a
command by name\" button.  Tap it and a search box lists every
command; type a few letters, tap a match, and it runs.

You have already used it once: jetpacs-setup-demo, which wrote
this folder.  Try another:

1. Tap the terminal button in the top bar.
2. Type: calendar
3. Tap the match.

The phone hops to the Eval tab and notes that the command ran.
Its real output is a new buffer — next step.

* 2. Buffers — everything Emacs has open

Open the menu (the button in the top-left of a tab screen) and
tap Buffers.  There is *Calendar* — a month grid drawn by a
text-mode program older than the phone in your hand, rendered
as a native screen.  This walkthrough has a buffer in that
list too.

Come back here anytime with: Files tab, the jetpacs-demo
folder, walkthrough.org.

* 3. Edit this file

This is an ordinary editor — your edits land in the real file.

- [ ] Change the box on this line from [ ] to [X]
- [ ] On the empty line below, type walk and pause; word chips
      appear above the keyboard — tap one to finish the word

- [ ] Tap Save (it enables once you have typed)

Made a mess?  M-x jetpacs-setup-demo rewrites both tour files
back to pristine.

* 4. Eval — talk to Emacs directly

Switch to the Eval tab in the bottom bar and type:

  (jetpacs-shell-notify \"Hello from Emacs!\")

Tap the send button.  The message that pops up at the bottom
of the screen was produced by Emacs calling the same machinery
every screen here uses.  Arithmetic works too: (* 6 7).

* 5. Load a whole app

The other file in this folder, hello-app.el, is a complete
Jetpacs app in about forty lines.  Open it from the Files tab
and read it — the comments explain every part.  Then, in the
Eval tab:

  (load \"~/jetpacs-demo/hello-app.el\")

An app launcher appears: open the menu, tap Apps, and there is
Hello next to Jetpacs.  Open it and tap the button.

Now the part that makes this Emacs and not an app store: open
hello-app.el in the editor, change the CHANGE ME line, save,
run the load line again, and reopen Hello.  Your edit is on
screen.  Edit, reload, look — that loop is the whole idea.

To remove the app again, eval: (jetpacs-app-unregister \"hello\")

* 6. The rest of the chrome

From the menu:
- Messages — Emacs's own log, useful when something is odd.
- Tools — a shell, processes, timers, bookmarks, kill ring.
- Settings — theme, line numbers, and every option an app
  registers; saved back into your Emacs config.

* 7. Where next

- The tour is disposable: delete the jetpacs-demo folder when
  you are done, or keep scribbling in it.  M-x
  jetpacs-setup-demo recreates it fresh anytime.
- Your own Emacs config drives everything: anything you setq,
  load, or install on the Emacs side shows up here.
- To build an app like Hello from scratch, read
  docs/TUTORIAL.md in the Jetpacs repository — it grows
  hello-app.el's pattern into a real Tier 1 app.
")
    ("hello-app.el" . "\
;;; hello-app.el --- Your first Jetpacs app: load, tap, edit, reload

;; This is a COMPLETE Jetpacs app.  Load it into the running Emacs
;; from the phone's Eval tab:
;;
;;   (load \"~/jetpacs-demo/hello-app.el\")
;;
;; An app launcher appears (menu -> Apps) with a new app, Hello.
;; No restart, no install step: registering an app on a live
;; session refreshes the phone by itself.
;;
;; Then make it yours: change the CHANGE ME line below, tap Save,
;; run the load line again, and reopen Hello.

(require 'jetpacs-core)

;; State lives in Emacs, not on the phone.  These are ordinary
;; variables; the screen below is rebuilt from them on every push.

(defvar my-hello-taps 0
  \"How many times the big button has been tapped.\")

(defvar my-hello-greeting \"Hello from your own app!\" ; <- CHANGE ME
  \"The headline the Hello screen shows.\")

(defun my-hello--body ()
  \"Build the screen: plain data describing widgets.\"
  (jetpacs-column
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text my-hello-greeting 'title)
           (jetpacs-text (format \"Built inside %s\" (emacs-version))
                      'caption))))
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text (format \"Taps so far: %d\" my-hello-taps)
                      'headline)
           (jetpacs-button \"Tap me\" (jetpacs-action \"hello.tap\")))))))

(with-jetpacs-owner \"hello\"

  ;; The button above names the action \"hello.tap\"; this handler
  ;; decides what that means.  The phone can only name actions,
  ;; never send code.
  (jetpacs-defaction \"hello.tap\"
    (lambda (_args _payload)
      (setq my-hello-taps (1+ my-hello-taps))
      (jetpacs-shell-notify (format \"Tap %d!\" my-hello-taps))
      (jetpacs-shell-push)))

  ;; A view is a named screen; :tab puts it in the bottom bar
  ;; while the Hello app is open.
  (jetpacs-shell-define-view \"hello\"
    :builder (lambda (snackbar)
               (jetpacs-shell-tab-view \"hello\" (my-hello--body)
                                    :snackbar snackbar))
    :tab '(:icon \"waving_hand\" :label \"Hello\")
    :order 5)

  ;; And the app itself: a launcher card owning that view.
  (jetpacs-defapp \"hello\" :label \"Hello\" :icon \"waving_hand\"
               :views '(\"hello\")))

;; Undo everything:  (jetpacs-app-unregister \"hello\")

;;; hello-app.el ends here
"))
  "Alist of (FILENAME . CONTENT) written by `jetpacs-setup-demo'.")

;; ─── Setup ───────────────────────────────────────────────────────────────────

;;;###autoload
(defun jetpacs-setup-demo (&optional dir)
  "Write the guided tour into DIR (default `jetpacs-demo-directory') and open it.
Overwrites exactly the files named in `jetpacs-demo--files' — anything
else in the directory is untouched — so re-running resets the tour to
pristine.  On a connected phone the walkthrough opens in the editor;
the navigation is deferred past the calling action's own push (M-x
lands on the Eval tab after every command — this must land later).
Returns the directory written to."
  (interactive)
  (let ((dir (file-name-as-directory
              (expand-file-name (or dir jetpacs-demo-directory))))
        ;; The tour text is non-ASCII (em-dashes); pin utf-8 so no
        ;; platform default can make write-region prompt.
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (dolist (spec jetpacs-demo--files)
      (write-region (cdr spec) nil (expand-file-name (car spec) dir)
                    nil 'silent))
    (when (jetpacs-connected-p)
      (run-at-time
       0.1 nil
       (lambda ()
         ;; The welcome tab just lost its reason to exist; make "files"
         ;; the logical tab before the retired name can go stale, then
         ;; land the user in the walkthrough itself.
         (jetpacs-shell-push "files")
         (jetpacs-shell-notify
          (format "The tour lives in %s — this file is yours to edit"
                  (abbreviate-file-name (directory-file-name dir))))
         (jetpacs-files-open (expand-file-name (caar jetpacs-demo--files)
                                               dir)))))
    (when (called-interactively-p 'interactive)
      (message "Jetpacs walkthrough written to %s" dir))
    dir))

;; The verb-order twin, for muscle memory from the Glasspane app's
;; `glasspane-demo-setup' (and either spelling is findable from M-x).
(defalias 'jetpacs-demo-setup #'jetpacs-setup-demo)

;; ─── The welcome tab ─────────────────────────────────────────────────────────

(defun jetpacs-demo--welcome-p ()
  "Non-nil while the welcome tab should be offered.
Stateless: the tour not existing IS the first-run condition."
  (and jetpacs-demo-show-welcome
       (not (file-directory-p (expand-file-name jetpacs-demo-directory)))))

(defun jetpacs-demo--welcome-view (snackbar)
  "The first-run Start tab: name the M-x button, prompt the tour command."
  (jetpacs-shell-tab-view
   "welcome"
   (jetpacs-lazy-column
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-text "Welcome to Jetpacs" 'title)
            (jetpacs-text
             (concat "Your phone is now a screen for Emacs.  Every screen "
                     "here is built by the Emacs you paired with, and "
                     "follows it live.")
             'body))))
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-row
             (jetpacs-icon "terminal")
             (jetpacs-text "This button is M-x" 'headline))
            (jetpacs-text
             (concat "Emacs is thousands of commands, each with a name, and "
                     "the terminal-shaped button in the top bar runs any of "
                     "them: tap it, type a few letters, tap the match.  It "
                     "is on every screen, and it is how you reach anything "
                     "not already on one.")
             'body))))
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-text "Try it now" 'headline)
            (jetpacs-text "1. Tap the terminal button in the top bar." 'body)
            (jetpacs-text "2. Type: jetpacs-setup-demo" 'body)
            (jetpacs-text "3. Tap the match." 'body)
            (jetpacs-text
             (concat "It writes a short guided tour — two files — onto this "
                     "device and opens it.  This tab retires once the tour "
                     "exists; the same command brings the tour back "
                     "anytime.")
             'caption))))
    (jetpacs-button "Skip the tour"
                 (jetpacs-action "jetpacs.demo.skip" :when-offline "drop")
                 :variant "text"))
   :snackbar snackbar))

(jetpacs-shell-define-view "welcome"
  :builder #'jetpacs-demo--welcome-view
  :tab '(:icon "flag" :label "Start")
  :when #'jetpacs-demo--welcome-p
  :order 10)  ; leftmost tab — the landing view on a fresh install

;; ─── Wire actions ────────────────────────────────────────────────────────────

(jetpacs-defaction "jetpacs.demo.setup"
  ;; Allowlisted and argument-free: always writes the fixed file set into
  ;; `jetpacs-demo-directory' — nothing on the wire chooses paths or content.
  (lambda (_ _) (jetpacs-setup-demo)))

(jetpacs-defaction "jetpacs.demo.skip"
  (lambda (_ _)
    ;; Persisted through the settings seam (surfaces the no-custom-file
    ;; case) — a skip that silently un-skipped on restart would be worse
    ;; than no button.
    (jetpacs-settings-save-variable 'jetpacs-demo-show-welcome nil)
    ;; The tab the user is standing on just disappeared; land on Files.
    (jetpacs-shell-push "files")))

(jetpacs-settings-register-section
 "Welcome tour"
 '((jetpacs-demo-show-welcome
    :label "Offer the Start tab until the tour exists")))

(provide 'jetpacs-demo)
;;; jetpacs-demo.el ends here
