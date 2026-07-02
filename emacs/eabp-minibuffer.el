;;; eabp-minibuffer.el --- Bridge minibuffer prompts to the companion -*- lexical-binding: t; -*-

;; When an EABP action handler calls a prompting function (y-or-n-p,
;; read-from-minibuffer, completing-read, …) the user is on their phone,
;; not at a keyboard.  This module intercepts those calls, sends the prompt
;; to the companion as a dialog, and synchronously waits for the reply —
;; exactly as the original function would block for keyboard input, just
;; over the bridge instead.
;;
;; The advice is active ONLY while `eabp--in-action-handler' is non-nil,
;; so normal Emacs usage at the keyboard is completely unaffected.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'cl-lib)

;; ─── Configuration ───────────────────────────────────────────────────────────

(defcustom eabp-prompt-timeout 60
  "Seconds to wait for the companion to answer a forwarded prompt.
After this the prompt is cancelled (as if the user dismissed the dialog)."
  :type 'integer :group 'eabp)

;; ─── Internal state ──────────────────────────────────────────────────────────

(defvar eabp--in-action-handler nil
  "Non-nil while an EABP action handler is executing.
Bound by `eabp--on-action' in eabp-surfaces.el.  The minibuffer advice
checks this to decide whether to intercept.")

(defvar eabp--prompt-reply nil
  "Alist of prompt-id → reply value, filled by the `prompt.reply' action.")

(defvar eabp--prompt-cancelled nil
  "Alist of prompt-id → t, set when the companion dismisses the dialog.")

(defvar eabp-minibuffer--context-buffers nil
  "List of buffer names displayed during the current action handler.")

