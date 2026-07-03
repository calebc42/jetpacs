;;; eabp-tablist.el --- Generic tabulated-list renderer + package browser -*- lexical-binding: t; -*-

;; Tier 0.5: `tabulated-list-mode' is a declarative UI framework — columns
;; come from `tabulated-list-format', rows carry their id and entry as text
;; properties — so ONE renderer covers every derivative (package menu,
;; process list, bookmarks, timers, and any package built on it).
;;
;; Registered as a Tier-1 skin for `tabulated-list-mode' in
;; `eabp-render-buffer-functions'; anything the buffer view shows in a
;; tabulated-list derivative renders as sortable cards instead of monospace
;; text.  Row taps reuse the existing `eabp.buffer.act' seam (push button /
;; RET at position), so activation adds no new dispatch surface; the only
;; new wire actions are `tablist.sort' and `tablist.refresh', both validated
;; against the buffer's own column format.
;;
;; Modes can specialize without replacing the walk via three hook alists
;; (header, row, filter) — the package browser below is the first skin.
;;
;; Host seams (this file depends on no UI layer): re-pushes go through
;; `eabp-buffer-refresh-function' (owned by eabp-buffer), and opening a
;; buffer as the current view goes through `eabp-tablist-view-buffer-function'
;; which the host shell points at its buffer-view navigation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'package)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

;; ─── Configuration and host seams ────────────────────────────────────────────

(defcustom eabp-tablist-max-rows 100
  "Maximum rows rendered from one tabulated-list buffer.
Large lists (a full MELPA package menu is thousands of rows) are capped
with a trailing note; skins narrow with filters rather than paging."
  :type 'integer :group 'eabp)

