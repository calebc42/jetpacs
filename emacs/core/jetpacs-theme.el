;;; jetpacs-theme.el --- Mirror the Emacs theme onto the companion -*- lexical-binding: t; -*-

;; The companion's default look is Material You (falling back to a static
;; Emacs-purple scheme); this module is the third rung of that ladder — the
;; phone can look like YOUR Emacs.  It reads the active theme's colors,
;; shapes them into the Material roles the companion's renderer already
;; resolves theme tokens against (SPEC §9: "primary", "surface_variant", …),
;; and pushes them as one `theme.set' frame (SPEC §7).  The companion
;; persists the palette like a cached surface, so the mirrored look
;; survives app restarts while Emacs is away.
;;
;; Two extraction paths:
;;
;;  - Prot's modus themes (built into Emacs; the reference implementation
;;    for this feature): when a modus-* theme is active we read its named
;;    palette via `modus-themes-get-color-value' — `bg-main', `bg-dim',
;;    accent colors, and the `bg-*-subtle' tints that map one-to-one onto
;;    Material's container roles, with modus's contrast guarantees intact.
;;
;;  - Any other theme: resolved face attributes (`default', `link',
;;    `font-lock-*', `error', `shadow', `mode-line-inactive', outline
;;    levels), with container tones derived by blending each accent into
;;    the theme background.
;;
;; Every color is optional on the wire; the companion fills holes from its
;; fallback scheme, so a spartan theme still yields a complete UI.  In a
;; frame that can't resolve colors (batch/tty), no frame is sent at all.
;;
;; Opt-in: (setq jetpacs-theme-sync t) — or flip it in Customize — then the
;; palette follows every `load-theme' (Emacs 29+) and every reconnect.
;; `M-x jetpacs-theme-send' pushes once regardless; `M-x jetpacs-theme-clear'
;; reverts the companion to its own scheme.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'jetpacs)

(defcustom jetpacs-theme-sync nil
  "When non-nil, mirror the active Emacs theme onto the companion app.
The palette is pushed after every successful handshake and (on Emacs 29+)
whenever a theme is enabled or disabled.  When nil the companion keeps its
own scheme: Material You on Android 12+, an Emacs-purple fallback earlier.
Setting this through Customize applies immediately on a live connection;
after a plain `setq', push with \\[jetpacs-theme-send] or reconnect."
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         ;; Live toggle (guarded: :set also runs while this file loads,
         ;; before the functions below exist).
         (when (and (featurep 'jetpacs-theme) (jetpacs-connected-p))
           (if val (jetpacs-theme--push-soon) (jetpacs-theme-clear))))
  :group 'jetpacs)

;; ─── Color plumbing ──────────────────────────────────────────────────────────

(defun jetpacs-theme--rgb (color)
  "COLOR (a name or #RRGGBB string) as a list of three [0,1] floats, or nil.
Hex strings are parsed directly — `color-name-to-rgb' resolves through
the current display, which on a tty/batch frame quantizes #2e3440 to the
nearest terminal color — so theme hexes stay exact on every frame type.
nil for the `unspecified-fg'/`unspecified-bg' placeholders a batch or tty
frame reports, and for anything the display can't resolve."
  (cond
   ((not (stringp color)) nil)
   ((string-prefix-p "unspecified" color) nil)
   ((string-match "\\`#\\([[:xdigit:]]+\\)\\'" color)
    (let* ((hex (match-string 1 color))
           (digits (/ (length hex) 3)))
      (when (and (> digits 0) (= (% (length hex) 3) 0))
        (let ((max (float (1- (expt 16 digits)))))
          (mapcar (lambda (i)
                    (/ (string-to-number
                        (substring hex (* i digits) (* (1+ i) digits))
                        16)
                       max))
                  '(0 1 2))))))
   (t (color-name-to-rgb color))))

(defun jetpacs-theme--hex (color)
  "COLOR normalized to \"#rrggbb\", or nil when unresolvable."
  (when-let ((rgb (jetpacs-theme--rgb color)))
    (apply #'format "#%02x%02x%02x"
           (mapcar (lambda (c) (min 255 (round (* 255 c)))) rgb))))

(defun jetpacs-theme--blend (a b frac)
  "FRAC of color A mixed into (1 - FRAC) of color B, as hex; nil on failure."
  (let ((ra (jetpacs-theme--rgb a))
        (rb (jetpacs-theme--rgb b)))
    (when (and ra rb)
      (apply #'format "#%02x%02x%02x"
             (cl-mapcar (lambda (ca cb)
                          (min 255 (round (* 255 (+ (* frac ca)
                                                    (* (- 1.0 frac) cb))))))
                        ra rb)))))

(defun jetpacs-theme--dark-p (color)
  "Non-nil when COLOR reads as a dark background (relative luminance < 0.5)."
  (when-let ((rgb (jetpacs-theme--rgb color)))
    (< (+ (* 0.2126 (nth 0 rgb))
          (* 0.7152 (nth 1 rgb))
          (* 0.0722 (nth 2 rgb)))
       0.5)))

(defun jetpacs-theme--face-color (attr &rest faces)
  "Inheritance-resolved ATTR of the first of FACES with a usable color, as hex."
  (catch 'hit
    (dolist (f faces)
      (when (facep f)
        (when-let ((hex (jetpacs-theme--hex (face-attribute f attr nil t))))
          (throw 'hit hex))))
    nil))

;; ─── Modus palette access ────────────────────────────────────────────────────

(defun jetpacs-theme--modus-p ()
  "Non-nil when a modus theme is active and its palette API is available.
The API (`modus-themes-get-color-value') exists from modus-themes 4 /
Emacs 30's bundled copy; older bundled versions fall through to the
generic face extraction, which handles modus fine — just without the
palette's purpose-built container tints."
  (and (fboundp 'modus-themes-get-color-value)
       (cl-find-if (lambda (theme)
                     (string-prefix-p "modus-" (symbol-name theme)))
                   custom-enabled-themes)
       t))

(defun jetpacs-theme--modus (key)
  "Hex value of the active modus theme's palette color KEY, or nil."
  (when-let ((value (ignore-errors (modus-themes-get-color-value key))))
    (and (stringp value) (jetpacs-theme--hex value))))

;; ─── Palette construction ────────────────────────────────────────────────────

(defun jetpacs-theme--compact (alist)
  "ALIST without the pairs whose value is nil."
  (cl-remove-if-not #'cdr alist))

(defun jetpacs-theme--colors ()
  "Material color-role alist for the active theme, or nil when unresolvable."
  (let* ((modus (jetpacs-theme--modus-p))
         (bg (or (and modus (jetpacs-theme--modus 'bg-main))
                 (jetpacs-theme--face-color :background 'default)))
         (fg (or (and modus (jetpacs-theme--modus 'fg-main))
                 (jetpacs-theme--face-color :foreground 'default))))
    (when (and bg fg)
      (let* ((primary (or (and modus (jetpacs-theme--modus 'blue))
                          (jetpacs-theme--face-color
                           :foreground 'link 'font-lock-function-name-face)
                          fg))
             (secondary (or (and modus (jetpacs-theme--modus 'magenta))
                            (jetpacs-theme--face-color
                             :foreground 'font-lock-keyword-face)
                            primary))
             (tertiary (or (and modus (jetpacs-theme--modus 'cyan))
                           (jetpacs-theme--face-color
                            :foreground 'font-lock-constant-face)
                           secondary))
             (err (or (and modus (jetpacs-theme--modus 'red))
                      (jetpacs-theme--face-color :foreground 'error)
                      "#b3261e"))
             ;; Container tone: modus ships purpose-built subtle tints
             ;; (documented as legible under fg-main); otherwise sink the
             ;; accent most of the way into the background.
             (container (lambda (accent modus-key)
                          (or (and modus (jetpacs-theme--modus modus-key))
                              (jetpacs-theme--blend accent bg 0.22))))
             (on-container (lambda (accent)
                             (if modus fg
                               (jetpacs-theme--blend accent fg 0.35)))))
        (jetpacs-theme--compact
         `((primary . ,primary)
           (on_primary . ,bg)
           (primary_container . ,(funcall container primary 'bg-blue-subtle))
           (on_primary_container . ,(funcall on-container primary))
           (secondary . ,secondary)
           (on_secondary . ,bg)
           (secondary_container . ,(funcall container secondary 'bg-magenta-subtle))
           (on_secondary_container . ,(funcall on-container secondary))
           (tertiary . ,tertiary)
           (on_tertiary . ,bg)
           (tertiary_container . ,(funcall container tertiary 'bg-cyan-subtle))
           (on_tertiary_container . ,(funcall on-container tertiary))
           (error . ,err)
           (on_error . ,bg)
           (error_container . ,(funcall container err 'bg-red-subtle))
           (on_error_container . ,(funcall on-container err))
           (background . ,bg)
           (on_background . ,fg)
           (surface . ,bg)
           (on_surface . ,fg)
           (surface_variant . ,(or (and modus (jetpacs-theme--modus 'bg-dim))
                                   (jetpacs-theme--face-color
                                    :background 'mode-line-inactive)
                                   (jetpacs-theme--blend fg bg 0.08)))
           (on_surface_variant . ,(or (and modus (jetpacs-theme--modus 'fg-dim))
                                      (jetpacs-theme--face-color
                                       :foreground 'mode-line-inactive)
                                      fg))
           (outline . ,(or (and modus (jetpacs-theme--modus 'border))
                           (jetpacs-theme--face-color :foreground 'shadow)
                           (jetpacs-theme--blend fg bg 0.5)))))))))

(defun jetpacs-theme--syntax ()
  "Editor token-color alist from the theme's font-lock/org/outline faces.
Keys mirror the companion's SyntaxColors; missing faces are simply
omitted and the companion keeps its static color for that token."
  (let* ((heading (cl-loop for f in '(outline-1 outline-2 outline-3
                                      outline-4 outline-5 outline-6)
                           for hex = (jetpacs-theme--face-color :foreground f)
                           when hex collect hex))
         (paren (cl-remove-duplicates
                 (delq nil
                       (mapcar (lambda (f)
                                 (jetpacs-theme--face-color :foreground f))
                               '(font-lock-keyword-face
                                 font-lock-constant-face
                                 font-lock-string-face
                                 font-lock-function-name-face
                                 font-lock-builtin-face
                                 font-lock-type-face)))
                 :test #'equal :from-end t)))
    (jetpacs-theme--compact
     `((comment . ,(jetpacs-theme--face-color
                    :foreground 'font-lock-comment-face))
       (string . ,(jetpacs-theme--face-color
                   :foreground 'font-lock-string-face))
       (keyword . ,(jetpacs-theme--face-color
                    :foreground 'font-lock-keyword-face))
       (function . ,(jetpacs-theme--face-color
                     :foreground 'font-lock-function-name-face))
       (constant . ,(jetpacs-theme--face-color
                     :foreground 'font-lock-constant-face))
       (number . ,(jetpacs-theme--face-color
                   :foreground 'font-lock-number-face
                   'font-lock-constant-face))
       (link . ,(jetpacs-theme--face-color :foreground 'link))
       (meta . ,(jetpacs-theme--face-color
                 :foreground 'font-lock-preprocessor-face 'shadow))
       (todo . ,(jetpacs-theme--face-color :foreground 'org-todo 'error))
       (done . ,(jetpacs-theme--face-color :foreground 'org-done 'success))
       (heading . ,(and heading (vconcat heading)))
       (paren . ,(and paren (vconcat paren)))))))

(defun jetpacs-theme-payload ()
  "The full `theme.set' payload for the active theme, or nil.
nil means the frame can't resolve colors (batch/tty) — callers must not
push in that case, so a colorless session never wipes a good palette."
  (when-let ((colors (jetpacs-theme--colors)))
    `((dark . ,(if (jetpacs-theme--dark-p (alist-get 'surface colors))
                   t :false))
      (colors . ,colors)
      (syntax . ,(jetpacs-theme--syntax)))))

;; ─── Pushing ─────────────────────────────────────────────────────────────────

(defun jetpacs-theme-send ()
  "Push the active Emacs theme's palette to the companion, once.
Works regardless of `jetpacs-theme-sync' — a manual one-shot mirror."
  (interactive)
  (cond
   ((not (jetpacs-connected-p))
    (message "Jetpacs: not connected"))
   ((not (jetpacs-granted-p "theme"))
    (message "Jetpacs: companion predates theme sync; update the app"))
   (t
    (let ((payload (jetpacs-theme-payload)))
      (if (null payload)
          (message "Jetpacs: this frame reports no usable theme colors")
        (jetpacs-send "theme.set" payload)
        (message "Jetpacs: theme pushed"))))))

(defun jetpacs-theme-clear ()
  "Revert the companion to its own scheme (Material You / Emacs purple).
Sends the documented clear form — `colors: null' — which also wipes the
palette the companion had persisted."
  (interactive)
  (when (and (jetpacs-connected-p) (jetpacs-granted-p "theme"))
    (jetpacs-send "theme.set" '((colors . :null)))))

(defvar jetpacs-theme--timer nil
  "Debounce timer for automatic pushes, or nil.")

(defun jetpacs-theme--push-soon (&rest _)
  "Debounced auto-push, gated on `jetpacs-theme-sync' and the theme grant.
Debounced because `load-theme' fires disable+enable back to back, and
re-gated inside the timer because the connection can die in between."
  (when (and jetpacs-theme-sync
             (jetpacs-connected-p)
             (jetpacs-granted-p "theme"))
    (when (timerp jetpacs-theme--timer)
      (cancel-timer jetpacs-theme--timer))
    (setq jetpacs-theme--timer
          (run-at-time
           0.2 nil
           (lambda ()
             (setq jetpacs-theme--timer nil)
             (when (and jetpacs-theme-sync (jetpacs-connected-p))
               (when-let ((payload (jetpacs-theme-payload)))
                 (jetpacs-send "theme.set" payload))))))))

(defun jetpacs-theme--on-connect (_welcome)
  (jetpacs-theme--push-soon))

(add-hook 'jetpacs-connected-hook #'jetpacs-theme--on-connect)

;; Emacs 29+: follow theme switches live. On 28 the palette still refreshes
;; on every (re)connect; push manually after a mid-session load-theme.
(when (boundp 'enable-theme-functions)
  (add-hook 'enable-theme-functions #'jetpacs-theme--push-soon)
  (add-hook 'disable-theme-functions #'jetpacs-theme--push-soon))

(provide 'jetpacs-theme)
;;; jetpacs-theme.el ends here
