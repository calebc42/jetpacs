;;; eabp-complete.el --- Completion-at-point bridge (Tier 0 IDE) -*- lexical-binding: t; -*-

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
(require 'eabp)
(require 'eabp-surfaces)

(defcustom eabp-complete-enabled t
  "When non-nil, the phone editor offers Emacs-backed completion.
Set to nil to stop the companion from issuing completion requests
entirely (the editor node is pushed without its `complete' flag)."
  :type 'boolean :group 'eabp)

(defcustom eabp-complete-max-candidates 30
  "Maximum number of candidates returned per completion request.
The phone strip shows a handful; anything past this cap is wasted
bytes on the wire."
  :type 'integer :group 'eabp)

;; ─── Shadow buffers ──────────────────────────────────────────────────────────

(defun eabp-complete--mode-for (file)
  "The major mode FILE would get from `auto-mode-alist', or `fundamental-mode'.
Never visits FILE — the mode is chosen from the name alone."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (if (and (symbolp mode) mode (fboundp mode)) mode 'fundamental-mode)))

(defun eabp-complete--shadow-buffer (file)
  "Get or create the hidden shadow buffer for FILE.
The buffer carries FILE's major mode so the right capfs are live, but
mode hooks are delayed: no LSP client, flycheck, or other machinery
spins up over a throwaway completion buffer.  The leading space in the
name keeps it out of buffer lists and disables undo."
  (let ((name (format " *eabp-complete: %s*" file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (delay-mode-hooks (funcall (eabp-complete--mode-for file)))
          (current-buffer)))))

;; ─── Candidate harvesting ────────────────────────────────────────────────────

(defun eabp-complete--capf-data ()
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

(defun eabp-complete--word-fallback ()
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

(defun eabp-complete--annotate (fn cand)
  "Apply annotation function FN to CAND, trimmed; nil when absent or failing."
  (when fn
    (let ((a (condition-case nil (funcall fn cand) (error nil))))
      (when (and (stringp a) (not (string-empty-p (string-trim a))))
        (string-trim a)))))

(defun eabp-complete--collect ()
  "Harvest completions at point in the current buffer.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Each candidate node is an
alist of `label' plus optional `annotation' and `kind', ready for
serialization.  Candidates are sorted shortest-first (the likeliest
next keystroke saver), capped at `eabp-complete-max-candidates'."
  (let* ((data (eabp-complete--capf-data))
         (beg (nth 0 data))
         (table (nth 2 data))
         (props (nthcdr 3 data))
         (ann-fn (plist-get props :annotation-function))
         (kind-fn (plist-get props :company-kind))
         ;; The phone replaces text *before* the cursor, so the prefix is
         ;; [BEG, point) even when the capf's END extends past point.
         (prefix (and data (buffer-substring-no-properties beg (point))))
         ;; An empty prefix would ask the table for *everything* (the whole
         ;; obarray in elisp buffers) — cheap to refuse, useless to answer.
         ;; Lazy tables can signal when queried (ispell again), hence the
         ;; condition-case: a broken table degrades to the fallback.
         (cands (and prefix (not (string-empty-p prefix))
                     (condition-case nil
                         (all-completions prefix table
                                          (plist-get props :predicate))
                       (error nil)))))
    ;; Empty capf result → generic word fallback (org prose, unknown modes).
    (unless cands
      (when-let ((fb (eabp-complete--word-fallback)))
        (setq prefix (car fb) cands (cdr fb) ann-fn nil kind-fn nil)))
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
                          ,@(when-let ((a (eabp-complete--annotate ann-fn c)))
                              `((annotation . ,a)))
                          ,@(when-let ((k (and kind-fn
                                               (condition-case nil
                                                   (funcall kind-fn c)
                                                 (error nil)))))
                              `((kind . ,(symbol-name k))))))
                      (seq-take cands eabp-complete-max-candidates)))))))

(defun eabp-complete-in-text (file text cursor)
  "Complete FILE's TEXT at CURSOR (a 0-based offset into TEXT).
Replays TEXT into FILE's shadow buffer and harvests candidates there.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Separated from the action
handler so tests can call it directly."
  (with-current-buffer (eabp-complete--shadow-buffer file)
    (erase-buffer)
    (insert text)
    (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
    (eabp-complete--collect)))

;; ─── Action handler ──────────────────────────────────────────────────────────

;; Reply shape: the phone recomputes the replace range as
;; [cursor - length(prefix), cursor) in its own string units and validates
;; the prefix still sits there before applying — so no absolute offsets
;; cross the wire and a stale reply degrades to "strip doesn't show",
;; never to a wrong edit.
(eabp-defaction "edit.complete"
  (lambda (args _)
    (when eabp-complete-enabled
      (let ((file (alist-get 'file args))
            (req (alist-get 'request_id args))
            (text (alist-get 'text args))
            (cursor (alist-get 'cursor args)))
        (when (and (stringp file) (stringp text) (numberp cursor))
          (let ((result (condition-case err
                            (eabp-complete-in-text file text cursor)
                          (error (message "EABP complete failed: %s"
                                          (error-message-string err))
                                 nil))))
            ;; Always reply, even empty, so the phone can clear its strip.
            (eabp-send "completions.show"
                       `((id . ,file)
                         (request_id . ,(or req 0))
                         (prefix . ,(or (car result) ""))
                         (candidates . ,(vconcat (cdr result)))))))))))

(provide 'eabp-complete)
;;; eabp-complete.el ends here
