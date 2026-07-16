;;; build-contract.el --- generate eabp/contract.json from the source of truth -*- lexical-binding: t; -*-

;; NOT part of the bundle.  Regenerate the machine-readable wire contract:
;;
;;   emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write
;;
;; `eabp/contract.json' (the eabp protocol submodule — the published,
;; pinnable contract repo) publishes the *static* wire vocabulary a Kotlin renderer
;; or the composer editor validates emissions against — node types, the authored
;; per-node key schema and frame-kind schema (contract_format 3, Spec 1.0-rc),
;; action-hook keys, the offline policies, the toolbar vocabulary, and a
;; discriminated action schema, plus the api/protocol/spec versions.  It is
;; STATIC AND AUTHORED ONLY: the node/kind schemas are the hand-reviewed
;; `jetpacs-lint.el' tables, never inferred from golden examples, and there are
;; no live registrations (node support is still negotiated per-connection via
;; `node_types', SPEC §3).  Output is byte-stable — fixed key order, arrays as
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

(defconst jetpacs-contract-format 3
  "Schema version of `contract.json' itself — bump on a contract-shape change.
Format 2 (Spec 1.0-rc freeze, S1) adds `spec_version', `node_schema',
and `kind_schema'.  Format 3 (the eabp extraction) renames `api_version'
to `reference_api_version': the field describes the elisp reference
implementation's Tier-1 surface, not the wire — informational only, so
the contract repo reads as implementation-neutral.")

(defun jetpacs-contract--spec-version ()
  "The spec version declared in eabp/SPEC.md's status block (\"1.0-rc\").
SPEC.md is the single source of truth for this number; the ERT test
`jetpacs-spec-header-version-coherent' keeps the header machine-readable."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "eabp/SPEC.md" jetpacs-contract--root))
    (goto-char (point-min))
    (unless (re-search-forward
             "^Spec: \\*\\*\\([0-9]+\\.[0-9]+\\(?:-rc\\)?\\)\\*\\*" nil t)
      (error "eabp/SPEC.md header carries no parseable Spec: version"))
    (match-string 1)))

(defun jetpacs-contract--node-schema ()
  "The authored per-node key schema as contract objects.
The \"*\" row is the keys legal on any node (post-construction riders)."
  (cons
   (cons "*" (list (cons "required" [])
                   (cons "optional"
                         (jetpacs-contract--names jetpacs-lint-node-common-keys))))
   (mapcar (lambda (row)
             (cons (nth 0 row)
                   (list (cons "required" (jetpacs-contract--names (nth 1 row)))
                         (cons "optional" (jetpacs-contract--names (nth 2 row))))))
           jetpacs-lint-node-schema)))

(defun jetpacs-contract--kind-schema ()
  "The frame-kind schema as contract objects.
`direction' is the sender (client = Emacs, companion, or both); a kind
whose payload is a §9 node tree carries `payload: \"node\"' instead of
key lists."
  (mapcar (lambda (row)
            (cons (nth 0 row)
                  (if (eq (nth 2 row) 'node)
                      (list (cons "direction" (symbol-name (nth 1 row)))
                            (cons "payload" "node"))
                    (list (cons "direction" (symbol-name (nth 1 row)))
                          (cons "required" (jetpacs-contract--names (nth 2 row)))
                          (cons "optional" (jetpacs-contract--names (nth 3 row)))))))
          jetpacs-lint-kind-schema))

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
   ;; Informational: the reference elisp client's Tier-1 API version at
   ;; generation time.  Not a wire number — pin `protocol_version' /
   ;; `spec_version' instead.
   (cons "reference_api_version" jetpacs-api-version)
   (cons "protocol_version" jetpacs-protocol-version)
   (cons "spec_version"     (jetpacs-contract--spec-version))
   (cons "node_types"       (vconcat jetpacs-lint-node-types))
   (cons "node_schema"      (jetpacs-contract--node-schema))
   (cons "kind_schema"      (jetpacs-contract--kind-schema))
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
  "Committed location of `contract.json' (inside the eabp submodule)."
  (expand-file-name "eabp/contract.json" jetpacs-contract--root))

(defun jetpacs-contract-write ()
  "Write the contract to `eabp/contract.json' (UTF-8, LF)."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (jetpacs-contract-string) nil (jetpacs-contract-file)))
  (message "Wrote %s" (jetpacs-contract-file)))

(provide 'build-contract)
;;; build-contract.el ends here
