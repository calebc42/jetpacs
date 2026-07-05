;;; glasspane-config.el --- App-managed org defaults on disk -*- lexical-binding: t; -*-

;; Glasspane's opinionated defaults — capture templates, agenda wiring,
;; babel languages — live as small elisp files in
;; `glasspane-config-directory', written and refreshed by the app rather
;; than hand-maintained in init.el.  The contract:
;;
;;   - `glasspane-config-sync' (or the allowlisted `config.sync' action)
;;     rewrites every managed file to the bundle's current defaults, so
;;     an app update can evolve them; edits to the files themselves are
;;     expected to be lost.
;;   - Personal configuration belongs in init.el (which runs after the
;;     `require'-time load below, so it wins) or in Customize.
;;   - The defaults are deliberately soft: capture templates merge by
;;     key and never replace one the user already defined; variables are
;;     seeded only while still at their stock values.
;;
;; The starter init (docs/starter-init.el) calls
;; `glasspane-config-ensure': first run creates and loads the
;; directory, later runs just load it.  An existing init opts in the
;; same way — nothing is written until asked.

;;; Code:

(require 'eabp-surfaces)

(defcustom glasspane-config-directory
  (expand-file-name "elisp/glasspane/" user-emacs-directory)
  "Directory holding Glasspane's app-managed configuration files.
Files here are rewritten wholesale by `glasspane-config-sync' — treat
the directory as the app's, not yours."
  :type 'directory :group 'eabp)

(defconst glasspane-config-version 1
  "Version of the managed defaults; stamped into every written file.")

(defconst glasspane-config--files
  '(("capture-templates.el" . "\
;;; capture-templates.el --- Glasspane-managed capture templates
;; APP-MANAGED (glasspane-config v1): rewritten by `glasspane-config-sync'.
;; Don't edit here — define your own templates in init.el; these merge
;; by key and never replace one you already have.

(require 'org-capture)

(defvar glasspane-config-capture-templates
  '((\"t\" \"Todo\" entry (file+headline org-default-notes-file \"Tasks\")
     \"* TODO %?\\n%U\\n%i\" :empty-lines 1)
    (\"n\" \"Note\" entry (file+headline org-default-notes-file \"Notes\")
     \"* %? :note:\\n%U\\n%i\" :empty-lines 1)
    (\"l\" \"Link\" entry (file+headline org-default-notes-file \"Links\")
     \"* %?\\n%U\\n%a\" :empty-lines 1))
  \"Glasspane's default capture templates (phone capture reads these).\")

(dolist (tpl glasspane-config-capture-templates)
  (unless (assoc (car tpl) org-capture-templates)
    (setq org-capture-templates
          (append org-capture-templates (list tpl)))))
")
    ("org-defaults.el" . "\
;;; org-defaults.el --- Glasspane-managed org wiring
;; APP-MANAGED (glasspane-config v1): rewritten by `glasspane-config-sync'.
;; Personal settings belong in init.el or Customize — they win because
;; init.el runs after this file loads.

(require 'org)

;; Capture lands in the inbox inside `org-directory' (only seeded while
;; still at org's stock ~/.notes default).
(when (equal org-default-notes-file
             (convert-standard-filename \"~/.notes\"))
  (setq org-default-notes-file
        (expand-file-name \"inbox.org\" org-directory)))
(make-directory org-directory t)

;; The phone's agenda tab needs agenda files; default to the whole
;; org directory when nothing is configured yet.
(unless org-agenda-files
  (setq org-agenda-files (list org-directory)))

;; State changes and clocks go into LOGBOOK drawers — the heading
;; detail view shows them as a structured section.
(setq org-log-into-drawer t)

;; Languages the demo corpus executes from the phone; the run button
;; only appears for languages loaded here.
(org-babel-do-load-languages
 'org-babel-load-languages
 '((emacs-lisp . t) (shell . t)))
"))
  "Alist of (FILENAME . CONTENT) written by `glasspane-config-sync'.")

;;;###autoload
(defun glasspane-config-sync (&optional dir)
  "Write the app-managed defaults into DIR and load them.
DIR defaults to `glasspane-config-directory'.  Every file in
`glasspane-config--files' is overwritten — the reset-to-current-bundle
semantics are the point.  Returns DIR."
  (interactive)
  (let ((dir (file-name-as-directory
              (expand-file-name (or dir glasspane-config-directory))))
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (dolist (spec glasspane-config--files)
      (write-region (cdr spec) nil (expand-file-name (car spec) dir)
                    nil 'silent))
    (glasspane-config-load dir)
    (when (called-interactively-p 'interactive)
      (message "Glasspane defaults written to %s" dir))
    dir))

(defun glasspane-config-load (&optional dir)
  "Load every elisp file in DIR (default `glasspane-config-directory').
A missing directory is fine — nothing loads until the user opts in via
`glasspane-config-ensure' or `glasspane-config-sync'.  Files load in
name order, so extra user files sort predictably among the managed
ones."
  (let ((dir (expand-file-name (or dir glasspane-config-directory))))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (condition-case err
            (load file nil 'nomessage)
          (error (message "glasspane-config: error loading %s: %s"
                          file (error-message-string err))))))))

;;;###autoload
(defun glasspane-config-ensure ()
  "Create the app-managed defaults on first run; load them afterwards.
The starter init calls this right after (require \\='glasspane): a
missing `glasspane-config-directory' is populated via
`glasspane-config-sync'; an existing one is only loaded, never
rewritten."
  (if (file-directory-p glasspane-config-directory)
      (glasspane-config-load)
    (glasspane-config-sync)))

(eabp-defaction "config.sync"
  ;; Allowlisted and argument-free: rewrites the fixed file set into
  ;; `glasspane-config-directory' — nothing on the wire chooses paths
  ;; or content.
  (lambda (_ _)
    (let ((dir (glasspane-config-sync)))
      (when (fboundp 'eabp-shell-notify)
        (eabp-shell-notify
         (format "App defaults refreshed in %s"
                 (abbreviate-file-name dir)))))
    (when (fboundp 'eabp-shell-push)
      (eabp-shell-push))))

(provide 'glasspane-config)
;;; glasspane-config.el ends here
