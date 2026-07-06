;;; glasspane-views.el --- Saved queries as views -*- lexical-binding: t; -*-

;; PKM plan Task 11 — the Dataview / Notion-database story: a named
;; org-ql query rendered three ways over the same result set — list
;; (table with property columns), board (kanban by TODO state), and
;; calendar (grouped by scheduled date).  Definitions persist through
;; Customize; rendering switches per view and persists too.
;;
;; Everything rides existing machinery: `glasspane-org--query' (memoised,
;; org-ql-or-fallback), the §9 table node, `heading.tap' for drill-in,
;; and `heading.todo-set' for moving a board card between columns (a
;; menu on the card — plain columns don't drag; a drag wire node is a
;; later decision, noted in the plan).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)
(require 'eabp-settings)
(require 'glasspane-org)
(require 'glasspane-ui)

(defcustom glasspane-saved-views nil
  "Saved query views: a list of alists with `name', `query', `rendering'.
`query' is anything `glasspane-org--parse-query' accepts (org-ql sexp,
filter tokens, or free text); `rendering' is \"list\" | \"board\" |
\"calendar\".  Managed from the phone; persisted through Customize."
  :type '(repeat sexp) :group 'eabp)

(defvar glasspane-views--current nil
  "Name of the saved view being shown, or nil for the hub.")

(defvar glasspane-views--form-gen 0
  "Generation counter for the new-view form's widget ids (field clear).")

(defconst glasspane-views--renderings '("list" "board" "calendar"))

(defun glasspane-views--get (name)
  (cl-find name glasspane-saved-views
           :key (lambda (v) (alist-get 'name v)) :test #'equal))

(defun glasspane-views--persist ()
  (eabp-settings-save-variable 'glasspane-saved-views glasspane-saved-views))

(defun glasspane-views--set-rendering (name rendering)
  "Set view NAME's rendering to RENDERING, rebuilding the saved list.
Rebuilding (rather than a `setcdr' into the entry) tolerates a
hand-authored Customize entry without a `rendering' key and never
mutates the value Customize handed out."
  (setq glasspane-saved-views
        (mapcar (lambda (v)
                  (if (equal (alist-get 'name v) name)
                      (cons (cons 'rendering rendering)
                            (assq-delete-all 'rendering (copy-alist v)))
                    v))
                glasspane-saved-views)))

(defun glasspane-views--items (view)
  "Run VIEW's query; heading items, or signal `user-error'."
  (glasspane-org--query
   (glasspane-org--parse-query (alist-get 'query view))))

;; ─── Renderings ──────────────────────────────────────────────────────────────

(defun glasspane-views--tap (item)
  "The drill-in action for ITEM's heading."
  (eabp-action "heading.tap" :args (alist-get 'ref item)
               :when-offline "drop"))

(defun glasspane-views--table-node (items)
  "The list rendering: one table row per item, tappable cells."
  (eabp-table
   (cons
    (eabp-table-row
     (list (eabp-table-cell (list (eabp-span "Heading" :bold t)))
           (eabp-table-cell (list (eabp-span "State" :bold t)))
           (eabp-table-cell (list (eabp-span "Scheduled" :bold t)))
           (eabp-table-cell (list (eabp-span "Tags" :bold t))))
     :header t)
    (mapcar
     (lambda (item)
       (let ((tap (glasspane-views--tap item)))
         (eabp-table-row
          (list (eabp-table-cell
                 (list (eabp-span (or (alist-get 'headline item) "")))
                 :on-tap tap)
                (eabp-table-cell
                 (list (eabp-span (or (alist-get 'todo item) ""))))
                (eabp-table-cell
                 (list (eabp-span (or (glasspane-ui--ts-date
                                       (alist-get 'scheduled item))
                                      ""))))
                (eabp-table-cell
                 (list (eabp-span (mapconcat #'identity
                                             (append (alist-get 'tags item) nil)
                                             " "))))))))
     items))
   :aligns '("start" "start" "start" "start")))

(defun glasspane-views--board-columns (items)
  "Distinct TODO states across ITEMS, keyword order preserved.
Global keywords come first in `org-todo-keywords-1' order; states the
global list doesn't know (file-local #+TODO: lines) follow in encounter
order — every present state gets a column, or its cards would silently
vanish from the board."
  (let ((present (delete-dups (mapcar (lambda (i)
                                        (or (alist-get 'todo i) ""))
                                      items))))
    (append (cl-remove-if-not (lambda (kw) (member kw present))
                              org-todo-keywords-1)
            (cl-remove-if (lambda (kw)
                            (or (string-empty-p kw)
                                (member kw org-todo-keywords-1)))
                          present)
            (and (member "" present) '("")))))

(defun glasspane-views--board-card (item columns)
  "A board card: tap opens the heading; the menu moves it to a column."
  (let ((ref (alist-get 'ref item))
        (state (or (alist-get 'todo item) "")))
    (eabp-card
     (list
      (eabp-row
       (eabp-box (list (eabp-text (or (alist-get 'headline item) "") 'body))
                 :weight 1)
       (eabp-menu
        (mapcar (lambda (target)
                  (eabp-menu-item
                   (if (string-empty-p target) "No state" target)
                   (eabp-action "heading.todo-set"
                                :args (append ref `((state . ,target)))
                                :when-offline "queue")))
                (remove state columns))
        :icon "more_vert")))
     :on-tap (glasspane-views--tap item))))

(defun glasspane-views--board-node (items)
  "The kanban rendering: one column per TODO state, panning sideways."
  (let ((columns (glasspane-views--board-columns items)))
    (apply #'eabp-scroll-row
           (mapcar
            (lambda (col)
              (let ((in-col (cl-remove-if-not
                             (lambda (i) (equal (or (alist-get 'todo i) "")
                                                col))
                             items)))
                (eabp-box
                 (list (apply #'eabp-column
                              (cons (eabp-section-header
                                     (format "%s (%d)"
                                             (if (string-empty-p col)
                                                 "No state" col)
                                             (length in-col)))
                                    (mapcar (lambda (i)
                                              (glasspane-views--board-card
                                               i columns))
                                            in-col))))
                 :padding 4)))
            columns))))

(defun glasspane-views--calendar-nodes (items)
  "The agenda rendering: items grouped by scheduled date, ascending."
  (let ((buckets (make-hash-table :test 'equal)))
    (dolist (item items)
      (let ((date (or (glasspane-ui--ts-date (alist-get 'scheduled item))
                     "")))
        (puthash date (cons item (gethash date buckets)) buckets)))
    (let ((dates (sort (hash-table-keys buckets)
                       (lambda (a b)
                         ;; Unscheduled ("" sorts first) goes last.
                         (cond ((string-empty-p a) nil)
                               ((string-empty-p b) t)
                               (t (string< a b)))))))
      (cl-loop for date in dates
               append
               (cons (eabp-section-header
                      (if (string-empty-p date) "Unscheduled"
                        (glasspane-ui--format-date date "%a, %b %e")))
                     (mapcar (lambda (item)
                               (eabp-card
                                (list (eabp-text
                                       (format "%s%s"
                                               (if-let ((todo (alist-get 'todo item)))
                                                   (concat todo " ") "")
                                               (or (alist-get 'headline item) ""))
                                       'body))
                                :on-tap (glasspane-views--tap item)))
                             (nreverse (gethash date buckets))))))))

;; ─── The two screens (one shell view) ────────────────────────────────────────

(defun glasspane-views--rendering-chips (view)
  "The List | Board | Calendar switcher for VIEW."
  (apply #'eabp-row
         (mapcar (lambda (r)
                   (eabp-chip (capitalize r)
                              :selected (equal r (alist-get 'rendering view))
                              :on-tap (eabp-action
                                       "views.rendering"
                                       :args `((name . ,(alist-get 'name view))
                                               (rendering . ,r))
                                       :when-offline "drop")))
                 glasspane-views--renderings)))

(defun glasspane-views--open-view (view snackbar)
  "The screen for one saved VIEW."
  (let* ((items (condition-case err
                    (glasspane-views--items view)
                  (user-error (list 'error (error-message-string err)))))
         (broken (eq (car-safe items) 'error)))
    (eabp-shell-nav-view
     (alist-get 'name view)
     (apply #'eabp-lazy-column
            (append
             (list (glasspane-views--rendering-chips view)
                   (eabp-spacer :height 4))
             (cond
              (broken
               (list (eabp-text (cadr items) 'body)))
              ((null items)
               ;; %s: a hand-authored query may be a sexp, not a string.
               (list (eabp-empty-state :icon "manage_search"
                                       :title "No matches"
                                       :caption (format "%s"
                                                        (alist-get 'query view)))))
              (t (pcase (alist-get 'rendering view)
                   ("board" (list (glasspane-views--board-node items)))
                   ("calendar" (glasspane-views--calendar-nodes items))
                   (_ (list (glasspane-views--table-node items))))))))
     :nav-action (eabp-action "views.back" :when-offline "drop")
     :snackbar snackbar)))

(defun glasspane-views--new-form ()
  "The collapsed new-view form at the hub's foot.
Field values mirror through the UI-state store; views.save reads them."
  (let ((gen glasspane-views--form-gen))
    (eabp-collapsible
     "views-new"
     (eabp-section-header "New view")
     (list
      (eabp-text-input (format "views-new-name-%d" gen)
                       :label "Name" :single-line t)
      (eabp-text-input (format "views-new-query-%d" gen)
                       :label "Query"
                       :hint "todo:TODO tags:work — or an org-ql sexp"
                       :single-line t)
      (eabp-enum-list (format "views-new-rendering-%d" gen)
                      glasspane-views--renderings
                      :value '("list"))
      (eabp-button "Save view"
                   (eabp-action "views.save" :when-offline "drop")
                   :icon "add"))
     :collapsed t)))

(defun glasspane-views--hub (snackbar)
  "The hub: every saved view as a card, plus the new-view form."
  (eabp-shell-nav-view
   "Saved views"
   (apply #'eabp-lazy-column
          (append
           (if glasspane-saved-views
               (mapcar
                (lambda (view)
                  (let ((name (alist-get 'name view)))
                    (eabp-card
                     (list
                      (eabp-row
                       (eabp-box
                        (list (eabp-column
                               (eabp-text name 'label)
                               (eabp-text (format "%s · %s"
                                                  (alist-get 'rendering view)
                                                  (alist-get 'query view))
                                          'caption)))
                        :weight 1)
                       (eabp-icon-button
                        "delete"
                        (eabp-action "views.delete" :args `((name . ,name))
                                     :when-offline "queue")
                        :content-description "Delete view")))
                     :on-tap (eabp-action "views.open" :args `((name . ,name))
                                          :when-offline "drop"))))
                glasspane-saved-views)
             (list (eabp-empty-state
                    :icon "manage_search" :title "No saved views"
                    :caption "Name a query below and it becomes a view")))
           (list (eabp-divider) (glasspane-views--new-form))))
   :snackbar snackbar))

(defun glasspane-views--view (snackbar)
  (if-let ((view (and glasspane-views--current
                      (glasspane-views--get glasspane-views--current))))
      (glasspane-views--open-view view snackbar)
    (glasspane-views--hub snackbar)))

(eabp-shell-define-view "views" :builder #'glasspane-views--view :order 75)

;; Everyday nav: saved views are a daily destination, so they ride the
;; drawer (the contract: drawer = everyday nav, satellites = settings).
(eabp-shell-add-drawer-item
 40 (lambda ()
      (eabp-drawer-item "manage_search" "Saved views"
                        (eabp-shell-switch-view "views"))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "views.open"
  (lambda (args _)
    (let ((name (alist-get 'name args)))
      (when (glasspane-views--get name)
        (setq glasspane-views--current name)
        (eabp-shell-push nil :switch-to "views")))))

(eabp-defaction "views.back"
  (lambda (_args _)
    (setq glasspane-views--current nil)
    (eabp-shell-push nil :switch-to "views")))

(eabp-defaction "views.rendering"
  (lambda (args _)
    (let ((view (glasspane-views--get (alist-get 'name args)))
          (rendering (alist-get 'rendering args)))
      (when (and view (member rendering glasspane-views--renderings))
        (glasspane-views--set-rendering (alist-get 'name view) rendering)
        (glasspane-views--persist)
        (eabp-shell-push)))))

(eabp-defaction "views.save"
  (lambda (_args _)
    (let* ((gen glasspane-views--form-gen)
           (name (string-trim
                  (or (eabp-ui-state (format "views-new-name-%d" gen)) "")))
           (query (string-trim
                   (or (eabp-ui-state (format "views-new-query-%d" gen)) "")))
           (rendering (let ((r (eabp-ui-state
                                (format "views-new-rendering-%d" gen))))
                        (cond ((stringp r) r)
                              ((consp r) (car r))
                              ((vectorp r) (aref r 0))
                              (t "list")))))
      (cond
       ((string-empty-p name) (eabp-shell-notify "The view needs a name"))
       ((string-empty-p query) (eabp-shell-notify "The view needs a query"))
       (t
        (condition-case err
            (progn
              ;; Parse now so a broken query fails at save, not render.
              (glasspane-org--parse-query query)
              (setq glasspane-saved-views
                    (append (cl-remove name glasspane-saved-views
                                       :key (lambda (v) (alist-get 'name v))
                                       :test #'equal)
                            (list `((name . ,name)
                                    (query . ,query)
                                    (rendering . ,(if (member rendering
                                                              glasspane-views--renderings)
                                                      rendering "list"))))))
              (glasspane-views--persist)
              (eabp-ui-state-clear "views-new")
              (cl-incf glasspane-views--form-gen)
              (eabp-shell-notify (format "Saved view %s" name)))
          (user-error (eabp-shell-notify (error-message-string err))))))
      (eabp-shell-push))))

(eabp-defaction "views.delete"
  (lambda (args _)
    (let ((name (alist-get 'name args)))
      (when (glasspane-views--get name)
        (setq glasspane-saved-views
              (cl-remove name glasspane-saved-views
                         :key (lambda (v) (alist-get 'name v)) :test #'equal))
        (glasspane-views--persist)
        (when (equal glasspane-views--current name)
          (setq glasspane-views--current nil))
        (eabp-shell-notify (format "Deleted view %s" name))
        (eabp-shell-push)))))

(provide 'glasspane-views)
;;; glasspane-views.el ends here
