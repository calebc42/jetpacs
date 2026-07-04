;;; eabp-witheditor.el --- Bridge with-editor buffers to the phone -*- lexical-binding: t; -*-

;; When magit (or any with-editor client) runs a command that needs an
;; editor — a commit message, an interactive rebase todo — git launches
;; Emacs as its editor and a with-editor buffer appears, expecting the user
;; to edit it and press `C-c C-c' (finish) or `C-c C-k' (cancel).  Over the
;; bridge there is no keyboard, so that buffer would just sit there and the
;; whole operation hangs (this is the second half of the magit-commit hang;
;; the first is `map-y-or-n-p' in eabp-minibuffer.el).
;;
;; This module detects the buffer and pushes a dialog with a message editor
;; plus Commit/Cancel buttons, wired to `with-editor-finish' /
;; `with-editor-cancel'.  Two allowlisted actions (`witheditor.finish',
;; `witheditor.cancel') carry the buffer name and are validated against a
;; live with-editor buffer — never arbitrary dispatch (SPEC.md §5).
;;
;; Core never hard-depends on with-editor/magit: the hooks are installed via
;; `with-eval-after-load', so this file loads fine without them installed.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)

(defvar-local eabp-witheditor--bridged nil
  "Non-nil once this buffer's with-editor session has been bridged.
Guards against the enable/disable double-fire of `with-editor-mode-hook'
and the overlap with `git-commit-setup-hook' (both fire for a commit).")

;; ─── Message region ──────────────────────────────────────────────────────────

(defun eabp-witheditor--message-region ()
  "Return (BEG . END) of the editable message in the current buffer.
Git's template appends a `# Please enter the commit message...' comment
block (and, with `commit.verbose', a `>8' scissors line) after the
message; those comment lines are excluded so editing can't clobber them."
  (save-excursion
    (goto-char (point-min))
    (cons (point-min)
          (if (re-search-forward "^#" nil t)
              (line-beginning-position)
            (point-max)))))

(defun eabp-witheditor--current-message ()
  "The current message text (before the comment tail), trailing blank trimmed."
  (let ((r (eabp-witheditor--message-region)))
    (string-trim-right
     (buffer-substring-no-properties (car r) (cdr r)))))

;; ─── Presentation ────────────────────────────────────────────────────────────

(defun eabp-witheditor--state-id (name)
  "UI-state / editor id for the with-editor buffer named NAME."
  (concat "witheditor:" name))

(defun eabp-witheditor--present (buf)
  "Push a dialog to edit and finish/cancel with-editor buffer BUF."
  (with-current-buffer buf
    (let* ((name (buffer-name buf))
           (eid (eabp-witheditor--state-id name))
           (content (eabp-witheditor--current-message)))
      ;; Seed UI state so the Commit button reads the initial text even if
      ;; the user finishes without editing (publish-state only emits on
      ;; change — same pattern as the eval REPL / capture form).
      (eabp-ui-state-put eid content)
      (eabp-send-dialog
       (eabp-column
        (eabp-text "Commit message" 'title)
        (eabp-editor eid content
                     :chromeless t
                     :publish-state t)
        (eabp-row
         (eabp-button "Cancel"
                      (eabp-action "witheditor.cancel" :args `((buffer . ,name)))
                      :variant "text")
         (eabp-spacer :weight 1)
         (eabp-button "Commit"
                      (eabp-action "witheditor.finish"
                                   :args `((buffer . ,name))))))))))

(defun eabp-witheditor--maybe-bridge ()
  "Bridge the current with-editor buffer to the phone, once, when connected.
Runs from `git-commit-setup-hook' / `with-editor-mode-hook'; a no-op at
the keyboard (nothing connected) so desktop magit is unaffected."
  (when (and (bound-and-true-p with-editor-mode)
             (eabp-connected-p)
             (not eabp-witheditor--bridged))
    (setq eabp-witheditor--bridged t)
    (eabp-witheditor--present (current-buffer))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun eabp-witheditor--find-buffer (name)
  "Return the live with-editor buffer named NAME, or nil.
The handlers refuse any buffer that is not a live with-editor session —
this is the validation the command-dispatch boundary requires."
  (let ((buf (and (stringp name) (get-buffer name))))
    (and buf
         (buffer-live-p buf)
         (with-current-buffer buf (bound-and-true-p with-editor-mode))
         buf)))

(eabp-defaction "witheditor.finish"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (eabp-witheditor--find-buffer name))
           (value (or (alist-get 'value args)
                      (and buf (eabp-ui-state (eabp-witheditor--state-id name))))))
      (when buf
        (with-current-buffer buf
          ;; Replace only the message region, leaving git's comment/scissors
          ;; tail intact (git strips it on commit).
          (let ((r (eabp-witheditor--message-region)))
            (delete-region (car r) (cdr r))
            (goto-char (point-min))
            (insert (if (stringp value) value "") "\n"))
          (eabp-ui-state-clear (eabp-witheditor--state-id name))
          (when (fboundp 'with-editor-finish)
            (with-editor-finish nil)))
        (eabp-dismiss-dialog)
        (eabp-shell-push)))))

(eabp-defaction "witheditor.cancel"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (eabp-witheditor--find-buffer name)))
      (when buf
        (with-current-buffer buf
          (eabp-ui-state-clear (eabp-witheditor--state-id name))
          (when (fboundp 'with-editor-cancel)
            (with-editor-cancel nil)))
        (eabp-dismiss-dialog)
        (eabp-shell-push)))))

;; ─── Hooks (installed only once with-editor/git-commit are present) ───────────

(with-eval-after-load 'with-editor
  (add-hook 'with-editor-mode-hook #'eabp-witheditor--maybe-bridge))

(with-eval-after-load 'git-commit
  (add-hook 'git-commit-setup-hook #'eabp-witheditor--maybe-bridge))

(provide 'eabp-witheditor)
;;; eabp-witheditor.el ends here
