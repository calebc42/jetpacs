;;; eabp-buffer.el --- Generic buffer renderer (Tier 0) -*- lexical-binding: t; -*-

;; Tier 0 of EABP: render ANY Emacs buffer faithfully from its text plus its
;; text/overlay properties (face, display, invisible, keymap, button,
;; mouse-face), with interactive regions made tappable.  This is the universal
;; substrate — every major mode renders through here for free, no per-package
;; translator required.
;;
;; Per-mode "skins" (Tier 1, e.g. a hand-built org dashboard) are *opt-in*
;; overrides registered in `eabp-render-buffer-functions'.  Anything
;; unregistered falls through to the generic renderer below, so a new package
;; is usable on day one and only gets bespoke polish where it's worth it.
;;
;; Emacs stays the single source of truth for styling: this module resolves
;; faces to span attributes and ships them; the device only paints the spans
;; (it never re-fontifies).
;;
;; This file deliberately does NOT depend on any UI/host layer (no org-ui).
;; The only seam back to the host is `eabp-buffer-refresh-function', which the
;; host sets so a tap that mutates a buffer can re-push the showing surface.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'eabp-widgets)
(require 'eabp-surfaces)   ; eabp-defaction / eabp-action

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom eabp-buffer-max-lines 500
  "Maximum number of lines the generic renderer emits for a buffer.
Buffers longer than this are truncated (with a trailing note) so a huge
magit/log/compilation buffer can't produce an unbounded surface."
  :type 'integer :group 'eabp)

(defcustom eabp-buffer-monospace t
  "When non-nil, the generic renderer paints buffer text monospace.
Most Emacs buffers (dired, magit, tables, source) rely on column alignment,
so monospace is the faithful default.  Tier-1 skins may override per mode."
  :type 'boolean :group 'eabp)

(defcustom eabp-buffer-emit-colors t
  "When non-nil, carry a face's foreground color into the rendered span.
Only colors that differ from the default face are emitted, so semantic color
\(diff add/remove, font-lock keywords, warnings) survives while ordinary body
text still uses the device theme's on-surface color."
  :type 'boolean :group 'eabp)

(defvar eabp-buffer-refresh-function nil
  "Function called with no args after an `eabp.buffer.act' mutates a buffer.
The host shell sets this to re-push whatever surface is showing the buffer.
Kept as a seam so this module never depends on a specific UI layer.")

(defvar eabp-buffer--default-fg-hex nil
  "Hex of the default face foreground, bound for the duration of a render.
Spans whose foreground matches this are emitted without a color so the
device theme owns ordinary text.")

;; ─── Face resolution ─────────────────────────────────────────────────────────

(defun eabp-buffer--color-hex (color)
  "Return COLOR (a name or hex string) as \"#RRGGBB\", or nil if unresolvable."
  (when (and (stringp color) (not (string-empty-p color)))
    (let ((vals (ignore-errors (color-values color))))
      (when vals
        (apply #'format "#%02X%02X%02X"
               (mapcar (lambda (v) (/ v 256)) vals))))))

(defun eabp-buffer--face-refs (face)
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
        (setq refs (append refs (eabp-buffer--face-refs f))))
      refs))
   (t nil)))

