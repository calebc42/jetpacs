;;; jetpacs-tablist.el --- Generic tabulated-list renderer (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: `tabulated-list-mode' is a declarative UI framework — columns
;; come from `tabulated-list-format', rows carry their id and entry as text
;; properties — so ONE renderer covers every derivative (package menu,
;; process list, bookmarks, timers, and any package built on it).
;;
;; Registered as a skin for `tabulated-list-mode' in
;; `jetpacs-render-buffer-functions'; anything the buffer view shows in a
;; tabulated-list derivative renders as sortable cards instead of monospace
;; text.  Row taps reuse the existing `jetpacs.buffer.act' seam (push button /
;; RET at position), so activation adds no new dispatch surface; the only
;; new wire actions are `tablist.sort' and `tablist.refresh', both validated
;; against the buffer's own column format.
;;
;; Modes can specialize without replacing the walk via three hook alists
;; (header, row, filter) — jetpacs-package-browser.el is the worked example.
;;
;; Host seams (this file depends on no UI layer): re-pushes go through
;; `jetpacs-buffer-refresh-function' (owned by jetpacs-buffer), and opening a
;; buffer as the current view goes through `jetpacs-tablist-view-buffer-function'
;; which the host shell points at its buffer-view navigation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)

;; ─── Configuration and host seams ────────────────────────────────────────────

(defcustom jetpacs-tablist-max-rows 100
  "Maximum rows rendered from one tabulated-list buffer.
Large lists (a full MELPA package menu is thousands of rows) are capped
with a trailing note; skins narrow with filters rather than paging."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-tablist-view-buffer-function
  (lambda (name) (message "Jetpacs: no host to view buffer %s" name))
  "Function of a buffer name that navigates the companion to that buffer.
Set by the host shell (the org-ui dashboard points it at the buffer view).")

;; ─── Per-mode skin hooks ─────────────────────────────────────────────────────

(defvar jetpacs-tablist-header-functions nil
  "Alist of (MODE . FN); FN of the buffer returns extra header nodes.
Rendered between the title row and the sort chips.  Nearest derived
mode wins, like `jetpacs-render-buffer-functions'.")

(defvar jetpacs-tablist-row-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY POS) returns a row node, or nil
to fall back to the generic row.  Called with the list buffer current.")

(defvar jetpacs-tablist-filter-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY) says whether to keep a row.
Filtering runs before the row cap, so narrowed views see deep rows.")

(defun jetpacs-tablist--mode-fn (alist)
  "The nearest-derived-mode function from ALIST for the current buffer."
  (cl-loop for (mode . fn) in alist
           when (derived-mode-p mode) return fn))

;; ─── Reading the list ────────────────────────────────────────────────────────

(defun jetpacs-tablist--rows ()
  "Collect (POS ID ENTRY) for each printed row of the current buffer.
Walking the printed buffer (rather than `tabulated-list-entries', which
may be a function) respects the mode's current sort and filtering."
  (save-excursion
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (let ((id (tabulated-list-get-id))
              (entry (tabulated-list-get-entry)))
          (when (and id entry)
            (push (list (point) id entry) rows)))
        (forward-line 1))
      (nreverse rows))))

(defun jetpacs-tablist-col-string (col)
  "The display string of entry column COL (a string or (LABEL . PROPS))."
  (cond ((stringp col) col)
        ((consp col) (format "%s" (car col)))
        (t (format "%s" col))))

