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
;; It also carries the one org-opinionated stock screen: the capture
;; template builder (Settings → Capture Templates), which manages
;; `org-capture-templates' from the phone — see the "Capture template
;; management" section at the bottom.  That section is why this module
;; sits after the shell/settings machinery in the bundle order; the
;; extraction layer above it stays UI-free.
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
(require 'org-id)
(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-settings)

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

(provide 'jetpacs-org)
;;; jetpacs-org.el ends here
