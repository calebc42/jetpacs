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
;; buffer view (narrowed around the line, scrolled to it).
;;
;; Two kinds of producer feed the same visit/stepper/seam:
;;   * buffer-loci — a position in a results buffer whose own goto command
;;     jumps to source (occur/compilation/xref).  Addressed by (buffer,pos).
;;   * file-loci  — a plain (file,line), e.g. the Files content search,
;;     handed in via `jetpacs-results-set-file-loci' and addressed by index
;;     into that server-built set (no path travels over the wire).
;;
;; The visit mechanism is uniform and parses no mode internals: place
;; point on the locus row, run the row's own RET/mouse-2 command (from its
;; text-property keymap, else the major-mode map) with the buffer-display
;; functions shimmed so nothing pops a desktop window, and read where
;; point lands.  Whatever `occur'/`compile'/`xref' would have visited is
;; exactly where the phone is taken.
;;
;; A visit arms a stepper: while you are looking at a visited locus, the
;; drill-in top bar offers prev/next-match chrome (`results.step') that
;; walks the same result set and re-navigates without a trip back to the
;; list — the touch-native form of `next-error'/`previous-error'.  The
;; host asks for that chrome through `jetpacs-results-buffer-view-actions'.
;;
;; Host seam (this module depends on no UI layer): the source location is
;; shown through `jetpacs-results-visit-region-function', the single jump
;; primitive the buffer view host (jetpacs-emacs-ui) points at its region
;; view for every producer.

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

