;;; glasspane-org.el --- EABP Org-Mode Data Extraction -*- lexical-binding: t; -*-

;; Provides functions to extract structured data from org-mode buffers.
;; This layer is pure Elisp and has no bridge dependencies.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-clock)
(require 'org-capture)
(require 'org-id)
(require 'cl-lib)

;; ─── Refresh coordination ──────────────────────────────────────────────────────

(defvar glasspane-org--inhibit-save-refresh nil
  "When non-nil, the `after-save-hook' dashboard refresh is suppressed.
Bound around our own programmatic saves (heading edits, file saves) so an
explicit dashboard push isn't doubled by the save-hook firing on top.")

;; The dashboard pushes every view on every action (so navigation stays
;; instant and offline-capable), which means the expensive extractions here
;; — a full `org-agenda' run, an `org-map-entries' sweep — used to execute
;; on every chip tap and snackbar.  They are memoised now; this table is
;; dropped through `glasspane-org-cache-invalidate', the single seam every
;; mutation path (heading actions, saves, capture, queue replay) already
;; calls.
(defvar glasspane-org--cache (make-hash-table :test 'equal)
  "Memoised org extraction results.
Keys are built by `glasspane-org--cache-key' and include today's date, so
day-relative readers (the agenda) roll over at midnight even without an
explicit invalidation.")

(defun glasspane-org--cache-key (&rest parts)
  "Build a cache key from PARTS, scoped to today's date."
  (cons (format-time-string "%Y-%m-%d") parts))

(defmacro glasspane-org--with-cache (key &rest body)
  "Memoise BODY's result in `glasspane-org--cache' under KEY."
  (declare (indent 1))
  (let ((k (gensym "key")) (hit (gensym "hit")))
    `(let* ((,k ,key)
            (,hit (gethash ,k glasspane-org--cache 'glasspane-org--miss)))
       (if (eq ,hit 'glasspane-org--miss)
           (puthash ,k (progn ,@body) glasspane-org--cache)
         ,hit))))

(defun glasspane-org-cache-invalidate ()
  "Drop every memoised org extraction.
Called by every mutation path (heading actions, phone/desktop saves,
capture, offline-queue drain), so the readers recompute from fresh org
state on the next dashboard push."
  (clrhash glasspane-org--cache))

;; ─── Heading references ────────────────────────────────────────────────────────
;;
;; Every heading the UI lists carries a `ref' — a small, JSON-safe alist that
;; lets a later action (drill-in, todo-set, schedule, clock-in) find the same
;; heading again. The round-trip is: build with `glasspane-org--heading-ref' while
;; point is on the heading, ship it to the device inside an action's `:args',
;; and resolve it back to a live marker with `glasspane-org--resolve-ref'.

(defun glasspane-org--heading-ref ()
  "Build a location ref for the org heading at point.
Returns an alist with `file'/`pos'/`headline', plus `id' when the entry
already has an ID property (never created here — we don't mutate files).
nil-valued keys are omitted so the alist serialises cleanly to JSON."
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

(defun glasspane-org--resolve-ref (ref)
  "Resolve REF to a live marker at its org heading, or signal an error.
REF is an alist as built by `glasspane-org--heading-ref' (extra keys such as a
consed-on `state' are ignored). Resolution tries, in order: the stable
`id' (survives edits anywhere), the recorded `pos' accepted only if its
headline still matches, then a headline search through the file."
  (let ((id (alist-get 'id ref))
        (file (alist-get 'file ref))
        (pos (alist-get 'pos ref))
        (headline (alist-get 'headline ref)))
    (or
     ;; 1. Stable org ID — robust against edits elsewhere in the file.
     (and (stringp id) (not (string-empty-p id))
          (ignore-errors (org-id-find id 'marker)))
     ;; 2. Recorded position, trusted only if the headline still matches.
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
     ;; 3. Headline search — the heading moved but still exists in the file.
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

(defun glasspane-org--agenda-items (&optional span start-day)
  "Extract agenda items for SPAN (\\='day, \\='week, or \\='month).
START-DAY is an optional string (e.g. \"2026-11-01\") to start the agenda on.
Returns a list of alists representing agenda items.  Memoised; see
`glasspane-org-cache-invalidate'."
  (glasspane-org--with-cache (glasspane-org--cache-key 'agenda (or span 'day) start-day)
    (glasspane-org--agenda-items-1 span start-day)))

(defconst glasspane-org--agenda-buffer "*EABP Agenda*"
  "Private buffer the agenda extraction builds into (and kills after).")

(defun glasspane-org--agenda-items-1 (span start-day)
  "Uncached worker for `glasspane-org--agenda-items'."
  (let ((org-agenda-span (or span 'day))
        (org-agenda-start-day start-day)
        (org-agenda-files (org-agenda-files))
        ;; Build into a private buffer so a user's open *Org Agenda* on the
        ;; desktop is never clobbered (and never killed) by an extraction.
        ;; `org-agenda-buffer-tmp-name' is the supported redirect: `org-agenda'
        ;; REBINDS `org-agenda-buffer-name' in its own let* and recomputes it,
        ;; so binding that variable directly gets shadowed — the build then
        ;; lands in *Org Agenda* while we look for (and fail to find, and fail
        ;; to kill) our own name.
        (org-agenda-buffer-tmp-name glasspane-org--agenda-buffer)
        (org-agenda-sticky nil)
        (inhibit-redisplay t)
        items)
    (unwind-protect
        (save-window-excursion
          (let ((org-agenda-window-setup 'current-window))
            (org-agenda nil "a")
            (with-current-buffer glasspane-org--agenda-buffer
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((marker (get-text-property (point) 'org-marker))
                   (tags (get-text-property (point) 'tags))
                   (time (get-text-property (point) 'time))
                   (type (get-text-property (point) 'type))
                   ;; The agenda's own qualifier ("Sched. 3x: ", "In 3 d.: ")
                   ;; and the item's own date as an absolute day number —
                   ;; ts-date < (org-today) is the overdue test.
                   (extra (get-text-property (point) 'extra))
                   (ts-date (get-text-property (point) 'ts-date))
                   (date-abs (get-text-property (point) 'date))
                   ;; org ≥9.6 stores the gregorian (MONTH DAY YEAR) list
                   ;; directly; older code stored the absolute day number.
                   ;; Feeding the list to calendar-gregorian-from-absolute
                   ;; signals, which emptied the whole agenda.
                   (date-list (cond ((consp date-abs) date-abs)
                                    ((numberp date-abs)
                                     (calendar-gregorian-from-absolute date-abs))))
                   (date-str (when date-list (format "%04d-%02d-%02d" (nth 2 date-list) (nth 0 date-list) (nth 1 date-list)))))
              (when marker
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker)
                    (let* ((components (org-heading-components))
                           (todo (nth 2 components))
                           (priority (nth 3 components))
                           (headline (nth 4 components)))
                      (push `((headline . ,headline)
                              (todo . ,todo)
                              (priority . ,(if priority (char-to-string priority) nil))
                              (tags . ,(vconcat tags))
                              (file . ,(buffer-file-name))
                              (pos . ,(marker-position marker))
                              (time . ,time)
                              (date . ,date-str)
                              (type . ,(when type (format "%s" type)))
                              (extra . ,extra)
                              (ts-date . ,ts-date)
                              (ref . ,(glasspane-org--heading-ref)))
                            items))))))
            (forward-line 1)))))
      ;; Kill by buffer object, not name, and even when extraction errored.
      (when-let ((buf (get-buffer glasspane-org--agenda-buffer)))
        (kill-buffer buf)))
    (nreverse items)))

(defun glasspane-org--todo-items (&optional files)
  "Extract TODO items from FILES (or agenda files).
Memoised; see `glasspane-org-cache-invalidate'."
  (glasspane-org--with-cache (glasspane-org--cache-key 'todos files)
    (glasspane-org--todo-items-1 files)))

(defun glasspane-org--todo-items-1 (files)
  "Uncached worker for `glasspane-org--todo-items'."
  (let (items)
    (org-map-entries
     (lambda ()
       (let* ((components (org-heading-components))
              (todo (nth 2 components))
              (priority (nth 3 components))
              (headline (nth 4 components))
              (tags (org-get-tags))
              (scheduled (org-entry-get (point) "SCHEDULED"))
              (deadline  (org-entry-get (point) "DEADLINE")))
         (when todo
           (push `((headline . ,headline)
                   (todo . ,todo)
                   (priority . ,(if priority (char-to-string priority) nil))
                   (tags . ,(vconcat tags))
                   (scheduled . ,scheduled)
                   (deadline  . ,deadline)
                   (file . ,(buffer-file-name))
                   (pos . ,(point))
                   (ref . ,(glasspane-org--heading-ref)))
                 items))))
     "TODO<>\"\"" (or files 'agenda))
    (nreverse items)))

(defun glasspane-org--heading-item-at ()
  "Build a heading item alist for the org entry at point.
Same shape as `glasspane-org--todo-items' entries (headline/todo/priority/
tags/file/pos/ref); used by the search layer."
  (let* ((components (org-heading-components))
         (todo (nth 2 components))
         (priority (nth 3 components))
         (headline (nth 4 components))
         (tags (org-get-tags))
         (scheduled (org-entry-get (point) "SCHEDULED"))
         (deadline  (org-entry-get (point) "DEADLINE")))
    `((headline . ,headline)
      (todo . ,todo)
      (priority . ,(if priority (char-to-string priority) nil))
      (tags . ,(vconcat tags))
      (scheduled . ,scheduled)
      (deadline  . ,deadline)
      (file . ,(buffer-file-name))
      (pos . ,(point))
      (ref . ,(glasspane-org--heading-ref)))))

(defun glasspane-org--file-heading-items (file)
  "Extract level-1 headings from FILE as item alists.
Same shape as `glasspane-org--todo-items' entries (plus scheduled/deadline),
suitable for `glasspane-ui--agenda-card'."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (let (items)
         (org-map-entries
          (lambda ()
            (let* ((components (org-heading-components))
                   (level (nth 0 components))
                   (todo (nth 2 components))
                   (priority (nth 3 components))
                   (headline (nth 4 components))
                   (tags (org-get-tags))
                   (scheduled (org-entry-get (point) "SCHEDULED"))
                   (deadline  (org-entry-get (point) "DEADLINE")))
              (when (= level 1)
                (push `((headline . ,headline)
                        (todo . ,todo)
                        (priority . ,(if priority (char-to-string priority) nil))
                        (tags . ,(vconcat tags))
                        (scheduled . ,scheduled)
                        (deadline  . ,deadline)
                        (file . ,(buffer-file-name))
                        (pos . ,(point))
                        (ref . ,(glasspane-org--heading-ref)))
                      items))))
          nil nil)
         (nreverse items))))))

;; Search queries pass through one parser (`glasspane-org--parse-query')
;; into an org-ql-shaped sexp, whichever of the three input shapes the
;; user typed.  With org-ql installed the sexp runs there; without it a
;; built-in interpreter (`glasspane-org--query-match-p') covers the
;; common predicates.  Malformed queries signal `user-error' so the UI
;; can show the problem — an empty result must mean "nothing matched",
;; never "the query didn't parse".

(defconst glasspane-org--ql-literals '(today nil t < <= > >= =)
  "Symbols with meaning to org-ql that normalization must not stringify.")

(defun glasspane-org--normalize-ql (form)
  "Return sexp query FORM with elisp-isms rewritten to org-ql shape.
Hand-typed queries arrive looking like elisp — (tags \\='server) or
\(todo NEXT) — but org-ql wants plain strings, so quotes are unwrapped
and bare symbols in argument positions become strings.  Clause heads,
keywords, and the symbols org-ql itself understands (`today',
comparators) pass through untouched."
  (if (and (consp form) (eq (car form) 'quote) (cdr form))
      (glasspane-org--normalize-ql (cadr form))
    (if (not (consp form))
        form
      (cons (car form)
            (mapcar #'glasspane-org--normalize-ql-arg (cdr form))))))

(defun glasspane-org--normalize-ql-arg (arg)
  "Normalize ARG, a clause argument inside a sexp query.
Sub-clauses recurse through `glasspane-org--normalize-ql'; quoted or
bare symbols become strings unless org-ql assigns them meaning."
  (cond
   ((and (consp arg) (eq (car arg) 'quote) (cdr arg))
    (glasspane-org--normalize-ql-arg (cadr arg)))
   ((consp arg) (glasspane-org--normalize-ql arg))
   ((keywordp arg) arg)
   ((memq arg glasspane-org--ql-literals) arg)
   ((symbolp arg) (symbol-name arg))
   (t arg)))

(defun glasspane-org--query-tokens (q)
  "Split query Q on whitespace, keeping \"quoted phrases\" whole."
  (let ((pos 0) (tokens nil))
    (while (string-match "\"\\([^\"]*\\)\"\\|\\S-+" q pos)
      (push (or (match-string 1 q) (match-string 0 q)) tokens)
      (setq pos (match-end 0)))
    (nreverse tokens)))

(defun glasspane-org--parse-query (query)
  "Parse the search QUERY string into an org-ql sexp, or nil if empty.
Three input shapes are accepted:
- an org-ql sexp:  (and (todo \"TODO\") (tags \"work\"))
- filter tokens:   todo:TODO,NEXT tags:work priority:A
- free text:       \"exact phrase\" or bare words (matched
  case-insensitively against the heading and body)
Tokens of different kinds AND together; comma-separated values within
todo:/tags: mean any-of.  Signals `user-error' on a malformed sexp."
  (let ((q (string-trim query)))
    (cond
     ((string-empty-p q) nil)
     ;; A sexp query, possibly pasted with its elisp quote: '(tags "x")
     ((string-match-p "\\`'?(" q)
      (let ((form (condition-case nil (read q)
                    (error (user-error "Query has unbalanced parentheses: %s" q)))))
        (glasspane-org--normalize-ql form)))
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
                  `(priority ,(substring tok 9)))
                 (t `(regexp ,(regexp-quote tok)))))
              (glasspane-org--query-tokens q))))
        (if (cdr clauses) `(and ,@clauses) (car clauses)))))))

(defun glasspane-org--query-match-p (tree)
  "Non-nil when the heading at point matches query sexp TREE.
The org-ql subset the built-in search understands; anything else
signals `user-error' naming the term.  Tags and TODO keywords compare
case-sensitively (they are org data); free text and headings match
case-insensitively (search UX)."
  (pcase tree
    (`(and . ,cs) (cl-every #'glasspane-org--query-match-p cs))
    (`(or . ,cs) (and (cl-some #'glasspane-org--query-match-p cs) t))
    (`(not ,c) (not (glasspane-org--query-match-p c)))
    (`(todo . ,kws)
     (let ((st (org-get-todo-state)))
       (and st (if kws (and (member st kws) t)
                 (not (member st org-done-keywords))))))
    (`(done)
     (let ((st (org-get-todo-state)))
       (and st (member st org-done-keywords) t)))
    (`(tags . ,tags)
     (let ((have (org-get-tags)))
       (if tags (and (cl-some (lambda (tg) (member tg have)) tags) t)
         (and have t))))
    (`(priority ,(and op (pred symbolp)) ,val)
     ;; Comparators run on priority rank, where #A outranks #B — the
     ;; char values order the other way round, so the tests flip.
     (let ((pr (nth 3 (org-heading-components)))
           (want (string-to-char val)))
       (and pr (pcase op
                 ('< (> pr want)) ('<= (>= pr want))
                 ('> (< pr want)) ('>= (<= pr want))
                 ('= (= pr want))
                 (_ (user-error "Unsupported priority comparator %s" op))))))
    (`(priority . ,ps)
     (let ((pr (nth 3 (org-heading-components))))
       (if ps (and pr (member (char-to-string pr) ps) t)
         (and pr t))))
    (`(heading . ,texts)
     (let ((hl (or (nth 4 (org-heading-components)) ""))
           (case-fold-search t))
       (cl-every (lambda (s) (string-match-p (regexp-quote s) hl)) texts)))
    (`(regexp . ,res)
     ;; Heading plus body, up to the next heading — close enough to
     ;; org-ql's entry scope for search purposes.
     (let ((end (save-excursion (outline-next-heading) (point)))
           (case-fold-search t))
       (cl-every (lambda (re)
                   (save-excursion (re-search-forward re end t)))
                 res)))
    (`(property ,name . ,val)
     (let ((v (org-entry-get (point) name)))
       (if val (equal v (car val)) (and v t))))
    (`(level ,n) (eql (org-current-level) n))
    (`(level ,n ,m) (let ((l (org-current-level))) (and l (<= n l m))))
    (`(scheduled . ,args) (glasspane-org--planning-match-p "SCHEDULED" args))
    (`(deadline . ,args) (glasspane-org--planning-match-p "DEADLINE" args))
    (_ (user-error "Query term %S needs the org-ql package installed" tree))))

(defun glasspane-org--planning-day (spec)
  "Resolve a query date SPEC to an absolute day number.
SPEC is `today', an integer offset in days from today, or a date
string org can read (\"2026-07-05\")."
  (cond
   ((eq spec 'today) (org-today))
   ((integerp spec) (+ (org-today) spec))
   ((stringp spec) (org-time-string-to-absolute spec))
   (t (user-error "Unsupported query date %S" spec))))

(defun glasspane-org--planning-match-p (which args)
  "Match the WHICH (\"SCHEDULED\"/\"DEADLINE\") stamp at point against ARGS.
ARGS is an org-ql-style plist of :on / :from / :to date specs; empty
ARGS matches mere presence of the stamp."
  (let ((ts (org-entry-get (point) which)))
    (and ts
         (let ((day (org-time-string-to-absolute ts)))
           (cl-loop for (key spec) on args by #'cddr
                    always (pcase key
                             (:on (= day (glasspane-org--planning-day spec)))
                             (:from (>= day (glasspane-org--planning-day spec)))
                             (:to (<= day (glasspane-org--planning-day spec)))
                             (_ (user-error "Unsupported %s option %s"
                                            (downcase which) key))))))))

(defun glasspane-org--search-fallback (tree)
  "Run parsed query TREE over the agenda files without org-ql."
  (let (items)
    (org-map-entries
     (lambda ()
       (when (glasspane-org--query-match-p tree)
         (push (glasspane-org--heading-item-at) items)))
     nil 'agenda)
    (nreverse items)))

(defun glasspane-org--query (tree)
  "Run parsed query sexp TREE over the agenda files; heading items.
The engine behind search and every saved/derived view: `org-ql' when
installed, the built-in interpreter otherwise.  Signals `user-error'
on unsupported terms.  Memoised; see `glasspane-org-cache-invalidate'."
  (when tree
    (glasspane-org--with-cache
        (glasspane-org--cache-key 'query (format "%S" tree))
      (if (fboundp 'org-ql-select)
          (condition-case err
              (org-ql-select (org-agenda-files) tree
                             :action #'glasspane-org--heading-item-at)
            (user-error (signal (car err) (cdr err)))
            (error (user-error "Query failed: %s" (error-message-string err))))
        (glasspane-org--search-fallback tree)))))

(defun glasspane-org--search (query)
  "Search agenda files for QUERY; return a list of heading items.
QUERY may be an org-ql sexp, filter tokens, or free text — see
`glasspane-org--parse-query'.  Signals `user-error' on queries that
don't parse or use unsupported terms, so callers can surface the
problem."
  (glasspane-org--query (glasspane-org--parse-query query)))

(defun glasspane-org--filter-items (items query)
  "ITEMS whose headings match QUERY — the sparse filter.
QUERY takes the standard search syntax; matching runs the built-in
matcher at each item's own heading, so it works on any file, agenda
or not.  Signals `user-error' on queries that don't parse or use
unsupported terms."
  (let ((tree (glasspane-org--parse-query query)))
    (if (null tree)
        items
      (cl-remove-if-not
       (lambda (item)
         (let ((file (alist-get 'file item))
               (pos (alist-get 'pos item)))
           (and file pos
                (with-current-buffer (find-file-noselect file)
                  (org-with-wide-buffer
                   (goto-char (min pos (point-max)))
                   (unless (org-at-heading-p)
                     (ignore-errors (org-back-to-heading t)))
                   (glasspane-org--query-match-p tree))))))
       items))))

(defun glasspane-org--all-tags ()
  "Sorted tags for the query builder.
Combines `org-tag-alist' (the configured vocabulary) with every tag
actually used in the agenda files.  Memoised; see
`glasspane-org-cache-invalidate'."
  (glasspane-org--with-cache (glasspane-org--cache-key 'all-tags)
    (let ((tags nil))
      (dolist (entry org-tag-alist)
        (let ((tg (if (consp entry) (car entry) entry)))
          (when (stringp tg) (push tg tags))))
      (dolist (entry (org-global-tags-completion-table))
        (when (stringp (car entry)) (push (car entry) tags)))
      (sort (delete-dups tags) #'string-lessp))))

(defun glasspane-org--file-list ()
  "List of agenda files and basic stats."
  (mapcar (lambda (f) 
            `((file . ,f)
              (name . ,(file-name-nondirectory f))))
          (org-agenda-files)))

(defun glasspane-org--heading-at (pos file)
  "Get full heading detail at POS in FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (let* ((components (org-heading-components))
             (todo (nth 2 components))
             (priority (nth 3 components))
             (headline (nth 4 components))
             (tags (org-get-tags))
             (props (org-entry-properties))
             ;; Basic body extraction:
             (end (save-excursion (org-end-of-subtree t t)))
             (body-start (save-excursion (forward-line 1) (point)))
             (body (if (< body-start end)
                       (buffer-substring-no-properties body-start end)
                     "")))
        `((headline . ,headline)
          (todo . ,todo)
          (priority . ,(if priority (char-to-string priority) nil))
          (tags . ,(vconcat tags))
          (properties . ,props)
          (body . ,body))))))

(defun glasspane-org--parse-template-prompts (template-string)
  "Return the ordered field names to collect for TEMPLATE-STRING.
Each `%^{NAME}' or `%^{NAME|default}' contributes NAME (the default is
dropped from the label but honoured at fill time). A `%?' body position
adds a leading \"Headline\" field. Duplicates are removed."
  (let (prompts (start 0))
    (while (string-match "%\\^{\\([^}]+\\)}" template-string start)
      ;; Capture the match BEFORE `split-string' runs — it calls `string-match'
      ;; internally and would clobber the match data, leaving `match-end' wrong
      ;; and the loop spinning forever.
      (let ((spec (match-string 1 template-string))
            (end (match-end 0)))
        (push (string-trim (car (split-string spec "|"))) prompts)
        (setq start end)))
    (setq prompts (nreverse prompts))
    (delete-dups
     (if (string-match-p "%\\?" template-string)
         (cons "Headline" prompts)
       prompts))))

(defun glasspane-org--capture-templates ()
  "Return list of capture templates."
  (mapcar (lambda (tmpl)
            (let ((key (nth 0 tmpl))
                  (desc (nth 1 tmpl))
                  (template-string (nth 4 tmpl)))
              `((key . ,key)
                (description . ,desc)
                (prompts . ,(vconcat (glasspane-org--parse-template-prompts 
                                      (if (stringp template-string) template-string "")))))))
          org-capture-templates))

(defun glasspane-org--fill-template (tmpl values)
  "Fill org capture TMPL string from VALUES (NAME -> user input alist).
`%?' becomes the Headline value; each `%^{NAME|default}' becomes the user
value for NAME, else its default, else empty. Any *other* interactive
escape that survives (`%^{…}' with no value, `%^t', `%^g', …) is then
stripped, so `org-capture' can never block on a minibuffer prompt — which
on the phone would hang behind the bridge."
  (let ((headline (or (cdr (assoc "Headline" values)) "")))
    ;; %? — free-form body position.
    (setq tmpl (replace-regexp-in-string "%\\?" headline tmpl t t))
    ;; %^{NAME|default} — scan the template's own tokens so NAME always
    ;; matches what `glasspane-org--parse-template-prompts' produced.
    (setq tmpl (replace-regexp-in-string
                "%\\^{\\([^}]*\\)}"
                (lambda (m)
                  ;; M is the whole "%^{ … }" match; parse it directly rather
                  ;; than via match-data (unreliable inside this callback).
                  (let* ((spec (substring m 3 -1))
                         (bar (string-search "|" spec))
                         (name (string-trim (if bar (substring spec 0 bar) spec)))
                         (default (and bar (substring spec (1+ bar))))
                         (val (cdr (assoc name values))))
                    (cond ((and (stringp val) (not (string-empty-p val))) val)
                          ((stringp default) default)
                          (t ""))))
                tmpl t t))
    ;; Neutralise any remaining caret (interactive) escapes; leave plain
    ;; ones like %U %t %i %a for org to expand non-interactively.
    (replace-regexp-in-string "%\\^.?" "" tmpl t t)))

(defun glasspane-org--do-capture (template-key values &optional extra-body)
  "Run capture for TEMPLATE-KEY with VALUES alist (NAME -> user input).
EXTRA-BODY, when non-empty, is appended below the filled template —
the carrier for text shared from another app via the share sheet."
  (let ((entry (assoc template-key org-capture-templates)))
    (when entry
      (let* ((tmpl (nth 4 entry))
             (filled (if (stringp tmpl)
                         (glasspane-org--fill-template tmpl values)
                       tmpl))
             (filled (if (and (stringp filled)
                              (stringp extra-body)
                              (not (string-empty-p (string-trim extra-body))))
                         (concat filled "\n" (string-trim extra-body))
                       filled))
             ;; Shallow-copy the entry, swap in the filled template, and force
             ;; :immediate-finish so the capture buffer never waits for the
             ;; C-c C-c a phone user can't press.
             (new-entry (copy-sequence entry)))
        (setcar (nthcdr 4 new-entry) filled)
        (setcdr (nthcdr 4 new-entry)
                (append (nthcdr 5 new-entry) '(:immediate-finish t)))
        ;; `org-capture-entry' short-circuits template selection inside
        ;; `org-capture', so binding it to the FILLED copy is what makes the
        ;; pre-filled template the one that actually runs.  (Binding it to
        ;; the original — as this code once did — re-ran the raw %^{...}
        ;; prompts and double-asked the user through the bridge.)
        (let ((org-capture-entry new-entry))
          ;; Safety net: a fully pre-filled template shouldn't prompt at all,
          ;; but if any escape slips through, never let `org-capture' block
          ;; Emacs forever on a minibuffer the phone can't answer. `with-timeout'
          ;; fires even while a synchronous read is waiting.
          (with-timeout (30 (message "eabp: capture timed out (a prompt was left unanswered)"))
            (org-capture)))))))

(defun glasspane-org--item-hm (time)
  "Normalize an agenda item's raw `time' property to \"HH:MM\", or nil.
The property comes straight from the agenda's time grid and looks like
\" 9:15......\" or \"14:00-15:00\" — leading space, no zero padding,
grid filler dots."
  (when (stringp time)
    (let ((s (string-trim time)))
      (when (string-match "\\`\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)" s)
        (format "%02d:%s"
                (string-to-number (match-string 1 s))
                (match-string 2 s))))))

(defun glasspane-org--upcoming-reminders (&optional horizon-hours)
  "Timed agenda items within HORIZON-HOURS (default 24) as reminder specs.
Only items with a clock time qualify (a date alone isn't an alarm).
Each spec is ((id . STR) (at_ms . MS) (title . STR) (body . STR)),
ready for the companion's `reminders.set' frame."
  (let* ((horizon (* (or horizon-hours 24) 3600))
         (now (float-time))
         (items (append (glasspane-org--agenda-items 'day nil)
                        (glasspane-org--agenda-items
                         'day (format-time-string "%Y-%m-%d"
                                                  (time-add nil 86400)))))
         reminders)
    (dolist (it items)
      (let ((date (alist-get 'date it))
            (hm (glasspane-org--item-hm (alist-get 'time it)))
            (headline (alist-get 'headline it))
            (type (alist-get 'type it)))
        (when (and (stringp date) hm)
          (let ((at (float-time (org-time-string-to-time
                                 (concat date " " hm)))))
            (when (and (> at now) (< (- at now) horizon))
              (push `((id . ,(format "%s/%s" date (or headline "?")))
                      (at_ms . ,(truncate (* at 1000)))
                      (title . ,(or headline "Org reminder"))
                      (body . ,(concat hm (when (stringp type)
                                            (concat " · " type)))))
                    reminders))))))
    (nreverse reminders)))

(defun glasspane-org--clock-status ()
  "Current clock status."
  (when (org-clock-is-active)
    `((task . ,org-clock-current-task)
      (start . ,(float-time org-clock-start-time))
      (file . ,(buffer-file-name (marker-buffer org-clock-marker)))
      (pos . ,(marker-position org-clock-marker)))))

(defun glasspane-org--recent-clocks (n)
  "Last N clocked tasks."
  (let (items)
    (dolist (m org-clock-history)
      (when (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (goto-char m)
            (let* ((components (org-heading-components))
                   (headline (nth 4 components)))
              (push `((headline . ,headline)
                      (file . ,(buffer-file-name))
                      (pos . ,(marker-position m))
                      (ref . ,(glasspane-org--heading-ref)))
                    items))))))
    (cl-subseq (nreverse items) 0 (min n (length items)))))

;; ─── Automated Timestamps ───────────────────────────────────────────────────

(defun glasspane-org--timestamp-string ()
  "Return the current time formatted as an inactive Org timestamp."
  (format-time-string "[%Y-%m-%d %a %H:%M]"))

(defun glasspane-org--before-save-timestamps ()
  "Update #+MODIFIED and ensure #+CREATED at the file level on save."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        ;; Update #+MODIFIED if present
        (when (re-search-forward "^[ \t]*#\\+MODIFIED:[ \t]*\\(.*\\)$" nil t)
          (replace-match (glasspane-org--timestamp-string) t t nil 1))
        
        (goto-char (point-min))
        ;; Add #+CREATED to titled note files only.  Inserting front
        ;; matter into a plain org buffer (agenda file, table, config)
        ;; grows it at the top and invalidates the buffer positions any
        ;; in-flight position-based action was rendered with, so gate on
        ;; a #+TITLE — the marker of a note document.
        (when (and (not (re-search-forward "^[ \t]*#\\+CREATED:" nil t))
                   (progn (goto-char (point-min))
                          (re-search-forward "^[ \t]*#\\+TITLE:.*$" nil t)))
          (forward-line 1)
          (insert (format "#+CREATED: %s\n" (glasspane-org--timestamp-string))))))))

(add-hook 'before-save-hook #'glasspane-org--before-save-timestamps)

(defun glasspane-org--heading-created-property ()
  "Add a :CREATED: property to new headings."
  (org-set-property "CREATED" (glasspane-org--timestamp-string)))

(add-hook 'org-insert-heading-hook #'glasspane-org--heading-created-property)

(defun glasspane-org--heading-modified-property (property &rest _)
  "Update :MODIFIED: property when any other property changes."
  (when (and (stringp property)
             (not (equal property "MODIFIED"))
             (not (equal property "CREATED")))
    (let ((org-property-changed-functions nil))
      (org-set-property "MODIFIED" (glasspane-org--timestamp-string)))))

(add-hook 'org-property-changed-functions #'glasspane-org--heading-modified-property)

(add-hook 'org-after-todo-state-change-hook
          (lambda ()
            (let ((org-property-changed-functions nil))
              (org-set-property "MODIFIED" (glasspane-org--timestamp-string)))))

(provide 'glasspane-org)
;;; glasspane-org.el ends here
