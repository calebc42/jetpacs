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

;; ─── Advice: map-y-or-n-p ────────────────────────────────────────────────────
;;
;; `map-y-or-n-p' drives `save-some-buffers' and other batch confirmations.
;; It reads raw events via `read-event', which never arrive over the bridge —
;; so from the phone it HANGS forever (no dialog is ever shown, so the prompt
;; timeout can't even fire).  This is the freeze `magit-commit' hits: it runs
;; save-some-buffers before opening the message buffer.  We reimplement the
;; loop as one bridged dialog per object instead of feeding it events.

(defun eabp--map-y-or-n-p-advice (orig-fn prompter actor list &rest args)
  "Around advice for `map-y-or-n-p': one bridged dialog per object.
Returns the number of objects ACTOR was called on, matching the original.
LIST may be a list of objects or a generator function; PROMPTER may be a
format string or a function returning a string (ask), t (act silently)
or nil (skip silently)."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompter actor list args)
    (let* ((count 0)
           (all nil)              ; non-nil once "Yes to all" is chosen
           (done nil)             ; non-nil once "Quit"/dismiss stops the loop
           (next (if (functionp list)
                     list
                   (let ((remaining list))
                     (lambda () (when remaining (pop remaining))))))
           obj)
      (while (and (not done) (setq obj (funcall next)))
        (let ((p (cond ((functionp prompter) (funcall prompter obj))
                       ((stringp prompter) (format prompter obj))
                       (t (format "%s? " obj)))))
          (cond
           ;; PROMPTER may resolve to "act, don't ask" (t) or "skip" (nil).
           ((eq p t) (funcall actor obj) (setq count (1+ count)))
           ((null p) nil)
           ;; A prior "Yes to all" acts on every remaining object silently.
           (all (funcall actor obj) (setq count (1+ count)))
           (t
            (let* ((id (eabp--prompt-id))
                   (title (if (stringp p) (string-trim-right p "[ ?]+")
                            (format "%s" p)))
                   (body (eabp-column
                          (eabp-text title 'title)
                          (eabp-flow-row
                           (eabp-button
                            "Yes"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "y"))))
                           (eabp-button
                            "No"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "n")))
                            :variant "outlined")
                           (eabp-button
                            "Yes to all"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "all")))
                            :variant "outlined")
                           (eabp-button
                            "Quit"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "quit")))
                            :variant "text")))))
              (eabp--send-prompt-dialog id body)
              ;; `_' catches "quit", the `cancelled' symbol (dismiss/timeout),
              ;; and anything unexpected — all stop the loop.
              (pcase (unwind-protect (eabp--wait-for-prompt id)
                       (eabp--cleanup-prompt))
                ("y" (funcall actor obj) (setq count (1+ count)))
                ("n" nil)
                ("all" (setq all t) (funcall actor obj) (setq count (1+ count)))
                (_ (setq done t))))))))
      count)))

(advice-add 'map-y-or-n-p :around #'eabp--map-y-or-n-p-advice)

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

;; ─── Advice: read-passwd ─────────────────────────────────────────────────────
;;
;; `read-passwd' (TRAMP, GPG, auth-source) must NOT flow through the plaintext
;; `read-string' bridge: it needs a masked field, and the secret must not
;; linger in UI state.  We also intercept before the raw-event advice below,
;; since stock `read-passwd' reads keys directly.

(defun eabp--read-passwd-once (prompt)
  "Prompt for one masked secret over the bridge.
Returns the entered string, or the symbol `cancelled' on dismiss/timeout."
  (let* ((id (eabp--prompt-id))
         (input-id (format "prompt-pw-%s" id))
         (current ""))
    (eabp-on-state-change input-id (lambda (v) (setq current (or v ""))))
    ;; NOT `eabp--send-prompt-dialog': that prepends context-buffer cards, and
    ;; a passphrase prompt must never sit beside buffer contents.
    (eabp-send-dialog
     (eabp-column
      (eabp-text (string-trim-right prompt "[ :]+") 'title)
      (eabp-text-input input-id
                       :label "Password"
                       :single-line t
                       :password t
                       :on-submit (eabp-action "prompt.reply"
                                               :args `((prompt_id . ,id))))
      (eabp-row
       (eabp-button "Cancel"
                    (eabp-action "prompt.dismiss" :args `((prompt_id . ,id)))
                    :variant "text")
       (eabp-spacer :width 8)
       (eabp-button "OK"
                    (eabp-action "prompt.reply" :args `((prompt_id . ,id)))))))
    (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                   ;; Scrub every trace of the secret from handler state.
                   (remhash input-id eabp--state-handlers)
                   (remhash input-id eabp--ui-state)
                   (eabp--cleanup-prompt))))
      (if (eq reply 'cancelled) 'cancelled (or reply current "")))))

