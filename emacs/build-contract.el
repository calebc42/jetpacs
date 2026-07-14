;;; build-contract.el --- generate docs/contract.json from the source of truth -*- lexical-binding: t; -*-

;; NOT part of the bundle.  Regenerate the machine-readable wire contract:
;;
;;   emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write
;;
;; `docs/contract.json' publishes the *static* wire vocabulary a Kotlin renderer
;; or the composer editor validates emissions against — node types, action-hook
;; keys, the offline policies, the toolbar vocabulary, and a discriminated action
;; schema, plus the api/protocol versions.  It is STATIC ONLY: there is no
;; inferred per-node attribute schema (the golden examples are incomplete; live
;; node support is negotiated per-connection via `node_types', SPEC §3) and no
;; live registrations.  Output is byte-stable — fixed key order, arrays as
;; vectors, UTF-8/LF, one terminal newline — so the `jetpacs-contract-artifact-current'
;; drift test can diff a fresh run against the committed file.  Loading this file
;; only defines functions; it writes nothing until `jetpacs-contract-write' runs.

(require 'json)
(require 'seq)

(defvar jetpacs-contract--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repo root, derived from this file's own location.")

(add-to-list 'load-path (expand-file-name "emacs/core" jetpacs-contract--root))
(require 'jetpacs)
(require 'jetpacs-lint)
(require 'jetpacs-source)

(defconst jetpacs-contract-format 1
  "Schema version of `contract.json' itself — bump on a contract-shape change.")

(defun jetpacs-contract--names (syms)
  "SYMS as a JSON array (vector) of their names."
  (vconcat (mapcar #'symbol-name syms)))

(defun jetpacs-contract--action-schema ()
  "The discriminated action schema, derived from the lint defconsts.
`remote' is the named-action shape; each remaining key is a companion-local
builtin mapped to its required payload."
  (let ((optional (jetpacs-contract--names
                   (seq-difference jetpacs-lint-action-fields '(action builtin)))))
    (cons
     (cons "remote" (list (cons "required" ["action"])
                          (cons "optional" optional)))
     (mapcar
      (lambda (entry)
        (cons (car entry)
              (list (cons "required"
                          (vconcat (cons "builtin"
                                         (mapcar #'symbol-name (cdr entry)))))
                    (cons "optional" []))))
      jetpacs-lint-action-builtins))))

(defun jetpacs-contract ()
  "The contract as an ordered alist (objects) with vectors for arrays."
  (list
   (cons "contract_format"  jetpacs-contract-format)
   (cons "api_version"      jetpacs-api-version)
   (cons "protocol_version" jetpacs-protocol-version)
   (cons "node_types"       (vconcat jetpacs-lint-node-types))
   (cons "action_hook_keys" (jetpacs-contract--names jetpacs-lint--action-keys))
   (cons "action_fields"    (jetpacs-contract--names jetpacs-lint-action-fields))
   (cons "offline_policies" (vconcat jetpacs-lint--when-offline-values))
   (cons "offline_default"  "queue")
   (cons "action_schema"    (jetpacs-contract--action-schema))
   (cons "toolbar"
         (list (cons "ops"        (jetpacs-contract--names jetpacs-lint--toolbar-ops))
               (cons "placements" (vconcat jetpacs-lint--toolbar-placements))
               (cons "line_ops"   (vconcat jetpacs-lint--toolbar-line-ops))))
   (cons "binding"
         (list (cons "layouts"            (vconcat jetpacs-lint-spec-layouts))
               (cons "transforms"         (vconcat jetpacs-lint-spec-transforms))
               (cons "spec_keys"          (vconcat (mapcar (lambda (k) (substring (symbol-name k) 1))
                                                           jetpacs-lint-spec-keys)))
               (cons "chrome_kinds"       (vconcat jetpacs-lint-spec-chrome-kinds))
               (cons "source_field_types" (vconcat jetpacs-source-field-types))))))

(defun jetpacs-contract-string ()
  "The canonical JSON text of the contract, with one terminal newline."
  (let ((json-encoding-pretty-print t)
        (json-encoding-default-indentation "  ")
        (json-encoding-object-sort-predicate nil))
    (concat (json-encode (jetpacs-contract)) "\n")))

(defun jetpacs-contract-file ()
  "Committed location of `contract.json'."
  (expand-file-name "docs/contract.json" jetpacs-contract--root))

(defun jetpacs-contract-write ()
  "Write the contract to `docs/contract.json' (UTF-8, LF)."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (jetpacs-contract-string) nil (jetpacs-contract-file)))
  (message "Wrote %s" (jetpacs-contract-file)))

(provide 'build-contract)
;;; build-contract.el ends here
