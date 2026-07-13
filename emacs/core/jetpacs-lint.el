;;; jetpacs-lint.el --- validate SDUI specs before the wire -*- lexical-binding: t; -*-

;; A spec is a tree of alists built by the `jetpacs-widgets.el' constructors
;; and serialized to JSON by `jetpacs--encode'.  A malformed node — an
;; unknown `t', a non-serializable attribute value, a broken action —
;; either renders as nothing on the companion or, worse, makes
;; `json-serialize' throw and blanks the *whole* push.  This module lets a
;; Tier 1 catch those before they reach the wire:
;;
;;   `jetpacs-lint-spec'       — return a list of problems for a spec (nil = clean).
;;   `jetpacs-render-to-json'  — serialize + parse a spec headless (the wire
;;                            round-trip, so views are testable with no phone).
;;   `jetpacs-lint-on-push'    — when set, `jetpacs-surface-update' replaces each
;;                            invalid node in place with a visible error node,
;;                            so one bad subtree degrades instead of the push.
;;
;; The known-type list is the same vocabulary as `SDUI_NODE_TYPES'
;; (SduiRenderer.kt) and `test/widgets.golden'; the drift test
;; `jetpacs-lint-types-cover-golden' fails if a constructor emits a `t' not
;; listed here.

;;; Code:

(require 'cl-lib)
(require 'json)

;; `jetpacs--node' lives in jetpacs-widgets, which loads before this file (bundle
;; order and the core-load test). Declared so an isolated byte-compile of
;; this file alone stays warning-clean.
(declare-function jetpacs--node "jetpacs-widgets" (type &rest kvs))

(defconst jetpacs-lint-node-types
  '("text" "rich_text" "row" "flow_row" "column" "box" "surface"
    "lazy_column" "spacer" "divider" "card" "collapsible"
    "reorderable_list" "table" "tabs" "chart" "canvas" "month_grid"
    "icon" "image"
    "date_stamp" "section_header" "empty_state" "progress" "menu" "button"
    "icon_button" "chip" "assist_chip" "text_input" "editor" "checkbox"
    "switch" "enum_list" "date_button" "time_button" "slider" "scaffold")
  "Node `t' discriminators the reference companion renders.
Mirror of `SDUI_NODE_TYPES' in SduiRenderer.kt.  A `t' outside this set
is almost always a typo; a Tier 1 deliberately targeting an extended
companion gates on `jetpacs-node-supported-p' instead.")

(defconst jetpacs-lint--action-keys
  '(on_tap on_change on_submit on_save on_pick on_reorder on_refresh
    nav_action on_long_tap on_swipe on_add_row on_add_col on_trigger
    on_day_tap on_month_change on_point_tap on_button)
  "Node keys whose value is an embedded action object (SPEC §9).")

(defconst jetpacs-lint-action-fields '(action builtin args when_offline dedupe)
  "The fields an action object may carry (SPEC §5).
`action' and `builtin' are mutually exclusive; a `builtin' additionally
carries the payload keys its kind requires (`jetpacs-lint-action-builtins').")

(defconst jetpacs-lint--when-offline-values '("queue" "drop" "wake")
  "Valid `when_offline' queue policies (SPEC §5); the default is \"queue\".")

(defconst jetpacs-lint-action-builtins
  '(("view.switch" view)
    ("clipboard.copy" text)
    ("jetpacs.settings.open"))
  "Companion-local builtins → the payload keys each requires (SPEC §5).
Each entry is (NAME . REQUIRED-KEYS): an action object using `builtin'
must name one of these and carry every listed key.  `build-contract.el'
derives the discriminated action schema in `contract.json' from this.")

(defconst jetpacs-lint--numeric-attrs
  '(padding weight spacing run_spacing elevation size min_lines max_lines
    width height fill_fraction aspect_ratio min max steps initial dots
    ;; canvas draw-op coordinates
    x y w h r cx cy x1 y1 x2 y2 radius stroke)
  "Attributes whose value must be a number.")

(defconst jetpacs-lint--color-attrs '(color bg)
  "Attributes whose value must be a hex string or a theme token.")

(defconst jetpacs-lint--toolbar-ops '(snippet line on_tap menu)
  "The op fields of an editor toolbar item — exactly one per item (SPEC §9).")

(defconst jetpacs-lint--toolbar-placements '("cursor" "line-start" "block")
  "Valid `placement' values on a toolbar snippet item.")

(defconst jetpacs-lint--toolbar-line-ops '("promote" "demote" "move-up" "move-down")
  "Valid builtin `line' op names on a toolbar item.")

;; ─── Declarative view specs (jetpacs-spec.el) ────────────────────────────────

(defconst jetpacs-lint-spec-layouts '("list" "board" "calendar")
  "Layouts a declarative view `:spec' may request.")

(defconst jetpacs-lint-spec-transforms
  '("raw" "string" "date" "date-label" "tags-list" "count" "bool" "ref")
  "The closed transform names a template placeholder's `as' may name.")

(defconst jetpacs-lint-spec-keys
  '(:source :params :layout :template :header :group-by :empty-state :chrome)
  "The keys a view `:spec' plist may carry.")

(defconst jetpacs-lint-spec-chrome-kinds '("tab" "nav")
  "The `:kind' values a spec `:chrome' may declare.")

;; ─── Shape predicates ────────────────────────────────────────────────────────

(defun jetpacs-lint--alist-p (x)
  "Non-nil when X is a non-empty proper list of conses (a node/subspec)."
  (and (consp x) (proper-list-p x) (cl-every #'consp x)))

(defun jetpacs-lint--node-seq-p (x)
  "Non-nil when X is a non-empty list or vector whose elements are all alists.
This is how children, spans, items, rows, and cells are distinguished
from a single nested node and from plain scalar sequences (a vector of
strings like table `aligns' is not a node sequence)."
  (let ((elts (cond ((vectorp x) (append x nil))
                    ((proper-list-p x) x)
                    (t 'bad))))
    (and (listp elts) elts (cl-every #'jetpacs-lint--alist-p elts))))

(defun jetpacs-lint--serializable-scalar-p (val)
  "Non-nil when VAL is a JSON-serializable scalar.
A string, number, vector, the boolean/null keywords, or nil — the leaf
values `json-serialize' accepts.  Containers and actions are validated by
recursion, not here."
  (or (stringp val) (numberp val) (vectorp val)
      (memq val '(t :false :null)) (null val)))

;; ─── Validation ──────────────────────────────────────────────────────────────

(defun jetpacs-lint--check-action (val path report)
  "Validate embedded action VAL at PATH, reporting via REPORT."
  (if (not (jetpacs-lint--alist-p val))
      (funcall report path (format "action must be an object: %S" val))
    (let ((action (alist-get 'action val))
          (builtin (alist-get 'builtin val))
          (wo (alist-get 'when_offline val))
          (args-cell (assq 'args val)))
      (cond ((and action builtin)
             (funcall report path "action has both `action' and `builtin'"))
            ((and (not action) (not builtin))
             (funcall report path "action has neither `action' nor `builtin'"))
            ((and action (not (stringp action)))
             (funcall report path (format "action name must be a string: %S" action)))
            ((and builtin (not (stringp builtin)))
             (funcall report path (format "builtin name must be a string: %S" builtin))))
      ;; A `builtin' names a companion-local action from a closed set; validate
      ;; the name and the payload keys its kind requires (SPEC §5).
      (when (stringp builtin)
        (let ((spec (assoc builtin jetpacs-lint-action-builtins)))
          (if (not spec)
              (funcall report path (format "unknown builtin: %S" builtin))
            (dolist (req (cdr spec))
              (unless (assq req val)
                (funcall report path
                         (format "builtin %s requires `%s'" builtin req)))))))
      (when (and wo (not (member wo jetpacs-lint--when-offline-values)))
        (funcall report path (format "invalid when_offline: %S" wo)))
      (when (and args-cell (cdr args-cell) (not (jetpacs-lint--alist-p (cdr args-cell))))
        (funcall report path "action `args' must be an object")))))

(defun jetpacs-lint--check-color (key val path report)
  "Validate color attribute KEY=VAL at PATH via REPORT."
  (cond ((not (stringp val))
         (funcall report path (format "%s must be a string: %S" key val)))
        ((and (string-prefix-p "#" val)
              (not (string-match-p "\\`#[0-9A-Fa-f]\\{3,8\\}\\'" val)))
         (funcall report path (format "%s is not a valid hex colour: %S" key val)))))

(defun jetpacs-lint--check-scalar (key val path report)
  "Report at PATH via REPORT when scalar KEY=VAL is not JSON-serializable."
  (unless (jetpacs-lint--serializable-scalar-p val)
    (funcall report path
             (format "%s has a non-serializable value: %S" key val))))

(defun jetpacs-lint--check-toolbar-item (item path report &optional no-menu)
  "Validate toolbar-item vocabulary for ITEM at PATH via REPORT (SPEC §9).
Checks the closed op set — exactly one of snippet/line/on_tap/menu —
and the placement/line enums, recursing into `menu' sub-items and
`long_press' with NO-MENU set (menus don't nest).  Action shape and
scalar serializability are the generic walk's job, not repeated here."
  (if (not (jetpacs-lint--alist-p item))
      (funcall report path (format "toolbar item must be an object: %S" item))
    (let ((ops (cl-remove-if-not (lambda (k) (assq k item))
                                 jetpacs-lint--toolbar-ops)))
      (unless (= (length ops) 1)
        (funcall report path
                 (format "toolbar item needs exactly one of %s, has %s"
                         jetpacs-lint--toolbar-ops (or ops "none"))))
      (when (and no-menu (assq 'menu item))
        (funcall report path "menu cannot nest inside menu or long_press"))
      (when-let ((cell (assq 'placement item)))
        (unless (member (cdr cell) jetpacs-lint--toolbar-placements)
          (funcall report path (format "invalid placement: %S" (cdr cell))))
        (unless (assq 'snippet item)
          (funcall report path "placement is only valid with snippet")))
      (when-let ((cell (assq 'line item)))
        (unless (member (cdr cell) jetpacs-lint--toolbar-line-ops)
          (funcall report path (format "invalid line op: %S" (cdr cell)))))
      (when-let ((menu (cdr (assq 'menu item))))
        (when (jetpacs-lint--node-seq-p menu)
          (let ((i 0))
            (dolist (sub (append menu nil))
              (jetpacs-lint--check-toolbar-item sub (cons i (cons 'menu path))
                                                report t)
              (setq i (1+ i))))))
      (when-let ((lp (cdr (assq 'long_press item))))
        (jetpacs-lint--check-toolbar-item lp (cons 'long_press path)
                                          report t)))))

(defun jetpacs-lint--walk (node path report)
  "Walk NODE at PATH (reversed key list), reporting problems via REPORT."
  (when (assq 't node)
    (let ((type (alist-get 't node)))
      (unless (and (stringp type) (member type jetpacs-lint-node-types))
        (funcall report path (format "unknown or invalid node type: %S" type)))))
  (dolist (pair node)
    (let* ((key (car pair)) (val (cdr pair)) (kpath (cons key path)))
      (cond
       ((eq key 't) nil)
       ((memq key jetpacs-lint--action-keys)
        (jetpacs-lint--check-action val kpath report))
       ;; An editor's data-driven toolbar: vocabulary checks per item, then
       ;; the generic walk for actions and scalar serializability.
       ((and (eq key 'toolbar) (jetpacs-lint--node-seq-p val))
        (let ((i 0))
          (dolist (item (append val nil))
            (jetpacs-lint--check-toolbar-item item (cons i kpath) report)
            (jetpacs-lint--walk item (cons i kpath) report)
            (setq i (1+ i)))))
       ((jetpacs-lint--node-seq-p val)
        (let ((i 0))
          (dolist (child (append val nil))
            (jetpacs-lint--walk child (cons i kpath) report)
            (setq i (1+ i)))))
       ((jetpacs-lint--alist-p val)
        (jetpacs-lint--walk val kpath report))
       ((memq key jetpacs-lint--numeric-attrs)
        (unless (numberp val)
          (funcall report kpath (format "%s must be a number: %S" key val))))
       ((memq key jetpacs-lint--color-attrs)
        (jetpacs-lint--check-color key val kpath report))
       (t (jetpacs-lint--check-scalar key val kpath report))))))

;;;###autoload
(defun jetpacs-lint-spec (spec)
  "Return a list of (PATH . PROBLEM) describing problems in SPEC, nil if clean.
PATH is the root-to-node list of keys (and child indices) locating the
problem; PROBLEM is a human-readable string.  A Tier 1 runs this in its
own ERT tests to keep its views wire-valid without a companion attached."
  (let (problems)
    (if (not (jetpacs-lint--alist-p spec))
        (push (cons nil (format "spec is not a node object: %S" spec)) problems)
      (jetpacs-lint--walk
       spec nil
       (lambda (path msg) (push (cons (reverse path) msg) problems))))
    (nreverse problems)))

;; ─── Headless render harness ─────────────────────────────────────────────────

;;;###autoload
(defun jetpacs-render-to-json (spec &optional object-type)
  "Serialize SPEC to JSON and parse it back — the wire round-trip, headless.
Returns the parsed structure (OBJECT-TYPE defaults to `alist'), which is
exactly what the companion receives, so a Tier 1 can assert on its views
in batch with no phone.  Signals the same error a live push would if SPEC
is not serializable."
  (json-parse-string
   (json-serialize spec :null-object :null :false-object :false)
   :object-type (or object-type 'alist)
   :null-object :null :false-object :false))

;; ─── On-push guard (opt-in) ──────────────────────────────────────────────────

(defcustom jetpacs-lint-on-push nil
  "When non-nil, validate every surface spec before it is sent.
Invalid nodes are replaced in place by a visible error node, so one bad
subtree degrades to a message instead of a blank or dropped push.  Off by
default: it walks the whole tree on every push, needless once a Tier 1 is
known-good.  A development and test aid."
  :type 'boolean :group 'jetpacs)

(defun jetpacs-lint--error-node (msg)
  "An inline error node carrying MSG (an `empty_state')."
  (jetpacs--node "empty_state" 'icon "error" 'title "Invalid UI" 'caption msg))

(defun jetpacs-lint--node-serializable-p (node)
  "Non-nil when NODE's own scalar attributes are JSON-serializable.
Container and action values are validated by recursion, not here."
  (cl-every
   (lambda (pair)
     (let ((key (car pair)) (val (cdr pair)))
       (or (memq key jetpacs-lint--action-keys)
           (jetpacs-lint--node-seq-p val)
           (jetpacs-lint--alist-p val)
           (jetpacs-lint--serializable-scalar-p val))))
   node))

(defun jetpacs-lint-sanitize-spec (node)
  "Return NODE with each structurally-invalid descendant replaced by an error node.
An unknown `t' or a node with a non-serializable own attribute becomes an
`empty_state' error node; valid containers are recursed so only the bad
subtree is lost."
  (cond
   ((not (jetpacs-lint--alist-p node)) node)
   ((let ((ty (and (assq 't node) (alist-get 't node))))
      (and ty (not (and (stringp ty) (member ty jetpacs-lint-node-types)))))
    (jetpacs-lint--error-node (format "unknown node type: %s" (alist-get 't node))))
   ((not (jetpacs-lint--node-serializable-p node))
    (jetpacs-lint--error-node "node has an invalid attribute value"))
   (t
    (mapcar
     (lambda (pair)
       (let ((key (car pair)) (val (cdr pair)))
         (cond
          ((memq key jetpacs-lint--action-keys) pair)
          ((jetpacs-lint--node-seq-p val)
           (cons key (if (vectorp val)
                         (vconcat (mapcar #'jetpacs-lint-sanitize-spec (append val nil)))
                       (mapcar #'jetpacs-lint-sanitize-spec val))))
          ((jetpacs-lint--alist-p val)
           (cons key (jetpacs-lint-sanitize-spec val)))
          (t pair))))
     node))))

;; ─── Declarative view-spec validation ───────────────────────────────────────

(defun jetpacs-lint--plist-keys (plist)
  "The keys of PLIST, in order."
  (let (ks) (while (cdr plist) (push (car plist) ks) (setq plist (cddr plist)))
       (nreverse ks)))

(defun jetpacs-lint--walk-template (node fields path report)
  "Walk template NODE, reporting placeholders that bind outside FIELDS,
unknown transforms, and malformed embedded actions.  PATH is the reversed
key list; REPORT is called with (PATH MESSAGE)."
  (cond
   ((not (jetpacs-lint--alist-p node))
    (when (vectorp node)
      (let ((i 0)) (dolist (x (append node nil))
                     (jetpacs-lint--walk-template x fields (cons i path) report)
                     (setq i (1+ i))))))
   ((assq 'bind node)                   ; a placeholder
    (let ((f (alist-get 'bind node)) (as (alist-get 'as node)))
      (unless (and (stringp f) (member f fields))
        (funcall report path (format "placeholder binds unknown field: %S" f)))
      (when (and as (not (member as jetpacs-lint-spec-transforms)))
        (funcall report path (format "unknown transform: %S" as)))))
   ((or (assq 'action node) (assq 'builtin node))   ; an embedded action
    (jetpacs-lint--check-action node path report)
    (when-let ((args (cdr (assq 'args node))))
      (jetpacs-lint--walk-template args fields (cons 'args path) report)))
   (t                                   ; an ordinary node: walk its attrs
    (dolist (pair node)
      (unless (memq (car pair) '(t args))
        (jetpacs-lint--walk-template (cdr pair) fields (cons (car pair) path) report))))))

;;;###autoload
(defun jetpacs-lint-view-spec (spec fields)
  "Return a list of (PATH . PROBLEM) for declarative view SPEC, nil if clean.
FIELDS is the field-name strings the bound source declares (from
`jetpacs-source-fields'); every `((bind . F))' must name one.  Proves the spec
is closed data referencing only registered fields, transforms, and actions —
the SPEC §5 enforcement point for the binding grammar."
  (let* (problems
         (report (lambda (path msg) (push (cons (reverse path) msg) problems))))
    (if (not (and (listp spec) (plistp spec)))
        (funcall report nil (format "spec is not a plist: %S" spec))
      (let ((ks (jetpacs-lint--plist-keys spec)))
        (dolist (k ks)
          (unless (memq k jetpacs-lint-spec-keys)
            (funcall report (list k) (format "unknown spec key: %s" k))))
        (unless (memq :source ks) (funcall report nil "spec has no :source"))
        (unless (memq :template ks) (funcall report nil "spec has no :template")))
      (unless (stringp (plist-get spec :source))
        (funcall report (list :source) "must be a string"))
      (let ((layout (plist-get spec :layout)))
        (when (and layout (not (member layout jetpacs-lint-spec-layouts)))
          (funcall report (list :layout) (format "unknown layout: %S" layout))))
      (let ((kind (plist-get (plist-get spec :chrome) :kind)))
        (when (and kind (not (member kind jetpacs-lint-spec-chrome-kinds)))
          (funcall report (list :chrome) (format "unknown chrome kind: %S" kind))))
      (let ((gbf (plist-get (plist-get spec :group-by) :field)))
        (when (and gbf (not (member gbf fields)))
          (funcall report (list :group-by) (format "group-by unknown field: %S" gbf))))
      (dolist (key '(:template :header))
        (when (plist-get spec key)
          (jetpacs-lint--walk-template (plist-get spec key) fields (list key) report))))
    (nreverse problems)))

(provide 'jetpacs-lint)
;;; jetpacs-lint.el ends here
