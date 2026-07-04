;;; eabp-primitives-test.el --- Emacs-primitive coverage gauntlet -*- lexical-binding: t; -*-

;; Regression net for the primitive-completeness work
;; (docs/PLAN-primitive-completeness.md).  Each fix there lands a test
;; here, so "primitive X is covered" is asserted, not assumed.
;;
;; Run from the repo root (any Emacs 28+):
;;   emacs -Q --batch -l test/eabp-primitives-test.el -f ert-run-tests-batch-and-exit
;;
;; Currently covers P0 (the hang fixes): map-y-or-n-p, the raw event
;; readers, and the with-editor commit-message splice.  Later phases append.

;;; Code:

(defvar eabp-primitives-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(add-to-list 'load-path (expand-file-name "../emacs/core" eabp-primitives-test--dir))

(require 'ert)
(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-minibuffer)
(require 'eabp-shell)
(require 'eabp-witheditor)
(require 'eabp-buffer)
(require 'eabp-emacs-ui)
(require 'eabp-keymap)
(require 'eabp-transient)

;; ─── Bridge harness ──────────────────────────────────────────────────────────

(defvar eabp-prim--replies nil
  "Queue of values returned by successive stubbed `eabp--wait-for-prompt'.")
(defvar eabp-prim--sent nil
  "Dialog bodies captured by the stubbed senders, newest first.")

(defmacro eabp-prim--with-bridge (replies &rest body)
  "Run BODY as if inside an action handler with prompts stubbed.
REPLIES seeds the values `eabp--wait-for-prompt' returns in order; dialog
sends are captured into `eabp-prim--sent'."
  (declare (indent 1))
  `(let ((eabp--in-action-handler t)
         (eabp-prim--replies ,replies)
         (eabp-prim--sent nil))
     (cl-letf (((symbol-function 'eabp--send-prompt-dialog)
                (lambda (_id body) (push body eabp-prim--sent)))
               ((symbol-function 'eabp-send-dialog)
                (lambda (body) (push body eabp-prim--sent)))
               ((symbol-function 'eabp--wait-for-prompt)
                (lambda (_id) (pop eabp-prim--replies)))
               ((symbol-function 'eabp--cleanup-prompt) #'ignore)
               ((symbol-function 'eabp-dismiss-dialog) #'ignore))
       ,@body)))

;; ─── Task 1: map-y-or-n-p ────────────────────────────────────────────────────

(ert-deftest eabp-prim-map-y-or-n-p-mixed ()
  "Yes acts, No skips; the return count is the number of ACTOR calls."
  (let (acted)
    (eabp-prim--with-bridge (list "y" "n" "y")
      (should (= 2 (map-y-or-n-p "Save %s? "
                                 (lambda (x) (push x acted))
                                 '(a b c)))))
    (should (equal acted '(c a)))))

(ert-deftest eabp-prim-map-y-or-n-p-yes-to-all ()
  "\"Yes to all\" acts on every remaining object with no further prompts."
  (let (acted)
    (eabp-prim--with-bridge (list "all")   ; a single reply for three objects
      (should (= 3 (map-y-or-n-p "Save %s? "
                                 (lambda (x) (push x acted))
                                 '(a b c)))))
    (should (equal acted '(c b a)))))

(ert-deftest eabp-prim-map-y-or-n-p-quit ()
  "Quit stops the loop; remaining objects are skipped."
  (let (acted)
    (eabp-prim--with-bridge (list "y" "quit")
      (should (= 1 (map-y-or-n-p "Save %s? "
                                 (lambda (x) (push x acted))
                                 '(a b c)))))
    (should (equal acted '(a)))))

(ert-deftest eabp-prim-map-y-or-n-p-cancel-stops ()
  "A dismissed/timed-out dialog (the `cancelled' symbol) stops the loop."
  (eabp-prim--with-bridge (list 'cancelled)
    (should (= 0 (map-y-or-n-p "Save %s? " #'identity '(a b))))))

(ert-deftest eabp-prim-map-y-or-n-p-generator ()
  "A generator-function LIST is consumed until it returns nil."
  (let ((items '(a b)) acted)
    (eabp-prim--with-bridge (list "y" "y")
      (should (= 2 (map-y-or-n-p "Save %s? "
                                 (lambda (x) (push x acted))
                                 (lambda () (pop items))))))
    (should (equal acted '(b a)))))

(ert-deftest eabp-prim-map-y-or-n-p-passthrough ()
  "Outside an action handler the advice delegates to the original."
  (let ((eabp--in-action-handler nil))
    (should (= 42 (eabp--map-y-or-n-p-advice
                   (lambda (&rest _) 42) "P %s?" #'identity '(a))))))

(ert-deftest eabp-prim-map-y-or-n-p-prompter-contract ()
  "A function PROMPTER's non-string truthy return acts silently; nil skips.
Matches subr.el: only a STRING return actually asks."
  (let (acted)
    (eabp-prim--with-bridge nil        ; no replies: nothing may ask
      (should (= 2 (map-y-or-n-p
                    (lambda (x) (if (eq x 'skip-me) nil 'act)) ; truthy ≠ t
                    (lambda (x) (push x acted))
                    '(a skip-me b))))
      (should-not eabp-prim--sent))    ; no dialog was ever sent
    (should (equal acted '(b a)))))

;; ─── Task 2: raw event readers ───────────────────────────────────────────────

(ert-deftest eabp-prim-read-event-bridges ()
  "`read-event' inside a handler returns the parsed key's first event."
  (eabp-prim--with-bridge (list "y")
    (should (equal ?y (read-event "Press: ")))))

(ert-deftest eabp-prim-read-key-sequence-bridges ()
  "`read-key-sequence' returns the parsed key description."
  (eabp-prim--with-bridge (list "C-c")
    (should (equal (kbd "C-c") (read-key-sequence "Seq: ")))))

(ert-deftest eabp-prim-read-key-sequence-vector-bridges ()
  "`read-key-sequence-vector' coerces the parsed description to a vector."
  (eabp-prim--with-bridge (list "a")
    (should (vectorp (read-key-sequence-vector "Seq: ")))))

(ert-deftest eabp-prim-read-event-cancel-quits ()
  "An empty reply degrades to `keyboard-quit' rather than hanging."
  (eabp-prim--with-bridge (list "")
    (should (eq 'quit (condition-case nil
                          (progn (read-event "Press: ") 'no-quit)
                        (quit 'quit))))))

(ert-deftest eabp-prim-raw-event-guards ()
  "The bridge predicate is off outside handlers, during macros, and for sleeps."
  (should-not (let ((eabp--in-action-handler nil))
                (eabp--raw-event-should-bridge-p)))
  (should-not (let ((eabp--in-action-handler t) (executing-kbd-macro [?x]))
                (eabp--raw-event-should-bridge-p)))
  (should-not (let ((eabp--in-action-handler t) (unread-command-events '(?x)))
                (eabp--raw-event-should-bridge-p)))
  (should-not (let ((eabp--in-action-handler t))
                (eabp--raw-event-should-bridge-p 0.5)))   ; SECONDS = a sleep
  (should (let ((eabp--in-action-handler t)
                (executing-kbd-macro nil) (unread-command-events nil))
            (eabp--raw-event-should-bridge-p))))

;; ─── Task 3: with-editor message splice ──────────────────────────────────────

(ert-deftest eabp-prim-witheditor-message-region ()
  "The message region stops at the first git comment line."
  (with-temp-buffer
    (insert "My subject\n\nBody line\n"
            "# Please enter the commit message for your changes.\n"
            "# On branch main\n")
    (let ((r (eabp-witheditor--message-region)))
      (should (equal (buffer-substring-no-properties (car r) (cdr r))
                     "My subject\n\nBody line\n")))
    (should (equal (eabp-witheditor--current-message)
                   "My subject\n\nBody line"))))

(ert-deftest eabp-prim-witheditor-splice-preserves-comments ()
  "Finishing replaces only the message, leaving the comment tail intact."
  (with-temp-buffer
    (insert "old subject\n\n# comment one\n# comment two\n")
    ;; Mirror the finish handler's splice.
    (let ((r (eabp-witheditor--message-region)))
      (delete-region (car r) (cdr r))
      (goto-char (point-min))
      (insert "new subject" "\n"))
    (should (equal (buffer-string)
                   "new subject\n# comment one\n# comment two\n"))))

(ert-deftest eabp-prim-witheditor-no-comments ()
  "With no comment tail the whole buffer is the message region."
  (with-temp-buffer
    (insert "just a message\n")
    (let ((r (eabp-witheditor--message-region)))
      (should (= (cdr r) (point-max))))
    (should (equal (eabp-witheditor--current-message) "just a message"))))

(ert-deftest eabp-prim-witheditor-phone-initiated-gate ()
  "The bridge fires only for sessions started near a phone action.
A desktop commit (no recent action) must not pop a dialog on the phone."
  (let (presented (eabp-witheditor--active nil))
    (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
              ((symbol-function 'eabp-witheditor--present)
               (lambda (buf) (setq presented buf))))
      ;; Desktop-initiated: last action long ago → no bridge.
      (with-temp-buffer
        (set (make-local-variable 'with-editor-mode) t)
        (let ((eabp--in-action-handler nil)
              (eabp--last-action-time 0))
          (eabp-witheditor--maybe-bridge))
        (should-not presented))
      ;; Phone-initiated: a fresh action → bridge, exactly once.
      (with-temp-buffer
        (set (make-local-variable 'with-editor-mode) t)
        (let ((eabp--in-action-handler nil)
              (eabp--last-action-time (float-time)))
          (eabp-witheditor--maybe-bridge)
          (should (eq presented (current-buffer)))
          (setq presented nil)
          (eabp-witheditor--maybe-bridge)   ; double-fire guard
          (should-not presented))))))

(ert-deftest eabp-prim-witheditor-session-ended-dismisses ()
  "An externally finished session dismisses the dialog once, then no-ops."
  (let ((dismissals 0)
        (eabp-witheditor--active "COMMIT_EDITMSG"))
    (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
              ((symbol-function 'eabp-dismiss-dialog)
               (lambda () (setq dismissals (1+ dismissals)))))
      (eabp-witheditor--session-ended)
      (should (= dismissals 1))
      (should-not eabp-witheditor--active)
      (eabp-witheditor--session-ended)     ; already cleared → no-op
      (should (= dismissals 1)))))

;; ─── Node-tree search (for inspecting captured dialog specs) ─────────────────

(defun eabp-prim--find-node (spec type)
  "Depth-first: the first node in SPEC whose `t' discriminator is TYPE."
  (cond
   ((and (consp spec) (equal (alist-get 't spec) type)) spec)
   ((consp spec)
    (cl-some (lambda (kv)
               (let ((v (cdr kv)))
                 (cond ((vectorp v)
                        (cl-some (lambda (e) (eabp-prim--find-node e type)) v))
                       ((consp v) (eabp-prim--find-node v type)))))
             spec))
   (t nil)))

;; ─── Task 4/8: prompt-redirection binding in eabp--on-action ─────────────────

(ert-deftest eabp-prim-on-action-binds-redirection ()
  "Handlers run with completion redirection pinned to the built-ins."
  (let (seen)
    (eabp-defaction "eabp-prim-probe"
      (lambda (_ _)
        (setq seen (list completing-read-function
                         read-file-name-function
                         read-buffer-function
                         disabled-command-function))))
    (unwind-protect
        (progn
          (eabp--on-action '((action . "eabp-prim-probe")) nil)
          (should (equal seen (list #'completing-read-default
                                    #'read-file-name-default
                                    nil nil))))
      (remhash "eabp-prim-probe" eabp-action-handlers))))

;; ─── Task 5: completing-read honours INITIAL-INPUT ───────────────────────────

(ert-deftest eabp-prim-completing-read-seeds-initial ()
  "INITIAL-INPUT seeds the filter field's value on the first render."
  (eabp-prim--with-bridge (list "reply")
    (ignore-errors
      (completing-read "Pick: " '("alpha" "beta") nil nil "al"))
    (let* ((first (car (last eabp-prim--sent)))
           (field (eabp-prim--find-node first "text_input")))
      (should field)
      (should (equal (alist-get 'value field) "al")))))

(ert-deftest eabp-prim-completing-read-no-seed-when-empty ()
  "With no INITIAL-INPUT the filter field stays uncontrolled (no value)."
  (eabp-prim--with-bridge (list "reply")
    (ignore-errors
      (completing-read "Pick: " '("alpha" "beta")))
    (let* ((first (car (last eabp-prim--sent)))
           (field (eabp-prim--find-node first "text_input")))
      (should field)
      (should-not (alist-get 'value field)))))

;; ─── Task 6: read-passwd masks and scrubs ────────────────────────────────────

(ert-deftest eabp-prim-read-passwd-masks-and-scrubs ()
  "The passphrase field is masked and its id is left in no handler state."
  (let (field-id)
    (eabp-prim--with-bridge (list "s3cret")
      (should (equal "s3cret" (read-passwd "Pass: ")))
      (let* ((spec (car (last eabp-prim--sent)))
             (field (eabp-prim--find-node spec "text_input")))
        (should field)
        (should (eq t (alist-get 'password field)))
        (setq field-id (alist-get 'id field))))
    (should-not (gethash field-id eabp--ui-state))
    (should-not (gethash field-id eabp--state-handlers))))

(ert-deftest eabp-prim-read-passwd-confirm-mismatch ()
  "CONFIRM prompts twice; a persistent mismatch degrades to quit, not hang."
  (eabp-prim--with-bridge (list "a" "b" "a" "b" "a" "b")
    (should (eq 'quit (condition-case nil
                          (progn (read-passwd "Pass: " t) 'no-quit)
                        (quit 'quit))))))

;; ─── Task 7: read-answer / read-char-from-minibuffer ─────────────────────────

(ert-deftest eabp-prim-read-answer-returns-long ()
  "`read-answer' returns the chosen answer's long string."
  (skip-unless (fboundp 'read-answer))
  (eabp-prim--with-bridge (list "yes")
    (should (equal "yes"
                   (read-answer "Proceed? "
                                '(("yes" ?y "do it") ("no" ?n "don't")))))))

(ert-deftest eabp-prim-read-char-from-minibuffer-buttons ()
  "`read-char-from-minibuffer' with a CHARS allowlist returns the chosen char."
  (skip-unless (fboundp 'read-char-from-minibuffer))
  (eabp-prim--with-bridge (list "b")
    (should (equal ?b (read-char-from-minibuffer "Pick: " '(?a ?b ?c))))))

;; ─── P2: Tier 0 renderer fidelity ────────────────────────────────────────────

(defun eabp-prim--all-spans (nodes)
  "Flatten every span alist out of rendered NODES (a rich_text list)."
  (let (spans)
    (dolist (n nodes)
      (when (equal (alist-get 't n) "rich_text")
        (setq spans (append spans (append (alist-get 'spans n) nil)))))
    spans))

(defun eabp-prim--span-text (spans)
  "The concatenated text of SPANS."
  (mapconcat (lambda (s) (or (alist-get 'text s) "")) spans ""))

;; Task 11: face :background → span bg
(ert-deftest eabp-prim-buffer-background-span ()
  "A background-only face yields a span with `bg' and no `color'."
  (with-temp-buffer
    (insert "shaded")
    (put-text-property (point-min) (point-max) 'face '(:background "#FF0000"))
    (let ((s (car (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))
      (should (equal (alist-get 'bg s) "#FF0000"))
      (should-not (alist-get 'color s)))))

;; Task 13.1: font-lock-face fallback
(ert-deftest eabp-prim-buffer-font-lock-face-fallback ()
  "`font-lock-face' is honoured when `face' is absent."
  (with-temp-buffer
    (insert "kw")
    (put-text-property (point-min) (point-max) 'font-lock-face '(:weight bold))
    (let ((s (car (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))
      (should (eq t (alist-get 'bold s))))))

;; Task 13.4: anonymous face plist :inherit
(ert-deftest eabp-prim-buffer-anon-inherit ()
  "An anonymous face plist resolves attributes through `:inherit'."
  (with-temp-buffer
    (insert "inh")
    (put-text-property (point-min) (point-max) 'face '(:inherit bold))
    (let ((s (car (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))
      (should (eq t (alist-get 'bold s))))))

;; Task 12: line-prefix
(ert-deftest eabp-prim-buffer-line-prefix ()
  "A string `line-prefix' is prepended as a gutter span."
  (with-temp-buffer
    (insert "content")
    (put-text-property (point-min) (point-max) 'line-prefix "»» ")
    (let ((spans (eabp-prim--all-spans (eabp-buffer-render (current-buffer)))))
      (should (equal (alist-get 'text (car spans)) "»» ")))))

;; Task 13.2: tab expansion
(ert-deftest eabp-prim-buffer-tab-expansion ()
  "TABs expand to spaces on `tab-width' stops."
  (with-temp-buffer
    (setq tab-width 4)
    (insert "a\tb")
    (let ((text (eabp-prim--span-text
                 (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))
      (should (equal text "a   b")))))

;; Task 13.3: form feed → divider
(ert-deftest eabp-prim-buffer-form-feed-divider ()
  "A form-feed line renders as a divider node."
  (with-temp-buffer
    (insert "before\n\f\nafter")
    (let ((nodes (eabp-buffer-render (current-buffer))))
      (should (cl-some (lambda (n) (equal (alist-get 't n) "divider")) nodes)))))

;; Task 9: overlay before/after strings
(ert-deftest eabp-prim-buffer-overlay-before-string ()
  "An overlay `before-string' is spliced in at the overlay start."
  (with-temp-buffer
    (insert "line")
    (overlay-put (make-overlay (point-min) (point-min)) 'before-string "PRE")
    (should (string-prefix-p
             "PRE" (eabp-prim--span-text
                    (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))))

(ert-deftest eabp-prim-buffer-overlay-after-string ()
  "An overlay `after-string' is spliced in at the overlay end."
  (with-temp-buffer
    (insert "line")
    (overlay-put (make-overlay (point-max) (point-max)) 'after-string "POST")
    (should (string-suffix-p
             "POST" (eabp-prim--span-text
                     (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))))

;; Task 10: display space spec
(ert-deftest eabp-prim-buffer-display-space ()
  "A `(space :width N)' display spec becomes N spaces."
  (with-temp-buffer
    (insert "ab")
    (put-text-property 1 2 'display '(space :width 4))
    (should (equal "    b"
                   (eabp-prim--span-text
                    (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))))

;; Offscreen display specs (magit's "fringe" and "o" placeholders)
(ert-deftest eabp-prim-buffer-fringe-placeholder-dropped ()
  "An overlay before-string carrying a fringe display spec renders nothing.
Magit's section indicators are (propertize \"fringe\" \\='display
\\='(left-fringe BITMAP FACE)) — the literal text must never leak."
  (with-temp-buffer
    (insert "Untracked files (13)")
    (overlay-put (make-overlay (point-min) (point-min))
                 'before-string
                 (propertize "fringe" 'display '(left-fringe right-triangle)))
    (should (equal "Untracked files (13)"
                   (eabp-prim--span-text
                    (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))))

(ert-deftest eabp-prim-buffer-margin-placeholder-dropped ()
  "An overlay before-string with a margin display spec renders nothing.
Magit's margin overlays are (propertize \"o\" \\='display
\\='((margin right-margin) DATE)) anchored mid-line."
  (with-temp-buffer
    (insert "Recent commits")
    ;; Anchored mid-word, as magit-make-margin-overlay does (at point).
    (overlay-put (make-overlay 2 2)
                 'before-string
                 (propertize "o" 'display '((margin right-margin) "3 days")))
    (should (equal "Recent commits"
                   (eabp-prim--span-text
                    (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))))

(ert-deftest eabp-prim-buffer-margin-textprop-dropped ()
  "A margin display spec as a TEXT property also drops its covered text."
  (with-temp-buffer
    (insert "xY")
    (put-text-property 2 3 'display '((margin right-margin) "hidden"))
    (should (equal "x"
                   (eabp-prim--span-text
                    (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))))

(ert-deftest eabp-prim-buffer-folded-line-with-margin-overlay-dropped ()
  "A fully-invisible line still disappears despite a margin placeholder.
The collapsed magit commit lines must not render as lone \"o\" rows."
  (with-temp-buffer
    (insert "visible\nhidden line\n")
    (put-text-property 9 21 'invisible t)     ; "hidden line" + newline
    (overlay-put (make-overlay 9 9)
                 'before-string
                 (propertize "o" 'display '((margin right-margin) "date")))
    (let ((nodes (eabp-buffer-render (current-buffer))))
      ;; Only the "visible" line renders (plus possibly a trailing blank).
      (should-not (string-match-p
                   "o" (eabp-prim--span-text (eabp-prim--all-spans nodes)))))))

;; ─── P3: liveness ────────────────────────────────────────────────────────────

;; Task 14: live re-push for self-updating buffers
(ert-deftest eabp-prim-live-refresh-pushes-on-change ()
  "The watch re-pushes when the viewed buffer changes, and only then; and
navigating away tears the watch down."
  (let ((pushes 0)
        (eabp-emacs-ui-live-refresh t)
        (eabp-emacs-ui--viewing-buffer nil)
        (eabp-emacs-ui--live-timer nil)
        (eabp-emacs-ui--live-buffer nil)
        (eabp-emacs-ui--live-tick nil))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*eabp-live-test*" t)
          (insert "start\n")
          (setq eabp-emacs-ui--viewing-buffer (buffer-name))
          (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
                    ((symbol-function 'eabp-shell-push)
                     (lambda (&rest _) (setq pushes (1+ pushes)))))
            (eabp-emacs-ui--reconcile-live-watch)
            (should (timerp eabp-emacs-ui--live-timer))
            ;; No change yet: a poll pushes nothing.
            (eabp-emacs-ui--live-poll)
            (should (= pushes 0))
            ;; A change: the next poll pushes exactly once.
            (insert "more\n")
            (eabp-emacs-ui--live-poll)
            (should (= pushes 1))
            ;; Still no new change: no extra push.
            (eabp-emacs-ui--live-poll)
            (should (= pushes 1))
            ;; Navigating away stops the watch.
            (setq eabp-emacs-ui--viewing-buffer nil)
            (eabp-emacs-ui--live-poll)
            (should-not eabp-emacs-ui--live-timer)))
      (eabp-emacs-ui--live-stop))))

(ert-deftest eabp-prim-live-refresh-stops-when-disconnected ()
  "A disconnected poll tears the watch down instead of pushing."
  (let ((pushes 0)
        (eabp-emacs-ui-live-refresh t)
        (eabp-emacs-ui--viewing-buffer "*eabp-live-test2*")
        (eabp-emacs-ui--live-timer nil)
        (eabp-emacs-ui--live-buffer nil)
        (eabp-emacs-ui--live-tick nil))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*eabp-live-test2*" t)
          (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
                    ((symbol-function 'eabp-shell-push)
                     (lambda (&rest _) (setq pushes (1+ pushes)))))
            (eabp-emacs-ui--reconcile-live-watch)
            (should (timerp eabp-emacs-ui--live-timer)))
          ;; Drop the connection: the next poll stops, pushes nothing.
          (cl-letf (((symbol-function 'eabp-connected-p) (lambda () nil)))
            (eabp-emacs-ui--live-poll))
          (should-not eabp-emacs-ui--live-timer)
          (should (= pushes 0)))
      (eabp-emacs-ui--live-stop))))

;; ─── P4: discovery & picker polish ───────────────────────────────────────────

(defun eabp-prim--find-all (spec type)
  "Every node in SPEC whose `t' discriminator is TYPE, depth-first."
  (let (acc)
    (cl-labels ((walk (x)
                  (when (consp x)
                    (when (equal (alist-get 't x) type) (push x acc))
                    (dolist (kv x)
                      (let ((v (cdr kv)))
                        (cond ((vectorp v) (mapc #'walk (append v nil)))
                              ((consp v) (walk v))))))))
      (walk spec))
    (nreverse acc)))

(defun eabp-prim--menu-cmd () "Throwaway command for menu tests." (interactive) 'ok)

;; Task 16: menu-bar mining
(ert-deftest eabp-prim-menu-candidates ()
  "Menu items become breadcrumb-labeled, help-annotated command entries;
disabled items are excluded."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map [menu-bar mymenu]
        (cons "MyMenu" (make-sparse-keymap "MyMenu")))
      (define-key map [menu-bar mymenu greet]
        '(menu-item "Greet" eabp-prim--menu-cmd :help "Say hi"))
      (define-key map [menu-bar mymenu nope]
        '(menu-item "Nope" eabp-prim--menu-cmd :enable nil))
      (use-local-map map)
      (let* ((cands (eabp-keymap--menu-candidates (current-buffer)))
             (greet (cl-find-if (lambda (c) (string-match-p "Greet" (car c))) cands)))
        (should greet)
        (should (string-match-p "MyMenu ▸ Greet — Say hi" (car greet)))
        (should (equal (cdr greet) '(command . eabp-prim--menu-cmd)))
        ;; The :enable nil item is dropped (and the command deduped anyway).
        (should-not (cl-some (lambda (c) (string-match-p "Nope" (car c))) cands))))))

;; Task 17: affixation-function + group-function
(ert-deftest eabp-prim-picker-affixation-and-groups ()
  "The picker renders affixation prefixes/suffixes and group headers."
  (let* ((items '("alpha" "beta" "gamma"))
         (collection
          (lambda (str pred action)
            (if (eq action 'metadata)
                '(metadata
                  (affixation-function
                   . (lambda (cs)
                       (mapcar (lambda (c) (list c "» " (concat " [" c "]"))) cs)))
                  (group-function
                   . (lambda (c transform)
                       (if transform c (if (string< c "c") "First" "Second")))))
              (complete-with-action action items str pred)))))
    (eabp-prim--with-bridge (list "reply")
      (ignore-errors (completing-read "Pick: " collection))
      (let* ((spec (car (last eabp-prim--sent)))
             (headers (mapcar (lambda (n) (alist-get 'title n))
                              (eabp-prim--find-all spec "section_header")))
             (texts (mapcar (lambda (n) (alist-get 'text n))
                            (eabp-prim--find-all spec "text"))))
        (should (member "First" headers))
        (should (member "Second" headers))
        (should (member "» alpha" texts))     ; affixation prefix prepended
        (should (member "[alpha]" texts))))))  ; suffix as caption

;; ─── P5: gauntlet — pre-existing prompt bridges ──────────────────────────────
;;
;; The advices below predate this plan, but the gauntlet asserts every bridged
;; primitive, so a regression in any of them fails a test rather than the app.

(ert-deftest eabp-prim-y-or-n-p ()
  "`y-or-n-p' returns t for yes and nil for no/cancel."
  (eabp-prim--with-bridge (list t)
    (should (eq t (y-or-n-p "OK? "))))
  (eabp-prim--with-bridge (list :false)
    (should (eq nil (y-or-n-p "OK? "))))
  (eabp-prim--with-bridge (list 'cancelled)
    (should (eq nil (y-or-n-p "OK? ")))))

(ert-deftest eabp-prim-yes-or-no-p ()
  "`yes-or-no-p' shares the y-or-n-p bridge."
  (eabp-prim--with-bridge (list t)
    (should (eq t (yes-or-no-p "Sure? ")))))

(ert-deftest eabp-prim-read-from-minibuffer ()
  "`read-from-minibuffer'/`read-string' return the typed value."
  (eabp-prim--with-bridge (list "hello")
    (should (equal "hello" (read-from-minibuffer "Name: "))))
  (eabp-prim--with-bridge (list "hi")
    (should (equal "hi" (read-string "S: ")))))

(ert-deftest eabp-prim-read-char ()
  "`read-char' returns the first character of the reply."
  (eabp-prim--with-bridge (list "x")
    (should (equal ?x (read-char "Ch: ")))))

(ert-deftest eabp-prim-read-char-choice ()
  "`read-char-choice' returns the chosen (valid) character."
  (eabp-prim--with-bridge (list "y")
    (should (equal ?y (read-char-choice "y/n: " '(?y ?n))))))

(ert-deftest eabp-prim-read-multiple-choice ()
  "`read-multiple-choice' returns the whole chosen entry."
  (eabp-prim--with-bridge (list "y")
    (should (equal '(?y "yes")
                   (read-multiple-choice "Q " '((?y "yes") (?n "no")))))))

(ert-deftest eabp-prim-completing-read-pick ()
  "A tapped candidate is returned by `completing-read' (static collection)."
  (eabp-prim--with-bridge (list "beta")
    (should (equal "beta" (completing-read "Pick: " '("alpha" "beta" "gamma"))))))

(ert-deftest eabp-prim-completing-read-dynamic-pick ()
  "A dynamic (function) collection returns a valid tapped candidate."
  (let ((coll (lambda (s p a) (complete-with-action a '("red" "green") s p))))
    (eabp-prim--with-bridge (list "green")
      (should (equal "green" (completing-read "Color: " coll))))))

(ert-deftest eabp-prim-completing-read-multiple ()
  "`completing-read-multiple' returns the selected strings."
  (eabp-prim--with-bridge (list ["a" "b"])
    (should (equal '("a" "b")
                   (completing-read-multiple "Tags: " '("a" "b" "c"))))))

;; ─── P5: gauntlet — render substrates ────────────────────────────────────────

(ert-deftest eabp-prim-render-folded-outline ()
  "A collapsed outline heading renders its ▸ expand affordance."
  (with-temp-buffer
    (insert "* Heading\nbody line\nmore body\n* Two\n")
    (outline-mode)
    (goto-char (point-min))
    (outline-hide-subtree)
    (let ((texts (eabp-prim--span-text
                  (eabp-prim--all-spans (eabp-buffer-render (current-buffer))))))
      (should (string-match-p "▸" texts)))))

(ert-deftest eabp-prim-render-tabulated-list ()
  "A tabulated-list buffer renders as sortable cards via the Tier 0.5 skin."
  (require 'eabp-tablist)
  (with-temp-buffer
    (tabulated-list-mode)
    (setq tabulated-list-format [("Name" 10 t) ("Val" 6 nil)]
          tabulated-list-entries '(("id1" ["foo" "1"]) ("id2" ["bar" "2"])))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (let* ((nodes (eabp-render-buffer (current-buffer)))
           (cards (cl-mapcan (lambda (n) (eabp-prim--find-all n "card")) nodes)))
      (should (>= (length cards) 2)))))

;; ─── Transient layout reader (magit-commit dialog) ───────────────────────────
;;
;; `transient--layout' has two incompatible shapes across versions; the dialog
;; renderer must handle both.  Regression for the magit-commit crash:
;;   "Wrong type argument: listp, [2 nil ([transient-column ...])]".

(defun eabp-prim--assert-transient-groups (layout)
  "Put LAYOUT on a temp symbol and assert `eabp-transient--groups' parses it."
  (let ((sym (make-symbol "eabp-prim-tsym")))
    (put sym 'transient--layout layout)
    (let ((groups (eabp-transient--groups sym)))
      (should (assoc "Arguments" groups))
      (should (assoc "Create" groups))
      ;; The --all switch parses as an infix.
      (should (cl-find "--all" (cdr (assoc "Arguments" groups))
                       :key (lambda (k) (plist-get k :argument)) :test #'equal))
      ;; The Commit suffix parses as a command.
      (should (cl-find 'ignore (cdr (assoc "Create" groups))
                       :key (lambda (k) (plist-get k :command)))))))

(ert-deftest eabp-prim-transient-layout-new-format ()
  "The newer single-root-vector layout (inline-plist leaves) parses.
This is the exact shape from the on-device magit-commit crash, INCLUDING
the bare \"\" separator children the layout interleaves — parsing those
as leaves was the second crash (Wrong type argument: listp, \"\")."
  (eabp-prim--assert-transient-groups
   [2 nil ([transient-column (:description "Arguments")
                             ((transient-switch :key "-a" :description "All"
                                                :argument "--all" :command ignore))]
           [transient-columns nil
                              ([transient-column (:description "Create")
                                                 ((transient-suffix :key "c"
                                                                    :description "Commit"
                                                                    :command ignore)
                                                  ""      ; separator
                                                  (transient-suffix :key "e"
                                                                    :description "Extend"
                                                                    :command ignore))])])]))

(ert-deftest eabp-prim-transient-layout-old-format ()
  "The 0.7.x list-of-groups layout (nested-plist leaves) still parses."
  (eabp-prim--assert-transient-groups
   '([1 transient-column (:description "Arguments")
        ((1 transient-switch (:key "-a" :description "All"
                                   :argument "--all" :command ignore)))]
     [1 transient-columns nil
        ([1 transient-column (:description "Create")
            ((1 transient-suffix (:key "c" :description "Commit"
                                       :command ignore)))])])))

(provide 'eabp-primitives-test)
;;; eabp-primitives-test.el ends here
