;;; core-load-test.el --- The Jetpacs core must load standalone -*- lexical-binding: t; -*-

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

(dolist (feature '(jetpacs jetpacs-widgets jetpacs-lint jetpacs-surfaces jetpacs-source jetpacs-triggers
                   jetpacs-device jetpacs-minibuffer jetpacs-buffer jetpacs-shell jetpacs-spec
                   jetpacs-apps jetpacs-tablist jetpacs-comint jetpacs-results jetpacs-transient
                   jetpacs-keymap jetpacs-sync jetpacs-complete jetpacs-settings
                   jetpacs-files jetpacs-witheditor jetpacs-emacs-ui
                   jetpacs-package-browser jetpacs-customize
                   jetpacs-tools jetpacs-automations))
  (require feature))

(dolist (feature '(glasspane glasspane-ui glasspane-org jetpacs-magit))
  (when (featurep feature)
    (error "Core pulled in app feature %s" feature)))

;; Org stays confined to the jetpacs-org primitive layer: the rest of the
;; foundation must not pull org in on its own, so app authors who don't
;; touch org pay none of its weight.  jetpacs-org (loaded next) is the one
;; sanctioned exception.
(when (featurep 'org)
  (error "Core (excluding jetpacs-org) loaded org — an org dependency leaked into emacs/core/"))

;; jetpacs-org is the foundation's unopinionated org-primitive layer (query,
;; cache, heading refs, typed extraction, safe mutations).  Apps and
;; declarative runtimes build on it; it alone may require org.
(require 'jetpacs-org)
(unless (featurep 'jetpacs-org)
  (error "jetpacs-org failed to load"))
(unless (featurep 'org)
  (error "jetpacs-org did not provide org support"))

;; The shell must be servable on its own: views registered by core
;; feature modules exist even with no app loaded.
(unless (assoc "files" jetpacs-shell-views)
  (error "Shell has no files view"))
(unless (assoc "eval" jetpacs-shell-views)
  (error "Shell has no eval view"))
(unless (assoc "customize" jetpacs-shell-views)
  (error "Shell has no customize view"))
(unless (assoc "tools" jetpacs-shell-views)
  (error "Shell has no tools view"))
(unless (assoc "automations" jetpacs-shell-views)
  (error "Shell has no automations view"))

(message "Jetpacs core loads standalone: OK")

;;; core-load-test.el ends here
