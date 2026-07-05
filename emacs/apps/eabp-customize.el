;;; eabp-customize.el --- Customize browser over the defcustom group tree -*- lexical-binding: t; -*-

;; The M-x customize counterpart of the tablist story.  For
;; tabulated-list the printed buffer is itself the declarative source,
;; so eabp-tablist walks it; a Custom-mode buffer is widget.el *layout*
;; — positions and markers, not data — and the wrong thing to scrape.
;; The declarative framework behind Customize is the metadata: the
;; defgroup tree plus each variable's `custom-type' schema, and
;; eabp-settings.el already renders those schemas as native controls.
;; So this app skips Custom-mode entirely: `custom-group-members'
;; provides the structure, the shared settings item renderer and apply
;; pipeline provide the leaves, and edits persist through Customize
;; (`customize-set-variable' + `customize-save-variable') like every
;; other setting.  A Custom buffer opened by hand still renders through
;; Tier 0, whose widget support can push its buttons and edit fields.
;;
;; Boundary (docs/SPEC.md §5): `customize.set' / `customize.reset'
;; accept any symbol satisfying `custom-variable-p' — deliberately wider
;; than the `settings.*' registry gate, and exactly as powerful as
;; M-x customize itself (which the M-x escape hatch already exposes).
;; Values remain plain data validated against the variable's declared
;; type before they are applied; nothing off the wire is funcalled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cus-edit)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-settings)
(require 'eabp-shell)

;; ─── View state ──────────────────────────────────────────────────────────────

(defcustom eabp-customize-max-items 50
  "Maximum subgroups and maximum variables rendered per customize screen.
Huge groups (or a broad search) are capped with a trailing note; narrow
with the search box rather than paging."
  :type 'integer :group 'eabp)

(defvar eabp-customize--path '(emacs)
  "Breadcrumb of group symbols from the root to the group being shown.")

(defvar eabp-customize--search ""
  "Current search string; non-empty switches to the flat variable list.")

(defvar eabp-customize--modified-only nil
  "Non-nil limits the view to variables changed from their defaults.")

(defun eabp-customize--group ()
  "The group currently being browsed."
  (car (last eabp-customize--path)))

(defun eabp-customize--flat-p ()
  "Non-nil when showing the flat variable list instead of the group tree."
  (or eabp-customize--modified-only
      (not (string-empty-p eabp-customize--search))))

;; ─── Reading the group tree ──────────────────────────────────────────────────

(defun eabp-customize--group-p (sym)
  "Non-nil when SYM names a customization group, loading it if deferred.
`custom-load-symbol' pulls in members a package declared via
`custom-autoload' — the same load Customize performs opening a group."
  (when sym
    (ignore-errors (custom-load-symbol sym))
    (and (or (get sym 'custom-group)
             (get sym 'group-documentation))
         t)))

(defun eabp-customize--members (group)
  "GROUP's members as (GROUPS VARIABLES FACES), each a list of symbols."
  (let (groups vars faces)
    (dolist (m (custom-group-members group nil))
      (pcase (cadr m)
        ('custom-group (push (car m) groups))
        ('custom-variable (push (car m) vars))
        ('custom-face (push (car m) faces))))
    (list (nreverse groups) (nreverse vars) (nreverse faces))))

(defun eabp-customize--flat-vars ()
  "All customizable variables passing the search and modified filters."
  (let ((q eabp-customize--search) out)
    (mapatoms
     (lambda (sym)
       (when (and (custom-variable-p sym)
                  (or (string-empty-p q)
                      (string-match-p (regexp-quote q) (symbol-name sym)))
                  (or (not eabp-customize--modified-only)
                      (eabp-settings-modified-p sym)))
         (push sym out))))
    (sort out #'string-lessp)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defvar eabp-customize--watched (make-hash-table :test 'eq)
  "Symbols whose switch state handler has been registered this session.
The settings registry registers its handlers at load, so queued toggles
always replay; customize covers arbitrary variables, so handlers are
registered when a variable first renders.  A toggle queued offline
against a variable this session has never rendered lands in
`eabp-ui-state' without applying — the documented cost of not
enumerating every defcustom up front.")

(defun eabp-customize--watch (sym)
  "Register SYM's switch handler under custom/SYM once."
  (unless (gethash sym eabp-customize--watched)
    (puthash sym t eabp-customize--watched)
    (eabp-settings-watch-toggle sym (concat "custom/" (symbol-name sym)))))

(defun eabp-customize--var-item (sym)
  "SYM as a native settings card dispatching customize.* actions."
  (if (not (boundp sym))
      ;; Autoloaded defcustom whose library isn't loaded: no type schema
      ;; to render a control from yet.
      (eabp-card
       (list (eabp-text (symbol-name sym) 'label)
             (eabp-text "Not loaded — tap to load its library" 'caption))
       :on-tap (eabp-action "customize.load"
                            :args `((name . ,(symbol-name sym)))
                            :when-offline "drop"))
    (eabp-customize--watch sym)
    (eabp-card (list (eabp-settings-item
                      sym
                      :id-prefix "custom/"
                      :set-action "customize.set"
                      :reset-action "customize.reset")))))

(defun eabp-customize--group-card (sym)
  "A tappable card descending into group SYM."
  (let ((doc (get sym 'group-documentation)))
    (eabp-card
     (list (eabp-row
            (eabp-box
             (list (apply #'eabp-column
                          (delq nil
                                (list (eabp-text (symbol-name sym) 'label)
                                      (when doc
                                        (eabp-text (car (split-string doc "\n"))
                                                   'caption))))))
             :weight 1)
            (eabp-icon "chevron_right")))
     :on-tap (eabp-action "customize.browse"
                          :args `((group . ,(symbol-name sym)))
                          :when-offline "drop"))))

(defun eabp-customize--crumbs ()
  "The breadcrumb path as one line: link-styled ancestors › bold current.
Tapping an ancestor pops back to it (customize.browse truncates the
path when the group is already on it)."
  (let ((current (eabp-customize--group)))
    (eabp-rich-text
     (cl-loop for g in eabp-customize--path
              for i from 0
              unless (zerop i) collect (eabp-span " › ")
              collect (if (eq g current)
                          (eabp-span (capitalize (symbol-name g)) :bold t)
                        (eabp-span (capitalize (symbol-name g))
                                   :on-tap (eabp-action
                                            "customize.browse"
                                            :args `((group . ,(symbol-name g)))
                                            :when-offline "drop"))))
     :style 'body)))

(defun eabp-customize--cap-note (total what)
  "The trailing truncation note, as a list, when TOTAL exceeds the cap."
  (when (> total eabp-customize-max-items)
    (list (eabp-text (format "Showing %d of %d %s — narrow with the search."
                             eabp-customize-max-items total what)
                     'caption))))

(defun eabp-customize--group-nodes ()
  "The browse view: breadcrumbs, subgroup cards, variable items."
  (pcase-let* ((group (eabp-customize--group))
               (`(,groups ,vars ,faces) (eabp-customize--members group))
               (doc (get group 'group-documentation)))
    (append
     (list (eabp-customize--crumbs))
     (when doc (list (eabp-text (car (split-string doc "\n")) 'caption)))
     (when groups
       (append
        (list (eabp-section-header (format "Groups (%d)" (length groups))))
        (mapcar #'eabp-customize--group-card
                (cl-subseq groups 0 (min (length groups)
                                         eabp-customize-max-items)))
        (eabp-customize--cap-note (length groups) "groups")))
     (when vars
       (append
        (list (eabp-section-header (format "Variables (%d)" (length vars))))
        (mapcar #'eabp-customize--var-item
                (cl-subseq vars 0 (min (length vars)
                                       eabp-customize-max-items)))
        (eabp-customize--cap-note (length vars) "variables")))
     (when faces
       (list (eabp-text (format "%d face%s — edit faces in Emacs"
                                (length faces)
                                (if (= (length faces) 1) "" "s"))
                        'caption)))
     (unless (or groups vars faces)
       (list (eabp-empty-state :icon "tune" :title "Nothing here"
                               :caption "This group declares no members."))))))

(defun eabp-customize--flat-nodes ()
  "The search/modified view: a flat, capped list of variable items."
  (let* ((syms (eabp-customize--flat-vars))
         (total (length syms)))
    (if (null syms)
        (list (eabp-empty-state
               :icon "search" :title "No matching variables"
               :caption "Search matches customizable variable names."))
      (append
       (list (eabp-text (format "%d variable%s" total (if (= total 1) "" "s"))
                        'caption))
       (mapcar #'eabp-customize--var-item
               (cl-subseq syms 0 (min total eabp-customize-max-items)))
       (eabp-customize--cap-note total "variables")))))

(defun eabp-customize--body ()
  ;; lazy_column, not column: the scaffold body has no scroll container
  ;; on the client, so a plain column taller than the screen is simply
  ;; unreachable below the fold.
  (apply #'eabp-lazy-column
         (append
          ;; The framing: the Settings screen is the curated Tier 1
          ;; experience; this browser is the escape hatch to everything
          ;; else, and "everything else" is desktop-oriented.
          (list (eabp-text
                 (concat "These are desktop Emacs's own options — many "
                         "won't affect the phone experience. Curated "
                         "options live in Settings.")
                 'caption)
                (eabp-text-input "customize-search"
                                 :value eabp-customize--search
                                 :label "Search all variables" :single-line t
                                 :on-submit (eabp-action "customize.search"))
                (eabp-flow-row
                 (eabp-chip "Modified"
                            :selected eabp-customize--modified-only
                            :on-tap (eabp-action "customize.modified-filter"
                                                 :when-offline "drop"))))
          (if (eabp-customize--flat-p)
              (eabp-customize--flat-nodes)
            (eabp-customize--group-nodes)))))

(defun eabp-customize--view (snackbar)
  "The shell view: back pops one level until the root, then leaves."
  (eabp-shell-nav-view
   "Customize" (eabp-customize--body)
   :nav-action (unless (and (null (cdr eabp-customize--path))
                            (not (eabp-customize--flat-p)))
                 (eabp-action "customize.up" :when-offline "drop"))
   :snackbar snackbar))

(eabp-shell-define-view "customize" :builder #'eabp-customize--view :order 85)

;; Entry point: a card in the settings screen's Emacs section (a
;; companion-local view switch, so it works offline).
(eabp-settings-add-link
 20 (lambda ()
      (eabp-card
       (list (eabp-row
              (eabp-icon "tune")
              (eabp-box (list (eabp-column
                               (eabp-text "Customize" 'label)
                               (eabp-text "Browse and edit any Emacs option"
                                          'caption)))
                        :weight 1)
              (eabp-icon "chevron_right")))
       :on-tap (eabp-shell-switch-view "customize"))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "customize.show"
  ;; Open the browser, optionally at GROUP (for cross-links from other
  ;; screens); with no group it resumes wherever the user last was.
  (lambda (args _)
    (let* ((name (alist-get 'group args))
           (sym (and (stringp name) (intern-soft name))))
      (when (eabp-customize--group-p sym)
        (setq eabp-customize--path (if (eq sym 'emacs) '(emacs)
                                     (list 'emacs sym))
              eabp-customize--search ""
              eabp-customize--modified-only nil)))
    (eabp-shell-push nil :switch-to "customize")))

(eabp-defaction "customize.browse"
  (lambda (args _)
    (let* ((name (alist-get 'group args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (eabp-customize--group-p sym))
          (eabp-shell-notify (format "%s is not a customization group"
                                     (or name "?")))
        (setq eabp-customize--search ""
              eabp-customize--modified-only nil
              eabp-customize--path
              (let ((at (cl-position sym eabp-customize--path)))
                (if at ; a breadcrumb tap: pop back to that depth
                    (cl-subseq eabp-customize--path 0 (1+ at))
                  (append eabp-customize--path (list sym))))))
      (eabp-shell-push))))

(eabp-defaction "customize.up"
  ;; The view's back arrow: dismiss the flat list first, then pop one
  ;; group; the arrow only leaves the view once both are spent (the
  ;; builder omits the action at the root, restoring the default back).
  (lambda (_ __)
    (cond ((eabp-customize--flat-p)
           (setq eabp-customize--search ""
                 eabp-customize--modified-only nil))
          ((cdr eabp-customize--path)
           (setq eabp-customize--path (butlast eabp-customize--path))))
    (eabp-shell-push)))

(eabp-defaction "customize.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq eabp-customize--search
            (downcase (string-trim (or (and (stringp q) q) ""))))
      (eabp-shell-push))))

(eabp-defaction "customize.modified-filter"
  (lambda (_ __)
    (setq eabp-customize--modified-only (not eabp-customize--modified-only))
    (eabp-shell-push)))

(eabp-defaction "customize.load"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym (custom-variable-p sym))
        (condition-case err
            (custom-load-symbol sym)
          (error (eabp-shell-notify (error-message-string err)))))
      (eabp-shell-push))))

(eabp-defaction "customize.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (custom-variable-p sym)))
          (eabp-shell-notify
           (format "%s is not a customizable variable" (or name "?")))
        ;; A deferred defcustom must load before its type can validate.
        (ignore-errors (custom-load-symbol sym))
        (eabp-settings-apply-wire sym (alist-get 'value args)))
      (eabp-shell-push))))

(eabp-defaction "customize.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (custom-variable-p sym)))
          (eabp-shell-notify "Cannot reset this setting")
        (eabp-settings-reset sym))
      (eabp-shell-push))))

(provide 'eabp-customize)
;;; eabp-customize.el ends here
