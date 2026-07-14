;;; init.el --- Jetpacs demo config: core + orgzly + glasspane -*- lexical-binding: t; -*-

;; The "everything installed" init for the alpha demo device: the
;; wizard's starter foundation plus all three bundles (jetpacs-core,
;; orgzly, glasspane) and the full native-Emacs phone ergonomics from
;; the previous daily-driver config.  Copy to ~/.emacs.d/init.el.
;;
;; NOTE for the shoot (docs/DEMO-VIDEO-SCRIPT.md): Scenes 1-5 record a
;; FRESH device using the wizard's own starter init — this file is the
;; Scene 6 end state, and the config to rehearse and daily-drive with.

;;; ── The bundles: jetpacs core + both apps ────────────────────────────
;; Single-file bundles live in ~/.emacs.d/elisp/.  A newer staged copy
;; is adopted automatically at startup: onboarding, dev deploy scripts,
;; and browser downloads all land in /sdcard/Documents/jetpacs; the
;; most-recent copy wins.
(add-to-list 'load-path (expand-file-name "elisp" user-emacs-directory))
(dolist (bundle '("jetpacs-core.el" "orgzly.el" "glasspane.el"))
  (let ((staged (seq-filter #'file-readable-p
                            (list (concat "/sdcard/Documents/jetpacs/" bundle))))
        (installed (expand-file-name (concat "elisp/" bundle)
                                     user-emacs-directory)))
    (dolist (s staged)
      (when (or (not (file-exists-p installed))
                (file-newer-than-file-p s installed))
        (make-directory (file-name-directory installed) t)
        (copy-file s installed t)
        (message "%s: adopted new bundle from %s"
                 bundle (file-name-directory s))))))
(require 'jetpacs-core)
(require 'orgzly)     ; Orgzly Revived in elisp — requires jetpacs-core
(require 'glasspane)  ; the org app — requires jetpacs-core

;; First run writes Glasspane's managed org defaults into
;; ~/.emacs.d/elisp/glasspane/ and loads them; later runs just load.
;; Refresh after an app update with M-x glasspane-config-sync.
(glasspane-config-ensure)

;;; ── Pairing ──────────────────────────────────────────────────────────
;; From the companion app's pairing screen.  If the app's data is
;; cleared (e.g. to re-record onboarding), the token regenerates —
;; re-copy it from the new pairing screen.
(setq jetpacs-auth-token "MVCZ-P35K-7K79-AMWW")

;; Mirror the active Emacs theme onto the phone (pushed after each
;; handshake) — with Nord loaded below, the companion picks up Nord.
(setq jetpacs-theme-sync t)

;;; ===============================================================
;;; Package Management
;;; ===============================================================
(require 'package)
(setq package-archives '(("melpa" . "https://melpa.org/packages/")
                         ("elpa"  . "https://elpa.gnu.org/packages/")))
(package-initialize)
;; Offline-safe: a failed refresh must not abort startup mid-init
;; (missing packages just warn and are skipped by use-package).
(unless package-archive-contents
  (ignore-errors (package-refresh-contents)))
(require 'use-package)
(setq use-package-always-ensure t)

;;; ===============================================================
;;; Emacs server (emacsclient from Termux)
;;; ===============================================================
(require 'server)
(setq server-socket-dir "~/.emacs.d/server")
(unless (server-running-p)
  (server-start))

;;; ===============================================================
;;; Performance (phone-sized)
;;; ===============================================================
(setq gc-cons-threshold (* 32 1024 1024))
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)

;;; ===============================================================
;;; Touch & display basics
;;; ===============================================================
(when (fboundp 'pixel-scroll-precision-mode)
  (pixel-scroll-precision-mode 1))
(setq touch-screen-precision-scroll t
      touch-screen-word-select t
      touch-screen-extend-selection t
      touch-screen-display-keyboard t)
(context-menu-mode 1)
(setq use-dialog-box t
      use-short-answers t
      inhibit-startup-screen t)
(setq scroll-margin 3
      scroll-preserve-screen-position t)
(when (eq system-type 'android)
  ;; Volume keys page the buffer — handy for one-handed reading.
  (setq android-pass-multimedia-buttons-to-system nil)
  (global-set-key (kbd "<volume-up>")   #'scroll-down-command)
  (global-set-key (kbd "<volume-down>") #'scroll-up-command))

;;; ===============================================================
;;; Tool bar: bottom of frame, touch shortcuts
;;; ===============================================================
(tool-bar-mode 1)
(menu-bar-mode 1)
(setq tool-bar-position 'bottom)
(when (boundp 'tool-bar-position)
  (modify-all-frames-parameters '((tool-bar-position . bottom))))
(setq tool-bar-button-margin 12)
(tool-bar-add-item "index" #'execute-extended-command
                   'execute-extended-command :help "M-x (execute command)")
(tool-bar-add-item "fold" #'consult-buffer
                   'consult-buffer :help "Switch buffer")
(tool-bar-add-item "exit" #'keyboard-quit
                   'keyboard-quit :help "C-g (quit)")
(defun my/tool-bar-tab ()
  "Simulate pressing TAB."
  (interactive)
  (setq unread-command-events (listify-key-sequence (kbd "TAB"))))
(tool-bar-add-item "right-arrow" #'my/tool-bar-tab
                   'my/tool-bar-tab :help "TAB (indent / org-cycle)")
(defun my/tool-bar-backtab ()
  "Simulate pressing Shift-TAB."
  (interactive)
  (setq unread-command-events (listify-key-sequence (kbd "<backtab>"))))
(tool-bar-add-item "left-arrow" #'my/tool-bar-backtab
                   'my/tool-bar-backtab :help "Shift-TAB")
;; Capture popup
(defun my/popup-centered (menu)
  "Pop up MENU centered horizontally."
  (popup-menu menu
              (list (list (/ (frame-pixel-width) 2)
                          (/ (frame-pixel-height) 3))
                    (selected-frame))))
(defvar my/org-capture-menu
  (let ((map (make-sparse-keymap "Capture")))
    (define-key map [link] '(menu-item "Link" (lambda () (interactive) (org-capture nil "l"))))
    (define-key map [note] '(menu-item "Note" (lambda () (interactive) (org-capture nil "n"))))
    (define-key map [todo] '(menu-item "Todo" (lambda () (interactive) (org-capture nil "t"))))
    map)
  "Popup menu of org-capture templates.")
(defun my/org-capture-touch ()
  "Choose an org-capture template from a tappable popup menu."
  (interactive)
  (my/popup-centered my/org-capture-menu))
(tool-bar-add-item "new" #'my/org-capture-touch
                   'my/org-capture-touch :help "Org capture (quick note)")
(defun my/toggle-keyboard ()
  "Toggle the on-screen keyboard."
  (interactive)
  (frame-toggle-on-screen-keyboard (selected-frame)))
(when (fboundp 'frame-toggle-on-screen-keyboard)
  (tool-bar-add-item "help" #'my/toggle-keyboard
                     'my/toggle-keyboard :help "Toggle on-screen keyboard"))
(when (fboundp 'modifier-bar-mode)
  (modifier-bar-mode 1))

;;; ===============================================================
;;; Org Mode
;;; ===============================================================
(use-package org
  :ensure nil
  :hook ((org-mode . visual-line-mode))
  :bind (("C-c a" . org-agenda)
         ("C-c c" . org-capture)
         ("C-c b" . org-store-link)
         :map org-mode-map
         ("C-S-p" . org-previous-visible-heading)
         ("C-S-n" . org-next-visible-heading)
         ("C-S-u" . outline-up-heading)
         ("C-c h" . my/org-collapse-this))
  :config
  (require 'org-id)

  (defun my/org-collapse-this ()
    "Jump to the current header and fold it."
    (interactive)
    (org-back-to-heading t)
    (org-fold-subtree t))
  ;; Directories setup
  (setq org-directory "~/org"
        org-default-notes-file (expand-file-name "inbox.org" org-directory))
  (make-directory org-directory t)

  ;; The directory covers every .org file in it (including trackers.org
  ;; when it exists); never list individual files that may be absent —
  ;; a missing agenda file makes Org prompt at startup.
  (setq org-agenda-files (list org-directory)
        org-agenda-skip-unavailable-files t)
  ;; Visual settings
  (setq org-startup-indented t
        org-hide-leading-stars t
        org-hide-emphasis-markers t
        org-src-fontify-natively t
        org-src-tab-acts-natively t
        org-edit-src-content-indentation 0)
  ;; Workflow & Refiling
  ;; (org-todo-keywords is managed via the phone's Settings screen and
  ;; saved to custom.el, loaded at the end of this file.)
  (setq org-refile-targets '((nil :maxlevel . 3)
                             (org-agenda-files :maxlevel . 3))
        org-refile-use-outline-path 'file
        org-outline-path-complete-in-steps nil
        org-refile-allow-creating-parent-nodes 'confirm)
  (setq org-return-follows-link t
        mouse-1-click-follows-link t)
  (set-face-attribute 'org-level-1 nil :height 1.3 :weight 'bold)
  (set-face-attribute 'org-level-2 nil :height 1.2 :weight 'bold)
  (set-face-attribute 'org-level-3 nil :height 1.1)
  (setq org-tag-alist '(("WORK" . ?w) ("HOME" . ?h)
                        ("STUDY" . ?s) ("URGENT" . ?u)))
  (org-babel-do-load-languages 'org-babel-load-languages
                               '((emacs-lisp . t)
                                 (shell . t)
                                 (python . t)))
  (add-to-list 'org-structure-template-alist '("w" . "warning"))
  (add-to-list 'org-structure-template-alist '("n" . "note"))
  (add-to-list 'org-structure-template-alist '("tip" . "tip"))
  (add-to-list 'org-structure-template-alist '("im" . "important")))

;; Capture templates: merge by key instead of setq — Glasspane's managed
;; config seeds its own templates, and a plain setq here would wipe them.
(with-eval-after-load 'org-capture
  (dolist (tmpl '(("t" "Todo" entry (file+headline org-default-notes-file "Tasks")
                   "* TODO %?\n  %U\n  %i" :empty-lines 1)
                  ("n" "Note" entry (file+headline org-default-notes-file "Notes")
                   "* %? :note:\n  %U\n  %i" :empty-lines 1)
                  ("l" "Link" entry (file+headline org-default-notes-file "Links")
                   "* %?\n  %U\n  %a" :empty-lines 1)))
    (setf (alist-get (car tmpl) org-capture-templates nil nil #'equal)
          (cdr tmpl))))

(defun my/org-tag-completion ()
  "Complete tags in Org headlines (global + buffer-local tags)."
  (when (and (eq major-mode 'org-mode)
             (org-at-heading-p))
    (when (looking-back ":\\([a-zA-Z0-9_@#%]*\\)" (line-beginning-position))
      (let* ((start (match-beginning 1))
             (end   (point))
             (global-tags (delq nil (mapcar (lambda (x) (if (stringp (car x)) (car x) nil)) org-tag-alist)))
             (local-tags (org-get-buffer-tags))
             (all-tags (delete-dups (append global-tags local-tags))))
        (list start end all-tags :exclusive 'no :annotation-function (lambda (_) " Tag"))))))
(add-hook 'org-mode-hook
          (lambda () (add-to-list 'completion-at-point-functions #'my/org-tag-completion)))

;; Org Tool Bar
(defvar my/org-insert-menu
  (let ((map (make-sparse-keymap "Org Insert")))
    (define-key map [link]     '(menu-item "Link..."         org-insert-link))
    (define-key map [deadline] '(menu-item "Deadline..."     org-deadline))
    (define-key map [schedule] '(menu-item "Schedule..."     org-schedule))
    (define-key map [checkbox] '(menu-item "Toggle checkbox" org-toggle-checkbox))
    (define-key map [refile]   '(menu-item "Refile..."       org-refile))
    (define-key map [heading]  '(menu-item "Heading" org-insert-heading-respect-content))
    map))
(defvar my/org-move-menu
  (let ((map (make-sparse-keymap "Org Move")))
    (define-key map [demote]  '(menu-item "Demote subtree"  org-demote-subtree))
    (define-key map [promote] '(menu-item "Promote subtree" org-promote-subtree))
    (define-key map [down]    '(menu-item "Subtree down"    org-move-subtree-down))
    (define-key map [up]      '(menu-item "Subtree up"      org-move-subtree-up))
    map))
(defun my/org-insert-popup () (interactive) (my/popup-centered my/org-insert-menu))
(defun my/org-move-popup ()   (interactive) (my/popup-centered my/org-move-menu))
(defun my/org-tool-bar-setup ()
  "Give Org buffers extra tool-bar buttons."
  (let ((map (copy-keymap tool-bar-map)))
    (tool-bar-local-item "checked" 'org-todo 'org-todo map :help "Cycle TODO state")
    (tool-bar-local-item "attach" 'my/org-insert-popup 'my/org-insert-popup map :help "Insert: heading, schedule, link...")
    (tool-bar-local-item "up-arrow" 'my/org-move-popup 'my/org-move-popup map :help "Move/promote/demote subtree")
    (setq-local tool-bar-map map)))
(add-hook 'org-mode-hook #'my/org-tool-bar-setup)

;; Org Ecosystem Packages
(use-package org-ql
  :after org
  :demand t   ; Glasspane's search tab uses the full org-ql language
  :bind (("C-c q s" . org-ql-search)
         ("C-c q v" . org-ql-view)
         ("C-c q f" . org-ql-find))
  :config
  ;; Custom views to separate actionable projects from non-actionable resources
  (setq org-ql-views
        (append
         '(("Actionable"
            :buffers-files org-agenda-files
            :query (todo "TODO" "IN PROGRESS")
            :sort (priority date))

           ("Resources"
            :buffers-files (directory-files-recursively org-directory "\\.org$")
            :query (and (not (todo))
                        (tags "note" "server"))
            :sort (date reverse))

           ("Urgent Areas"
            :buffers-files org-agenda-files
            :query (and (todo)
                        (tags "URGENT"))
            :sort (priority)))
         (bound-and-true-p org-ql-views))))
(use-package org-transclusion
  :after org
  :bind (("C-c n t" . org-transclusion-add)
         ("C-c n T" . org-transclusion-mode)
         ("C-c n e" . org-transclusion-make-from-link))
  :config
  (setq org-transclusion-live-sync-interval 5))

;;; ===============================================================
;;; Notes & review: vulpea, org-srs
;;; ===============================================================
;; vulpea keeps a SQLite index of the vault (titles, aliases, links);
;; Glasspane reads it for backlinks and the editor's [[ completion.
(use-package vulpea
  :if (and (fboundp 'sqlite-available-p) (sqlite-available-p))
  :config
  (setq vulpea-db-sync-directories (list org-directory))
  (vulpea-db-autosync-mode 1))

;; org-srs drives Glasspane's Review screen AND native-Emacs review.
(use-package org-srs
  :after org
  :hook (org-mode . org-srs-embed-overlay-mode)   ; optional: #+SRS embed markers
  :custom
  ;; Non-blocking reveal. Also what makes review work in *native* Emacs
  ;; on Android (the default reads a key the touch UI can't send).
  (org-srs-item-confirm #'org-srs-item-confirm-command)
  :bind (:map org-mode-map
              ("<f5>" . org-srs-review-rate-easy)
              ("<f6>" . org-srs-review-rate-good)
              ("<f7>" . org-srs-review-rate-hard)
              ("<f8>" . org-srs-review-rate-again))
  :config
  (org-srs-ui-mode 1))   ; child-frame touch buttons for native-Emacs review

;; org-roam retired: vulpea now provides the note index/backlinks that
;; Glasspane consumes, and two autosync SQLite indexes over the same
;; vault cost battery.  Re-enable if you still want its capture flow.
;; (use-package org-roam
;;   :if (and (fboundp 'sqlite-available-p) (sqlite-available-p))
;;   :custom
;;   (org-roam-directory (file-truename (expand-file-name "resources" org-directory)))
;;   (org-roam-completion-everywhere t)
;;   :bind (("C-c n f" . org-roam-node-find)
;;          ("C-c n i" . org-roam-node-insert)
;;          ("C-c n l" . org-roam-buffer-toggle)
;;          ("C-c n c" . org-roam-capture))
;;   :config
;;   (make-directory org-roam-directory t)
;;   (org-roam-db-autosync-mode))

;;; ===============================================================
;;; Notifications
;;; ===============================================================
(defun my/notify (title message &optional _urgency)
  "Send a system notification with TITLE and MESSAGE."
  (if (fboundp 'android-notifications-notify)
      (android-notifications-notify :title title :body message)
    (message "%s: %s" title message)))
(when (fboundp 'android-notifications-notify)
  (defun my/appt-notify (mins _new-time msg)
    (let ((mins (if (listp mins) (car mins) mins))
          (msg  (if (listp msg)  (car msg)  msg)))
      (my/notify (format "Org: in %s min" mins) msg)))
  (setq appt-display-format 'window
        appt-disp-window-function #'my/appt-notify
        appt-message-warning-time 10)
  (appt-activate 1)
  (with-eval-after-load 'org
    (add-hook 'org-agenda-finalize-hook #'org-agenda-to-appt)))

;;; ===============================================================
;;; History and State
;;; ===============================================================
(setq load-prefer-newer t)
(save-place-mode 1)
(setq history-length 25)
(savehist-mode 1)
(add-to-list 'savehist-additional-variables 'kill-ring)
(recentf-mode 1)
(setq recentf-max-menu-items 25
      recentf-max-saved-items 25)
(global-auto-revert-mode 1)
(setq global-auto-revert-non-file-buffers t
      auto-revert-verbose nil)
(auto-save-visited-mode 1)

;;; File Management (Backups, Auto-saves, Lockfiles)
;; Backups and auto-saves in one place, no lock files (single-user
;; device).
(setq backup-directory-alist
      `(("." . ,(expand-file-name "backups/" user-emacs-directory)))
      backup-by-copying t
      create-lockfiles nil)
(let ((auto-save-dir (expand-file-name "auto-save/" user-emacs-directory)))
  (make-directory auto-save-dir t)
  (setq auto-save-file-name-transforms `((".*" ,auto-save-dir t))))

;;; ===============================================================
;;; Editing Quality of Life
;;; ===============================================================
(setq kill-do-not-save-duplicates t)
(delete-selection-mode 1)
(global-subword-mode 1)
(setq-default fill-column 80
              indent-tabs-mode nil
              tab-width 4)
(defun my/smarter-move-beginning-of-line (arg)
  "Toggle point between first non-whitespace and beginning of line."
  (interactive "^p")
  (setq arg (or arg 1))
  (when (/= arg 1)
    (let ((line-move-visual nil))
      (forward-line (1- arg))))
  (let ((orig-point (point)))
    (back-to-indentation)
    (when (= orig-point (point))
      (move-beginning-of-line 1))))
(global-set-key (kbd "C-a") #'my/smarter-move-beginning-of-line)
(defun copy-file-path ()
  "Copy the current buffer file name to the clipboard."
  (interactive)
  (let ((filename (if (equal major-mode 'dired-mode)
                      (default-directory)
                    (buffer-file-name))))
    (when filename
      (kill-new filename)
      (message "Copied '%s'" filename))))
(global-set-key (kbd "C-c p") #'copy-file-path)
(use-package smartparens
  :hook ((prog-mode . smartparens-mode)
         (org-mode . smartparens-mode))
  :config
  (require 'smartparens-config))
(use-package yasnippet
  :hook ((prog-mode . yas-minor-mode)
         (org-mode . yas-minor-mode))
  :config (yas-reload-all))
(use-package yasnippet-snippets)
(show-paren-mode 1)
(setq show-paren-delay 0
      show-paren-when-point-inside-paren t)
(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

;;; ===============================================================
;;; Dired
;;; ===============================================================
(use-package dired
  :ensure nil
  :commands (dired dired-jump)
  :bind (("C-x C-j" . dired-jump))
  :config
  (setq dired-listing-switches "-alh"
        dired-dwim-target t
        dired-recursive-copies 'always
        dired-recursive-deletes 'always
        dired-kill-when-opening-new-dired-buffer t))

;;; ===============================================================
;;; Version Control
;;; ===============================================================
(use-package magit
  :bind (("C-x g" . magit-status)
         ("C-c g" . magit-file-dispatch))
  :custom
  ;; Keeps Magit from fracturing the window layout, ideal for smaller screens
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  ;; Automatically save relevant buffers when running Git operations
  (magit-save-repository-buffers 'dontask)
  :config
  ;; Add a touch-friendly shortcut to the bottom tool-bar
  (when (boundp 'tool-bar-map)
    (tool-bar-add-item "vc-dir" #'magit-status 'magit-status :help "Magit Status")))

;;; ===============================================================
;;; Discovery and Completion
;;; ===============================================================
(use-package which-key
  :ensure nil
  :init (which-key-mode)
  :config
  (setq which-key-idle-delay 0.3
        which-key-max-description-length nil
        which-key-sort-order 'which-key-prefix-then-key-order
        which-key-compute-remaps t))
(use-package vertico
  :init (vertico-mode)
  :custom (vertico-cycle t))
(use-package marginalia
  :after vertico
  :init (marginalia-mode))
(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))
(setq completion-ignore-case t
      read-buffer-completion-ignore-case t
      read-file-name-completion-ignore-case t)
(use-package consult
  :bind (("C-s" . consult-line)
         ("C-x b" . consult-buffer)
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)))
(use-package helpful
  :bind
  ([remap describe-function] . helpful-callable)
  ([remap describe-variable] . helpful-variable)
  ([remap describe-key] . helpful-key)
  ([remap describe-command] . helpful-command))
(use-package corfu
  :custom
  (corfu-auto t)
  (corfu-quit-no-match t)
  :init (global-corfu-mode)
  :config (setq corfu-auto-prefix 1))
(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim)
         ("C-h B" . embark-bindings))
  :init
  (setq prefix-help-command #'embark-prefix-help-command))
(use-package embark-consult
  :hook (embark-collect-mode . consult-preview-at-point-mode))
(use-package avy
  :bind (("M-j" . avy-goto-char-timer))
  :custom
  (avy-timeout-seconds 0.3)
  (avy-style 'pre))

;;; ===============================================================
;;; Window and Buffer Management
;;; ===============================================================
(winner-mode 1)
(repeat-mode 1)
(use-package popper
  :bind (("C-`"  . popper-toggle)
         ("M-`"  . popper-cycle))
  :init
  (setq popper-reference-buffers
        '("\\*Messages\\*" "Output\\*$" help-mode compilation-mode))
  (popper-mode +1)
  (popper-echo-mode +1))
(use-package tab-bar
  :ensure nil
  :init (tab-bar-mode 1)
  :bind (("M-[" . tab-previous)
         ("M-]" . tab-next))
  :config
  (setq tab-bar-show 1
        tab-bar-close-button-show nil
        tab-bar-new-button-show nil))
(use-package uniquify
  :ensure nil
  :custom
  (uniquify-buffer-name-style 'forward)
  (uniquify-separator "/")
  (uniquify-after-kill-buffer-p t)
  (uniquify-ignore-buffers-re "^\\*"))

;;; ===============================================================
;;; Undo System
;;; ===============================================================
(use-package vundo
  :bind ("C-x u" . vundo)
  :config (setq vundo-glyph-alist vundo-unicode-symbols))
(use-package undo-fu-session
  :config (global-undo-fu-session-mode))

;;; ===============================================================
;;; Aesthetics
;;; ===============================================================
(defun my/set-font-faces ()
  (if (find-font (font-spec :name "JetBrains Mono"))
      (set-face-attribute 'default nil :font "JetBrains Mono" :height 160)
    (set-face-attribute 'default nil :height 160)))
(my/set-font-faces)

;; With jetpacs-theme-sync t (set above), the companion app derives its
;; palette from this theme.
(use-package nord-theme
  :config
  (load-theme 'nord t)

  ;; Maintain the custom UI tweaks using the Nord color palette
  (let ((nord0 "#2E3440")  ;; main background
        (nord1 "#3B4252")  ;; lighter background for UI/blocks
        (nord3 "#4C566A")  ;; comments / subtle UI elements
        (nord4 "#D8DEE9")) ;; main text foreground
    (custom-set-faces
     `(fringe ((t :background ,nord0)))
     `(org-block-begin-line ((t :background ,nord1 :foreground ,nord3 :extend t)))
     `(org-block-end-line   ((t :background ,nord1 :foreground ,nord3 :extend t)))
     `(org-block ((t :background ,nord0 :extend t)))
     `(tool-bar ((t :foreground ,nord4 :background ,nord1))))))

(use-package nerd-icons)
(use-package doom-modeline
  :init (doom-modeline-mode 1)
  :config
  (setq doom-modeline-height 35
        doom-modeline-icon (and (find-font (font-spec :name "Symbols Nerd Font Mono")) t)
        doom-modeline-window-width-limit 60))
(column-number-mode 1)
(global-hl-line-mode 1)
(blink-cursor-mode -1)

;;; ===============================================================
;;; Lines, wrapping, numbers
;;; ===============================================================
(setq-default word-wrap t)
(setq visual-line-fringe-indicators '(left-curly-arrow right-curly-arrow))
(global-visual-line-mode 1)
(global-display-line-numbers-mode 1)
(setq display-line-numbers-width-start t)
(dolist (mode '(eshell-mode-hook org-agenda-mode-hook))
  (add-hook mode (lambda () (display-line-numbers-mode 0))))
(defun my/toggle-line-numbers-type ()
  "Toggle between relative and absolute line numbers in this buffer."
  (interactive)
  (if (eq display-line-numbers 'relative)
      (progn (setq display-line-numbers t)
             (message "Line numbers: Absolute"))
    (setq display-line-numbers 'relative)
    (message "Line numbers: Relative")))
(global-set-key (kbd "C-c l") #'my/toggle-line-numbers-type)

;;; ===============================================================
;;; Eshell
;;; ===============================================================
(use-package eshell
  :ensure nil
  :bind ("C-c e" . eshell)
  :config
  (setq eshell-history-size 5000
        eshell-save-history-on-exit t
        eshell-hist-ignoredups t
        eshell-scroll-to-bottom-on-input t))

;; Tree-sitter: where to fetch grammars, and prefer ts modes.
(setq treesit-language-source-alist
      '((python "https://github.com/tree-sitter/tree-sitter-python")
        (c      "https://github.com/tree-sitter/tree-sitter-c")
        (bash   "https://github.com/tree-sitter/tree-sitter-bash")))
(dolist (remap '((c-mode . c-ts-mode)
                 (sh-mode . bash-ts-mode)))
  (add-to-list 'major-mode-remap-alist remap))

;;; ── Settings persistence ─────────────────────────────────────────────
;; The phone's Settings screen saves through Customize.  Loaded LAST so
;; anything changed from the phone wins over the defaults in this file.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))

;;; ── Demo helpers ─────────────────────────────────────────────────────
;; Seed the guided-tour corpus into ~/org (overwrites the seven demo
;; file names — Scene 5 of the shooting script):
;;   (glasspane-demo-setup-org)
;; The hello app, if onboarding installed it:
;;   (load "/sdcard/Documents/jetpacs/jetpacs-hello.el")

;;; init.el ends here
