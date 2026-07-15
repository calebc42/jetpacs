;;; build-bundle.el --- Regenerate the single-file bundles from the sources -*- lexical-binding: t; -*-

;; Concatenate the sources into two loadable single-file bundles at the
;; repo root. Run this after editing any source file:
;;
;;   emacs --batch -l emacs/build-bundle.el
;;
;; Output:
;;   jetpacs-core.el  — the Jetpacs foundation (emacs/core/): transport, shell,
;;                   generic renderers, minibuffer bridge, editor
;;                   sync/completion, settings machinery, and the stock
;;                   satellite screens (package/customize browsers, tools
;;                   hub, automations).  What a third-party
;;                   Tier 1 (the Glasspane app in its own repo, and others)
;;                   depends on.  The Glasspane app bundle is built by the
;;                   glasspane repo's own build-bundle.el, which requires this.
;;
;; The files are emitted in dependency order. Because every source ends with
;; a `(provide 'FEATURE)', the inter-file `(require ...)' forms become no-ops
;; once the providing chunk has loaded earlier in the bundle, so a plain
;; in-order concatenation loads correctly. External requires (org, dired,
;; cl-lib, ...) resolve normally.

;;; Code:

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       ;; Dependency order. Do not reorder without re-checking the require
       ;; graph.
       (core-files '("core/jetpacs.el"
                     "core/jetpacs-config.el"
                     "core/jetpacs-org.el"
                     "core/jetpacs-theme.el"
                     "core/jetpacs-widgets.el"
                     "core/jetpacs-lint.el"
                     "core/jetpacs-surfaces.el"
                     "core/jetpacs-source.el"
                     "core/jetpacs-triggers.el"
                     "core/jetpacs-device.el"
                     "core/jetpacs-minibuffer.el"
                     "core/jetpacs-buffer.el"
                     "core/jetpacs-shell.el"
                     "core/jetpacs-spec.el"
                     "core/jetpacs-apps.el"
                     "core/jetpacs-tablist.el"
                     "core/jetpacs-comint.el"
                     "core/jetpacs-results.el"
                     "core/jetpacs-hypertext.el"
                     "core/jetpacs-sections.el"
                     "core/jetpacs-transient.el"
                     "core/jetpacs-keymap.el"
                     "core/jetpacs-sync.el"
                     "core/jetpacs-complete.el"
                     "core/jetpacs-settings.el"
                     "core/jetpacs-files.el"
                     "core/jetpacs-witheditor.el"
                     "core/jetpacs-emacs-ui.el"
                     "core/jetpacs-package-browser.el"
                     "core/jetpacs-customize.el"
                     "core/jetpacs-tools.el"
                     "core/jetpacs-hosts.el"
                     "core/jetpacs-automations.el"
                     "core/jetpacs-app-store.el"))
       (emit (lambda (out features summary files)
               (with-temp-file out
                 (insert (format ";;; %s --- %s -*- lexical-binding: t; -*-\n"
                                 (file-name-nondirectory out) summary)
                         ";;\n"
                         ";; GENERATED FILE -- do not edit by hand.\n"
                         ";; Produced by emacs/build-bundle.el from the emacs/ sources.\n"
                         ";; Concatenated in dependency order; each part keeps its own `provide',\n"
                         ";; so the inter-file `require' forms resolve within this file.\n"
                         ";;\n"
                         ";;; Code:\n\n")
                 (dolist (f files)
                   (insert ";;; ==================================================================\n"
                           (format ";;; BEGIN %s\n" f)
                           ";;; ==================================================================\n\n")
                   (insert-file-contents (expand-file-name f here))
                   (goto-char (point-max))
                   (insert "\n"))
                 (dolist (feature features)
                   (insert (format "(provide '%s)\n" feature)))
                 (insert (format ";;; %s ends here\n" (file-name-nondirectory out))))
               (message "Wrote %s" out))))
  (funcall emit (expand-file-name "../jetpacs-core.el" here)
           '(jetpacs-core) "Jetpacs core client, single-file bundle"
           core-files))

;;; build-bundle.el ends here
