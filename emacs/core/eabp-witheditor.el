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

(defcustom eabp-witheditor-action-window 30
  "Seconds after a phone action within which a with-editor buffer bridges.
The git editor callback lands asynchronously AFTER the action handler that
started the commit has returned, so the bridge can't test
`eabp--in-action-handler' — instead it treats an editor buffer appearing
this soon after a dispatched action as phone-initiated.  Outside the
window (a commit made at the desktop while the phone happens to be
connected) nothing is pushed to the phone."
  :type 'integer :group 'eabp)

(defvar-local eabp-witheditor--bridged nil
  "Non-nil once this buffer's with-editor session has been bridged.
Guards against the enable/disable double-fire of `with-editor-mode-hook'
and the overlap with `git-commit-setup-hook' (both fire for a commit).")

(defvar eabp-witheditor--active nil
  "Buffer name of the with-editor session currently shown as a dialog, or nil.
Lets the post-finish/cancel hooks dismiss the phone dialog when the
session ends from the desktop side (or any path that isn't our actions).")

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
           (content (eabp-witheditor--current-message))
           ;; Rebase todos and other non-commit editor buffers get their
           ;; buffer name; only a real commit gets the friendly title.
           (title (if (bound-and-true-p git-commit-mode)
                      "Commit message"
                    name)))
      ;; Seed UI state so the Commit button reads the initial text even if
      ;; the user finishes without editing (publish-state only emits on
      ;; change — same pattern as the eval REPL / capture form).
      (eabp-ui-state-put eid content)
      (setq eabp-witheditor--active name)
      (eabp-send-dialog
       (eabp-column
        (eabp-text title 'title)
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

(defvar eabp--last-action-time)     ; eabp-surfaces.el
(defvar eabp--in-action-handler)    ; eabp-minibuffer.el

(defun eabp-witheditor--phone-initiated-p ()
  "Non-nil when the current editor buffer plausibly stems from a phone action.
True inside an action handler, or within `eabp-witheditor-action-window'
seconds of one (the git callback lands after the handler returned)."
  (or eabp--in-action-handler
      (< (- (float-time) eabp--last-action-time)
         eabp-witheditor-action-window)))

(defun eabp-witheditor--maybe-bridge ()
  "Bridge the current with-editor buffer to the phone, once, when connected.
Runs from `git-commit-setup-hook' / `with-editor-mode-hook'.  Bridges only
flows the phone plausibly started (see `eabp-witheditor--phone-initiated-p')
— a commit made at the desktop while the phone is connected must NOT pop
an uninvited dialog on it."
  (when (and (bound-and-true-p with-editor-mode)
             (eabp-connected-p)
             (eabp-witheditor--phone-initiated-p)
             (not eabp-witheditor--bridged))
    (setq eabp-witheditor--bridged t)
    (eabp-witheditor--present (current-buffer))))

(defun eabp-witheditor--session-ended ()
  "Dismiss the phone dialog when a bridged session ends outside our actions.
On `with-editor-post-finish/cancel-hook': the user may have finished the
commit at the desktop (C-c C-c there) while the phone dialog was up."
  (when eabp-witheditor--active
    (setq eabp-witheditor--active nil)
    (when (eabp-connected-p)
      (eabp-dismiss-dialog))))

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
          ;; Clear BEFORE finishing: the post-finish hook must not
          ;; double-dismiss (it would race a dialog a later flow opened).
          (setq eabp-witheditor--active nil)
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
          (setq eabp-witheditor--active nil)
          (when (fboundp 'with-editor-cancel)
            (with-editor-cancel nil)))
        (eabp-dismiss-dialog)
        (eabp-shell-push)))))

;; ─── Hooks (installed only once with-editor/git-commit are present) ───────────

(with-eval-after-load 'with-editor
  (add-hook 'with-editor-mode-hook #'eabp-witheditor--maybe-bridge)
  ;; Dismiss our dialog when the session ends from the desktop side.
  (add-hook 'with-editor-post-finish-hook #'eabp-witheditor--session-ended)
  (add-hook 'with-editor-post-cancel-hook #'eabp-witheditor--session-ended))

(with-eval-after-load 'git-commit
  (add-hook 'git-commit-setup-hook #'eabp-witheditor--maybe-bridge))

(provide 'eabp-witheditor)
;;; eabp-witheditor.el ends here
