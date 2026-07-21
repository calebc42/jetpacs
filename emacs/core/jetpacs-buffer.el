;;; jetpacs-buffer.el --- Generic buffer renderer (Tier 0) -*- lexical-binding: t; -*-

;; Tier 0 of Jetpacs: render ANY Emacs buffer faithfully from its text plus its
;; text/overlay properties (face, display, invisible, keymap, button,
;; mouse-face), with interactive regions made tappable.  This is the universal
;; substrate — every major mode renders through here for free, no per-package
;; translator required.
;;
;; Per-mode "skins" (Tier 1, e.g. a hand-built org dashboard) are *opt-in*
;; overrides registered in `jetpacs-render-buffer-functions'.  Anything
;; unregistered falls through to the generic renderer below, so a new package
;; is usable on day one and only gets bespoke polish where it's worth it.
;;
;; Emacs stays the single source of truth for styling: this module resolves
;; faces to span attributes and ships them; the device only paints the spans
;; (it never re-fontifies).
;;
;; This file deliberately does NOT depend on any UI/host layer (no org-ui).
;; The only seam back to the host is `jetpacs-buffer-refresh-function', which the
;; host sets so a tap that mutates a buffer can re-push the showing surface.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)   ; jetpacs-defaction / jetpacs-action

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-buffer-max-lines 500
  "Maximum number of lines the generic renderer emits for a buffer.
Buffers longer than this are truncated (with a trailing note) so a huge
magit/log/compilation buffer can't produce an unbounded surface."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-buffer-monospace t
  "When non-nil, the generic renderer paints buffer text monospace.
Most Emacs buffers (dired, magit, tables, source) rely on column alignment,
so monospace is the faithful default.  Tier-1 skins may override per mode."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-buffer-emit-colors t
  "When non-nil, carry a face's foreground color into the rendered span.
Only colors that differ from the default face are emitted, so semantic color
\(diff add/remove, font-lock keywords, warnings) survives while ordinary body
text still uses the device theme's on-surface color."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-line-numbers nil
  "Line numbers in the generic buffer view and the phone editor.
nil shows none; `absolute' shows buffer line numbers; `relative' shows
distances from point (the current line shows its absolute number,
vim's hybrid style).  Configurable from the phone's Settings view."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Absolute" absolute)
                 (const :tag "Relative" relative))
  :group 'jetpacs)

(defconst jetpacs-buffer--line-number-color "#8A8A8A"
  "Dim gray for line-number spans; legible on light and dark themes.")

