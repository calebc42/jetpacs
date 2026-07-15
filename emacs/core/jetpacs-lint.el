;;; jetpacs-lint.el --- validate SDUI specs before the wire -*- lexical-binding: t; -*-

;; A spec is a tree of alists built by the `jetpacs-widgets.el' constructors
;; and serialized to JSON by `jetpacs--encode'.  A malformed node — an
;; unknown `t', a non-serializable attribute value, a broken action —
;; either renders as nothing on the companion or, worse, makes
;; `json-serialize' throw and blanks the *whole* push.  This module lets a
;; Tier 1 catch those before they reach the wire:
;;
;;   `jetpacs-lint-spec'       — return a list of problems for a spec (nil = clean).
;;   `jetpacs-lint-payload'    — validate a frame kind + payload against the
;;                            kind schema (the frame-level counterpart).
;;   `jetpacs-render-to-json'  — serialize + parse a spec headless (the wire
;;                            round-trip, so views are testable with no phone).
;;   `jetpacs-lint-on-push'    — when set, `jetpacs-surface-update' replaces each
;;                            invalid node in place with a visible error node,
;;                            so one bad subtree degrades instead of the push.
;;
;; The known-type list is the same vocabulary as `SDUI_NODE_TYPES'
;; (SduiRenderer.kt) and `test/widgets.golden'; the drift test
;; `jetpacs-lint-types-cover-golden' fails if a constructor emits a `t' not
;; listed here.  Since Spec 1.0-rc the tables below also carry the authored
;; per-node key schema (`jetpacs-lint-node-schema') and the frame-kind
;; schema (`jetpacs-lint-kind-schema'); `build-contract.el' publishes both
;; in docs/contract.json (contract_format 2) for non-elisp implementations.

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
    "icon_button" "chip" "assist_chip" "badge" "text_input" "editor" "checkbox"
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

(defconst jetpacs-lint--notification-action-keys '(label on_tap icon dismiss input)
  "Keys a notification `meta.actions' entry may carry (SPEC §9).
An entry is required to carry `label' and `on_tap'; `input' is the inline
text-reply sub-object `{hint?, key?}'.")

(defconst jetpacs-lint-action-fields '(action builtin args when_offline dedupe)
  "The fields an action object may carry (SPEC §5).
`action' and `builtin' are mutually exclusive; a `builtin' additionally
carries the payload keys its kind requires (`jetpacs-lint-action-builtins').")

(defconst jetpacs-lint--when-offline-values '("queue" "drop" "wake")
  "Valid `when_offline' queue policies (SPEC §5); the default is \"queue\".")

(defconst jetpacs-lint-state-predicate-types
  '("airplane" "battery.level" "bluetooth.enabled" "calendar.event"
    "call.state" "headset" "network" "power" "screen" "time.window"
    "wifi.enabled")
  "State-predicate types a trigger `when' gate may reference (SPEC §11).
Mirrors StateSampler.kt's STATE_TYPES; extend both (and SPEC §11's
predicate table) together.  Lint-time advisory only: the live
negotiation authority is the welcome's `device.state_types' report
\(`jetpacs-triggers--when-supported-p'), never this list.")

(defconst jetpacs-lint--predicate-fields
  '(("power"             state)
    ("battery.level"     above below)
    ("screen"            state)
    ("airplane"          state)
    ("network"           transport)
    ("headset"           state)
    ("time.window"       after before days)
    ("wifi.enabled"      enabled)
    ("bluetooth.enabled" enabled)
    ("calendar.event"    calendar title_contains)
    ("call.state"        state))
  "Match fields each state-predicate type may carry (SPEC §11).")

(defconst jetpacs-lint--time-window-re
  "\\`\\(?:[01]?[0-9]\\|2[0-3]\\):[0-5][0-9]\\'"
  "The \"HH:MM\" grammar of a `time.window' bound.")

(defconst jetpacs-lint--day-names '("mon" "tue" "wed" "thu" "fri" "sat" "sun")
  "The `time.window' `days' vocabulary (SPEC §11).")

(defconst jetpacs-lint--placeholder-re
  "\\${\\(?:id\\|type\\|data\\.[A-Za-z0-9_]+\\)}"
  "The on_fire placeholder token grammar (SPEC §11 / §9): `${id}',
`${type}', `${data.FIELD}'.  A `${…}' outside this grammar is left
literal by the companion — almost always a typo worth a warning.")

(defconst jetpacs-lint-action-builtins
  '(("view.switch" view)
    ("clipboard.copy" text)
    ("jetpacs.settings.open"))
  "Companion-local builtins → the payload keys each requires (SPEC §5).
Each entry is (NAME . REQUIRED-KEYS): an action object using `builtin'
must name one of these and carry every listed key.  `build-contract.el'
derives the discriminated action schema in `contract.json' from this.")

(defconst jetpacs-lint-node-common-keys '(scroll_here dialog_style)
  "Keys legal on any node, attached after construction.
`scroll_here' marks a lazy_column child as its scroll target
\(`jetpacs-scroll-here', SPEC §9); `dialog_style' rides a dialog spec's
root node (`jetpacs-send-dialog', SPEC §7).")

(defconst jetpacs-lint-node-schema
  ;; (TYPE REQUIRED-KEYS OPTIONAL-KEYS) — one row per entry of
  ;; `jetpacs-lint-node-types', same order.
  '(("text"            (text)               (style weight color selectable
                                             max_lines padding syntax))
    ("rich_text"       (spans)              (style padding))
    ("row"             (children)           (spacing align scroll weight fill))
    ("flow_row"        (children)           (spacing run_spacing))
    ("column"          (children)           (spacing align scroll weight fill))
    ("box"             (children)           (alignment padding weight on_tap
                                             width height fill_fraction border))
    ("surface"         (children)           (color shape elevation padding fill
                                             width height fill_fraction border))
    ("lazy_column"     (children)           ())
    ("spacer"          ()                   (height width weight))
    ("divider"         ()                   ())
    ("card"            (children)           (on_tap on_swipe swipe_start
                                             swipe_end padding weight width
                                             height fill_fraction border))
    ("collapsible"     (id header children) (collapsed on_long_tap on_swipe))
    ("reorderable_list" (items)             (on_reorder))
    ("table"           (rows)               (aligns on_add_row on_add_col
                                             padding))
    ("tabs"            (items children)     (initial scrollable pager_only
                                             on_change id))
    ("chart"           (series)             (kind height y_range summary
                                             on_point_tap))
    ("canvas"          (width height ops)   ())
    ("month_grid"      (month)              (marks selected min_month max_month
                                             on_day_tap on_month_change))
    ("icon"            (name)               (size color padding badge))
    ("image"           (url)                (content_description padding width
                                             height aspect_ratio content_scale))
    ("date_stamp"      ()                   (day month month_index year time
                                             padding))
    ("section_header"  (title)              (trailing padding))
    ("empty_state"     ()                   (icon title caption on_tap
                                             action_label padding))
    ("progress"        ()                   (variant value padding))
    ("menu"            (items)              (icon padding))
    ("button"          (label on_tap)       (icon variant weight padding))
    ("icon_button"     (icon on_tap)        (content_description padding badge))
    ("chip"            (label)              (on_tap selected icon padding))
    ("assist_chip"     (label)              (on_tap icon padding))
    ("badge"           (label)              (icon color padding children))
    ("text_input"      (id)                 (value hint label on_submit
                                             single_line min_lines max_lines
                                             monospace syntax password keyboard
                                             padding))
    ("editor"          (id)                 (value on_save read_only syntax
                                             line_numbers complete chromeless
                                             publish_state toolbar))
    ("checkbox"        (id)                 (checked label on_change padding))
    ("switch"          (id)                 (checked label on_change padding))
    ("enum_list"       (id options)         (value multi_select allow_add
                                             on_change padding))
    ("date_button"     (label on_pick)      (value))
    ("time_button"     (label on_pick)      (value))
    ("slider"          (id on_change)       (value min max steps))
    ("scaffold"        ()                   (top_bar fab body bottom_bar
                                             floating_toolbar snackbar
                                             snackbar_action drawer on_refresh)))
  "Per-node key schema: (TYPE REQUIRED OPTIONAL), one row per node type.
Authored from `test/widgets.golden' ∪ the `jetpacs-widgets.el' constructor
signatures, hand-reviewed against WIDGETS.md and SPEC §9 (the review is
SPEC-CHANGES.md entry #1).  `jetpacs-lint-spec' reports a missing REQUIRED
key as an error and a key outside the row (and outside
`jetpacs-lint-node-common-keys') as a warning — a warning, not an error,
because companions must ignore unknown keys (the §9 forward-compat rule),
so an author may deliberately target a newer companion.  Value types are
not re-declared here: the numeric/color/action key classes above apply by
key name.  `build-contract.el' publishes this as `node_schema'.")

(defconst jetpacs-lint-kind-schema
  ;; (KIND DIRECTION REQUIRED OPTIONAL) | (KIND DIRECTION node)
  ;; DIRECTION: who sends it — `client' (Emacs), `companion', or `both'.
  ;; `node' marks a payload that is a §9 node tree rather than a fixed
  ;; key set.
  '(;; Handshake (SPEC §3)
    ("session.hello"    client    (protocol client wants) (features))
    ("auth.challenge"   companion (nonce)                 ())
    ("auth.response"    client    (nonce mac)             ())
    ("session.welcome"  companion (server_proof granted node_types surfaces
                                   queued_events)
                                                          (protocol server
                                                           device))
    ;; Envelope-level (SPEC §2)
    ("ack"              both      ()                      ())
    ("error"            both      (code)                  (detail perm settings))
    ("ping"             both      ()                      ())
    ("pong"             both      ()                      ())
    ;; Surfaces, events, offline queue (SPEC §4–§6)
    ("surface.update"   client    (surface revision spec) (ttl_s stale_spec
                                                           current_view))
    ("surface.remove"   client    (surface)               ())
    ("event.action"     companion (action)                (args surface
                                                           revision_seen fields
                                                           queued_at))
    ("state.changed"    companion (id value)              ())
    ("queue.replay"     client    ()                      ())
    ("queue.drained"    companion (delivered expired)     (duplicate_request))
    ;; Dialogs, toasts, pies, reminders, theme (SPEC §7)
    ("dialog.show"      client    node)
    ("dialog.dismiss"   client    ()                      ())
    ("pie_menu.show"    client    (categories)            (center_label buffer))
    ("pie_menu.dismiss" client    ()                      ())
    ("toast.show"       client    (text)                  ())
    ("reminders.set"    client    (reminders)             (owner))
    ("theme.set"        client    ()                      (dark colors syntax))
    ;; Editor sync & completion (SPEC §8).  The companion→client legs
    ;; (edit.open/delta/caret/close/complete) are §5 actions riding
    ;; `event.action', not frame kinds — only the client→companion legs
    ;; appear here.
    ("completions.show" client    (id request_id prefix candidates) ())
    ("diagnostics.show" client    (id session seq diags)  ())
    ("eldoc.show"       client    (id session text)       ())
    ("fontify.show"     client    (id session seq runs)   ())
    ("edit.resync"      client    (id session)            ())
    ;; Device capabilities & triggers (SPEC §10–§11)
    ("capability.invoke" client   (cap)                   (args))
    ("capability.result" companion (ok)                   (result))
    ("triggers.set"      client   (triggers)              ()))
  "Frame-kind schema: kind → sender direction + payload keys.
Mirrors `Kind' in Envelope.kt and the frame vocabulary of SPEC §§2–8,
10–11, authored from the reference implementations' actual send sites.
`jetpacs-lint-payload' enforces it (missing required = error, unknown
key = warning); `build-contract.el' publishes it as `kind_schema'.
Action names (§5 registry entries, e.g. `trigger.fired', `edit.open')
are deliberately NOT enumerated — they are negotiated vocabulary, not
frame kinds.")

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

(defun jetpacs-lint--check-notification-action (entry path report)
  "Validate a notification `meta.actions' ENTRY at PATH via REPORT (SPEC §9).
Enforces the required `label'/`on_tap' and warns on a key outside the
vocabulary; the embedded `on_tap' action and the `input' sub-object are
left to the generic walk (`on_tap' is an action key; `input' recurses)."
  (if (not (jetpacs-lint--alist-p entry))
      (funcall report path (format "notification action must be an object: %S" entry))
    (unless (assq 'label entry)
      (funcall report path "notification action missing required `label'"))
    (unless (assq 'on_tap entry)
      (funcall report path "notification action missing required `on_tap'"))
    (dolist (pair entry)
      (unless (memq (car pair) jetpacs-lint--notification-action-keys)
        (funcall report path
                 (format "warning: unknown key `%s' on notification action"
                         (car pair)))))
    (when-let ((input (cdr (assq 'input entry))))
      (when (jetpacs-lint--alist-p input)
        (dolist (pair input)
          (unless (memq (car pair) '(hint key))
            (funcall report path
                     (format "warning: unknown key `%s' on notification action `input'"
                             (car pair)))))))))

(defun jetpacs-lint--check-schema (node type path report)
  "Enforce TYPE's key schema on NODE at PATH via REPORT (SPEC §9).
A missing required key is an error; a key outside the schema row (and
outside `jetpacs-lint-node-common-keys') is a \"warning: \"-prefixed
problem — companions ignore unknown keys, so an extra key may be a
deliberate newer-companion target, but is more often a typo."
  (when-let ((schema (assoc type jetpacs-lint-node-schema)))
    (dolist (req (nth 1 schema))
      (unless (assq req node)
        (funcall report path (format "%s: missing required `%s'" type req))))
    (dolist (pair node)
      (let ((key (car pair)))
        (unless (or (eq key 't)
                    (memq key (nth 1 schema))
                    (memq key (nth 2 schema))
                    (memq key jetpacs-lint-node-common-keys))
          (funcall report path
                   (format "warning: unknown key `%s' on %s" key type)))))))

(defun jetpacs-lint--fills-row-p (child)
  "Non-nil when CHILD, as a non-terminal `row' child, swallows the row.
A `row'/`column' renders `fillMaxWidth'; without a `weight' to bound it (and
when not itself a horizontally scrolling row), it fills the row and pushes
later siblings off-screen."
  (and (jetpacs-lint--alist-p child)
       (member (alist-get 't child) '("row" "column"))
       (not (alist-get 'weight child))
       (not (alist-get 'scroll child))))

(defun jetpacs-lint--check-row-layout (node path report)
  "Warn when NODE (a `row') has a non-terminal unweighted `row'/`column' child.
That child fills the row and pushes the trailing children off-screen — the
fix is a :weight on the flexible child, a weighted `jetpacs-box', or
`jetpacs-list-item'.  A scrolling row keeps its children intrinsic, so it is
exempt."
  (unless (alist-get 'scroll node)
    (let* ((children (append (alist-get 'children node) nil))
           (last-i (1- (length children)))
           (i 0))
      (dolist (child children)
        (when (and (< i last-i) (jetpacs-lint--fills-row-p child))
          (funcall report (cons i (cons 'children path))
                   (format (concat "warning: unweighted %s before trailing children "
                                   "fills the row and pushes them off-screen — give "
                                   "the flexible child :weight, wrap it in a weighted "
                                   "`jetpacs-box', or use `jetpacs-list-item'")
                           (alist-get 't child))))
        (setq i (1+ i))))))

(defun jetpacs-lint--walk (node path report)
  "Walk NODE at PATH (reversed key list), reporting problems via REPORT."
  (when (assq 't node)
    (let ((type (alist-get 't node)))
      (if (not (and (stringp type) (member type jetpacs-lint-node-types)))
          (funcall report path (format "unknown or invalid node type: %S" type))
        (jetpacs-lint--check-schema node type path report)
        (when (equal type "row")
          (jetpacs-lint--check-row-layout node path report)))))
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
       ;; `actions' is overloaded: a notification's `meta.actions' entries
       ;; (SPEC §9) carry no `t' and get the action-button vocabulary check;
       ;; a chrome `actions' array (top_bar) holds ordinary `t'-tagged nodes
       ;; and is just walked.  The generic walk runs for both either way.
       ((and (eq key 'actions) (jetpacs-lint--node-seq-p val))
        (let ((i 0))
          (dolist (entry (append val nil))
            (unless (assq 't entry)
              (jetpacs-lint--check-notification-action entry (cons i kpath) report))
            (jetpacs-lint--walk entry (cons i kpath) report)
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

;;;###autoload
(defun jetpacs-lint-payload (kind payload)
  "Return a list of (PATH . PROBLEM) for a frame's KIND and PAYLOAD alist.
nil = clean.  The frame-kind half of the schema registry: KIND must be
registered in `jetpacs-lint-kind-schema', PAYLOAD must carry the kind's
required keys (errors), and a key outside the schema is a \"warning: \"-
prefixed problem.  A kind whose payload is a §9 node tree
\(`dialog.show') is validated with `jetpacs-lint-spec'.  PAYLOAD nil
means an empty payload."
  (let* ((entry (assoc kind jetpacs-lint-kind-schema))
         problems
         (report (lambda (path msg) (push (cons path msg) problems))))
    (cond
     ((not entry)
      (funcall report nil (format "unknown frame kind: %S" kind)))
     ((eq (nth 2 entry) 'node)
      (setq problems (reverse (jetpacs-lint-spec payload))))
     ((and payload (not (jetpacs-lint--alist-p payload)))
      (funcall report nil (format "payload must be an object: %S" payload)))
     (t
      (dolist (req (nth 2 entry))
        (unless (assq req payload)
          (funcall report (list req)
                   (format "%s: missing required `%s'" kind req))))
      (dolist (pair payload)
        (let ((key (car pair)))
          (unless (or (memq key (nth 2 entry)) (memq key (nth 3 entry)))
            (funcall report (list key)
                     (format "warning: unknown payload key `%s' on %s"
                             key kind)))))))
    (nreverse problems)))

;; ─── Trigger registrations (SPEC §11) ────────────────────────────────────────

(defun jetpacs-lint--check-predicate (p path report)
  "Validate state predicate P at PATH via REPORT (SPEC §11)."
  (if (not (jetpacs-lint--alist-p p))
      (funcall report path (format "predicate must be an object: %S" p))
    (let* ((type (alist-get 'type p))
           (row (assoc type jetpacs-lint--predicate-fields)))
      (cond
       ((not (stringp type))
        (funcall report path "predicate missing `type'"))
       ((not (member type jetpacs-lint-state-predicate-types))
        (funcall report path (format "unknown state-predicate type: %S" type))))
      (when row
        (dolist (pair p)
          (unless (or (eq (car pair) 'type) (memq (car pair) (cdr row)))
            (funcall report path
                     (format "warning: unknown key `%s' on %s predicate"
                             (car pair) type)))))
      (pcase type
        ("battery.level"
         (unless (or (assq 'above p) (assq 'below p))
           (funcall report path "battery.level needs `above' or `below'")))
        ("time.window"
         (dolist (bound '(after before))
           (when-let ((v (alist-get bound p)))
             (unless (and (stringp v)
                          (string-match-p jetpacs-lint--time-window-re v))
               (funcall report path
                        (format "`%s' must be \"HH:MM\": %S" bound v)))))
         (when-let ((days (alist-get 'days p)))
           (dolist (d (append days nil))
             (unless (member d jetpacs-lint--day-names)
               (funcall report path (format "unknown day: %S" d))))))))))

(defun jetpacs-lint--check-placeholders (val path report)
  "Warn via REPORT about `${…}' tokens in VAL outside the SPEC §11 grammar.
Recurses over strings, alists, and sequences the way the companion's
interpolation does."
  (cond
   ((stringp val)
    (let ((start 0))
      (while (string-match "\\${[^}]*}" val start)
        (let ((token (match-string 0 val)))
          (unless (string-match-p
                   (concat "\\`" jetpacs-lint--placeholder-re "\\'") token)
            (funcall report path
                     (format "warning: placeholder %s is outside the \
${id}/${type}/${data.FIELD} grammar and will stay literal" token))))
        (setq start (match-end 0)))))
   ((jetpacs-lint--alist-p val)
    (dolist (pair val)
      (jetpacs-lint--check-placeholders (cdr pair) (cons (car pair) path)
                                        report)))
   ((or (vectorp val) (proper-list-p val))
    (let ((i 0))
      (dolist (x (append val nil))
        (jetpacs-lint--check-placeholders x (cons i path) report)
        (setq i (1+ i)))))))

(defun jetpacs-lint--check-on-fire-entry (entry path report)
  "Validate one on_fire ENTRY at PATH via REPORT (SPEC §11)."
  (if (not (jetpacs-lint--alist-p entry))
      (funcall report path (format "on_fire entry must be an object: %S" entry))
    (let ((cap (assq 'cap entry)) (notify (assq 'notify entry)))
      (cond
       ((and cap notify)
        (funcall report path "on_fire entry has both `cap' and `notify'"))
       ((and (not cap) (not notify))
        (funcall report path "on_fire entry has neither `cap' nor `notify'")))
      ;; The cap NAME never interpolates (§11) — a token there is a bug,
      ;; not a dynamic dispatch.
      (when (and cap (stringp (cdr cap))
                 (string-match-p "\\${" (cdr cap)))
        (funcall report path "`cap' names never interpolate — no ${…} here"))
      (when-let ((args (cdr (assq 'args entry))))
        (jetpacs-lint--check-placeholders args (cons 'args path) report))
      (when notify
        (jetpacs-lint--check-placeholders (cdr notify) (cons 'notify path)
                                          report)))))

;;;###autoload
(defun jetpacs-lint-trigger (spec)
  "Return a list of (PATH . PROBLEM) for trigger registration SPEC, nil if clean.
SPEC is one wire-shaped `triggers.set' entry alist (what
`jetpacs-triggers--specs' emits): `id'/`type' plus the optional
`params', `when', `policy', `dedupe', `throttle_s', `on_fire'.
Advisory and lint/CI-time, like `jetpacs-lint-spec': it validates the
`when' predicate shapes against `jetpacs-lint-state-predicate-types',
the on_fire exactly-one-of `cap'/`notify' rule, and the `${…}'
placeholder grammar.  The live push negotiates against the session
reports instead (`jetpacs-triggers--supported-p' and
`jetpacs-triggers--when-supported-p')."
  (let* (problems
         (report (lambda (path msg) (push (cons (reverse path) msg) problems))))
    (if (not (jetpacs-lint--alist-p spec))
        (funcall report nil (format "registration is not an object: %S" spec))
      (unless (stringp (alist-get 'id spec))
        (funcall report '(id) "missing or non-string `id'"))
      (unless (stringp (alist-get 'type spec))
        (funcall report '(type) "missing or non-string `type'"))
      (when-let ((policy (alist-get 'policy spec)))
        (unless (member policy jetpacs-lint--when-offline-values)
          (funcall report '(policy) (format "invalid policy: %S" policy))))
      (when-let ((gate (alist-get 'when spec)))
        (let ((i 0))
          (dolist (p (append gate nil))
            (jetpacs-lint--check-predicate p (list i 'when) report)
            (setq i (1+ i)))))
      (when-let ((on-fire (alist-get 'on_fire spec)))
        (let ((i 0))
          (dolist (entry (append on-fire nil))
            (jetpacs-lint--check-on-fire-entry entry (list i 'on_fire) report)
            (setq i (1+ i))))))
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

;; ─── Tier-1 test helpers ─────────────────────────────────────────────────────
;; Every Tier 1 re-derived these two in a private test library (grocy had
;; `grocy-test--collect-text' and `grocy-test--view-clean'); ship them so an
;; app's ERT suite is a couple of lines, not a helper file.

(defconst jetpacs-lint--visible-text-keys '(text label title caption hint)
  "Node keys whose string value is user-visible on-screen text.
The set `jetpacs-test-visible-text' harvests.")

(defun jetpacs-lint--collect-visible (node collect)
  "Call COLLECT on each user-visible string in NODE, depth-first."
  (when (jetpacs-lint--alist-p node)
    (dolist (pair node)
      (let ((key (car pair)) (val (cdr pair)))
        (cond
         ((and (memq key jetpacs-lint--visible-text-keys) (stringp val))
          (funcall collect val))
         ((jetpacs-lint--node-seq-p val)
          (dolist (child (append val nil))
            (jetpacs-lint--collect-visible child collect)))
         ((jetpacs-lint--alist-p val)
          (jetpacs-lint--collect-visible val collect)))))))

;;;###autoload
(defun jetpacs-test-visible-text (spec)
  "Return the user-visible text strings in SPEC, in depth-first tree order.
Harvests the string value of every visible-text key (`text', `label',
`title', `caption', `hint') across the node tree, so a Tier 1 can assert its
view shows (or omits) a string without a companion — e.g.
\(should (member \"Milk\" (jetpacs-test-visible-text view))).  An additive
node's self-describing fallback (the `badge' label child) may repeat its
label; membership tests are unaffected."
  (let (out)
    (jetpacs-lint--collect-visible spec (lambda (s) (push s out)))
    (nreverse out)))

;;;###autoload
(defun jetpacs-test-view-ok (spec)
  "Assert SPEC is a wire-valid view: lint-error-free AND serializable.
Signals a descriptive `error' listing the lint errors, or re-signals the
serialization error, on failure; returns t on success.  The one-call view
check for a Tier 1's ERT suite — call it bare, and its failure fails the
test: (jetpacs-test-view-ok (my-app-view nil)).  Warnings (the forward-compat
`warning:'-prefixed problems, e.g. the row flex-trap heuristic) do not fail
it — inspect the full list with `jetpacs-lint-spec' when you want those too."
  (let ((errors (cl-remove-if
                 (lambda (p) (string-prefix-p "warning: " (cdr p)))
                 (jetpacs-lint-spec spec))))
    (when errors
      (error "jetpacs-test-view-ok: %d lint error(s): %s"
             (length errors)
             (mapconcat (lambda (p) (format "%s @ %S" (cdr p) (car p)))
                        errors "; ")))
    (jetpacs-render-to-json spec)       ; signals on an unserializable tree
    t))

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
