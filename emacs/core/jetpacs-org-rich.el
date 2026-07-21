;;; jetpacs-org-rich.el --- Org → rich-text SDUI emitter -*- lexical-binding: t; -*-

;; Turns org content into Jetpacs `rich_text' nodes (styled span runs) instead of
;; the syntax-highlighted monospace `jetpacs-markup' produces. Emacs does the
;; parsing via `org-element', so the device never re-parses org — it only paints
;; the spans. Inline emphasis (bold/italic/underline/strike/code/verbatim),
;; links (tappable), timestamps, and #hashtags all map to native styling.
;;
;; Block-level content that doesn't fit a single styled paragraph — source
;; blocks, example blocks — falls back to `jetpacs-markup' so code keeps its
;; highlighted, fixed-width look.  Org tables render as native `table' grids
;; (tap-to-edit, long-press row/column menu, and add-row/add-column when
;; file context is supplied); table.el tables keep the markup fallback.
;; Babel #+RESULTS content renders read-only inside a foldable section —
;; execution regenerates it, so hand edits would be silently lost.
;;
;; Entry point: `jetpacs-org-rich-body' (an org body string -> a list of nodes).

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-table)
(require 'cl-lib)
(require 'jetpacs-widgets)

;; ─── Dynamic context for interactive elements ───────────────────────────────

(defvar jetpacs-org-rich--file nil
  "File path being rendered; enables interactive checkboxes when non-nil.")

(defvar jetpacs-org-rich--body-offset nil
  "Offset mapping temp-buffer positions to real-file positions.
real-pos = offset + temp-pos.  Set by `jetpacs-org-rich-body' when
FILE and OFFSET are supplied.")

(defvar jetpacs-org-rich--skip-drawers nil
  "Drawer names (upcased) the current render should omit.
Bound by callers that present a drawer's content in their own way —
the heading detail view parses LOGBOOK into a structured section, so
rendering the raw drawer too would double it.")

(defvar jetpacs-org-rich--read-only nil
  "Non-nil while rendering babel #+RESULTS content.
Suppresses edit affordances (table cell taps, row/column menus,
checkbox toggles) — execution regenerates results, so a hand edit
would be silently overwritten by the next run.")

;; ─── Inline spans ────────────────────────────────────────────────────────────

(defun jetpacs-org-rich--flag (style key)
  "Return STYLE (a plist of emphasis flags) with KEY turned on.
Prepended so `plist-get' sees the new value first; STYLE is never mutated."
  (cons key (cons t style)))

(defun jetpacs-org-rich--leaf (text style)
  "Build a span for TEXT carrying the emphasis flags set in STYLE."
  (apply #'jetpacs-span (or text "")
         (append (when (plist-get style :bold)      '(:bold t))
                 (when (plist-get style :italic)    '(:italic t))
                 (when (plist-get style :underline) '(:underline t))
                 (when (plist-get style :strike)    '(:strike t))
                 (when (plist-get style :code)      '(:code t))
                 (when (plist-get style :tag)       '(:tag t))
                 (when (plist-get style :baseline)
                   (list :baseline (plist-get style :baseline))))))

(defconst jetpacs-org-rich--image-re
  "\\.\\(png\\|jpe?g\\|gif\\|webp\\|bmp\\|svg\\)\\'"
  "Matches link targets that should render as inline images.")

(defun jetpacs-org-rich--image-url (type target)
  "Return a renderable URL for a link of TYPE to TARGET if it's an image.
http(s) image URLs pass through; local file/attachment paths become
file:// URIs the companion can try to load. Returns nil for non-images."
  (when (and (stringp target)
             (string-match-p jetpacs-org-rich--image-re (downcase target)))
    (let ((ty (and type (downcase type))))
      (cond
       ((member ty '("http" "https")) (concat ty ":" target))
       ((or (null ty) (equal ty "file"))
        (concat "file://" (expand-file-name target)))
       ((equal ty "attachment")
        (let ((dir (ignore-errors (org-attach-dir))))
          (when dir (concat "file://" (expand-file-name target dir)))))))))

(defun jetpacs-org-rich--text-spans (text style)
  "Split TEXT into plain runs and #hashtag runs, all under STYLE.
A hashtag must follow start-of-string or a non-word character, so `C#'
and URL fragments aren't mistaken for tags."
  (let ((spans nil) (start 0) (len (length text)))
    (while (string-match "\\(?:^\\|[^[:alnum:]_]\\)\\(#[[:alnum:]_-]+\\)" text start)
      (let ((mb (match-beginning 1)) (me (match-end 1)))
        (when (> mb start)
          (push (jetpacs-org-rich--leaf (substring text start mb) style) spans))
        (push (jetpacs-org-rich--leaf (substring text mb me)
                                   (jetpacs-org-rich--flag style :tag))
              spans)
        (setq start me)))
    (when (< start len)
      (push (jetpacs-org-rich--leaf (substring text start) style) spans))
    (nreverse spans)))

(defun jetpacs-org-rich--linkify (spans action)
  "Attach ON-TAP ACTION to every span in SPANS that doesn't already have one."
  (mapcar (lambda (sp)
            (if (assq 'on_tap sp) sp (cons (cons 'on_tap action) sp)))
          spans))

(defun jetpacs-org-rich--inline (objects style)
  "Convert a list of org inline OBJECTS (strings and elements) to spans.
STYLE carries inherited emphasis flags as recursion descends into
bold/italic/... containers.

Whitespace following an object belongs to the object as `:post-blank'
— it is absent from both the object's contents and the next sibling
string — so every non-string object re-emits it as a plain span, or
words jam together after emphasis, links, and timestamps."
  (let (spans)
    (dolist (obj objects)
      (cond
       ((stringp obj)
        (setq spans (append spans (jetpacs-org-rich--text-spans obj style))))
       ((null obj) nil)
       (t
        (pcase (org-element-type obj)
          ('bold (setq spans (append spans
                                     (jetpacs-org-rich--inline
                                      (org-element-contents obj)
                                      (jetpacs-org-rich--flag style :bold)))))
          ('italic (setq spans (append spans
                                       (jetpacs-org-rich--inline
                                        (org-element-contents obj)
                                        (jetpacs-org-rich--flag style :italic)))))
          ('underline (setq spans (append spans
                                          (jetpacs-org-rich--inline
                                           (org-element-contents obj)
                                           (jetpacs-org-rich--flag style :underline)))))
          ('strike-through (setq spans (append spans
                                               (jetpacs-org-rich--inline
                                                (org-element-contents obj)
                                                (jetpacs-org-rich--flag style :strike)))))
          ('code (setq spans (append spans
                                     (list (jetpacs-org-rich--leaf
                                            (org-element-property :value obj)
                                            (jetpacs-org-rich--flag style :code))))))
          ('verbatim (setq spans (append spans
                                         (list (jetpacs-org-rich--leaf
                                                (org-element-property :value obj)
                                                (jetpacs-org-rich--flag style :code))))))
          ('link
           (let* ((raw (org-element-property :raw-link obj))
                  (contents (org-element-contents obj))
                  (child (if contents
                             (jetpacs-org-rich--inline contents style)
                           (list (jetpacs-org-rich--leaf (or raw "link") style))))
                  (action (jetpacs-action "org.link.open"
                                       :args (list (cons 'link raw)))))
             (setq spans (append spans (jetpacs-org-rich--linkify child action)))))
          ('timestamp
           (setq spans (append spans
                               (list (jetpacs-org-rich--leaf
                                      (org-element-property :raw-value obj)
                                      (jetpacs-org-rich--flag style :code))))))
          ('entity
           ;; Render org entities (\alpha, \rightarrow, …) as their Unicode form.
           (let ((utf8 (or (org-element-property :utf-8 obj)
                           (org-element-property :name obj))))
             (when utf8
               (setq spans (append spans (list (jetpacs-org-rich--leaf utf8 style)))))))
          ('subscript
           (setq spans (append spans
                               (jetpacs-org-rich--inline
                                (org-element-contents obj)
                                (cons :baseline (cons "sub" style))))))
          ('superscript
           (setq spans (append spans
                               (jetpacs-org-rich--inline
                                (org-element-contents obj)
                                (cons :baseline (cons "super" style))))))
          ('footnote-reference
           ;; A superscript, link-colored marker; tapping reports the inline
           ;; definition (when the reference carries one) via snackbar.
           (let* ((label (org-element-property :label obj))
                  (marker (format "[%s]" (if (and (stringp label)
                                                  (string-prefix-p "fn:" label))
                                             (substring label 3)
                                           (or label "*"))))
                  (def (string-trim
                        (or (ignore-errors
                              (org-element-interpret-data
                               (org-element-contents obj)))
                            "")))
                  (action (jetpacs-action "org.footnote.show"
                                       :args (list (cons 'label (or label ""))
                                                   (cons 'def def)))))
             (setq spans
                   (append spans
                           (list (jetpacs-span marker
                                            :baseline "super"
                                            :tag t
                                            :on-tap action))))))
          ('line-break
           (setq spans (append spans (list (jetpacs-span "\n")))))
          (_
           ;; Anything else (latex fragment, export snippet, …): fall back to
           ;; its interpreted source text.
           (let ((txt (ignore-errors (org-element-interpret-data obj))))
             (when (stringp txt)
               (setq spans (append spans
                                   (jetpacs-org-rich--text-spans
                                    (string-trim-right txt) style)))))))
        (let ((pb (or (org-element-property :post-blank obj) 0)))
          (when (> pb 0)
            (setq spans (append spans
                                (list (jetpacs-org-rich--leaf
                                       (make-string pb ?\s) style)))))))))
    spans))

;; ─── Block elements ──────────────────────────────────────────────────────────

(defun jetpacs-org-rich--item (item)
  "Render a plain-list ITEM to a node (bullet/number + content, plus sub-elements).

When `jetpacs-org-rich--file' and `jetpacs-org-rich--body-offset' are set
(the reader passes them), checkbox items get a tappable icon that
toggles the checkbox via Emacs without entering edit mode."
  (let* ((bullet (or (org-element-property :bullet item) "- "))
         (checkbox (org-element-property :checkbox item))
         (contents (org-element-contents item))
         (para (cl-find-if (lambda (c) (eq (org-element-type c) 'paragraph)) contents))
         (inline (when para (jetpacs-org-rich--inline (org-element-contents para) nil)))
         (lead-text (concat (string-trim-right bullet) " "))
         (head
          (if (and checkbox jetpacs-org-rich--file jetpacs-org-rich--body-offset
                   (not jetpacs-org-rich--read-only))
              ;; Interactive checkbox — a tappable icon beside the item text.
              (let* ((checked (eq checkbox 'on))
                     (item-pos (+ jetpacs-org-rich--body-offset
                                  (org-element-property :begin item)))
                     (cb-icon (pcase checkbox
                                ('on  "check_box")
                                ('off "check_box_outline_blank")
                                (_    "indeterminate_check_box")))
                     (cb (jetpacs-box
                          (list (jetpacs-icon cb-icon :size 20))
                          :on-tap (jetpacs-action
                                   "checkbox.toggle"
                                   :args `((file . ,jetpacs-org-rich--file)
                                           (pos  . ,item-pos))))))
                (jetpacs-row cb
                          (jetpacs-box
                           (list (jetpacs-rich-text
                                  (cons (jetpacs-span lead-text)
                                        (or inline (list (jetpacs-span ""))))))
                           :weight 1)))
            ;; No checkbox, or no file context — plain text as before.
            (let* ((mark (pcase checkbox
                           ('on "☑ ") ('off "☐ ") ('trans "◪ ") (_ "")))
                   (lead (jetpacs-span (concat lead-text mark))))
              (jetpacs-rich-text (cons lead (or inline (list (jetpacs-span ""))))))))
         (rest-contents (delq para (copy-sequence contents)))
         (sub-nodes (delq nil (mapcar #'jetpacs-org-rich--element rest-contents))))
    (if sub-nodes
        (jetpacs-column head
                     (jetpacs-row (jetpacs-spacer :width 16)
                               (jetpacs-box (list (apply #'jetpacs-column sub-nodes)) :weight 1)))
      head)))

(defun jetpacs-org-rich--list (el)
  "Render a plain-list EL to a column of item nodes."
  (let ((items (delq nil
                     (mapcar (lambda (item)
                               (when (eq (org-element-type item) 'item)
                                 (jetpacs-org-rich--item item)))
                             (org-element-contents el)))))
    (when items (apply #'jetpacs-column items))))

;; ─── Source blocks ───────────────────────────────────────────────────────────

(defun jetpacs-org-rich--src-block (el)
  "Render src-block EL: highlighted code, plus a run header when executable.
The header (language label + play button dispatching `org.babel.execute')
appears only when file context is present *and* this Emacs has an
`org-babel-execute:LANG' function — the same test execution would make,
so the button never promises more than `org-babel-load-languages'
delivers.  The action carries the block's real-file position; the code
itself never crosses the wire."
  (let* ((lang (org-element-property :language el))
         (code (jetpacs-markup (or (org-element-property :value el) "")
                            :syntax (or lang "text")))
         (pos (and jetpacs-org-rich--file jetpacs-org-rich--body-offset
                   lang
                   (fboundp (intern (concat "org-babel-execute:" lang)))
                   (+ jetpacs-org-rich--body-offset
                      (org-element-property :post-affiliated el)))))
    (if (not pos)
        code
      (jetpacs-column
       (jetpacs-row
        (jetpacs-text lang 'label)
        (jetpacs-spacer :weight 1)
        (jetpacs-icon-button "play_arrow"
                          (jetpacs-action "org.babel.execute"
                                       :args `((file . ,jetpacs-org-rich--file)
                                               (pos . ,pos)))
                          :content-description "Run block"))
       code))))

;; ─── Tables ──────────────────────────────────────────────────────────────────

(defconst jetpacs-org-rich--cookie-re "\\`<[lcr]?[0-9]*>\\'"
  "Matches alignment/width cookie cells: <l>, <r>, <c>, <10>, <r20>, …")

(defun jetpacs-org-rich--cell-text (cell)
  "Trimmed plain text of table CELL (nil-safe: nil CELL gives \"\")."
  (if (null cell) ""
    (string-trim
     (or (ignore-errors
           (org-element-interpret-data (org-element-contents cell)))
         ""))))

(defun jetpacs-org-rich--cookie-row-p (cells)
  "Non-nil when CELLS form a cookie row (alignment config, not data).
Every non-empty cell is a cookie and at least one is non-empty."
  (let ((texts (mapcar #'jetpacs-org-rich--cell-text cells)))
    (and (cl-some (lambda (s) (not (string-empty-p s))) texts)
         (cl-every (lambda (s)
                     (or (string-empty-p s)
                         (string-match-p jetpacs-org-rich--cookie-re s)))
                   texts))))

(defun jetpacs-org-rich--table-aligns (cookie-rows data-rows ncols)
  "Alignment strings (start/center/end) for NCOLS columns.
A cookie in COOKIE-ROWS wins; otherwise a column whose DATA-ROWS cells
are mostly numbers right-aligns, mirroring org's own aligner.  Returns
nil when every column would be \"start\" (no wire noise)."
  (let (aligns)
    (dotimes (c ncols)
      (let ((cookie
             (cl-loop for row in cookie-rows
                      for text = (jetpacs-org-rich--cell-text (nth c row))
                      when (string-match "\\`<\\([lcr]\\)" text)
                      return (match-string 1 text))))
        (push
         (pcase cookie
           ("l" "start") ("c" "center") ("r" "end")
           (_ (let ((total 0) (numbers 0))
                (dolist (row data-rows)
                  (let ((text (jetpacs-org-rich--cell-text (nth c row))))
                    (unless (string-empty-p text)
                      (cl-incf total)
                      (when (string-match-p org-table-number-regexp text)
                        (cl-incf numbers)))))
                (if (and (> total 0)
                         (>= (/ (float numbers) total)
                             org-table-number-fraction))
                    "end" "start"))))
         aligns)))
    (setq aligns (nreverse aligns))
    (and (cl-some (lambda (a) (not (equal a "start"))) aligns)
         aligns)))

(defun jetpacs-org-rich--table-cell (cell)
  "Build a cell node for table CELL.
When file context is present (the reader passes it), tapping the cell
edits it through `org.table.edit' and long-pressing opens the
row/column menu (`org.table.cell-menu'), both at its real-file
position.  Read-only renders (babel results) stay inert."
  (let* ((spans (or (jetpacs-org-rich--inline (org-element-contents cell) nil)
                    (list (jetpacs-span ""))))
         (pos (and jetpacs-org-rich--file jetpacs-org-rich--body-offset
                   (not jetpacs-org-rich--read-only)
                   (+ jetpacs-org-rich--body-offset
                      (or (org-element-property :contents-begin cell)
                          (org-element-property :begin cell)))))
         (args (when pos
                 `((file . ,jetpacs-org-rich--file) (pos . ,pos)))))
    (jetpacs-table-cell
     spans
     :on-tap (when pos (jetpacs-action "org.table.edit" :args args))
     :on-long-tap (when pos (jetpacs-action "org.table.cell-menu" :args args)))))

(defun jetpacs-org-rich--table (el)
  "Render an org table EL to a native `jetpacs-table' node, or nil when empty.
Cookie-only rows configure column alignment and drop out of display;
alignment otherwise follows org's numeric-majority rule.  Header rows
are the first row group when a rule separates it from more groups
\(decorative border rules don't create one).  With file context, cells
tap-edit and the client offers add-row/add-column affordances."
  (let* ((file jetpacs-org-rich--file)
         (offset jetpacs-org-rich--body-offset)
         (cookie-rows nil)
         ;; Ordered display shapes: `rule' or a list of cell elements.
         (shapes
          (delq nil
                (mapcar
                 (lambda (row)
                   (when (eq (org-element-type row) 'table-row)
                     (if (eq (org-element-property :type row) 'rule)
                         'rule
                       (let ((cells (org-element-contents row)))
                         (if (jetpacs-org-rich--cookie-row-p cells)
                             (progn (push cells cookie-rows) nil)
                           cells)))))
                 (org-element-contents el))))
         (data-rows (cl-remove 'rule shapes))
         (ncols (cl-loop for s in data-rows maximize (length s))))
    (when (and ncols (> ncols 0))
      ;; Header = the first row group, when a rule separates it from
      ;; further groups; leading border rules don't open a group.
      (let ((groups 0) (prev-rule t) header-rows)
        (dolist (shape shapes)
          (if (eq shape 'rule)
              (setq prev-rule t)
            (when prev-rule (cl-incf groups))
            (setq prev-rule nil)
            (when (= groups 1) (push shape header-rows))))
        (unless (> groups 1) (setq header-rows nil))
        (let ((table-pos (and file offset
                              (not jetpacs-org-rich--read-only)
                              (+ offset
                                 (org-element-property :post-affiliated el)))))
          (jetpacs-table
           (mapcar (lambda (shape)
                     (if (eq shape 'rule)
                         (jetpacs-table-rule)
                       (jetpacs-table-row
                        (mapcar #'jetpacs-org-rich--table-cell shape)
                        :header (and (memq shape header-rows) t))))
                   shapes)
           :aligns (jetpacs-org-rich--table-aligns
                    (nreverse cookie-rows) data-rows ncols)
           :on-add-row (when table-pos
                         (jetpacs-action "org.table.add-row"
                                      :args `((file . ,file)
                                              (pos . ,table-pos))))
           :on-add-col (when table-pos
                         (jetpacs-action "org.table.add-col"
                                      :args `((file . ,file)
                                              (pos . ,table-pos))))))))))

(defun jetpacs-org-rich--drawer (el)
  "Render drawer EL as a folded section, like desktop org.
Returns nil for drawers named in `jetpacs-org-rich--skip-drawers'
and for drawers whose content renders to nothing."
  (let ((name (or (org-element-property :drawer-name el) "DRAWER")))
    (unless (member (upcase name) jetpacs-org-rich--skip-drawers)
      (let ((inner (delq nil (mapcar #'jetpacs-org-rich--element
                                     (org-element-contents el)))))
        (when inner
          (jetpacs-collapsible
           (format "drawer/%s/%s"
                   (or jetpacs-org-rich--file "")
                   (+ (or jetpacs-org-rich--body-offset 0)
                      (org-element-property :begin el)))
           (jetpacs-text name 'label)
           inner
           :collapsed t))))))

(defun jetpacs-org-rich--paragraph-image (el)
  "If paragraph EL is just a single image link, return an `jetpacs-image' node."
  (let* ((contents (org-element-contents el))
         (non-blank (cl-remove-if (lambda (c) (and (stringp c) (string-blank-p c)))
                                  contents)))
    (when (and (= (length non-blank) 1)
               (consp (car non-blank))
               (eq (org-element-type (car non-blank)) 'link))
      (let* ((lnk (car non-blank))
             (url (jetpacs-org-rich--image-url (org-element-property :type lnk)
                                            (org-element-property :path lnk))))
        (when url (jetpacs-image url))))))

(defun jetpacs-org-rich--element (el)
  "Render one top-level org element EL to a node, or nil to skip it.
Babel output — any element under a #+RESULTS: affiliated keyword —
renders read-only inside a foldable RESULTS section, like desktop org."
  (if (org-element-property :results el)
      (let* ((jetpacs-org-rich--read-only t)
             (node (jetpacs-org-rich--element-1 el)))
        (when node
          ;; `:results drawer' output is already a foldable drawer named
          ;; RESULTS — don't nest a second collapsible around it.
          (if (equal (alist-get 't node) "collapsible")
              node
            (jetpacs-collapsible
             (format "results/%s/%s"
                     (or jetpacs-org-rich--file "")
                     (+ (or jetpacs-org-rich--body-offset 0)
                        (org-element-property :begin el)))
             (jetpacs-text "RESULTS" 'label)
             (list node)))))
    (jetpacs-org-rich--element-1 el)))

(defun jetpacs-org-rich--element-1 (el)
  "Render element EL to a node ignoring any #+RESULTS: wrapping."
  (pcase (org-element-type el)
    ('paragraph
     (or (jetpacs-org-rich--paragraph-image el)
         (let ((spans (jetpacs-org-rich--inline (org-element-contents el) nil)))
           (when spans (jetpacs-rich-text spans)))))
    ('plain-list (jetpacs-org-rich--list el))
    ('src-block (jetpacs-org-rich--src-block el))
    ((or 'example-block 'fixed-width)
     (jetpacs-markup (or (org-element-property :value el) "")))
    ('quote-block
     (let ((inner (delq nil (mapcar #'jetpacs-org-rich--element
                                    (org-element-contents el)))))
       (when inner (apply #'jetpacs-column inner))))
    ('table
     ;; table.el tables keep the monospace fallback; org tables go native.
     (if (eq (org-element-property :type el) 'table.el)
         (jetpacs-markup (string-trim (org-element-interpret-data el)) :syntax "org")
       (or (jetpacs-org-rich--table el)
           (jetpacs-markup (string-trim (org-element-interpret-data el)) :syntax "org"))))
    ('horizontal-rule (jetpacs-divider))
    ('drawer (jetpacs-org-rich--drawer el))
    ;; Structural noise the reader handles elsewhere (properties drawer) or
    ;; that carries no display value on its own.
    ((or 'keyword 'comment 'comment-block 'planning
         'property-drawer 'node-property)
     nil)
    (_
     (let ((txt (ignore-errors (string-trim (org-element-interpret-data el)))))
       (when (and (stringp txt) (not (string-empty-p txt)))
         (jetpacs-markup txt :syntax "org"))))))

(defun jetpacs-org-rich--top-elements (tree)
  "Return the top-level elements of parsed TREE, descending through a section."
  (let (out)
    (dolist (el (org-element-contents tree))
      (if (eq (org-element-type el) 'section)
          (setq out (append out (org-element-contents el)))
        (setq out (append out (list el)))))
    out))

;;;###autoload
(defun jetpacs-org-rich-body (body &optional base-dir file offset)
  "Parse org BODY string into a list of Jetpacs rich/markup nodes.
Paragraphs and lists become native `rich_text'; code/tables/examples
fall back to highlighted `jetpacs-markup'. BASE-DIR resolves relative image
paths (pass the org file's directory).

FILE and OFFSET enable interactive elements (checkboxes): OFFSET maps
temp-buffer positions to real file positions (real = offset + temp).
Returns nil for empty input."
  (if (or (null body) (string-empty-p (string-trim body)))
      nil
    (let ((jetpacs-org-rich--file file)
          (jetpacs-org-rich--body-offset offset))
      (with-temp-buffer
        (insert body)
        (when (and base-dir (file-directory-p base-dir))
          (setq default-directory base-dir))
        (let ((org-inhibit-startup t)
              (org-element-use-cache nil))
          (delay-mode-hooks (org-mode))
          (let ((tree (org-element-parse-buffer)))
            (delq nil (mapcar #'jetpacs-org-rich--element
                              (jetpacs-org-rich--top-elements tree)))))))))

(provide 'jetpacs-org-rich)
;;; jetpacs-org-rich.el ends here
