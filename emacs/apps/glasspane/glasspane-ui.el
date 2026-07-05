;;; glasspane-ui.el --- The Glasspane org app for EABP -*- lexical-binding: t; -*-

;; The reference Tier 1 app: registers the org views (agenda, tasks, clock,
;; search, detail, settings) into the generic shell (eabp-shell.el) and
;; handles their semantic actions.  Everything here is one opinionated take
;; built on the core seams — shell views, the files module's editor hooks,
;; the settings registry, the render-buffer skin registry.  Nothing below
;; is required for the core bridge to function.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-shell)
(require 'glasspane-org)
(require 'glasspane-clock)
(require 'glasspane-org-reader)
(require 'eabp-files)
(require 'eabp-keymap)
(require 'eabp-magit)
(require 'eabp-settings)
;; Not used directly — pulled in so (require 'glasspane-ui) still assembles
;; the complete reference app for init-file users.
(require 'eabp-emacs-ui)
(require 'eabp-package-browser)
(require 'cl-lib)

(defvar glasspane-ui--detail-ref nil
  "Reference alist (id/file/pos/headline) of the heading being viewed, or nil.")

(defvar glasspane-ui--detail-read-mode t
  "When non-nil, detail view shows the foldable reader instead of the editor.")

(defvar glasspane-ui--tasks-filter "ALL"
  "Current filter for the Tasks tab.")

(defvar glasspane-ui--search-query ""
  "Last submitted query for the Search view.")

(defcustom glasspane-org-custom-agendas nil
  "Alist of custom agenda views (Name . Query) for EABP."
  :type '(alist :key-type string :value-type string)
  :group 'eabp)

(defvar glasspane-ui--search-results nil
  "Cached heading items from the last search.")

;; ─── Reminders & home-screen widget (piggybacked on each shell push) ────────

(defvar glasspane-ui--last-reminders 'unset
  "Reminder list from the previous sync, to suppress identical sends.")

(defun glasspane-ui--sync-reminders ()
  "Send upcoming timed items to the companion as exact-alarm reminders."
  (let ((rems (condition-case nil (glasspane-org--upcoming-reminders) (error nil))))
    (unless (equal rems glasspane-ui--last-reminders)
      (setq glasspane-ui--last-reminders rems)
      (eabp-send "reminders.set" `((reminders . ,(vconcat rems)))))))

(defvar glasspane-ui--last-widget 'unset
  "Widget views from the previous push, to suppress identical pushes.")

(defun glasspane-ui--widget-item-meta (it hm)
  "Compose the widget metadata line for agenda item IT.
Leads with the time HM or the agenda's own qualifier (\"Sched. 3x\",
\"In 3 d.\", \"2 d. ago\"), then the file name — the Orgzly-style
second row. A bare \"Scheduled\"/\"Deadline\" qualifier restates what
the row's type icon already says, so it is dropped."
  (let* ((extra (alist-get 'extra it))
         (extra (and (stringp extra)
                     (replace-regexp-in-string
                      "[ \t]+" " "
                      (string-trim (replace-regexp-in-string
                                    ":[ \t]*\\'" "" (string-trim extra))))))
         (extra (and extra (not (member extra '("" "Scheduled" "Deadline")))
                     extra))
         (file (alist-get 'file it)))
    (string-join (delq nil (list (or hm extra)
                                 (and file (file-name-nondirectory file))))
                 " · ")))

(defun glasspane-ui--widget-agenda-icon (type)
  "Map an org agenda TYPE to a widget metadata icon name."
  (cond ((not (stringp type)) "event")
        ((string-match-p "deadline" type) "deadline")
        ((string-match-p "scheduled" type) "scheduled")
        (t "event")))

(defun glasspane-ui--widget-row (it)
  "Build one generic widget row from agenda item IT.
All semantics live here: the row tap opens the heading in the app, the
trailing circle todo-cycles silently — the companion just renders."
  (let* ((hm (glasspane-org--item-hm (alist-get 'time it)))
         (todo (alist-get 'todo it))
         (done (and todo
                    (member todo (or (default-value 'org-done-keywords)
                                     '("DONE" "CANCELLED")))
                    t))
         (ref (alist-get 'ref it))
         (meta (glasspane-ui--widget-item-meta it hm))
         (meta (unless (string-empty-p meta) meta)))
    (eabp-widget-item
     (or (alist-get 'headline it) "Untitled")
     :todo todo :done done
     :meta meta
     :icon (and meta (glasspane-ui--widget-agenda-icon (alist-get 'type it)))
     :on-tap (eabp-action "heading.tap" :args ref) :in-app t
     :button (and todo (if done "todo_done" "todo_open"))
     :on-button (and todo (eabp-action "heading.todo-cycle" :args ref)))))

(defun glasspane-ui--widget-items ()
  "Today's agenda as widget rows, overdue grouped under dividers."
  (let* ((today (org-today))
         ;; The widget list scrolls, so the cap is just a sanity bound on
         ;; spec size, not a display limit.
         (raw (seq-take (condition-case nil
                            (glasspane-org--agenda-items 'day nil)
                          (error nil))
                        20))
         (overdue-p (lambda (it)
                      (let ((ts (alist-get 'ts-date it)))
                        (and (numberp ts) (< ts today)))))
         (overdue (seq-filter overdue-p raw))
         (current (seq-remove overdue-p raw)))
    (if (null overdue)
        (mapcar #'glasspane-ui--widget-row raw)
      (append
       (cons (eabp-widget-divider "Overdue")
             (mapcar #'glasspane-ui--widget-row overdue))
       (when current
         (cons (eabp-widget-divider "Today")
               (mapcar #'glasspane-ui--widget-row current)))))))

(defun glasspane-ui--widget-query-items (query)
  "Custom-agenda QUERY results as widget rows.
Search hits carry no agenda qualifiers — the metadata line is the file
name under a folder icon. `glasspane-org--search' is memoised, so
re-pushing is cheap."
  (mapcar
   (lambda (it)
     (let* ((todo (alist-get 'todo it))
            (done (and todo
                       (member todo (or (default-value 'org-done-keywords)
                                        '("DONE" "CANCELLED")))
                       t))
            (file (alist-get 'file it))
            (ref (alist-get 'ref it)))
       (eabp-widget-item
        (or (alist-get 'headline it) "Untitled")
        :todo todo :done done
        :meta (and file (file-name-nondirectory file))
        :icon (and file "folder")
        :on-tap (eabp-action "heading.tap" :args ref) :in-app t
        :button (and todo (if done "todo_done" "todo_open"))
        :on-button (and todo (eabp-action "heading.todo-cycle" :args ref)))))
   (seq-take (condition-case nil (glasspane-org--search query) (error nil))
             20)))

(defun glasspane-ui--push-widget ()
  "Push the `widget:agenda' surface backing the home-screen widget.
A multi-view spec: \"today\" (the day agenda) plus one view per
`glasspane-org-custom-agendas' entry. The widget's header selector
switches between them companion-side from cache, so it works offline.
View keys are interned because `json-serialize' requires symbol keys."
  (let ((views
         (cons
          (cons 'today
                `((title . ,(format-time-string "Agenda · %a %b %d"))
                  (items . ,(vconcat (glasspane-ui--widget-items)))))
          (mapcar (lambda (ca)
                    (cons (intern (car ca))
                          `((title . ,(car ca))
                            (items . ,(vconcat (glasspane-ui--widget-query-items
                                                (cdr ca)))))))
                  glasspane-org-custom-agendas))))
    (unless (equal views glasspane-ui--last-widget)
      (setq glasspane-ui--last-widget views)
      (eabp-surface-push
       "widget:agenda"
       `((views . ,views)
         (initial_view . "today"))))))

;; Both are memo-guarded, so unchanged data sends nothing.
(add-hook 'eabp-shell-after-push-hook #'glasspane-ui--sync-reminders)
(add-hook 'eabp-shell-after-push-hook #'glasspane-ui--push-widget)

(defun glasspane-ui--forget-widget-memo ()
  "Force the next widget push even when the items are unchanged.
An explicit refresh (`dashboard.refresh', e.g. the widget's refresh
button) must visibly bump the widget's \"Synced\" caption, and a
suppressed identical push would leave it frozen."
  (setq glasspane-ui--last-widget 'unset))

(add-hook 'eabp-shell-refresh-hook #'glasspane-ui--forget-widget-memo)

;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun glasspane-ui--agenda-view (snackbar)
  (eabp-shell-tab-view "agenda" (glasspane-ui--agenda-body)
                       :snackbar snackbar))

(defun glasspane-ui--tasks-view (snackbar)
  (eabp-shell-tab-view "tasks" (glasspane-ui--tasks-body)
                       :snackbar snackbar))

(defun glasspane-ui--clock-view (snackbar)
  (eabp-shell-tab-view "clock" (glasspane-ui--clock-body)
                       :snackbar snackbar))

(defun glasspane-ui--search-view (snackbar)
  (eabp-shell-nav-view "Search" (glasspane-ui--search-body)
                       :snackbar snackbar))

(defun glasspane-ui--settings-view (snackbar)
  (eabp-shell-nav-view "Settings" (glasspane-ui--settings-body)
                       :snackbar snackbar))

(defun glasspane-ui--detail-view (snackbar)
  "The heading drill-in: reader/editor body under curated heading actions."
  (let* ((ref glasspane-ui--detail-ref)
         (file (and ref (alist-get 'file ref)))
         (pos (and ref (alist-get 'pos ref)))
         (buf (and file (find-buffer-visiting file)))
         (is-clocked-in (and buf
                             (bound-and-true-p org-clock-hd-marker)
                             (marker-buffer org-clock-hd-marker)
                             (equal buf (marker-buffer org-clock-hd-marker))
                             (with-current-buffer buf
                               (= (line-number-at-pos pos)
                                  (line-number-at-pos org-clock-hd-marker))))))
    (eabp-shell-nav-view
     "Detail" (glasspane-ui--detail-body ref)
     ;; Back is pure navigation: builtin = instant, local, works offline.
     ;; heading.back stays registered for compatibility but nothing emits
     ;; it anymore.
     :actions (delq nil
                    (list
                     (when ref
                       (if is-clocked-in
                           (eabp-icon-button "timer_off" (eabp-action "org.clock.out")
                                             :content-description "Clock Out")
                         (eabp-icon-button "timer" (eabp-action "heading.clock-in" :args ref)
                                           :content-description "Clock In")))
                     (eabp-icon-button
                      (if glasspane-ui--detail-read-mode "edit" "visibility")
                      (eabp-action "detail.toggle-read")
                      :content-description
                      (if glasspane-ui--detail-read-mode "Edit" "Read"))
                     (when (and ref (glasspane-ui--org-file-p file))
                       (eabp-icon-button
                        "tune"
                        (eabp-action "files.properties.show"
                                     :args `((file . ,file)))
                        :content-description "Properties"))))
   :bottom-bar (when glasspane-ui--detail-read-mode
                 (eabp-bottom-bar
                  (list
                   (eabp-nav-item
                    "note_add" "New Note"
                    (eabp-action "heading.add-note"
                                 :args glasspane-ui--detail-ref
                                 :when-offline "drop")))))
   :floating-toolbar (when glasspane-ui--detail-read-mode
                       (vconcat
                        (list
                         (eabp-nav-item
                          "drive_file_move" "Refile"
                          (eabp-action "heading.refile"
                                       :args glasspane-ui--detail-ref
                                       :when-offline "drop"))
                         (eabp-nav-item
                          "archive" "Archive"
                          (eabp-action "heading.archive"
                                       :args glasspane-ui--detail-ref
                                       :when-offline "drop")))))
   :snackbar snackbar)))

(eabp-shell-define-view "agenda" :builder #'glasspane-ui--agenda-view
                        :tab '(:icon "event" :label "Agenda") :order 10)
(eabp-shell-define-view "tasks" :builder #'glasspane-ui--tasks-view
                        :tab '(:icon "checklist" :label "Tasks") :order 20)
(eabp-shell-define-view "clock" :builder #'glasspane-ui--clock-view
                        :tab '(:icon "schedule" :label "Clock") :order 30)
(eabp-shell-define-view "search" :builder #'glasspane-ui--search-view
                        :order 70)
(eabp-shell-define-view "settings" :builder #'glasspane-ui--settings-view
                        :order 80)
(eabp-shell-define-view "detail" :builder #'glasspane-ui--detail-view
                        :when (lambda () (and glasspane-ui--detail-ref t))
                        :overlay (lambda () (and glasspane-ui--detail-ref t))
                        :order 110)

;; Landing on any non-overlay view closes the detail drill-in.
(add-hook 'eabp-shell-view-switched-hook
          (lambda (_view) (setq glasspane-ui--detail-ref nil)))

;; Capture is this app's global affordance: the default FAB on every tab
;; view that doesn't define its own.
(setq eabp-shell-default-fab-function
      (lambda (_name)
        (eabp-fab "add" :label "Capture"
                  :on-tap (eabp-action "org.capture.show"))))

;; Search from every tab's top bar; Settings from the drawer.
(eabp-shell-add-top-action
 9 (lambda () (eabp-icon-button "filter_list" (eabp-shell-switch-view "search")
                                 :content-description "Filter")))
(eabp-shell-add-top-action
 10 (lambda () (eabp-icon-button "search" (eabp-shell-switch-view "search")
                                 :content-description "Search")))
(eabp-shell-add-drawer-item
 60 (lambda () (eabp-drawer-item "settings" "Settings"
                                 (eabp-shell-switch-view "settings"))))

;; The org extractions are memoised; an explicit refresh (pull-to-refresh,
;; the drawer item, a queue drain) must drop them.
(add-hook 'eabp-shell-refresh-hook #'glasspane-org-cache-invalidate)

;; ─── Tab Bodies ──────────────────────────────────────────────────────────────

;; ── Agenda navigation ──
;; The agenda is anchored on a date (UI state "agenda-anchor", nil = today).
;; The ‹ › buttons shift the anchor by one day/week/month according to the
;; active span, and the anchor feeds `glasspane-org--agenda-items' as START-DAY —
;; whose cache keys already include it, so each visited range memoises
;; independently.

(defun glasspane-ui--agenda-anchor ()
  "The agenda's anchor date as \"YYYY-MM-DD\"; today when unset."
  (let ((a (eabp-ui-state "agenda-anchor")))
    (if (and (stringp a) (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" a))
        a
      (format-time-string "%Y-%m-%d"))))

(defun glasspane-ui--shift-date (date n unit)
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

(defun glasspane-ui--format-date (date fmt)
  "Render DATE (\"YYYY-MM-DD\") through `format-time-string' FMT."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (format-time-string fmt (encode-time 0 0 12 d m y))))

(defun glasspane-ui--agenda-nav-row (mode anchor)
  "The ‹ [range label] [today] › navigation row for the agenda header."
  (let* ((today (format-time-string "%Y-%m-%d"))
         (at-today (pcase mode
                     ("month" (equal (substring anchor 0 7) (substring today 0 7)))
                     (_ (equal anchor today))))
         (label (pcase mode
                  ("month" (glasspane-ui--format-date anchor "%B %Y"))
                  ("week" (concat "Week of "
                                  (glasspane-ui--format-date anchor "%b %d")))
                  (_ (if at-today
                         (concat "Today · " (glasspane-ui--format-date anchor "%a, %b %d"))
                       (glasspane-ui--format-date anchor "%a, %b %d"))))))
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

(defun glasspane-ui--agenda-type-icon (type)
  "Return (ICON . COLOR) for an agenda item TYPE string (color may be nil)."
  (cond
   ((null type) nil)
   ((string-match-p "past-scheduled" type) '("history" . "#E53935"))
   ((string-match-p "deadline" type) '("flag" . nil))
   ((string-match-p "scheduled" type) '("schedule" . nil))
   (t nil)))

(defun glasspane-ui--agenda-type-label (type)
  "Short human label for an agenda item TYPE string, or nil to omit."
  (pcase type
    ("past-scheduled" "overdue")
    ("upcoming-deadline" "deadline soon")
    ("deadline" "deadline")
    ("scheduled" "scheduled")
    (_ nil)))

(defun glasspane-ui--card-date-label (ts)
  "Format org timestamp TS as a compact \"Mon D\" (or \"Mon D HH:MM\") string."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" ts))
    (let* ((month (string-to-number (match-string 2 ts)))
           (day   (string-to-number (match-string 3 ts)))
           (mon   (aref eabp--month-abbrevs (1- month)))
           (time  (glasspane-ui--ts-time ts)))
      (if time (format "%s %d %s" mon day time)
        (format "%s %d" mon day)))))

(defun glasspane-ui--card-date-row (it)
  "An inline scheduling indicator for card item IT.
Shows compact icon + text labels for SCHEDULED and/or DEADLINE when present.
Returns nil when neither is set."
  (let* ((scheduled (alist-get 'scheduled it))
         (deadline  (alist-get 'deadline it))
         (slabel (glasspane-ui--card-date-label scheduled))
         (dlabel (glasspane-ui--card-date-label deadline))
         (chips (delq nil
                      (list
                       (when slabel
                         (eabp-row
                          (eabp-icon "schedule" :size 14 :color "#9E9E9E")
                          (eabp-text slabel 'caption)))
                       (when dlabel
                         (eabp-row
                          (eabp-icon "flag" :size 14 :color "#EF5350")
                          (eabp-text dlabel 'caption)))))))
    (when chips
      (apply #'eabp-flow-row chips))))

(defun glasspane-ui--agenda-card (it)
  "A detail-rich agenda card for item IT.
Leading time (or a type icon), priority-prefixed headline (struck
through when done), a todo/type/file caption, tag chips when present,
and a quick complete button for open todos."
  (let* ((headline (or (alist-get 'headline it) "Untitled"))
         (todo (alist-get 'todo it))
         ;; Normalized "HH:MM" — the raw property is a time-grid string
         ;; like " 9:15......".
         (time (glasspane-org--item-hm (alist-get 'time it)))
         (type (alist-get 'type it))
         (file (alist-get 'file it))
         (priority (alist-get 'priority it))
         (tags (append (alist-get 'tags it) nil))
         (ref (alist-get 'ref it))
         (done (and todo (member todo (or (default-value 'org-done-keywords)
                                          '("DONE" "CANCELLED")))))
         (icon+color (glasspane-ui--agenda-type-icon type))
         (caption (string-join
                   (delq nil (list todo
                                   (and (stringp type)
                                        (glasspane-ui--agenda-type-label type))
                                   (and file (file-name-nondirectory file))))
                   "  ·  "))
         (lead (cond ((and (stringp time) (not (string-empty-p time)))
                      (eabp-text time 'label))
                     (icon+color
                      (eabp-icon (car icon+color) :size 18 :color (cdr icon+color)))))
         (headline-node
          (eabp-rich-text
           (delq nil
                 (list
                  (when priority
                    (eabp-span (format "[%s] " priority) :bold t :color "#F57C00"))
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
                        (glasspane-ui--card-date-row it)
                        (when tags
                          (apply #'eabp-flow-row
                                 (mapcar (lambda (tg)
                                           (eabp-assist-chip tg :on-tap (eabp-action "search.by-tag" :args `((tag . ,tg)))))
                                         tags))))))))
    (eabp-card
     (list (apply #'eabp-row
                  (delq nil (list lead
                                  (eabp-box (list middle) :weight 1)))))
     :on-tap (eabp-action "heading.tap" :args ref)
     :on-swipe (eabp-action "heading.todo-cycle" :args ref))))

(defun glasspane-ui--agenda-day-view (items)
  (let ((cards (mapcar #'glasspane-ui--agenda-card items)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for this day."))))

(defun glasspane-ui--agenda-week-view (items)
  (let ((elements nil)
        (current-date nil))
    (dolist (it items)
      (let ((date (alist-get 'date it)))
        (unless (equal date current-date)
          (setq current-date date)
          (push (eabp-section-header (or date "Unknown Date")) elements))
        (push (glasspane-ui--agenda-card it) elements)))
    (if elements
        (apply #'eabp-lazy-column (nreverse elements))
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for this week."))))

(defun glasspane-ui--agenda-month-view (items anchor)
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
         (apply #'eabp-lazy-column (mapcar #'glasspane-ui--agenda-card selected-items))
       (eabp-text "No events" 'caption)))))

(defun glasspane-ui--agenda-body ()
  (let* ((mode (or (eabp-ui-state "agenda-mode") "day"))
         (is-span (member mode '("day" "week" "month")))
         (anchor (glasspane-ui--agenda-anchor))
         ;; The month span always starts on the 1st so the grid and the
         ;; extraction agree on the visible range.
         (start-day (cond ((equal mode "month") (concat (substring anchor 0 7) "-01"))
                          (is-span anchor)))
         (items (cond
                 ((equal mode "day") (condition-case nil (glasspane-org--agenda-items 'day start-day) (error nil)))
                 ((equal mode "week") (condition-case nil (glasspane-org--agenda-items 'week start-day) (error nil)))
                 ((equal mode "month") (condition-case nil (glasspane-org--agenda-items 'month start-day) (error nil)))
                 (t (condition-case nil (glasspane-org--search (cdr (assoc mode glasspane-org-custom-agendas))) (error nil)))))
         (custom-chips (mapcar (lambda (ca)
                                 (let ((name (car ca)))
                                   (eabp-chip name
                                              :selected (equal mode name)
                                              :on-tap (eabp-action "agenda.set-mode" :args `((mode . ,name))))))
                               glasspane-org-custom-agendas)))
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
                    (glasspane-ui--agenda-nav-row mode anchor))
                  (eabp-spacer :height 4)
                  (cond
                   ((equal mode "day")
                    (glasspane-ui--agenda-day-view items))
                   ((equal mode "week")
                    (glasspane-ui--agenda-week-view items))
                   ((equal mode "month")
                    (glasspane-ui--agenda-month-view items anchor))
                   (t
                    (if items
                        (apply #'eabp-lazy-column (mapcar #'glasspane-ui--agenda-card items))
                      (eabp-empty-state :icon "event_busy"
                                        :title "No results"
                                        :caption "This custom agenda found no items.")))))))))

(defun glasspane-ui--tasks-body ()
  (let* ((items (condition-case nil
                    (glasspane-org--todo-items)
                  (error nil)))
         (filtered (if (equal glasspane-ui--tasks-filter "ALL") items
                     (cl-remove-if-not
                      (lambda (it)
                        (equal (alist-get 'todo it) glasspane-ui--tasks-filter))
                      items)))
         (cards (mapcar #'glasspane-ui--agenda-card filtered)))
    (eabp-column
     (apply #'eabp-flow-row
            (mapcar (lambda (kw)
                      (eabp-chip kw
                                 :selected (equal glasspane-ui--tasks-filter kw)
                                 :on-tap (eabp-action "tasks.filter"
                                                      :args `((filter . ,kw)))))
                    (cons "ALL" (or (glasspane-ui--global-todo-keywords)
                                    '("TODO" "DONE")))))
     (if cards
         (apply #'eabp-lazy-column cards)
       (eabp-empty-state :icon "task_alt"
                         :title "No tasks"
                         :caption "Nothing matches this filter.")))))

;; The old agenda-files-only "files" body is superseded by the full
;; browser in eabp-files.el (eabp-files-browser-body).

(defun glasspane-ui--clock-body ()
  (let* ((status (glasspane-org--clock-status))
         (recent (condition-case nil
                     (glasspane-org--recent-clocks 5)
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

(defun glasspane-ui--result-card (it)
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
                                             (eabp-assist-chip tg :on-tap (eabp-action "search.by-tag" :args `((tag . ,tg)))))
                                           tags)))))))
    (eabp-card (list (apply #'eabp-column children))
               :on-tap (eabp-action "heading.tap" :args ref))))

(defun glasspane-ui--search-body ()
  (let* ((q (or glasspane-ui--search-query ""))
         (results glasspane-ui--search-results)
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
         (cards (mapcar #'glasspane-ui--result-card results)))
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

(defun glasspane-ui--global-todo-keywords ()
  "Extract a flat list of all global TODO keywords from `org-todo-keywords'."
  (let ((kws nil))
    (dolist (seq (default-value 'org-todo-keywords))
      (dolist (w (cdr seq))
        (unless (string-equal w "|")
          ;; Strip fast-access keys, e.g. "TODO(t)" -> "TODO"
          (push (if (string-match "^\\([a-zA-Z0-9_-]+\\)" w)
                    (match-string 1 w)
                  w)
                kws))))
    (nreverse kws)))

(defun glasspane-ui--split-todo-sequence (seq)
  "Split `org-todo-keywords' entry SEQ into (ACTIVE . FINISHED) keyword lists.
Keywords keep their fast-access annotations (\"TODO(t!)\").  Mirrors
org's rule for sequences without an explicit \"|\": the last keyword
is the finished state."
  (let ((words (cdr seq))
        (active nil)
        (finished nil)
        (target 'active))
    (dolist (w words)
      (if (equal w "|")
          (setq target 'finished)
        (if (eq target 'active)
            (push w active)
          (push w finished))))
    (setq active (nreverse active)
          finished (nreverse finished))
    (when (and (null finished) (not (member "|" words)))
      (setq finished (last active)
            active (butlast active)))
    (cons active finished)))

(defun glasspane-ui--settings-body ()
  (let* ((available-tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist))
         (enum-list (eabp-enum-list "settings-tags" available-tags
                                    :value available-tags
                                    :multi-select t
                                    :allow-add t
                                    :on-change (eabp-action "settings.tags")))
         (linenum-value (pcase eabp-line-numbers
                          ('absolute "Absolute")
                          ('relative "Relative")
                          (_ "Off")))
         (agenda-cards
          (cl-loop for (name . query) in glasspane-org-custom-agendas
                   collect
                   (eabp-card
                    (list
                     (eabp-row
                      (eabp-box
                       (list
                        (eabp-column
                         (eabp-text name 'label)
                         (eabp-text query 'body)))
                       :weight 1)
                      (eabp-icon-button "edit"
                                        (eabp-action "settings.agenda.edit"
                                                     :args `((name . ,name))
                                                     :when-offline "drop")
                                        :content-description "Edit search")
                      (eabp-icon-button "delete"
                                        (eabp-action "settings.agenda.delete"
                                                     :args `((name . ,name))
                                                     :when-offline "drop")
                                        :content-description "Delete search"))))))
         (seq-cards
          (condition-case err
              (cl-loop for seq in (or (default-value 'org-todo-keywords) '((sequence "TODO" "DONE")))
                       for i from 0
                       collect
                       (let* ((split (glasspane-ui--split-todo-sequence seq))
                              (bare (lambda (w)
                                      (if (string-match "^\\([a-zA-Z0-9_-]+\\)" w)
                                          (match-string 1 w)
                                        w)))
                              (active (mapcar bare (car split)))
                              (finished (mapcar bare (cdr split))))
                         (eabp-card
                          (list
                           (eabp-row
                            ;; The text column must carry the flex weight
                            ;; itself: the client renders columns fillMaxWidth,
                            ;; so an unweighted one swallows the whole row and
                            ;; pushes the buttons off-screen.
                            (eabp-box
                             (list
                              (eabp-column
                               (eabp-text (format "Sequence %d" (1+ i)) 'label)
                               (eabp-text (concat (mapconcat #'identity active ", ") " | " (mapconcat #'identity finished ", ")) 'body)))
                             :weight 1)
                            (eabp-icon-button "edit"
                                              (eabp-action "settings.todo.edit"
                                                           :args `((index . ,i))
                                                           :when-offline "drop")
                                              :content-description "Edit sequence")
                            (eabp-icon-button "delete"
                                              (eabp-action "settings.todo.delete"
                                                           :args `((index . ,i))
                                                           :when-offline "drop")
                                              :content-description "Delete sequence"))))))
            (error (list (eabp-text (format "Error loading sequences: %s" (error-message-string err)) 'caption))))))
    ;; lazy_column, not column: the scaffold body has no scroll container
    ;; on the client, so a plain column taller than the screen is simply
    ;; unreachable below the fold.
    (apply #'eabp-lazy-column
           (append
            (list (eabp-section-header "Display")
                  (eabp-text "Line numbers in the buffer view and editor." 'caption)
                  (eabp-enum-list "settings-linenum" '("Off" "Absolute" "Relative")
                                  :value (list linenum-value)
                                  :on-change (eabp-action "settings.line-numbers"))
                  (eabp-divider)
                  (eabp-section-header "Saved Searches")
                  (eabp-text "Manage your custom agenda queries." 'caption))
            agenda-cards
            (list (eabp-button "New Saved Search"
                               (eabp-action "settings.agenda.edit")
                               :variant "outlined")
                  (eabp-divider)
                  (eabp-section-header "Global TODO Sequences")
                  (eabp-text "Manage your global TODO states and workflows." 'caption))
            seq-cards
            (list (eabp-button "Add Sequence"
                               (eabp-action "settings.todo.edit"
                                            :args '((index . -1))
                                            :when-offline "drop")
                               :variant "outlined")
                  (eabp-divider)
                  (eabp-section-header "Global Org Tags")
                  (eabp-text "Manage the global tag list (org-tag-alist)." 'caption)
                  enum-list)
            ;; Schema-driven sections: every allowlisted defcustom in
            ;; `eabp-settings-registry', rendered from its custom-type.
            (eabp-settings-sections)))))

(defun glasspane-ui--todo-chips (current keywords ref)
  "A row of chips for KEYWORDS with CURRENT selected; tapping an active chip removes it."
  (apply #'eabp-flow-row
         (mapcar (lambda (kw)
                   (eabp-chip kw
                              :selected (equal kw current)
                              :on-tap (eabp-action
                                       "heading.todo-set"
                                       :args (cons (cons 'state (if (equal kw current) "" kw)) ref))))
                 keywords)))

(defun glasspane-ui--ts-date (ts)
  "Return the YYYY-MM-DD date inside org timestamp string TS, or nil."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" ts))
    (match-string 1 ts)))

(defun glasspane-ui--ts-time (ts)
  "Return the HH:MM time inside org timestamp string TS, or nil."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)" ts))
    (match-string 1 ts)))

(defun glasspane-ui--ts-repeater (ts)
  "Return the repeater cookie (e.g. \"+1w\", \".+2d\") inside TS, or nil.
The one part of a timestamp the date-stamp chip can't display."
  (when (and (stringp ts)
             (string-match "\\([.+]?\\+[0-9]+[hdwmy]\\)" ts))
    (match-string 1 ts)))

(defun glasspane-ui--priority-chips (current ref)
  "A row of priority chips (A..C) with CURRENT selected; tapping an active chip removes it."
  (let* ((hi (or (bound-and-true-p org-priority-highest) ?A))
         (lo (or (bound-and-true-p org-priority-lowest) ?C))
         (levels (mapcar #'char-to-string (number-sequence hi lo))))
    (apply #'eabp-flow-row
           (mapcar (lambda (p)
                     (eabp-chip p
                                :selected (equal p current)
                                :on-tap (eabp-action
                                         "heading.priority"
                                         :args (cons (cons 'value (if (equal p current) "" p)) ref))))
                   levels))))

(defun glasspane-ui--property-row (key value ref pos)
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

(defun glasspane-org--format-clock-time (start end)
  (condition-case nil
      (let ((s-date (substring start 0 10))
            (s-time (substring start -5))
            (e-date (substring end 0 10))
            (e-time (substring end -5)))
        (if (equal s-date e-date)
            (format "%s, %s to %s" s-date s-time e-time)
          (format "%s %s to %s %s" s-date s-time e-date e-time)))
    (error (format "%s to %s" start end))))

(defun glasspane-org--parse-logbook (text)
  (let ((lines (split-string text "\n" t "[ \t]+"))
        entries current-entry)
    (dolist (line lines)
      (cond
       ((string-match "^CLOCK: \\[\\(.*?\\)\\]--\\[\\(.*?\\)\\] =>[ \t]+\\(.*\\)$" line)
        (when current-entry (push current-entry entries))
        (setq current-entry (list :type 'clock :start (match-string 1 line)
                                  :end (match-string 2 line)
                                  :duration (match-string 3 line))))
       ((string-match "^CLOCK: \\[\\(.*?\\)\\]$" line)
        (when current-entry (push current-entry entries))
        (setq current-entry (list :type 'clock :start (match-string 1 line) :active t)))
       ((string-match "^- Note taken on \\(\\[.*?\\]\\) \\\\\\\\$" line)
        (when current-entry (push current-entry entries))
        (setq current-entry (list :type 'note :timestamp (match-string 1 line) :content "")))
       ((string-match "^- State \"\\(.*?\\)\"[ \t]+from \"\\(.*?\\)\"[ \t]+\\(\\[.*?\\]\\)\\(\\(?: \\\\\\\\\\)?\\)$" line)
        (when current-entry (push current-entry entries))
        (setq current-entry (list :type 'state :to (match-string 1 line) :from (match-string 2 line)
                                  :timestamp (match-string 3 line)
                                  :has-note (not (string-empty-p (match-string 4 line)))
                                  :content "")))
       ((string-match "^- State \"\\(.*?\\)\"[ \t]+\\(\\[.*?\\]\\)\\(\\(?: \\\\\\\\\\)?\\)$" line)
        (when current-entry (push current-entry entries))
        (setq current-entry (list :type 'state :to (match-string 1 line)
                                  :timestamp (match-string 2 line)
                                  :has-note (not (string-empty-p (match-string 3 line)))
                                  :content "")))
       (t
        ;; Continuation line
        (when current-entry
          (let ((content (plist-get current-entry :content)))
            (setq current-entry (plist-put current-entry :content
                                           (if (string-empty-p content)
                                               line
                                             (concat content "\n" line)))))))))
    (when current-entry (push current-entry entries))
    (nreverse entries)))

(defun glasspane-ui--render-logbook-entry (entry)
  (let ((type (plist-get entry :type)))
    (cl-case type
      (clock
       (eabp-box
        (list
         (eabp-row
          (eabp-icon "timer" :color "primary" :padding [0 12 0 0])
          (eabp-column
           (eabp-text (if (plist-get entry :active)
                          (format "Started %s" (plist-get entry :start))
                        (glasspane-org--format-clock-time (plist-get entry :start) (plist-get entry :end)))
                      'body t nil nil nil [0 0 4 0])
           (eabp-text (plist-get entry :duration) 'caption))))
        :padding [8 16 8 16]))
      (note
       (eabp-box
        (list
         (eabp-row
          (eabp-icon "chat" :color "primary" :padding [0 12 0 0])
          (eabp-column
           (eabp-text (format "Note • %s" (plist-get entry :timestamp)) 'caption nil nil nil nil [0 0 4 0])
           (eabp-text (plist-get entry :content) 'body))))
        :padding [8 16 8 16]))
      (state
       (eabp-box
        (list
         (eabp-row
          (eabp-icon "change_history" :color "primary" :padding [0 12 0 0])
          (eabp-column
           (eabp-text (if (plist-get entry :from)
                          (format "%s → %s" (plist-get entry :from) (plist-get entry :to))
                        (format "Set to %s" (plist-get entry :to)))
                      'body t nil nil nil [0 0 4 0])
           (eabp-text (if (not (string-empty-p (plist-get entry :content)))
                          (format "%s\n%s" (plist-get entry :timestamp) (plist-get entry :content))
                        (plist-get entry :timestamp))
                      'caption))))
        :padding [8 16 8 16])))))

(defun glasspane-ui--logbook-entries (pos)
  "Return structured logbook entries for heading at POS, or nil."
  (save-excursion
    (goto-char pos)
    (let ((end (save-excursion (org-end-of-meta-data t) (point))))
      (goto-char pos)
      (when (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$" end t)
        (let ((start (match-end 0)))
          (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
            (glasspane-org--parse-logbook (buffer-substring-no-properties start (match-beginning 0)))))))))

(defun glasspane-ui--properties-section (props ref pos)
  "The Properties collapsible: KEY → VALUE rows plus an + Add button.
Always present (even with no properties yet) so + Add is reachable."
  (eabp-collapsible
   (format "detail-props/%s" pos)
   (eabp-text (if props (format "Properties (%d)" (length props)) "Properties")
              'label)
   (delq nil
         (append
          (mapcar (lambda (kv)
                    (glasspane-ui--property-row (car kv) (or (cdr kv) "") ref pos))
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

(defun glasspane-ui--detail-body (ref)
  (condition-case err
      (let* ((marker (glasspane-org--resolve-ref ref))
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
                              :tags (org-get-tags)
                              :local-tags (ignore-errors (org-get-tags pos t))
                              :scheduled (org-entry-get pos "SCHEDULED")
                              :deadline (org-entry-get pos "DEADLINE")
                              :keywords (or org-todo-keywords-1 '("TODO" "DONE")))))))
             (headline (plist-get meta :headline))
             (todo (plist-get meta :todo))
             (priority (plist-get meta :priority))
             (tags (plist-get meta :tags))
             (local-tags (plist-get meta :local-tags))
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
        (if (not glasspane-ui--detail-read-mode)
            (let ((content (with-current-buffer buf
                             (org-with-wide-buffer
                              (goto-char pos)
                              (org-mark-subtree)
                              (buffer-substring-no-properties (region-beginning) (region-end))))))
              (eabp-column
               (eabp-editor (format "detail-%s" pos) content
                            :syntax "org"
                            :toolbar "org"
                            :line-numbers (and eabp-line-numbers
                                               (symbol-name eabp-line-numbers))
                            :on-save (eabp-action "detail.save"
                                                  :args `((ref . ,ref))
                                                  :when-offline "queue"
                                                  :dedupe (format "save-detail/%s" pos)))))
          (let ((sdate (glasspane-ui--ts-date scheduled))
                (ddate (glasspane-ui--ts-date deadline))
                (entry-props (ignore-errors
                               (with-current-buffer buf
                                 (org-with-wide-buffer
                                  (goto-char pos)
                                  (org-entry-properties pos 'standard)))))
                (logbook-entries (ignore-errors
                                   (with-current-buffer buf
                                     (org-with-wide-buffer
                                      (glasspane-ui--logbook-entries pos))))))
            (apply #'eabp-lazy-column
                   (delq nil
                         (append
                          (list
                           ;; File breadcrumb
                           (eabp-text (file-name-nondirectory (or file "?")) 'caption)
                           ;; Headline
                           (eabp-text headline 'title)
                           ;; State (always visible)
                           (glasspane-ui--todo-chips todo keywords ref)
                           ;; Priority (always visible)
                           (glasspane-ui--priority-chips priority ref)
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
                                                   :time (glasspane-ui--ts-time scheduled))
                                (eabp-spacer :width 0))
                              (eabp-box
                               (list
                                (apply #'eabp-column
                                       (delq nil
                                             (list
                                              (eabp-text "Scheduled" 'label)
                                              (unless sdate
                                                (eabp-text "Not scheduled" 'caption))
                                              (when-let ((rep (glasspane-ui--ts-repeater scheduled)))
                                                (eabp-text (concat "Repeats " rep) 'caption))
                                              (eabp-flow-row
                                               (eabp-date-button "Set date"
                                                                 (eabp-action "heading.schedule" :args ref)
                                                                 :value sdate)
                                               (eabp-time-button "Set time"
                                                                 (eabp-action "heading.schedule-time" :args ref)
                                                                 :value (glasspane-ui--ts-time scheduled))
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
                                                   :time (glasspane-ui--ts-time deadline))
                                (eabp-spacer :width 0))
                              (eabp-box
                               (list
                                (apply #'eabp-column
                                       (delq nil
                                             (list
                                              (eabp-text "Deadline" 'label)
                                              (unless ddate
                                                (eabp-text "No deadline" 'caption))
                                              (when-let ((rep (glasspane-ui--ts-repeater deadline)))
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
                           (let* ((local-tags (or local-tags tags))
                                  (inherited-tags (seq-difference tags local-tags))
                                  (available (seq-uniq (append local-tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist))))
                                  (tags-content
                                   (apply #'eabp-column
                                          (delq nil
                                                (list
                                                 (eabp-enum-list (format "detail-tags/%s" pos) available
                                                                 :value local-tags :multi-select t :allow-add t
                                                                 :on-change (eabp-action "heading.tags" :args ref))
                                                 (when inherited-tags
                                                   (eabp-column
                                                    (eabp-text "Inherited" 'caption nil nil nil nil 8)
                                                    (apply #'eabp-flow-row
                                                           (mapcar (lambda (tg)
                                                                     (eabp-assist-chip tg))
                                                                   inherited-tags)))))))))
                             (eabp-collapsible
                              (format "detail-tags-fold/%s" pos)
                              (eabp-text (if tags (format "Tags (%d)" (length tags)) "Tags") 'label)
                              (list tags-content)
                              :collapsed (null tags)))
                           ;; ▸ Logbook (collapsible)
                           (when logbook-entries
                             (eabp-collapsible
                              (format "detail-logbook/%s" pos)
                              (eabp-text (format "Logbook (%d)" (length logbook-entries)) 'label)
                              (let ((notes (seq-filter (lambda (e) (eq (plist-get e :type) 'note)) logbook-entries))
                                    (states (seq-filter (lambda (e) (eq (plist-get e :type) 'state)) logbook-entries))
                                    (clocks (seq-filter (lambda (e) (eq (plist-get e :type) 'clock)) logbook-entries)))
                                (delq nil
                                      (list
                                       (when notes
                                         (eabp-collapsible
                                          (format "detail-logbook-notes/%s" pos)
                                          (eabp-text (format "Notes (%d)" (length notes)) 'label)
                                          (delq nil (cl-loop for entry in notes
                                                             for i from 0
                                                             append (list (glasspane-ui--render-logbook-entry entry)
                                                                          (when (< i (1- (length notes))) (eabp-divider)))))
                                          :collapsed nil))
                                       (when states
                                         (eabp-collapsible
                                          (format "detail-logbook-states/%s" pos)
                                          (eabp-text (format "State Changes (%d)" (length states)) 'label)
                                          (delq nil (cl-loop for entry in states
                                                             for i from 0
                                                             append (list (glasspane-ui--render-logbook-entry entry)
                                                                          (when (< i (1- (length states))) (eabp-divider)))))
                                          :collapsed t))
                                       (when clocks
                                         (eabp-collapsible
                                          (format "detail-logbook-clocks/%s" pos)
                                          (eabp-text (format "Clocks (%d)" (length clocks)) 'label)
                                          (delq nil (cl-loop for entry in clocks
                                                             for i from 0
                                                             append (list (glasspane-ui--render-logbook-entry entry)
                                                                          (when (< i (1- (length clocks))) (eabp-divider)))))
                                          :collapsed t)))))
                              :collapsed t))
                           ;; ▸ Properties (collapsible — collapsed by default)
                           (glasspane-ui--properties-section entry-props ref pos)
                           (eabp-divider))
                          ;; Reader: body (highlighted) and child headings (foldable).
                          ;; Properties are shown above, so skip them here.
                          (glasspane-org-reader-subtree file pos t)))))))
    (error
     (eabp-column
      (eabp-text "Error loading heading" 'title)
      (eabp-text (error-message-string err) 'body)))))

;; ─── Capture Dialog ──────────────────────────────────────────────────────────

(defvar glasspane-ui--shared-text nil
  "Body text shared from another app, pending the next capture submit.")
(defvar glasspane-ui--shared-subject nil
  "Subject shared from another app; seeds the capture Headline field.")

(defun glasspane-ui-show-capture-dialog ()
  (condition-case err
      (let* ((templates (glasspane-org--capture-templates))
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
                      (when glasspane-ui--shared-text
                        (list (eabp-card
                               (list (eabp-text
                                      (truncate-string-to-width
                                       glasspane-ui--shared-text 200 nil nil "…")
                                      'caption)))))
                      template-buttons
                      (list (eabp-button "Cancel"
                                         (eabp-action "org.capture.cancel")
                                         :variant "text"))))))
        (eabp-send-dialog dialog-body))
    (error
     (message "EABP capture dialog error: %s" (error-message-string err)))))

(defun glasspane-ui-show-capture-form (template-key)
  ;; Forget values from any previous capture so they can't leak into
  ;; this submit (`eabp--ui-state' is global and persistent).
  (eabp-ui-state-clear "cap-")
  ;; A shared-in subject pre-fills the Headline field; it must also land
  ;; in UI state, since state.changed only fires for edits the user makes.
  (when glasspane-ui--shared-subject
    (eabp-ui-state-put "cap-Headline" glasspane-ui--shared-subject))
  (condition-case err
      (let* ((templates (glasspane-org--capture-templates))
             (tmpl (cl-find-if
                    (lambda (t-info) (equal (alist-get 'key t-info) template-key))
                    templates))
             (prompts (append (alist-get 'prompts tmpl) nil)) ;; coerce vector to list
             (inputs (mapcar (lambda (p)
                               (eabp-text-input
                                (format "cap-%s" p) :label p
                                :value (and (equal p "Headline")
                                            glasspane-ui--shared-subject)))
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

(eabp-defaction "heading.tap"
  (lambda (args _)
    ;; ARGS is the ref alist (id/file/pos/headline) the card embedded.
    ;; This push IS the navigation, so it forces the detail view.
    (setq glasspane-ui--detail-ref args)
    (setq glasspane-ui--detail-read-mode t)
    (eabp-shell-push nil :switch-to "detail")))

(eabp-defaction "detail.toggle-read"
  (lambda (_ _)
    (setq glasspane-ui--detail-read-mode (not glasspane-ui--detail-read-mode))
    (eabp-shell-push nil :switch-to "detail")))

(eabp-defaction "detail.save"
  (lambda (args _)
    (let ((ref (alist-get 'ref args))
          (value (alist-get 'value args)))
      (when (and ref value)
        (condition-case err
            (let* ((marker (glasspane-org--resolve-ref ref))
                   (buf (marker-buffer marker))
                   (pos (marker-position marker)))
              (with-current-buffer buf
                (org-with-wide-buffer
                 (goto-char pos)
                 (org-mark-subtree)
                 (delete-region (region-beginning) (region-end))
                 (insert value)
                 (goto-char pos)
                 (setq glasspane-ui--detail-ref (glasspane-org--heading-ref))
                 (let ((glasspane-org--inhibit-save-refresh t)
                       (save-silently t))
                   (save-buffer))))
              (when (fboundp 'glasspane-org-cache-invalidate)
                (glasspane-org-cache-invalidate))
              (setq glasspane-ui--detail-read-mode t)
              (eabp-shell-notify "Saved heading"))
          (error
           (eabp-shell-notify (format "Save failed: %s" (error-message-string err))))))
      (eabp-shell-push))))

(eabp-defaction "heading.back"
  ;; Legacy: detail's back button is now a companion-local view.switch.
  ;; Kept for stale cached UIs.
  (lambda (_ _)
    (setq glasspane-ui--detail-ref nil)
    (eabp-shell-push nil :switch-to (eabp-shell-current-tab))))

(eabp-defaction "tasks.filter"
  (lambda (args _)
    (setq glasspane-ui--tasks-filter (alist-get 'filter args))
    (eabp-shell-push)))

(eabp-defaction "org.search.run"
  ;; The query arrives as the search field's submitted `value'. Run it,
  ;; cache the results, and land the user on the search view.
  (lambda (args _)
    (let ((q (or (alist-get 'value args) "")))
      (setq glasspane-ui--search-query q
            glasspane-ui--search-results
            (condition-case err
                (glasspane-org--search q)
              (error
               (message "EABP search error: %s" (error-message-string err))
               nil)))
      (eabp-shell-push nil :switch-to "search"))))

(eabp-defaction "org.capture.show"
  (lambda (_ _)
    (glasspane-ui-show-capture-dialog)))

(eabp-defaction "org.capture.select"
  (lambda (args _)
    (glasspane-ui-show-capture-form (alist-get 'key args))))

(eabp-defaction "org.capture.cancel"
  (lambda (_ _)
    (setq glasspane-ui--shared-text nil
          glasspane-ui--shared-subject nil)
    (eabp-dismiss-dialog)))

(defun glasspane-ui--on-share (args _payload)
  "Android share sheet → capture: stash the text/subject, open the picker.
Queued offline, so sharing works with Emacs dead — the capture dialog
appears on the next replay."
  (let ((text (alist-get 'text args))
        (subject (alist-get 'subject args)))
    (setq glasspane-ui--shared-text
          (and (stringp text) (not (string-empty-p (string-trim text)))
               (string-trim text))
          glasspane-ui--shared-subject
          (and (stringp subject) (not (string-empty-p (string-trim subject)))
               (string-trim subject)))
    ;; A share with only a subject still captures: use it as the text too.
    (unless glasspane-ui--shared-text
      (setq glasspane-ui--shared-text glasspane-ui--shared-subject))
    (glasspane-ui-show-capture-dialog)))

;; The companion's share sheet emits the app-agnostic `share.text'; this
;; app answers it with org capture.  The old app-specific id stays
;; registered so shares queued by a pre-rename companion still replay.
(eabp-defaction "share.text" #'glasspane-ui--on-share)
(eabp-defaction "org.capture.share" #'glasspane-ui--on-share)

(eabp-defaction "org.capture.submit"
  (lambda (args _)
    (let ((key (alist-get 'key args)))
      (condition-case err
          (let* ((templates (glasspane-org--capture-templates))
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
            (glasspane-org--do-capture key values glasspane-ui--shared-text)
            (setq glasspane-ui--shared-text nil
                  glasspane-ui--shared-subject nil)
            (glasspane-org-cache-invalidate)
            (eabp-ui-state-clear "cap-")
            (eabp-shell-notify "Captured ✓")
            (eabp-dismiss-dialog)
            (eabp-shell-push))
        (error
         (message "EABP capture submit error: %s" (error-message-string err))
         (setq glasspane-ui--shared-text nil
               glasspane-ui--shared-subject nil)
         (eabp-ui-state-clear "cap-")
         (eabp-dismiss-dialog))))))

(defun glasspane-ui--at-ref (args fn &optional save)
  "Resolve ARGS to its heading and call FN with point there.
With SAVE non-nil, save the buffer afterwards (guarded against
triggering our own after-save refresh on top of the explicit push).
Returns non-nil on success; messages and returns nil on failure."
  (condition-case err
      (let ((marker (glasspane-org--resolve-ref args)))
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (funcall fn))
          (when save
            (let ((glasspane-org--inhibit-save-refresh t)
                  (save-silently t))
              (save-buffer))))
        (glasspane-org-cache-invalidate)
        t)
    (error
     (message "EABP: heading action failed: %s" (error-message-string err))
     (eabp-shell-notify "Couldn't find that heading — refreshing")
     (eabp-shell-push)
     nil)))

(eabp-defaction "heading.todo-set"
  (lambda (args _)
    (let* ((state (alist-get 'state args))
           (clear (equal state "")))
      (when (and state
                 (glasspane-ui--at-ref args (lambda () (org-todo (if clear 'none state))) t))
        (eabp-shell-notify (if clear "State cleared" (format "State → %s" state)))
        (eabp-shell-push)))))

(eabp-defaction "heading.todo-cycle"
  (lambda (args _)
    (when (glasspane-ui--at-ref args
                                (lambda ()
                                  (org-todo)
                                  (unless (org-get-todo-state)
                                    (org-todo)))
                                t)
      (let* ((marker (glasspane-org--resolve-ref args))
             (state (with-current-buffer (marker-buffer marker)
                      (org-with-wide-buffer
                       (goto-char marker)
                       (org-get-todo-state)))))
        (eabp-shell-notify (if state (format "State → %s" state) "State cleared"))
        (eabp-shell-push)))))

(eabp-defaction "heading.schedule"
  (lambda (args _)
    ;; CLEAR removes the timestamp; otherwise WHEN (relative, e.g. "+1d") or
    ;; VALUE (concrete "YYYY-MM-DD", from the date picker) sets it.
    (let* ((clear (alist-get 'clear args))
           (date (or (alist-get 'when args) (alist-get 'value args)))
           (ok (cond
                (clear (glasspane-ui--at-ref args (lambda () (org-schedule '(4))) t))
                ((and (stringp date) (not (string-empty-p date)))
                 (glasspane-ui--at-ref args (lambda () (org-schedule nil date)) t)))))
      (when ok
        (eabp-shell-notify (if clear "Schedule cleared" (format "Scheduled %s" date)))
        (eabp-shell-push)))))

(eabp-defaction "heading.schedule-time"
  ;; Adds/updates the clock time on the existing SCHEDULED date (today if
  ;; none yet). VALUE is the "HH:MM" the time picker injected.
  (lambda (args _)
    (let ((time (alist-get 'value args)))
      (when (and (stringp time) (not (string-empty-p time))
                 (glasspane-ui--at-ref
                  args
                  (lambda ()
                    (let* ((sched (org-entry-get nil "SCHEDULED"))
                           (date (or (glasspane-ui--ts-date sched)
                                     (format-time-string "%Y-%m-%d"))))
                      (org-schedule nil (format "%s %s" date time))))
                  t))
        (eabp-shell-notify (format "Scheduled %s" time))
        (eabp-shell-push)))))

(eabp-defaction "org.footnote.show"
  ;; A tapped footnote marker in rich text: surface its inline definition
  ;; (when the reference carried one) or just its label.
  (lambda (args _)
    (let ((def (alist-get 'def args))
          (label (alist-get 'label args)))
      (eabp-shell-notify
       (if (and (stringp def) (not (string-empty-p def)))
           (format "Footnote: %s" def)
         (format "Footnote %s" (or label ""))))
      (eabp-shell-push))))

(eabp-defaction "heading.deadline"
  (lambda (args _)
    (let* ((clear (alist-get 'clear args))
           (date (or (alist-get 'when args) (alist-get 'value args)))
           (ok (cond
                (clear (glasspane-ui--at-ref args (lambda () (org-deadline '(4))) t))
                ((and (stringp date) (not (string-empty-p date)))
                 (glasspane-ui--at-ref args (lambda () (org-deadline nil date)) t)))))
      (when ok
        (eabp-shell-notify (if clear "Deadline cleared" (format "Deadline %s" date)))
        (eabp-shell-push)))))

(eabp-defaction "heading.priority"
  (lambda (args _)
    ;; Empty VALUE means None (remove); otherwise the first char is the priority.
    (let* ((val (alist-get 'value args))
           (remove (or (null val) (string-empty-p val)))
           (ok (glasspane-ui--at-ref
                args
                (lambda ()
                  (if remove (org-priority 'remove)
                    (org-priority (string-to-char val))))
                t)))
      (when ok
        (eabp-shell-notify (if remove "Priority cleared"
                                (format "Priority %s" val)))
        (eabp-shell-push)))))

(eabp-defaction "heading.refile"
  ;; Bridged picker over org-refile targets; refiles the whole subtree.
  (lambda (args _)
    (condition-case err
        (let ((marker (glasspane-org--resolve-ref args)))
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
                   (eabp-shell-notify "Refile cancelled")
                 (org-refile nil nil target)
                 (let ((glasspane-org--inhibit-save-refresh t)
                       (save-silently t))
                   (org-save-all-org-buffers))
                 (glasspane-org-cache-invalidate)
                 (setq glasspane-ui--detail-ref nil)
                 (eabp-shell-notify (format "Refiled to %s" choice))))))
          (eabp-shell-push nil :switch-to (eabp-shell-current-tab)))
      (error
       (eabp-shell-notify (format "Refile failed: %s"
                                     (error-message-string err)))
       (eabp-shell-push)))))

(eabp-defaction "heading.archive"
  ;; Bridged y/n confirm, then org-archive-subtree; saves source + archive.
  (lambda (args _)
    (let ((headline (or (alist-get 'headline args) "this heading")))
      (if (not (yes-or-no-p (format "Archive \"%s\"? " headline)))
          (eabp-shell-notify "Archive cancelled")
        (when (glasspane-ui--at-ref
               args
               (lambda ()
                 (org-archive-subtree)
                 (let ((glasspane-org--inhibit-save-refresh t)
                       (save-silently t))
                   (org-save-all-org-buffers))))
          (setq glasspane-ui--detail-ref nil)
          (eabp-shell-notify "Archived")))
      (eabp-shell-push nil :switch-to (eabp-shell-current-tab)))))

(eabp-defaction "heading.add-note"
  ;; Quick logbook note: bridged prompt, written where org-log-into-drawer
  ;; says notes belong, in org's own note format.
  (lambda (args _)
    (let ((note (string-trim (condition-case nil
                                 (read-string "Note: ")
                               (quit "")))))
      (if (string-empty-p note)
          (eabp-shell-notify "Note cancelled")
        (when (glasspane-ui--at-ref
               args
               (lambda ()
                 (let ((org-log-into-drawer t))
                   (goto-char (org-log-beginning t))
                   (insert (format "- Note taken on %s \\\\\n  %s\n"
                                   (format-time-string
                                    (org-time-stamp-format t t))
                                   (replace-regexp-in-string "\n" "\n  " note)))))
               t)
          (eabp-shell-notify "Note added")))
      (eabp-shell-push))))

(eabp-defaction "heading.prop-set"
  ;; VALUE arrives injected by the row input's on-submit; NAME rides in
  ;; args. An empty value deletes the property.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (value (string-trim (or (alist-get 'value args) "")))
           (ok (and (stringp name) (not (string-empty-p name))
                    (glasspane-ui--at-ref
                     args
                     (lambda ()
                       (if (string-empty-p value)
                           (org-delete-property name)
                         (org-set-property name value)))
                     t))))
      (when ok
        (eabp-shell-notify (if (string-empty-p value)
                                  (format "Removed %s" name)
                                (format "%s → %s" name value)))
        (eabp-shell-push)))))

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
        (eabp-shell-notify "Property names can't contain colons or spaces"))
       ((glasspane-ui--at-ref args
                             (lambda () (org-set-property (upcase name) ""))
                             t)
        (eabp-shell-notify (format "Added %s — fill in its value" (upcase name)))))
      (eabp-shell-push))))

(eabp-defaction "heading.tags"
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (tags (cond
                  ((vectorp val) (append val nil))
                  ((listp val) val)
                  ((stringp val) (split-string val "[ \t:,]+" t))
                  (t nil)))
           (ok (glasspane-ui--at-ref args (lambda () (org-set-tags tags)) t)))
      (when ok
        (eabp-shell-notify (if tags (format "Tags: %s" (string-join tags " "))
                                "Tags cleared"))
        (eabp-shell-push)))))

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
      (eabp-shell-notify (format "Line numbers: %s" (or choice "Off")))
      (eabp-shell-push))))

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
          (glasspane-ui--customize-save 'org-tag-alist org-tag-alist)))
      (eabp-shell-notify "Settings saved")
      (eabp-shell-push))))

;; The org settings exposed to the companion, through the generic
;; schema-driven machinery (the registry is the security boundary:
;; only symbols listed here can be modified from the wire).
(eabp-settings-register-section
 "Org Workflow"
 '((org-directory :label "Org directory")
   (org-log-done :label "Log task completion")
   (org-log-into-drawer :label "Log into drawer")
   (org-archive-location :label "Archive location")))
(eabp-settings-register-section
 "Org Agenda"
 '((org-agenda-span :label "Agenda span")
   (org-deadline-warning-days :label "Deadline warning days")))
(eabp-settings-register-section
 "Org Editing & Display"
 '((org-startup-folded :label "Initial folding")
   (org-startup-indented :label "Indent to outline level")
   (org-hide-emphasis-markers :label "Hide emphasis markers")
   (org-return-follows-link :label "Enter follows links")))

;; Org-derived views are memoised; per the cache contract every mutation
;; must drop the memo or the phone keeps rendering stale data.
(add-hook 'eabp-settings-after-set-hook
          (lambda (sym _value)
            (when (string-prefix-p "org-" (symbol-name sym))
              (glasspane-org-cache-invalidate))))

(defalias 'glasspane-ui--customize-save #'eabp-settings-save-variable
  "Persist a variable through Customize, surfacing failures.
Kept as an alias for the todo/tag actions that predate the generic
settings module (`eabp-settings-save-variable').")

(defun glasspane-ui--todo-keywords-apply (seqs)
  "Make SEQS the effective and persisted `org-todo-keywords'.
Live org buffers cache the keywords buffer-locally at mode init
(`org-todo-keywords-1', `org-todo-regexp', ...), so each one is
restarted, and the org memo cache is dropped so task views re-render
with the new states.  Returns non-nil when persisting succeeded."
  (customize-set-variable 'org-todo-keywords seqs)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'org-mode)
        (ignore-errors (org-mode-restart)))))
  (glasspane-org-cache-invalidate)
  (glasspane-ui--customize-save 'org-todo-keywords seqs))

(eabp-defaction "settings.todo.edit"
  (lambda (args _)
    (condition-case err
        (let* ((idx (alist-get 'index args))
               (seqs (or (default-value 'org-todo-keywords) '((sequence "TODO" "DONE"))))
               (seq (if (>= idx 0) (nth idx seqs) '(sequence "TODO" "|" "DONE"))))
          (if (null seq)
              ;; Stale index: the list changed since the card was rendered.
              (progn (eabp-shell-notify "That sequence no longer exists")
                     (eabp-shell-push))
            (let* ((type (car seq))
                   ;; Keep the raw keyword strings, fast-access keys and all
                   ;; ("TODO(t!)"), so an untouched save round-trips losslessly.
                   (split (glasspane-ui--split-todo-sequence seq))
                   (active (mapconcat #'identity (car split) ", "))
                   (finished (mapconcat #'identity (cdr split) ", ")))
              ;; Pre-filled `:value's must be seeded by hand: state.changed
              ;; only fires for edits the user makes, and these ids may still
              ;; hold text from the previously edited sequence.
              (eabp-ui-state-clear "todo-")
              (eabp-ui-state-put "todo-active" active)
              (eabp-ui-state-put "todo-finished" finished)
              (eabp-send-dialog
               (eabp-column
                (eabp-text (if (>= idx 0) "Edit Sequence" "New Sequence") 'title)
                (eabp-text "Comma-separated states; fast keys like TODO(t) are kept." 'caption)
                (eabp-text-input "todo-active" :label "Active States" :value active :single-line t)
                (eabp-text-input "todo-finished" :label "Finished States" :value finished :single-line t)
                (eabp-row
                 (eabp-spacer :weight 1)
                 (when (>= idx 0)
                   (eabp-button "Delete" (eabp-action "settings.todo.delete" :args `((index . ,idx))) :variant "text"))
                 (eabp-button "Cancel" (eabp-action "dialog.dismiss") :variant "text")
                 (eabp-spacer :width 8)
                 (eabp-button "Save" (eabp-action "settings.todo.save" :args `((index . ,idx) (type . ,(symbol-name type)))))))))))
      (error
       (eabp-shell-notify (format "Edit failed: %s" (error-message-string err)))))))

(eabp-defaction "settings.agenda.edit"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (query (if name (cdr (assoc name glasspane-org-custom-agendas)) "")))
      (eabp-ui-state-clear "agenda-")
      (eabp-ui-state-put "agenda-name" (or name ""))
      (eabp-ui-state-put "agenda-query" query)
      (eabp-send-dialog
       (eabp-column
        (eabp-text (if name "Edit Saved Search" "New Saved Search") 'title)
        (eabp-text "Enter the display name and the org-ql query string." 'caption)
        (eabp-text-input "agenda-name" :label "Name" :value (or name "") :single-line t)
        (eabp-text-input "agenda-query" :label "Query String" :value query)
        (eabp-row
         (eabp-spacer :weight 1)
         (when name
           (eabp-button "Delete" (eabp-action "settings.agenda.delete" :args `((name . ,name))) :variant "text"))
         (eabp-button "Cancel" (eabp-action "dialog.dismiss") :variant "text")
         (eabp-spacer :width 8)
         (eabp-button "Save" (eabp-action "settings.agenda.save" :args `((old-name . ,name))))))))))

(eabp-defaction "settings.agenda.delete"
  (lambda (args _)
    (let ((name (alist-get 'name args)))
      (setq glasspane-org-custom-agendas (assoc-delete-all name glasspane-org-custom-agendas))
      (glasspane-ui--customize-save 'glasspane-org-custom-agendas glasspane-org-custom-agendas)
      (eabp-dismiss-dialog)
      (eabp-shell-notify (format "Deleted saved search: %s" name))
      (eabp-shell-push))))

(eabp-defaction "settings.agenda.save"
  (lambda (args _)
    (let ((old-name (alist-get 'old-name args))
          (new-name (eabp-ui-state "agenda-name"))
          (query (eabp-ui-state "agenda-query")))
      (if (or (not (stringp new-name)) (string-empty-p new-name))
          (eabp-shell-notify "Name cannot be empty")
        (when (and old-name (not (equal old-name new-name)))
          (setq glasspane-org-custom-agendas (assoc-delete-all old-name glasspane-org-custom-agendas)))
        (setq glasspane-org-custom-agendas (assoc-delete-all new-name glasspane-org-custom-agendas))
        (setq glasspane-org-custom-agendas (append glasspane-org-custom-agendas (list (cons new-name query))))
        (glasspane-ui--customize-save 'glasspane-org-custom-agendas glasspane-org-custom-agendas)
        (eabp-dismiss-dialog)
        (eabp-shell-notify "Saved custom agenda")
        (eabp-shell-push)))))

(eabp-defaction "settings.todo.save"
  (lambda (args _)
    (let* ((idx (alist-get 'index args))
           (type (intern (alist-get 'type args)))
           (parse (lambda (id)
                    (delq nil
                          (mapcar (lambda (x)
                                    (let ((x (replace-regexp-in-string "^[ \t\n\r]+\\|[ \t\n\r]+$" "" x)))
                                      (if (equal x "") nil x)))
                                  (split-string (or (eabp-ui-state id) "") ",")))))
           (active (funcall parse "todo-active"))
           (finished (funcall parse "todo-finished"))
           (seqs (copy-sequence (or (default-value 'org-todo-keywords) '((sequence "TODO" "DONE")))))
           (new-seq (append (list type) active (when finished (cons "|" finished)))))
      (cond
       ((and (null active) (null finished))
        (eabp-shell-notify "A sequence needs at least one state"))
       ((>= idx (length seqs))
        ;; Stale index: the list changed since the dialog was built.
        (eabp-shell-notify "Sequences changed underneath; reopen the editor")
        (eabp-dismiss-dialog)
        (eabp-shell-push))
       (t
        (if (>= idx 0)
            (setcar (nthcdr idx seqs) new-seq)
          (setq seqs (append seqs (list new-seq))))
        (when (glasspane-ui--todo-keywords-apply seqs)
          (eabp-shell-notify "TODO sequence saved"))
        (eabp-dismiss-dialog)
        (eabp-shell-push))))))

(eabp-defaction "settings.todo.delete"
  (lambda (args _)
    (let* ((idx (alist-get 'index args))
           (seqs (or (default-value 'org-todo-keywords) '((sequence "TODO" "DONE")))))
      (when (and (>= idx 0) (< idx (length seqs)))
        (setq seqs (or (append (cl-subseq seqs 0 idx) (cl-subseq seqs (1+ idx)))
                       ;; Org misbehaves with no keywords at all; deleting
                       ;; the last sequence falls back to the stock one.
                       '((sequence "TODO" "|" "DONE"))))
        (when (glasspane-ui--todo-keywords-apply seqs)
          (eabp-shell-notify "TODO sequence deleted"))
        (eabp-dismiss-dialog)
        (eabp-shell-push)))))

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
          (setq glasspane-ui--search-query q)
          (eabp-ui-state-put "search-query" q)))
      (eabp-shell-push))))

(eabp-defaction "agenda.save-custom"
  (lambda (args _)
    (let* ((query (alist-get 'query args))
           (name (read-string "Agenda Name: ")))
      (when (and (stringp name) (not (string-empty-p name)))
        ;; Remove existing if overriding
        (setq glasspane-org-custom-agendas (assoc-delete-all name glasspane-org-custom-agendas))
        (add-to-list 'glasspane-org-custom-agendas (cons name query) t)
        (customize-save-variable 'glasspane-org-custom-agendas glasspane-org-custom-agendas)
        (eabp-shell-notify (format "Saved custom agenda: %s" name))
        (eabp-shell-push)))))

(eabp-defaction "agenda.set-mode"
  (lambda (args _)
    (let ((mode (alist-get 'mode args)))
      (eabp-ui-state-put "agenda-mode" mode)
      (eabp-shell-push))))

(eabp-defaction "agenda.nav"
  ;; Shift the agenda anchor by DIR (±1) in units of the active span.
  (lambda (args _)
    (let* ((dir (alist-get 'dir args))
           (dir (if (numberp dir) dir 1))
           (mode (or (eabp-ui-state "agenda-mode") "day"))
           (unit (pcase mode ("week" 'week) ("month" 'month) (_ 'day)))
           (anchor (glasspane-ui--agenda-anchor)))
      ;; Month steps walk 1st → 1st so ±1 never skips a short month.
      (when (eq unit 'month)
        (setq anchor (concat (substring anchor 0 7) "-01")))
      (eabp-ui-state-put "agenda-anchor"
                         (glasspane-ui--shift-date anchor dir unit))
      (eabp-shell-push))))

(eabp-defaction "agenda.today"
  ;; Reset the anchor (and any month-grid selection) back to today.
  (lambda (_ _)
    (eabp-ui-state-put "agenda-anchor" nil)
    (eabp-ui-state-put "agenda-selected-date" nil)
    (eabp-shell-push)))

(eabp-defaction "agenda.select-date"
  (lambda (args _)
    (let ((date (alist-get 'date args)))
      (eabp-ui-state-put "agenda-selected-date" date)
      (eabp-shell-push))))

(eabp-defaction "heading.clock-in"
  (lambda (args _)
    (when (glasspane-ui--at-ref args #'org-clock-in)
      (eabp-shell-notify "Clocked in")
      (eabp-shell-push "clock"))))

(eabp-defaction "search.by-tag"
  (lambda (args _)
    (let* ((tag (alist-get 'tag args))
           (query (format "(tags %S)" tag)))
      (eabp-ui-state-put "search-filter-tags" (vector tag))
      (eabp-ui-state-put "search-filter-todo" "Any")
      (eabp-ui-state-put "search-filter-text" "")
      (setq glasspane-ui--search-query query
            glasspane-ui--search-results
            (condition-case nil
                (glasspane-org--search query)
              (error nil)))
      (eabp-shell-push nil :switch-to "search"))))

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
              (eabp-shell-notify (format "Opened %s" link)))
          (error
           (eabp-shell-notify
            (format "Couldn't open %s: %s" link (error-message-string err)))))
        (eabp-shell-push)))))

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
                (let ((glasspane-org--inhibit-save-refresh t)
                      (save-silently t))
                  (save-buffer)))
              (glasspane-org-cache-invalidate)
              (eabp-shell-push))
          (error
           (eabp-shell-notify
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
        (let ((glasspane-org--inhibit-save-refresh t)
              (save-silently t))
          (with-current-buffer (find-file-noselect file)
            (save-buffer)))
        (glasspane-org-cache-invalidate)
        (eabp-shell-push nil :switch-to "edit")))))

(eabp-defaction "file.view"
  ;; Legacy (old cached UIs): now routes into the eabp-files editor.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file) (file-readable-p file))
        (setq eabp-files--file (expand-file-name file))
        (eabp-shell-push nil :switch-to "edit")))))

;; ─── Files integration: org files open reader-first ─────────────────────────
;; Registered on the core files module's app seams; the editor itself stays
;; org-agnostic.

(defvar glasspane-ui--files-read-mode nil
  "When non-nil, org files open in the foldable reader instead of the editor.")

(defvar glasspane-ui--files-refile-mode nil
  "When non-nil, org reader shows a flat drag-to-reorder heading list.")

(defun glasspane-ui--org-file-p (file)
  "Non-nil when FILE is an org file."
  (and file (string-match-p "\\.org\\'" file)))

(defun glasspane-ui--org-editor-body (file)
  "Reader body for org FILE while read mode is on; nil = plain editor."
  (when (and glasspane-ui--files-read-mode (glasspane-ui--org-file-p file))
    (if glasspane-ui--files-refile-mode
        (or (glasspane-org-reader-refile-list file)
            (eabp-text "No headings to show." 'caption))
      (let ((items (glasspane-org--file-heading-items file)))
        (if items
            (apply #'eabp-lazy-column
                   (mapcar #'glasspane-ui--agenda-card items))
          (eabp-empty-state :icon "description"
                            :title "Empty file"
                            :caption "No headings found."))))))

(defun glasspane-ui--org-editor-actions (file)
  "Reader/refile toggles and the properties dialog for org FILE."
  (when (glasspane-ui--org-file-p file)
    (delq nil
          (list
           (when glasspane-ui--files-read-mode
             (eabp-icon-button
              (if glasspane-ui--files-refile-mode "visibility" "swap_vert")
              (eabp-action "files.toggle-refile")
              :content-description
              (if glasspane-ui--files-refile-mode "Reader" "Refile")))
           (eabp-icon-button
            (if glasspane-ui--files-read-mode "edit" "visibility")
            (eabp-action "files.toggle-read")
            :content-description
            (if glasspane-ui--files-read-mode "Edit" "Read"))
           (eabp-icon-button
            "tune"
            (eabp-action "files.properties.show" :args `((file . ,file)))
            :content-description "Properties")))))

(add-hook 'eabp-files-editor-body-functions #'glasspane-ui--org-editor-body)
(add-hook 'eabp-files-editor-actions-functions #'glasspane-ui--org-editor-actions)

;; Org files get the org formatting toolbar above the keyboard — declared
;; in the editor spec, so the renderer stays app-agnostic.
(setq eabp-files-editor-toolbar-function
      (lambda (file) (when (glasspane-ui--org-file-p file) "org")))

;; Org files open reader-first; everything else lands in the editor.
(add-hook 'eabp-files-open-hook
          (lambda (file)
            (setq glasspane-ui--files-read-mode (glasspane-ui--org-file-p file))))

;; A phone-side save may have changed org data the views memoise.
(add-hook 'eabp-files-after-save-hook
          (lambda (_file) (glasspane-org-cache-invalidate)))

(eabp-defaction "files.toggle-read"
  (lambda (_ _)
    (setq glasspane-ui--files-read-mode (not glasspane-ui--files-read-mode))
    (eabp-shell-push nil :switch-to "edit")))

(eabp-defaction "files.toggle-refile"
  (lambda (_ _)
    (setq glasspane-ui--files-refile-mode (not glasspane-ui--files-refile-mode))
    (eabp-shell-push nil :switch-to "edit")))

(eabp-defaction "files.properties.show"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (if (not (and file (stringp file) (file-readable-p file)))
          (eabp-shell-notify (format "Cannot open properties: %s" (or file "no file")))
        (condition-case err
            (let* ((buf (or (get-file-buffer file) (find-file-noselect file)))
                   (kwds (with-current-buffer buf (org-collect-keywords '("TITLE" "CATEGORY" "FILETAGS"))))
                   (title (car (alist-get "TITLE" kwds nil nil #'equal)))
                   (category (car (alist-get "CATEGORY" kwds nil nil #'equal)))
                   (filetags-str (car (alist-get "FILETAGS" kwds nil nil #'equal)))
                   (filetags (when filetags-str (split-string filetags-str ":" t "[ \t\n\r]+")))
                   (available-tags (seq-uniq (append filetags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist)))))
              (eabp-send-dialog
               (eabp-column
                (eabp-text "File Properties" 'title)
                (eabp-text (file-name-nondirectory file) 'caption)
                (eabp-text-input "file-prop-title" :label "Title" :value title :single-line t)
                (eabp-text-input "file-prop-category" :label "Category" :value category :single-line t)
                (eabp-text "File Tags" 'caption nil nil nil nil 8)
                (eabp-enum-list "file-prop-tags" available-tags
                                :value filetags :multi-select t :allow-add t)
                (eabp-row
                 (eabp-spacer :weight 1)
                 (eabp-button "Cancel" (eabp-action "dialog.dismiss") :variant "text")
                 (eabp-spacer :width 8)
                 (eabp-button "Save" (eabp-action "files.properties.save" :args `((file . ,file))))))))
          (error
           (eabp-shell-notify (format "Properties error: %s" (error-message-string err)))))))))

(eabp-defaction "files.properties.save"
  (lambda (args _)
    (let* ((file (alist-get 'file args))
           (buf (or (get-file-buffer file) (find-file-noselect file)))
           (title (eabp-ui-state "file-prop-title"))
           (category (eabp-ui-state "file-prop-category"))
           (tags-val (eabp-ui-state "file-prop-tags"))
           (tags (cond
                  ((vectorp tags-val) (append tags-val nil))
                  ((listp tags-val) tags-val)
                  (t nil))))
      (with-current-buffer buf
        (save-excursion
          (save-restriction
            (widen)
            (let ((update-kwd (lambda (kwd val)
                                (goto-char (point-min))
                                (if (re-search-forward (format "^[ \t]*#\\+%s:[ \t]*\\(.*\\)$" kwd) nil t)
                                    (if (and val (not (string-empty-p val)))
                                        (replace-match val t t nil 1)
                                      (delete-region (line-beginning-position) (min (1+ (line-end-position)) (point-max))))
                                  (when (and val (not (string-empty-p val)))
                                    (goto-char (point-min))
                                    ;; If inserting something else than TITLE and a TITLE exists, insert after it.
                                    (when (not (equal kwd "TITLE"))
                                      (when (re-search-forward "^[ \t]*#\\+TITLE:.*$" nil t)
                                        (forward-line 1)))
                                    (insert (format "#+%s: %s\n" kwd val)))))))
              (funcall update-kwd "TITLE" title)
              (funcall update-kwd "FILETAGS" (when tags (concat ":" (string-join tags ":") ":")))
              (funcall update-kwd "CATEGORY" category))
            (let ((glasspane-org--inhibit-save-refresh t)
                  (save-silently t))
              (save-buffer)))))
      (eabp-dismiss-dialog)
      (glasspane-org-cache-invalidate)
      (eabp-shell-push))))

;; ─── Auto-refresh ────────────────────────────────────────────────────────────

(defvar glasspane-ui--save-refresh-timer nil)

(defcustom glasspane-ui-save-refresh-delay 2
  "Idle seconds after saving an agenda file before re-pushing the dashboard.
Debounces bursts of saves (e.g. `org-save-all-org-buffers') into one push."
  :type 'integer :group 'eabp)

(defun glasspane-ui--after-save-refresh ()
  "Schedule a dashboard refresh if an org agenda file was just saved.
No-op for saves EABP itself performs — anything inside an action
handler (`eabp--in-action-handler') pushes explicitly, and other
programmatic saves bind `glasspane-org--inhibit-save-refresh' — which would
otherwise refresh twice or loop."
  (when (and (eabp-connected-p)
             (not (bound-and-true-p glasspane-org--inhibit-save-refresh))
             (not (bound-and-true-p eabp--in-action-handler))
             buffer-file-name
             (derived-mode-p 'org-mode)
             (ignore-errors
               (member (expand-file-name buffer-file-name)
                       (mapcar #'expand-file-name (org-agenda-files)))))
    (glasspane-org-cache-invalidate)
    (when (timerp glasspane-ui--save-refresh-timer)
      (cancel-timer glasspane-ui--save-refresh-timer))
    (setq glasspane-ui--save-refresh-timer
          (run-with-idle-timer glasspane-ui-save-refresh-delay nil
                               #'eabp-shell-push))))

(add-hook 'after-save-hook #'glasspane-ui--after-save-refresh)

(defun glasspane-ui--refresh-if-connected (&rest _)
  "Re-push the dashboard when there's a live session.
Safe to put on any hook: a no-op while disconnected.  Invalidates the
extraction cache first — this runs on clock in/out, which mutate the
org buffer without necessarily saving it."
  (when (eabp-connected-p)
    (glasspane-org-cache-invalidate)
    (eabp-shell-push)))

;; The connect and queue-drained pushes are owned by the shell; this app
;; only contributes its cache invalidation via `eabp-shell-refresh-hook'.

;; Clock state shows on the Clock tab and the dashboard generally —
;; keep it live. Depth 90: after eabp-surfaces' notification hooks.
(add-hook 'org-clock-in-hook  #'glasspane-ui--refresh-if-connected 90)
(add-hook 'org-clock-out-hook #'glasspane-ui--refresh-if-connected 90)

(provide 'glasspane-ui)
;;; glasspane-ui.el ends here