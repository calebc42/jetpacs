;;; eabp-hello.el --- The smallest possible Tier 1, for live demos -*- lexical-binding: t; -*-

;; A complete Tier 1 app in ~60 lines, written to be LOADED INTO A RUNNING
;; SESSION: start the companion with only the core
;; (`(require 'eabp-core)`), connect, then — from the phone's own Eval tab
;; or any Emacs REPL —
;;
;;   (load "/path/to/eabp-hello.el")
;;
;; and switch back to the app: a "Hello" tab has appeared in the bottom
;; bar.  No restart, no re-push call — registering a view on a live
;; session schedules the refresh itself.  Re-evaluate any part of the
;; file after editing and the phone follows.
;;
;; It is deliberately not part of any bundle; it exists to be read,
;; loaded, and mutated in front of an audience.

;;; Code:

(require 'eabp-shell)
(require 'eabp-widgets)
(require 'eabp-surfaces)

(defvar eabp-hello--count 0
  "How many times the button has been tapped, phone or desktop alike.")

(defun eabp-hello--body ()
  "The Hello view: live Emacs state + one round-tripping button."
  (eabp-column
   (eabp-card
    (list (eabp-column
           (eabp-text "Hello from a live Tier 1" 'title)
           (eabp-text (format "This spec was built inside %s"
                              (emacs-version))
                      'caption))))
   (eabp-card
    (list (eabp-column
           (eabp-text (format "Taps so far: %d" eabp-hello--count) 'headline)
           (eabp-button "Tap me"
                        (eabp-action "hello.tap")))))
   (eabp-text "Edit eabp-hello.el, re-evaluate, watch this view change."
              'caption)))

(eabp-defaction "hello.tap"
  ;; The allowlist rule in one line: the wire says "hello.tap", this
  ;; handler decides what that means — the wire never names code.
  (lambda (_args _payload)
    (setq eabp-hello--count (1+ eabp-hello--count))
    (eabp-shell-notify (format "Tap %d!" eabp-hello--count))
    (eabp-shell-push)))

(eabp-shell-define-view "hello"
  :builder (lambda (snackbar)
             (eabp-shell-tab-view "hello" (eabp-hello--body)
                                  :snackbar snackbar))
  :tab '(:icon "waving_hand" :label "Hello")
  :order 5)  ; leftmost — before any other app's tabs

(provide 'eabp-hello)
;;; eabp-hello.el ends here
