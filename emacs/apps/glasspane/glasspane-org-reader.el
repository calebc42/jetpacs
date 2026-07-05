;;; glasspane-org-reader.el --- Foldable org outline renderer for EABP -*- lexical-binding: t; -*-

;; Renders an org buffer (or a single subtree) into a tree of EABP widgets:
;; each heading becomes an `eabp-collapsible' whose header is the org-highlighted
;; heading line and whose children are an optional (collapsed) PROPERTIES drawer,
;; the heading's own body as highlighted org text, and its child headings —
;; recursively. Folding is resolved entirely on the device (see the `collapsible'
;; widget), so the whole subtree is shipped once and folds without a round-trip.
;;
;; Two entry points feed the UI layer (glasspane-ui):
;;   `glasspane-org-reader-file'    — whole file, every top-level heading foldable
;;   `glasspane-org-reader-subtree' — one heading's content inline + children foldable

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'eabp-widgets)
(require 'glasspane-org-rich)

(defcustom glasspane-org-reader-max-headings 400
  "Cap on headings rendered in one reader pass, to bound very large files."
  :type 'integer :group 'eabp)

;; ─── Parsing ───────────────────────────────────────────────────────────────────

(defun glasspane-org-reader--record (pos next)
  "Build a record for the heading at POS, whose body ends at NEXT.
Returns a plist with :level :pos :line :props :body :body-start.
:body-start is the real-buffer position of the first non-blank char
in the body, used to map temp-buffer positions back for interactive
elements (checkboxes)."
  (save-excursion
    (goto-char pos)
    (let* ((comps (org-heading-components))
           (level (or (nth 0 comps) 1))
           (line (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))
           (props (ignore-errors (org-entry-properties pos 'standard)))
           (body-info
            (progn
              (goto-char pos)
              ;; No FULL arg: skip only planning + PROPERTIES (shown as
              ;; their own section).  LOGBOOK and other drawers stay in
              ;; the body, where the rich renderer folds them.
              (ignore-errors (org-end-of-meta-data))
              (let* ((b (min (point) next))
                     (raw (buffer-substring-no-properties b next))
                     (trimmed (string-trim-left raw "\\(?:[ \t]*[\n\r]\\)+"))
                     (trim-count (- (length raw) (length trimmed))))
                (list (string-trim-right trimmed) (+ b trim-count)))))
           (body (car body-info))
           (body-start (cadr body-info)))
      (list :level level :pos pos :line line :props props
            :body body :body-start body-start))))

(defun glasspane-org-reader--collect (beg end include-first)
  "Collect heading records between BEG and END.
INCLUDE-FIRST non-nil includes the heading at BEG (used for subtrees)."
  (let (positions records)
    (save-excursion
      (goto-char beg)
      (when (and include-first (org-at-heading-p))
        (push (line-beginning-position) positions)
        (end-of-line))                  ; don't re-match this heading below
      (while (re-search-forward org-heading-regexp end t)
        (push (line-beginning-position) positions)))
    (setq positions (nreverse positions))
    (cl-loop for cell on positions
             for pos = (car cell)
             for next = (or (cadr cell) end)
             do (push (glasspane-org-reader--record pos next) records))
    (nreverse records)))

(defun glasspane-org-reader--build-tree (records)
  "Nest flat RECORDS into a tree by :level. Each node gains a :children list."
  (let* ((root (list :level 0 :children nil))
         (stack (list root)))
    (dolist (rec records)
      (let ((node (append rec (list :children nil)))
            (level (plist-get rec :level)))
        (while (>= (plist-get (car stack) :level) level)
          (pop stack))
        (let ((parent (car stack)))
          (plist-put parent :children
                     (append (plist-get parent :children) (list node))))
        (push node stack)))
    (plist-get root :children)))

;; ─── Rendering ──────────────────────────────────────────────────────────────────

(defun glasspane-org-reader--props-node (props file pos)
  "A collapsed PROPERTIES drawer node for PROPS (an alist of KEY . VALUE)."
  (let ((text (mapconcat (lambda (kv) (format ":%s: %s" (car kv) (cdr kv)))
                         props "\n")))
    (eabp-collapsible (format "fold-props/%s/%s" file pos)
                      (eabp-text "PROPERTIES" 'label)
                      (list (eabp-text text 'mono))
                      :collapsed t)))

(defun glasspane-org-reader--content-nodes (n file &optional skip-props)
  "Inline content nodes for tree node N: PROPERTIES drawer, body, child headings.
When SKIP-PROPS is non-nil, omit the PROPERTIES drawer (used when the
detail view already shows properties in its own section)."
  (let ((pos (plist-get n :pos))
        (props (plist-get n :props))
        (body (plist-get n :body))
        (body-start (plist-get n :body-start))
        (children (plist-get n :children)))
    (delq nil
          (append
           (when (and props (not skip-props))
             (list (glasspane-org-reader--props-node props file pos)))
           (when (and body (not (string-empty-p body)))
             ;; Native rich text (emphasis, links, #tags) instead of the
             ;; monospace org highlighter; code/tables still fall back to it.
             ;; file + offset enable interactive checkboxes.  SKIP-PROPS
             ;; marks the detail view, which shows LOGBOOK as its own
             ;; structured section — suppress the raw drawer there.
             (let ((glasspane-org-rich--skip-drawers
                    (and skip-props '("LOGBOOK"))))
               (glasspane-org-rich-body body (and file (file-name-directory file))
                                        file (when body-start (1- body-start)))))
           (mapcar (lambda (c) (glasspane-org-reader--heading-node c file)) children)))))

(defun glasspane-org-reader--heading-node (n file)
  "Render tree node N (and its subtree) to a foldable `eabp-collapsible'.
Long-pressing the header opens the heading detail view when FILE is available."
  (let* ((pos (plist-get n :pos))
         (ref (when file
                `((file . ,file) (pos . ,pos) (headline . "")))))
    (eabp-collapsible (format "fold/%s/%s" file pos)
                      (eabp-markup (plist-get n :line) :syntax "org")
                      (glasspane-org-reader--content-nodes n file)
                      :on-long-tap (when ref
                                     (eabp-action "heading.tap" :args ref)))))

;; ─── Entry points ───────────────────────────────────────────────────────────────

(defun glasspane-org-reader--cap (records)
  "Truncate RECORDS to `glasspane-org-reader-max-headings'."
  (if (> (length records) glasspane-org-reader-max-headings)
      (cl-subseq records 0 glasspane-org-reader-max-headings)
    records))

(defun glasspane-org-reader-file (file)
  "Render the whole org FILE to a list of foldable widget nodes.
Content before the first heading is not shown."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (let* ((records (glasspane-org-reader--cap
                        (glasspane-org-reader--collect (point-min) (point-max) nil)))
              (tree (glasspane-org-reader--build-tree records)))
         (mapcar (lambda (n) (glasspane-org-reader--heading-node n file)) tree))))))

(defun glasspane-org-reader-subtree (file pos &optional skip-props)
  "Render the org subtree at POS in FILE.
The drilled-into heading's own PROPERTIES/body render inline (its title is
already in the top bar); its child headings render as foldable sections.
Returns a list of widget nodes (possibly empty).
When SKIP-PROPS is non-nil, the top-level PROPERTIES drawer is omitted."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (goto-char (min pos (point-max)))
       (unless (org-at-heading-p) (ignore-errors (org-back-to-heading t)))
       (let* ((beg (point))
              (end (save-excursion (org-end-of-subtree t t)))
              (records (glasspane-org-reader--cap
                        (glasspane-org-reader--collect beg end t)))
              (tree (glasspane-org-reader--build-tree records))
              (root (car tree)))
         (when root
           (glasspane-org-reader--content-nodes root file skip-props)))))))

(defun glasspane-org-reader-refile-list (file)
  "Render all headings in FILE as a flat reorderable item list.
Returns a single `eabp-reorderable-list' node for refile mode."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (let* ((records (glasspane-org-reader--cap
                        (glasspane-org-reader--collect (point-min) (point-max) nil)))
              (items (mapcar (lambda (r)
                               `((label . ,(plist-get r :line))
                                 (level . ,(plist-get r :level))
                                 (pos   . ,(plist-get r :pos))
                                 (file  . ,file)))
                             records)))
         (eabp-reorderable-list
          items
          :on-reorder (eabp-action "heading.reorder"
                                   :args `((file . ,file)))))))))

(provide 'glasspane-org-reader)
;;; glasspane-org-reader.el ends here
