;;; jetpacs-results.el --- Generic results/loci navigator (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: the `next-error' protocol is the substrate under every
;; "list of loci → jump into a source buffer" mode — occur, grep/rgrep
;; and compilation (grep-mode derives from compilation-mode, so it is
;; covered for free), xref, and anything else built on them.  ONE skin
;; renders them all as tappable cards, the same bet jetpacs-tablist makes
;; on tabulated-list-mode and jetpacs-comint makes on comint-mode.
;;
;; Under the Tier 0 generic renderer these buffers already render and
;; their rows are already tappable — but a tap runs the mode's own visit
;; command, which pops a *desktop* window and leaves the phone sitting on
;; the results buffer.  This substrate re-points the tap at the phone: it
;; follows the locus and shows the *source location* in the companion's
;; buffer view (narrowed around the line, scrolled to it), reusing the
;; same host seam files.grep-visit already uses.
;;
;; The visit mechanism is uniform and parses no mode internals: place
;; point on the locus row, run the row's own RET/mouse-2 command (from its
;; text-property keymap, else the major-mode map) with the buffer-display
;; functions shimmed so nothing pops a desktop window, and read where
;; point lands.  Whatever `occur'/`compile'/`xref' would have visited is
;; exactly where the phone is taken.
;;
;; Host seam (this module depends on no UI layer): the source location is
;; shown through `jetpacs-results-visit-region-function', which the buffer
;; view host (jetpacs-emacs-ui) points at its region view — the same
;; indirection `jetpacs-files-view-region-function' uses.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)   ; jetpacs-defaction / jetpacs-action
(require 'jetpacs-buffer)     ; jetpacs-render-buffer-register

;; ─── Configuration and host seam ─────────────────────────────────────────────

(defcustom jetpacs-results-max-loci 300
  "Maximum locus cards rendered from one results buffer.
A huge grep/compilation buffer is capped with a trailing note; the row
count in the header still reflects the true total."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-results-context-lines 100
  "Lines of source context shown below a visited locus.
The region view opens a window starting `jetpacs-results-context-before'
lines above the locus and running this many lines past it, so the hit and
its surroundings are visible without the buffer view's from-the-top cap."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-results-context-before 20
  "Lines of source context shown above a visited locus."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-results-visit-region-function
  (lambda (name &rest _) (message "Jetpacs: no host to view %s" name))
  "Function of (BUFFER-NAME BEG END LABEL &optional POINT) showing a
buffer slice with POINT's line as the scroll target.  Set by the buffer
view host (jetpacs-emacs-ui); kept as a seam so this module never depends
on the UI layer.")

;; Modes this substrate skins.  compilation-mode covers grep-mode, rgrep,
;; and any `define-compilation-mode' derivative by derivation; occur and
;; the xref results buffer are their own modes.  The list also gates the
;; visit action: an arbitrary buffer name off the wire can only ever reach
;; a buffer that is actually one of these results modes.
(defconst jetpacs-results-modes
  '(occur-mode compilation-mode xref--xref-buffer-mode)
  "Major modes rendered and visited as loci by this substrate.")

(defun jetpacs-results--buffer-p (buf)
  "Non-nil when BUF is live and one of `jetpacs-results-modes'."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (apply #'derived-mode-p jetpacs-results-modes))))

;; ─── Reading the loci ─────────────────────────────────────────────────────────

(defun jetpacs-results--locus-pos (bol eol)
  "Return the position on line [BOL, EOL) carrying a jump, or nil.
Generic across the family: occur marks matches with `occur-target',
compilation with `compilation-message', xref rows are `button's, and any
mode may carry a `mouse-face'/text-property keymap over the loci.  Checks
the line start first (where all three put the property) then the first
non-blank char, so an indented or mid-line marker is still found."
  (cl-flet ((jump-at (p)
              (and (< p eol)
                   (or (get-text-property p 'occur-target)
                       (get-text-property p 'compilation-message)
                       (get-text-property p 'xref-item)
                       (get-char-property p 'button)
                       (get-char-property p 'mouse-face)
                       (let ((km (or (get-char-property p 'keymap)
                                     (get-char-property p 'local-map))))
                         (and (keymapp km)
                              (or (lookup-key km (kbd "RET"))
                                  (lookup-key km [return])
                                  (lookup-key km [mouse-2]))))))))
    (cond
     ((jump-at bol) bol)
     (t (let ((p (save-excursion
                   (goto-char bol)
                   (skip-chars-forward " \t" eol)
                   (point))))
          (and (> p bol) (jump-at p) p))))))

(defun jetpacs-results--loci (buf)
  "Collect (POS . TEXT) for each locus row of results buffer BUF.
POS is the actionable position on the line; TEXT is the trimmed line.
Walking the printed buffer respects the mode's current ordering/filtering."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let (loci)
        (while (not (eobp))
          (let* ((bol (line-beginning-position))
                 (eol (line-end-position))
                 (pos (and (> eol bol) (jetpacs-results--locus-pos bol eol))))
            (when pos
              (push (cons pos (string-trim
                               (buffer-substring-no-properties bol eol)))
                    loci)))
          (forward-line 1))
        (nreverse loci)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-results--card (name pos text)
  "A tappable card for the locus at POS in results buffer NAME."
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-box (list (jetpacs-rich-text
                           (list (jetpacs-span (if (string-empty-p text) " " text)
                                            :mono t))))
                    :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap (jetpacs-action "results.visit"
                        :args `((buffer . ,name) (pos . ,pos))
                        :when-offline "drop")))