(defun eabp-minibuffer--record-context-buffer (buffer-or-name)
  "Record BUFFER-OR-NAME as a context buffer if in an action handler."
  (when eabp--in-action-handler
    (let ((buf (get-buffer buffer-or-name)))
      (when (and buf (string-prefix-p "*" (buffer-name buf)))
        (cl-pushnew (buffer-name buf) eabp-minibuffer--context-buffers :test #'equal)))))

(defun eabp-minibuffer--display-buffer-advice (orig-fn buffer-or-name &rest args)
  (eabp-minibuffer--record-context-buffer buffer-or-name)
  (apply orig-fn buffer-or-name args))

(advice-add 'display-buffer :around #'eabp-minibuffer--display-buffer-advice)

(defun eabp-minibuffer--temp-buffer-show-hook ()
  (eabp-minibuffer--record-context-buffer (current-buffer)))

(add-hook 'temp-buffer-show-hook #'eabp-minibuffer--temp-buffer-show-hook)

(defun eabp-minibuffer--context-cards ()
  "Return a list of `eabp-card` widgets containing the text of recently displayed context buffers."
  (delq nil
        (mapcar (lambda (bname)
                  (let ((buf (get-buffer bname)))
                    (when buf
                      (eabp-card
                       (list (eabp-column
                              (eabp-text bname 'caption)
                              (eabp-text
                               (with-current-buffer buf
                                 (buffer-substring-no-properties (point-min) (min (point-max) (+ (point-min) 4000))))
                               'body nil nil t)))))))
                (reverse eabp-minibuffer--context-buffers))))

;; ─── Reply / dismiss handlers ────────────────────────────────────────────────

(defun eabp--prompt-reply-handler (args _payload)
  "Handle `prompt.reply' actions from the companion."
  (let ((id (alist-get 'prompt_id args))
        (value (alist-get 'value args)))
    (when id
      (push (cons id value) eabp--prompt-reply))))

(defun eabp--prompt-dismiss-handler (args _payload)
  "Handle `prompt.dismiss' actions — user dismissed without answering."
  (let ((id (alist-get 'prompt_id args)))
    (when id
      (push (cons id t) eabp--prompt-cancelled))))

;; Register via the action dispatch table.  This file is loaded after
;; eabp-surfaces has provided itself, so `eabp-defaction' is available.
(eabp-defaction "prompt.reply"  #'eabp--prompt-reply-handler)
(eabp-defaction "prompt.dismiss" #'eabp--prompt-dismiss-handler)

;; ─── Core: send prompt, wait for reply ───────────────────────────────────────

(defvar eabp--prompt-counter 0)

(defun eabp--prompt-id ()
  "Generate a unique prompt id."
  (format "prompt-%d-%04x" (cl-incf eabp--prompt-counter) (random #x10000)))

(defun eabp--send-prompt-dialog (_prompt-id body)
  "Send BODY as a dialog, prepending any recorded context-buffer cards.
A BODY that is itself a `lazy_column' (the completing-read picker) gets
the cards merged into it: nesting one vertical scroll container inside
another crashes the companion's Compose renderer."
  (let ((context-cards (eabp-minibuffer--context-cards)))
    (cond
     ((null context-cards)
      (eabp-send-dialog body))
     ((equal (alist-get 't body) "lazy_column")
      (eabp-send-dialog
       `((t . "lazy_column")
         (children . ,(vconcat context-cards
                               (append (alist-get 'children body) nil))))))
     (t
      (eabp-send-dialog
       (apply #'eabp-lazy-column (append context-cards (list body))))))))

(defun eabp--wait-for-prompt (prompt-id)
  "Block (pumping the event loop) until PROMPT-ID gets a reply or times out.
Returns the reply value, or the symbol `cancelled' if dismissed/timed out."
  (let ((deadline (+ (float-time) eabp-prompt-timeout)))
    (while (and (not (assoc prompt-id eabp--prompt-reply))
                (not (assoc prompt-id eabp--prompt-cancelled))
                (< (float-time) deadline)
                ;; Stay alive only as long as the connection is up.
                (eabp-connected-p))
      (accept-process-output nil 0.1))
    (cond
     ((assoc prompt-id eabp--prompt-reply)
      (let ((value (alist-get prompt-id eabp--prompt-reply nil nil #'equal)))
        ;; Clean up.
        (setq eabp--prompt-reply
              (assoc-delete-all prompt-id eabp--prompt-reply))
        value))
     (t
      ;; Dismissed, timed out, or disconnected.
      (setq eabp--prompt-cancelled
            (assoc-delete-all prompt-id eabp--prompt-cancelled))
      'cancelled))))

(defun eabp--cleanup-prompt ()
  "Dismiss any leftover dialog after an action handler finishes."
  (eabp-dismiss-dialog)
  (setq eabp-minibuffer--context-buffers nil))

;; ─── Advice: y-or-n-p ────────────────────────────────────────────────────────

(defun eabp--y-or-n-p-advice (orig-fn prompt &rest args)
  "Around advice for `y-or-n-p'.  Intercept during action handlers."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let* ((id (eabp--prompt-id))
           (dialog-body
            (eabp-column
             (eabp-text (string-trim-right prompt "[ ?]+") 'title)
             (eabp-row
              (eabp-button "No"
                           (eabp-action "prompt.reply"
                                        :args `((prompt_id . ,id) (value . :false)))
                           :variant "outlined")
              (eabp-spacer :width 8)
              (eabp-button "Yes"
                           (eabp-action "prompt.reply"
                                        :args `((prompt_id . ,id) (value . t))))))))
      (eabp--send-prompt-dialog id dialog-body)
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (not (or (eq reply 'cancelled)
                 (eq reply :false)
                 (eq reply nil)))))))

(advice-add 'y-or-n-p :around #'eabp--y-or-n-p-advice)

;; ─── Advice: yes-or-no-p ────────────────────────────────────────────────────

(defun eabp--yes-or-no-p-advice (orig-fn prompt &rest args)
  "Around advice for `yes-or-no-p'.  Same as y-or-n-p for the companion."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    ;; Reuse the y-or-n-p bridge — the distinction doesn't matter on a phone.
    (eabp--y-or-n-p-advice #'ignore prompt)))

(advice-add 'yes-or-no-p :around #'eabp--yes-or-no-p-advice)

;; ─── Advice: read-from-minibuffer ────────────────────────────────────────────

(defun eabp--read-from-minibuffer-advice (orig-fn prompt &rest args)
  "Around advice for `read-from-minibuffer'.  Text-input dialog."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let* ((id (eabp--prompt-id))
           (initial (nth 0 args))  ;; initial-contents
           (input-id (format "prompt-input-%s" id))
           (current-value (if (stringp initial) initial ""))
           (dialog-body
            (eabp-column
             (eabp-text (string-trim-right prompt "[ :]+") 'title)
             (eabp-text-input input-id
                              :label "Input"
                              :value (if (stringp initial) initial nil)
                              :on-submit (eabp-action "prompt.reply"
                                                      :args `((prompt_id . ,id))))
             (eabp-row
              (eabp-button "Cancel"
                           (eabp-action "prompt.dismiss"
                                        :args `((prompt_id . ,id)))
                           :variant "text")
              (eabp-spacer :width 8)
              (eabp-button "OK"
                           (eabp-action "prompt.reply"
                                        :args `((prompt_id . ,id))))))))
      (eabp-on-state-change input-id (lambda (val) (setq current-value val)))
      (eabp--send-prompt-dialog id dialog-body)
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (eabp--cleanup-prompt))))
        (if (eq reply 'cancelled)
            (keyboard-quit)
          (or reply current-value ""))))))

(advice-add 'read-from-minibuffer :around #'eabp--read-from-minibuffer-advice)

;; ─── Advice: read-string ─────────────────────────────────────────────────────
;;
;; `read-string' delegates to `read-from-minibuffer' in standard Emacs, so
;; the advice above already covers it.  We add an explicit advice anyway so
;; the interception is guaranteed even if a package replaces `read-string'.

(defun eabp--read-string-advice (orig-fn prompt &rest args)
  "Around advice for `read-string'."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((initial (nth 0 args)))
      (eabp--read-from-minibuffer-advice #'ignore prompt initial))))

(advice-add 'read-string :around #'eabp--read-string-advice)

;; ─── Advice: completing-read ─────────────────────────────────────────────────

(defun eabp-minibuffer--filter (candidates query)
  "Return CANDIDATES matching QUERY.
Every whitespace-separated token in QUERY must appear (case-insensitive
substring, orderless-style); candidates that QUERY is a prefix of are
sorted first."
  (if (or (null query) (string-empty-p query))
      candidates
    (let* ((tokens (split-string (downcase query) "[ \t]+" t))
           (matches (cl-remove-if-not
                     (lambda (c)
                       (let ((lc (downcase c)))
                         (cl-every (lambda (tok) (string-search tok lc)) tokens)))
                     candidates)))
      (cl-stable-sort
       matches
       (lambda (a b)
         (and (string-prefix-p query a t)
              (not (string-prefix-p query b t))))))))

(defun eabp--completing-read-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read': a live-filtering picker over the bridge.
As the user types in the filter field, the candidate list re-filters and
re-renders (vertico-style). Tapping a candidate, or pressing Done, replies."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (id (eabp--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           ;; `all-completions' handles every collection kind (list, obarray,
           ;; hash table, completion function) honouring PREDICATE.
           (candidates (ignore-errors
                         (sort (all-completions "" collection predicate) #'string<)))
           (max-display 50)
           (render
            (lambda (query)
              (let* ((matches (eabp-minibuffer--filter candidates query))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches))
                     (cards (mapcar
                             (lambda (c)
                               (eabp-card
                                (list (eabp-text c 'body))
                                :on-tap (eabp-action "prompt.reply"
                                                     :args `((prompt_id . ,id)
                                                             (value . ,c)))))
                             shown)))
                ;; A lazy (scrollable) column: long candidate lists scroll
                ;; instead of pushing everything below off-screen.  Cancel
                ;; sits in the header row so it is reachable regardless of
                ;; list length or scroll position.
                (apply #'eabp-lazy-column
                       (append
                        (list
                         (eabp-row
                          (eabp-box (list (eabp-text title 'title)) :weight 1)
                          (eabp-button "Cancel"
                                       (eabp-action "prompt.dismiss"
                                                    :args `((prompt_id . ,id)))
                                       :variant "text"))
                         ;; No :value — the field is uncontrolled after seeding
                         ;; so re-renders never stomp the user's text/cursor.
                         (eabp-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter…"
                                          :single-line t
                                          :on-submit (eabp-action
                                                      "prompt.reply"
                                                      :args `((prompt_id . ,id))))
                         (eabp-text (if (> total max-display)
                                        (format "%d matches · top %d shown" total max-display)
                                      (format "%d matches" total))
                                    'caption))
                        cards))))))
      ;; Re-render on every keystroke (runs during `eabp--wait-for-prompt's
      ;; event pump). Cleared after the wait so it can't leak.
      (eabp-on-state-change input-id
                            (lambda (val)
                              (eabp--send-prompt-dialog id (funcall render val))))
      (eabp--send-prompt-dialog id (funcall render ""))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (eabp--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         ;; A tapped candidate is exact; a typed query falls back to its top
         ;; match (RET-picks-top, like vertico) so partial input still works.
         ((and (stringp reply) (not (string-empty-p reply)))
          (if (member reply candidates)
              reply
            (or (car (eabp-minibuffer--filter candidates reply)) reply)))
         (t ""))))))

(advice-add 'completing-read :around #'eabp--completing-read-advice)

;; ─── Advice: read-char & read-char-exclusive ─────────────────────────────────

(defun eabp--read-char-advice (orig-fn prompt &rest args)
  "Around advice for `read-char' and `read-char-exclusive'.
Uses a text input dialog and returns the first character."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((reply (eabp--read-from-minibuffer-advice #'ignore prompt)))
      (if (and (stringp reply) (> (length reply) 0))
          (aref reply 0)
        (keyboard-quit)))))

(advice-add 'read-char :around #'eabp--read-char-advice)
(advice-add 'read-char-exclusive :around #'eabp--read-char-advice)

;; ─── Advice: read-char-choice ────────────────────────────────────────────────

(defun eabp--read-char-choice-advice (orig-fn prompt chars &rest args)
  "Around advice for `read-char-choice'.
Forces the user to select a valid character from CHARS."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt chars args)
    (catch 'done
      (while t
        (let* ((reply (eabp--read-from-minibuffer-advice #'ignore prompt))
               (char (when (and (stringp reply) (> (length reply) 0))
                       (aref reply 0))))
          (if (and char (memq char chars))
              (throw 'done char)
            (when (fboundp 'eabp-org-ui-snackbar)
              (eabp-org-ui-snackbar "Invalid choice. Please try again."))))))))

(advice-add 'read-char-choice :around #'eabp--read-char-choice-advice)

(provide 'eabp-minibuffer)
;;; eabp-minibuffer.el ends here
