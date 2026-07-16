;;; jetpacs-customize.el --- Customize browser over the defcustom group tree -*- lexical-binding: t; -*-

;; The M-x customize counterpart of the tablist story.  For
;; tabulated-list the printed buffer is itself the declarative source,
;; so jetpacs-tablist walks it; a Custom-mode buffer is widget.el *layout*
;; — positions and markers, not data — and the wrong thing to scrape.
;; The declarative framework behind Customize is the metadata: the
;; defgroup tree plus each variable's `custom-type' schema, and
;; jetpacs-settings.el already renders those schemas as native controls.
;; So this app skips Custom-mode entirely: `custom-group-members'
;; provides the structure, the shared settings item renderer and apply
;; pipeline provide the leaves, and edits persist through Customize
;; (`customize-set-variable' + `customize-save-variable') like every
;; other setting.  A Custom buffer opened by hand still renders through
;; Tier 0, whose widget support can push its buttons and edit fields.
;;
;; Boundary (ebp/SPEC.md §5): `customize.set' / `customize.reset'
;; accept any symbol satisfying `custom-variable-p' — deliberately wider
;; than the `settings.*' registry gate, and exactly as powerful as
;; M-x customize itself (which the M-x escape hatch already exposes).
;; Values remain plain data validated against the variable's declared
;; type before they are applied; nothing off the wire is funcalled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cus-edit)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-settings)
(require 'jetpacs-shell)

;; ─── View state ──────────────────────────────────────────────────────────────

(defcustom jetpacs-customize-max-items 50
  "Maximum subgroups and maximum variables rendered per customize screen.
Huge groups (or a broad search) are capped with a trailing note; narrow
with the search box rather than paging."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-customize--path '(emacs)
  "Breadcrumb of group symbols from the root to the group being shown.")

(defvar jetpacs-customize--search ""
  "Current search string; non-empty switches to the flat variable list.")

(defvar jetpacs-customize--modified-only nil
  "Non-nil limits the view to variables changed from their defaults.")

(defun jetpacs-customize--group ()
  "The group currently being browsed."
  (car (last jetpacs-customize--path)))

(defun jetpacs-customize--flat-p ()
  "Non-nil when showing the flat variable list instead of the group tree."
  (or jetpacs-customize--modified-only
      (not (string-empty-p jetpacs-customize--search))))

;; ─── Reading the group tree ──────────────────────────────────────────────────

(defun jetpacs-customize--group-p (sym)
  "Non-nil when SYM names a customization group, loading it if deferred.
`custom-load-symbol' pulls in members a package declared via
`custom-autoload' — the same load Customize performs opening a group."
  (when sym
    (ignore-errors (custom-load-symbol sym))
    (and (or (get sym 'custom-group)
             (get sym 'group-documentation))
         t)))

(defun jetpacs-customize--members (group)
  "GROUP's members as (GROUPS VARIABLES FACES), each a list of symbols."
  (let (groups vars faces)
    (dolist (m (custom-group-members group nil))
      (pcase (cadr m)
        ('custom-group (push (car m) groups))
        ('custom-variable (push (car m) vars))
        ('custom-face (push (car m) faces))))
    (list (nreverse groups) (nreverse vars) (nreverse faces))))

(defun jetpacs-customize--flat-vars ()
  "All customizable variables passing the search and modified filters."
  (let ((q jetpacs-customize--search) out)
    (mapatoms
     (lambda (sym)
       (when (and (custom-variable-p sym)
                  (or (string-empty-p q)
                      (string-match-p (regexp-quote q) (symbol-name sym)))
                  (or (not jetpacs-customize--modified-only)
                      (jetpacs-settings-modified-p sym)))
         (push sym out))))
    (sort out #'string-lessp)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defvar jetpacs-customize--watched (make-hash-table :test 'eq)
  "Symbols whose switch state handler has been registered this session.
The settings registry registers its handlers at load, so queued toggles
always replay; customize covers arbitrary variables, so handlers are
registered when a variable first renders.  A toggle queued offline
against a variable this session has never rendered lands in
`jetpacs-ui-state' without applying — the documented cost of not
enumerating every defcustom up front.")

(defun jetpacs-customize--watch (sym)
  "Register SYM's switch handler under custom/SYM once."
  (unless (gethash sym jetpacs-customize--watched)
    (puthash sym t jetpacs-customize--watched)
    (jetpacs-settings-watch-toggle sym (concat "custom/" (symbol-name sym)))))

(defun jetpacs-customize--var-item (sym)
  "SYM as a native settings card dispatching customize.* actions."
  (if (not (boundp sym))
      ;; Autoloaded defcustom whose library isn't loaded: no type schema
      ;; to render a control from yet.
      (jetpacs-card
       (list (jetpacs-text (symbol-name sym) 'label)
             (jetpacs-text "Not loaded — tap to load its library" 'caption))
       :on-tap (jetpacs-action "customize.load"
                            :args `((name . ,(symbol-name sym)))
                            :when-offline "drop"))
    (jetpacs-customize--watch sym)
    (jetpacs-card (list (jetpacs-settings-item
                      sym
                      :id-prefix "custom/"
                      :set-action "customize.set"
                      :reset-action "customize.reset")))))

(defun jetpacs-customize--group-card (sym)
  "A tappable card descending into group SYM."
  (let ((doc (get sym 'group-documentation)))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-box
             (list (apply #'jetpacs-column
                          (delq nil
                                (list (jetpacs-text (symbol-name sym) 'label)
                                      (when doc
                                        (jetpacs-text (car (split-string doc "\n"))
                                                   'caption))))))
             :weight 1)
            (jetpacs-icon "chevron_right")))
     :on-tap (jetpacs-action "customize.browse"
                          :args `((group . ,(symbol-name sym)))
                          :when-offline "drop"))))

(defun jetpacs-customize--crumbs ()
  "The breadcrumb path as one line: link-styled ancestors › bold current.
Tapping an ancestor pops back to it (customize.browse truncates the
path when the group is already on it)."
  (let ((current (jetpacs-customize--group)))
    (jetpacs-rich-text
     (cl-loop for g in jetpacs-customize--path
              for i from 0
              unless (zerop i) collect (jetpacs-span " › ")
              collect (if (eq g current)
                          (jetpacs-span (capitalize (symbol-name g)) :bold t)
                        (jetpacs-span (capitalize (symbol-name g))
                                   :on-tap (jetpacs-action
                                            "customize.browse"
                                            :args `((group . ,(symbol-name g)))
                                            :when-offline "drop"))))
     :style 'body)))

(defun jetpacs-customize--cap-note (total what)
  "The trailing truncation note, as a list, when TOTAL exceeds the cap."
  (when (> total jetpacs-customize-max-items)
    (list (jetpacs-text (format "Showing %d of %d %s — narrow with the search."
                             jetpacs-customize-max-items total what)
                     'caption))))

(defun jetpacs-customize--group-nodes ()
  "The browse view: breadcrumbs, subgroup cards, variable items."
  (pcase-let* ((group (jetpacs-customize--group))
               (`(,groups ,vars ,faces) (jetpacs-customize--members group))
               (doc (get group 'group-documentation)))
    (append
     (list (jetpacs-customize--crumbs))
     (when doc (list (jetpacs-text (car (split-string doc "\n")) 'caption)))
     (when groups
       (append
        (list (jetpacs-section-header (format "Groups (%d)" (length groups))))
        (mapcar #'jetpacs-customize--group-card
                (cl-subseq groups 0 (min (length groups)
                                         jetpacs-customize-max-items)))
        (jetpacs-customize--cap-note (length groups) "groups")))
     (when vars
       (append
        (list (jetpacs-section-header (format "Variables (%d)" (length vars))))
        (mapcar #'jetpacs-customize--var-item
                (cl-subseq vars 0 (min (length vars)
                                       jetpacs-customize-max-items)))
        (jetpacs-customize--cap-note (length vars) "variables")))
     (when faces
       (list (jetpacs-text (format "%d face%s — edit faces in Emacs"
                                (length faces)
                                (if (= (length faces) 1) "" "s"))
                        'caption)))
     (unless (or groups vars faces)
       (list (jetpacs-empty-state :icon "tune" :title "Nothing here"
                               :caption "This group declares no members."))))))

(defun jetpacs-customize--flat-nodes ()
  "The search/modified view: a flat, capped list of variable items."
  (let* ((syms (jetpacs-customize--flat-vars))
         (total (length syms)))
    (if (null syms)
        (list (jetpacs-empty-state
               :icon "search" :title "No matching variables"
               :caption "Search matches customizable variable names."))
      (append
       (list (jetpacs-text (format "%d variable%s" total (if (= total 1) "" "s"))
                        'caption))
       (mapcar #'jetpacs-customize--var-item
               (cl-subseq syms 0 (min total jetpacs-customize-max-items)))
       (jetpacs-customize--cap-note total "variables")))))

(defun jetpacs-customize--body ()
  ;; lazy_column, not column: the scaffold body has no scroll container
  ;; on the client, so a plain column taller than the screen is simply
  ;; unreachable below the fold.
  (apply #'jetpacs-lazy-column
         (append
          ;; The framing: the Settings screen is the curated Tier 1
          ;; experience; this browser is the escape hatch to everything
          ;; else, and "everything else" is desktop-oriented.
          (list (jetpacs-text
                 (concat "These are desktop Emacs's own options — many "
                         "won't affect the phone experience. Curated "
                         "options live in Settings.")
                 'caption)
                (jetpacs-text-input "customize-search"
                                 :value jetpacs-customize--search
                                 :label "Search all variables" :single-line t
                                 :on-submit (jetpacs-action "customize.search"))
                (jetpacs-flow-row
                 (jetpacs-chip "Modified"
                            :selected jetpacs-customize--modified-only
                            :on-tap (jetpacs-action "customize.modified-filter"
                                                 :when-offline "drop"))))
          (if (jetpacs-customize--flat-p)
              (jetpacs-customize--flat-nodes)
            (jetpacs-customize--group-nodes)))))

(defun jetpacs-customize--view (snackbar)
  "The shell view: back pops one level until the root, then leaves."
  (jetpacs-shell-nav-view
   "Customize" (jetpacs-customize--body)
   :nav-action (unless (and (null (cdr jetpacs-customize--path))
                            (not (jetpacs-customize--flat-p)))
                 (jetpacs-action "customize.up" :when-offline "drop"))
   :snackbar snackbar))

(jetpacs-shell-define-view "customize" :builder #'jetpacs-customize--view :order 85)

;; Entry point: a card in the settings screen's Emacs section (a
;; companion-local view switch, so it works offline).
(jetpacs-settings-add-link
 20 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "tune")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Customize" 'label)
                               (jetpacs-text "Browse and edit any Emacs option"
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-shell-switch-view "customize"))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "customize.show"
  ;; Open the browser, optionally at GROUP (for cross-links from other
  ;; screens); with no group it resumes wherever the user last was.
  (lambda (args _)
    (let* ((name (alist-get 'group args))
           (sym (and (stringp name) (intern-soft name))))
      (when (jetpacs-customize--group-p sym)
        (setq jetpacs-customize--path (if (eq sym 'emacs) '(emacs)
                                     (list 'emacs sym))
              jetpacs-customize--search ""
              jetpacs-customize--modified-only nil)))
    (jetpacs-shell-push nil :switch-to "customize")))

(jetpacs-defaction "customize.browse"
  (lambda (args _)
    (let* ((name (alist-get 'group args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (jetpacs-customize--group-p sym))
          (jetpacs-shell-notify (format "%s is not a customization group"
                                     (or name "?")))
        (setq jetpacs-customize--search ""
              jetpacs-customize--modified-only nil
              jetpacs-customize--path
              (let ((at (cl-position sym jetpacs-customize--path)))
                (if at ; a breadcrumb tap: pop back to that depth
                    (cl-subseq jetpacs-customize--path 0 (1+ at))
                  (append jetpacs-customize--path (list sym))))))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.up"
  ;; The view's back arrow: dismiss the flat list first, then pop one
  ;; group; the arrow only leaves the view once both are spent (the
  ;; builder omits the action at the root, restoring the default back).
  (lambda (_ __)
    (cond ((jetpacs-customize--flat-p)
           (setq jetpacs-customize--search ""
                 jetpacs-customize--modified-only nil))
          ((cdr jetpacs-customize--path)
           (setq jetpacs-customize--path (butlast jetpacs-customize--path))))
    (jetpacs-shell-push)))

(jetpacs-defaction "customize.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq jetpacs-customize--search
            (downcase (string-trim (or (and (stringp q) q) ""))))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.modified-filter"
  (lambda (_ __)
    (setq jetpacs-customize--modified-only (not jetpacs-customize--modified-only))
    (jetpacs-shell-push)))

(jetpacs-defaction "customize.load"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym (custom-variable-p sym))
        (condition-case err
            (custom-load-symbol sym)
          (error (jetpacs-shell-notify (error-message-string err)))))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (custom-variable-p sym)))
          (jetpacs-shell-notify
           (format "%s is not a customizable variable" (or name "?")))
        ;; A deferred defcustom must load before its type can validate.
        (ignore-errors (custom-load-symbol sym))
        (jetpacs-settings-apply-wire sym (alist-get 'value args)))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (custom-variable-p sym)))
          (jetpacs-shell-notify "Cannot reset this setting")
        (jetpacs-settings-reset sym))
      (jetpacs-shell-push))))

(provide 'jetpacs-customize)
;;; jetpacs-customize.el ends here
