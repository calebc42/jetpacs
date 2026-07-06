;;; glasspane-journal.el --- Daily-note landing surface -*- lexical-binding: t; -*-

;; The Logseq bootstrapping habit, org-native (PKM plan Task 5): open
;; the app → today's page, ready to type.  A `journal' tab renders one
;; datetree day at a time — capture row on top, the day's content
;; through the foldable reader, and (on today) a "Carried over" section
;; of unfinished TODOs scheduled before today with one-tap reschedule.
;;
;; Engine decision: plain `org-datetree' (builtin, standard, importable
;; — the file layout every journal tool understands).  vulpea-journal
;; gets evaluated when the vulpea spike runs on device (PKM Task 1);
;; the seam is `glasspane-journal--append' / `--day-pos', one code path
;; either way.
;;
;; The journal file defaults to journal.org in `org-directory' — no new
;; layout invented, nothing seeded until the first capture creates the
;; datetree.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-datetree)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)
(require 'eabp-settings)
(require 'glasspane-org)
(require 'glasspane-org-reader)
(require 'glasspane-ui)                ; date helpers + the glasspane defapp

(defcustom glasspane-journal-file nil
  "The journal file holding the datetree.
nil means journal.org inside `org-directory'."
  :type '(choice (const :tag "journal.org in org-directory" nil) file)
  :group 'eabp)

(defcustom glasspane-journal-landing nil
  "When non-nil the app opens on the Journal view instead of Agenda."
  :type 'boolean :group 'eabp)

(defvar glasspane-journal--date nil
  "The day being viewed (\"YYYY-MM-DD\"), or nil for today.")

(defvar glasspane-journal--capture-gen 0
  "Generation counter for the capture row's widget id.
Bumped after each append: rotating the id is the server-driven way to
clear the input field.")

(defun glasspane-journal--file ()
  "The journal file path."
  (or glasspane-journal-file
      (expand-file-name "journal.org" org-directory)))

(defun glasspane-journal--today ()
  (format-time-string "%Y-%m-%d"))

(defun glasspane-journal--current ()
  "The date the view shows."
  (or glasspane-journal--date (glasspane-journal--today)))

;; ─── The datetree seam ───────────────────────────────────────────────────────

(defun glasspane-journal--day-pos (date)
  "Position of DATE's day heading in the journal file, or nil.
Datetree day headings read \"*** 2026-07-05 Saturday\"; the full
Y-m-d makes the match unambiguous against month/year levels."
  (let ((file (glasspane-journal--file)))
    (when (file-readable-p file)
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (when (re-search-forward
                (format "^\\*+[ \t]+%s\\(?:[ \t]\\|$\\)" (regexp-quote date))
                nil t)
           (line-beginning-position)))))))

(defvar glasspane-org--inhibit-save-refresh)

(defun glasspane-journal--append (text &optional date)
  "Append TEXT as a plain list item under DATE's (default today) day.
Creates the datetree levels (and the file) on first use."
  (let ((date (or date (glasspane-journal--today)))
        (file (glasspane-journal--file)))
    (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number
                                     (split-string date "-"))))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (org-datetree-find-date-create (list m d y))
         (org-back-to-heading t)
         (org-end-of-subtree t t)
         (unless (bolp) (insert "\n"))
         (insert "- " text "\n"))
        (let ((glasspane-org--inhibit-save-refresh t)
              (save-silently t))
          (save-buffer))))
    (glasspane-org-cache-invalidate)))

