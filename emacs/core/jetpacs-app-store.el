;;; jetpacs-app-store.el --- Manage Apps: install/uninstall staged bundles -*- lexical-binding: t; -*-

;; The on-phone half of app distribution (PLAN-automation-and-launcher
;; Task 18, modernized onto the foundation flow): a "Manage apps" screen
;; listing every app bundle staged under `jetpacs-staging-dirs' —
;; recursively, one row per file name, newest copy wins — with an
;; install or uninstall affordance according to membership in
;; `jetpacs-installed-bundles' (the create-once apps.el list).
;;
;; Install is LIVE: rewrite apps.el, then adopt + byte-compile + require
;; through `jetpacs-config-install-bundle' — the exact seam boot uses —
;; and the app appears in the launcher with no restart.  Uninstall
;; rewrites apps.el and tears down what it can: the owner ids recorded
;; at install time go through `jetpacs-app-unregister'; elisp cannot
;; truly unload, so the screen says "fully gone after a restart" when
;; that's the honest answer.
;;
;; Trust: installing IS running code.  The first tap opens a consent
;; dialog that says so plainly, and the wire only ever carries a bundle
;; FILE NAME, validated against a fresh scan of the staging tree —
;; never a path, and never the foundation's own files (jetpacs-core.el
;; and jetpacs-init.el are not apps and never appear).

;;; Code:

