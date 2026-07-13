;;; jetpacs-spec.el --- declarative data-view compiler -*- lexical-binding: t; -*-

;; The UI half of a declarative view.  `jetpacs-shell-define-view' accepts a
;; `:spec' (a plist) beside `:builder'; this module compiles it, at push time,
;; into the same scaffold node tree a hand-written builder returns:
;;
;;   query a named source -> group -> per-item template instantiation -> layout
;;   -> chrome (tab/nav).
;;
;; The template is RAW wire-node data (ordinary widget constructors are not
;; promised to preserve placeholders, so a template is authored as raw nodes).
;; A leaf may be a PLACEHOLDER `((bind . "field") (as . "transform"))' — the
;; only dynamic element, resolved server-side from the item's fields through a
;; CLOSED, domain-neutral transform set (SPEC §5: no expressions on the wire).
;; `jetpacs-lint-view-spec' (jetpacs-lint.el) proves a spec carries only closed
;; data and registered names.
;;
;; Layouts: list (header + one template per item), calendar (ISO-date groups,
;; ascending, unscheduled last), board (grouped columns; the per-card
;; cross-column "move" menu is a Glasspane opinion left to :builder in v1).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-source)
(require 'jetpacs-shell)
(require 'jetpacs-lint)

;; ─── Placeholders + transforms ───────────────────────────────────────────────

(defun jetpacs-spec--placeholder-p (x)
  "Non-nil when X is a `((bind . FIELD) [(as . TRANSFORM)])' placeholder."
  (and (jetpacs-lint--alist-p x) (assq 'bind x) t))

(defun jetpacs-spec--field-value (item field)
  "The raw value of FIELD (a string) in ITEM (a symbol-keyed alist)."
  (and field (alist-get (intern field) item)))

(defun jetpacs-spec--date-label (iso)
  "\"Mon D\" for an ISO date string ISO, or nil."
  (when (and (stringp iso)
             (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" iso))
    (format "%s %d" (jetpacs-month-abbrev (string-to-number (match-string 2 iso)))
            (string-to-number (match-string 3 iso)))))

(defun jetpacs-spec--transform (as raw)
  "Apply the closed transform named AS to RAW; nil means \"absent\" (dropped).
Transforms are domain-neutral: a source normalizes engine data to canonical
types (ISO dates, string lists) before core sees it."
  (pcase as
    ("raw" raw)
    ("string" (and raw (if (stringp raw) raw (format "%s" raw))))
    ("date" (and (stringp raw)
                 (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" raw) raw))
    ("date-label" (jetpacs-spec--date-label raw))
    ("tags-list" (let ((l (cond ((vectorp raw) (append raw nil)) ((listp raw) raw))))
                   (and l (mapconcat (lambda (s) (format "%s" s)) l " "))))
    ("count" (length (cond ((vectorp raw) (append raw nil)) ((listp raw) raw) (t nil))))
    ("bool" (if raw t :false))
    ("ref" raw)
    (_ raw)))

(defun jetpacs-spec--resolve (ph item source)
  "Resolve placeholder PH against ITEM (SOURCE labels errors)."
  (ignore source)
  (jetpacs-spec--transform (or (alist-get 'as ph) "raw")
                           (jetpacs-spec--field-value item (alist-get 'bind ph))))

;; ─── Instantiation (the only place a field value is computed) ────────────────

(defun jetpacs-spec--instantiate-args (args item source)
  "Instantiate an action's ARGS for ITEM.
ARGS is a placeholder binding the whole args object (e.g. a ref), or an alist
whose values are literals/placeholders and which may carry one `_spread' entry
\(a placeholder for a base object to merge under the literal keys).  A key that
collides with a spread key is an error."
  (cond
   ((jetpacs-spec--placeholder-p args) (jetpacs-spec--resolve args item source))
   ((jetpacs-lint--alist-p args)
    (let* ((spread-cell (assq '_spread args))
           (base (and spread-cell (jetpacs-spec--resolve (cdr spread-cell) item source)))
           (rest (assq-delete-all '_spread (copy-alist args)))
           (merged (delq nil
                         (mapcar (lambda (pair)
                                   (let ((v (jetpacs-spec--instantiate (cdr pair) item source)))
                                     (and v (cons (car pair) v))))
                                 rest))))
      (dolist (pair merged)
        (when (assq (car pair) base)
          (error "jetpacs-spec: args key `%s' collides with the spread object" (car pair))))
      (append base merged)))
   (t args)))

(defun jetpacs-spec--instantiate (node item source)
  "Return NODE with every placeholder resolved against ITEM.
A placeholder resolving to nil drops its containing attribute/child."
  (cond
   ((jetpacs-spec--placeholder-p node) (jetpacs-spec--resolve node item source))
   ((vectorp node)
    (vconcat (delq nil (mapcar (lambda (x) (jetpacs-spec--instantiate x item source))
                               (append node nil)))))
   ((jetpacs-lint--alist-p node)
    (delq nil
          (mapcar
           (lambda (pair)
             (let ((v (if (eq (car pair) 'args)
                          (jetpacs-spec--instantiate-args (cdr pair) item source)
                        (jetpacs-spec--instantiate (cdr pair) item source))))
               (and v (cons (car pair) v))))
           node)))
   (t node)))

;; ─── Grouping ────────────────────────────────────────────────────────────────

(defun jetpacs-spec--group-key (item field)
  "The group key of ITEM by FIELD — its value, or \"\" when absent."
  (or (jetpacs-spec--field-value item field) ""))

(defun jetpacs-spec--column-order (items field order source empty-last)
  "The ordered distinct group values of ITEMS by FIELD.
ORDER is an explicit values vector, else the source field's enum values, else
encounter order; present groups not covered are appended; \"\" goes last when
EMPTY-LAST."
  (let* ((present (delete-dups (mapcar (lambda (it) (jetpacs-spec--group-key it field)) items)))
         (base (cond ((vectorp order) (append order nil))
                     ((and source (jetpacs-source-p source))
                      (let ((fspec (cl-find field (jetpacs-source-fields source)
                                            :key (lambda (f) (plist-get f :name)) :test #'equal)))
                        (and (equal (plist-get fspec :type) "enum")
                             (append (plist-get fspec :values) nil))))))
         (ordered (append (cl-remove-if-not (lambda (v) (member v present)) base)
                          (cl-remove-if (lambda (v) (member v base)) present))))
    (if empty-last
        (append (cl-remove "" ordered :test #'equal)
                (and (member "" ordered) '("")))
      ordered)))

(defun jetpacs-spec--group-label (g layout)
  "A human label for group value G under LAYOUT."
  (cond ((and (stringp g) (string-empty-p g))
         (if (equal layout "calendar") "Unscheduled" "None"))
        ((equal layout "calendar") (or (jetpacs-spec--date-label g) g))
        (t g)))

;; ─── Layouts ─────────────────────────────────────────────────────────────────

(defun jetpacs-spec--cards (template items source)
  "Instantiate TEMPLATE for each of ITEMS."
  (mapcar (lambda (it) (jetpacs-spec--instantiate template it source)) items))

(defun jetpacs-spec--list (spec items template source)
  "The list layout: optional header then one template per item, in a lazy column."
  (apply #'jetpacs-lazy-column
         (append (when (plist-get spec :header)
                   (list (jetpacs-spec--instantiate (plist-get spec :header) nil source)))
                 (jetpacs-spec--cards template items source))))

(defun jetpacs-spec--calendar (spec items template source)
  "The calendar layout: ISO-date groups ascending (unscheduled last), each a
section header + its item templates, flattened into a lazy column."
  (let* ((field (or (plist-get (plist-get spec :group-by) :field) "scheduled"))
         (buckets (make-hash-table :test 'equal)))
    (dolist (it items)
      (let ((k (jetpacs-spec--group-key it field)))
        (puthash k (cons it (gethash k buckets)) buckets)))
    (let ((dates (sort (hash-table-keys buckets)
                       (lambda (a b) (cond ((string-empty-p a) nil)
                                           ((string-empty-p b) t)
                                           (t (string< a b)))))))
      (apply #'jetpacs-lazy-column
             (cl-loop for d in dates append
                      (cons (jetpacs-section-header (jetpacs-spec--group-label d "calendar"))
                            (jetpacs-spec--cards template (nreverse (gethash d buckets)) source)))))))

(defun jetpacs-spec--board (spec items template source)
  "The board layout: one column per group value, panning sideways."
  (let* ((gb (plist-get spec :group-by))
         (field (or (plist-get gb :field) "todo"))
         (groups (jetpacs-spec--column-order items field (plist-get gb :order)
                                             source (plist-get gb :empty-last))))
    (apply #'jetpacs-scroll-row
           (mapcar
            (lambda (g)
              (let ((in-col (cl-remove-if-not
                             (lambda (it) (equal (jetpacs-spec--group-key it field) g)) items)))
                (jetpacs-box
                 (list (apply #'jetpacs-column
                              (cons (jetpacs-section-header
                                     (format "%s (%d)" (jetpacs-spec--group-label g "board")
                                             (length in-col)))
                                    (jetpacs-spec--cards template in-col source))))
                 :padding 4)))
            groups))))

(defun jetpacs-spec--layout-body (spec items)
  "The body node for SPEC over ITEMS."
  (let ((template (plist-get spec :template))
        (source (plist-get spec :source)))
    (pcase (plist-get spec :layout)
      ("board" (jetpacs-spec--board spec items template source))
      ("calendar" (jetpacs-spec--calendar spec items template source))
      (_ (jetpacs-spec--list spec items template source)))))

(defun jetpacs-spec--empty-body (spec)
  "The empty-state node for SPEC (a default when none is declared)."
  (let ((es (plist-get spec :empty-state)))
    (jetpacs-empty-state :icon (or (plist-get es :icon) "inbox")
                         :title (or (plist-get es :title) "Nothing here")
                         :caption (plist-get es :caption))))

;; ─── Chrome + compile ────────────────────────────────────────────────────────

(defun jetpacs-spec--seq (x)
  "X (a vector or list of nodes) as a list, or nil."
  (and x (append x nil)))

(defun jetpacs-spec--wrap (name chrome body snackbar)
  "Wrap BODY in the tab/nav chrome for view NAME."
  (pcase (or (plist-get chrome :kind) "tab")
    ("nav"
     (jetpacs-shell-nav-view (or (plist-get chrome :title) (capitalize name)) body
                             :back-to (plist-get chrome :back)
                             :actions (jetpacs-spec--seq (plist-get chrome :actions))
                             :fab (plist-get chrome :fab)
                             :snackbar snackbar))
    (_
     (apply #'jetpacs-shell-tab-view name body
            :snackbar snackbar
            (append
             (when (plist-get chrome :title)
               (list :top-bar (jetpacs-shell-default-top-bar (plist-get chrome :title))))
             (when (plist-member chrome :fab) (list :fab (plist-get chrome :fab))))))))

(defun jetpacs-spec--compile (name spec snackbar)
  "Compile view NAME's declarative SPEC into a scaffold node tree.
Runs inside `jetpacs-shell--build-view''s condition-case, so a failure here
degrades to that view's error card rather than dropping the push."
  ;; Structural lint before querying: prove the spec is closed data over the
  ;; source's declared fields.  A problem aborts to the shell's error card.
  (let ((problems (jetpacs-lint-view-spec
                   spec (mapcar (lambda (f) (plist-get f :name))
                                (jetpacs-source-fields (plist-get spec :source))))))
    (when problems (error "invalid :spec for %s: %s" name (cdar problems))))
  (let* ((items (jetpacs-source-query (plist-get spec :source) (plist-get spec :params)))
         (body  (if items (jetpacs-spec--layout-body spec items)
                  (jetpacs-spec--empty-body spec))))
    (jetpacs-spec--wrap name (plist-get spec :chrome) body snackbar)))

(provide 'jetpacs-spec)
;;; jetpacs-spec.el ends here
