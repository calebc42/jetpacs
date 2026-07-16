;;; jetpacs-commands.el --- Command visibility on device surfaces -*- lexical-binding: t; -*-

;; The shared vocabulary for which Emacs commands the device should
;; OFFER.  Plenty of commands are perfectly runnable but nonsensical
;; from a phone — they need mouse/wheel events the bridge never sends,
;; or they suspend the host session — and every candidate-producing
;; surface (the M-x picker today; the command palette and pie menu keep
;; their own curated lists for now) needs the same answer to "should
;; this command be suggested here?".  This module is that answer, in
;; three layers:
;;
;;   1. `jetpacs-suppressed-commands' — a defcustom of symbols and
;;      regexps, the user's block list.  Surfaces in the settings
;;      browser like any other jetpacs option.
;;   2. The `jetpacs-unsupported' symbol property — the definition-site
;;      channel, so an app or skin can mark its own commands as
;;      not-for-mobile without editing the user's list:
;;        (put 'my-desktop-only-cmd 'jetpacs-unsupported t)
;;   3. `jetpacs-command-visible-p' — the predicate combining both over
;;      a `commandp' baseline; consumers pass it wherever a command
;;      predicate goes (the M-x action hands it to `completing-read').
;;
;; Altitude note: this is UX-level filtering of SUGGESTIONS, not a
;; security boundary — the dispatch boundary remains the SPEC §5 action
;; allowlist.  And because the device M-x completes with require-match,
;; a suppressed command is not just unsuggested but unrunnable from
;; that picker; the Eval tab remains the sanctioned escape hatch.
;; Nothing here touches the wire: candidates are filtered before they
;; are ever shipped.

;;; Code:

(require 'jetpacs)
(require 'seq)

(defcustom jetpacs-suppressed-commands
  '(suspend-frame
    suspend-emacs
    mwheel-scroll
    "\\`mouse-"
    "\\`scroll-bar-"
    "\\`tmm-")
  "Commands hidden from the device's M-x picker.
Each entry is either a symbol (matched with `eq') or a string (a
regexp matched against the command name with `string-match-p' —
anchor with \\\\` when you mean a prefix).  The defaults are commands
that cannot work over the bridge: they require mouse or wheel events
the device never sends, or suspend the host Emacs out from under the
session.

Suppression is silent and, because the M-x picker completes with
require-match, total for that surface: a suppressed command cannot be
run from it even when typed in full.  The Eval tab still can.  To
suppress a command from its definition site instead (an app shipping
desktop-only commands), set the `jetpacs-unsupported' symbol property
rather than editing this list."
  :type '(repeat (choice (symbol :tag "Command")
                         (regexp :tag "Name regexp")))
  :group 'jetpacs)

(defun jetpacs-command-visible-p (symbol)
  "Non-nil when SYMBOL should be offered as a command on the device.
True when SYMBOL is a command (`commandp'), does not carry a non-nil
`jetpacs-unsupported' symbol property, and matches no entry of
`jetpacs-suppressed-commands'.  Designed as a `completing-read'
PREDICATE over `obarray' (the device M-x), and as the visibility
test for any other surface that suggests commands."
  (and (commandp symbol)
       (not (get symbol 'jetpacs-unsupported))
       (let ((name (symbol-name symbol)))
         (not (seq-some (lambda (entry)
                          (if (stringp entry)
                              (string-match-p entry name)
                            (eq entry symbol)))
                        jetpacs-suppressed-commands)))))

(provide 'jetpacs-commands)
;;; jetpacs-commands.el ends here
