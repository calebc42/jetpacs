;;; init.el --- Glasspane starter configuration -*- lexical-binding: t; -*-

;; A minimal init for running Emacs with the Glasspane companion app on
;; Android.  Copy it to ~/.emacs.d/init.el on the device (or use it as
;; the seed for your own config).  Everything works with built-in Emacs
;; alone; the two external packages (org-ql for the search tab, vulpea
;; for backlinks and note completion) install themselves on the first
;; launch with a network connection and are skipped gracefully offline —
;; startup never breaks either way.
;;
;; How the pieces divide:
;;   - This file: getting the bundle loaded, pairing, phone basics.
;;   - ~/.emacs.d/elisp/glasspane/: Glasspane's own opinionated org
;;     defaults (capture templates, agenda wiring, babel languages),
;;     written and kept current BY THE APP.  Don't edit those files —
;;     anything you set here, after the (require 'glasspane) line, wins.
;;   - M-x customize (saved to custom.el): settings changed from the
;;     phone's Settings screen land here.

;;; ── Glasspane bundle ─────────────────────────────────────────────────
;; The single-file bundle lives at ~/.emacs.d/elisp/glasspane.el.  A
;; newer staged copy is adopted automatically at startup: the companion
;; app's onboarding writes it to /sdcard/Documents, and deploy.ps1 (a
;; dev machine) stages it to /sdcard/Download.  Both slots are checked
;; and the most-recent copy wins, so either delivery path just works.
(add-to-list 'load-path (expand-file-name "elisp" user-emacs-directory))
(let ((staged (seq-filter #'file-readable-p
                          '("/sdcard/Documents/glasspane.el"
                            "/sdcard/Download/glasspane.el")))
      (installed (expand-file-name "elisp/glasspane.el" user-emacs-directory)))
  (dolist (s staged)
    (when (or (not (file-exists-p installed))
              (file-newer-than-file-p s installed))
      (make-directory (file-name-directory installed) t)
      (copy-file s installed t)
      (message "glasspane: adopted new bundle from %s"
               (file-name-directory s)))))
(require 'glasspane)

;; First run writes Glasspane's managed org defaults into
;; ~/.emacs.d/elisp/glasspane/ and loads them; later runs just load.
;; Refresh them after an app update with M-x glasspane-config-sync.
(glasspane-config-ensure)

;;; ── Pairing ──────────────────────────────────────────────────────────
;; Open the Glasspane app: its "Waiting for Emacs" screen shows a
;; one-line (setq eabp-auth-token "...") — tap it to copy, then paste
;; it below and restart Emacs (or eval the line).
;;
;; (setq eabp-auth-token "PASTE-YOUR-PAIRING-LINE-HERE")

;;; ── Settings persistence ─────────────────────────────────────────────
;; The phone's Settings screen saves through Customize; keep that out of
;; this file and load it on startup.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))

;;; ── Touch and display basics ─────────────────────────────────────────
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
(when (eq system-type 'android)
  ;; Volume keys page the buffer — handy for one-handed reading.
  (setq android-pass-multimedia-buttons-to-system nil)
  (global-set-key (kbd "<volume-up>")   #'scroll-down-command)
  (global-set-key (kbd "<volume-down>") #'scroll-up-command))

;;; ── File hygiene ─────────────────────────────────────────────────────
;; Keep clutter out of your org directory: backups and auto-saves in
;; one place, no lock files (single-user device), auto-revert so edits
;; from the phone appear in open buffers.
(setq backup-directory-alist
      `(("." . ,(expand-file-name "backups/" user-emacs-directory)))
      backup-by-copying t
      create-lockfiles nil)
(let ((auto-save-dir (expand-file-name "auto-save/" user-emacs-directory)))
  (make-directory auto-save-dir t)
  (setq auto-save-file-name-transforms `((".*" ,auto-save-dir t))))
(global-auto-revert-mode 1)
(setq global-auto-revert-non-file-buffers t
      auto-revert-verbose nil)
(save-place-mode 1)
(savehist-mode 1)
(recentf-mode 1)

;;; ── External packages: org-ql, vulpea, org-srs ───────────────────────
;; All optional, all degrade cleanly:
;;   - org-ql: the search tab understands the common queries on its own
;;     (todo:/tags:/priority: tokens, free text, and sexps like
;;     (and (todo "TODO") (tags "work"))); installing org-ql unlocks the
;;     rest of the language — ts/clocked/property comparators and friends.
;;   - vulpea (v2+): the note database behind backlinks, unlinked
;;     mentions, and [[ note completion in the phone editor.  Without it
;;     those sections simply don't appear.
;;   - org-srs: spaced repetition (FSRS) behind the Review screen and
;;     the detail view's "Make flashcard".  Without it the Review drawer
;;     entry simply doesn't exist.
;; Installs are attempted once per launch until they succeed; with no
;; network nothing breaks.
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(dolist (pkg '(org-ql vulpea org-srs))
  (unless (package-installed-p pkg)
    (condition-case err
        (progn
          (unless package-archive-contents
            (package-refresh-contents))
          (package-install pkg))
      (error (message "starter-init: %s install deferred (%s)"
                      pkg (error-message-string err))))))
(require 'org-ql nil t)

;;; ── Notes database: vulpea ───────────────────────────────────────────
;; vulpea keeps a SQLite index of the vault (titles, aliases, links) and
;; watches `org-directory' for changes — including external ones from
;; git or Syncthing.  Glasspane reads it for the detail view's backlinks
;; and the editor's [[ completion; index updates stay off the save path.
(when (require 'vulpea nil t)
  (setq vulpea-db-sync-directories (list org-directory))
  (vulpea-db-autosync-mode 1))

;;; ── Spaced repetition: org-srs ───────────────────────────────────────
;; The command-style confirm is what makes phone-driven review work (the
;; default reads a key), and it is upstream's own recommendation for
;; Emacs on Android.  The Review screen also binds it defensively.
(when (require 'org-srs nil t)
  (setq org-srs-item-confirm #'org-srs-item-confirm-command))

;;; ── Try the demo ─────────────────────────────────────────────────────
;; M-x glasspane-demo-setup-org writes a sample org corpus (tables,
;; babel, LaTeX, agenda data, flashcards) into ~/org — note it
;; overwrites the seven demo file names if they already exist.  With
;; org-srs installed the flashcards register as live review items.

;;; init.el ends here
