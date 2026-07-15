;;; jetpacs-sql.el --- SQL connection & schema hub (core stock satellite) -*- lexical-binding: t; -*-

;; A stock satellite for `sql.el', reached from the drawer ("Databases") and
;; from the project dashboard's Databases entry.  `sql-interactive-mode'
;; derives from `comint-mode', so a live SQL session already renders as a REPL
;; for free (the Tier 0.5 comint substrate); this screen adds the connection
;; picker and schema introspection that had no phone surface.
;;
;; v1 (schema-browser MVP), all glue over `sql.el' + the comint substrate:
;;
;;   Connections   → cards from `sql-connection-alist'; a tap runs
;;                   `sql-connect' and lands on the SQLi REPL.
;;   New connection→ a product picker → `sql-product-interactive'.
;;   Active session→ shown while a live SQLi buffer exists: open the REPL, or
;;                   list objects with `sql-list-all' (output pops into its own
;;                   buffer, rendered by the generic Tier 0 skin).
;;
;; Phase 2 (not here): structured result-tables (a tuples-only / -json query
;; path per product) rendered as `jetpacs' tables, and a dbs→tables→columns
;; schema tree.  Both are client-format-dependent and out of this MVP.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-tablist)   ; jetpacs-tablist-view-buffer-function — the buffer navigator
(require 'jetpacs-shell)
(require 'sql)

;; ─── Showing a SQL buffer ────────────────────────────────────────────────────

(defun jetpacs-sql--view-buffer-of (fn)
  "Call FN (returning a buffer or buffer name) and view the result.
Window excursion contains the pop-to-buffer these commands do; errors — a
missing client binary, an unreachable server — land in the snackbar instead
of dying silently.  (Copied from the tools wrapper.)"
  (condition-case err
      (let ((buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

(defun jetpacs-sql--sqli-buffer ()
  "The current live SQLi buffer object, or nil.
`sql-find-sqli-buffer' may return a buffer or a name; normalize to a buffer."
  (when-let ((raw (ignore-errors (sql-find-sqli-buffer))))
    (get-buffer raw)))

;; ─── Cards ───────────────────────────────────────────────────────────────────

