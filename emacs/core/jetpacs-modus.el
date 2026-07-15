;;; jetpacs-modus.el --- Control screen for the built-in modus themes -*- lexical-binding: t; -*-

;; A stock satellite screen — a peer to the package browser and the
;; customize menu — for Prot's modus themes, which ship inside Emacs
;; (28+).  Because they are always present and carry a real API, they earn
;; a first-class screen rather than being buried in the customize tree:
;;
;;  - pick a theme from a light/dark grouped list, each row previewing its
;;    background, foreground, and identity accent as swatches; the active
;;    theme is marked and a tap loads another;
;;  - a palette strip for the current theme (the same semantic roles the
;;    theme mirror reads — `accent-0', `err', …);
;;  - the everyday style options (bold, italic, mixed fonts, variable-pitch
;;    UI) as switches, each reloading the theme so the change shows at once;
;;  - Toggle / Rotate quick actions where the running modus version has them.
;;
;; This drives the theme of the *client's* Emacs.  It dovetails with
;; `jetpacs-theme-mode' (jetpacs-theme.el): when that is `emacs', switching
;; a theme here re-pushes the palette so the companion mirrors it live; when
;; it is not, the screen offers a one-tap "Mirror on phone" to flip it.
;;
;; The screen reads modus through its public API only
;; (`modus-themes-get-color-value', `modus-themes-load-theme',
;; `modus-themes-items', …), so it works with the version bundled in the
;; user's Emacs — 4.x on Emacs 30, 5.x elsewhere — lighting up the extras
;; (derivative themes, Rotate) only where that version provides them.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-shell)
(require 'jetpacs-settings)

;; The modus themes are an optional runtime dependency loaded on demand; every
;; use below is guarded.  Declared so the byte-compiler stays quiet.
(declare-function modus-themes-get-color-value "modus-themes"
                  (color &optional with-overrides theme))
(declare-function modus-themes-get-current-theme "modus-themes" ())
(declare-function modus-themes-get-all-known-themes "modus-themes" (&optional family))
(declare-function modus-themes-load-theme "modus-themes" (theme &optional hook))
(declare-function modus-themes-toggle "modus-themes" ())
(declare-function modus-themes-rotate "modus-themes" (themes &optional reverse))
(declare-function require-theme "custom" (feature &optional noerror))
(defvar modus-themes-items)
(defvar modus-themes-to-toggle)
(defvar modus-themes-to-rotate)

;; ─── Availability and loading ────────────────────────────────────────────────

(defun jetpacs-modus--available-p ()
  "Non-nil when the built-in modus themes are installed in this Emacs."
  (and (seq-some (lambda (theme)
                   (string-prefix-p "modus-" (symbol-name theme)))
                 (custom-available-themes))
       t))

(defun jetpacs-modus--ensure ()
  "Load the modus-themes library without enabling a theme; non-nil on success.
The library lives in the themes directory rather than on `load-path', so
`require-theme' (Emacs 29+) is the reliable loader; a plain `require' covers
the case where it is on `load-path', and `featurep' the case where a modus
theme is already active."
  (or (featurep 'modus-themes)
      (require 'modus-themes nil t)
      (and (fboundp 'require-theme)
           (ignore-errors (require-theme 'modus-themes t))
           (featurep 'modus-themes))))

;; ─── Theme queries ───────────────────────────────────────────────────────────

(defun jetpacs-modus--themes ()
  "Selectable modus themes: the stock set, plus derivatives where supported."
  (cond ((fboundp 'modus-themes-get-all-known-themes)
         (modus-themes-get-all-known-themes))
        ((boundp 'modus-themes-items) modus-themes-items)))

(defun jetpacs-modus--current ()
  "The active modus theme symbol, or nil."
  (if (fboundp 'modus-themes-get-current-theme)
      (modus-themes-get-current-theme)
    (let ((known (jetpacs-modus--themes)))
      (seq-find (lambda (theme) (memq theme known)) custom-enabled-themes))))

(defun jetpacs-modus--dark-p (theme)
  "Non-nil when THEME reads as a dark modus theme.
Prefer the theme's own `:background-mode' property (set by the modus 5.0
registry and by derivatives); fall back to the stock naming, where every
`vivendi' is dark and every `operandi' light."
  (let ((props (get theme 'theme-properties)))
    (if (plist-member props :background-mode)
        (eq (plist-get props :background-mode) 'dark)
      (string-match-p "vivendi" (symbol-name theme)))))

(defun jetpacs-modus--color (key &optional theme)
  "Hex value of modus palette KEY for THEME (or the current theme), or nil."
  (when (fboundp 'modus-themes-get-color-value)
    (let ((value (ignore-errors
                   (if theme
                       (modus-themes-get-color-value key nil theme)
                     (modus-themes-get-color-value key :with-overrides)))))
      (and (stringp value) value))))

;; ─── Swatches ────────────────────────────────────────────────────────────────

(defun jetpacs-modus--swatch (hex &optional size)
  "A round color chip of HEX at SIZE dp (default 22), or nil when HEX is nil."
  (when hex
    (jetpacs-surface nil :color hex :shape "circle"
                     :width (or size 22) :height (or size 22))))

(defconst jetpacs-modus--strip-keys
  '(bg-main fg-main accent-0 accent-1 accent-2 accent-3 err info)
  "Palette roles shown in the current theme's swatch strip.")

(defun jetpacs-modus--strip (theme)
  "The current-theme swatch strip: one chip per `jetpacs-modus--strip-keys'."
  (delq nil (mapcar (lambda (key)
                      (jetpacs-modus--swatch (jetpacs-modus--color key theme)))
                    jetpacs-modus--strip-keys)))

(defun jetpacs-modus--preview (theme)
  "A compact background / foreground / accent preview for THEME's list row."
  (delq nil (mapcar (lambda (key)
                      (jetpacs-modus--swatch (jetpacs-modus--color key theme) 16))
                    '(bg-main fg-main accent-0))))

;; ─── View sections ───────────────────────────────────────────────────────────

(defun jetpacs-modus--mirror-note ()
  "Companion-mirror status: a live badge, or a one-tap switch to mirror mode."
  (when (boundp 'jetpacs-theme-mode)
    (if (eq jetpacs-theme-mode 'emacs)
        (jetpacs-row (jetpacs-icon "smartphone" :size 16)
                     (jetpacs-text "Mirroring to the companion" 'caption))
      (jetpacs-chip "Mirror on phone" :icon "smartphone"
                    :on-tap (jetpacs-action "modus.mirror" :when-offline "drop")))))

(defun jetpacs-modus--current-card (current)
  "The header card: the active theme's name, polarity, palette, mirror status."
  (jetpacs-card
   (list (apply #'jetpacs-column
                (delq nil
                      (list (jetpacs-text (if current (symbol-name current)
                                            "No modus theme active")
                                          'title)
                            (when current
                              (jetpacs-text (if (jetpacs-modus--dark-p current)
                                                "Dark" "Light")
                                            'caption))
                            (when current (apply #'jetpacs-row (jetpacs-modus--strip current)))
                            (when current (jetpacs-modus--mirror-note))))))))

(defun jetpacs-modus--actions-row ()
  "Quick-action buttons the running modus version supports, or nil."
  (let (buttons)
    (when (and (fboundp 'modus-themes-rotate)
               (boundp 'modus-themes-to-rotate))
      (push (jetpacs-button "Rotate"
                            (jetpacs-action "modus.rotate" :when-offline "drop")
                            :icon "autorenew" :variant "tonal")
            buttons))
    (when (and (fboundp 'modus-themes-toggle)
               (boundp 'modus-themes-to-toggle)
               (= (length modus-themes-to-toggle) 2))
      (push (jetpacs-button "Toggle"
                            (jetpacs-action "modus.toggle" :when-offline "drop")
                            :icon "brightness_6" :variant "tonal")
            buttons))
    (when buttons (apply #'jetpacs-row buttons))))

(defun jetpacs-modus--theme-card (theme current)
  "A row for THEME: name, polarity, preview swatches; a tap loads it.
CURRENT (the active theme) is marked and not re-loadable."
  (let ((activep (eq theme current)))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-box (list (jetpacs-column
                                (jetpacs-text (symbol-name theme) 'label)
                                (jetpacs-text (if (jetpacs-modus--dark-p theme)
                                                  "Dark" "Light")
                                              'caption)))
                         :weight 1)
            (apply #'jetpacs-row (jetpacs-modus--preview theme))
            (if activep
                (jetpacs-icon "check_circle" :color "primary")
              (jetpacs-icon "chevron_right"))))
     :on-tap (unless activep
               (jetpacs-action "modus.load"
                               :args `((theme . ,(symbol-name theme)))
                               :when-offline "drop")))))

(defun jetpacs-modus--themes-section (current)
  "The theme picker: cards grouped Light then Dark."
  (let* ((themes (jetpacs-modus--themes))
         (light (seq-remove #'jetpacs-modus--dark-p themes))
         (dark (seq-filter #'jetpacs-modus--dark-p themes))
         (card (lambda (theme) (jetpacs-modus--theme-card theme current))))
    (append
     (when light (cons (jetpacs-section-header "Light") (mapcar card light)))
     (when dark (cons (jetpacs-section-header "Dark") (mapcar card dark))))))

(defconst jetpacs-modus--options
  '((modus-themes-bold-constructs    . "Bold keywords")
    (modus-themes-italic-constructs  . "Italic comments")
    (modus-themes-mixed-fonts        . "Mixed fonts in code")
    (modus-themes-variable-pitch-ui  . "Variable-pitch UI")
    (modus-themes-disable-other-themes . "Disable other themes on load"))
  "Modus style options exposed as switches, each with a friendly label.")

(defun jetpacs-modus--option-symbols ()
  "Just the option symbols from `jetpacs-modus--options'."
  (mapcar #'car jetpacs-modus--options))

(defun jetpacs-modus--style-section ()
  "The style options as switch cards."
  (cons
   (jetpacs-section-header "Style")
   (mapcar (lambda (opt)
             (let ((sym (car opt)) (label (cdr opt)))
               (jetpacs-card
                (list (if (boundp sym)
                          (jetpacs-settings-item sym
                                                 :label label
                                                 :id-prefix "modus/"
                                                 :set-action "modus.set"
                                                 :reset-action "modus.reset")
                        (jetpacs-text (concat label " — not available") 'caption))))))
           jetpacs-modus--options)))

(defun jetpacs-modus--more-link ()
  "A card cross-linking into the customize browser's modus group."
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-icon "tune")
          (jetpacs-box (list (jetpacs-text "More options in Customize" 'label))
                       :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap (jetpacs-action "customize.show"
                           :args '((group . "modus-themes"))
                           :when-offline "drop")))

(defun jetpacs-modus--body ()
  "The screen body, assuming the modus library is loaded."
  (let ((current (jetpacs-modus--current)))
    (apply #'jetpacs-lazy-column
           (delq nil
                 (append
                  (list (jetpacs-modus--current-card current)
                        (jetpacs-modus--actions-row))
                  (jetpacs-modus--themes-section current)
                  (list (jetpacs-modus--style-section))
                  (list (jetpacs-modus--more-link)))))))

(defun jetpacs-modus--view (snackbar)
  "The shell view: back returns to the settings screen."
  (jetpacs-shell-nav-view
   "Modus Themes"
   (if (jetpacs-modus--ensure)
       (jetpacs-modus--body)
     (jetpacs-column
      (jetpacs-text "The modus themes are not available in this Emacs." 'body)))
   :back-to "settings"
   :snackbar snackbar))

;; ─── Live re-apply ───────────────────────────────────────────────────────────

(defun jetpacs-modus--reload (&rest _)
  "Reload the active modus theme so a just-changed option takes effect.
Modus 5.0 dropped the auto-reload its options used to trigger, so we do it
here; the reload also drives `enable-theme-functions', re-pushing the mirror
when `jetpacs-theme-mode' is `emacs'."
  (when-let ((theme (jetpacs-modus--current)))
    (when (fboundp 'modus-themes-load-theme)
      (ignore-errors (modus-themes-load-theme theme)))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "modus.show"
  (lambda (_ __)
    (jetpacs-shell-push nil :switch-to "modus")))

(jetpacs-defaction "modus.load"
  (lambda (args _)
    (let* ((name (alist-get 'theme args))
           (sym (and (stringp name) (intern-soft name))))
      (if (and sym (jetpacs-modus--ensure) (memq sym (jetpacs-modus--themes)))
          (condition-case err
              (modus-themes-load-theme sym)
            (error (jetpacs-shell-notify (error-message-string err))))
        (jetpacs-shell-notify (format "Unknown modus theme: %s" (or name "?"))))
      (jetpacs-shell-push))))

(jetpacs-defaction "modus.toggle"
  (lambda (_ __)
    (when (and (jetpacs-modus--ensure) (fboundp 'modus-themes-toggle))
      (condition-case err (modus-themes-toggle)
        (error (jetpacs-shell-notify (error-message-string err)))))
    (jetpacs-shell-push)))

(jetpacs-defaction "modus.rotate"
  (lambda (_ __)
    (when (and (jetpacs-modus--ensure)
               (fboundp 'modus-themes-rotate)
               (boundp 'modus-themes-to-rotate))
      (condition-case err (modus-themes-rotate modus-themes-to-rotate)
        (error (jetpacs-shell-notify (error-message-string err)))))
    (jetpacs-shell-push)))

(jetpacs-defaction "modus.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (memq sym (jetpacs-modus--option-symbols))
          (progn
            (jetpacs-settings-apply-wire sym (alist-get 'value args))
            (jetpacs-modus--reload))
        (jetpacs-shell-notify (format "%s is not a modus option" (or name "?"))))
      (jetpacs-shell-push))))

(jetpacs-defaction "modus.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (when (memq sym (jetpacs-modus--option-symbols))
        (jetpacs-settings-reset sym)
        (jetpacs-modus--reload))
      (jetpacs-shell-push))))

(jetpacs-defaction "modus.mirror"
  ;; Flip the companion into mirror mode; its `:set' pushes the current theme.
  (lambda (_ __)
    (when (boundp 'jetpacs-theme-mode)
      (jetpacs-settings-apply 'jetpacs-theme-mode 'emacs))
    (jetpacs-shell-push)))

;; ─── Registration ────────────────────────────────────────────────────────────

;; The style switches publish state.changed under `modus/<name>'; register
;; their handlers up front (like a settings section) so a toggle queued
;; offline replays even before the screen has first rendered.  The reload
;; after-set re-applies the theme so the change is visible.
(dolist (sym (jetpacs-modus--option-symbols))
  (jetpacs-settings-watch-toggle
   sym (concat "modus/" (symbol-name sym)) #'jetpacs-modus--reload))

(when (jetpacs-modus--available-p)
  (jetpacs-shell-define-view "modus" :builder #'jetpacs-modus--view :order 87)
  ;; Entry point: a card in the settings screen's Emacs section, beside the
  ;; package browser and customize menu (companion-local switch, works offline).
  (jetpacs-settings-add-link
   25 (lambda ()
        (jetpacs-card
         (list (jetpacs-row
                (jetpacs-icon "palette")
                (jetpacs-box (list (jetpacs-column
                                    (jetpacs-text "Modus Themes" 'label)
                                    (jetpacs-text "Pick, preview, and tune the built-in themes"
                                                  'caption)))
                             :weight 1)
                (jetpacs-icon "chevron_right")))
         :on-tap (jetpacs-action "modus.show" :when-offline "drop")))))

(provide 'jetpacs-modus)
;;; jetpacs-modus.el ends here
