;;; jetpacs-widgets.el --- Jetpacs SDUI widget constructors -*- lexical-binding: t; -*-

;; Provides all UI-tree constructors for Jetpacs surfaces.
;; These functions build the alists that are serialized to JSON.
;;
;; Every constructor funnels through `jetpacs--node': type + (KEY VALUE)
;; pairs, where nil values are dropped.  That one rule replaces the old
;; per-constructor `(when x (push …))' boilerplate and keeps the wire
;; format in a single, greppable place per widget.

;;; Code:

(require 'cl-lib)

(defun jetpacs--node (type &rest kvs)
  "Build a widget node alist of TYPE from KVS (alternating KEY VALUE).
Pairs whose VALUE is nil are omitted, so optional attributes read as
plain arguments at the call site.  TYPE nil builds a bare alist (used
by sub-specs like actions, drawer items, and top bars that carry no
`t' discriminator)."
  (let (pairs)
    (while kvs
      (let ((k (pop kvs)) (v (pop kvs)))
        (when v (push (cons k v) pairs))))
    (if type
        (cons (cons 't type) (nreverse pairs))
      (nreverse pairs))))

;; ─── Core & Layout ───────────────────────────────────────────────────────────

(defun jetpacs--children-and-opts (args)
  "Split ARGS into (CHILDREN . OPTS) at the first keyword in ARGS.
Child nodes are alists, never keywords, so the first keyword in ARGS
marks the start of a trailing options plist.  Lets the `&rest'-children
constructors take options without breaking `(jetpacs-row a b c)' callers."
  (let ((i (cl-position-if #'keywordp args)))
    (if i (cons (cl-subseq args 0 i) (cl-subseq args i))
      (cons args nil))))

(defun jetpacs--node-p (x)
  "Non-nil when X looks like a widget node or sub-spec: a proper alist whose
every element is a cons.  A real node's own pairs are dotted (`(t . \"row\")'),
so a node is never itself a list *of* nodes — which is what lets
`jetpacs--as-children' tell a single node from a list of children."
  (and (consp x) (proper-list-p x) (cl-every #'consp x)))

(defun jetpacs--as-children (args)
  "Normalize container ARGS to a flat child list, dropping nils.
Accepts the nodes as `&rest' — `(NODE NODE …)' — or the legacy single
list-of-nodes argument — `((NODE NODE …))' (or a lone nil for none): a
one-element ARGS whose sole element is itself a list of nodes (or nil) is
unwrapped.  So `(jetpacs-card (list a b))' and `(jetpacs-card a b)' mean the
same thing — the children-API consistency fix (issue #9)."
  (let ((kids (if (and (consp args) (null (cdr args))
                       (let ((only (car args)))
                         (or (null only)
                             (and (proper-list-p only)
                                  (cl-every #'jetpacs--node-p only)))))
                  (car args)
                args)))
    (remq nil kids)))

(defun jetpacs-text (text &rest args)
  "A text node whose options are positional or keyword (keywords win).
ARGS is STYLE WEIGHT COLOR SELECTABLE MAX-LINES PADDING positionally, or the
same names as trailing keywords :style :weight :color :selectable :max-lines
:padding — so a color needs no positional nils: `(jetpacs-text s :color
\"#fff\")' rather than `(jetpacs-text s nil nil \"#fff\")' (issue #10).
STYLE is title/headline/body/caption/label; WEIGHT is the layout weight;
COLOR is a hex string."
  (let* ((split (jetpacs--children-and-opts args))
         (pos  (car split))
         (opts (cdr split))
         (style      (or (plist-get opts :style)      (nth 0 pos)))
         (weight     (or (plist-get opts :weight)     (nth 1 pos)))
         (color      (or (plist-get opts :color)      (nth 2 pos)))
         (selectable (or (plist-get opts :selectable) (nth 3 pos)))
         (max-lines  (or (plist-get opts :max-lines)  (nth 4 pos)))
         (padding    (or (plist-get opts :padding)    (nth 5 pos))))
    (jetpacs--node "text"
                'text text
                'style (and style (format "%s" style))
                'weight weight
                'color color
                'selectable (and selectable t)
                'max_lines max-lines
                'padding padding)))

(cl-defun jetpacs-markup (text &key syntax style padding)
  "A read-only TEXT node with optional client-side highlighting.
SYNTAX (\"org\", \"elisp\") turns on the highlighter; STYLE is the same set
as `jetpacs-text'. Use this for displaying code/org content; for plain labels
use `jetpacs-text'."
  (jetpacs--node "text"
              'text text
              'syntax (and syntax (format "%s" syntax))
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun jetpacs-rich-text (spans &key style padding)
  "A rich-text node rendering SPANS (a list from `jetpacs-span').
Use this for org content Emacs has already parsed into styled runs —
emphasis, links, and #tags render natively rather than as highlighted
monospace. STYLE is the base text style (title/body/caption/label)."
  (jetpacs--node "rich_text"
              'spans (vconcat spans)
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun jetpacs-span (text &key bold italic underline strike code tag baseline color bg on-tap mono)
  "A styled text run for `jetpacs-rich-text'.
BOLD/ITALIC/UNDERLINE/STRIKE/CODE toggle emphasis; TAG themes it like a
#hashtag; BASELINE is \"super\" or \"sub\"; COLOR is a hex foreground
override and BG a hex background (diff shading, hl-line, region, isearch);
ON-TAP makes it a clickable link.  MONO renders the run in a fixed-width
font without the code-styling background — used by the generic buffer
renderer to preserve column alignment (dired, magit, tables, ascii)."
  (jetpacs--node nil
              'text text
              'bold (and bold t)
              'italic (and italic t)
              'underline (and underline t)
              'strike (and strike t)
              'code (and code t)
              'tag (and tag t)
              'baseline baseline
              'color color
              'bg bg
              'on_tap on-tap
              'mono (and mono t)))

(defun jetpacs-row (&rest args)
  "A horizontal row of child nodes.
ARGS is child nodes, optionally followed by keywords: :spacing (dp
between children), :align (cross-axis \"top\"/\"center\"/\"bottom\"),
:scroll (pan sideways on overflow), :weight (this row's own flex share
when it is itself a child of a `row'/`column'), :fill (nil to wrap
content instead of filling the parent width), and :key (a stable string
identity for this row as a `lazy_column' child — reconciliation keeps
its client-side state, scroll anchor, and animation across pushes that
insert/remove/reorder rows; SPEC §9).

Layout note: a `row'/`column' renders `fillMaxWidth', so an *unweighted* one
placed inside a row fills it and pushes the later siblings off-screen.  Give
the flexible child a :weight — or use `jetpacs-list-item' — so trailing
children keep their width; or pass `:fill nil' to a nested container that
should size to its content (see WIDGETS.md)."
  (let* ((split (jetpacs--children-and-opts args))
         (opts (cdr split)))
    (jetpacs--node "row"
                'children (vconcat (remq nil (car split)))
                'spacing (plist-get opts :spacing)
                'align (plist-get opts :align)
                'scroll (and (plist-get opts :scroll) t)
                'weight (plist-get opts :weight)
                'key (plist-get opts :key)
                ;; Default is fill (renderer default); emit only the opt-out.
                'fill (and (plist-member opts :fill)
                           (not (plist-get opts :fill)) :false))))

(defun jetpacs-flow-row (&rest args)
  "A horizontal row of children that wraps onto new lines when full.
The right container for chip/tag rows, which overflow a plain `jetpacs-row'.
Optional trailing keywords: :spacing and :run-spacing (dp)."
  (let* ((split (jetpacs--children-and-opts args)))
    (jetpacs--node "flow_row"
                'children (vconcat (remq nil (car split)))
                'spacing (plist-get (cdr split) :spacing)
                'run_spacing (plist-get (cdr split) :run-spacing))))

(defun jetpacs-scroll-row (&rest children)
  "A horizontal row of CHILDREN that pans sideways when it overflows.
The single-line counterpart to `jetpacs-flow-row' (which wraps instead):
use it for chip rails that must stay on one row.  Child weights are
ignored — a scrolling row has no bounded width to distribute."
  (jetpacs--node "row" 'children (vconcat children) 'scroll t))

(defun jetpacs-column (&rest args)
  "A vertical column of child nodes.
ARGS is child nodes, optionally followed by keywords: :spacing (dp
between children), :align (cross-axis \"start\"/\"center\"/\"end\"),
:scroll (make the column scroll vertically), :weight (this column's own
flex share when it is a child of a `row'/`column'), :fill (nil to wrap
content instead of filling the parent width), and :key (a stable string
identity for this column as a `lazy_column' child — see `jetpacs-row';
SPEC §9).

Layout note: a `column' renders `fillMaxWidth', so an *unweighted* one placed
inside a row fills it and pushes the later siblings off-screen — give it
:weight, pass `:fill nil' to size it to its content, or use
`jetpacs-list-item' (see WIDGETS.md)."
  (let* ((split (jetpacs--children-and-opts args))
         (opts (cdr split)))
    (jetpacs--node "column"
                'children (vconcat (remq nil (car split)))
                'spacing (plist-get opts :spacing)
                'align (plist-get opts :align)
                'scroll (and (plist-get opts :scroll) t)
                'weight (plist-get opts :weight)
                'key (plist-get opts :key)
                'fill (and (plist-member opts :fill)
                           (not (plist-get opts :fill)) :false))))

(defun jetpacs-scroll-column (&rest children)
  "A vertically scrollable column of CHILDREN nodes."
  (jetpacs--node "column" 'children (vconcat children) 'scroll t))

(cl-defun jetpacs-border (&key (width 1) color)
  "A border spec of WIDTH dp in COLOR (hex or theme token).
Pass as the :border of `jetpacs-box' / `jetpacs-surface' / `jetpacs-card'."
  (jetpacs--node nil 'width width 'color color))

(defun jetpacs-box (&rest args)
  "A Box wrapping child nodes.
CHILDREN are the nodes as `&rest' or a single list of nodes (both forms
accepted — issue #9), optionally followed by keywords: :alignment,
:padding, :weight, :on-tap, :width, :height, :fill-fraction (0.0-1.0 of
the parent width), :border (an `jetpacs-border' spec), and :key (a stable
string identity for this box as a `lazy_column' child — see `jetpacs-row';
SPEC §9).  WIDTH/HEIGHT fix the box size (dp)."
  (let* ((split (jetpacs--children-and-opts args))
         (opts (cdr split)))
    (jetpacs--node "box"
                'children (vconcat (jetpacs--as-children (car split)))
                'key (plist-get opts :key)
                'alignment (plist-get opts :alignment)
                'padding (plist-get opts :padding)
                'weight (plist-get opts :weight)
                'on_tap (plist-get opts :on-tap)
                'width (plist-get opts :width)
                'height (plist-get opts :height)
                'fill_fraction (plist-get opts :fill-fraction)
                'border (plist-get opts :border))))

(defun jetpacs-surface (&rest args)
  "A Surface wrapping child nodes.
CHILDREN are the nodes as `&rest' or a single list of nodes (both forms
accepted — issue #9), optionally followed by keywords.  :color is a hex
string or a theme token (\"primary\", \"surface_container\",
\"primary_container\", …) that adapts to the device's light/dark theme.
:shape is \"rounded\", \"rounded_small\", or \"circle\".  :fill stretches the
surface to full width (e.g. zebra rows in a list).  :width/:height fix the
size (dp), :fill-fraction (0.0-1.0) sets a fraction of parent width, and
:border is an `jetpacs-border' spec stroked with :shape.  :elevation and
:padding as named.  :key is a stable string identity for this surface as
a `lazy_column' child — see `jetpacs-row'; SPEC §9."
  (let* ((split (jetpacs--children-and-opts args))
         (opts (cdr split)))
    (jetpacs--node "surface"
                'children (vconcat (jetpacs--as-children (car split)))
                'key (plist-get opts :key)
                'color (plist-get opts :color)
                'shape (plist-get opts :shape)
                'elevation (plist-get opts :elevation)
                'padding (plist-get opts :padding)
                'fill (and (plist-get opts :fill) t)
                'width (plist-get opts :width)
                'height (plist-get opts :height)
                'fill_fraction (plist-get opts :fill-fraction)
                'border (plist-get opts :border))))

(defun jetpacs-lazy-column (&rest children)
  "A scrollable column of CHILDREN."
  (jetpacs--node "lazy_column" 'children (vconcat children)))

(defun jetpacs-scroll-here (node)
  "Mark NODE as the scroll target of its enclosing `jetpacs-lazy-column'.
The client scrolls the list to this child on first show and whenever
the child's index changes (e.g. new transcript output shifting a REPL's
input row down); a re-push that leaves the index unchanged never
disturbs the user's scroll position.  One target per lazy column — the
first flagged child wins."
  (append node '((scroll_here . t))))

(cl-defun jetpacs-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (jetpacs--node "spacer" 'height height 'width width 'weight weight))

(defun jetpacs-divider ()
  "A horizontal divider."
  (jetpacs--node "divider"))

(defun jetpacs-card (&rest args)
  "An elevated card wrapping child nodes.
CHILDREN are the nodes as `&rest' or a single list of nodes (both forms
accepted — issue #9), optionally followed by keywords.  :width/:height fix
the size (dp), :fill-fraction (0.0-1.0) sets a fraction of parent width, and
:border is an `jetpacs-border' spec.  :swipe-start / :swipe-end are
`jetpacs-swipe-action' specs revealed by dragging the card from that side; a
full swipe fires the action and the card springs back (push the updated list
in the handler).  They win over the legacy single-action :on-swipe.  Old
companions render no gesture, so a swipe action must also be reachable by tap
or menu.  :on-tap, :padding and :weight as named.  :key gives the card a
stable identity as a `lazy_column' child, so reconciliation preserves its
client-side state, scroll anchor, and animation across pushes that
insert/remove/reorder rows (SPEC §9; falls back to a stateful child's id,
then position)."
  (let* ((split (jetpacs--children-and-opts args))
         (opts (cdr split)))
    (jetpacs--node "card"
                'children (vconcat (jetpacs--as-children (car split)))
                'key (plist-get opts :key)
                'on_tap (plist-get opts :on-tap)
                'on_swipe (plist-get opts :on-swipe)
                'swipe_start (plist-get opts :swipe-start)
                'swipe_end (plist-get opts :swipe-end)
                'padding (plist-get opts :padding)
                'weight (plist-get opts :weight)
                'width (plist-get opts :width)
                'height (plist-get opts :height)
                'fill_fraction (plist-get opts :fill-fraction)
                'border (plist-get opts :border))))

(cl-defun jetpacs-swipe-action (icon label action &key color)
  "A per-side card swipe action (`jetpacs-card' :swipe-start / :swipe-end).
ICON and LABEL are revealed on the swipe background as the card drags;
ACTION is dispatched once on a full swipe.  COLOR optionally tints the
revealed background (hex; defaults to a theme container color)."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_trigger action
              'color color))

(cl-defun jetpacs-list-item (&key leading title subtitle overline trailing
                                  on-tap swipe-start swipe-end padding key
                                  (spacing 12))
  "An elevated list-item card with a flexible middle and pinned edges — the
standard \"leading · title/subtitle · trailing\" list row, laid out so the
trailing controls are never pushed off-screen.

LEADING is an optional node at the start (an icon, checkbox, or avatar).
OVERLINE / TITLE / SUBTITLE build the flexible text column (any subset): TITLE
is `body', OVERLINE a `label' above it, SUBTITLE a `caption' below.
TRAILING is a single node, or a list of nodes, pinned at the end (a status
badge, icon buttons) — each keeps its intrinsic width.
ON-TAP makes the whole card tappable; SWIPE-START / SWIPE-END attach swipe
actions; PADDING pads the card; SPACING is the gap between the row's parts.
KEY rides the outer card as its stable `lazy_column' identity (see
`jetpacs-card') — give every dynamic list row one (the org id, the file
path) so reorders and inserts never smear state across rows.

The middle column carries the flex weight, so the trailing children keep their
width — the layout trap a bare `(jetpacs-row (jetpacs-column …) …)' falls into,
since a `column' renders `fillMaxWidth' (see WIDGETS.md).  Composes existing
nodes (`card' > `row' > weighted `column'); it is not a new wire node type, so
it needs no companion support.  For a trailing element, prefer an
intrinsic-width leaf (a `jetpacs-text' badge, `jetpacs-icon-button') — a nested
`jetpacs-row' would itself render `fillMaxWidth' and crowd the middle out."
  (let* ((texts (delq nil
                      (list (and overline (jetpacs-text overline 'label))
                            (and title    (jetpacs-text title 'body))
                            (and subtitle (jetpacs-text subtitle 'caption)))))
         (middle (apply #'jetpacs-column (append texts (list :spacing 2 :weight 1))))
         ;; TRAILING may be one node (an alist with a `t' type) or a list of them.
         (trailing-nodes (cond ((null trailing) nil)
                               ((assq 't trailing) (list trailing))
                               (t (append trailing nil))))
         (children (delq nil (append (list leading middle) trailing-nodes))))
    (jetpacs-card
     (list (apply #'jetpacs-row
                  (append children (list :align "center" :spacing spacing))))
     :on-tap on-tap :swipe-start swipe-start :swipe-end swipe-end
     :padding padding :key key)))

(cl-defun jetpacs-tab-item (label &key icon)
  "One tab in a `jetpacs-tabs' row: LABEL with an optional ICON above it."
  (jetpacs--node nil 'label label 'icon icon))

(cl-defun jetpacs-tabs (items children &key initial scrollable pager-only
                              on-change id)
  "An intra-view tab row over swipeable pages (SPEC §9 `tabs').
ITEMS (from `jetpacs-tab-item') label the tabs; CHILDREN is the
same-length list of page nodes.  Switching — tab tap or horizontal
swipe — is companion-local and never round-trips, the `view.switch'
philosophy; ON-CHANGE optionally dispatches on a settled page change
with the new index injected into args as `value'.  INITIAL picks the
starting page; SCROLLABLE lets many tabs pan instead of cramming;
PAGER-ONLY drops the tab row entirely for pure swipe-through content
\(flashcard review).  The user's page survives re-pushes; ID, when
non-nil, keys that client-side state — a push carrying a NEW id resets
to INITIAL (a fresh flashcard lands on its question page).  A companion
that predates the node stacks all pages — gate on
`jetpacs-node-supported-p' and fall back to a chip row plus the
selected child."
  (jetpacs--node "tabs"
              'items (vconcat items)
              'children (vconcat children)
              'initial initial
              'scrollable (and scrollable t)
              'pager_only (and pager-only t)
              'on_change on-change
              'id id))

(cl-defun jetpacs-collapsible (id header children &key collapsed on-long-tap on-swipe)
  "A fold/expand section. ID keys the (client-side) fold state.
HEADER is the always-visible node shown next to the chevron; CHILDREN
(a list of nodes) are revealed when expanded. COLLAPSED non-nil starts
folded. Folding happens entirely on-device — no action round-trip.
ON-LONG-TAP, when non-nil, is an action dispatched on long-press of
the header (used by the org reader to open the heading detail view)."
  (jetpacs--node "collapsible"
              'id id
              'header header
              'children (vconcat children)
              'collapsed (and collapsed t)
              'on_long_tap on-long-tap
              'on_swipe on-swipe))

(cl-defun jetpacs-reorderable-list (items &key on-reorder)
  "A drag-reorderable list of ITEMS.
Each item is an alist with at least (label . STRING) and (level . INT).
ON-REORDER is an action template dispatched with additional keys
\(from_pos . N) (after_pos . M) (new_level . L) when the user drops
a dragged item.  Dragging vertically reorders; horizontally promotes
or demotes."
  (jetpacs--node "reorderable_list"
              'items (vconcat items)
              'on_reorder on-reorder))

(cl-defun jetpacs-table (rows &key aligns on-add-row on-add-col padding)
  "A grid of cells with org-table semantics.
ROWS is a list from `jetpacs-table-row' and `jetpacs-table-rule'.  Columns
size to their widest cell and the grid pans horizontally on-device
when it overflows the screen — the whole table ships once.
ALIGNS is a list of per-column alignments (\"start\", \"center\",
\"end\"); columns beyond its length default to start.
ON-ADD-ROW / ON-ADD-COL, when non-nil, make the client render slim
\"+\" append affordances (a strip below the last row / a gutter after
the last column) that dispatch those actions.  The actions carry no
client-added args — embed the table's location when building them."
  (jetpacs--node "table"
              'rows (vconcat rows)
              'aligns (and aligns (vconcat aligns))
              'on_add_row on-add-row
              'on_add_col on-add-col
              'padding padding))

(cl-defun jetpacs-table-row (cells &key header)
  "A table row of CELLS (from `jetpacs-table-cell').
HEADER marks the row as part of the header group: the client renders
it emphasized, with a heavier rule under the group."
  (jetpacs--node nil
              'cells (vconcat cells)
              'header (and header t)))

(defun jetpacs-table-rule ()
  "A horizontal rule row (an org hline) — a divider line inside the grid."
  (jetpacs--node nil 'rule t))

(cl-defun jetpacs-table-cell (spans &key on-tap on-long-tap)
  "A table cell rendering SPANS (a list from `jetpacs-span').
ON-TAP / ON-LONG-TAP dispatch as-is — embed the cell's file/pos in the
action args when building it (the client adds nothing)."
  (jetpacs--node nil
              'spans (vconcat spans)
              'on_tap on-tap
              'on_long_tap on-long-tap))

;; ─── Interactive ─────────────────────────────────────────────────────────────

(defvar jetpacs--confirm-index (make-hash-table :test 'equal)
  "Map of action name -> ((NORMALIZED-ARGS . PROMPT) …), newest first.
Written by `jetpacs-action' whenever a descriptor carries :confirm; read
back by the dispatch gate (`jetpacs--on-action') to decide whether an
inbound `event.action' needs a yes/no prompt.  The prompt must resolve
client-side: the companion treats `confirm' as opaque author-side policy
and does not echo it in the delivered frame (SPEC §5), so a gate that
trusted the payload would never fire on-device.  Entries are refreshed
by every re-render (construction re-registers) and persist otherwise —
dropping :confirm from a control keeps gating stale queued taps until
restart, which errs in the safe direction.")

(defun jetpacs--confirm-key-name (k)
  "The wire name of args key K, matching `json-serialize' (colon stripped)."
  (cond ((keywordp k) (substring (symbol-name k) 1))
        ((symbolp k) (symbol-name k))
        (t (format "%s" k))))

(defun jetpacs--confirm-normalize (v)
  "Canonical identity of an action-args value across the JSON round trip.
The companion parses the descriptor's `args' and re-emits them in the
event, so what survives is structural — org.json neither preserves
object key order nor the `.0' of a whole-valued double.  Objects
normalize to (:obj . PAIRS) sorted by key with string key names, arrays
\(authored vectors, decoded lists) to (:arr . ITEMS), and whole floats
to integers; scalars (strings, ints, t/:false/:null) pass through."
  (cond
   ((vectorp v)
    (cons :arr (mapcar #'jetpacs--confirm-normalize (append v nil))))
   ((and (floatp v) (= v (ftruncate v))) (truncate v))
   ((null v) nil)
   ((and (proper-list-p v)
         (cl-every (lambda (e)
                     (and (consp e) (car e)
                          (or (symbolp (car e)) (stringp (car e)))))
                   v))
    (cons :obj (sort (mapcar (lambda (kv)
                               (cons (jetpacs--confirm-key-name (car kv))
                                     (jetpacs--confirm-normalize (cdr kv))))
                             v)
                     (lambda (a b) (string< (car a) (car b))))))
   ((proper-list-p v)
    (cons :arr (mapcar #'jetpacs--confirm-normalize v)))
   (t v)))

(defun jetpacs--confirm-register (action args prompt)
  "Index PROMPT as the confirm gate for ACTION dispatched with ARGS."
  (let ((key (jetpacs--confirm-normalize args)))
    (puthash action
             (cons (cons key prompt)
                   (assoc-delete-all key (gethash action jetpacs--confirm-index)))
             jetpacs--confirm-index)))

(defun jetpacs--confirm-for (action args)
  "The confirm prompt registered for dispatching ACTION with ARGS, or nil.
Exact args identity wins (per-row prompts name the right row); when the
name is indexed but the echoed args match no entry, the newest prompt
for the name is the fallback — a round trip that defeats normalization
must fail toward prompting, never toward an ungated destructive action."
  (let ((entries (gethash action jetpacs--confirm-index)))
    (when entries
      (or (cdr (assoc (jetpacs--confirm-normalize args) entries))
          (cdar entries)))))

(cl-defun jetpacs-action (action &key args (when-offline "queue") dedupe confirm)
  "An action descriptor.
ACTION names an allowlisted handler (`jetpacs-defaction'); ARGS is an
alist baked in server-side.  WHEN-OFFLINE is the queue policy
\(\"queue\"/\"drop\"/\"wake\", SPEC §5) and DEDUPE collapses queued repeats.

CONFIRM, when non-nil, is a prompt string shown as a native yes/no dialog
\(via the minibuffer bridge) before the handler runs — declining is a
clean no-op.  For destructive actions (delete, remove): pair it with an
undo snackbar (`jetpacs-snackbar-action') where an undo is cheap, and
reserve :confirm for what an undo can't restore.  The gate runs at
dispatch time in Emacs, resolving the prompt from a client-side index
keyed by action name + args — the companion never echoes `confirm'
\(SPEC §5) — so a queued offline tap confirms on replay."
  (when (and (stringp confirm) (not (string-empty-p confirm)))
    (jetpacs--confirm-register action args confirm))
  (jetpacs--node nil
              'action action
              'when_offline when-offline
              'args args
              'dedupe dedupe
              'confirm confirm))

(defun jetpacs-clipboard-action (text)
  "A companion-local action that copies TEXT to the device clipboard.
Handled entirely on-device (like the `view.switch' builtin) — no
round-trip to Emacs, works offline."
  (jetpacs--node nil 'builtin "clipboard.copy" 'text text))

(defun jetpacs-native-settings-action ()
  "Open native Jetpacs settings, even while Emacs is offline."
  (jetpacs--node nil 'builtin "jetpacs.settings.open"))

(cl-defun jetpacs-button (label action &key icon variant weight padding)
  "A button. VARIANT is filled/outlined/text/tonal."
  (jetpacs--node "button"
              'label label
              'on_tap action
              'icon icon
              'variant variant
              'weight weight
              'padding padding))

(cl-defun jetpacs-date-button (label on-pick &key value)
  "A button that opens a date picker. ON-PICK is dispatched with the chosen
date injected into its args as `value' (\"YYYY-MM-DD\"). VALUE seeds the
picker (\"YYYY-MM-DD\")."
  (jetpacs--node "date_button" 'label label 'on_pick on-pick 'value value))

(cl-defun jetpacs-time-button (label on-pick &key value)
  "A button that opens a time picker. ON-PICK is dispatched with the chosen
time injected into its args as `value' (\"HH:MM\"). VALUE seeds the picker."
  (jetpacs--node "time_button" 'label label 'on_pick on-pick 'value value))

(cl-defun jetpacs-image (url &key content-description padding
                          width height aspect-ratio content-scale)
  "An image loaded from URL (an http(s) URL or a readable file:// path).
WIDTH/HEIGHT fix the size (dp); ASPECT-RATIO (w/h) constrains it;
CONTENT-SCALE is \"fit\" (default), \"crop\", or \"fill\".  With no width or
fill given the image fills the available width, as before."
  (jetpacs--node "image"
              'url url
              'content_description content-description
              'padding padding
              'width width
              'height height
              'aspect_ratio aspect-ratio
              'content_scale (and content-scale (format "%s" content-scale))))

;; ─── Visualization ladder (SPEC §9) ──────────────────────────────────────────

(defun jetpacs--chart-point (p)
  "Normalize chart point P to a {y} / {x,y} node.
P is a number (→ {y}), or a two-element list/cons (X Y) (→ {x,y})."
  (cond ((numberp p) (jetpacs--node nil 'y p))
        ((consp p) (jetpacs--node nil 'x (car p) 'y (if (consp (cdr p)) (cadr p) (cdr p))))
        (t (jetpacs--node nil 'y 0))))

(cl-defun jetpacs-chart-series (points &key label color)
  "One chart series over POINTS (numbers, or (X Y) pairs).
LABEL and COLOR (hex or theme token) are optional."
  (jetpacs--node nil
              'label label
              'color color
              'points (vconcat (mapcar #'jetpacs--chart-point points))))

(cl-defun jetpacs-chart (series &key kind height y-range summary on-point-tap)
  "A data-driven chart of SERIES (a list from `jetpacs-chart-series').
KIND is \"line\" (default), \"bar\", \"area\", or \"sparkline\".  HEIGHT is
in dp; Y-RANGE is (MIN MAX); SUMMARY is the accessibility label;
ON-POINT-TAP fires with the tapped point injected as `value'.  Rung 1 of
the visualization ladder — data in, polished chart out, no draw ops."
  (jetpacs--node "chart"
              'series (vconcat series)
              'kind (and kind (format "%s" kind))
              'height height
              'y_range (and y-range (vconcat y-range))
              'summary summary
              'on_point_tap on-point-tap))

(cl-defun jetpacs-canvas (width height ops)
  "A canvas of WIDTH×HEIGHT dp rendering OPS (a list of draw-op nodes).
Ops come from `jetpacs-draw-line'/`-rect'/`-circle'/`-path'/`-text';
coordinates are in the WIDTH×HEIGHT space.  Rung 2 — the elisp-only
escape hatch for visuals no curated node covers."
  (jetpacs--node "canvas" 'width width 'height height 'ops (vconcat ops)))

(cl-defun jetpacs-month-grid (month &key marks selected min-month max-month
                                    on-day-tap on-month-change)
  "An agenda month calendar for MONTH (\"YYYY-MM\") — SPEC §9 `month_grid'.
MARKS is an alist of (\"YYYY-MM-DD\" . SPEC): SPEC is a dot count
\(1-3 dots render under the day) or an alist like
\((dots . N) (color . \"#hex\")).  SELECTED (\"YYYY-MM-DD\") fills one
day; today is always outlined.  MIN-MONTH/MAX-MONTH (\"YYYY-MM\") clamp
the companion-local month navigation (chevrons and horizontal swipe).
ON-DAY-TAP dispatches with the tapped date injected into args as
`value'; ON-MONTH-CHANGE with the newly shown \"YYYY-MM\" — answer it
by pushing fresh marks (marks for unfetched months are simply absent,
never blocking).  An additive node: gate on `jetpacs-node-supported-p';
the fallback recipe is a `jetpacs-flow-row' of `fill_fraction'-sized day
boxes with `on_tap'."
  (jetpacs--node "month_grid"
              'month month
              'marks (and marks
                          (mapcar (lambda (m)
                                    (cons (intern (car m))
                                          (if (numberp (cdr m))
                                              `((dots . ,(cdr m)))
                                            (cdr m))))
                                  marks))
              'selected selected
              'min_month min-month
              'max_month max-month
              'on_day_tap on-day-tap
              'on_month_change on-month-change))

(cl-defun jetpacs-draw-line (x1 y1 x2 y2 &key color stroke)
  "A canvas line op from (X1 Y1) to (X2 Y2)."
  (jetpacs--node nil 'op "line" 'x1 x1 'y1 y1 'x2 x2 'y2 y2
              'color color 'stroke stroke))

(cl-defun jetpacs-draw-rect (x y w h &key color fill stroke radius)
  "A canvas rect op at (X Y) of size W×H; FILL vs stroked; ROUNDED by RADIUS."
  (jetpacs--node nil 'op "rect" 'x x 'y y 'w w 'h h 'color color
              'fill (and fill t) 'stroke stroke 'radius radius))

(cl-defun jetpacs-draw-circle (cx cy r &key color fill stroke)
  "A canvas circle op centred (CX CY) of radius R; FILL vs stroked."
  (jetpacs--node nil 'op "circle" 'cx cx 'cy cy 'r r 'color color
              'fill (and fill t) 'stroke stroke))

(cl-defun jetpacs-draw-path (points &key color fill stroke closed)
  "A canvas path op over POINTS (a list of (X Y) pairs); FILL/CLOSED optional."
  (jetpacs--node nil 'op "path"
              'points (vconcat (mapcar (lambda (p) (vector (nth 0 p) (nth 1 p))) points))
              'color color 'fill (and fill t) 'stroke stroke
              'closed (and closed t)))

(cl-defun jetpacs-draw-text (x y text &key color size align)
  "A canvas text op drawing TEXT at (X Y); ALIGN is start/center/end."
  (jetpacs--node nil 'op "text" 'x x 'y y 'text text 'color color 'size size
              'align (and align (format "%s" align))))

(cl-defun jetpacs-icon-button (icon action &key content-description padding badge)
  "An icon button.
BADGE overlays a count on the icon: a number (rendered capped at 99+)
or the empty string for a bare attention dot; nil for none."
  (jetpacs--node "icon_button"
              'icon icon
              'on_tap action
              'content_description content-description
              'padding padding
              'badge badge))

(cl-defun jetpacs-menu (items &key icon padding)
  "An overflow menu: an icon that opens a dropdown of ITEMS.
ITEMS is a list from `jetpacs-menu-item'. ICON defaults to a vertical
ellipsis. Folding/opening is handled entirely on-device."
  (jetpacs--node "menu" 'items (vconcat items) 'icon icon 'padding padding))

(cl-defun jetpacs-menu-item (label action &key icon)
  "An item in an overflow `jetpacs-menu': LABEL dispatches ACTION when tapped."
  (jetpacs--node nil 'label label 'on_tap action 'icon icon))

(cl-defun jetpacs-text-input (id &key value hint label on-submit single-line
                              multi-line min-lines max-lines monospace syntax
                              password keyboard autofocus clear-on-submit
                              padding)
  "A text input field.
ID identifies the field. ON-SUBMIT is an action dispatched when done.
The client defaults to single-line; pass MULTI-LINE non-nil for a box that
accepts newlines (Enter inserts a newline rather than submitting, so such a
field should be paired with a submit button). MIN-LINES/MAX-LINES size the box
and MONOSPACE renders it in a fixed-width font (handy for code).
SYNTAX (e.g. \"elisp\", \"org\") turns on client-side highlighting.
PASSWORD masks the entry (dots) and requests a password keyboard — used by
the `read-passwd' bridge; such a field's value must not be logged or
retained beyond the read.
KEYBOARD picks the IME: \"number\", \"decimal\", \"email\", \"phone\", or
\"uri\"; nil (or an unknown value) falls back to the text keyboard, and
PASSWORD always wins.
AUTOFOCUS makes the field grab focus and raise the keyboard the first
time it composes under a new ID — re-pushes of the same ID never
re-steal focus. CLEAR-ON-SUBMIT empties the field client-side after the
submit dispatch, in place (no ID rotation), so focus and the keyboard
survive for chained rapid entry; the mirrored ui-state clears with it."
  (jetpacs--node "text_input"
              'id id
              'value value
              'hint hint
              'label label
              'on_submit on-submit
              ;; `:false' (not t) so the client overrides its single-line default.
              'single_line (cond (multi-line :false)
                                 (single-line t))
              'min_lines min-lines
              'max_lines max-lines
              'monospace (and monospace t)
              'syntax syntax
              'password (and password t)
              'keyboard keyboard
              'autofocus (and autofocus t)
              'clear_on_submit (and clear-on-submit t)
              'padding padding))

(cl-defun jetpacs-enum-list (id options &key value multi-select allow-add on-change padding)
  "An enum list for selecting from OPTIONS.
ID identifies the field. VALUE is a list/vector of currently selected strings.
MULTI-SELECT allows choosing multiple options. ALLOW-ADD shows an input for
adding new options. ON-CHANGE is an action dispatched when the selection
changes."
  (jetpacs--node "enum_list"
              'id id
              'options (vconcat options)
              ;; A bare string VALUE would vconcat into a vector of char
              ;; codes — wrap it as the one-element selection it means.
              'value (and value (vconcat (if (stringp value) (list value) value)))
              'multi_select (and multi-select t)
              'allow_add (and allow-add t)
              'on_change on-change
              'padding padding))

(cl-defun jetpacs-checkbox (id &key checked label on-change padding)
  "A checkbox."
  (jetpacs--node "checkbox"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun jetpacs-switch (id &key checked label on-change padding)
  "A toggle switch."
  (jetpacs--node "switch"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun jetpacs-slider (id on-change &key value min max steps)
  "A continuous slider identified by ID.
ON-CHANGE fires once on release with the position injected into args as
`value'.  VALUE seeds the position; MIN/MAX bound the range (default
0.0/1.0); STEPS, when > 0, makes the slider discrete."
  (jetpacs--node "slider"
              'id id
              'on_change on-change
              'value value
              'min min
              'max max
              'steps steps))

;; ─── Display ─────────────────────────────────────────────────────────────────

(cl-defun jetpacs-icon (name &key size color padding badge)
  "An icon display.
BADGE overlays a count: a number (capped at 99+ on-device) or the empty
string for a bare attention dot; nil for none."
  (jetpacs--node "icon" 'name name 'size size 'color color 'padding padding
              'badge badge))

(cl-defun jetpacs-chip (label &key on-tap selected icon padding)
  "A filter chip."
  (jetpacs--node "chip"
              'label label
              'on_tap on-tap
              'selected (and selected t)
              'icon icon
              'padding padding))

(cl-defun jetpacs-progress (&key variant value padding)
  "A progress indicator. VARIANT is circular/linear. VALUE is 0.0-1.0."
  (jetpacs--node "progress" 'variant variant 'value value 'padding padding))

(cl-defun jetpacs-assist-chip (label &key on-tap icon padding)
  "An assist chip (e.g. a #tag). LABEL is shown; ON-TAP fires on click.
Unlike `jetpacs-chip' (a selectable filter chip) this is a flat, tappable
suggestion chip — pair it with `jetpacs-flow-row' for wrapping tag rows."
  (jetpacs--node "assist_chip"
              'label label
              'on_tap on-tap
              'icon icon
              'padding padding))

(cl-defun jetpacs-badge (label &key icon color padding)
  "A compact, non-interactive status pill: an optional leading ICON and LABEL
on a tonal container tinted by COLOR (a hex string or a Material theme token
like \"error\"/\"primary\"/\"tertiary\").  Unlike a chip it carries no tap and
no outline; unlike a nested icon+label `jetpacs-row' (which renders
`fillMaxWidth') it is intrinsic-width, so it sits correctly as a trailing
element in a row — the standard status-badge slot in `jetpacs-list-item'.

An additive node (SPEC §9): it embeds a fallback `text' child (the label in
COLOR), so a companion predating the `badge' node degrades to a colored label
rather than nothing — callers need not gate on `jetpacs-node-supported-p'."
  (jetpacs--node "badge"
              'label label
              'icon icon
              'color color
              'padding padding
              'children (vector (jetpacs-text label 'label nil color))))

(cl-defun jetpacs-section-header (title &key trailing padding)
  "A styled section label. TRAILING is an optional node shown at the end
\(e.g. a count or an `jetpacs-icon-button')."
  (jetpacs--node "section_header" 'title title 'trailing trailing 'padding padding))

(cl-defun jetpacs-empty-state (&key icon title caption on-tap action-label padding)
  "A centered empty-state placeholder.
ICON names a glyph (default \"inbox\"); TITLE and CAPTION describe the
emptiness. When ON-TAP and ACTION-LABEL are both given, an outlined
button is shown beneath the text."
  (jetpacs--node "empty_state"
              'icon icon
              'title title
              'caption caption
              'on_tap on-tap
              'action_label action-label
              'padding padding))

(defconst jetpacs--month-abbrevs
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
   "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
  "Short month labels used by `jetpacs-date-stamp'.")

(defun jetpacs-month-abbrev (n)
  "The three-letter English abbreviation for month N (1 = Jan .. 12 = Dec).
Returns nil when N is not an integer in 1..12."
  (and (integerp n) (>= n 1) (<= n 12)
       (aref jetpacs--month-abbrevs (1- n))))

(cl-defun jetpacs-date-stamp (&key date day month month-index year time padding)
  "A compact date/time chip-card.
Pass DATE as \"YYYY-MM-DD\" to derive DAY, MONTH (abbrev), YEAR and
MONTH-INDEX automatically, or supply those fields directly. TIME is an
optional \"HH:MM\" rendered in a second card below the date. MONTH-INDEX
\(1-12) drives the header tint."
  (when (and date
             (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" date))
    (let ((y (match-string 1 date))
          (m (string-to-number (match-string 2 date)))
          (d (string-to-number (match-string 3 date))))
      (setq year (or year y)
            month-index (or month-index m)
            month (or month (jetpacs-month-abbrev m))
            day (or day (number-to-string d)))))
  (jetpacs--node "date_stamp"
              'day (and day (format "%s" day))
              'month month
              'month_index month-index
              'year (and year (format "%s" year))
              'time time
              'padding padding))

;; ─── Composites (pure elisp; no new wire node) ───────────────────────────────
;;
;; High-frequency shapes a Tier 1 would otherwise hand-roll every screen —
;; each composes the primitive nodes above (like `jetpacs-list-item') and adds
;; no `t' to the vocabulary, so the reference companion renders them with no
;; change.  Grocy hand-wrote every one of these; these erase that boilerplate.

;; ─── Semantic text (A1) ──────────────────────────────────────────────────────
;;
;; Intent-level text shorthands: `jetpacs-error' reads better than `jetpacs-text
;; ... :color "error"' and puts the theme decision (which color *is* muted, what
;; a heading *is*) in one place instead of re-derived per screen.  Each is a
;; pure function returning an existing `text'/`rich_text' node — no new wire
;; node, no companion support needed — except the `success'/`warning' colors:
;; those tokens land in the renderer's `resolveColor' separately (plan K0); a
;; companion predating them falls through to the ambient text color, so the
;; text still renders (just untinted).  See docs/PLAN-dsl-ergonomics.md (A1).

(cl-defun jetpacs-heading (text &key (level 1) padding)
  "A heading showing TEXT at LEVEL (1 → title, 2 → headline, ≥3 → body).
PADDING is the surrounding inset (dp).  A thin wrapper over `jetpacs-text'
that names the intent instead of re-picking a style at every call site."
  (jetpacs-text text
                :style (pcase level (1 'title) (2 'headline) (_ 'body))
                :padding padding))

(cl-defun jetpacs-muted (text &key (style 'caption) padding)
  "De-emphasized TEXT tinted `on_surface_variant' (the muted theme color).
STYLE is the text style (default `caption'); PADDING the inset (dp)."
  (jetpacs-text text :style style :color "on_surface_variant" :padding padding))

(cl-defun jetpacs-error (text &key padding)
  "TEXT in the theme error color.  PADDING is the inset (dp)."
  (jetpacs-text text :color "error" :padding padding))

(cl-defun jetpacs-warning (text &key padding)
  "TEXT in the theme warning color (amber).  PADDING is the inset (dp).
Uses the additive `warning' color token (renderer K0): a companion predating
it resolves `warning' to the ambient text color, so the text still shows —
just untinted.  No `jetpacs-node-supported-p' gate is needed."
  (jetpacs-text text :color "warning" :padding padding))

(cl-defun jetpacs-success (text &key padding)
  "TEXT in the theme success color (green).  PADDING is the inset (dp).
Uses the additive `success' color token (renderer K0); see `jetpacs-warning'
for the older-companion fallback."
  (jetpacs-text text :color "success" :padding padding))

(cl-defun jetpacs-strong (text &key padding)
  "Bold TEXT — a one-span `rich_text', since plain `text' carries no weight.
PADDING is the inset (dp)."
  (jetpacs-rich-text (list (jetpacs-span text :bold t)) :padding padding))

(cl-defun jetpacs-code (text &key padding)
  "Inline monospace/code TEXT — a one-span `rich_text'.
PADDING is the inset (dp).  For a multi-line code block use `jetpacs-markup'
with :syntax; this is the inline `verbatim'/`~code~' run."
  (jetpacs-rich-text (list (jetpacs-span text :code t)) :padding padding))

;; ─── Sub-tree error boundary (A2) ────────────────────────────────────────────

(defmacro jetpacs-try (body &rest keys)
  "Evaluate BODY (a node-producing form); on error return a fallback node.
A builder that signals blanks the whole view — one throwing card takes down
the dashboard.  Wrapping the card in `jetpacs-try' contains the failure to
that subtree: siblings still render, and the throw becomes a local fallback
node instead of an empty surface.

KEYS: :fallback FN — a function of the error object returning a node
      (default: a muted `jetpacs-empty-state' captioned with the error).
The error is always logged to *Messages* first, so it is never swallowed
silently.  This is a macro that merely *chooses* which node to emit, so it
adds nothing to the wire and needs no companion support; it pairs with the
renderer's defensive rendering (plan K2), which stops a malformed *node*
from blanking the surface the same way this stops a malformed *builder*.
See docs/PLAN-dsl-ergonomics.md (A2)."
  (declare (indent 1))
  (let ((fb (plist-get keys :fallback)))
    `(condition-case err
         ,body
       (error
        (message "jetpacs-try: %s" (error-message-string err))
        ,(if fb
             `(funcall ,fb err)
           `(jetpacs-empty-state
             :title "Couldn't render"
             :caption (error-message-string err)))))))

(defun jetpacs-action-with-arg (action key value)
  "Return a copy of ACTION (an action alist) with (KEY . VALUE) set in its `args'.
ACTION nil returns nil.  Bakes a chosen value into the dispatched action
server-side — the composites use it (the stepper's target number, the
segmented control's option) rather than relying on companion
value-injection, so the handler receives the value already typed (a
number stays a number).  Public since 1.23.0: the same need arrives in
any Tier 1 that builds per-row or per-option actions from one template."
  (when action
    (let ((args (assq-delete-all key (copy-alist (alist-get 'args action))))
          (base (assq-delete-all 'args (copy-alist action))))
      (append base (list (cons 'args (append args (list (cons key value)))))))))

(defalias 'jetpacs--action-with-arg #'jetpacs-action-with-arg
  "Internal alias kept for pre-1.23.0 callers; use `jetpacs-action-with-arg'.")

(defun jetpacs-additive (node fallback)
  "Mark NODE (an additive wire type) to degrade to FALLBACK on old companions.
Attaches FALLBACK (a single node) as NODE's children: a companion that
recognizes NODE's `t' renders it (leaf additive nodes ignore unexpected
children); one that predates it falls through the renderer's unknown-node
path, which renders the children — i.e. FALLBACK.  This is the
self-describing degrade the `badge' node ships with, generalized: the
caller never needs to gate on `jetpacs-node-supported-p'.  Any existing
children of NODE are replaced — so this fits the leaf additive nodes
\(`chart', `canvas', `month_grid'), NOT `tabs', whose children are its
pages; a tabs fallback keeps the explicit
`jetpacs-node-supported-p' gate — passing a tabs node signals an error
\(since 1.24.0) rather than silently discarding the pages."
  (when (equal (alist-get 't node) "tabs")
    (error "jetpacs-additive: a `tabs' node's children are its pages — %s"
           "gate on jetpacs-node-supported-p instead"))
  (append (assq-delete-all 'children (copy-alist node))
          (list (cons 'children (vector fallback)))))

(cl-defun jetpacs-stepper (id value on-change &key (min 0) max (step 1) format)
  "A −/+ stepper over the numeric VALUE.
ID names the stepper (its −/+ buttons carry \"Decrease/Increase ID\"
accessibility labels).  Tapping −/+ dispatches ON-CHANGE with the new,
clamped number injected into its args as `value' — baked server-side, so
the handler receives a real number, never a string.  MIN/MAX bound the
value (MAX nil = unbounded) and STEP is the increment.  FORMAT, when given,
is a function of the number returning the middle label (e.g. \"4 servings\");
the default shows the bare number.  Composes an icon-button row (`remove' ·
value · `add') sized to its content, so it sits as a compact cluster and
never triggers the row flex trap; not a new wire node, so no companion
support is needed."
  (let ((dec (max min (- value step)))
        (inc (if max (min max (+ value step)) (+ value step))))
    (jetpacs-row
     (jetpacs-icon-button "remove" (jetpacs--action-with-arg on-change 'value dec)
                       :content-description (format "Decrease %s" id))
     (jetpacs-text (if format (funcall format value) (number-to-string value)) 'title)
     (jetpacs-icon-button "add" (jetpacs--action-with-arg on-change 'value inc)
                       :content-description (format "Increase %s" id))
     :align "center" :spacing 8 :fill nil)))

(cl-defun jetpacs-segmented (id options on-change &key selected scroll spacing run-spacing)
  "A single-select chip group over OPTIONS (the id-labelled filter row).
Each option renders a `jetpacs-chip'; tapping one dispatches ON-CHANGE
with its value injected into args as `value'.  SELECTED (a string) marks
the current option.  An OPTIONS entry is a string (value = label) or a
plist (:value :label :icon).  Wraps by default (a `flow_row', with :spacing
and :run-spacing between/along rows); :scroll makes it a single-line
horizontal rail (a `scroll_row') instead.  ID is carried for symmetry with
the form field it usually drives.  Composes chips — not a new wire node, no
companion support needed."
  (ignore id)
  (let ((chips (mapcar
                (lambda (opt)
                  (let* ((val   (if (stringp opt) opt (plist-get opt :value)))
                         (label (if (stringp opt) opt (or (plist-get opt :label) val)))
                         (icon  (and (not (stringp opt)) (plist-get opt :icon))))
                    (jetpacs-chip label
                               :selected (equal val selected)
                               :icon icon
                               :on-tap (jetpacs--action-with-arg on-change 'value val))))
                options)))
    (if scroll
        (apply #'jetpacs-scroll-row chips)
      (apply #'jetpacs-flow-row
             (append chips (list :spacing spacing :run-spacing run-spacing))))))

(cl-defun jetpacs-stat (value &key label icon color weight on-tap padding
                              fill-fraction width)
  "A metric tile: a large VALUE, an optional LABEL beneath and ICON above,
with COLOR (a hex string or a Material theme token like \"primary\") tinting
the value and icon.  WEIGHT lets several tiles share a row equally, while
FILL-FRACTION (0.0-1.0 of the parent width) or WIDTH (dp) sizes a tile inside
a wrapping `flow_row' of tiles; ON-TAP makes the tile tappable.  Composes an
elevated `card' over a centered `column' — the dashboard/overview staple; not
a new wire node."
  (jetpacs-card
   (list (apply #'jetpacs-column
                (append (delq nil
                              (list (and icon (jetpacs-icon icon :color color))
                                    (jetpacs-text (format "%s" value) 'headline nil color)
                                    (and label (jetpacs-text label 'caption))))
                        (list :spacing 2 :align "center"))))
   :weight weight :on-tap on-tap :padding (or padding 16)
   :fill-fraction fill-fraction :width width))

(cl-defun jetpacs-kv (label value &key spacing)
  "A property/definition row: LABEL on the left in the muted `label' style,
VALUE filling the width to its right.  VALUE is a string (rendered as `body'
text) or a ready node used as-is — a string value is weighted so it wraps
without pushing anything off-screen.  The detail-screen staple (`grocy--kv');
composes a `row', not a new wire node.  SPACING is the label→value gap (dp)."
  (jetpacs-row
   (jetpacs-text label 'label)
   (if (stringp value) (jetpacs-text value 'body 1) value)
   :spacing (or spacing 8) :align "top"))

(cl-defun jetpacs-sectioned-list (sections &key empty)
  "A `lazy_column' assembled from SECTIONS with built-in empty handling.
Each SECTION is a plist:
  :header  a string (→ `jetpacs-section-header'), a ready node, or nil.
  :items   the section's list of child nodes.
  :empty   a node shown in place of the items when :items is empty.
When every section is empty and EMPTY is given, that node (an
`jetpacs-empty-state', typically) is shown alone.  Erases the
`append'/`apply' + per-list empty-check plumbing every list screen repeats,
completing the `jetpacs-list-item' story; composes a `lazy_column', not a
new wire node."
  (let ((any (cl-some (lambda (s) (plist-get s :items)) sections)))
    (if (and (not any) empty)
        (jetpacs-lazy-column empty)
      (apply #'jetpacs-lazy-column
             (cl-loop for s in sections
                      for header = (plist-get s :header)
                      for items  = (plist-get s :items)
                      for sempty = (plist-get s :empty)
                      append (delq nil
                                   (cons (cond ((null header) nil)
                                               ((stringp header)
                                                (jetpacs-section-header header))
                                               (t header))
                                         (or items (and sempty (list sempty))))))))))

;; ─── Home-screen widgets ─────────────────────────────────────────────────────
;;
;; Rows for `widget:*' surfaces (the home-screen list widgets, including
;; the blank `widget:customN' slots). The companion renders these with
;; RemoteViews, so the vocabulary is deliberately small: two-line rows
;; with an optional trailing icon button, plus bold section dividers.

(cl-defun jetpacs-widget-item (text &key todo done meta icon on-tap in-app
                                 button on-button)
  "A row in a home-screen widget list.
TEXT is the title line. TODO is a state keyword rendered as a colored
prefix while open; DONE strikes the title through. META is the
secondary line and ICON its glyph: \"scheduled\", \"deadline\",
\"event\", or \"folder\". ON-TAP is dispatched when the row is tapped;
IN-APP routes it through the opened companion app (navigation),
otherwise the tap is silent. BUTTON (\"todo_open\", \"todo_done\",
\"add\") shows a trailing icon button that dispatches ON-BUTTON
silently — it never opens the app."
  (jetpacs--node nil
              'text text
              'todo todo
              'done (and done t)
              'meta meta
              'icon icon
              'on_tap on-tap
              'tap_in_app (and in-app t)
              'button button
              'on_button on-button))

(defun jetpacs-widget-divider (label)
  "A bold section divider row (\"Overdue\", \"Today\") in a widget list."
  (jetpacs--node nil 'divider label))

(cl-defun jetpacs-tile (label &key subtitle icon state on-tap in-app)
  "A Quick Settings tile spec for a `tile:customN' slot surface.
LABEL and SUBTITLE are the tile texts (the subtitle shows on Android
10+). ICON names a glyph: \"todo_open\", \"todo_done\", \"add\",
\"refresh\", \"scheduled\", \"deadline\", \"event\", or \"folder\".
STATE is \"active\", \"inactive\" (the default), or \"unavailable\".
ON-TAP is dispatched when the tile is tapped; IN-APP opens the
companion app and routes the action through it, otherwise the tap
fires silently from the shade (no unlock required — compose
accordingly). An un-pushed slot shows as a grayed-out tile."
  (jetpacs--node nil
              'label label
              'subtitle subtitle
              'icon icon
              'state (and state (format "%s" state))
              'on_tap on-tap
              'tap_in_app (and in-app t)))

;; ─── Scaffold ────────────────────────────────────────────────────────────────

(cl-defun jetpacs-toolbar-item (icon label &key snippet placement line
                                on-tap long-press menu)
  "One item in a data-driven editor toolbar (SPEC §9 \"Editor toolbars\").
ICON names the chip glyph and LABEL is its short text.  Exactly one op
per item: SNIPPET is text the companion inserts locally, with the closed
placeholder set ${selection} ${cursor} ${input:Prompt} ${date} ${time}
\(unknown ${...} tokens insert literally); LINE is a builtin line op —
\"promote\", \"demote\", \"move-up\", or \"move-down\"; ON-TAP is an
ordinary action object dispatched to Emacs (the escape hatch); MENU is a
list of sub-items (this constructor with nil ICON) shown as a dropdown —
menus don't nest.  PLACEMENT refines SNIPPET: \"cursor\" (default),
\"line-start\" (prefix the cursor's line, deduped), or \"block\" (own
line\(s)).  LONG-PRESS is a secondary op — an item (nil ICON and LABEL)
carrying one of SNIPPET/LINE/ON-TAP.  Pass the item list to
`jetpacs-editor' :toolbar; `jetpacs-lint-spec' validates the vocabulary."
  (jetpacs--node nil
              'icon icon
              'label label
              'snippet snippet
              'placement placement
              'line line
              'on_tap on-tap
              'long_press long-press
              'menu (and menu (vconcat menu))))

(cl-defun jetpacs-editor (id value &key on-save on-enter read-only syntax
                          line-numbers complete chromeless publish-state
                          autofocus toolbar)
  "A full-height plain-text editor node.
ID identifies the editor (its unsaved state lives companion-side under
this key). VALUE seeds the buffer. ON-SAVE is dispatched with the full
text injected into args as `value'. READ-ONLY disables editing/saving.
SYNTAX (\"elisp\", \"org\") forces highlighting; when omitted the client
infers it from the file extension in ID.  LINE-NUMBERS is \"absolute\"
or \"relative\" (relative to the cursor) for a gutter, nil for none.
COMPLETE enables Emacs-backed completion: the client sends debounced
`edit.complete' actions while typing and renders the returned candidates
as a suggestion strip (see jetpacs-complete.el).
CHROMELESS hides the filename/undo/save header and sizes the field
compactly instead of full-height — an inline field with the full bridge
\(completion, squiggles, doc line), e.g. the eval REPL input.
PUBLISH-STATE emits debounced `state.changed' with the text under ID,
so button-driven forms can read it back from `jetpacs-ui-state' — and
any action dispatch flushes a pending value first (SPEC §5), so a
button handler never reads a debounce-stale buffer.
ON-ENTER turns the keyboard's Enter into a dispatch: the action fires
with the full buffer injected into args as `value' INSTEAD of inserting
a newline (the outliner's Enter-creates-a-sibling; a literal newline
still comes from a hardware Enter or a toolbar snippet), and the
keyboard stays up for the editor the handler pushes next.
AUTOFOCUS makes the editor grab focus and raise the keyboard the first
time it composes under a new ID — pair it with a per-edit ID generation
so a freshly pushed editor is immediately typeable.
TOOLBAR attaches a keyboard-adjacent formatting toolbar: a list of
`jetpacs-toolbar-item's the companion interprets as data (the default
path), or a string naming a host-registered native toolbar (the Kotlin
alternative — the reference companion registers none); nil for none.
Server-driven so the renderer stays app-agnostic: the app opts an
editor into the affordance."
  (jetpacs--node "editor"
              'id id
              'value value
              'on_save on-save
              'on_enter on-enter
              'read_only (and read-only t)
              'syntax syntax
              'line_numbers line-numbers
              'complete (and complete t)
              'chromeless (and chromeless t)
              'publish_state (and publish-state t)
              'autofocus (and autofocus t)
              'toolbar (if (and toolbar (listp toolbar))
                           (vconcat toolbar)
                         toolbar)))

(cl-defun jetpacs-scaffold (&key top-bar fab body bottom-bar floating-toolbar
                            snackbar snackbar-action drawer on-refresh)
  "The standard app frame.
SNACKBAR is the transient message text; SNACKBAR-ACTION optionally adds
an action button to it (`jetpacs-snackbar-action') — the undo
affordance.  Old companions show the plain message."
  (jetpacs--node "scaffold"
              'top_bar top-bar
              'fab fab
              'body body
              'bottom_bar bottom-bar
              'floating_toolbar floating-toolbar
              'snackbar snackbar
              'snackbar_action snackbar-action
              'drawer drawer
              'on_refresh on-refresh))

(cl-defun jetpacs-drawer (items &key header)
  "A navigation drawer spec. ITEMS is a list from `jetpacs-drawer-item'."
  (jetpacs--node nil 'header header 'items (vconcat items)))

(defun jetpacs-snackbar-action (label action)
  "An action button on the scaffold snackbar (`jetpacs-scaffold').
LABEL is the button text (\"Undo\"); ACTION dispatches only when the
user taps it — never when the snackbar times out, so a mutation stays
final unless explicitly recalled."
  (jetpacs--node nil 'label label 'on_tap action))

(cl-defun jetpacs-drawer-item (icon label action &key selected badge)
  "An item in the navigation drawer.
BADGE shows a trailing count: a number (capped at 99+ on-device) or the
empty string for a bare attention dot; nil for none."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)
              'badge badge))

(cl-defun jetpacs-top-bar (title &key nav-icon nav-action actions)
  "A TopAppBar spec."
  (jetpacs--node nil
              'title title
              'nav_icon nav-icon
              'nav_action nav-action
              'actions (and actions (vconcat actions))))

(cl-defun jetpacs-fab (icon &key label on-tap extended)
  "A FloatingActionButton spec."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_tap on-tap
              'extended (and extended t)))

(defun jetpacs-bottom-bar (items)
  "A BottomBar spec. ITEMS is a list from `jetpacs-nav-item'."
  (jetpacs--node nil 'items (vconcat items)))

(cl-defun jetpacs-nav-item (icon label action &key selected badge)
  "An item in the bottom bar.
BADGE overlays a count on the tab icon: a number (capped at 99+
on-device) or the empty string for a bare attention dot; nil for none."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)
              'badge badge))

(provide 'jetpacs-widgets)
;;; jetpacs-widgets.el ends here