(defun eabp-buffer--ref-attr (ref attr)
  "Read ATTR from a single face REF (symbol or plist); nil if unspecified."
  (let ((v (cond
            ((symbolp ref) (face-attribute ref attr nil t))
            ((listp ref) (plist-get ref attr))
            (t nil))))
    (if (eq v 'unspecified) nil v)))

(defun eabp-buffer--attr (refs attr)
  "First specified value of ATTR across REFS, in priority order."
  (cl-some (lambda (r) (eabp-buffer--ref-attr r attr)) refs))

(defconst eabp-buffer--bold-weights
  '(bold semi-bold semibold extra-bold extrabold ultra-bold ultrabold heavy black)
  "Weight symbols treated as bold.")

(defun eabp-buffer--span-style (face)
  "Return a plist (:bold :italic :underline :strike :color) for FACE.
COLOR is included only when it resolves and differs from the default
foreground.  Returns nil for an unstyled run."
  (condition-case nil
      (let* ((refs (eabp-buffer--face-refs face))
             (weight (eabp-buffer--attr refs :weight))
             (slant (eabp-buffer--attr refs :slant))
             (underline (eabp-buffer--attr refs :underline))
             (strike (eabp-buffer--attr refs :strike-through))
             (fg (and eabp-buffer-emit-colors
                      (eabp-buffer--attr refs :foreground)))
             (hex (and fg (eabp-buffer--color-hex fg))))
        (append
         (when (memq weight eabp-buffer--bold-weights) '(:bold t))
         (when (memq slant '(italic oblique)) '(:italic t))
         (when underline '(:underline t))
         (when strike '(:strike t))
         (when (and hex (not (equal hex eabp-buffer--default-fg-hex)))
           (list :color hex))))
    (error nil)))

;; ─── Interactivity ─────────────────────────────────────────────────────────

(defun eabp-buffer--actionable-p (pos)
  "Non-nil if the char at POS belongs to a tappable region.
True for text/widget buttons, regions carrying a `mouse-face', and regions
with their own `keymap'/`local-map' (magit sections, info refs, …).  The
major-mode keymap is buffer-local, not a text property, so this never marks
the whole buffer tappable."
  (or (get-char-property pos 'button)
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

(defcustom eabp-buffer-fold-commands
  '(magit-section-toggle magit-section-cycle magit-section-cycle-global
    org-cycle org-fold-show-entry org-fold-hide-subtree
    outline-toggle-children outline-cycle outline-show-subtree
    outline-hide-subtree hs-toggle-hiding)
  "Commands treated as safe fold toggles for the generic fold affordance.
Only a command in this list will be invoked by `eabp.buffer.fold', so the
phone can never trigger an arbitrary command through the fold path."
  :type '(repeat function) :group 'eabp)

(defun eabp-buffer--invisible-at (pos)
  "Non-nil if the char at POS is currently folded away (invisible)."
  (let ((v (get-char-property pos 'invisible)))
    (and v (invisible-p v))))

(defun eabp-buffer--hidden-follows-p (eol limit)
  "Non-nil if a folded (invisible) region begins right after the line at EOL.
Bounded by LIMIT.  This is the generic \"this heading is collapsed\" signal.
Checks the end-of-line chars and the start of the next line, since modes
differ on whether the heading's newline or the body's first char carries the
`invisible' property."
  (or (and (< eol limit) (eabp-buffer--invisible-at eol))
      (and (< (1+ eol) limit) (eabp-buffer--invisible-at (1+ eol)))
      (save-excursion
        (goto-char (min eol (max (point-min) (1- limit))))
        (forward-line 1)
        (and (< (point) limit) (eabp-buffer--invisible-at (point))))))

(defun eabp-buffer--fold-span (pos buffer-name text)
  "A tappable affordance span that expands/collapses the fold at heading position POS."
  (eabp-span text
             :on-tap (eabp-action "eabp.buffer.fold"
                                  :args `((buffer . ,buffer-name) (pos . ,pos)))))

;; ─── Region → spans ─────────────────────────────────────────────────────────

(defun eabp-buffer--line-spans (bol eol buffer-name)
  "Build the list of spans for the buffer text in [BOL, EOL).
Honors `invisible' (skips folded text) and string `display' overrides, maps
faces to styling, and attaches a tap action at the start of each actionable
property run."
  (let ((pos bol) spans)
    (while (< pos eol)
      (let ((next (next-char-property-change pos eol)))
        (when (<= next pos) (setq next (1+ pos))) ; defensive: always advance
        (setq next (min next eol))
        (let ((invis (get-char-property pos 'invisible)))
          (unless (and invis (invisible-p invis))
            (let* ((disp (get-char-property pos 'display))
                   (text (if (stringp disp)
                             disp
                           (buffer-substring-no-properties pos next)))
                   (style (eabp-buffer--span-style (get-char-property pos 'face)))
                   (act (when (eabp-buffer--actionable-p pos)
                          (eabp-action "eabp.buffer.act"
                                       :args `((buffer . ,buffer-name)
                                               (pos . ,pos))))))
              (when (and (stringp text) (not (string-empty-p text)))
                (push (apply #'eabp-span text
                             (append style
                                     (when eabp-buffer-monospace '(:mono t))
                                     (when act (list :on-tap act))))
                      spans)))))
        (setq pos next)))
    (nreverse spans)))

(defun eabp-buffer--fold-state (bol eol limit)
  "Return 'folded, 'unfolded, or nil if not a foldable heading."
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
      (if (eabp-buffer--hidden-follows-p eol limit)
          'folded
        'unfolded))
     (t nil))))

(defun eabp-buffer--render-region (beg end buffer-name)
  "Return a list of `rich_text' nodes for [BEG, END) of the current buffer.
One node per line; blank lines keep their vertical space.  Capped at
`eabp-buffer-max-lines'."
  (let ((eabp-buffer--default-fg-hex
         (eabp-buffer--color-hex (face-attribute 'default :foreground nil t)))
        (count 0)
        nodes)
    (ignore-errors (font-lock-ensure beg end))
    (save-excursion
      (goto-char beg)
      (while (and (< (point) end) (< count eabp-buffer-max-lines))
        (let* ((bol (line-beginning-position))
               (eol (min end (line-end-position)))
               (spans (eabp-buffer--line-spans bol eol buffer-name)))
          ;; A fully-folded line (no visible spans, hidden at bol) is dropped
          ;; entirely so collapsed content truly disappears instead of leaving
          ;; a blank gap.  Visible lines render; a collapsed heading gets a
          ;; trailing ▸ affordance to expand it from the app, unfolded gets ▾.
          (unless (and (null spans) (eabp-buffer--invisible-at bol))
            (pcase (eabp-buffer--fold-state bol eol end)
              ('folded
               (setq spans (append (or spans (list (eabp-span " ")))
                                   (list (eabp-buffer--fold-span bol buffer-name "  ▸")))))
              ('unfolded
               (setq spans (append (or spans (list (eabp-span " ")))
                                   (list (eabp-buffer--fold-span bol buffer-name "  ▾"))))))
            (push (eabp-rich-text (or spans (list (eabp-span " ")))) nodes)
            (setq count (1+ count))))
        (forward-line 1)))
    (nreverse nodes)))

;; ─── Public: generic renderer + dispatch registry ────────────────────────────

(defun eabp-buffer-render (&optional buffer)
  "Render BUFFER (default current) generically into a list of SDUI nodes.
Truncated to `eabp-buffer-max-lines'; a caption note is appended if cut."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((name (buffer-name buf))
             (total (count-lines (point-min) (point-max)))
             (nodes (eabp-buffer--render-region (point-min) (point-max) name)))
        (if (> total eabp-buffer-max-lines)
            (append nodes
                    (list (eabp-text
                           (format "… %d more line(s) (showing first %d)"
                                   (- total eabp-buffer-max-lines)
                                   eabp-buffer-max-lines)
                           'caption)))
          nodes)))))

(defvar eabp-render-buffer-functions nil
  "Alist of (MAJOR-MODE . FUNCTION) Tier-1 renderer skins.
FUNCTION takes the buffer and returns a list of SDUI nodes.  A mode with no
entry — including any mode derived from an unregistered one — falls through
to the generic `eabp-buffer-render'.  Derived modes match their nearest
registered ancestor; the first matching entry wins.")

(defun eabp-render-buffer-register (mode fn)
  "Register FN as the Tier-1 renderer skin for MODE (a major-mode symbol)."
  (setf (alist-get mode eabp-render-buffer-functions) fn))

(defun eabp-render-buffer (&optional buffer)
  "Render BUFFER via its registered skin, else the generic renderer.
Returns a list of SDUI nodes.  This is the single dispatch seam: Tier 1 is
purely additive on top of the Tier 0 substrate."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (with-current-buffer buf
      (let ((fn (seq-some (lambda (cell)
                            (and (derived-mode-p (car cell)) (cdr cell)))
                          eabp-render-buffer-functions)))
        (if fn (funcall fn buf) (eabp-buffer-render buf))))))

;; ─── Tap dispatch ─────────────────────────────────────────────────────────

(defun eabp-buffer-invoke-at (buffer-name pos)
  "Run the tap action at POS in BUFFER-NAME and return non-nil if one fired.
Tries, in order: push a button, then the region keymap's binding for RET /
mouse-2 / mouse-1.  Runs with the buffer current and point at POS; commands
that only need point (buttons, magit/dired/info visit) work, those that
require a live window may not.  Called inside an action handler, so any
minibuffer prompts it raises are bridged to the companion automatically."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        (cond
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
              t))))))))

(eabp-defaction "eabp.buffer.act"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (eabp-buffer-invoke-at buffer pos))
      ;; Re-push the showing surface; the tap may have folded a section,
      ;; navigated, or mutated the buffer.
      (when (functionp eabp-buffer-refresh-function)
        (funcall eabp-buffer-refresh-function)))))

;; ─── Fold dispatch ────────────────────────────────────────────────────────

(defun eabp-buffer--run-fold-toggle ()
  "Run the current buffer's own fold toggle at point; non-nil if one ran.
Generic: prefer the command the buffer binds to TAB when it is a known fold
toggle (org-cycle, magit-section-toggle, the outline cycle, …); otherwise
pick the first `eabp-buffer-fold-commands' member actually bound in this
buffer.  Never runs a command outside that allowlist."
  (let ((tab (or (key-binding (kbd "TAB")) (key-binding (kbd "<tab>")))))
    (cond
     ((and (commandp tab) (memq tab eabp-buffer-fold-commands))
      (call-interactively tab) t)
     (t
      (let ((cmd (cl-find-if
                  (lambda (c)
                    (and (commandp c)
                         (where-is-internal c (current-active-maps))))
                  eabp-buffer-fold-commands)))
        (when cmd (call-interactively cmd) t))))))

(defun eabp-buffer-toggle-fold-at (buffer-name pos)
  "Toggle the fold at POS in BUFFER-NAME using the buffer's own fold command.
Point is placed on the heading first, so the mode's toggle acts on the right
section.  Runs inside an action handler, so any prompt is bridged."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        (eabp-buffer--run-fold-toggle)))))

(eabp-defaction "eabp.buffer.fold"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (eabp-buffer-toggle-fold-at buffer pos))
      (when (functionp eabp-buffer-refresh-function)
        (funcall eabp-buffer-refresh-function)))))

(provide 'eabp-buffer)
;;; eabp-buffer.el ends here
