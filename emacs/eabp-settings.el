;;; eabp-settings.el --- Schema-driven settings from defcustom metadata -*- lexical-binding: t; -*-

;; Renders an allowlisted set of defcustom variables as companion widgets
;; derived from their `custom-type' schemas, and applies edits through
;; Customize: candidate values are validated with the type's widget
;; `:match', set via `customize-set-variable' (so `:set' setters run),
;; and persisted via `customize-save-variable'.
;;
;; The registry is the security boundary: `settings.set' / `settings.reset'
;; only touch symbols present in `eabp-settings-registry', never arbitrary
;; names off the wire.  Exposing a new setting is one registry entry.
;;
;; Widget mapping by type: boolean -> switch (the client switch publishes
;; state.changed rather than dispatching an action, so per-id handlers are
;; registered at load), choice-of-consts -> single-select enum list,
;; string/file/directory -> text input, integer/number -> numeric text
;; input, anything else -> a raw elisp-expression input read with `read'.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)

(declare-function custom-file "cus-edit" (&optional no-error))

;; The host UI (eabp-org-ui) points these at its snackbar and dashboard
;; push; this module stays independent of any particular screen.
(defvar eabp-settings-notify-function #'message
  "Function of one string, used to surface rejections and save failures.")

(defvar eabp-settings-refresh-function #'ignore
  "Function called after a setting changes so the client re-renders.")

(defvar eabp-settings-registry
  '(("Org Workflow"
     (org-directory :label "Org directory")
     (org-log-done :label "Log task completion")
     (org-log-into-drawer :label "Log into drawer")
     (org-archive-location :label "Archive location"))
    ("Org Agenda"
     (org-agenda-span :label "Agenda span")
     (org-deadline-warning-days :label "Deadline warning days"))
    ("Org Editing & Display"
     (org-startup-folded :label "Initial folding")
     (org-startup-indented :label "Indent to outline level")
     (org-hide-emphasis-markers :label "Hide emphasis markers")
     (org-return-follows-link :label "Enter follows links")))
  "Sections of settings exposed to the companion.
