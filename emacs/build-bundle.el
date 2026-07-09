;;; build-bundle.el --- Regenerate the single-file bundles from the sources -*- lexical-binding: t; -*-

;; Concatenate the sources into two loadable single-file bundles at the
;; repo root. Run this after editing any source file:
;;
;;   emacs --batch -l emacs/build-bundle.el
;;
;; Output:
;;   eabp-core.el  — the EABP foundation (emacs/core/): transport, shell,
;;                   generic renderers, minibuffer bridge, editor
;;                   sync/completion, settings machinery.  What a third-party
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
       (core-files '("core/eabp.el"
                     "core/eabp-widgets.el"
                     "core/eabp-lint.el"
                     "core/eabp-surfaces.el"
                     "core/eabp-triggers.el"
                     "core/eabp-device.el"
                     "core/eabp-minibuffer.el"
                     "core/eabp-buffer.el"
                     "core/eabp-shell.el"
                     "core/eabp-apps.el"
                     "core/eabp-tablist.el"
                     "core/eabp-comint.el"
                     "core/eabp-transient.el"
                     "core/eabp-keymap.el"
                     "core/eabp-sync.el"
                     "core/eabp-complete.el"
                     "core/eabp-settings.el"
                     "core/eabp-files.el"
                     "core/eabp-witheditor.el"
                     "core/eabp-emacs-ui.el"))
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
  (funcall emit (expand-file-name "../eabp-core.el" here)
           '(eabp-core) "EABP core client, single-file bundle"
           core-files))

;;; build-bundle.el ends here