(defvar eabp-tablist-view-buffer-function
  (lambda (name) (message "EABP: no host to view buffer %s" name))
  "Function of a buffer name that navigates the companion to that buffer.
Set by the host shell (the org-ui dashboard points it at the buffer view).")

;; ─── Per-mode skin hooks ─────────────────────────────────────────────────────

(defvar eabp-tablist-header-functions nil
  "Alist of (MODE . FN); FN of the buffer returns extra header nodes.
Rendered between the title row and the sort chips.  Nearest derived
mode wins, like `eabp-render-buffer-functions'.")

(defvar eabp-tablist-row-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY POS) returns a row node, or nil
to fall back to the generic row.  Called with the list buffer current.")

(defvar eabp-tablist-filter-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY) says whether to keep a row.
Filtering runs before the row cap, so narrowed views see deep rows.")

(defun eabp-tablist--mode-fn (alist)
  "The nearest-derived-mode function from ALIST for the current buffer."
  (cl-loop for (mode . fn) in alist
           when (derived-mode-p mode) return fn))

;; ─── Reading the list ────────────────────────────────────────────────────────

(defun eabp-tablist--rows ()
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

(defun eabp-tablist--col-string (col)
  "The display string of entry column COL (a string or (LABEL . PROPS))."
  (cond ((stringp col) col)
        ((consp col) (format "%s" (car col)))
        (t (format "%s" col))))

(defun eabp-tablist--entry-col (entry name)
  "ENTRY's column named NAME per the current buffer's format, or nil."
  (let ((i (cl-position name tabulated-list-format :key #'car :test #'equal)))
    (and i (< i (length entry))
         (eabp-tablist--col-string (aref entry i)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-tablist--sort-chips ()
  "A chip row for the sortable columns of the current buffer, or nil."
  (let* ((key (car tabulated-list-sort-key))
         (desc (cdr tabulated-list-sort-key))
         (chips (cl-loop for col across tabulated-list-format
                         for name = (car col)
                         when (nth 2 col) ; sortable
                         collect (eabp-chip
                                  (if (equal name key)
                                      (concat name (if desc " ↓" " ↑"))
                                    name)
                                  :selected (equal name key)
                                  :on-tap (eabp-action
                                           "tablist.sort"
                                           :args `((buffer . ,(buffer-name))
                                                   (column . ,name))
                                           :when-offline "drop")))))
    (when chips (apply #'eabp-flow-row chips))))

(defun eabp-tablist--default-row (buf-name pos entry)
  "Generic row card: first column as title, the rest as a caption."
  (let* ((cols (mapcar #'eabp-tablist--col-string (append entry nil)))
         (rest (string-join (cl-remove-if #'string-empty-p (cdr cols)) "  ·  ")))
    (eabp-card
     (list (apply #'eabp-column
                  (delq nil
                        (list (eabp-text (or (car cols) "") 'label)
                              (unless (string-empty-p rest)
                                (eabp-text rest 'caption))))))
     :on-tap (eabp-action "eabp.buffer.act"
                          :args `((buffer . ,buf-name) (pos . ,pos))
                          :when-offline "drop"))))

(defun eabp-tablist-render (buf)
  "Tier-1 skin: BUF (a tabulated-list buffer) as sortable, tappable cards."
  (with-current-buffer buf
    (let* ((name (buffer-name))
           (header-fn (eabp-tablist--mode-fn eabp-tablist-header-functions))
           (row-fn (eabp-tablist--mode-fn eabp-tablist-row-functions))
           (filter-fn (eabp-tablist--mode-fn eabp-tablist-filter-functions))
           (rows (eabp-tablist--rows))
           (rows (if filter-fn
                     (cl-remove-if-not
                      (lambda (r) (funcall filter-fn (nth 1 r) (nth 2 r)))
                      rows)
                   rows))
           (total (length rows))
           (shown (cl-subseq rows 0 (min total eabp-tablist-max-rows))))
      (append
       (list (eabp-row
              (eabp-box (list (eabp-text (format "%d rows" total) 'caption))
                        :weight 1)
              (eabp-icon-button "refresh"
                                (eabp-action "tablist.refresh"
                                             :args `((buffer . ,name))
                                             :when-offline "drop")
                                :content-description "Refresh list")))
       (when header-fn (funcall header-fn buf))
       (let ((chips (eabp-tablist--sort-chips)))
         (and chips (list chips)))
       (mapcar (lambda (r)
                 (or (and row-fn
                          (funcall row-fn (nth 1 r) (nth 2 r) (nth 0 r)))
                     (eabp-tablist--default-row name (nth 0 r) (nth 2 r))))
               shown)
       (when (> total (length shown))
         (list (eabp-text
                (format "Showing %d of %d — narrow with a filter."
                        (length shown) total)
                'caption)))))))

(eabp-render-buffer-register 'tabulated-list-mode #'eabp-tablist-render)

;; ─── Generic actions ─────────────────────────────────────────────────────────

(defun eabp-tablist--refresh-view ()
  (when (functionp eabp-buffer-refresh-function)
    (funcall eabp-buffer-refresh-function)))

(eabp-defaction "tablist.sort"
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
        (eabp-tablist--refresh-view)))))

(eabp-defaction "tablist.refresh"
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) ""))))
      (when buf
        (with-current-buffer buf
          (when (derived-mode-p 'tabulated-list-mode)
            (ignore-errors (revert-buffer))))
        (eabp-tablist--refresh-view)))))

;; ─── Package browser skin ────────────────────────────────────────────────────
;;
;; package-menu-mode derives from tabulated-list-mode, so the walk above is
;; reused; this section adds search + status chips, install/delete per row,
;; and archive refresh / upgrade-all — the curated actions validate package
;; names against the archive/installed lists, keeping the wire semantic.

(defvar eabp-tablist--pkg-search ""
  "Current package search string (matches name and summary).")

(defvar eabp-tablist--pkg-status "all"
  "Current package status filter chip.")

(defconst eabp-tablist--pkg-statuses
  '(("all")
    ("installed" "installed" "dependency" "unsigned" "external" "held")
    ("available" "available" "new")
    ("built-in" "built-in")
    ("upgradable" "obsolete"))
  "Chip name -> package-menu status strings it admits.")

(defun eabp-tablist--pkg-toast (text)
  (eabp-send "toast.show" `((text . ,text))))

(defun eabp-tablist--package-filter (id entry)
  "Keep package row (ID ENTRY) when it matches the search and status chips."
  (let ((statuses (cdr (assoc eabp-tablist--pkg-status
                              eabp-tablist--pkg-statuses)))
        (status (or (eabp-tablist--entry-col entry "Status") ""))
        (hay (concat (eabp-tablist--col-string (aref entry 0)) " "
                     (and (package-desc-p id)
                          (or (package-desc-summary id) "")))))
    (and (or (null statuses) (member status statuses))
         (or (string-empty-p eabp-tablist--pkg-search)
             (string-match-p (regexp-quote eabp-tablist--pkg-search)
                             (downcase hay))))))

(defun eabp-tablist--package-header (_buf)
  (list
   (eabp-text-input "pkg-search"
                    :value eabp-tablist--pkg-search
                    :label "Search packages" :single-line t
                    :on-submit (eabp-action "packages.search"))
   (apply #'eabp-flow-row
          (mapcar (lambda (chip)
                    (let ((s (car chip)))
                      (eabp-chip (capitalize s)
                                 :selected (equal eabp-tablist--pkg-status s)
                                 :on-tap (eabp-action
                                          "packages.status-filter"
                                          :args `((status . ,s))
                                          :when-offline "drop"))))
                  eabp-tablist--pkg-statuses))
   (eabp-row
    (eabp-button "Refresh archives"
                 (eabp-action "packages.refresh-archives" :when-offline "drop")
                 :variant "text")
    (eabp-spacer :weight 1)
    (when (fboundp 'package-upgrade-all)
      (eabp-button "Upgrade all"
                   (eabp-action "packages.upgrade-all" :when-offline "drop")
                   :variant "text")))))

(defun eabp-tablist--package-row (id entry _pos)
  (when (package-desc-p id)
    (let* ((sym (package-desc-name id))
           (name (symbol-name sym))
           (version (or (eabp-tablist--entry-col entry "Version") ""))
           (status (or (eabp-tablist--entry-col entry "Status") ""))
           (summary (or (package-desc-summary id) ""))
           (installed (assq sym package-alist)))
      (eabp-card
       (list
        (eabp-row
         (eabp-box
          (list (eabp-column
                 (eabp-row (eabp-text name 'label)
                           (eabp-text version 'caption)
                           (eabp-text status 'caption))
                 (eabp-text summary 'caption)))
          :weight 1)
         (cond
          (installed
           (eabp-icon-button "delete"
                             (eabp-action "packages.delete"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Uninstall %s" name)))
          ((not (equal status "built-in"))
           (eabp-icon-button "arrow_downward"
                             (eabp-action "packages.install"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Install %s" name))))))
       :on-tap (eabp-action "packages.describe"
                            :args `((package . ,name))
                            :when-offline "drop")))))

(setf (alist-get 'package-menu-mode eabp-tablist-header-functions)
      #'eabp-tablist--package-header)
(setf (alist-get 'package-menu-mode eabp-tablist-row-functions)
      #'eabp-tablist--package-row)
(setf (alist-get 'package-menu-mode eabp-tablist-filter-functions)
      #'eabp-tablist--package-filter)

;; ─── Package actions ─────────────────────────────────────────────────────────

(defun eabp-tablist--pkg-buffer ()
  "The live *Packages* menu buffer, creating (without fetching) if needed."
  (require 'package)
  (unless package--initialized (package-initialize))
  (or (get-buffer "*Packages*")
      (save-window-excursion
        (list-packages t)
        (get-buffer "*Packages*"))))

(defun eabp-tablist--pkg-revert ()
  "Re-generate the package menu after an install/delete and re-push."
  (let ((buf (get-buffer "*Packages*")))
    (when buf
      (with-current-buffer buf
        (ignore-errors (revert-buffer)))))
  (eabp-tablist--refresh-view))

(eabp-defaction "packages.show"
  (lambda (_ __)
    (let ((buf (eabp-tablist--pkg-buffer)))
      (when (and buf (null package-archive-contents))
        (eabp-tablist--pkg-toast
         "Archives not fetched yet - tap Refresh archives"))
      (funcall eabp-tablist-view-buffer-function (buffer-name buf)))))

(eabp-defaction "packages.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq eabp-tablist--pkg-search
            (downcase (or (and (stringp q) q) "")))
      (eabp-tablist--refresh-view))))

(eabp-defaction "packages.status-filter"
  (lambda (args _)
    (let ((s (alist-get 'status args)))
      (when (assoc s eabp-tablist--pkg-statuses)
        (setq eabp-tablist--pkg-status s)
        (eabp-tablist--refresh-view)))))

(eabp-defaction "packages.install"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (assq sym package-archive-contents)))
          (eabp-tablist--pkg-toast (format "%s is not in the archives" name))
        (eabp-tablist--pkg-toast (format "Installing %s…" name))
        (condition-case err
            (progn
              (package-install sym)
              (eabp-tablist--pkg-toast (format "Installed %s" name)))
          (error (eabp-tablist--pkg-toast
                  (format "Install failed: %s" (error-message-string err)))))
        (eabp-tablist--pkg-revert)))))

(eabp-defaction "packages.delete"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name)))
           (desc (and sym (cadr (assq sym package-alist)))))
      (if (not desc)
          (eabp-tablist--pkg-toast (format "%s is not installed" name))
        (condition-case err
            (progn
              (package-delete desc)
              (eabp-tablist--pkg-toast (format "Deleted %s" name)))
          (error (eabp-tablist--pkg-toast
                  ;; Typically: something still depends on it.
                  (format "Delete failed: %s" (error-message-string err)))))
        (eabp-tablist--pkg-revert)))))

(eabp-defaction "packages.refresh-archives"
  (lambda (_ __)
    (eabp-tablist--pkg-toast "Refreshing package archives…")
    (condition-case err
        (progn
          (require 'package)
          (unless package--initialized (package-initialize))
          (package-refresh-contents)
          (eabp-tablist--pkg-toast "Archives refreshed"))
      (error (eabp-tablist--pkg-toast
              (format "Refresh failed: %s" (error-message-string err)))))
    (eabp-tablist--pkg-revert)))

(eabp-defaction "packages.upgrade-all"
  (lambda (_ __)
    (if (not (fboundp 'package-upgrade-all))
        (eabp-tablist--pkg-toast "Upgrade-all needs Emacs 29+")
      (eabp-tablist--pkg-toast "Upgrading all packages…")
      (condition-case err
          (progn
            (package-upgrade-all nil)
            (eabp-tablist--pkg-toast "Upgrades complete"))
        (error (eabp-tablist--pkg-toast
                (format "Upgrade failed: %s" (error-message-string err)))))
      (eabp-tablist--pkg-revert))))

(eabp-defaction "packages.describe"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym
                 (or (assq sym package-archive-contents)
                     (assq sym package-alist)
                     (assq sym package--builtins)))
        (save-window-excursion (describe-package sym))
        (funcall eabp-tablist-view-buffer-function "*Help*")))))

(provide 'eabp-tablist)
;;; eabp-tablist.el ends here
