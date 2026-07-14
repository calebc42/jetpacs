;;; jetpacs-witheditor.el --- Bridge with-editor buffers to the phone -*- lexical-binding: t; -*-

;; When magit (or any with-editor client) runs a command that needs an
;; editor — a commit message, an interactive rebase todo — git launches
;; Emacs as its editor and a with-editor buffer appears, expecting the user
;; to edit it and press `C-c C-c' (finish) or `C-c C-k' (cancel).  Over the
;; bridge there is no keyboard, so that buffer would just sit there and the
;; whole operation hangs (this is the second half of the magit-commit hang;
;; the first is `map-y-or-n-p' in jetpacs-minibuffer.el).
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

(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)

(defcustom jetpacs-witheditor-action-window 30
  "Seconds after a phone action within which a with-editor buffer bridges.
The git editor callback lands asynchronously AFTER the action handler that
started the commit has returned, so the bridge can't test
`jetpacs--in-action-handler' — instead it treats an editor buffer appearing
this soon after a dispatched action as phone-initiated.  Outside the
window (a commit made at the desktop while the phone happens to be
connected) nothing is pushed to the phone."
  :type 'integer :group 'jetpacs)

(defvar-local jetpacs-witheditor--bridged nil
  "Non-nil once this buffer's with-editor session has been bridged.
Guards against the enable/disable double-fire of `with-editor-mode-hook'
and the overlap with `git-commit-setup-hook' (both fire for a commit).")

(defvar jetpacs-witheditor--active nil
  "Buffer name of the with-editor session currently shown as a dialog, or nil.
Lets the post-finish/cancel hooks dismiss the phone dialog when the
session ends from the desktop side (or any path that isn't our actions).")

;; ─── Message region ──────────────────────────────────────────────────────────

(defun jetpacs-witheditor--message-region ()
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

(defun jetpacs-witheditor--current-message ()
  "The current message text (before the comment tail), trailing blank trimmed."
  (let ((r (jetpacs-witheditor--message-region)))
    (string-trim-right
     (buffer-substring-no-properties (car r) (cdr r)))))

;; ─── Presentation ────────────────────────────────────────────────────────────

(defun jetpacs-witheditor--state-id (name)
  "UI-state / editor id for the with-editor buffer named NAME."
  (concat "witheditor:" name))

(defun jetpacs-witheditor--present (buf)
  "Push a dialog to edit and finish/cancel with-editor buffer BUF."
  (with-current-buffer buf
    (let* ((name (buffer-name buf))
           (eid (jetpacs-witheditor--state-id name))
           (content (jetpacs-witheditor--current-message))
           ;; Rebase todos and other non-commit editor buffers get their
           ;; buffer name; only a real commit gets the friendly title.
           (title (if (bound-and-true-p git-commit-mode)
                      "Commit message"
                    name)))
      ;; Seed UI state so the Commit button reads the initial text even if
      ;; the user finishes without editing (publish-state only emits on
      ;; change — same pattern as the eval REPL / capture form).
      (jetpacs-ui-state-put eid content)
      (setq jetpacs-witheditor--active name)
      (jetpacs-send-dialog
       (jetpacs-column
        (jetpacs-text title 'title)
        (jetpacs-editor eid content
                     :chromeless t
                     :publish-state t)
        (jetpacs-row
         (jetpacs-button "Cancel"
                      (jetpacs-action "witheditor.cancel" :args `((buffer . ,name)))
                      :variant "text")
         (jetpacs-spacer :weight 1)
         (jetpacs-button "Commit"
                      (jetpacs-action "witheditor.finish"
                                   :args `((buffer . ,name))))))))))

(defvar jetpacs--last-action-time)     ; jetpacs-surfaces.el
(defvar jetpacs--in-action-handler)    ; jetpacs-minibuffer.el

(defun jetpacs-witheditor--phone-initiated-p ()
  "Non-nil when the current editor buffer plausibly stems from a phone action.
True inside an action handler, or within `jetpacs-witheditor-action-window'
seconds of one (the git callback lands after the handler returned)."
  (or jetpacs--in-action-handler
      (< (- (float-time) jetpacs--last-action-time)
         jetpacs-witheditor-action-window)))

(defun jetpacs-witheditor--maybe-bridge ()
  "Bridge the current with-editor buffer to the phone, once, when connected.
Runs from `git-commit-setup-hook' / `with-editor-mode-hook'.  Bridges only
flows the phone plausibly started (see `jetpacs-witheditor--phone-initiated-p')
— a commit made at the desktop while the phone is connected must NOT pop
an uninvited dialog on it."
  (when (and (bound-and-true-p with-editor-mode)
             (jetpacs-connected-p)
             (jetpacs-witheditor--phone-initiated-p)
             (not jetpacs-witheditor--bridged))
    (setq jetpacs-witheditor--bridged t)
    (jetpacs-witheditor--present (current-buffer))))

(defun jetpacs-witheditor--session-ended ()
  "Dismiss the phone dialog when a bridged session ends outside our actions.
On `with-editor-post-finish/cancel-hook': the user may have finished the
commit at the desktop (C-c C-c there) while the phone dialog was up."
  (when jetpacs-witheditor--active
    (setq jetpacs-witheditor--active nil)
    (when (jetpacs-connected-p)
      (jetpacs-dismiss-dialog))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun jetpacs-witheditor--find-buffer (name)
  "Return the live with-editor buffer named NAME, or nil.
The handlers refuse any buffer that is not a live with-editor session —
this is the validation the command-dispatch boundary requires."
  (let ((buf (and (stringp name) (get-buffer name))))
    (and buf
         (buffer-live-p buf)
         (with-current-buffer buf (bound-and-true-p with-editor-mode))
         buf)))

(jetpacs-defaction "witheditor.finish"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (jetpacs-witheditor--find-buffer name))
           (value (or (alist-get 'value args)
                      (and buf (jetpacs-ui-state (jetpacs-witheditor--state-id name))))))
      (when buf
        (with-current-buffer buf
          ;; Replace only the message region, leaving git's comment/scissors
          ;; tail intact (git strips it on commit).
          (let ((r (jetpacs-witheditor--message-region)))
            (delete-region (car r) (cdr r))
            (goto-char (point-min))
            (insert (if (stringp value) value "") "\n"))
          (jetpacs-ui-state-clear (jetpacs-witheditor--state-id name))
          ;; Clear BEFORE finishing: the post-finish hook must not
          ;; double-dismiss (it would race a dialog a later flow opened).
          (setq jetpacs-witheditor--active nil)
          (when (fboundp 'with-editor-finish)
            (with-editor-finish nil)))
        (jetpacs-dismiss-dialog)
        (jetpacs-shell-push)))))

(jetpacs-defaction "witheditor.cancel"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (jetpacs-witheditor--find-buffer name)))
      (when buf
        (with-current-buffer buf
          (jetpacs-ui-state-clear (jetpacs-witheditor--state-id name))
          (setq jetpacs-witheditor--active nil)
          (when (fboundp 'with-editor-cancel)
            (with-editor-cancel nil)))
        (jetpacs-dismiss-dialog)
        (jetpacs-shell-push)))))

;; ─── Hooks (installed only once with-editor/git-commit are present) ───────────

(with-eval-after-load 'with-editor
  (add-hook 'with-editor-mode-hook #'jetpacs-witheditor--maybe-bridge)
  ;; Dismiss our dialog when the session ends from the desktop side.
  (add-hook 'with-editor-post-finish-hook #'jetpacs-witheditor--session-ended)
  (add-hook 'with-editor-post-cancel-hook #'jetpacs-witheditor--session-ended))

(with-eval-after-load 'git-commit
  (add-hook 'git-commit-setup-hook #'jetpacs-witheditor--maybe-bridge))

(provide 'jetpacs-witheditor)
;;; jetpacs-witheditor.el ends here
