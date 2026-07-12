;;; jetpacs-config.el --- The foundation-owned root and per-app config subtrees -*- lexical-binding: t; -*-

;; Jetpacs owns a namespaced directory tree under the user's Emacs home
;; (`jetpacs-root', i.e. ~/.emacs.d/jetpacs/) rather than colonizing
;; ~/.emacs.d itself.  The user's init.el keeps a single seam line (see
;; docs/starter-init.el) that loads the managed entry point; everything
;; the foundation and its apps write lives under `jetpacs-root'.  The
;; user's own files (init.el, custom.el) stay at the `user-emacs-directory'
;; root, OUTSIDE this tree, so a sync pass can never clobber them.
;;
;; Two ownership tiers, mirrored in this file's verbs:
;;
;;   - SYNC (overwrite): `jetpacs-app-config-sync' rewrites every managed
;;     file to the current bundle defaults, so an app update can evolve
;;     them; edits to those files are expected to be lost.  DO-NOT-EDIT
;;     banners mark them.
;;   - CREATE-ONCE: `jetpacs-app-config-ensure' populates a subtree on the
;;     first run and only loads it thereafter, so user edits survive.
;;
;; The MUST-own-vs-overridable axis is ORTHOGONAL to these file tiers and
;; is carried in Lisp, not on disk: an invariant is a defun / registry
;; mutation / hook (a stray `setq' can't reach it); a default is a
;; `defcustom' the user is meant to override.  See
;; `jetpacs--install-invariants' in jetpacs-apps.el.
;;
;; This module is the generalization of Glasspane's `glasspane-config.el':
;; the same sync/ensure/load contract, promoted into the core and keyed by
;; app-id so any app reuses it (an app becomes a thin caller passing its id
;; and its (FILENAME . CONTENT) file set).

;;; Code:

(require 'jetpacs)

(defconst jetpacs-root
  (expand-file-name "jetpacs/" user-emacs-directory)
  "The foundation-owned directory tree, replacing the mis-named `elisp/'.
Everything Jetpacs and its apps write lives here.  The user's own files
\(init.el, custom.el) stay at the `user-emacs-directory' root, OUTSIDE this
tree, so a sync pass can never clobber them.  Treat this directory as the
foundation's, not the user's.")

(defconst jetpacs-lib-dir
  (expand-file-name "lib/" jetpacs-root)
  "Where adopted single-file bundles live (core + each app), one `require'
each.  SYNC tier: the newest staged copy is adopted over the installed one.
Kept flat and monolithic on purpose — on-device loading is one `require'
per bundle, never a multi-file module graph.")

(defun jetpacs-app-dir (id)
  "Return the config-subtree directory for app ID under `jetpacs-root'.
Keyed by the same app-id as views (\"ID.*\") and UI-state (\"ID.\"), so an
app's on-disk config, in-memory registrations and namespaced state all
share one key.  The directory is not created here — the config verbs do
that when the app opts in."
  (file-name-as-directory
   (expand-file-name id (expand-file-name "apps/" jetpacs-root))))

(defun jetpacs-app-config-load (id)
  "Load every elisp file in app ID's config subtree, in name order.
A missing subtree is fine — nothing loads until the app opts in via
`jetpacs-app-config-ensure' or `jetpacs-app-config-sync'.  Files load in
name order (so extra user files sort predictably among managed ones); an
error in one file is reported and skipped, never fatal."
  (let ((dir (jetpacs-app-dir id)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (condition-case err
            (load file nil 'nomessage)
          (error (message "jetpacs-config: error loading %s: %s"
                          file (error-message-string err))))))))

(defun jetpacs-app-config-sync (id files)
  "Write FILES into app ID's config subtree and load them.
FILES is an alist of (FILENAME . CONTENT).  Every file is overwritten —
the reset-to-current-bundle semantics are the point, so an app update can
evolve its defaults.  Returns the subtree directory."
  (let ((dir (jetpacs-app-dir id))
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (dolist (spec files)
      (write-region (cdr spec) nil (expand-file-name (car spec) dir)
                    nil 'silent))
    (jetpacs-app-config-load id)
    dir))

(defun jetpacs-app-config-ensure (id files)
  "Create app ID's config subtree from FILES on first run; load it after.
A missing subtree is populated via `jetpacs-app-config-sync'; an existing
one is only loaded, never rewritten — so a user's edits to the seeded files
survive an app that merely re-runs this at load time.  An app forces the
overwrite/upgrade path explicitly with `jetpacs-app-config-sync' (e.g.
behind an allowlisted `config.sync' action)."
  (if (file-directory-p (jetpacs-app-dir id))
      (jetpacs-app-config-load id)
    (jetpacs-app-config-sync id files)))

;; ─── Bundle adoption + the managed entry-point bootstrap ─────────────────────
;;
;; jetpacs-init.el (the on-disk entry file the user's one seam line loads) is
;; deliberately thin: it only needs to get lib/jetpacs-core.el in place and
;; `(require 'jetpacs-core)'.  Everything after that lives HERE, in versioned
;; core, so it is testable and evolves with the bundle rather than with a file
;; the user has to re-paste.

(defconst jetpacs-staging-dirs '("/sdcard/Documents/" "/sdcard/Download/")
  "Shared-storage directories bundles are staged into before adoption.
The companion (a separate UID) can only write here, not the Emacs sandbox;
Emacs pulls the newest staged copy into `jetpacs-lib-dir'.")

(defvar jetpacs-installed-bundles nil
  "App bundle file names to adopt and require at startup.
Set by the create-once ~/.emacs.d/jetpacs/apps.el, which the user edits to
install an app.  The core bundle is always loaded and is never listed here.")

(defun jetpacs-config-adopt (bundle)
  "Copy the newest staged BUNDLE into `jetpacs-lib-dir'; return its feature.
Newest-wins across `jetpacs-staging-dirs' (browser downloads and companion/
deploy staging both land there).  A `.el' name maps to its feature symbol."
  (let ((installed (expand-file-name bundle jetpacs-lib-dir)))
    (make-directory jetpacs-lib-dir t)
    (dolist (dir jetpacs-staging-dirs)
      (let ((s (concat dir bundle)))
        (when (and (file-readable-p s)
                   (or (not (file-exists-p installed))
                       (file-newer-than-file-p s installed)))
          (copy-file s installed t)
          (message "jetpacs: adopted %s from %s" bundle dir))))
    (intern (file-name-base bundle))))

(defun jetpacs-config-seed-file (path content)
  "Create PATH with CONTENT once, making parent dirs; never overwrite.
The create-once tier: `apps.el' and `user.el' are seeded this way so user
edits to them survive every subsequent startup and sync."
  (unless (file-exists-p path)
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8))
      (write-region content nil path nil 'silent))))

(defconst jetpacs-config--user-template
  ";;; user.el --- Your Jetpacs overrides -*- lexical-binding: t; -*-
;; CREATE-ONCE: Jetpacs wrote this once and never touches it again.
;; It loads AFTER Jetpacs's defaults and your saved Settings, so anything
;; here wins.  Put personal tweaks (keybindings, theme, variables) below.

"
  "Seed contents for a fresh ~/.emacs.d/jetpacs/user.el.")

(defconst jetpacs-config--apps-template
  ";;; apps.el --- Jetpacs installed app bundles -*- lexical-binding: t; -*-
;; CREATE-ONCE, yours to edit.  List the app bundle files you download into
;; /sdcard/Download (or Documents); each is adopted into ~/.emacs.d/jetpacs/lib/
;; and required at startup.  The core bundle is always loaded and is NOT listed.

(setq jetpacs-installed-bundles '())   ; e.g. '(\"glasspane.el\")
"
  "Seed contents for a fresh ~/.emacs.d/jetpacs/apps.el.")

(defconst jetpacs-config--apps-migrated-template
  ";;; apps.el --- Jetpacs installed app bundles -*- lexical-binding: t; -*-
;; CREATE-ONCE, yours to edit.  Migrated from your previous init.el bundle list.

(setq jetpacs-installed-bundles '(%s))
"
  "Seed for apps.el after a legacy migration; %s is the discovered bundle list.")

(defun jetpacs-config-migrate-legacy ()
  "Non-destructively move the old ~/.emacs.d/elisp/ layout under `jetpacs-root'.
Copies bundle `.el' files into `jetpacs-lib-dir', each elisp/<app>/ config
subtree into `(jetpacs-app-dir <app>)', and seeds apps.el from the discovered
app bundles so they still load.  Leaves the old elisp/ and custom.el untouched.
Runs at most once: guarded on apps.el not yet existing."
  (let ((old (expand-file-name "elisp/" user-emacs-directory)))
    (when (and (file-directory-p old)
               (not (file-exists-p (expand-file-name "apps.el" jetpacs-root))))
      (make-directory jetpacs-lib-dir t)
      (let (bundles)
        (dolist (f (directory-files old t "\\.el\\'"))
          (let ((name (file-name-nondirectory f)))
            (copy-file f (expand-file-name name jetpacs-lib-dir) t)
            (unless (equal name "jetpacs-core.el")
              (push name bundles))))
        (dolist (d (directory-files old t "\\`[^.]"))
          (when (file-directory-p d)
            (let ((dest (jetpacs-app-dir (file-name-nondirectory d))))
              (unless (file-directory-p dest)
                (copy-directory d dest nil t t)))))
        (jetpacs-config-seed-file
         (expand-file-name "apps.el" jetpacs-root)
         (format jetpacs-config--apps-migrated-template
                 (mapconcat (lambda (b) (format "%S" b))
                            (nreverse bundles) " ")))
        (message "jetpacs: migrated %s into %s"
                 (abbreviate-file-name old) (abbreviate-file-name jetpacs-root))))))

(defun jetpacs-apply-foundation-defaults ()
  "Apply Jetpacs's phone-ergonomics and file-hygiene defaults.
Called by the managed entry point BEFORE `custom-file' and the user's
`user.el' load, so every setting here is overridable — these are DEFAULTS
\(plain setters), not invariants.  Touch/scroll basics, backups and auto-saves
in one place, no lock files (single-user device), auto-revert, and volume keys
paging the buffer on Android."
  (when (fboundp 'pixel-scroll-precision-mode)
    (pixel-scroll-precision-mode 1))
  (setq touch-screen-precision-scroll t
        touch-screen-word-select t
        touch-screen-extend-selection t
        touch-screen-display-keyboard t)
  (when (fboundp 'context-menu-mode) (context-menu-mode 1))
  (setq use-dialog-box t
        use-short-answers t
        inhibit-startup-screen t)
  (when (eq system-type 'android)
    (setq android-pass-multimedia-buttons-to-system nil)
    (global-set-key (kbd "<volume-up>")   #'scroll-down-command)
    (global-set-key (kbd "<volume-down>") #'scroll-up-command))
  (setq backup-directory-alist
        `(("." . ,(expand-file-name "backups/" user-emacs-directory)))
        backup-by-copying t
        create-lockfiles nil)
  (let ((auto-save-dir (expand-file-name "auto-save/" user-emacs-directory)))
    (make-directory auto-save-dir t)
    (setq auto-save-file-name-transforms `((".*" ,auto-save-dir t))))
  (global-auto-revert-mode 1)
  (setq global-auto-revert-non-file-buffers t
        auto-revert-verbose nil)
  (save-place-mode 1)
  (savehist-mode 1)
  (recentf-mode 1))

(defun jetpacs-config-bootstrap ()
  "Wire up the managed root after core has loaded.
Called by jetpacs-init.el once `jetpacs-core' is required: migrate any legacy
layout, load the create-once installed-app list and adopt+require each app,
apply the foundation defaults, then load `custom-file' and the user override.
Invariants are re-asserted separately at connect (`jetpacs-before-connect-hook')."
  (add-to-list 'load-path jetpacs-lib-dir)
  (jetpacs-config-migrate-legacy)
  ;; Installed apps: a create-once, user-owned list.
  (let ((apps (expand-file-name "apps.el" jetpacs-root)))
    (jetpacs-config-seed-file apps jetpacs-config--apps-template)
    (load apps t))
  (dolist (bundle jetpacs-installed-bundles)
    (condition-case err
        (require (jetpacs-config-adopt bundle))
      (error (display-warning
              'jetpacs
              (format "app bundle %s failed to load: %S" bundle err)
              :error))))
  ;; Foundation defaults (overridable) — before custom/user so those win.
  (jetpacs-apply-foundation-defaults)
  ;; custom-file: user data, pinned OUTSIDE the jetpacs/ sync tree.
  (unless custom-file
    (setq custom-file (expand-file-name "custom.el" user-emacs-directory)))
  (when (and custom-file (file-exists-p custom-file))
    (load custom-file nil 'nomessage))
  ;; User override escape hatch — loaded LAST so the user beats every default.
  (let ((user (expand-file-name "user.el" jetpacs-root)))
    (jetpacs-config-seed-file user jetpacs-config--user-template)
    (load user t)))

(provide 'jetpacs-config)
;;; jetpacs-config.el ends here
