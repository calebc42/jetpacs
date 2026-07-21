;;; jetpacs-theme-picker.el --- shared scaffold for theme control screens -*- lexical-binding: t; -*-

;; The generic half of a theme picker/control satellite screen: palette
;; strip and per-theme preview swatches, prefix-stripped display names,
;; the companion-mirror note, the current-theme header card, the
;; light/dark grouped picker, and the customize cross-link.  A concrete
;; screen supplies its provider functions (theme list, current, dark-p,
;; palette color) and its action names; `jetpacs-modus.el' is the
;; built-in instantiation, and third-party theme families (ef-themes and
;; friends) parameterize the same scaffold from the app tier.
;;
;; Per-theme previews gate on `modus-themes-activate' — the modus 5.0
;; palette machinery that resolving a NON-current theme's colors needs;
;; derivative families built on that API (ef-themes 2.0+) get previews
;; for free, and older providers degrade to clean name-only rows.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)

(defconst jetpacs-theme-picker-strip-keys
  '(bg-main fg-main accent-0 accent-1 accent-2 accent-3 err info)
  "Palette roles shown in the current theme's swatch strip.")

(defun jetpacs-theme-picker-display-name (prefix theme)
  "A human-friendly label for THEME: drop PREFIX, then title-case,
so `modus-operandi-tinted' reads as \"Operandi Tinted\"."
  (capitalize
   (replace-regexp-in-string
    "-" " " (string-remove-prefix prefix (symbol-name theme)))))

(defun jetpacs-theme-picker-strip (color-fn)
  "The CURRENT theme's swatch strip: one chip per strip key.
COLOR-FN takes (KEY &optional THEME) and returns a hex string or nil;
called with no theme it reads the live palette, which resolves on every
provider version."
  (delq nil (mapcar (lambda (key) (jetpacs-swatch (funcall color-fn key)))
                    jetpacs-theme-picker-strip-keys)))

(defun jetpacs-theme-picker-preview (color-fn theme)
  "Per-theme swatches (background / foreground / accent) for THEME's row.
Only when the running palette machinery can resolve a NON-current
theme's colors (`modus-themes-activate', modus 5.0+); otherwise nil, so
the list shows uniformly clean names instead of swatches for the active
theme alone."
  (when (fboundp 'modus-themes-activate)
    (delq nil (mapcar (lambda (key)
                        (jetpacs-swatch (funcall color-fn key theme) 18))
                      '(bg-main fg-main accent-0)))))

(defun jetpacs-theme-picker-mirror-note (mirror-action)
  "Companion-mirror status: a live badge, or a one-tap switch to mirror mode.
MIRROR-ACTION is the action that flips `jetpacs-theme-mode' to `emacs'."
  (when (boundp 'jetpacs-theme-mode)
    (if (eq jetpacs-theme-mode 'emacs)
        (jetpacs-row (jetpacs-icon "smartphone" :size 16)
                     (jetpacs-text "Mirroring to the companion" 'caption))
      (jetpacs-chip "Mirror on phone" :icon "smartphone"
                    :on-tap (jetpacs-action mirror-action :when-offline "drop")))))

(cl-defun jetpacs-theme-picker-current-card (current &key display-fn dark-p-fn
                                                     color-fn mirror-action
                                                     none-label)
  "The header card: the active theme's name, polarity, palette, mirror status.
CURRENT is the active theme symbol or nil (NONE-LABEL shows then);
DISPLAY-FN renders its title, DARK-P-FN its polarity, COLOR-FN feeds the
palette strip, and MIRROR-ACTION the mirror note."
  (jetpacs-card
   (list (apply #'jetpacs-column
                (delq nil
                      (list (jetpacs-text (if current (funcall display-fn current)
                                            none-label)
                                          'title)
                            (when current
                              (jetpacs-text (concat (if (funcall dark-p-fn current)
                                                        "Dark" "Light")
                                                    " · " (symbol-name current))
                                            'caption))
                            (when current
                              (apply #'jetpacs-row
                                     (jetpacs-theme-picker-strip color-fn)))
                            (when current
                              (jetpacs-theme-picker-mirror-note mirror-action))))))))

(cl-defun jetpacs-theme-picker-theme-card (theme current &key display-fn
                                                 color-fn load-action)
  "A single-line row for THEME: name, preview swatches, and a marker; a tap
dispatches LOAD-ACTION with the theme name.  CURRENT (the active theme)
is checked and not re-loadable.  The swatches are spread as direct row
children (a nested `row' fills the width and would starve the weighted
name); polarity is omitted — the cards are already grouped under
Light/Dark headers."
  (let ((activep (eq theme current)))
    (jetpacs-card
     (list (apply #'jetpacs-row
                  (append
                   (list (jetpacs-box
                          (list (jetpacs-text (funcall display-fn theme) 'label))
                          :weight 1))
                   (jetpacs-theme-picker-preview color-fn theme)
                   (list (if activep
                             (jetpacs-icon "check_circle" :color "primary")
                           (jetpacs-icon "chevron_right"))))))
     :on-tap (unless activep
               (jetpacs-action load-action
                               :args `((theme . ,(symbol-name theme)))
                               :when-offline "drop")))))

(cl-defun jetpacs-theme-picker-themes-section (themes current &key dark-p-fn
                                                      display-fn color-fn
                                                      load-action)
  "The theme picker: THEMES as cards grouped Light then Dark."
  (let* ((light (seq-remove dark-p-fn themes))
         (dark (seq-filter dark-p-fn themes))
         (card (lambda (theme)
                 (jetpacs-theme-picker-theme-card theme current
                                                  :display-fn display-fn
                                                  :color-fn color-fn
                                                  :load-action load-action))))
    (append
     (when light (cons (jetpacs-section-header "Light") (mapcar card light)))
     (when dark (cons (jetpacs-section-header "Dark") (mapcar card dark))))))

(defun jetpacs-theme-picker-more-link (group)
  "A card cross-linking into the customize browser's GROUP."
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-icon "tune")
          (jetpacs-box (list (jetpacs-text "More options in Customize" 'label))
                       :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap (jetpacs-action "customize.show"
                           :args `((group . ,group))
                           :when-offline "drop")))

(provide 'jetpacs-theme-picker)
;;; jetpacs-theme-picker.el ends here