(defun glasspane-journal--carried-over ()
  "Unfinished TODOs scheduled before today — the carry-over list."
  (glasspane-org--query '(and (todo) (scheduled :to -1))))

;; ─── The view ────────────────────────────────────────────────────────────────

(defun glasspane-journal--nav-row (date today-p)
  "‹ yesterday | the day (a native date picker) | tomorrow › chrome."
  (apply #'eabp-row
         (delq nil
               (list
                (eabp-icon-button
                 "chevron_left"
                 (eabp-action "journal.nav" :args '((delta . -1))
                              :when-offline "drop")
                 :content-description "Previous day")
                (eabp-box
                 (list (eabp-date-button
                        (glasspane-ui--format-date
                         date (if today-p "Today · %a, %b %e" "%a, %b %e, %Y"))
                        (eabp-action "journal.goto" :when-offline "drop")
                        :value date))
                 :weight 1 :alignment "center")
                (unless today-p
                  (eabp-chip "Today"
                             :on-tap (eabp-action "journal.today"
                                                  :when-offline "drop")))
                (eabp-icon-button
                 "chevron_right"
                 (eabp-action "journal.nav" :args '((delta . 1))
                              :when-offline "drop")
                 :content-description "Next day")))))

(defun glasspane-journal--capture-row (date)
  "The always-on-top quick-capture input for DATE."
  (eabp-text-input
   (format "journal-capture-%d" glasspane-journal--capture-gen)
   :hint "Add to this day…"
   :single-line t
   :on-submit (eabp-action "journal.capture"
                           :args `((date . ,date))
                           :when-offline "queue")))

(defun glasspane-journal--day-nodes (date)
  "DATE's datetree content through the foldable reader, or a placeholder."
  (or (when-let ((pos (glasspane-journal--day-pos date)))
        (glasspane-org-reader-subtree (glasspane-journal--file) pos t))
      (list (eabp-text "Nothing here yet — the row above starts the day."
                       'caption))))

(defun glasspane-journal--carried-card (item)
  "One carried-over TODO with one-tap reschedule.
The buttons ride the existing allowlisted `heading.schedule' — the
orgro timestamp-tap-edit item folds in here."
  (let ((ref (alist-get 'ref item)))
    (eabp-card
     (list
      (eabp-column
       (eabp-text (or (alist-get 'headline item) "") 'body)
       (eabp-text (format "%s · %s"
                          (or (alist-get 'todo item) "TODO")
                          (or (alist-get 'scheduled item) ""))
                  'caption)
       (eabp-row
        (eabp-spacer :weight 1)
        (eabp-button "Today"
                     (eabp-action "heading.schedule"
                                  :args (append ref '((when . "+0d")))
                                  :when-offline "queue")
                     :variant "text")
        (eabp-date-button "Pick"
                          (eabp-action "heading.schedule"
                                       :args ref
                                       :when-offline "queue"))))))))

(defun glasspane-journal--view (snackbar)
  "The journal screen for the current date."
  (let* ((date (glasspane-journal--current))
         (today-p (equal date (glasspane-journal--today)))
         ;; A broken query must cost the section, not the day.
         (carried (and today-p
                       (condition-case nil
                           (glasspane-journal--carried-over)
                         (error nil)))))
    (eabp-shell-tab-view
     "journal"
     (apply #'eabp-lazy-column
            (append
             (list (glasspane-journal--nav-row date today-p)
                   (glasspane-journal--capture-row date)
                   (eabp-spacer :height 4))
             (glasspane-journal--day-nodes date)
             (when carried
               (append
                (list (eabp-divider)
                      (eabp-section-header
                       (format "Carried over (%d)" (length carried))))
                (mapcar #'glasspane-journal--carried-card carried)))
             ;; The clock rides the journal (its own tab felt barren and
             ;; crowded the bottom bar) — today's time is journal matter.
             (when (and today-p (fboundp 'glasspane-ui--clock-body))
               (list (eabp-divider)
                     (eabp-section-header "Clock")
                     (glasspane-ui--clock-body)))))
     :snackbar snackbar)))

(eabp-shell-define-view "journal"
                        :builder #'glasspane-journal--view
                        :tab '(:icon "today" :label "Journal")
                        :order 15)

;; ─── Landing & state resets ──────────────────────────────────────────────────

(defun glasspane-journal--apply-landing (_welcome)
  "Land on the journal when configured and no tab was chosen this session.
Depth 5: before the shell's on-connect push (10) builds the surface."
  (when (and glasspane-journal-landing (null eabp-shell--current-tab))
    (setq eabp-shell--current-tab "journal")))

(add-hook 'eabp-connected-hook #'glasspane-journal--apply-landing 5)

(defun glasspane-journal--on-view-switched (view)
  "Leaving the journal resets it to today — returning starts fresh."
  (unless (equal view "journal")
    (setq glasspane-journal--date nil)))

(add-hook 'eabp-shell-view-switched-hook #'glasspane-journal--on-view-switched)

(eabp-settings-register-section
 "Journal"
 '((glasspane-journal-landing :label "Open on the journal")))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "journal.nav"
  (lambda (args _)
    (let ((delta (alist-get 'delta args)))
      (when (integerp delta)
        (setq glasspane-journal--date
              (glasspane-ui--shift-date (glasspane-journal--current)
                                        delta 'day))
        (eabp-shell-push)))))

(eabp-defaction "journal.goto"
  (lambda (args _)
    (let ((date (alist-get 'value args)))
      (when (and (stringp date)
                 (string-match-p
                  "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" date))
        (setq glasspane-journal--date date)
        (eabp-shell-push)))))

(eabp-defaction "journal.today"
  (lambda (_args _)
    (setq glasspane-journal--date nil)
    (eabp-shell-push)))

(eabp-defaction "journal.capture"
  (lambda (args _)
    (let ((text (string-trim (or (alist-get 'value args) "")))
          (date (alist-get 'date args)))
      (unless (string-empty-p text)
        (glasspane-journal--append
         text (and (stringp date) (not (string-empty-p date)) date))
        ;; Rotate the input id: the re-render clears the field.
        (cl-incf glasspane-journal--capture-gen)
        (eabp-shell-notify "Added to journal")
        (eabp-shell-push)))))

(provide 'glasspane-journal)
;;; glasspane-journal.el ends here