(require 'seq)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-config)
(require 'jetpacs-apps)

(defconst jetpacs-app-store--foundation-files
  '("jetpacs-core.el" "jetpacs-init.el")
  "The foundation's own staged files: not apps, never listed.")

;; ─── The scan ────────────────────────────────────────────────────────────────

(defun jetpacs-app-store--summary (path)
  "The bundle's own one-line description, from its first header line.
\";;; name.el --- SUMMARY -*- ...\" is the convention every bundle
follows; a file without it just gets no caption."
  (with-temp-buffer
    (insert-file-contents path nil 0 300)
    (goto-char (point-min))
    (when (looking-at ";;;[^\n]*?--- *\\(.*?\\) *\\(?:-\\*-.*\\)?$")
      (match-string 1))))

(defun jetpacs-app-store--scan ()
  "Staged app bundles, sorted by name: one plist per distinct file name.
Recursive under each staging dir (Jetpacs's own dedicated subtree, so
the walk is bounded); duplicates resolve newest-wins, mirroring
`jetpacs-config-adopt' so the row shown is the copy that would install."
  (let ((best (make-hash-table :test 'equal)))
    (dolist (dir jetpacs-staging-dirs)
      (when (file-directory-p dir)
        (dolist (path (directory-files-recursively dir "\\.el\\'"))
          (let ((name (file-name-nondirectory path)))
            (unless (member name jetpacs-app-store--foundation-files)
              (let ((prev (gethash name best)))
                (when (or (null prev) (file-newer-than-file-p path prev))
                  (puthash name path best))))))))
    (let (entries)
      (maphash
       (lambda (name path)
         (let ((attrs (file-attributes path)))
           (push (list :name name :path path
                       :installed (and (member name jetpacs-installed-bundles) t)
                       :summary (ignore-errors (jetpacs-app-store--summary path))
                       :size (file-attribute-size attrs)
                       :mtime (file-attribute-modification-time attrs))
                 entries)))
       best)
      (sort entries (lambda (a b) (string< (plist-get a :name)
                                           (plist-get b :name)))))))

(defun jetpacs-app-store--entry (name)
  "The fresh-scan entry for bundle NAME, or nil.
The validation gate every wire action passes through: an action names a
bundle, this resolves it against what is actually staged right now."
  (and (stringp name)
       (seq-find (lambda (e) (equal (plist-get e :name) name))
                 (jetpacs-app-store--scan))))

;; ─── apps.el, rewritten canonically ──────────────────────────────────────────

(defconst jetpacs-app-store--apps-template
  ";;; apps.el --- Jetpacs installed app bundles -*- lexical-binding: t; -*-
;; Yours to edit — but the phone's Manage Apps screen also writes it,
;; and each install/uninstall from there rewrites this whole file from
;; the list below (hand comments do not survive that).

(setq jetpacs-installed-bundles '(%s))
"
  "Body written by the Manage Apps screen; %s is the bundle list.")

(defun jetpacs-app-store--write-apps ()
  "Persist the current `jetpacs-installed-bundles' into apps.el."
  (let ((coding-system-for-write 'utf-8))
    (write-region (format jetpacs-app-store--apps-template
                          (mapconcat (lambda (b) (format "%S" b))
                                     jetpacs-installed-bundles " "))
                  nil (expand-file-name "apps.el" jetpacs-root) nil 'silent)))

;; ─── The view ────────────────────────────────────────────────────────────────

(defun jetpacs-app-store--row (entry)
  (let* ((name (plist-get entry :name))
         (installed (plist-get entry :installed)))
    (jetpacs-card
     (list
      (jetpacs-row
       (jetpacs-box
        (list (jetpacs-column
               (jetpacs-text (file-name-base name) 'label)
               (when (plist-get entry :summary)
                 (jetpacs-text (plist-get entry :summary) 'body))
               (jetpacs-text
                (format "%s · %s%s"
                        (file-size-human-readable (plist-get entry :size))
                        (format-time-string "%Y-%m-%d %H:%M"
                                            (plist-get entry :mtime))
                        (if installed "  ·  installed" ""))
                'caption)))
        :weight 1)
       (if installed
           (jetpacs-icon-button "delete"
                                (jetpacs-action "app.uninstall"
                                                :args `((bundle . ,name))
                                                :when-offline "drop")
                                :content-description (format "Uninstall %s" name))
         (jetpacs-icon-button "download"
                              (jetpacs-action "app.install"
                                              :args `((bundle . ,name))
                                              :when-offline "drop")
                              :content-description (format "Install %s" name))))))))

(defun jetpacs-app-store--body ()
  (let ((entries (jetpacs-app-store--scan)))
    (if (null entries)
        (jetpacs-lazy-column
         (jetpacs-empty-state
          :icon "extension"
          :title "No staged bundles"
          :caption (format "Drop app bundles (*.el) anywhere under %s and they appear here."
                           (car jetpacs-staging-dirs))))
      (apply #'jetpacs-lazy-column
             (append
              (list (jetpacs-text
                     "Installing runs the bundle's Emacs Lisp now and on every start."
                     'caption))
              (mapcar #'jetpacs-app-store--row entries))))))

(defun jetpacs-app-store--view (snackbar)
  (jetpacs-shell-nav-view "Manage Apps" (jetpacs-app-store--body)
                          :snackbar snackbar))

(jetpacs-shell-define-view "app-store" :builder #'jetpacs-app-store--view
                           :order 95)

;; Everyday-adjacent nav: rides the drawer right under the Apps entry.
;; Never a dead entry — the view always renders (empty state included).
(jetpacs-shell-add-drawer-item
 6 (lambda ()
     (jetpacs-drawer-item "extension" "Manage apps"
                          (jetpacs-shell-switch-view "app-store"))))

;; ─── Wire actions ────────────────────────────────────────────────────────────

(jetpacs-defaction "app.install"
  ;; Step 1: consent.  Nothing installs from this action — it only shows
  ;; the dialog naming what would run.
  (lambda (args _)
    (let ((entry (jetpacs-app-store--entry (alist-get 'bundle args))))
      (if (null entry)
          (progn (jetpacs-shell-notify "That bundle is no longer staged")
                 (jetpacs-shell-push))
        (let ((name (plist-get entry :name)))
          (jetpacs-send-dialog
           (jetpacs-column
            (jetpacs-text (format "Install %s?" (file-name-base name)) 'title)
            (when (plist-get entry :summary)
              (jetpacs-text (plist-get entry :summary) 'body))
            (jetpacs-text
             "This is Emacs Lisp: once installed it runs with full access to your Emacs and files, now and on every start."
             'caption)
            (jetpacs-text
             (format "%s · %s · %s"
                     name
                     (file-size-human-readable (plist-get entry :size))
                     (format-time-string "%Y-%m-%d %H:%M"
                                         (plist-get entry :mtime)))
             'caption)
            (jetpacs-row
             (jetpacs-spacer :weight 1)
             (jetpacs-button "Cancel" (jetpacs-action "dialog.dismiss")
                             :variant "text")
             (jetpacs-spacer :width 8)
             (jetpacs-button "Install"
                             (jetpacs-action "app.install.confirm"
                                             :args `((bundle . ,name))
                                             :when-offline "drop"))))))))))

(jetpacs-defaction "app.install.confirm"
  ;; Step 2: apps.el first (the durable record), then the live install
  ;; through the boot seam.  A bundle that fails to load is rolled back
  ;; out of apps.el — a broken install must not brick the next boot.
  (lambda (args _)
    (jetpacs-dismiss-dialog)
    (let ((entry (jetpacs-app-store--entry (alist-get 'bundle args))))
      (cond
       ((null entry)
        (jetpacs-shell-notify "That bundle is no longer staged")
        (jetpacs-shell-push))
       ((plist-get entry :installed)
        (jetpacs-shell-notify "Already installed")
        (jetpacs-shell-push))
       (t
        (let ((name (plist-get entry :name)))
          (jetpacs-send "toast.show"
                        `((text . ,(format "Installing %s… (byte-compiles; takes a moment)"
                                           (file-name-base name)))))
          (setq jetpacs-installed-bundles
                (append jetpacs-installed-bundles (list name)))
          (jetpacs-app-store--write-apps)
          (condition-case err
              (progn
                (jetpacs-config-install-bundle name)
                (jetpacs-shell-notify (format "%s installed" (file-name-base name))))
            (error
             (setq jetpacs-installed-bundles
                   (delete name jetpacs-installed-bundles))
             (jetpacs-app-store--write-apps)
             (jetpacs-shell-notify
              (format "%s failed to load — not installed (%s)"
                      (file-name-base name) (error-message-string err)))))
          (jetpacs-shell-push)))))))

(jetpacs-defaction "app.uninstall"
  (lambda (args _)
    (let ((entry (jetpacs-app-store--entry (alist-get 'bundle args))))
      (if (or (null entry) (not (plist-get entry :installed)))
          (progn (jetpacs-shell-notify "Not installed")
                 (jetpacs-shell-push))
        (let ((name (plist-get entry :name)))
          (jetpacs-send-dialog
           (jetpacs-column
            (jetpacs-text (format "Uninstall %s?" (file-name-base name)) 'title)
            (jetpacs-text
             "Removes it from the installed list. Code already loaded this session is torn down where possible; it is fully gone after a restart. The staged file stays for reinstalling."
             'caption)
            (jetpacs-row
             (jetpacs-spacer :weight 1)
             (jetpacs-button "Cancel" (jetpacs-action "dialog.dismiss")
                             :variant "text")
             (jetpacs-spacer :width 8)
             (jetpacs-button "Uninstall"
                             (jetpacs-action "app.uninstall.confirm"
                                             :args `((bundle . ,name))
                                             :when-offline "drop"))))))))))

(jetpacs-defaction "app.uninstall.confirm"
  (lambda (args _)
    (jetpacs-dismiss-dialog)
    (let ((name (alist-get 'bundle args)))
      (if (not (and (stringp name) (member name jetpacs-installed-bundles)))
          (progn (jetpacs-shell-notify "Not installed")
                 (jetpacs-shell-push))
        (setq jetpacs-installed-bundles (delete name jetpacs-installed-bundles))
        (jetpacs-app-store--write-apps)
        ;; Live teardown reaches only what the ownership registry saw
        ;; this session; the durable half is apps.el, already written.
        (let ((owners (alist-get name jetpacs-config--bundle-owners
                                 nil nil #'equal)))
          (dolist (owner owners) (ignore-errors (jetpacs-app-unregister owner)))
          (setf (alist-get name jetpacs-config--bundle-owners nil t #'equal) nil)
          (jetpacs-shell-notify
           (if owners
               (format "%s uninstalled" (file-name-base name))
             (format "%s removed — fully gone after a restart"
                     (file-name-base name)))))
        (jetpacs-shell-push)))))

(provide 'jetpacs-app-store)
;;; jetpacs-app-store.el ends here
