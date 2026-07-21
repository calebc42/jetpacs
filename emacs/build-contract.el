;;; build-contract.el --- project the lint tables for conformance against ebp -*- lexical-binding: t; -*-

;; NOT part of the bundle.  The reference pair's conformance projector:
;; regenerate THIS implementation's view of the wire contract and compare
;; it against `ebp/contract.json' — the authored truth (the ebp repo owns
;; the contract; ebp SPEC-CHANGES #30, the Option-B inversion of
;; docs/PLAN-ebp-extraction.md).  On a mismatch: if unintended, fix the
;; lint tables/constructors here until the drift test
;; (`jetpacs-contract-artifact-current') passes; if intended, the wire
;; change lands in ebp FIRST (amendment row + hand-edit of the contract),
;; and this projector then proves the tables match.  To regenerate in
;; place, for comparison or to propose an upstream edit:
;;
;;   emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write
;;
;; Since the #30 follow-up `jetpacs-lint's wire tables themselves DERIVE
;; from ebp/contract.json at load, making this projection a ROUND TRIP:
;; contract → derived tables → this output must reproduce the committed
;; contract byte-exactly, so the drift test witnesses that the
;; derivation is lossless (and that the client's own api/protocol
;; versions still match the contract's) rather than guarding
;; hand-copied tables.  The projection is STATIC: never inferred from
;; golden examples, and there are no live registrations (node support is
;; still negotiated per-connection via `node_types', SPEC-2 §3).  Output
;; is byte-stable — fixed key order, arrays as vectors, UTF-8/LF, one
;; terminal newline — so the drift test can diff a fresh run against the
;; committed file.  Loading this file only defines functions; it writes
;; nothing until `jetpacs-contract-write' runs.

(require 'json)
(require 'seq)

(defvar jetpacs-contract--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repo root, derived from this file's own location.")

(add-to-list 'load-path (expand-file-name "emacs/core" jetpacs-contract--root))
(require 'jetpacs)
(require 'jetpacs-lint)
(require 'jetpacs-source)

(defconst jetpacs-contract-format 5
  "Schema version of `contract.json' itself — bump on a contract-shape change.
Format 2 (Spec 1.0-rc freeze, S1) adds `spec_version', `node_schema',
and `kind_schema'.  Format 3 (the ebp extraction) renames `api_version'
to `reference_api_version': the field describes the elisp reference
implementation's Tier-1 surface, not the wire — informational only, so
the contract repo reads as implementation-neutral.  Format 5 (the
JSON-RPC envelope swap, SPEC-2; 4 was claimed by the deferred v1
error_codes amendment) replaces `kind_schema' with `methods' — each
carrying `direction', `type' (request/notification), `params', and for
requests `result' — and lands `error_codes' (codes + `data.kind'
vocabulary).  Drafted by the slop line; reshape freely (SPEC-2 §8.5).")

(defun jetpacs-contract--spec-version ()
  "The spec version declared in ebp/SPEC-2.md's status block (\"2.0-draft\").
SPEC-2.md is the single source of truth for this number; the ERT test
`jetpacs-spec-header-version-coherent' keeps the header machine-readable."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "ebp/SPEC-2.md" jetpacs-contract--root))
    (goto-char (point-min))
    (unless (re-search-forward
             "^Spec: \\*\\*\\([0-9]+\\.[0-9]+\\(?:-rc\\|-draft\\)?\\)\\*\\*" nil t)
      (error "ebp/SPEC-2.md header carries no parseable Spec: version"))
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

(defun jetpacs-contract--methods ()
  "The JSON-RPC method table as contract objects (format 5).
`direction' is the sender (client = Emacs, companion, or both);
`type' is the SPEC-2 §4 classification (request / notification).
Params of a §9 node tree carry `params: \"node\"' instead of key lists;
a request also carries its `result' schema from
`jetpacs-lint-result-schema'."
  (mapcar
   (lambda (row)
     (let* ((method (nth 0 row))
            (request-p (eq (nth 2 row) 'request))
            (result (and request-p (assoc method jetpacs-lint-result-schema))))
       (cons method
             (append
              (list (cons "direction" (symbol-name (nth 1 row)))
                    (cons "type" (if request-p "request" "notification"))
                    (cons "params"
                          (if (eq (nth 3 row) 'node) "node"
                            (list (cons "required" (jetpacs-contract--names (nth 3 row)))
                                  (cons "optional" (jetpacs-contract--names (nth 4 row)))))))
              (when result
                (list (cons "result"
                            (list (cons "required" (jetpacs-contract--names (nth 1 result)))
                                  (cons "optional" (jetpacs-contract--names (nth 2 result)))))))))))
   jetpacs-lint-kind-schema))

(defun jetpacs-contract--error-codes ()
  "The error-code vocabulary as contract objects (SPEC-2 §2.4)."
  (mapcar (lambda (row)
            (cons (number-to-string (nth 0 row))
                  (list (cons "kind" (nth 1 row))
                        (cons "context" (nth 2 row)))))
          jetpacs-lint-error-codes))

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
                                         (mapcar #'symbol-name (nth 1 entry)))))
                    (cons "optional" (jetpacs-contract--names (nth 2 entry))))))
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
   (cons "methods"          (jetpacs-contract--methods))
   (cons "error_codes"      (jetpacs-contract--error-codes))
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
  "Committed location of `contract.json' (inside the ebp submodule)."
  (expand-file-name "ebp/contract.json" jetpacs-contract--root))

(defun jetpacs-contract-write ()
  "Write the contract to `ebp/contract.json' (UTF-8, LF)."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (jetpacs-contract-string) nil (jetpacs-contract-file)))
  (message "Wrote %s" (jetpacs-contract-file)))

(provide 'build-contract)
;;; build-contract.el ends here
