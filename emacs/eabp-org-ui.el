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
(require 'eabp-magit)
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
         target)
        ;; Piggyback the cheap companions of a dashboard push: upcoming
        ;; reminder alarms and the home-screen widget. Both are memo-guarded
        ;; so unchanged data sends nothing.
        (eabp-org-ui--sync-reminders)
        (eabp-org-ui--push-widget))
    (error
     (message "EABP dashboard push failed: %s" (error-message-string err)))))

(defvar eabp-org-ui--last-reminders 'unset
  "Reminder list from the previous sync, to suppress identical sends.")

(defun eabp-org-ui--sync-reminders ()
  "Send upcoming timed items to the companion as exact-alarm reminders."
  (let ((rems (condition-case nil (eabp-org--upcoming-reminders) (error nil))))
    (unless (equal rems eabp-org-ui--last-reminders)
      (setq eabp-org-ui--last-reminders rems)
      (eabp-send "reminders.set" `((reminders . ,(vconcat rems)))))))

(defvar eabp-org-ui--last-widget 'unset
  "Widget lines from the previous push, to suppress identical pushes.")

(defun eabp-org-ui--widget-lines ()
  "Today's agenda as short \"HH:MM  Headline\" strings for the widget."
  (mapcar (lambda (it)
            (let ((hm (eabp-org--item-hm (alist-get 'time it))))
              (concat (if hm (concat hm "  ") "")
                      (or (alist-get 'headline it) ""))))
          (seq-take (condition-case nil
                        (eabp-org--agenda-items 'day nil)
                      (error nil))
                    6)))

(defun eabp-org-ui--push-widget ()
  "Push the `widget:agenda' surface backing the home-screen widget."
  (let ((lines (eabp-org-ui--widget-lines)))
    (unless (equal lines eabp-org-ui--last-widget)
      (setq eabp-org-ui--last-widget lines)
      (eabp-surface-push
       "widget:agenda"
       `((title . ,(format-time-string "Agenda · %a %b %d"))
         (lines . ,(vconcat lines)))))))

(defun eabp-org-ui--active-view ()
  "Name of the view that should be considered active for this push."
  (cond (eabp-org-ui--detail-ref "detail")
        (t eabp-org-ui--current-tab)))

(defun eabp-org-ui--view-names ()
  "All view names included in a dashboard push."
  (append '("agenda" "tasks" "clock" "buffers" "eval" "files" "search"
            "settings" "messages")
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
         (is-messages (equal name "messages"))
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
                       ("messages" (eabp-emacs-ui--messages-body))
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
                                             "note_add"
                                             (eabp-action "heading.add-note"
                                                          :args eabp-org-ui--detail-ref
                                                          :when-offline "drop")
                                             :content-description "Add note")
                                            (eabp-icon-button
                                             "drive_file_move"
                                             (eabp-action "heading.refile"
                                                          :args eabp-org-ui--detail-ref
                                                          :when-offline "drop")
                                             :content-description "Refile")
                                            (eabp-icon-button
                                             "archive"
                                             (eabp-action "heading.archive"
                                                          :args eabp-org-ui--detail-ref
                                                          :when-offline "drop")
                                             :content-description "Archive")
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
                   (is-messages
                    (eabp-top-bar "Messages"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)
                                  :actions (list
                                            (eabp-icon-button
                                             "refresh"
                                             (eabp-action "emacs.messages.refresh"
                                                          :when-offline "drop")
                                             :content-description "Refresh"))))
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
               ((or is-detail is-edit is-search is-settings is-messages) nil)
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
                                          :snackbar snackbar
                                          ;; Tab views support pull-to-refresh;
                                          ;; navigation/detail views don't (a
                                          ;; stray pull mustn't rebuild them).
                                          :on-refresh
                                          (when is-tab
                                            (eabp-action "dashboard.refresh"
                                                         :when-offline "drop"))))))))

(defun eabp-org-ui--drawer ()
  "The navigation drawer shown on tab views."
  (eabp-drawer
   (list
    (eabp-drawer-item "view_list" "Buffers"
                      (eabp-org-ui--switch-view "buffers"))
    (eabp-drawer-item "history" "Messages"
                      (eabp-org-ui--switch-view "messages"))
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

;; ── Agenda navigation ──
;; The agenda is anchored on a date (UI state "agenda-anchor", nil = today).
;; The ‹ › buttons shift the anchor by one day/week/month according to the
;; active span, and the anchor feeds `eabp-org--agenda-items' as START-DAY —
;; whose cache keys already include it, so each visited range memoises
;; independently.

(defun eabp-org-ui--agenda-anchor ()
  "The agenda's anchor date as \"YYYY-MM-DD\"; today when unset."
  (let ((a (eabp-ui-state "agenda-anchor")))
    (if (and (stringp a) (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" a))
        a
      (format-time-string "%Y-%m-%d"))))

(defun eabp-org-ui--shift-date (date n unit)
  "Shift DATE (\"YYYY-MM-DD\") by N UNITs (`day', `week', or `month').
Month arithmetic clamps the day into the target month, so Jan 31 + 1
month is Feb 28, not an invalid date."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (if (eq unit 'month)
        (let* ((total (+ (* 12 y) (1- m) n))
               (ny (/ total 12))
               (nm (1+ (% total 12))))
          (format "%04d-%02d-%02d" ny nm
                  (min d (calendar-last-day-of-month nm ny))))
      (let ((days (* n (if (eq unit 'week) 7 1))))
        ;; Noon avoids DST-transition off-by-one-day surprises.
        (format-time-string "%Y-%m-%d"
                            (time-add (encode-time 0 0 12 d m y)
                                      (* days 86400)))))))

(defun eabp-org-ui--format-date (date fmt)
  "Render DATE (\"YYYY-MM-DD\") through `format-time-string' FMT."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (format-time-string fmt (encode-time 0 0 12 d m y))))

(defun eabp-org-ui--agenda-nav-row (mode anchor)
  "The ‹ [range label] [today] › navigation row for the agenda header."
  (let* ((today (format-time-string "%Y-%m-%d"))
         (at-today (pcase mode
                     ("month" (equal (substring anchor 0 7) (substring today 0 7)))
                     (_ (equal anchor today))))
         (label (pcase mode
                  ("month" (eabp-org-ui--format-date anchor "%B %Y"))
                  ("week" (concat "Week of "
                                  (eabp-org-ui--format-date anchor "%b %d")))
                  (_ (if at-today
                         (concat "Today · " (eabp-org-ui--format-date anchor "%a, %b %d"))
                       (eabp-org-ui--format-date anchor "%a, %b %d"))))))
    (apply #'eabp-row
           (delq nil
                 (list
                  (eabp-icon-button "chevron_left"
                                    (eabp-action "agenda.nav" :args '((dir . -1)))
                                    :content-description "Previous")
                  (eabp-box (list (eabp-text label 'label))
                            :weight 1 :alignment "center")
                  (unless at-today
                    (eabp-icon-button "today" (eabp-action "agenda.today")
                                      :content-description "Back to today"))
                  (eabp-icon-button "chevron_right"
                                    (eabp-action "agenda.nav" :args '((dir . 1)))
                                    :content-description "Next"))))))

;; ── Agenda cards ──

(defun eabp-org-ui--agenda-type-icon (type)
  "Return (ICON . COLOR) for an agenda item TYPE string (color may be nil)."
  (cond
   ((null type) '("event" . nil))
   ((string-match-p "past-scheduled" type) '("history" . "#E53935"))
   ((string-match-p "deadline" type) '("flag" . nil))
   ((string-match-p "scheduled" type) '("schedule" . nil))
   (t '("event" . nil))))

(defun eabp-org-ui--agenda-type-label (type)
  "Short human label for an agenda item TYPE string, or nil to omit."
  (pcase type
    ("past-scheduled" "overdue")
    ("upcoming-deadline" "deadline soon")
    ("deadline" "deadline")
    ("scheduled" "scheduled")
    (_ nil)))

(defun eabp-org-ui--card-date-row (it)
  "An inline scheduling indicator for card item IT.
Shows compact date-stamp chips for SCHEDULED and/or DEADLINE when present.
Returns nil when neither is set."
  (let* ((scheduled (alist-get 'scheduled it))
         (deadline  (alist-get 'deadline it))
         (sdate (eabp-org-ui--ts-date scheduled))
         (ddate (eabp-org-ui--ts-date deadline))
         (chips (delq nil
                      (list
                       (when sdate
                         (eabp-row
                          (eabp-icon "schedule" :size 14)
                          (eabp-date-stamp :date sdate
                                           :time (eabp-org-ui--ts-time scheduled)
                                           :padding 2)))
                       (when ddate
                         (eabp-row
                          (eabp-icon "flag" :size 14)
                          (eabp-date-stamp :date ddate
                                           :time (eabp-org-ui--ts-time deadline)
                                           :padding 2)))))))
    (when chips
      (apply #'eabp-flow-row chips))))

(defun eabp-org-ui--agenda-card (it)
  "A detail-rich agenda card for item IT.
Leading time (or a type icon), priority-prefixed headline (struck
through when done), a todo/type/file caption, tag chips when present,
and a quick complete button for open todos."
  (let* ((headline (or (alist-get 'headline it) "Untitled"))
         (todo (alist-get 'todo it))
         ;; Normalized "HH:MM" — the raw property is a time-grid string
         ;; like " 9:15......".
         (time (eabp-org--item-hm (alist-get 'time it)))
         (type (alist-get 'type it))
         (file (alist-get 'file it))
         (priority (alist-get 'priority it))
         (tags (append (alist-get 'tags it) nil))
         (ref (alist-get 'ref it))
         (done (and todo (member todo (or (default-value 'org-done-keywords)
                                          '("DONE" "CANCELLED")))))
         (icon+color (eabp-org-ui--agenda-type-icon type))
         (caption (string-join
                   (delq nil (list todo
                                   (and (stringp type)
                                        (eabp-org-ui--agenda-type-label type))
                                   (and file (file-name-nondirectory file))))
                   "  ·  "))
         (lead (if (and (stringp time) (not (string-empty-p time)))
                   (eabp-text time 'label)
                 (eabp-icon (car icon+color) :size 18 :color (cdr icon+color))))
         (headline-node
          (eabp-rich-text
           (delq nil
                 (list
                  (when priority
                    (eabp-span (format "[#%s] " priority) :bold t :color "#F57C00"))
                  (if done
                      (eabp-span headline :strike t)
                    (eabp-span headline))))))
         (middle
          (apply #'eabp-column
                 (delq nil
                       (list
                        headline-node
                        (unless (string-empty-p caption)
                          (eabp-text caption 'caption))
                        (eabp-org-ui--card-date-row it)
                        (when tags
                          (apply #'eabp-flow-row
                                 (mapcar (lambda (tg)
                                           (eabp-assist-chip (concat "#" tg)))
                                         tags)))))))
         (complete-btn
          (when (and todo (not done))
            (eabp-icon-button
             "check"
             (eabp-action "heading.todo-set"
                          :args (cons '(state . "DONE") ref)
                          :dedupe (format "todo-set/%s"
                                          (or (alist-get 'id ref)
                                              (alist-get 'headline ref)
                                              "?")))
             :content-description "Mark done"))))
    (eabp-card
     (list (apply #'eabp-row
                  (delq nil (list lead
                                  (eabp-box (list middle) :weight 1)
                                  complete-btn))))
     :on-tap (eabp-action "heading.tap" :args ref))))

(defun eabp-org-ui--agenda-day-view (items)
  (let ((cards (mapcar #'eabp-org-ui--agenda-card items)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for this day."))))

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

(defun eabp-org-ui--agenda-month-view (items anchor)
  "Month grid for ITEMS, showing the month containing ANCHOR (YYYY-MM-DD)."
  (let* ((today (format-time-string "%Y-%m-%d"))
         (month-prefix (substring anchor 0 7))
         (sel (eabp-ui-state "agenda-selected-date"))
         ;; A remembered selection only counts inside the shown month;
         ;; otherwise select today (when visible) or the anchor day.
         (selected-date (cond
                         ((and (stringp sel) (string-prefix-p month-prefix sel)) sel)
                         ((string-prefix-p month-prefix today) today)
                         (t anchor)))
         (items-by-date (seq-group-by (lambda (it) (alist-get 'date it)) items))
         (selected-items (cdr (assoc selected-date items-by-date)))
         (month (string-to-number (substring anchor 5 7)))
         (year (string-to-number (substring anchor 0 4)))
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
         (is-span (member mode '("day" "week" "month")))
         (anchor (eabp-org-ui--agenda-anchor))
         ;; The month span always starts on the 1st so the grid and the
         ;; extraction agree on the visible range.
         (start-day (cond ((equal mode "month") (concat (substring anchor 0 7) "-01"))
                          (is-span anchor)))
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
    (apply #'eabp-column
           (delq nil
                 (list
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
                  (when is-span
                    (eabp-org-ui--agenda-nav-row mode anchor))
                  (eabp-spacer :height 4)
                  (cond
                   ((equal mode "day")
                    (eabp-org-ui--agenda-day-view items))
                   ((equal mode "week")
                    (eabp-org-ui--agenda-week-view items))
                   ((equal mode "month")
                    (eabp-org-ui--agenda-month-view items anchor))
                   (t
                    (if items
                        (apply #'eabp-lazy-column (mapcar #'eabp-org-ui--agenda-card items))
                      (eabp-empty-state :icon "event_busy"
                                        :title "No results"
                                        :caption "This custom agenda found no items.")))))))))

(defun eabp-org-ui--tasks-body ()
  (let* ((items (condition-case nil
                    (eabp-org--todo-items)
                  (error nil)))
         (filtered (if (equal eabp-org-ui--tasks-filter "ALL") items
                     (cl-remove-if-not
                      (lambda (it)
                        (equal (alist-get 'todo it) eabp-org-ui--tasks-filter))
                      items)))
         (cards (mapcar #'eabp-org-ui--agenda-card filtered)))
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
                                    :on-change (eabp-action "settings.tags")))
         (linenum-value (pcase eabp-line-numbers
                          ('absolute "Absolute")
                          ('relative "Relative")
                          (_ "Off"))))
    (eabp-column
     (eabp-section-header "Display")
     (eabp-text "Line numbers in the buffer view and editor." 'caption)
     (eabp-enum-list "settings-linenum" '("Off" "Absolute" "Relative")
                     :value (list linenum-value)
                     :on-change (eabp-action "settings.line-numbers"))
     (eabp-divider)
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

(defun eabp-org-ui--ts-repeater (ts)
  "Return the repeater cookie (e.g. \"+1w\", \".+2d\") inside TS, or nil.
The one part of a timestamp the date-stamp chip can't display."
  (when (and (stringp ts)
             (string-match "\\([.+]?\\+[0-9]+[hdwmy]\\)" ts))
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

(defun eabp-org-ui--property-row (key value ref pos)
  "A two-column KEY → editable VALUE row for the detail Properties editor.
KEY renders without org's colons.  ID is shown read-only (editing it
breaks links); every other value is an inline input whose submit runs
`heading.prop-set' — submitting an empty value removes the property."
  (eabp-row
   (eabp-box (list (eabp-text key 'label)) :weight 2)
   (eabp-box
    (list (if (equal key "ID")
              (eabp-text value 'caption nil nil t)
            (eabp-text-input (format "prop-%s/%s" pos key)
                             :value value
                             :single-line t
                             :on-submit (eabp-action "heading.prop-set"
                                                     :args (cons `(name . ,key) ref)))))
    :weight 3)))

(defun eabp-org-ui--properties-section (props ref pos)
  "The Properties collapsible: KEY → VALUE rows plus an + Add button.
Always present (even with no properties yet) so + Add is reachable."
  (eabp-collapsible
   (format "detail-props/%s" pos)
   (eabp-text (if props (format "Properties (%d)" (length props)) "Properties")
              'label)
   (delq nil
         (append
          (mapcar (lambda (kv)
                    (eabp-org-ui--property-row (car kv) (or (cdr kv) "") ref pos))
                  props)
          (list
           (when props
             (eabp-text "Submit an empty value to remove a property." 'caption))
           (eabp-row
            (eabp-spacer :weight 1)
            (eabp-button "+ Add property"
                         (eabp-action "heading.prop-add" :args ref)
                         :variant "outlined")))))
   :collapsed t))

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
                            :line-numbers (and eabp-line-numbers
                                               (symbol-name eabp-line-numbers))
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
                           ;; The date-stamp chip IS the display (date + time);
                           ;; the raw "<2026-07-02 Thu>" caption is gone. Only a
                           ;; repeater cookie — which the chip can't show —
                           ;; surfaces as a caption.
                           (eabp-collapsible
                            (format "detail-sched/%s" pos)
                            (eabp-text "Scheduling" 'label)
                            (list
                             (eabp-row
                              (if sdate
                                  (eabp-date-stamp :date sdate
                                                   :time (eabp-org-ui--ts-time scheduled))
                                (eabp-spacer :width 0))
                              (eabp-box
                               (list
                                (apply #'eabp-column
                                       (delq nil
                                             (list
                                              (eabp-text "Scheduled" 'label)
                                              (unless sdate
                                                (eabp-text "Not scheduled" 'caption))
                                              (when-let ((rep (eabp-org-ui--ts-repeater scheduled)))
                                                (eabp-text (concat "Repeats " rep) 'caption))
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
                                                            :variant "text"))))))
                               :weight 1))
                             (eabp-divider)
                             (eabp-row
                              (if ddate
                                  (eabp-date-stamp :date ddate
                                                   :time (eabp-org-ui--ts-time deadline))
                                (eabp-spacer :width 0))
                              (eabp-box
                               (list
                                (apply #'eabp-column
                                       (delq nil
                                             (list
                                              (eabp-text "Deadline" 'label)
                                              (unless ddate
                                                (eabp-text "No deadline" 'caption))
                                              (when-let ((rep (eabp-org-ui--ts-repeater deadline)))
                                                (eabp-text (concat "Repeats " rep) 'caption))
                                              (eabp-flow-row
                                               (eabp-date-button "Set date"
                                                                 (eabp-action "heading.deadline" :args ref)
                                                                 :value ddate)
                                               (eabp-button "Clear"
                                                            (eabp-action "heading.deadline"
                                                                         :args (cons '(clear . t) ref))
                                                            :variant "text"))))))
                               :weight 1)))
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
                           (eabp-org-ui--properties-section entry-props ref pos)
                           (eabp-divider))
                          ;; Reader: body (highlighted) and child headings (foldable).
                          ;; Properties are shown above, so skip them here.
                          (eabp-org-reader-subtree file pos t)))))))
    (error
     (eabp-column
      (eabp-text "Error loading heading" 'title)
      (eabp-text (error-message-string err) 'body)))))

;; ─── Capture Dialog ──────────────────────────────────────────────────────────

(defvar eabp-org-ui--shared-text nil
  "Body text shared from another app, pending the next capture submit.")
(defvar eabp-org-ui--shared-subject nil
  "Subject shared from another app; seeds the capture Headline field.")

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
                     (append
                      ;; Shared-in content shows a preview so the user knows
                      ;; what this capture will carry.
                      (when eabp-org-ui--shared-text
                        (list (eabp-card
                               (list (eabp-text
                                      (truncate-string-to-width
                                       eabp-org-ui--shared-text 200 nil nil "…")
                                      'caption)))))
                      template-buttons
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
  ;; A shared-in subject pre-fills the Headline field; it must also land
  ;; in UI state, since state.changed only fires for edits the user makes.
  (when eabp-org-ui--shared-subject
    (eabp-ui-state-put "cap-Headline" eabp-org-ui--shared-subject))
  (condition-case err
      (let* ((templates (eabp-org--capture-templates))
             (tmpl (cl-find-if
                    (lambda (t-info) (equal (alist-get 'key t-info) template-key))
                    templates))
             (prompts (append (alist-get 'prompts tmpl) nil)) ;; coerce vector to list
             (inputs (mapcar (lambda (p)
                               (eabp-text-input
                                (format "cap-%s" p) :label p
                                :value (and (equal p "Headline")
                                            eabp-org-ui--shared-subject)))
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
    ;; Manual refresh is an explicit "give me fresh data": bypass the memo.
    (eabp-org-cache-invalidate)
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
    (setq eabp-org-ui--shared-text nil
          eabp-org-ui--shared-subject nil)
    (eabp-dismiss-dialog)))

(eabp-defaction "org.capture.share"
  ;; Android share sheet → capture: stash the shared text/subject and open
  ;; the template picker.  Queued offline, so sharing works with Emacs dead
  ;; — the capture dialog appears on the next replay.
  (lambda (args _)
    (let ((text (alist-get 'text args))
          (subject (alist-get 'subject args)))
      (setq eabp-org-ui--shared-text
            (and (stringp text) (not (string-empty-p (string-trim text)))
                 (string-trim text))
            eabp-org-ui--shared-subject
            (and (stringp subject) (not (string-empty-p (string-trim subject)))
                 (string-trim subject)))
      ;; A share with only a subject still captures: use it as the text too.
      (unless eabp-org-ui--shared-text
        (setq eabp-org-ui--shared-text eabp-org-ui--shared-subject))
      (eabp-org-ui-show-capture-dialog))))

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
            (eabp-org--do-capture key values eabp-org-ui--shared-text)
            (setq eabp-org-ui--shared-text nil
                  eabp-org-ui--shared-subject nil)
            (eabp-org-cache-invalidate)
            (eabp-ui-state-clear "cap-")
            (eabp-org-ui-snackbar "Captured ✓")
            (eabp-dismiss-dialog)
            (eabp-org-ui-push-dashboard))
        (error
         (message "EABP capture submit error: %s" (error-message-string err))
         (setq eabp-org-ui--shared-text nil
               eabp-org-ui--shared-subject nil)
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

(eabp-defaction "heading.refile"
  ;; Bridged picker over org-refile targets; refiles the whole subtree.
  (lambda (args _)
    (condition-case err
        (let ((marker (eabp-org--resolve-ref args)))
          (with-current-buffer (marker-buffer marker)
            (org-with-wide-buffer
             (goto-char marker)
             (let* ((org-refile-targets (or org-refile-targets
                                            '((org-agenda-files :maxlevel . 3))))
                    (targets (org-refile-get-targets))
                    (choice (condition-case nil
                                (completing-read "Refile to: "
                                                 (mapcar #'car targets) nil t)
                              (quit nil)))
                    (target (and choice (assoc choice targets))))
               (if (not target)
                   (eabp-org-ui-snackbar "Refile cancelled")
                 (org-refile nil nil target)
                 (let ((eabp-org--inhibit-save-refresh t)
                       (save-silently t))
                   (org-save-all-org-buffers))
                 (eabp-org-cache-invalidate)
                 (setq eabp-org-ui--detail-ref nil)
                 (eabp-org-ui-snackbar (format "Refiled to %s" choice))))))
          (eabp-org-ui-push-dashboard nil :switch-to eabp-org-ui--current-tab))
      (error
       (eabp-org-ui-snackbar (format "Refile failed: %s"
                                     (error-message-string err)))
       (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.archive"
  ;; Bridged y/n confirm, then org-archive-subtree; saves source + archive.
  (lambda (args _)
    (let ((headline (or (alist-get 'headline args) "this heading")))
      (if (not (yes-or-no-p (format "Archive \"%s\"? " headline)))
          (eabp-org-ui-snackbar "Archive cancelled")
        (when (eabp-org-ui--at-ref
               args
               (lambda ()
                 (org-archive-subtree)
                 (let ((eabp-org--inhibit-save-refresh t)
                       (save-silently t))
                   (org-save-all-org-buffers))))
          (setq eabp-org-ui--detail-ref nil)
          (eabp-org-ui-snackbar "Archived")))
      (eabp-org-ui-push-dashboard nil :switch-to eabp-org-ui--current-tab))))

(eabp-defaction "heading.add-note"
  ;; Quick logbook note: bridged prompt, written where org-log-into-drawer
  ;; says notes belong, in org's own note format.
  (lambda (args _)
    (let ((note (string-trim (condition-case nil
                                 (read-string "Note: ")
                               (quit "")))))
      (if (string-empty-p note)
          (eabp-org-ui-snackbar "Note cancelled")
        (when (eabp-org-ui--at-ref
               args
               (lambda ()
                 (goto-char (org-log-beginning t))
                 (insert (format "- Note taken on %s \\\\\n  %s\n"
                                 (format-time-string
                                  (org-time-stamp-format t t))
                                 note)))
               t)
          (eabp-org-ui-snackbar "Note added")))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.prop-set"
  ;; VALUE arrives injected by the row input's on-submit; NAME rides in
  ;; args. An empty value deletes the property.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (value (string-trim (or (alist-get 'value args) "")))
           (ok (and (stringp name) (not (string-empty-p name))
                    (eabp-org-ui--at-ref
                     args
                     (lambda ()
                       (if (string-empty-p value)
                           (org-delete-property name)
                         (org-set-property name value)))
                     t))))
      (when ok
        (eabp-org-ui-snackbar (if (string-empty-p value)
                                  (format "Removed %s" name)
                                (format "%s → %s" name value)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.prop-add"
  ;; The bridged read-string asks for the key; the new (empty) property
  ;; then appears as a row whose value column is ready to fill in.
  (lambda (args _)
    (let ((name (string-trim (condition-case nil
                                 (read-string "New property name: ")
                               (quit "")))))
      (cond
       ((string-empty-p name) nil)
       ((string-match-p "[: \t]" name)
        (eabp-org-ui-snackbar "Property names can't contain colons or spaces"))
       ((eabp-org-ui--at-ref args
                             (lambda () (org-set-property (upcase name) ""))
                             t)
        (eabp-org-ui-snackbar (format "Added %s — fill in its value" (upcase name)))))
      (eabp-org-ui-push-dashboard))))

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

(eabp-defaction "settings.line-numbers"
  ;; Single-select enum: value arrives as a JSON array with (at most) one
  ;; entry.  Deselecting everything counts as Off.
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (choice (car (append val nil)))
           (sym (pcase choice
                  ("Absolute" 'absolute)
                  ("Relative" 'relative)
                  (_ nil))))
      (setq eabp-line-numbers sym)
      (ignore-errors (customize-save-variable 'eabp-line-numbers sym))
      (eabp-org-ui-snackbar (format "Line numbers: %s" (or choice "Off")))
      (eabp-org-ui-push-dashboard))))

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

(eabp-defaction "agenda.nav"
  ;; Shift the agenda anchor by DIR (±1) in units of the active span.
  (lambda (args _)
    (let* ((dir (alist-get 'dir args))
           (dir (if (numberp dir) dir 1))
           (mode (or (eabp-ui-state "agenda-mode") "day"))
           (unit (pcase mode ("week" 'week) ("month" 'month) (_ 'day)))
           (anchor (eabp-org-ui--agenda-anchor)))
      ;; Month steps walk 1st → 1st so ±1 never skips a short month.
      (when (eq unit 'month)
        (setq anchor (concat (substring anchor 0 7) "-01")))
      (eabp-ui-state-put "agenda-anchor"
                         (eabp-org-ui--shift-date anchor dir unit))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "agenda.today"
  ;; Reset the anchor (and any month-grid selection) back to today.
  (lambda (_ _)
    (eabp-ui-state-put "agenda-anchor" nil)
    (eabp-ui-state-put "agenda-selected-date" nil)
    (eabp-org-ui-push-dashboard)))

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
Safe to put on any hook: a no-op while disconnected.  Invalidates the
extraction cache first — this runs on clock in/out, which mutate the
org buffer without necessarily saving it."
  (when (eabp-connected-p)
    (eabp-org-cache-invalidate)
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