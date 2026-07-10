;;; jetpacs-complete.el --- Completion-at-point bridge (Tier 0 IDE) -*- lexical-binding: t; -*-

;; Brings Emacs completion to the phone editor.  The companion sends an
;; `edit.complete' action with a window of the editor's text and the cursor
;; position; this module replays that text into a hidden shadow buffer with
;; the file's major mode, runs the buffer's own
;; `completion-at-point-functions', and replies with a `completions.show'
;; frame carrying the completed prefix plus candidate labels/annotations.
;; The phone renders them as a suggestion strip above the keyboard and
;; applies the accepted candidate locally — no round-trip on insert.
;;
;; Corfu/company/posframe never enter the picture: they are UIs over capf,
;; and the phone brings its own UI.  Emacs is the completion *server*.
;;
;; The shadow buffer never visits the file (no disk access, no LSP session,
;; no mode hooks — see `delay-mode-hooks' below), so a completion request
;; can't mutate anything.  This keeps the command-dispatch boundary intact:
;; `edit.complete' is a pure query.
;;
;; v2 (planned): incremental delta sync into the shadow buffer + eglot
;; integration, turning Emacs into a language-server multiplexer for the
;; phone.  The wire shapes here are designed to survive that upgrade.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-surfaces)
(require 'jetpacs-sync)

(defcustom jetpacs-complete-enabled t
  "When non-nil, the phone editor offers Emacs-backed completion.
Set to nil to stop the companion from issuing completion requests
entirely (the editor node is pushed without its `complete' flag)."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-complete-max-candidates 30
  "Maximum number of candidates returned per completion request.
The phone strip shows a handful; anything past this cap is wasted
bytes on the wire."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-complete-debug nil
  "When non-nil, echo each completion request to *Messages*.
Each `edit.complete' from the phone logs the file, the prefix it
resolved, and how many candidates it returned — a live trace of the
bridge working, without a device attached to logcat.  Development aid;
leave nil in normal use."
  :type 'boolean :group 'jetpacs)

;; ─── Shadow buffers ──────────────────────────────────────────────────────────

(defun jetpacs-complete--shadow-buffer (file)
  "Get or create the hidden shadow buffer for FILE.
The buffer carries FILE's major mode so the right capfs are live, but
mode hooks are delayed: no LSP client, flycheck, or other machinery
spins up over a throwaway completion buffer.  The leading space in the
name keeps it out of buffer lists and disables undo."
  (let ((name (format " *jetpacs-complete: %s*" file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (condition-case nil
              (delay-mode-hooks (funcall (jetpacs-sync--mode-for file)))
            (error (delay-mode-hooks (fundamental-mode))))
          (run-hooks 'jetpacs-sync-shadow-setup-hook)
          (current-buffer)))))

;; ─── Candidate harvesting ────────────────────────────────────────────────────

(defun jetpacs-complete--capf-data ()
  "Run the buffer's capfs at point; return (BEG END TABLE . PROPS) or nil.
A capf that signals — e.g. text-mode's `ispell-completion-at-point'
with no dictionary installed — counts as producing nothing, so the
generic word fallback still gets its turn."
  (let ((res (condition-case nil
                 (run-hook-wrapped 'completion-at-point-functions
                                   #'completion--capf-wrapper 'all)
               (error nil))))
    (when (and (consp res) (consp (cdr res)) (numberp (cadr res)))
      (cdr res))))

(defun jetpacs-complete--word-fallback ()
  "Dabbrev-style fallback: words in the buffer sharing the token at point.
Returns (PREFIX . CANDIDATES) or nil.  Used when no capf produces
anything — plain text, org prose, unknown modes — so the strip is never
uselessly empty in a buffer full of repeated identifiers."
  (let* ((end (point))
         (beg (save-excursion (skip-syntax-backward "w_") (point))))
    (when (< beg end)
      (let ((prefix (buffer-substring-no-properties beg end))
            (case-fold-search nil)
            cands)
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward
                  (concat "\\_<" (regexp-quote prefix) "\\(?:\\sw\\|\\s_\\)+")
                  nil t)
            ;; Skip the token being completed itself.
            (unless (= (match-beginning 0) beg)
              (cl-pushnew (match-string-no-properties 0) cands :test #'equal))))
        (when cands (cons prefix (nreverse cands)))))))

(defun jetpacs-complete--annotate (fn cand)
  "Apply annotation function FN to CAND, trimmed; nil when absent or failing."
  (when fn
    (let ((a (condition-case nil (funcall fn cand) (error nil))))
      (when (and (stringp a) (not (string-empty-p (string-trim a))))
        (string-trim a)))))

(defun jetpacs-complete--collect ()
  "Harvest completions at point in the current buffer.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Each candidate node is an
alist of `label' plus optional `annotation' and `kind', ready for
serialization.  Candidates are sorted shortest-first (the likeliest
next keystroke saver), capped at `jetpacs-complete-max-candidates'."
  (let* ((data (jetpacs-complete--capf-data))
         (beg (nth 0 data))
         (table (nth 2 data))
         (props (nthcdr 3 data))
         (ann-fn (plist-get props :annotation-function))
         (kind-fn (plist-get props :company-kind))
         ;; Optional capf extension (SPEC §8): what a candidate INSERTS
         ;; when it differs from its display label — a wikilink chip
         ;; shows "[[Title" but lands "[[id:…][Title]]" in the buffer.
         (insert-fn (plist-get props :jetpacs-insert-function))
         ;; The phone replaces text *before* the cursor, so the prefix is
         ;; [BEG, point) even when the capf's END extends past point.
         (prefix (and data (buffer-substring-no-properties beg (point))))
         ;; Lazy tables can signal when queried (ispell again), hence the
         ;; condition-case: a broken table degrades to the fallback.
         (cands (and prefix
                     (condition-case nil
                         (all-completions prefix table
                                          (plist-get props :predicate))
                       (error nil))))
         ;; An empty prefix is legitimate LSP member completion (right
         ;; after "." the server returns a small, precise list) but on an
         ;; unconstrained table (elisp's obarray) it means *everything* —
         ;; keep the former, drop the latter by sheer size.
         (cands (if (and cands (string-empty-p prefix)
                         (> (length cands) 500))
                    nil
                  cands)))
    ;; Empty capf result → generic word fallback (org prose, unknown modes).
    (unless cands
      (when-let ((fb (jetpacs-complete--word-fallback)))
        (setq prefix (car fb) cands (cdr fb)
              ann-fn nil kind-fn nil insert-fn nil)))
    (when cands
      (setq cands (sort (delete-dups
                         (mapcar #'substring-no-properties cands))
                        (lambda (a b) (or (< (length a) (length b))
                                          (and (= (length a) (length b))
                                               (string< a b))))))
      ;; Sole candidate == what's already typed: nothing to offer.
      (setq cands (delete prefix cands))
      (when cands
        (cons prefix
              (mapcar (lambda (c)
                        `((label . ,c)
                          ,@(when-let ((a (jetpacs-complete--annotate ann-fn c)))
                              `((annotation . ,a)))
                          ,@(when-let ((ins (and insert-fn
                                                 (condition-case nil
                                                     (funcall insert-fn c)
                                                   (error nil)))))
                              (and (stringp ins) (not (equal ins c))
                                   `((insert . ,ins))))
                          ,@(when-let ((k (and kind-fn
                                               (condition-case nil
                                                   (funcall kind-fn c)
                                                 (error nil)))))
                              `((kind . ,(symbol-name k))))))
                      (seq-take cands jetpacs-complete-max-candidates)))))))

(defun jetpacs-complete-in-text (file text cursor)
  "Complete FILE's TEXT at CURSOR (a 0-based offset into TEXT).
Replays TEXT into FILE's shadow buffer and harvests candidates there.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Separated from the action
handler so tests can call it directly.

This is the v1 windowed path, kept as the fallback for clients that
ship text with the request; the slim path is `jetpacs-complete-in-session'."
  (with-current-buffer (jetpacs-complete--shadow-buffer file)
    (erase-buffer)
    (insert text)
    (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
    (jetpacs-complete--collect)))

(defun jetpacs-complete-in-session (file session seq cursor)
  "Complete in FILE's synced session shadow at CURSOR (0-based code points).
The v2 slim path: no text crosses the wire because jetpacs-sync already
holds the whole document.  SESSION and SEQ must match the live sync
state exactly — a mismatch means the phone edited past us, so reply
nothing and ask for a resync instead of completing against stale text.
Returns (PREFIX . CANDIDATE-NODES) or nil."
  (let ((buf (jetpacs-sync-session-buffer file session seq)))
    (if (not buf)
        (progn (jetpacs-sync-request-resync file session) nil)
      (with-current-buffer buf
        (save-excursion
          (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
          (jetpacs-complete--collect))))))

;; ─── Action handler ──────────────────────────────────────────────────────────

;; Reply shape: the phone recomputes the replace range as
;; [cursor - length(prefix), cursor) in its own string units and validates
;; the prefix still sits there before applying — so no absolute offsets
;; cross the wire and a stale reply degrades to "strip doesn't show",
;; never to a wrong edit.
(jetpacs-defaction "edit.complete"
  (lambda (args _)
    (when jetpacs-complete-enabled
      (let ((file (alist-get 'file args))
            (req (alist-get 'request_id args))
            (text (alist-get 'text args))
            (session (alist-get 'session args))
            (seq (alist-get 'seq args))
            (cursor (alist-get 'cursor args)))
        (when (and (stringp file) (numberp cursor)
                   (or (stringp text) (numberp session)))
          (let ((result (condition-case err
                            (if (stringp text)
                                ;; v1: request carries its own text window.
                                (jetpacs-complete-in-text file text cursor)
                              ;; v2: complete in the jetpacs-sync shadow.
                              (jetpacs-complete-in-session file session seq cursor))
                          (error (message "Jetpacs complete failed: %s"
                                          (error-message-string err))
                                 nil))))
            (when jetpacs-complete-debug
              (if result
                  (message "Jetpacs complete: %s prefix=%S -> %d candidate(s)"
                           (file-name-nondirectory file)
                           (car result) (length (cdr result)))
                (message "Jetpacs complete: %s -> nothing to offer at cursor"
                         (file-name-nondirectory file))))
            ;; Always reply, even empty, so the phone can clear its strip.
            (jetpacs-send "completions.show"
                       `((id . ,file)
                         (request_id . ,(or req 0))
                         (prefix . ,(or (car result) ""))
                         (candidates . ,(vconcat (cdr result)))))))))))

(provide 'jetpacs-complete)
;;; jetpacs-complete.el ends here