(defun eabp--read-passwd-advice (orig-fn prompt &rest args)
  "Around advice for `read-passwd': masked entry, secret never retained.
Honours CONFIRM (ARGS' first element) by prompting twice and comparing,
retrying up to three times before giving up with `keyboard-quit'."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((confirm (nth 0 args))
          (tries 0))
      (catch 'done
        (while t
          (let ((first (eabp--read-passwd-once prompt)))
            (when (eq first 'cancelled) (keyboard-quit))
            (if (not confirm)
                (throw 'done first)
              (let ((again (eabp--read-passwd-once
                            (if (stringp confirm) confirm "Confirm password: "))))
                (when (eq again 'cancelled) (keyboard-quit))
                (cond
                 ((equal first again) (throw 'done first))
                 ((>= (setq tries (1+ tries)) 3)
                  (eabp-send "toast.show" '((text . "Passwords didn't match")))
                  (keyboard-quit))
                 (t (eabp-send "toast.show"
                               '((text . "Passwords didn't match — try again")))))))))))))

(advice-add 'read-passwd :around #'eabp--read-passwd-advice)

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

(defun eabp-minibuffer--annotator (collection predicate)
  "An annotation function for COLLECTION's candidates, or nil.
Honours completion metadata and `completion-extra-properties', so
marginalia-style captions survive the bridge."
  (let* ((md (ignore-errors (completion-metadata "" collection predicate)))
         (annotf (or (and md (completion-metadata-get md 'annotation-function))
                     (plist-get completion-extra-properties
                                :annotation-function))))
    (when annotf
      (lambda (cand)
        (let ((a (ignore-errors (funcall annotf cand))))
          (when (stringp a)
            (let ((s (string-trim (substring-no-properties a))))
              (unless (string-empty-p s) s))))))))

(defun eabp--completing-read-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read': a live-filtering picker over the bridge.
As the user types in the filter field, the candidate list re-filters and
re-renders (vertico-style). Tapping a candidate, or pressing Done, replies.
Function collections (files, buffers, dynamic tables) re-complete against
the query each keystroke, so typing a path navigates directories."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (initial-arg (nth 2 args))   ; INITIAL-INPUT: STRING or (STRING . POS)
           ;; `read-file-name' passes its DIR here, so honouring it is what
           ;; makes a bridged file prompt open in the right directory.
           (initial (cond ((stringp initial-arg) initial-arg)
                          ((consp initial-arg) (car initial-arg))
                          (t "")))
           (def (nth 4 args))   ; (predicate require-match initial hist DEF …)
           (id (eabp--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           (dynamic (functionp collection))
           ;; Static collections snapshot once and get token filtering;
           ;; `all-completions' handles list/obarray/hash honouring PREDICATE.
           (candidates (unless dynamic
                         (ignore-errors
                           (sort (all-completions "" collection predicate)
                                 #'string<))))
           (annotate (eabp-minibuffer--annotator collection predicate))
           ;; (PREFIX . MATCHES) for QUERY.  PREFIX is the completion-
           ;; boundaries head (e.g. the directory part of a file name) that
           ;; rebuilds a full value from a returned candidate.
           (matches-for
            (lambda (query)
              (if dynamic
                  (let* ((q (or query ""))
                         (bounds (ignore-errors
                                   (completion-boundaries q collection
                                                          predicate "")))
                         (prefix (substring q 0 (or (car bounds) 0))))
                    (cons prefix
                          (ignore-errors
                            (sort (all-completions q collection predicate)
                                  #'string<))))
                (cons "" (eabp-minibuffer--filter candidates query)))))
           (max-display 50)
           (render
            (lambda (query &optional seed)
              (let* ((pm (funcall matches-for query))
                     (prefix (car pm))
                     (matches (cdr pm))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches))
                     (cards (mapcar
                             (lambda (c)
                               (let ((a (and annotate (funcall annotate c))))
                                 (eabp-card
                                  (list (if a
                                            (eabp-row
                                             (eabp-box (list (eabp-text c 'body))
                                                       :weight 1)
                                             (eabp-text a 'caption))
                                          (eabp-text c 'body)))
                                  :on-tap (eabp-action
                                           "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(concat prefix c)))))))
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
                         ;; :value only on the SEED (first) render, and only
                         ;; when there is initial input — after that the field
                         ;; is uncontrolled so re-renders never stomp the
                         ;; user's text/cursor (see the on-state-change below).
                         (eabp-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter…"
                                          :single-line t
                                          :value (and seed
                                                      (not (string-empty-p query))
                                                      query)
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
      ;; Seed the first render with INITIAL-INPUT: the field carries it as its
      ;; value, so an immediate submit returns it (like RET on initial input at
      ;; the keyboard) and the list is pre-filtered.  Clearing the field then
      ;; submitting is an explicit empty → DEF, so the empty branch is left
      ;; untouched.
      (eabp--send-prompt-dialog id (funcall render initial t))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (eabp--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         ;; A tapped candidate is exact; a typed query falls back to its top
         ;; match (RET-picks-top, like vertico) so partial input still works.
         ((and (stringp reply) (not (string-empty-p reply)))
          (cond
           (dynamic
            (if (ignore-errors (test-completion reply collection predicate))
                reply
              (let* ((pm (funcall matches-for reply))
                     (top (cadr pm)))
                (if top (concat (car pm) top) reply))))
           ((member reply candidates) reply)
           (t (or (car (eabp-minibuffer--filter candidates reply)) reply))))
         ;; Empty submit falls back to the caller's DEF, like RET at the
         ;; keyboard would.
         (t (or (and def (if (consp def) (car def) def)) "")))))))

(advice-add 'completing-read :around #'eabp--completing-read-advice)

;; ─── Advice: completing-read-multiple ────────────────────────────────────────
;;
;; CRM reads via `read-from-minibuffer' with a special keymap, so without
;; this it degrades to a bare comma-separated text input.  Bridge it as a
;; multi-select picker: tapping candidates toggles them, the filter's
;; submit adds free text (org tags), Done replies with the selection.

(defvar eabp--prompt-toggle-callbacks nil
  "Alist of prompt-id → callback for `prompt.toggle' actions.")

(eabp-defaction "prompt.toggle"
  (lambda (args _)
    (let* ((pid (alist-get 'prompt_id args))
           (fn (alist-get pid eabp--prompt-toggle-callbacks nil nil #'equal)))
      (when fn (funcall fn (alist-get 'value args))))))

(defun eabp--completing-read-multiple-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read-multiple': a multi-select picker."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (id (eabp--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           (candidates (ignore-errors
                         (sort (all-completions "" collection predicate)
                               #'string<)))
           (annotate (eabp-minibuffer--annotator collection predicate))
           (selected nil)
           (query "")
           (max-display 50)
           (render
            (lambda ()
              (let* ((matches (eabp-minibuffer--filter candidates query))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches)))
                (apply #'eabp-lazy-column
                       (append
                        (list
                         (eabp-row
                          (eabp-box (list (eabp-text title 'title)) :weight 1)
                          (eabp-button "Cancel"
                                       (eabp-action "prompt.dismiss"
                                                    :args `((prompt_id . ,id)))
                                       :variant "text")
                          (eabp-button (format "Done (%d)" (length selected))
                                       (eabp-action "prompt.reply"
                                                    :args `((prompt_id . ,id)
                                                            (value . ,(vconcat (reverse selected)))))))
                         (eabp-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter, submit to add"
                                          :single-line t
                                          :on-submit (eabp-action
                                                      "prompt.toggle"
                                                      :args `((prompt_id . ,id))))
                         (when selected
                           (apply #'eabp-flow-row
                                  (mapcar (lambda (s)
                                            (eabp-chip s :selected t
                                                       :on-tap (eabp-action
                                                                "prompt.toggle"
                                                                :args `((prompt_id . ,id)
                                                                        (value . ,s)))))
                                          (reverse selected))))
                         (eabp-text (format "%d matches" total) 'caption))
                        (mapcar
                         (lambda (c)
                           (let ((a (and annotate (funcall annotate c))))
                             (eabp-card
                              (list (if a
                                        (eabp-row
                                         (eabp-box (list (eabp-text c 'body))
                                                   :weight 1)
                                         (eabp-text a 'caption))
                                      (eabp-text c 'body)))
                              :on-tap (eabp-action "prompt.toggle"
                                                   :args `((prompt_id . ,id)
                                                           (value . ,c))))))
                         shown)))))))
      (setf (alist-get id eabp--prompt-toggle-callbacks nil nil #'equal)
            (lambda (val)
              (when (and (stringp val) (not (string-empty-p val)))
                (setq selected (if (member val selected)
                                   (delete val selected)
                                 (cons val selected)))
                (eabp--send-prompt-dialog id (funcall render)))))
      (eabp-on-state-change input-id
                            (lambda (val)
                              (setq query (or val ""))
                              (eabp--send-prompt-dialog id (funcall render))))
      (eabp--send-prompt-dialog id (funcall render))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (setq eabp--prompt-toggle-callbacks
                           (assoc-delete-all id eabp--prompt-toggle-callbacks))
                     (eabp--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         (t (cl-remove-if-not #'stringp (append reply nil))))))))

(advice-add 'completing-read-multiple :around #'eabp--completing-read-multiple-advice)

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

(defun eabp--char-buttons-dialog (id prompt buttons)
  "Show a dialog of PROMPT text plus BUTTONS, with a Cancel row."
  (eabp--send-prompt-dialog
   id
   (eabp-column
    (eabp-text prompt 'body)
    (apply #'eabp-flow-row buttons)
    (eabp-row
     (eabp-spacer :weight 1)
     (eabp-button "Cancel"
                  (eabp-action "prompt.dismiss" :args `((prompt_id . ,id)))
                  :variant "text")))))

(defun eabp--read-char-choice-advice (orig-fn prompt chars &rest args)
  "Around advice for `read-char-choice': each valid char is a button.
The prompt text usually explains the choices ([y]es [n]o …), so it is
shown in full above the buttons; only valid chars can come back."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt chars args)
    (let* ((id (eabp--prompt-id))
           (chars (append chars nil)))
      (eabp--char-buttons-dialog
       id prompt
       (mapcar (lambda (ch)
                 (eabp-button (char-to-string ch)
                              (eabp-action "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(char-to-string ch))))
                              :variant "outlined"))
               chars))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (if (and (stringp reply) (> (length reply) 0)
                 (memq (aref reply 0) chars))
            (aref reply 0)
          (keyboard-quit))))))

(advice-add 'read-char-choice :around #'eabp--read-char-choice-advice)

;; ─── Advice: read-multiple-choice ────────────────────────────────────────────

(defun eabp--read-multiple-choice-advice (orig-fn prompt choices &rest args)
  "Around advice for `read-multiple-choice'.
CHOICES are (CHAR NAME [DESC]); the names become buttons, and the full
chosen entry is returned as the original would."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt choices args)
    (let ((id (eabp--prompt-id)))
      (eabp--char-buttons-dialog
       id prompt
       (mapcar (lambda (choice)
                 (eabp-button (capitalize (cadr choice))
                              (eabp-action "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(char-to-string (car choice)))))
                              :variant "outlined"))
               choices))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (or (and (stringp reply) (> (length reply) 0)
                 (assq (aref reply 0) choices))
            (keyboard-quit))))))

(advice-add 'read-multiple-choice :around #'eabp--read-multiple-choice-advice)

;; ─── Advice: read-char-from-minibuffer ───────────────────────────────────────
;;
;; Modern core reads single-char answers here (it echoes in the minibuffer
;; and, unlike `read-char', accepts an allowlist).  Without this the fallback
;; would be a free-text box; with a CHARS allowlist it becomes buttons.

(defun eabp--read-char-from-minibuffer-advice (orig-fn prompt &rest args)
  "Around advice for `read-char-from-minibuffer'.
With a CHARS allowlist (ARGS' first element) render each as a button via
the char-choice bridge; otherwise a single-char text prompt."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((chars (nth 0 args)))
      (if chars
          (eabp--read-char-choice-advice #'ignore prompt chars)
        (eabp--read-char-advice #'ignore prompt)))))

(when (fboundp 'read-char-from-minibuffer)
  (advice-add 'read-char-from-minibuffer :around
              #'eabp--read-char-from-minibuffer-advice))

;; ─── Advice: read-answer ─────────────────────────────────────────────────────
;;
;; `read-answer' backs the long-form "y, n, or q" prompts an increasing share
;; of core uses.  ANSWERS is (LONG-ANSWER CHAR HELP …); render a button per
;; entry and return the chosen LONG-ANSWER string (the function's contract).

(defun eabp--read-answer-advice (orig-fn question answers &rest _)
  "Around advice for `read-answer': one button per answer."
  (if (not eabp--in-action-handler)
      (funcall orig-fn question answers)
    (let ((id (eabp--prompt-id)))
      (eabp--char-buttons-dialog
       id question
       (mapcar (lambda (a)
                 (let ((long (car a)))
                   (eabp-button (capitalize long)
                                (eabp-action "prompt.reply"
                                             :args `((prompt_id . ,id)
                                                     (value . ,long)))
                                :variant "outlined")))
               answers))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (if (and (stringp reply) (assoc reply answers))
            reply
          (keyboard-quit))))))

(when (fboundp 'read-answer)
  (advice-add 'read-answer :around #'eabp--read-answer-advice))

;; ─── Advice: raw event readers ───────────────────────────────────────────────
;;
;; `read-event', `read-key', `read-key-sequence' and its -vector sibling read
;; keyboard events directly, bypassing every prompt bridge above.  From the
;; phone they HANG.  `query-replace' (via `perform-replace') and any command
;; that reads a single keystroke land here.  We can't render an arbitrary key
;; event as a dialog cleanly, so this is deliberately crude: turn the read
;; into an answerable text prompt (a key description like "y" or "C-c"), and
;; if it can't be answered, `keyboard-quit' rather than block forever.

(defun eabp--raw-event-should-bridge-p (&optional seconds)
  "Non-nil when a raw-event read should be bridged rather than run natively.
Bridges only inside an action handler, and never when events are already
available — a running keyboard macro (`eabp-keymap--execute-key' drives
commands through `execute-kbd-macro'), queued `unread-command-events', or a
timed read (SECONDS non-nil, i.e. `read-event' used as a sleep)."
  (and eabp--in-action-handler
       (not executing-kbd-macro)
       (not unread-command-events)
       (not seconds)))

(defun eabp--bridge-key-prompt (prompt)
  "Prompt the phone for a key description and return it parsed, or quit.
Returns the `kbd' result (a string or vector), or signals `quit' when the
reply is empty or unparseable."
  (let ((reply (eabp--read-from-minibuffer-advice
                #'ignore (or (and (stringp prompt) prompt)
                             "Key input expected: "))))
    (if (and (stringp reply) (not (string-empty-p reply)))
        (let ((keys (ignore-errors (kbd reply))))
          (if (and keys (> (length keys) 0)) keys (keyboard-quit)))
      (keyboard-quit))))

(defun eabp--read-event-advice (orig-fn &rest args)
  "Around advice for `read-event'/`read-key': bridge or degrade, never hang.
Returns the first event of the parsed key description."
  ;; read-event: (&optional PROMPT INHERIT-INPUT-METHOD SECONDS).
  ;; read-key:   (&optional PROMPT) — nth 2 is simply nil.
  (if (not (eabp--raw-event-should-bridge-p (nth 2 args)))
      (apply orig-fn args)
    (aref (eabp--bridge-key-prompt (nth 0 args)) 0)))

(advice-add 'read-event :around #'eabp--read-event-advice)
(advice-add 'read-key :around #'eabp--read-event-advice)

(defun eabp--read-key-sequence-advice (orig-fn &rest args)
  "Around advice for `read-key-sequence': return the parsed sequence."
  (if (not (eabp--raw-event-should-bridge-p))
      (apply orig-fn args)
    (eabp--bridge-key-prompt (or (nth 0 args) "Key sequence: "))))

(defun eabp--read-key-sequence-vector-advice (orig-fn &rest args)
  "Around advice for `read-key-sequence-vector': parsed sequence as a vector."
  (if (not (eabp--raw-event-should-bridge-p))
      (apply orig-fn args)
    (let ((keys (eabp--bridge-key-prompt (or (nth 0 args) "Key sequence: "))))
      (if (vectorp keys) keys (vconcat keys)))))

(advice-add 'read-key-sequence :around #'eabp--read-key-sequence-advice)
(advice-add 'read-key-sequence-vector :around #'eabp--read-key-sequence-vector-advice)

(provide 'eabp-minibuffer)
;;; eabp-minibuffer.el ends here