Each element is (TITLE . ENTRIES); an entry is (SYMBOL . PLIST) where
PLIST supports :label (display name) and :after-set (function of the
new value, for propagation the defcustom's `:set' doesn't cover).
Only symbols listed here can be modified from the wire.")

(defun eabp-settings--entry (sym)
  "Registry entry for SYM, or nil if SYM is not exposed."
  (cl-loop for (_title . entries) in eabp-settings-registry
           thereis (assq sym entries)))

;; ─── Persistence ─────────────────────────────────────────────────────────────

(defun eabp-settings-save-variable (symbol value)
  "Persist SYMBOL as VALUE through Customize, surfacing failures.
Returns non-nil on success.  Failures are reported through
`eabp-settings-notify-function' instead of being silently dropped;
notably, `customize-save-variable' quietly skips saving when there is
no file to save into (started with -q, or no init file), which would
otherwise look like a save and then vanish on restart."
  (require 'cus-edit)
  (condition-case err
      (if (custom-file t)
          (progn (customize-save-variable symbol value) t)
        (set-default symbol value)
        (funcall eabp-settings-notify-function
                 "Applied for this session only: no init file to save settings into")
        nil)
    (error
     (funcall eabp-settings-notify-function
              (format "Applied for this session, but saving failed: %s"
                      (error-message-string err)))
     nil)))

;; ─── Type classification ─────────────────────────────────────────────────────

(defun eabp-settings--type (sym)
  "The `custom-type' schema of SYM, or nil for plain defvars."
  (get sym 'custom-type))

(defun eabp-settings--const-option (alt)
  "If choice alternative ALT is a const, return (TAG . VALUE); else nil."
  (when (and (consp alt) (eq (car alt) 'const))
    (let ((args (cdr alt)) (tag nil))
      (while (keywordp (car args))
        (when (eq (car args) :tag)
          (setq tag (cadr args)))
        (setq args (cddr args)))
      (cons (or tag (format "%s" (car args))) (car args)))))

(defun eabp-settings--choice-options (type)
  "For a (choice ...) TYPE, alist of (TAG . VALUE) for its const arms.
Non-const arms (e.g. a free string alternative) are simply not offered;
a current value outside the consts still displays, printed."
  (delq nil (mapcar #'eabp-settings--const-option (cdr type))))

(defun eabp-settings--kind (type)
  "Classify custom TYPE into a widget kind symbol."
  (pcase (if (consp type) (car type) type)
    ('boolean 'boolean)
    ((or 'string 'regexp 'file 'directory) 'string)
    ((or 'integer 'natnum 'number 'float) 'number)
    ('choice (if (eabp-settings--choice-options type) 'choice 'raw))
    (_ 'raw)))

(defun eabp-settings--valid-p (sym value)
  "Whether VALUE structurally satisfies SYM's custom type."
  (let ((type (eabp-settings--type sym)))
    (or (null type)
        (condition-case nil
            (and (widget-apply (widget-convert type) :match value) t)
          (error nil)))))

;; ─── Setting values ──────────────────────────────────────────────────────────

(defun eabp-settings--apply (sym value)
  "Validate, set, propagate and persist VALUE for SYM.
Returns non-nil when the value was accepted (even if only applied for
the session because persisting failed)."
  (if (not (eabp-settings--valid-p sym value))
      (progn
        (funcall eabp-settings-notify-function
                 (format "Invalid value for %s" sym))
        nil)
    (customize-set-variable sym value)
    (let ((fn (plist-get (cdr (eabp-settings--entry sym)) :after-set)))
      (when fn (funcall fn value)))
    ;; Org-derived views are memoised; per the cache contract every
    ;; mutation must drop it or the phone keeps rendering stale data.
    (when (and (string-prefix-p "org-" (symbol-name sym))
               (fboundp 'eabp-org-cache-invalidate))
      (eabp-org-cache-invalidate))
    (eabp-settings-save-variable sym value)
    t))

(defun eabp-settings--decode (sym wire)
  "Decode client-sent WIRE into a candidate value for SYM.
Returns (VALUE) on success, `skip' for a no-op (e.g. an enum
deselection), nil when undecodable."
  (let* ((type (eabp-settings--type sym))
         (kind (eabp-settings--kind type))
         (trim (lambda (s) (replace-regexp-in-string
                            "\\`[ \t\n\r]+\\|[ \t\n\r]+\\'" "" s))))
    (pcase kind
      ('choice
       (let ((tag (car (append wire nil))))
         (if (null tag)
             'skip                      ; deselect: keep the current value
           (let ((opt (assoc tag (eabp-settings--choice-options type))))
             (and opt (list (cdr opt)))))))
      ('boolean (list (eq wire t)))
      ('string (and (stringp wire) (list wire)))
      ('number
       (when (stringp wire)
         (let ((s (funcall trim wire)))
           (and (string-match "\\`-?[0-9]+\\(\\.[0-9]+\\)?\\'" s)
                (list (string-to-number s))))))
      (_ (when (stringp wire)
           (condition-case nil
               (list (car (read-from-string wire)))
             (error nil)))))))

;; ─── Standard values / reset ─────────────────────────────────────────────────

(defun eabp-settings--standard-value (sym)
  "SYM's uncustomized default from the defcustom, evaluated."
  (let ((std (get sym 'standard-value)))
    (and std (eval (car std) t))))

(defun eabp-settings--modified-p (sym)
  "Whether SYM's current global value differs from its standard default."
  (and (get sym 'standard-value)
       (not (equal (default-value sym) (eabp-settings--standard-value sym)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-settings--doc-line (sym)
  "First line of SYM's docstring, or nil."
  (let ((doc (documentation-property sym 'variable-documentation)))
    (and doc (car (split-string (substitute-command-keys doc) "\n" t)))))

(defun eabp-settings--item (entry)
  "Widget column for registry ENTRY."
  (let ((sym (car entry)))
    (if (not (boundp sym))
        (eabp-text (format "%s is not loaded yet" sym) 'caption)
      (let* ((plist (cdr entry))
             (name (symbol-name sym))
             (label (or (plist-get plist :label) name))
             (doc (eabp-settings--doc-line sym))
             (value (default-value sym))
             (type (eabp-settings--type sym))
             (kind (eabp-settings--kind type))
             (wid-id (concat "setting/" name))
             (set-action (eabp-action "settings.set" :args `((name . ,name))))
             (reset (and (eabp-settings--modified-p sym)
                         (eabp-icon-button
                          "history"
                          (eabp-action "settings.reset" :args `((name . ,name)))
                          :content-description (format "Reset %s to default" label))))
             (control
              (pcase kind
                ('boolean
                 (eabp-switch wid-id :checked (and value t) :label label))
                ('choice
                 (let* ((opts (eabp-settings--choice-options type))
                        (current (car (rassoc value opts)))
                        (labels (mapcar #'car opts)))
                   (unless current
                     ;; Value set outside the const arms (e.g. a custom
                     ;; drawer name): show it, printed, as the selection.
                     (setq current (prin1-to-string value)
                           labels (append labels (list current))))
                   (eabp-enum-list wid-id labels :value (list current)
                                   :on-change set-action)))
                ('string
                 (eabp-text-input wid-id :value (and (stringp value) value)
                                  :label label :single-line t
                                  :on-submit set-action))
                ('number
                 (eabp-text-input wid-id
                                  :value (and (numberp value)
                                              (number-to-string value))
                                  :label label :single-line t
                                  :on-submit set-action))
                (_
                 (eabp-text-input wid-id :value (prin1-to-string value)
                                  :label label :single-line t :monospace t
                                  :hint "Elisp expression"
                                  :on-submit set-action)))))
        (apply #'eabp-column
               (delq nil
                     (list
                      ;; Booleans carry their label inside the switch row;
                      ;; everything else gets a plain label row. The weighted
                      ;; box keeps the reset button on-screen (columns render
                      ;; fillMaxWidth and would swallow the row).
                      (eabp-row
                       (eabp-box (list (if (eq kind 'boolean)
                                           control
                                         (eabp-text label 'label)))
                                 :weight 1)
                       reset)
                      (when doc (eabp-text doc 'caption))
                      (unless (eq kind 'boolean) control))))))))

(defun eabp-settings-sections ()
  "Flat list of nodes rendering every registry section."
  (cl-loop for (title . entries) in eabp-settings-registry
           append (append (list (eabp-divider)
                                (eabp-section-header title))
                          (mapcar #'eabp-settings--item entries))))

;; ─── Actions and state handlers ──────────────────────────────────────────────

(eabp-defaction "settings.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (eabp-settings--entry sym))))
      (cond
       ((not entry)
        (funcall eabp-settings-notify-function
                 (format "Setting %s is not editable from the app"
                         (or name "?"))))
       (t
        (pcase (eabp-settings--decode sym (alist-get 'value args))
          ('skip nil)
          ('nil (funcall eabp-settings-notify-function
                         (format "Invalid value for %s" name)))
          (`(,value) (eabp-settings--apply sym value)))))
      (funcall eabp-settings-refresh-function))))

(eabp-defaction "settings.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (eabp-settings--entry sym))))
      (if (not (and entry (get sym 'standard-value)))
          (funcall eabp-settings-notify-function "Cannot reset this setting")
        (when (eabp-settings--apply sym (eabp-settings--standard-value sym))
          (funcall eabp-settings-notify-function
                   (format "%s reset to default" name))))
      (funcall eabp-settings-refresh-function))))

(defun eabp-settings--register-state-handlers ()
  "Register state.changed handlers for every registry symbol.
The client's switch widget publishes state.changed instead of
dispatching an action, and a queued toggle can replay before the
settings screen has ever rendered this session — so handlers are
registered at load, not at render.  Non-boolean payloads under these
ids (e.g. a text input's published state) are ignored; text inputs
save through settings.set on submit."
  (dolist (section eabp-settings-registry)
    (dolist (entry (cdr section))
      (let ((sym (car entry)))
        (eabp-on-state-change
         (concat "setting/" (symbol-name sym))
         (lambda (val)
           (when (memq val '(t :false))
             (eabp-settings--apply sym (eq val t))
             (funcall eabp-settings-refresh-function))))))))

(eabp-settings--register-state-handlers)

(provide 'eabp-settings)
;;; eabp-settings.el ends here
