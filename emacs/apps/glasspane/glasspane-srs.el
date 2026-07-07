;;; glasspane-srs.el --- Spaced repetition over org-srs -*- lexical-binding: t; -*-

;; The Tier 1 skin for org-srs (PKM plan: SRS = org-srs, decided
;; 2026-07-05): a Review drawer destination plus "Make flashcard" on the
;; heading detail view.
;;
;; Design — org-srs as an ENGINE, not a mirrored session.  An earlier
;; version puppeteered org-srs's live, window-centric review session
;; (`org-srs-review-start' → `switch-to-buffer' + window asserts) and
;; rendered the raw review buffer; on the phone that produced broken
;; cards (per-line ellipsis dots on multi-line answers, raw org stars,
;; cloze cards that looped without revealing) and stray message toasts.
;;
;; Instead we drive org-srs entirely in the background and render our own
;; clean cards:
;;   - The queue is `org-srs-review-pending-items' — the same set org-srs
;;     itself pulls each step; we show its first element and re-fetch
;;     after every rating (so `Again' cards reappear and the queue empties
;;     naturally).  No session, no continue-hook loop.
;;   - Rating is `org-srs-review-rate' with EXPLICIT item args, which
;;     routes through `org-srs-item-with-current' (a `with-current-buffer'
;;     + marker) — no window, no selected-buffer coupling.
;;   - The question/answer are extracted per item type (card regions,
;;     cloze spans) and rendered with our widgets: reveal is a plain UI
;;     flag, so nothing depends on org-srs's confirm state machine.
;;   - Undo keeps its own small stack of log-drawer snapshots (org-srs's
;;     own undo history is only set up by the session we don't run).
;;
;; Native-Emacs review coherence is a non-goal (this skin is for the
;; phone).  Everything degrades to absent when org-srs isn't installed.

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

(declare-function org-srs-review-pending-items "org-srs-review")
(declare-function org-srs-review-postpone "org-srs-review")
(declare-function org-srs-review-rate "org-srs-review-rate")
(declare-function org-srs-item-create "org-srs-item")
(declare-function org-srs-item-marker "org-srs-item")
(declare-function org-srs-item-call-with-current "org-srs-item")
(declare-function org-srs-item-cloze-collect "org-srs-item-cloze")
(declare-function org-srs-log-beginning-of-drawer "org-srs-log")
(declare-function org-srs-log-end-of-drawer "org-srs-log")
(declare-function org-srs-log-hide-drawer "org-srs-log")
(declare-function org-srs-table-goto-column "org-srs-table")
(declare-function org-srs-stats-intervals "org-srs-stats-interval")
(declare-function org-srs-time-seconds-desc "org-srs-time")

;; `org-srs-review-rate' reads this dynamic var to decide whether it is
;; mid-session; outside a session it is unbound, so we bind it to nil to
;; take the explicit-item-args path.  The bare defvar marks it special
;; so the `let' below binds dynamically even when byte-compiled without
;; org-srs loaded.
(defvar org-srs-review-item)

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

(defvar glasspane-srs--active nil
  "Non-nil while a review is in progress on the phone.")

(defvar glasspane-srs--current nil
  "The item-args `(ITEM ID BUFFER)' under review, or nil.
Nil while a session is active means the queue drained (the done
screen); ITEM is `(card SIDE)' or `(cloze CLOZE-ID)'.")

(defvar glasspane-srs--revealed nil
  "Non-nil once the answer for `glasspane-srs--current' is shown.
A pure UI flag — the reveal never touches org-srs.")

(defvar glasspane-srs--undo nil
  "Stack of (ITEM-ARGS . LOG-STRING) snapshots for `srs.undo'.
Each entry is the item's SRSITEMS log-drawer text captured just
before that item was rated.")

(defmacro glasspane-srs--engine (&rest body)
  "Run BODY (org-srs engine calls) quietly, returning its value or nil.
Messages are suppressed so org-srs's and the user's `message's don't
surface as Glasspane toasts; a signal becomes a snackbar, never a
crash — a review tap that silently dies is a bug class."
  (declare (indent 0) (debug t))
  `(condition-case err
       (let ((inhibit-message t) (message-log-max nil))
         ,@body)
     (error
      (eabp-shell-notify (format "Review: %s" (error-message-string err)))
      nil)))

(defmacro glasspane-srs--quietly (&rest body)
  "Run BODY with messages suppressed, returning its value or nil on error.
The render-time counterpart of `glasspane-srs--engine': a failure while
building a view must NOT raise a snackbar (only actions do that)."
  (declare (indent 0) (debug t))
  `(let ((inhibit-message t) (message-log-max nil))
     (ignore-errors ,@body)))

(defun glasspane-srs--next-item ()
  "The first pending item over the source, or nil when none remain."
  (car (org-srs-review-pending-items (glasspane-srs--source))))

(defun glasspane-srs--advance ()
  "Load the next pending item and clear the reveal flag.
`--current' nil afterward means the queue drained."
  (setq glasspane-srs--current (glasspane-srs--quietly (glasspane-srs--next-item))
        glasspane-srs--revealed nil))

;; ─── Due count (idle screen) ─────────────────────────────────────────────────

(defun glasspane-srs--due-count ()
  "Items a session over the configured source would show now, or nil.
Memoised through the org cache seam — every mutating srs.* action
invalidates, so the count follows ratings without a per-render scan."
  (when (glasspane-srs-available-p)
    (glasspane-srs--quietly
      (glasspane-org--with-cache
          (glasspane-org--cache-key 'srs-due (glasspane-srs--source))
        (length (org-srs-review-pending-items (glasspane-srs--source)))))))

;; ─── Content extraction & clean rendering ────────────────────────────────────

(defconst glasspane-srs--noise-drawers '("PROPERTIES" "SRSITEMS" "LOGBOOK")
  "Drawers hidden from the fallback render: org metadata plus org-srs's
review log (`org-srs-log-drawer-name' is SRSITEMS).")

;; Card layouts are computed with plain org (not org-srs's region
;; helpers): under a subtree narrowing those helpers return *entry*-scoped
;; positions that collapse to empty answers.  This is predictable and
;; testable without org-srs installed.

(defun glasspane-srs--child-body (base title child-re)
  "Body region (BEG . END) of the direct child named TITLE, or nil.
BASE is the entry's outline level (point-min is its heading);
CHILD-RE matches level BASE+1 headings.  The region starts after the
child's own heading and meta-data, so it carries no `*' stars."
  (save-excursion
    (goto-char (point-min))
    (let (region)
      (while (and (not region) (re-search-forward child-re nil t))
        (goto-char (match-beginning 0))
        (when (and (eql (org-current-level) (1+ base))
                   (string-equal-ignore-case
                    (or (org-get-heading t t t t) "") title))
          (setq region
                (cons (save-excursion (org-end-of-meta-data t) (point))
                      (save-excursion (org-end-of-subtree t t) (point)))))
        (goto-char (match-end 0)))
      region)))

(defun glasspane-srs--card-parts (side)
  "Return (QUESTION . ANSWER) parts for the narrowed heading entry.
Each part is (title . STRING) or (region BEG . END).  SIDE is the
reviewed (hidden answer) side, `front' or `back'.  Handles the common
heading-level layouts: heading-as-front + body-as-back, and explicit
`Front'/`Back' children."
  (goto-char (point-min))
  (let* ((base (or (org-current-level) 1))
         (title (or (org-get-heading t t t t) ""))
         (child-re (format "^\\*\\{%d\\}[ \t]" (1+ base)))
         (meta-end (save-excursion (goto-char (point-min))
                                   (org-end-of-meta-data t) (point)))
         (first-child (save-excursion
                        (goto-char meta-end)
                        (if (re-search-forward child-re nil t)
                            (line-beginning-position)
                          (point-max))))
         (front (glasspane-srs--child-body base "Front" child-re))
         (back (glasspane-srs--child-body base "Back" child-re))
         (front-face
          (cond (front (cons 'region front))
                ((and back (< meta-end first-child))
                 (list 'region meta-end first-child))
                (t (cons 'title title))))
         (back-face
          (cond (back (cons 'region back))
                (t (list 'region meta-end (point-max))))))
    (if (eq side 'front)
        (cons back-face front-face)
      (cons front-face back-face))))

(defun glasspane-srs--part-nodes (part)
  "Render a card PART: (title . STRING) or (region BEG END)/(region BEG . END)."
  (pcase part
    (`(title . ,s)
     (and (stringp s) (not (string-empty-p s)) (list (eabp-text s 'title))))
    (`(region ,beg . ,rest)
     (let ((end (if (consp rest) (car rest) rest))
           (eabp-line-numbers nil))
       (when (and (integerp beg) (integerp end) (< beg end))
         (eabp-buffer-render-region (current-buffer) beg end))))
    (_ nil)))

(defun glasspane-srs--card-content (item revealed)
  "Question and (when REVEALED) answer nodes for a `card' ITEM.
ITEM is `(card SIDE)'; SIDE (default `back') is the hidden answer."
  (condition-case nil
      (let ((parts (glasspane-srs--card-parts (or (cadr item) 'back))))
        (append
         (or (glasspane-srs--part-nodes (car parts))
             (list (eabp-text "(no question)" 'caption)))
         (when revealed
           (cons (eabp-divider)
                 (or (glasspane-srs--part-nodes (cdr parts))
                     (list (eabp-text "(no answer)" 'caption)))))))
    (error (list (eabp-text "Couldn't lay out this card." 'caption)))))

(defun glasspane-srs--cloze-content (item revealed)
  "Nodes for a `cloze' ITEM: the sentence with the reviewed blank.
ITEM is `(cloze CLOZE-ID)'.  The reviewed cloze shows as `[hint]' /
`[…]' until REVEALED; other clozes show their text as context.  Bounds
come from plain org; only `org-srs-item-cloze-collect' is org-srs."
  (condition-case nil
      (let* ((target (cadr item))
             (beg (save-excursion (goto-char (point-min))
                                  (org-end-of-meta-data t) (point)))
             (end (point-max))
             (clozes (sort (copy-sequence (org-srs-item-cloze-collect beg end))
                           (lambda (a b) (< (cadr a) (cadr b)))))
             (pos beg) (parts nil))
        (dolist (cz clozes)
          (cl-destructuring-bind (id cbeg cend text &optional hint) cz
            (push (buffer-substring-no-properties pos cbeg) parts)
            (push (cond ((not (equal id target)) text)
                        (revealed text)
                        (t (format "[%s]" (or hint "…"))))
                  parts)
            (setq pos cend)))
        (push (buffer-substring-no-properties pos end) parts)
        (list (eabp-text (string-trim (apply #'concat (nreverse parts))) 'body)))
    (error (list (eabp-text "Couldn't lay out this cloze." 'caption)))))

(defun glasspane-srs--fallback-content ()
  "Render the narrowed entry cleanly for an unknown item type.
Drawers and gutter line numbers stripped; transient overlays only."
  (let ((eabp-line-numbers nil) (overlays nil)
        (open (format "^[ \t]*:%s:[ \t]*$"
                      (regexp-opt glasspane-srs--noise-drawers))))
    (unwind-protect
        (progn
          (add-to-invisibility-spec 'glasspane-srs-hide)
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward open nil t)
              (let ((dbeg (match-beginning 0))
                    (dend (save-excursion
                            (and (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
                                 (min (1+ (line-end-position)) (point-max))))))
                (if (null dend)
                    (goto-char (line-end-position))
                  (let ((ov (make-overlay dbeg dend)))
                    (overlay-put ov 'invisible 'glasspane-srs-hide)
                    (push ov overlays))
                  (goto-char dend)))))
          (eabp-buffer-render (current-buffer)))
      (mapc #'delete-overlay overlays)
      (remove-from-invisibility-spec 'glasspane-srs-hide))))

(defun glasspane-srs--item-nodes (item-args revealed)
  "Clean card nodes for ITEM-ARGS (`(ITEM ID BUFFER)'), REVEALED or not.
Resolves the item's marker in the background — no window, no session —
narrows to its entry, and dispatches on the item type."
  (let* ((item (car item-args))
         (type (car item))
         (marker (glasspane-srs--quietly (apply #'org-srs-item-marker item-args))))
    (if (not (and (markerp marker) (marker-buffer marker)))
        (list (eabp-text "Couldn't load this card." 'caption))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char marker)
            (org-back-to-heading-or-point-min)
            (unless (org-before-first-heading-p) (org-narrow-to-subtree))
            (pcase type
              ('card (glasspane-srs--card-content item revealed))
              ('cloze (glasspane-srs--cloze-content item revealed))
              (_ (glasspane-srs--fallback-content)))))))))

;; ─── Rating chrome ───────────────────────────────────────────────────────────

(defconst glasspane-srs--ratings
  '(("again" :again "Again" "outlined")
    ("hard" :hard "Hard" "tonal")
    ("good" :good "Good" "filled")
    ("easy" :easy "Easy" "tonal"))
  "WIRE-NAME KEYWORD LABEL VARIANT rows for the rating buttons.")

(defun glasspane-srs--intervals ()
  "Predicted next intervals as a (:again SECS …) plist, or nil.
The org-srs-ui-mouse recipe, over the current item args: with point on
its log row and a `rating' column, the simulator runs."
  (when glasspane-srs--current
    (glasspane-srs--quietly
      (apply #'org-srs-item-call-with-current
             (lambda ()
               (when (org-srs-table-goto-column 'rating)
                 (org-srs-stats-intervals)))
             glasspane-srs--current))))

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

(defun glasspane-srs--session-body ()
  "The active-session screen: the card, then reveal or rating controls."
  (if (null glasspane-srs--current)
      (eabp-empty-state
       :icon "school" :title "All caught up"
       :caption "Review complete."
       :action-label "Done"
       :on-tap (eabp-action "srs.quit" :when-offline "drop"))
    (apply #'eabp-lazy-column
           (append
            (glasspane-srs--item-nodes glasspane-srs--current
                                       glasspane-srs--revealed)
            (list (eabp-spacer :height 8) (eabp-divider))
            (if glasspane-srs--revealed
                (glasspane-srs--rating-controls)
              (list (eabp-button "Show answer"
                                 (eabp-action "srs.answer.show"
                                              :when-offline "drop")
                                 :variant "filled" :icon "visibility")))))))

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
  "Session top-bar actions — kept to the two that read at a glance:
undo (only after a rating) and close.  Postpone/suspend are niche and
their icons weren't legible; they stay as `srs.*' actions for a future
labelled menu rather than cluttering the bar."
  (delq nil
        (list
         (when glasspane-srs--undo
           (eabp-icon-button "undo"
                             (eabp-action "srs.undo" :when-offline "drop")
                             :content-description "Undo last rating"))
         (eabp-icon-button "close"
                           (eabp-action "srs.quit" :when-offline "drop")
                           :content-description "End review"))))

(defun glasspane-srs--view (snackbar)
  "The Review screen for the current session state."
  (eabp-shell-nav-view
   "Review"
   (cond
    ((not (glasspane-srs-available-p)) (glasspane-srs--install-body))
    (glasspane-srs--active (glasspane-srs--session-body))
    (t (glasspane-srs--idle-body)))
   :actions (when (and glasspane-srs--active glasspane-srs--current)
              (glasspane-srs--top-actions))
   :snackbar snackbar))

(eabp-shell-define-view "srs" :builder #'glasspane-srs--view :order 78)

;; Everyday nav (the drawer contract); no entry while org-srs is absent.
(eabp-shell-add-drawer-item
 45 (lambda ()
      (when (glasspane-srs-available-p)
        (eabp-drawer-item "school" "Review" (eabp-shell-switch-view "srs")))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "srs.review.start"
  (lambda (_args _)
    (if (not (glasspane-srs-available-p))
        (eabp-shell-notify "org-srs is not installed")
      (setq glasspane-srs--active t glasspane-srs--undo nil)
      (glasspane-srs--advance))
    (eabp-shell-push nil :switch-to "srs")))

(eabp-defaction "srs.answer.show"
  (lambda (_args _)
    (when glasspane-srs--current (setq glasspane-srs--revealed t))
    (eabp-shell-push)))

(defun glasspane-srs--push-undo (item-args)
  "Snapshot ITEM-ARGS's log drawer onto the undo stack (capped).
Best-effort: a snapshot failure must not block the rating."
  (glasspane-srs--quietly
    (let ((marker (apply #'org-srs-item-marker item-args)))
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (let ((log (buffer-substring-no-properties
                     (progn (org-srs-log-beginning-of-drawer) (point))
                     (progn (org-srs-log-end-of-drawer) (point)))))
           (push (cons item-args log) glasspane-srs--undo)
           (when (nthcdr 20 glasspane-srs--undo)
             (setcdr (nthcdr 19 glasspane-srs--undo) nil))))))))

(eabp-defaction "srs.rate"
  (lambda (args _)
    (let ((kw (cadr (assoc (alist-get 'rating args) glasspane-srs--ratings))))
      (when (and kw glasspane-srs--current)
        (glasspane-srs--push-undo glasspane-srs--current)
        (glasspane-srs--engine
          ;; No session ⇒ org-srs-review-item is unbound; nil makes
          ;; `org-srs-review-rate' rate the item passed in ARGS instead.
          (let ((org-srs-review-item nil))
            (apply #'org-srs-review-rate kw glasspane-srs--current)))
        (glasspane-org-cache-invalidate)
        (glasspane-srs--advance)))
    (eabp-shell-push)))

(eabp-defaction "srs.quit"
  (lambda (_args _)
    (setq glasspane-srs--active nil glasspane-srs--current nil
          glasspane-srs--revealed nil glasspane-srs--undo nil)
    (eabp-shell-push)))

(eabp-defaction "srs.postpone"
  (lambda (_args _)
    (when glasspane-srs--current
      (glasspane-srs--engine
        (apply #'org-srs-review-postpone '(1 :day) glasspane-srs--current))
      (glasspane-org-cache-invalidate)
      (glasspane-srs--advance))
    (eabp-shell-push)))

(eabp-defaction "srs.suspend"
  (lambda (_args _)
    (when glasspane-srs--current
      (glasspane-srs--engine
        (let ((marker (apply #'org-srs-item-marker glasspane-srs--current)))
          (with-current-buffer (marker-buffer marker)
            (save-excursion
              (save-restriction
                (widen)
                (goto-char marker)
                (org-back-to-heading t)
                (unless (org-in-commented-heading-p) (org-toggle-comment))
                (let ((save-silently t)) (save-buffer)))))))
      (glasspane-org-cache-invalidate)
      (glasspane-srs--advance))
    (eabp-shell-push)))

(eabp-defaction "srs.undo"
  ;; org-srs's own undo history is set up only by the session we don't
  ;; run, so we restore the item's log drawer from our own snapshot and
  ;; re-present the card (answer shown) for a fresh rating.
  (lambda (_args _)
    (if-let ((snap (pop glasspane-srs--undo)))
        (progn
          (glasspane-srs--engine
            (let* ((item-args (car snap))
                   (marker (apply #'org-srs-item-marker item-args)))
              (with-current-buffer (marker-buffer marker)
                (org-with-wide-buffer
                 (goto-char marker)
                 (delete-region
                  (progn (org-srs-log-beginning-of-drawer) (point))
                  (progn (org-srs-log-end-of-drawer) (point)))
                 (insert (cdr snap))
                 (org-srs-log-hide-drawer)
                 (let ((save-silently t)) (save-buffer))))))
          (glasspane-org-cache-invalidate)
          (setq glasspane-srs--current (car snap) glasspane-srs--revealed t))
      (eabp-shell-notify "Nothing to undo"))
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
