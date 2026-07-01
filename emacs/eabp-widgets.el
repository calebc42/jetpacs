;;; eabp-widgets.el --- EABP SDUI widget constructors -*- lexical-binding: t; -*-

;; Provides all UI-tree constructors for EABP surfaces.
;; These functions build the alists that are serialized to JSON.

;;; Code:

(require 'cl-lib)

;; ─── Core & Layout ───────────────────────────────────────────────────────────

(defun eabp-text (text &optional style weight color selectable max-lines padding)
  "A text node. STYLE is title/headline/body/caption/label.
WEIGHT is the layout weight. COLOR is a hex string."
  (let ((node `((t . "text") (text . ,text))))
    (when style (push `(style . ,(format "%s" style)) node))
    (when weight (push `(weight . ,weight) node))
    (when color (push `(color . ,color) node))
    (when selectable (push `(selectable . t) node))
    (when max-lines (push `(max_lines . ,max-lines) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-markup (text &key syntax style padding)
  "A read-only TEXT node with optional client-side highlighting.
SYNTAX (\"org\", \"elisp\") turns on the highlighter; STYLE is the same set
as `eabp-text'. Use this for displaying code/org content; for plain labels
use `eabp-text'."
  (let ((node `((t . "text") (text . ,text))))
    (when syntax (push `(syntax . ,(format "%s" syntax)) node))
    (when style (push `(style . ,(format "%s" style)) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-rich-text (spans &key style padding)
  "A rich-text node rendering SPANS (a list from `eabp-span').
Use this for org content Emacs has already parsed into styled runs —
emphasis, links, and #tags render natively rather than as highlighted
monospace. STYLE is the base text style (title/body/caption/label)."
  (let ((node `((t . "rich_text") (spans . ,(vconcat spans)))))
    (when style (push `(style . ,(format "%s" style)) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-span (text &key bold italic underline strike code tag baseline color on-tap mono)
  "A styled text run for `eabp-rich-text'.
BOLD/ITALIC/UNDERLINE/STRIKE/CODE toggle emphasis; TAG themes it like a
#hashtag; BASELINE is \"super\" or \"sub\"; COLOR is a hex override; ON-TAP
makes it a clickable link.  MONO renders the run in a fixed-width font
without the code-styling background — used by the generic buffer renderer to
preserve column alignment (dired, magit, tables, ascii)."
  (let ((node `((text . ,text))))
    (when bold      (push '(bold . t) node))
    (when italic    (push '(italic . t) node))
    (when underline (push '(underline . t) node))
    (when strike    (push '(strike . t) node))
    (when code      (push '(code . t) node))
    (when tag       (push '(tag . t) node))
    (when baseline  (push `(baseline . ,baseline) node))
    (when color     (push `(color . ,color) node))
    (when on-tap    (push `(on_tap . ,on-tap) node))
    (when mono      (push '(mono . t) node))
    node))

(defun eabp-row (&rest children)
  "A horizontal row of CHILDREN nodes."
  `((t . "row") (children . ,(vconcat children))))

(defun eabp-flow-row (&rest children)
  "A horizontal row of CHILDREN that wraps onto new lines when full.
The right container for chip/tag rows, which overflow a plain `eabp-row'."
  `((t . "flow_row") (children . ,(vconcat children))))

(defun eabp-column (&rest children)
  "A vertical column of CHILDREN nodes."
  `((t . "column") (children . ,(vconcat children))))

(cl-defun eabp-box (children &key alignment padding weight on-tap)
  "A Box wrapping CHILDREN."
  (let ((node `((t . "box") (children . ,(vconcat children)))))
    (when alignment (push `(alignment . ,alignment) node))
    (when padding (push `(padding . ,padding) node))
    (when weight (push `(weight . ,weight) node))
    (when on-tap (push `(on_tap . ,on-tap) node))
    node))

(cl-defun eabp-surface (children &key color shape elevation padding)
  "A Surface wrapping CHILDREN."
  (let ((node `((t . "surface") (children . ,(vconcat children)))))
    (when color (push `(color . ,color) node))
    (when shape (push `(shape . ,shape) node))
    (when elevation (push `(elevation . ,elevation) node))
    (when padding (push `(padding . ,padding) node))
    node))

(defun eabp-lazy-column (&rest children)
  "A scrollable column of CHILDREN."
  `((t . "lazy_column") (children . ,(vconcat children))))

(cl-defun eabp-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (let ((node `((t . "spacer"))))
    (when height (push `(height . ,height) node))
    (when width (push `(width . ,width) node))
    (when weight (push `(weight . ,weight) node))
    node))

(defun eabp-divider ()
  "A horizontal divider."
  `((t . "divider")))

(cl-defun eabp-card (children &key on-tap padding weight)
  "An elevated card wrapping CHILDREN."
  (let ((node `((t . "card") (children . ,(vconcat children)))))
    (when on-tap (push `(on_tap . ,on-tap) node))
    (when padding (push `(padding . ,padding) node))
    (when weight (push `(weight . ,weight) node))
    node))

(cl-defun eabp-collapsible (id header children &key collapsed on-long-tap)
  "A fold/expand section. ID keys the (client-side) fold state.
HEADER is the always-visible node shown next to the chevron; CHILDREN
\(a list of nodes) are revealed when expanded. COLLAPSED non-nil starts
folded. Folding happens entirely on-device — no action round-trip.
ON-LONG-TAP, when non-nil, is an action dispatched on long-press of
the header (used by the org reader to open the heading detail view)."
  (let ((node `((t . "collapsible") (id . ,id) (header . ,header)
                (children . ,(vconcat children)))))
    (when collapsed (push `(collapsed . t) node))
    (when on-long-tap (push `(on_long_tap . ,on-long-tap) node))
    node))

;; ─── Interactive ─────────────────────────────────────────────────────────────

(cl-defun eabp-action (action &key args (when-offline "queue") dedupe)
  "An action descriptor."
  (let ((node `((action . ,action) (when_offline . ,when-offline))))
    (when args   (push `(args . ,args) node))
    (when dedupe (push `(dedupe . ,dedupe) node))
    node))

(cl-defun eabp-button (label action &key icon variant weight padding)
  "A button. VARIANT is filled/outlined/text/tonal."
  (let ((node `((t . "button") (label . ,label) (on_tap . ,action))))
    (when icon (push `(icon . ,icon) node))
    (when variant (push `(variant . ,variant) node))
    (when weight (push `(weight . ,weight) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-date-button (label on-pick &key value)
  "A button that opens a date picker. ON-PICK is dispatched with the chosen
date injected into its args as `value' (\"YYYY-MM-DD\"). VALUE seeds the
picker (\"YYYY-MM-DD\")."
  (let ((node `((t . "date_button") (label . ,label) (on_pick . ,on-pick))))
    (when value (push `(value . ,value) node))
    node))

(cl-defun eabp-time-button (label on-pick &key value)
  "A button that opens a time picker. ON-PICK is dispatched with the chosen
time injected into its args as `value' (\"HH:MM\"). VALUE seeds the picker."
  (let ((node `((t . "time_button") (label . ,label) (on_pick . ,on-pick))))
    (when value (push `(value . ,value) node))
    node))

(cl-defun eabp-image (url &key content-description padding)
  "An image loaded from URL (an http(s) URL or a readable file:// path)."
  (let ((node `((t . "image") (url . ,url))))
    (when content-description (push `(content_description . ,content-description) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-icon-button (icon action &key content-description padding)
  "An icon button."
  (let ((node `((t . "icon_button") (icon . ,icon) (on_tap . ,action))))
    (when content-description (push `(content_description . ,content-description) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-menu (items &key icon padding)
  "An overflow menu: an icon that opens a dropdown of ITEMS.
ITEMS is a list from `eabp-menu-item'. ICON defaults to a vertical
ellipsis. Folding/opening is handled entirely on-device."
  (let ((node `((t . "menu") (items . ,(vconcat items)))))
    (when icon (push `(icon . ,icon) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-menu-item (label action &key icon)
  "An item in an overflow `eabp-menu': LABEL dispatches ACTION when tapped."
  (let ((node `((label . ,label) (on_tap . ,action))))
    (when icon (push `(icon . ,icon) node))
    node))

(cl-defun eabp-text-input (id &key value hint label on-submit single-line
                              multi-line min-lines max-lines monospace syntax padding)
  "A text input field.
ID identifies the field. ON-SUBMIT is an action dispatched when done.
The client defaults to single-line; pass MULTI-LINE non-nil for a box that
accepts newlines (Enter inserts a newline rather than submitting, so such a
field should be paired with a submit button). MIN-LINES/MAX-LINES size the box
and MONOSPACE renders it in a fixed-width font (handy for code)."
  (let ((node `((t . "text_input") (id . ,id))))
    (when value (push `(value . ,value) node))
    (when hint (push `(hint . ,hint) node))
    (when label (push `(label . ,label) node))
    (when on-submit (push `(on_submit . ,on-submit) node))
    (when single-line (push `(single_line . t) node))
    ;; `:false' (not t) so the client overrides its single-line default.
    (when multi-line (push `(single_line . :false) node))
    (when min-lines (push `(min_lines . ,min-lines) node))
    (when max-lines (push `(max_lines . ,max-lines) node))
    (when monospace (push `(monospace . t) node))
    ;; SYNTAX (e.g. "elisp", "org") turns on client-side highlighting.
    (when syntax (push `(syntax . ,syntax) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-enum-list (id options &key value multi-select allow-add on-change padding)
  "An enum list for selecting from OPTIONS.
ID identifies the field. VALUE is a list/vector of currently selected strings.
MULTI-SELECT allows choosing multiple options. ALLOW-ADD shows an input to add new options.
ON-CHANGE is an action dispatched when the selection changes."
  (let ((node `((t . "enum_list") (id . ,id) (options . ,(vconcat options)))))
    (when value (push `(value . ,(vconcat value)) node))
    (when multi-select (push `(multi_select . t) node))
    (when allow-add (push `(allow_add . t) node))
    (when on-change (push `(on_change . ,on-change) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-checkbox (id &key checked label on-change padding)
  "A checkbox."
  (let ((node `((t . "checkbox") (id . ,id))))
    (when checked (push `(checked . t) node))
    (when label (push `(label . ,label) node))
    (when on-change (push `(on_change . ,on-change) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-switch (id &key checked label on-change padding)
  "A toggle switch."
  (let ((node `((t . "switch") (id . ,id))))
    (when checked (push `(checked . t) node))
    (when label (push `(label . ,label) node))
    (when on-change (push `(on_change . ,on-change) node))
    (when padding (push `(padding . ,padding) node))
    node))

;; ─── Display ─────────────────────────────────────────────────────────────────

(cl-defun eabp-icon (name &key size color padding)
  "An icon display."
  (let ((node `((t . "icon") (name . ,name))))
    (when size (push `(size . ,size) node))
    (when color (push `(color . ,color) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-chip (label &key on-tap selected icon padding)
  "A filter chip."
  (let ((node `((t . "chip") (label . ,label))))
    (when on-tap (push `(on_tap . ,on-tap) node))
    (when selected (push `(selected . t) node))
    (when icon (push `(icon . ,icon) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-progress (&key variant value padding)
  "A progress indicator. VARIANT is circular/linear. VALUE is 0.0-1.0."
  (let ((node `((t . "progress"))))
    (when variant (push `(variant . ,variant) node))
    (when value (push `(value . ,value) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-assist-chip (label &key on-tap icon padding)
  "An assist chip (e.g. a #tag). LABEL is shown; ON-TAP fires on click.
Unlike `eabp-chip' (a selectable filter chip) this is a flat, tappable
suggestion chip — pair it with `eabp-flow-row' for wrapping tag rows."
  (let ((node `((t . "assist_chip") (label . ,label))))
    (when on-tap (push `(on_tap . ,on-tap) node))
    (when icon (push `(icon . ,icon) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-section-header (title &key trailing padding)
  "A styled section label. TRAILING is an optional node shown at the end
\(e.g. a count or an `eabp-icon-button')."
  (let ((node `((t . "section_header") (title . ,title))))
    (when trailing (push `(trailing . ,trailing) node))
    (when padding (push `(padding . ,padding) node))
    node))

(cl-defun eabp-empty-state (&key icon title caption on-tap action-label padding)
  "A centered empty-state placeholder.
ICON names a glyph (default \"inbox\"); TITLE and CAPTION describe the
emptiness. When ON-TAP and ACTION-LABEL are both given, an outlined
button is shown beneath the text."
  (let ((node `((t . "empty_state"))))
    (when icon (push `(icon . ,icon) node))
    (when title (push `(title . ,title) node))
    (when caption (push `(caption . ,caption) node))
    (when on-tap (push `(on_tap . ,on-tap) node))
    (when action-label (push `(action_label . ,action-label) node))
    (when padding (push `(padding . ,padding) node))
    node))

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
  (let ((node `((t . "date_stamp"))))
    (when day (push `(day . ,(format "%s" day)) node))
    (when month (push `(month . ,month) node))
    (when month-index (push `(month_index . ,month-index) node))
    (when year (push `(year . ,(format "%s" year)) node))
    (when time (push `(time . ,time) node))
    (when padding (push `(padding . ,padding) node))
    node))

;; ─── Scaffold ────────────────────────────────────────────────────────────────

(cl-defun eabp-editor (id value &key on-save read-only syntax)
  "A full-height plain-text editor node.
ID identifies the editor (its unsaved state lives companion-side under
this key). VALUE seeds the buffer. ON-SAVE is dispatched with the full
text injected into args as `value'. READ-ONLY disables editing/saving.
SYNTAX (\"elisp\", \"org\") forces highlighting; when omitted the client
infers it from the file extension in ID."
  (let ((node `((t . "editor") (id . ,id) (value . ,value))))
    (when on-save (push `(on_save . ,on-save) node))
    (when read-only (push `(read_only . t) node))
    (when syntax (push `(syntax . ,syntax) node))
    node))

(cl-defun eabp-scaffold (&key top-bar fab body bottom-bar snackbar drawer)
  "A full-screen scaffold wrapper.
DRAWER (see `eabp-drawer') adds a hamburger navigation drawer whose
open/close state is handled entirely companion-side."
  (let ((node `((t . "scaffold"))))
    (when top-bar (push `(top_bar . ,top-bar) node))
    (when fab (push `(fab . ,fab) node))
    (when body (push `(body . ,body) node))
    (when bottom-bar (push `(bottom_bar . ,bottom-bar) node))
    (when snackbar (push `(snackbar . ,snackbar) node))
    (when drawer (push `(drawer . ,drawer) node))
    node))

(cl-defun eabp-drawer (items &key header)
  "A navigation drawer spec. ITEMS is a list from `eabp-drawer-item'."
  (append (when header `((header . ,header)))
          `((items . ,(vconcat items)))))

(cl-defun eabp-drawer-item (icon label action &key selected)
  "An item in the navigation drawer."
  (let ((node `((icon . ,icon) (label . ,label) (on_tap . ,action))))
    (when selected (push `(selected . t) node))
    node))

(cl-defun eabp-top-bar (title &key nav-icon nav-action actions)
  "A TopAppBar spec."
  (let ((node `((title . ,title))))
    (when nav-icon (push `(nav_icon . ,nav-icon) node))
    (when nav-action (push `(nav_action . ,nav-action) node))
    (when actions (push `(actions . ,(vconcat actions)) node))
    node))

(cl-defun eabp-fab (icon &key label on-tap extended)
  "A FloatingActionButton spec."
  (let ((node `((icon . ,icon))))
    (when label (push `(label . ,label) node))
    (when on-tap (push `(on_tap . ,on-tap) node))
    (when extended (push `(extended . t) node))
    node))

(defun eabp-bottom-bar (items)
  "A BottomBar spec. ITEMS is a list from `eabp-nav-item'."
  `((items . ,(vconcat items))))

(cl-defun eabp-nav-item (icon label action &key selected)
  "An item in the bottom bar."
  (let ((node `((icon . ,icon) (label . ,label) (on_tap . ,action))))
    (when selected (push `(selected . t) node))
    node))

(provide 'eabp-widgets)
;;; eabp-widgets.el ends here
