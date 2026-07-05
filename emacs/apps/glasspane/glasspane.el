;;; glasspane.el --- Glasspane: the reference org app on EABP -*- lexical-binding: t; -*-

;; The one-require entry point for the full reference app.  Pulls in the
;; EABP core (transport, shell, renderers, editor bridge) plus every
;; Glasspane module (org views, clock notification, magit pie, package
;; browser, demo tour):
;;
;;   (require 'glasspane)
;;
;; The pre-built single-file bundle at the repo root carries the same
;; feature name, so init files work unchanged with either install option.

;;; Code:

(require 'glasspane-ui)
(require 'glasspane-config)

;; Load the app-managed defaults (capture templates, agenda wiring) if
;; the user has opted in — init.el code after (require 'glasspane) still
;; runs later, so personal settings always win.
(glasspane-config-load)

(provide 'glasspane)
;;; glasspane.el ends here
