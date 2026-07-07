;;; eabp-widgets.el --- EABP SDUI widget constructors -*- lexical-binding: t; -*-

;; Provides all UI-tree constructors for EABP surfaces.
;; These functions build the alists that are serialized to JSON.
;;
;; Every constructor funnels through `eabp--node': type + (KEY VALUE)
;; pairs, where nil values are dropped.  That one rule replaces the old
;; per-constructor `(when x (push …))' boilerplate and keeps the wire
;; format in a single, greppable place per widget.

;;; Code:

(require 'cl-lib)

(defun eabp--node (type &rest kvs)
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

(defun eabp-text (text &optional style weight color selectable max-lines padding)
  "A text node. STYLE is title/headline/body/caption/label.
WEIGHT is the layout weight. COLOR is a hex string."
  (eabp--node "text"
              'text text
              'style (and style (format "%s" style))
              'weight weight
              'color color
              'selectable (and selectable t)
              'max_lines max-lines
              'padding padding))

(cl-defun eabp-markup (text &key syntax style padding)
  "A read-only TEXT node with optional client-side highlighting.
SYNTAX (\"org\", \"elisp\") turns on the highlighter; STYLE is the same set
as `eabp-text'. Use this for displaying code/org content; for plain labels
use `eabp-text'."
  (eabp--node "text"
              'text text
              'syntax (and syntax (format "%s" syntax))
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun eabp-rich-text (spans &key style padding)
  "A rich-text node rendering SPANS (a list from `eabp-span').
Use this for org content Emacs has already parsed into styled runs —
emphasis, links, and #tags render natively rather than as highlighted
monospace. STYLE is the base text style (title/body/caption/label)."
  (eabp--node "rich_text"
              'spans (vconcat spans)
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun eabp-span (text &key bold italic underline strike code tag baseline color bg on-tap mono)
  "A styled text run for `eabp-rich-text'.
BOLD/ITALIC/UNDERLINE/STRIKE/CODE toggle emphasis; TAG themes it like a
#hashtag; BASELINE is \"super\" or \"sub\"; COLOR is a hex foreground
override and BG a hex background (diff shading, hl-line, region, isearch);
ON-TAP makes it a clickable link.  MONO renders the run in a fixed-width
font without the code-styling background — used by the generic buffer
renderer to preserve column alignment (dired, magit, tables, ascii)."
  (eabp--node nil
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

(defun eabp--children-and-opts (args)
  "Split ARGS into (CHILDREN . OPTS) at the first keyword in ARGS.
Child nodes are alists, never keywords, so the first keyword in ARGS
marks the start of a trailing options plist.  Lets the `&rest'-children
constructors take options without breaking `(eabp-row a b c)' callers."
  (let ((i (cl-position-if #'keywordp args)))
    (if i (cons (cl-subseq args 0 i) (cl-subseq args i))
      (cons args nil))))

(defun eabp-row (&rest args)
  "A horizontal row of child nodes.
ARGS is child nodes, optionally followed by keywords: :spacing (dp
between children), :align (cross-axis \"top\"/\"center\"/\"bottom\"),
and :scroll (pan sideways on overflow)."
  (let* ((split (eabp--children-and-opts args)))
    (eabp--node "row"
                'children (vconcat (car split))
                'spacing (plist-get (cdr split) :spacing)
                'align (plist-get (cdr split) :align)
                'scroll (and (plist-get (cdr split) :scroll) t))))

(defun eabp-flow-row (&rest args)
  "A horizontal row of children that wraps onto new lines when full.
The right container for chip/tag rows, which overflow a plain `eabp-row'.
Optional trailing keywords: :spacing and :run-spacing (dp)."
  (let* ((split (eabp--children-and-opts args)))
    (eabp--node "flow_row"
                'children (vconcat (car split))
                'spacing (plist-get (cdr split) :spacing)
                'run_spacing (plist-get (cdr split) :run-spacing))))

(defun eabp-scroll-row (&rest children)
  "A horizontal row of CHILDREN that pans sideways when it overflows.
The single-line counterpart to `eabp-flow-row' (which wraps instead):
use it for chip rails that must stay on one row.  Child weights are
ignored — a scrolling row has no bounded width to distribute."
  (eabp--node "row" 'children (vconcat children) 'scroll t))

(defun eabp-column (&rest args)
  "A vertical column of child nodes.
ARGS is child nodes, optionally followed by keywords: :spacing (dp
between children), :align (cross-axis \"start\"/\"center\"/\"end\"),
and :scroll (make the column scroll vertically)."
  (let* ((split (eabp--children-and-opts args)))
    (eabp--node "column"
                'children (vconcat (car split))
                'spacing (plist-get (cdr split) :spacing)
                'align (plist-get (cdr split) :align)
                'scroll (and (plist-get (cdr split) :scroll) t))))

(defun eabp-scroll-column (&rest children)
  "A vertically scrollable column of CHILDREN nodes."
  (eabp--node "column" 'children (vconcat children) 'scroll t))

(cl-defun eabp-border (&key (width 1) color)
  "A border spec of WIDTH dp in COLOR (hex or theme token).
Pass as the :border of `eabp-box' / `eabp-surface' / `eabp-card'."
  (eabp--node nil 'width width 'color color))

(cl-defun eabp-box (children &key alignment padding weight on-tap
                             width height fill-fraction border)
  "A Box wrapping CHILDREN.
WIDTH/HEIGHT fix the box size (dp); FILL-FRACTION (0.0-1.0) sets it to a
fraction of the parent width; BORDER is an `eabp-border' spec."
  (eabp--node "box"
              'children (vconcat children)
              'alignment alignment
              'padding padding
              'weight weight
              'on_tap on-tap
              'width width
              'height height
              'fill_fraction fill-fraction
              'border border))

(cl-defun eabp-surface (children &key color shape elevation padding fill
                                 width height fill-fraction border)
  "A Surface wrapping CHILDREN.
COLOR is a hex string or a theme token (\"primary\", \"surface_container\",
\"primary_container\", …) that adapts to the device's light/dark theme.
SHAPE is \"rounded\", \"rounded_small\", or \"circle\".  FILL stretches the
surface to full width (e.g. zebra rows in a list).  WIDTH/HEIGHT fix the
size (dp), FILL-FRACTION (0.0-1.0) sets a fraction of parent width, and
BORDER is an `eabp-border' spec stroked with SHAPE."
  (eabp--node "surface"
              'children (vconcat children)
              'color color
              'shape shape
              'elevation elevation
              'padding padding
              'fill (and fill t)
              'width width
              'height height
              'fill_fraction fill-fraction
              'border border))

(defun eabp-lazy-column (&rest children)
  "A scrollable column of CHILDREN."
  (eabp--node "lazy_column" 'children (vconcat children)))

(defun eabp-scroll-here (node)
  "Mark NODE as the scroll target of its enclosing `eabp-lazy-column'.
The client scrolls the list to this child on first show and whenever
the child's index changes (e.g. new transcript output shifting a REPL's
input row down); a re-push that leaves the index unchanged never
disturbs the user's scroll position.  One target per lazy column — the
first flagged child wins."
  (append node '((scroll_here . t))))

(cl-defun eabp-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (eabp--node "spacer" 'height height 'width width 'weight weight))

(defun eabp-divider ()
  "A horizontal divider."
  (eabp--node "divider"))

(cl-defun eabp-card (children &key on-tap padding weight on-swipe
                              width height fill-fraction border)
  "An elevated card wrapping CHILDREN.
WIDTH/HEIGHT fix the size (dp), FILL-FRACTION (0.0-1.0) sets a fraction
of parent width, and BORDER is an `eabp-border' spec."
  (eabp--node "card"
              'children (vconcat children)
              'on_tap on-tap
              'on_swipe on-swipe
              'padding padding
              'weight weight
              'width width
              'height height
              'fill_fraction fill-fraction
              'border border))

(cl-defun eabp-collapsible (id header children &key collapsed on-long-tap on-swipe)
  "A fold/expand section. ID keys the (client-side) fold state.
HEADER is the always-visible node shown next to the chevron; CHILDREN
(a list of nodes) are revealed when expanded. COLLAPSED non-nil starts
folded. Folding happens entirely on-device — no action round-trip.
ON-LONG-TAP, when non-nil, is an action dispatched on long-press of
the header (used by the org reader to open the heading detail view)."
  (eabp--node "collapsible"
              'id id
              'header header
              'children (vconcat children)
              'collapsed (and collapsed t)
              'on_long_tap on-long-tap
              'on_swipe on-swipe))

(cl-defun eabp-reorderable-list (items &key on-reorder)
  "A drag-reorderable list of ITEMS.
Each item is an alist with at least (label . STRING) and (level . INT).
ON-REORDER is an action template dispatched with additional keys
\(from_pos . N) (after_pos . M) (new_level . L) when the user drops
a dragged item.  Dragging vertically reorders; horizontally promotes
or demotes."
  (eabp--node "reorderable_list"
              'items (vconcat items)
              'on_reorder on-reorder))

(cl-defun eabp-table (rows &key aligns on-add-row on-add-col padding)
  "A grid of cells with org-table semantics.
ROWS is a list from `eabp-table-row' and `eabp-table-rule'.  Columns
size to their widest cell and the grid pans horizontally on-device
when it overflows the screen — the whole table ships once.
ALIGNS is a list of per-column alignments (\"start\", \"center\",
\"end\"); columns beyond its length default to start.
ON-ADD-ROW / ON-ADD-COL, when non-nil, make the client render slim
\"+\" append affordances (a strip below the last row / a gutter after
the last column) that dispatch those actions.  The actions carry no
client-added args — embed the table's location when building them."
  (eabp--node "table"
              'rows (vconcat rows)
              'aligns (and aligns (vconcat aligns))
              'on_add_row on-add-row
              'on_add_col on-add-col
              'padding padding))

(cl-defun eabp-table-row (cells &key header)
  "A table row of CELLS (from `eabp-table-cell').
HEADER marks the row as part of the header group: the client renders
it emphasized, with a heavier rule under the group."
  (eabp--node nil
              'cells (vconcat cells)
              'header (and header t)))

(defun eabp-table-rule ()
  "A horizontal rule row (an org hline) — a divider line inside the grid."
  (eabp--node nil 'rule t))

(cl-defun eabp-table-cell (spans &key on-tap on-long-tap)
  "A table cell rendering SPANS (a list from `eabp-span').
ON-TAP / ON-LONG-TAP dispatch as-is — embed the cell's file/pos in the
action args when building it (the client adds nothing)."
  (eabp--node nil
              'spans (vconcat spans)
              'on_tap on-tap
              'on_long_tap on-long-tap))

;; ─── Interactive ─────────────────────────────────────────────────────────────

(cl-defun eabp-action (action &key args (when-offline "queue") dedupe)
  "An action descriptor."
  (eabp--node nil
              'action action
              'when_offline when-offline
              'args args
              'dedupe dedupe))

(defun eabp-clipboard-action (text)
  "A companion-local action that copies TEXT to the device clipboard.
Handled entirely on-device (like the `view.switch' builtin) — no
round-trip to Emacs, works offline."
  (eabp--node nil 'builtin "clipboard.copy" 'text text))

(cl-defun eabp-button (label action &key icon variant weight padding)
  "A button. VARIANT is filled/outlined/text/tonal."
  (eabp--node "button"
              'label label
              'on_tap action
              'icon icon
              'variant variant
              'weight weight
              'padding padding))

(cl-defun eabp-date-button (label on-pick &key value)
  "A button that opens a date picker. ON-PICK is dispatched with the chosen
date injected into its args as `value' (\"YYYY-MM-DD\"). VALUE seeds the
picker (\"YYYY-MM-DD\")."
  (eabp--node "date_button" 'label label 'on_pick on-pick 'value value))

(cl-defun eabp-time-button (label on-pick &key value)
  "A button that opens a time picker. ON-PICK is dispatched with the chosen
time injected into its args as `value' (\"HH:MM\"). VALUE seeds the picker."
  (eabp--node "time_button" 'label label 'on_pick on-pick 'value value))

(cl-defun eabp-image (url &key content-description padding
                          width height aspect-ratio content-scale)
  "An image loaded from URL (an http(s) URL or a readable file:// path).
WIDTH/HEIGHT fix the size (dp); ASPECT-RATIO (w/h) constrains it;
CONTENT-SCALE is \"fit\" (default), \"crop\", or \"fill\".  With no width or
fill given the image fills the available width, as before."
  (eabp--node "image"
              'url url
              'content_description content-description
              'padding padding
              'width width
              'height height
              'aspect_ratio aspect-ratio
              'content_scale (and content-scale (format "%s" content-scale))))

;; ─── Visualization ladder (SPEC §9) ──────────────────────────────────────────

(defun eabp--chart-point (p)
  "Normalize chart point P to a {y} / {x,y} node.
P is a number (→ {y}), or a two-element list/cons (X Y) (→ {x,y})."
  (cond ((numberp p) (eabp--node nil 'y p))
        ((consp p) (eabp--node nil 'x (car p) 'y (if (consp (cdr p)) (cadr p) (cdr p))))
        (t (eabp--node nil 'y 0))))

(cl-defun eabp-chart-series (points &key label color)
  "One chart series over POINTS (numbers, or (X Y) pairs).
LABEL and COLOR (hex or theme token) are optional."
  (eabp--node nil
              'label label
              'color color
              'points (vconcat (mapcar #'eabp--chart-point points))))

(cl-defun eabp-chart (series &key kind height y-range summary on-point-tap)
  "A data-driven chart of SERIES (a list from `eabp-chart-series').
KIND is \"line\" (default), \"bar\", \"area\", or \"sparkline\".  HEIGHT is
in dp; Y-RANGE is (MIN MAX); SUMMARY is the accessibility label;
ON-POINT-TAP fires with the tapped point injected as `value'.  Rung 1 of
the visualization ladder — data in, polished chart out, no draw ops."
  (eabp--node "chart"
              'series (vconcat series)
              'kind (and kind (format "%s" kind))
              'height height
              'y_range (and y-range (vconcat y-range))
              'summary summary
              'on_point_tap on-point-tap))

(cl-defun eabp-canvas (width height ops)
  "A canvas of WIDTH×HEIGHT dp rendering OPS (a list of draw-op nodes).
Ops come from `eabp-draw-line'/`-rect'/`-circle'/`-path'/`-text';
coordinates are in the WIDTH×HEIGHT space.  Rung 2 — the elisp-only
escape hatch for visuals no curated node covers."
  (eabp--node "canvas" 'width width 'height height 'ops (vconcat ops)))

(cl-defun eabp-draw-line (x1 y1 x2 y2 &key color stroke)
  "A canvas line op from (X1 Y1) to (X2 Y2)."
  (eabp--node nil 'op "line" 'x1 x1 'y1 y1 'x2 x2 'y2 y2
              'color color 'stroke stroke))

(cl-defun eabp-draw-rect (x y w h &key color fill stroke radius)
  "A canvas rect op at (X Y) of size W×H; FILL vs stroked; ROUNDED by RADIUS."
  (eabp--node nil 'op "rect" 'x x 'y y 'w w 'h h 'color color
              'fill (and fill t) 'stroke stroke 'radius radius))

(cl-defun eabp-draw-circle (cx cy r &key color fill stroke)
  "A canvas circle op centred (CX CY) of radius R; FILL vs stroked."
  (eabp--node nil 'op "circle" 'cx cx 'cy cy 'r r 'color color
              'fill (and fill t) 'stroke stroke))

(cl-defun eabp-draw-path (points &key color fill stroke closed)
  "A canvas path op over POINTS (a list of (X Y) pairs); FILL/CLOSED optional."
  (eabp--node nil 'op "path"
              'points (vconcat (mapcar (lambda (p) (vector (nth 0 p) (nth 1 p))) points))
              'color color 'fill (and fill t) 'stroke stroke
              'closed (and closed t)))

(cl-defun eabp-draw-text (x y text &key color size align)
  "A canvas text op drawing TEXT at (X Y); ALIGN is start/center/end."
  (eabp--node nil 'op "text" 'x x 'y y 'text text 'color color 'size size
              'align (and align (format "%s" align))))

(cl-defun eabp-icon-button (icon action &key content-description padding)
  "An icon button."
  (eabp--node "icon_button"
              'icon icon
              'on_tap action
              'content_description content-description
              'padding padding))

(cl-defun eabp-menu (items &key icon padding)
  "An overflow menu: an icon that opens a dropdown of ITEMS.
ITEMS is a list from `eabp-menu-item'. ICON defaults to a vertical
ellipsis. Folding/opening is handled entirely on-device."
  (eabp--node "menu" 'items (vconcat items) 'icon icon 'padding padding))

(cl-defun eabp-menu-item (label action &key icon)
  "An item in an overflow `eabp-menu': LABEL dispatches ACTION when tapped."
  (eabp--node nil 'label label 'on_tap action 'icon icon))

(cl-defun eabp-text-input (id &key value hint label on-submit single-line
                              multi-line min-lines max-lines monospace syntax
                              password padding)
  "A text input field.
ID identifies the field. ON-SUBMIT is an action dispatched when done.
The client defaults to single-line; pass MULTI-LINE non-nil for a box that
accepts newlines (Enter inserts a newline rather than submitting, so such a
field should be paired with a submit button). MIN-LINES/MAX-LINES size the box
and MONOSPACE renders it in a fixed-width font (handy for code).
SYNTAX (e.g. \"elisp\", \"org\") turns on client-side highlighting.
PASSWORD masks the entry (dots) and requests a password keyboard — used by
the `read-passwd' bridge; such a field's value must not be logged or
retained beyond the read."
  (eabp--node "text_input"
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
              'padding padding))

(cl-defun eabp-enum-list (id options &key value multi-select allow-add on-change padding)
  "An enum list for selecting from OPTIONS.
ID identifies the field. VALUE is a list/vector of currently selected strings.
MULTI-SELECT allows choosing multiple options. ALLOW-ADD shows an input for
adding new options. ON-CHANGE is an action dispatched when the selection
changes."
  (eabp--node "enum_list"
              'id id
              'options (vconcat options)
              ;; A bare string VALUE would vconcat into a vector of char
              ;; codes — wrap it as the one-element selection it means.
              'value (and value (vconcat (if (stringp value) (list value) value)))
              'multi_select (and multi-select t)
              'allow_add (and allow-add t)
              'on_change on-change
              'padding padding))

(cl-defun eabp-checkbox (id &key checked label on-change padding)
  "A checkbox."
  (eabp--node "checkbox"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun eabp-switch (id &key checked label on-change padding)
  "A toggle switch."
  (eabp--node "switch"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun eabp-slider (id on-change &key value min max steps)
  "A continuous slider identified by ID.
ON-CHANGE fires once on release with the position injected into args as
`value'.  VALUE seeds the position; MIN/MAX bound the range (default
0.0/1.0); STEPS, when > 0, makes the slider discrete."
  (eabp--node "slider"
              'id id
              'on_change on-change
              'value value
              'min min
              'max max
              'steps steps))

;; ─── Display ─────────────────────────────────────────────────────────────────

(cl-defun eabp-icon (name &key size color padding)
  "An icon display."
  (eabp--node "icon" 'name name 'size size 'color color 'padding padding))

(cl-defun eabp-chip (label &key on-tap selected icon padding)
  "A filter chip."
  (eabp--node "chip"
              'label label
              'on_tap on-tap
              'selected (and selected t)
              'icon icon
              'padding padding))

(cl-defun eabp-progress (&key variant value padding)
  "A progress indicator. VARIANT is circular/linear. VALUE is 0.0-1.0."
  (eabp--node "progress" 'variant variant 'value value 'padding padding))

(cl-defun eabp-assist-chip (label &key on-tap icon padding)
  "An assist chip (e.g. a #tag). LABEL is shown; ON-TAP fires on click.
Unlike `eabp-chip' (a selectable filter chip) this is a flat, tappable
suggestion chip — pair it with `eabp-flow-row' for wrapping tag rows."
  (eabp--node "assist_chip"
              'label label
              'on_tap on-tap
              'icon icon
              'padding padding))

(cl-defun eabp-section-header (title &key trailing padding)
  "A styled section label. TRAILING is an optional node shown at the end
\(e.g. a count or an `eabp-icon-button')."
  (eabp--node "section_header" 'title title 'trailing trailing 'padding padding))

(cl-defun eabp-empty-state (&key icon title caption on-tap action-label padding)
  "A centered empty-state placeholder.
ICON names a glyph (default \"inbox\"); TITLE and CAPTION describe the
emptiness. When ON-TAP and ACTION-LABEL are both given, an outlined
button is shown beneath the text."
  (eabp--node "empty_state"
              'icon icon
              'title title
              'caption caption
              'on_tap on-tap
              'action_label action-label
              'padding padding))

(defconst eabp--month-abbrevs
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
   "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
  "Short month labels used by `eabp-date-stamp'.")

(cl-defun eabp-date-stamp (&key date day month month-index year time padding)
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
            month (or month (aref eabp--month-abbrevs (1- m)))
            day (or day (number-to-string d)))))
  (eabp--node "date_stamp"
              'day (and day (format "%s" day))
              'month month
              'month_index month-index
              'year (and year (format "%s" year))
              'time time
              'padding padding))

;; ─── Home-screen widgets ─────────────────────────────────────────────────────
;;
;; Rows for `widget:*' surfaces (the home-screen list widgets, including
;; the blank `widget:customN' slots). The companion renders these with
;; RemoteViews, so the vocabulary is deliberately small: two-line rows
;; with an optional trailing icon button, plus bold section dividers.

(cl-defun eabp-widget-item (text &key todo done meta icon on-tap in-app
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
  (eabp--node nil
              'text text
              'todo todo
              'done (and done t)
              'meta meta
              'icon icon
              'on_tap on-tap
              'tap_in_app (and in-app t)
              'button button
              'on_button on-button))

(defun eabp-widget-divider (label)
  "A bold section divider row (\"Overdue\", \"Today\") in a widget list."
  (eabp--node nil 'divider label))

(cl-defun eabp-tile (label &key subtitle icon state on-tap in-app)
  "A Quick Settings tile spec for a `tile:customN' slot surface.
LABEL and SUBTITLE are the tile texts (the subtitle shows on Android
10+). ICON names a glyph: \"todo_open\", \"todo_done\", \"add\",
\"refresh\", \"scheduled\", \"deadline\", \"event\", or \"folder\".
STATE is \"active\", \"inactive\" (the default), or \"unavailable\".
ON-TAP is dispatched when the tile is tapped; IN-APP opens the
companion app and routes the action through it, otherwise the tap
fires silently from the shade (no unlock required — compose
accordingly). An un-pushed slot shows as a grayed-out tile."
  (eabp--node nil
              'label label
              'subtitle subtitle
              'icon icon
              'state (and state (format "%s" state))
              'on_tap on-tap
              'tap_in_app (and in-app t)))

;; ─── Scaffold ────────────────────────────────────────────────────────────────

(cl-defun eabp-editor (id value &key on-save read-only syntax line-numbers
                          complete chromeless publish-state toolbar)
  "A full-height plain-text editor node.
ID identifies the editor (its unsaved state lives companion-side under
this key). VALUE seeds the buffer. ON-SAVE is dispatched with the full
text injected into args as `value'. READ-ONLY disables editing/saving.
SYNTAX (\"elisp\", \"org\") forces highlighting; when omitted the client
infers it from the file extension in ID.  LINE-NUMBERS is \"absolute\"
or \"relative\" (relative to the cursor) for a gutter, nil for none.
COMPLETE enables Emacs-backed completion: the client sends debounced
`edit.complete' actions while typing and renders the returned candidates
as a suggestion strip (see eabp-complete.el).
CHROMELESS hides the filename/undo/save header and sizes the field
compactly instead of full-height — an inline field with the full bridge
\(completion, squiggles, doc line), e.g. the eval REPL input.
PUBLISH-STATE emits debounced `state.changed' with the text under ID,
so button-driven forms can read it back from `eabp-ui-state'.
TOOLBAR names a keyboard-adjacent formatting toolbar the client should
attach (\"org\" today); nil for none.  Server-driven so the renderer
stays app-agnostic: the app opts an editor into the affordance."
  (eabp--node "editor"
              'id id
              'value value
              'on_save on-save
              'read_only (and read-only t)
              'syntax syntax
              'line_numbers line-numbers
              'complete (and complete t)
              'chromeless (and chromeless t)
              'publish_state (and publish-state t)
              'toolbar toolbar))

(cl-defun eabp-scaffold (&key top-bar fab body bottom-bar floating-toolbar snackbar drawer on-refresh)
  "The standard app frame."
  (eabp--node "scaffold"
              'top_bar top-bar
              'fab fab
              'body body
              'bottom_bar bottom-bar
              'floating_toolbar floating-toolbar
              'snackbar snackbar
              'drawer drawer
              'on_refresh on-refresh))

(cl-defun eabp-drawer (items &key header)
  "A navigation drawer spec. ITEMS is a list from `eabp-drawer-item'."
  (eabp--node nil 'header header 'items (vconcat items)))

(cl-defun eabp-drawer-item (icon label action &key selected)
  "An item in the navigation drawer."
  (eabp--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)))

(cl-defun eabp-top-bar (title &key nav-icon nav-action actions)
  "A TopAppBar spec."
  (eabp--node nil
              'title title
              'nav_icon nav-icon
              'nav_action nav-action
              'actions (and actions (vconcat actions))))

(cl-defun eabp-fab (icon &key label on-tap extended)
  "A FloatingActionButton spec."
  (eabp--node nil
              'icon icon
              'label label
              'on_tap on-tap
              'extended (and extended t)))

(defun eabp-bottom-bar (items)
  "A BottomBar spec. ITEMS is a list from `eabp-nav-item'."
  (eabp--node nil 'items (vconcat items)))

(cl-defun eabp-nav-item (icon label action &key selected)
  "An item in the bottom bar."
  (eabp--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)))

(provide 'eabp-widgets)
;;; eabp-widgets.el ends here
