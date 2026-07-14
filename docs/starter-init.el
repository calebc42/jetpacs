;;; init.el --- Jetpacs starter configuration -*- lexical-binding: t; -*-

;; A minimal init for running Emacs with the Jetpacs companion app on
;; Android.  Copy it to ~/.emacs.d/init.el on the device (or add the seam
;; block below to your own init).
;;
;; Everything Jetpacs manages lives under its OWN tree, ~/.emacs.d/jetpacs/
;; — the core bundle, the apps you install, and its generated wiring.  Your
;; files stay yours: this init.el, ~/.emacs.d/custom.el (your saved
;; Settings), and ~/.emacs.d/jetpacs/user.el (your overrides, created once).
;; The foundation's phone ergonomics and file hygiene are applied by the
;; managed entry point, and anything you set wins because your files load
;; after it.

;;; ── The Jetpacs seam ─────────────────────────────────────────────────────
;; One line loads the managed entry point (like `(load custom-file)').  The
;; first run copies it in from /sdcard/Documents/jetpacs (staged by the
;; companion's onboarding); after that it self-updates, so this block never
;; changes again.  Keep it near the TOP of init.el, so an error later in your
;; own config can't stop the bridge from booting.
(let ((entry (expand-file-name "jetpacs/jetpacs-init.el" user-emacs-directory))
      (staged "/sdcard/Documents/jetpacs/jetpacs-init.el"))
  (when (and (file-readable-p staged)
             (or (not (file-exists-p entry))
                 (file-newer-than-file-p staged entry)))
    (make-directory (file-name-directory entry) t)
    (copy-file staged entry t))
  (unless (load entry t)
    (message "Jetpacs: %s is missing and nothing is staged at %s — run the companion app's setup, and check that Emacs can read shared storage" entry staged)))

;;; ── Pairing ──────────────────────────────────────────────────────────────
;; Open the Jetpacs app: its pairing screen shows a one-line
;; (setq jetpacs-auth-token "...") — tap it to copy, paste it below, and
;; restart Emacs (or eval the line).
;;
;; (setq jetpacs-auth-token "PASTE-YOUR-PAIRING-LINE-HERE")

;;; ── Your configuration ───────────────────────────────────────────────────
;; Anything below here (or in ~/.emacs.d/jetpacs/user.el) overrides the
;; foundation defaults — they were applied while the seam loaded, above.

;;; init.el ends here
