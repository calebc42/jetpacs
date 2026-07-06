;;; glasspane-srs.el --- Spaced repetition over org-srs -*- lexical-binding: t; -*-

;; The Tier 1 skin for org-srs (PKM plan: SRS = org-srs, decided
;; 2026-07-05): a Review drawer destination that drives a full review
;; session from the phone — question, one-tap reveal, the four FSRS
;; ratings with predicted intervals — plus "Make flashcard" on the
;; heading detail view.
;;
;; The load-bearing trick: org-srs hides answers with OVERLAYS (ellipsis
;; `display' for card backs, hint overlays for clozes) and org-fold, in
;; a buffer narrowed to the item.  The Tier 0 generic renderer reads
;; `invisible' and `display' through `get-char-property' — overlays
;; included — so `eabp-buffer-render' on the review buffer reproduces
;; the question/answer state faithfully for every item type, current and
;; future.  (The rich org reader reads text, not overlays; it would leak
;; answers.)
;;
;; The review flow mirrors org-srs's own touchscreen UI
;; (org-srs-ui-mouse.el): `org-srs-item-confirm-pending-p' decides
;; question vs answer, the pending confirm command is the reveal, and
;; `org-srs-review-rate' advances.  Wire-driven review REQUIRES the
;; command-style confirm (`org-srs-item-confirm-command', the upstream
;; Android recommendation) — the default `read-key' would block the
;; bridge — so the session-driving handlers bind it; rating advances
;; synchronously, so the binding covers the next item's display too.
;;
;; Everything degrades to absent when org-srs isn't installed: no
;; drawer entry, no detail section, no settings.  The starter init
;; installs it from MELPA.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)
(require 'eabp-shell)
(require 'eabp-settings)
(require 'glasspane-org)

(declare-function org-srs-review-start "org-srs-review")
(declare-function org-srs-review-quit "org-srs-review")
(declare-function org-srs-review-next "org-srs-review")
(declare-function org-srs-review-postpone "org-srs-review")
(declare-function org-srs-review-suspend "org-srs-review")
(declare-function org-srs-review-pending-items "org-srs-review")
(declare-function org-srs-reviewing-p "org-srs-review")
(declare-function org-srs-review-rate "org-srs-review-rate")
(declare-function org-srs-review-undo "org-srs-review-undo")
(declare-function org-srs-item-confirm-pending-p "org-srs-item")
(declare-function org-srs-item-confirm-command "org-srs-item")
(declare-function org-srs-item-call-with-current "org-srs-item")
(declare-function org-srs-item-create "org-srs-item")
(declare-function org-srs-table-goto-column "org-srs-table")
(declare-function org-srs-stats-intervals "org-srs-stats-interval")
(declare-function org-srs-time-seconds-desc "org-srs-time")

;; org-srs dynamic variables the handlers reference or bind; the bare
;; defvars mark them special so byte-compilation keeps the bindings
;; dynamic (org-srs itself may not be loaded at compile time).
(defvar org-srs-item-confirm)
(defvar org-srs-review-item)
(defvar org-srs-review-undo-history)

(defcustom glasspane-srs-source nil
  "The review scope: a file or directory org-srs reviews over.
nil means `org-directory' — review everything, the phone default."
  :type '(choice (const :tag "org-directory" nil) directory file)
  :group 'eabp)

(defvar glasspane-srs--available 'unknown
  "Cached org-srs availability; `unknown' re-probes on next ask.")

(defun glasspane-srs-available-p ()
  "Non-nil when org-srs is installed and loadable.
A failed probe is cached (a missing package must not re-scan the
load-path per render); pull-to-refresh re-probes, so installing
org-srs mid-session only needs a refresh."
  (when (eq glasspane-srs--available 'unknown)
    (setq glasspane-srs--available (and (require 'org-srs nil t) t)))
  glasspane-srs--available)

(add-hook 'eabp-shell-refresh-hook
          (lambda () (setq glasspane-srs--available 'unknown)))

(defun glasspane-srs--source ()
  (or glasspane-srs-source org-directory))

;; ─── Session state ───────────────────────────────────────────────────────────

(defvar glasspane-srs--buffer nil
  "The buffer of the item under review, or nil outside a session.
org-srs keeps session state buffer-local; this is the phone's handle
to it, captured on each item display (the next item may live in a
different file).")

(defun glasspane-srs--reviewing-p ()
  "Non-nil while a phone-visible review session is active."
  (and (buffer-live-p glasspane-srs--buffer)
       (fboundp 'org-srs-reviewing-p)
       (with-current-buffer glasspane-srs--buffer
         (org-srs-reviewing-p))))

(defun glasspane-srs--answer-pending-p ()
  "Non-nil when the current item awaits its reveal (question state)."
  (and (glasspane-srs--reviewing-p)
       (with-current-buffer glasspane-srs--buffer
         (and (org-srs-item-confirm-pending-p) t))))

(defun glasspane-srs--on-item-display (&rest _)
  "Track the item buffer: each display may land in a new file."
  (setq glasspane-srs--buffer (current-buffer)))

(defun glasspane-srs--on-finish ()
  "Session over: drop the handle and re-render."
  (setq glasspane-srs--buffer nil)
  (eabp-shell--schedule-repush))

;; The same three hooks org-srs's own touch UI redraws on — they also
;; mirror desktop-driven reviews to the phone.  Registering on org-srs
;; hook symbols before org-srs loads is fine: `add-hook' creates the
;; variable and the later defvar keeps it.
(add-hook 'org-srs-item-before-review-hook #'glasspane-srs--on-item-display)
(add-hook 'org-srs-item-before-confirm-hook
          (lambda (&rest _) (eabp-shell--schedule-repush)))
(add-hook 'org-srs-item-after-confirm-hook
          (lambda (&rest _) (eabp-shell--schedule-repush)))
(add-hook 'org-srs-review-finish-hook #'glasspane-srs--on-finish)

(defmacro glasspane-srs--in-review (&rest body)
  "Run BODY driving the current review session.
Puts the review buffer in the selected window first (org-srs's
navigation asserts the two agree — it is a window-centric UI), binds
the command-style confirm, and turns signals into snackbars: a tap
that silently does nothing is a bug class, not an outcome."
  (declare (indent 0))
  `(if (not (glasspane-srs--reviewing-p))
       (eabp-shell-notify "No review in progress")
     (condition-case err
         (let ((org-srs-item-confirm #'org-srs-item-confirm-command))
           (switch-to-buffer glasspane-srs--buffer nil t)
           ,@body)
       (error (eabp-shell-notify
               (format "Review: %s" (error-message-string err)))))))

;; ─── Due counts ──────────────────────────────────────────────────────────────

(defun glasspane-srs--due-count ()
  "Items a session over the configured source would show now, or nil.
Memoised through the org cache seam — every mutating srs.* action
invalidates, so the count follows ratings without a per-render scan."
  (when (glasspane-srs-available-p)
    (condition-case nil
        (glasspane-org--with-cache
            (glasspane-org--cache-key 'srs-due (glasspane-srs--source))
          (length (org-srs-review-pending-items (glasspane-srs--source))))
      (error nil))))

;; ─── Rating chrome ───────────────────────────────────────────────────────────

(defconst glasspane-srs--ratings
  '(("again" :again "Again" "outlined")
    ("hard" :hard "Hard" "tonal")
    ("good" :good "Good" "filled")
    ("easy" :easy "Easy" "tonal"))
  "WIRE-NAME KEYWORD LABEL VARIANT rows for the rating buttons.")

(defun glasspane-srs--intervals ()
  "Predicted next intervals as a (:again SECS …) plist, or nil.
The org-srs-ui-mouse recipe: with point on the item's log row, the
`rating' column present means the simulator can run."
  (when (glasspane-srs--reviewing-p)
    (with-current-buffer glasspane-srs--buffer
      (when-let ((item (and (local-variable-p 'org-srs-review-item)
                            org-srs-review-item)))
        (ignore-errors
          (apply #'org-srs-item-call-with-current
                 (lambda ()
                   (when (org-srs-table-goto-column 'rating)
                     (org-srs-stats-intervals)))
                 item))))))

(defun glasspane-srs--format-interval (seconds)
  "SECONDS as a short \"3d 2h\" description (two components max)."
  (cl-loop for (amount unit . rest) on (org-srs-time-seconds-desc seconds)
           by #'cddr
           for i from 1
           concat (format "%d%.1s" amount
                          (string-trim-left (symbol-name unit) ":"))
           while (< i 2)
           when rest concat " "))

(defun glasspane-srs--rating-controls ()
  "The four rating buttons with predicted-interval captions."
  (let ((intervals (glasspane-srs--intervals)))
    (delq nil
          (list
           (when intervals
             (apply #'eabp-row
                    (mapcar (lambda (row)
                              (eabp-box
                               (list (eabp-text
                                      (if-let ((secs (plist-get intervals
                                                                (cadr row))))
                                          (glasspane-srs--format-interval secs)
                                        "")
                                      'caption))
                               :weight 1 :alignment "center"))
                            glasspane-srs--ratings)))
           (apply #'eabp-row
                  (mapcar (lambda (row)
                            (cl-destructuring-bind (name _kw label variant) row
                              (eabp-button label
                                           (eabp-action
                                            "srs.rate"
                                            :args `((rating . ,name))
                                            :when-offline "drop")
                                           :variant variant :weight 1)))
                          glasspane-srs--ratings))))))

;; ─── The view ────────────────────────────────────────────────────────────────

(defun glasspane-srs--card-nodes ()
  "The current item, rendered faithfully — overlays carry the hiding."
  (with-current-buffer glasspane-srs--buffer
    (save-excursion (eabp-buffer-render))))

(defun glasspane-srs--session-body ()
  "The active-session screen: the item plus reveal or rating controls."
  (apply #'eabp-lazy-column
         (append
          (glasspane-srs--card-nodes)
          (list (eabp-spacer :height 8) (eabp-divider))
          (if (glasspane-srs--answer-pending-p)
              (list (eabp-button "Show answer"
                                 (eabp-action "srs.answer.show"
                                              :when-offline "drop")
                                 :variant "filled" :icon "visibility"))
            (glasspane-srs--rating-controls)))))

(defun glasspane-srs--idle-body ()
  "The between-sessions screen: due summary and the start button."
  (let ((due (glasspane-srs--due-count)))
    (cond
     ((null due)
      (eabp-column
       (eabp-text "Couldn't count due items — check *Messages*." 'caption)
       (eabp-button "Start review"
                    (eabp-action "srs.review.start" :when-offline "drop")
                    :variant "filled" :icon "play_arrow")))
     ((zerop due)
      (eabp-empty-state :icon "school" :title "All caught up"
                        :caption "Nothing due right now."))
     (t
      (eabp-column
       (eabp-text (format "%d item%s due" due (if (= due 1) "" "s")) 'title)
       (eabp-spacer :height 8)
       (eabp-button "Start review"
                    (eabp-action "srs.review.start" :when-offline "drop")
                    :variant "filled" :icon "play_arrow"))))))

(defun glasspane-srs--install-body ()
  (eabp-empty-state
   :icon "school" :title "org-srs not installed"
   :caption (concat "Install the org-srs package (MELPA) in the on-device "
                    "Emacs — the starter init does it on first launch — "
                    "then pull to refresh.")))

(defun glasspane-srs--top-actions ()
  "Session top-bar actions: undo (when possible), postpone, suspend, quit."
  (delq nil
        (list
         (when (and (boundp 'org-srs-review-undo-history)
                    org-srs-review-undo-history)
           (eabp-icon-button "undo"
                             (eabp-action "srs.undo" :when-offline "drop")
                             :content-description "Undo last rating"))
         (eabp-icon-button "update"
                           (eabp-action "srs.postpone" :when-offline "drop")
                           :content-description "Postpone this item")
         (eabp-icon-button "block"
                           (eabp-action "srs.suspend" :when-offline "drop")
                           :content-description "Suspend this item")
         (eabp-icon-button "close"
                           (eabp-action "srs.quit" :when-offline "drop")
                           :content-description "End review"))))

(defun glasspane-srs--view (snackbar)
  "The Review screen for the current session state."
  (let ((reviewing (glasspane-srs--reviewing-p)))
    (eabp-shell-nav-view
     "Review"
     (cond
      ((not (glasspane-srs-available-p)) (glasspane-srs--install-body))
      (reviewing (glasspane-srs--session-body))
      (t (glasspane-srs--idle-body)))
     :actions (when reviewing (glasspane-srs--top-actions))
     :snackbar snackbar)))

(eabp-shell-define-view "srs" :builder #'glasspane-srs--view :order 78)

;; Everyday nav (the drawer contract); no entry while org-srs is absent.
(eabp-shell-add-drawer-item
 45 (lambda ()
      (when (glasspane-srs-available-p)
        (eabp-drawer-item "school" "Review" (eabp-shell-switch-view "srs")))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "srs.review.start"
  (lambda (_args _)
    (cond
     ((not (glasspane-srs-available-p))
      (eabp-shell-notify "org-srs is not installed"))
     ((glasspane-srs--reviewing-p))     ; already running: just re-render
     (t
      (condition-case err
          ;; org-srs navigates via the selected window; keep the two in
          ;; agreement from the very first item.
          (with-current-buffer (window-buffer)
            (let ((org-srs-item-confirm #'org-srs-item-confirm-command))
              (org-srs-review-start (glasspane-srs--source))))
        (error (eabp-shell-notify
                (format "Review: %s" (error-message-string err)))))))
    (eabp-shell-push nil :switch-to "srs")))

(eabp-defaction "srs.answer.show"
  (lambda (_args _)
    (glasspane-srs--in-review
      (when-let ((cmd (org-srs-item-confirm-pending-p)))
        (funcall cmd)))
    (eabp-shell-push)))

(eabp-defaction "srs.rate"
  (lambda (args _)
    (let* ((name (alist-get 'rating args))
           (rating (cadr (assoc name glasspane-srs--ratings))))
      (when rating
        (glasspane-srs--in-review
          (when (glasspane-srs--answer-pending-p)
            (user-error "Show the answer before rating"))
          (org-srs-review-rate rating))
        ;; Review logs live in the org files the views memoise.
        (glasspane-org-cache-invalidate)
        (eabp-shell-push)))))

(eabp-defaction "srs.quit"
  (lambda (_args _)
    (glasspane-srs--in-review
      (org-srs-review-quit))
    (setq glasspane-srs--buffer nil)
    (eabp-shell-push)))

(eabp-defaction "srs.postpone"
  (lambda (_args _)
    (glasspane-srs--in-review
      (org-srs-review-postpone)
      (org-srs-review-next))
    (glasspane-org-cache-invalidate)
    (eabp-shell-push)))

(eabp-defaction "srs.suspend"
  (lambda (_args _)
    (glasspane-srs--in-review
      (org-srs-review-suspend))
    (glasspane-org-cache-invalidate)
    (eabp-shell-push)))

(eabp-defaction "srs.undo"
  (lambda (_args _)
    (glasspane-srs--in-review
      (org-srs-review-undo))
    (glasspane-org-cache-invalidate)
    (eabp-shell-push)))

;; ─── Authoring: Make flashcard on the heading detail view ───────────────────

(eabp-defaction "srs.item.create"
  ;; The type picker and any follow-up prompts arrive as phone dialogs
  ;; through the minibuffer bridge — write it as if at the keyboard.
  (lambda (args _)
    (if (not (glasspane-srs-available-p))
        (eabp-shell-notify "org-srs is not installed")
      (condition-case err
          (let ((marker (glasspane-org--resolve-ref args)))
            (with-current-buffer (marker-buffer marker)
              (org-with-wide-buffer
               (goto-char marker)
               (org-srs-item-create))
              (let ((save-silently t)) (save-buffer)))
            (glasspane-org-cache-invalidate)
            (eabp-shell-notify "Review item created"))
        (quit (eabp-shell-notify "Cancelled"))
        (error (eabp-shell-notify
                (format "Flashcard: %s" (error-message-string err))))))
    (eabp-shell-push)))

(defun glasspane-srs-detail-nodes (ref)
  "The detail-view section for REF: make this heading reviewable."
  (when (glasspane-srs-available-p)
    (list (eabp-divider)
          (eabp-row
           (eabp-box (list (eabp-text "Spaced repetition" 'caption))
                     :weight 1)
           (eabp-button "Make flashcard"
                        (eabp-action "srs.item.create"
                                     :args ref
                                     :when-offline "drop")
                        :variant "text" :icon "school")))))

(add-hook 'glasspane-ui-detail-nodes-functions #'glasspane-srs-detail-nodes)

;; ─── Settings ────────────────────────────────────────────────────────────────

(with-eval-after-load 'org-srs
  (eabp-settings-register-section
   "Review"
   '((org-srs-review-new-items-per-day :label "New cards per day")
     (org-srs-review-max-reviews-per-day :label "Max reviews per day"))))

(provide 'glasspane-srs)
;;; glasspane-srs.el ends here
