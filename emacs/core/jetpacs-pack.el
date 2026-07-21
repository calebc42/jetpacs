;;; jetpacs-pack.el --- engine-pack manifest assembly -*- lexical-binding: t; -*-

;; A Tier-1 app ships as a jetpacs *engine pack*: a bundle of elisp plus
;; a machine-readable manifest that tells the no-code composer what it
;; can bind without reading any elisp — the data SOURCES the app
;; registers, the composer-facing ACTIONS its cards expose, the layouts
;; available, and (the SDUI dependency model) the Emacs packages the
;; engine relies on so the composer can install them.
;;
;; This module is the generic assembly seam.  The manifest is built from
;; LIVE registrations (`jetpacs-source-catalog', `jetpacs-action-catalog'),
;; so it can never drift from what the app actually registers; the app
;; supplies only its identity (id, version, min api, depends) and its
;; owner for the action filter.  Sources and actions are name-sorted so
;; the generated JSON is byte-stable.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'jetpacs-source)               ; jetpacs-source-catalog
(require 'jetpacs-surfaces)             ; jetpacs-action-catalog
(require 'jetpacs-lint)                 ; jetpacs-lint-spec-layouts

(defun jetpacs-pack--sort-by (key entries)
  "ENTRIES (a list of alists) sorted by their KEY value, for a stable manifest.
`jetpacs-source-catalog'/`jetpacs-action-catalog' iterate a hash table, so a
deterministic snapshot must impose an order."
  (sort (copy-sequence entries)
        (lambda (a b) (string< (format "%s" (alist-get key a))
                               (format "%s" (alist-get key b))))))

(cl-defun jetpacs-pack-manifest (&key id version min-api depends owner
                                      (feature id))
  "An engine-pack manifest built from live registrations.
ID names the pack (and defaults FEATURE, the elisp feature the composer
loads); VERSION is the pack's own version; MIN-API the minimum jetpacs
api it requires; DEPENDS a list of ((name . N) (min_version . V)) alists
for the composer to install.  OWNER filters `jetpacs-action-catalog' —
an app that wraps its registrations in `with-jetpacs-owner' gets an
exact catalog regardless of what else the build environment loaded.
Returns a JSON-serializable alist; sources and actions are name-sorted
so the generated JSON is byte-stable."
  (list (cons 'pack_id         id)
        (cons 'pack_version    version)
        (cons 'min_jetpacs_api min-api)
        (cons 'feature         feature)
        (cons 'depends         (vconcat depends))
        (cons 'layouts         (vconcat jetpacs-lint-spec-layouts))
        (cons 'sources         (vconcat (jetpacs-pack--sort-by
                                         'name (jetpacs-source-catalog))))
        (cons 'actions         (vconcat (jetpacs-pack--sort-by
                                         'action (jetpacs-action-catalog owner))))))

(defun jetpacs-pack-json (manifest)
  "MANIFEST as pretty-printed, newline-terminated JSON text."
  (with-temp-buffer
    (insert (json-serialize manifest :null-object :null :false-object :false))
    (json-pretty-print-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (buffer-string)))

(defun jetpacs-pack-write (manifest file)
  "Write MANIFEST's JSON to FILE.  Returns FILE."
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file file (insert (jetpacs-pack-json manifest))))
  file)

(provide 'jetpacs-pack)
;;; jetpacs-pack.el ends here