(defun jetpacs-results-render (buf)
  "Tier-1 skin: results BUF as a count header + one tappable card per locus.
Returns a list of SDUI nodes, per the `jetpacs-render-buffer' contract."
  (with-current-buffer buf
    (let* ((name (buffer-name buf))
           (loci (jetpacs-results--loci buf))
           (total (length loci))
           (shown (if (> total jetpacs-results-max-loci)
                      (cl-subseq loci 0 jetpacs-results-max-loci)
                    loci)))
      (if (null loci)
          ;; No parsed loci — the mode may be mid-run (an empty *grep*),
          ;; or nothing matched.  Fall back to the faithful Tier 0 text so
          ;; the buffer is never blank.
          (jetpacs-buffer-render buf)
        (append
         (list (jetpacs-text
                (format "%d result%s" total (if (= total 1) "" "s"))
                'caption))
         (mapcar (lambda (l) (jetpacs-results--card name (car l) (cdr l))) shown)
         (when (> total (length shown))
           (list (jetpacs-text
                  (format "Showing %d of %d — narrow the search."
                          (length shown) total)
                  'caption))))))))

(dolist (mode jetpacs-results-modes)
  (jetpacs-render-buffer-register mode #'jetpacs-results-render))

;; ─── Visiting a locus ─────────────────────────────────────────────────────────

(defun jetpacs-results--visit-command (pos)
  "The visit command for the locus at POS: text-prop keymap, else major map.
occur/compilation/xref all bind RET (and mouse-2) to their goto command;
compilation additionally carries a text-property keymap over each error."
  (let ((km (or (get-char-property pos 'keymap)
                (get-char-property pos 'local-map))))
    (or (and (keymapp km)
             (or (lookup-key km (kbd "RET"))
                 (lookup-key km [return])
                 (lookup-key km [mouse-2])))
        (let ((maj (current-local-map)))
          (and maj
               (or (lookup-key maj (kbd "RET"))
                   (lookup-key maj [return])
                   (lookup-key maj [mouse-2])))))))

(defun jetpacs-results--follow (buf pos)
  "Follow the locus at POS in results BUF; return (DEST-BUFFER . DEST-POS) or nil.
Runs the row's own goto command with the buffer-display functions shimmed
so nothing pops a desktop window and the user's Emacs layout is untouched
\(`save-window-excursion'); reads where point lands.  Returns nil when the
command doesn't leave the results buffer (e.g. the target file is gone)."
  (with-current-buffer buf
    (goto-char (min (max (point-min) pos) (point-max)))
    (let ((cmd (jetpacs-results--visit-command (point)))
          dest-buf dest-pos)
      (when (commandp cmd)
        (save-window-excursion
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                    ((symbol-function 'pop-to-buffer-same-window)
                     (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                    ((symbol-function 'switch-to-buffer)
                     (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                    ((symbol-function 'switch-to-buffer-other-window)
                     (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer))))
            (condition-case nil
                (call-interactively cmd)
              (error nil))
            (setq dest-buf (current-buffer) dest-pos (point)))))
      ;; A visit that never left the results buffer is a failure, not a jump.
      (and dest-buf (not (eq dest-buf buf)) (cons dest-buf dest-pos)))))

(defun jetpacs-results--region-around (buf pos)
  "Return (BEG END LABEL POINT) framing POS in BUF for the region view.
The window runs `jetpacs-results-context-before' lines above POS and
`jetpacs-results-context-lines' past it; LABEL is \"buffer:line\"."
  (with-current-buffer buf
    (save-excursion
      (goto-char (min (max (point-min) pos) (point-max)))
      (let* ((line (line-number-at-pos))
             (target (line-beginning-position))
             (beg (save-excursion (forward-line (- jetpacs-results-context-before))
                                  (point)))
             (end (save-excursion
                    (forward-line (1+ jetpacs-results-context-lines))
                    (point))))
        (list beg end (format "%s:%d" (buffer-name buf) line) target)))))

(jetpacs-defaction "results.visit"
  ;; Show a locus in context: follow it (reusing the mode's own goto
  ;; command, shimmed so nothing pops a desktop window) and open the
  ;; source location in the buffer view, narrowed and scrolled to the
  ;; line.  The buffer must be one of `jetpacs-results-modes', so a name
  ;; off the wire can only ever drive a real results buffer's own visit.
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) "")))
          (pos (alist-get 'pos args)))
      (cond
       ((not (jetpacs-results--buffer-p buf))
        (message "%s is not a results buffer" (alist-get 'buffer args)))
       ((not (numberp pos))
        (message "results.visit: bad position"))
       (t
        (let ((dest (ignore-errors (jetpacs-results--follow buf pos))))
          (if (null dest)
              (message "Couldn't open that location")
            (pcase-let ((`(,beg ,end ,label ,point)
                         (jetpacs-results--region-around (car dest) (cdr dest))))
              (funcall jetpacs-results-visit-region-function
                       (buffer-name (car dest)) beg end label point)))))))))

(provide 'jetpacs-results)
;;; jetpacs-results.el ends here
