;;; eabp-emacs-ui.el --- EABP Emacs REPL & Buffer Viewer -*- lexical-binding: t; -*-

;; Provides an in-app Emacs interaction layer:
;;   * Buffer viewer (switch buffers, see content)
;;   * *Messages* tail
;;   * M-x command runner (interactive command dialog)
;;   * Elisp eval REPL
;;
;; Registers three shell views — "buffers", "eval" (a bottom-bar tab), and
;; "messages" — plus their drawer entries and the M-x top-bar action.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer)
(require 'eabp-tablist)
(require 'eabp-shell)
(require 'eabp-witheditor)
(require 'imenu)
(require 'cl-lib)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar eabp-emacs-ui--viewing-buffer nil
  "Name of the buffer currently being viewed, or nil for the buffer list.")

(defvar eabp-emacs-ui--section nil
  "Active section narrowing for the buffer view, or nil.
A plist (:buffer NAME :beg POS :end POS :label STRING :point POS);
while set for the viewed buffer, the view renders just that slice,
with :point (when non-nil) marked as the scroll target.  Set by
`imenu.show' or `eabp-emacs-ui-view-region', cleared by `imenu.clear'
or leaving the buffer.")

(defun eabp-emacs-ui-view-region (buffer-name beg end label &optional point)
  "Open the buffer view on BUFFER-NAME narrowed to [BEG, END).
LABEL heads the slice; POINT, when non-nil, marks the scroll-target
line.  The navigation entry other modules use to show \"this spot in
that buffer\" — grep hits, and any future jump affordance."
  (setq eabp-emacs-ui--viewing-buffer buffer-name
        eabp-emacs-ui--section (list :buffer buffer-name :beg beg :end end
                                     :label label :point point))
  (eabp-shell-push nil :switch-to "buffers"))

;; eabp-files stays independent of this module (it loads first); its
;; grep hits navigate here through the seam.
(defvar eabp-files-view-region-function)
(with-eval-after-load 'eabp-files
  (setq eabp-files-view-region-function #'eabp-emacs-ui-view-region))

;; Navigating to a buffer (the tablist skins open package descriptions and
;; list buffers this way) is this module's buffer view.
(setq eabp-tablist-view-buffer-function
      (lambda (name)
        (setq eabp-emacs-ui--viewing-buffer name)
        (eabp-shell-push nil :switch-to "buffers")))

(defvar eabp-emacs-ui--eval-history nil
  "List of (input . output) pairs from the eval REPL, newest first.")

(defcustom eabp-emacs-ui-eval-history-max 50
  "Maximum eval-history entries kept (and shipped in the dashboard spec)."
  :type 'integer :group 'eabp)

(defcustom eabp-emacs-ui-eval-output-max 2000
  "Eval results longer than this many characters are truncated for display."
  :type 'integer :group 'eabp)

(defvar eabp-emacs-ui--messages-line-count 100
  "Number of tail lines to show from *Messages*.")

;; ─── Buffer List ─────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--buffer-list-body ()
  "Build UI for the buffer list."
  (let* ((bufs (cl-remove-if
                (lambda (b) (string-prefix-p " " (buffer-name b)))
                (buffer-list)))
         (cards (mapcar
                 (lambda (buf)
                   (let* ((name (buffer-name buf))
                          (file (buffer-file-name buf))
                          (modified (buffer-modified-p buf))
                          (subtitle (cond
                                    (file (abbreviate-file-name file))
                                    (t (format "%d lines"
                                              (with-current-buffer buf
                                                (count-lines (point-min) (point-max)))))))
                          (prefix (if modified "● " "")))
                     (eabp-card
                      (list (eabp-column
                             (eabp-text (concat prefix name) 'body)
                             (eabp-text subtitle 'caption)))
                      :on-tap (eabp-action "emacs.buffer.view"
                                           :args `((buffer . ,name))))))
                 bufs)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-text "No buffers." 'body))))

;; ─── Buffer Content Viewer ───────────────────────────────────────────────────

(defun eabp-emacs-ui--buffer-view-body (buffer-name)
  "Build UI showing the contents of BUFFER-NAME.
Rendered through the Tier 0 generic renderer (`eabp-render-buffer'), so the
buffer's faces and tappable regions survive — any major mode works without a
bespoke translator.  With an imenu section active for this buffer, only
that slice renders, under a dismissible header."
  (let ((buf (get-buffer buffer-name))
        (section (and (equal (plist-get eabp-emacs-ui--section :buffer)
                             buffer-name)
                      eabp-emacs-ui--section)))
    (cond
     ((not buf)
      (eabp-text (format "Buffer '%s' not found." buffer-name) 'body))
     (section
      (apply #'eabp-lazy-column
             (cons (eabp-row
                    (eabp-box (list (eabp-text (plist-get section :label)
                                               'label))
                              :weight 1)
                    (eabp-icon-button "close"
                                      (eabp-action "imenu.clear"
                                                   :when-offline "drop")
                                      :content-description "Show whole buffer"))
                   (eabp-buffer-render-region buf
                                              (plist-get section :beg)
                                              (plist-get section :end)
                                              (plist-get section :point)))))
     (t (apply #'eabp-lazy-column (eabp-render-buffer buf))))))

;; ─── imenu sections ──────────────────────────────────────────────────────────
;;
;; imenu is the per-buffer index of definitions/sections any major mode
;; provides declaratively.  The picker is a bridged `completing-read'
;; (the same vertico-style dialog M-x uses), and the chosen entry
;; renders as a region slice — the phone has no scroll-to-position, so
;; "jump" means "show me that section".

(defun eabp-emacs-ui--imenu-flatten (alist prefix)
  "Flatten an imenu ALIST into ((LABEL . POSITION) ...), in index order.
Nested submenus join their path with \" / \"; the *Rescan* pseudo-entry
and unresolvable positions are dropped.  PREFIX is the path so far."
  (let (out)
    (dolist (item alist)
      (when (and (consp item) (car item))
        (let* ((label (if (string-empty-p prefix)
                          (format "%s" (car item))
                        (format "%s / %s" prefix (car item))))
               (tail (cdr item))
               ;; (NAME . POS) or the general (NAME POS FUNCTION ...) form.
               (pos (cond ((number-or-marker-p tail) tail)
                          ((and (consp tail) (number-or-marker-p (car tail)))
                           (car tail)))))
          (cond
           ((and (listp tail) (not pos))  ; a submenu
            (setq out (append out (eabp-emacs-ui--imenu-flatten tail label))))
           ((and pos
                 (not (equal (format "%s" (car item)) "*Rescan*"))
                 (>= (if (markerp pos) (or (marker-position pos) 0) pos) 1))
            (setq out (append out (list (cons label
                                              (if (markerp pos)
                                                  (marker-position pos)
                                                pos))))))))))
    out))

;; ─── Live buffer refresh ─────────────────────────────────────────────────────
;;
;; A buffer drilled into on the phone is a one-shot snapshot: it's rendered at
;; tap time and then frozen.  Self-updating buffers — compilation, grep, async
;; shell, *Messages* — need to re-push as they change.  While a buffer is being
;; viewed, a light timer compares `buffer-chars-modified-tick' and re-pushes on
;; change; the reconcile runs after every push, so the watch tracks
;; `eabp-emacs-ui--viewing-buffer' however it was set or cleared.

(defcustom eabp-emacs-ui-live-refresh t
  "When non-nil, a buffer drilled into on the phone refreshes as it changes.
Self-updating buffers (compilation, grep, async shell, *Messages*) re-push
while viewed instead of freezing at the snapshot taken when you opened them."
  :type 'boolean :group 'eabp)

(defcustom eabp-emacs-ui-live-interval 1.0
  "Seconds between change checks for the buffer being viewed.
Polls only while a buffer is actively drilled into and the bridge is
connected; each check is a cheap tick comparison and pushes only on change."
  :type 'number :group 'eabp)

(defvar eabp-emacs-ui--live-timer nil)
(defvar eabp-emacs-ui--live-buffer nil
  "The buffer object currently watched for live refresh, or nil.")
(defvar eabp-emacs-ui--live-tick nil
  "`buffer-chars-modified-tick' of the watched buffer at its last push.")

(defun eabp-emacs-ui--live-tick-of (buf)
  "The `buffer-chars-modified-tick' of BUF, or nil if BUF is dead."
  (and (buffer-live-p buf)
       (with-current-buffer buf (buffer-chars-modified-tick))))

(defun eabp-emacs-ui--live-stop ()
  "Tear down the live-refresh watch."
  (when (timerp eabp-emacs-ui--live-timer)
    (cancel-timer eabp-emacs-ui--live-timer))
  (setq eabp-emacs-ui--live-timer nil
        eabp-emacs-ui--live-buffer nil
        eabp-emacs-ui--live-tick nil))

(defun eabp-emacs-ui--live-poll ()
  "Timer body: re-push when the watched buffer changed since its last push."
  (let ((buf eabp-emacs-ui--live-buffer))
    (if (or (not eabp-emacs-ui-live-refresh)
            (not (eabp-connected-p))
            (not (buffer-live-p buf))
            ;; The user navigated away from (or swapped) the viewed buffer.
            (not (equal (buffer-name buf) eabp-emacs-ui--viewing-buffer)))
        (eabp-emacs-ui--live-stop)
      (let ((tick (eabp-emacs-ui--live-tick-of buf)))
        (unless (equal tick eabp-emacs-ui--live-tick)
          ;; Safe to push here: a timer, not a change hook.
          (eabp-shell-push)
          ;; Re-read the tick AFTER the push so a message the push itself
          ;; logged (when the viewed buffer *is* *Messages*) can't drive an
          ;; endless self-refresh — only genuinely new changes re-trigger.
          (setq eabp-emacs-ui--live-tick (eabp-emacs-ui--live-tick-of buf)))))))

(defun eabp-emacs-ui--reconcile-live-watch ()
  "Start/stop the live-refresh watch to match the buffer being viewed.
Runs after every shell push, so the watch follows
`eabp-emacs-ui--viewing-buffer' no matter which code path changed it."
  (let* ((name (and eabp-emacs-ui-live-refresh
                    (eabp-connected-p)
                    eabp-emacs-ui--viewing-buffer))
         (buf (and name (get-buffer name))))
    (cond
     ((not (buffer-live-p buf)) (eabp-emacs-ui--live-stop))
     ((eq buf eabp-emacs-ui--live-buffer) nil) ; already watching it
     (t
      (eabp-emacs-ui--live-stop)
      (setq eabp-emacs-ui--live-buffer buf
            eabp-emacs-ui--live-tick (eabp-emacs-ui--live-tick-of buf)
            eabp-emacs-ui--live-timer
            (run-at-time eabp-emacs-ui-live-interval eabp-emacs-ui-live-interval
                         #'eabp-emacs-ui--live-poll))))))

(add-hook 'eabp-shell-after-push-hook #'eabp-emacs-ui--reconcile-live-watch)

;; ─── *Messages* Tail ─────────────────────────────────────────────────────────

(defun eabp-emacs-ui--messages-tail ()
  "The last `eabp-emacs-ui--messages-line-count' lines of *Messages*."
  (if-let ((msgs-buf (get-buffer "*Messages*")))
      (with-current-buffer msgs-buf
        (let* ((lines (split-string
                       (buffer-substring-no-properties (point-min) (point-max))
                       "\n" t))
               (tail (last lines eabp-emacs-ui--messages-line-count)))
          (mapconcat #'identity tail "\n")))
    "No *Messages* buffer."))

(defun eabp-emacs-ui--messages-line (line stripe)
  "One zebra row for the Messages view.
LINE is selectable (long-press to copy); STRIPE non-nil tints the row
with a theme-adaptive container color so lines read as distinct entries."
  (let ((text (eabp-text (if (string-empty-p line) " " line)
                         'mono nil nil t nil 4)))
    (if stripe
        (eabp-surface (list text)
                      :color "surface_container"
                      :shape "rounded_small"
                      :fill t)
      text)))

(defun eabp-emacs-ui--messages-body ()
  "Build the Messages view: zebra-striped, selectable lines + copy all.
Each *Messages* line is its own row (alternate rows tinted) so entries
are visually delineated; every row is long-press selectable, and Copy
all uses the companion-local clipboard builtin."
  (let* ((content (eabp-emacs-ui--messages-tail))
         (i 0)
         (rows (mapcar (lambda (line)
                         (prog1 (eabp-emacs-ui--messages-line line (cl-oddp i))
                           (setq i (1+ i))))
                       (split-string content "\n"))))
    (eabp-column
     (eabp-row
      (eabp-text (format "Last %d lines" eabp-emacs-ui--messages-line-count)
                 'caption)
      (eabp-spacer :weight 1)
      (eabp-button "Copy all" (eabp-clipboard-action content) :variant "text"))
     (eabp-box
      (list (apply #'eabp-lazy-column rows))
      :weight 1))))

;; ─── *Messages* → device toasts ──────────────────────────────────────────────

(defcustom eabp-forward-messages t
  "When non-nil, echo-area messages mirror to the companion as toasts.
Throttled to at most one per second (latest wins); EABP's own bridge
chatter is filtered out so it can never echo back to the phone."
  :type 'boolean :group 'eabp)

(defvar eabp-emacs-ui--toast-last 0
  "Time of the last toast sent, for throttling.")
(defvar eabp-emacs-ui--toast-timer nil)
(defvar eabp-emacs-ui--toast-pending nil
  "Latest message held back by the throttle, flushed by the timer.")
(defvar eabp-emacs-ui--in-toast nil
  "Reentrancy guard: non-nil while forwarding a message.")

(defun eabp-emacs-ui--toast-send (text)
  (setq eabp-emacs-ui--toast-last (float-time))
  (eabp-send "toast.show" `((text . ,text))))

(defun eabp-emacs-ui--message-advice (format-string &rest args)
  "Mirror `message' output to the companion as a toast.
Runs as :after advice on `message'; never signals, never recurses.
Honours `inhibit-message': output the caller silenced for the echo area
\(e.g. the flymake shadow compile's \"Wrote ....elc\") stays silent on
the phone too."
  (when (and eabp-forward-messages
             (not inhibit-message)
             (not eabp-emacs-ui--in-toast)
             format-string
             (eabp-connected-p))
    (let* ((eabp-emacs-ui--in-toast t)
           (msg (ignore-errors (apply #'format-message format-string args))))
      (when (and (stringp msg)
                 (not (string-empty-p (string-trim msg)))
                 (not (string-prefix-p "EABP" msg)))
        (when (> (length msg) 200)
          (setq msg (concat (substring msg 0 200) "…")))
        (if (> (- (float-time) eabp-emacs-ui--toast-last) 1.0)
            (eabp-emacs-ui--toast-send msg)
          ;; Throttle window: hold only the LATEST message and flush once.
          (setq eabp-emacs-ui--toast-pending msg)
          (unless (timerp eabp-emacs-ui--toast-timer)
            (setq eabp-emacs-ui--toast-timer
                  (run-at-time
                   1.0 nil
                   (lambda ()
                     (setq eabp-emacs-ui--toast-timer nil)
                     (when eabp-emacs-ui--toast-pending
                       (eabp-emacs-ui--toast-send
                        (prog1 eabp-emacs-ui--toast-pending
                          (setq eabp-emacs-ui--toast-pending nil))))))))))))
  nil)

(advice-add 'message :after #'eabp-emacs-ui--message-advice)

;; ─── Eval REPL ───────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--eval-card (entry)
  "One REPL history card for ENTRY (INPUT . OUTPUT).
Input line, then the (selectable) result, with copy and re-run buttons."
  (let* ((input (car entry))
         (output (cdr entry))
         (shown (if (> (length output) eabp-emacs-ui-eval-output-max)
                    (concat (substring output 0 eabp-emacs-ui-eval-output-max)
                            " …")
                  output)))
    (eabp-card
     (list (eabp-column
            (eabp-row
             (eabp-box (list (eabp-text (concat "λ> " input) 'label))
                       :weight 1)
             (eabp-icon-button "content_copy"
                               (eabp-clipboard-action output)
                               :content-description "Copy result")
             (eabp-icon-button "play_arrow"
                               (eabp-action "emacs.eval.submit"
                                            :args `((value . ,input)))
                               :content-description "Re-run"))
            (eabp-text shown 'mono nil nil t))))))

;; REPL input is one-shot expressions, not a file: tell the sync bridge so
;; its byte-compile diagnostics run under lexical binding (matching the
;; `eval' below) instead of warning about a missing lexical-binding cookie.
(with-eval-after-load 'eabp-sync
  (add-to-list 'eabp-sync-elisp-repl-files "eval.el"))

(defun eabp-emacs-ui--eval-body ()
  "Build UI for the elisp eval REPL.
History (newest first) scrolls in a weighted region; the input field and
Eval button stay pinned below it, so they can never be pushed off-screen
by a long history — the layout bug the old plain-column version had."
  (let* ((history-cards (mapcar #'eabp-emacs-ui--eval-card
                                eabp-emacs-ui--eval-history))
         ;; A chromeless editor instead of a plain text_input: the id names
         ;; a virtual elisp file, so the full bridge lights up in the REPL —
         ;; completion chips from the live obarray, paren/byte-compile
         ;; squiggles as you type, eldoc signatures in the doc line, and
         ;; Emacs-theme fontification. publish-state keeps the Eval button's
         ;; ui-state read working exactly like the old field.
         (input-field (eabp-editor "eval.el" ""
                                   :chromeless t
                                   :publish-state t
                                   :complete t
                                   :syntax "elisp")))
    (eabp-column
     (eabp-box
      (list (if history-cards
                (apply #'eabp-lazy-column history-cards)
              (eabp-empty-state :icon "code"
                                :title "Elisp REPL"
                                :caption "Results appear here, newest first.")))
      :weight 1)
     (eabp-divider)
     (eabp-box
      (list
       (eabp-row
        (eabp-box (list input-field) :weight 1)
        (eabp-spacer :width 8)
        (eabp-icon-button "send" (eabp-action "emacs.eval.submit")
                          :content-description "Eval")))
      :padding 8))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

;; Buffer list / view
(eabp-defaction "emacs.buffer.view"
  (lambda (args _)
    (setq eabp-emacs-ui--viewing-buffer (alist-get 'buffer args)
          eabp-emacs-ui--section nil)
    (eabp-shell-push)))

(eabp-defaction "emacs.buffer.back"
  (lambda (_ _)
    (setq eabp-emacs-ui--viewing-buffer nil
          eabp-emacs-ui--section nil)
    (eabp-shell-push)))

;; imenu sections
(eabp-defaction "imenu.show"
  (lambda (args _)
    (let* ((name (or (alist-get 'buffer args) eabp-emacs-ui--viewing-buffer))
           (buf (and (stringp name) (get-buffer name))))
      (if (not buf)
          (message "No buffer to index")
        (let ((flat (with-current-buffer buf
                      (condition-case nil
                          (eabp-emacs-ui--imenu-flatten
                           (imenu--make-index-alist t) "")
                        (error nil)))))
          (if (null flat)
              (message "No sections found in %s" name)
            (let ((choice (condition-case nil
                              (completing-read "Section: " (mapcar #'car flat)
                                               nil t)
                            (quit nil))))
              (when-let ((pos (cdr (assoc choice flat))))
                (with-current-buffer buf
                  ;; The section runs from the entry's line to the next
                  ;; index position after it (in any submenu), else eob.
                  (let* ((beg (save-excursion (goto-char (min pos (point-max)))
                                              (line-beginning-position)))
                         (after (sort (cl-remove-if (lambda (p) (<= p pos))
                                                    (mapcar #'cdr flat))
                                      #'<))
                         (end (or (car after) (point-max))))
                    (setq eabp-emacs-ui--section
                          (list :buffer name :beg beg :end end
                                :label choice))))
                (eabp-shell-push)))))))))

(eabp-defaction "imenu.clear"
  (lambda (_ _)
    (setq eabp-emacs-ui--section nil)
    (eabp-shell-push)))

(defun eabp-emacs-ui--eval-record (input output)
  "Push (INPUT . OUTPUT) onto the eval history, bounded by the max."
  (push (cons input output) eabp-emacs-ui--eval-history)
  (when (> (length eabp-emacs-ui--eval-history) eabp-emacs-ui-eval-history-max)
    (setcdr (nthcdr (1- eabp-emacs-ui-eval-history-max)
                    eabp-emacs-ui--eval-history)
            nil)))

;; Eval REPL
(eabp-defaction "emacs.eval.submit"
  (lambda (args _)
    ;; The Eval button carries no value, so fall back to the field's latest
    ;; value recorded by `state.changed' (same pattern as the capture form).
    ;; "eval.el" is the editor-based field; "eval-input" the legacy one.
    (let* ((expr (or (alist-get 'value args)
                     (eabp-ui-state "eval.el")
                     (eabp-ui-state "eval-input")
                     ""))
           (result (condition-case err
                       ;; Wrap in progn so multi-sexp input evaluates fully
                       ;; (bare `read' silently ignored everything after the
                       ;; first form).
                       (let ((val (eval (car (read-from-string
                                              (format "(progn %s\n)" expr)))
                                        t)))
                         (format "%S" val))
                     (error (format "ERROR: %s" (error-message-string err))))))
      (unless (string-empty-p (string-trim expr))
        (eabp-emacs-ui--eval-record expr result))
      (eabp-shell-push))))

;; M-x — runs `completing-read' over all commands, which the minibuffer
;; bridge turns into a live-filtering (vertico-style) picker dialog. The
;; chosen command is then run with `call-interactively' (its own prompts,
;; if any, are bridged too). Result lands in the Eval tab's history.
(eabp-defaction "emacs.mx.show"
  (lambda (_ _)
    (let ((cmd-name (condition-case nil
                        (completing-read "M-x " obarray #'commandp t)
                      (quit nil))))
      (when (and (stringp cmd-name) (not (string-empty-p cmd-name)))
        (let ((cmd (intern-soft cmd-name)))
          (cond
           ((not (commandp cmd))
            (eabp-emacs-ui--eval-record (concat "M-x " cmd-name)
                                        (format "'%s' is not a command." cmd-name)))
           (t
            (condition-case err
                (progn
                  (call-interactively cmd)
                  (eabp-emacs-ui--eval-record (concat "M-x " cmd-name)
                                              "Command executed."))
              (error
               (eabp-emacs-ui--eval-record
                (concat "M-x " cmd-name)
                (format "ERROR: %s" (error-message-string err))))))))
        (eabp-shell-push "eval")))))

;; Messages refresh
(eabp-defaction "emacs.messages.refresh"
  (lambda (_ _)
    (eabp-shell-push)))

;; Clear eval history
(eabp-defaction "emacs.eval.clear"
  (lambda (_ _)
    (setq eabp-emacs-ui--eval-history nil)
    (eabp-shell-push)))


;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--buffers-view (snackbar)
  "The Buffers view: list of live buffers, or the drilled-in buffer.
The list gets tab-style chrome (drawer, bottom bar, pull-to-refresh)
even though Buffers has no bottom-bar item of its own — it is reached
from the drawer.  Drilling into a buffer swaps to back-arrow chrome
with a keyboard FAB that opens the buffer's keymap."
  (if eabp-emacs-ui--viewing-buffer
      (eabp-shell-nav-view
       eabp-emacs-ui--viewing-buffer
       (eabp-emacs-ui--buffer-view-body eabp-emacs-ui--viewing-buffer)
       ;; Content swap within the buffers view: stays an Emacs round-trip
       ;; (the list must be rebuilt).
       :nav-action (eabp-action "emacs.buffer.back")
       :actions (list (eabp-icon-button
                       "toc"
                       (eabp-action "imenu.show"
                                    :args `((buffer . ,eabp-emacs-ui--viewing-buffer))
                                    :when-offline "drop")
                       :content-description "Sections (imenu)"))
       :fab (eabp-fab "keyboard"
                      :on-tap (eabp-action "eabp.keymap.show"
                               :args `((buffer . ,eabp-emacs-ui--viewing-buffer))
                               :when-offline "drop"))
       :snackbar snackbar)
    (eabp-shell-tab-view "buffers" (eabp-emacs-ui--buffer-list-body)
                         :snackbar snackbar)))

(defun eabp-emacs-ui--eval-view (snackbar)
  "The Eval tab: REPL history over a pinned input row."
  (eabp-shell-tab-view
   "eval" (eabp-emacs-ui--eval-body)
   :top-bar (eabp-shell-default-top-bar
             "Eval"
             :extra-actions (list (eabp-icon-button
                                   "delete"
                                   (eabp-action "emacs.eval.clear")
                                   :content-description "Clear history")))
   :fab nil
   :snackbar snackbar))

(defun eabp-emacs-ui--messages-view (snackbar)
  "The Messages view: the *Messages* tail with a refresh button."
  (eabp-shell-nav-view
   "Messages" (eabp-emacs-ui--messages-body)
   :actions (list (eabp-icon-button
                   "refresh"
                   (eabp-action "emacs.messages.refresh" :when-offline "drop")
                   :content-description "Refresh"))
   :snackbar snackbar))

(eabp-shell-define-view "buffers" :builder #'eabp-emacs-ui--buffers-view
                        :order 60)
(eabp-shell-define-view "eval" :builder #'eabp-emacs-ui--eval-view
                        :tab '(:icon "code" :label "Eval") :order 50)
(eabp-shell-define-view "messages" :builder #'eabp-emacs-ui--messages-view
                        :order 90)

;; Landing anywhere but the current tab drops a buffer drill-in (and its
;; imenu section).  Named so re-evaluating the file doesn't stack lambdas.
(defun eabp-emacs-ui--on-view-switched (view)
  (unless (equal view (eabp-shell-current-tab))
    (setq eabp-emacs-ui--viewing-buffer nil
          eabp-emacs-ui--section nil)))
(add-hook 'eabp-shell-view-switched-hook #'eabp-emacs-ui--on-view-switched)

(eabp-shell-add-drawer-item
 10 (lambda () (eabp-drawer-item "view_list" "Buffers"
                                 (eabp-shell-switch-view "buffers"))))
(eabp-shell-add-drawer-item
 20 (lambda () (eabp-drawer-item "history" "Messages"
                                 (eabp-shell-switch-view "messages"))))

;; M-x is available from every tab's top bar (no drawer entry needed).
(eabp-shell-add-top-action
 20 (lambda () (eabp-icon-button "terminal" (eabp-action "emacs.mx.show"))))

(provide 'eabp-emacs-ui)
;;; eabp-emacs-ui.el ends here
