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

(provide 'eabp-primitives-test)
;;; eabp-primitives-test.el ends here
