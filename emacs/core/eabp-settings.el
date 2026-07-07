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
;; The rendering/apply machinery itself is public and gate-agnostic —
;; eabp-customize.el reuses it under its own `customize.*' actions with a
;; `custom-variable-p' gate; the registry rule above binds `settings.*' only.
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

;; The host shell points these at its snackbar and dashboard push; this
;; module stays independent of any particular screen.
(defvar eabp-settings-notify-function #'message
  "Function of one string, used to surface rejections and save failures.")

(defvar eabp-settings-refresh-function #'ignore
  "Function called after a setting changes so the client re-renders.")

(defvar eabp-settings-after-set-hook nil
  "Hook run with (SYMBOL VALUE) after a setting is applied from the wire.
For propagation the defcustom's `:set' doesn't cover — e.g. an app whose
views memoise derived data registers its cache invalidation here.")

(defvar eabp-settings-registry nil
  "Sections of settings exposed to the companion.
Each element is (TITLE . ENTRIES); an entry is (SYMBOL . PLIST) where
PLIST supports :label (display name) and :after-set (function of the
new value, for propagation the defcustom's `:set' doesn't cover).
Only symbols listed here can be modified from the wire.

Empty by default: the machinery is app-agnostic, and each Tier 1 app
exposes its own variables through `eabp-settings-register-section'.")

(defun eabp-settings-register-section (title entries)
  "Register (or replace) the settings section TITLE with ENTRIES.
ENTRIES is a list of (SYMBOL . PLIST) — see `eabp-settings-registry'.
Also registers the state.changed handlers the entries' switch widgets
publish through, so a queued toggle can replay before the settings
screen has ever rendered this session."
  (when (fboundp 'eabp--claim) (eabp--claim "settings" title))
  (setq eabp-settings-registry
        (append (assoc-delete-all title eabp-settings-registry)
                (list (cons title entries))))
  (eabp-settings--register-state-handlers (list (cons title entries))))

(defun eabp-settings-remove-section (title)
  "Unregister the settings section TITLE (used by `eabp-app-unregister')."
  (setq eabp-settings-registry (assoc-delete-all title eabp-settings-registry)))

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

(defun eabp-settings-apply (sym value &optional after-set)
  "Validate, set, propagate and persist VALUE for SYM.
AFTER-SET, when non-nil, is called with VALUE once the set has run —
the propagation a caller's gate attaches (a registry entry's
:after-set); it is the caller's because this function no longer knows
which gate admitted SYM.  Returns non-nil when the value was accepted
\(even if only applied for the session because persisting failed)."
  (if (not (eabp-settings--valid-p sym value))
      (progn
        (funcall eabp-settings-notify-function
                 (format "Invalid value for %s" sym))
        nil)
    (customize-set-variable sym value)
    (when after-set (funcall after-set value))
    ;; App views may memoise data derived from this variable; per the
    ;; cache contract every mutation must reach the registered droppers.
    (run-hook-with-args 'eabp-settings-after-set-hook sym value)
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

(defun eabp-settings-apply-wire (sym wire &optional after-set)
  "Decode client-sent WIRE and apply it to SYM; non-nil unless rejected.
An undecodable payload notifies and returns nil; a no-op (e.g. an enum
deselection) returns non-nil without touching SYM.  AFTER-SET is passed
through to `eabp-settings-apply'.  Callers gate SYM before calling —
this function validates the value, not the symbol."
  (pcase (eabp-settings--decode sym wire)
    ('skip t)
    ('nil (funcall eabp-settings-notify-function
                   (format "Invalid value for %s" sym))
          nil)
    (`(,value) (eabp-settings-apply sym value after-set))))

;; ─── Standard values / reset ─────────────────────────────────────────────────

(defun eabp-settings--standard-value (sym)
  "SYM's uncustomized default from the defcustom, evaluated."
  (let ((std (get sym 'standard-value)))
    (and std (eval (car std) t))))

(defun eabp-settings-modified-p (sym)
  "Whether SYM's current global value differs from its standard default.
Safe on any symbol: unbound means unmodified, and a standard-value form
that fails to evaluate counts as unmodified rather than erroring (the
customize browser calls this across arbitrary defcustoms)."
  (and (boundp sym)
       (get sym 'standard-value)
       (not (equal (default-value sym)
                   (condition-case nil (eabp-settings--standard-value sym)
                     (error (default-value sym)))))))

(defun eabp-settings-reset (sym &optional after-set)
  "Reset SYM to its defcustom standard value; non-nil on success.
Notifies instead of erroring when SYM has no standard value to return
to.  AFTER-SET is passed through to `eabp-settings-apply'."
  (if (not (get sym 'standard-value))
      (progn
        (funcall eabp-settings-notify-function "Cannot reset this setting")
        nil)
    (when (eabp-settings-apply sym (eabp-settings--standard-value sym) after-set)
      (funcall eabp-settings-notify-function
               (format "%s reset to default" sym))
      t)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-settings--doc-line (sym)
  "First line of SYM's docstring, or nil."
  (let ((doc (documentation-property sym 'variable-documentation)))
    (and doc (car (split-string (substitute-command-keys doc) "\n" t)))))

(cl-defun eabp-settings-item (sym &key label (id-prefix "setting/")
                                  (set-action "settings.set")
                                  (reset-action "settings.reset"))
  "Widget column rendering SYM's control from its `custom-type' schema.
LABEL defaults to the symbol name.  ID-PREFIX keys the control's widget
id; a switch under it publishes state.changed, so pair a non-default
prefix with `eabp-settings-watch-toggle'.  SET-ACTION and RESET-ACTION
name the wire actions the controls dispatch, each carrying the symbol
name under `name' — the settings screen uses the registry-gated
`settings.*', the customize browser the `custom-variable-p'-gated
`customize.*'."
  (if (not (boundp sym))
      (eabp-text (format "%s is not loaded yet" sym) 'caption)
    (let* ((name (symbol-name sym))
           (label (or label name))
           (doc (eabp-settings--doc-line sym))
           (value (default-value sym))
           (type (eabp-settings--type sym))
           (kind (eabp-settings--kind type))
           (wid-id (concat id-prefix name))
           (set (eabp-action set-action :args `((name . ,name))))
           (reset (and (eabp-settings-modified-p sym)
                       (eabp-icon-button
                        "history"
                        (eabp-action reset-action :args `((name . ,name)))
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
                                 :on-change set)))
              ('string
               (eabp-text-input wid-id :value (and (stringp value) value)
                                :label label :single-line t
                                :on-submit set))
              ('number
               (eabp-text-input wid-id
                                :value (and (numberp value)
                                            (number-to-string value))
                                :label label :single-line t
                                :on-submit set))
              (_
               (eabp-text-input wid-id :value (prin1-to-string value)
                                :label label :single-line t :monospace t
                                :hint "Elisp expression"
                                :on-submit set)))))
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
                    (unless (eq kind 'boolean) control)))))))

(defun eabp-settings--item (entry)
  "Widget column for registry ENTRY."
  (eabp-settings-item (car entry) :label (plist-get (cdr entry) :label)))

(defvar eabp-settings-links nil
  "Ordered list of (ORDER . BUILDER) navigation entries for the settings screen.
BUILDER is a nullary function returning a node (usually a tappable card
leading to another screen).  Apps register their satellite screens here
— the package browser, the customize browser — instead of each claiming
a drawer slot; `eabp-settings-sections' renders them under a trailing
\"Emacs\" section.")

(defun eabp-settings-add-link (order builder)
  "Add BUILDER (a nullary node builder) to the settings screen at ORDER."
  (setq eabp-settings-links
        (sort (cons (cons order builder) eabp-settings-links)
              (lambda (a b) (< (car a) (car b))))))

(defun eabp-settings-sections ()
  "Flat list of nodes rendering every registry section, then the links."
  (append
   (cl-loop for (title . entries) in eabp-settings-registry
            append (append (list (eabp-divider)
                                 (eabp-section-header title))
                           (mapcar #'eabp-settings--item entries)))
   (when eabp-settings-links
     (append (list (eabp-divider) (eabp-section-header "Emacs"))
             (mapcar (lambda (e) (funcall (cdr e))) eabp-settings-links)))))

;; ─── Actions and state handlers ──────────────────────────────────────────────

(eabp-defaction "settings.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (eabp-settings--entry sym))))
      (if (not entry)
          (funcall eabp-settings-notify-function
                   (format "Setting %s is not editable from the app"
                           (or name "?")))
        (eabp-settings-apply-wire sym (alist-get 'value args)
                                  (plist-get (cdr entry) :after-set)))
      (funcall eabp-settings-refresh-function))))

(eabp-defaction "settings.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (eabp-settings--entry sym))))
      (if (not entry)
          (funcall eabp-settings-notify-function "Cannot reset this setting")
        (eabp-settings-reset sym (plist-get (cdr entry) :after-set)))
      (funcall eabp-settings-refresh-function))))

(defun eabp-settings-watch-toggle (sym id &optional after-set)
  "Register the state.changed handler applying SYM's switch under widget ID.
The client's switch widget publishes state.changed instead of
dispatching an action, so a boolean setting only works once a handler
exists for its widget id.  Non-boolean payloads under ID (e.g. a text
input's published state) are ignored; those save through their submit
action instead.  AFTER-SET is passed through to `eabp-settings-apply'."
  (eabp-on-state-change
   id (lambda (val)
        (when (memq val '(t :false))
          (eabp-settings-apply sym (eq val t) after-set)
          (funcall eabp-settings-refresh-function)))))

(defun eabp-settings--register-state-handlers (sections)
  "Register the switch handlers for every symbol in SECTIONS.
A queued toggle can replay before the settings screen has ever rendered
this session — so handlers are registered when the section is, not at
render."
  (dolist (section sections)
    (dolist (entry (cdr section))
      (eabp-settings-watch-toggle
       (car entry)
       (concat "setting/" (symbol-name (car entry)))
       (plist-get (cdr entry) :after-set)))))

(provide 'eabp-settings)
;;; eabp-settings.el ends here
