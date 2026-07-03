;;; build-bundle.el --- Regenerate ../glasspane.el from the sources -*- lexical-binding: t; -*-

;; Concatenate the eabp-*.el sources into a single loadable file: glasspane.el
;; (written to the repo root). Run this after editing any source file.
;;
;;   emacs --batch -l emacs/build-bundle.el
;;
;; The files are emitted in dependency order. Because every source ends with a
;; `(provide 'FEATURE)', the inter-file `(require 'eabp-...)' forms become no-ops
;; once the providing chunk has loaded earlier in the bundle, so a plain in-order
;; concatenation loads correctly. External requires (org, dired, cl-lib, ...)
;; resolve normally.

;;; Code:

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (out  (expand-file-name "../glasspane.el" here))
       ;; Dependency order. Do not reorder without re-checking the require graph.
       (files '("eabp.el"
                "eabp-widgets.el"
                "eabp-surfaces.el"
                "eabp-minibuffer.el"
                "eabp-buffer.el"
                "eabp-org-rich.el"
                "eabp-org-reader.el"
                "eabp-org.el"
                "eabp-keymap.el"
                "eabp-magit.el"
                "eabp-emacs-ui.el"
                "eabp-sync.el"
                "eabp-complete.el"
                "eabp-settings.el"
                "eabp-files.el"
                "eabp-org-ui.el"
                "eabp-demo.el")))
  (with-temp-file out
    (insert ";;; glasspane.el --- Glasspane Emacs client, single-file bundle -*- lexical-binding: t; -*-\n"
            ";;\n"
            ";; GENERATED FILE -- do not edit by hand.\n"
            ";; Produced by emacs/build-bundle.el from the emacs/eabp-*.el sources.\n"
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
    (insert "(provide 'glasspane)\n"
            ";;; glasspane.el ends here\n"))
  (message "Wrote %s" out))

;;; build-bundle.el ends here
