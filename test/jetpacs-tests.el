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
(require 'jetpacs-source)
(require 'jetpacs-shell)
(require 'jetpacs-spec)
(require 'jetpacs-keymap)
(require 'jetpacs-results)
(require 'jetpacs-hypertext)
(require 'jetpacs-sections)
(require 'jetpacs-hosts)
(require 'jetpacs-files)
(require 'jetpacs-minibuffer)
(require 'jetpacs-emacs-ui)
(require 'jetpacs-complete)
(require 'jetpacs-sync)
(require 'jetpacs-settings)
(require 'jetpacs-theme)
(require 'jetpacs-modus)
(require 'jetpacs-automations)
(require 'jetpacs-app-store)
(require 'jetpacs-org)

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
        ;; label is "buffer:line  ·  i/N" — carries the file:line and counter
        (should (string-match-p ":[0-9]+" label))
        (should (string-match-p "[0-9]+/[0-9]+\\'" label))))))

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

(ert-deftest jetpacs-results-step-advances-and-clamps ()
  "Stepping walks the result set and clamps at both ends."
  (jetpacs-tests--with-occur ob
      "a needle\nb\nc needle\nd\ne needle\n" "needle"   ; 3 matches
    (let* ((jetpacs-results--nav nil)
           (loci (jetpacs-results--loci ob))
           captured
           (jetpacs-results-visit-region-function
            (lambda (_name _beg _end label &optional _point)
              (setq captured label)))
           (visit (gethash "results.visit" jetpacs-action-handlers))
           (step (gethash "results.step" jetpacs-action-handlers)))
      (should (= 3 (length loci)))
      (funcall visit `((buffer . ,(buffer-name ob)) (pos . ,(car (nth 0 loci)))) nil)
      (should (= 0 (plist-get jetpacs-results--nav :index)))
      (should (string-match-p "1/3" captured))
      (funcall step '((dir . 1)) nil)
      (should (= 1 (plist-get jetpacs-results--nav :index)))
      (should (string-match-p "2/3" captured))
      (funcall step '((dir . 1)) nil)
      (should (= 2 (plist-get jetpacs-results--nav :index)))
      (should (string-match-p "3/3" captured))
      ;; Clamp past the end: index unchanged, seam not re-invoked.
      (let ((before captured))
        (funcall step '((dir . 1)) nil)
        (should (= 2 (plist-get jetpacs-results--nav :index)))
        (should (equal before captured)))
      ;; Back down, then clamp past the start.
      (funcall step '((dir . -1)) nil)
      (funcall step '((dir . -1)) nil)
      (should (= 0 (plist-get jetpacs-results--nav :index)))
      (let ((before captured))
        (funcall step '((dir . -1)) nil)
        (should (= 0 (plist-get jetpacs-results--nav :index)))
        (should (equal before captured))))))

(ert-deftest jetpacs-results-stepper-actions ()
  "Stepper chrome shows only for the visited source buffer, one direction per end."
  (jetpacs-tests--with-occur ob
      "a needle\nb\nc needle\nd\ne needle\n" "needle"
    (let* ((jetpacs-results--nav nil)
           (loci (jetpacs-results--loci ob))
           (jetpacs-results-visit-region-function (lambda (&rest _) nil))
           (visit (gethash "results.visit" jetpacs-action-handlers))
           (step (gethash "results.step" jetpacs-action-handlers)))
      (funcall visit `((buffer . ,(buffer-name ob)) (pos . ,(car (nth 0 loci)))) nil)
      (let ((dest (plist-get jetpacs-results--nav :dest)))
        ;; A different buffer gets no stepper chrome.
        (should-not (jetpacs-results-buffer-view-actions "no-such-buffer"))
        ;; At the first locus only the forward button is offered (dir +1).
        (let ((btns (jetpacs-results-buffer-view-actions dest)))
          (should (= 1 (length btns)))
          (should (= 1 (alist-get 'dir (alist-get 'args
                                        (alist-get 'on_tap (car btns)))))))
        ;; In the middle, both directions.
        (funcall step '((dir . 1)) nil)
        (should (= 2 (length (jetpacs-results-buffer-view-actions dest))))
        ;; At the last locus only the back button remains (dir -1).
        (funcall step '((dir . 1)) nil)
        (let ((btns (jetpacs-results-buffer-view-actions dest)))
          (should (= 1 (length btns)))
          (should (= -1 (alist-get 'dir (alist-get 'args
                                         (alist-get 'on_tap (car btns)))))))))))

(ert-deftest jetpacs-results-file-loci-visit-and-step ()
  "Files content-search hits ride the shared substrate: visit by index + stepper."
  (let* ((dir (file-name-as-directory (make-temp-file "jetpacs-grep" t)))
         (f (expand-file-name "notes.txt" dir)))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "needle one\nplain\nneedle two\nplain\nneedle three\n"))
          (let* ((jetpacs-files-roots (list (cons "R" dir)))
                 (jetpacs-files--grep (jetpacs-files--grep-scan dir "needle"))
                 (jetpacs-results--nav nil)
                 (jetpacs-results--file-set nil)
                 captured
                 (jetpacs-results-visit-region-function
                  (lambda (name _beg _end label &optional _point)
                    (setq captured (list name label))))
                 (visit (gethash "results.visit" jetpacs-action-handlers))
                 (step (gethash "results.step" jetpacs-action-handlers)))
            (should (= 3 (length (plist-get jetpacs-files--grep :hits))))
            ;; Rendering the results body arms the shared file-locus set.
            (jetpacs-files--grep-body)
            (should (= 3 (length jetpacs-results--file-set)))
            (should (equal f (plist-get (car jetpacs-results--file-set) :file)))
            ;; Visit the first hit by index; nav is file-kind with a counter.
            (funcall visit '((index . 0)) nil)
            (should (eq 'file (plist-get jetpacs-results--nav :kind)))
            (should (= 0 (plist-get jetpacs-results--nav :index)))
            (should (= 3 (plist-get jetpacs-results--nav :count)))
            (should (string-match-p "1/3" (nth 1 captured)))
            (let ((dest (plist-get jetpacs-results--nav :dest)))
              ;; Stepper chrome shows for the visited file buffer, first end only.
              (should (= 1 (length (jetpacs-results-buffer-view-actions dest))))
              (should-not (jetpacs-results-buffer-view-actions "no-such-buffer"))
              ;; Step to the last hit, then clamp.
              (funcall step '((dir . 1)) nil)
              (funcall step '((dir . 1)) nil)
              (should (= 2 (plist-get jetpacs-results--nav :index)))
              (should (string-match-p "3/3" (nth 1 captured)))
              (let ((before (nth 1 captured)))
                (funcall step '((dir . 1)) nil)
                (should (= 2 (plist-get jetpacs-results--nav :index)))
                (should (equal before (nth 1 captured)))))))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (ignore-errors (delete-directory dir t)))))

;; ─── jetpacs-org primitives ──────────────────────────────────────────────────
;;
;; The core org layer shipped its planning mutation broken (string vs symbol
;; planning type, and a call to the nonexistent `org-remove-planning-info');
;; these smoke tests exercise the parser, typed extraction, and every mutation
;; primitive so that class of bug can't ship silently.

(defmacro jetpacs-tests--with-org-file (var content &rest body)
  "Bind VAR to a live org buffer visiting a temp file with CONTENT; run BODY."
  (declare (indent 2))
  (let ((f (make-symbol "f")))
    `(let ((,f (make-temp-file "jetpacs-org" nil ".org")))
       (unwind-protect
           (progn
             (with-temp-file ,f (insert ,content))
             (let ((,var (find-file-noselect ,f)))
               (with-current-buffer ,var ,@body)))
         (when (get-file-buffer ,f) (kill-buffer (get-file-buffer ,f)))
         (ignore-errors (delete-file ,f))))))

(ert-deftest jetpacs-org-parse-query-shapes ()
  "The query parser handles sexp passthrough, filter tokens, and free text."
  (should (equal '(todo "TODO") (jetpacs-org-parse-query "'(todo \"TODO\")")))
  (should (equal '(and (todo "TODO" "NEXT") (tags "work"))
                 (jetpacs-org-parse-query "todo:TODO,NEXT tags:work")))
  (should (equal '(regexp "hello") (jetpacs-org-parse-query "hello")))
  (should (null (jetpacs-org-parse-query "   ")))
  (should-error (jetpacs-org-parse-query "(and (todo") :type 'user-error))

(ert-deftest jetpacs-org-typed-value ()
  "Typed extraction reads checkbox/number/list per the requested type."
  ;; NB: avoid property names org treats as special (TAGS, TODO, …); a
  ;; drawer \"Tags\" is shadowed by the heading's real tags.
  (jetpacs-tests--with-org-file buf
      "* Rec\n:PROPERTIES:\n:Done: [X]\n:Qty: 7\n:Items: a, b, c\n:END:\n"
    (goto-char (point-min))
    (should (eq t (jetpacs-org-entry-typed-value "Done" 'checkbox)))
    (should (= 7 (jetpacs-org-entry-typed-value "Qty" 'number)))
    (should (equal '("a" "b" "c") (jetpacs-org-entry-typed-value "Items" 'list)))))

(ert-deftest jetpacs-org-mutations ()
  "Property, TODO, and planning mutations apply at a heading ref.
The planning add+remove path was previously non-functional."
  (jetpacs-tests--with-org-file buf
      "* Task\n"
    (goto-char (point-min))
    (let ((ref (jetpacs-org-heading-ref)))
      (jetpacs-org-set-property ref 'test "Owner" "cc")
      (should (equal "cc" (org-entry-get (point-min) "Owner")))
      (jetpacs-org-toggle-todo ref 'test "TODO")
      (goto-char (point-min))
      (should (equal "TODO" (org-get-todo-state)))
      ;; planning: add both types, then remove
      (jetpacs-org-set-planning ref 'test "SCHEDULED" "2026-07-15")
      (should (org-entry-get (point-min) "SCHEDULED"))
      (jetpacs-org-set-planning ref 'test "DEADLINE" "2026-07-20")
      (should (org-entry-get (point-min) "DEADLINE"))
      (jetpacs-org-set-planning ref 'test "SCHEDULED" "")
      (should-not (org-entry-get (point-min) "SCHEDULED"))
      (should (org-entry-get (point-min) "DEADLINE")))))

(ert-deftest jetpacs-org-entry-matches ()
  "The point accessor of the query grammar, term by term."
  (jetpacs-tests--with-org-file buf
      (concat "* TODO Buy milk :errand:\n"
              "SCHEDULED: <2026-07-15>\n"
              ":PROPERTIES:\n:Owner: cc\n:END:\n"
              "some body needle here\n"
              "* DONE [#A] Ship release :work:\n"
              "** Child\n")
    (goto-char (point-min))
    (should (jetpacs-org-entry-matches-p '(todo)))
    (should (jetpacs-org-entry-matches-p '(todo "TODO")))
    (should-not (jetpacs-org-entry-matches-p '(done)))
    (should (jetpacs-org-entry-matches-p '(tags "errand")))
    (should-not (jetpacs-org-entry-matches-p '(tags "work")))
    (should (jetpacs-org-entry-matches-p '(heading "milk")))
    (should (jetpacs-org-entry-matches-p '(regexp "needle")))
    (should-not (jetpacs-org-entry-matches-p '(regexp "absent")))
    (should (jetpacs-org-entry-matches-p '(property "Owner" "cc")))
    (should (jetpacs-org-entry-matches-p '(property "Owner")))
    (should (jetpacs-org-entry-matches-p '(level 1)))
    (should (jetpacs-org-entry-matches-p '(scheduled :on "2026-07-15")))
    (should-not (jetpacs-org-entry-matches-p '(deadline)))
    (should (jetpacs-org-entry-matches-p
             '(and (todo "TODO") (or (tags "errand") (tags "work")))))
    (should (jetpacs-org-entry-matches-p '(not (done))))
    ;; second heading: done + priority
    (search-forward "* DONE")
    (should (jetpacs-org-entry-matches-p '(done)))
    (should-not (jetpacs-org-entry-matches-p '(todo)))
    (should (jetpacs-org-entry-matches-p '(priority "A")))
    (should (jetpacs-org-entry-matches-p '(priority >= "B")))
    (should-not (jetpacs-org-entry-matches-p '(priority < "A")))
    ;; unsupported term names org-ql
    (should-error (jetpacs-org-entry-matches-p '(clocked)) :type 'user-error)))

(defmacro jetpacs-tests--with-note-accessors (&rest body)
  "Run BODY with the `vulpea-note-*' accessors reading plist notes.
Covers exactly the slots `jetpacs-org--note-get' consumes, so the note
path of the grammar is testable with no vulpea installed."
  `(cl-letf (((symbol-function 'vulpea-note-todo)
              (lambda (n) (plist-get n :todo)))
             ((symbol-function 'vulpea-note-tags)
              (lambda (n) (plist-get n :tags)))
             ((symbol-function 'vulpea-note-priority)
              (lambda (n) (plist-get n :priority)))
             ((symbol-function 'vulpea-note-title)
              (lambda (n) (plist-get n :title)))
             ((symbol-function 'vulpea-note-level)
              (lambda (n) (plist-get n :level)))
             ((symbol-function 'vulpea-note-properties)
              (lambda (n) (plist-get n :properties)))
             ((symbol-function 'vulpea-note-scheduled)
              (lambda (n) (plist-get n :scheduled)))
             ((symbol-function 'vulpea-note-deadline)
              (lambda (n) (plist-get n :deadline)))
             ((symbol-function 'vulpea-note-closed)
              (lambda (n) (plist-get n :closed)))
             ((symbol-function 'vulpea-note-path)
              (lambda (n) (plist-get n :path)))
             ((symbol-function 'vulpea-note-outline-path)
              (lambda (n) (plist-get n :outline-path))))
     ,@body))

(ert-deftest jetpacs-org-note-matches ()
  "The note accessor agrees with the point accessor on equivalent data.
One grammar, two accessors — this is the agreement contract that lets
the composer delete its own matcher."
  (jetpacs-tests--with-note-accessors
   (let ((todo-note '(:todo "TODO" :tags ("errand") :priority nil
                      :title "Buy milk" :level 1
                      :properties (("OWNER" . "cc"))
                      :scheduled "<2026-07-15>" :deadline nil :closed nil))
         (done-note '(:todo "DONE" :tags ("work") :priority ?A
                      :title "Ship release" :level 1
                      :properties nil :scheduled nil :deadline nil
                      :closed "[2026-07-10]")))
     (dolist (case `(((todo)                    ,todo-note t)
                     ((todo "TODO")             ,todo-note t)
                     ((done)                    ,todo-note nil)
                     ((done)                    ,done-note t)
                     ((todo)                    ,done-note nil)
                     ((tags "errand")           ,todo-note t)
                     ((tags "work")             ,todo-note nil)
                     ((heading "milk")          ,todo-note t)
                     ((property "Owner" "cc")   ,todo-note t)
                     ((property "Owner")        ,todo-note t)
                     ((level 1)                 ,todo-note t)
                     ((level 2 3)               ,todo-note nil)
                     ((scheduled :on "2026-07-15") ,todo-note t)
                     ((deadline)                ,todo-note nil)
                     ((priority "A")            ,done-note t)
                     ((priority >= "B")         ,done-note t)
                     ((priority < "A")          ,done-note nil)
                     ((and (todo "TODO") (or (tags "errand") (tags "work")))
                      ,todo-note t)
                     ((not (done))              ,todo-note t)))
       (pcase-let ((`(,tree ,note ,want) case))
         (should (eq (and (jetpacs-org-note-matches-p tree note) t) want))))
     ;; Index-only semantics, distinct from point by design:
     ;; regexp searches title + properties (no body in the index) …
     (should (jetpacs-org-note-matches-p '(regexp "milk") todo-note))
     (should (jetpacs-org-note-matches-p '(regexp "cc") todo-note))
     (should-not (jetpacs-org-note-matches-p '(regexp "body") todo-note))
     ;; … string priorities normalize to chars …
     (should (jetpacs-org-note-matches-p
              '(priority "B") '(:todo nil :priority "B" :title "x")))
     ;; … done-ness falls back to "DONE"/CLOSED when org-done-keywords is
     ;; unset (the headless-scan approximation) …
     (let ((org-done-keywords nil))
       (should (jetpacs-org-note-matches-p '(done) done-note))
       (should (jetpacs-org-note-matches-p
                '(done) '(:todo "WIP" :closed "[2026-07-01]" :title "x"))))
     ;; … and unsupported terms error, so callers can route to org-ql.
     (should-error (jetpacs-org-note-matches-p '(clocked) todo-note)
                   :type 'user-error))))

(ert-deftest jetpacs-org-note-query-support ()
  "The supported-terms predicate routes sexps between index and org-ql."
  (should (jetpacs-org-note-query-supported-p nil))
  (should (jetpacs-org-note-query-supported-p '(todo "TODO")))
  (should (jetpacs-org-note-query-supported-p
           '(and (or (tags "a") (not (done))) (scheduled :on today))))
  (should-not (jetpacs-org-note-query-supported-p '(clocked)))
  (should-not (jetpacs-org-note-query-supported-p '(and (todo) (clocked))))
  (should-not (jetpacs-org-note-query-supported-p "not a sexp")))

(ert-deftest jetpacs-org-vulpea-source-dispatch ()
  "The vulpea source query dispatches :dir / :file / :file+:heading scopes."
  (jetpacs-tests--with-note-accessors
   (let* ((n1 '(:path "/v/a.org" :level 1 :outline-path nil :todo "TODO" :title "one"))
          (n2 '(:path "/v/a.org" :level 2 :outline-path ("Records") :todo "DONE" :title "two"))
          (n3 '(:path "/v/b.org" :level 1 :outline-path nil :todo nil :title "three"))
          (all (list n1 n2 n3))
          (dir-arg nil))
     (cl-letf (((symbol-function 'vulpea-db-query)
                (lambda (pred) (cl-remove-if-not pred all)))
               ((symbol-function 'vulpea-db-query-by-directory)
                (lambda (dir level) (setq dir-arg (list dir level)) all)))
       ;; :dir goes straight to the directory query, file-level only.
       (should (equal all (jetpacs-org-vulpea-source-notes '(:dir "/v/"))))
       (should (equal '("/v" 0) dir-arg))
       ;; :file scopes to that file's level-1 notes.
       (should (equal (list n1)
                      (jetpacs-org-vulpea-source-notes '(:file "/v/a.org"))))
       ;; :file + :heading scopes to the heading's direct children.
       (should (equal (list n2)
                      (jetpacs-org-vulpea-source-notes
                       '(:file "/v/a.org" :heading "Records"))))
       ;; the query variant filters through the note matcher.
       (should (equal (list n2)
                      (jetpacs-org-vulpea-query
                       '(:file "/v/a.org" :heading "Records") '(done))))
       (should-not (jetpacs-org-vulpea-query
                    '(:file "/v/a.org" :heading "Records") '(todo "TODO")))
       (should-error (jetpacs-org-vulpea-source-notes '(:heading "x"))
                     :type 'user-error)))))

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

;; ─── Hypertext substrate (Tier 0.5) ────────────────────────────────────────

(ert-deftest jetpacs-buffer-call-shimmed-clears-input-event ()
  "`jetpacs-buffer-call-shimmed' clears `last-input-event' around the command,
so an event-driven goto (compile-goto-error and kin) navigates by point,
not by a stale pending event.  Regression for the hijack fix, previously
pinned only implicitly through jetpacs-results--follow."
  (let ((seen 'unset)
        (last-input-event 'stale-pending-event)
        (last-nonmenu-event 'stale-pending-event))
    (with-temp-buffer
      (insert "target-content")
      (let ((cmd (lambda () (interactive) (setq seen last-input-event))))
        (jetpacs-buffer-call-shimmed cmd)))
    (should (eq seen nil))))

(ert-deftest jetpacs-buffer-invoke-at-clears-input-event ()
  "`jetpacs-buffer-invoke-at' clears the pending input event before running a
region-keymap command — the seam every hypertext link tap rides — so a
POS-driven eww/Info/help RET can't be hijacked by a stale event."
  (let ((seen 'unset)
        (last-input-event 'stale-pending-event))
    (with-temp-buffer
      (rename-buffer "jetpacs-invoke-at-test" t)
      (insert "link")
      (let ((km (make-sparse-keymap))
            (cmd (lambda () (interactive) (setq seen last-input-event))))
        (define-key km (kbd "RET") cmd)
        (put-text-property (point-min) (point-max) 'keymap km)
        (should (jetpacs-buffer-invoke-at (buffer-name) 1))))
    (should (eq seen nil))))

(ert-deftest jetpacs-hypertext-emit-structure ()
  "The emitter maps kinds to the right node types and never drops a segment."
  (let* ((model (list '(:kind heading :level 1 :text "H")
                      '(:kind para :text "p")
                      '(:kind rule)
                      '(:kind image :alt "cat")
                      '(:kind bogus :text "still shown")))
         (nodes (jetpacs-hypertext--emit model "Title")))
    (should (= (length nodes) 6))                       ; title + 5 segments
    (should (equal (alist-get 't (nth 0 nodes)) "text"))          ; title
    (should (equal (alist-get 't (nth 1 nodes)) "section_header"))
    (should (equal (alist-get 't (nth 2 nodes)) "text"))          ; para (plain)
    (should (equal (alist-get 't (nth 3 nodes)) "divider"))       ; rule
    (should (equal (alist-get 't (nth 4 nodes)) "text"))          ; image placeholder
    (should (equal (alist-get 't (nth 5 nodes)) "text"))))        ; unknown → para

(ert-deftest jetpacs-hypertext-emit-spans-and-headings ()
  "Heading with no :text flattens its spans to the section_header title;
a paragraph with spans becomes a rich_text carrying those spans."
  (let* ((spans (list (jetpacs-span "hello ")
                      (jetpacs-span "link"
                                 :on-tap (jetpacs-action "jetpacs.buffer.act"
                                                      :args '((buffer . "b") (pos . 3))))))
         (model (list (list :kind 'heading :level 2 :spans spans)
                      (list :kind 'para :spans spans)))
         (nodes (jetpacs-hypertext--emit model nil)))
    (should (equal (alist-get 't (nth 0 nodes)) "section_header"))
    (should (equal (alist-get 'title (nth 0 nodes)) "hello link"))
    (should (equal (alist-get 't (nth 1 nodes)) "rich_text"))
    (should (= (length (alist-get 'spans (nth 1 nodes))) 2))))

(ert-deftest jetpacs-hypertext-emit-lint-clean ()
  "Every emitted document node is wire-valid (passes the spec linter)."
  (let* ((model (list '(:kind heading :level 1 :text "H")
                      (list :kind 'para :spans (list (jetpacs-span "x" :bold t)))
                      '(:kind pre :text "code" :syntax "elisp")
                      (list :kind 'quote :text "q")
                      '(:kind rule)
                      '(:kind image :alt "a" :url "http://x")
                      (list :kind 'table
                            :rows (list (list :header t
                                              :cells (list (list (jetpacs-span "H"))))
                                        (list :cells (list (list (jetpacs-span "v"))))))))
         (nodes (jetpacs-hypertext--emit model "Doc")))
    (dolist (n nodes)
      (should (null (jetpacs-lint-spec n))))))

(defconst jetpacs-tests--hypertext-golden-file
  (expand-file-name "hypertext.golden" jetpacs-tests--dir))

(defun jetpacs-hypertext--emit-cases ()
  "Document models exercising every segment kind; each yields a node list."
  (let* ((act (jetpacs-action "jetpacs.buffer.act"
                           :args '((buffer . "*eww*") (pos . 42))))
         (link (jetpacs-span "docs" :on-tap act))
         (spans (list (jetpacs-span "see the ") link (jetpacs-span " page."))))
    (list
     (jetpacs-hypertext--emit (list '(:kind heading :level 1 :text "Chapter One")))
     (jetpacs-hypertext--emit (list (list :kind 'para :spans spans)))
     (jetpacs-hypertext--emit (list '(:kind para :text "A plain paragraph.")))
     (jetpacs-hypertext--emit (list '(:kind pre :text "(message \"hi\")" :syntax "elisp")))
     (jetpacs-hypertext--emit (list '(:kind quote :text "To be or not to be.")))
     (jetpacs-hypertext--emit (list '(:kind rule)))
     (jetpacs-hypertext--emit (list '(:kind image :alt "A cat" :url "http://x/cat.png")))
     (jetpacs-hypertext--emit (list '(:kind image :url "http://x/only.png")))
     (jetpacs-hypertext--emit
      (list (list :kind 'table
                  :rows (list (list :header t
                                    :cells (list (list (jetpacs-span "Item"))
                                                 (list (jetpacs-span "Qty"))))
                              (list :cells (list (list (jetpacs-span "apples"))
                                                 (list (jetpacs-span "4"))))))))
     (jetpacs-hypertext--emit
      (list '(:kind heading :level 1 :text "Doc")
            (list :kind 'para :spans spans)
            '(:kind rule)
            '(:kind bogus :text "degraded but shown"))
      "Page Title"))))

(defun jetpacs-hypertext--emit-lines ()
  (let ((i -1))
    (mapcar (lambda (nodes)
              (setq i (1+ i))
              (format "%02d %s" i
                      (json-serialize
                       (vconcat (mapcar #'jetpacs-tests--canon nodes))
                       :null-object :null :false-object :false)))
            (jetpacs-hypertext--emit-cases))))

(defun jetpacs-tests-regen-hypertext-golden ()
  "Rewrite the hypertext golden from the current emitter.
Only run this after an INTENTIONAL change; review the diff."
  (with-temp-file jetpacs-tests--hypertext-golden-file
    (insert (string-join (jetpacs-hypertext--emit-lines) "\n") "\n"))
  (message "Wrote %s" jetpacs-tests--hypertext-golden-file))

(ert-deftest jetpacs-hypertext-emit-golden ()
  "The emitter's wire output matches the committed hypertext.golden snapshot."
  (should (file-readable-p jetpacs-tests--hypertext-golden-file))
  (should (equal (jetpacs-hypertext--emit-lines)
                 (split-string
                  (with-temp-buffer
                    (insert-file-contents jetpacs-tests--hypertext-golden-file)
                    (buffer-string))
                  "\n" t))))

(ert-deftest jetpacs-hypertext-shr-scan ()
  "An shr-rendered buffer scans into headings (with levels) and link-bearing
paragraphs; link spans tap `jetpacs.buffer.act', and the emitted document is
wire-valid.  Gated on libxml (absent in lean builds; present in CI Emacs)."
  (skip-unless (jetpacs-feature-p 'libxml))
  (require 'shr)
  (let ((html (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "fixtures/hypertext-basic.html"
                                   jetpacs-tests--dir))
                (buffer-string)))
        model)
    (with-temp-buffer
      (insert html)
      ;; Render the <body> only, as eww does — a raw full-document shr would
      ;; also render <title> into the buffer, which eww strips.
      (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
             (body (or (car (dom-by-tag dom 'body)) dom)))
        (erase-buffer)
        (shr-insert-document body))
      (setq model (jetpacs-hypertext--scan-shr (current-buffer))))
    ;; Headings, in order, with their levels.
    (let ((headings (seq-filter (lambda (s) (eq (plist-get s :kind) 'heading))
                                model)))
      (should (= (length headings) 2))
      (should (equal (mapcar (lambda (h) (plist-get h :level)) headings) '(1 2)))
      (should (member "Main Heading"
                      (mapcar (lambda (h) (plist-get h :text)) headings))))
    ;; Paragraphs, at least one carrying a link span tapping jetpacs.buffer.act.
    (let* ((paras (seq-filter (lambda (s) (eq (plist-get s :kind) 'para)) model))
           (spans (apply #'append (mapcar (lambda (p) (plist-get p :spans)) paras)))
           (taps (seq-filter (lambda (sp) (alist-get 'on_tap sp)) spans)))
      (should (>= (length paras) 2))
      (should (>= (length taps) 1))
      (should (equal (alist-get 'action (alist-get 'on_tap (car taps)))
                     "jetpacs.buffer.act")))
    ;; The whole emitted document is wire-valid.
    (dolist (n (jetpacs-hypertext--emit model "Test Page"))
      (should (null (jetpacs-lint-spec n))))))

(ert-deftest jetpacs-hypertext-image-resolve ()
  "The image emitter resolves in battery order: a readable file passes
through as file://, an http(s) URL passes through untouched (never cached),
Emacs-only bytes (:data, base64 data: URIs) go through the write-once
content cache, and the unresolvable degrade to an alt caption."
  (let* ((tmproot (make-temp-file "jetpacs-hyper-root" t))
         (jetpacs-root tmproot))
    (unwind-protect
        (progn
          ;; a readable :file → file:// passthrough
          (let* ((f (make-temp-file "jetpacs-img" nil ".png" "PNG"))
                 (n (jetpacs-hypertext--image
                     (list :kind 'image :file f :alt "local"))))
            (should (equal (alist-get 't n) "image"))
            (should (equal (alist-get 'url n) (concat "file://" f)))
            (should (equal (alist-get 'content_description n) "local"))
            (delete-file f))
          ;; http(s) → URL passthrough; the cache is never touched
          (let ((n (jetpacs-hypertext--image
                    '(:kind image :url "https://x.test/a.png" :alt "net"))))
            (should (equal (alist-get 't n) "image"))
            (should (equal (alist-get 'url n) "https://x.test/a.png"))
            (should-not (file-directory-p
                         (jetpacs-hypertext--image-cache-dir))))
          ;; :data → the content cache, write-once (same path both times)
          (let* ((seg '(:kind image :data "RAWBYTES" :content-type png :alt "d"))
                 (n1 (jetpacs-hypertext--image seg))
                 (url1 (alist-get 'url n1))
                 (path (substring url1 (length "file://"))))
            (should (string-prefix-p "file://" url1))
            (should (string-suffix-p ".png" path))
            (should (equal (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally path)
                             (buffer-string))
                           "RAWBYTES"))
            (should (equal (alist-get 'url (jetpacs-hypertext--image seg)) url1)))
          ;; a base64 data: URI decodes into the cache
          (let* ((uri (concat "data:image/png;base64,"
                              (base64-encode-string "DATAURI")))
                 (n (jetpacs-hypertext--image (list :kind 'image :url uri)))
                 (path (substring (alist-get 'url n) (length "file://"))))
            (should (equal (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally path)
                             (buffer-string))
                           "DATAURI")))
          ;; nothing resolvable → alt caption, never dropped
          (let ((n (jetpacs-hypertext--image '(:kind image :alt "gone"))))
            (should (equal (alist-get 't n) "text"))
            (should (string-match-p "gone" (alist-get 'text n)))))
      (delete-directory tmproot t))))

(ert-deftest jetpacs-hypertext-image-cache-sweep ()
  "A write past the byte cap sweeps oldest-mtime files first; the clear
command empties the cache."
  (let* ((tmproot (make-temp-file "jetpacs-hyper-root" t))
         (jetpacs-root tmproot)
         (jetpacs-hypertext-image-cache-max 8)) ; two 6-byte files can't both fit
    (unwind-protect
        (let ((p1 (jetpacs-hypertext--image-cache-put "DATA-A" 'png)))
          (should (file-exists-p p1))
          (set-file-times p1 (time-subtract (current-time) 120))
          (let ((p2 (jetpacs-hypertext--image-cache-put "DATA-B" 'png)))
            (should-not (file-exists-p p1))    ; oldest evicted
            (should (file-exists-p p2))
            (jetpacs-hypertext-image-cache-clear)
            (should-not (file-exists-p p2))))
      (delete-directory tmproot t))))

(ert-deftest jetpacs-hypertext-shr-media ()
  "Media blocks lift out of shr prose: an image-only block becomes an image
segment (the real source URL kept, shr's placeholder rectangle discarded),
and rendered table regions pair with the page DOM by shr-table-id into
native tables — both tables of the fixture, proving id order.  The whole
document stays wire-valid."
  (skip-unless (jetpacs-feature-p 'libxml))
  (require 'shr)
  (let ((html (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "fixtures/hypertext-media.html"
                                   jetpacs-tests--dir))
                (buffer-string)))
        nodes)
    (with-temp-buffer
      (insert html)
      (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
             (body (or (car (dom-by-tag dom 'body)) dom)))
        (erase-buffer)
        (shr-insert-document body))
      (setq-local eww-data (list :source html :title "Media Page"))
      (let* ((model (jetpacs-hypertext--scan-shr (current-buffer)))
             (resolved (jetpacs-hypertext--eww-resolve-tables
                        model (current-buffer))))
        ;; the image segment: URL and alt survive, the placeholder does not
        (let ((img (seq-find (lambda (s) (eq (plist-get s :kind) 'image))
                             model)))
          (should img)
          (should (equal (plist-get img :url) "https://example.com/pic.png"))
          (should (equal (plist-get img :alt) "A picture"))
          (should-not (plist-get img :data)))
        ;; both tables resolve to native rows, in document order
        (let ((tables (seq-filter (lambda (s) (eq (plist-get s :kind) 'table))
                                  resolved)))
          (should (= (length tables) 2))
          (let ((r1 (plist-get (nth 0 tables) :rows))
                (r2 (plist-get (nth 1 tables) :rows)))
            (should (equal (plist-get (car r1) :cells) '("Name" "Age")))
            (should (plist-get (car r1) :header))
            (should (equal (plist-get (nth 2 r1) :cells) '("Grace" "85")))
            (should (equal (plist-get (car r2) :cells) '("solo")))
            (should-not (plist-get (car r2) :header))))
        (setq nodes (jetpacs-hypertext--emit resolved "Media Page"))))
    (let ((types (mapcar (lambda (n) (alist-get 't n)) nodes)))
      (should (member "image" types))
      (should (= (seq-count (lambda (ty) (equal ty "table")) types) 2)))
    (dolist (n nodes) (should (null (jetpacs-lint-spec n))))))

(ert-deftest jetpacs-hypertext-nested-table-stays-mono ()
  "A document containing nested tables is left alone by the DOM pass (shr's
render order diverges from document order there): its table segments keep
the monospace fallback, never a wrong native table."
  (skip-unless (jetpacs-feature-p 'libxml))
  (require 'shr)
  (let ((html (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "fixtures/hypertext-nested-table.html"
                                   jetpacs-tests--dir))
                (buffer-string))))
    (with-temp-buffer
      (insert html)
      (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
             (body (or (car (dom-by-tag dom 'body)) dom)))
        (erase-buffer)
        (shr-insert-document body))
      (setq-local eww-data (list :source html))
      (let* ((model (jetpacs-hypertext--scan-shr (current-buffer)))
             (resolved (jetpacs-hypertext--eww-resolve-tables
                        model (current-buffer)))
             (tables (seq-filter (lambda (s) (eq (plist-get s :kind) 'table))
                                 resolved)))
        (should tables)
        (dolist (tbl tables)
          (should-not (plist-get tbl :rows))
          ;; and it emits as a monospace block, alignment preserved
          (let ((n (jetpacs-hypertext--emit-segment tbl)))
            (should (equal (alist-get 't n) "surface"))))))))

(ert-deftest jetpacs-hypertext-rider-registration ()
  "A third-party shr mode rides through the public one-line seam: dispatch
picks the document renderer for it, headings and all.  Registering a base
mode (special-mode) is refused — dispatch is derived-mode-p wide."
  (should-error (jetpacs-hypertext-register-shr-mode 'special-mode))
  (define-derived-mode jetpacs-tests--rider-mode special-mode "TestRider")
  (unwind-protect
      (progn
        (jetpacs-hypertext-register-shr-mode 'jetpacs-tests--rider-mode)
        (with-temp-buffer
          (jetpacs-tests--rider-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "Riding High" 'face 'shr-h1)
                    "\n\nPlain prose paragraph.\n"))
          (let* ((nodes (jetpacs-render-buffer (current-buffer)))
                 (header (seq-find (lambda (n)
                                     (equal (alist-get 't n) "section_header"))
                                   nodes)))
            (should header)
            (should (equal (alist-get 'title header) "Riding High"))
            (dolist (n nodes) (should (null (jetpacs-lint-spec n)))))))
    (setq jetpacs-render-buffer-functions
          (assq-delete-all 'jetpacs-tests--rider-mode
                           jetpacs-render-buffer-functions))))

(ert-deftest jetpacs-hypertext-nav-allowlist ()
  "hypertext.nav resolves only a mode's own allowlisted ops; anything else —
a foreign op, an op for the wrong mode, a non-document mode — resolves to
no command, so the wire can never name a command to run."
  (should (eq (jetpacs-hypertext--nav-command 'eww-mode 'back) 'eww-back-url))
  (should (eq (jetpacs-hypertext--nav-command 'Info-mode 'next) 'Info-next))
  (should (eq (jetpacs-hypertext--nav-command 'help-mode 'forward) 'help-go-forward))
  (should (null (jetpacs-hypertext--nav-command 'eww-mode 'next)))     ; not for eww
  (should (null (jetpacs-hypertext--nav-command 'help-mode 'reload)))  ; not for help
  (should (null (jetpacs-hypertext--nav-command 'text-mode 'back)))    ; not a doc mode
  (should (null (jetpacs-hypertext--nav-command 'eww-mode 'evil))))    ; unknown op

(ert-deftest jetpacs-hypertext-nav-live-ops ()
  "Info always offers node motion; back/forward gate on the live history."
  (should (equal (jetpacs-hypertext--nav-live-ops 'text-mode) nil))
  (let ((ops (jetpacs-hypertext--nav-live-ops 'Info-mode)))
    (dolist (op '(prev next up toc)) (should (memq op ops)))))

(ert-deftest jetpacs-hypertext-help-adapter ()
  "help-mode renders as a document: the subject is the title, xref buttons
become jetpacs.buffer.act taps, and the emitted document is wire-valid."
  (require 'help-mode)
  (save-window-excursion (describe-function 'car))
  (let* ((buf (get-buffer "*Help*"))
         (model (with-current-buffer buf (jetpacs-hypertext--scan-lines buf)))
         (title (jetpacs-hypertext--help-title buf))
         (nodes (jetpacs-hypertext-render-help buf))
         (spans (apply #'append
                       (mapcar (lambda (s) (plist-get s :spans))
                               (seq-filter
                                (lambda (s) (eq (plist-get s :kind) 'para)) model))))
         (taps (seq-filter (lambda (sp) (alist-get 'on_tap sp)) spans)))
    (should (equal title "car"))
    (should (>= (length taps) 1))
    (should (equal (alist-get 'action (alist-get 'on_tap (car taps)))
                   "jetpacs.buffer.act"))
    (dolist (n nodes) (should (null (jetpacs-lint-spec n))))))

(ert-deftest jetpacs-hypertext-info-classify ()
  "The Info line classifier lifts underlined lines to headings (with levels),
drops the bare underline rule, and leaves prose as paragraphs."
  (with-temp-buffer
    (insert "Fixture Top\n***********\n\nIntro paragraph.\n\n"
            "The Second Node\n===============\n\nBody.\n")
    (let (classes)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((bol (line-beginning-position)) (eol (line-end-position)))
          (push (if (>= bol eol) 'blank
                  (jetpacs-hypertext--info-line-class bol eol))
                classes))
        (forward-line 1))
      ;; Top(*=1) rule(skip) blank Intro(nil) blank Second(===2) rule(skip) blank Body(nil)
      (should (equal (seq-take (nreverse classes) 9)
                     '(1 skip blank nil blank 2 skip blank nil))))))

(ert-deftest jetpacs-hypertext-info-adapter ()
  "An Info node renders as a document: node-name title, its underlined
heading lifted to a section (the rule line dropped), and a wire-valid tree.
Tolerant of batch Info quirks — skips if the node won't open."
  (require 'info)
  (let* ((dir (make-temp-file "jetpacs-info" t))
         (file (expand-file-name "fixture.info" dir))
         opened)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "This is fixture.info.\n\n"
                    "\037\n"
                    "File: fixture.info,  Node: Top,  Up: (dir)\n\n"
                    "Fixture Top\n***********\n\n"
                    "Intro paragraph of the top node.\n\n"
                    "* Menu:\n\n"
                    "* Second::    The second node.\n\n"
                    "\037\n"
                    "File: fixture.info,  Node: Second,  Prev: Top,  Up: Top\n\n"
                    "The Second Node\n===============\n\n"
                    "Body of the second node.\n"))
          (setq opened
                (ignore-errors
                  (save-window-excursion (Info-find-node file "Top"))
                  (get-buffer "*info*")))
          (skip-unless opened)
          (with-current-buffer opened
            (let* ((model (jetpacs-hypertext--scan-lines
                           opened #'jetpacs-hypertext--info-line-class))
                   (headings (seq-filter
                              (lambda (s) (eq (plist-get s :kind) 'heading)) model))
                   (nodes (jetpacs-hypertext-render-info opened)))
              (should (member "Fixture Top"
                              (mapcar (lambda (h) (plist-get h :text)) headings)))
              ;; the "***********" rule line is not emitted as a paragraph
              (should-not
               (seq-find
                (lambda (s)
                  (and (eq (plist-get s :kind) 'para)
                       (string-match-p
                        "\\`[*=-]+\\'"
                        (string-trim (jetpacs-hypertext--spans-text
                                      (plist-get s :spans))))))
                model))
              (dolist (n nodes) (should (null (jetpacs-lint-spec n)))))))
      (ignore-errors (kill-buffer "*info*"))
      (delete-directory dir t))))

;; ─── The remote hosts hub ────────────────────────────────────────────────────

(ert-deftest jetpacs-hosts-ssh-config-parse ()
  "The ssh-config parser: concrete Host names (multi-name lines too), in
order, deduplicated; wildcard/negation patterns and non-Host lines skipped;
missing file is nil."
  (let ((file (make-temp-file "jetpacs-ssh-config")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# comment\n"
                    "Host build\n"
                    "  HostName build.example.org\n"
                    "Host web db web\n"
                    "Host *\n"
                    "  ServerAliveInterval 60\n"
                    "Host *.internal !bastion staging\n"
                    "Match host build\n"
                    "  User deploy\n"))
          (should (equal (jetpacs-hosts--ssh-config-hosts file)
                         '("build" "web" "db" "staging"))))
      (delete-file file))
    (should (null (jetpacs-hosts--ssh-config-hosts "/no/such/file")))))

(ert-deftest jetpacs-hosts-list-merge ()
  "The live host list: explicit `jetpacs-hosts' entries first and shadowing
same-labelled ssh-config discoveries; the rest appended as /ssh: cards."
  (let ((jetpacs-hosts '(("build" . "/ssh:deploy@build:/srv/")
                      ("pi" . "/ssh:pi:~/")))
        (jetpacs-hosts-from-ssh-config t))
    (cl-letf (((symbol-function 'jetpacs-hosts--ssh-config-hosts)
               (lambda (_) '("build" "web"))))
      (should (equal (jetpacs-hosts--all)
                     '(("build" . "/ssh:deploy@build:/srv/")
                       ("pi" . "/ssh:pi:~/")
                       ("web" . "/ssh:web:~/")))))))

(ert-deftest jetpacs-hosts-view-body ()
  "Host cards carry the label — never the TRAMP path — in their action
args, and the whole body is wire-valid; no hosts renders the empty state."
  (let ((jetpacs-hosts '(("box" . "/ssh:box:~/")))
        (jetpacs-hosts-from-ssh-config nil))
    (let ((body (jetpacs-hosts--body)))
      (should (null (jetpacs-lint-spec body)))
      ;; every action in the tree carries only the label
      (let (actions)
        (cl-labels ((walk (n)
                      (cond
                       ;; an action alist proper: (action . "name") is a string
                       ;; (a button node's `action' key holds a whole alist)
                       ((and (consp n) (consp (car-safe n))
                             (stringp (alist-get 'action n)))
                        (push n actions))
                       ;; cars and cdrs cover lists, alists, and dotted pairs
                       ((consp n) (walk (car n)) (walk (cdr n)))
                       ((vectorp n) (mapc #'walk (append n nil))))))
          (walk body))
        (should actions)
        (dolist (a actions)
          (let ((args (alist-get 'args a)))
            (should (equal (alist-get 'host args) "box"))
            (should-not (rassoc "/ssh:box:~/" args)))))))
  (let ((jetpacs-hosts nil) (jetpacs-hosts-from-ssh-config nil))
    (should (equal (alist-get 't (jetpacs-hosts--body)) "empty_state"))))

(ert-deftest jetpacs-hosts-files-action ()
  "hosts.files resolves the label through the allowlist and shows the
dired buffer through the buffer-view seam; an unknown label touches
nothing."
  (let* ((jetpacs-hosts '(("box" . "/ssh:box:~/")))
         (jetpacs-hosts-from-ssh-config nil)
         (fn (gethash "hosts.files" jetpacs-action-handlers))
         (dired-buf (generate-new-buffer " *jetpacs-hosts-dired*"))
         opened viewed)
    (unwind-protect
        (cl-letf (((symbol-function 'dired-noselect)
                   (lambda (dir &rest _) (setq opened dir) dired-buf))
                  (jetpacs-tablist-view-buffer-function
                   (lambda (name) (setq viewed name))))
          (should fn)
          ;; happy path: resolved dir opened, buffer handed to the view
          (funcall fn '((host . "box")) nil)
          (should (equal opened "/ssh:box:~/"))
          (should (equal viewed (buffer-name dired-buf)))
          ;; unknown label: allowlist refuses, nothing runs
          (setq opened nil viewed nil)
          (funcall fn '((host . "evil")) nil)
          (should-not opened)
          (should-not viewed))
      (kill-buffer dired-buf))))

;; ─── The magit-section substrate ─────────────────────────────────────────────
;;
;; The library is third-party; these tests self-discover it (plus its deps)
;; in the user's package directory and skip cleanly where it's absent —
;; the libxml gating pattern, for a package instead of a build feature.

(defvar jetpacs-tests--magit-section-state 'unknown)

(defun jetpacs-tests--magit-section-p ()
  "Load magit-section from the user's elpa if present; non-nil on success."
  (when (eq jetpacs-tests--magit-section-state 'unknown)
    (dolist (pat '("magit-section-*" "compat-*" "llama-*" "dash-*"
                   "cond-let-*" "transient-*"))
      (dolist (d (file-expand-wildcards
                  (expand-file-name pat "~/.emacs.d/elpa")))
        (when (file-directory-p d)
          (add-to-list 'load-path d))))
    (setq jetpacs-tests--magit-section-state
          (require 'magit-section nil t)))
  jetpacs-tests--magit-section-state)

(defun jetpacs-tests--make-section-buffer ()
  "A live magit-section buffer: two top sections, the first with a nested
child, built exactly as the library builds them.  Caller kills it.
Uses `eval' so the `magit-insert-section' macro expands only after the
library is loaded (keeps this file byte-compile-safe)."
  (let ((buf (generate-new-buffer " *jetpacs-sections-test*")))
    (with-current-buffer buf
      (eval '(progn
               (magit-section-mode)
               (setq-local inhibit-read-only t)
               (magit-insert-section (magit-section 'demo-root)
                 (magit-insert-section (magit-section 'one)
                   (magit-insert-heading "Section One")
                   (insert "body line 1\nbody line 2\n")
                   (magit-insert-section (magit-section 'one-child)
                     (magit-insert-heading "Nested child")
                     (insert "nested body\n")))
                 (magit-insert-section (magit-section 'two)
                   (magit-insert-heading "Section Two")
                   (insert "second body\n"))))
            t))
    buf))

(defun jetpacs-tests--section-header-text (node)
  "The concatenated header text of a collapsible NODE."
  (mapconcat (lambda (sp) (or (alist-get 'text sp) ""))
             (alist-get 'spans (alist-get 'header node)) ""))

(ert-deftest jetpacs-sections-render-tree ()
  "A magit-section buffer renders as collapsible cards through the
dispatch: stable ids, headers with taps stripped, bodies and nested
children inside, Emacs's fold state mirrored (hidden bodies still
shipped), everything wire-valid."
  (skip-unless (jetpacs-tests--magit-section-p))
  (let ((buf (jetpacs-tests--make-section-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Hide the second section in Emacs, then render.
          (eval '(magit-section-hide
                  (cadr (slot-value magit-root-section 'children)))
                t)
          (let* ((nodes (jetpacs-render-buffer buf))
                 (tops (seq-filter
                        (lambda (n) (equal (alist-get 't n) "collapsible"))
                        nodes)))
            (should (= (length tops) 2))
            (let ((one (nth 0 tops)) (two (nth 1 tops)))
              ;; headers: own text, no taps
              (should (equal (jetpacs-tests--section-header-text one)
                             "Section One"))
              (should-not (seq-find (lambda (sp) (alist-get 'on_tap sp))
                                    (alist-get 'spans (alist-get 'header one))))
              ;; ids: stable non-empty strings, distinct
              (should (stringp (alist-get 'id one)))
              (should-not (equal (alist-get 'id one) (alist-get 'id two)))
              ;; long-press wires the section menu
              (should (equal (alist-get 'action (alist-get 'on_long_tap one))
                             "sections.menu"))
              ;; children: body lines + the nested collapsible
              (let* ((kids (append (alist-get 'children one) nil))
                     (texts (mapcar (lambda (n)
                                      (if (equal (alist-get 't n) "rich_text")
                                          (mapconcat
                                           (lambda (sp) (or (alist-get 'text sp) ""))
                                           (alist-get 'spans n) "")
                                        (alist-get 't n)))
                                    kids)))
                (should (member "body line 1" texts))
                (should (member "collapsible" texts)))
              ;; Emacs-hidden section: collapsed mirrored, body still shipped
              (should (eq (alist-get 'collapsed two) t))
              (should (seq-find
                       (lambda (n)
                         (and (equal (alist-get 't n) "rich_text")
                              (string-match-p
                               "second body"
                               (mapconcat (lambda (sp)
                                            (or (alist-get 'text sp) ""))
                                          (alist-get 'spans n) ""))))
                       (append (alist-get 'children two) nil))))
            (dolist (n nodes) (should (null (jetpacs-lint-spec n))))))
      (kill-buffer buf))))

(ert-deftest jetpacs-sections-menu-candidates ()
  "The section context menu offers the region's own bindings (labelled,
key-addressed — never a command name) plus the fold toggle."
  (skip-unless (jetpacs-tests--magit-section-p))
  (let ((buf (jetpacs-tests--make-section-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((cands (jetpacs-sections--menu-candidates (point-min))))
            (should (assoc "Toggle fold (TAB)" cands))
            ;; every candidate value is a key description, not a symbol
            (dolist (c cands) (should (stringp (cdr c))))))
      (kill-buffer buf))))

(ert-deftest jetpacs-sections-visit-routing ()
  "Body taps are visit-routed: the rendered spans carry `sections.visit',
a row whose RET command leaves the buffer shows its destination through
the region-view seam (no desktop window), and a row whose command acts in
place falls back to a re-push."
  (skip-unless (jetpacs-tests--magit-section-p))
  (let ((buf (jetpacs-tests--make-section-buffer))
        (target (generate-new-buffer " *jetpacs-sections-target*"))
        shown refreshed)
    (unwind-protect
        (with-current-buffer buf
          ;; A row whose RET jumps: bind it via a text-prop keymap first
          ;; (bare magit-section body rows carry no keymap of their own —
          ;; in real magit the section's keymap slot supplies one).
          (with-current-buffer target (insert "line one\ntarget line\n"))
          (let* ((jump (lambda ()
                         (interactive)
                         (pop-to-buffer target)
                         (goto-char 10)))
                 (km (make-sparse-keymap)))
            (define-key km (kbd "RET") jump)
            (save-excursion
              (goto-char (point-min))
              (search-forward "body line 1")
              (let ((inhibit-read-only t))
                (put-text-property (line-beginning-position)
                                   (line-end-position)
                                   'keymap km))
              ;; 1. that row's rendered span is visit-routed
              (let* ((nodes (jetpacs-render-buffer buf))
                     (tops (seq-filter
                            (lambda (n) (equal (alist-get 't n) "collapsible"))
                            nodes))
                     (taps (delq nil
                                 (mapcar
                                  (lambda (n)
                                    (and (equal (alist-get 't n) "rich_text")
                                         (seq-find
                                          (lambda (sp) (alist-get 'on_tap sp))
                                          (append (alist-get 'spans n) nil))))
                                  (append (alist-get 'children (car tops)) nil)))))
                (should taps)
                (should (equal (alist-get 'action (alist-get 'on_tap (car taps)))
                               "sections.visit")))
              ;; 2. following it shows the destination through the seam
              (let ((jetpacs-results-visit-region-function
                     (lambda (name beg end label point)
                       (setq shown (list name beg end label point))))
                    (jetpacs-buffer-refresh-function
                     (lambda () (setq refreshed t))))
                (should (jetpacs-sections--visit buf (line-beginning-position)))
                (should (equal (car shown) (buffer-name target)))
                (should (numberp (nth 4 shown)))
                ;; 3. in-place case: heading RET stays put, seam untouched
                (setq shown nil)
                (should-not (jetpacs-sections--visit buf (point-min)))
                (should-not shown)
                (ignore refreshed)))))
      (kill-buffer buf)
      (kill-buffer target))))

(ert-deftest jetpacs-sections-washer-stub ()
  "An unwashed lazy section (content == end, washer pending) renders as a
card with a tap-to-load stub wired to the fold action; once Emacs shows
\(washes) it, a re-render carries the real body."
  (skip-unless (jetpacs-tests--magit-section-p))
  (let ((buf (generate-new-buffer " *jetpacs-sections-lazy*")))
    (unwind-protect
        (with-current-buffer buf
          (eval '(progn
                   (magit-section-mode)
                   (setq-local inhibit-read-only t)
                   (magit-insert-section (magit-section 'root)
                     (magit-insert-section (magit-section 'lazy t)
                       (magit-insert-heading "Lazy Section")
                       (magit-insert-section-body
                         (insert "washed content line\n")))))
                t)
          (let* ((nodes (jetpacs-render-buffer buf))
                 (card (seq-find
                        (lambda (n) (equal (alist-get 't n) "collapsible"))
                        nodes)))
            (should card)
            (should (equal (jetpacs-tests--section-header-text card)
                           "Lazy Section"))
            ;; the stub taps the fold action (which washes in Emacs)
            (let* ((stub (seq-find
                          (lambda (n) (equal (alist-get 't n) "rich_text"))
                          (append (alist-get 'children card) nil)))
                   (tap (seq-find (lambda (sp) (alist-get 'on_tap sp))
                                  (append (alist-get 'spans stub) nil))))
              (should tap)
              (should (equal (alist-get 'action (alist-get 'on_tap tap))
                             "jetpacs.buffer.fold")))
            (dolist (n nodes) (should (null (jetpacs-lint-spec n)))))
          ;; wash it (what the fold tap does), re-render: real body present
          (eval '(magit-section-show
                  (car (slot-value magit-root-section 'children)))
                t)
          (let* ((nodes (jetpacs-render-buffer buf))
                 (card (seq-find
                        (lambda (n) (equal (alist-get 't n) "collapsible"))
                        nodes))
                 (texts (mapcar
                         (lambda (n)
                           (mapconcat (lambda (sp) (or (alist-get 'text sp) ""))
                                      (alist-get 'spans n) ""))
                         (seq-filter
                          (lambda (n) (equal (alist-get 't n) "rich_text"))
                          (append (alist-get 'children card) nil)))))
            (should (member "washed content line" texts))))
      (kill-buffer buf))))

(ert-deftest jetpacs-sections-fallback-without-root ()
  "A magit-section-mode buffer with no root section (still populating)
falls through to the Tier 0 renderer instead of erroring."
  (skip-unless (jetpacs-tests--magit-section-p))
  (with-temp-buffer
    (eval '(magit-section-mode) t)
    (let ((inhibit-read-only t)) (insert "just text\n"))
    (setq-local magit-root-section nil)
    (should (jetpacs-render-buffer (current-buffer)))))

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

(ert-deftest jetpacs-version-header-pinned-to-api ()
  "jetpacs.el's package Version: header equals `jetpacs-api-version'.
A `package-vc-install' of this repo must report the same number the API
constant promises (hardening Task 24) — they cannot drift."
  (let ((f (expand-file-name "../emacs/core/jetpacs.el" jetpacs-tests--dir)))
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (should (re-search-forward "^;; Version: \\([0-9.]+\\)$" nil t))
      (should (equal (match-string 1) jetpacs-api-version)))))

(ert-deftest jetpacs-spec-header-version-coherent ()
  "docs/SPEC.md's status block is machine-readably coherent (freeze S0):
the header's wire-protocol version equals `jetpacs-protocol-version', the
spec version's major is that same wire version, and the amendment log the
header's policy names exists.  The full spec-version string is pinned here
so a status flip (1.0-rc -> 1.0) is an intentional, reviewed change —
same philosophy as the contract.json byte-pin."
  (let ((f (expand-file-name "../docs/SPEC.md" jetpacs-tests--dir)))
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (should (re-search-forward
               "^Spec: \\*\\*\\([0-9]+\\)\\.\\([0-9]+\\)\\(-rc\\)?\\*\\*" nil t))
      (let ((major (string-to-number (match-string 1)))
            (full (concat (match-string 1) "." (match-string 2)
                          (or (match-string 3) ""))))
        (should (equal full "1.0-rc"))
        (should (= major jetpacs-protocol-version)))
      (should (re-search-forward "Wire protocol: \\*\\*`v: \\([0-9]+\\)`\\*\\*" nil t))
      (should (= (string-to-number (match-string 1)) jetpacs-protocol-version))
      (goto-char (point-min))
      (should (re-search-forward "\\[SPEC-CHANGES\\.md\\](SPEC-CHANGES\\.md)" nil t))
      (should (file-exists-p
               (expand-file-name "../docs/SPEC-CHANGES.md" jetpacs-tests--dir))))))

;; ─── Build-feature probe (Phase H / Task 23) ─────────────────────────────────

(ert-deftest jetpacs-build-features-probe ()
  "The probe reports a subset of the known vocabulary — flat symbols,
nothing outside `jetpacs--build-feature-probes' — and `jetpacs-feature-p'
mirrors membership, accepting strings too."
  (should (listp jetpacs-build-features))
  (dolist (f jetpacs-build-features)
    (should (symbolp f))
    (should (assq f jetpacs--build-feature-probes)))
  (dolist (probe jetpacs--build-feature-probes)
    (should (eq (and (memq (car probe) jetpacs-build-features) t)
                (jetpacs-feature-p (car probe))))
    (should (eq (jetpacs-feature-p (car probe))
                (jetpacs-feature-p (symbol-name (car probe))))))
  (should-not (jetpacs-feature-p 'flisbo)))

(ert-deftest jetpacs-hello-carries-build-features ()
  "session.hello reports the build matrix as the additive `features' field
\(SPEC §3): a vector of feature-name strings beside client and wants."
  (let (sent)
    (cl-letf (((symbol-function 'jetpacs-send)
               (lambda (kind &optional payload &rest _)
                 (push (cons kind payload) sent))))
      (jetpacs--send-hello))
    (let* ((hello (assoc "session.hello" sent))
           (features (alist-get 'features (cdr hello))))
      (should hello)
      (should (vectorp features))
      (should (equal (append features nil)
                     (mapcar #'symbol-name jetpacs-build-features)))
      ;; The pre-existing payload fields are intact beside it.
      (should (alist-get 'client (cdr hello)))
      (should (alist-get 'wants (cdr hello))))))

(ert-deftest jetpacs-settings-render-row-read-only ()
  "A :render registry entry renders via its builder and stays read-only:
excluded from the settings.set/reset gate and from switch state handlers."
  (let* ((row '(jetpacs-build-features :render jetpacs-shell--build-features-row))
         (jetpacs-settings-registry
          (list (cons "Bridge" (list '(jetpacs-theme-mode :label "Theme") row)))))
    ;; Renders the builder's node (and it lints clean).
    (let ((node (jetpacs-settings--item row)))
      (should (equal "column" (alist-get 't node)))
      (should-not (jetpacs-lint-spec node)))
    ;; The render row never resolves for the wire gate; its sibling does.
    (should-not (jetpacs-settings--entry 'jetpacs-build-features))
    (should (jetpacs-settings--entry 'jetpacs-theme-mode))
    ;; No state handler is registered for the render row.
    (let (watched)
      (cl-letf (((symbol-function 'jetpacs-settings-watch-toggle)
                 (lambda (sym _id &optional _after) (push sym watched))))
        (jetpacs-settings--register-state-handlers jetpacs-settings-registry))
      (should (equal watched '(jetpacs-theme-mode))))))

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

(ert-deftest jetpacs-lint-builtin-vocabulary ()
  "Builtins are a closed set with required payloads (SPEC §5)."
  ;; Unknown builtin.
  (should (jetpacs-lint-spec `((t . "button") (on_tap . ((builtin . "does.not.exist"))))))
  ;; Known builtins missing their required payload key.
  (should (jetpacs-lint-spec `((t . "button") (on_tap . ((builtin . "view.switch"))))))
  (should (jetpacs-lint-spec `((t . "button") (on_tap . ((builtin . "clipboard.copy"))))))
  ;; Well-formed builtins pass (label present: the node schema requires it).
  (should-not (jetpacs-lint-spec
               `((t . "button") (label . "L")
                 (on_tap . ((builtin . "view.switch") (view . "app:dashboard"))))))
  (should-not (jetpacs-lint-spec
               `((t . "button") (label . "L")
                 (on_tap . ((builtin . "clipboard.copy") (text . "hi"))))))
  (should-not (jetpacs-lint-spec
               `((t . "button") (label . "L")
                 (on_tap . ((builtin . "jetpacs.settings.open")))))))

(ert-deftest jetpacs-lint-recognizes-chart-and-widget-action-keys ()
  "`on_point_tap' and `on_button' are validated as embedded actions."
  ;; A malformed action under each new key is caught.
  (should (jetpacs-lint-spec `((t . "chart") (on_point_tap . ((args . ((k . "v"))))))))
  (should (jetpacs-lint-spec `((t . "text") (on_button . ((action . "a.b") (when_offline . "nope"))))))
  ;; A well-formed one passes (series present: the node schema requires it).
  (should-not (jetpacs-lint-spec `((t . "chart") (series . [])
                                  (on_point_tap . ((action . "x.y")))))))

(ert-deftest jetpacs-lint-flags-nonserializable-and-typed-attrs ()
  "A symbol attr value and a non-numeric padding are caught before the wire."
  (should (jetpacs-lint-spec `((t . "text") (text . some-symbol))))
  (should (jetpacs-lint-spec `((t . "text") (text . "ok") (padding . "lots"))))
  (should (jetpacs-lint-spec `((t . "surface") (children . []) (color . "#GGG")))))

;; ─── Schema registry (Spec 1.0-rc freeze, S1) ────────────────────────────────

(ert-deftest jetpacs-lint-node-schema-covers-node-types ()
  "The node-schema table has exactly one row per known node type."
  (should (equal (sort (mapcar #'car jetpacs-lint-node-schema) #'string<)
                 (sort (copy-sequence jetpacs-lint-node-types) #'string<)))
  (should (= (length jetpacs-lint-node-schema)
             (length jetpacs-lint-node-types))))

(ert-deftest jetpacs-lint-schema-missing-required-errors ()
  "A node missing a schema-required key is an error, never a warning."
  (let ((problems (jetpacs-lint-spec '((t . "text")))))
    (should problems)
    (should (cl-some (lambda (p)
                       (string-match-p "missing required `text'" (cdr p)))
                     problems))
    (should-not (cl-some (lambda (p) (string-prefix-p "warning: " (cdr p)))
                         problems)))
  ;; Required keys are per-type: a button needs label AND on_tap.
  (let ((problems (jetpacs-lint-spec '((t . "button") (label . "L")))))
    (should (cl-some (lambda (p)
                       (string-match-p "missing required `on_tap'" (cdr p)))
                     problems))))

(ert-deftest jetpacs-lint-schema-unknown-key-warns ()
  "A key outside a node's schema is a \"warning: \"-prefixed problem —
forward compat lets an author target a newer companion — and the
post-construction riders (scroll_here, dialog_style) are legal anywhere."
  (let ((problems (jetpacs-lint-spec '((t . "text") (text . "hi") (flisbo . 1)))))
    (should (= (length problems) 1))
    (should (string-prefix-p "warning: " (cdr (car problems))))
    (should (string-match-p "flisbo" (cdr (car problems)))))
  (should-not (jetpacs-lint-spec (jetpacs-scroll-here (jetpacs-text "target"))))
  (should-not (jetpacs-lint-spec
               (cons '(dialog_style . "sheet")
                     (jetpacs-column (jetpacs-text "d"))))))

;; ─── Notification action buttons (SPEC §9, meta.actions) ─────────────────────

(ert-deftest jetpacs-notification-action-builds-shapes ()
  "The constructor emits the documented `meta.actions' entry shape."
  ;; icon + dismiss.
  (let ((a (jetpacs-notification-action
            "Done" (jetpacs-action "a.b") :icon "check" :dismiss t)))
    (should (equal "Done" (alist-get 'label a)))
    (should (equal "check" (alist-get 'icon a)))
    (should (eq t (alist-get 'dismiss a)))
    (should (assq 'on_tap a))
    (should-not (assq 'input a)))
  ;; An inline reply with a hint and a custom key.
  (let ((a (jetpacs-notification-action
            "Reply" (jetpacs-action "a.c") :reply-hint "Note" :reply-key "note")))
    (should (equal "Note" (alist-get 'hint (alist-get 'input a))))
    (should (equal "note" (alist-get 'key (alist-get 'input a)))))
  ;; A bare :reply still emits an `input' object (empty), defaulting the key
  ;; companion-side — never a JSON null.
  (let ((a (jetpacs-notification-action "Reply" (jetpacs-action "a.c") :reply t)))
    (should (assq 'input a))
    (should (hash-table-p (alist-get 'input a))))
  ;; The spec builder threads actions into meta.actions as a vector.
  (let* ((spec (jetpacs-notification-spec
                :channel "myapp" :body (list (jetpacs-text "x" 'title))
                :actions (list (jetpacs-notification-action
                                "Done" (jetpacs-action "a.b") :dismiss t))))
         (actions (alist-get 'actions (alist-get 'meta spec))))
    (should (vectorp actions))
    (should (= 1 (length actions)))))

(ert-deftest jetpacs-lint-passes-notification-actions ()
  "A notification spec with well-formed actions lints clean (SPEC §9)."
  (should-not
   (jetpacs-lint-spec
    (jetpacs-notification-spec
     :channel "myapp" :ongoing t
     :body (list (jetpacs-text "Tea steeping" 'title))
     :actions (list (jetpacs-notification-action
                     "Done" (jetpacs-action "a.b") :icon "check" :dismiss t)
                    (jetpacs-notification-action
                     "Reply" (jetpacs-action "a.c") :reply-hint "Note"))))))

(ert-deftest jetpacs-lint-flags-notification-actions ()
  "Missing required keys error; an unknown entry/input key warns."
  ;; Missing on_tap.
  (should (cl-some
           (lambda (p) (string-match-p "missing required `on_tap'" (cdr p)))
           (jetpacs-lint-spec
            (jetpacs-notification-spec
             :body (list (jetpacs-text "x" 'title))
             :actions (list '((label . "Done")))))))
  ;; Missing label.
  (should (cl-some
           (lambda (p) (string-match-p "missing required `label'" (cdr p)))
           (jetpacs-lint-spec
            (jetpacs-notification-spec
             :body (list (jetpacs-text "x" 'title))
             :actions (list `((on_tap . ,(jetpacs-action "a.b"))))))))
  ;; An unknown key on the entry and on the input sub-object both warn.
  (should (cl-some
           (lambda (p) (string-match-p "unknown key `frob' on notification action"
                                       (cdr p)))
           (jetpacs-lint-spec
            (jetpacs-notification-spec
             :body (list (jetpacs-text "x" 'title))
             :actions (list `((label . "R") (on_tap . ,(jetpacs-action "a.b"))
                              (frob . t)))))))
  ;; A malformed embedded on_tap action is still caught by the generic walk.
  (should (jetpacs-lint-spec
           (jetpacs-notification-spec
            :body (list (jetpacs-text "x" 'title))
            :actions (list '((label . "R") (on_tap . ((when_offline . "nope")))))))))

(ert-deftest jetpacs-lint-actions-key-not-confused-with-chrome ()
  "A chrome `actions' array (t-tagged nodes, e.g. top_bar) is never mistaken
for a notification `meta.actions' entry, so no spurious label/on_tap errors."
  (should-not
   (jetpacs-lint-spec
    `((actions . [((t . "icon_button") (icon . "search")
                   (on_tap . ((action . "a.b")))) ])))))

(defun jetpacs-tests--golden-json-lines (file)
  "Parse FILE's \"NN {json}\" golden lines into elisp values."
  (let (out)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "^[0-9]+ \\(.+\\)$" nil t)
        (push (json-parse-string (match-string 1)
                                 :object-type 'alist
                                 :null-object :null :false-object :false)
              out)))
    (nreverse out)))

(ert-deftest jetpacs-lint-widgets-golden-validates ()
  "Every typed node in widgets.golden is schema-clean — no errors, no
warnings — so the authored schema exactly covers the golden corpus."
  (let ((checked 0))
    (dolist (l (jetpacs-tests--golden-json-lines jetpacs-tests--golden-file))
      (when (and (listp l) (assq 't l))
        (setq checked (1+ checked))
        (should-not (jetpacs-lint-spec l))))
    (should (> checked 30))))            ; sanity: the corpus actually parsed

(ert-deftest jetpacs-lint-hypertext-golden-validates ()
  "Every node in hypertext.golden (lines are node arrays) is schema-clean."
  (let ((checked 0))
    (dolist (l (jetpacs-tests--golden-json-lines
                jetpacs-tests--hypertext-golden-file))
      (dolist (node (append l nil))
        (setq checked (1+ checked))
        (should-not (jetpacs-lint-spec node))))
    (should (> checked 8))))

(ert-deftest jetpacs-lint-frames-golden-validates ()
  "Every frames.golden line's kind and payload validate against the kind
schema — the elisp half of the conformance kit's frame leg."
  (let ((lines (jetpacs-tests--golden-json-lines
                jetpacs-tests--frames-golden-file)))
    (should lines)
    (dolist (l lines)
      (let ((kind (alist-get 'kind l)))
        (should (stringp kind))
        (should-not (jetpacs-lint-payload kind (alist-get 'payload l)))))))

(ert-deftest jetpacs-lint-payload-negative ()
  "The kind schema bites: unknown kind, missing required key, unknown key,
and a seeded corruption of a real golden line all report problems."
  (should (jetpacs-lint-payload "flisbo.kind" nil))
  ;; Missing required payload keys are errors.
  (let ((problems (jetpacs-lint-payload "surface.update" '((surface . "app:x")))))
    (should (cl-some (lambda (p)
                       (string-match-p "missing required `revision'" (cdr p)))
                     problems))
    (should (cl-some (lambda (p)
                       (string-match-p "missing required `spec'" (cdr p)))
                     problems)))
  ;; A key outside the kind's schema is a warning.
  (let ((problems (jetpacs-lint-payload "toast.show"
                                        '((text . "hi") (color . "#F00")))))
    (should (= (length problems) 1))
    (should (string-prefix-p "warning: " (cdr (car problems)))))
  ;; Clean payloads pass; nil means an empty payload.
  (should-not (jetpacs-lint-payload "queue.replay" nil))
  (should-not (jetpacs-lint-payload "toast.show" '((text . "hi"))))
  ;; dialog.show's payload is a §9 node tree — the node schema applies.
  (should-not (jetpacs-lint-payload
               "dialog.show" (cons '(dialog_style . "sheet")
                                   (jetpacs-column (jetpacs-text "d")))))
  (should (jetpacs-lint-payload "dialog.show" '((t . "flisbo"))))
  ;; Seeded corruption of a real golden line fails.
  (let* ((line (car (jetpacs-tests--golden-json-lines
                     jetpacs-tests--frames-golden-file)))
         (kind (alist-get 'kind line))
         (payload (mapcar (lambda (kv)
                            (if (eq (car kv) 'triggers)
                                (cons 'triggerz (cdr kv))
                              kv))
                          (alist-get 'payload line))))
    (should (jetpacs-lint-payload kind payload))))

(defun jetpacs-tests--envelope-kinds ()
  "The Kind strings declared in Envelope.kt (the Kotlin source)."
  (let ((f (expand-file-name
            "../jetpacs/src/main/java/com/calebc42/jetpacs/Envelope.kt"
            jetpacs-tests--dir))
        kinds)
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (while (re-search-forward "const val [A-Z_]+ = \"\\([a-z_.]+\\)\"" nil t)
        (cl-pushnew (match-string 1) kinds :test #'equal)))
    (nreverse kinds)))

(ert-deftest jetpacs-lint-kind-schema-covers-envelope ()
  "Every Kotlin `Kind' constant is a registered kind — the cross-language
leg for frames.  The schema may know more kinds than Envelope.kt names
\(the companion handles several by literal string), never fewer."
  (let ((kotlin (jetpacs-tests--envelope-kinds)))
    (should kotlin)
    (dolist (k kotlin)
      (should (assoc k jetpacs-lint-kind-schema)))))

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

;; ─── Drift gates (Stage-1 T1.3) ──────────────────────────────────────────────

(defun jetpacs-tests--golden-node-types ()
  "The distinct `t' discriminators emitted across test/widgets.golden."
  (let ((golden (expand-file-name "widgets.golden" jetpacs-tests--dir)) (seen nil))
    (with-temp-buffer
      (insert-file-contents golden)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim (buffer-substring (line-beginning-position)
                                                   (line-end-position)))))
          (when (and (> (length line) 0) (string-match "{.*}" line))
            (let* ((obj (ignore-errors
                          (json-parse-string (match-string 0 line) :object-type 'alist)))
                   (ty (and obj (alist-get 't obj))))
              (when ty (cl-pushnew ty seen :test #'equal)))))
        (forward-line 1)))
    seen))

(defun jetpacs-tests--sdui-node-types ()
  "The SDUI_NODE_TYPES set parsed from SduiRenderer.kt (the Kotlin source)."
  (let ((f (expand-file-name
            "../jetpacs/src/main/java/com/calebc42/jetpacs/SduiRenderer.kt"
            jetpacs-tests--dir))
        (types nil))
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (when (re-search-forward "SDUI_NODE_TYPES[^=]*=[ \t]*setOf(" nil t)
        (let* ((open (1- (match-end 0)))
               (end (save-excursion (goto-char open) (forward-sexp) (point))))
          (while (re-search-forward "\"\\([a-z_]+\\)\"" end t)
            (cl-pushnew (match-string 1) types :test #'equal)))))
    types))

(defun jetpacs-tests--api-stability-symbols ()
  "Public jetpacs symbols named under `## The public surface' in API-STABILITY.md."
  (let ((f (expand-file-name "../docs/API-STABILITY.md" jetpacs-tests--dir)) (syms nil))
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (when (re-search-forward "^## The public surface" nil t)
        (while (re-search-forward "`\\(\\(?:with-\\)?jetpacs-[a-z0-9-]+\\)`" nil t)
          (let ((name (match-string 1)))
            (unless (string-match-p "--" name)
              (cl-pushnew (intern name) syms))))))
    (nreverse syms)))

(ert-deftest jetpacs-contract-artifact-current ()
  "The committed docs/contract.json byte-matches a fresh generation.
Regenerate after an intentional wire-vocabulary change:
  emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write"
  (load (expand-file-name "../emacs/build-contract.el" jetpacs-tests--dir) nil t)
  (let ((committed (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8-unix))
                       (insert-file-contents (jetpacs-contract-file)))
                     (buffer-string))))
    (should (string= committed (jetpacs-contract-string)))))

(ert-deftest jetpacs-node-types-mirror ()
  "lint node types = widgets.golden `t' set = Kotlin SDUI_NODE_TYPES.
The cross-language leg: a node type added on one side but not the others
fails CI.  The Kotlin dispatcher-vs-SDUI_NODE_TYPES leg lives in
SduiRendererNodeTypesTest.kt."
  (let ((lint   (sort (copy-sequence jetpacs-lint-node-types) #'string<))
        (golden (sort (jetpacs-tests--golden-node-types) #'string<))
        (kotlin (sort (jetpacs-tests--sdui-node-types) #'string<)))
    (should golden)
    (should kotlin)
    (should (equal lint golden))
    (should (equal lint kotlin))))

(ert-deftest jetpacs-api-stability-symbols-bound ()
  "Every public symbol named in API-STABILITY.md is actually defined.
Extends the `--'-internal rule into a machine-checked sweep of the surface."
  (let ((syms (jetpacs-tests--api-stability-symbols)) (missing nil))
    (should syms)
    (dolist (s syms)
      (unless (or (fboundp s) (boundp s)) (push s missing)))
    (should (null missing))))

;; ─── Promoted public seams (Stage-1 T1.4) ────────────────────────────────────

(ert-deftest jetpacs-seam-month-abbrev ()
  "`jetpacs-month-abbrev' is bounds-checked and 1-indexed."
  (should (equal (jetpacs-month-abbrev 1) "Jan"))
  (should (equal (jetpacs-month-abbrev 12) "Dec"))
  (should-not (jetpacs-month-abbrev 0))
  (should-not (jetpacs-month-abbrev 13))
  (should-not (jetpacs-month-abbrev "x")))

(ert-deftest jetpacs-seam-ui-state-list ()
  "`jetpacs-ui-state-list' coerces every shape to a list of strings."
  (let ((jetpacs--ui-state (make-hash-table :test 'equal)))
    (jetpacs-ui-state-put "a" "one")
    (should (equal (jetpacs-ui-state-list "a") '("one")))          ; plain string
    (jetpacs-ui-state-put "b" ["x" "y"])
    (should (equal (jetpacs-ui-state-list "b") '("x" "y")))        ; vector
    (jetpacs-ui-state-put "c" (vector "x" 5 "z"))
    (should (equal (jetpacs-ui-state-list "c") '("x" "z")))        ; non-string dropped
    (jetpacs-ui-state-put "d" "[\"p\",\"q\"]")
    (should (equal (jetpacs-ui-state-list "d") '("p" "q")))        ; JSON array decoded
    (jetpacs-ui-state-put "e" "[not json")
    (should-not (jetpacs-ui-state-list "e"))                       ; malformed discarded
    (should-not (jetpacs-ui-state-list "missing"))))               ; absent -> nil

(ert-deftest jetpacs-seam-in-action-p ()
  "`jetpacs-in-action-p' reflects the dynamic action-handler flag."
  (should-not (jetpacs-in-action-p))
  (let ((jetpacs--in-action-handler t))
    (should (jetpacs-in-action-p))))

(ert-deftest jetpacs-seam-files-open ()
  "`jetpacs-files-open' guards on readable/in-root, runs the hook, returns the path."
  (let ((jetpacs-files--file nil) (fired nil)
        (tmp (make-temp-file "jetpacs-open")))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-shell-push) #'ignore)
                  ((symbol-function 'jetpacs-files--within-root-p) (lambda (_f) t)))
          (let ((jetpacs-files-open-hook (list (lambda (p) (setq fired p)))))
            (should (equal (jetpacs-files-open tmp) (expand-file-name tmp)))
            (should (equal fired (expand-file-name tmp)))
            (should (equal (jetpacs-files-current-file) (expand-file-name tmp)))
            ;; Out of root: refused, hook not run, returns nil.
            (cl-letf (((symbol-function 'jetpacs-files--within-root-p) (lambda (_f) nil)))
              (setq fired nil)
              (should-not (jetpacs-files-open tmp))
              (should-not fired))))
      (delete-file tmp))))

(ert-deftest jetpacs-seam-set-current-tab ()
  "`jetpacs-shell-set-current-tab' routes a valid tab through push, rejects others."
  (let ((jetpacs-shell-views nil)
        (jetpacs--registration-owners (make-hash-table :test 'equal))
        (pushed 'unset))
    (cl-letf (((symbol-function 'jetpacs-shell--schedule-repush) #'ignore)
              ((symbol-function 'jetpacs-shell-push)
               (lambda (&optional tab &rest _) (setq pushed tab))))
      (jetpacs-shell-define-view "t.tab" :builder #'ignore :tab '(:label "T"))
      (should (equal (jetpacs-shell-set-current-tab "t.tab") "t.tab"))
      (should (equal pushed "t.tab"))
      (setq pushed 'unset)
      (should-not (jetpacs-shell-set-current-tab "t.nope"))
      (should (eq pushed 'unset)))))

;; ─── Source registry (Stage-2 T2.1) ──────────────────────────────────────────

(defmacro jetpacs-tests--with-sources (&rest body)
  "Run BODY with fresh source + ownership registries."
  (declare (indent 0))
  `(let ((jetpacs--sources (make-hash-table :test 'equal))
         (jetpacs--source-cache (make-hash-table :test 'equal))
         (jetpacs--registration-owners (make-hash-table :test 'equal)))
     ,@body))

(ert-deftest jetpacs-source-uncached-requeries ()
  "An uncached source runs its query on every call."
  (jetpacs-tests--with-sources
    (let ((calls 0))
      (jetpacs-defsource "s.plain"
        :params '((:name q :type "text" :required t))
        :fields '((:name "a" :type "text"))
        :query (lambda (p) (cl-incf calls) (list (list (cons 'a (alist-get 'q p))))))
      (should (equal (jetpacs-source-query "s.plain" '((q . "x"))) '(((a . "x")))))
      (jetpacs-source-query "s.plain" '((q . "x")))
      (should (= calls 2)))))

(ert-deftest jetpacs-source-cache-key-memoises ()
  "A :cache-key source memoises per params + token; a new token re-queries."
  (jetpacs-tests--with-sources
    (let ((token 1) (calls 0))
      (jetpacs-defsource "s.cached"
        :params '((:name q :type "text"))
        :fields '((:name "a" :type "text"))
        :cache-key (lambda (_p) token)
        :query (lambda (_p) (cl-incf calls) (list)))
      (jetpacs-source-query "s.cached" '((q . "x")))
      (jetpacs-source-query "s.cached" '((q . "x")))
      (should (= calls 1))                                 ; memoised
      (setq token 2)
      (jetpacs-source-query "s.cached" '((q . "x")))
      (should (= calls 2))                                 ; new token -> re-query
      (jetpacs-source-query "s.cached" '((q . "y")))
      (should (= calls 3)))))                              ; new params -> re-query

(ert-deftest jetpacs-source-error-not-cached ()
  "A query that errors is not cached; the next call re-runs it."
  (jetpacs-tests--with-sources
    (let ((calls 0))
      (jetpacs-defsource "s.err"
        :params '((:name q :type "text"))
        :fields '((:name "a" :type "text"))
        :cache-key (lambda (_p) 1)
        :query (lambda (_p) (cl-incf calls) (error "boom")))
      (should-error (jetpacs-source-query "s.err" '((q . "x"))))
      (should-error (jetpacs-source-query "s.err" '((q . "x"))))
      (should (= calls 2)))))

(ert-deftest jetpacs-source-required-and-canonical ()
  "A missing required param errors; canonical params drop extras."
  (jetpacs-tests--with-sources
    (let ((seen nil))
      (jetpacs-defsource "s.req"
        :params '((:name q :type "text" :required t))
        :fields '((:name "a" :type "text"))
        :query (lambda (p) (setq seen p) (list)))
      (should-error (jetpacs-source-query "s.req" '((other . "z"))))
      (jetpacs-source-query "s.req" '((q . "x") (extra . "drop")))
      (should (equal seen '((q . "x")))))))

(ert-deftest jetpacs-source-schema-validation ()
  "defsource rejects an unknown type and an enum without :values."
  (jetpacs-tests--with-sources
    (should-error (jetpacs-defsource "s.bad" :fields '((:name "a" :type "wat"))))
    (should-error (jetpacs-defsource "s.enum" :fields '((:name "a" :type "enum"))))
    (should (jetpacs-defsource "s.ok"
              :fields (list (list :name "a" :type "enum" :values ["x" "y"]))
              :query #'ignore))))

(ert-deftest jetpacs-source-catalog-serializable ()
  "The catalog round-trips through the wire encoder (metadata only)."
  (jetpacs-tests--with-sources
    (jetpacs-defsource "s.cat"
      :params '((:name q :type "text" :required t))
      :fields '((:name "a" :type "text"))
      :query #'ignore)
    (let ((cat (jetpacs-source-catalog)))
      (should (jetpacs-render-to-json (vconcat cat)))     ; the catalog as a JSON array
      (should (equal (alist-get 'name (car cat)) "s.cat")))))

(ert-deftest jetpacs-source-teardown-by-owner ()
  "`jetpacs-app-unregister' removes an app's owned sources and action metadata."
  (let ((jetpacs--sources (make-hash-table :test 'equal))
        (jetpacs--source-cache (make-hash-table :test 'equal))
        (jetpacs-action-handlers (make-hash-table :test 'equal))
        (jetpacs--action-catalog (make-hash-table :test 'equal))
        (jetpacs--registration-owners (make-hash-table :test 'equal))
        (jetpacs-shell-views nil)
        (jetpacs-apps--registry nil)
        (jetpacs--ui-state (make-hash-table :test 'equal))
        (jetpacs--state-handlers (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'jetpacs-shell--schedule-repush) #'ignore))
      (with-jetpacs-owner "app1"
        (jetpacs-defsource "app1.src" :fields '((:name "a" :type "text")) :query #'ignore)
        (jetpacs-defaction "app1.do" #'ignore :doc "d"))
      (should (jetpacs-source-p "app1.src"))
      (should (gethash "app1.do" jetpacs--action-catalog))
      (jetpacs-app-unregister "app1")
      (should-not (jetpacs-source-p "app1.src"))
      (should-not (gethash "app1.do" jetpacs--action-catalog)))))

(ert-deftest jetpacs-action-catalog-metadata ()
  "jetpacs-defaction records optional args/doc; the catalog filters by owner + serializes."
  (let ((jetpacs-action-handlers (make-hash-table :test 'equal))
        (jetpacs--action-catalog (make-hash-table :test 'equal))
        (jetpacs--registration-owners (make-hash-table :test 'equal)))
    (jetpacs-defaction "a.plain" #'ignore)                 ; legacy 2-arg, no metadata
    (should (gethash "a.plain" jetpacs-action-handlers))
    (should-not (gethash "a.plain" jetpacs--action-catalog))
    (with-jetpacs-owner "app1"
      (jetpacs-defaction "app1.do" #'ignore
                      :args '((:name id :type "ref" :required t)) :doc "Do it"))
    (let ((all (jetpacs-action-catalog))
          (mine (jetpacs-action-catalog "app1")))
      (should (jetpacs-render-to-json (vconcat all)))      ; serializable
      (should (= (length mine) 1))
      (should (equal (alist-get 'action (car mine)) "app1.do"))
      (should (equal (alist-get 'doc (car mine)) "Do it")))
    (jetpacs-defaction "app1.do" #'ignore)                 ; re-register w/o metadata clears it
    (should-not (gethash "app1.do" jetpacs--action-catalog))))

;; ─── Form registry + node-or (Stage-2 T2.6) ──────────────────────────────────

(ert-deftest jetpacs-form-lifecycle ()
  "Seed-if-absent, value, reset (rotates gen + clears), dispose."
  (let ((jetpacs--forms (make-hash-table :test 'equal))
        (jetpacs--ui-state (make-hash-table :test 'equal))
        (jetpacs--state-handlers (make-hash-table :test 'equal)))
    (let* ((f (jetpacs-form "cap" "app1"))
           (id0 (jetpacs-form-field-id f "title")))
      (jetpacs-form-seed f "title" "hi")
      (should (equal (jetpacs-form-value f "title") "hi"))
      (jetpacs-form-seed f "title" "other")               ; seed-if-absent won't clobber
      (should (equal (jetpacs-form-value f "title") "hi"))
      (jetpacs-form-reset f)                               ; clears + rotates the id
      (should-not (jetpacs-form-value f "title"))
      (should-not (equal (jetpacs-form-field-id f "title") id0))
      (should (eq f (jetpacs-form "cap" "app1")))          ; same (ns,owner) -> same object
      (jetpacs-form-dispose f)
      (should-not (eq f (jetpacs-form "cap" "app1"))))))

(ert-deftest jetpacs-form-teardown-by-owner ()
  "`jetpacs-app-unregister' disposes an app's owned forms."
  (let ((jetpacs--forms (make-hash-table :test 'equal))
        (jetpacs--sources (make-hash-table :test 'equal))
        (jetpacs--source-cache (make-hash-table :test 'equal))
        (jetpacs-action-handlers (make-hash-table :test 'equal))
        (jetpacs--action-catalog (make-hash-table :test 'equal))
        (jetpacs--registration-owners (make-hash-table :test 'equal))
        (jetpacs-shell-views nil)
        (jetpacs-apps--registry nil)
        (jetpacs--ui-state (make-hash-table :test 'equal))
        (jetpacs--state-handlers (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'jetpacs-shell--schedule-repush) #'ignore))
      (jetpacs-form "cap" "app1")
      (should (= (length (jetpacs--forms-of-owner "app1")) 1))
      (jetpacs-app-unregister "app1")
      (should (= (length (jetpacs--forms-of-owner "app1")) 0)))))

(ert-deftest jetpacs-node-or-fallback ()
  "`jetpacs-node-or' picks per `jetpacs-node-supported-p'."
  (let ((jetpacs--session nil))                            ; disconnected -> fallback
    (should (eq (jetpacs-node-or "month_grid" 'prim 'fb) 'fb)))
  (let ((jetpacs--session '((granted))))                   ; connected, no catalog -> primary
    (should (eq (jetpacs-node-or "month_grid" 'prim 'fb) 'prim)))
  (let ((jetpacs--session '((node_types . ["chart"]))))    ; catalog omits it -> fallback
    (should (eq (jetpacs-node-or "month_grid" 'prim 'fb) 'fb))
    (should (eq (jetpacs-node-or "chart" 'prim 'fb) 'prim))))

;; ─── Declarative :spec compiler (Stage-2 T2.2/T2.3/T2.4) ──────────────────────

(ert-deftest jetpacs-spec-transforms ()
  "The closed, domain-neutral transform set."
  (should (equal (jetpacs-spec--transform "raw" "x") "x"))
  (should (equal (jetpacs-spec--transform "string" 5) "5"))
  (should (equal (jetpacs-spec--transform "date" "2026-07-05") "2026-07-05"))
  (should-not (jetpacs-spec--transform "date" "nope"))
  (should (equal (jetpacs-spec--transform "date-label" "2026-07-05") "Jul 5"))
  (should (equal (jetpacs-spec--transform "tags-list" ["a" "b"]) "a b"))
  (should (= (jetpacs-spec--transform "count" ["a" "b" "c"]) 3))
  (should (eq (jetpacs-spec--transform "bool" "x") t))
  (should (eq (jetpacs-spec--transform "bool" nil) :false)))

(ert-deftest jetpacs-spec-instantiate ()
  "A template's placeholders resolve; a nil resolution drops its attribute."
  (let ((item '((headline . "Hi") (ref . ((id . "1"))) (todo)))
        (template '((t . "card")
                    (on_tap . ((action . "heading.tap") (args . ((bind . "ref")))))
                    (subtitle . ((bind . "todo")))          ; nil -> dropped
                    (children . [((t . "text") (text . ((bind . "headline"))))]))))
    (let ((out (jetpacs-spec--instantiate template item "s")))
      (should (equal (alist-get 'text (aref (alist-get 'children out) 0)) "Hi"))
      (should (equal (alist-get 'args (alist-get 'on_tap out)) '((id . "1"))))
      (should-not (assq 'subtitle out)))))            ; dropped, not (subtitle . nil)

(ert-deftest jetpacs-spec-instantiate-args-spread ()
  "The _spread form merges a bound object under literal keys; collisions error."
  (let ((item '((ref . ((id . "1"))) (todo . "NEXT"))))
    (should (equal (jetpacs-spec--instantiate-args
                    '((_spread . ((bind . "ref"))) (state . ((bind . "todo")))) item "s")
                   '((id . "1") (state . "NEXT"))))
    (should-error (jetpacs-spec--instantiate-args
                   '((_spread . ((bind . "ref"))) (id . "clash")) item "s"))))

(ert-deftest jetpacs-lint-view-spec-checks ()
  "The view-spec validator flags every out-of-vocabulary element."
  (let ((fields '("headline" "ref" "todo" "scheduled")))
    (should-not (jetpacs-lint-view-spec
                 '(:source "s" :layout "list"
                   :template ((t . "text") (text . ((bind . "headline")))))
                 fields))
    (should (jetpacs-lint-view-spec                       ; unknown field
             '(:source "s" :template ((t . "text") (text . ((bind . "nope"))))) fields))
    (should (jetpacs-lint-view-spec                       ; unknown transform
             '(:source "s" :template ((t . "text") (text . ((bind . "todo") (as . "wat"))))) fields))
    (should (jetpacs-lint-view-spec                       ; unknown spec key
             '(:source "s" :template ((t . "text")) :bogus 1) fields))
    (should (jetpacs-lint-view-spec                       ; bad layout
             '(:source "s" :layout "grid" :template ((t . "text"))) fields))
    (should (jetpacs-lint-view-spec '(:template ((t . "text"))) fields))   ; no :source
    (should (jetpacs-lint-view-spec                       ; group-by unknown field
             '(:source "s" :template ((t . "text")) :group-by (:field "xxx")) fields))
    (should (jetpacs-lint-view-spec                       ; bad chrome kind
             '(:source "s" :template ((t . "text")) :chrome (:kind "sheet")) fields))))

(ert-deftest jetpacs-spec-list-layout ()
  "list: header + one template per item in a lazy column; lints clean."
  (let* ((items '(((headline . "A") (ref . ((id . "1"))))
                  ((headline . "B") (ref . ((id . "2"))))))
         (spec '(:source "s" :layout "list"
                 :template ((t . "card")
                            (on_tap . ((action . "heading.tap") (args . ((bind . "ref")))))
                            (children . [((t . "text") (text . ((bind . "headline"))))]))))
         (body (jetpacs-spec--layout-body spec items))
         (cards (append (alist-get 'children body) nil)))
    (should (equal (alist-get 't body) "lazy_column"))
    (should (= (length cards) 2))
    (should (equal (alist-get 'text (aref (alist-get 'children (car cards)) 0)) "A"))
    (should-not (jetpacs-lint-spec body))))

(ert-deftest jetpacs-spec-calendar-order ()
  "calendar: ISO-date groups ascending, unscheduled last."
  (let* ((items '(((headline . "A") (scheduled . "2026-07-05"))
                  ((headline . "B") (scheduled . "2026-07-01"))
                  ((headline . "C"))))
         (spec '(:source "s" :layout "calendar" :group-by (:field "scheduled")
                 :template ((t . "text") (text . ((bind . "headline"))))))
         (body (jetpacs-spec--layout-body spec items))
         (kids (append (alist-get 'children body) nil))
         (texts (delq nil (mapcar (lambda (n) (and (equal (alist-get 't n) "text")
                                                   (alist-get 'text n)))
                                  kids))))
    (should (equal texts '("B" "A" "C")))
    (should-not (jetpacs-lint-spec body))))

(ert-deftest jetpacs-spec-column-order ()
  "board grouping: explicit order first, unseen appended, empty last."
  (should (equal (jetpacs-spec--column-order
                  '(((todo . "DONE")) ((todo . "TODO")) ((todo)) ((todo . "WAIT")))
                  "todo" ["TODO" "DONE"] nil t)
                 '("TODO" "DONE" "WAIT" "")))
  ;; empty not forced last when empty-last nil
  (should (member "" (jetpacs-spec--column-order '(((todo))) "todo" nil nil nil))))

(ert-deftest jetpacs-spec-board-layout ()
  "board: one column per group value; lints clean."
  (let* ((items '(((headline . "A") (todo . "DONE"))
                  ((headline . "B") (todo . "TODO"))
                  ((headline . "C"))))
         (spec '(:source "s" :layout "board"
                 :group-by (:field "todo" :order ["TODO" "DONE"] :empty-last t)
                 :template ((t . "text") (text . ((bind . "headline"))))))
         (body (jetpacs-spec--layout-body spec items)))
    (should (= (length (append (alist-get 'children body) nil)) 3))
    (should-not (jetpacs-lint-spec body))))

(ert-deftest jetpacs-spec-compile-and-empty ()
  "Full compile: query -> layout -> chrome; empty items -> empty_state."
  (jetpacs-tests--with-sources
    (cl-letf (((symbol-function 'jetpacs-shell-nav-view) (lambda (_title body &rest _) body)))
      (jetpacs-defsource "t.src"
        :fields '((:name "headline" :type "text") (:name "ref" :type "ref"))
        :query (lambda (_p) (list '((headline . "A") (ref . ((id . "1")))))))
      (let ((view (jetpacs-spec--compile "t.view"
                    '(:source "t.src" :layout "list"
                      :template ((t . "card")
                                 (children . [((t . "text") (text . ((bind . "headline"))))]))
                      :chrome (:kind "nav" :title "T"))
                    nil)))
        (should (equal (alist-get 't view) "lazy_column"))
        (should (jetpacs-render-to-json view)))
      ;; empty result -> empty_state body
      (jetpacs-defsource "t.empty" :fields '((:name "a" :type "text"))
        :query (lambda (_p) nil))
      (let ((view (jetpacs-spec--compile "t.e"
                    '(:source "t.empty" :template ((t . "text") (text . ((bind . "a"))))
                      :chrome (:kind "nav" :title "T"))
                    nil)))
        (should (equal (alist-get 't view) "empty_state"))))))

(ert-deftest jetpacs-spec-compile-bad-spec-signals ()
  "A spec binding an undeclared field fails lint at compile (shell degrades it)."
  (jetpacs-tests--with-sources
    (jetpacs-defsource "t.src" :fields '((:name "headline" :type "text"))
      :query (lambda (_p) (list '((headline . "A")))))
    (should-error (jetpacs-spec--compile "t.view"
                    '(:source "t.src" :template ((t . "text") (text . ((bind . "nope")))))
                    nil))))

(ert-deftest jetpacs-spec-define-view-exclusive ()
  "jetpacs-shell-define-view requires exactly one of :builder / :spec."
  (let ((jetpacs-shell-views nil)
        (jetpacs--registration-owners (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'jetpacs-shell--schedule-repush) #'ignore))
      (should-error (jetpacs-shell-define-view "v"))
      (should-error (jetpacs-shell-define-view "v" :builder #'ignore :spec '(:source "s")))
      (should (jetpacs-shell-define-view "v" :spec '(:source "s" :template ((t . "text")))))
      (should (plist-get (cdr (assoc "v" jetpacs-shell-views)) :spec)))))

(ert-deftest jetpacs-raw-send-never-signals ()
  "A send racing the async connect's failure sentinel degrades to a
dropped frame, never an error out of the caller.  `process-live-p' can
pass an instant before the process dies (TOCTOU), so the write itself
must be guarded — the wire is fire-and-forget."
  (let ((jetpacs--process 'fake))
    (cl-letf (((symbol-function 'process-live-p) (lambda (p) (eq p 'fake)))
              ((symbol-function 'process-send-string)
               (lambda (&rest _) (error "Process jetpacs not running"))))
      (jetpacs--raw-send "{}"))))          ; a signal here fails the test

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

(defvar jetpacs-tests--modus5-p
  (let ((dir (getenv "JETPACS_MODUS_DIR")))
    (when (and dir (file-directory-p dir))
      (add-to-list 'load-path dir)
      (add-to-list 'custom-theme-load-path dir))
    (ignore-errors (require 'modus-themes nil t))
    (fboundp 'modus-themes-get-current-theme))
  "Non-nil when the modus 5.0+ derivative API is loadable.
Emacs's bundled modus (4.x on Emacs 30) has the palette accessor and the
same semantic mappings but not the derivative registry that
`modus-themes-get-current-theme' walks.  Point JETPACS_MODUS_DIR at a
modus-themes >=5.0 checkout to exercise the derivative-detection tests.")

(ert-deftest jetpacs-theme-modus-palette ()
  "The modus path reads the palette's SEMANTIC roles — exact in batch, where
face specs don't even apply (min-colors) but the palette is plain data.
Reading roles (`accent-0', `err', `prose-todo') rather than raw hues is what
keeps the mirror faithful across derivatives and the color-vision variants.
Holds on both the bundled modus 4.x and a 5.0+ checkout."
  (skip-unless (memq 'modus-vivendi (custom-available-themes)))
  (unwind-protect
      (progn
        (load-theme 'modus-vivendi t)
        (should (jetpacs-theme--modus-p))
        (let* ((payload (jetpacs-theme-payload))
               (colors (alist-get 'colors payload))
               (syntax (alist-get 'syntax payload)))
          (should (eq (alist-get 'dark payload) t))
          (should (equal (alist-get 'background colors)
                         (jetpacs-theme--modus 'bg-main)))
          ;; Primary is the palette's designated identity accent, not raw blue.
          (should (equal (alist-get 'primary colors)
                         (jetpacs-theme--modus 'accent-0)))
          ;; Tertiary is the contrasting accent.
          (should (equal (alist-get 'tertiary colors)
                         (jetpacs-theme--modus 'accent-2)))
          ;; Error is the semantic role, not raw red (accessibility variants
          ;; remap `err' away from red — see -deuteranopia test below).
          (should (equal (alist-get 'error colors)
                         (jetpacs-theme--modus 'err)))
          ;; Secondary is a muted derivation of primary, not a second hue.
          (should (alist-get 'secondary colors))
          (should-not (equal (alist-get 'secondary colors)
                             (alist-get 'primary colors)))
          ;; Containers are derived blends: present, and not the raw accent.
          (should (alist-get 'primary_container colors))
          (should-not (equal (alist-get 'primary_container colors)
                             (alist-get 'primary colors)))
          (should (equal (alist-get 'surface_variant colors)
                         (jetpacs-theme--modus 'bg-dim)))
          (should (equal (alist-get 'outline colors)
                         (jetpacs-theme--modus 'border)))
          (should (equal (alist-get 'on_primary_container colors)
                         (jetpacs-theme--modus 'fg-main)))
          ;; Syntax reads semantic code roles too (exact in batch).
          (should (equal (alist-get 'keyword syntax)
                         (jetpacs-theme--modus 'keyword)))
          (should (equal (alist-get 'function syntax)
                         (jetpacs-theme--modus 'fnname)))
          (should (equal (alist-get 'todo syntax)
                         (jetpacs-theme--modus 'prose-todo)))
          (should (equal (alist-get 'done syntax)
                         (jetpacs-theme--modus 'prose-done)))
          (should (stringp (json-serialize payload
                                           :null-object :null
                                           :false-object :false)))))
    (disable-theme 'modus-vivendi)))

(ert-deftest jetpacs-theme-modus-error-is-accessible ()
  "`error' tracks the semantic `err' role, so a deuteranopia-optimized modus
theme — which must not signal errors with red — does NOT mirror as raw red.
This is the whole point of reading roles instead of hues."
  (skip-unless (memq 'modus-vivendi-deuteranopia (custom-available-themes)))
  (unwind-protect
      (progn
        (load-theme 'modus-vivendi-deuteranopia t)
        (should (jetpacs-theme--modus-p))
        (let ((colors (alist-get 'colors (jetpacs-theme-payload))))
          (should (equal (alist-get 'error colors) (jetpacs-theme--modus 'err)))
          ;; The accessible `err' is not the palette's raw red.
          (should-not (equal (jetpacs-theme--modus 'err)
                             (jetpacs-theme--modus 'red)))))
    (disable-theme 'modus-vivendi-deuteranopia)))

(ert-deftest jetpacs-theme-modus-respects-overrides ()
  "The palette is read WITH overrides, so a user's palette override (here a
recolored identity accent) is mirrored onto the companion's primary role."
  (skip-unless (memq 'modus-vivendi (custom-available-themes)))
  (let ((modus-themes-common-palette-overrides '((accent-0 "#123456"))))
    (unwind-protect
        (progn
          (load-theme 'modus-vivendi t)
          (should (equal (alist-get 'primary
                                    (alist-get 'colors (jetpacs-theme-payload)))
                         "#123456")))
      (disable-theme 'modus-vivendi))))

(ert-deftest jetpacs-theme-modus-derivative-detected ()
  "A theme BUILT ON modus (modus 5.0's derivative API) is detected as
modus-family through its `:modus-core-palette' property — not a `modus-'
name prefix, which every derivative would fail — and its own identity accent
is mirrored.  This is the cross-theme compatibility guarantee: the ef-themes,
standard-themes, and third-party skins all ride this same path."
  (skip-unless jetpacs-tests--modus5-p)
  (let* ((dir (make-temp-file "jetpacs-modus-deriv" t))
         (file (expand-file-name "jetpacs-testderiv-theme.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (prin1-to-string
                     '(progn
                        (require 'modus-themes)
                        (defvar jetpacs-testderiv-palette
                          (append '((bg-main "#0a0a12")
                                    (fg-main "#e6e6ea")
                                    (green-lush "#3fbf6f")
                                    (accent-0 green-lush))
                                  modus-themes-vivendi-palette))
                        (defvar jetpacs-testderiv-palette-user nil)
                        (defvar jetpacs-testderiv-palette-overrides nil)
                        (modus-themes-theme
                         'jetpacs-testderiv 'jetpacs-test-derivatives
                         "Test derivative with a green identity accent." 'dark
                         'jetpacs-testderiv-palette
                         'jetpacs-testderiv-palette-user
                         'jetpacs-testderiv-palette-overrides)
                        (provide-theme 'jetpacs-testderiv)))))
          (add-to-list 'custom-theme-load-path dir)
          (load-theme 'jetpacs-testderiv t)
          ;; The derivative's name has no `modus-' prefix, yet it is detected.
          (should (eq (jetpacs-theme--modus-theme) 'jetpacs-testderiv))
          (should (jetpacs-theme--modus-p))
          (let ((colors (alist-get 'colors (jetpacs-theme-payload))))
            ;; Its own identity accent lands on primary, not a stock blue.
            (should (equal (alist-get 'primary colors) "#3fbf6f"))
            ;; Its own surface, not the base modus one.
            (should (equal (alist-get 'surface colors) "#0a0a12"))))
      (when (custom-theme-enabled-p 'jetpacs-testderiv)
        (disable-theme 'jetpacs-testderiv))
      (delete-directory dir t))))

;; ─── Modus themes control screen ─────────────────────────────────────────────

(ert-deftest jetpacs-modus-queries ()
  "The theme queries read modus through its API: current theme, the theme
list, and light/dark classification."
  (skip-unless (jetpacs-modus--available-p))
  (should (jetpacs-modus--ensure))
  (unwind-protect
      (progn
        (load-theme 'modus-vivendi t)
        (should (eq (jetpacs-modus--current) 'modus-vivendi))
        (let ((themes (jetpacs-modus--themes)))
          (should (memq 'modus-operandi themes))
          (should (memq 'modus-vivendi themes)))
        ;; vivendi is dark, operandi light.
        (should (jetpacs-modus--dark-p 'modus-vivendi))
        (should-not (jetpacs-modus--dark-p 'modus-operandi))
        ;; A palette role resolves to a hex swatch color.
        (should (string-prefix-p "#" (jetpacs-modus--color 'bg-main))))
    (disable-theme 'modus-vivendi)))

(ert-deftest jetpacs-modus-view-builds-and-lints ()
  "The screen builds a lint-clean spec with the picker, swatches, the active
marker, the style switches, and the customize cross-link."
  (skip-unless (jetpacs-modus--available-p))
  (unwind-protect
      (progn
        (load-theme 'modus-vivendi t)
        (let* ((view (jetpacs-modus--view nil))
               (s (prin1-to-string view)))
          (should-not (jetpacs-lint-spec view))
          ;; Serialize like the real push does: lint alone missed a raw-list
          ;; child (a section node-list must be spread, not nested), which
          ;; `json-serialize' rejects as a non-symbol object key.
          (should (stringp (json-serialize view :null-object :null
                                           :false-object :false)))
          (should (string-search "Modus Themes" s))
          (should (string-search "modus-operandi" s))  ; other themes listed
          (should (string-search "surface" s))          ; swatches
          (should (string-search "check_circle" s))     ; active marker
          (should (string-search "Bold keywords" s))    ; a style switch
          (should (string-search "modus.load" s))       ; tap-to-load
          (should (string-search "customize.show" s)))) ; deep-options link
    (disable-theme 'modus-vivendi)))

(ert-deftest jetpacs-modus-load-action-switches-theme ()
  "The modus.load action loads the named theme; an unknown name is refused."
  (skip-unless (jetpacs-modus--available-p))
  (should (jetpacs-modus--ensure))
  (let ((fn (gethash "modus.load" jetpacs-action-handlers))
        notified)
    (should fn)
    (cl-letf (((symbol-function 'jetpacs-shell-push) (lambda (&rest _) nil))
              ((symbol-function 'jetpacs-shell-notify)
               (lambda (msg &rest _) (setq notified msg))))
      (unwind-protect
          (progn
            (funcall fn '((theme . "modus-operandi")) nil)
            (should (eq (jetpacs-modus--current) 'modus-operandi))
            ;; A non-modus / unknown theme is rejected, not loaded.
            (funcall fn '((theme . "no-such-theme")) nil)
            (should notified)
            (should (eq (jetpacs-modus--current) 'modus-operandi)))
        (mapc #'disable-theme
              (seq-filter (lambda (th) (string-prefix-p "modus-" (symbol-name th)))
                          custom-enabled-themes))))))

(ert-deftest jetpacs-modus-mirror-note-tracks-mode ()
  "The header's mirror affordance is a live badge under `emacs' mode and a
one-tap switch otherwise."
  (let ((jetpacs-theme-mode 'emacs))
    (should (string-search "Mirroring"
                           (prin1-to-string (jetpacs-modus--mirror-note)))))
  (let ((jetpacs-theme-mode 'default))
    (should (string-search "modus.mirror"
                           (prin1-to-string (jetpacs-modus--mirror-note))))))

(ert-deftest jetpacs-modus-settings-link-registered ()
  "The screen is reachable from the Emacs settings section, beside Packages
and Customize."
  (skip-unless (jetpacs-modus--available-p))
  (let ((body (prin1-to-string (jetpacs-settings-sections))))
    (should (string-search "modus.show" body))
    (should (string-search "Modus Themes" body))))

(ert-deftest jetpacs-shell-every-view-serializes ()
  "Every registered shell view must not just lint but `json-serialize' — the
push assembles them all into one surface, so a single non-serializable node
\(e.g. a raw list where a node is expected) fails the whole dashboard push and
takes every other view down with it."
  (when (jetpacs-modus--available-p) (load-theme 'modus-vivendi t))
  (unwind-protect
      (dolist (view jetpacs-shell-views)
        (let ((name (car view)))
          (should
           (stringp
            (condition-case err
                (json-serialize (jetpacs-shell--build-view name (cdr view) nil)
                                :null-object :null :false-object :false)
              (error (ert-fail (format "view %S: %S" name err))))))))
    (when (custom-theme-enabled-p 'modus-vivendi) (disable-theme 'modus-vivendi))))

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
    (should (string-search "setting/jetpacs-theme-mode" body))
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
  (let ((jetpacs-theme-mode 'emacs))
    (jetpacs-theme--push-mode)
    (should-not jetpacs-theme--timer))
  ;; Disconnected `M-x jetpacs-theme-send' must message, not error or hang.
  (jetpacs-theme-send))

(ert-deftest jetpacs-theme-frame-for-mode ()
  "Each mode maps to its wire frame: `emacs' mirrors a palette; `material' and
`default' send a `base' directive that carries no colors (so the companion
drops any mirror and forces that scheme)."
  ;; `default' / `material' are static directives, resolvable in batch.
  (let ((jetpacs-theme-mode 'default))
    (should (equal (jetpacs-theme--frame-for-mode) '((base . "default")))))
  (let ((jetpacs-theme-mode 'material))
    (should (equal (jetpacs-theme--frame-for-mode) '((base . "material")))))
  ;; `emacs' yields the mirrored palette (with colors, no base).
  (skip-unless (memq 'modus-vivendi (custom-available-themes)))
  (unwind-protect
      (let ((jetpacs-theme-mode 'emacs))
        (load-theme 'modus-vivendi t)
        (let ((frame (jetpacs-theme--frame-for-mode)))
          (should (alist-get 'colors frame))
          (should-not (alist-get 'base frame))))
    (disable-theme 'modus-vivendi)))

(ert-deftest jetpacs-theme-mode-renders-as-enum ()
  "The setting surfaces as a three-way single-select enum (Default/Material/
Emacs), the control the settings layer builds for a choice-of-consts type."
  (let* ((col (jetpacs-settings-item 'jetpacs-theme-mode :label "Companion theme"))
         (node (prin1-to-string col)))
    (should-not (jetpacs-lint-spec col))
    ;; An enum_list control, not a switch.
    (should (string-search "enum_list" node))
    (dolist (tag '("Default" "Material" "Emacs"))
      (should (string-search tag node)))))

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

(ert-deftest jetpacs-config-adopt-byte-compiles ()
  "Adopt compiles the bundle to lib/*.elc (Phase H / Task 22); an
unchanged bundle is not recompiled; a newer re-synced .el is; a broken
.el warns, drops the .elc, and never signals out of the adopt step —
boot falls back to loading source."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-adopt" t)))
         (jetpacs-root tmp)
         (jetpacs-lib-dir (expand-file-name "lib/" tmp))
         (staging (file-name-as-directory (expand-file-name "staging/" tmp)))
         (jetpacs-staging-dirs (list staging))
         (bundle "jetpacs-tests-adopt.el")
         (staged (concat staging bundle))
         (installed (expand-file-name bundle jetpacs-lib-dir))
         (elc (concat installed "c"))
         (jetpacs-tests--cfg-a nil)
         (warnings nil))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type msg &rest _) (push msg warnings))))
          (make-directory staging t)
          (write-region "(setq jetpacs-tests--cfg-a 1)\n(provide 'jetpacs-tests-adopt)\n"
                        nil staged nil 'silent)
          ;; Adopt: copied into lib/ and compiled beside it.
          (should (eq (jetpacs-config-adopt bundle) 'jetpacs-tests-adopt))
          (should (file-exists-p installed))
          (should (file-exists-p elc))
          ;; The compiled artifact is loadable and current.
          (load elc nil 'nomessage 'nosuffix)
          (should (= jetpacs-tests--cfg-a 1))
          ;; Nothing newer staged: a second adopt leaves the .elc alone.
          (let ((mtime (file-attribute-modification-time (file-attributes elc))))
            (jetpacs-config-adopt bundle)
            (should (equal mtime (file-attribute-modification-time
                                  (file-attributes elc)))))
          ;; A newer re-synced source recompiles (backdate the installed
          ;; pair so mtime granularity can't hide the freshness ordering).
          (set-file-times elc (time-subtract nil 100))
          (set-file-times installed (time-subtract nil 50))
          (write-region "(setq jetpacs-tests--cfg-a 2)\n(provide 'jetpacs-tests-adopt)\n"
                        nil staged nil 'silent)
          (jetpacs-config-adopt bundle)
          (load elc nil 'nomessage 'nosuffix)
          (should (= jetpacs-tests--cfg-a 2))
          ;; A deliberately-broken newer bundle: adopt still returns the
          ;; feature, warns, and removes the .elc so source is what loads.
          (set-file-times elc (time-subtract nil 100))
          (set-file-times installed (time-subtract nil 50))
          (write-region "(defvar jetpacs-tests--broken\n" nil staged nil 'silent)
          (should (eq (jetpacs-config-adopt bundle) 'jetpacs-tests-adopt))
          (should-not (file-exists-p elc))
          (should warnings))
      (delete-directory tmp t))))

;; ─── App store (Manage Apps) ─────────────────────────────────────────────────

(ert-deftest jetpacs-config-adopt-searches-staging-recursively ()
  "A bundle staged in a subdirectory adopts by basename — the Manage
Apps screen lists the whole staging tree, so boot must find the same
copies on every later start."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-adopt-r" t)))
         (jetpacs-lib-dir (expand-file-name "lib/" tmp))
         (staging (file-name-as-directory (expand-file-name "staging/" tmp)))
         (jetpacs-staging-dirs (list staging))
         (bundle "jetpacs-tests-radopt.el"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "apps/more" staging) t)
          (write-region "(provide 'jetpacs-tests-radopt)\n" nil
                        (expand-file-name (concat "apps/more/" bundle) staging)
                        nil 'silent)
          (should (eq (jetpacs-config-adopt bundle) 'jetpacs-tests-radopt))
          (should (file-exists-p (expand-file-name bundle jetpacs-lib-dir))))
      (delete-directory tmp t))))

(ert-deftest jetpacs-app-store-scan-shape ()
  "The scan: recursive, foundation files excluded, the newest duplicate
wins, installed state keyed on `jetpacs-installed-bundles'."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-store" t)))
         (jetpacs-staging-dirs (list tmp))
         (jetpacs-installed-bundles '("beta.el")))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "sub" tmp) t)
          (write-region ";;; alpha.el --- the alpha app -*- lexical-binding: t; -*-\n"
                        nil (expand-file-name "alpha.el" tmp) nil 'silent)
          (write-region "" nil (expand-file-name "beta.el" tmp) nil 'silent)
          ;; A newer copy of alpha deeper in the tree wins the row.
          (write-region ";;; alpha.el --- the newer alpha -*- lexical-binding: t; -*-\n"
                        nil (expand-file-name "sub/alpha.el" tmp) nil 'silent)
          (set-file-times (expand-file-name "alpha.el" tmp)
                          (time-subtract nil 100))
          ;; The foundation's own staged files are not apps.
          (write-region "" nil (expand-file-name "jetpacs-core.el" tmp) nil 'silent)
          (write-region "" nil (expand-file-name "jetpacs-init.el" tmp) nil 'silent)
          (let* ((entries (jetpacs-app-store--scan))
                 (alpha (car entries))
                 (beta (cadr entries)))
            (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                           '("alpha.el" "beta.el")))
            (should (equal (plist-get alpha :summary) "the newer alpha"))
            (should (string-match-p "/sub/" (plist-get alpha :path)))
            (should-not (plist-get alpha :installed))
            (should (plist-get beta :installed))))
      (delete-directory tmp t))))

(ert-deftest jetpacs-app-store-install-uninstall-round-trip ()
  "Install rewrites apps.el and loads the bundle live, recording its
owners; uninstall rewrites apps.el and tears the recorded owners down.
An unknown bundle name changes nothing — the wire only ever names
something actually staged."
  (let* ((tmp (file-name-as-directory (make-temp-file "jetpacs-store-i" t)))
         (jetpacs-root tmp)
         (jetpacs-lib-dir (expand-file-name "lib/" tmp))
         (staging (file-name-as-directory (expand-file-name "staging/" tmp)))
         (jetpacs-staging-dirs (list staging))
         (jetpacs-installed-bundles nil)
         (jetpacs-config--bundle-owners nil)
         (load-path (cons (expand-file-name "lib/" tmp) load-path))
         (apps-el (expand-file-name "apps.el" tmp))
         (notices nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jetpacs-shell-push)
                   (cl-function (lambda (&optional _tab &key _switch-to))))
                  ((symbol-function 'jetpacs-shell-notify)
                   (lambda (text) (push text notices)))
                  ((symbol-function 'jetpacs-send) (lambda (&rest _) t))
                  ((symbol-function 'jetpacs-dismiss-dialog) #'ignore))
          (make-directory staging t)
          (write-region
           (concat "(with-jetpacs-owner \"tstore\""
                   " (jetpacs-defaction \"tstore.ping\" #'ignore))\n"
                   "(provide 'jetpacs-tests-store-app)\n")
           nil (expand-file-name "jetpacs-tests-store-app.el" staging)
           nil 'silent)
          ;; Unknown name: rejected, nothing listed.
          (funcall (gethash "app.install.confirm" jetpacs-action-handlers)
                   '((bundle . "nope.el")) nil)
          (should-not jetpacs-installed-bundles)
          ;; The real install: listed, persisted, loaded, owners recorded.
          (funcall (gethash "app.install.confirm" jetpacs-action-handlers)
                   '((bundle . "jetpacs-tests-store-app.el")) nil)
          (should (equal jetpacs-installed-bundles
                         '("jetpacs-tests-store-app.el")))
          (should (gethash "tstore.ping" jetpacs-action-handlers))
          (should (equal (alist-get "jetpacs-tests-store-app.el"
                                    jetpacs-config--bundle-owners
                                    nil nil #'equal)
                         '("tstore")))
          (should (string-match-p
                   "jetpacs-tests-store-app\\.el"
                   (with-temp-buffer (insert-file-contents apps-el)
                                     (buffer-string))))
          ;; Uninstall: unlisted, persisted, the owner torn down live.
          (funcall (gethash "app.uninstall.confirm" jetpacs-action-handlers)
                   '((bundle . "jetpacs-tests-store-app.el")) nil)
          (should-not jetpacs-installed-bundles)
          (should-not (gethash "tstore.ping" jetpacs-action-handlers))
          (should-not (string-match-p
                       "store-app"
                       (with-temp-buffer (insert-file-contents apps-el)
                                         (buffer-string)))))
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
