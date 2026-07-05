;;; core-load-test.el --- The EABP core must load standalone -*- lexical-binding: t; -*-

;; The delineation guard: loads ONLY emacs/core/ — the apps directory is
;; not even on the load-path — and asserts the foundation is complete and
;; app-free.  If a core module ever grows a (require 'glasspane-...) or an
;; org dependency, this fails.
;;
;; Run from the repo root (any Emacs 28+):
;;   emacs -Q --batch -l test/core-load-test.el

;;; Code:

(add-to-list 'load-path
             (expand-file-name "../emacs/core"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))

(dolist (feature '(eabp eabp-widgets eabp-surfaces eabp-minibuffer
                   eabp-buffer eabp-shell eabp-tablist eabp-comint
                   eabp-transient eabp-keymap eabp-sync eabp-complete
                   eabp-settings eabp-files eabp-witheditor eabp-emacs-ui))
  (require feature))

(dolist (feature '(glasspane glasspane-ui glasspane-org eabp-magit
                   eabp-package-browser))
  (when (featurep feature)
    (error "Core pulled in app feature %s" feature)))

;; The core is org-agnostic by contract; org loads only when a Tier 1
;; app (or the user) asks for it.
(when (featurep 'org)
  (error "Core loaded org — an org dependency leaked into emacs/core/"))

;; The shell must be servable on its own: views registered by core
;; feature modules exist even with no app loaded.
(unless (assoc "files" eabp-shell-views)
  (error "Shell has no files view"))
(unless (assoc "eval" eabp-shell-views)
  (error "Shell has no eval view"))

(message "EABP core loads standalone: OK")

;;; core-load-test.el ends here
