;;; jetpacs-org.el --- Jetpacs Org-Mode Core Layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 calebc42 and contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Provides the unopinionated, primitive-first Org-mode extraction layer
;; for the Jetpacs foundation. Included are the query parser, the built-in
;; org-ql interpreter, heading identity mapping, and typed property extraction.
;;
;; This is the core engine for third-party Tier-1 apps (like Glasspane)
;; or declarative runtimes (like jetpacs-crud.el) to read and query org data.
;;
;; It also carries the org-opinionated stock surfaces: the capture
;; template builder (Settings → Capture Templates), which manages
;; `org-capture-templates' from the phone, and the Tier-1 org buffer
;; render skin (dividers, native tables, inline images, LaTeX preview
;; images over the faithful Tier-0 line render) — see the sections at
;; the bottom.  Those sections are why this module sits after the
;; shell/settings machinery in the bundle order; the extraction layer
;; above them stays UI-free.
;;
;; The query grammar is interpreted ONCE (`jetpacs-org--matches-p') over a
;; pluggable data accessor: `jetpacs-org-entry-matches-p' reads the org
;; entry at point, `jetpacs-org-note-matches-p' reads a `vulpea-note'
;; struct off the vulpea index.  vulpea is an OPTIONAL engine: nothing
;; here requires it at load, the note path is only entered when a caller
;; hands us a note, and `jetpacs-org-vulpea-available-p' is the probe.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-capture)
(require 'org-element)
(require 'org-footnote)
(require 'org-habit)
(require 'org-id)
(require 'org-table)
(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-settings)
(require 'jetpacs-buffer)     ; the Tier-0 line renderer the org skin rides
(require 'jetpacs-hypertext)  ; the content-addressed image cache

;; The vulpea note index is an optional engine (installed app-side or by
;; the composer's dependency bootstrap); these are compile-time stubs only.
(declare-function vulpea-note-id "vulpea-note")
(declare-function vulpea-note-path "vulpea-note")
(declare-function vulpea-note-title "vulpea-note")
(declare-function vulpea-note-todo "vulpea-note")
(declare-function vulpea-note-tags "vulpea-note")
(declare-function vulpea-note-priority "vulpea-note")
(declare-function vulpea-note-level "vulpea-note")
(declare-function vulpea-note-properties "vulpea-note")
(declare-function vulpea-note-scheduled "vulpea-note")
(declare-function vulpea-note-deadline "vulpea-note")
(declare-function vulpea-note-closed "vulpea-note")
(declare-function vulpea-note-outline-path "vulpea-note")
(declare-function vulpea-db-query "vulpea-db")
(declare-function vulpea-db-query-by-directory "vulpea-db")

;; ─── Cache layer ───────────────────────────────────────────────────────────────

(defvar jetpacs-org--cache (make-hash-table :test 'equal)
  "Memoised org extraction results.")

(defun jetpacs-org--files-mtime (files)
  "Return the maximum modification time of FILES (or 0 if none exist)."
  (let ((mtime 0.0))
    (dolist (file files)
      (when (file-exists-p file)
        (let* ((attrs (file-attributes (file-truename file)))
               (t-val (float-time (file-attribute-modification-time attrs))))
          (when (> t-val mtime)
            (setq mtime t-val)))))
    mtime))

(defun jetpacs-org--cache-key (namespace &rest parts)
  "Build a cache key from NAMESPACE and PARTS.
Scoped to today's date and the agenda files' mtime to automatically bust
the cache on external edits or date roll-over."
  (cons (format-time-string "%Y-%m-%d")
        (cons (jetpacs-org--files-mtime (org-agenda-files))
              (cons namespace parts))))

(defmacro jetpacs-org-with-cache (namespace key &rest body)
  "Memoise BODY's result in `jetpacs-org--cache' under NAMESPACE and KEY."
  (declare (indent 2))
  (let ((k (gensym "key")) (hit (gensym "hit")))
    `(let* ((,k (jetpacs-org--cache-key ,namespace ,key))
            (,hit (gethash ,k jetpacs-org--cache 'jetpacs-org--miss)))
       (if (eq ,hit 'jetpacs-org--miss)
           (puthash ,k (progn ,@body) jetpacs-org--cache)
         ,hit))))

(defun jetpacs-org-cache-invalidate (&optional namespace)
  "Drop memoised org extractions.
If NAMESPACE is provided, only clear entries matching it. Otherwise clear all."
  (if namespace
      (maphash (lambda (k _v)
                 ;; k is (date mtime namespace . parts)
                 (when (equal (nth 2 k) namespace)
                   (remhash k jetpacs-org--cache)))
               jetpacs-org--cache)
    (clrhash jetpacs-org--cache)))

;; ─── Heading references ────────────────────────────────────────────────────────

(defun jetpacs-org-heading-ref ()
  "Build a location ref for the org heading at point.
Returns an alist with `file'/`pos'/`headline', plus `id' when the entry
already has an ID property. This reference is stable for JSON serialization
and round-trips over the wire."
  (save-excursion
    (unless (org-at-heading-p)
      (ignore-errors (org-back-to-heading t)))
    (let ((id (org-entry-get nil "ID"))
          (ref `((file . ,(or (buffer-file-name) ""))
                 (pos . ,(point))
                 (headline . ,(or (nth 4 (org-heading-components)) "")))))
      (if (and (stringp id) (not (string-empty-p id)))
          (cons `(id . ,id) ref)
        ref))))

