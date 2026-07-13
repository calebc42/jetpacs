;;; jetpacs-source.el --- named, owned, engine-agnostic data sources -*- lexical-binding: t; -*-

;; A *source* is a named producer of a list of item alists — the data half of
;; a declarative view (`:spec', jetpacs-spec.el).  Core knows no query engine:
;; an app registers a source with a `:query' thunk (the sole funcall, run
;; server-side, never serialized — §5-safe: the name is data, the function is
;; local) plus machine-readable `:params' and `:fields' metadata so an editor
;; can enumerate what a source takes and produces.
;;
;;   (jetpacs-defsource "glasspane.org"
;;     :params '((:name query :type "text" :required t))
;;     :fields '((:name "headline" :type "text") (:name "scheduled" :type "date")
;;               (:name "tags" :type "string-list") (:name "ref" :type "ref"))
;;     :query   (lambda (p) (glasspane-org-query
;;                           (glasspane-org-parse-query (alist-get 'query p))))
;;     :cache-key (lambda (_p) (glasspane-org--agenda-mtime)))
;;
;; Sources are OWNED (via `jetpacs-current-owner') exactly like actions/views,
;; so `jetpacs-app-unregister' tears them down.  They are UNCACHED by default;
;; supplying `:cache-key' memoises one result per (name, canonical-params,
;; freshness-token).  An error is never cached.

;;; Code:

(require 'cl-lib)
(require 'jetpacs-surfaces)             ; jetpacs--claim / --unclaim / --owned-names / current-owner

(defconst jetpacs-source-field-types
  '("text" "number" "boolean" "date" "string-list" "enum" "ref")
  "The closed, domain-neutral field/param types a source declares.
A source normalizes engine-specific data (Org timestamps, TODO keywords,
tags) into these before core sees it; an `enum' requires a `:values' vector.")

(defvar jetpacs--sources (make-hash-table :test 'equal)
  "Registry of source NAME -> plist (:params :fields :query :cache-key :owner).")

(defvar jetpacs--source-cache (make-hash-table :test 'equal)
  "Memo for sources that opt in via `:cache-key'.
Key is (NAME CANONICAL-PARAMS FRESHNESS-TOKEN); absent for uncached sources.")

;; ─── Schema validation ───────────────────────────────────────────────────────

(defun jetpacs-source--check-type (ctx type values)
  "Validate TYPE is a known field type (enum needs VALUES); CTX labels errors."
  (unless (member type jetpacs-source-field-types)
    (error "jetpacs source %s: unknown type %S (want one of %S)"
           ctx type jetpacs-source-field-types))
  (when (and (equal type "enum") (not (vectorp values)))
    (error "jetpacs source %s: enum type requires a :values vector" ctx)))

(defun jetpacs-source--validate-schema (name params fields)
  "Validate the :params and :fields metadata of source NAME."
  (dolist (p params)
    (jetpacs-source--check-type (format "%s param %s" name (plist-get p :name))
                                (plist-get p :type) (plist-get p :values)))
  (dolist (f fields)
    (jetpacs-source--check-type (format "%s field %s" name (plist-get f :name))
                                (plist-get f :type) (plist-get f :values))))

;; ─── Registration ────────────────────────────────────────────────────────────

(cl-defun jetpacs-defsource (name &key params fields query cache-key)
  "Register (or replace) data source NAME (a string).
PARAMS is a list of `(:name SYM :type TYPE :required BOOL [:values VEC])'
descriptors validated and canonicalized before each query.  FIELDS is the
list of `(:name STRING :type TYPE [:values VEC])' a `:spec' template may
bind.  QUERY is `(PARAMS-ALIST) -> (list item-alist...)', app-supplied and
never serialized.  CACHE-KEY, when non-nil, is `(PARAMS-ALIST) -> TOKEN'
enabling one memoised result per params + token.  Returns NAME."
  (jetpacs-source--validate-schema name params fields)
  (jetpacs--claim "source" name)
  (puthash name (list :params params :fields fields :query query
                      :cache-key cache-key :owner jetpacs-current-owner)
           jetpacs--sources)
  (jetpacs-source-invalidate name)      ; a re-registration must not serve stale rows
  name)

(defun jetpacs-source-remove (name)
  "Unregister source NAME, dropping its cache and ownership record."
  (remhash name jetpacs--sources)
  (jetpacs-source-invalidate name)
  (jetpacs--unclaim "source" name))

(defun jetpacs-source-p (name)
  "Non-nil when NAME is a registered source."
  (and (gethash name jetpacs--sources) t))

(defun jetpacs-source-fields (name)
  "The declared output fields of source NAME (a list of field plists)."
  (plist-get (gethash name jetpacs--sources) :fields))

;; ─── Query + cache ───────────────────────────────────────────────────────────

(defun jetpacs-source--canonical-params (src params)
  "Validate PARAMS against SRC's schema; return a canonical (name-sorted) alist.
A missing required param signals an error.  Only declared params survive, so
the cache key is stable regardless of the caller's alist order or extras."
  (let (out)
    (dolist (pspec (plist-get src :params))
      (let* ((pname (plist-get pspec :name))
             (cell (assq pname params)))
        (when (and (plist-get pspec :required) (null cell))
          (error "jetpacs source: missing required param `%s'" pname))
        (when cell (push (cons pname (cdr cell)) out))))
    (sort out (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))))

(defun jetpacs-source-query (name params)
  "Run source NAME with PARAMS (a symbol-keyed alist); return its item list.
Validates and canonicalizes PARAMS first.  Uncached unless the source
declared a `:cache-key', in which case the result is memoised per (name,
canonical-params, freshness-token).  A query that errors is never cached."
  (let* ((src (or (gethash name jetpacs--sources)
                  (error "No such jetpacs source: %s" name)))
         (canon (jetpacs-source--canonical-params src params))
         (ckfn (plist-get src :cache-key)))
    (if (null ckfn)
        (funcall (plist-get src :query) canon)
      (let* ((key (list name canon (funcall ckfn canon)))
             (hit (gethash key jetpacs--source-cache 'jetpacs--miss)))
        (if (not (eq hit 'jetpacs--miss))
            hit
          ;; puthash only after a successful call, so an error is never cached.
          (let ((result (funcall (plist-get src :query) canon)))
            (puthash key result jetpacs--source-cache)
            result))))))

(defun jetpacs-source-invalidate (&optional name)
  "Drop cached results for source NAME (all sources when NAME is nil)."
  (if (null name)
      (clrhash jetpacs--source-cache)
    (let (keys)
      (maphash (lambda (k _v) (when (equal (car k) name) (push k keys)))
               jetpacs--source-cache)
      (dolist (k keys) (remhash k jetpacs--source-cache)))))

;; ─── Enumeration (for editors / the composer) ────────────────────────────────

(defun jetpacs-source--param-json (p)
  "Serializable form of param descriptor P (symbol keys, per the wire convention)."
  (append (list (cons 'name (symbol-name (plist-get p :name)))
                (cons 'type (plist-get p :type))
                (cons 'required (if (plist-get p :required) t :false)))
          (when (plist-get p :values) (list (cons 'values (plist-get p :values))))))

(defun jetpacs-source--field-json (f)
  "Serializable form of field descriptor F (symbol keys)."
  (append (list (cons 'name (format "%s" (plist-get f :name)))
                (cons 'type (plist-get f :type)))
          (when (plist-get f :values) (list (cons 'values (plist-get f :values))))))

(defun jetpacs-source-catalog ()
  "A JSON-serializable inventory of registered sources — metadata only.
Each entry is (name, params, fields); the `:query' function is never
included.  Lets an editor enumerate available sources and their fields."
  (let (out)
    (maphash
     (lambda (name src)
       (push (list (cons 'name name)
                   (cons 'params (vconcat (mapcar #'jetpacs-source--param-json
                                                  (plist-get src :params))))
                   (cons 'fields (vconcat (mapcar #'jetpacs-source--field-json
                                                  (plist-get src :fields)))))
             out))
     jetpacs--sources)
    (nreverse out)))

(provide 'jetpacs-source)
;;; jetpacs-source.el ends here
