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

(defun eabp-row (&rest children)
  "A horizontal row of CHILDREN nodes."
  (eabp--node "row" 'children (vconcat children)))

(defun eabp-flow-row (&rest children)
  "A horizontal row of CHILDREN that wraps onto new lines when full.
The right container for chip/tag rows, which overflow a plain `eabp-row'."
  (eabp--node "flow_row" 'children (vconcat children)))

(defun eabp-column (&rest children)
  "A vertical column of CHILDREN nodes."
  (eabp--node "column" 'children (vconcat children)))

(cl-defun eabp-box (children &key alignment padding weight on-tap)
  "A Box wrapping CHILDREN."
  (eabp--node "box"
              'children (vconcat children)
              'alignment alignment
              'padding padding
              'weight weight
              'on_tap on-tap))

(cl-defun eabp-surface (children &key color shape elevation padding fill)
  "A Surface wrapping CHILDREN.
COLOR is a hex string or a theme token (\"primary\", \"surface_container\",
\"primary_container\", …) that adapts to the device's light/dark theme.
SHAPE is \"rounded\", \"rounded_small\", or \"circle\".  FILL stretches the
surface to full width (e.g. zebra rows in a list)."
  (eabp--node "surface"
              'children (vconcat children)
              'color color
              'shape shape
              'elevation elevation
              'padding padding
              'fill (and fill t)))

(defun eabp-lazy-column (&rest children)
  "A scrollable column of CHILDREN."
  (eabp--node "lazy_column" 'children (vconcat children)))

(cl-defun eabp-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (eabp--node "spacer" 'height height 'width width 'weight weight))

(defun eabp-divider ()
  "A horizontal divider."
  (eabp--node "divider"))

(cl-defun eabp-card (children &key on-tap padding weight on-swipe)
  "An elevated card wrapping CHILDREN."
  (eabp--node "card"
              'children (vconcat children)
              'on_tap on-tap
              'on_swipe on-swipe
              'padding padding
              'weight weight))

(cl-defun eabp-collapsible (id header children &key collapsed on-long-tap)
  "A fold/expand section. ID keys the (client-side) fold state.
HEADER is the always-visible node shown next to the chevron; CHILDREN
\(a list of nodes) are revealed when expanded. COLLAPSED non-nil starts
folded. Folding happens entirely on-device — no action round-trip.
ON-LONG-TAP, when non-nil, is an action dispatched on long-press of
the header (used by the org reader to open the heading detail view)."
  (eabp--node "collapsible"
              'id id
              'header header
              'children (vconcat children)
              'collapsed (and collapsed t)
              'on_long_tap on-long-tap))

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

(cl-defun eabp-image (url &key content-description padding)
  "An image loaded from URL (an http(s) URL or a readable file:// path)."
  (eabp--node "image"
              'url url
              'content_description content-description
              'padding padding))

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
              'value (and value (vconcat value))
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
