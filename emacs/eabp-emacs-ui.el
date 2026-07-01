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
  "List of (input . output) pairs from the eval REPL.")

(defvar eabp-emacs-ui--messages-line-count 50
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

(defun eabp-emacs-ui--messages-body ()
  "Build UI showing the tail of *Messages*."
  (let* ((msgs-buf (get-buffer "*Messages*"))
         (content (if msgs-buf
                      (with-current-buffer msgs-buf
                        (let* ((lines (split-string
                                       (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n" t))
                               (tail (last lines eabp-emacs-ui--messages-line-count)))
                          (mapconcat #'identity tail "\n")))
                    "No *Messages* buffer.")))
    (eabp-lazy-column
     (eabp-card
      (list (eabp-text content 'body nil nil t))))))

;; ─── Eval REPL ───────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--eval-body ()
  "Build UI for the elisp eval REPL."
  (let* ((history-cards
          (mapcar (lambda (entry)
                    (let ((input (car entry))
                          (output (cdr entry)))
                      (eabp-card
                       (list (eabp-column
                              (eabp-text (concat "λ> " input) 'label)
                              (eabp-text output 'body nil nil t))))))
                  (reverse eabp-emacs-ui--eval-history)))
         (input-field (eabp-text-input "eval-input"
                                       :label "Elisp Expression"
                                       :hint "(message \"hello\")"
                                       :multi-line t
                                       :min-lines 6
                                       :max-lines 12
                                       :monospace t
                                       :syntax "elisp"
                                       :on-submit (eabp-action "emacs.eval.submit"))))
    (eabp-column
     (if history-cards
         (apply #'eabp-lazy-column history-cards)
       (eabp-card
        (list (eabp-text "Type an expression below and tap Eval" 'caption))))
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

;; Eval REPL
(eabp-defaction "emacs.eval.submit"
  (lambda (args _)
    ;; The Eval button carries no value, so fall back to the field's latest
    ;; value recorded by `state.changed' (same pattern as the capture form).
    (let* ((expr (or (alist-get 'value args)
                     (eabp-ui-state "eval-input")
                     ""))
           (result (condition-case err
                       (let ((val (eval (read expr) t)))
                         (format "%S" val))
                     (error (format "ERROR: %s" (error-message-string err))))))
      (unless (string-empty-p (string-trim expr))
        (push (cons expr result) eabp-emacs-ui--eval-history))
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
            (push (cons (concat "M-x " cmd-name)
                        (format "'%s' is not a command." cmd-name))
                  eabp-emacs-ui--eval-history))
           (t
            (condition-case err
                (progn
                  (call-interactively cmd)
                  (push (cons (concat "M-x " cmd-name) "Command executed.")
                        eabp-emacs-ui--eval-history))
              (error
               (push (cons (concat "M-x " cmd-name)
                           (format "ERROR: %s" (error-message-string err)))
                     eabp-emacs-ui--eval-history))))))
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