(defun jetpacs-sql--entry (icon title caption action)
  "A hub row: ICON, TITLE/CAPTION, chevron; the whole card runs ACTION."
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-icon icon)
          (jetpacs-box (list (jetpacs-column (jetpacs-text title 'label)
                                             (jetpacs-text caption 'caption)))
                       :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap action))

;; ─── Active session ──────────────────────────────────────────────────────────

(defun jetpacs-sql--session-nodes ()
  "Nodes for a live SQLi session, or nil when none is running."
  (when-let ((buf (jetpacs-sql--sqli-buffer)))
    (list
     (jetpacs-section-header "Active session")
     (jetpacs-sql--entry "terminal" (buffer-name buf)
                         "Open the SQL REPL"
                         (jetpacs-action "sql.open" :when-offline "drop"))
     (jetpacs-sql--entry "table_rows" "List tables"
                         "Send an object listing to the session"
                         (jetpacs-action "sql.list-tables" :when-offline "drop")))))

;; ─── Connections ─────────────────────────────────────────────────────────────

(defun jetpacs-sql--connection-product (entry)
  "The SQL product symbol declared in a `sql-connection-alist' ENTRY, or nil."
  (let ((val (cadr (assq 'sql-product (cdr entry)))))
    (cond ((and (consp val) (eq (car val) 'quote)) (cadr val))
          ((symbolp val) val))))

(defun jetpacs-sql--connection-card (entry)
  "A card for a `sql-connection-alist' ENTRY; a tap connects and opens a REPL."
  (let* ((name (format "%s" (car entry)))
         (prod (jetpacs-sql--connection-product entry))
         (caption (if prod
                      (or (sql-get-product-feature prod :name) (symbol-name prod))
                    "Connect and open a REPL")))
    (jetpacs-sql--entry "database" name caption
                        (jetpacs-action "sql.connect"
                                        :args `((connection . ,name))
                                        :when-offline "drop"))))

(defun jetpacs-sql--connections-nodes ()
  "The connections section: a card per saved connection, or an empty state."
  (if (null sql-connection-alist)
      (list (jetpacs-empty-state
             :icon "database" :title "No saved connections"
             :caption "Define connections in `sql-connection-alist', then connect here."))
    (cons (jetpacs-section-header "Connections")
          (mapcar #'jetpacs-sql--connection-card sql-connection-alist))))

;; ─── Hub view ────────────────────────────────────────────────────────────────

(defun jetpacs-sql--body ()
  (apply #'jetpacs-lazy-column
         (append
          (jetpacs-sql--session-nodes)
          (jetpacs-sql--connections-nodes)
          (list (jetpacs-section-header "Add")
                (jetpacs-sql--entry "add" "New connection"
                                    "Start a REPL for a database product"
                                    (jetpacs-shell-switch-view "sql-new"))))))

(defun jetpacs-sql--view (snackbar)
  (jetpacs-shell-nav-view "Databases" (jetpacs-sql--body) :snackbar snackbar))

;; ─── New-connection product picker ───────────────────────────────────────────

(defun jetpacs-sql--products ()
  "SQL products Emacs can start an interactive session for."
  (seq-filter (lambda (p) (sql-get-product-feature (car p) :sqli-comint-func))
              sql-product-alist))

(defun jetpacs-sql--product-card (entry)
  "A card for a `sql-product-alist' ENTRY; a tap starts that product's REPL."
  (let* ((sym (car entry))
         (name (or (sql-get-product-feature sym :name) (capitalize (symbol-name sym)))))
    (jetpacs-sql--entry "storage" name
                        (format "Start a %s session" name)
                        (jetpacs-action "sql.new"
                                        :args `((product . ,(symbol-name sym)))
                                        :when-offline "drop"))))

(defun jetpacs-sql--new-body ()
  (let ((products (jetpacs-sql--products)))
    (if (null products)
        (jetpacs-empty-state :icon "storage" :title "No SQL products available")
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-text "Pick a database product to start a session."
                                 'caption)
                   (mapcar #'jetpacs-sql--product-card products))))))

(defun jetpacs-sql--new-view (snackbar)
  (jetpacs-shell-nav-view "New connection" (jetpacs-sql--new-body)
                          :back-to "sql" :snackbar snackbar))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "sql.show"
  (lambda (_ __)
    (jetpacs-shell-push nil :switch-to "sql")))

(jetpacs-defaction "sql.connect"
  (lambda (args _)
    (let* ((name (alist-get 'connection args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (assoc-string name sql-connection-alist t)))
          (jetpacs-shell-notify (format "Unknown connection: %s" (or name "?")))
        (jetpacs-sql--view-buffer-of
         (lambda ()
           ;; `sql-connect' returns the SQLi buffer on a fresh session; fall
           ;; back to whatever buffer it left current.
           (let ((buf (sql-connect sym)))
             (if (bufferp buf) buf (current-buffer)))))))))

(jetpacs-defaction "sql.new"
  (lambda (args _)
    (let* ((name (alist-get 'product args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (assq sym sql-product-alist)))
          (jetpacs-shell-notify (format "Unknown SQL product: %s" (or name "?")))
        (jetpacs-sql--view-buffer-of
         (lambda ()
           (let ((buf (sql-product-interactive sym)))
             (if (bufferp buf) buf (current-buffer)))))))))

(jetpacs-defaction "sql.open"
  (lambda (_ __)
    (let ((buf (jetpacs-sql--sqli-buffer)))
      (if buf
          (funcall jetpacs-tablist-view-buffer-function (buffer-name buf))
        (jetpacs-shell-notify "No active SQL session")))))

(jetpacs-defaction "sql.list-tables"
  (lambda (_ __)
    (if (null (jetpacs-sql--sqli-buffer))
        (jetpacs-shell-notify "Connect to a database first")
      (jetpacs-sql--view-buffer-of
       (lambda () (sql-list-all) "*List All*")))))

;; ─── Registration ────────────────────────────────────────────────────────────

(jetpacs-shell-define-view "sql" :builder #'jetpacs-sql--view :order 81)
(jetpacs-shell-define-view "sql-new" :builder #'jetpacs-sql--new-view :order 81)

(jetpacs-shell-add-drawer-item
 35 (lambda ()
      (jetpacs-drawer-item "database" "Databases"
                           (jetpacs-shell-switch-view "sql"))))

(provide 'jetpacs-sql)
;;; jetpacs-sql.el ends here
