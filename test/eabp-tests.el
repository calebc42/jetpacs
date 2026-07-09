;;; eabp-tests.el --- ERT suite for the EABP core client -*- lexical-binding: t; -*-

;; Run from the repo root (any Emacs 28+):
;;   emacs -Q --batch -l test/eabp-tests.el -f ert-run-tests-batch-and-exit
;; or via test/run-tests.sh.
;;
;; This suite covers the EABP core (emacs/core/). The Glasspane app's tests
;; live in the separate glasspane repo (test/glasspane-tests.el).
;;
;; The widget wire-format test compares every constructor against the
;; committed golden snapshot (test/widgets.golden).  After an INTENTIONAL
;; wire-format change, regenerate it with:
;;   emacs -Q --batch -l test/eabp-tests.el -f eabp-tests-regen-widget-golden

;;; Code:

(defvar eabp-tests--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(dolist (dir '("../emacs/core" "../emacs/apps"))
  (add-to-list 'load-path (expand-file-name dir eabp-tests--dir)))

(require 'ert)
(require 'cl-lib)
(require 'eabp)
(require 'eabp-triggers)
(require 'eabp-device)
(require 'eabp-apps)
(require 'eabp-widgets)
(require 'eabp-lint)
(require 'eabp-shell)
(require 'eabp-keymap)
(require 'eabp-files)
(require 'eabp-minibuffer)
(require 'eabp-emacs-ui)
(require 'eabp-complete)
(require 'eabp-sync)
(require 'eabp-settings)

;; ─── Capture ────────────────────────────────────────────────────────────────

;; ─── Reminders ──────────────────────────────────────────────────────────────

;; ─── Widget items ───────────────────────────────────────────────────────────

;; ─── Extraction cache ───────────────────────────────────────────────────────

;; ─── Files sandbox ──────────────────────────────────────────────────────────

(ert-deftest eabp-files-roots-boundary ()
  "Sibling-prefix directories and parent traversal must be rejected."
  (let ((eabp-files-roots '(("R" . "/tmp/eabp-root/"))))
    (make-directory "/tmp/eabp-root" t)
    (make-directory "/tmp/eabp-root-evil" t)
    (should (eabp-files--within-root-p "/tmp/eabp-root/notes.org"))
    (should (eabp-files--within-root-p "/tmp/eabp-root"))
    (should-not (eabp-files--within-root-p "/tmp/eabp-root-evil/x.org"))
    (should-not (eabp-files--within-root-p "/tmp/eabp-root/../etc/passwd"))))

;; ─── Keymap labels ──────────────────────────────────────────────────────────

(ert-deftest eabp-keymap-labels ()
  "Labels strip only the current major mode's stem."
  (with-temp-buffer
    (let ((major-mode 'org-mode))
      (should (equal (eabp-keymap--command-label 'org-agenda-list) "agenda-list"))
      (should (equal (eabp-keymap--command-label 'forward-paragraph)
                     "forward-paragraph")))
    (let ((major-mode 'magit-status-mode))
      (should (equal (eabp-keymap--command-label 'magit-stage) "stage")))
    (let ((major-mode 'fundamental-mode))
      (should (equal (eabp-keymap--command-label 'org-agenda-list)
                     "org-agenda-list")))))

;; ─── Agenda extraction ──────────────────────────────────────────────────────

;; ─── Search: query parsing, matching, builder ───────────────────────────────

(defmacro eabp-tests--with-search-fixture (&rest body)
  "Run BODY with a temp org agenda file of known headings."
  `(let ((file (make-temp-file "eabp-search" nil ".org")))
     (with-temp-file file
       (insert "* TODO [#A] Fix the server :server:urgent:\n"
               "DEADLINE: <" (format-time-string "%Y-%m-%d") ">\n"
               "* DONE Deploy the Server :Server:\n"
               "* Buy milk :home:\n"
               "Semi-skimmed preferred.\n"
               "* TODO Call plumber :home:\n"))
     (unwind-protect
         (let ((org-agenda-files (list file)))
           (glasspane-org-cache-invalidate)
           ,@body)
       (delete-file file))))

(defun eabp-tests--search-headlines (query)
  "Headlines returned for QUERY, in file order."
  (mapcar (lambda (it) (alist-get 'headline it))
          (glasspane-org--search query)))

;; ─── Agenda date arithmetic & widgets ───────────────────────────────────────

;; ─── Prompt dialogs ─────────────────────────────────────────────────────────

(ert-deftest eabp-prompt-dialog-merge ()
  "Context cards merge INTO a lazy_column body — nesting crashes the client."
  (let (sent)
    (cl-letf (((symbol-function 'eabp-send-dialog)
               (lambda (spec) (setq sent spec))))
      (with-current-buffer (get-buffer-create "*ctx*")
        (erase-buffer)
        (insert "context text"))
      (unwind-protect
          (let ((eabp-minibuffer--context-buffers '("*ctx*")))
            (eabp--send-prompt-dialog "p1" (eabp-lazy-column (eabp-text "hi")))
            (should (equal (alist-get 't sent) "lazy_column"))
            (let ((children (append (alist-get 'children sent) nil)))
              (should (= (length children) 2))
              (should-not (cl-some (lambda (c)
                                     (equal (alist-get 't c) "lazy_column"))
                                   children)))
            (eabp--send-prompt-dialog "p2" (eabp-column (eabp-text "hi")))
            (should (equal (alist-get 't sent) "lazy_column")))
        (kill-buffer "*ctx*")))))

;; ─── Tier 1 keymap menus ────────────────────────────────────────────────────

;; ─── Buffer-view line numbers ───────────────────────────────────────────────

(require 'eabp-buffer)

(defun eabp-tests--first-span-text (node)
  (alist-get 'text (aref (alist-get 'spans node) 0)))

(ert-deftest eabp-buffer-line-numbers ()
  "Absolute and relative (hybrid) gutter spans on the Tier 0 renderer."
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (goto-char (point-min))
    (forward-line 1)                    ; point on line 2 ("beta")
    (let ((eabp-line-numbers 'absolute))
      (let ((nodes (eabp-buffer-render (current-buffer))))
        (should (equal (eabp-tests--first-span-text (nth 0 nodes)) "1 "))
        (should (equal (eabp-tests--first-span-text (nth 2 nodes)) "3 "))))
    (let ((eabp-line-numbers 'relative))
      (let ((nodes (eabp-buffer-render (current-buffer))))
        ;; distance 1 above point; point's line shows its absolute number
        (should (equal (eabp-tests--first-span-text (nth 0 nodes)) "1 "))
        (should (equal (eabp-tests--first-span-text (nth 1 nodes)) "2 "))
        (should (equal (eabp-tests--first-span-text (nth 2 nodes)) "1 "))))
    (let ((eabp-line-numbers nil))
      (let ((nodes (eabp-buffer-render (current-buffer))))
        (should (equal (eabp-tests--first-span-text (nth 0 nodes)) "alpha"))))))

;; ─── Messages view ──────────────────────────────────────────────────────────

(ert-deftest eabp-messages-zebra ()
  "Messages rows alternate plain/striped and stay selectable."
  (let ((plain (eabp-emacs-ui--messages-line "one" nil))
        (striped (eabp-emacs-ui--messages-line "two" t)))
    (should (equal (alist-get 't plain) "text"))
    (should (alist-get 'selectable plain))
    (should (equal (alist-get 't striped) "surface"))
    (should (equal (alist-get 'color striped) "surface_container"))
    (should (alist-get 'fill striped))
    (should (stringp (json-serialize (eabp-emacs-ui--messages-body)
                                     :null-object :null
                                     :false-object :false)))))

;; ─── Detail-view properties editor ──────────────────────────────────────────

;; ─── Shell ──────────────────────────────────────────────────────────────────

(ert-deftest eabp-shell-broken-view-isolated ()
  "A view builder that signals renders an error view; the push survives.
The live-coding contract: a broken Tier 1 view costs its own screen."
  (let ((built (eabp-shell--build-view
                "boom" (list :builder (lambda (_) (error "kaput"))) nil)))
    ;; It is still a well-formed scaffold view carrying the error text.
    (should (alist-get 'children built))
    (should (string-match-p "kaput" (format "%S" built))))
  ;; Broken :when / :overlay predicates count as nil, not as a crash.
  (let ((eabp-shell-views
         (list (cons "bad-pred"
                     (list :builder (lambda (_) nil)
                           :when (lambda () (error "pred boom"))
                           :overlay (lambda () (error "pred boom"))
                           :order 1)))))
    (should-not (eabp-shell--visible-views))
    (should-not (eabp-shell--active-view))))

;; ─── Transport ──────────────────────────────────────────────────────────────

(ert-deftest eabp-request-no-leak ()
  "Requests sent while disconnected must not leak pending callbacks."
  (let ((eabp--process nil))
    (clrhash eabp--pending)
    (eabp-request "ping" nil #'ignore)
    (should (= (hash-table-count eabp--pending) 0))))

;; ─── Toast forwarding ───────────────────────────────────────────────────────

(ert-deftest eabp-toast-throttle ()
  "Messages mirror as toasts: throttled, latest-wins, EABP noise filtered."
  (let ((sent nil)
        (eabp-forward-messages t)
        (eabp-emacs-ui--toast-last 0)
        (eabp-emacs-ui--toast-timer nil)
        (eabp-emacs-ui--toast-pending nil))
    (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
              ((symbol-function 'eabp-send)
               (lambda (_kind payload &rest _)
                 (push (alist-get 'text payload) sent))))
      (eabp-emacs-ui--message-advice "hello %s" "world")
      (should (equal sent '("hello world")))
      ;; Inside the throttle window: held as pending, not sent.
      (eabp-emacs-ui--message-advice "again")
      (should (equal sent '("hello world")))
      (should (equal eabp-emacs-ui--toast-pending "again"))
      (should (timerp eabp-emacs-ui--toast-timer))
      (cancel-timer eabp-emacs-ui--toast-timer)
      ;; Bridge-internal messages never bounce back to the phone.
      (setq eabp-emacs-ui--toast-last 0)
      (eabp-emacs-ui--message-advice "EABP: internal chatter")
      (should (= (length sent) 1)))))

;; ─── Completion bridge ──────────────────────────────────────────────────────

(ert-deftest eabp-complete-elisp-capf ()
  "The elisp shadow buffer completes symbols from the live obarray."
  (let* ((text "(defun f () (buffer-substring-no")
         (result (eabp-complete-in-text "test.el" text (length text))))
    (should result)
    (should (equal (car result) "buffer-substring-no"))
    (should (cl-find "buffer-substring-no-properties" (cdr result)
                     :key (lambda (c) (alist-get 'label c))
                     :test #'equal))))

(ert-deftest eabp-complete-word-fallback ()
  "Modes with no useful capf fall back to same-buffer word completion."
  (let* ((text "alphabet soup is alphabetical\nalp")
         (result (eabp-complete-in-text "notes.txt" text (length text))))
    (should result)
    (should (equal (car result) "alp"))
    (let ((labels (mapcar (lambda (c) (alist-get 'label c)) (cdr result))))
      (should (member "alphabet" labels))
      (should (member "alphabetical" labels)))))

(ert-deftest eabp-complete-nothing-without-token ()
  "No token before the cursor → nil, so the phone strip stays hidden."
  (should-not (eabp-complete-in-text "notes.txt" "hello world " 12)))

(ert-deftest eabp-complete-candidates-capped ()
  "Candidate lists respect `eabp-complete-max-candidates'."
  (let* ((eabp-complete-max-candidates 3)
         ;; "def" prefixes hundreds of elisp symbols (defun, defvar, ...).
         (text "(def")
         (result (eabp-complete-in-text "cap.el" text (length text))))
    (should result)
    (should (<= (length (cdr result)) 3))))

(ert-deftest eabp-complete-shadow-buffer-reused ()
  "One hidden shadow buffer per file, reused across requests."
  (eabp-complete-in-text "reuse.el" "(car" 4)
  (let ((count (cl-count-if
                (lambda (b) (string-search "eabp-complete: reuse.el"
                                           (buffer-name b)))
                (buffer-list))))
    (eabp-complete-in-text "reuse.el" "(cdr" 4)
    (should (= count (cl-count-if
                      (lambda (b) (string-search "eabp-complete: reuse.el"
                                                 (buffer-name b)))
                      (buffer-list))))))

;; ─── Editor sync (v2) ───────────────────────────────────────────────────────

(ert-deftest eabp-sync-open-and-delta ()
  "edit.open seeds the shadow; a seq-1 delta splices it correctly."
  (let ((eabp-sync-diagnostics nil)
        (file "sync-test.el"))
    (unwind-protect
        (progn
          (eabp-sync-open file 7 "(defun foo ())")
          (should (eabp-sync-session-buffer file 7 0))
          ;; Replace "foo" (3 code points at offset 7) with "bar-baz".
          (should (eabp-sync-apply-delta file 7 1 7 3 "bar-baz" 18))
          (with-current-buffer (eabp-sync-session-buffer file 7 1)
            (should (equal (buffer-string) "(defun bar-baz ())")))
          ;; The old seq no longer matches.
          (should-not (eabp-sync-session-buffer file 7 0)))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-code-point-offsets ()
  "Delta offsets are code points, so astral chars can't skew positions.
The phone sends offset 2 for the char after an emoji even though its
UTF-16 index there is 3."
  (let ((eabp-sync-diagnostics nil)
        (file "sync-emoji.txt")
        (text (string ?a #x1F600 ?b ?c)))
    (unwind-protect
        (progn
          (eabp-sync-open file 9 text)
          (should (eabp-sync-apply-delta file 9 1 2 1 "XY" 5))
          (with-current-buffer (eabp-sync-session-buffer file 9 1)
            (should (equal (buffer-string) (string ?a #x1F600 ?X ?Y ?c)))))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-mismatch-goes-stale ()
  "A wrong seq requests one resync; the stale session swallows the rest."
  (let ((eabp-sync-diagnostics nil)
        (file "sync-stale.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'eabp-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (eabp-sync-open file 3 "abc")
          ;; seq 2 arrives but 1 was expected.
          (should-not (eabp-sync-apply-delta file 3 2 0 0 "x" 4))
          (should (equal (caar sent) "edit.resync"))
          (should-not (eabp-sync-session file))
          ;; The rest of the in-flight burst is swallowed silently.
          (setq sent nil)
          (should-not (eabp-sync-apply-delta file 3 3 0 0 "y" 5))
          (should-not sent)
          ;; A fresh open recovers the session.
          (eabp-sync-open file 4 "xyz")
          (should (eabp-sync-session-buffer file 4 0)))
      (eabp-sync-close file))))

(ert-deftest eabp-complete-in-session ()
  "Slim completion completes in the synced shadow at a bare cursor offset."
  (let ((eabp-sync-diagnostics nil)
        (file "sync-complete.el"))
    (unwind-protect
        (progn
          (eabp-sync-open file 11 "(buffer-subst")
          (let ((result (eabp-complete-in-session file 11 0 13)))
            (should result)
            (should (equal (car result) "buffer-subst"))
            (should (cl-find "buffer-substring-no-properties" (cdr result)
                             :key (lambda (c) (alist-get 'label c))
                             :test #'equal))))
      (eabp-sync-close file))))

(ert-deftest eabp-complete-in-session-rejects-stale ()
  "Completion against a mismatched seq returns nil and asks for resync."
  (let ((eabp-sync-diagnostics nil)
        (file "sync-complete-stale.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'eabp-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (eabp-sync-open file 5 "(car")
          (should-not (eabp-complete-in-session file 5 99 4))
          (should (cl-find "edit.resync" sent :key #'car :test #'equal)))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-eldoc-push ()
  "Eldoc at a synced cursor pushes an elisp signature to the phone."
  (let ((eabp-sync-diagnostics nil)
        (file "eldoc-test.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'eabp-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (eabp-sync-open file 21 "(buffer-substring ")
          (with-current-buffer (eabp-sync-session-buffer file 21 0)
            (save-excursion
              (goto-char (point-max))
              (eabp-sync--run-eldoc file 21)))
          (let ((push (cdr (assoc "eldoc.show" sent))))
            (should push)
            (should (string-search "buffer-substring" (alist-get 'text push)))
            (should (string-search "START" (alist-get 'text push)))))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-eglot-real-file-session ()
  "LSP-able files sync into their REAL buffer — eglot's substrate.
The session buffer visits the file, deltas splice it, and close leaves
the buffer alive (it may be the user's, and it keeps the server warm)."
  (let ((eabp-sync-diagnostics nil)
        (eabp-sync-eglot t)
        (file (make-temp-file "eabp-eglot" nil ".py")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "x = 1\n"))
          (eabp-sync-open file 51 "x = 1\n")
          (let ((buf (eabp-sync-session-buffer file 51 0)))
            (should buf)
            (should (equal (file-truename (buffer-file-name buf))
                           (file-truename file)))
            (should (with-current-buffer buf
                      (derived-mode-p 'python-mode)))
            ;; Replace "1" (offset 4) with "42" — splices the real buffer.
            (should (eabp-sync-apply-delta file 51 1 4 1 "42" 7))
            (should (equal (with-current-buffer buf (buffer-string))
                           "x = 42\n"))
            (eabp-sync-close file)
            (should (buffer-live-p buf))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (ignore-errors (delete-file file)))))

(ert-deftest eabp-sync-shadow-setup-hook-runs ()
  "The setup hook runs in fresh shadows, letting config opt capfs back in."
  (let* ((eabp-sync-diagnostics nil)
         (file "hook-test.el")
         (ran nil)
         (eabp-sync-shadow-setup-hook
          (list (lambda () (setq ran (list major-mode (buffer-name)))))))
    (unwind-protect
        (progn
          (eabp-sync-open file 13 "x")
          (should ran)
          (should (eq (car ran) 'emacs-lisp-mode)))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-flymake-elisp-backend ()
  "The in-process backend flags wrong arity and unbalanced parens."
  (let ((eabp-sync-diagnostics nil)
        (file "flymake-test.el"))
    (unwind-protect
        (progn
          ;; Wrong arity: `f' takes one argument, `g' passes two.
          (eabp-sync-open file 31 "(defun f (x) x)\n(defun g () (f 1 2))\n")
          (with-current-buffer (eabp-sync-session-buffer file 31 0)
            (let (got)
              (eabp-sync--flymake-elisp (lambda (diags &rest _) (setq got diags)))
              (should got)
              (should (cl-some (lambda (d)
                                 (string-match-p "f" (flymake-diagnostic-text d)))
                               got))))
          ;; Unbalanced parens: reported as an error, without compiling.
          (eabp-sync-open file 32 "(defun broken () ")
          (with-current-buffer (eabp-sync-session-buffer file 32 0)
            (let (got)
              (eabp-sync--flymake-elisp (lambda (diags &rest _) (setq got diags)))
              (should got)
              (should (eq (flymake-diagnostic-type (car got)) :error)))))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-diagnostics-pipeline ()
  "Broken elisp in a synced shadow produces a diagnostics.show push."
  (let ((eabp-sync-diagnostics t)
        (file "diag-pipe.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'eabp-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (eabp-sync-open file 41 "(defun f (x) x)\n(defun g () (f 1 2))\n")
          (with-current-buffer (eabp-sync-session-buffer file 41 0)
            (should flymake-mode)
            ;; The backend is synchronous, but flymake publishes through
            ;; its own machinery — give the timers a moment.
            (let ((deadline (+ (float-time) 5)))
              (while (and (null (flymake-diagnostics))
                          (< (float-time) deadline))
                (sit-for 0.1)))
            (should (flymake-diagnostics)))
          (eabp-sync--collect-and-push file)
          (let ((push (cdr (assoc "diagnostics.show" sent))))
            (should push)
            (should (> (length (alist-get 'diags push)) 0)))
          ;; Content-identical diagnostics must STILL re-push after an edit:
          ;; the phone's render gate is seq-keyed, so the break-then-undo
          ;; scenario needs a fresh push even when nothing changed. This
          ;; append-a-space delta leaves every diagnostic position intact.
          (setq sent nil)
          (should (eabp-sync-apply-delta file 41 1 37 0 " " 38))
          (with-current-buffer (eabp-sync-session-buffer file 41 1)
            (let ((deadline (+ (float-time) 5)))
              (while (and (null (flymake-diagnostics))
                          (< (float-time) deadline))
                (sit-for 0.1))))
          (eabp-sync--collect-and-push file)
          (let ((push (cdr (assoc "diagnostics.show" sent))))
            (should push)
            (should (equal (alist-get 'seq push) 1))))
      (eabp-sync-close file))))

(ert-deftest eabp-complete-empty-prefix-policy ()
  "Empty prefixes: small precise tables (LSP members) pass, obarray doesn't."
  ;; A small table at point — the shape of member completion after ".".
  (with-temp-buffer
    (setq-local completion-at-point-functions
                (list (lambda () (list (point) (point)
                                       '("append" "clear" "copy")))))
    (insert "xs.")
    (goto-char (point-max))
    (let ((r (eabp-complete--collect)))
      (should r)
      (should (equal (car r) ""))
      (should (= (length (cdr r)) 3))))
  ;; The unconstrained obarray right after "(" still yields nothing.
  (should-not (eabp-complete-in-text "guard.el" "(" 1)))

(ert-deftest eabp-complete-python-word-fallback ()
  "Python files complete same-buffer identifiers via the word fallback."
  (let* ((text "def fibonacci(n):\n    return n\n\nfib")
         (result (eabp-complete-in-text "demo.py" text (length text))))
    (should result)
    (should (equal (car result) "fib"))
    (should (cl-find "fibonacci" (cdr result)
                     :key (lambda (c) (alist-get 'label c))
                     :test #'equal))))

(ert-deftest eabp-sync-fontify-push ()
  "Fontification pushes on open and re-pushes per seq (stamp includes seq)."
  (let ((eabp-sync-diagnostics nil)
        (eabp-sync-fontify t)
        (file "fontify-test.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'eabp-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent)))
                  ;; Batch Emacs resolves no face colors; stub the style so
                  ;; the walk itself is what's under test.
                  ((symbol-function 'eabp-buffer--span-style)
                   (lambda (face) (and face '(:bold t)))))
          (eabp-sync-open file 61 "(defun foo ())")
          (let ((push (cdr (assoc "fontify.show" sent))))
            (should push)
            (should (> (length (alist-get 'runs push)) 0))
            (let ((r (aref (alist-get 'runs push) 0)))
              (should (numberp (alist-get 'b r)))
              (should (> (alist-get 'e r) (alist-get 'b r)))))
          ;; Content-identical runs still re-push after an edit — the
          ;; phone's render gate is seq-keyed, exactly like diagnostics.
          (setq sent nil)
          (should (eabp-sync-apply-delta file 61 1 14 0 " " 15))
          (should (assoc "fontify.show" sent)))
      (eabp-sync-close file))))

(ert-deftest eabp-sync-mode-remap-respected ()
  "Shadow mode selection honors `major-mode-remap-alist' (ts modes)."
  (let ((major-mode-remap-alist '((emacs-lisp-mode . lisp-interaction-mode))))
    (should (eq (eabp-sync--mode-for "x.el") 'lisp-interaction-mode)))
  (let ((major-mode-remap-alist nil))
    (should (eq (eabp-sync--mode-for "x.el") 'emacs-lisp-mode))))

(ert-deftest eabp-sync-severity-mapping ()
  "Flymake types normalize to the three wire severities."
  (should (equal (eabp-sync--severity :error) "error"))
  (should (equal (eabp-sync--severity :warning) "warning"))
  (should (equal (eabp-sync--severity :note) "note"))
  ;; Unknown types degrade to warning, never crash.
  (should (equal (eabp-sync--severity 'no-such-type) "warning")))

;; ─── Pairing auth ───────────────────────────────────────────────────────────

(ert-deftest eabp-hmac-sha256-rfc-vectors ()
  "The pure-elisp HMAC matches RFC 4231 / classic test vectors."
  ;; RFC 4231 test case 2 (short key).
  (should (equal (eabp--hmac-sha256-hex "Jefe" "what do ya want for nothing?")
                 "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
  ;; The classic quick-brown-fox vector.
  (should (equal (eabp--hmac-sha256-hex
                  "key" "The quick brown fox jumps over the lazy dog")
                 "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"))
  ;; RFC 4231 test case 6: key longer than the block size (hash-first path).
  ;; The key must be RAW 0xAA bytes — a multibyte (make-string 131 ?\xaa)
  ;; would UTF-8-encode to two bytes per char and break the vector.
  (should (equal (eabp--hmac-sha256-hex
                  (apply #'unibyte-string (make-list 131 #xaa))
                  "Test Using Larger Than Block-Size Key - Hash Key First")
                 "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")))

(ert-deftest eabp-auth-handshake-round-trip ()
  "Challenge → response → proof, both directions, plus the failure modes."
  (let ((eabp-auth-token "ABCD-EFGH-JKMN-PQRS")
        (eabp--auth-server-nonce nil)
        (eabp--auth-client-nonce nil)
        (sent nil))
    (cl-letf (((symbol-function 'eabp-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      ;; The challenge produces a response with the right MAC.
      (eabp--on-auth-challenge '((nonce . "deadbeef")))
      (let* ((resp (cdr (assoc "auth.response" sent)))
             (cnonce (alist-get 'nonce resp)))
        (should resp)
        (should (equal (alist-get 'mac resp)
                       (eabp--hmac-sha256-hex
                        eabp-auth-token
                        (format "eabp1:client:deadbeef:%s" cnonce))))
        ;; A welcome carrying the matching server proof verifies…
        (should (eabp--auth-verify-welcome
                 `((server_proof
                    . ,(eabp--hmac-sha256-hex
                        eabp-auth-token
                        (format "eabp1:server:%s:deadbeef" cnonce))))))
        ;; …a wrong or missing proof is refused (fail closed)…
        (should-not (eabp--auth-verify-welcome '((server_proof . "bogus"))))
        (should-not (eabp--auth-verify-welcome '((protocol . 1))))))
    ;; …and with no token configured, the legacy path still passes.
    (let ((eabp-auth-token nil))
      (should (eabp--auth-verify-welcome '((protocol . 1)))))))

(ert-deftest eabp-auth-challenge-without-token-stays-silent ()
  "Unpaired Emacs answers a challenge with guidance, never a frame."
  (let ((eabp-auth-token nil)
        (sent nil))
    (cl-letf (((symbol-function 'eabp-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      (eabp--on-auth-challenge '((nonce . "deadbeef")))
      (should-not sent))))

;; ─── Demo files ─────────────────────────────────────────────────────────────

;; ─── Org tables: emitter and actions ────────────────────────────────────────

;; ─── Org babel results: foldable and read-only ──────────────────────────────

;; ─── Org babel: emitter and action ──────────────────────────────────────────

;; ─── Org drawers ─────────────────────────────────────────────────────────────

(defun eabp-tests--find-node (tree pred)
  "Depth-first search of widget TREE for a node satisfying PRED.
TREE may be a node (alist), a list of nodes, or a vector of nodes."
  (cond
   ((vectorp tree)
    (cl-some (lambda (x) (eabp-tests--find-node x pred)) tree))
   ((and (consp tree) (consp (car tree)) (symbolp (caar tree)))
    (if (funcall pred tree) tree
      (cl-some (lambda (kv) (and (consp kv)
                                 (eabp-tests--find-node (cdr kv) pred)))
               tree)))
   ((consp tree)
    (cl-some (lambda (x) (eabp-tests--find-node x pred)) tree))))

;; ─── Org case conventions ────────────────────────────────────────────────────
;; Keywords, blocks, and drawer delimiters may be lowercase in org files;
;; TODO keywords and tags are case-sensitive.  Recognition must not depend
;; on the ambient `case-fold-search'.

;; ─── Demo org corpus ─────────────────────────────────────────────────────────

;; ─── App-managed config directory ────────────────────────────────────────────

;; ─── Widget wire format (golden snapshot) ───────────────────────────────────

(defconst eabp-tests--golden-file
  (expand-file-name "widgets.golden" eabp-tests--dir))

(defun eabp-tests--canon (x)
  "Recursively sort alist keys in X so serialization order is stable."
  (cond
   ((and (consp x) (consp (car x)) (symbolp (caar x)))
    (sort (mapcar (lambda (kv) (cons (car kv) (eabp-tests--canon (cdr kv))))
                  (copy-sequence x))
          (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))
   ((vectorp x) (vconcat (mapcar #'eabp-tests--canon x)))
   (t x)))

(defun eabp-tests--widget-cases ()
  "A battery exercising every widget constructor with all its options."
  (let* ((act (eabp-action "x.y" :args '((k . "v"))
                           :when-offline "drop" :dedupe "d"))
         (leaf (eabp-text "leaf")))
    (list
     (eabp-text "hi")
     (eabp-text "hi" 'title 1 "#FF0000" t 2 4)
     (eabp-markup "code" :syntax "elisp" :style 'body :padding 4)
     (eabp-rich-text (list (eabp-span "a" :bold t)) :style 'body :padding 2)
     (eabp-span "s" :bold t :italic t :underline t :strike t :code t
                :tag t :baseline "super" :color "#FFF" :on-tap act :mono t)
     (eabp-row leaf leaf)
     (eabp-flow-row leaf)
     (eabp-column leaf)
     (eabp-box (list leaf) :alignment "center" :padding 2 :weight 1 :on-tap act)
     (eabp-surface (list leaf) :color "#111" :shape "rounded" :elevation 2 :padding 3)
     (eabp-surface (list leaf) :color "surface_container" :shape "rounded_small" :fill t)
     (eabp-lazy-column leaf leaf)
     (eabp-spacer :height 4 :width 2 :weight 1)
     (eabp-divider)
     (eabp-card (list leaf) :on-tap act :padding 8 :weight 1)
     (eabp-collapsible "cid" leaf (list leaf) :collapsed t :on-long-tap act)
     (eabp-reorderable-list (list '((label . "h") (level . 1))) :on-reorder act)
     (eabp-action "y.z")
     act
     (eabp-clipboard-action "copied text")
     (eabp-button "L" act :icon "add" :variant "text" :weight 1 :padding 2)
     (eabp-date-button "L" act :value "2026-01-01")
     (eabp-time-button "L" act :value "10:00")
     (eabp-image "http://x" :content-description "d" :padding 1)
     (eabp-icon-button "add" act :content-description "c" :padding 1)
     (eabp-menu (list (eabp-menu-item "L" act :icon "add")) :icon "more_vert" :padding 2)
     (eabp-text-input "tid" :value "v" :hint "h" :label "l" :on-submit act
                      :single-line t :min-lines 1 :max-lines 3
                      :monospace t :syntax "org" :padding 2)
     (eabp-text-input "tid2" :multi-line t)
     (eabp-enum-list "eid" '("a" "b") :value '("a") :multi-select t
                     :allow-add t :on-change act :padding 1)
     (eabp-checkbox "kid" :checked t :label "l" :on-change act :padding 1)
     (eabp-switch "sid" :checked t :label "l" :on-change act :padding 1)
     (eabp-icon "add" :size 20 :color "#FFF" :padding 1)
     (eabp-chip "l" :on-tap act :selected t :icon "add" :padding 1)
     (eabp-progress :variant "linear" :value 0.5 :padding 1)
     (eabp-assist-chip "l" :on-tap act :icon "add" :padding 1)
     (eabp-section-header "t" :trailing leaf :padding 1)
     (eabp-empty-state :icon "inbox" :title "t" :caption "c"
                       :on-tap act :action-label "al" :padding 1)
     (eabp-date-stamp :date "2026-07-02" :time "10:00" :padding 1)
     (eabp-date-stamp :day 2 :month "Jul" :month-index 7 :year 2026)
     (eabp-editor "f.org" "content" :on-save act :read-only t :syntax "org"
                  :line-numbers "absolute" :complete t
                  :chromeless t :publish-state t)
     (eabp-drawer (list (eabp-drawer-item "i" "l" act :selected t)) :header "h")
     (eabp-top-bar "t" :nav-icon "menu" :nav-action act :actions (list leaf))
     (eabp-fab "add" :label "l" :on-tap act :extended t)
     (eabp-bottom-bar (list (eabp-nav-item "i" "l" act :selected t)))
     (eabp-scaffold :top-bar (eabp-top-bar "t") :fab (eabp-fab "add")
                    :body leaf :bottom-bar (eabp-bottom-bar nil)
                    :snackbar "s" :drawer (eabp-drawer nil :header "h")
                    :on-refresh act)
     (eabp-table
      (list (eabp-table-row
             (list (eabp-table-cell (list (eabp-span "Item" :bold t)))
                   (eabp-table-cell (list (eabp-span "Qty"))))
             :header t)
            (eabp-table-rule)
            (eabp-table-row
             (list (eabp-table-cell (list (eabp-span "apples"))
                                    :on-tap act :on-long-tap act)
                   (eabp-table-cell (list (eabp-span "4"))))))
      :aligns '("start" "end") :on-add-row act :on-add-col act :padding 2)
     (eabp-table
      (list (eabp-table-row (list (eabp-table-cell (list (eabp-span "a")))))))
     (eabp-scroll-row leaf leaf)
     ;; Phase C — composition knobs
     (eabp-slider "vol" act :value 0.3 :min 0.0 :max 1.0 :steps 10)
     (eabp-row leaf leaf :spacing 4 :align "top")
     (eabp-column leaf leaf :spacing 6 :align "center")
     (eabp-surface (list leaf) :width 120 :height 40 :fill-fraction 0.5
                   :border (eabp-border :width 2 :color "#888"))
     (eabp-image "http://x" :width 100 :height 80 :aspect-ratio 1.5
                 :content-scale "crop")
     ;; Phase D — visualization ladder
     (eabp-chart (list (eabp-chart-series '(1 3 2 5) :label "a" :color "#4C6FFF")
                       (eabp-chart-series '(2 2 4 3)))
                 :kind "line" :height 160 :y-range '(0 6) :summary "trend"
                 :on-point-tap act)
     (eabp-canvas 100 60
                  (list (eabp-draw-line 0 0 100 60 :color "#888" :stroke 2)
                        (eabp-draw-rect 10 10 30 20 :fill t :color "primary" :radius 4)
                        (eabp-draw-circle 70 30 15 :color "#E64980")
                        (eabp-draw-path '((0 60) (50 0) (100 60)) :closed t :fill t)
                        (eabp-draw-text 50 30 "hi" :align "center" :size 10))))))

(defun eabp-tests--widget-lines ()
  (let ((i -1))
    (mapcar (lambda (c)
              (setq i (1+ i))
              (format "%02d %s" i
                      (json-serialize (eabp-tests--canon c)
                                      :null-object :null
                                      :false-object :false)))
            (eabp-tests--widget-cases))))

(defun eabp-tests-regen-widget-golden ()
  "Rewrite the golden snapshot from the current constructors.
Only run this after an INTENTIONAL wire-format change; review the diff."
  (with-temp-file eabp-tests--golden-file
    (insert (string-join (eabp-tests--widget-lines) "\n") "\n"))
  (message "Wrote %s" eabp-tests--golden-file))

(ert-deftest eabp-widgets-wire-format ()
  "Every constructor's wire format matches the committed golden snapshot."
  (should (file-readable-p eabp-tests--golden-file))
  (should (equal (eabp-tests--widget-lines)
                 (split-string
                  (with-temp-buffer
                    (insert-file-contents eabp-tests--golden-file)
                    (buffer-string))
                  "\n" t))))

;; ─── Triggers & device capabilities (SPEC §10–§11) ──────────────────────────

(ert-deftest eabp-triggers-replace-set-push ()
  "Registering triggers pushes the full replace-set, id-sorted, nils omitted.
Register-time pushes are debounced (a burst is one frame);
`eabp-triggers-push-now' is the flush."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (eabp--session '((granted . ("triggers"))))
        (eabp-triggers-changed-hook nil)  ; isolate from the app's re-push
        (eabp-triggers--push-timer nil)
        (sent nil))
    (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
              ((symbol-function 'eabp-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      (eabp-trigger-register "t2" :type "screen" :params '((state . "off")))
      (eabp-trigger-register "t1" :type "power"
                             :params '((state . "connected"))
                             :policy "wake" :throttle-s 60)
      ;; The burst is pending, not sent; the flush emits ONE frame
      ;; carrying both, sorted by id.
      (should-not sent)
      (should (timerp eabp-triggers--push-timer))
      (eabp-triggers-push-now)
      (should (= (length sent) 1))
      (should-not eabp-triggers--push-timer)
      (should (equal (caar sent) "triggers.set"))
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (= (length specs) 2))
        (should (equal (alist-get 'id (nth 0 specs)) "t1"))
        (should (equal (alist-get 'policy (nth 0 specs)) "wake"))
        (should (equal (alist-get 'throttle_s (nth 0 specs)) 60))
        (should-not (assq 'dedupe (nth 0 specs)))
        (should-not (assq 'on_fire (nth 0 specs)))
        (should (equal (alist-get 'id (nth 1 specs)) "t2"))
        (should-not (assq 'policy (nth 1 specs))))
      ;; Unregistering pushes the shrunken set (never fires stale).
      (setq sent nil)
      (eabp-trigger-unregister "t1")
      (eabp-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (= (length specs) 1))
        (should (equal (alist-get 'id (car specs)) "t2"))))))

(ert-deftest eabp-triggers-gated-on-grant ()
  "No triggers.set leaves Emacs unless the companion granted `triggers'."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (eabp--session '((granted . ("surfaces.dialog" "capabilities"))))
        (eabp-triggers-changed-hook nil)  ; isolate from the app's re-push
        (sent nil))
    (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
              ((symbol-function 'eabp-send)
               (lambda (kind &rest _) (push kind sent))))
      (eabp-trigger-register "t" :type "power")
      (eabp-triggers-push-now)          ; flush past the debounce
      (should-not sent))))

(ert-deftest eabp-triggers-unsupported-type-skipped ()
  "A type the companion can't host is skipped, never pushed.
The companion rejects a replace-set wholesale on an unknown type, so
one too-new registration must cost itself, not the whole set — checked
against both the static batch-1 catalog and a welcome-reported one."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (eabp--session '((granted . ("triggers"))))
        (eabp-triggers-changed-hook nil)
        (eabp-triggers--push-timer nil)
        (sent nil))
    (cl-letf (((symbol-function 'eabp-connected-p) (lambda () t))
              ((symbol-function 'eabp-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      (eabp-trigger-register "ok" :type "power")
      (eabp-trigger-register "too-new" :type "wifi.ssid")
      ;; The fallback catalog governs: wifi.ssid stays home.
      (eabp-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (equal (mapcar (lambda (s) (alist-get 'id s)) specs)
                       '("ok"))))
      ;; A companion that reports the type gets it.
      (setq eabp--session '((granted . ("triggers"))
                            (device . ((trigger_types . ("power" "wifi.ssid"))))))
      (eabp-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (equal (mapcar (lambda (s) (alist-get 'id s)) specs)
                       '("ok" "too-new"))))
      ;; And one that reports a catalog WITHOUT a batch-1 type wins too:
      ;; the report is authoritative in both directions.
      (setq eabp--session '((granted . ("triggers"))
                            (device . ((trigger_types . ("wifi.ssid"))))))
      (eabp-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (equal (mapcar (lambda (s) (alist-get 'id s)) specs)
                       '("too-new")))))))

(ert-deftest eabp-triggers-fire-dispatch ()
  "An inbound trigger.fired event.action reaches the per-id handler."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (fired nil))
    ;; Disconnected in batch, so register never sends.
    (eabp-trigger-register "charge" :type "power"
                           :handler (lambda (data args)
                                      (setq fired (list data args))))
    (eabp--handle-line
     (json-serialize
      '((v . 1) (id . "m-test-1") (reply_to . :null)
        (kind . "event.action")
        (payload . ((action . "trigger.fired")
                    (args . ((id . "charge") (type . "power")
                             (data . ((state . "connected")))
                             (at_ms . 1751700000000))))))
      :null-object :null :false-object :false))
    (should fired)
    (should (equal (alist-get 'state (car fired)) "connected"))
    (should (equal (alist-get 'id (cadr fired)) "charge"))
    (should (equal (alist-get 'at_ms (cadr fired)) 1751700000000))
    ;; A fire for an id not in the set is dropped, never signalled.
    (setq fired nil)
    (eabp--handle-line
     (json-serialize
      '((v . 1) (id . "m-test-2") (reply_to . :null)
        (kind . "event.action")
        (payload . ((action . "trigger.fired")
                    (args . ((id . "gone") (type . "power")
                             (data . :null) (at_ms . 1))))))
      :null-object :null :false-object :false))
    (should-not fired)))

(ert-deftest eabp-triggers-deftrigger-and-disable ()
  "eabp-deftrigger registers under the symbol name; disabling excludes
the id from the pushed specs and re-enabling restores it."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (eabp-triggers-disabled nil))
    (eabp-deftrigger test/charge
      :type "power" :params '((state . "connected"))
      :handler #'ignore)
    (should (gethash "test/charge" eabp-triggers--table))
    (should (= 1 (length (eabp-triggers--specs))))
    ;; Disable: registration stays, the wire set shrinks.
    (eabp-trigger-set-enabled "test/charge" nil)
    (should-not (eabp-trigger-enabled-p "test/charge"))
    (should (gethash "test/charge" eabp-triggers--table))
    (should (= 0 (length (eabp-triggers--specs))))
    ;; Re-enable restores the spec.
    (eabp-trigger-set-enabled "test/charge" t)
    (should (= 1 (length (eabp-triggers--specs))))))

(ert-deftest eabp-triggers-toggle-action-persists ()
  "The trigger.toggle action flips enablement and saves via the seam."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (eabp-triggers-disabled nil)
        (saved nil))
    (eabp-deftrigger test/toggle :type "screen" :handler #'ignore)
    (cl-letf (((symbol-function 'eabp-settings-save-variable)
               (lambda (sym val) (setq saved (cons sym val)) t)))
      (eabp--on-action '((action . "trigger.toggle")
                         (args . ((id . "test/toggle") (value . :false))))
                       nil)
      (should-not (eabp-trigger-enabled-p "test/toggle"))
      (should (equal (car saved) 'eabp-triggers-disabled))
      (should (member "test/toggle" (cdr saved)))
      ;; Toggling an unknown id is a no-op, not an error.
      (eabp--on-action '((action . "trigger.toggle")
                         (args . ((id . "nope") (value . t))))
                       nil)
      (should-not (eabp-trigger-enabled-p "test/toggle")))))

(ert-deftest eabp-triggers-test-fire-and-last-fired ()
  "trigger.test runs the handler through the real dispatch path and
records the last-fired time."
  (let ((eabp-triggers--table (make-hash-table :test 'equal))
        (eabp-triggers--last-fired (make-hash-table :test 'equal))
        (fired nil))
    (eabp-deftrigger test/fire
      :type "power"
      :handler (lambda (_data args) (setq fired args)))
    (should-not (gethash "test/fire" eabp-triggers--last-fired))
    (eabp--on-action '((action . "trigger.test")
                       (args . ((id . "test/fire"))))
                     nil)
    (should fired)
    (should (eq (alist-get 'test fired) t))
    (should (equal (alist-get 'type fired) "power"))
    (should (gethash "test/fire" eabp-triggers--last-fired))))

(ert-deftest eabp-device-report-queries ()
  "Session helpers read the granted list and the welcome's device report."
  (let ((eabp--session
         '((granted . ("capabilities" "surfaces.dialog"))
           (device . ((caps . ("settings.open"))
                      (perms . ((exact_alarms . t)
                                (write_settings . :false))))))))
    (should (eabp-granted-p "capabilities"))
    (should-not (eabp-granted-p "triggers"))
    (should (eabp-device-cap-p "settings.open"))
    (should-not (eabp-device-cap-p "flashlight"))
    (should (eabp-device-can-p "exact_alarms"))
    (should-not (eabp-device-can-p 'write_settings))
    (should-not (eabp-device-can-p "fine_location")))
  ;; With no session at all, everything reads as absent, nothing errors.
  (let ((eabp--session nil))
    (should-not (eabp-granted-p "capabilities"))
    (should-not (eabp-device-caps))
    (should-not (eabp-device-can-p "exact_alarms"))))

(ert-deftest eabp-node-supported-negotiation ()
  "`eabp-node-supported-p' gates on the welcome's node catalog, permissively."
  ;; A present catalog is positive knowledge: listed = yes, omitted = no.
  (let ((eabp--session '((node_types . ["text" "row" "chart"]))))
    (should (eabp-node-supported-p 'chart))
    (should (eabp-node-supported-p "text"))
    (should-not (eabp-node-supported-p 'canvas))
    (should-not (eabp-node-supported-p "slider")))
  ;; An older companion sends no catalog: treat every node as supported
  ;; (negotiation is positive knowledge, never a denylist).
  (let ((eabp--session '((granted . ("capabilities")))))
    (should (eabp-node-supported-p 'chart))
    (should (eabp-node-supported-p 'anything-at-all)))
  ;; Not connected: unsupported (nothing renders anywhere).
  (let ((eabp--session nil))
    (should-not (eabp-node-supported-p 'text))))

(ert-deftest eabp-api-version-bound ()
  "The API/protocol version constants exist for third-party compatibility checks."
  (should (stringp eabp-api-version))
  (should (integerp eabp-protocol-version)))

;; ─── Spec linter (Phase B / Task 4) ──────────────────────────────────────────

(ert-deftest eabp-lint-passes-valid-specs ()
  "A tree built from the constructors lints clean."
  (should-not
   (eabp-lint-spec
    (eabp-column
     (eabp-card (list (eabp-text "Title" 'headline)
                      (eabp-rich-text (list (eabp-span "bold" :bold t))))
                :on-tap (eabp-action "x.y" :args '((k . "v"))))
     (eabp-row (eabp-button "Go" (eabp-action "a.b"))
               (eabp-switch "s" :checked t :on-change (eabp-action "c.d")))))))

(ert-deftest eabp-lint-flags-unknown-node ()
  "An unknown `t' is reported."
  (let ((problems (eabp-lint-spec (eabp--node "flisbo" 'text "x"))))
    (should problems)
    (should (string-match-p "unknown" (cdr (car problems))))))

(ert-deftest eabp-lint-flags-bad-action ()
  "An action with neither `action' nor `builtin', and a bad when_offline."
  (should (eabp-lint-spec `((t . "button") (on_tap . ((args . ((k . "v"))))))))
  (should (eabp-lint-spec `((t . "button")
                            (on_tap . ((action . "a.b") (when_offline . "sometimes")))))))

(ert-deftest eabp-lint-flags-nonserializable-and-typed-attrs ()
  "A symbol attr value and a non-numeric padding are caught before the wire."
  (should (eabp-lint-spec `((t . "text") (text . some-symbol))))
  (should (eabp-lint-spec `((t . "text") (text . "ok") (padding . "lots"))))
  (should (eabp-lint-spec `((t . "surface") (children . []) (color . "#GGG")))))

(ert-deftest eabp-lint-sanitize-isolates-bad-subtree ()
  "Sanitizing replaces only the invalid node, keeping siblings intact."
  (let* ((spec (eabp-column
                (eabp-text "keep me" 'body)
                (eabp--node "bogus" 'text "drop me")))
         (clean (eabp-lint-sanitize-spec spec))
         (kids (alist-get 'children clean)))   ; a vector (constructors vconcat)
    (should-not (eabp-lint-spec clean))          ; sanitized tree is valid
    (should (equal "text" (alist-get 't (elt kids 0))))
    (should (equal "empty_state" (alist-get 't (elt kids 1))))))  ; bogus → error node

(ert-deftest eabp-render-to-json-roundtrips ()
  "The headless harness serializes and parses a spec back to the wire shape."
  (let ((parsed (eabp-render-to-json (eabp-text "hi" 'title))))
    (should (equal "text" (alist-get 't parsed)))
    (should (equal "hi" (alist-get 'text parsed)))
    (should (equal "title" (alist-get 'style parsed)))))

(ert-deftest eabp-lint-passes-visualization ()
  "Chart and canvas specs lint clean and round-trip (Phase D)."
  (let ((chart (eabp-chart (list (eabp-chart-series '(1 2 3) :color "#4C6FFF"))
                           :kind "bar" :on-point-tap (eabp-action "p.tap")))
        (canvas (eabp-canvas 80 40
                             (list (eabp-draw-line 0 0 80 40 :stroke 2)
                                   (eabp-draw-circle 40 20 10 :fill t :color "primary")
                                   (eabp-draw-text 10 20 "hi" :align "center")))))
    (should-not (eabp-lint-spec chart))
    (should-not (eabp-lint-spec canvas))
    (should (equal "chart" (alist-get 't (eabp-render-to-json chart))))
    (should (equal "canvas" (alist-get 't (eabp-render-to-json canvas))))))

;; ─── Multi-tenant ownership (Phase E) ─────────────────────────────────────────

(ert-deftest eabp-owner-collision-detection ()
  "Same-owner re-registration is silent; a cross-owner clash errors under strict."
  (let ((eabp-action-handlers (make-hash-table :test 'equal))
        (eabp--registration-owners (make-hash-table :test 'equal))
        (eabp-strict-namespaces nil))
    ;; Same owner re-registers freely — the live-reload case.
    (with-eabp-owner "appA" (eabp-defaction "app.a.do" #'ignore))
    (with-eabp-owner "appA" (eabp-defaction "app.a.do" #'ignore))
    (should (equal "appA" (gethash "action:app.a.do" eabp--registration-owners)))
    ;; A different owner claiming the same name errors when strict.
    (let ((eabp-strict-namespaces t))
      (should-error
       (with-eabp-owner "appB" (eabp-defaction "app.a.do" #'ignore))))
    ;; The strict refusal left the original owner and handler intact.
    (should (equal "appA" (gethash "action:app.a.do" eabp--registration-owners)))))

(ert-deftest eabp-app-unregister-teardown ()
  "`eabp-app-unregister' removes the app's owned actions, views, and state."
  (let ((eabp-action-handlers (make-hash-table :test 'equal))
        (eabp--registration-owners (make-hash-table :test 'equal))
        (eabp-shell-views nil)
        (eabp-apps--registry nil)
        (eabp--ui-state (make-hash-table :test 'equal))
        (eabp--state-handlers (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'eabp-shell--schedule-repush) #'ignore))
      (with-eabp-owner "marks"
        (eabp-defaction "marks.jump" #'ignore)
        (eabp-shell-define-view "marks" :builder #'ignore))
      (eabp-ui-state-put "marks.q" "hi")
      (eabp-on-state-change "marks.q" #'ignore)
      (should (gethash "marks.jump" eabp-action-handlers))
      (should (assoc "marks" eabp-shell-views))
      (eabp-app-unregister "marks")
      (should-not (gethash "marks.jump" eabp-action-handlers))
      (should-not (assoc "marks" eabp-shell-views))
      (should-not (eabp-ui-state "marks.q"))
      (should-not (gethash "marks.q" eabp--state-handlers))
      (should-not (gethash "action:marks.jump" eabp--registration-owners)))))

(ert-deftest eabp-lint-types-cover-golden ()
  "Every `t' the constructors emit (per widgets.golden) is a known lint type.
Guards against a new constructor shipping a node the linter — and, by the
mirror invariant, the renderer's SDUI_NODE_TYPES — doesn't know about."
  (let ((golden (expand-file-name "widgets.golden" eabp-tests--dir))
        (seen nil))
    (with-temp-buffer
      (insert-file-contents golden)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim (buffer-substring (line-beginning-position)
                                                   (line-end-position)))))
          (when (and (> (length line) 0)
                     ;; lines are "NN {json}" — drop the leading index
                     (string-match "{.*}" line))
            (let* ((json (match-string 0 line))
                   (obj (ignore-errors
                          (json-parse-string json :object-type 'alist)))
                   (ty (and obj (alist-get 't obj))))
              (when ty (cl-pushnew ty seen :test #'equal)))))
        (forward-line 1)))
    (should seen)                       ; sanity: we actually parsed some
    (dolist (ty seen)
      (should (member ty eabp-lint-node-types)))))

(ert-deftest eabp-capability-invoke-roundtrip ()
  "capability.invoke correlates its reply and normalizes ok vs typed error."
  (let ((eabp--pending (make-hash-table :test 'equal))
        (eabp--process 'fake)
        (sent nil)
        (result nil))
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (p) (eq p 'fake)))
              ((symbol-function 'eabp--raw-send)
               (lambda (line) (push line sent))))
      ;; Success path: capability.result {ok: true} resolves with OK non-nil.
      (let ((id (eabp-capability-invoke
                 "settings.open" '((panel . "wifi"))
                 (lambda (ok payload) (setq result (list ok payload))))))
        (should (= (length sent) 1))
        (let* ((frame (json-parse-string (car sent)
                                         :object-type 'alist :array-type 'list
                                         :null-object :null :false-object :false))
               (payload (alist-get 'payload frame)))
          (should (equal (alist-get 'kind frame) "capability.invoke"))
          (should (equal (alist-get 'cap payload) "settings.open"))
          (should (equal (alist-get 'panel (alist-get 'args payload)) "wifi")))
        (eabp--handle-line
         (json-serialize
          `((v . 1) (id . "m-r-1") (reply_to . ,id)
            (kind . "capability.result") (payload . ((ok . t))))
          :null-object :null :false-object :false))
        (should (equal (car result) t)))
      ;; Error path: a typed error frame resolves with OK nil and the code.
      (setq result nil)
      (let ((id (eabp-capability-invoke
                 "flashlight" nil
                 (lambda (ok payload) (setq result (list ok payload))))))
        (eabp--handle-line
         (json-serialize
          `((v . 1) (id . "m-r-2") (reply_to . ,id)
            (kind . "error")
            (payload . ((code . "cap-unsupported")
                        (detail . "unknown capability 'flashlight'"))))
          :null-object :null :false-object :false))
        (should result)
        (should-not (car result))
        (should (equal (alist-get 'code (cadr result)) "cap-unsupported"))))))

(ert-deftest eabp-device-apps-list-parses-result ()
  "apps.list results become the (LABEL . PACKAGE) alist pickers want."
  (let (got)
    (cl-letf (((symbol-function 'eabp-capability-invoke)
               (lambda (cap _args callback)
                 (should (equal cap "apps.list"))
                 (funcall callback t
                          '((ok . t)
                            (result . ((apps . (((label . "Emacs")
                                                 (package . "org.gnu.emacs"))
                                                ((label . "Termux")
                                                 (package . "com.termux")))))))))))
      (eabp-device-apps-list (lambda (apps) (setq got apps))))
    (should (equal got '(("Emacs" . "org.gnu.emacs")
                         ("Termux" . "com.termux"))))))

(ert-deftest eabp-device-permissions-dialog-renders ()
  "The permissions dialog lists the perm map with grant deep-links."
  (let ((eabp--session
         '((granted . ("capabilities"))
           (device . ((caps . ("settings.open"))
                      (perms . ((write_settings . :false)
                                (notification_policy . :false)
                                (exact_alarms . t)))))))
        (sent nil))
    (cl-letf (((symbol-function 'eabp-send-dialog)
               (lambda (spec) (push spec sent))))
      (eabp-device-permissions-dialog))
    (let ((json (json-serialize (eabp-tests--canon (car sent))
                                :null-object :null :false-object :false)))
      (should (string-search "Device permissions" json))
      (should (string-search "MANAGE_WRITE_SETTINGS" json))
      (should (string-search "device.perm.open" json))
      ;; Granted rows carry no Grant button.
      (should (string-search "Exact alarms" json))
      (should (string-search "\"Granted\"" json)))))

(ert-deftest eabp-device-launch-app-uses-dialog ()
  "The app picker is a companion dialog dispatching device.launch."
  (let ((sent nil))
    (cl-letf (((symbol-function 'eabp-device-apps-list)
               (lambda (callback)
                 (funcall callback '(("Emacs" . "org.gnu.emacs")))))
              ((symbol-function 'eabp-send-dialog)
               (lambda (spec) (push spec sent))))
      (eabp-device-launch-app))
    (let ((json (json-serialize (eabp-tests--canon (car sent))
                                :null-object :null :false-object :false)))
      (should (string-search "device.launch" json))
      (should (string-search "org.gnu.emacs" json)))))

(ert-deftest eabp-device-clipboard-read-nil-on-error ()
  "A cap-permission clipboard failure yields nil, not an error."
  (let ((got 'untouched))
    (cl-letf (((symbol-function 'eabp-capability-invoke)
               (lambda (_cap _args callback)
                 (funcall callback nil '((code . "cap-permission")
                                         (detail . "backgrounded"))))))
      (eabp-device-clipboard-read (lambda (text) (setq got text))))
    (should-not got)))

;; ─── App identity (eabp-defapp, AUTO Task 14) ────────────────────────────────

(ert-deftest eabp-apps-single-app-zero-change ()
  "With one app registered, every view shows and the launcher is absent."
  (let ((eabp-apps--registry nil)
        (eabp-apps--current nil))
    (eabp-defapp "one" :label "One" :views '("agenda"))
    (should-not (eabp-apps--multi-p))
    (should (eabp-apps--view-visible-p "agenda"))
    (should (eabp-apps--view-visible-p "files"))
    ;; Even views claimed by nobody-in-particular show.
    (should (eabp-apps--view-visible-p "someone-elses-view"))))

(ert-deftest eabp-apps-multi-app-gating ()
  "From the second app on, only the current app's views (plus unclaimed
core views) are included."
  (let ((eabp-apps--registry nil)
        (eabp-apps--current nil))
    (eabp-defapp "glasspane" :views '("agenda" "tasks"))
    (eabp-defapp "hello" :views '("hello"))
    (should (eabp-apps--multi-p))
    ;; Equal :order keeps registration order: glasspane is the default.
    (should (equal (eabp-apps-current) "glasspane"))
    (should (eabp-apps--view-visible-p "agenda"))
    (should-not (eabp-apps--view-visible-p "hello"))
    (should (eabp-apps--view-visible-p "files")) ; unclaimed: everywhere
    (setq eabp-apps--current "hello")
    (should (eabp-apps--view-visible-p "hello"))
    (should-not (eabp-apps--view-visible-p "agenda"))
    ;; Removing the second app restores single-app behavior.
    (eabp-apps-remove "hello")
    (should (eabp-apps--view-visible-p "agenda"))))

(ert-deftest eabp-apps-bottom-bar-and-home-gating ()
  "The bottom bar shows one app's tabs; home enters the push multi-app only."
  (let ((eabp-apps--registry nil)
        (eabp-apps--current nil)
        (eabp-shell-views nil)
        (eabp-shell--current-tab nil))
    (eabp-shell-define-view "home" :builder #'eabp-apps--home-view
                            :when #'eabp-apps--multi-p :order 1)
    (eabp-shell-define-view "agenda" :builder #'ignore
                            :tab '(:icon "event" :label "Agenda") :order 10)
    (eabp-shell-define-view "hello" :builder #'ignore
                            :tab '(:icon "home" :label "Hello") :order 20)
    (eabp-defapp "glasspane" :views '("agenda"))
    ;; Single app: home hidden, both tabs visible (hello is unclaimed).
    (should-not (assoc "home" (eabp-shell--visible-views)))
    (should (= 2 (length (alist-get 'items (eabp-shell-bottom-bar "agenda")))))
    ;; Second app claims hello: home appears, bars split per app.
    (eabp-defapp "hello-app" :views '("hello"))
    (should (assoc "home" (eabp-shell--visible-views)))
    (should-not (assoc "hello" (eabp-shell--visible-views)))
    (let ((items (alist-get 'items (eabp-shell-bottom-bar "agenda"))))
      (should (= 1 (length items)))
      (should (equal (alist-get 'label (aref items 0)) "Agenda")))
    ;; The default landing tab respects the filter too.
    (should (equal (eabp-shell-current-tab) "agenda"))
    ;; The home grid builds one card per app.
    (should (eabp-apps--home-view nil))))

(ert-deftest eabp-apps-open-action-switches ()
  "app.open flips the current app and pushes onto its landing tab."
  (let ((eabp-apps--registry nil)
        (eabp-apps--current nil)
        (eabp-shell-views nil)
        (pushed nil))
    (eabp-shell-define-view "agenda" :builder #'ignore
                            :tab '(:icon "event" :label "Agenda") :order 10)
    (eabp-shell-define-view "hello" :builder #'ignore
                            :tab '(:icon "home" :label "Hello") :order 20)
    (eabp-defapp "glasspane" :views '("agenda"))
    (eabp-defapp "hello-app" :views '("hello"))
    (cl-letf (((symbol-function 'eabp-shell-push)
               (cl-function
                (lambda (&optional tab &key switch-to)
                  (setq pushed (list tab switch-to))))))
      (eabp--on-action '((action . "app.open")
                         (args . ((app . "hello-app"))))
                       nil)
      (should (equal (eabp-apps-current) "hello-app"))
      (should (equal pushed '("hello" "hello")))
      ;; Unknown apps are dropped, never switched to.
      (eabp--on-action '((action . "app.open") (args . ((app . "nope")))) nil)
      (should (equal (eabp-apps-current) "hello-app")))))

;; ─── Protocol frame shapes (golden snapshot, SPEC §10–§11) ──────────────────

(defconst eabp-tests--frames-golden-file
  (expand-file-name "frames.golden" eabp-tests--dir))

(defun eabp-tests--device-cases ()
  "One `capability.invoke' payload per `eabp-device-*' wrapper.
Captures what each thin defun hands the funnel — the SPEC §10 arg
shapes — without touching the wire."
  (let (calls)
    (cl-letf (((symbol-function 'eabp-device--invoke)
               (lambda (cap args &optional _callback)
                 (push `((kind . "capability.invoke")
                         (payload
                          . ((cap . ,cap)
                             (args . ,(or args (make-hash-table
                                                :test 'equal))))))
                       calls))))
      (eabp-device-intent :action "android.intent.action.VIEW"
                          :data "https://example.com")
      (eabp-device-intent :package "com.termux"
                          :class-name "com.termux.app.TermuxActivity"
                          :mode "activity"
                          :extras '((com.example.FLAG . t)
                                    (com.example.COUNT . 3)))
      (eabp-device-app-launch "org.gnu.emacs")
      (eabp-device-apps-list #'ignore)
      (eabp-device-vibrate 300)
      (eabp-device-vibrate nil '(0 100 50 100))
      (eabp-device-tts "hello" :pitch 1.2 :rate 0.9)
      (eabp-device-volume-set "music" 5)
      (eabp-device-ringer-mode "vibrate")
      (eabp-device-flashlight t)
      (eabp-device-flashlight nil)
      (eabp-device-media-key "play_pause")
      (eabp-device-clipboard-read #'ignore)
      (eabp-device-settings-open "wifi")
      (eabp-device-keep-screen-on t)
      (eabp-device-brightness 128)
      (eabp-device-dnd "priority"))
    (nreverse calls)))

(defun eabp-tests--frame-cases ()
  "Outbound protocol frame payloads pinned by test/frames.golden.
Trigger and capability frames today; new wire frames add cases here."
  (let ((eabp-triggers--table (make-hash-table :test 'equal)))
    ;; Batch Emacs is disconnected, so these registers never send.
    (eabp-trigger-register "power-sync" :type "power"
                           :params '((state . "connected"))
                           :policy "wake" :dedupe "power-sync" :throttle-s 60
                           :on-fire [((cap . "flashlight")
                                      (args . ((on . t))))])
    (eabp-trigger-register "screen-off" :type "screen"
                           :params '((state . "off")))
    (append
     (list
      `((kind . "triggers.set")
        (payload . ((triggers . ,(eabp-triggers--specs))))))
     (eabp-tests--device-cases))))

(defun eabp-tests--frame-lines ()
  (let ((i -1))
    (mapcar (lambda (c)
              (setq i (1+ i))
              (format "%02d %s" i
                      (json-serialize (eabp-tests--canon c)
                                      :null-object :null
                                      :false-object :false)))
            (eabp-tests--frame-cases))))

(defun eabp-tests-regen-frame-golden ()
  "Rewrite the frame golden snapshot from the current senders.
Only run this after an INTENTIONAL wire-format change; review the diff."
  (with-temp-file eabp-tests--frames-golden-file
    (insert (string-join (eabp-tests--frame-lines) "\n") "\n"))
  (message "Wrote %s" eabp-tests--frames-golden-file))

(ert-deftest eabp-frames-wire-format ()
  "Trigger/capability frame payloads match the committed golden snapshot."
  (should (file-readable-p eabp-tests--frames-golden-file))
  (should (equal (eabp-tests--frame-lines)
                 (split-string
                  (with-temp-buffer
                    (insert-file-contents eabp-tests--frames-golden-file)
                    (buffer-string))
                  "\n" t))))

;; ─── Journal (PKM Task 5) ────────────────────────────────────────────────────

;; ─── Saved views (PKM Task 11) ───────────────────────────────────────────────

(defun eabp-tests--views-items ()
  "Synthetic heading items exercising all three renderings."
  '(((headline . "Write spec") (todo . "TODO") (tags . ["work"])
     (scheduled . "<2026-07-04 Sat>")
     (ref . ((file . "/tmp/a.org") (pos . 1) (headline . "Write spec"))))
    ((headline . "Ship it") (todo . "NEXT") (tags . [])
     (scheduled . nil)
     (ref . ((file . "/tmp/a.org") (pos . 50) (headline . "Ship it"))))))

;; ─── Org-defined automations (AUTO Task 13) ──────────────────────────────────

(defmacro eabp-tests--with-automations-file (content &rest body)
  "Run BODY with a temp automations file holding CONTENT."
  (declare (indent 1))
  `(let* ((file (make-temp-file "eabp-autom" nil ".org"))
          (glasspane-automations-file file)
          (glasspane-automations--ids nil)
          (eabp-triggers--table (make-hash-table :test 'equal))
          (eabp-triggers-changed-hook nil))
     (unwind-protect
         (progn (with-temp-file file (insert ,content))
                ,@body)
       (when-let ((buf (find-buffer-visiting file))) (kill-buffer buf))
       (delete-file file))))

;; ─── Sparse filter (orgro parity) ────────────────────────────────────────────

;; ─── Notes bridge: wikilinks + backlinks (PKM 3–4, vulpea mocked) ────────────

(defmacro eabp-tests--with-fake-vulpea (notes &rest body)
  "Run BODY with the vulpea seam answering from NOTES (plists)."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'glasspane-notes-available-p) (lambda () t))
             ((symbol-function 'vulpea-db-search-by-title)
              (lambda (pattern)
                (cl-remove-if-not
                 (lambda (n) (string-match-p (regexp-quote (downcase pattern))
                                             (downcase (plist-get n :title))))
                 ,notes)))
             ((symbol-function 'vulpea-db-query-by-links-some)
              (lambda (_ids &optional _type) ,notes))
             ((symbol-function 'vulpea-db-get-by-id)
              (lambda (id)
                (cl-find id ,notes
                         :key (lambda (n) (plist-get n :id))
                         :test #'equal)))
             ((symbol-function 'vulpea-note-id)
              (lambda (n) (plist-get n :id)))
             ((symbol-function 'vulpea-note-title)
              (lambda (n) (plist-get n :title)))
             ((symbol-function 'vulpea-note-path)
              (lambda (n) (plist-get n :path)))
             ((symbol-function 'vulpea-note-aliases)
              (lambda (n) (plist-get n :aliases))))
     ,@body))

;; ─── SRS skin: review over org-srs (org-srs mocked) ──────────────────────────

(ert-deftest eabp-buffer-overlay-hiding-fidelity ()
  "The generic renderer honors overlay `display' and `invisible' —
the property the whole SRS skin rests on: org-srs hides answers with
exactly these, so the phone must show the ellipsis, never the answer."
  (with-temp-buffer
    (insert "Front text\nAnswer text\nFolded text\n")
    (add-to-invisibility-spec 'eabp-test-fold)
    ;; Card-style hiding: the answer displays as an ellipsis.
    (let ((ov (make-overlay 12 23)))        ; "Answer text"
      (overlay-put ov 'display "..."))
    ;; Fold-style hiding: the region is invisible.
    (let ((ov (make-overlay 24 35)))        ; "Folded text"
      (overlay-put ov 'invisible 'eabp-test-fold))
    (let ((json (json-serialize
                 (eabp-tests--canon (apply #'eabp-column (eabp-buffer-render)))
                 :null-object :null :false-object :false)))
      (should (string-search "Front text" json))
      (should (string-search "..." json))
      (should-not (string-search "Answer text" json))
      (should-not (string-search "Folded text" json)))))

(defvar eabp-tests--srs-items nil "The mocked pending queue (item-args).")
(defvar eabp-tests--srs-rated nil "Ratings recorded by the mock engine.")

(defmacro eabp-tests--with-fake-org-srs (&rest body)
  "Run BODY with a minimal org-srs *engine* mock.
`eabp-tests--srs-items' is the pending queue (a list of item-args);
`eabp-tests--srs-rated' records ratings.  Session state is reset per
invocation; per-item positions (markers, regions, clozes) are mocked
in individual tests where needed."
  (declare (indent 0))
  `(let ((glasspane-srs--available t)
         (glasspane-srs--active nil)
         (glasspane-srs--current nil)
         (glasspane-srs--revealed nil)
         (glasspane-srs--undo nil)
         (eabp-tests--srs-items nil)
         (eabp-tests--srs-rated nil)
         (eabp-shell--snackbar nil))
     (cl-letf (((symbol-function 'org-srs-review-pending-items)
                (lambda (&optional _) eabp-tests--srs-items))
               ((symbol-function 'org-srs-item-marker)
                (lambda (&rest _) (copy-marker (point-min))))
               ((symbol-function 'org-srs-review-rate)
                (lambda (rating &rest _) (push rating eabp-tests--srs-rated)))
               ((symbol-function 'org-srs-item-call-with-current)
                (lambda (thunk &rest _) (funcall thunk)))
               ((symbol-function 'org-srs-table-goto-column)
                (lambda (_) t))
               ((symbol-function 'org-srs-stats-intervals)
                (lambda () '(:again 600 :hard 86400 :good 259200 :easy 604800)))
               ((symbol-function 'org-srs-time-seconds-desc)
                (lambda (secs) (list (/ secs 60) :minute)))
               ((symbol-function 'eabp-shell-push)
                (cl-function (lambda (&optional _tab &key _switch-to)))))
       ,@body)))

; heading line stripped

(provide 'eabp-tests)
;;; eabp-tests.el ends here
