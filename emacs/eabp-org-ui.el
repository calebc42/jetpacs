;;; eabp-org-ui.el --- EABP Org-Mode UI Screens -*- lexical-binding: t; -*-

;; Builds EABP surface specs for the org-client and handles inbound actions.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-org)
(require 'eabp-org-reader)
(require 'eabp-files)
(require 'eabp-keymap)
(require 'cl-lib)

(defvar eabp-org-ui--current-tab "agenda"
  "Currently active tab in the dashboard.")

(defvar eabp-org-ui--detail-ref nil
  "Reference alist (id/file/pos/headline) of the heading being viewed, or nil.")

(defvar eabp-org-ui--detail-read-mode t
  "When non-nil, detail view shows the foldable reader instead of the editor.")

(defvar eabp-org-ui--tasks-filter "ALL"
  "Current filter for the Tasks tab.")

(defvar eabp-org-ui--search-query ""
  "Last submitted query for the Search view.")

(defcustom eabp-org-custom-agendas nil
  "Alist of custom agenda views (Name . Query) for EABP."
  :type '(alist :key-type string :value-type string)
  :group 'eabp)

(defvar eabp-org-ui--search-results nil
  "Cached heading items from the last search.")

(defvar eabp-org-ui--snackbar nil
  "Transient snackbar text, consumed (and cleared) by the next dashboard push.")

(defun eabp-org-ui-snackbar (text)
  "Queue TEXT to show as a snackbar on the next dashboard push.
Note: the companion re-shows a snackbar only when the text *changes*,
so two identical messages back-to-back display once."
  (setq eabp-org-ui--snackbar text))

;; Forward-declare so the dashboard can reference it before eabp-emacs-ui loads
(defvar eabp-emacs-ui--viewing-buffer nil)

;; ─── Main Dashboard ──────────────────────────────────────────────────────────

(cl-defun eabp-org-ui-push-dashboard (&optional tab &key switch-to)
  "Push the dashboard as a multi-view surface.
Every tab is rendered as a named view in one push; the companion
switches between them locally (the `view.switch' builtin), so tab
navigation never waits on Emacs. TAB switches the logical tab before
building. SWITCH-TO additionally forces the companion onto that view
\(used when a push *is* the navigation, e.g. opening a detail)."
  (when tab
    (unless (equal tab eabp-org-ui--current-tab)
      (setq eabp-emacs-ui--viewing-buffer nil))
    (setq eabp-org-ui--current-tab tab))

  ;; Require the emacs-ui lazily (avoids load-order issues)
  (require 'eabp-emacs-ui)

  (condition-case err
      (let* ((active (eabp-org-ui--active-view))
             (target (or switch-to tab))
             ;; A navigation push lands the user on TARGET, so feedback
             ;; (e.g. "Saved init.el") must attach there, not to the view
             ;; they're leaving.
             (snack-view (or target active))
             (snackbar (prog1 eabp-org-ui--snackbar
                         (setq eabp-org-ui--snackbar nil)))
             (views (mapcar
                     (lambda (name)
                       (cons (intern name)
                             (eabp-org-ui--view name
                                                (when (equal name snack-view)
                                                  snackbar))))
                     (eabp-org-ui--view-names))))
        (eabp-surface-push
         "app:dashboard"
         `((views . ,views)
           (initial_view . ,active))
         nil nil
         ;; Force the companion onto a view only when this push *is* a
         ;; navigation (tab arg or detail open) — background refreshes must
         ;; not yank the user off whatever they're looking at.
         target))
    (error
     (message "EABP dashboard push failed: %s" (error-message-string err)))))

(defun eabp-org-ui--active-view ()
  "Name of the view that should be considered active for this push."
  (cond (eabp-org-ui--detail-ref "detail")
        (t eabp-org-ui--current-tab)))

(defun eabp-org-ui--view-names ()
  "All view names included in a dashboard push."
  (append '("agenda" "tasks" "clock" "buffers" "eval" "files" "search" "settings")
          (when eabp-files--file '("edit"))
          (when eabp-org-ui--detail-ref '("detail"))))

(defun eabp-org-ui--view (name snackbar)
  "Build the full scaffold view NAME. SNACKBAR is attached when non-nil."
  (let* ((is-detail (equal name "detail"))
         (is-edit (equal name "edit"))
         (is-files (equal name "files"))
         (is-search (equal name "search"))
         (is-buffer-view (and (equal name "buffers")
                              eabp-emacs-ui--viewing-buffer))
         (is-settings (equal name "settings"))
         (is-tab (and (not is-buffer-view)
                      (member name '("agenda" "tasks" "clock" "buffers" "eval" "files"))))
         (body (condition-case body-err
                   (cond
                    (is-detail
                     (eabp-org-ui--detail-body eabp-org-ui--detail-ref))
                    (is-edit
                     (eabp-files-editor-body))
                    (is-files
                     (eabp-files-browser-body))
                    (is-search
                     (eabp-org-ui--search-body))
                    (is-buffer-view
                     (eabp-emacs-ui--buffer-view-body eabp-emacs-ui--viewing-buffer))
                    (t
                     (pcase name
                       ("agenda"   (eabp-org-ui--agenda-body))
                       ("tasks"    (eabp-org-ui--tasks-body))
                       ("clock"    (eabp-org-ui--clock-body))
                       ("buffers"  (eabp-emacs-ui--buffer-list-body))
                       ("eval"     (eabp-emacs-ui--eval-body))
                       ("settings" (eabp-org-ui--settings-body))
                       (_          (eabp-text "Unknown tab")))))
                 (error
                  (eabp-column
                   (eabp-text "Error building tab" 'title)
                   (eabp-text (format "%s" (error-message-string body-err)) 'body)))))
         (top-bar (cond
                   (is-detail
                    ;; Back is pure navigation: builtin = instant, local,
                    ;; works offline. heading.back stays registered for
                    ;; compatibility but nothing emits it anymore.
                    (eabp-top-bar "Detail"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)
                                  :actions (list
                                            (eabp-icon-button
                                             (if eabp-org-ui--detail-read-mode "edit" "visibility")
                                             (eabp-action "detail.toggle-read")
                                             :content-description
                                             (if eabp-org-ui--detail-read-mode "Edit" "Read")))))
                   (is-edit
                    (eabp-top-bar (if eabp-files--file
                                      (file-name-nondirectory eabp-files--file)
                                    "Editor")
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view "files")
                                  :actions (when (eabp-files--org-p eabp-files--file)
                                             (delq nil
                                                   (list
                                                    (when eabp-files--read-mode
                                                      (eabp-icon-button
                                                       (if eabp-files--refile-mode "visibility" "swap_vert")
                                                       (eabp-action "files.toggle-refile")
                                                       :content-description
                                                       (if eabp-files--refile-mode "Reader" "Refile")))
                                                    (eabp-icon-button
                                                     (if eabp-files--read-mode "edit" "visibility")
                                                     (eabp-action "files.toggle-read")
                                                     :content-description
                                                     (if eabp-files--read-mode "Edit" "Read")))))))
                   ((and is-files eabp-files--dir)
                    (eabp-top-bar (abbreviate-file-name eabp-files--dir)
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-action "files.cd" :args '((dir . :null)))))
                   (is-search
                    (eabp-top-bar "Search"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)))
                   (is-settings
                    (eabp-top-bar "Settings"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)))
                   (is-buffer-view
                    ;; Content swap within the buffers view: stays an
                    ;; Emacs round-trip (the list must be rebuilt).
                    (eabp-top-bar (or eabp-emacs-ui--viewing-buffer "Buffer")
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-action "emacs.buffer.back")))
                   (t
                    (eabp-top-bar (capitalize name)
                                  :actions (append
                                            ;; A top-bar Eval button: always
                                            ;; reachable even if the input grows.
                                            (when (equal name "eval")
                                              (list (eabp-icon-button
                                                     "play_arrow"
                                                     (eabp-action "emacs.eval.submit")
                                                     :content-description "Eval")))
                                            (list
                                             (eabp-icon-button
                                              "search"
                                              (eabp-org-ui--switch-view "search")
                                              :content-description "Search")
                                             (eabp-icon-button "terminal"
                                                               (eabp-action "emacs.mx.show"))
                                             (eabp-icon-button "refresh"
                                                               (eabp-action "dashboard.refresh"
                                                                            :when-offline "drop"))))))))
         (fab (cond
               ((or is-detail is-edit is-search) nil)
               ;; Buffer view: keyboard FAB opens the radial keymap menu
               (is-buffer-view
                (eabp-fab "keyboard"
                          :on-tap (eabp-action "eabp.keymap.show"
                                   :args `((buffer . ,eabp-emacs-ui--viewing-buffer))
                                   :when-offline "drop")))
               ;; Files: a create FAB — the view always shows a directory now
               ;; (the landing dir or a subdirectory), so it's always offered.
               (is-files
                (eabp-fab "add" :label "New"
                          :on-tap (eabp-action "files.new")))
               ((equal name "eval")
                (eabp-fab "delete" :label "Clear"
                          :on-tap (eabp-action "emacs.eval.clear")))
               (t
                (eabp-fab "add" :label "Capture"
                          :on-tap (eabp-action "org.capture.show")))))
         (drawer (when is-tab (eabp-org-ui--drawer)))
         (bottom-bar
          (when is-tab
            (eabp-bottom-bar
             (mapcar (lambda (spec)
                       (pcase-let ((`(,icon ,label ,view) spec))
                         (eabp-nav-item icon label
                                        (eabp-org-ui--switch-view view)
                                        :selected (equal name view))))
                     '(("event" "Agenda" "agenda")
                       ("checklist" "Tasks" "tasks")
                       ("schedule" "Clock" "clock")
                       ("folder_open" "Files" "files")
                       ("code" "Eval" "eval")))))))
    `((children . ,(vector (eabp-scaffold :top-bar top-bar :body body
                                          :fab fab :bottom-bar bottom-bar
                                          :drawer drawer
                                          :snackbar snackbar))))))

(defun eabp-org-ui--drawer ()
  "The navigation drawer shown on tab views."
  (eabp-drawer
   (list
    (eabp-drawer-item "view_list" "Buffers"
                      (eabp-org-ui--switch-view "buffers"))
    (eabp-drawer-item "terminal" "M-x"
                      (eabp-action "emacs.mx.show"))
    (eabp-drawer-item "sync" "Reload config"
                      (eabp-action "config.reload"))
    (eabp-drawer-item "settings" "Settings"
                      (eabp-org-ui--switch-view "settings"))
    (eabp-drawer-item "refresh" "Refresh data"
                      (eabp-action "dashboard.refresh" :when-offline "drop")))
   :header "EABP"))

(defun eabp-org-ui--switch-view (view)
  "Action descriptor for the companion-local `view.switch' builtin."
  `((builtin . "view.switch") (view . ,view)))

;; ─── Tab Bodies ──────────────────────────────────────────────────────────────

(defun eabp-org-ui--agenda-card (it)
  (let* ((headline (or (alist-get 'headline it) "?"))
         (todo (alist-get 'todo it))
         (time (alist-get 'time it))
         (ref (alist-get 'ref it))
         (caption (string-join (delq nil (list time todo)) "  ·  ")))
    (eabp-card
     (list (eabp-column
            (eabp-text (or headline "Untitled") 'body)
            (if (string-empty-p caption)
                (eabp-spacer :height 0)
              (eabp-text caption 'caption))))
     :on-tap (eabp-action "heading.tap" :args ref))))

(defun eabp-org-ui--agenda-day-view (items)
  (let ((cards (mapcar #'eabp-org-ui--agenda-card items)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for today."))))

(defun eabp-org-ui--agenda-week-view (items)
  (let ((elements nil)
        (current-date nil))
    (dolist (it items)
      (let ((date (alist-get 'date it)))
        (unless (equal date current-date)
          (setq current-date date)
          (push (eabp-section-header (or date "Unknown Date")) elements))
        (push (eabp-org-ui--agenda-card it) elements)))
    (if elements
        (apply #'eabp-lazy-column (nreverse elements))
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for this week."))))

(defun eabp-org-ui--agenda-month-view (items)
  (let* ((selected-date (eabp-ui-state "agenda-selected-date"))
         (selected-date (if (stringp selected-date) selected-date (format-time-string "%Y-%m-%d")))
         (items-by-date (seq-group-by (lambda (it) (alist-get 'date it)) items))
         (selected-items (cdr (assoc selected-date items-by-date)))
         (decoded-now (decode-time))
         (month (nth 4 decoded-now))
         (year (nth 5 decoded-now))
         (days-in-month (calendar-last-day-of-month month year))
         (first-day-of-month (calendar-day-of-week (list month 1 year)))
         (grid-rows nil)
         (current-day 1)
         (week-header (apply #'eabp-row
                             (mapcar (lambda (d) (eabp-box (list (eabp-text d 'caption)) :weight 1 :alignment "center"))
                                     '("S" "M" "T" "W" "T" "F" "S")))))
    (while (<= current-day days-in-month)
      (let ((row-cells nil))
        (dotimes (dow 7)
          (if (or (and (= current-day 1) (< dow first-day-of-month))
                  (> current-day days-in-month))
              (push (eabp-box (list (eabp-spacer)) :weight 1) row-cells)
            (let* ((date-str (format "%04d-%02d-%02d" year month current-day))
                   (day-items (cdr (assoc date-str items-by-date)))
                   (is-selected (equal date-str selected-date))
                   (text-color (if is-selected "#FFFFFF" nil))
                   (bg-color (if is-selected "#1976D2" nil))
                   (cell-content (list
                                  (eabp-surface
                                   (list
                                    (eabp-text (number-to-string current-day) 'body nil text-color)
                                    (if day-items
                                        (eabp-icon "circle" :size 6 :color (if is-selected "#FFFFFF" "#1976D2") :padding 2)
                                      (eabp-spacer :height 8)))
                                   :color bg-color :shape "rounded" :padding 4))))
              (push (eabp-box cell-content :weight 1 :alignment "center"
                              :on-tap (eabp-action "agenda.select-date" :args `((date . ,date-str))))
                    row-cells)
              (setq current-day (1+ current-day)))))
        (push (apply #'eabp-row (nreverse row-cells)) grid-rows)))
    (eabp-column
     week-header
     (eabp-spacer :height 8)
     (apply #'eabp-column (nreverse grid-rows))
     (eabp-divider)
     (eabp-section-header (format "Events for %s" selected-date))
     (if selected-items
         (apply #'eabp-lazy-column (mapcar #'eabp-org-ui--agenda-card selected-items))
       (eabp-text "No events" 'caption)))))

(defun eabp-org-ui--agenda-body ()
  (let* ((mode (or (eabp-ui-state "agenda-mode") "day"))
         (start-day (if (equal mode "month") (format-time-string "%Y-%m-01") nil))
         (items (cond
                 ((equal mode "day") (condition-case nil (eabp-org--agenda-items 'day start-day) (error nil)))
                 ((equal mode "week") (condition-case nil (eabp-org--agenda-items 'week start-day) (error nil)))
                 ((equal mode "month") (condition-case nil (eabp-org--agenda-items 'month start-day) (error nil)))
                 (t (condition-case nil (eabp-org--search (cdr (assoc mode eabp-org-custom-agendas))) (error nil)))))
         (custom-chips (mapcar (lambda (ca)
                                 (let ((name (car ca)))
                                   (eabp-chip name
                                              :selected (equal mode name)
                                              :on-tap (eabp-action "agenda.set-mode" :args `((mode . ,name))))))
                               eabp-org-custom-agendas)))
    (eabp-column
     (apply #'eabp-flow-row
            (eabp-chip "Day"
                       :selected (equal mode "day")
                       :on-tap (eabp-action "agenda.set-mode" :args '((mode . "day"))))
            (eabp-chip "Week"
                       :selected (equal mode "week")
                       :on-tap (eabp-action "agenda.set-mode" :args '((mode . "week"))))
            (eabp-chip "Month"
                       :selected (equal mode "month")
                       :on-tap (eabp-action "agenda.set-mode" :args '((mode . "month"))))
            custom-chips)
     (eabp-spacer :height 8)
     (cond
      ((equal mode "day")
       (eabp-org-ui--agenda-day-view items))
      ((equal mode "week")
       (eabp-org-ui--agenda-week-view items))
      ((equal mode "month")
       (eabp-org-ui--agenda-month-view items))
      (t
       (if items
           (apply #'eabp-lazy-column (mapcar #'eabp-org-ui--agenda-card items))
         (eabp-empty-state :icon "event_busy"
                           :title "No results"
                           :caption "This custom agenda found no items.")))))))

(defun eabp-org-ui--tasks-body ()
  (let* ((items (condition-case nil
                    (eabp-org--todo-items)
                  (error nil)))
         (filtered (if (equal eabp-org-ui--tasks-filter "ALL") items
                     (cl-remove-if-not
                      (lambda (it)
                        (equal (alist-get 'todo it) eabp-org-ui--tasks-filter))
                      items)))
         (cards (mapcar (lambda (it)
                          (let ((headline (or (alist-get 'headline it) "?"))
                                (todo (or (alist-get 'todo it) ""))
                                (ref (alist-get 'ref it)))
                            (eabp-card
                             (list (eabp-row
                                    (eabp-box
                                     (list (eabp-column
                                            (eabp-text headline 'body)
                                            (eabp-text todo 'caption)))
                                     :weight 1)
                                    (eabp-icon-button
                                     "check"
                                     (eabp-action "heading.todo-set"
                                                  :args (cons '(state . "DONE") ref)
                                                  :dedupe (format "todo-set/%s"
                                                                  (or (alist-get 'id ref)
                                                                      (alist-get 'headline ref)
                                                                      "?"))))))
                             :on-tap (eabp-action "heading.tap" :args ref))))
                        filtered)))
    (eabp-column
     (apply #'eabp-flow-row
            (mapcar (lambda (kw)
                      (eabp-chip kw
                                 :selected (equal eabp-org-ui--tasks-filter kw)
                                 :on-tap (eabp-action "tasks.filter"
                                                      :args `((filter . ,kw)))))
                    (cons "ALL" (or (default-value 'org-todo-keywords-1)
                                    '("TODO" "DONE")))))
     (if cards
         (apply #'eabp-lazy-column cards)
       (eabp-empty-state :icon "task_alt"
                         :title "No tasks"
                         :caption "Nothing matches this filter.")))))

;; The old agenda-files-only "files" body is superseded by the full
;; browser in eabp-files.el (eabp-files-browser-body).

(defun eabp-org-ui--clock-body ()
  (let* ((status (eabp-org--clock-status))
         (recent (condition-case nil
                     (eabp-org--recent-clocks 5)
                   (error nil)))
         (status-card
          (if status
              (let* ((start (alist-get 'start status))
                     (mins (when start
                             (max 0 (floor (/ (- (float-time) start) 60))))))
                (eabp-card
                 (list (eabp-column
                        (eabp-text "Currently Clocked In" 'caption)
                        (eabp-text (or (alist-get 'task status) "?") 'headline)
                        (eabp-text (if mins (format "%d min elapsed" mins) "")
                                   'caption)
                        (eabp-button "Clock Out" (eabp-action "org.clock.out"))))))
            (eabp-empty-state :icon "schedule"
                              :title "Not clocked in"
                              :caption "Pick a recent task below to start.")))
         (recent-cards
          (mapcar (lambda (r)
                    (eabp-card
                     (list (eabp-text (or (alist-get 'headline r) "?") 'body))
                     :on-tap (eabp-action "heading.clock-in"
                                          :args (alist-get 'ref r))))
                  recent))
         (all-children (append (list status-card)
                               (when recent-cards
                                 (cons (eabp-section-header "Recent Tasks")
                                       recent-cards)))))
    (apply #'eabp-column all-children)))

(defun eabp-org-ui--result-card (it)
  "Render a search/heading item IT to a tappable card with tag chips."
  (let* ((headline (or (alist-get 'headline it) "?"))
         (todo (alist-get 'todo it))
         (file (alist-get 'file it))
         (tags (append (alist-get 'tags it) nil))
         (ref (alist-get 'ref it))
         (caption (string-join
                   (delq nil (list todo (when file (file-name-nondirectory file))))
                   "  ·  "))
         (children (delq nil
                         (list
                          (eabp-text headline 'body)
                          (unless (string-empty-p caption)
                            (eabp-text caption 'caption))
                          (when tags
                            (apply #'eabp-flow-row
                                   (mapcar (lambda (tg)
                                             (eabp-assist-chip (concat "#" tg)))
                                           tags)))))))
    (eabp-card (list (apply #'eabp-column children))
               :on-tap (eabp-action "heading.tap" :args ref))))

(defun eabp-org-ui--search-body ()
  (let* ((q (or eabp-org-ui--search-query ""))
         (results eabp-org-ui--search-results)
         (input (eabp-text-input "search-query"
                                 :value q
                                 :hint "Search headings (text or org-ql query)"
                                 :single-line t
                                 :on-submit (eabp-action "org.search.run")))
         (todo-val (or (eabp-ui-state "search-filter-todo") "Any"))
         (tags-val (or (eabp-ui-state "search-filter-tags") []))
         (text-val (or (eabp-ui-state "search-filter-text") ""))
         (available-tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist))
         (builder (eabp-card
                   (list
                    (eabp-column
                     (eabp-text "Query Builder" 'headline)
                     (eabp-text "Status:" 'caption)
                     (eabp-enum-list "search-filter-todo" '("Any" "TODO" "DONE")
                                     :value todo-val
                                     :on-change (eabp-action "search.update-filter" :args '((field . "todo"))))
                     (eabp-text "Tags:" 'caption)
                     (eabp-enum-list "search-filter-tags" available-tags
                                     :value tags-val
                                     :multi-select t
                                     :on-change (eabp-action "search.update-filter" :args '((field . "tags"))))
                     (eabp-text "Text Contains:" 'caption)
                     (eabp-text-input "search-filter-text"
                                      :value text-val
                                      :hint "Search text..."
                                      :single-line t
                                      :on-submit (eabp-action "search.update-filter" :args '((field . "text"))))))
                   :padding 16))
         (cards (mapcar #'eabp-org-ui--result-card results)))
    (eabp-column
     builder
     (eabp-spacer :height 8)
     (eabp-row
      (eabp-box (list input) :weight 1)
      (eabp-button "Search" (eabp-action "org.search.run" :args `((value . ,q))))
      (eabp-button "Save" (eabp-action "agenda.save-custom" :args `((query . ,q)))))
     (cond
      (cards (apply #'eabp-lazy-column cards))
      ((and (stringp q) (not (string-empty-p q)))
       (eabp-empty-state :icon "manage_search"
                         :title "No matches"
                         :caption (format "Nothing matched \"%s\"." q)))
      (t
       (eabp-empty-state :icon "search"
                         :title "Search your notes"
                         :caption "Type a query and press search."))))))

(defun eabp-org-ui--settings-body ()
  (let* ((available-tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist))
         (enum-list (eabp-enum-list "settings-tags" available-tags
                                    :value available-tags
                                    :multi-select t
                                    :allow-add t
                                    :on-change (eabp-action "settings.tags"))))
    (eabp-column
     (eabp-section-header "Global Org Tags")
     (eabp-text "Manage the global tag list (org-tag-alist)." 'caption)
     enum-list)))

(defun eabp-org-ui--todo-chips (current keywords ref)
  "A row of chips for KEYWORDS with CURRENT selected; taps carry REF."
  (apply #'eabp-flow-row
         (mapcar (lambda (kw)
                   (eabp-chip kw
                              :selected (equal kw current)
                              :on-tap (eabp-action
                                       "heading.todo-set"
                                       :args (cons (cons 'state kw) ref))))
                 keywords)))

(defun eabp-org-ui--ts-date (ts)
  "Return the YYYY-MM-DD date inside org timestamp string TS, or nil."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" ts))
    (match-string 1 ts)))

(defun eabp-org-ui--ts-time (ts)
  "Return the HH:MM time inside org timestamp string TS, or nil."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)" ts))
    (match-string 1 ts)))

(defun eabp-org-ui--priority-chips (current ref)
  "A row of priority chips (A..C plus None) with CURRENT selected; taps carry REF."
  (let* ((hi (or (bound-and-true-p org-priority-highest) ?A))
         (lo (or (bound-and-true-p org-priority-lowest) ?C))
         (levels (mapcar #'char-to-string (number-sequence hi lo))))
    (apply #'eabp-flow-row
           (append
            (mapcar (lambda (p)
                      (eabp-chip p
                                 :selected (equal p current)
                                 :on-tap (eabp-action
                                          "heading.priority"
                                          :args (cons (cons 'value p) ref))))
                    levels)
            (list (eabp-chip "None"
                             :selected (null current)
                             :on-tap (eabp-action
                                      "heading.priority"
                                      :args (cons '(value . "") ref))))))))

(defun eabp-org-ui--detail-body (ref)
  (condition-case err
      (let* ((marker (eabp-org--resolve-ref ref))
             (buf (marker-buffer marker))
             (file (buffer-file-name buf))
             (pos (marker-position marker))
             (meta (with-current-buffer buf
                     (org-with-wide-buffer
                      (goto-char pos)
                      (let ((comps (org-heading-components)))
                        (list :headline (or (nth 4 comps) "")
                              :todo (nth 2 comps)
                              :priority (and (nth 3 comps)
                                             (char-to-string (nth 3 comps)))
                              :tags (org-get-tags pos t)
                              :scheduled (org-entry-get pos "SCHEDULED")
                              :deadline (org-entry-get pos "DEADLINE")
                              :keywords (or org-todo-keywords-1 '("TODO" "DONE")))))))
             (headline (plist-get meta :headline))
             (todo (plist-get meta :todo))
             (priority (plist-get meta :priority))
             (tags (plist-get meta :tags))
             (scheduled (plist-get meta :scheduled))
             (deadline (plist-get meta :deadline))
             (keywords (plist-get meta :keywords))
             (is-clocked-in (and (bound-and-true-p org-clock-hd-marker)
                                 (marker-buffer org-clock-hd-marker)
                                 (equal buf (marker-buffer org-clock-hd-marker))
                                 (with-current-buffer buf
                                   (= (line-number-at-pos marker)
                                      (line-number-at-pos org-clock-hd-marker)))))
             (sched-button
              (lambda (label when)
                (eabp-button label
                             (eabp-action "heading.schedule"
                                          :args (cons (cons 'when when) ref))
                             :variant "text"))))
        (if (not eabp-org-ui--detail-read-mode)
            (let ((content (with-current-buffer buf
                             (org-with-wide-buffer
                              (goto-char pos)
                              (org-mark-subtree)
                              (buffer-substring-no-properties (region-beginning) (region-end))))))
              (eabp-column
               (eabp-editor (format "detail-%s" pos) content
                            :syntax "org"
                            :on-save (eabp-action "detail.save"
                                                  :args `((ref . ,ref))
                                                  :when-offline "queue"
                                                  :dedupe (format "save-detail/%s" pos)))))
          (let ((sdate (eabp-org-ui--ts-date scheduled))
                (ddate (eabp-org-ui--ts-date deadline))
                (entry-props (ignore-errors
                               (with-current-buffer buf
                                 (org-with-wide-buffer
                                  (goto-char pos)
                                  (org-entry-properties pos 'standard))))))
            (apply #'eabp-lazy-column
                   (delq nil
                         (append
                          (list
                           ;; File breadcrumb
                           (eabp-text (file-name-nondirectory (or file "?")) 'caption)
                           ;; Headline
                           (eabp-text headline 'title)
                           ;; State (always visible)
                           (eabp-org-ui--todo-chips todo keywords ref)
                           ;; Priority (always visible)
                           (eabp-org-ui--priority-chips priority ref)
                           (eabp-divider)
                           ;; ▸ Scheduling (collapsible — expanded when any date is set)
                           (eabp-collapsible
                            (format "detail-sched/%s" pos)
                            (eabp-text "Scheduling" 'label)
                            (delq nil
                                  (list
                                   (eabp-row
                                    (if sdate (eabp-date-stamp :date sdate) (eabp-spacer :width 0))
                                    (eabp-box
                                     (list
                                      (eabp-column
                                       (eabp-text (concat "Scheduled: " (or scheduled "—")) 'caption)
                                       (eabp-flow-row
                                        (eabp-date-button "Set date"
                                                          (eabp-action "heading.schedule" :args ref)
                                                          :value sdate)
                                        (eabp-time-button "Set time"
                                                          (eabp-action "heading.schedule-time" :args ref)
                                                          :value (eabp-org-ui--ts-time scheduled))
                                        (funcall sched-button "Today" "+0d")
                                        (funcall sched-button "+1d" "+1d")
                                        (funcall sched-button "+1w" "+1w")
                                        (eabp-button "Clear"
                                                     (eabp-action "heading.schedule"
                                                                  :args (cons '(clear . t) ref))
                                                     :variant "text"))))
                                     :weight 1))
                                   (eabp-text (concat "Deadline: " (or deadline "—")) 'caption)
                                   (eabp-flow-row
                                    (eabp-date-button "Set date"
                                                      (eabp-action "heading.deadline" :args ref)
                                                      :value ddate)
                                    (eabp-button "Clear"
                                                 (eabp-action "heading.deadline"
                                                              :args (cons '(clear . t) ref))
                                                 :variant "text"))))
                            :collapsed (not (or sdate ddate)))
                           ;; ▸ Tags (collapsible)
                           (let ((available (seq-uniq (append tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist)))))
                             (eabp-collapsible
                              (format "detail-tags-fold/%s" pos)
                              (eabp-text (if tags (format "Tags (%d)" (length tags)) "Tags") 'label)
                              (list
                               (eabp-enum-list (format "detail-tags/%s" pos) available
                                               :value tags :multi-select t :allow-add t
                                               :on-change (eabp-action "heading.tags" :args ref)))
                              :collapsed (null tags)))
                           ;; ▸ Clock (collapsible)
                           (eabp-collapsible
                            (format "detail-clock/%s" pos)
                            (eabp-text "Clock" 'label)
                            (list
                             (if is-clocked-in
                                 (eabp-button "Clock Out" (eabp-action "org.clock.out"))
                               (eabp-button "Clock In" (eabp-action "heading.clock-in" :args ref))))
                            :collapsed (not is-clocked-in))
                           ;; TODO: Add LOGBOOK collapsible section
                           ;; ▸ Properties (collapsible — collapsed by default)
                           (when entry-props
                             (let ((text (mapconcat (lambda (kv) (format ":%s: %s" (car kv) (cdr kv)))
                                                   entry-props "\n")))
                               (eabp-collapsible
                                (format "detail-props/%s" pos)
                                (eabp-text "Properties" 'label)
                                (list (eabp-text text 'mono))
                                :collapsed t)))
                           (eabp-divider))
                          ;; Reader: body (highlighted) and child headings (foldable).
                          ;; Properties are shown above, so skip them here.
                          (eabp-org-reader-subtree file pos t)))))))
    (error
     (eabp-column
      (eabp-text "Error loading heading" 'title)
      (eabp-text (error-message-string err) 'body)))))

;; ─── Capture Dialog ──────────────────────────────────────────────────────────

(defun eabp-org-ui-show-capture-dialog ()
  (condition-case err
      (let* ((templates (eabp-org--capture-templates))
             (template-buttons
              (mapcar (lambda (t-info)
                        (eabp-button
                         (alist-get 'description t-info)
                         (eabp-action "org.capture.select"
                                      :args `((key . ,(alist-get 'key t-info))))
                         :variant "outlined"))
                      templates))
             (dialog-body
              (apply #'eabp-column
                     (eabp-text "Quick Capture" 'title)
                     (eabp-text "Select a template:" 'caption)
                     (append template-buttons
                             (list (eabp-button "Cancel"
                                               (eabp-action "org.capture.cancel")
                                               :variant "text"))))))
        (eabp-send-dialog dialog-body))
    (error
     (message "EABP capture dialog error: %s" (error-message-string err)))))

(defun eabp-org-ui-show-capture-form (template-key)
  ;; Forget values from any previous capture so they can't leak into
  ;; this submit (`eabp--ui-state' is global and persistent).
  (eabp-ui-state-clear "cap-")
  (condition-case err
      (let* ((templates (eabp-org--capture-templates))
             (tmpl (cl-find-if
                    (lambda (t-info) (equal (alist-get 'key t-info) template-key))
                    templates))
             (prompts (append (alist-get 'prompts tmpl) nil)) ;; coerce vector to list
             (inputs (mapcar (lambda (p)
                               (eabp-text-input (format "cap-%s" p) :label p))
                             prompts))
             (dialog-body
              (apply #'eabp-column
                     (eabp-text (format "Capture: %s" (alist-get 'description tmpl)) 'title)
                     (append inputs
                             (list
                              (eabp-row
                               (eabp-button "Cancel"
                                            (eabp-action "org.capture.cancel")
                                            :variant "text")
                               (eabp-button "Capture"
                                            (eabp-action "org.capture.submit"
                                                         :args `((key . ,template-key))))))))))
        (eabp-send-dialog dialog-body))
    (error
     (message "EABP capture form error: %s" (error-message-string err)))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

(eabp-defaction "view.switched"
  (lambda (args _)
    ;; The companion already flipped the view locally — this event only
    ;; synchronizes Emacs's notion of "where the user is" and refreshes
    ;; the (possibly stale) cached views in the background.
    (let ((view (alist-get 'view args)))
      (when view
        (unless (equal view "detail")
          (setq eabp-org-ui--detail-ref nil)
          (unless (equal view eabp-org-ui--current-tab)
            (setq eabp-emacs-ui--viewing-buffer nil))
          (when (member view '("agenda" "tasks" "clock" "files" "eval"))
            (setq eabp-org-ui--current-tab view)))
        ;; Back from the editor closes the file (the next push drops the
        ;; edit view). Unsaved companion-side text is discarded with it.
        (when (and (equal view "files") eabp-files--file)
          (setq eabp-files--file nil))
        ;; No :switch-to — never yank the user during a background refresh.
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "nav.tab"
  ;; Legacy round-trip navigation; superseded by the view.switch builtin
  ;; but kept so stale cached UIs from older pushes still work.
  (lambda (args _)
    (let ((tab (alist-get 'tab args)))
      (eabp-org-ui-push-dashboard tab))))

(eabp-defaction "dashboard.refresh"
  (lambda (_ _)
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "heading.tap"
  (lambda (args _)
    ;; ARGS is the ref alist (id/file/pos/headline) the card embedded.
    ;; This push IS the navigation, so it forces the detail view.
    (setq eabp-org-ui--detail-ref args)
    (setq eabp-org-ui--detail-read-mode t)
    (eabp-org-ui-push-dashboard nil :switch-to "detail")))

(eabp-defaction "detail.toggle-read"
  (lambda (_ _)
    (setq eabp-org-ui--detail-read-mode (not eabp-org-ui--detail-read-mode))
    (eabp-org-ui-push-dashboard nil :switch-to "detail")))

(eabp-defaction "detail.save"
  (lambda (args _)
    (let ((ref (alist-get 'ref args))
          (value (alist-get 'value args)))
      (when (and ref value)
        (condition-case err
            (let* ((marker (eabp-org--resolve-ref ref))
                   (buf (marker-buffer marker))
                   (pos (marker-position marker)))
              (with-current-buffer buf
                (org-with-wide-buffer
                 (goto-char pos)
                 (org-mark-subtree)
                 (delete-region (region-beginning) (region-end))
                 (insert value)
                 (goto-char pos)
                 (setq eabp-org-ui--detail-ref (eabp-org--heading-ref))
                 (let ((eabp-org--inhibit-save-refresh t)
                       (save-silently t))
                   (save-buffer))))
              (when (fboundp 'eabp-org-cache-invalidate)
                (eabp-org-cache-invalidate))
              (setq eabp-org-ui--detail-read-mode t)
              (eabp-org-ui-snackbar "Saved heading"))
          (error
           (eabp-org-ui-snackbar (format "Save failed: %s" (error-message-string err))))))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.back"
  ;; Legacy: detail's back button is now a companion-local view.switch.
  ;; Kept for stale cached UIs.
  (lambda (_ _)
    (setq eabp-org-ui--detail-ref nil)
    (eabp-org-ui-push-dashboard nil :switch-to eabp-org-ui--current-tab)))

(eabp-defaction "tasks.filter"
  (lambda (args _)
    (setq eabp-org-ui--tasks-filter (alist-get 'filter args))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "org.search.run"
  ;; The query arrives as the search field's submitted `value'. Run it,
  ;; cache the results, and land the user on the search view.
  (lambda (args _)
    (let ((q (or (alist-get 'value args) "")))
      (setq eabp-org-ui--search-query q
            eabp-org-ui--search-results
            (condition-case err
                (eabp-org--search q)
              (error
               (message "EABP search error: %s" (error-message-string err))
               nil)))
      (eabp-org-ui-push-dashboard nil :switch-to "search"))))

(eabp-defaction "org.capture.show"
  (lambda (_ _)
    (eabp-org-ui-show-capture-dialog)))

(eabp-defaction "org.capture.select"
  (lambda (args _)
    (eabp-org-ui-show-capture-form (alist-get 'key args))))

(eabp-defaction "org.capture.cancel"
  (lambda (_ _)
    (eabp-dismiss-dialog)))

(eabp-defaction "org.capture.submit"
  (lambda (args _)
    (let ((key (alist-get 'key args)))
      (condition-case err
          (let* ((templates (eabp-org--capture-templates))
                 (tmpl (cl-find-if
                        (lambda (t-info) (equal (alist-get 'key t-info) key))
                        templates))
                 (prompts (append (alist-get 'prompts tmpl) nil))
                 ;; Field values arrived earlier as state.changed events and
                 ;; were recorded into `eabp--ui-state' by eabp-surfaces.
                 (values (mapcar
                          (lambda (p)
                            (let ((v (eabp-ui-state (format "cap-%s" p))))
                              (cons p (if (stringp v) v ""))))
                          prompts)))
            (eabp-org--do-capture key values)
            (eabp-org-cache-invalidate)
            (eabp-ui-state-clear "cap-")
            (eabp-org-ui-snackbar "Captured ✓")
            (eabp-dismiss-dialog)
            (eabp-org-ui-push-dashboard))
        (error
         (message "EABP capture submit error: %s" (error-message-string err))
         (eabp-ui-state-clear "cap-")
         (eabp-dismiss-dialog))))))

(defun eabp-org-ui--at-ref (args fn &optional save)
  "Resolve ARGS to its heading and call FN with point there.
With SAVE non-nil, save the buffer afterwards (guarded against
triggering our own after-save refresh on top of the explicit push).
Returns non-nil on success; messages and returns nil on failure."
  (condition-case err
      (let ((marker (eabp-org--resolve-ref args)))
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (funcall fn))
          (when save
            (let ((eabp-org--inhibit-save-refresh t)
                  (save-silently t))
              (save-buffer))))
        (eabp-org-cache-invalidate)
        t)
    (error
     (message "EABP: heading action failed: %s" (error-message-string err))
     (eabp-org-ui-snackbar "Couldn't find that heading — refreshing")
     (eabp-org-ui-push-dashboard)
     nil)))

(eabp-defaction "heading.todo-set"
  (lambda (args _)
    (let ((state (alist-get 'state args)))
      (when (and state
                 (eabp-org-ui--at-ref args (lambda () (org-todo state)) t))
        (eabp-org-ui-snackbar (format "State → %s" state))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.schedule"
  (lambda (args _)
    ;; CLEAR removes the timestamp; otherwise WHEN (relative, e.g. "+1d") or
    ;; VALUE (concrete "YYYY-MM-DD", from the date picker) sets it.
    (let* ((clear (alist-get 'clear args))
           (date (or (alist-get 'when args) (alist-get 'value args)))
           (ok (cond
                (clear (eabp-org-ui--at-ref args (lambda () (org-schedule '(4))) t))
                ((and (stringp date) (not (string-empty-p date)))
                 (eabp-org-ui--at-ref args (lambda () (org-schedule nil date)) t)))))
      (when ok
        (eabp-org-ui-snackbar (if clear "Schedule cleared" (format "Scheduled %s" date)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.schedule-time"
  ;; Adds/updates the clock time on the existing SCHEDULED date (today if
  ;; none yet). VALUE is the "HH:MM" the time picker injected.
  (lambda (args _)
    (let ((time (alist-get 'value args)))
      (when (and (stringp time) (not (string-empty-p time))
                 (eabp-org-ui--at-ref
                  args
                  (lambda ()
                    (let* ((sched (org-entry-get nil "SCHEDULED"))
                           (date (or (eabp-org-ui--ts-date sched)
                                     (format-time-string "%Y-%m-%d"))))
                      (org-schedule nil (format "%s %s" date time))))
                  t))
        (eabp-org-ui-snackbar (format "Scheduled %s" time))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "org.footnote.show"
  ;; A tapped footnote marker in rich text: surface its inline definition
  ;; (when the reference carried one) or just its label.
  (lambda (args _)
    (let ((def (alist-get 'def args))
          (label (alist-get 'label args)))
      (eabp-org-ui-snackbar
       (if (and (stringp def) (not (string-empty-p def)))
           (format "Footnote: %s" def)
         (format "Footnote %s" (or label ""))))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.deadline"
  (lambda (args _)
    (let* ((clear (alist-get 'clear args))
           (date (or (alist-get 'when args) (alist-get 'value args)))
           (ok (cond
                (clear (eabp-org-ui--at-ref args (lambda () (org-deadline '(4))) t))
                ((and (stringp date) (not (string-empty-p date)))
                 (eabp-org-ui--at-ref args (lambda () (org-deadline nil date)) t)))))
      (when ok
        (eabp-org-ui-snackbar (if clear "Deadline cleared" (format "Deadline %s" date)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.priority"
  (lambda (args _)
    ;; Empty VALUE means None (remove); otherwise the first char is the priority.
    (let* ((val (alist-get 'value args))
           (remove (or (null val) (string-empty-p val)))
           (ok (eabp-org-ui--at-ref
                args
                (lambda ()
                  (if remove (org-priority 'remove)
                    (org-priority (string-to-char val))))
                t)))
      (when ok
        (eabp-org-ui-snackbar (if remove "Priority cleared"
                                (format "Priority %s" val)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.tags"
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (tags (cond
                  ((vectorp val) (append val nil))
                  ((listp val) val)
                  ((stringp val) (split-string val "[ \t:,]+" t))
                  (t nil)))
           (ok (eabp-org-ui--at-ref args (lambda () (org-set-tags tags)) t)))
      (when ok
        (eabp-org-ui-snackbar (if tags (format "Tags: %s" (string-join tags " "))
                                "Tags cleared"))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "settings.tags"
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (tags-list (cond
                       ((vectorp val) (append val nil))
                       ((listp val) val)
                       (t nil))))
      (when tags-list
        ;; Keep existing keys/chars if possible, else just use the string
        (let ((new-alist (mapcar (lambda (tg)
                                   (let ((existing (assoc tg org-tag-alist)))
                                     (if existing existing tg)))
                                 tags-list)))
          (setq org-tag-alist new-alist)
          (customize-save-variable 'org-tag-alist org-tag-alist)))
      (eabp-org-ui-snackbar "Settings saved")
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "search.update-filter"
  (lambda (args _)
    (let ((field (alist-get 'field args))
          (value (alist-get 'value args)))
      (eabp-ui-state-put (concat "search-filter-" field) value)
      (let* ((todo (eabp-ui-state "search-filter-todo"))
             (tags (eabp-ui-state "search-filter-tags"))
             (text (eabp-ui-state "search-filter-text"))
             (clauses nil))
        (when (and (stringp todo) (not (equal todo "Any")))
          (push `(todo ,todo) clauses))
        (when (vectorp tags)
          (dolist (tg (append tags nil))
            (push `(tags ,tg) clauses)))
        (when (and (stringp text) (not (string-empty-p text)))
          (push `(regexp ,text) clauses))
        (let ((q (if clauses
                     (if (= (length clauses) 1)
                         (format "%S" (car clauses))
                       (format "%S" `(and ,@(nreverse clauses))))
                   "")))
          (setq eabp-org-ui--search-query q)
          (eabp-ui-state-put "search-query" q)))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "agenda.save-custom"
  (lambda (args _)
    (let* ((query (alist-get 'query args))
           (name (read-string "Agenda Name: ")))
      (when (and (stringp name) (not (string-empty-p name)))
        ;; Remove existing if overriding
        (setq eabp-org-custom-agendas (assoc-delete-all name eabp-org-custom-agendas))
        (add-to-list 'eabp-org-custom-agendas (cons name query) t)
        (customize-save-variable 'eabp-org-custom-agendas eabp-org-custom-agendas)
        (eabp-org-ui-snackbar (format "Saved custom agenda: %s" name))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "agenda.set-mode"
  (lambda (args _)
    (let ((mode (alist-get 'mode args)))
      (eabp-ui-state-put "agenda-mode" mode)
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "agenda.select-date"
  (lambda (args _)
    (let ((date (alist-get 'date args)))
      (eabp-ui-state-put "agenda-selected-date" date)
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.clock-in"
  (lambda (args _)
    (when (eabp-org-ui--at-ref args #'org-clock-in)
      (eabp-org-ui-snackbar "Clocked in")
      (eabp-org-ui-push-dashboard "clock"))))

(eabp-defaction "org.link.open"
  ;; A tappable link inside rich org text. Emacs resolves it (id:, file:,
  ;; http(s):, attachment:, …) via the org link machinery; we report the
  ;; outcome back as a snackbar since the action itself happens Emacs-side.
  (lambda (args _)
    (let ((link (alist-get 'link args)))
      (when (and (stringp link) (not (string-empty-p link)))
        (condition-case err
            (progn
              (org-link-open-from-string link)
              (eabp-org-ui-snackbar (format "Opened %s" link)))
          (error
           (eabp-org-ui-snackbar
            (format "Couldn't open %s: %s" link (error-message-string err)))))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "checkbox.toggle"
  ;; Toggle a checkbox in an org file from the reader view.  The companion
  ;; sends FILE and POS (the real-buffer position of the list item line).
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (pos  (alist-get 'pos args)))
      (when (and file pos (file-readable-p file))
        (condition-case err
            (progn
              (with-current-buffer (find-file-noselect file)
                (org-with-wide-buffer
                 (goto-char pos)
                 (org-toggle-checkbox))
                (let ((eabp-org--inhibit-save-refresh t)
                      (save-silently t))
                  (save-buffer)))
              (eabp-org-cache-invalidate)
              (eabp-org-ui-push-dashboard))
          (error
           (eabp-org-ui-snackbar
            (format "Toggle failed: %s" (error-message-string err)))))))))

(eabp-defaction "heading.reorder"
  (lambda (args _)
    (let* ((file      (alist-get 'file args))
           (from-pos  (alist-get 'from_pos args))
           (after-pos (alist-get 'after_pos args))  ;; 0 or nil = move to top
           (new-level (alist-get 'new_level args)))
      (when (and file from-pos (file-readable-p file))
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (goto-char from-pos)
           (org-back-to-heading t)
           (let* ((from-level (org-outline-level))
                  (subtree-beg (point))
                  (subtree-end (save-excursion (org-end-of-subtree t t) (point)))
                  (subtree-size (- subtree-end subtree-beg)))
             ;; Cut the subtree
             (org-cut-subtree)
             ;; Navigate to the insertion point
             (if (and after-pos (> after-pos 0))
                 (let ((target (if (> after-pos from-pos)
                                   (- after-pos subtree-size)
                                 after-pos)))
                   (goto-char (min target (point-max)))
                   (org-back-to-heading t)
                   (org-end-of-subtree t t))
               ;; Move to top of file (before first heading)
               (goto-char (point-min))
               (when (re-search-forward org-heading-regexp nil t)
                 (goto-char (line-beginning-position))))
             ;; Paste at the new level (or original level if nil)
             (org-paste-subtree (or new-level from-level)))))
        (let ((eabp-org--inhibit-save-refresh t)
              (save-silently t))
          (with-current-buffer (find-file-noselect file)
            (save-buffer)))
        (eabp-org-cache-invalidate)
        (eabp-org-ui-push-dashboard nil :switch-to "edit")))))

(eabp-defaction "file.view"
  ;; Legacy (old cached UIs): now routes into the eabp-files editor.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file) (file-readable-p file))
        (setq eabp-files--file (expand-file-name file))
        (eabp-org-ui-push-dashboard nil :switch-to "edit")))))

;; ─── Auto-refresh ────────────────────────────────────────────────────────────

(defvar eabp-org-ui--save-refresh-timer nil)

(defcustom eabp-org-ui-save-refresh-delay 2
  "Idle seconds after saving an agenda file before re-pushing the dashboard.
Debounces bursts of saves (e.g. `org-save-all-org-buffers') into one push."
  :type 'integer :group 'eabp)

(defun eabp-org-ui--after-save-refresh ()
  "Schedule a dashboard refresh if an org agenda file was just saved.
No-op for saves EABP itself performs (ID creation, action handlers),
which would otherwise refresh twice or loop."
  (when (and (eabp-connected-p)
             (not (bound-and-true-p eabp-org--inhibit-save-refresh))
             buffer-file-name
             (derived-mode-p 'org-mode)
             (ignore-errors
               (member (expand-file-name buffer-file-name)
                       (mapcar #'expand-file-name (org-agenda-files)))))
    (eabp-org-cache-invalidate)
    (when (timerp eabp-org-ui--save-refresh-timer)
      (cancel-timer eabp-org-ui--save-refresh-timer))
    (setq eabp-org-ui--save-refresh-timer
          (run-with-idle-timer eabp-org-ui-save-refresh-delay nil
                               #'eabp-org-ui-push-dashboard))))

(add-hook 'after-save-hook #'eabp-org-ui--after-save-refresh)

(defun eabp-org-ui--refresh-if-connected (&rest _)
  "Re-push the dashboard when there's a live session.
Safe to put on any hook: a no-op while disconnected."
  (when (eabp-connected-p)
    (eabp-org-ui-push-dashboard)))

;; After (re)connect, push the dashboard so the app never shows a stale
;; screen from a previous Emacs session. Depth 10: after the revision
;; snapshot has been absorbed (-50 in eabp-surfaces) and after the
;; org-clock notification re-assert (0).
(add-hook 'eabp-connected-hook
          (lambda (_welcome) (eabp-org-ui-push-dashboard))
          10)

;; After a replay, queued taps have just mutated org state — the cached
;; views on the phone are now behind reality.
(add-hook 'eabp-queue-drained-hook
          (lambda (_payload)
            (eabp-org-cache-invalidate)
            (eabp-org-ui-push-dashboard)))

;; Clock state shows on the Clock tab and the dashboard generally —
;; keep it live. Depth 90: after eabp-surfaces' notification hooks.
(add-hook 'org-clock-in-hook  #'eabp-org-ui--refresh-if-connected 90)
(add-hook 'org-clock-out-hook #'eabp-org-ui--refresh-if-connected 90)

(provide 'eabp-org-ui)
;;; eabp-org-ui.el ends here