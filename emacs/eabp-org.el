;;; eabp-org.el --- EABP Org-Mode Data Extraction -*- lexical-binding: t; -*-

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

(defvar eabp-org--inhibit-save-refresh nil
  "When non-nil, the `after-save-hook' dashboard refresh is suppressed.
Bound around our own programmatic saves (heading edits, file saves) so an
explicit dashboard push isn't doubled by the save-hook firing on top.")

(defun eabp-org-cache-invalidate ()
  "Invalidate any memoised org extractions.
The data readers below (`eabp-org--agenda-items', `eabp-org--todo-items',
…) currently recompute straight from the org buffers on every call, so
there is nothing to drop — this is a no-op kept as the single seam every
mutation path already calls, so a future memoisation layer can hook in
here without touching the call sites."
  nil)

;; ─── Heading references ────────────────────────────────────────────────────────
;;
;; Every heading the UI lists carries a `ref' — a small, JSON-safe alist that
;; lets a later action (drill-in, todo-set, schedule, clock-in) find the same
;; heading again. The round-trip is: build with `eabp-org--heading-ref' while
;; point is on the heading, ship it to the device inside an action's `:args',
;; and resolve it back to a live marker with `eabp-org--resolve-ref'.

(defun eabp-org--heading-ref ()
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

(defun eabp-org--resolve-ref (ref)
  "Resolve REF to a live marker at its org heading, or signal an error.
REF is an alist as built by `eabp-org--heading-ref' (extra keys such as a
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

(defun eabp-org--agenda-items (&optional span start-day)
  "Extract agenda items for SPAN ('day, 'week, or 'month).
START-DAY is an optional string (e.g. \"2026-11-01\") to start the agenda on.
Returns a list of alists representing agenda items."
  (let ((org-agenda-span (or span 'day))
        (org-agenda-start-day start-day)
        (org-agenda-files (org-agenda-files))
        (inhibit-redisplay t)
        items)
    (save-window-excursion
      (let ((org-agenda-window-setup 'current-window))
        (org-agenda nil "a")
        (with-current-buffer org-agenda-buffer-name
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((marker (get-text-property (point) 'org-marker))
                   (tags (get-text-property (point) 'tags))
                   (time (get-text-property (point) 'time))
                   (type (get-text-property (point) 'type))
                   (date-abs (get-text-property (point) 'date))
                   (date-list (when date-abs (calendar-gregorian-from-absolute date-abs)))
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
                              (ref . ,(eabp-org--heading-ref)))
                            items))))))
            (forward-line 1))))
      (kill-buffer org-agenda-buffer-name))
    (nreverse items)))

(defun eabp-org--todo-items (&optional files)
  "Extract TODO items from FILES (or agenda files)."
  (let (items)
    (org-map-entries
     (lambda ()
       (let* ((components (org-heading-components))
              (todo (nth 2 components))
              (priority (nth 3 components))
              (headline (nth 4 components))
              (tags (org-get-tags)))
         (when todo
           (push `((headline . ,headline)
                   (todo . ,todo)
                   (priority . ,(if priority (char-to-string priority) nil))
                   (tags . ,(vconcat tags))
                   (file . ,(buffer-file-name))
                   (pos . ,(point))
                   (ref . ,(eabp-org--heading-ref)))
                 items))))
     "TODO<>\"\"" (or files 'agenda))
    (nreverse items)))

(defun eabp-org--heading-item-at ()
  "Build a heading item alist for the org entry at point.
Same shape as `eabp-org--todo-items' entries (headline/todo/priority/
tags/file/pos/ref); used by the search layer."
  (let* ((components (org-heading-components))
         (todo (nth 2 components))
         (priority (nth 3 components))
         (headline (nth 4 components))
         (tags (org-get-tags)))
    `((headline . ,headline)
      (todo . ,todo)
      (priority . ,(if priority (char-to-string priority) nil))
      (tags . ,(vconcat tags))
      (file . ,(buffer-file-name))
      (pos . ,(point))
      (ref . ,(eabp-org--heading-ref)))))

(defun eabp-org--search-substring (query)
  "Case-insensitive substring search of agenda files for QUERY.
Matches headline text or any tag. Returns a list of heading items."
  (let ((q (downcase (string-trim query))) items)
    (org-map-entries
     (lambda ()
       (let* ((comps (org-heading-components))
              (headline (downcase (or (nth 4 comps) "")))
              (tags (org-get-tags)))
         (when (or (string-search q headline)
                   (cl-some (lambda (tg) (string-search q (downcase tg))) tags))
           (push (eabp-org--heading-item-at) items))))
     nil 'agenda)
    (nreverse items)))

(defun eabp-org--search (query)
  "Search agenda files for QUERY; return a list of heading items.
Uses `org-ql' when available, falling back to a substring match."
  (if (string-empty-p (string-trim query))
      nil
    (let ((ql-query (if (and (stringp query) (string-prefix-p "(" (string-trim query)))
                        (condition-case nil (read query) (error query))
                      query)))
      (if (fboundp 'org-ql-select)
          (condition-case nil
              (org-ql-select (org-agenda-files) ql-query
                             :action #'eabp-org--heading-item-at)
            (error (eabp-org--search-substring query)))
        (eabp-org--search-substring query)))))

(defun eabp-org--file-list ()
  "List of agenda files and basic stats."
  (mapcar (lambda (f) 
            `((file . ,f)
              (name . ,(file-name-nondirectory f))))
          (org-agenda-files)))

(defun eabp-org--heading-at (pos file)
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

(defun eabp-org--parse-template-prompts (template-string)
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

(defun eabp-org--capture-templates ()
  "Return list of capture templates."
  (mapcar (lambda (tmpl)
            (let ((key (nth 0 tmpl))
                  (desc (nth 1 tmpl))
                  (template-string (nth 4 tmpl)))
              `((key . ,key)
                (description . ,desc)
                (prompts . ,(vconcat (eabp-org--parse-template-prompts 
                                      (if (stringp template-string) template-string "")))))))
          org-capture-templates))

(defun eabp-org--fill-template (tmpl values)
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
    ;; matches what `eabp-org--parse-template-prompts' produced.
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

(defun eabp-org--do-capture (template-key values)
  "Run capture for TEMPLATE-KEY with VALUES alist (NAME -> user input)."
  (let ((org-capture-entry (assoc template-key org-capture-templates)))
    (when org-capture-entry
      (let* ((tmpl (nth 4 org-capture-entry))
             (new-tmpl (if (stringp tmpl)
                           (eabp-org--fill-template tmpl values)
                         tmpl)))
        (let* ((new-entry (copy-sequence org-capture-entry))
               (org-capture-templates (list new-entry)))
          (setcar (nthcdr 4 new-entry) new-tmpl)
          ;; Safety net: a fully pre-filled template shouldn't prompt at all,
          ;; but if any escape slips through, never let `org-capture' block
          ;; Emacs forever on a minibuffer the phone can't answer. `with-timeout'
          ;; fires even while a synchronous read is waiting.
          (with-timeout (30 (message "eabp: capture timed out (a prompt was left unanswered)"))
            (org-capture nil template-key)
            ;; Auto-finish capture for headless flow
            (org-capture-finalize)))))))

(defun eabp-org--clock-status ()
  "Current clock status."
  (when (org-clock-is-active)
    `((task . ,org-clock-current-task)
      (start . ,(float-time org-clock-start-time))
      (file . ,(buffer-file-name (marker-buffer org-clock-marker)))
      (pos . ,(marker-position org-clock-marker)))))

(defun eabp-org--recent-clocks (n)
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
                      (ref . ,(eabp-org--heading-ref)))
                    items))))))
    (cl-subseq (nreverse items) 0 (min n (length items)))))

(provide 'eabp-org)
;;; eabp-org.el ends here
