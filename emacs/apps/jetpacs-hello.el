;;; jetpacs-hello.el --- The smallest possible Tier 1, for live demos -*- lexical-binding: t; -*-

;; A complete Tier 1 app in ~60 lines, written to be LOADED INTO A RUNNING
;; SESSION: start the companion with only the core
;; (`(require 'jetpacs-core)`), connect, then — from the phone's own Eval tab
;; or any Emacs REPL —
;;
;;   (load "/path/to/jetpacs-hello.el")
;;
;; and switch back to the app: a "Hello" tab has appeared in the bottom
;; bar.  No restart, no re-push call — registering a view on a live
;; session schedules the refresh itself.  Re-evaluate any part of the
;; file after editing and the phone follows.
;;
;; It is deliberately not part of any bundle; it exists to be read,
;; loaded, and mutated in front of an audience.

;;; Code:

(require 'jetpacs-shell)
(require 'jetpacs-apps)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)

(defvar jetpacs-hello--count 0
  "How many times the button has been tapped, phone or desktop alike.")

(defun jetpacs-hello--body ()
  "The Hello view: live Emacs state + one round-tripping button."
  (jetpacs-column
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text "Hello from a live Tier 1" 'title)
           (jetpacs-text (format "This spec was built inside %s"
                              (emacs-version))
                      'caption))))
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text (format "Taps so far: %d" jetpacs-hello--count) 'headline)
           (jetpacs-button "Tap me"
                        (jetpacs-action "hello.tap")))))
   (jetpacs-text "Edit jetpacs-hello.el, re-evaluate, watch this view change."
              'caption)))

;; Registrations run under the app's owner id: that scopes chrome and
;; settings to this app when others coexist, catches name collisions,
;; and makes (jetpacs-app-unregister "hello") a clean teardown.  The view
;; name lives in the app's namespace — "hello" here; a bigger app names
;; its views "appid.view" (see jetpacs-apps.el, the Tier-1 entry point).
(with-jetpacs-owner "hello"

  (jetpacs-defaction "hello.tap"
    ;; The allowlist rule in one line: the wire says "hello.tap", this
    ;; handler decides what that means — the wire never names code.
    (lambda (_args _payload)
      (setq jetpacs-hello--count (1+ jetpacs-hello--count))
      (jetpacs-shell-notify (format "Tap %d!" jetpacs-hello--count))
      (jetpacs-shell-push)))

  (jetpacs-shell-define-view "hello"
    :builder (lambda (snackbar)
               (jetpacs-shell-tab-view "hello" (jetpacs-hello--body)
                                    :snackbar snackbar))
    :tab '(:icon "waving_hand" :label "Hello")
    :order 5)  ; leftmost — before any other app's tabs

  ;; Loaded next to Glasspane this makes it app number two: the launcher
  ;; home appears with two cards, and each app keeps its own tab bar.
  (jetpacs-defapp "hello" :label "Hello" :icon "waving_hand"
               :views '("hello") :order 20))

(provide 'jetpacs-hello)
;;; jetpacs-hello.el ends here
