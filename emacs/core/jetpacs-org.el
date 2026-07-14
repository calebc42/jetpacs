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
;; The query grammar is interpreted ONCE (`jetpacs-org--matches-p') over a
;; pluggable data accessor: `jetpacs-org-entry-matches-p' reads the org
;; entry at point, `jetpacs-org-note-matches-p' reads a `vulpea-note'
;; struct off the vulpea index.  vulpea is an OPTIONAL engine: nothing
;; here requires it at load, the note path is only entered when a caller
;; hands us a note, and `jetpacs-org-vulpea-available-p' is the probe.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-id)
(require 'cl-lib)

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
        scheduled deadline)
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
  "Set the TODO state at REF to STATE, or toggle if nil."
  (jetpacs-org-with-mutation ref namespace
    (org-todo state)))

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

(provide 'jetpacs-org)
;;; jetpacs-org.el ends here
