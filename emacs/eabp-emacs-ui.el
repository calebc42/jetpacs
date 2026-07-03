;;; eabp-emacs-ui.el --- EABP Emacs REPL & Buffer Viewer -*- lexical-binding: t; -*-

;; Provides an in-app Emacs interaction layer:
;;   * Buffer viewer (switch buffers, see content)
;;   * *Messages* tail
;;   * M-x command runner (interactive command dialog)
;;   * Elisp eval REPL
;;
;; Integrates with the dashboard as additional bottom-bar tabs.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer)
(require 'cl-lib)

;; The generic (Tier 0) buffer renderer re-pushes the showing surface after a
;; tap mutates a buffer.  Point it at the dashboard host (resolved lazily at
;; call time, so the org-ui load order doesn't matter here).
(setq eabp-buffer-refresh-function #'eabp-org-ui-push-dashboard)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar eabp-emacs-ui--viewing-buffer nil
  "Name of the buffer currently being viewed, or nil for the buffer list.")

(defvar eabp-emacs-ui--eval-history nil
  "List of (input . output) pairs from the eval REPL, newest first.")

(defcustom eabp-emacs-ui-eval-history-max 50
  "Maximum eval-history entries kept (and shipped in the dashboard spec)."
  :type 'integer :group 'eabp)

(defcustom eabp-emacs-ui-eval-output-max 2000
  "Eval results longer than this many characters are truncated for display."
  :type 'integer :group 'eabp)

(defvar eabp-emacs-ui--messages-line-count 100
  "Number of tail lines to show from *Messages*.")

;; ─── Buffer List ─────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--buffer-list-body ()
  "Build UI for the buffer list."
  (let* ((bufs (cl-remove-if
                (lambda (b) (string-prefix-p " " (buffer-name b)))
                (buffer-list)))
         (cards (mapcar
                 (lambda (buf)
                   (let* ((name (buffer-name buf))
                          (file (buffer-file-name buf))
                          (modified (buffer-modified-p buf))
                          (subtitle (cond
                                    (file (abbreviate-file-name file))
                                    (t (format "%d lines"
                                              (with-current-buffer buf
                                                (count-lines (point-min) (point-max)))))))
                          (prefix (if modified "● " "")))
                     (eabp-card
                      (list (eabp-column
                             (eabp-text (concat prefix name) 'body)
                             (eabp-text subtitle 'caption)))
                      :on-tap (eabp-action "emacs.buffer.view"
                                           :args `((buffer . ,name))))))
                 bufs)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-text "No buffers." 'body))))

;; ─── Buffer Content Viewer ───────────────────────────────────────────────────

(defun eabp-emacs-ui--buffer-view-body (buffer-name)
  "Build UI showing the contents of BUFFER-NAME.
Rendered through the Tier 0 generic renderer (`eabp-render-buffer'), so the
buffer's faces and tappable regions survive — any major mode works without a
bespoke translator."
  (let ((buf (get-buffer buffer-name)))
    (if (not buf)
        (eabp-text (format "Buffer '%s' not found." buffer-name) 'body)
      (apply #'eabp-lazy-column (eabp-render-buffer buf)))))

;; ─── *Messages* Tail ─────────────────────────────────────────────────────────

(defun eabp-emacs-ui--messages-tail ()
  "The last `eabp-emacs-ui--messages-line-count' lines of *Messages*."
  (if-let ((msgs-buf (get-buffer "*Messages*")))
      (with-current-buffer msgs-buf
        (let* ((lines (split-string
                       (buffer-substring-no-properties (point-min) (point-max))
                       "\n" t))
               (tail (last lines eabp-emacs-ui--messages-line-count)))
          (mapconcat #'identity tail "\n")))
    "No *Messages* buffer."))

(defun eabp-emacs-ui--messages-line (line stripe)
  "One zebra row for the Messages view.
LINE is selectable (long-press to copy); STRIPE non-nil tints the row
with a theme-adaptive container color so lines read as distinct entries."
  (let ((text (eabp-text (if (string-empty-p line) " " line)
                         'mono nil nil t nil 4)))
    (if stripe
        (eabp-surface (list text)
                      :color "surface_container"
                      :shape "rounded_small"
                      :fill t)
      text)))

(defun eabp-emacs-ui--messages-body ()
  "Build the Messages view: zebra-striped, selectable lines + copy all.
Each *Messages* line is its own row (alternate rows tinted) so entries
are visually delineated; every row is long-press selectable, and Copy
all uses the companion-local clipboard builtin."
  (let* ((content (eabp-emacs-ui--messages-tail))
         (i 0)
         (rows (mapcar (lambda (line)
                         (prog1 (eabp-emacs-ui--messages-line line (cl-oddp i))
                           (setq i (1+ i))))
                       (split-string content "\n"))))
    (eabp-column
     (eabp-row
      (eabp-text (format "Last %d lines" eabp-emacs-ui--messages-line-count)
                 'caption)
      (eabp-spacer :weight 1)
      (eabp-button "Copy all" (eabp-clipboard-action content) :variant "text"))
     (eabp-box
      (list (apply #'eabp-lazy-column rows))
      :weight 1))))

;; ─── *Messages* → device toasts ──────────────────────────────────────────────

(defcustom eabp-forward-messages t
  "When non-nil, echo-area messages mirror to the companion as toasts.
Throttled to at most one per second (latest wins); EABP's own bridge
chatter is filtered out so it can never echo back to the phone."
  :type 'boolean :group 'eabp)

(defvar eabp-emacs-ui--toast-last 0
  "Time of the last toast sent, for throttling.")
(defvar eabp-emacs-ui--toast-timer nil)
(defvar eabp-emacs-ui--toast-pending nil
  "Latest message held back by the throttle, flushed by the timer.")
(defvar eabp-emacs-ui--in-toast nil
  "Reentrancy guard: non-nil while forwarding a message.")

(defun eabp-emacs-ui--toast-send (text)
  (setq eabp-emacs-ui--toast-last (float-time))
  (eabp-send "toast.show" `((text . ,text))))

(defun eabp-emacs-ui--message-advice (format-string &rest args)
  "Mirror `message' output to the companion as a toast.
Runs as :after advice on `message'; never signals, never recurses."
  (when (and eabp-forward-messages
             (not eabp-emacs-ui--in-toast)
             format-string
             (eabp-connected-p))
    (let* ((eabp-emacs-ui--in-toast t)
           (msg (ignore-errors (apply #'format-message format-string args))))
      (when (and (stringp msg)
                 (not (string-empty-p (string-trim msg)))
                 (not (string-prefix-p "EABP" msg)))
        (when (> (length msg) 200)
          (setq msg (concat (substring msg 0 200) "…")))
        (if (> (- (float-time) eabp-emacs-ui--toast-last) 1.0)
            (eabp-emacs-ui--toast-send msg)
          ;; Throttle window: hold only the LATEST message and flush once.
          (setq eabp-emacs-ui--toast-pending msg)
          (unless (timerp eabp-emacs-ui--toast-timer)
            (setq eabp-emacs-ui--toast-timer
                  (run-at-time
                   1.0 nil
                   (lambda ()
                     (setq eabp-emacs-ui--toast-timer nil)
                     (when eabp-emacs-ui--toast-pending
                       (eabp-emacs-ui--toast-send
                        (prog1 eabp-emacs-ui--toast-pending
                          (setq eabp-emacs-ui--toast-pending nil))))))))))))
  nil)

(advice-add 'message :after #'eabp-emacs-ui--message-advice)

;; ─── Eval REPL ───────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--eval-card (entry)
  "One REPL history card for ENTRY (INPUT . OUTPUT).
Input line, then the (selectable) result, with copy and re-run buttons."
  (let* ((input (car entry))
         (output (cdr entry))
         (shown (if (> (length output) eabp-emacs-ui-eval-output-max)
                    (concat (substring output 0 eabp-emacs-ui-eval-output-max)
                            " …")
                  output)))
    (eabp-card
     (list (eabp-column
            (eabp-row
             (eabp-box (list (eabp-text (concat "λ> " input) 'label))
                       :weight 1)
             (eabp-icon-button "content_copy"
                               (eabp-clipboard-action output)
                               :content-description "Copy result")
             (eabp-icon-button "play_arrow"
                               (eabp-action "emacs.eval.submit"
                                            :args `((value . ,input)))
                               :content-description "Re-run"))
            (eabp-text shown 'mono nil nil t))))))

(defun eabp-emacs-ui--eval-body ()
  "Build UI for the elisp eval REPL.
History (newest first) scrolls in a weighted region; the input field and
Eval button stay pinned below it, so they can never be pushed off-screen
by a long history — the layout bug the old plain-column version had."
  (let* ((history-cards (mapcar #'eabp-emacs-ui--eval-card
                                eabp-emacs-ui--eval-history))
         ;; A chromeless editor instead of a plain text_input: the id names
         ;; a virtual elisp file, so the full bridge lights up in the REPL —
         ;; completion chips from the live obarray, paren/byte-compile
         ;; squiggles as you type, eldoc signatures in the doc line, and
         ;; Emacs-theme fontification. publish-state keeps the Eval button's
         ;; ui-state read working exactly like the old field.
         (input-field (eabp-editor "eval.el" ""
                                   :chromeless t
                                   :publish-state t
                                   :complete t
                                   :syntax "elisp")))
    (eabp-column
     (eabp-box
      (list (if history-cards
                (apply #'eabp-lazy-column history-cards)
              (eabp-empty-state :icon "code"
                                :title "Elisp REPL"
                                :caption "Results appear here, newest first.")))
      :weight 1)
     input-field
     (eabp-row
      (eabp-spacer :weight 1)
      (eabp-button "Eval" (eabp-action "emacs.eval.submit"))))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

;; Buffer list / view
(eabp-defaction "emacs.buffer.view"
  (lambda (args _)
    (setq eabp-emacs-ui--viewing-buffer (alist-get 'buffer args))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "emacs.buffer.back"
  (lambda (_ _)
    (setq eabp-emacs-ui--viewing-buffer nil)
    (eabp-org-ui-push-dashboard)))

(defun eabp-emacs-ui--eval-record (input output)
  "Push (INPUT . OUTPUT) onto the eval history, bounded by the max."
  (push (cons input output) eabp-emacs-ui--eval-history)
  (when (> (length eabp-emacs-ui--eval-history) eabp-emacs-ui-eval-history-max)
    (setcdr (nthcdr (1- eabp-emacs-ui-eval-history-max)
                    eabp-emacs-ui--eval-history)
            nil)))

;; Eval REPL
(eabp-defaction "emacs.eval.submit"
  (lambda (args _)
    ;; The Eval button carries no value, so fall back to the field's latest
    ;; value recorded by `state.changed' (same pattern as the capture form).
    ;; "eval.el" is the editor-based field; "eval-input" the legacy one.
    (let* ((expr (or (alist-get 'value args)
                     (eabp-ui-state "eval.el")
                     (eabp-ui-state "eval-input")
                     ""))
           (result (condition-case err
                       ;; Wrap in progn so multi-sexp input evaluates fully
                       ;; (bare `read' silently ignored everything after the
                       ;; first form).
                       (let ((val (eval (car (read-from-string
                                              (format "(progn %s\n)" expr)))
                                        t)))
                         (format "%S" val))
                     (error (format "ERROR: %s" (error-message-string err))))))
      (unless (string-empty-p (string-trim expr))
        (eabp-emacs-ui--eval-record expr result))
      (eabp-org-ui-push-dashboard))))

;; M-x — runs `completing-read' over all commands, which the minibuffer
;; bridge turns into a live-filtering (vertico-style) picker dialog. The
;; chosen command is then run with `call-interactively' (its own prompts,
;; if any, are bridged too). Result lands in the Eval tab's history.
(eabp-defaction "emacs.mx.show"
  (lambda (_ _)
    (let ((cmd-name (condition-case nil
                        (completing-read "M-x " obarray #'commandp t)
                      (quit nil))))
      (when (and (stringp cmd-name) (not (string-empty-p cmd-name)))
        (let ((cmd (intern-soft cmd-name)))
          (cond
           ((not (commandp cmd))
            (eabp-emacs-ui--eval-record (concat "M-x " cmd-name)
                                        (format "'%s' is not a command." cmd-name)))
           (t
            (condition-case err
                (progn
                  (call-interactively cmd)
                  (eabp-emacs-ui--eval-record (concat "M-x " cmd-name)
                                              "Command executed."))
              (error
               (eabp-emacs-ui--eval-record
                (concat "M-x " cmd-name)
                (format "ERROR: %s" (error-message-string err))))))))
        (eabp-org-ui-push-dashboard "eval")))))

;; Messages refresh
(eabp-defaction "emacs.messages.refresh"
  (lambda (_ _)
    (eabp-org-ui-push-dashboard)))

;; Clear eval history
(eabp-defaction "emacs.eval.clear"
  (lambda (_ _)
    (setq eabp-emacs-ui--eval-history nil)
    (eabp-org-ui-push-dashboard)))

(provide 'eabp-emacs-ui)
;;; eabp-emacs-ui.el ends here
