;;; jetpacs-tests.el --- ERT suite for the Jetpacs core client -*- lexical-binding: t; -*-

;; Run from the repo root (any Emacs 28+):
;;   emacs -Q --batch -l test/jetpacs-tests.el -f ert-run-tests-batch-and-exit
;; or via test/run-tests.sh.
;;
;; This suite covers the Jetpacs core (emacs/core/). The Glasspane app's tests
;; live in the separate glasspane repo (test/glasspane-tests.el).
;;
;; The widget wire-format test compares every constructor against the
;; committed golden snapshot (test/widgets.golden).  After an INTENTIONAL
;; wire-format change, regenerate it with:
;;   emacs -Q --batch -l test/jetpacs-tests.el -f jetpacs-tests-regen-widget-golden

;;; Code:

(defvar jetpacs-tests--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(dolist (dir '("../emacs/core" "../emacs/apps"))
  (add-to-list 'load-path (expand-file-name dir jetpacs-tests--dir)))

(require 'ert)
(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-triggers)
(require 'jetpacs-device)
(require 'jetpacs-apps)
(require 'jetpacs-widgets)
(require 'jetpacs-lint)
(require 'jetpacs-shell)
(require 'jetpacs-keymap)
(require 'jetpacs-results)
(require 'jetpacs-files)
(require 'jetpacs-minibuffer)
(require 'jetpacs-emacs-ui)
(require 'jetpacs-complete)
(require 'jetpacs-sync)
(require 'jetpacs-settings)
(require 'jetpacs-theme)
(require 'jetpacs-automations)

;; ─── Capture ────────────────────────────────────────────────────────────────

;; ─── Reminders ──────────────────────────────────────────────────────────────

;; ─── Widget items ───────────────────────────────────────────────────────────

;; ─── Extraction cache ───────────────────────────────────────────────────────

;; ─── Files sandbox ──────────────────────────────────────────────────────────

(ert-deftest jetpacs-files-roots-boundary ()
  "Sibling-prefix directories and parent traversal must be rejected."
  (let ((jetpacs-files-roots '(("R" . "/tmp/jetpacs-root/"))))
    (make-directory "/tmp/jetpacs-root" t)
    (make-directory "/tmp/jetpacs-root-evil" t)
    (should (jetpacs-files--within-root-p "/tmp/jetpacs-root/notes.org"))
    (should (jetpacs-files--within-root-p "/tmp/jetpacs-root"))
    (should-not (jetpacs-files--within-root-p "/tmp/jetpacs-root-evil/x.org"))
    (should-not (jetpacs-files--within-root-p "/tmp/jetpacs-root/../etc/passwd"))))

(ert-deftest jetpacs-files-shared-storage-root ()
  "An accessible shared-storage dir is detected and authorized as a root;
disabling it (`nil') detects nothing and authorizes nothing."
  (let* ((dir (file-name-as-directory (make-temp-file "jetpacs-shared" t)))
         (probe (expand-file-name "x.org" dir)))
    (unwind-protect
        (progn
          ;; An explicit, accessible path is detected and added to the roots,
          ;; so the within-root guard now clears files beneath it.
          (let ((jetpacs-files-shared-storage dir)
                (jetpacs-files--shared-dir 'unset)
                (jetpacs-files-roots nil))
            (should (equal (jetpacs-files-shared-dir) dir))
            (should (jetpacs-files--within-root-p probe)))
          ;; Disabled: no detection, no root, nothing authorized.
          (let ((jetpacs-files-shared-storage nil)
                (jetpacs-files--shared-dir 'unset)
                (jetpacs-files-roots nil))
            (should-not (jetpacs-files-shared-dir))
            (should-not (jetpacs-files--within-root-p probe))))
      (delete-directory dir t))))

;; ─── Keymap labels ──────────────────────────────────────────────────────────

(ert-deftest jetpacs-keymap-labels ()
  "Labels strip only the current major mode's stem."
  (with-temp-buffer
    (let ((major-mode 'org-mode))
      (should (equal (jetpacs-keymap--command-label 'org-agenda-list) "agenda-list"))
      (should (equal (jetpacs-keymap--command-label 'forward-paragraph)
                     "forward-paragraph")))
    (let ((major-mode 'magit-status-mode))
      (should (equal (jetpacs-keymap--command-label 'magit-stage) "stage")))
    (let ((major-mode 'fundamental-mode))
      (should (equal (jetpacs-keymap--command-label 'org-agenda-list)
                     "org-agenda-list")))))

;; ─── Agenda extraction ──────────────────────────────────────────────────────

;; ─── Search: query parsing, matching, builder ───────────────────────────────

(defmacro jetpacs-tests--with-search-fixture (&rest body)
  "Run BODY with a temp org agenda file of known headings."
  `(let ((file (make-temp-file "jetpacs-search" nil ".org")))
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

(defun jetpacs-tests--search-headlines (query)
  "Headlines returned for QUERY, in file order."
  (mapcar (lambda (it) (alist-get 'headline it))
          (glasspane-org--search query)))

;; ─── Agenda date arithmetic & widgets ───────────────────────────────────────

;; ─── Prompt dialogs ─────────────────────────────────────────────────────────

(ert-deftest jetpacs-prompt-dialog-merge ()
  "Context cards merge INTO a lazy_column body — nesting crashes the client."
  (let (sent)
    (cl-letf (((symbol-function 'jetpacs-send-dialog)
               (lambda (spec) (setq sent spec))))
      (with-current-buffer (get-buffer-create "*ctx*")
        (erase-buffer)
        (insert "context text"))
      (unwind-protect
          (let ((jetpacs-minibuffer--context-buffers '("*ctx*")))
            (jetpacs--send-prompt-dialog "p1" (jetpacs-lazy-column (jetpacs-text "hi")))
            (should (equal (alist-get 't sent) "lazy_column"))
            (let ((children (append (alist-get 'children sent) nil)))
              (should (= (length children) 2))
              (should-not (cl-some (lambda (c)
                                     (equal (alist-get 't c) "lazy_column"))
                                   children)))
            (jetpacs--send-prompt-dialog "p2" (jetpacs-column (jetpacs-text "hi")))
            (should (equal (alist-get 't sent) "lazy_column")))
        (kill-buffer "*ctx*")))))

;; ─── Tier 1 keymap menus ────────────────────────────────────────────────────

;; ─── Buffer-view line numbers ───────────────────────────────────────────────

(require 'jetpacs-buffer)

(defun jetpacs-tests--first-span-text (node)
  (alist-get 'text (aref (alist-get 'spans node) 0)))

(ert-deftest jetpacs-buffer-line-numbers ()
  "Absolute and relative (hybrid) gutter spans on the Tier 0 renderer."
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (goto-char (point-min))
    (forward-line 1)                    ; point on line 2 ("beta")
    (let ((jetpacs-line-numbers 'absolute))
      (let ((nodes (jetpacs-buffer-render (current-buffer))))
        (should (equal (jetpacs-tests--first-span-text (nth 0 nodes)) "1 "))
        (should (equal (jetpacs-tests--first-span-text (nth 2 nodes)) "3 "))))
    (let ((jetpacs-line-numbers 'relative))
      (let ((nodes (jetpacs-buffer-render (current-buffer))))
        ;; distance 1 above point; point's line shows its absolute number
        (should (equal (jetpacs-tests--first-span-text (nth 0 nodes)) "1 "))
        (should (equal (jetpacs-tests--first-span-text (nth 1 nodes)) "2 "))
        (should (equal (jetpacs-tests--first-span-text (nth 2 nodes)) "1 "))))
    (let ((jetpacs-line-numbers nil))
      (let ((nodes (jetpacs-buffer-render (current-buffer))))
        (should (equal (jetpacs-tests--first-span-text (nth 0 nodes)) "alpha"))))))

;; ─── Messages view ──────────────────────────────────────────────────────────

(ert-deftest jetpacs-messages-zebra ()
  "Messages rows alternate plain/striped and stay selectable."
  (let ((plain (jetpacs-emacs-ui--messages-line "one" nil))
        (striped (jetpacs-emacs-ui--messages-line "two" t)))
    (should (equal (alist-get 't plain) "text"))
    (should (alist-get 'selectable plain))
    (should (equal (alist-get 't striped) "surface"))
    (should (equal (alist-get 'color striped) "surface_container"))
    (should (alist-get 'fill striped))
    (should (stringp (json-serialize (jetpacs-emacs-ui--messages-body)
                                     :null-object :null
                                     :false-object :false)))))

;; ─── Detail-view properties editor ──────────────────────────────────────────

;; ─── Shell ──────────────────────────────────────────────────────────────────

(ert-deftest jetpacs-shell-broken-view-isolated ()
  "A view builder that signals renders an error view; the push survives.
The live-coding contract: a broken Tier 1 view costs its own screen."
  (let ((built (jetpacs-shell--build-view
                "boom" (list :builder (lambda (_) (error "kaput"))) nil)))
    ;; It is still a well-formed scaffold view carrying the error text.
    (should (alist-get 'children built))
    (should (string-match-p "kaput" (format "%S" built))))
  ;; Broken :when / :overlay predicates count as nil, not as a crash.
  (let ((jetpacs-shell-views
         (list (cons "bad-pred"
                     (list :builder (lambda (_) nil)
                           :when (lambda () (error "pred boom"))
                           :overlay (lambda () (error "pred boom"))
                           :order 1)))))
    (should-not (jetpacs-shell--visible-views))
    (should-not (jetpacs-shell--active-view))))

;; ─── Transport ──────────────────────────────────────────────────────────────

(ert-deftest jetpacs-request-no-leak ()
  "Requests sent while disconnected must not leak pending callbacks."
  (let ((jetpacs--process nil))
    (clrhash jetpacs--pending)
    (jetpacs-request "ping" nil #'ignore)
    (should (= (hash-table-count jetpacs--pending) 0))))

;; ─── Toast forwarding ───────────────────────────────────────────────────────

(ert-deftest jetpacs-toast-throttle ()
  "Messages mirror as toasts: throttled, latest-wins, Jetpacs noise filtered."
  (let ((sent nil)
        (jetpacs-forward-messages t)
        (jetpacs-emacs-ui--toast-last 0)
        (jetpacs-emacs-ui--toast-timer nil)
        (jetpacs-emacs-ui--toast-pending nil))
    (cl-letf (((symbol-function 'jetpacs-connected-p) (lambda () t))
              ((symbol-function 'jetpacs-send)
               (lambda (_kind payload &rest _)
                 (push (alist-get 'text payload) sent))))
      (jetpacs-emacs-ui--message-advice "hello %s" "world")
      (should (equal sent '("hello world")))
      ;; Inside the throttle window: held as pending, not sent.
      (jetpacs-emacs-ui--message-advice "again")
      (should (equal sent '("hello world")))
      (should (equal jetpacs-emacs-ui--toast-pending "again"))
      (should (timerp jetpacs-emacs-ui--toast-timer))
      (cancel-timer jetpacs-emacs-ui--toast-timer)
      ;; Bridge-internal messages never bounce back to the phone.
      (setq jetpacs-emacs-ui--toast-last 0)
      (jetpacs-emacs-ui--message-advice "Jetpacs: internal chatter")
      (should (= (length sent) 1)))))

;; ─── Completion bridge ──────────────────────────────────────────────────────

(ert-deftest jetpacs-complete-elisp-capf ()
  "The elisp shadow buffer completes symbols from the live obarray."
  (let* ((text "(defun f () (buffer-substring-no")
         (result (jetpacs-complete-in-text "test.el" text (length text))))
    (should result)
    (should (equal (car result) "buffer-substring-no"))
    (should (cl-find "buffer-substring-no-properties" (cdr result)
                     :key (lambda (c) (alist-get 'label c))
                     :test #'equal))))

(ert-deftest jetpacs-complete-word-fallback ()
  "Modes with no useful capf fall back to same-buffer word completion."
  (let* ((text "alphabet soup is alphabetical\nalp")
         (result (jetpacs-complete-in-text "notes.txt" text (length text))))
    (should result)
    (should (equal (car result) "alp"))
    (let ((labels (mapcar (lambda (c) (alist-get 'label c)) (cdr result))))
      (should (member "alphabet" labels))
      (should (member "alphabetical" labels)))))

(ert-deftest jetpacs-complete-nothing-without-token ()
  "No token before the cursor → nil, so the phone strip stays hidden."
  (should-not (jetpacs-complete-in-text "notes.txt" "hello world " 12)))

(ert-deftest jetpacs-complete-candidates-capped ()
  "Candidate lists respect `jetpacs-complete-max-candidates'."
  (let* ((jetpacs-complete-max-candidates 3)
         ;; "def" prefixes hundreds of elisp symbols (defun, defvar, ...).
         (text "(def")
         (result (jetpacs-complete-in-text "cap.el" text (length text))))
    (should result)
    (should (<= (length (cdr result)) 3))))

(ert-deftest jetpacs-complete-shadow-buffer-reused ()
  "One hidden shadow buffer per file, reused across requests."
  (jetpacs-complete-in-text "reuse.el" "(car" 4)
  (let ((count (cl-count-if
                (lambda (b) (string-search "jetpacs-complete: reuse.el"
                                           (buffer-name b)))
                (buffer-list))))
    (jetpacs-complete-in-text "reuse.el" "(cdr" 4)
    (should (= count (cl-count-if
                      (lambda (b) (string-search "jetpacs-complete: reuse.el"
                                                 (buffer-name b)))
                      (buffer-list))))))

;; ─── Editor sync (v2) ───────────────────────────────────────────────────────

(ert-deftest jetpacs-sync-open-and-delta ()
  "edit.open seeds the shadow; a seq-1 delta splices it correctly."
  (let ((jetpacs-sync-diagnostics nil)
        (file "sync-test.el"))
    (unwind-protect
        (progn
          (jetpacs-sync-open file 7 "(defun foo ())")
          (should (jetpacs-sync-session-buffer file 7 0))
          ;; Replace "foo" (3 code points at offset 7) with "bar-baz".
          (should (jetpacs-sync-apply-delta file 7 1 7 3 "bar-baz" 18))
          (with-current-buffer (jetpacs-sync-session-buffer file 7 1)
            (should (equal (buffer-string) "(defun bar-baz ())")))
          ;; The old seq no longer matches.
          (should-not (jetpacs-sync-session-buffer file 7 0)))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-code-point-offsets ()
  "Delta offsets are code points, so astral chars can't skew positions.
The phone sends offset 2 for the char after an emoji even though its
UTF-16 index there is 3."
  (let ((jetpacs-sync-diagnostics nil)
        (file "sync-emoji.txt")
        (text (string ?a #x1F600 ?b ?c)))
    (unwind-protect
        (progn
          (jetpacs-sync-open file 9 text)
          (should (jetpacs-sync-apply-delta file 9 1 2 1 "XY" 5))
          (with-current-buffer (jetpacs-sync-session-buffer file 9 1)
            (should (equal (buffer-string) (string ?a #x1F600 ?X ?Y ?c)))))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-mismatch-goes-stale ()
  "A wrong seq requests one resync; the stale session swallows the rest."
  (let ((jetpacs-sync-diagnostics nil)
        (file "sync-stale.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (jetpacs-sync-open file 3 "abc")
          ;; seq 2 arrives but 1 was expected.
          (should-not (jetpacs-sync-apply-delta file 3 2 0 0 "x" 4))
          (should (equal (caar sent) "edit.resync"))
          (should-not (jetpacs-sync-session file))
          ;; The rest of the in-flight burst is swallowed silently.
          (setq sent nil)
          (should-not (jetpacs-sync-apply-delta file 3 3 0 0 "y" 5))
          (should-not sent)
          ;; A fresh open recovers the session.
          (jetpacs-sync-open file 4 "xyz")
          (should (jetpacs-sync-session-buffer file 4 0)))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-complete-in-session ()
  "Slim completion completes in the synced shadow at a bare cursor offset."
  (let ((jetpacs-sync-diagnostics nil)
        (file "sync-complete.el"))
    (unwind-protect
        (progn
          (jetpacs-sync-open file 11 "(buffer-subst")
          (let ((result (jetpacs-complete-in-session file 11 0 13)))
            (should result)
            (should (equal (car result) "buffer-subst"))
            (should (cl-find "buffer-substring-no-properties" (cdr result)
                             :key (lambda (c) (alist-get 'label c))
                             :test #'equal))))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-complete-in-session-rejects-stale ()
  "Completion against a mismatched seq returns nil and asks for resync."
  (let ((jetpacs-sync-diagnostics nil)
        (file "sync-complete-stale.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (jetpacs-sync-open file 5 "(car")
          (should-not (jetpacs-complete-in-session file 5 99 4))
          (should (cl-find "edit.resync" sent :key #'car :test #'equal)))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-eldoc-push ()
  "Eldoc at a synced cursor pushes an elisp signature to the phone."
  (let ((jetpacs-sync-diagnostics nil)
        (file "eldoc-test.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (jetpacs-sync-open file 21 "(buffer-substring ")
          (with-current-buffer (jetpacs-sync-session-buffer file 21 0)
            (save-excursion
              (goto-char (point-max))
              (jetpacs-sync--run-eldoc file 21)))
          (let ((push (cdr (assoc "eldoc.show" sent))))
            (should push)
            (should (string-search "buffer-substring" (alist-get 'text push)))
            (should (string-search "START" (alist-get 'text push)))))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-eglot-real-file-session ()
  "LSP-able files sync into their REAL buffer — eglot's substrate.
The session buffer visits the file, deltas splice it, and close leaves
the buffer alive (it may be the user's, and it keeps the server warm)."
  (let ((jetpacs-sync-diagnostics nil)
        (jetpacs-sync-eglot t)
        (file (make-temp-file "jetpacs-eglot" nil ".py")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "x = 1\n"))
          (jetpacs-sync-open file 51 "x = 1\n")
          (let ((buf (jetpacs-sync-session-buffer file 51 0)))
            (should buf)
            (should (equal (file-truename (buffer-file-name buf))
                           (file-truename file)))
            (should (with-current-buffer buf
                      (derived-mode-p 'python-mode)))
            ;; Replace "1" (offset 4) with "42" — splices the real buffer.
            (should (jetpacs-sync-apply-delta file 51 1 4 1 "42" 7))
            (should (equal (with-current-buffer buf (buffer-string))
                           "x = 42\n"))
            (jetpacs-sync-close file)
            (should (buffer-live-p buf))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (ignore-errors (delete-file file)))))

(ert-deftest jetpacs-sync-shadow-setup-hook-runs ()
  "The setup hook runs in fresh shadows, letting config opt capfs back in."
  (let* ((jetpacs-sync-diagnostics nil)
         (file "hook-test.el")
         (ran nil)
         (jetpacs-sync-shadow-setup-hook
          (list (lambda () (setq ran (list major-mode (buffer-name)))))))
    (unwind-protect
        (progn
          (jetpacs-sync-open file 13 "x")
          (should ran)
          (should (eq (car ran) 'emacs-lisp-mode)))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-flymake-elisp-backend ()
  "The in-process backend flags wrong arity and unbalanced parens."
  (let ((jetpacs-sync-diagnostics nil)
        (file "flymake-test.el"))
    (unwind-protect
        (progn
          ;; Wrong arity: `f' takes one argument, `g' passes two.
          (jetpacs-sync-open file 31 "(defun f (x) x)\n(defun g () (f 1 2))\n")
          (with-current-buffer (jetpacs-sync-session-buffer file 31 0)
            (let (got)
              (jetpacs-sync--flymake-elisp (lambda (diags &rest _) (setq got diags)))
              (should got)
              (should (cl-some (lambda (d)
                                 (string-match-p "f" (flymake-diagnostic-text d)))
                               got))))
          ;; Unbalanced parens: reported as an error, without compiling.
          (jetpacs-sync-open file 32 "(defun broken () ")
          (with-current-buffer (jetpacs-sync-session-buffer file 32 0)
            (let (got)
              (jetpacs-sync--flymake-elisp (lambda (diags &rest _) (setq got diags)))
              (should got)
              (should (eq (flymake-diagnostic-type (car got)) :error)))))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-diagnostics-pipeline ()
  "Broken elisp in a synced shadow produces a diagnostics.show push."
  (let ((jetpacs-sync-diagnostics t)
        (file "diag-pipe.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent))))
          (jetpacs-sync-open file 41 "(defun f (x) x)\n(defun g () (f 1 2))\n")
          (with-current-buffer (jetpacs-sync-session-buffer file 41 0)
            (should flymake-mode)
            ;; The backend is synchronous, but flymake publishes through
            ;; its own machinery — give the timers a moment.
            (let ((deadline (+ (float-time) 5)))
              (while (and (null (flymake-diagnostics))
                          (< (float-time) deadline))
                (sit-for 0.1)))
            (should (flymake-diagnostics)))
          (jetpacs-sync--collect-and-push file)
          (let ((push (cdr (assoc "diagnostics.show" sent))))
            (should push)
            (should (> (length (alist-get 'diags push)) 0)))
          ;; Content-identical diagnostics must STILL re-push after an edit:
          ;; the phone's render gate is seq-keyed, so the break-then-undo
          ;; scenario needs a fresh push even when nothing changed. This
          ;; append-a-space delta leaves every diagnostic position intact.
          (setq sent nil)
          (should (jetpacs-sync-apply-delta file 41 1 37 0 " " 38))
          (with-current-buffer (jetpacs-sync-session-buffer file 41 1)
            (let ((deadline (+ (float-time) 5)))
              (while (and (null (flymake-diagnostics))
                          (< (float-time) deadline))
                (sit-for 0.1))))
          (jetpacs-sync--collect-and-push file)
          (let ((push (cdr (assoc "diagnostics.show" sent))))
            (should push)
            (should (equal (alist-get 'seq push) 1))))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-complete-empty-prefix-policy ()
  "Empty prefixes: small precise tables (LSP members) pass, obarray doesn't."
  ;; A small table at point — the shape of member completion after ".".
  (with-temp-buffer
    (setq-local completion-at-point-functions
                (list (lambda () (list (point) (point)
                                       '("append" "clear" "copy")))))
    (insert "xs.")
    (goto-char (point-max))
    (let ((r (jetpacs-complete--collect)))
      (should r)
      (should (equal (car r) ""))
      (should (= (length (cdr r)) 3))))
  ;; The unconstrained obarray right after "(" still yields nothing.
  (should-not (jetpacs-complete-in-text "guard.el" "(" 1)))

(ert-deftest jetpacs-complete-python-word-fallback ()
  "Python files complete same-buffer identifiers via the word fallback."
  (let* ((text "def fibonacci(n):\n    return n\n\nfib")
         (result (jetpacs-complete-in-text "demo.py" text (length text))))
    (should result)
    (should (equal (car result) "fib"))
    (should (cl-find "fibonacci" (cdr result)
                     :key (lambda (c) (alist-get 'label c))
                     :test #'equal))))

(ert-deftest jetpacs-sync-fontify-push ()
  "Fontification pushes on open and re-pushes per seq (stamp includes seq)."
  (let ((jetpacs-sync-diagnostics nil)
        (jetpacs-sync-fontify t)
        (file "fontify-test.el")
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-send)
                   (lambda (kind payload &rest _)
                     (push (cons kind payload) sent)))
                  ;; Batch Emacs resolves no face colors; stub the style so
                  ;; the walk itself is what's under test.
                  ((symbol-function 'jetpacs-buffer--span-style)
                   (lambda (face) (and face '(:bold t)))))
          (jetpacs-sync-open file 61 "(defun foo ())")
          (let ((push (cdr (assoc "fontify.show" sent))))
            (should push)
            (should (> (length (alist-get 'runs push)) 0))
            (let ((r (aref (alist-get 'runs push) 0)))
              (should (numberp (alist-get 'b r)))
              (should (> (alist-get 'e r) (alist-get 'b r)))))
          ;; Content-identical runs still re-push after an edit — the
          ;; phone's render gate is seq-keyed, exactly like diagnostics.
          (setq sent nil)
          (should (jetpacs-sync-apply-delta file 61 1 14 0 " " 15))
          (should (assoc "fontify.show" sent)))
      (jetpacs-sync-close file))))

(ert-deftest jetpacs-sync-mode-remap-respected ()
  "Shadow mode selection honors `major-mode-remap-alist' (ts modes)."
  (let ((major-mode-remap-alist '((emacs-lisp-mode . lisp-interaction-mode))))
    (should (eq (jetpacs-sync--mode-for "x.el") 'lisp-interaction-mode)))
  (let ((major-mode-remap-alist nil))
    (should (eq (jetpacs-sync--mode-for "x.el") 'emacs-lisp-mode))))

(ert-deftest jetpacs-sync-severity-mapping ()
  "Flymake types normalize to the three wire severities."
  (should (equal (jetpacs-sync--severity :error) "error"))
  (should (equal (jetpacs-sync--severity :warning) "warning"))
  (should (equal (jetpacs-sync--severity :note) "note"))
  ;; Unknown types degrade to warning, never crash.
  (should (equal (jetpacs-sync--severity 'no-such-type) "warning")))

;; ─── Pairing auth ───────────────────────────────────────────────────────────

(ert-deftest jetpacs-hmac-sha256-rfc-vectors ()
  "The pure-elisp HMAC matches RFC 4231 / classic test vectors."
  ;; RFC 4231 test case 2 (short key).
  (should (equal (jetpacs--hmac-sha256-hex "Jefe" "what do ya want for nothing?")
                 "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
  ;; The classic quick-brown-fox vector.
  (should (equal (jetpacs--hmac-sha256-hex
                  "key" "The quick brown fox jumps over the lazy dog")
                 "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"))
  ;; RFC 4231 test case 6: key longer than the block size (hash-first path).
  ;; The key must be RAW 0xAA bytes — a multibyte (make-string 131 ?\xaa)
  ;; would UTF-8-encode to two bytes per char and break the vector.
  (should (equal (jetpacs--hmac-sha256-hex
                  (apply #'unibyte-string (make-list 131 #xaa))
                  "Test Using Larger Than Block-Size Key - Hash Key First")
                 "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")))

(ert-deftest jetpacs-auth-handshake-round-trip ()
  "Challenge → response → proof, both directions, plus the failure modes."
  (let ((jetpacs-auth-token "ABCD-EFGH-JKMN-PQRS")
        (jetpacs--auth-server-nonce nil)
        (jetpacs--auth-client-nonce nil)
        (sent nil))
    (cl-letf (((symbol-function 'jetpacs-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      ;; The challenge produces a response with the right MAC.
      (jetpacs--on-auth-challenge '((nonce . "deadbeef")))
      (let* ((resp (cdr (assoc "auth.response" sent)))
             (cnonce (alist-get 'nonce resp)))
        (should resp)
        (should (equal (alist-get 'mac resp)
                       (jetpacs--hmac-sha256-hex
                        jetpacs-auth-token
                        (format "jetpacs1:client:deadbeef:%s" cnonce))))
        ;; A welcome carrying the matching server proof verifies…
        (should (jetpacs--auth-verify-welcome
                 `((server_proof
                    . ,(jetpacs--hmac-sha256-hex
                        jetpacs-auth-token
                        (format "jetpacs1:server:%s:deadbeef" cnonce))))))
        ;; …a wrong or missing proof is refused (fail closed)…
        (should-not (jetpacs--auth-verify-welcome '((server_proof . "bogus"))))
        (should-not (jetpacs--auth-verify-welcome '((protocol . 1))))))
    ;; …and with no token configured, the legacy path still passes.
    (let ((jetpacs-auth-token nil))
      (should (jetpacs--auth-verify-welcome '((protocol . 1)))))))

(ert-deftest jetpacs-auth-challenge-without-token-stays-silent ()
  "Unpaired Emacs answers a challenge with guidance, never a frame."
  (let ((jetpacs-auth-token nil)
        (sent nil))
    (cl-letf (((symbol-function 'jetpacs-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      (jetpacs--on-auth-challenge '((nonce . "deadbeef")))
      (should-not sent))))

;; ─── Demo files ─────────────────────────────────────────────────────────────

;; ─── Org tables: emitter and actions ────────────────────────────────────────

;; ─── Org babel results: foldable and read-only ──────────────────────────────

;; ─── Org babel: emitter and action ──────────────────────────────────────────

;; ─── Org drawers ─────────────────────────────────────────────────────────────

(defun jetpacs-tests--find-node (tree pred)
  "Depth-first search of widget TREE for a node satisfying PRED.
TREE may be a node (alist), a list of nodes, or a vector of nodes."
  (cond
   ((vectorp tree)
    (cl-some (lambda (x) (jetpacs-tests--find-node x pred)) tree))
   ((and (consp tree) (consp (car tree)) (symbolp (caar tree)))
    (if (funcall pred tree) tree
      (cl-some (lambda (kv) (and (consp kv)
                                 (jetpacs-tests--find-node (cdr kv) pred)))
               tree)))
   ((consp tree)
    (cl-some (lambda (x) (jetpacs-tests--find-node x pred)) tree))))

;; ─── Org case conventions ────────────────────────────────────────────────────
;; Keywords, blocks, and drawer delimiters may be lowercase in org files;
;; TODO keywords and tags are case-sensitive.  Recognition must not depend
;; on the ambient `case-fold-search'.

;; ─── Demo org corpus ─────────────────────────────────────────────────────────

;; ─── App-managed config directory ────────────────────────────────────────────

;; ─── Results / xref navigator substrate ──────────────────────────────────────
;;
;; occur / grep / compilation / xref all render as tappable loci cards, and a
;; tap follows the locus into the source and shows it on the phone via the
;; region seam.  The visit reuses each mode's own goto command under a
;; display shim, so these tests exercise the real occur/compilation machinery
;; rather than a parser of our own.

(defmacro jetpacs-tests--with-occur (var text query &rest body)
  "Run BODY with VAR bound to the *Occur* buffer for QUERY over TEXT.
The temp source buffer and *Occur* are cleaned up afterwards."
  (declare (indent 3))
  (let ((src (make-symbol "src")))
    `(let ((,src (generate-new-buffer "jetpacs-occur-src")))
       (unwind-protect
           (progn
             (with-current-buffer ,src
               (insert ,text)
               (goto-char (point-min))
               (occur ,query))
             (let ((,var (get-buffer "*Occur*")))
               ,@body))
         (when (get-buffer "*Occur*") (kill-buffer "*Occur*"))
         (when (buffer-live-p ,src) (kill-buffer ,src))))))

(ert-deftest jetpacs-results-occur-loci ()
  "occur match lines become loci; headings and blanks do not."
  (jetpacs-tests--with-occur ob
      "alpha needle one\nbeta\ngamma needle two\ndelta\nneedle three\n" "needle"
    (let ((loci (jetpacs-results--loci ob)))
      (should (= 3 (length loci)))
      (should (cl-every (lambda (l) (and (integerp (car l)) (stringp (cdr l)))) loci))
      ;; the trimmed row text carries the matched line
      (should (cl-every (lambda (l) (string-match-p "needle" (cdr l))) loci)))))

(ert-deftest jetpacs-results-render-shape ()
  "The skin renders a count header plus one card per locus."
  (jetpacs-tests--with-occur ob
      "one needle\ntwo needle\nthree\n" "needle"
    (let ((nodes (jetpacs-results-render ob)))
      ;; header caption + 2 cards
      (should (= 3 (length nodes)))
      ;; a card carries a results.visit on_tap with a numeric position
      (let ((card (jetpacs-tests--find-node
                   nodes
                   (lambda (n) (equal (alist-get 'action n) "results.visit")))))
        (should card)
        (should (numberp (alist-get 'pos (alist-get 'args card))))))))

(ert-deftest jetpacs-results-occur-follow ()
  "Following an occur locus lands in the source buffer on the matched line."
  (jetpacs-tests--with-occur ob
      "alpha needle one\nbeta\ngamma needle two\n" "needle"
    (let* ((loci (jetpacs-results--loci ob))
           (dest (jetpacs-results--follow ob (car (car loci)))))
      (should dest)
      (should (buffer-live-p (car dest)))
      (with-current-buffer (car dest)
        (goto-char (cdr dest))
        (should (string-match-p
                 "needle"
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position))))))))

(ert-deftest jetpacs-results-visit-action-invokes-seam ()
  "results.visit follows the locus and calls the region seam with buffer:line."
  (jetpacs-tests--with-occur ob
      "x needle\ny\nz needle\n" "needle"
    (let* ((loci (jetpacs-results--loci ob))
           (pos (car (car loci)))
           captured
           (jetpacs-results-visit-region-function
            (lambda (name beg end label &optional point)
              (setq captured (list name beg end label point))))
           (fn (gethash "results.visit" jetpacs-action-handlers)))
      (should fn)
      (funcall fn `((buffer . ,(buffer-name ob)) (pos . ,pos)) nil)
      (should captured)
      (pcase-let ((`(,name ,beg ,end ,label ,point) captured))
        (should (stringp name))
        (should (and (integerp beg) (integerp end) (< beg end)))
        (should (integerp point))
        (should (string-match-p ":[0-9]+\\'" label))))))

(ert-deftest jetpacs-results-visit-boundary ()
  "results.visit refuses a buffer that is not a results-mode buffer."
  (let ((plain (generate-new-buffer "jetpacs-not-results"))
        called
        (jetpacs-results-visit-region-function
         (lambda (&rest _) (setq called t)))
        (fn (gethash "results.visit" jetpacs-action-handlers)))
    (unwind-protect
        (with-current-buffer plain
          (fundamental-mode)
          (insert "just some text\n")
          (funcall fn `((buffer . ,(buffer-name plain)) (pos . 1)) nil)
          (should-not called))
      (kill-buffer plain))))

(ert-deftest jetpacs-results-compilation-follow ()
  "A compilation locus over a real file follows into that file."
  (let* ((dir (file-name-as-directory (make-temp-file "jetpacs-comp" t)))
         (f (expand-file-name "real.txt" dir))
         (cb (get-buffer-create "*jetpacs-compile-test*")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "alpha needle one\nbeta\ngamma needle two\n"))
          (with-current-buffer cb
            (setq default-directory dir)
            (insert "-*- mode: compilation -*-\n"
                    (format "%s:1:alpha needle one\n" f)
                    (format "%s:3:gamma needle two\n" f))
            (compilation-mode)
            (let ((inhibit-read-only t))
              (compilation-parse-errors (point-min) (point-max))))
          (let ((loci (jetpacs-results--loci cb)))
            (should (= 2 (length loci)))
            (let ((dest (jetpacs-results--follow cb (car (car loci)))))
              (should dest)
              (should (equal (expand-file-name f)
                             (expand-file-name
                              (buffer-file-name (car dest))))))))
      (when (get-buffer cb) (kill-buffer cb))
      (ignore-errors (delete-directory dir t)))))

;; ─── Widget wire format (golden snapshot) ───────────────────────────────────

(defconst jetpacs-tests--golden-file
  (expand-file-name "widgets.golden" jetpacs-tests--dir))

(defun jetpacs-tests--canon (x)
  "Recursively sort alist keys in X so serialization order is stable."
  (cond
   ((and (consp x) (consp (car x)) (symbolp (caar x)))
    (sort (mapcar (lambda (kv) (cons (car kv) (jetpacs-tests--canon (cdr kv))))
                  (copy-sequence x))
          (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))
   ((vectorp x) (vconcat (mapcar #'jetpacs-tests--canon x)))
   (t x)))

(defun jetpacs-tests--widget-cases ()
  "A battery exercising every widget constructor with all its options."
  (let* ((act (jetpacs-action "x.y" :args '((k . "v"))
                           :when-offline "drop" :dedupe "d"))
         (leaf (jetpacs-text "leaf")))
    (list
     (jetpacs-text "hi")
     (jetpacs-text "hi" 'title 1 "#FF0000" t 2 4)
     (jetpacs-markup "code" :syntax "elisp" :style 'body :padding 4)
     (jetpacs-rich-text (list (jetpacs-span "a" :bold t)) :style 'body :padding 2)
     (jetpacs-span "s" :bold t :italic t :underline t :strike t :code t
                :tag t :baseline "super" :color "#FFF" :on-tap act :mono t)
     (jetpacs-row leaf leaf)
     (jetpacs-flow-row leaf)
     (jetpacs-column leaf)
     (jetpacs-box (list leaf) :alignment "center" :padding 2 :weight 1 :on-tap act)
     (jetpacs-surface (list leaf) :color "#111" :shape "rounded" :elevation 2 :padding 3)
     (jetpacs-surface (list leaf) :color "surface_container" :shape "rounded_small" :fill t)
     (jetpacs-lazy-column leaf leaf)
     (jetpacs-spacer :height 4 :width 2 :weight 1)
     (jetpacs-divider)
     (jetpacs-card (list leaf) :on-tap act :padding 8 :weight 1
                :swipe-start (jetpacs-swipe-action "check" "Done" act)
                :swipe-end (jetpacs-swipe-action "schedule" "Later" act
                                              :color "#4CAF50"))
     (jetpacs-collapsible "cid" leaf (list leaf) :collapsed t :on-long-tap act)
     (jetpacs-reorderable-list (list '((label . "h") (level . 1))) :on-reorder act)
     (jetpacs-action "y.z")
     act
     (jetpacs-clipboard-action "copied text")
     (jetpacs-button "L" act :icon "add" :variant "text" :weight 1 :padding 2)
     (jetpacs-date-button "L" act :value "2026-01-01")
     (jetpacs-time-button "L" act :value "10:00")
     (jetpacs-image "http://x" :content-description "d" :padding 1)
     (jetpacs-icon-button "add" act :content-description "c" :padding 1 :badge 3)
     (jetpacs-menu (list (jetpacs-menu-item "L" act :icon "add")) :icon "more_vert" :padding 2)
     (jetpacs-text-input "tid" :value "v" :hint "h" :label "l" :on-submit act
                      :single-line t :min-lines 1 :max-lines 3
                      :monospace t :syntax "org" :keyboard "number" :padding 2)
     (jetpacs-text-input "tid2" :multi-line t)
     (jetpacs-enum-list "eid" '("a" "b") :value '("a") :multi-select t
                     :allow-add t :on-change act :padding 1)
     (jetpacs-checkbox "kid" :checked t :label "l" :on-change act :padding 1)
     (jetpacs-switch "sid" :checked t :label "l" :on-change act :padding 1)
     (jetpacs-icon "add" :size 20 :color "#FFF" :padding 1 :badge "")
     (jetpacs-chip "l" :on-tap act :selected t :icon "add" :padding 1)
     (jetpacs-progress :variant "linear" :value 0.5 :padding 1)
     (jetpacs-assist-chip "l" :on-tap act :icon "add" :padding 1)
     (jetpacs-section-header "t" :trailing leaf :padding 1)
     (jetpacs-empty-state :icon "inbox" :title "t" :caption "c"
                       :on-tap act :action-label "al" :padding 1)
     (jetpacs-date-stamp :date "2026-07-02" :time "10:00" :padding 1)
     (jetpacs-date-stamp :day 2 :month "Jul" :month-index 7 :year 2026)
     (jetpacs-editor "f.org" "content" :on-save act :read-only t :syntax "org"
                  :line-numbers "absolute" :complete t
                  :chromeless t :publish-state t)
     (jetpacs-drawer (list (jetpacs-drawer-item "i" "l" act :selected t :badge 100))
                  :header "h")
     (jetpacs-top-bar "t" :nav-icon "menu" :nav-action act :actions (list leaf))
     (jetpacs-fab "add" :label "l" :on-tap act :extended t)
     (jetpacs-bottom-bar (list (jetpacs-nav-item "i" "l" act :selected t :badge 2)))
     (jetpacs-scaffold :top-bar (jetpacs-top-bar "t") :fab (jetpacs-fab "add")
                    :body leaf :bottom-bar (jetpacs-bottom-bar nil)
                    :snackbar "s"
                    :snackbar-action (jetpacs-snackbar-action "Undo" act)
                    :drawer (jetpacs-drawer nil :header "h")
                    :on-refresh act)
     (jetpacs-table
      (list (jetpacs-table-row
             (list (jetpacs-table-cell (list (jetpacs-span "Item" :bold t)))
                   (jetpacs-table-cell (list (jetpacs-span "Qty"))))
             :header t)
            (jetpacs-table-rule)
            (jetpacs-table-row
             (list (jetpacs-table-cell (list (jetpacs-span "apples"))
                                    :on-tap act :on-long-tap act)
                   (jetpacs-table-cell (list (jetpacs-span "4"))))))
      :aligns '("start" "end") :on-add-row act :on-add-col act :padding 2)
     (jetpacs-table
      (list (jetpacs-table-row (list (jetpacs-table-cell (list (jetpacs-span "a")))))))
     (jetpacs-scroll-row leaf leaf)
     ;; Phase C — composition knobs
     (jetpacs-slider "vol" act :value 0.3 :min 0.0 :max 1.0 :steps 10)
     (jetpacs-row leaf leaf :spacing 4 :align "top")
     (jetpacs-column leaf leaf :spacing 6 :align "center")
     (jetpacs-surface (list leaf) :width 120 :height 40 :fill-fraction 0.5
                   :border (jetpacs-border :width 2 :color "#888"))
     (jetpacs-image "http://x" :width 100 :height 80 :aspect-ratio 1.5
                 :content-scale "crop")
     ;; Phase D — visualization ladder
     (jetpacs-chart (list (jetpacs-chart-series '(1 3 2 5) :label "a" :color "#4C6FFF")
                       (jetpacs-chart-series '(2 2 4 3)))
                 :kind "line" :height 160 :y-range '(0 6) :summary "trend"
                 :on-point-tap act)
     (jetpacs-canvas 100 60
                  (list (jetpacs-draw-line 0 0 100 60 :color "#888" :stroke 2)
                        (jetpacs-draw-rect 10 10 30 20 :fill t :color "primary" :radius 4)
                        (jetpacs-draw-circle 70 30 15 :color "#E64980")
                        (jetpacs-draw-path '((0 60) (50 0) (100 60)) :closed t :fill t)
                        (jetpacs-draw-text 50 30 "hi" :align "center" :size 10)))
     ;; Data-driven editor toolbar (SPEC §9 "Editor toolbars")
     (jetpacs-toolbar-item "code" "Src"
                        :snippet "#+begin_src ${input:Language}\n${cursor}\n#+end_src"
                        :placement "block"
                        :long-press (jetpacs-toolbar-item nil nil :line "promote"))
     ;; Intra-view tabs over swipeable pages
     (jetpacs-tabs (list (jetpacs-tab-item "Day" :icon "event")
                      (jetpacs-tab-item "Week"))
                (list leaf leaf)
                :initial 1 :scrollable t :on-change act :id "tid")
     ;; Agenda month calendar
     (jetpacs-month-grid "2026-07"
                      :marks '(("2026-07-10" . 3)
                               ("2026-07-14" . ((dots . 1) (color . "#E64980"))))
                      :selected "2026-07-10"
                      :min-month "2026-01" :max-month "2026-12"
                      :on-day-tap act :on-month-change act))))

(defun jetpacs-tests--widget-lines ()
  (let ((i -1))
    (mapcar (lambda (c)
              (setq i (1+ i))
              (format "%02d %s" i
                      (json-serialize (jetpacs-tests--canon c)
                                      :null-object :null
                                      :false-object :false)))
            (jetpacs-tests--widget-cases))))

(defun jetpacs-tests-regen-widget-golden ()
  "Rewrite the golden snapshot from the current constructors.
Only run this after an INTENTIONAL wire-format change; review the diff."
  (with-temp-file jetpacs-tests--golden-file
    (insert (string-join (jetpacs-tests--widget-lines) "\n") "\n"))
  (message "Wrote %s" jetpacs-tests--golden-file))

(ert-deftest jetpacs-widgets-wire-format ()
  "Every constructor's wire format matches the committed golden snapshot."
  (should (file-readable-p jetpacs-tests--golden-file))
  (should (equal (jetpacs-tests--widget-lines)
                 (split-string
                  (with-temp-buffer
                    (insert-file-contents jetpacs-tests--golden-file)
                    (buffer-string))
                  "\n" t))))

;; ─── Triggers & device capabilities (SPEC §10–§11) ──────────────────────────

(ert-deftest jetpacs-triggers-replace-set-push ()
  "Registering triggers pushes the full replace-set, id-sorted, nils omitted.
Register-time pushes are debounced (a burst is one frame);
`jetpacs-triggers-push-now' is the flush."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs--session '((granted . ("triggers"))))
        (jetpacs-triggers-changed-hook nil)  ; isolate from the app's re-push
        (jetpacs-triggers--push-timer nil)
        (sent nil))
    (cl-letf (((symbol-function 'jetpacs-connected-p) (lambda () t))
              ((symbol-function 'jetpacs-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      (jetpacs-trigger-register "t2" :type "screen" :params '((state . "off")))
      (jetpacs-trigger-register "t1" :type "power"
                             :params '((state . "connected"))
                             :policy "wake" :throttle-s 60)
      ;; The burst is pending, not sent; the flush emits ONE frame
      ;; carrying both, sorted by id.
      (should-not sent)
      (should (timerp jetpacs-triggers--push-timer))
      (jetpacs-triggers-push-now)
      (should (= (length sent) 1))
      (should-not jetpacs-triggers--push-timer)
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
      (jetpacs-trigger-unregister "t1")
      (jetpacs-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (= (length specs) 1))
        (should (equal (alist-get 'id (car specs)) "t2"))))))

(ert-deftest jetpacs-triggers-gated-on-grant ()
  "No triggers.set leaves Emacs unless the companion granted `triggers'."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs--session '((granted . ("surfaces.dialog" "capabilities"))))
        (jetpacs-triggers-changed-hook nil)  ; isolate from the app's re-push
        (sent nil))
    (cl-letf (((symbol-function 'jetpacs-connected-p) (lambda () t))
              ((symbol-function 'jetpacs-send)
               (lambda (kind &rest _) (push kind sent))))
      (jetpacs-trigger-register "t" :type "power")
      (jetpacs-triggers-push-now)          ; flush past the debounce
      (should-not sent))))

(ert-deftest jetpacs-triggers-unsupported-type-skipped ()
  "A type the companion can't host is skipped, never pushed.
The companion rejects a replace-set wholesale on an unknown type, so
one too-new registration must cost itself, not the whole set — checked
against both the static batch-1 catalog and a welcome-reported one."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs--session '((granted . ("triggers"))))
        (jetpacs-triggers-changed-hook nil)
        (jetpacs-triggers--push-timer nil)
        (sent nil))
    (cl-letf (((symbol-function 'jetpacs-connected-p) (lambda () t))
              ((symbol-function 'jetpacs-send)
               (lambda (kind payload &rest _)
                 (push (cons kind payload) sent))))
      (jetpacs-trigger-register "ok" :type "power")
      (jetpacs-trigger-register "too-new" :type "wifi.ssid")
      ;; The fallback catalog governs: wifi.ssid stays home.
      (jetpacs-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (equal (mapcar (lambda (s) (alist-get 'id s)) specs)
                       '("ok"))))
      ;; A companion that reports the type gets it.
      (setq jetpacs--session '((granted . ("triggers"))
                            (device . ((trigger_types . ("power" "wifi.ssid"))))))
      (jetpacs-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (equal (mapcar (lambda (s) (alist-get 'id s)) specs)
                       '("ok" "too-new"))))
      ;; And one that reports a catalog WITHOUT a batch-1 type wins too:
      ;; the report is authoritative in both directions.
      (setq jetpacs--session '((granted . ("triggers"))
                            (device . ((trigger_types . ("wifi.ssid"))))))
      (jetpacs-triggers-push-now)
      (let ((specs (append (alist-get 'triggers (cdar sent)) nil)))
        (should (equal (mapcar (lambda (s) (alist-get 'id s)) specs)
                       '("too-new")))))))

(ert-deftest jetpacs-triggers-fire-dispatch ()
  "An inbound trigger.fired event.action reaches the per-id handler."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (fired nil))
    ;; Disconnected in batch, so register never sends.
    (jetpacs-trigger-register "charge" :type "power"
                           :handler (lambda (data args)
                                      (setq fired (list data args))))
    (jetpacs--handle-line
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
    (jetpacs--handle-line
     (json-serialize
      '((v . 1) (id . "m-test-2") (reply_to . :null)
        (kind . "event.action")
        (payload . ((action . "trigger.fired")
                    (args . ((id . "gone") (type . "power")
                             (data . :null) (at_ms . 1))))))
      :null-object :null :false-object :false))
    (should-not fired)))

(ert-deftest jetpacs-triggers-deftrigger-and-disable ()
  "jetpacs-deftrigger registers under the symbol name; disabling excludes
the id from the pushed specs and re-enabling restores it."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs-triggers-disabled nil))
    (jetpacs-deftrigger test/charge
      :type "power" :params '((state . "connected"))
      :handler #'ignore)
    (should (gethash "test/charge" jetpacs-triggers--table))
    (should (= 1 (length (jetpacs-triggers--specs))))
    ;; Disable: registration stays, the wire set shrinks.
    (jetpacs-trigger-set-enabled "test/charge" nil)
    (should-not (jetpacs-trigger-enabled-p "test/charge"))
    (should (gethash "test/charge" jetpacs-triggers--table))
    (should (= 0 (length (jetpacs-triggers--specs))))
    ;; Re-enable restores the spec.
    (jetpacs-trigger-set-enabled "test/charge" t)
    (should (= 1 (length (jetpacs-triggers--specs))))))

(ert-deftest jetpacs-triggers-toggle-action-persists ()
  "The trigger.toggle action flips enablement and saves via the seam."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs-triggers-disabled nil)
        (saved nil))
    (jetpacs-deftrigger test/toggle :type "screen" :handler #'ignore)
    (cl-letf (((symbol-function 'jetpacs-settings-save-variable)
               (lambda (sym val) (setq saved (cons sym val)) t)))
      (jetpacs--on-action '((action . "trigger.toggle")
                         (args . ((id . "test/toggle") (value . :false))))
                       nil)
      (should-not (jetpacs-trigger-enabled-p "test/toggle"))
      (should (equal (car saved) 'jetpacs-triggers-disabled))
      (should (member "test/toggle" (cdr saved)))
      ;; Toggling an unknown id is a no-op, not an error.
      (jetpacs--on-action '((action . "trigger.toggle")
                         (args . ((id . "nope") (value . t))))
                       nil)
      (should-not (jetpacs-trigger-enabled-p "test/toggle")))))

(ert-deftest jetpacs-triggers-test-fire-and-last-fired ()
  "trigger.test runs the handler through the real dispatch path and
records the last-fired time."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs-triggers--last-fired (make-hash-table :test 'equal))
        (fired nil))
    (jetpacs-deftrigger test/fire
      :type "power"
      :handler (lambda (_data args) (setq fired args)))
    (should-not (gethash "test/fire" jetpacs-triggers--last-fired))
    (jetpacs--on-action '((action . "trigger.test")
                       (args . ((id . "test/fire"))))
                     nil)
    (should fired)
    (should (eq (alist-get 'test fired) t))
    (should (equal (alist-get 'type fired) "power"))
    (should (gethash "test/fire" jetpacs-triggers--last-fired))))

(ert-deftest jetpacs-automations-view-renders ()
  "The Automations view builds for both the empty and populated registry."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal))
        (jetpacs-triggers--last-fired (make-hash-table :test 'equal))
        (jetpacs-triggers-disabled nil))
    (should (jetpacs-automations--view nil))   ; empty state
    (jetpacs-deftrigger test/view
      :type "battery.level" :params '((below . 20))
      :policy "drop" :throttle-s 300 :handler #'ignore)
    (let ((json (json-serialize
                 (jetpacs-tests--canon (jetpacs-automations--view "snack"))
                 :null-object :null :false-object :false)))
      (should (string-search "test/view" json))
      (should (string-search "trigger.toggle" json))
      (should (string-search "trigger.test" json))
      (should (string-search "Never fired" json))
      (should (string-search "below=20" json)))))

(ert-deftest jetpacs-device-report-queries ()
  "Session helpers read the granted list and the welcome's device report."
  (let ((jetpacs--session
         '((granted . ("capabilities" "surfaces.dialog"))
           (device . ((caps . ("settings.open"))
                      (perms . ((exact_alarms . t)
                                (write_settings . :false))))))))
    (should (jetpacs-granted-p "capabilities"))
    (should-not (jetpacs-granted-p "triggers"))
    (should (jetpacs-device-cap-p "settings.open"))
    (should-not (jetpacs-device-cap-p "flashlight"))
    (should (jetpacs-device-can-p "exact_alarms"))
    (should-not (jetpacs-device-can-p 'write_settings))
    (should-not (jetpacs-device-can-p "fine_location")))
  ;; With no session at all, everything reads as absent, nothing errors.
  (let ((jetpacs--session nil))
    (should-not (jetpacs-granted-p "capabilities"))
    (should-not (jetpacs-device-caps))
    (should-not (jetpacs-device-can-p "exact_alarms"))))

(ert-deftest jetpacs-node-supported-negotiation ()
  "`jetpacs-node-supported-p' gates on the welcome's node catalog, permissively."
  ;; A present catalog is positive knowledge: listed = yes, omitted = no.
  (let ((jetpacs--session '((node_types . ["text" "row" "chart"]))))
    (should (jetpacs-node-supported-p 'chart))
    (should (jetpacs-node-supported-p "text"))
    (should-not (jetpacs-node-supported-p 'canvas))
    (should-not (jetpacs-node-supported-p "slider")))
  ;; An older companion sends no catalog: treat every node as supported
  ;; (negotiation is positive knowledge, never a denylist).
  (let ((jetpacs--session '((granted . ("capabilities")))))
    (should (jetpacs-node-supported-p 'chart))
    (should (jetpacs-node-supported-p 'anything-at-all)))
  ;; Not connected: unsupported (nothing renders anywhere).
  (let ((jetpacs--session nil))
    (should-not (jetpacs-node-supported-p 'text))))

(ert-deftest jetpacs-api-version-bound ()
  "The API/protocol version constants exist for third-party compatibility checks."
  (should (stringp jetpacs-api-version))
  (should (integerp jetpacs-protocol-version)))

;; ─── Spec linter (Phase B / Task 4) ──────────────────────────────────────────

(ert-deftest jetpacs-lint-passes-valid-specs ()
  "A tree built from the constructors lints clean."
  (should-not
   (jetpacs-lint-spec
    (jetpacs-column
     (jetpacs-card (list (jetpacs-text "Title" 'headline)
                      (jetpacs-rich-text (list (jetpacs-span "bold" :bold t))))
                :on-tap (jetpacs-action "x.y" :args '((k . "v"))))
     (jetpacs-row (jetpacs-button "Go" (jetpacs-action "a.b"))
               (jetpacs-switch "s" :checked t :on-change (jetpacs-action "c.d")))))))

(ert-deftest jetpacs-lint-flags-unknown-node ()
  "An unknown `t' is reported."
  (let ((problems (jetpacs-lint-spec (jetpacs--node "flisbo" 'text "x"))))
    (should problems)
    (should (string-match-p "unknown" (cdr (car problems))))))

(ert-deftest jetpacs-lint-flags-bad-action ()
  "An action with neither `action' nor `builtin', and a bad when_offline."
  (should (jetpacs-lint-spec `((t . "button") (on_tap . ((args . ((k . "v"))))))))
  (should (jetpacs-lint-spec `((t . "button")
                            (on_tap . ((action . "a.b") (when_offline . "sometimes")))))))

(ert-deftest jetpacs-lint-flags-nonserializable-and-typed-attrs ()
  "A symbol attr value and a non-numeric padding are caught before the wire."
  (should (jetpacs-lint-spec `((t . "text") (text . some-symbol))))
  (should (jetpacs-lint-spec `((t . "text") (text . "ok") (padding . "lots"))))
  (should (jetpacs-lint-spec `((t . "surface") (children . []) (color . "#GGG")))))

(ert-deftest jetpacs-lint-sanitize-isolates-bad-subtree ()
  "Sanitizing replaces only the invalid node, keeping siblings intact."
  (let* ((spec (jetpacs-column
                (jetpacs-text "keep me" 'body)
                (jetpacs--node "bogus" 'text "drop me")))
         (clean (jetpacs-lint-sanitize-spec spec))
         (kids (alist-get 'children clean)))   ; a vector (constructors vconcat)
    (should-not (jetpacs-lint-spec clean))          ; sanitized tree is valid
    (should (equal "text" (alist-get 't (elt kids 0))))
    (should (equal "empty_state" (alist-get 't (elt kids 1))))))  ; bogus → error node

(ert-deftest jetpacs-render-to-json-roundtrips ()
  "The headless harness serializes and parses a spec back to the wire shape."
  (let ((parsed (jetpacs-render-to-json (jetpacs-text "hi" 'title))))
    (should (equal "text" (alist-get 't parsed)))
    (should (equal "hi" (alist-get 'text parsed)))
    (should (equal "title" (alist-get 'style parsed)))))

(ert-deftest jetpacs-lint-passes-visualization ()
  "Chart and canvas specs lint clean and round-trip (Phase D)."
  (let ((chart (jetpacs-chart (list (jetpacs-chart-series '(1 2 3) :color "#4C6FFF"))
                           :kind "bar" :on-point-tap (jetpacs-action "p.tap")))
        (canvas (jetpacs-canvas 80 40
                             (list (jetpacs-draw-line 0 0 80 40 :stroke 2)
                                   (jetpacs-draw-circle 40 20 10 :fill t :color "primary")
                                   (jetpacs-draw-text 10 20 "hi" :align "center")))))
    (should-not (jetpacs-lint-spec chart))
    (should-not (jetpacs-lint-spec canvas))
    (should (equal "chart" (alist-get 't (jetpacs-render-to-json chart))))
    (should (equal "canvas" (alist-get 't (jetpacs-render-to-json canvas))))))

(ert-deftest jetpacs-lint-swipe-badge-snackbar ()
  "Swipe actions, badges, and snackbar actions ride the generic lint walk."
  (should-not
   (jetpacs-lint-spec
    (jetpacs-card (list (jetpacs-text "row"))
               :swipe-start (jetpacs-swipe-action "check" "Done"
                                               (jetpacs-action "t.done"))
               :swipe-end (jetpacs-swipe-action "schedule" "Later"
                                             (jetpacs-action "t.later")
                                             :color "#4CAF50"))))
  ;; A broken swipe action is caught: on_trigger is an action key.
  (should (jetpacs-lint-spec
           (jetpacs-card (list (jetpacs-text "row"))
                      :swipe-start '((icon . "x")
                                     (on_trigger . ((args . ((k . "v")))))))))
  (should-not (jetpacs-lint-spec (jetpacs-icon "inbox" :badge 3)))
  (should-not (jetpacs-lint-spec
               (jetpacs-icon-button "inbox" (jetpacs-action "a.b") :badge "")))
  (should-not
   (jetpacs-lint-spec
    (jetpacs-scaffold :body (jetpacs-text "b") :snackbar "Archived"
                   :snackbar-action (jetpacs-snackbar-action
                                     "Undo" (jetpacs-action "t.unarchive"))))))

;; ─── Data-driven editor toolbars (SPEC §9 "Editor toolbars") ─────────────────

(ert-deftest jetpacs-toolbar-item-shape ()
  "Toolbar items emit the closed §9 vocabulary; nil options are dropped."
  (should (equal '((icon . "format_bold") (label . "B")
                   (snippet . "*${selection}*"))
                 (jetpacs-toolbar-item "format_bold" "B"
                                    :snippet "*${selection}*")))
  ;; Menu sub-items ride as a vector; a nil icon is dropped.
  (let* ((sub (jetpacs-toolbar-item nil "* H1" :snippet "* "
                                 :placement "line-start"))
         (item (jetpacs-toolbar-item "title" "H" :menu (list sub))))
    (should-not (assq 'icon sub))
    (should (equal (vector sub) (alist-get 'menu item))))
  ;; The editor emits a toolbar list as a vector; a string passes through.
  (should (vectorp (alist-get 'toolbar
                              (jetpacs-editor "f.org" ""
                                           :toolbar (list (jetpacs-toolbar-item
                                                           "up" "^" :line "move-up"))))))
  (should (equal "org" (alist-get 'toolbar
                                  (jetpacs-editor "f.org" "" :toolbar "org")))))

(ert-deftest jetpacs-lint-toolbar-vocabulary ()
  "A full valid toolbar lints clean; op-set and enum violations are flagged."
  (should-not
   (jetpacs-lint-spec
    (jetpacs-editor "f.org" "" :toolbar
                 (list (jetpacs-toolbar-item "format_bold" "B"
                                          :snippet "*${selection}*")
                       (jetpacs-toolbar-item "arrow_upward" "^" :line "move-up")
                       (jetpacs-toolbar-item "title" "H" :menu
                                          (list (jetpacs-toolbar-item
                                                 nil "* H1" :snippet "* "
                                                 :placement "line-start")))
                       (jetpacs-toolbar-item "schedule" "TS" :snippet "[${date}]"
                                          :long-press (jetpacs-toolbar-item
                                                       nil nil :snippet "<${date}>"))
                       (jetpacs-toolbar-item "bolt" "M-x"
                                          :on-tap (jetpacs-action "x.y"))))))
  (cl-flet ((lint-one (item)
              (jetpacs-lint-spec (jetpacs-editor "f.org" "" :toolbar (list item)))))
    ;; Two op fields on one item.
    (should (lint-one (jetpacs-toolbar-item "a" "b" :snippet "x" :line "promote")))
    ;; No op field at all.
    (should (lint-one (jetpacs-toolbar-item "a" "b")))
    ;; Bad placement enum, and placement without snippet.
    (should (lint-one (jetpacs-toolbar-item "a" "b" :snippet "x"
                                         :placement "floating")))
    (should (lint-one (jetpacs-toolbar-item "a" "b" :line "promote"
                                         :placement "cursor")))
    ;; Bad builtin line op.
    (should (lint-one (jetpacs-toolbar-item "a" "b" :line "sideways")))
    ;; Menus don't nest.
    (should (lint-one (jetpacs-toolbar-item "a" "b" :menu
                                         (list (jetpacs-toolbar-item
                                                nil "s" :menu
                                                (list (jetpacs-toolbar-item
                                                       nil "x" :line "promote")))))))
    ;; A broken embedded action is still the generic walk's catch.
    (should (lint-one (jetpacs-toolbar-item "a" "b" :on-tap '((args . ((k . "v")))))))))

;; ─── Multi-tenant ownership (Phase E) ─────────────────────────────────────────

(ert-deftest jetpacs-owner-collision-detection ()
  "Same-owner re-registration is silent; a cross-owner clash errors under strict."
  (let ((jetpacs-action-handlers (make-hash-table :test 'equal))
        (jetpacs--registration-owners (make-hash-table :test 'equal))
        (jetpacs-strict-namespaces nil))
    ;; Same owner re-registers freely — the live-reload case.
    (with-jetpacs-owner "appA" (jetpacs-defaction "app.a.do" #'ignore))
    (with-jetpacs-owner "appA" (jetpacs-defaction "app.a.do" #'ignore))
    (should (equal "appA" (gethash "action:app.a.do" jetpacs--registration-owners)))
    ;; A different owner claiming the same name errors when strict.
    (let ((jetpacs-strict-namespaces t))
      (should-error
       (with-jetpacs-owner "appB" (jetpacs-defaction "app.a.do" #'ignore))))
    ;; The strict refusal left the original owner and handler intact.
    (should (equal "appA" (gethash "action:app.a.do" jetpacs--registration-owners)))))

(ert-deftest jetpacs-app-unregister-teardown ()
  "`jetpacs-app-unregister' removes the app's owned actions, views, and state."
  (let ((jetpacs-action-handlers (make-hash-table :test 'equal))
        (jetpacs--registration-owners (make-hash-table :test 'equal))
        (jetpacs-shell-views nil)
        (jetpacs-apps--registry nil)
        (jetpacs--ui-state (make-hash-table :test 'equal))
        (jetpacs--state-handlers (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'jetpacs-shell--schedule-repush) #'ignore))
      (with-jetpacs-owner "marks"
        (jetpacs-defaction "marks.jump" #'ignore)
        (jetpacs-shell-define-view "marks" :builder #'ignore))
      (jetpacs-ui-state-put "marks.q" "hi")
      (jetpacs-on-state-change "marks.q" #'ignore)
      (should (gethash "marks.jump" jetpacs-action-handlers))
      (should (assoc "marks" jetpacs-shell-views))
      (jetpacs-app-unregister "marks")
      (should-not (gethash "marks.jump" jetpacs-action-handlers))
      (should-not (assoc "marks" jetpacs-shell-views))
      (should-not (jetpacs-ui-state "marks.q"))
      (should-not (gethash "marks.q" jetpacs--state-handlers))
      (should-not (gethash "action:marks.jump" jetpacs--registration-owners)))))

(ert-deftest jetpacs-lint-types-cover-golden ()
  "Every `t' the constructors emit (per widgets.golden) is a known lint type.
Guards against a new constructor shipping a node the linter — and, by the
mirror invariant, the renderer's SDUI_NODE_TYPES — doesn't know about."
  (let ((golden (expand-file-name "widgets.golden" jetpacs-tests--dir))
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
      (should (member ty jetpacs-lint-node-types)))))

(ert-deftest jetpacs-capability-invoke-roundtrip ()
  "capability.invoke correlates its reply and normalizes ok vs typed error."
  (let ((jetpacs--pending (make-hash-table :test 'equal))
        (jetpacs--process 'fake)
        (sent nil)
        (result nil))
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (p) (eq p 'fake)))
              ((symbol-function 'jetpacs--raw-send)
               (lambda (line) (push line sent))))
      ;; Success path: capability.result {ok: true} resolves with OK non-nil.
      (let ((id (jetpacs-capability-invoke
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
        (jetpacs--handle-line
         (json-serialize
          `((v . 1) (id . "m-r-1") (reply_to . ,id)
            (kind . "capability.result") (payload . ((ok . t))))
          :null-object :null :false-object :false))
        (should (equal (car result) t)))
      ;; Error path: a typed error frame resolves with OK nil and the code.
      (setq result nil)
      (let ((id (jetpacs-capability-invoke
                 "flashlight" nil
                 (lambda (ok payload) (setq result (list ok payload))))))
        (jetpacs--handle-line
         (json-serialize
          `((v . 1) (id . "m-r-2") (reply_to . ,id)
            (kind . "error")
            (payload . ((code . "cap-unsupported")
                        (detail . "unknown capability 'flashlight'"))))
          :null-object :null :false-object :false))
        (should result)
        (should-not (car result))
        (should (equal (alist-get 'code (cadr result)) "cap-unsupported"))))))

(ert-deftest jetpacs-device-apps-list-parses-result ()
  "apps.list results become the (LABEL . PACKAGE) alist pickers want."
  (let (got)
    (cl-letf (((symbol-function 'jetpacs-capability-invoke)
               (lambda (cap _args callback)
                 (should (equal cap "apps.list"))
                 (funcall callback t
                          '((ok . t)
                            (result . ((apps . (((label . "Emacs")
                                                 (package . "org.gnu.emacs"))
                                                ((label . "Termux")
                                                 (package . "com.termux")))))))))))
      (jetpacs-device-apps-list (lambda (apps) (setq got apps))))
    (should (equal got '(("Emacs" . "org.gnu.emacs")
                         ("Termux" . "com.termux"))))))

(ert-deftest jetpacs-device-shortcut-pin-args ()
  "shortcut.pin sends id/label/action, base64s the icon file, and omits
absent optional keys."
  (let ((icon (make-temp-file "jetpacs-icon" nil ".png" "PNGBYTES"))
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-capability-invoke)
                   (lambda (cap args &optional _callback)
                     (setq sent (cons cap args)))))
          (jetpacs-device-shortcut-pin
           "distro" "My Distro"
           (jetpacs-action "app.open" :args '((view . "root")))
           :icon-file icon :long-label "My Distro Notes")
          (should (equal (car sent) "shortcut.pin"))
          (let ((args (cdr sent)))
            (should (equal (alist-get 'id args) "distro"))
            (should (equal (alist-get 'label args) "My Distro"))
            (should (equal (alist-get 'long_label args) "My Distro Notes"))
            (should (equal (alist-get 'icon_png args)
                           (base64-encode-string "PNGBYTES" t)))
            ;; The action rides as a standard action object, untouched.
            (should (equal (alist-get 'action (alist-get 'action args))
                           "app.open"))
            (should (equal (alist-get 'view (alist-get 'args (alist-get 'action args)))
                           "root"))))
      (delete-file icon))
    ;; No icon, no long label: the keys are absent, not null — the
    ;; companion falls back to its own icon.
    (cl-letf (((symbol-function 'jetpacs-capability-invoke)
               (lambda (cap args &optional _callback)
                 (setq sent (cons cap args)))))
      (jetpacs-device-shortcut-pin "d2" "Distro 2" (jetpacs-action "app.open"))
      (let ((args (cdr sent)))
        (should-not (assq 'icon_png args))
        (should-not (assq 'long_label args))))))

(ert-deftest jetpacs-device-shortcuts-set-args ()
  "shortcuts.set wraps entries in a vector; nil clears with an empty one."
  (let (sent)
    (cl-letf (((symbol-function 'jetpacs-capability-invoke)
               (lambda (cap args &optional _callback)
                 (setq sent (cons cap args)))))
      (jetpacs-device-shortcuts-set
       (list (list "capture" "Capture" (jetpacs-action "capture.open"))
             (list "agenda" "Agenda" (jetpacs-action "agenda.open"))))
      (should (equal (car sent) "shortcuts.set"))
      (let ((shortcuts (alist-get 'shortcuts (cdr sent))))
        (should (vectorp shortcuts))
        (should (= (length shortcuts) 2))
        (let ((first (aref shortcuts 0)))
          (should (equal (alist-get 'id first) "capture"))
          (should (equal (alist-get 'label first) "Capture"))
          (should-not (assq 'icon_png first))))
      ;; Replace-set discipline: clearing sends an empty vector, never a
      ;; missing key.
      (jetpacs-device-shortcuts-set nil)
      (should (equal (alist-get 'shortcuts (cdr sent)) [])))))

(ert-deftest jetpacs-device-permissions-dialog-renders ()
  "The permissions dialog lists the perm map with grant deep-links."
  (let ((jetpacs--session
         '((granted . ("capabilities"))
           (device . ((caps . ("settings.open"))
                      (perms . ((write_settings . :false)
                                (notification_policy . :false)
                                (exact_alarms . t)))))))
        (sent nil))
    (cl-letf (((symbol-function 'jetpacs-send-dialog)
               (lambda (spec) (push spec sent))))
      (jetpacs-device-permissions-dialog))
    (let ((json (json-serialize (jetpacs-tests--canon (car sent))
                                :null-object :null :false-object :false)))
      (should (string-search "Device permissions" json))
      (should (string-search "MANAGE_WRITE_SETTINGS" json))
      (should (string-search "device.perm.open" json))
      ;; Granted rows carry no Grant button.
      (should (string-search "Exact alarms" json))
      (should (string-search "\"Granted\"" json)))))

(ert-deftest jetpacs-device-launch-app-uses-dialog ()
  "The app picker is a companion dialog dispatching device.launch."
  (let ((sent nil))
    (cl-letf (((symbol-function 'jetpacs-device-apps-list)
               (lambda (callback)
                 (funcall callback '(("Emacs" . "org.gnu.emacs")))))
              ((symbol-function 'jetpacs-send-dialog)
               (lambda (spec) (push spec sent))))
      (jetpacs-device-launch-app))
    (let ((json (json-serialize (jetpacs-tests--canon (car sent))
                                :null-object :null :false-object :false)))
      (should (string-search "device.launch" json))
      (should (string-search "org.gnu.emacs" json)))))

(ert-deftest jetpacs-device-clipboard-read-nil-on-error ()
  "A cap-permission clipboard failure yields nil, not an error."
  (let ((got 'untouched))
    (cl-letf (((symbol-function 'jetpacs-capability-invoke)
               (lambda (_cap _args callback)
                 (funcall callback nil '((code . "cap-permission")
                                         (detail . "backgrounded"))))))
      (jetpacs-device-clipboard-read (lambda (text) (setq got text))))
    (should-not got)))

;; ─── App identity (jetpacs-defapp, AUTO Task 14) ────────────────────────────────

(ert-deftest jetpacs-apps-single-app-zero-change ()
  "With one app registered, every view shows and the launcher is absent."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil))
    (jetpacs-defapp "one" :label "One" :views '("agenda"))
    (should-not (jetpacs-apps--multi-p))
    (should (jetpacs-apps--view-visible-p "agenda"))
    (should (jetpacs-apps--view-visible-p "files"))
    ;; Even views claimed by nobody-in-particular show.
    (should (jetpacs-apps--view-visible-p "someone-elses-view"))))

(ert-deftest jetpacs-apps-multi-app-gating ()
  "From the second app on, only the current app's views (plus unclaimed
core views) are included."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil))
    (jetpacs-defapp "glasspane" :views '("agenda" "tasks"))
    (jetpacs-defapp "hello" :views '("hello"))
    (should (jetpacs-apps--multi-p))
    ;; Equal :order keeps registration order: glasspane is the default.
    (should (equal (jetpacs-apps-current) "glasspane"))
    (should (jetpacs-apps--view-visible-p "agenda"))
    (should-not (jetpacs-apps--view-visible-p "hello"))
    (should (jetpacs-apps--view-visible-p "files")) ; unclaimed: everywhere
    (setq jetpacs-apps--current "hello")
    (should (jetpacs-apps--view-visible-p "hello"))
    (should-not (jetpacs-apps--view-visible-p "agenda"))
    ;; Removing the second app restores single-app behavior.
    (jetpacs-apps-remove "hello")
    (should (jetpacs-apps--view-visible-p "agenda"))))

(ert-deftest jetpacs-apps-bottom-bar-and-home-gating ()
  "The bottom bar shows one app's tabs; home enters the push multi-app only."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-shell-views nil)
        (jetpacs-shell--current-tab nil))
    (jetpacs-shell-define-view "home" :builder #'jetpacs-apps--home-view
                            :when #'jetpacs-apps--multi-p :order 1)
    (jetpacs-shell-define-view "agenda" :builder #'ignore
                            :tab '(:icon "event" :label "Agenda") :order 10)
    (jetpacs-shell-define-view "hello" :builder #'ignore
                            :tab '(:icon "home" :label "Hello") :order 20)
    (jetpacs-defapp "glasspane" :views '("agenda"))
    ;; Single app: home hidden, both tabs visible (hello is unclaimed).
    (should-not (assoc "home" (jetpacs-shell--visible-views)))
    (should (= 2 (length (alist-get 'items (jetpacs-shell-bottom-bar "agenda")))))
    ;; Second app claims hello: home appears, bars split per app.
    (jetpacs-defapp "hello-app" :views '("hello"))
    (should (assoc "home" (jetpacs-shell--visible-views)))
    (should-not (assoc "hello" (jetpacs-shell--visible-views)))
    (let ((items (alist-get 'items (jetpacs-shell-bottom-bar "agenda"))))
      (should (= 1 (length items)))
      (should (equal (alist-get 'label (aref items 0)) "Agenda")))
    ;; The default landing tab respects the filter too.
    (should (equal (jetpacs-shell-current-tab) "agenda"))
    ;; The home grid builds one card per app.
    (should (jetpacs-apps--home-view nil))))

(ert-deftest jetpacs-apps-open-action-switches ()
  "app.open flips the current app and pushes onto its landing tab."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-shell-views nil)
        (pushed nil))
    (jetpacs-shell-define-view "agenda" :builder #'ignore
                            :tab '(:icon "event" :label "Agenda") :order 10)
    (jetpacs-shell-define-view "hello" :builder #'ignore
                            :tab '(:icon "home" :label "Hello") :order 20)
    (jetpacs-defapp "glasspane" :views '("agenda"))
    (jetpacs-defapp "hello-app" :views '("hello"))
    (cl-letf (((symbol-function 'jetpacs-shell-push)
               (cl-function
                (lambda (&optional tab &key switch-to)
                  (setq pushed (list tab switch-to))))))
      (jetpacs--on-action '((action . "app.open")
                         (args . ((app . "hello-app"))))
                       nil)
      (should (equal (jetpacs-apps-current) "hello-app"))
      (should (equal pushed '("hello" "hello")))
      ;; Unknown apps are dropped, never switched to.
      (jetpacs--on-action '((action . "app.open") (args . ((app . "nope")))) nil)
      (should (equal (jetpacs-apps-current) "hello-app")))))

(ert-deftest jetpacs-apps-owned-chrome-gating ()
  "Owned drawer items and top actions show only in their app; unowned everywhere."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-shell-drawer-items nil)
        (jetpacs-shell-top-actions nil))
    (jetpacs-shell-add-drawer-item 10 (lambda () '((label . "core"))))
    (with-jetpacs-owner "one"
      (jetpacs-shell-add-drawer-item 20 (lambda () '((label . "one's")))))
    (with-jetpacs-owner "two"
      (jetpacs-shell-add-drawer-item 30 (lambda () '((label . "two's"))))
      (jetpacs-shell-add-top-action 10 (lambda () '((label . "two-action")))))
    (cl-flet ((labels ()
                (let ((d (prin1-to-string (jetpacs-shell-drawer))))
                  (mapcar (lambda (l) (and (string-search l d) l))
                          '("core" "one's" "two's")))))
      ;; Single app: everything shows (a lone app is always current).
      (jetpacs-defapp "one" :views '())
      (should (equal (labels) '("core" "one's" "two's")))
      ;; Second app: chrome follows the current app.
      (jetpacs-defapp "two" :views '())
      (should (equal (jetpacs-apps-current) "one"))
      (should (equal (labels) '("core" "one's" nil)))
      (should-not (string-search "two-action"
                                 (prin1-to-string
                                  (jetpacs-shell-default-top-bar "T"))))
      (setq jetpacs-apps--current "two")
      (should (equal (labels) '("core" nil "two's")))
      (should (string-search "two-action"
                             (prin1-to-string
                              (jetpacs-shell-default-top-bar "T")))))))

(ert-deftest jetpacs-apps-settings-section-scoping ()
  "Owned settings sections render only while their app is current."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-settings-registry nil)
        (jetpacs-settings-links nil)
        (jetpacs-settings-native-links nil))
    (jetpacs-settings-register-section "Shared" '())
    (with-jetpacs-owner "one"
      (jetpacs-settings-register-section "One's section" '()))
    (with-jetpacs-owner "two"
      (jetpacs-settings-register-section "Two's section" '()))
    (unwind-protect
        (progn
          (jetpacs-defapp "one" :views '())
          (jetpacs-defapp "two" :views '())
          (let ((body (prin1-to-string (jetpacs-settings-sections))))
            (should (string-search "Shared" body))
            (should (string-search "One's section" body))
            (should-not (string-search "Two's section" body)))
          (setq jetpacs-apps--current "two")
          (let ((body (prin1-to-string (jetpacs-settings-sections))))
            (should (string-search "Two's section" body))
            (should-not (string-search "One's section" body))))
      (jetpacs--unclaim "settings" "One's section")
      (jetpacs--unclaim "settings" "Two's section"))))

(ert-deftest jetpacs-apps-view-resolver ()
  "Core view slots resolve to \"<appid>.<name>\" when the current app has one."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-shell-views nil))
    ;; No app at all: names pass through.
    (should (equal (jetpacs-shell-resolve-view "settings") "settings"))
    (jetpacs-shell-define-view "rich.settings" :builder #'ignore)
    (jetpacs-defapp "rich" :views '("rich.settings"))
    (jetpacs-defapp "plain" :views '())
    (should (equal (jetpacs-shell-resolve-view "settings") "rich.settings"))
    ;; An app without its own settings falls back to the stock name.
    (setq jetpacs-apps--current "plain")
    (should (equal (jetpacs-shell-resolve-view "settings") "settings"))))

(ert-deftest jetpacs-apps-per-app-fab ()
  "Each app's default FAB appears only while that app is current."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-apps--fabs nil)
        (jetpacs-shell-default-fab-function nil))
    (jetpacs-apps-set-default-fab "one" (lambda (_name) '((t . "fab-one"))))
    (jetpacs-defapp "one" :views '())
    (jetpacs-defapp "two" :views '())
    (should (equal (jetpacs-shell-default-fab "x") '((t . "fab-one"))))
    (setq jetpacs-apps--current "two")
    (should-not (jetpacs-shell-default-fab "x"))))

(ert-deftest jetpacs-apps-unregister-tears-down-chrome ()
  "jetpacs-app-unregister drops the app's chrome, links, and FAB."
  (let ((jetpacs-apps--registry nil)
        (jetpacs-apps--current nil)
        (jetpacs-shell-drawer-items nil)
        (jetpacs-shell-top-actions nil)
        (jetpacs-settings-links nil)
        (jetpacs-settings-native-links nil)
        (jetpacs-apps--fabs nil))
    (with-jetpacs-owner "gone"
      (jetpacs-shell-add-drawer-item 10 (lambda () '((label . "gone"))))
      (jetpacs-shell-add-top-action 10 (lambda () '((label . "gone"))))
      (jetpacs-settings-add-link 10 (lambda () '((label . "gone"))))
      (jetpacs-settings-add-native-link 10 (lambda () '((label . "gone-native")))))
    (jetpacs-apps-set-default-fab "gone" #'ignore)
    (jetpacs-defapp "gone" :views '())
    (jetpacs-app-unregister "gone")
    (should-not jetpacs-shell-drawer-items)
    (should-not jetpacs-shell-top-actions)
    (should-not jetpacs-settings-links)
    (should-not jetpacs-settings-native-links)
    (should-not (assoc "gone" jetpacs-apps--fabs))))

;; ─── Protocol frame shapes (golden snapshot, SPEC §10–§11) ──────────────────

(defconst jetpacs-tests--frames-golden-file
  (expand-file-name "frames.golden" jetpacs-tests--dir))

(defun jetpacs-tests--device-cases ()
  "One `capability.invoke' payload per `jetpacs-device-*' wrapper.
Captures what each thin defun hands the funnel — the SPEC §10 arg
shapes — without touching the wire."
  (let (calls)
    (cl-letf (((symbol-function 'jetpacs-device--invoke)
               (lambda (cap args &optional _callback)
                 (push `((kind . "capability.invoke")
                         (payload
                          . ((cap . ,cap)
                             (args . ,(or args (make-hash-table
                                                :test 'equal))))))
                       calls))))
      (jetpacs-device-intent :action "android.intent.action.VIEW"
                          :data "https://example.com")
      (jetpacs-device-intent :package "com.termux"
                          :class-name "com.termux.app.TermuxActivity"
                          :mode "activity"
                          :extras '((com.example.FLAG . t)
                                    (com.example.COUNT . 3)))
      (jetpacs-device-app-launch "org.gnu.emacs")
      (jetpacs-device-apps-list #'ignore)
      (jetpacs-device-vibrate 300)
      (jetpacs-device-vibrate nil '(0 100 50 100))
      (jetpacs-device-tts "hello" :pitch 1.2 :rate 0.9)
      (jetpacs-device-volume-set "music" 5)
      (jetpacs-device-ringer-mode "vibrate")
      (jetpacs-device-flashlight t)
      (jetpacs-device-flashlight nil)
      (jetpacs-device-media-key "play_pause")
      (jetpacs-device-clipboard-read #'ignore)
      (jetpacs-device-settings-open "wifi")
      (jetpacs-device-keep-screen-on t)
      (jetpacs-device-brightness 128)
      (jetpacs-device-dnd "priority"))
    (nreverse calls)))

(defun jetpacs-tests--frame-cases ()
  "Outbound protocol frame payloads pinned by test/frames.golden.
Trigger and capability frames today; new wire frames add cases here."
  (let ((jetpacs-triggers--table (make-hash-table :test 'equal)))
    ;; Batch Emacs is disconnected, so these registers never send.
    (jetpacs-trigger-register "power-sync" :type "power"
                           :params '((state . "connected"))
                           :policy "wake" :dedupe "power-sync" :throttle-s 60
                           :on-fire [((cap . "flashlight")
                                      (args . ((on . t))))])
    (jetpacs-trigger-register "screen-off" :type "screen"
                           :params '((state . "off")))
    (append
     (list
      `((kind . "triggers.set")
        (payload . ((triggers . ,(jetpacs-triggers--specs))))))
     (jetpacs-tests--device-cases))))

(defun jetpacs-tests--frame-lines ()
  (let ((i -1))
    (mapcar (lambda (c)
              (setq i (1+ i))
              (format "%02d %s" i
                      (json-serialize (jetpacs-tests--canon c)
                                      :null-object :null
                                      :false-object :false)))
            (jetpacs-tests--frame-cases))))

(defun jetpacs-tests-regen-frame-golden ()
  "Rewrite the frame golden snapshot from the current senders.
Only run this after an INTENTIONAL wire-format change; review the diff."
  (with-temp-file jetpacs-tests--frames-golden-file
    (insert (string-join (jetpacs-tests--frame-lines) "\n") "\n"))
  (message "Wrote %s" jetpacs-tests--frames-golden-file))

(ert-deftest jetpacs-frames-wire-format ()
  "Trigger/capability frame payloads match the committed golden snapshot."
  (should (file-readable-p jetpacs-tests--frames-golden-file))
  (should (equal (jetpacs-tests--frame-lines)
                 (split-string
                  (with-temp-buffer
                    (insert-file-contents jetpacs-tests--frames-golden-file)
                    (buffer-string))
                  "\n" t))))

;; ─── Journal (PKM Task 5) ────────────────────────────────────────────────────

;; ─── Saved views (PKM Task 11) ───────────────────────────────────────────────

(defun jetpacs-tests--views-items ()
  "Synthetic heading items exercising all three renderings."
  '(((headline . "Write spec") (todo . "TODO") (tags . ["work"])
     (scheduled . "<2026-07-04 Sat>")
     (ref . ((file . "/tmp/a.org") (pos . 1) (headline . "Write spec"))))
    ((headline . "Ship it") (todo . "NEXT") (tags . [])
     (scheduled . nil)
     (ref . ((file . "/tmp/a.org") (pos . 50) (headline . "Ship it"))))))

;; ─── Org-defined automations (AUTO Task 13) ──────────────────────────────────

(defmacro jetpacs-tests--with-automations-file (content &rest body)
  "Run BODY with a temp automations file holding CONTENT."
  (declare (indent 1))
  `(let* ((file (make-temp-file "jetpacs-autom" nil ".org"))
          (glasspane-automations-file file)
          (glasspane-automations--ids nil)
          (jetpacs-triggers--table (make-hash-table :test 'equal))
          (jetpacs-triggers-changed-hook nil))
     (unwind-protect
         (progn (with-temp-file file (insert ,content))
                ,@body)
       (when-let ((buf (find-buffer-visiting file))) (kill-buffer buf))
       (delete-file file))))

;; ─── Sparse filter (orgro parity) ────────────────────────────────────────────

;; ─── Notes bridge: wikilinks + backlinks (PKM 3–4, vulpea mocked) ────────────

(defmacro jetpacs-tests--with-fake-vulpea (notes &rest body)
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

(ert-deftest jetpacs-buffer-overlay-hiding-fidelity ()
  "The generic renderer honors overlay `display' and `invisible' —
the property the whole SRS skin rests on: org-srs hides answers with
exactly these, so the phone must show the ellipsis, never the answer."
  (with-temp-buffer
    (insert "Front text\nAnswer text\nFolded text\n")
    (add-to-invisibility-spec 'jetpacs-test-fold)
    ;; Card-style hiding: the answer displays as an ellipsis.
    (let ((ov (make-overlay 12 23)))        ; "Answer text"
      (overlay-put ov 'display "..."))
    ;; Fold-style hiding: the region is invisible.
    (let ((ov (make-overlay 24 35)))        ; "Folded text"
      (overlay-put ov 'invisible 'jetpacs-test-fold))
    (let ((json (json-serialize
                 (jetpacs-tests--canon (apply #'jetpacs-column (jetpacs-buffer-render)))
                 :null-object :null :false-object :false)))
      (should (string-search "Front text" json))
      (should (string-search "..." json))
      (should-not (string-search "Answer text" json))
      (should-not (string-search "Folded text" json)))))

(defvar jetpacs-tests--srs-items nil "The mocked pending queue (item-args).")
(defvar jetpacs-tests--srs-rated nil "Ratings recorded by the mock engine.")

(defmacro jetpacs-tests--with-fake-org-srs (&rest body)
  "Run BODY with a minimal org-srs *engine* mock.
`jetpacs-tests--srs-items' is the pending queue (a list of item-args);
`jetpacs-tests--srs-rated' records ratings.  Session state is reset per
invocation; per-item positions (markers, regions, clozes) are mocked
in individual tests where needed."
  (declare (indent 0))
  `(let ((glasspane-srs--available t)
         (glasspane-srs--active nil)
         (glasspane-srs--current nil)
         (glasspane-srs--revealed nil)
         (glasspane-srs--undo nil)
         (jetpacs-tests--srs-items nil)
         (jetpacs-tests--srs-rated nil)
         (jetpacs-shell--snackbar nil))
     (cl-letf (((symbol-function 'org-srs-review-pending-items)
                (lambda (&optional _) jetpacs-tests--srs-items))
               ((symbol-function 'org-srs-item-marker)
                (lambda (&rest _) (copy-marker (point-min))))
               ((symbol-function 'org-srs-review-rate)
                (lambda (rating &rest _) (push rating jetpacs-tests--srs-rated)))
               ((symbol-function 'org-srs-item-call-with-current)
                (lambda (thunk &rest _) (funcall thunk)))
               ((symbol-function 'org-srs-table-goto-column)
                (lambda (_) t))
               ((symbol-function 'org-srs-stats-intervals)
                (lambda () '(:again 600 :hard 86400 :good 259200 :easy 604800)))
               ((symbol-function 'org-srs-time-seconds-desc)
                (lambda (secs) (list (/ secs 60) :minute)))
               ((symbol-function 'jetpacs-shell-push)
                (cl-function (lambda (&optional _tab &key _switch-to)))))
       ,@body)))

; heading line stripped

;; ─── Theme mirroring ────────────────────────────────────────────────────────

(ert-deftest jetpacs-theme-hex-parsing ()
  "Hex colors parse display-independently (a tty frame must not quantize)."
  (should (equal (jetpacs-theme--hex "#2E3440") "#2e3440"))
  (should (equal (jetpacs-theme--hex "#2e3440") "#2e3440"))
  (should (equal (jetpacs-theme--rgb "#f00") '(1.0 0.0 0.0)))
  (should-not (jetpacs-theme--rgb "unspecified-bg"))
  (should-not (jetpacs-theme--rgb "unspecified-fg"))
  (should-not (jetpacs-theme--rgb 'unspecified))
  (should-not (jetpacs-theme--rgb "#12345"))
  (should (equal (jetpacs-theme--blend "#000000" "#ffffff" 0.25) "#bfbfbf"))
  (should (jetpacs-theme--dark-p "#2e3440"))
  (should-not (jetpacs-theme--dark-p "#eceff4")))

(ert-deftest jetpacs-theme-generic-palette ()
  "The face-extraction path builds Material roles from resolved face colors."
  (should-not (jetpacs-theme--modus-p))
  (let* ((fixture '(((default . :background) . "#eceff4")
                    ((default . :foreground) . "#2e3440")
                    ((link . :foreground) . "#5e81ac")
                    ((error . :foreground) . "#bf616a")
                    ((font-lock-keyword-face . :foreground) . "#3b5b8c")
                    ((font-lock-string-face . :foreground) . "#4f6f3f")))
         (real (symbol-function 'face-attribute)))
    (cl-letf (((symbol-function 'face-attribute)
               (lambda (face attr &optional frame inherit)
                 (or (cdr (assoc (cons face attr) fixture))
                     (funcall real face attr frame inherit)))))
      (let* ((payload (jetpacs-theme-payload))
             (colors (alist-get 'colors payload))
             (syntax (alist-get 'syntax payload)))
        (should (eq (alist-get 'dark payload) :false))
        (should (equal (alist-get 'background colors) "#eceff4"))
        (should (equal (alist-get 'on_surface colors) "#2e3440"))
        ;; Primary is the IDENTITY accent — the keyword face, not the
        ;; link face (links are blue in nearly every theme; primary←link
        ;; painted the FAB blue under purple-identity themes).
        (should (equal (alist-get 'primary colors) "#3b5b8c"))
        ;; Accent text sits on the theme background it was designed against.
        (should (equal (alist-get 'on_primary colors) "#eceff4"))
        ;; Secondary is the muted derivation of primary, not a second hue.
        (should (alist-get 'secondary colors))
        (should-not (equal (alist-get 'secondary colors)
                           (alist-get 'primary colors)))
        (should (equal (alist-get 'error colors) "#bf616a"))
        ;; Containers are derived blends: present, and not the raw accent.
        (should (alist-get 'primary_container colors))
        (should-not (equal (alist-get 'primary_container colors)
                           (alist-get 'primary colors)))
        (should (equal (alist-get 'keyword syntax) "#3b5b8c"))
        (should (equal (alist-get 'string syntax) "#4f6f3f"))
        ;; The whole frame must serialize for the wire.
        (should (stringp (json-serialize payload
                                         :null-object :null
                                         :false-object :false)))))))

(ert-deftest jetpacs-theme-batch-frame-sends-nothing ()
  "A frame with no resolvable default colors yields no payload (never push
garbage from a tty/batch session)."
  (should-not (jetpacs-theme--modus-p))
  (let ((real (symbol-function 'face-attribute)))
    (cl-letf (((symbol-function 'face-attribute)
               (lambda (face attr &optional frame inherit)
                 (if (eq face 'default) 'unspecified
                   (funcall real face attr frame inherit)))))
      (should-not (jetpacs-theme-payload)))))

(ert-deftest jetpacs-theme-modus-palette ()
  "The modus path reads the palette API — exact in batch, where face specs
don't even apply (min-colors) but the palette variables are plain data."
  (skip-unless (memq 'modus-vivendi (custom-available-themes)))
  (unwind-protect
      (progn
        (load-theme 'modus-vivendi t)
        (should (jetpacs-theme--modus-p))
        (let* ((payload (jetpacs-theme-payload))
               (colors (alist-get 'colors payload)))
          (should (eq (alist-get 'dark payload) t))
          (should (equal (alist-get 'background colors)
                         (jetpacs-theme--modus 'bg-main)))
          (should (equal (alist-get 'primary colors)
                         (jetpacs-theme--modus 'blue)))
          (should (equal (alist-get 'error colors)
                         (jetpacs-theme--modus 'red)))
          ;; Secondary stays in the identity hue, muted (modus blue-faint).
          (should (equal (alist-get 'secondary colors)
                         (jetpacs-theme--modus 'blue-faint)))
          ;; Container roles take the palette's purpose-built subtle tints.
          (should (equal (alist-get 'primary_container colors)
                         (jetpacs-theme--modus 'bg-blue-subtle)))
          (should (equal (alist-get 'secondary_container colors)
                         (jetpacs-theme--modus 'bg-blue-nuanced)))
          (should (equal (alist-get 'on_primary_container colors)
                         (jetpacs-theme--modus 'fg-main)))
          (should (stringp (json-serialize payload
                                           :null-object :null
                                           :false-object :false)))))
    (disable-theme 'modus-vivendi)))

;; ─── Stock settings screen ──────────────────────────────────────────────────

(ert-deftest jetpacs-shell-stock-settings-screen ()
  "The foundation separates native Jetpacs and Emacs settings."
  (should (assoc "settings" jetpacs-shell-views))
  (should (assoc "Bridge" jetpacs-settings-registry))
  ;; Both settings domains are first-class drawer destinations.
  (let ((items (delq nil (mapcar (lambda (e) (funcall (cadr e)))
                                 jetpacs-shell-drawer-items))))
    (should (= 1 (cl-count-if
                  (lambda (item) (equal (alist-get 'label item) "Jetpacs Settings"))
                  items)))
    (should (= 1 (cl-count-if
                  (lambda (item) (equal (alist-get 'label item) "Emacs Settings"))
                  items))))
  ;; The stock body renders native Jetpacs settings separately from every
  ;; Emacs-owned defcustom and satellite destination.
  (let ((body (prin1-to-string (jetpacs-shell-settings-body))))
    (should (string-search "Jetpacs Settings" body))
    (should (string-search "jetpacs.settings.open" body))
    (should (string-search "Emacs Settings" body))
    (should (string-search "setting/jetpacs-theme-sync" body))
    (should (string-search "setting/jetpacs-dialog-style" body))
    (should (string-search "setting/jetpacs-reconnect" body))))

(ert-deftest jetpacs-shell-settings-view-replaceable ()
  "An app's own \"settings\" registration replaces the stock view in place."
  (let ((orig (cdr (assoc "settings" jetpacs-shell-views))))
    (should orig)
    (unwind-protect
        (progn
          (jetpacs-shell-define-view "settings" :builder #'ignore)
          (should (eq (plist-get (cdr (assoc "settings" jetpacs-shell-views))
                                 :builder)
                      #'ignore))
          (should (= 1 (cl-count "settings" jetpacs-shell-views
                                 :key #'car :test #'equal))))
      (jetpacs-shell-define-view "settings"
        :builder (plist-get orig :builder)
        :order (plist-get orig :order)))))

(ert-deftest jetpacs-theme-push-gating ()
  "No auto-push while disconnected; the manual command degrades to a message."
  (setq jetpacs-theme--timer nil)
  (let ((jetpacs-theme-sync t))
    (jetpacs-theme--push-soon)
    (should-not jetpacs-theme--timer))
  ;; Disconnected `M-x jetpacs-theme-send' must message, not error or hang.
  (jetpacs-theme-send))

;; ─── Phase G: foundation-owned root + init seam ─────────────────────────────

(ert-deftest jetpacs-install-invariants-reasserts ()
  "The isolation seams survive a user `setq'.
`jetpacs-before-connect-hook' runs at the top of `jetpacs-connect' — after
the user's whole init.el — and re-installs the four internal seam vars, so
nothing done during init can leak another app's views/chrome/settings to
the first served frame."
  (let ((jetpacs-shell-view-filter-function nil)
        (jetpacs-shell-chrome-filter-function nil)
        (jetpacs-shell-view-resolver-function nil)
        (jetpacs-settings-section-filter-function nil))
    ;; A stray user setq has nulled the whole gating mechanism...
    (should-not jetpacs-shell-view-filter-function)
    ;; ...connect's first act (this hook) restores every seam.
    (run-hooks 'jetpacs-before-connect-hook)
    (should (eq jetpacs-shell-view-filter-function #'jetpacs-apps--view-visible-p))
    (should (eq jetpacs-shell-chrome-filter-function #'jetpacs-apps-current-p))
    (should (eq jetpacs-shell-view-resolver-function #'jetpacs-apps--resolve-view))
    (should (eq jetpacs-settings-section-filter-function #'jetpacs-apps-current-p))))

(ert-deftest jetpacs-settings-custom-file-guard ()
  "The custom-file guard latches a warning for a path under `jetpacs-root'
and stays silent for the safe ~/.emacs.d/custom.el location."
  (let ((jetpacs-settings--custom-file-warned nil)
        (inside (expand-file-name "custom.el" jetpacs-lib-dir))
        (safe (expand-file-name "custom.el" user-emacs-directory)))
    ;; Safe location: no warning, flag untouched.
    (jetpacs-settings--warn-if-custom-file-managed safe)
    (should-not jetpacs-settings--custom-file-warned)
    ;; Under the sync tree: warns once (flag latches so it fires only once).
    (jetpacs-settings--warn-if-custom-file-managed inside)
    (should jetpacs-settings--custom-file-warned)))

(defvar jetpacs-tests--cfg-a nil "Scratch var set by app-config test fixtures.")

(ert-deftest jetpacs-app-config-verbs ()
  "sync overwrites and loads; ensure seeds once then only loads; a missing
subtree loads nothing without error."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-root" t)))
         (jetpacs-root tmp)
         (id "testapp")
         (afile (lambda () (expand-file-name "a.el" (jetpacs-app-dir id)))))
    (unwind-protect
        (progn
          ;; app-dir is keyed under apps/<id>/ within the (rebound) root.
          (should (equal (jetpacs-app-dir id)
                         (file-name-as-directory
                          (expand-file-name (concat "apps/" id) tmp))))
          ;; Missing subtree: load is a silent no-op.
          (setq jetpacs-tests--cfg-a nil)
          (jetpacs-app-config-load id)
          (should-not jetpacs-tests--cfg-a)
          ;; ensure: first run seeds the file and loads it.
          (jetpacs-app-config-ensure
           id (list (cons "a.el" "(setq jetpacs-tests--cfg-a 1)\n")))
          (should (file-exists-p (funcall afile)))
          (should (= jetpacs-tests--cfg-a 1))
          ;; ensure again with DIFFERENT content: create-once => not rewritten.
          (jetpacs-app-config-ensure
           id (list (cons "a.el" "(setq jetpacs-tests--cfg-a 2)\n")))
          (with-temp-buffer
            (insert-file-contents (funcall afile))
            (should (string-match-p "cfg-a 1" (buffer-string))))
          ;; sync: the explicit upgrade path DOES overwrite and reload.
          (jetpacs-app-config-sync
           id (list (cons "a.el" "(setq jetpacs-tests--cfg-a 3)\n")))
          (should (= jetpacs-tests--cfg-a 3)))
      (delete-directory tmp t))))

(ert-deftest jetpacs-config-seed-file-create-once ()
  "seed-file writes once (making parent dirs) and never overwrites."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-seed" t)))
         (f (expand-file-name "sub/user.el" tmp)))
    (unwind-protect
        (progn
          (jetpacs-config-seed-file f "first\n")
          (should (equal "first\n"
                         (with-temp-buffer (insert-file-contents f) (buffer-string))))
          ;; A second call must NOT clobber the (possibly user-edited) file.
          (jetpacs-config-seed-file f "second\n")
          (should (equal "first\n"
                         (with-temp-buffer (insert-file-contents f) (buffer-string)))))
      (delete-directory tmp t))))

(ert-deftest jetpacs-config-migrate-legacy-nondestructive ()
  "The old ~/.emacs.d/elisp/ layout migrates into the jetpacs/ root:
bundles -> lib/, app subtrees -> apps/<id>/, apps.el seeded with the
discovered app bundles (never core); the old elisp/ is left intact and a
second run is a no-op."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-mig" t)))
         (user-emacs-directory tmp)
         (jetpacs-root (expand-file-name "jetpacs/" tmp))
         (jetpacs-lib-dir (expand-file-name "lib/" jetpacs-root))
         (old (expand-file-name "elisp/" tmp)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "glasspane" old) t)
          (write-region "core" nil (expand-file-name "jetpacs-core.el" old) nil 'silent)
          (write-region "app" nil (expand-file-name "glasspane.el" old) nil 'silent)
          (write-region ";; cfg" nil
                        (expand-file-name "glasspane/org-defaults.el" old) nil 'silent)
          (jetpacs-config-migrate-legacy)
          ;; Bundle .el files copied into lib/.
          (should (file-exists-p (expand-file-name "jetpacs-core.el" jetpacs-lib-dir)))
          (should (file-exists-p (expand-file-name "glasspane.el" jetpacs-lib-dir)))
          ;; App config subtree copied under apps/glasspane/.
          (should (file-exists-p
                   (expand-file-name "org-defaults.el" (jetpacs-app-dir "glasspane"))))
          ;; apps.el seeded, listing the app bundle but never the core bundle.
          (let ((apps (expand-file-name "apps.el" jetpacs-root)))
            (should (file-exists-p apps))
            (with-temp-buffer
              (insert-file-contents apps)
              (should (string-match-p "glasspane\\.el" (buffer-string)))
              (should-not (string-match-p "jetpacs-core" (buffer-string)))))
          ;; Non-destructive: the old tree is still there.
          (should (file-exists-p (expand-file-name "jetpacs-core.el" old)))
          ;; Idempotent: a second run (apps.el now exists) does nothing, no error.
          (jetpacs-config-migrate-legacy))
      (delete-directory tmp t))))

;; ─── Owner-scoped reminders ──────────────────────────────────────────────────

(ert-deftest jetpacs-reminders-owner-set-negotiation ()
  "Owner-scoped when the capability is granted; a plain global set when a lone
app; warn-and-arm-nothing when owner-unaware and a second app is present."
  (let (sent)
    (cl-letf (((symbol-function 'jetpacs-send)
               (lambda (&rest args) (push args sent) t)))
      ;; 1. Granted `reminders.owner' -> scoped send carrying the owner.
      (cl-letf (((symbol-function 'jetpacs-granted-p)
                 (lambda (cap) (equal cap "reminders.owner"))))
        (setq sent nil)
        (should (jetpacs-reminders-owner-set '(((id . "a") (at_ms . 1))) "glasspane"))
        (let ((call (car sent)))
          (should (equal (car call) "reminders.set"))
          (should (equal (alist-get 'owner (cadr call)) "glasspane"))))
      ;; 2. Owner-unaware companion, only one app -> plain global set (no owner).
      (cl-letf (((symbol-function 'jetpacs-granted-p) (lambda (_) nil))
                ((symbol-function 'jetpacs-apps--multi-p) (lambda () nil)))
        (setq sent nil)
        (should (jetpacs-reminders-owner-set '() "glasspane"))
        (let ((call (car sent)))
          (should (equal (car call) "reminders.set"))
          (should-not (assq 'owner (cadr call)))))
      ;; 3. Owner-unaware companion, a second app present -> refuse: nothing sent.
      (cl-letf (((symbol-function 'jetpacs-granted-p) (lambda (_) nil))
                ((symbol-function 'jetpacs-apps--multi-p) (lambda () t))
                ((symbol-function 'display-warning) (lambda (&rest _) nil)))
        (setq sent nil)
        (let ((jetpacs-reminders--warned nil))
          (should-not (jetpacs-reminders-owner-set
                       '(((id . "a") (at_ms . 1))) "glasspane")))
        (should (null sent))))))

(provide 'jetpacs-tests)
;;; jetpacs-tests.el ends here
