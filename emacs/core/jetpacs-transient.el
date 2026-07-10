;;; jetpacs-transient.el --- Render transient prefixes as touch dialogs -*- lexical-binding: t; -*-

;; Transient prefixes (all of magit, and a growing share of modern packages)
;; are declarative specs: groups, keys, descriptions, switches and options
;; live in the `transient--layout' symbol property.  This module renders a
;; prefix as a touch dialog — infix switches/options as toggle chips,
;; suffixes as buttons — instead of transient's keyboard-driven popup.
;;
;; The integration point is an advice on `transient-setup': when a prefix
;; command runs inside an Jetpacs action handler (an M-x from the phone, or a
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
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar jetpacs-transient--current nil
  "(PREFIX . BUFFER-NAME) of the transient dialog being shown, or nil.
Suffixes run with BUFFER-NAME current so predicates and commands see the
context the prefix was invoked from (a magit status buffer, say).")

(defvar jetpacs-transient--values nil
  "Alist of PREFIX → list of active argument strings (\"--all\", \"--author=X\").")

;; ─── Reading the layout ──────────────────────────────────────────────────────

(defun jetpacs-transient--desc (plist fallback)
  "Resolve PLIST's :description (string or function) or FALLBACK."
  (let ((d (plist-get plist :description)))
    (cond ((stringp d) d)
          ((functionp d)
           (or (ignore-errors
                 (let ((s (funcall d)))
                   (and (stringp s) (substring-no-properties s))))
               fallback))
          (t fallback))))

(defun jetpacs-transient--visible-p (plist)
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

;; The `transient--layout' shape changed across transient versions, and the
;; two shapes are NOT compatible:
;;
;;   0.7.x (Emacs 30 bundled): the property is a LIST of group vectors, each
;;     [LEVEL CLASS PLIST CHILDREN] (4 slots); a suffix/infix leaf is a nested
;;     list (LEVEL CLASS (:key … :command …)).
;;   newer (what a MELPA/Android magit pulls): the property is a single ROOT
;;     vector, groups are [CLASS PLIST CHILDREN] (3 slots), and a leaf inlines
;;     its plist as (transient-CLASS :key … :command …).
;;
;; The helpers below normalise both: a group's plist is the last plist-shaped
;; slot, its children the last list slot; a leaf's plist is found wherever the
;; version put it.  (This is why magit-commit crashed — the old reader did
;; `dolist' on the new root VECTOR and indexed slots that had moved.)

(defun jetpacs-transient--vec-plist (g)
  "The property plist of a group vector G (nil or a keyword-keyed list)."
  (let ((n (length g)))
    (when (> n 1)
      (let ((cand (aref g (- n 2))))
        (and (consp cand) (keywordp (car cand)) cand)))))

(defun jetpacs-transient--vec-children (g)
  "The child-node list of a group vector G (its last slot when a list)."
  (let ((n (length g)))
    (when (> n 0)
      (let ((last (aref g (1- n))))
        (and (listp last) last)))))

(defun jetpacs-transient--leaf-plist (c)
  "The property plist of a suffix/infix leaf node C, across versions.
Handles a bare plist, the newer inline (transient-CLASS :k v …), and the
older nested (LEVEL CLASS (:k v …)) / (LEVEL CLASS :k v …).  Non-cons
children — the layout intersperses bare \"\" strings as visual
separators — yield nil."
  (and (consp c)
       (cond
        ((keywordp (car c)) c)
        ((and (car c) (symbolp (car c))
              (string-prefix-p "transient-" (symbol-name (car c))))
         (cdr c))
        ((integerp (car c))
         (let ((rest (cddr c)))                   ; drop LEVEL + CLASS
           (cond ((keywordp (car-safe rest)) rest) ; inline after level
                 ((and (consp (car-safe rest))     ; nested (…)
                       (keywordp (car-safe (car rest))))
                  (car rest))
                 (t nil))))
        (t nil))))

(defun jetpacs-transient--groups (prefix)
  "Flatten PREFIX's layout into (DESCRIPTION . CHILDREN) groups.
Each child is a plist with :kind (`infix' or `suffix'), :description,
:argument and :command.  Nested column containers are flattened; group
and child visibility predicates are honoured where recognisable.  Robust
to both the list-of-groups and single-root-vector layout shapes."
  (let (groups)
    (cl-labels
        ((walk-group (g inherited-desc)
           (when (vectorp g)
             (let* ((plist (jetpacs-transient--vec-plist g))
                    (children (jetpacs-transient--vec-children g))
                    (desc (jetpacs-transient--desc plist inherited-desc)))
               (when (jetpacs-transient--visible-p plist)
                 (if (cl-some #'vectorp children)
                     ;; A container of sub-groups (columns/rows) or the root:
                     ;; recurse into each vector child.
                     (dolist (sub children)
                       (when (vectorp sub) (walk-group sub desc)))
                   (let ((kids (delq nil (mapcar #'parse-child children))))
                     (when kids
                       (push (cons desc kids) groups))))))))
         (parse-child (c)
           (let ((plist (jetpacs-transient--leaf-plist c)))
             (when plist
               (let ((arg (plist-get plist :argument))
                     (cmd (plist-get plist :command)))
                 (when (jetpacs-transient--visible-p plist)
                   (cond
                    ((stringp arg)
                     (list :kind 'infix
                           :argument arg
                           :description (jetpacs-transient--desc plist arg)))
                    ((commandp cmd)
                     (list :kind 'suffix
                           :command cmd
                           :description
                           (jetpacs-transient--desc
                            plist
                            (capitalize
                             (replace-regexp-in-string
                              "-" " " (symbol-name cmd)))))))))))))
      (let ((layout (get prefix 'transient--layout)))
        (cond
         ;; Newer: a single root container vector.
         ((vectorp layout) (walk-group layout nil))
         ;; Older: a list of top-level group vectors.
         ((listp layout) (dolist (g layout) (walk-group g nil))))))
    (nreverse groups)))

(defun jetpacs-transient--child (prefix key value)
  "Find the child plist in PREFIX's layout whose KEY equals VALUE."
  (cl-loop for (_desc . kids) in (jetpacs-transient--groups prefix)
           thereis (cl-find value kids
                            :key (lambda (k) (plist-get k key))
                            :test #'equal)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-transient--arg-active (prefix arg)
  "The active value for ARG in PREFIX's state, or nil.
For options (\"--author=\") any stored value with that prefix counts."
  (let ((values (alist-get prefix jetpacs-transient--values)))
    (if (string-suffix-p "=" arg)
        (cl-find arg values :test #'string-prefix-p)
      (car (member arg values)))))

(defun jetpacs-transient--dialog (prefix)
  "Build the dialog spec for PREFIX from its layout and argument state."
  (apply
   #'jetpacs-lazy-column
   (append
    (list (jetpacs-row
           (jetpacs-box
            (list (jetpacs-text
                   (capitalize (replace-regexp-in-string
                                "-" " " (symbol-name prefix)))
                   'title))
            :weight 1)
           (jetpacs-button "Close"
                        (jetpacs-action "dialog.dismiss")
                        :variant "text")))
    (cl-loop
     for (desc . kids) in (jetpacs-transient--groups prefix)
     append
     (delq nil
           (list
            (when desc (jetpacs-section-header desc))
            (apply
             #'jetpacs-flow-row
             (mapcar
              (lambda (k)
                (if (eq (plist-get k :kind) 'infix)
                    (let* ((arg (plist-get k :argument))
                           (active (jetpacs-transient--arg-active prefix arg)))
                      (jetpacs-chip (if (and active (not (equal active arg)))
                                     active ; show "--author=X", not "--author="
                                   (plist-get k :description))
                                 :selected (and active t)
                                 :on-tap (jetpacs-action
                                          "transient.toggle"
                                          :args `((argument . ,arg))
                                          :when-offline "drop")))
                  (jetpacs-button (plist-get k :description)
                               (jetpacs-action
                                "transient.invoke"
                                :args `((command . ,(symbol-name
                                                     (plist-get k :command))))
                                :when-offline "drop")
                               :variant "outlined")))
              kids))))))))

(defun jetpacs-transient-show (prefix)
  "Render PREFIX as a touch dialog and record it as current."
  (setq jetpacs-transient--current (cons prefix (buffer-name)))
  (jetpacs-send-dialog (jetpacs-transient--dialog prefix)))

;; ─── Interception ────────────────────────────────────────────────────────────

(defun jetpacs--transient-setup-advice (orig-fn &optional name &rest args)
  "When a prefix is invoked from the phone, dialog instead of popup.
Without this, `transient-setup' would block waiting for key events that
can never arrive over the bridge."
  (if (and jetpacs--in-action-handler name (get name 'transient--layout))
      (jetpacs-transient-show name)
    (apply orig-fn name args)))

(advice-add 'transient-setup :around #'jetpacs--transient-setup-advice)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "transient.show"
  ;; Open a prefix by name.  Equivalent surface to M-x (which is already an
  ;; allowlisted path): only commands that ARE transient prefixes qualify.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (and sym (commandp sym) (get sym 'transient--layout))
          (jetpacs-transient-show sym)
        (jetpacs-send "toast.show"
                   `((text . ,(format "%s is not a transient prefix"
                                      (or name "?")))))))))

(jetpacs-defaction "transient.toggle"
  (lambda (args _)
    (let* ((prefix (car jetpacs-transient--current))
           (arg (alist-get 'argument args))
           (child (and prefix (jetpacs-transient--child prefix :argument arg))))
      (when child
        (let* ((values (alist-get prefix jetpacs-transient--values))
               (active (jetpacs-transient--arg-active prefix arg)))
          (setf (alist-get prefix jetpacs-transient--values)
                (if active
                    (remove active values)
                  (cons (if (string-suffix-p "=" arg)
                            ;; Options carry a value: prompt for it (the
                            ;; minibuffer bridge turns this into a dialog).
                            (concat arg (read-string
                                         (format "%s " (plist-get child :description))))
                          arg)
                        values)))
          (jetpacs-send-dialog (jetpacs-transient--dialog prefix)))))))

(jetpacs-defaction "transient.invoke"
  (lambda (args _)
    (let* ((prefix (car jetpacs-transient--current))
           (buf (cdr jetpacs-transient--current))
           (name (alist-get 'command args))
           (sym (and (stringp name) (intern-soft name)))
           (child (and prefix sym
                       (jetpacs-transient--child prefix :command sym))))
      (when child
        (jetpacs-dismiss-dialog)
        (let ((values (copy-sequence
                       (alist-get prefix jetpacs-transient--values)))
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
                (error (jetpacs-send
                        "toast.show"
                        `((text . ,(format "%s failed: %s" name
                                           (error-message-string err))))))))))
        (when (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function))))))

(provide 'jetpacs-transient)
;;; jetpacs-transient.el ends here
