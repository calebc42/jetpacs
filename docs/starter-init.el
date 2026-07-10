;;; init.el --- Jetpacs starter configuration -*- lexical-binding: t; -*-

;; A minimal init for running Emacs with the Jetpacs companion app on
;; Android.  Copy it to ~/.emacs.d/init.el on the device (or use it as
;; the seed for your own config).  It sets up the foundation only:
;; loading the core bundle, pairing, and phone ergonomics.  Everything
;; works with built-in Emacs alone.
;;
;; Apps (Glasspane, orgzly-native, your own) ship as single .el bundles
;; from their own projects.  To install one: download its bundle (your
;; browser saves to Download), add its file name to the list below, add
;; its `require', restart Emacs.  Each app's own starter init (in its
;; repo) is the fuller alternative to this file.

;;; ── The Jetpacs core bundle ──────────────────────────────────────────
;; jetpacs-core.el lives at ~/.emacs.d/elisp/.  A newer staged copy is
;; adopted automatically at startup: the companion app's onboarding
;; writes it to /sdcard/Documents, the deploy scripts (a dev machine)
;; stage to /sdcard/Download, and a browser download also lands in
;; Download.  Both slots are checked and the most-recent copy wins —
;; and every app bundle you add to the list is adopted the same way.
(add-to-list 'load-path (expand-file-name "elisp" user-emacs-directory))
(dolist (bundle '("jetpacs-core.el"))   ; add app bundles: "glasspane.el" …
  (let ((staged (seq-filter #'file-readable-p
                            (list (concat "/sdcard/Documents/" bundle)
                                  (concat "/sdcard/Download/" bundle))))
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
;; (require 'glasspane)  ; after adding its bundle to the list above

;;; ── Pairing ──────────────────────────────────────────────────────────
;; Open the Jetpacs app: its pairing screen shows a one-line
;; (setq jetpacs-auth-token "...") — tap it to copy, then paste it below
;; and restart Emacs (or eval the line).
;;
;; (setq jetpacs-auth-token "PASTE-YOUR-PAIRING-LINE-HERE")

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
;; Backups and auto-saves in one place, no lock files (single-user
;; device), auto-revert so external edits appear in open buffers.
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

;;; ── Try the hello demo ───────────────────────────────────────────────
;; If the onboarding installed jetpacs-hello.el, evaluate this from the
;; phone's Eval tab (or any REPL) on a connected session and watch a
;; Hello tab appear live:
;;
;;   (load "/sdcard/Documents/jetpacs-hello.el")

;;; init.el ends here
