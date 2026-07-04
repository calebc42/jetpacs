;;; glasspane-org-rich.el --- Org → rich-text SDUI emitter -*- lexical-binding: t; -*-

;; Turns org content into EABP `rich_text' nodes (styled span runs) instead of
;; the syntax-highlighted monospace `eabp-markup' produces. Emacs does the
;; parsing via `org-element', so the device never re-parses org — it only paints
;; the spans. Inline emphasis (bold/italic/underline/strike/code/verbatim),
;; links (tappable), timestamps, and #hashtags all map to native styling.
;;
;; Block-level content that doesn't fit a single styled paragraph — source
;; blocks, tables, example blocks — falls back to `eabp-markup' so code keeps
;; its highlighted, fixed-width look.
;;
;; Entry point: `glasspane-org-rich-body' (an org body string -> a list of nodes).

;;; Code:

(require 'org)
(require 'org-element)
(require 'cl-lib)
(require 'eabp-widgets)

;; ─── Dynamic context for interactive elements ───────────────────────────────

(defvar glasspane-org-rich--file nil
  "File path being rendered; enables interactive checkboxes when non-nil.")

(defvar glasspane-org-rich--body-offset nil
  "Offset mapping temp-buffer positions to real-file positions.
real-pos = offset + temp-pos.  Set by `glasspane-org-rich-body' when
FILE and OFFSET are supplied.")

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
    ('src-block
     (eabp-markup (or (org-element-property :value el) "")
                  :syntax (or (org-element-property :language el) "text")))
    ((or 'example-block 'fixed-width)
     (eabp-markup (or (org-element-property :value el) "")))
    ('quote-block
     (let ((inner (delq nil (mapcar #'glasspane-org-rich--element
                                    (org-element-contents el)))))
       (when inner (apply #'eabp-column inner))))
    ('table
     (eabp-markup (string-trim (org-element-interpret-data el)) :syntax "org"))
    ('horizontal-rule (eabp-divider))
    ;; Structural noise the reader handles elsewhere (properties drawer) or
    ;; that carries no display value on its own.
    ((or 'keyword 'comment 'comment-block 'planning
         'property-drawer 'drawer 'node-property)
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