(defun jetpacs-org-resolve-ref (ref)
  "Resolve REF to a live marker at its org heading, or signal an error.
REF is an alist as built by `jetpacs-org-heading-ref'. Resolution tries:
1. the stable `id' (survives edits anywhere)
2. the recorded `pos' (trusted only if its headline still matches)
3. a headline search through the file."
  (let ((id (alist-get 'id ref))
        (file (alist-get 'file ref))
        (pos (alist-get 'pos ref))
        (headline (alist-get 'headline ref)))
    ;; A whole-valued `pos' can return from the wire as a float (org.json
    ;; emits the trailing .0 — the same case `jetpacs--confirm-normalize'
    ;; guards); coerce so the trusted-position fast-path below survives the
    ;; round trip instead of falling through to the headline search (which
    ;; would resolve the wrong heading among duplicate titles).
    (when (numberp pos) (setq pos (truncate pos)))
    (or
     (and (stringp id) (not (string-empty-p id))
          (ignore-errors (org-id-find id 'marker)))
     (and (stringp file) (file-readable-p file)
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (org-with-wide-buffer
               (when (and (integerp pos) (<= (point-min) pos (point-max)))
                 (goto-char pos)
                 (when (ignore-errors (org-back-to-heading t) t)
                   (when (or (not (stringp headline)) (string-empty-p headline)
                             (equal (nth 4 (org-heading-components)) headline))
                     (copy-marker (point)))))))))
     (and (stringp file) (file-readable-p file)
          (stringp headline) (not (string-empty-p headline))
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (org-with-wide-buffer
               (goto-char (point-min))
               (catch 'found
                 (while (re-search-forward org-heading-regexp nil t)
                   (when (equal (nth 4 (org-heading-components)) headline)
                     (throw 'found (copy-marker (line-beginning-position)))))
                 nil)))))
     (error "Heading not found: %s"
            (or headline id file "?")))))

;; ─── Query Parser ──────────────────────────────────────────────────────────────

(defconst jetpacs-org-ql-literals '(today nil t < <= > >= =)
  "Symbols with meaning to org-ql that normalization must not stringify.")

(defun jetpacs-org--normalize-ql-arg (arg)
  "Normalize ARG, a clause argument inside a sexp query."
  (cond
   ((and (consp arg) (eq (car arg) 'quote) (cdr arg))
    (jetpacs-org--normalize-ql-arg (cadr arg)))
   ((consp arg) (jetpacs-org--normalize-ql arg))
   ((keywordp arg) arg)
   ((memq arg jetpacs-org-ql-literals) arg)
   ((symbolp arg) (symbol-name arg))
   (t arg)))

(defun jetpacs-org--normalize-ql (form)
  "Return sexp query FORM with elisp-isms rewritten to org-ql shape.
Quotes are unwrapped and bare symbols in argument positions become strings."
  (if (and (consp form) (eq (car form) 'quote) (cdr form))
      (jetpacs-org--normalize-ql (cadr form))
    (if (not (consp form))
        form
      (cons (car form)
            (mapcar #'jetpacs-org--normalize-ql-arg (cdr form))))))

(defun jetpacs-org--query-tokens (q)
  "Split query Q on whitespace, keeping \"quoted phrases\" whole."
  (let ((pos 0) (tokens nil))
    (while (string-match "\"\\([^\"]*\\)\"\\|\\S-+" q pos)
      (push (or (match-string 1 q) (match-string 0 q)) tokens)
      (setq pos (match-end 0)))
    (nreverse tokens)))

(defun jetpacs-org-parse-query (query)
  "Parse the search QUERY string into an org-ql sexp, or nil if empty.
Accepts three input shapes:
- an org-ql sexp:  (and (todo \"TODO\") (tags \"work\"))
- filter tokens:   todo:TODO,NEXT tags:work priority:A
- free text:       \"exact phrase\" or bare words
Signals `user-error' on a malformed sexp."
  (let ((q (string-trim (or query ""))))
    (cond
     ((string-empty-p q) nil)
     ((string-match-p "\\`'?(" q)
      (let ((form (condition-case nil (read q)
                    (error (user-error "Query has unbalanced parentheses: %s" q)))))
        (jetpacs-org--normalize-ql form)))
     (t
      (let ((clauses
             (mapcar
              (lambda (tok)
                (cond
                 ((string-prefix-p "todo:" tok)
                  `(todo ,@(split-string (substring tok 5) "," t)))
                 ((string-prefix-p "tags:" tok)
                  `(tags ,@(split-string (substring tok 5) "," t)))
                 ((string-prefix-p "priority:" tok)
                  `(priority ,@(split-string (substring tok 9) "," t)))
                 (t `(regexp ,(regexp-quote tok)))))
              (jetpacs-org--query-tokens q))))
        (if (cdr clauses) `(and ,@clauses) (car clauses)))))))

;; ─── Built-in Query Interpreter ────────────────────────────────────────────────

(defun jetpacs-org--planning-day (spec)
  "Resolve a query date SPEC to an absolute day number."
  (cond
   ((eq spec 'today) (time-to-days (current-time)))
   ((integerp spec) (+ (time-to-days (current-time)) spec))
   ((stringp spec) (time-to-days (org-time-string-to-time spec)))
   (t (user-error "Unsupported query date %S" spec))))

(defun jetpacs-org--planning-match-spec (stamp args)
  "Match raw planning STAMP string against ARGS plist (:on / :from / :to).
Empty ARGS means mere presence of the stamp."
  (and (stringp stamp) (not (string-empty-p stamp))
       (let ((day (time-to-days (org-time-string-to-time stamp)))
             (on (plist-get args :on))
             (from (plist-get args :from))
             (to (plist-get args :to)))
         (and (or (not on) (equal day (jetpacs-org--planning-day on)))
              (or (not from) (>= day (jetpacs-org--planning-day from)))
              (or (not to) (<= day (jetpacs-org--planning-day to)))))))

(defun jetpacs-org--planning-match-p (which args)
  "Match the WHICH (\"SCHEDULED\"/\"DEADLINE\") stamp at point against ARGS."
  (jetpacs-org--planning-match-spec (org-entry-get (point) which) args))

(defun jetpacs-org--entry-priority ()
  "The priority character of the heading at point, or nil."
  (save-excursion (org-back-to-heading t) (nth 3 (org-heading-components))))

(defun jetpacs-org--matches-p (tree get)
  "Non-nil when the entry read through accessor GET matches org-ql sexp TREE.
The ONE interpreter of the built-in query grammar.  GET is
\(funcall GET WHAT &rest ARGS) with WHAT one of:
  todo            -> the TODO keyword string, or nil
  done            -> non-nil when the entry counts as done
  tags            -> the entry's tag list
  priority        -> the priority character, or nil
  title           -> the headline/title string, or nil
  level           -> the outline level integer, or nil
  property NAME   -> the property's string value, or nil
  planning WHICH  -> the raw SCHEDULED/DEADLINE stamp string, or nil
  regexp-match RE -> non-nil when RE hits the entry's haystack
Signals `user-error' on unsupported terms."
  (pcase tree
    (`(and . ,cs) (cl-every (lambda (c) (jetpacs-org--matches-p c get)) cs))
    (`(or . ,cs) (and (cl-some (lambda (c) (jetpacs-org--matches-p c get)) cs) t))
    (`(not ,c) (not (jetpacs-org--matches-p c get)))
    (`(todo . ,kws)
     (let ((st (funcall get 'todo)))
       (and st (if kws (and (member st kws) t)
                 (not (funcall get 'done))))))
    (`(done) (and (funcall get 'done) t))
    (`(tags . ,tags)
     (let ((have (funcall get 'tags)))
       (if tags (and (cl-some (lambda (tg) (member tg have)) tags) t)
         (and have t))))
    (`(priority ,(and op (pred symbolp)) ,val)
     (let ((pr (funcall get 'priority))
           (want (if (stringp val) (string-to-char val) val)))
       ;; org urgency runs A > B > C — the higher priority is the smaller
       ;; character, so the comparator flips against the chars.
       (and pr (pcase op
                 ('< (> pr want)) ('<= (>= pr want))
                 ('> (< pr want)) ('>= (<= pr want))
                 ('= (= pr want))
                 (_ (user-error "Unsupported priority comparator %s" op))))))
    (`(priority . ,ps)
     (let ((pr (funcall get 'priority)))
       (if ps (and pr (member (char-to-string pr) ps) t)
         (and pr t))))
    (`(heading . ,texts)
     (let ((hl (or (funcall get 'title) ""))
           (case-fold-search t))
       (cl-every (lambda (s) (string-match-p (regexp-quote s) hl)) texts)))
    (`(regexp . ,res)
     (cl-every (lambda (re) (funcall get 'regexp-match re)) res))
    (`(property ,name . ,val)
     (let ((v (funcall get 'property name)))
       (if val (equal v (car val)) (and v t))))
    (`(level ,n) (eql (funcall get 'level) n))
    (`(level ,n ,m) (let ((l (funcall get 'level))) (and l (<= n l m))))
    (`(scheduled . ,args)
     (jetpacs-org--planning-match-spec (funcall get 'planning "SCHEDULED") args))
    (`(deadline . ,args)
     (jetpacs-org--planning-match-spec (funcall get 'planning "DEADLINE") args))
    (`(habit) (and (funcall get 'habit) t))
    (_ (user-error "Query term %S needs the org-ql package installed" tree))))

(defun jetpacs-org--point-get (what &rest args)
  "The grammar accessor over the org entry AT POINT."
  (pcase what
    ('todo (org-get-todo-state))
    ('done (let ((st (org-get-todo-state)))
             (and st (member st org-done-keywords) t)))
    ('tags (org-get-tags nil t))
    ('priority (jetpacs-org--entry-priority))
    ('title (nth 4 (org-heading-components)))
    ('level (org-current-level))
    ('property (org-entry-get (point) (car args)))
    ('planning (org-entry-get (point) (car args)))
    ;; `org-is-habit-p' tests only the STYLE=habit property (whether the
    ;; SCHEDULED repeater is valid is enforced later, by
    ;; `org-habit-parse-todo').
    ('habit (org-is-habit-p))
    ('regexp-match
     ;; The point haystack is the entry's body up to the next heading.
     (let ((end (save-excursion (outline-next-heading) (point)))
           (case-fold-search t))
       (save-excursion (re-search-forward (car args) end t))))))

(defun jetpacs-org--note-get (note what &rest args)
  "The grammar accessor over a `vulpea-note' NOTE (index only, no file visit)."
  (pcase what
    ('todo (vulpea-note-todo note))
    ;; The index does not record a file's per-file DONE keyword set, so
    ;; done-ness is approximated: a global done keyword (falling back to
    ;; the near-universal \"DONE\" when `org-done-keywords' is unset, as
    ;; it is in a headless scan) or a CLOSED stamp.  Exotic per-file done
    ;; keywords need the org-ql arm.
    ('done (let ((s (vulpea-note-todo note)))
             (or (and s (member s (or org-done-keywords '("DONE"))) t)
                 (and (vulpea-note-closed note) t))))
    ('tags (vulpea-note-tags note))
    ;; vulpea priority may be a char (org's native form) or a string.
    ('priority (let ((p (vulpea-note-priority note)))
                 (cond ((null p) nil)
                       ((characterp p) p)
                       ((and (stringp p) (> (length p) 0)) (aref p 0))
                       (t (let ((s (format "%s" p)))
                            (and (> (length s) 0) (aref s 0)))))))
    ('title (vulpea-note-title note))
    ('level (vulpea-note-level note))
    ;; vulpea indexes drawer keys upper-cased; match case-insensitively.
    ('property (cdr (assoc-string (car args) (vulpea-note-properties note) t)))
    ('planning (let ((s (if (equal (car args) "DEADLINE")
                            (vulpea-note-deadline note)
                          (vulpea-note-scheduled note))))
                 (and (stringp s) s)))
    ;; STYLE=habit off the index — the same property `org-is-habit-p'
    ;; tests at point.
    ('habit (equal "habit"
                   (cdr (assoc-string "STYLE" (vulpea-note-properties note) t))))
    ('regexp-match
     ;; The index haystack is title + properties — the body is not
     ;; indexed.  SEMANTIC DIFFERENCE from the point accessor, by design.
     (let ((hay (concat (or (vulpea-note-title note) "") " "
                        (mapconcat #'cdr (vulpea-note-properties note) " ")))
           (case-fold-search t))
       (string-match-p (car args) hay)))))

(defun jetpacs-org-entry-matches-p (tree)
  "Non-nil when the org entry at point matches org-ql sexp TREE.
This is the built-in fallback interpreter implementing the common subset
of org-ql. Signals `user-error' on unsupported terms."
  (jetpacs-org--matches-p tree #'jetpacs-org--point-get))

(defun jetpacs-org-note-matches-p (tree note)
  "Non-nil when `vulpea-note' NOTE matches org-ql sexp TREE.
The same grammar as `jetpacs-org-entry-matches-p', evaluated entirely
off the vulpea index (no file visit).  Note the `regexp' term searches
title + properties here (the body is not indexed).  Signals `user-error'
on terms outside `jetpacs-org-note-query-terms' — check
`jetpacs-org-note-query-supported-p' first to route those to org-ql."
  (jetpacs-org--matches-p
   tree (lambda (what &rest args) (apply #'jetpacs-org--note-get note what args))))

(defconst jetpacs-org-note-query-terms
  '(and or not todo done tags priority heading regexp property level
        scheduled deadline habit)
  "org-ql head symbols the built-in grammar evaluates off the note index.")

(defun jetpacs-org-note-query-supported-p (tree)
  "Non-nil when org-ql sexp TREE uses only index-evaluable terms.
Empty (nil) TREE — no filter — is trivially supported."
  (pcase tree
    ('nil t)
    (`(and . ,cs) (cl-every #'jetpacs-org-note-query-supported-p cs))
    (`(or . ,cs) (cl-every #'jetpacs-org-note-query-supported-p cs))
    (`(not ,c) (jetpacs-org-note-query-supported-p c))
    (`(,head . ,_) (and (memq head jetpacs-org-note-query-terms) t))
    (_ nil)))

;; ─── High-Level Query ──────────────────────────────────────────────────────────

(defun jetpacs-org--search-fallback (tree action)
  "Run parsed query TREE over the agenda files without org-ql.
Calls ACTION at each matching heading."
  (let (items)
    (org-map-entries
     (lambda ()
       (when (jetpacs-org-entry-matches-p tree)
         (push (funcall action) items)))
     nil 'agenda)
    (nreverse items)))

(defun jetpacs-org-query (namespace tree action)
  "Run parsed query sexp TREE over the agenda files, calling ACTION at matches.
Results are cached under NAMESPACE. Automatically dispatches to `org-ql-select'
if available, otherwise falls back to the built-in interpreter."
  (when tree
    (jetpacs-org-with-cache namespace (format "%S" tree)
      (if (fboundp 'org-ql-select)
          (condition-case err
              (org-ql-select (org-agenda-files) tree
                             :action action)
            (user-error (signal (car err) (cdr err)))
            (error (user-error "Query failed: %s" (error-message-string err))))
        (jetpacs-org--search-fallback tree action)))))

;; ─── Vulpea note index (optional engine) ──────────────────────────────────────

(defun jetpacs-org-vulpea-available-p ()
  "Non-nil when the vulpea note index is loadable on this Emacs.
vulpea is never required by the core; apps or the composer's dependency
bootstrap install it, and callers gate their index reads on this probe."
  (and (require 'vulpea nil t) (fboundp 'vulpea-db-query) t))

(defun jetpacs-org-vulpea-source-notes (source)
  "The `vulpea-note' records backing SOURCE, a scope plist.
SOURCE is one of:
  (:dir D)               -> the file-level notes of vault directory D
                            (one note file per record);
  (:file F :heading H)   -> the id'd headings directly under H in F;
  (:file F)              -> the id'd level-1 headings of F.
Headings must already carry `:ID:' properties for the index to see them.
Callers gate on `jetpacs-org-vulpea-available-p'."
  (let ((dir (plist-get source :dir))
        (file (plist-get source :file))
        (heading (plist-get source :heading)))
    (cond
     (dir (vulpea-db-query-by-directory (directory-file-name dir) 0))
     (file
      (let ((want (expand-file-name file)))
        (vulpea-db-query
         (lambda (n)
           (and (equal (expand-file-name (vulpea-note-path n)) want)
                (if heading
                    (equal (vulpea-note-outline-path n) (list heading))
                  (= (vulpea-note-level n) 1)))))))
     (t (user-error "Source needs :dir or :file: %S" source)))))

(defun jetpacs-org-vulpea-query (source &optional tree)
  "Notes of SOURCE matching org-ql sexp TREE, off the vulpea index.
A nil TREE admits every note of the scope.  TREE must stay inside
`jetpacs-org-note-query-terms' (see `jetpacs-org-note-query-supported-p');
route anything else through org-ql over the source file instead."
  (let ((notes (jetpacs-org-vulpea-source-notes source)))
    (if tree
        (cl-remove-if-not (lambda (n) (jetpacs-org-note-matches-p tree n)) notes)
      notes)))

;; ─── Mutations ─────────────────────────────────────────────────────────────────

(defun jetpacs-org-defer-save ()
  "Schedule a save for the current buffer during the next idle moment."
  (let ((buf (current-buffer)))
    (run-with-idle-timer 0.5 nil
      (lambda ()
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (buffer-modified-p)
              (save-buffer))))))))

(defmacro jetpacs-org-with-mutation (ref namespace &rest body)
  "Resolve REF, execute BODY at its heading, bust cache NAMESPACE, and defer save."
  (declare (indent 2))
  `(let ((marker (jetpacs-org-resolve-ref ,ref)))
     (with-current-buffer (marker-buffer marker)
       (save-excursion
         (goto-char marker)
         (prog1 (progn ,@body)
           (jetpacs-org-cache-invalidate ,namespace)
           (jetpacs-org-defer-save))))))

(defun jetpacs-org-set-property (ref namespace prop value)
  "Set PROP to VALUE on the heading at REF."
  (jetpacs-org-with-mutation ref namespace
    (org-entry-put (point) prop value)))

(defun jetpacs-org-toggle-todo (ref namespace &optional state)
  "Set the TODO state at REF to STATE, or toggle if nil.
Flushes org's state/repeat log note inline.  `org-todo' queues that note
onto `post-command-hook' (via `org-add-log-setup'), which never fires
here: a phone action runs inside the socket process filter, not the
command loop.  Left deferred, the \"State DONE ... [ts]\" LOGBOOK line is
never written — so `org-habit-done-dates' (which reads only that line)
would never see a habit completion, and the pending note could later pop
*Org Note* on a shared interactive Emacs.  `save-window-excursion'
contains the buffer switches `org-add-log-note' makes; the `time'/`state'
note stores immediately and needs no input."
  (jetpacs-org-with-mutation ref namespace
    (org-todo state)
    (when (bound-and-true-p org-log-setup)
      (save-window-excursion
        (let ((this-command org-log-note-this-command))
          (org-add-log-note))))))

(defun jetpacs-org-set-planning (ref namespace which date-str)
  "Set the WHICH planning stamp at REF to DATE-STR.
WHICH is \"SCHEDULED\" or \"DEADLINE\"; an empty or nil DATE-STR removes
the stamp.  `org-add-planning-info' wants the planning type as a symbol
\(scheduled/deadline), and removal is expressed as a trailing remove arg
with no time — the string form and the nonexistent
`org-remove-planning-info' both signalled."
  (let ((type (pcase (upcase (or which ""))
                ("SCHEDULED" 'scheduled)
                ("DEADLINE" 'deadline)
                (_ (user-error "Unsupported planning type: %s" which)))))
    (jetpacs-org-with-mutation ref namespace
      (if (or (null date-str) (string-empty-p date-str))
          (org-add-planning-info nil nil type)
        (org-add-planning-info type date-str)))))

;; ─── Typed extraction ──────────────────────────────────────────────────────────

(defun jetpacs-org-entry-typed-value (prop type)
  "Extract the value of PROP at point according to TYPE.
TYPE is one of `text', `checkbox', `date', `enum', `number', `list'."
  (let ((val (org-entry-get (point) prop)))
    (pcase type
      ('checkbox (equal val "[X]"))
      ('date (and val (not (string-empty-p val)) val))
      ('number (and val (string-to-number val)))
      ('enum
       ;; If there's an allowed values constraint (PROP_ALL), enforce it.
       (let ((allowed (org-entry-get (point) (concat prop "_ALL") t)))
         (if allowed
             (let ((options (split-string allowed "[ \t]+" t)))
               (if (member val options) val nil))
           (and val (not (string-empty-p val)) val))))
      ('list
       (and val (split-string val "[, \t]+" t)))
      (_ (or val "")))))

;; ─── Capture template management ──────────────────────────────────────────────
;;
;; Create, edit, and remove `org-capture-templates' entries from the phone.
;; The same live-form pattern as Glasspane's search query builder: collapsible
;; sections of structured controls (destination, status, tags, prompts,
;; includes) that regenerate the raw template string on every change, with
;; the string itself staying hand-editable for anything the builder doesn't
;; speak — the builder doubles as a worked example of the template escapes.
;;
;; Two satellite screens, reached from the settings screen's Emacs section
;; (beside Modus Themes and Customize):
;;
;;   "org-templates"      — the hub: a card per template with edit/delete,
;;                          plus the new-template button.
;;   "org-template-edit"  — the builder, gated (:when/:overlay) on an open
;;                          editing session like a detail drill-in.
;;
;; Persistence rides Customize (`jetpacs-settings-save-variable' on
;; `org-capture-templates'), so managed edits and deletions survive a
;; restart, while templates defined in init.el after the custom-file load
;; still win by running later.  Entries the builder can't represent stay
;; safe: a non-string template (a function) is listed but not editable; an
;; exotic target (id, clock, function) or a non-`entry' type is preserved
;; verbatim on save — the builder only rewrites what its controls own.

(defvar jetpacs-org--captpl-editing nil
  "Non-nil while the template builder screen is open.
The symbol `new' for a fresh template, else the key string being edited.")

(defvar jetpacs-org--captpl-entry nil
  "The original `org-capture-templates' entry being edited, or nil.
Kept so a save preserves what the builder doesn't own: the entry type,
an unsupported target form, and the trailing property plist.")

(defconst jetpacs-org--captpl-timestamps '("None" "Inactive (%U)" "Active (%T)")
  "Choices for the builder's timestamp control, in resting-first order.")

(defun jetpacs-org-capture-template-prompts (template-string)
  "Return the ordered field names TEMPLATE-STRING asks for at capture.
Each `%^{NAME}' or `%^{NAME|default}' contributes NAME (the default is
dropped from the label).  A `%?' body position adds a leading
\"Headline\" field.  Duplicates are removed.  This is the schema a
capture form derives from a template — apps build their fill dialogs
from it."
  (let (prompts (start 0))
    (while (string-match "%\\^{\\([^}]+\\)}" template-string start)
      ;; Capture the match BEFORE `split-string' runs — it calls
      ;; `string-match' internally and would clobber the match data.
      (let ((spec (match-string 1 template-string))
            (end (match-end 0)))
        (push (string-trim (car (split-string spec "|"))) prompts)
        (setq start end)))
    (setq prompts (nreverse prompts))
    (delete-dups
     (if (string-match-p "%\\?" template-string)
         (cons "Headline" prompts)
       prompts))))

;; ── Model: state ⇄ template string

(defun jetpacs-org--captpl-flag (id)
  "The UI-state value of switch ID as a boolean.
Switch values arrive as JSON booleans; `:false' must read as nil."
  (let ((v (jetpacs-ui-state id)))
    (and v (not (eq v :false)) (not (equal v "false")))))

(defun jetpacs-org--captpl-todo-keywords ()
  "Flat list of the global TODO keywords, fast-access keys stripped."
  (let (kws)
    (dolist (seq (default-value 'org-todo-keywords))
      (dolist (w (cdr seq))
        (unless (equal w "|")
          (push (if (string-match "\\`\\([[:alnum:]_-]+\\)" w)
                    (match-string 1 w)
                  w)
                kws))))
    (nreverse kws)))

(defun jetpacs-org--captpl-known-tags ()
  "Tag name candidates for the builder, from `org-tag-alist'."
  (delete-dups
   (delq nil (mapcar (lambda (x)
                       (cond ((stringp x) x)
                             ((and (consp x) (stringp (car x))) (car x))))
                     org-tag-alist))))

(defun jetpacs-org--captpl-build-template ()
  "Build an org capture template string from the captpl-* builder state.
The headline is the `%?' body position (so a capture form asks for it
as \"Headline\"), each extra prompt becomes a `NAME: %^{NAME}' line,
and the include toggles contribute their escape lines."
  (let* ((todo (car (jetpacs-ui-state-list "captpl-todo")))
         (tags (jetpacs-ui-state-list "captpl-tags"))
         (prompts (jetpacs-ui-state-list "captpl-prompts"))
         (ts (car (jetpacs-ui-state-list "captpl-timestamp")))
         (lines
          (list (concat "* "
                        (and todo (not (equal todo "None")) (concat todo " "))
                        "%?"
                        (and tags (concat " :" (string-join tags ":") ":"))))))
    (dolist (p prompts)
      (push (concat p ": %^{" p "}") lines))
    (pcase ts
      ("Inactive (%U)" (push "%U" lines))
      ("Active (%T)" (push "%T" lines)))
    (when (jetpacs-org--captpl-flag "captpl-link")
      (push "%a" lines))
    (when (jetpacs-org--captpl-flag "captpl-initial")
      (push "%i" lines))
    (string-join (nreverse lines) "\n")))

(defun jetpacs-org--captpl-template-fields (tmpl)
  "Best-effort structured fields recovered from template string TMPL.
Returns an alist with `todo', `tags', `timestamp', `link', `initial',
and `prompts' — the inverse of `jetpacs-org--captpl-build-template' for
templates it generated, and a useful approximation for hand-written
ones.  Only globally-known TODO keywords are recognized as states."
  (let* ((first-line (car (split-string tmpl "\n")))
         (todo (and (string-match "\\`\\*+ +\\([[:alnum:]_-]+\\)\\( \\|\\'\\)"
                                  first-line)
                    (let ((word (match-string 1 first-line)))
                      (car (member word (jetpacs-org--captpl-todo-keywords))))))
         (tags (and (string-match ":\\([[:alnum:]_@#%:]+\\):[ \t]*\\'" first-line)
                    (split-string (match-string 1 first-line) ":" t))))
    `((todo . ,todo)
      (tags . ,tags)
      (timestamp . ,(cond ((string-match-p "%U" tmpl) "Inactive (%U)")
                          ((string-match-p "%T" tmpl) "Active (%T)")
                          (t "None")))
      (link . ,(and (string-match-p "%a" tmpl) t))
      (initial . ,(and (string-match-p "%i" tmpl) t))
      (prompts . ,(remove "Headline"
                          (jetpacs-org-capture-template-prompts tmpl))))))

;; ── Model: destinations

(defun jetpacs-org--captpl-display-file (file)
  "FILE as the destination picker shows it: relative to `org-directory'."
  (let ((dir (file-name-as-directory (expand-file-name org-directory)))
        (file (expand-file-name file)))
    (if (string-prefix-p dir file)
        (substring file (length dir))
      (abbreviate-file-name file))))

(defun jetpacs-org--captpl-absolute-file (file)
  "The picker value FILE as an absolute path (relative means org-directory)."
  (expand-file-name file org-directory))

(defun jetpacs-org--captpl-org-files ()
  "Destination candidates: the notes file, org-directory files, agenda files."
  (delete-dups
   (mapcar #'jetpacs-org--captpl-display-file
           (delq nil
                 (append (list org-default-notes-file)
                         (ignore-errors
                           (directory-files (expand-file-name org-directory)
                                            t "\\.org\\'"))
                         (ignore-errors (org-agenda-files)))))))

(defun jetpacs-org--captpl-target-file (f)
  "Resolve a capture target's file element F to a display path, or nil."
  (cond ((stringp f) (jetpacs-org--captpl-display-file f))
        ((and (symbolp f) (boundp f) (stringp (symbol-value f)))
         (jetpacs-org--captpl-display-file (symbol-value f)))))

(defun jetpacs-org--captpl-target-fields (target)
  "Best-effort (FILE . HEADLINE) from capture TARGET, or nil if unsupported.
FILE is picker-relative; HEADLINE is nil for a plain file target, and an
olp joins its components with \"/\".  A symbol file (templates often use
`org-default-notes-file') resolves through its value."
  (pcase target
    (`(file ,f)
     (when-let ((f (jetpacs-org--captpl-target-file f)))
       (cons f nil)))
    (`(file+headline ,f ,h)
     (when-let ((f (jetpacs-org--captpl-target-file f)))
       (and (stringp h) (cons f h))))
    (`(file+olp ,f . ,olp)
     (when-let ((f (jetpacs-org--captpl-target-file f)))
       (and olp (cl-every #'stringp olp)
            (cons f (string-join olp "/")))))))

(defun jetpacs-org--captpl-target-summary (entry)
  "One-line destination summary for template ENTRY's hub card."
  (let ((tf (and (> (length entry) 3)
                 (jetpacs-org--captpl-target-fields (nth 3 entry)))))
    (cond ((and tf (cdr tf)) (format "%s → %s" (car tf) (cdr tf)))
          (tf (car tf))
          ((> (length entry) 3) "custom target")
          (t "template group"))))

;; ── Builder state seeding

(defun jetpacs-org--captpl-seed-fields (fields)
  "Write reverse-parsed FIELDS into the captpl-* builder state."
  (jetpacs-ui-state-put "captpl-todo" (or (alist-get 'todo fields) "None"))
  (jetpacs-ui-state-put "captpl-tags" (vconcat (alist-get 'tags fields)))
  (jetpacs-ui-state-put "captpl-prompts" (vconcat (alist-get 'prompts fields)))
  (jetpacs-ui-state-put "captpl-timestamp" (alist-get 'timestamp fields))
  (jetpacs-ui-state-put "captpl-link" (and (alist-get 'link fields) t))
  (jetpacs-ui-state-put "captpl-initial" (and (alist-get 'initial fields) t)))

(defun jetpacs-org--captpl-seed-new ()
  "Seed the builder state for a fresh template (a plain inbox todo's shape)."
  (jetpacs-ui-state-clear "captpl-")
  (jetpacs-ui-state-put "captpl-file"
                        (jetpacs-org--captpl-display-file org-default-notes-file))
  (jetpacs-ui-state-put "captpl-timestamp" "Inactive (%U)")
  (jetpacs-ui-state-put "captpl-initial" t)
  (jetpacs-ui-state-put "captpl-template" (jetpacs-org--captpl-build-template)))

(defun jetpacs-org--captpl-seed-edit (entry)
  "Seed the builder state from an existing template ENTRY.
The raw template string is kept verbatim; the structured controls get
the best-effort reverse parse of it."
  (jetpacs-ui-state-clear "captpl-")
  (jetpacs-ui-state-put "captpl-key" (nth 0 entry))
  (jetpacs-ui-state-put "captpl-description" (nth 1 entry))
  (when-let ((tf (jetpacs-org--captpl-target-fields (nth 3 entry))))
    (jetpacs-ui-state-put "captpl-file" (car tf))
    (jetpacs-ui-state-put "captpl-headline" (or (cdr tf) "")))
  (let ((tmpl (nth 4 entry)))
    (jetpacs-org--captpl-seed-fields (jetpacs-org--captpl-template-fields tmpl))
    (jetpacs-ui-state-put "captpl-template" tmpl)))

;; ── The builder screen

(defun jetpacs-org--captpl-section (key label summary widgets)
  "One collapsible builder section, header carrying the active SUMMARY.
The same shape as Glasspane's query-builder sections: a folded section
still reads as a summary of what it contributes."
  (jetpacs-collapsible
   (concat "captpl-sec-" key)
   (if summary
       (jetpacs-rich-text (list (jetpacs-span (concat label ": ") :bold t)
                                (jetpacs-span summary))
                          :style 'body)
     (jetpacs-text label 'body))
   widgets
   :collapsed t))

(defun jetpacs-org--captpl-prompts-caption ()
  "The live \"what capture asks for\" line under the template field."
  (let* ((tmpl (or (jetpacs-ui-state "captpl-template") ""))
         (prompts (and (stringp tmpl)
                       (jetpacs-org-capture-template-prompts tmpl))))
    (if prompts
        (format "At capture, this asks for: %s."
                (string-join prompts ", "))
      "No prompts — add %? or a %^{Field} to ask for input at capture.")))

(defun jetpacs-org--captpl-builder-card ()
  "The structured-controls card: destination, status, tags, prompts, includes."
  (let* ((file-val (or (car (jetpacs-ui-state-list "captpl-file")) ""))
         (headline-val (or (jetpacs-ui-state "captpl-headline") ""))
         (todo-val (or (car (jetpacs-ui-state-list "captpl-todo")) "None"))
         (tags-list (jetpacs-ui-state-list "captpl-tags"))
         (prompts-list (jetpacs-ui-state-list "captpl-prompts"))
         (ts-val (or (car (jetpacs-ui-state-list "captpl-timestamp")) "None"))
         (link (jetpacs-org--captpl-flag "captpl-link"))
         (initial (jetpacs-org--captpl-flag "captpl-initial"))
         (orig jetpacs-org--captpl-entry)
         (custom-target (and orig
                             (not (jetpacs-org--captpl-target-fields
                                   (nth 3 orig)))))
         (includes (delq nil (list (unless (equal ts-val "None") "timestamp")
                                   (and link "link")
                                   (and initial "shared text")))))
    (jetpacs-card
     (list
      (jetpacs-org--captpl-section
       "target" "Destination"
       (cond (custom-target "custom (kept as-is)")
             ((string-empty-p file-val) nil)
             ((string-empty-p headline-val) file-val)
             (t (format "%s → %s" file-val headline-val)))
       (if custom-target
           (list (jetpacs-text
                  "This template files somewhere the builder can't edit (an id, clock, or function target); saving keeps it unchanged."
                  'caption))
         (list
          (jetpacs-enum-list "captpl-file" (jetpacs-org--captpl-org-files)
                             :value (and (not (string-empty-p file-val))
                                         file-val)
                             :allow-add t
                             :on-change (jetpacs-action
                                         "org.templates.update"
                                         :args '((field . "file"))))
          (jetpacs-text-input "captpl-headline"
                              :value headline-val
                              :label "Under headline"
                              :hint "Empty = end of file; A/B nests an outline path"
                              :single-line t))))
      (jetpacs-org--captpl-section
       "todo" "Status" (unless (equal todo-val "None") todo-val)
       (list (jetpacs-enum-list "captpl-todo"
                                (cons "None" (jetpacs-org--captpl-todo-keywords))
                                :value todo-val
                                :on-change (jetpacs-action
                                            "org.templates.update"
                                            :args '((field . "todo"))))))
      (jetpacs-org--captpl-section
       "tags" "Tags" (when tags-list (string-join tags-list ", "))
       (list (jetpacs-enum-list "captpl-tags" (jetpacs-org--captpl-known-tags)
                                :value (vconcat tags-list)
                                :multi-select t
                                :allow-add t
                                :on-change (jetpacs-action
                                            "org.templates.update"
                                            :args '((field . "tags"))))))
      (jetpacs-org--captpl-section
       "prompts" "Extra prompts"
       (when prompts-list (string-join prompts-list ", "))
       (list (jetpacs-text
              "Each becomes a %^{Field} capture asks for."
              'caption)
             (jetpacs-enum-list "captpl-prompts" prompts-list
                                :value (vconcat prompts-list)
                                :multi-select t
                                :allow-add t
                                :on-change (jetpacs-action
                                            "org.templates.update"
                                            :args '((field . "prompts"))))))
      (jetpacs-org--captpl-section
       "includes" "Include" (and includes (string-join includes ", "))
       (list (jetpacs-text "Created timestamp" 'caption)
             (jetpacs-enum-list "captpl-timestamp"
                                jetpacs-org--captpl-timestamps
                                :value ts-val
                                :on-change (jetpacs-action
                                            "org.templates.update"
                                            :args '((field . "timestamp"))))
             (jetpacs-switch "captpl-link"
                             :checked link
                             :label "Link to where capture was called (%a)"
                             :on-change (jetpacs-action
                                         "org.templates.update"
                                         :args '((field . "link"))))
             (jetpacs-switch "captpl-initial"
                             :checked initial
                             :label "Shared/selected text (%i)"
                             :on-change (jetpacs-action
                                         "org.templates.update"
                                         :args '((field . "initial")))))))
     :padding 16)))

(defun jetpacs-org--captpl-builder-body ()
  "The template builder screen body."
  (let ((new (eq jetpacs-org--captpl-editing 'new))
        (key-val (or (jetpacs-ui-state "captpl-key") ""))
        (desc-val (or (jetpacs-ui-state "captpl-description") ""))
        (tmpl-val (or (jetpacs-ui-state "captpl-template") "")))
    (jetpacs-lazy-column
     (jetpacs-card
      (list
       (jetpacs-text-input "captpl-key"
                           :value key-val
                           :label "Key"
                           :hint "One short letter, e.g. t"
                           :single-line t)
       (jetpacs-text-input "captpl-description"
                           :value desc-val
                           :label "Name"
                           :hint "What the capture sheet shows, e.g. Todo"
                           :single-line t))
      :padding 16)
     (jetpacs-spacer :height 8)
     (jetpacs-org--captpl-builder-card)
     (jetpacs-spacer :height 8)
     (jetpacs-card
      (list
       (jetpacs-text "Template" 'headline)
       (jetpacs-text
        "The builder writes this org template as you pick — edit it here to go further."
        'caption)
       (jetpacs-text-input "captpl-template"
                           :value tmpl-val
                           :multi-line t
                           :min-lines 4
                           :monospace t
                           :syntax "org")
       (jetpacs-text (jetpacs-org--captpl-prompts-caption) 'caption)
       (jetpacs-row
        (jetpacs-spacer :weight 1)
        (jetpacs-button "Rebuild from builder"
                        (jetpacs-action "org.templates.update")
                        :variant "text")))
      :padding 16)
     (jetpacs-spacer :height 8)
     (jetpacs-row
      (when (stringp jetpacs-org--captpl-editing)
        (jetpacs-button "Delete"
                        (jetpacs-action "org.templates.delete"
                                        :args `((key . ,jetpacs-org--captpl-editing))
                                        :when-offline "drop")
                        :variant "text"))
      (jetpacs-spacer :weight 1)
      (jetpacs-button "Cancel" (jetpacs-action "org.templates.back")
                      :variant "text")
      (jetpacs-spacer :width 8)
      (jetpacs-button (if new "Add Template" "Save Template")
                      (jetpacs-action "org.templates.save"))))))

(defun jetpacs-org--captpl-builder-view (snackbar)
  (jetpacs-shell-nav-view
   (if (eq jetpacs-org--captpl-editing 'new)
       "New Capture Template"
     (format "Edit Template: %s"
             (or (jetpacs-ui-state "captpl-description")
                 jetpacs-org--captpl-editing)))
   (jetpacs-org--captpl-builder-body)
   :nav-action (jetpacs-action "org.templates.back")
   :snackbar snackbar))

;; ── The hub screen

(defun jetpacs-org--captpl-hub-card (entry)
  "The hub card for template ENTRY.
A function template (no template string) is listed and deletable but
not editable here — its card carries a code icon instead of edit."
  (let ((key (nth 0 entry))
        (desc (or (nth 1 entry) ""))
        (editable (stringp (nth 4 entry))))
    (jetpacs-card
     (list
      (jetpacs-row
       (jetpacs-box
        (list
         (jetpacs-column
          (jetpacs-text (if (string-empty-p desc) key desc) 'label)
          (jetpacs-text (format "%s · %s" key
                                (jetpacs-org--captpl-target-summary entry))
                        'caption)))
        :weight 1)
       (if editable
           (jetpacs-icon-button "edit"
                                (jetpacs-action "org.templates.edit"
                                                :args `((key . ,key))
                                                :when-offline "drop")
                                :content-description "Edit template")
         (jetpacs-icon "code"))
       (jetpacs-icon-button "delete"
                            (jetpacs-action "org.templates.delete"
                                            :args `((key . ,key))
                                            :when-offline "drop")
                            :content-description "Delete template"))))))

(defun jetpacs-org--captpl-hub-body ()
  (apply #'jetpacs-lazy-column
         (append
          (list (jetpacs-text
                 "What org-capture (and a capture sheet) offers. Managed templates persist through Customize; init.el templates listed here return on restart if deleted."
                 'caption))
          (if org-capture-templates
              (mapcar #'jetpacs-org--captpl-hub-card org-capture-templates)
            (list (jetpacs-empty-state
                   :icon "edit_note" :title "No capture templates"
                   :caption "Build one below — it lands in org-capture-templates.")))
          (list (jetpacs-button "New Template"
                                (jetpacs-action "org.templates.new"
                                                :when-offline "drop")
                                :variant "outlined")))))

(defun jetpacs-org--captpl-hub-view (snackbar)
  (jetpacs-shell-nav-view "Capture Templates" (jetpacs-org--captpl-hub-body)
                          :snackbar snackbar))

;; ── Actions

(defun jetpacs-org--captpl-persist ()
  (jetpacs-settings-save-variable 'org-capture-templates org-capture-templates))

(defun jetpacs-org--captpl-close (&optional switch-to)
  "Leave the builder screen, clearing its state; land on SWITCH-TO."
  (setq jetpacs-org--captpl-editing nil
        jetpacs-org--captpl-entry nil)
  (jetpacs-ui-state-clear "captpl-")
  (jetpacs-shell-push nil :switch-to (or switch-to "org-templates")))

(defun jetpacs-org--captpl-save-target (file headline)
  "Build the capture target from the builder's FILE and HEADLINE values.
An original entry whose target the builder can't represent is kept
verbatim.  Signals `user-error' when no destination file is set."
  (let ((orig jetpacs-org--captpl-entry))
    (cond
     ((and orig (not (jetpacs-org--captpl-target-fields (nth 3 orig))))
      (nth 3 orig))
     ((or (null file) (string-empty-p file))
      (user-error "Pick a destination file"))
     ((string-empty-p headline)
      (list 'file (jetpacs-org--captpl-absolute-file file)))
     ((string-match-p "/" headline)
      (append (list 'file+olp (jetpacs-org--captpl-absolute-file file))
              (mapcar #'string-trim (split-string headline "/" t))))
     (t (list 'file+headline (jetpacs-org--captpl-absolute-file file)
              headline)))))

(defun jetpacs-org--captpl-save ()
  "Validate the builder state and write the entry into `org-capture-templates'.
Returns non-nil when the save landed; a validation failure notifies and
returns nil, leaving the builder open."
  (let* ((key (string-trim (or (jetpacs-ui-state "captpl-key") "")))
         (desc (string-trim (or (jetpacs-ui-state "captpl-description") "")))
         (tmpl (or (jetpacs-ui-state "captpl-template") ""))
         (file (car (jetpacs-ui-state-list "captpl-file")))
         (headline (string-trim (or (jetpacs-ui-state "captpl-headline") "")))
         (old-key (and (stringp jetpacs-org--captpl-editing)
                       jetpacs-org--captpl-editing))
         (orig jetpacs-org--captpl-entry))
    (catch 'invalid
      (cl-flet ((invalid (msg) (jetpacs-shell-notify msg)
                         (throw 'invalid nil)))
        (when (string-empty-p key)
          (invalid "The template needs a key — one short letter"))
        (when (string-empty-p desc)
          (invalid "The template needs a name"))
        (when (string-empty-p (string-trim tmpl))
          (invalid "The template text is empty"))
        (when (and (assoc key org-capture-templates)
                   (not (equal key old-key))
                   ;; Creating over an existing key means overwrite (like a
                   ;; saved-search save); renaming onto an occupied key
                   ;; silently eating a template is not allowed.
                   old-key)
          (invalid (format "Key %s already belongs to another template" key)))
        (let* ((target (condition-case err
                           (jetpacs-org--captpl-save-target file headline)
                         (user-error (invalid (error-message-string err)))))
               (entry (append (list key desc
                                    (if orig (nth 2 orig) 'entry)
                                    target tmpl)
                              (if orig (nthcdr 5 orig) '(:empty-lines 1))))
               (templates (cl-remove-if
                           (lambda (e) (and old-key
                                            (not (equal old-key key))
                                            (equal (car e) old-key)))
                           org-capture-templates))
               (pos (cl-position key templates :key #'car :test #'equal)))
          (setq org-capture-templates
                (if pos
                    (append (cl-subseq templates 0 pos) (list entry)
                            (cl-subseq templates (1+ pos)))
                  (append templates (list entry))))
          (jetpacs-org--captpl-persist)
          t)))))

(jetpacs-defaction "org.templates.show"
  (lambda (_ _)
    (jetpacs-shell-push nil :switch-to "org-templates")))

(jetpacs-defaction "org.templates.new"
  (lambda (_ _)
    (setq jetpacs-org--captpl-editing 'new
          jetpacs-org--captpl-entry nil)
    (jetpacs-org--captpl-seed-new)
    (jetpacs-shell-push nil :switch-to "org-template-edit")))

(jetpacs-defaction "org.templates.edit"
  (lambda (args _)
    (let* ((key (alist-get 'key args))
           (entry (assoc key org-capture-templates)))
      (cond
       ((null entry)
        (jetpacs-shell-notify "That template no longer exists")
        (jetpacs-shell-push))
       ((not (stringp (nth 4 entry)))
        (jetpacs-shell-notify
         "That template is elisp-defined — edit it in your init file")
        (jetpacs-shell-push))
       (t
        (setq jetpacs-org--captpl-editing key
              jetpacs-org--captpl-entry entry)
        (jetpacs-org--captpl-seed-edit entry)
        (jetpacs-shell-push nil :switch-to "org-template-edit"))))))

(jetpacs-defaction "org.templates.update"
  ;; A builder control changed: record it, regenerate the template
  ;; string from the whole structured state, and re-push so section
  ;; summaries and the prompts preview follow.  The raw template field
  ;; updates through `state.changed' alone — field "template" (the
  ;; Rebuild button posts no field at all) must NOT regenerate, or a
  ;; hand edit would be clobbered mid-typing.
  (lambda (args _)
    (let ((field (alist-get 'field args)))
      (when field
        (jetpacs-ui-state-put (concat "captpl-" field)
                              (alist-get 'value args)))
      (unless (equal field "template")
        (jetpacs-ui-state-put "captpl-template"
                              (jetpacs-org--captpl-build-template))))
    (jetpacs-shell-push)))

(jetpacs-defaction "org.templates.back"
  (lambda (_ _)
    (jetpacs-org--captpl-close)))

(jetpacs-defaction "org.templates.save"
  (lambda (_ _)
    (if (jetpacs-org--captpl-save)
        (progn
          (jetpacs-shell-notify "Capture template saved")
          (jetpacs-org--captpl-close))
      (jetpacs-shell-push))))

(jetpacs-defaction "org.templates.delete"
  (lambda (args _)
    (let* ((key (alist-get 'key args))
           (entry (assoc key org-capture-templates)))
      (when entry
        (setq org-capture-templates (delq entry org-capture-templates))
        (jetpacs-org--captpl-persist)
        (jetpacs-shell-notify
         (format "Deleted capture template %s" (or (nth 1 entry) key))))
      (if (equal jetpacs-org--captpl-editing key)
          (jetpacs-org--captpl-close)
        (jetpacs-shell-push)))))

;; ── Registration

(jetpacs-shell-define-view "org-templates"
                           :builder #'jetpacs-org--captpl-hub-view :order 84)
(jetpacs-shell-define-view "org-template-edit"
                           :builder #'jetpacs-org--captpl-builder-view
                           :when (lambda () (and jetpacs-org--captpl-editing t))
                           :overlay (lambda () (and jetpacs-org--captpl-editing t))
                           :order 112)

;; Entry point: a card in the settings screen's Emacs section, beside
;; Modus Themes and Customize.
(jetpacs-settings-add-link
 27 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "edit_note")
              (jetpacs-box (list (jetpacs-column
                                  (jetpacs-text "Capture Templates" 'label)
                                  (jetpacs-text "Build and manage org-capture templates"
                                                'caption)))
                           :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-action "org.templates.show" :when-offline "drop"))))

;; ─── Org buffer render skin (Tier 1) ──────────────────────────────────────────
;;
;; The org analogue of the shr substrate: a Tier-1 skin registered for
;; org-mode buffers.  Deliberately flat and unopinionated — the body IS
;; the Tier-0 faithful line render (faces, folding affordances, tappable
;; links, line numbers, the line cap), and only elements that have a
;; native SDUI node are upgraded in place:
;;
;;   -----                → a real divider
;;   | org | tables |     → the native table node (header rows and rules
;;                          kept; table.el tables and #+TBLFM stay text)
;;   [[file:img.png]]     → an image node, for paragraphs that are just
;;                          one image link (http(s) images too — the
;;                          device fetches those itself)
;;   \begin{…}…\end{…}    → the formula rendered through org's own LaTeX
;;                          preview toolchain and shipped as an image
;;   #+CAPTION: …         → a caption line under its upgraded element
;;
;; Two inline objects route their taps through the Tier-0 span-action
;; seam instead of upgrading in place: footnote references open the
;; footnote dialog, and item checkboxes toggle (`org.checkbox.toggle',
;; statistics cookies included).  Everything else — citations, inline
;; math, drawers, list markers, src blocks — renders exactly as the
;; user's font-lock shows it.  If anything in the upgrade pass fails,
;; the buffer falls back to the pure Tier-0 render: this skin can
;; subtract nothing.

(defcustom jetpacs-org-render-latex-images t
  "When non-nil, org LaTeX environments render as preview images.
Uses org's own preview pipeline (`org-preview-latex-default-process',
`org-format-latex-options' — scale and colors included), so what the
phone shows is what \\[org-latex-preview] would show.  With no TeX
toolchain installed the environment silently stays styled text."
  :type 'boolean :group 'jetpacs)

(defvar jetpacs-org--latex-memo (make-hash-table :test 'equal)
  "FRAGMENT|PROCESS -> (PATH . WIDTH-PX) memo for rendered formulas.
`fail' marks a fragment whose render errored, so a missing toolchain
costs one attempt per formula per session, not one per push.")

(defun jetpacs-org--png-size (data)
  "(WIDTH . HEIGHT) in pixels from PNG DATA (a unibyte string), or nil."
  (when (and (stringp data) (> (length data) 24)
             (string-prefix-p "\x89PNG" data))
    (cl-flet ((u32 (o) (+ (* (aref data o) 16777216)
                          (* (aref data (+ o 1)) 65536)
                          (* (aref data (+ o 2)) 256)
                          (aref data (+ o 3)))))
      (cons (u32 16) (u32 20)))))

(defun jetpacs-org--svg-width (data)
  "Approximate device width for SVG DATA from its width=\"…pt\" attribute.
1.94 px/pt matches the 140 dpi org renders headless PNGs at, so both
output formats land at a consistent size."
  (when (and (stringp data)
             (string-match "width=[\"']\\([0-9.]+\\)pt[\"']" data))
    (round (* 1.94 (string-to-number (match-string 1 data))))))

(defun jetpacs-org--latex-safe-options ()
  "`org-format-latex-options', with colors a headless Emacs can resolve.
org's preview pipeline resolves the symbol `default' through the
default face, whose colors are \"unspecified\" in a batch or daemon
session; `color-values' then returns nil and the render dies on a
format error.  Substitute concrete values only in that case — an
explicit user color (hex or named, both resolve everywhere) is
honored untouched."
  (let ((opts (copy-sequence org-format-latex-options)))
    (cl-flet ((unresolvable-p (c) (not (and (stringp c) (color-values c)))))
      (when (and (eq (plist-get opts :foreground) 'default)
                 (unresolvable-p (face-attribute 'default :foreground nil)))
        (setq opts (plist-put opts :foreground "Black")))
      (when (and (eq (plist-get opts :background) 'default)
                 (unresolvable-p (face-attribute 'default :background nil)))
        (setq opts (plist-put opts :background "Transparent"))))
    opts))

(defun jetpacs-org--latex-image (fragment)
  "Render LaTeX FRAGMENT via org's preview toolchain; (URL . WIDTH-PX) or nil.
The image lands in the hypertext content cache (write-once, swept by
size), and the result is memoised per session — including failures, so
a machine without LaTeX doesn't re-run a doomed compile on every push.
WIDTH-PX is the pixel width for PNG output (nil for SVG)."
  (when (and jetpacs-org-render-latex-images
             (fboundp 'org-create-formula-image))
    (let* ((key (format "%s|%s|%S" fragment
                        org-preview-latex-default-process
                        org-format-latex-options))
           (hit (gethash key jetpacs-org--latex-memo)))
      (cond
       ((eq hit 'fail) nil)
       ((and (consp hit) (file-readable-p (car hit)))
        (cons (concat "file://" (car hit)) (cdr hit)))
       (t
        (let ((result
               (condition-case nil
                   (with-timeout (15)
                     (let* ((process org-preview-latex-default-process)
                            (ext (or (plist-get
                                      (cdr (assq process
                                                 org-preview-latex-process-alist))
                                      :image-output-type)
                                     "png"))
                            (tmp (make-temp-file "jetpacs-latex" nil
                                                 (concat "." ext))))
                       (unwind-protect
                           (progn
                             (org-create-formula-image
                              fragment tmp (jetpacs-org--latex-safe-options)
                              (current-buffer) process)
                             (let* ((data (with-temp-buffer
                                            (set-buffer-multibyte nil)
                                            (insert-file-contents-literally tmp)
                                            (buffer-string)))
                                    (path (and (> (length data) 0)
                                               (jetpacs-hypertext--image-cache-put
                                                data (intern ext)))))
                               (and path
                                    (cons path
                                          (or (car (jetpacs-org--png-size data))
                                              (jetpacs-org--svg-width data))))))
                         (ignore-errors (delete-file tmp)))))
                 (error nil))))
          (puthash key (or result 'fail) jetpacs-org--latex-memo)
          (when result
            (cons (concat "file://" (car result)) (cdr result)))))))))

(defun jetpacs-org--latex-node (el)
  "An image node for latex-environment EL, or nil when it can't render.
The rendered width ships as dp (px≈dp matches the 140 dpi render to
the phone's text size) so a small formula doesn't stretch to fill the
screen, capped at 340dp so a full-line environment (equation numbers
push the bounding box to the text width) still fits a phone."
  (when-let ((img (jetpacs-org--latex-image
                   (org-element-property :value el))))
    (jetpacs-image (car img)
                   :width (and (cdr img) (min (cdr img) 340))
                   :content-description "LaTeX formula")))

(defun jetpacs-org--visual-end (el)
  "EL's end position excluding trailing blank lines.
Tier 0 keeps blank lines' vertical space, so an upgrade must not
swallow the blanks org-element folds into an element's :end."
  (save-excursion
    (goto-char (org-element-property :end el))
    (skip-chars-backward " \t\n")
    (min (point-max) (line-beginning-position 2))))

(defun jetpacs-org--element-caption (el)
  "The raw #+CAPTION text from EL's affiliated keyword lines, or nil."
  (when (org-element-property :caption el)
    (save-excursion
      (goto-char (org-element-property :begin el))
      (let ((case-fold-search t))
        (when (re-search-forward
               "^[ \t]*#\\+caption\\(?:\\[.*?\\]\\)?:[ \t]*\\(.*\\)$"
               (org-element-property :post-affiliated el) t)
          (let ((cap (string-trim (match-string-no-properties 1))))
            (unless (string-empty-p cap) cap)))))))

(defun jetpacs-org--table-node (el)
  "A native table node for org table element EL, or nil for table.el syntax.
Rows come from `org-table-to-lisp'; hlines become rules, and the rows
above the first hline render as the header group (org's own header
convention).  The #+TBLFM line sits outside :contents-end and stays
Tier-0 text."
  (when (eq (org-element-property :type el) 'org)
    (let* ((lisp (org-table-to-lisp
                  (buffer-substring-no-properties
                   (org-element-property :contents-begin el)
                   (org-element-property :contents-end el))))
           (has-header (and (memq 'hline lisp)
                            (not (eq (car lisp) 'hline))))
           (seen-hline nil))
      (when lisp
        (jetpacs-table
         (mapcar (lambda (row)
                   (if (eq row 'hline)
                       (progn (setq seen-hline t) (jetpacs-table-rule))
                     (jetpacs-table-row
                      (mapcar (lambda (cell)
                                (jetpacs-table-cell (list (jetpacs-span cell))))
                              row)
                      :header (and has-header (not seen-hline)))))
                 lisp))))))

(defconst jetpacs-org--image-link-line-re
  (concat "[ \t]*\\[\\[\\(?:file:\\)?\\([^][]+\\."
          "\\(?:png\\|jpe?g\\|gif\\|webp\\|svg\\|bmp\\)\\)\\]"
          "\\(?:\\[\\([^][]*\\)\\]\\)?\\][ \t]*$")
  "A line that is exactly one image link, description optional.")

(defun jetpacs-org--image-node (el)
  "An image node when paragraph EL is a single standalone image link.
Local paths must be readable (relative ones resolve against the
buffer's file); http(s) URLs pass through — the device fetches those
itself.  Anything else returns nil and the paragraph stays text."
  (save-excursion
    (goto-char (org-element-property :post-affiliated el))
    (when (and (looking-at jetpacs-org--image-link-line-re)
               ;; The link line must BE the whole paragraph.
               (>= (line-beginning-position 2) (jetpacs-org--visual-end el)))
      (let* ((path (match-string-no-properties 1))
             (desc (match-string-no-properties 2))
             (url (cond
                   ((string-match-p "\\`https?://" path) path)
                   (t (let ((abs (expand-file-name
                                  path
                                  (if buffer-file-name
                                      (file-name-directory buffer-file-name)
                                    default-directory))))
                        (and (file-readable-p abs)
                             (concat "file://" abs)))))))
        (when url
          (jetpacs-image url
                         :content-description
                         (or (and desc (not (string-empty-p desc)) desc)
                             (file-name-nondirectory path))))))))

(defun jetpacs-org--upgrades ()
  "Upgrade blocks for the current org buffer: a sorted (BEG END NODES) list.
Each block replaces [BEG, END) of the Tier-0 line render with native
NODES.  Elements inside folded (invisible) regions are left alone —
Tier 0 already drops them, and upgrading would leak hidden content."
  (let (out)
    (org-element-map (org-element-parse-buffer 'element)
        '(horizontal-rule table latex-environment paragraph)
      (lambda (el)
        (let ((beg (org-element-property :begin el)))
          (unless (let ((iv (get-char-property beg 'invisible)))
                    (and iv (invisible-p iv)))
            (pcase-let
                ((`(,node . ,end)
                  (pcase (org-element-type el)
                    ('horizontal-rule
                     (cons (jetpacs-divider) (jetpacs-org--visual-end el)))
                    ('table
                     (when-let ((n (jetpacs-org--table-node el)))
                       (cons n (org-element-property :contents-end el))))
                    ('latex-environment
                     (when-let ((n (jetpacs-org--latex-node el)))
                       (cons n (jetpacs-org--visual-end el))))
                    ('paragraph
                     (when-let ((n (jetpacs-org--image-node el)))
                       (cons n (jetpacs-org--visual-end el)))))))
              (when node
                (let ((caption (jetpacs-org--element-caption el)))
                  ;; With a caption the affiliated lines fold into the
                  ;; upgrade (the caption re-emerges under the node);
                  ;; without one they stay Tier-0 meta text.
                  (push (list (if caption
                                  beg
                                (org-element-property :post-affiliated el))
                              end
                              (delq nil
                                    (list node
                                          (when caption
                                            (jetpacs-text caption 'caption)))))
                        out))))))))
    (sort (nreverse out) (lambda (a b) (< (car a) (car b))))))

(defun jetpacs-org--checkbox-at (pos)
  "The (BEG . END) bounds of the item checkbox POS sits inside, or nil.
A cheap char pre-filter guards the org-list predicate (the span seam
consults this per run); the predicate's match data then yields the
exact bracket bounds, so only a tap on the checkbox itself — not the
item's text — counts."
  (and (eq (char-after pos) ?\[)
       (memq (char-after (1+ pos)) '(?\s ?- ?X))
       (eq (char-after (+ pos 2)) ?\])
       (save-excursion
         (goto-char pos)
         (and (org-at-item-checkbox-p)
              (let ((beg (match-beginning 1))
                    (end (match-end 1)))
                (and beg (>= pos beg) (< pos end)
                     (cons beg end)))))))

(defun jetpacs-org--span-action (pos buffer-name)
  "Span tap routing for the org skin.
Footnote references open their dialog; item checkboxes toggle (queued
offline, like every other mutation).  Everything else returns nil and
keeps the generic Tier-0 behavior (links still open through
`jetpacs.buffer.act').  Cheap pre-filters guard both checks, so
ordinary runs pay regexp cost at most."
  (save-excursion
    (goto-char pos)
    (cond
     ((and (org-in-regexp org-footnote-re)
           (save-match-data (org-footnote-at-reference-p)))
      (jetpacs-action "org.footnote.show"
                      :args `((buffer . ,buffer-name) (pos . ,pos))
                      :when-offline "drop"))
     ((jetpacs-org--checkbox-at pos)
      (jetpacs-action "org.checkbox.toggle"
                      :args `((buffer . ,buffer-name) (pos . ,pos)))))))

(defun jetpacs-org-render (buffer)
  "Tier-1 render skin for org BUFFER: the Tier-0 line render, upgraded.
See the section comment above for exactly what upgrades; everything
else is the untouched Tier-0 output, and any error in the upgrade scan
degrades to the pure Tier-0 render.  Footnote-reference spans route
their taps to the footnote dialog via the Tier-0 span-action seam."
  (with-current-buffer buffer
    (let* ((jetpacs-buffer-span-action-function #'jetpacs-org--span-action)
           (name (buffer-name))
           (upgrades (condition-case nil
                         (jetpacs-org--upgrades)
                       (error nil)))
           (budget jetpacs-buffer-max-lines)
           (pos (point-min))
           out)
      (dolist (up upgrades)
        (pcase-let ((`(,beg ,end ,nodes) up))
          (when (and (> budget 0) (>= beg pos))
            (when (> beg pos)
              (let* ((jetpacs-buffer-max-lines budget)
                     (chunk (jetpacs-buffer-render-region name pos beg)))
                (setq out (nconc out chunk)
                      budget (- budget (length chunk)))))
            (when (> budget 0)
              (setq out (nconc out nodes)
                    budget (- budget (length nodes))))
            (setq pos end))))
      (when (and (> budget 0) (< pos (point-max)))
        (let ((jetpacs-buffer-max-lines budget))
          (setq out (nconc out (jetpacs-buffer-render-region
                                name pos (point-max))))))
      (when (<= budget 0)
        (setq out (nconc out (list (jetpacs-text
                                    (format "… truncated at %d lines"
                                            jetpacs-buffer-max-lines)
                                    'caption)))))
      out)))

(jetpacs-render-buffer-register 'org-mode #'jetpacs-org-render)

;; ── Footnote dialog
;;
;; Tapping a footnote reference opens a dialog (Glasspane styles dialogs
;; as bottom sheets) carrying the definition and its actions: Copy puts
;; the definition on the device clipboard (companion-local, works
;; offline), Edit opens the file in the phone editor and names the
;; definition's line.  A dialog needs no new protocol node — a popover
;; node can upgrade this later behind `jetpacs-node-or' without touching
;; the action.

(declare-function jetpacs-files-open "jetpacs-files" (file))

(defun jetpacs-org--footnote-dialog (buffer-name pos)
  "The footnote dialog spec for the reference at POS in BUFFER-NAME, or nil."
  (let ((buf (get-buffer (or buffer-name ""))))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (org-with-wide-buffer
         (goto-char (min (max (point-min) (truncate pos)) (point-max)))
         (when-let ((ref (org-footnote-at-reference-p)))
           (pcase-let ((`(,label ,_beg ,_end ,inline-def) ref))
             (let* ((def (or inline-def
                             (and label
                                  (nth 3 (org-footnote-get-definition label)))))
                    (def (and (stringp def) (string-trim def)))
                    (have-def (and def (not (string-empty-p def)))))
               (jetpacs-column
                (jetpacs-text (if label (format "Footnote [fn:%s]" label)
                                "Inline footnote")
                              'title)
                (jetpacs-text (if have-def def "No definition found.") 'body)
                (apply #'jetpacs-row
                       (delq nil
                             (list
                              (jetpacs-spacer :weight 1)
                              (when have-def
                                (jetpacs-button "Copy"
                                                (jetpacs-clipboard-action def)
                                                :variant "text"))
                              (when (and label (not inline-def)
                                         (buffer-file-name))
                                (jetpacs-button
                                 "Edit"
                                 (jetpacs-action "org.footnote.edit"
                                                 :args `((buffer . ,buffer-name)
                                                         (label . ,label))
                                                 :when-offline "drop")
                                 :variant "text"))
                              (jetpacs-button "Close"
                                              (jetpacs-action "dialog.dismiss")
                                              :variant "text")))))))))))))

(jetpacs-defaction "org.checkbox.toggle"
  ;; Position-addressed like `jetpacs.buffer.fold': the tap carries the
  ;; buffer and the checkbox's render-time position, and the handler
  ;; re-verifies the position is still a checkbox before mutating, so a
  ;; stale surface can never strike arbitrary text.  Statistics cookies
  ;; ([1/3], [50%]) update through `org-toggle-checkbox' itself; the org
  ;; query memos drop, a file-backed buffer schedules its idle save, and
  ;; the showing surface re-pushes.
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) "")))
          (pos (alist-get 'pos args)))
      (if (not (and buf (numberp pos)))
          (jetpacs-shell-notify "That checkbox is gone — refreshing")
        (with-current-buffer buf
          (org-with-wide-buffer
           (goto-char (min (max (point-min) (truncate pos)) (point-max)))
           (if (not (jetpacs-org--checkbox-at (point)))
               (jetpacs-shell-notify "That checkbox moved — refreshing")
             (org-toggle-checkbox)
             (jetpacs-org-cache-invalidate)
             (when (buffer-file-name)
               (jetpacs-org-defer-save))))))
      (if (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function)
        (jetpacs-shell-push)))))

(jetpacs-defaction "org.footnote.show"
  (lambda (args _)
    (let ((spec (jetpacs-org--footnote-dialog (alist-get 'buffer args)
                                              (alist-get 'pos args))))
      (if spec
          (jetpacs-send-dialog spec)
        (jetpacs-shell-notify "That footnote is gone — refreshing")
        (jetpacs-shell-push)))))

(jetpacs-defaction "org.footnote.edit"
  ;; Jump to the definition: open the file in the phone editor and name
  ;; the line — the editor node has no cursor-seek yet, so the line
  ;; number in the snackbar is the navigation aid.
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) "")))
          (label (alist-get 'label args)))
      (jetpacs-dismiss-dialog)
      (if (not (and buf (stringp label)))
          (progn (jetpacs-shell-notify "That footnote is gone — refreshing")
                 (jetpacs-shell-push))
        (with-current-buffer buf
          (let ((def (org-footnote-get-definition label))
                (file (buffer-file-name)))
            (cond
             ((null def)
              (jetpacs-shell-notify
               (format "No definition found for [fn:%s]" label))
              (jetpacs-shell-push))
             ((not (and file (fboundp 'jetpacs-files-open)
                        (jetpacs-files-open file)))
              (jetpacs-shell-notify
               "That file isn't editable from the phone")
              (jetpacs-shell-push))
             (t
              (jetpacs-shell-notify
               (format "Definition of [fn:%s] is at line %d"
                       label
                       (org-with-wide-buffer
                        (line-number-at-pos (nth 1 def)))))))))))))

;; ─── Habits (org-habit) ───────────────────────────────────────────────────────
;;
;; org-habit is a built-in org module: a repeating TODO with `:STYLE: habit`
;; and a SCHEDULED repeater (.+2d / ++1w / .+1m) grows a consistency graph —
;; a per-day colored strip showing done/missed/ready/overdue days.  On the
;; desktop the graph lives in the agenda; the phone has no agenda view, so
;; this ships a small dedicated "Habits" satellite view instead, listing every
;; habit with its graph and a one-tap Done.
;;
;; The compute is org-habit's own, called standalone (no agenda run):
;; `org-habit-build-graph' returns a propertized string, one char per day,
;; each carrying the org-habit face for that day's state.  We resolve each
;; face's background through the same `jetpacs-buffer--color-hex' the buffer
;; renderer uses — so user face customization flows through untouched — and
;; draw the strip as one `jetpacs-canvas' of filled rects.  No new protocol
;; node; `jetpacs-org-habit-graph' and `jetpacs-org-habit-strip' are public so
;; a real agenda (or Glasspane) can reuse them wherever a habit is shown.

;; `jetpacs-files-open' is already declared in the footnote section above.

(defcustom jetpacs-org-habit-preceding-days 21
  "Days of history shown in a phone habit consistency strip.
With `jetpacs-org-habit-following-days' this sets the cell count; the
default 21+today+7 = 29 cells fits a phone width at the strip's cell
size.  Independent of org's own `org-habit-preceding-days' (which tunes
the desktop agenda)."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-org-habit-following-days 7
  "Days of upcoming schedule shown in a phone habit consistency strip.
See `jetpacs-org-habit-preceding-days'."
  :type 'integer :group 'jetpacs)

(defun jetpacs-org--habit-face-hex (face)
  "The background of habit-graph FACE as \"#RRGGBB\", or nil.
FACE is a face symbol (or a cons whose car is one, org-habit's shape);
resolved through the buffer renderer's color machinery, so a user's
`org-habit-*-face' customization is honored."
  (let ((sym (if (consp face) (car face) face)))
    (and (facep sym)
         (jetpacs-buffer--color-hex
          (face-attribute sym :background nil t)))))

(defun jetpacs-org-habit-graph (&optional pom)
  "The consistency graph of the habit at POM (point default) as a cell list.
Each cell is a plist (:glyph CHAR :color HEX) for one day, oldest first,
spanning `jetpacs-org-habit-preceding-days' before today through
`jetpacs-org-habit-following-days' after.  Returns nil when POM is not a
habit — including a `:STYLE: habit' heading whose SCHEDULED has no valid
repeater, which `org-is-habit-p' accepts but `org-habit-parse-todo'
rejects (signals); that case is caught and yields nil, never an error.
Reuses org-habit's own `org-habit-build-graph' verbatim — the
back-projection, the past-day fade, and the repeater semantics
\(.+/++/+) are all org's, not reimplemented here."
  (org-with-point-at (or pom (point))
    (when (org-is-habit-p)
      (ignore-errors
        (let* ((habit (org-habit-parse-todo))
               (now (current-time))
               (graph (org-habit-build-graph
                       habit
                       (time-subtract now (days-to-time
                                           jetpacs-org-habit-preceding-days))
                       now
                       (time-add now (days-to-time
                                      jetpacs-org-habit-following-days)))))
          (cl-loop for i below (length graph)
                   collect (list :glyph (aref graph i)
                                 :color (jetpacs-org--habit-face-hex
                                         (get-text-property i 'face graph)))))))))

(cl-defun jetpacs-org-habit-strip (cells &key (cell-width 6) (height 12) (gap 2))
  "A `jetpacs-canvas' consistency strip from CELLS (see `jetpacs-org-habit-graph').
One filled CELL-WIDTH×HEIGHT rect per colored day, GAP apart; days with
no resolved color leave a bare slot.  The whole strip is a single node,
so a long history serializes and pans as one image rather than N boxes."
  (let* ((n (length cells))
         (width (max 1 (- (* n (+ cell-width gap)) gap))))
    (jetpacs-canvas
     width height
     (delq nil
           (cl-loop for c in cells for i from 0
                    for col = (plist-get c :color)
                    when col
                    collect (jetpacs-draw-rect (* i (+ cell-width gap)) 0
                                               cell-width height
                                               :color col :fill t :radius 2))))))

(defun jetpacs-org--habit-item ()
  "Collect the Habits-view data for the habit at point, or nil if unparseable.
Point is on the heading (an `org-map-entries' visit).  A `:STYLE: habit'
heading with a broken/absent SCHEDULED repeater passes `org-is-habit-p'
but makes `org-habit-parse-todo' signal — return nil for it so one
malformed habit is skipped, not fatal to the whole scan."
  (save-excursion
    (ignore-errors
      (let* ((habit (org-habit-parse-todo))
             (done-today (and (member (org-today)
                                      (org-habit-done-dates habit))
                              t)))
        (list (cons 'ref (jetpacs-org-heading-ref))
              (cons 'title (or (nth 4 (org-heading-components)) "Untitled"))
              (cons 'todo (org-get-todo-state))
              (cons 'file (buffer-file-name))
              (cons 'done-today done-today)
              (cons 'cells (jetpacs-org-habit-graph (point))))))))

(defun jetpacs-org--habits ()
  "Every parseable habit across the agenda files, as Habits-view item alists.
Memoised under the `habits' namespace (busted by the mtime/date cache
key and by `org.habit.done').  Malformed habits are skipped."
  (jetpacs-org-with-cache 'habits "all"
    (let (items)
      (org-map-entries
       (lambda () (when (org-is-habit-p)
                    (when-let ((item (jetpacs-org--habit-item)))
                      (push item items))))
       nil 'agenda)
      (nreverse items))))

(defun jetpacs-org--habit-card (item)
  "A card for habit ITEM: title, consistency strip, and a one-tap Done.
A habit already done today shows a check instead of the button; the
whole card opens the file in the editor."
  (let ((ref (alist-get 'ref item))
        (title (alist-get 'title item))
        (cells (alist-get 'cells item))
        (todo (alist-get 'todo item))
        (done-today (alist-get 'done-today item)))
    (jetpacs-card
     (list
      (jetpacs-row
       (jetpacs-box
        (list (apply #'jetpacs-column
                     (delq nil
                           (list (jetpacs-text title 'label)
                                 (jetpacs-spacer :height 4)
                                 (jetpacs-org-habit-strip cells)
                                 (and todo (jetpacs-text todo 'caption))))))
        :weight 1)
       (if done-today
           (jetpacs-text "Done ✓" 'caption)
         (jetpacs-button "Done"
                         (jetpacs-action "org.habit.done" :args ref
                                         :when-offline "queue")
                         :variant "tonal"))))
     :on-tap (jetpacs-action "org.habit.open" :args ref :when-offline "drop"))))

(defun jetpacs-org--habits-body ()
  (let ((habits (condition-case nil (jetpacs-org--habits) (error nil))))
    (apply #'jetpacs-lazy-column
           (if habits
               (mapcar #'jetpacs-org--habit-card habits)
             (list (jetpacs-empty-state
                    :icon "repeat" :title "No habits"
                    :caption "Add :STYLE: habit to a repeating TODO (SCHEDULED with a .+1d-style repeater) and it appears here."))))))

(defun jetpacs-org--habits-view (snackbar)
  (jetpacs-shell-nav-view "Habits" (jetpacs-org--habits-body) :snackbar snackbar))

(jetpacs-shell-define-view "org-habits"
                           :builder #'jetpacs-org--habits-view :order 86)

;; Everyday nav, like the stock Databases entry — a daily destination, not
;; a setting.
(jetpacs-shell-add-drawer-item
 36 (lambda ()
      (jetpacs-drawer-item "repeat" "Habits"
                           (jetpacs-shell-switch-view "org-habits"))))

(jetpacs-defaction "org.habits.show"
  (lambda (_ _)
    (jetpacs-shell-push nil :switch-to "org-habits")))

(jetpacs-defaction "org.habit.done"
  ;; ARGS is the heading ref itself.  `org-todo' \"DONE\" on a repeating
  ;; habit is org's own repeat: it advances SCHEDULED by the repeater and
  ;; resets the state to TODO.  `jetpacs-org-toggle-todo' also flushes the
  ;; deferred \"State DONE\" log note (see its docstring) — that line is
  ;; what `org-habit-done-dates' counts, so the strip recounts and the
  ;; button flips to \"Done ✓\" on the next push (the mutation busts the
  ;; `habits' memo).
  (lambda (args _)
    (condition-case err
        (progn
          (jetpacs-org-toggle-todo args 'habits "DONE")
          (jetpacs-shell-notify "Marked done — habit advanced"))
      (error (jetpacs-shell-notify
              (format "Couldn't mark done: %s" (error-message-string err)))))
    (jetpacs-shell-push)))

(jetpacs-defaction "org.habit.open"
  ;; ARGS is the heading ref; open its file in the phone editor (no
  ;; cursor-seek yet, same limitation as the footnote Edit jump).
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (if (and file (fboundp 'jetpacs-files-open) (jetpacs-files-open file))
          (jetpacs-shell-notify (format "Opened %s"
                                        (file-name-nondirectory file)))
        (jetpacs-shell-notify "That file isn't editable from the phone")))))

(provide 'jetpacs-org)
;;; jetpacs-org.el ends here