(defvar jetpacs-buffer-refresh-function nil
  "Function called with no args after an `emacs.buffer.act' mutates a buffer.
The host shell sets this to re-push whatever surface is showing the buffer.
Kept as a seam so this module never depends on a specific UI layer.")

(defvar jetpacs-buffer-span-action-function nil
  "When non-nil, a function (POS BUFFER-NAME) -> action alist, or nil.
Consulted at the start of every span run before the generic actionable
check; a non-nil result becomes that run's tap action instead of the
default `emacs.buffer.act' dispatch.  Tier-1 skins let-bind this
around delegated region renders to route taps on mode-specific objects
\(an org footnote reference, say) to their own actions.  A signaling
function counts as nil — a broken skin routing must not cost the
render.")

(defun jetpacs-buffer--span-action (pos buffer-name)
  "The tap action for the run starting at POS, or nil.
The skin override wins; otherwise an actionable region gets the generic
`emacs.buffer.act' dispatch."
  (or (and jetpacs-buffer-span-action-function
           (condition-case nil
               (funcall jetpacs-buffer-span-action-function pos buffer-name)
             (error nil)))
      (when (jetpacs-buffer--actionable-p pos)
        (jetpacs-action "emacs.buffer.act"
                     :args `((buffer . ,buffer-name)
                             (pos . ,pos))))))

(defvar jetpacs-buffer--default-fg-hex nil
  "Hex of the default face foreground, bound for the duration of a render.
Spans whose foreground matches this are emitted without a color so the
device theme owns ordinary text.")

(defvar jetpacs-buffer--default-bg-hex nil
  "Hex of the default face background, bound for the duration of a render.
Spans whose background matches this emit no `:bg', so ordinary text keeps
the device theme's surface color and only semantic backgrounds (diff
shading, hl-line, region, isearch) are carried over.")

;; ─── Face resolution ─────────────────────────────────────────────────────────

(defun jetpacs-buffer--color-hex (color)
  "Return COLOR (a name or hex string) as \"#RRGGBB\", or nil if unresolvable."
  (when (and (stringp color) (not (string-empty-p color)))
    (let ((vals (ignore-errors (color-values color))))
      (when vals
        (apply #'format "#%02X%02X%02X"
               (mapcar (lambda (v) (/ v 256)) vals))))))

(defun jetpacs-buffer--face-refs (face)
  "Normalize a FACE property value into an ordered list of face refs.
Each ref is a face symbol or an attribute plist; earlier refs take
precedence, matching Emacs's left-to-right face merging."
  (cond
   ((null face) nil)
   ((symbolp face) (list face))
   ((and (consp face) (keywordp (car face))) (list face)) ; a single plist
   ((consp face)
    (let (refs)
      (dolist (f face)
        (setq refs (append refs (jetpacs-buffer--face-refs f))))
      refs))
   (t nil)))

(defun jetpacs-buffer--ref-attr (ref attr)
  "Read ATTR from a single face REF (symbol or plist); nil if unspecified.
An anonymous plist that lacks ATTR but names an `:inherit' face resolves
ATTR through the inherited face(s), matching Emacs's own face merging (the
symbol branch already inherits via `face-attribute')."
  (let ((v (cond
            ((symbolp ref) (face-attribute ref attr nil t))
            ((listp ref)
             (if (plist-member ref attr)
                 (plist-get ref attr)
               (let ((inherit (plist-get ref :inherit)))
                 (and inherit
                      (jetpacs-buffer--attr (jetpacs-buffer--face-refs inherit) attr)))))
            (t nil))))
    (if (eq v 'unspecified) nil v)))

(defun jetpacs-buffer--attr (refs attr)
  "First specified value of ATTR across REFS, in priority order."
  (cl-some (lambda (r) (jetpacs-buffer--ref-attr r attr)) refs))

(defconst jetpacs-buffer--bold-weights
  '(bold semi-bold semibold extra-bold extrabold ultra-bold ultrabold heavy black)
  "Weight symbols treated as bold.")

(defcustom jetpacs-buffer-code-faces
  '(org-verbatim org-code markdown-inline-code-face markdown-code-face)
  "Faces whose runs render with the span `code' chrome on the device.
Face attributes carry no \"this is code\" bit, so inline-code faces are
named here explicitly; a run styled with any of them gets the client's
inline-code treatment (monospace on a tinted chip) on top of whatever
colors the face resolves to."
  :type '(repeat face) :group 'jetpacs)

(defun jetpacs-buffer--span-style (face)
  "Return a plist (:bold :italic :underline :strike :code :color :bg) for FACE.
COLOR/:bg are included only when they resolve and differ from the default
foreground/background, so ordinary text carries neither.  :code is set
when FACE names a member of `jetpacs-buffer-code-faces'.  Returns nil for
an unstyled run."
  (condition-case nil
      (let* ((refs (jetpacs-buffer--face-refs face))
             (weight (jetpacs-buffer--attr refs :weight))
             (slant (jetpacs-buffer--attr refs :slant))
             (underline (jetpacs-buffer--attr refs :underline))
             (strike (jetpacs-buffer--attr refs :strike-through))
             (fg (and jetpacs-buffer-emit-colors
                      (jetpacs-buffer--attr refs :foreground)))
             (hex (and fg (jetpacs-buffer--color-hex fg)))
             (bg (and jetpacs-buffer-emit-colors
                      (jetpacs-buffer--attr refs :background)))
             (bghex (and bg (jetpacs-buffer--color-hex bg))))
        (append
         (when (memq weight jetpacs-buffer--bold-weights) '(:bold t))
         (when (memq slant '(italic oblique)) '(:italic t))
         (when underline '(:underline t))
         (when strike '(:strike t))
         (when (cl-some (lambda (r)
                          (and (symbolp r) (memq r jetpacs-buffer-code-faces)))
                        refs)
           '(:code t))
         (when (and hex (not (equal hex jetpacs-buffer--default-fg-hex)))
           (list :color hex))
         (when (and bghex (not (equal bghex jetpacs-buffer--default-bg-hex)))
           (list :bg bghex))))
    (error nil)))

(defun jetpacs-buffer--raise-baseline (disp)
  "\"super\"/\"sub\" from a `(raise …)' display spec in DISP, else nil.
Org's pretty sub/superscripts (and anything else using a raise spec)
carry their shift here; the span `baseline' attribute reproduces it."
  (let ((r (cond
            ((eq (car-safe disp) 'raise) (cadr disp))
            ((consp disp)
             (cl-some (lambda (d) (and (eq (car-safe d) 'raise) (cadr d)))
                      disp)))))
    (cond ((and (numberp r) (> r 0)) "super")
          ((and (numberp r) (< r 0)) "sub"))))

;; ─── Interactivity ─────────────────────────────────────────────────────────

(defun jetpacs-buffer--widget-p (obj)
  "Non-nil if OBJ is a widget.el widget object.
Own predicate (rather than `widgetp') so detection needs no wid-edit;
when a buffer actually contains widgets, wid-edit is already loaded."
  (and (consp obj) (symbolp (car obj)) (get (car obj) 'widget-type)))

(defun jetpacs-buffer--widget-at (pos)
  "The widget.el widget at POS as (button . W) or (field . W), else nil.
The `button' property distinguishes pressables; `field' marks editable
value boxes (Customize).  Non-widget `field' values (comint, minibuffer)
don't count."
  (let ((b (get-char-property pos 'button)))
    (if (jetpacs-buffer--widget-p b)
        (cons 'button b)
      (let ((f (get-char-property pos 'field)))
        (and (jetpacs-buffer--widget-p f) (cons 'field f))))))

(defun jetpacs-buffer--actionable-p (pos)
  "Non-nil if the char at POS belongs to a tappable region.
True for text/widget buttons, widget editable fields, regions carrying a
`mouse-face', and regions with their own `keymap'/`local-map' (magit
sections, info refs, …).  The major-mode keymap is buffer-local, not a
text property, so this never marks the whole buffer tappable."
  (or (get-char-property pos 'button)
      (jetpacs-buffer--widget-p (get-char-property pos 'field))
      (get-char-property pos 'mouse-face)
      (keymapp (get-char-property pos 'keymap))
      (keymapp (get-char-property pos 'local-map))))

;; ─── Folding ───────────────────────────────────────────────────────────────
;;
;; Universal fold/unfold without any per-mode renderer.  Detection is generic:
;; a line is "expandable" when the text right after it is currently invisible
;; (which is how magit/org/outline/hideshow all hide a collapsed body).  The
;; action is generic too: run whatever command the buffer itself binds to TAB
;; at that heading — `org-cycle', `magit-section-toggle', the outline cycle,
;; etc. — i.e. exactly what the user would press in Emacs.  The allowlist below
;; keeps this from ever running a non-fold TAB (e.g. `indent-for-tab-command').

(defcustom jetpacs-buffer-fold-commands
  '(magit-section-toggle magit-section-cycle magit-section-cycle-global
    org-cycle org-fold-show-entry org-fold-hide-subtree
    outline-toggle-children outline-cycle outline-show-subtree
    outline-hide-subtree hs-toggle-hiding)
  "Commands treated as safe fold toggles for the generic fold affordance.
Only a command in this list will be invoked by `jetpacs.buffer.fold', so the
phone can never trigger an arbitrary command through the fold path."
  :type '(repeat function) :group 'jetpacs)

(defun jetpacs-buffer--invisible-at (pos)
  "Non-nil if the char at POS is currently folded away (invisible)."
  (let ((v (get-char-property pos 'invisible)))
    (and v (invisible-p v))))

(defun jetpacs-buffer--hidden-follows-p (eol limit)
  "Non-nil if a folded (invisible) region begins right after the line at EOL.
Bounded by LIMIT.  This is the generic \"this heading is collapsed\" signal.
Checks the end-of-line chars and the start of the next line, since modes
differ on whether the heading's newline or the body's first char carries the
`invisible' property."
  (or (and (< eol limit) (jetpacs-buffer--invisible-at eol))
      (and (< (1+ eol) limit) (jetpacs-buffer--invisible-at (1+ eol)))
      (save-excursion
        (goto-char (min eol (max (point-min) (1- limit))))
        (forward-line 1)
        (and (< (point) limit) (jetpacs-buffer--invisible-at (point))))))

(defun jetpacs-buffer--fold-span (pos buffer-name text)
  "A tappable affordance span that expands/collapses the fold at heading
position POS."
  (jetpacs-span text
             :on-tap (jetpacs-action "jetpacs.buffer.fold"
                                  :args `((buffer . ,buffer-name) (pos . ,pos)))))

;; ─── Region → spans ─────────────────────────────────────────────────────────

(defun jetpacs-buffer--expand-tabs (text col)
  "Expand TABs in TEXT to spaces given the starting column COL.
Returns (EXPANDED-TEXT . END-COL).  Text with no TAB is returned as-is, so
the common line pays only a `string-search'.  Keeps column alignment
faithful (dired, tables, source) since the phone's tab stops differ."
  (if (not (string-search "\t" text))
      (cons text (+ col (length text)))
    (let ((c col) parts)
      (dolist (ch (append text nil))
        (if (eq ch ?\t)
            (let ((n (- tab-width (mod c tab-width))))
              (push (make-string n ?\s) parts)
              (setq c (+ c n)))
          (push (char-to-string ch) parts)
          (setq c (1+ c))))
      (cons (apply #'concat (nreverse parts)) c))))

(defun jetpacs-buffer--offscreen-display-p (disp)
  "Non-nil when display spec DISP renders outside the text area.
Fringe bitmaps (`(left-fringe …)' / `(right-fringe …)') and margin specs
\(`((margin …) …)') show in the fringe/margin, never in the text flow —
the text they cover is a placeholder (magit literally uses \"fringe\" and
\"o\") that must not be rendered.  Also recognises a list of specs whose
members include one."
  (and (consp disp)
       (or (memq (car-safe disp) '(left-fringe right-fringe))
           (eq (car-safe (car-safe disp)) 'margin)
           ;; A list of display specs: offscreen if any member is.
           (and (consp (car-safe disp))
                (cl-some #'jetpacs-buffer--offscreen-display-p disp)))))

(defun jetpacs-buffer--space-width (disp col)
  "Columns a `(space …)' display spec DISP occupies starting at column COL.
Handles `:width N' and `:align-to COL'; pixel/relative forms approximate
to a single space."
  (let ((plist (cdr disp)))
    (cond
     ((plist-member plist :width)
      (let ((w (plist-get plist :width)))
        (max 0 (if (numberp w) (round w) 1))))
     ((plist-member plist :align-to)
      (let ((to (plist-get plist :align-to)))
        (max 1 (- (if (numberp to) (round to) col) col))))
     (t 1))))

(defun jetpacs-buffer--string-spans (str col)
  "Render a propertized STR (an overlay before/after-string) into spans.
Returns (SPANS . END-COL); honors `face'/`font-lock-face', string `display'
overrides, and TAB expansion so injected virtual text matches the buffer.
Runs covered by an offscreen display spec (fringe bitmaps, margin dates —
magit's \"fringe\" and \"o\" placeholders) render nothing."
  (let ((i 0) (n (length str)) (c col) out)
    (while (< i n)
      (let* ((next (or (next-property-change i str) n))
             (disp (get-text-property i 'display str))
             (raw (cond
                   ((stringp disp) disp)
                   ((jetpacs-buffer--offscreen-display-p disp) nil)
                   ((and (consp disp) (eq (car disp) 'space))
                    (make-string (jetpacs-buffer--space-width disp c) ?\s))
                   (t (substring-no-properties str i next))))
             (face (or (get-text-property i 'face str)
                       (get-text-property i 'font-lock-face str)))
             (baseline (jetpacs-buffer--raise-baseline disp))
             (style (append (jetpacs-buffer--span-style face)
                            (when baseline (list :baseline baseline)))))
        (when raw
          (let ((exp (jetpacs-buffer--expand-tabs raw c)))
            (setq c (cdr exp))
            (unless (string-empty-p (car exp))
              (push (apply #'jetpacs-span (car exp)
                           (append style (when jetpacs-buffer-monospace '(:mono t))))
                    out))))
        (setq i next)))
    (cons (nreverse out) c)))

(defun jetpacs-buffer--overlay-strings (bol eol)
  "Insertions ((POS TIE STRING) …) from overlay before/after-strings on a line.
`before-string' is placed at the overlay start, `after-string' at its end,
when those fall within [BOL, EOL].  Invisible overlays contribute nothing.
Sorted by position, before-strings ahead of after-strings at a tie.  These
are OVERLAY properties, not char properties, so the main span walk (which
uses `get-char-property') never sees them — this surfaces flymake inline
hints, diff-hl markers, and similar virtual text that would otherwise vanish."
  (let (ins)
    (dolist (ov (overlays-in bol (min (1+ eol) (point-max))))
      (let ((iv (overlay-get ov 'invisible)))
        (unless (and iv (invisible-p iv))
          (let ((bs (overlay-get ov 'before-string))
                (as (overlay-get ov 'after-string))
                (os (overlay-start ov))
                (oe (overlay-end ov)))
            (when (and (stringp bs) (>= os bol) (<= os eol))
              (push (list os 0 bs) ins))
            (when (and (stringp as) (>= oe bol) (<= oe eol))
              (push (list oe 1 as) ins))))))
    (sort ins (lambda (a b) (or (< (car a) (car b))
                                (and (= (car a) (car b))
                                     (< (nth 1 a) (nth 1 b))))))))

(defun jetpacs-buffer--line-spans (bol eol buffer-name)
  "Build the list of spans for the buffer text in [BOL, EOL).
Honors `invisible' (skips folded text), string and `(space …)' `display'
overrides, and overlay before/after-strings; expands TABs to `tab-width'
stops; maps `face'/`font-lock-face' to styling; and attaches a tap action
at the start of each actionable property run."
  (let ((pos bol) (col 0) spans
        (inserts (jetpacs-buffer--overlay-strings bol eol)))
    (cl-flet ((flush (upto)
                ;; Emit pending overlay-string insertions at or before UPTO,
                ;; splicing them into the run at the right column.
                (while (and inserts (<= (caar inserts) upto))
                  (let ((ss (jetpacs-buffer--string-spans (nth 2 (pop inserts)) col)))
                    (setq spans (nconc (nreverse (car ss)) spans)
                          col (cdr ss))))))
      (while (< pos eol)
        (flush pos)
        (let ((next (next-char-property-change pos eol)))
          (when (<= next pos) (setq next (1+ pos))) ; defensive: always advance
          (setq next (min next eol))
          (let ((invis (get-char-property pos 'invisible)))
            (unless (and invis (invisible-p invis))
              (let* ((disp (get-char-property pos 'display))
                     (face (or (get-char-property pos 'face)
                               (get-char-property pos 'font-lock-face)))
                     (baseline (jetpacs-buffer--raise-baseline disp))
                     (style (append (jetpacs-buffer--span-style face)
                                    (when baseline (list :baseline baseline))))
                     (act (jetpacs-buffer--span-action pos buffer-name))
                     text)
                (cond
                 ((stringp disp)
                  (setq text disp col (+ col (length disp))))
                 ;; Fringe/margin display: the covered text is a placeholder
                 ;; that never shows in the text flow — render nothing.
                 ((jetpacs-buffer--offscreen-display-p disp)
                  (setq text nil))
                 ((and (consp disp) (eq (car disp) 'space))
                  (let ((w (jetpacs-buffer--space-width disp col)))
                    (setq text (make-string w ?\s) col (+ col w))))
                 (t
                  (let ((exp (jetpacs-buffer--expand-tabs
                              (buffer-substring-no-properties pos next) col)))
                    (setq text (car exp) col (cdr exp)))))
                (when (and (stringp text) (not (string-empty-p text)))
                  (push (apply #'jetpacs-span text
                               (append style
                                       (when jetpacs-buffer-monospace '(:mono t))
                                       (when act (list :on-tap act))))
                        spans)))))
          (setq pos next)))
      ;; Trailing insertions at EOL (e.g. an after-string at end of line).
      (flush eol))
    (nreverse spans)))

(defun jetpacs-buffer--fold-state (bol eol limit)
  "Return \\='folded, \\='unfolded, or nil if not a foldable heading."
  (let ((magit-sec (get-char-property bol 'magit-section)))
    (cond
     (magit-sec
      (if (and (fboundp 'magit-section-hidden)
               (magit-section-hidden magit-sec))
          'folded
        'unfolded))
     ((and (bound-and-true-p outline-regexp)
           (save-excursion
             (goto-char bol)
             (looking-at outline-regexp)))
      (if (jetpacs-buffer--hidden-follows-p eol limit)
          'folded
        'unfolded))
     (t nil))))

(defun jetpacs-buffer--line-number-span (ln pt-line fmt)
  "A dim gutter span for line LN. PT-LINE is point's line, FMT the width format.
With `jetpacs-line-numbers' `relative', shows the distance from point —
except on point's own line, which shows its absolute number undimmed
\(vim's hybrid style)."
  (let ((current (and pt-line (= ln pt-line))))
    (jetpacs-span (format fmt (if (and (eq jetpacs-line-numbers 'relative)
                                    (not current))
                               (abs (- ln pt-line))
                             ln))
               :mono t
               :color (unless current jetpacs-buffer--line-number-color))))

(defun jetpacs-buffer--render-region (beg end buffer-name &optional mark-pos)
  "Return a list of `rich_text' nodes for [BEG, END) of the current buffer.
One node per line; blank lines keep their vertical space.  Capped at
`jetpacs-buffer-max-lines'.  When `jetpacs-line-numbers' is enabled each line
is prefixed with a dim gutter span carrying its (absolute or relative)
number — real buffer lines, so folded regions skip numbers faithfully.
MARK-POS, when non-nil, flags the line containing that position as the
enclosing lazy column's scroll target (see `jetpacs-scroll-here')."
  (let* ((jetpacs-buffer--default-fg-hex
          (jetpacs-buffer--color-hex (face-attribute 'default :foreground nil t)))
         (jetpacs-buffer--default-bg-hex
          (jetpacs-buffer--color-hex (face-attribute 'default :background nil t)))
         (pt-line (and jetpacs-line-numbers (line-number-at-pos (point))))
         (num-fmt (and jetpacs-line-numbers
                       (format "%%%dd " (length (number-to-string
                                                 (line-number-at-pos end))))))
         (ln (and jetpacs-line-numbers (line-number-at-pos beg)))
         (count 0)
         nodes)
    (ignore-errors (font-lock-ensure beg end))
    (save-excursion
      (goto-char beg)
      (while (and (< (point) end) (< count jetpacs-buffer-max-lines))
        (let* ((bol (line-beginning-position))
               (eol (min end (line-end-position))))
          (cond
           ;; A page break (^L alone on the line) renders as a divider rather
           ;; than a raw control glyph.
           ((and (< bol eol)
                 (save-excursion (goto-char bol) (looking-at "\f+$")))
            (push (jetpacs-divider) nodes)
            (setq count (1+ count)))
           (t
            (let ((spans (jetpacs-buffer--line-spans bol eol buffer-name)))
              ;; A fully-folded line (no visible spans, hidden at bol) is
              ;; dropped entirely so collapsed content truly disappears instead
              ;; of leaving a blank gap.  Visible lines render; a collapsed
              ;; heading gets a trailing ▸ affordance to expand it, unfolded ▾.
              (unless (and (null spans) (jetpacs-buffer--invisible-at bol))
                (pcase (jetpacs-buffer--fold-state bol eol end)
                  ('folded
                   (setq spans (append (or spans (list (jetpacs-span " ")))
                                       (list (jetpacs-buffer--fold-span bol buffer-name "  ▸")))))
                  ('unfolded
                   (setq spans (append (or spans (list (jetpacs-span " ")))
                                       (list (jetpacs-buffer--fold-span bol buffer-name "  ▾"))))))
                (setq spans (or spans (list (jetpacs-span " "))))
                ;; `line-prefix' (org-indent's virtual indentation, etc.) is a
                ;; text property, not part of the buffer text — prepend it as a
                ;; dim gutter span so the indentation survives.
                (let ((prefix (get-char-property bol 'line-prefix)))
                  (when (stringp prefix)
                    (setq spans (cons (jetpacs-span prefix :mono t
                                                 :color jetpacs-buffer--line-number-color)
                                      spans))))
                (when ln
                  (setq spans (cons (jetpacs-buffer--line-number-span ln pt-line num-fmt)
                                    spans)))
                (push (if (and mark-pos (>= mark-pos bol) (<= mark-pos eol))
                          (jetpacs-scroll-here (jetpacs-rich-text spans))
                        (jetpacs-rich-text spans))
                      nodes)
                (setq count (1+ count)))))))
        (when ln (setq ln (1+ ln)))
        (forward-line 1)))
    (nreverse nodes)))

;; ─── Public: generic renderer + dispatch registry ────────────────────────────

(defun jetpacs-buffer-render (&optional buffer)
  "Render BUFFER (default current) generically into a list of SDUI nodes.
Truncated to `jetpacs-buffer-max-lines'; a caption note is appended if cut."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((name (buffer-name buf))
             (total (count-lines (point-min) (point-max)))
             (nodes (jetpacs-buffer--render-region (point-min) (point-max) name)))
        (if (> total jetpacs-buffer-max-lines)
            (append nodes
                    (list (jetpacs-text
                           (format "… %d more line(s) (showing first %d)"
                                   (- total jetpacs-buffer-max-lines)
                                   jetpacs-buffer-max-lines)
                           'caption)))
          nodes)))))

(defun jetpacs-buffer-render-region (buffer beg end &optional mark-pos)
  "Render [BEG, END) of BUFFER generically into a list of SDUI nodes.
The public region variant of `jetpacs-buffer-render', for callers showing
a slice instead of the whole buffer (an imenu section, a hit context).
BEG and END are clamped to the buffer; the line cap still applies.
MARK-POS, when non-nil, flags its line as the scroll target."
  (let ((buf (get-buffer buffer)))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((beg (max (point-min) (min (or beg (point-min)) (point-max))))
             (end (max beg (min (or end (point-max)) (point-max)))))
        (jetpacs-buffer--render-region beg end (buffer-name buf) mark-pos)))))

(defun jetpacs-buffer-render-tail (buffer lines)
  "Render the last LINES lines of BUFFER into a list of SDUI nodes.
For transcript-shaped buffers (comint REPLs, logs) the interesting end
is the bottom — `jetpacs-buffer-render' caps from the top.  A leading
caption marks elided output."
  (let ((buf (get-buffer buffer)))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let ((beg (save-excursion
                   (goto-char (point-max))
                   (forward-line (- (max 1 lines)))
                   (point))))
        (append
         (when (> beg (point-min))
           (list (jetpacs-text (format "… %d earlier line(s) not shown"
                                    (count-lines (point-min) beg))
                            'caption)))
         (jetpacs-buffer--render-region beg (point-max) (buffer-name buf)))))))

(defvar jetpacs-render-buffer-functions nil
  "Alist of (MAJOR-MODE . FUNCTION) Tier-1 renderer skins.
FUNCTION takes the buffer and returns a list of SDUI nodes.  A mode with no
entry — including any mode derived from an unregistered one — falls through
to the generic `jetpacs-buffer-render'.  Derived modes match their nearest
registered ancestor; the first matching entry wins.")

(defun jetpacs-render-buffer-register (mode fn)
  "Register FN as the Tier-1 renderer skin for MODE (a major-mode symbol)."
  (setf (alist-get mode jetpacs-render-buffer-functions) fn))

(defun jetpacs-render-buffer (&optional buffer)
  "Render BUFFER via its registered skin, else the generic renderer.
Returns a list of SDUI nodes.  This is the single dispatch seam: Tier 1 is
purely additive on top of the Tier 0 substrate."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (with-current-buffer buf
      (let ((fn (seq-some (lambda (cell)
                            (and (derived-mode-p (car cell)) (cdr cell)))
                          jetpacs-render-buffer-functions)))
        (if fn (funcall fn buf) (jetpacs-buffer-render buf))))))

;; ─── Tap dispatch ─────────────────────────────────────────────────────────

(declare-function widget-apply-action "wid-edit" (widget &optional event))
(declare-function widget-field-value-get "wid-edit" (widget &optional no-truncate))
(declare-function widget-field-value-set "wid-edit" (widget value))

(defun jetpacs-buffer--widget-invoke (hit)
  "Activate widget HIT, a (button . W) or (field . W) pair.
Buttons run their :action (State menus, Toggle, checkboxes, links).
A field tap edits the field's raw text through a bridged prompt.
The wid-edit value primitives handle size padding and marker
bookkeeping, and the rewrite runs the same after-change hooks typing
would, so Customize notices the modification (state turns EDITED)."
  (pcase hit
    (`(button . ,w) (widget-apply-action w) t)
    (`(field . ,w)
     (let* ((old (widget-field-value-get w))
            (tag (or (widget-get w :tag) "Edit field"))
            (new (read-string (format "%s: " tag) old)))
       (unless (equal new old)
         (widget-field-value-set w new))
       t))))

(defun jetpacs-buffer-call-shimmed (cmd &optional on-error)
  "Run command CMD with window-display and input-event shims; return (BUF . POS).
The buffer-display functions are neutered so nothing pops a desktop window
and the user's Emacs layout is untouched (`save-window-excursion'), and the
triggering input event is cleared so event-driven goto commands
\(`compile-goto-error', the eww/Info/help follow commands) navigate to
point rather than to a stale pending event.  `this-command' is bound to
CMD and `last-command' to a sentinel: without a command loop both are
whatever the last desktop interaction left (or nil in batch), so a
repeat-style command (`mark-word', `kill-line' appending) would
spuriously detect \"same command again\" and extend from stale state.
Returns the buffer made current and the point reached after CMD runs;
errors are swallowed and report wherever point already is — unless
ON-ERROR is a function, which is then called with the error so surfaces
that must not fail silently (the editor's DWIM path) can toast it.
Call with the origin buffer current and point already placed on the
target."
  (let (dest-buf dest-pos)
    (save-window-excursion
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                ((symbol-function 'pop-to-buffer-same-window)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                ((symbol-function 'switch-to-buffer)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                ((symbol-function 'switch-to-buffer-other-window)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer))))
        (condition-case err
            (let ((last-input-event nil)
                  (last-nonmenu-event nil)
                  (this-command cmd)
                  (last-command 'jetpacs-buffer-call-shimmed))
              (call-interactively cmd))
          (error (when on-error (funcall on-error err)) nil))
        (setq dest-buf (current-buffer) dest-pos (point))))
    (cons dest-buf dest-pos)))

(defun jetpacs-buffer-invoke-at (buffer-name pos)
  "Run the tap action at POS in BUFFER-NAME and return non-nil if one fired.
Tries, in order: activate a widget.el widget, push a button, then the
region keymap's binding for RET / mouse-2 / mouse-1.  Runs with the buffer
current and point at POS; commands that only need point (buttons,
magit/dired/info visit) work, those that require a live window may not.
Called inside an action handler, so any minibuffer prompts it raises are
bridged to the companion automatically."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        ;; Clear the triggering input event before running the tap's command.
        ;; Link/visit commands reached through the keymap branch (eww/Info/help
        ;; RET, `compile-goto-error') read `last-input-event' and would jump to
        ;; a stale pending event instead of point; this tap is driven by POS.
        ;; Same guard as `jetpacs-buffer-call-shimmed'.
        (let ((last-input-event nil)
              (last-nonmenu-event nil))
          (cond
           ;; widget.el first: widgets store the widget object in the `button'
           ;; property, which fools button.el's `button-at' into returning a
           ;; bogus marker whose `push-button' then has no :action.
           ((jetpacs-buffer--widget-at (point))
            (jetpacs-buffer--widget-invoke (jetpacs-buffer--widget-at (point))))
           ((button-at (point)) (push-button) t)
           (t
            (let* ((km (or (get-char-property (point) 'keymap)
                           (get-char-property (point) 'local-map)))
                   (cmd (and (keymapp km)
                             (or (lookup-key km (kbd "RET"))
                                 (lookup-key km [return])
                                 (lookup-key km [mouse-2])
                                 (lookup-key km [mouse-1])))))
              (when (commandp cmd)
                (call-interactively cmd)
                t)))))))))

(jetpacs-defaction "emacs.buffer.act"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (jetpacs-buffer-invoke-at buffer pos))
      ;; Re-push the showing surface; the tap may have folded a section,
      ;; navigated, or mutated the buffer.
      (when (functionp jetpacs-buffer-refresh-function)
        (funcall jetpacs-buffer-refresh-function)))))

;; ─── Fold dispatch ────────────────────────────────────────────────────────

(defun jetpacs-buffer--run-fold-toggle ()
  "Run the current buffer's own fold toggle at point; non-nil if one ran.
Generic: prefer the command the buffer binds to TAB when it is a known fold
toggle (org-cycle, magit-section-toggle, the outline cycle, …); otherwise
pick the first `jetpacs-buffer-fold-commands' member actually bound in this
buffer.  Never runs a command outside that allowlist."
  (let ((tab (or (key-binding (kbd "TAB")) (key-binding (kbd "<tab>")))))
    (cond
     ((and (commandp tab) (memq tab jetpacs-buffer-fold-commands))
      (call-interactively tab) t)
     (t
      (let ((cmd (cl-find-if
                  (lambda (c)
                    (and (commandp c)
                         (where-is-internal c (current-active-maps))))
                  jetpacs-buffer-fold-commands)))
        (when cmd (call-interactively cmd) t))))))

(defun jetpacs-buffer-toggle-fold-at (buffer-name pos)
  "Toggle the fold at POS in BUFFER-NAME using the buffer's own fold command.
Point is placed on the heading first, so the mode's toggle acts on the right
section.  Runs inside an action handler, so any prompt is bridged."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        (jetpacs-buffer--run-fold-toggle)))))

(jetpacs-defaction "jetpacs.buffer.fold"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (jetpacs-buffer-toggle-fold-at buffer pos))
      (when (functionp jetpacs-buffer-refresh-function)
        (funcall jetpacs-buffer-refresh-function)))))

(provide 'jetpacs-buffer)
;;; jetpacs-buffer.el ends here
