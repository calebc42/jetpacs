;;; eabp-transient.el --- Render transient prefixes as touch dialogs -*- lexical-binding: t; -*-

;; Transient prefixes (all of magit, and a growing share of modern packages)
;; are declarative specs: groups, keys, descriptions, switches and options
;; live in the `transient--layout' symbol property.  This module renders a
;; prefix as a touch dialog — infix switches/options as toggle chips,
;; suffixes as buttons — instead of transient's keyboard-driven popup.
;;
;; The integration point is an advice on `transient-setup': when a prefix
;; command runs inside an EABP action handler (an M-x from the phone, or a
;; tap in a magit buffer), the keyboard popup — which would hang waiting
;; for key events — becomes a dialog instead.  Suffixes that are themselves
;; prefixes (magit-dispatch → magit-commit) re-enter the same advice, so
;; nesting works for free.
;;
;; Dispatch stays semantic: `transient.toggle' and `transient.invoke' only
;; accept the currently shown prefix, and only arguments/commands present
;; in its own layout.  Argument state is per-prefix; at invoke time
;; `transient-args' is rebound so the suffix sees the chips exactly as it
;; would see transient's own state.

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar eabp-transient--current nil
  "(PREFIX . BUFFER-NAME) of the transient dialog being shown, or nil.
Suffixes run with BUFFER-NAME current so predicates and commands see the
context the prefix was invoked from (a magit status buffer, say).")

(defvar eabp-transient--values nil
  "Alist of PREFIX → list of active argument strings (\"--all\", \"--author=X\").")

;; ─── Reading the layout ──────────────────────────────────────────────────────

(defun eabp-transient--desc (plist fallback)
  "Resolve PLIST's :description (string or function) or FALLBACK."
  (let ((d (plist-get plist :description)))
    (cond ((stringp d) d)
          ((functionp d)
           (or (ignore-errors
                 (let ((s (funcall d)))
                   (and (stringp s) (substring-no-properties s))))
               fallback))
          (t fallback))))

(defun eabp-transient--visible-p (plist)
  "Evaluate PLIST's :if-style predicates; include the child on error.
Only the common forms are handled; anything unrecognised is visible."
  (cl-flet ((safe (f) (ignore-errors (funcall f))))
    (cond ((plist-member plist :if)
           (safe (plist-get plist :if)))
          ((plist-member plist :if-not)
           (not (safe (plist-get plist :if-not))))
          ((plist-member plist :if-non-nil)
           (symbol-value (plist-get plist :if-non-nil)))
          ((plist-member plist :if-nil)
           (not (symbol-value (plist-get plist :if-nil))))
          ((plist-member plist :if-mode)
           (derived-mode-p (plist-get plist :if-mode)))
          ((plist-member plist :if-not-mode)
           (not (derived-mode-p (plist-get plist :if-not-mode))))
          (t t))))

(defun eabp-transient--groups (prefix)
  "Flatten PREFIX's layout into (DESCRIPTION . CHILDREN) groups.
Each child is a plist with :kind (`infix' or `suffix'), :description,
:argument and :command.  Nested column containers are flattened; group
and child visibility predicates are honoured where recognisable."
  (let (groups)
    (cl-labels
        ((walk-group (g inherited-desc)
           (when (and (vectorp g) (>= (length g) 4))
             (let* ((plist (aref g 2))
                    (children (aref g 3))
                    (desc (eabp-transient--desc plist inherited-desc)))
               (when (eabp-transient--visible-p plist)
                 (if (cl-some #'vectorp children)
                     ;; A container of sub-groups (columns/rows): recurse.
                     (dolist (sub children)
                       (walk-group sub desc))
                   (let ((kids (delq nil (mapcar #'parse-child children))))
                     (when kids
                       (push (cons desc kids) groups))))))))
         (parse-child (c)
           (when (and (consp c) (>= (length c) 3))
             (let* ((plist (nth 2 c))
                    (arg (plist-get plist :argument))
                    (cmd (plist-get plist :command)))
               (when (eabp-transient--visible-p plist)
                 (cond
                  ((stringp arg)
                   (list :kind 'infix
                         :argument arg
                         :description (eabp-transient--desc plist arg)))
                  ((commandp cmd)
                   (list :kind 'suffix
                         :command cmd
                         :description
                         (eabp-transient--desc
                          plist
                          (capitalize
                           (replace-regexp-in-string
                            "-" " " (symbol-name cmd))))))))))))
      (dolist (g (get prefix 'transient--layout))
        (walk-group g nil)))
    (nreverse groups)))

(defun eabp-transient--child (prefix key value)
  "Find the child plist in PREFIX's layout whose KEY equals VALUE."
  (cl-loop for (_desc . kids) in (eabp-transient--groups prefix)
           thereis (cl-find value kids
                            :key (lambda (k) (plist-get k key))
                            :test #'equal)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-transient--arg-active (prefix arg)
  "The active value for ARG in PREFIX's state, or nil.
For options (\"--author=\") any stored value with that prefix counts."
  (let ((values (alist-get prefix eabp-transient--values)))
    (if (string-suffix-p "=" arg)
        (cl-find arg values :test #'string-prefix-p)
      (car (member arg values)))))

(defun eabp-transient--dialog (prefix)
  "Build the dialog spec for PREFIX from its layout and argument state."
  (apply
   #'eabp-lazy-column
   (append
    (list (eabp-row
           (eabp-box
            (list (eabp-text
                   (capitalize (replace-regexp-in-string
                                "-" " " (symbol-name prefix)))
                   'title))
            :weight 1)
           (eabp-button "Close"
                        (eabp-action "dialog.dismiss")
                        :variant "text")))
    (cl-loop
     for (desc . kids) in (eabp-transient--groups prefix)
     append
     (delq nil
           (list
            (when desc (eabp-section-header desc))
            (apply
             #'eabp-flow-row
             (mapcar
              (lambda (k)
                (if (eq (plist-get k :kind) 'infix)
                    (let* ((arg (plist-get k :argument))
                           (active (eabp-transient--arg-active prefix arg)))
                      (eabp-chip (if (and active (not (equal active arg)))
                                     active ; show "--author=X", not "--author="
                                   (plist-get k :description))
                                 :selected (and active t)
                                 :on-tap (eabp-action
                                          "transient.toggle"
                                          :args `((argument . ,arg))
                                          :when-offline "drop")))
                  (eabp-button (plist-get k :description)
                               (eabp-action
                                "transient.invoke"
                                :args `((command . ,(symbol-name
                                                     (plist-get k :command))))
                                :when-offline "drop")
                               :variant "outlined")))
              kids))))))))

(defun eabp-transient-show (prefix)
  "Render PREFIX as a touch dialog and record it as current."
  (setq eabp-transient--current (cons prefix (buffer-name)))
  (eabp-send-dialog (eabp-transient--dialog prefix)))

;; ─── Interception ────────────────────────────────────────────────────────────

(defun eabp--transient-setup-advice (orig-fn &optional name &rest args)
  "When a prefix is invoked from the phone, dialog instead of popup.
Without this, `transient-setup' would block waiting for key events that
can never arrive over the bridge."
  (if (and eabp--in-action-handler name (get name 'transient--layout))
      (eabp-transient-show name)
    (apply orig-fn name args)))

(advice-add 'transient-setup :around #'eabp--transient-setup-advice)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "transient.show"
  ;; Open a prefix by name.  Equivalent surface to M-x (which is already an
  ;; allowlisted path): only commands that ARE transient prefixes qualify.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (and sym (commandp sym) (get sym 'transient--layout))
          (eabp-transient-show sym)
        (eabp-send "toast.show"
                   `((text . ,(format "%s is not a transient prefix"
                                      (or name "?")))))))))

(eabp-defaction "transient.toggle"
  (lambda (args _)
    (let* ((prefix (car eabp-transient--current))
           (arg (alist-get 'argument args))
           (child (and prefix (eabp-transient--child prefix :argument arg))))
      (when child
        (let* ((values (alist-get prefix eabp-transient--values))
               (active (eabp-transient--arg-active prefix arg)))
          (setf (alist-get prefix eabp-transient--values)
                (if active
                    (remove active values)
                  (cons (if (string-suffix-p "=" arg)
                            ;; Options carry a value: prompt for it (the
                            ;; minibuffer bridge turns this into a dialog).
                            (concat arg (read-string
                                         (format "%s " (plist-get child :description))))
                          arg)
                        values)))
          (eabp-send-dialog (eabp-transient--dialog prefix)))))))

(eabp-defaction "transient.invoke"
  (lambda (args _)
    (let* ((prefix (car eabp-transient--current))
           (buf (cdr eabp-transient--current))
           (name (alist-get 'command args))
           (sym (and (stringp name) (intern-soft name)))
           (child (and prefix sym
                       (eabp-transient--child prefix :command sym))))
      (when child
        (eabp-dismiss-dialog)
        (let ((values (copy-sequence
                       (alist-get prefix eabp-transient--values)))
              (orig (symbol-function 'transient-args)))
          (with-current-buffer (or (and buf (get-buffer buf))
                                   (current-buffer))
            ;; The suffix asks `transient-args' for the popup state it
            ;; would have had; hand it the chips.
            (cl-letf (((symbol-function 'transient-args)
                       (lambda (p)
                         (if (eq p prefix) values (funcall orig p)))))
              (condition-case err
                  (call-interactively sym)
                (quit nil)
                (error (eabp-send
                        "toast.show"
                        `((text . ,(format "%s failed: %s" name
                                           (error-message-string err))))))))))
        (when (functionp eabp-buffer-refresh-function)
          (funcall eabp-buffer-refresh-function))))))

(provide 'eabp-transient)
;;; eabp-transient.el ends here
