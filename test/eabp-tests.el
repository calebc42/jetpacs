;;; eabp-tests.el --- ERT suite for the Glasspane Emacs client -*- lexical-binding: t; -*-

;; Run from the repo root (any Emacs 28+):
;;   emacs -Q --batch -l test/eabp-tests.el -f ert-run-tests-batch-and-exit
;; or via test/run-tests.sh.
;;
;; The widget wire-format test compares every constructor against the
;; committed golden snapshot (test/widgets.golden).  After an INTENTIONAL
;; wire-format change, regenerate it with:
;;   emacs -Q --batch -l test/eabp-tests.el -f eabp-tests-regen-widget-golden

;;; Code:

(defvar eabp-tests--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(dolist (dir '("../emacs/core" "../emacs/apps" "../emacs/apps/glasspane"))
  (add-to-list 'load-path (expand-file-name dir eabp-tests--dir)))

(require 'ert)
(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-shell)
(require 'glasspane-org)
(require 'eabp-keymap)
(require 'eabp-magit)
(require 'eabp-files)
(require 'eabp-minibuffer)
(require 'glasspane-ui)
(require 'eabp-emacs-ui)
(require 'eabp-complete)
(require 'eabp-sync)
(require 'glasspane-demo)

;; ─── Capture ────────────────────────────────────────────────────────────────

(ert-deftest eabp-capture-fills-template ()
  "The filled capture template must be the one that actually runs."
  (let* ((file (make-temp-file "eabp-capture-test" nil ".org"))
         (org-capture-templates
          `(("t" "Task" entry (file ,file)
             "* TODO %^{Headline}\n%^{Notes|no notes}\n%?"))))
    (unwind-protect
        (progn
          (glasspane-org--do-capture "t" '(("Headline" . "Buy milk")
                                      ("Notes" . "2% fat")))
          (let ((content (with-current-buffer (find-file-noselect file)
                           (buffer-string))))
            (should (string-search "* TODO Buy milk" content))
            (should (string-search "2% fat" content))
            (should-not (string-search "%^{" content))))
      (delete-file file))))

(ert-deftest eabp-capture-shared-body ()
  "Text shared from another app is appended below the filled template."
  (let* ((file (make-temp-file "eabp-share-test" nil ".org"))
         (org-capture-templates
          `(("t" "Task" entry (file ,file) "* TODO %^{Headline}\n%?"))))
    (unwind-protect
        (progn
          (glasspane-org--do-capture "t" '(("Headline" . "Read article"))
                                "https://example.com/post\nInteresting bit.")
          (let ((content (with-current-buffer (find-file-noselect file)
                           (buffer-string))))
            (should (string-search "* TODO Read article" content))
            (should (string-search "https://example.com/post" content))
            (should (string-search "Interesting bit." content))))
      (delete-file file))))

;; ─── Reminders ──────────────────────────────────────────────────────────────

(ert-deftest eabp-upcoming-reminders ()
  "Timed items within the horizon become reminder specs; untimed don't."
  (let* ((file (make-temp-file "eabp-remind" nil ".org"))
         (tomorrow (glasspane-ui--shift-date (format-time-string "%Y-%m-%d")
                                            1 'day)))
    (with-temp-file file
      (insert (format "* TODO Standup\nSCHEDULED: <%s 09:15>\n" tomorrow)
              (format "* TODO Untimed thing\nSCHEDULED: <%s>\n" tomorrow)))
    (unwind-protect
        (let ((org-agenda-files (list file)))
          (glasspane-org-cache-invalidate)
          (let ((rems (glasspane-org--upcoming-reminders 48)))
            (should (= (length rems) 1))
            (let ((r (car rems)))
              (should (equal (alist-get 'title r) "Standup"))
              (should (> (alist-get 'at_ms r)
                         (truncate (* 1000 (float-time)))))
              (should (string-prefix-p "09:15" (alist-get 'body r))))))
      (delete-file file))))

;; ─── Widget items ───────────────────────────────────────────────────────────

(ert-deftest eabp-widget-items ()
  "Widget items compose meta, flag overdue, omit nil fields, cap at 20."
  (let ((today (org-today)))
    (cl-letf (((symbol-function 'glasspane-org--agenda-items)
               (lambda (&rest _)
                 (append
                  (list `((headline . "Standup") (time . "09:15") (todo . "TODO")
                          (type . "scheduled") (extra . "Scheduled: ")
                          (ts-date . ,today) (file . "/tmp/a.org")
                          (ref . ((file . "/tmp/a.org") (pos . 1)
                                  (headline . "Standup"))))
                        `((headline . "Report") (todo . "TODO")
                          (type . "past-scheduled") (extra . "Sched. 3x: ")
                          (ts-date . ,(- today 3)) (file . "/tmp/b.org"))
                        '((headline . "Shipped") (todo . "DONE"))
                        '((headline . "No time")))
                  (make-list 25 '((headline . "Filler") (time . "10:00")))))))
      (let ((items (glasspane-ui--widget-items)))
        ;; 20 capped rows plus the two injected dividers.
        (should (= (length items) 22))
        (should (equal (alist-get 'divider (nth 0 items)) "Overdue"))
        (let ((od (nth 1 items)))
          (should (equal (alist-get 'text od) "Report"))
          (should (equal (alist-get 'meta od) "Sched. 3x · b.org"))
          (should (equal (alist-get 'icon od) "scheduled"))
          (should (equal (alist-get 'button od) "todo_open"))
          (should (equal (alist-get 'action (alist-get 'on_button od))
                         "heading.todo-cycle")))
        (should (equal (alist-get 'divider (nth 2 items)) "Today"))
        (let ((first (nth 3 items)))
          (should (equal (alist-get 'text first) "Standup"))
          (should (equal (alist-get 'todo first) "TODO"))
          ;; A bare "Scheduled" qualifier is dropped: time + file only.
          (should (equal (alist-get 'meta first) "09:15 · a.org"))
          (should (equal (alist-get 'icon first) "scheduled"))
          (should (eq (alist-get 'tap_in_app first) t))
          (should (equal (alist-get 'action (alist-get 'on_tap first))
                         "heading.tap"))
          (should (equal (alist-get 'file (alist-get 'args (alist-get 'on_tap first)))
                         "/tmp/a.org"))
          (should-not (alist-get 'done first)))
        (let ((done (nth 4 items)))
          (should (eq (alist-get 'done done) t))
          (should (equal (alist-get 'button done) "todo_done"))
          ;; No time/extra/file → no meta at all.
          (should-not (assq 'meta done)))
        (let ((plain (nth 5 items)))
          (should (equal (alist-get 'text plain) "No time"))
          (should-not (assq 'todo plain))
          (should-not (assq 'button plain)))))))

;; ─── Extraction cache ───────────────────────────────────────────────────────

(ert-deftest glasspane-org-cache-memoises ()
  "Readers memoise until `glasspane-org-cache-invalidate' drops the table."
  (let ((n 0))
    (cl-letf (((symbol-function 'glasspane-org--todo-items-1)
               (lambda (_files) (setq n (1+ n)) '(fake))))
      (glasspane-org-cache-invalidate)
      (glasspane-org--todo-items)
      (glasspane-org--todo-items)
      (should (= n 1))
      (glasspane-org-cache-invalidate)
      (glasspane-org--todo-items)
      (should (= n 2)))))

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

(ert-deftest eabp-agenda-extraction ()
  "Items extract; the private buffer dies; the user's agenda survives."
  (let* ((file (make-temp-file "eabp-agenda-test" nil ".org")))
    (with-temp-file file
      (insert (format "* TODO Water plants\nSCHEDULED: <%s>\n"
                      (format-time-string "%Y-%m-%d %a"))))
    (unwind-protect
        (let ((org-agenda-files (list file)))
          (with-current-buffer (get-buffer-create "*Org Agenda*")
            (erase-buffer)
            (insert "user content"))
          (glasspane-org-cache-invalidate)
          (should (cl-some (lambda (it)
                             (equal (alist-get 'headline it) "Water plants"))
                           (glasspane-org--agenda-items 'day nil)))
          (should-not (get-buffer "*EABP Agenda*"))
          (should (equal (with-current-buffer "*Org Agenda*" (buffer-string))
                         "user content")))
      (delete-file file))))

(ert-deftest eabp-agenda-anchored-extraction ()
  "Navigation anchors actually change the extracted range."
  (let* ((file (make-temp-file "eabp-agenda-nav" nil ".org"))
         (tomorrow (glasspane-ui--shift-date
                    (format-time-string "%Y-%m-%d") 1 'day)))
    (with-temp-file file
      (insert (format "* TODO Future thing\nSCHEDULED: <%s>\n" tomorrow)))
    (unwind-protect
        (let ((org-agenda-files (list file)))
          (glasspane-org-cache-invalidate)
          (should-not (cl-some (lambda (it)
                                 (equal (alist-get 'headline it) "Future thing"))
                               (glasspane-org--agenda-items 'day nil)))
          (should (cl-some (lambda (it)
                             (equal (alist-get 'headline it) "Future thing"))
                           (glasspane-org--agenda-items 'day tomorrow))))
      (delete-file file))))

;; ─── Agenda date arithmetic & widgets ───────────────────────────────────────

(ert-deftest eabp-agenda-date-math ()
  (should (equal (glasspane-ui--shift-date "2026-07-01" 1 'day) "2026-07-02"))
  (should (equal (glasspane-ui--shift-date "2026-07-01" -1 'day) "2026-06-30"))
  (should (equal (glasspane-ui--shift-date "2026-07-01" -1 'week) "2026-06-24"))
  (should (equal (glasspane-ui--shift-date "2026-01-31" 1 'month) "2026-02-28"))
  (should (equal (glasspane-ui--shift-date "2024-01-31" 1 'month) "2024-02-29"))
  (should (equal (glasspane-ui--shift-date "2026-12-15" 1 'month) "2027-01-15"))
  (should (equal (glasspane-ui--shift-date "2026-01-15" -1 'month) "2025-12-15")))

(ert-deftest eabp-agenda-widgets-serialize ()
  "Agenda cards, nav rows, and the month grid build and serialize."
  (let ((item `((headline . "Ship release")
                (todo . "TODO")
                (time . "10:00")
                (type . "scheduled")
                (file . "/tmp/x.org")
                (priority . "A")
                (tags . ["work" "urgent"])
                (ref . ((file . "/tmp/x.org") (pos . 1)
                        (headline . "Ship release"))))))
    (dolist (node (list (glasspane-ui--agenda-card item)
                        (glasspane-ui--agenda-card
                         '((headline . "Done thing") (todo . "DONE")))
                        (glasspane-ui--agenda-nav-row "day" "2026-07-01")
                        (glasspane-ui--agenda-nav-row "week" "2026-07-01")
                        (glasspane-ui--agenda-nav-row "month" "2026-07-01")
                        (glasspane-ui--agenda-month-view nil "2026-02-14")))
      (should (consp node))
      (should (stringp (json-serialize node :null-object :null
                                       :false-object :false))))))

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

(ert-deftest eabp-magit-tier1 ()
  "The curated magit pie registers, fits the pie, and serializes."
  (with-temp-buffer
    (setq major-mode 'magit-status-mode)
    (let ((builder (eabp-keymap--tier1-builder (current-buffer))))
      (should (functionp builder))
      (let* ((spec (funcall builder (current-buffer)))
             (cats (append (alist-get 'categories spec) nil)))
        (should (equal (alist-get 'center_label spec) "Magit"))
        (should (= (length cats) 4))
        (dolist (cat cats)
          (should (<= (length (append (alist-get 'bindings cat) nil)) 8)))
        (let ((share (cl-find "Share" cats
                              :key (lambda (c) (alist-get 'label c))
                              :test #'equal)))
          (should (cl-every (lambda (b) (alist-get 'is_prefix b))
                            (append (alist-get 'bindings share) nil))))
        (should (stringp (json-serialize spec :null-object :null
                                         :false-object :false))))))
  (with-temp-buffer
    (should-not (eabp-keymap--tier1-builder (current-buffer)))))

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

(ert-deftest eabp-detail-properties ()
  "Property rows: colon-free editable keys, read-only ID, empty-value adds.
Also pins the org behavior the + Add flow depends on: a property set to
the empty string must still be returned by `org-entry-properties'."
  ;; Row shapes.
  (let* ((ref '((file . "/tmp/x.org") (pos . 1) (headline . "T")))
         (row (glasspane-ui--property-row "EFFORT" "2h" ref 1))
         (id-row (glasspane-ui--property-row "ID" "abc-123" ref 1)))
    (should (equal (alist-get 't row) "row"))
    ;; Key column: plain label, no colons.
    (let* ((key-box (aref (alist-get 'children row) 0))
           (key-text (aref (alist-get 'children key-box) 0)))
      (should (equal (alist-get 'text key-text) "EFFORT")))
    ;; Value column: an input for normal keys, read-only text for ID.
    (let* ((val-box (aref (alist-get 'children row) 1))
           (input (aref (alist-get 'children val-box) 0)))
      (should (equal (alist-get 't input) "text_input"))
      (should (equal (alist-get 'value input) "2h")))
    (let* ((val-box (aref (alist-get 'children id-row) 1))
           (node (aref (alist-get 'children val-box) 0)))
      (should (equal (alist-get 't node) "text"))))
  ;; Empty-valued properties survive extraction (the + Add contract).
  (let ((file (make-temp-file "eabp-props" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (insert "* Task\n")
          (goto-char (point-min))
          (org-mode)
          (org-set-property "NEWKEY" "")
          (should (assoc "NEWKEY" (org-entry-properties nil 'standard))))
      (delete-file file))))

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

(ert-deftest glasspane-demo-setup-writes-files ()
  "Setup writes every tour file, non-trivially sized, and is idempotent."
  (let ((dir (make-temp-file "glasspane-demo" t)))
    (unwind-protect
        (progn
          (glasspane-demo-setup dir)
          (glasspane-demo-setup dir)          ; overwrite must not error
          (dolist (f '("demo.el" "demo.py" "demo.sh" "demo.c" "demo.org"))
            (let ((path (expand-file-name f dir)))
              (should (file-exists-p path))
              (should (> (file-attribute-size (file-attributes path)) 200)))))
      (delete-directory dir t))))

(ert-deftest glasspane-demo-el-is-tour-ready ()
  "The elisp tour file exercises the bridge features it claims to.
Its wrong-arity call must reference a function defined in the same
file (so the byte-compiler can flag it), and completion must fire on
the text it tells the user to type."
  (let ((content (cdr (assoc "demo.el" glasspane-demo--files))))
    (should (string-search "(demo-greet \"world\" 'oops)" content))
    (should (string-search "(defun demo-greet (name)" content))
    ;; The completion instruction actually completes.
    (let ((result (eabp-complete-in-text "demo.el" "(buffer-sub" 11)))
      (should result)
      (should (equal (car result) "buffer-sub")))))

;; ─── Org tables: emitter and actions ────────────────────────────────────────

(ert-deftest glasspane-org-rich-table-node ()
  "Org tables emit native table nodes: header, rule, aligns, cell taps."
  (let* ((body (concat "| Item | Qty |\n"
                       "|------+-----|\n"
                       "| a    |   1 |\n"
                       "| bb   |   2 |\n"))
         (table (car (glasspane-org-rich-body body nil "/tmp/t.org" 10))))
    (should (equal (alist-get 't table) "table"))
    (let* ((rows (append (alist-get 'rows table) nil))
           (r0 (nth 0 rows)) (r1 (nth 1 rows)) (r2 (nth 2 rows)))
      (should (= (length rows) 4))
      (should (eq (alist-get 'header r0) t))
      (should (eq (alist-get 'rule r1) t))
      ;; The numeric column right-aligns (org's own heuristic).
      (should (equal (append (alist-get 'aligns table) nil) '("start" "end")))
      ;; Cells carry edit actions with real-file positions baked in.
      (let* ((cell (aref (alist-get 'cells r2) 0))
             (tap (alist-get 'on_tap cell)))
        (should (equal (alist-get 'action tap) "org.table.edit"))
        (should (equal (alist-get 'file (alist-get 'args tap)) "/tmp/t.org"))
        (should (integerp (alist-get 'pos (alist-get 'args tap))))))
    ;; Add affordances point back at the table.
    (should (equal (alist-get 'action (alist-get 'on_add_row table))
                   "org.table.add-row"))
    (should (equal (alist-get 'action (alist-get 'on_add_col table))
                   "org.table.add-col"))))

(ert-deftest glasspane-org-rich-table-readonly-without-context ()
  "Without file context the table renders, but nothing is tappable."
  (let ((table (car (glasspane-org-rich-body "| a | b |\n" nil))))
    (should (equal (alist-get 't table) "table"))
    (should-not (alist-get 'on_add_row table))
    (should-not (alist-get 'on_add_col table))
    (let ((cell (aref (alist-get 'cells (aref (alist-get 'rows table) 0)) 0)))
      (should-not (alist-get 'on_tap cell)))
    ;; A lone row group is not a header.
    (should-not (alist-get 'header (aref (alist-get 'rows table) 0)))))

(ert-deftest glasspane-org-rich-table-cookie-alignment ()
  "Cookie rows configure column alignment and drop out of display."
  (let ((table (car (glasspane-org-rich-body "| <c> | <r> |\n| a | b |\n" nil))))
    (should (equal (append (alist-get 'aligns table) nil) '("center" "end")))
    (should (= (length (alist-get 'rows table)) 1))))

(ert-deftest glasspane-ui-table-edit-recalculates ()
  "The org.table.edit handler writes the field and recalculates #+TBLFM."
  (let ((file (make-temp-file "eabp-table-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "| Item   | Qty | Cost |\n"
                    "|--------+-----+------|\n"
                    "| apples |   2 |    4 |\n"
                    "#+TBLFM: $3=$2*2\n"))
          (let (pos)
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (search-forward "| apples |")
              (setq pos (point)))     ; inside the Qty field
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "5"))
                      ((symbol-function 'eabp-shell-push) (lambda (&rest _)))
                      ((symbol-function 'eabp-shell-notify)
                       (lambda (text) (ert-fail text))))
              (funcall (gethash "org.table.edit" eabp-action-handlers)
                       `((file . ,file) (pos . ,pos)) nil)))
          (let ((content (with-temp-buffer
                           (insert-file-contents file) (buffer-string))))
            ;; Qty written, Cost recalculated by the formula.
            (should (string-match-p "| apples | +5 | +10 |" content))))
      (delete-file file))))

(ert-deftest glasspane-ui-table-add-row-and-column ()
  "add-row appends an empty row; add-col appends an empty column at the right."
  (let ((file (make-temp-file "eabp-table-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "| a | b |\n| c | d |\n"))
          (cl-letf (((symbol-function 'eabp-shell-push) (lambda (&rest _)))
                    ((symbol-function 'eabp-shell-notify)
                     (lambda (text) (ert-fail text))))
            (funcall (gethash "org.table.add-row" eabp-action-handlers)
                     `((file . ,file) (pos . 1)) nil)
            (funcall (gethash "org.table.add-col" eabp-action-handlers)
                     `((file . ,file) (pos . 1)) nil))
          (let* ((content (with-temp-buffer
                            (insert-file-contents file) (buffer-string)))
                 (lines (cl-remove-if-not
                         (lambda (l) (string-prefix-p "|" l))
                         (split-string content "\n" t))))
            (should (= (length lines) 3))           ; one row appended
            (dolist (l lines)
              (should (= (cl-count ?| l) 4)))       ; one column appended
            ;; The new column landed at the right edge, not the left.
            (should (string-match-p "\\`| a | b |" (car lines)))))
      (delete-file file))))

;; ─── Org babel: emitter and action ──────────────────────────────────────────

(ert-deftest glasspane-org-rich-src-block-run-header ()
  "Executable src blocks with file context grow a run header; others don't."
  (require 'ob-emacs-lisp)
  (let ((body "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"))
    ;; With context and a loaded language: column of header row + code.
    (let* ((node (car (glasspane-org-rich-body body nil "/tmp/t.org" 10)))
           (kids (alist-get 'children node)))
      (should (equal (alist-get 't node) "column"))
      (let* ((row-kids (alist-get 'children (aref kids 0)))
             (tap (alist-get 'on_tap (aref row-kids 2))))
        (should (equal (alist-get 'text (aref row-kids 0)) "emacs-lisp"))
        (should (equal (alist-get 'action tap) "org.babel.execute"))
        (should (integerp (alist-get 'pos (alist-get 'args tap)))))
      (should (equal (alist-get 't (aref kids 1)) "text")))
    ;; Without file context: plain highlighted code, no affordance.
    (should (equal (alist-get 't (car (glasspane-org-rich-body body nil)))
                   "text"))
    ;; A language this Emacs can't execute: plain code even with context.
    (should (equal (alist-get
                    't (car (glasspane-org-rich-body
                             "#+begin_src nosuchlang\nx\n#+end_src\n"
                             nil "/tmp/t.org" 10)))
                   "text"))))

(ert-deftest glasspane-ui-babel-execute-inserts-results ()
  "The org.babel.execute handler runs the block and saves its RESULTS."
  (require 'ob-emacs-lisp)
  (let ((file (make-temp-file "eabp-babel-test" nil ".org"))
        (org-confirm-babel-evaluate nil)
        notified)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Code\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"))
          (let (pos)
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (search-forward "#+begin_src")
              (setq pos (line-beginning-position)))
            (cl-letf (((symbol-function 'eabp-shell-push) (lambda (&rest _)))
                      ((symbol-function 'eabp-shell-notify)
                       (lambda (text) (setq notified text))))
              (funcall (gethash "org.babel.execute" eabp-action-handlers)
                       `((file . ,file) (pos . ,pos)) nil)))
          (should (equal notified "Block executed"))
          (let ((content (with-temp-buffer
                           (insert-file-contents file) (buffer-string))))
            (should (string-match-p "#\\+RESULTS:" content))
            (should (string-match-p "^: 3$" content))))
      (delete-file file))))

(ert-deftest glasspane-ui-babel-execute-honors-confirm ()
  "Declining the evaluation prompt aborts: no results, an error snackbar."
  (require 'ob-emacs-lisp)
  (let ((file (make-temp-file "eabp-babel-test" nil ".org"))
        (org-confirm-babel-evaluate t)
        notified)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                    ((symbol-function 'eabp-shell-push) (lambda (&rest _)))
                    ((symbol-function 'eabp-shell-notify)
                     (lambda (text) (setq notified text))))
            (funcall (gethash "org.babel.execute" eabp-action-handlers)
                     `((file . ,file) (pos . 1)) nil))
          (should (string-prefix-p "Run failed:" (or notified "")))
          (let ((content (with-temp-buffer
                           (insert-file-contents file) (buffer-string))))
            (should-not (string-match-p "#\\+RESULTS:" content))))
      (delete-file file))))

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

(ert-deftest glasspane-org-rich-drawer-renders-folded ()
  "Drawers render as collapsed sections instead of disappearing."
  (let* ((nodes (glasspane-org-rich-body
                 ":LOGBOOK:\n- Note taken\n:END:\nBody\n" nil))
         (drawer (car nodes)))
    (should (= (length nodes) 2))       ; drawer + body paragraph
    (should (equal (alist-get 't drawer) "collapsible"))
    (should (eq (alist-get 'collapsed drawer) t))
    (should (equal (alist-get 'text (alist-get 'header drawer)) "LOGBOOK"))
    (should (> (length (alist-get 'children drawer)) 0))))

(ert-deftest glasspane-org-reader-drawer-visibility ()
  "The reader shows heading drawers folded; the detail view (skip-props
path) suppresses the raw LOGBOOK drawer its structured section replaces."
  (let ((file (make-temp-file "eabp-drawer-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Task\n"
                    ":LOGBOOK:\n"
                    "CLOCK: [2026-07-03 Fri 10:00]--[2026-07-03 Fri 11:00] =>  1:00\n"
                    ":END:\n"
                    "Body text\n"))
          (let ((logbook-p (lambda (n)
                             (and (equal (alist-get 't n) "collapsible")
                                  (equal (alist-get 'text (alist-get 'header n))
                                         "LOGBOOK")))))
            (should (eabp-tests--find-node
                     (glasspane-org-reader-file file) logbook-p))
            (should-not (eabp-tests--find-node
                         (glasspane-org-reader-subtree file 1 t) logbook-p))))
      (when-let ((buf (find-buffer-visiting file))) (kill-buffer buf))
      (delete-file file))))

;; ─── Org case conventions ────────────────────────────────────────────────────
;; Keywords, blocks, and drawer delimiters may be lowercase in org files;
;; TODO keywords and tags are case-sensitive.  Recognition must not depend
;; on the ambient `case-fold-search'.

(ert-deftest glasspane-ui-table-edit-recalculates-lowercase-tblfm ()
  "A lowercase #+tblfm: line is as valid as #+TBLFM: for recalculation."
  (let ((file (make-temp-file "eabp-table-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "| Item   | Qty | Cost |\n"
                    "|--------+-----+------|\n"
                    "| apples |   2 |    4 |\n"
                    "#+tblfm: $3=$2*2\n"))
          (let (pos)
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (search-forward "| apples |")
              (setq pos (point)))
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "5"))
                      ((symbol-function 'eabp-shell-push) (lambda (&rest _)))
                      ((symbol-function 'eabp-shell-notify)
                       (lambda (text) (ert-fail text))))
              (funcall (gethash "org.table.edit" eabp-action-handlers)
                       `((file . ,file) (pos . ,pos)) nil)))
          (should (string-match-p
                   "| apples | +5 | +10 |"
                   (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (delete-file file))))

(ert-deftest glasspane-org-lowercase-drawer-and-clock ()
  "Lowercase :logbook:/:end:/clock: parse structurally and render folded."
  ;; Structured logbook parsing (detail view path).
  (with-temp-buffer
    (insert "* Task\n"
            ":logbook:\n"
            "clock: [2026-07-03 Fri 10:00]--[2026-07-03 Fri 11:00] =>  1:00\n"
            ":end:\n")
    (delay-mode-hooks (org-mode))
    (let ((entries (glasspane-ui--logbook-entries 1)))
      (should (= (length entries) 1))
      (should (eq (plist-get (car entries) :type) 'clock))))
  ;; Reader/detail rendering: folded in the reader, suppressed in detail.
  (let ((file (make-temp-file "eabp-drawer-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Task\n:logbook:\n- Note taken\n:end:\nBody\n"))
          (let ((logbook-p (lambda (n)
                             (and (equal (alist-get 't n) "collapsible")
                                  (equal (alist-get 'text (alist-get 'header n))
                                         "logbook")))))
            (should (eabp-tests--find-node
                     (glasspane-org-reader-file file) logbook-p))
            (should-not (eabp-tests--find-node
                         (glasspane-org-reader-subtree file 1 t) logbook-p))))
      (when-let ((buf (find-buffer-visiting file))) (kill-buffer buf))
      (delete-file file))))

;; ─── Demo org corpus ─────────────────────────────────────────────────────────

(ert-deftest glasspane-demo-org-corpus-is-valid ()
  "The demo org corpus writes, re-writes, parses, and exercises the
rich renderers (native table, babel run button)."
  (require 'ob-emacs-lisp)
  (let ((dir (make-temp-file "glasspane-demo-org" t)))
    (unwind-protect
        (progn
          (glasspane-demo-setup-org dir)
          (glasspane-demo-setup-org dir)  ; overwrite must not error
          (should (= (length glasspane-demo--org-files) 6))
          (dolist (spec glasspane-demo--org-files)
            (should (glasspane-org-reader-file
                     (expand-file-name (car spec) dir))))
          (should (eabp-tests--find-node
                   (glasspane-org-reader-file (expand-file-name "health.org" dir))
                   (lambda (n) (equal (alist-get 't n) "table"))))
          (should (eabp-tests--find-node
                   (glasspane-org-reader-file (expand-file-name "notes.org" dir))
                   (lambda (n)
                     (equal (alist-get 'action (alist-get 'on_tap n))
                            "org.babel.execute")))))
      (dolist (spec glasspane-demo--org-files)
        (when-let ((buf (find-buffer-visiting
                         (expand-file-name (car spec) dir))))
          (kill-buffer buf)))
      (delete-directory dir t))))

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
      (list (eabp-table-row (list (eabp-table-cell (list (eabp-span "a"))))))))))

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

(provide 'eabp-tests)
;;; eabp-tests.el ends here