(defvar jetpacs-results--nav nil
  "The active locus-stepper context, or nil.
A plist set by `results.visit'/`results.step': always (:kind KIND :index I
:count N :dest SRC-NAME), plus the kind-specific source to step from —
:buffer RESULTS-BUFFER-NAME for `buffer', or :loci FILE-LOCI for `file'.
While it holds and the buffer view is showing SRC-NAME's locus, the drill-in
top bar offers prev/next-match chrome (`jetpacs-results-buffer-view-actions').")

(defvar jetpacs-results--file-set nil
  "The active file-locus result set, or nil.
A list of file loci (each a plist (:file PATH :line N :text STRING)) set by
a file-producing search (e.g. the Files content search) through
`jetpacs-results-set-file-loci'.  Its result cards tap `results.visit' with
their index into this list; nothing off the wire carries a file path.")

(defun jetpacs-results-set-file-loci (loci)
  "Store LOCI as the active file-locus result set for `results.visit'.
LOCI is a list of plists (:file PATH :line N :text STRING).  A file
producer calls this as it renders its result cards (which tap
`results.visit' with the matching index), so the visit and the prev/next
stepper are shared with the buffer-backed occur/grep/xref producers."
  (setq jetpacs-results--file-set loci))

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
            ;; Goto commands like `compile-goto-error' read the triggering
            ;; event from `last-input-event' and jump to its position; a
            ;; stale pending event (a tap elsewhere, a D-Bus reply) would
            ;; hijack the jump.  This visit is driven by POS, not an event.
            (condition-case nil
                (let ((last-input-event nil)
                      (last-nonmenu-event nil))
                  (call-interactively cmd))
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

(defun jetpacs-results--index-of (loci pos)
  "Index in LOCI of the locus at POS, or 0 if not found."
  (or (cl-position pos loci :key #'car :test #'=) 0))

(defun jetpacs-results--show (dest index count nav-extra)
  "Open DEST (a (BUFFER . POS) pair) in the buffer view; arm the stepper.
Narrows to the locus, scrolls to the line, and heads the slice with an
i/N counter; NAV-EXTRA (a plist) supplies the kind-specific step source
merged into `jetpacs-results--nav'.  Returns non-nil."
  (pcase-let ((`(,beg ,end ,label ,point)
               (jetpacs-results--region-around (car dest) (cdr dest))))
    (setq jetpacs-results--nav
          (append (list :index index :count count :dest (buffer-name (car dest)))
                  nav-extra))
    (funcall jetpacs-results-visit-region-function
             (buffer-name (car dest)) beg end
             (format "%s  ·  %d/%d" label (1+ index) count)
             point)
    t))

(defun jetpacs-results--goto-buffer (results-buf loci index)
  "Visit buffer-locus LOCI[INDEX] of RESULTS-BUF; arm a `buffer'-kind nav.
Follows via the mode's own goto command (shimmed so nothing pops a desktop
window).  INDEX is clamped into the loci range."
  (let* ((count (length loci))
         (index (max 0 (min index (1- count))))
         (pos (car (nth index loci)))
         (dest (and pos (ignore-errors (jetpacs-results--follow results-buf pos)))))
    (if (null dest)
        (progn (message "Couldn't open that location") nil)
      (jetpacs-results--show dest index count
                          (list :kind 'buffer :buffer (buffer-name results-buf))))))

(defun jetpacs-results--file-dest (locus)
  "Resolve a file LOCUS (:file :line) to (BUFFER . POS), or nil.
Visits the file read-only-safely via `find-file-noselect'; nil when the
file is gone or unreadable."
  (let ((file (plist-get locus :file))
        (line (plist-get locus :line)))
    (when (and (stringp file) (file-readable-p file))
      (condition-case nil
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (save-excursion
                (goto-char (point-min))
                (forward-line (1- (max 1 (truncate (or line 1)))))
                (cons buf (point)))))
        (error nil)))))

(defun jetpacs-results--goto-file (loci index)
  "Visit file-locus LOCI[INDEX]; arm a `file'-kind nav.  INDEX is clamped."
  (let* ((count (length loci))
         (index (max 0 (min index (1- count))))
         (dest (jetpacs-results--file-dest (nth index loci))))
    (if (null dest)
        (progn (message "Couldn't open that location") nil)
      (jetpacs-results--show dest index count (list :kind 'file :loci loci)))))

(jetpacs-defaction "results.visit"
  ;; Show a locus in context and arm the stepper.  Two entry shapes:
  ;;   (buffer NAME) (pos P) — a results-mode buffer's own goto at P; NAME
  ;;     must be one of `jetpacs-results-modes', so a name off the wire can
  ;;     only ever drive a real results buffer's own visit.
  ;;   (index I)             — entry I of the active `jetpacs-results--file-set'
  ;;     (a server-built list; no path travels over the wire).
  (lambda (args _)
    (let ((buf-name (alist-get 'buffer args))
          (pos (alist-get 'pos args))
          (index (alist-get 'index args)))
      (cond
       ((and buf-name (numberp pos))
        (let ((buf (get-buffer buf-name)))
          (if (not (jetpacs-results--buffer-p buf))
              (message "%s is not a results buffer" buf-name)
            (let ((loci (jetpacs-results--loci buf)))
              (when loci
                (jetpacs-results--goto-buffer
                 buf loci (jetpacs-results--index-of loci pos)))))))
       ((numberp index)
        (let ((set jetpacs-results--file-set))
          (if (and set (>= index 0) (< index (length set)))
              (jetpacs-results--goto-file set index)
            (message "results.visit: no such result"))))
       (t (message "results.visit: nothing to visit"))))))

(jetpacs-defaction "results.step"
  ;; Step to the prev/next locus of the armed result set without returning
  ;; to the list.  DIR is +1 or -1.  Buffer-kind loci are recomputed each
  ;; step (so a reverted results buffer still steps sanely); file-kind loci
  ;; step over the snapshot armed at visit time.
  (lambda (args _)
    (let* ((nav jetpacs-results--nav)
           (dir (alist-get 'dir args)))
      (if (not (and nav (numberp dir)))
          (message "No results to step through")
        (let ((target (+ (plist-get nav :index) dir)))
          (cl-flet ((step (loci goto)
                      (cond
                       ((null loci) (message "No results"))
                       ((< target 0) (message "First match"))
                       ((>= target (length loci)) (message "Last match"))
                       (t (funcall goto loci target)))))
            (pcase (plist-get nav :kind)
              ('buffer
               (let ((buf (get-buffer (plist-get nav :buffer))))
                 (if (not (jetpacs-results--buffer-p buf))
                     (progn (setq jetpacs-results--nav nil)
                            (message "Those results are gone"))
                   (step (jetpacs-results--loci buf)
                         (lambda (loci i) (jetpacs-results--goto-buffer buf loci i))))))
              ('file
               (step (plist-get nav :loci) #'jetpacs-results--goto-file))
              (_ (message "No results to step through")))))))))

(defun jetpacs-results--nav-live-p (nav)
  "Non-nil when the stepper NAV can still step (its source survives)."
  (pcase (plist-get nav :kind)
    ('buffer (get-buffer (plist-get nav :buffer)))
    ('file (plist-get nav :loci))
    (_ nil)))

(defun jetpacs-results-buffer-view-actions (viewed-buffer-name)
  "Prev/next-match top-bar actions for the buffer view, or nil.
Returns icon-button nodes when `jetpacs-results--nav' is armed and
VIEWED-BUFFER-NAME is the source buffer the last locus visit navigated to
\(and the result set is still live); only the in-range direction is offered
at each end.  The buffer view host calls this to add stepper chrome to the
drill-in top bar — see jetpacs-emacs-ui."
  (let ((nav jetpacs-results--nav))
    (when (and nav
               (equal viewed-buffer-name (plist-get nav :dest))
               (jetpacs-results--nav-live-p nav))
      (let ((i (plist-get nav :index)) (n (plist-get nav :count)))
        (delq nil
              (list
               (when (> i 0)
                 (jetpacs-icon-button
                  "chevron_left"
                  (jetpacs-action "results.step" :args '((dir . -1))
                               :when-offline "drop")
                  :content-description (format "Previous match (%d of %d)" i n)))
               (when (< (1+ i) n)
                 (jetpacs-icon-button
                  "chevron_right"
                  (jetpacs-action "results.step" :args '((dir . 1))
                               :when-offline "drop")
                  :content-description (format "Next match (%d of %d)"
                                              (+ i 2) n)))))))))

(provide 'jetpacs-results)
;;; jetpacs-results.el ends here
