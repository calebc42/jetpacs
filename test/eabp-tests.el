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

(add-to-list 'load-path (expand-file-name "../emacs" eabp-tests--dir))

(require 'ert)
(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-org)
(require 'eabp-keymap)
(require 'eabp-magit)
(require 'eabp-files)
(require 'eabp-minibuffer)
(require 'eabp-org-ui)
(require 'eabp-emacs-ui)

;; ─── Capture ────────────────────────────────────────────────────────────────

(ert-deftest eabp-capture-fills-template ()
  "The filled capture template must be the one that actually runs."
  (let* ((file (make-temp-file "eabp-capture-test" nil ".org"))
         (org-capture-templates
          `(("t" "Task" entry (file ,file)
             "* TODO %^{Headline}\n%^{Notes|no notes}\n%?"))))
    (unwind-protect
        (progn
          (eabp-org--do-capture "t" '(("Headline" . "Buy milk")
                                      ("Notes" . "2% fat")))
          (let ((content (with-current-buffer (find-file-noselect file)
                           (buffer-string))))
            (should (string-search "* TODO Buy milk" content))
            (should (string-search "2% fat" content))
            (should-not (string-search "%^{" content))))
      (delete-file file))))

;; ─── Extraction cache ───────────────────────────────────────────────────────

(ert-deftest eabp-org-cache-memoises ()
  "Readers memoise until `eabp-org-cache-invalidate' drops the table."
  (let ((n 0))
    (cl-letf (((symbol-function 'eabp-org--todo-items-1)
               (lambda (_files) (setq n (1+ n)) '(fake))))
      (eabp-org-cache-invalidate)
      (eabp-org--todo-items)
      (eabp-org--todo-items)
      (should (= n 1))
      (eabp-org-cache-invalidate)
      (eabp-org--todo-items)
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
          (eabp-org-cache-invalidate)
          (should (cl-some (lambda (it)
                             (equal (alist-get 'headline it) "Water plants"))
                           (eabp-org--agenda-items 'day nil)))
          (should-not (get-buffer "*EABP Agenda*"))
          (should (equal (with-current-buffer "*Org Agenda*" (buffer-string))
                         "user content")))
      (delete-file file))))

(ert-deftest eabp-agenda-anchored-extraction ()
  "Navigation anchors actually change the extracted range."
  (let* ((file (make-temp-file "eabp-agenda-nav" nil ".org"))
         (tomorrow (eabp-org-ui--shift-date
                    (format-time-string "%Y-%m-%d") 1 'day)))
    (with-temp-file file
      (insert (format "* TODO Future thing\nSCHEDULED: <%s>\n" tomorrow)))
    (unwind-protect
        (let ((org-agenda-files (list file)))
          (eabp-org-cache-invalidate)
          (should-not (cl-some (lambda (it)
                                 (equal (alist-get 'headline it) "Future thing"))
                               (eabp-org--agenda-items 'day nil)))
          (should (cl-some (lambda (it)
                             (equal (alist-get 'headline it) "Future thing"))
                           (eabp-org--agenda-items 'day tomorrow))))
      (delete-file file))))

;; ─── Agenda date arithmetic & widgets ───────────────────────────────────────

(ert-deftest eabp-agenda-date-math ()
  (should (equal (eabp-org-ui--shift-date "2026-07-01" 1 'day) "2026-07-02"))
  (should (equal (eabp-org-ui--shift-date "2026-07-01" -1 'day) "2026-06-30"))
  (should (equal (eabp-org-ui--shift-date "2026-07-01" -1 'week) "2026-06-24"))
  (should (equal (eabp-org-ui--shift-date "2026-01-31" 1 'month) "2026-02-28"))
  (should (equal (eabp-org-ui--shift-date "2024-01-31" 1 'month) "2024-02-29"))
  (should (equal (eabp-org-ui--shift-date "2026-12-15" 1 'month) "2027-01-15"))
  (should (equal (eabp-org-ui--shift-date "2026-01-15" -1 'month) "2025-12-15")))

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
    (dolist (node (list (eabp-org-ui--agenda-card item)
                        (eabp-org-ui--agenda-card
                         '((headline . "Done thing") (todo . "DONE")))
                        (eabp-org-ui--agenda-nav-row "day" "2026-07-01")
                        (eabp-org-ui--agenda-nav-row "week" "2026-07-01")
                        (eabp-org-ui--agenda-nav-row "month" "2026-07-01")
                        (eabp-org-ui--agenda-month-view nil "2026-02-14")))
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
     (eabp-editor "f.org" "content" :on-save act :read-only t :syntax "org")
     (eabp-drawer (list (eabp-drawer-item "i" "l" act :selected t)) :header "h")
     (eabp-top-bar "t" :nav-icon "menu" :nav-action act :actions (list leaf))
     (eabp-fab "add" :label "l" :on-tap act :extended t)
     (eabp-bottom-bar (list (eabp-nav-item "i" "l" act :selected t)))
     (eabp-scaffold :top-bar (eabp-top-bar "t") :fab (eabp-fab "add")
                    :body leaf :bottom-bar (eabp-bottom-bar nil)
                    :snackbar "s" :drawer (eabp-drawer nil :header "h")))))

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