(defun jetpacs-tablist-entry-col (entry name)
  "ENTRY's column named NAME per the current buffer's format, or nil.
Part of the skin-author API: row/filter hooks use this to read a column
by its header label instead of a fragile index."
  (let ((i (cl-position name tabulated-list-format :key #'car :test #'equal)))
    (and i (< i (length entry))
         (jetpacs-tablist-col-string (aref entry i)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-tablist--sort-chips ()
  "A chip row for the sortable columns of the current buffer, or nil."
  (let* ((key (car tabulated-list-sort-key))
         (desc (cdr tabulated-list-sort-key))
         (chips (cl-loop for col across tabulated-list-format
                         for name = (car col)
                         when (nth 2 col) ; sortable
                         collect (jetpacs-chip
                                  (if (equal name key)
                                      (concat name (if desc " ↓" " ↑"))
                                    name)
                                  :selected (equal name key)
                                  :on-tap (jetpacs-action
                                           "tablist.sort"
                                           :args `((buffer . ,(buffer-name))
                                                   (column . ,name))
                                           :when-offline "drop")))))
    (when chips (apply #'jetpacs-flow-row chips))))

(defun jetpacs-tablist--default-row (buf-name pos entry)
  "Generic row card: first column as title, the rest as a caption."
  (let* ((cols (mapcar #'jetpacs-tablist-col-string (append entry nil)))
         (rest (string-join (cl-remove-if #'string-empty-p (cdr cols)) "  ·  ")))
    (jetpacs-card
     (list (apply #'jetpacs-column
                  (delq nil
                        (list (jetpacs-text (or (car cols) "") 'label)
                              (unless (string-empty-p rest)
                                (jetpacs-text rest 'caption))))))
     :on-tap (jetpacs-action "jetpacs.buffer.act"
                          :args `((buffer . ,buf-name) (pos . ,pos))
                          :when-offline "drop"))))

(defun jetpacs-tablist-render (buf)
  "Tier-1 skin: BUF (a tabulated-list buffer) as sortable, tappable cards."
  (with-current-buffer buf
    (let* ((name (buffer-name))
           (header-fn (jetpacs-tablist--mode-fn jetpacs-tablist-header-functions))
           (row-fn (jetpacs-tablist--mode-fn jetpacs-tablist-row-functions))
           (filter-fn (jetpacs-tablist--mode-fn jetpacs-tablist-filter-functions))
           (rows (jetpacs-tablist--rows))
           (rows (if filter-fn
                     (cl-remove-if-not
                      (lambda (r) (funcall filter-fn (nth 1 r) (nth 2 r)))
                      rows)
                   rows))
           (total (length rows))
           (shown (cl-subseq rows 0 (min total jetpacs-tablist-max-rows))))
      (append
       (list (jetpacs-row
              (jetpacs-box (list (jetpacs-text (format "%d rows" total) 'caption))
                        :weight 1)
              (jetpacs-icon-button "refresh"
                                (jetpacs-action "tablist.refresh"
                                             :args `((buffer . ,name))
                                             :when-offline "drop")
                                :content-description "Refresh list")))
       (when header-fn (funcall header-fn buf))
       (let ((chips (jetpacs-tablist--sort-chips)))
         (and chips (list chips)))
       (mapcar (lambda (r)
                 (or (and row-fn
                          (funcall row-fn (nth 1 r) (nth 2 r) (nth 0 r)))
                     (jetpacs-tablist--default-row name (nth 0 r) (nth 2 r))))
               shown)
       (when (> total (length shown))
         (list (jetpacs-text
                (format "Showing %d of %d — narrow with a filter."
                        (length shown) total)
                'caption)))))))

(jetpacs-render-buffer-register 'tabulated-list-mode #'jetpacs-tablist-render)

;; ─── Generic actions ─────────────────────────────────────────────────────────

(defun jetpacs-tablist-refresh-view ()
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

(jetpacs-defaction "tablist.sort"
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) "")))
          (col (alist-get 'column args)))
      (when buf
        (with-current-buffer buf
          (when (and (derived-mode-p 'tabulated-list-mode)
                     (cl-find col tabulated-list-format
                              :key #'car :test #'equal))
            ;; Same column: flip direction; new column: ascending.
            (setq tabulated-list-sort-key
                  (cons col (and (equal (car tabulated-list-sort-key) col)
                                 (not (cdr tabulated-list-sort-key)))))
            (tabulated-list-print t)))
        (jetpacs-tablist-refresh-view)))))

(jetpacs-defaction "tablist.refresh"
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) ""))))
      (when buf
        (with-current-buffer buf
          (when (derived-mode-p 'tabulated-list-mode)
            (ignore-errors (revert-buffer))))
        (jetpacs-tablist-refresh-view)))))

(provide 'jetpacs-tablist)
;;; jetpacs-tablist.el ends here
