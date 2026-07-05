;;; glasspane-org-rich.el --- Org → rich-text SDUI emitter -*- lexical-binding: t; -*-

;; Turns org content into EABP `rich_text' nodes (styled span runs) instead of
;; the syntax-highlighted monospace `eabp-markup' produces. Emacs does the
;; parsing via `org-element', so the device never re-parses org — it only paints
;; the spans. Inline emphasis (bold/italic/underline/strike/code/verbatim),
;; links (tappable), timestamps, and #hashtags all map to native styling.
;;
;; Block-level content that doesn't fit a single styled paragraph — source
;; blocks, example blocks — falls back to `eabp-markup' so code keeps its
;; highlighted, fixed-width look.  Org tables render as native `table' grids
;; (tap-to-edit and add-row/add-column when file context is supplied);
;; table.el tables keep the markup fallback.
;;
;; Entry point: `glasspane-org-rich-body' (an org body string -> a list of nodes).

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-table)
(require 'cl-lib)
(require 'eabp-widgets)

;; ─── Dynamic context for interactive elements ───────────────────────────────

(defvar glasspane-org-rich--file nil
  "File path being rendered; enables interactive checkboxes when non-nil.")

(defvar glasspane-org-rich--body-offset nil
  "Offset mapping temp-buffer positions to real-file positions.
real-pos = offset + temp-pos.  Set by `glasspane-org-rich-body' when
FILE and OFFSET are supplied.")

(defvar glasspane-org-rich--skip-drawers nil
  "Drawer names (upcased) the current render should omit.
Bound by callers that present a drawer's content in their own way —
the heading detail view parses LOGBOOK into a structured section, so
rendering the raw drawer too would double it.")

;; ─── Inline spans ────────────────────────────────────────────────────────────

(defun glasspane-org-rich--flag (style key)
  "Return STYLE (a plist of emphasis flags) with KEY turned on.
Prepended so `plist-get' sees the new value first; STYLE is never mutated."
  (cons key (cons t style)))

(defun glasspane-org-rich--leaf (text style)
  "Build a span for TEXT carrying the emphasis flags set in STYLE."
  (apply #'eabp-span (or text "")
         (append (when (plist-get style :bold)      '(:bold t))
                 (when (plist-get style :italic)    '(:italic t))
                 (when (plist-get style :underline) '(:underline t))
                 (when (plist-get style :strike)    '(:strike t))
                 (when (plist-get style :code)      '(:code t))
                 (when (plist-get style :tag)       '(:tag t))
                 (when (plist-get style :baseline)
                   (list :baseline (plist-get style :baseline))))))

(defconst glasspane-org-rich--image-re
  "\\.\\(png\\|jpe?g\\|gif\\|webp\\|bmp\\|svg\\)\\'"
  "Matches link targets that should render as inline images.")

(defun glasspane-org-rich--image-url (type target)
  "Return a renderable URL for a link of TYPE to TARGET if it's an image.
http(s) image URLs pass through; local file/attachment paths become
file:// URIs the companion can try to load. Returns nil for non-images."
  (when (and (stringp target)
             (string-match-p glasspane-org-rich--image-re (downcase target)))
    (let ((ty (and type (downcase type))))
      (cond
       ((member ty '("http" "https")) (concat ty ":" target))
       ((or (null ty) (equal ty "file"))
        (concat "file://" (expand-file-name target)))
       ((equal ty "attachment")
        (let ((dir (ignore-errors (org-attach-dir))))
          (when dir (concat "file://" (expand-file-name target dir)))))))))

(defun glasspane-org-rich--text-spans (text style)
  "Split TEXT into plain runs and #hashtag runs, all under STYLE.
A hashtag must follow start-of-string or a non-word character, so `C#'
and URL fragments aren't mistaken for tags."
  (let ((spans nil) (start 0) (len (length text)))
    (while (string-match "\\(?:^\\|[^[:alnum:]_]\\)\\(#[[:alnum:]_-]+\\)" text start)
      (let ((mb (match-beginning 1)) (me (match-end 1)))
        (when (> mb start)
          (push (glasspane-org-rich--leaf (substring text start mb) style) spans))
        (push (glasspane-org-rich--leaf (substring text mb me)
                                   (glasspane-org-rich--flag style :tag))
              spans)
        (setq start me)))
    (when (< start len)
      (push (glasspane-org-rich--leaf (substring text start) style) spans))
    (nreverse spans)))

(defun glasspane-org-rich--linkify (spans action)
  "Attach ON-TAP ACTION to every span in SPANS that doesn't already have one."
  (mapcar (lambda (sp)
            (if (assq 'on_tap sp) sp (cons (cons 'on_tap action) sp)))
          spans))

(defun glasspane-org-rich--inline (objects style)
  "Convert a list of org inline OBJECTS (strings and elements) to spans.
STYLE carries inherited emphasis flags as recursion descends into
bold/italic/... containers."
  (let (spans)
    (dolist (obj objects)
      (cond
       ((stringp obj)
        (setq spans (append spans (glasspane-org-rich--text-spans obj style))))
       ((null obj) nil)
       (t
        (pcase (org-element-type obj)
          ('bold (setq spans (append spans
                                     (glasspane-org-rich--inline
                                      (org-element-contents obj)
                                      (glasspane-org-rich--flag style :bold)))))
          ('italic (setq spans (append spans
                                       (glasspane-org-rich--inline
                                        (org-element-contents obj)
                                        (glasspane-org-rich--flag style :italic)))))
          ('underline (setq spans (append spans
                                          (glasspane-org-rich--inline
                                           (org-element-contents obj)
                                           (glasspane-org-rich--flag style :underline)))))
          ('strike-through (setq spans (append spans
                                               (glasspane-org-rich--inline
                                                (org-element-contents obj)
                                                (glasspane-org-rich--flag style :strike)))))
          ('code (setq spans (append spans
                                     (list (glasspane-org-rich--leaf
                                            (org-element-property :value obj)
                                            (glasspane-org-rich--flag style :code))))))
          ('verbatim (setq spans (append spans
                                         (list (glasspane-org-rich--leaf
                                                (org-element-property :value obj)
                                                (glasspane-org-rich--flag style :code))))))
          ('link
           (let* ((raw (org-element-property :raw-link obj))
                  (contents (org-element-contents obj))
                  (child (if contents
                             (glasspane-org-rich--inline contents style)
                           (list (glasspane-org-rich--leaf (or raw "link") style))))
                  (action (eabp-action "org.link.open"
                                       :args (list (cons 'link raw)))))
             (setq spans (append spans (glasspane-org-rich--linkify child action)))))
          ('timestamp
           (setq spans (append spans
                               (list (glasspane-org-rich--leaf
                                      (org-element-property :raw-value obj)
                                      (glasspane-org-rich--flag style :code))))))
          ('entity
           ;; Render org entities (\alpha, \rightarrow, …) as their Unicode form.
           (let ((utf8 (or (org-element-property :utf-8 obj)
                           (org-element-property :name obj))))
             (when utf8
               (setq spans (append spans (list (glasspane-org-rich--leaf utf8 style)))))))
          ('subscript
           (setq spans (append spans
                               (glasspane-org-rich--inline
                                (org-element-contents obj)
                                (cons :baseline (cons "sub" style))))))
          ('superscript
           (setq spans (append spans
                               (glasspane-org-rich--inline
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
                  (action (eabp-action "org.footnote.show"
                                       :args (list (cons 'label (or label ""))
                                                   (cons 'def def)))))
             (setq spans
                   (append spans
                           (list (eabp-span marker
                                            :baseline "super"
                                            :tag t
                                            :on-tap action))))))
          ('line-break
           (setq spans (append spans (list (eabp-span "\n")))))
          (_
           ;; Anything else (latex fragment, export snippet, …): fall back to
           ;; its interpreted source text.
           (let ((txt (ignore-errors (org-element-interpret-data obj))))
             (when (stringp txt)
               (setq spans (append spans
                                   (glasspane-org-rich--text-spans
                                    (string-trim-right txt) style))))))))))
    spans))

;; ─── Block elements ──────────────────────────────────────────────────────────

(defun glasspane-org-rich--item (item)
  "Render a plain-list ITEM to a node (bullet/number + content, plus sub-elements).

When `glasspane-org-rich--file' and `glasspane-org-rich--body-offset' are set
(the reader passes them), checkbox items get a tappable icon that
toggles the checkbox via Emacs without entering edit mode."
  (let* ((bullet (or (org-element-property :bullet item) "- "))
         (checkbox (org-element-property :checkbox item))
         (contents (org-element-contents item))
         (para (cl-find-if (lambda (c) (eq (org-element-type c) 'paragraph)) contents))
         (inline (when para (glasspane-org-rich--inline (org-element-contents para) nil)))
         (lead-text (concat (string-trim-right bullet) " "))
         (head
          (if (and checkbox glasspane-org-rich--file glasspane-org-rich--body-offset)
              ;; Interactive checkbox — a tappable icon beside the item text.
              (let* ((checked (eq checkbox 'on))
                     (item-pos (+ glasspane-org-rich--body-offset
                                  (org-element-property :begin item)))
                     (cb-icon (pcase checkbox
                                ('on  "check_box")
                                ('off "check_box_outline_blank")
                                (_    "indeterminate_check_box")))
                     (cb (eabp-box
                          (list (eabp-icon cb-icon :size 20))
                          :on-tap (eabp-action
                                   "checkbox.toggle"
                                   :args `((file . ,glasspane-org-rich--file)
                                           (pos  . ,item-pos))))))
                (eabp-row cb
                          (eabp-box
                           (list (eabp-rich-text
                                  (cons (eabp-span lead-text)
                                        (or inline (list (eabp-span ""))))))
                           :weight 1)))
            ;; No checkbox, or no file context — plain text as before.
            (let* ((mark (pcase checkbox
                           ('on "☑ ") ('off "☐ ") ('trans "◪ ") (_ "")))
                   (lead (eabp-span (concat lead-text mark))))
              (eabp-rich-text (cons lead (or inline (list (eabp-span ""))))))))
         (rest-contents (delq para (copy-sequence contents)))
         (sub-nodes (delq nil (mapcar #'glasspane-org-rich--element rest-contents))))
    (if sub-nodes
        (eabp-column head
                     (eabp-row (eabp-spacer :width 16)
                               (eabp-box (list (apply #'eabp-column sub-nodes)) :weight 1)))
      head)))

(defun glasspane-org-rich--list (el)
  "Render a plain-list EL to a column of item nodes."
  (let ((items (delq nil
                     (mapcar (lambda (item)
                               (when (eq (org-element-type item) 'item)
                                 (glasspane-org-rich--item item)))
                             (org-element-contents el)))))
    (when items (apply #'eabp-column items))))

;; ─── Source blocks ───────────────────────────────────────────────────────────

(defun glasspane-org-rich--src-block (el)
  "Render src-block EL: highlighted code, plus a run header when executable.
The header (language label + play button dispatching `org.babel.execute')
appears only when file context is present *and* this Emacs has an
`org-babel-execute:LANG' function — the same test execution would make,
so the button never promises more than `org-babel-load-languages'
delivers.  The action carries the block's real-file position; the code
itself never crosses the wire."
  (let* ((lang (org-element-property :language el))
         (code (eabp-markup (or (org-element-property :value el) "")
                            :syntax (or lang "text")))
         (pos (and glasspane-org-rich--file glasspane-org-rich--body-offset
                   lang
                   (fboundp (intern (concat "org-babel-execute:" lang)))
                   (+ glasspane-org-rich--body-offset
                      (org-element-property :post-affiliated el)))))
    (if (not pos)
        code
      (eabp-column
       (eabp-row
        (eabp-text lang 'label)
        (eabp-spacer :weight 1)
        (eabp-icon-button "play_arrow"
                          (eabp-action "org.babel.execute"
                                       :args `((file . ,glasspane-org-rich--file)
                                               (pos . ,pos)))
                          :content-description "Run block"))
       code))))

;; ─── Tables ──────────────────────────────────────────────────────────────────

(defconst glasspane-org-rich--cookie-re "\\`<[lcr]?[0-9]*>\\'"
  "Matches alignment/width cookie cells: <l>, <r>, <c>, <10>, <r20>, …")

(defun glasspane-org-rich--cell-text (cell)
  "Trimmed plain text of table CELL (nil-safe: nil CELL gives \"\")."
  (if (null cell) ""
    (string-trim
     (or (ignore-errors
           (org-element-interpret-data (org-element-contents cell)))
         ""))))

(defun glasspane-org-rich--cookie-row-p (cells)
  "Non-nil when CELLS form a cookie row (alignment config, not data).
Every non-empty cell is a cookie and at least one is non-empty."
  (let ((texts (mapcar #'glasspane-org-rich--cell-text cells)))
    (and (cl-some (lambda (s) (not (string-empty-p s))) texts)
         (cl-every (lambda (s)
                     (or (string-empty-p s)
                         (string-match-p glasspane-org-rich--cookie-re s)))
                   texts))))

(defun glasspane-org-rich--table-aligns (cookie-rows data-rows ncols)
  "Alignment strings (start/center/end) for NCOLS columns.
A cookie in COOKIE-ROWS wins; otherwise a column whose DATA-ROWS cells
are mostly numbers right-aligns, mirroring org's own aligner.  Returns
nil when every column would be \"start\" (no wire noise)."
  (let (aligns)
    (dotimes (c ncols)
      (let ((cookie
             (cl-loop for row in cookie-rows
                      for text = (glasspane-org-rich--cell-text (nth c row))
                      when (string-match "\\`<\\([lcr]\\)" text)
                      return (match-string 1 text))))
        (push
         (pcase cookie
           ("l" "start") ("c" "center") ("r" "end")
           (_ (let ((total 0) (numbers 0))
                (dolist (row data-rows)
                  (let ((text (glasspane-org-rich--cell-text (nth c row))))
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

(defun glasspane-org-rich--table-cell (cell)
  "Build a cell node for table CELL.
When file context is present (the reader passes it), the cell taps
through to `org.table.edit' at its real-file position."
  (let ((spans (or (glasspane-org-rich--inline (org-element-contents cell) nil)
                   (list (eabp-span ""))))
        (pos (and glasspane-org-rich--file glasspane-org-rich--body-offset
                  (+ glasspane-org-rich--body-offset
                     (or (org-element-property :contents-begin cell)
                         (org-element-property :begin cell))))))
    (eabp-table-cell
     spans
     :on-tap (when pos
               (eabp-action "org.table.edit"
                            :args `((file . ,glasspane-org-rich--file)
                                    (pos . ,pos)))))))

(defun glasspane-org-rich--table (el)
  "Render an org table EL to a native `eabp-table' node, or nil when empty.
Cookie-only rows configure column alignment and drop out of display;
alignment otherwise follows org's numeric-majority rule.  Header rows
are the first row group when a rule separates it from more groups
\(decorative border rules don't create one).  With file context, cells
tap-edit and the client offers add-row/add-column affordances."
  (let* ((file glasspane-org-rich--file)
         (offset glasspane-org-rich--body-offset)
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
                         (if (glasspane-org-rich--cookie-row-p cells)
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
                              (+ offset
                                 (org-element-property :post-affiliated el)))))
          (eabp-table
           (mapcar (lambda (shape)
                     (if (eq shape 'rule)
                         (eabp-table-rule)
                       (eabp-table-row
                        (mapcar #'glasspane-org-rich--table-cell shape)
                        :header (and (memq shape header-rows) t))))
                   shapes)
           :aligns (glasspane-org-rich--table-aligns
                    (nreverse cookie-rows) data-rows ncols)
           :on-add-row (when table-pos
                         (eabp-action "org.table.add-row"
                                      :args `((file . ,file)
                                              (pos . ,table-pos))))
           :on-add-col (when table-pos
                         (eabp-action "org.table.add-col"
                                      :args `((file . ,file)
                                              (pos . ,table-pos))))))))))

(defun glasspane-org-rich--drawer (el)
  "Render drawer EL as a folded section, like desktop org.
Returns nil for drawers named in `glasspane-org-rich--skip-drawers'
and for drawers whose content renders to nothing."
  (let ((name (or (org-element-property :drawer-name el) "DRAWER")))
    (unless (member (upcase name) glasspane-org-rich--skip-drawers)
      (let ((inner (delq nil (mapcar #'glasspane-org-rich--element
                                     (org-element-contents el)))))
        (when inner
          (eabp-collapsible
           (format "drawer/%s/%s"
                   (or glasspane-org-rich--file "")
                   (+ (or glasspane-org-rich--body-offset 0)
                      (org-element-property :begin el)))
           (eabp-text name 'label)
           inner
           :collapsed t))))))

(defun glasspane-org-rich--paragraph-image (el)
  "If paragraph EL is just a single image link, return an `eabp-image' node."
  (let* ((contents (org-element-contents el))
         (non-blank (cl-remove-if (lambda (c) (and (stringp c) (string-blank-p c)))
                                  contents)))
    (when (and (= (length non-blank) 1)
               (consp (car non-blank))
               (eq (org-element-type (car non-blank)) 'link))
      (let* ((lnk (car non-blank))
             (url (glasspane-org-rich--image-url (org-element-property :type lnk)
                                            (org-element-property :path lnk))))
        (when url (eabp-image url))))))

(defun glasspane-org-rich--element (el)
  "Render one top-level org element EL to a node, or nil to skip it."
  (pcase (org-element-type el)
    ('paragraph
     (or (glasspane-org-rich--paragraph-image el)
         (let ((spans (glasspane-org-rich--inline (org-element-contents el) nil)))
           (when spans (eabp-rich-text spans)))))
    ('plain-list (glasspane-org-rich--list el))
    ('src-block (glasspane-org-rich--src-block el))
    ((or 'example-block 'fixed-width)
     (eabp-markup (or (org-element-property :value el) "")))
    ('quote-block
     (let ((inner (delq nil (mapcar #'glasspane-org-rich--element
                                    (org-element-contents el)))))
       (when inner (apply #'eabp-column inner))))
    ('table
     ;; table.el tables keep the monospace fallback; org tables go native.
     (if (eq (org-element-property :type el) 'table.el)
         (eabp-markup (string-trim (org-element-interpret-data el)) :syntax "org")
       (or (glasspane-org-rich--table el)
           (eabp-markup (string-trim (org-element-interpret-data el)) :syntax "org"))))
    ('horizontal-rule (eabp-divider))
    ('drawer (glasspane-org-rich--drawer el))
    ;; Structural noise the reader handles elsewhere (properties drawer) or
    ;; that carries no display value on its own.
    ((or 'keyword 'comment 'comment-block 'planning
         'property-drawer 'node-property)
     nil)
    (_
     (let ((txt (ignore-errors (string-trim (org-element-interpret-data el)))))
       (when (and (stringp txt) (not (string-empty-p txt)))
         (eabp-markup txt :syntax "org"))))))

(defun glasspane-org-rich--top-elements (tree)
  "Return the top-level elements of parsed TREE, descending through a section."
  (let (out)
    (dolist (el (org-element-contents tree))
      (if (eq (org-element-type el) 'section)
          (setq out (append out (org-element-contents el)))
        (setq out (append out (list el)))))
    out))

;;;###autoload
(defun glasspane-org-rich-body (body &optional base-dir file offset)
  "Parse org BODY string into a list of EABP rich/markup nodes.
Paragraphs and lists become native `rich_text'; code/tables/examples
fall back to highlighted `eabp-markup'. BASE-DIR resolves relative image
paths (pass the org file's directory).

FILE and OFFSET enable interactive elements (checkboxes): OFFSET maps
temp-buffer positions to real file positions (real = offset + temp).
Returns nil for empty input."
  (if (or (null body) (string-empty-p (string-trim body)))
      nil
    (let ((glasspane-org-rich--file file)
          (glasspane-org-rich--body-offset offset))
      (with-temp-buffer
        (insert body)
        (when (and base-dir (file-directory-p base-dir))
          (setq default-directory base-dir))
        (let ((org-inhibit-startup t)
              (org-element-use-cache nil))
          (delay-mode-hooks (org-mode))
          (let ((tree (org-element-parse-buffer)))
            (delq nil (mapcar #'glasspane-org-rich--element
                              (glasspane-org-rich--top-elements tree)))))))))

(provide 'glasspane-org-rich)
;;; glasspane-org-rich.el ends here
