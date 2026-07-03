;;; eabp-files.el --- File browser & editor for EABP -*- lexical-binding: t; -*-

;; A dired-style file browser plus a plain-text editor, rendered through
;; EABP surfaces. Together with the eval tab this is the self-hosting
;; plumbing: init.el (and anything else) can be edited, saved, and
;; reloaded from the phone, so the desktop side never needs touching
;; once eabp is in the init file.
;;
;; Views contributed to the dashboard (wired in eabp-org-ui):
;;   "files" — root list / directory listing
;;   "edit"  — editor for `eabp-files--file' (present while a file is open)

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer) ; Tier 0 renderer + the major-mode→skin registry
(require 'eabp-complete) ; capf bridge: the editor's `complete' flag
(require 'eabp-org)   ; for eabp-org--inhibit-save-refresh / cache invalidation
(require 'eabp-org-reader)
(require 'dired)
(require 'cl-lib)

(defcustom eabp-files-roots
  `(("Config" . ,user-emacs-directory)
    ("Org"    . ,(or (and (boundp 'org-directory) org-directory) "~/org/"))
    ("Home"   . "~/"))
  "Root directories the Files browser is confined to.
Navigation, opening, and file operations are all refused outside these
roots (`eabp-files--within-root-p').  Labels are unused now that the Files
view lands directly in `eabp-files-default-dir' rather than on a roots list,
but the alist shape is kept for back-compatibility."
  :type '(alist :key-type string :value-type directory)
  :group 'eabp)

(defcustom eabp-files-default-dir "~/"
  "Directory the Files tab opens to (and the navigation ceiling).
Must lie within `eabp-files-roots'.  The Files view shows this directory's
full listing — the same view you get from the Buffers tab on its dired
buffer — instead of a separate shortcut screen."
  :type 'directory :group 'eabp)

(defcustom eabp-files-max-bytes (* 256 1024)
  "Files larger than this open read-only.
Editor saves travel inside a broadcast intent on the companion side,
which has a hard payload ceiling (~500 KB across all extras), so big
files must not round-trip through the editor."
  :type 'integer :group 'eabp)

(defvar eabp-files--dir nil
  "Directory being browsed, or nil for the landing dir (`eabp-files-default-dir').")

(defvar eabp-files--file nil
  "Absolute path of the file open in the editor, or nil.")

(defvar eabp-files--read-mode nil
  "When non-nil, org files open in the foldable reader instead of the editor.")

(defvar eabp-files--refile-mode nil
  "When non-nil, org reader shows a flat drag-to-reorder heading list.")

;; ─── Browser view (dired under the hood) ─────────────────────────────────────

;; The directory listing is backed by a real dired buffer — the standard Emacs
;; file engine — but presented through a Tier-1 card skin registered for
;; `dired-mode'.  So the same buffer renders as touch cards here and as a raw,
;; faithful listing from the Buffers tab: Tier 0 and Tier 1 over one model.
;; The Files tab lands directly in `eabp-files-default-dir' (no separate roots
;; screen) so it matches the full listing you get from the Buffers tab.

(defun eabp-files--within-root-p (path)
  "Non-nil when PATH is inside (or is) one of `eabp-files-roots'.
Uses `file-in-directory-p', which compares path components — a bare
string-prefix check would let root \"~/org\" authorize \"~/org-secrets\",
and this predicate is the security boundary for every file operation
the phone can trigger."
  (let ((full (expand-file-name path)))
    (cl-some (lambda (root)
               (file-in-directory-p full (expand-file-name (cdr root))))
             eabp-files-roots)))

(defun eabp-files--entry-menu (path)
  "Overflow menu of single-file operations for PATH.
Each item is an allowlisted action (see the command-dispatch boundary): the
handler runs one specific, root-guarded operation — never arbitrary dispatch."
  (eabp-menu
   (list
    (eabp-menu-item "Rename"
                    (eabp-action "files.rename" :args `((file . ,path)))
                    :icon "edit")
    (eabp-menu-item "Delete"
                    (eabp-action "files.delete" :args `((file . ,path)))
                    :icon "delete"))))

(defun eabp-files--card-for (path)
  "A tappable card for PATH — a folder (cd) or a file (open), with an op menu."
  (if (file-directory-p path)
      (eabp-card
       (list (eabp-row
              (eabp-icon "folder")
              (eabp-box (list (eabp-text (file-name-nondirectory
                                          (directory-file-name path))
                                         'body))
                        :weight 1)
              (eabp-files--entry-menu path)))
       :on-tap (eabp-action "files.cd" :args `((dir . ,path))))
    (let ((size (or (file-attribute-size (file-attributes path)) 0)))
      (eabp-card
       (list (eabp-row
              (eabp-icon "description")
              (eabp-box (list (eabp-column
                               (eabp-text (file-name-nondirectory path) 'body)
                               (eabp-text (file-size-human-readable size) 'caption)))
                        :weight 1)
              (eabp-files--entry-menu path)))
       :on-tap (eabp-action "files.open" :args `((file . ,path)))))))

(defun eabp-files--dired-cards (buffer)
  "Tier-1 dired skin: render dired BUFFER as a list of file/dir cards.
Directories sort first, then files.  A \"..\" card heads the list only when
the parent is still within the allowed roots — at the ceiling there is no
\"..\".  Returns a list of nodes, per the renderer contract."
  (with-current-buffer buffer
    (let ((dir (expand-file-name default-directory))
          paths)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          ;; Filter . and .. by their *local* names; the full path is what we
          ;; render.  Non-file lines (header, "total N") yield nil and skip.
          (let ((local (dired-get-filename 'no-dir t)))
            (when (and local (not (member local '("." ".."))))
              (push (dired-get-filename nil t) paths)))
          (forward-line 1)))
      (setq paths (delq nil (nreverse paths)))
      (let* ((dirs (sort (cl-remove-if-not #'file-directory-p paths) #'string<))
             (files (sort (cl-remove-if #'file-directory-p paths) #'string<))
             (parent (file-name-directory (directory-file-name dir)))
             (up-card
              (when (and parent (eabp-files--within-root-p parent))
                (eabp-card
                 (list (eabp-row (eabp-icon "arrow_upward") (eabp-text ".." 'body)))
                 :on-tap (eabp-action "files.cd" :args `((dir . ,parent)))))))
        (delq nil (cons up-card
                        (mapcar #'eabp-files--card-for (append dirs files))))))))

;; Register the skin globally: any dired buffer — the Files view here or one
;; opened from the Buffers tab — renders as cards.  This is the single dispatch
;; seam from eabp-buffer.el; the Files feature owns dired's app-wide look.
(eabp-render-buffer-register 'dired-mode #'eabp-files--dired-cards)

(defun eabp-files--dired-buffer (dir)
  "Return a freshly-reverted dired buffer for DIR, or nil.
Refuses DIR outside `eabp-files-roots' or unreadable; the within-root guard
turns the Android sandbox's raw stat errors into a graceful nil."
  (when (and (stringp dir) (file-directory-p dir) (eabp-files--within-root-p dir))
    (condition-case nil
        (let ((buf (dired-noselect dir)))
          (with-current-buffer buf (revert-buffer nil t))
          buf)
      (error nil))))

(defun eabp-files--current-dir ()
  "The directory the Files view is showing — `eabp-files--dir' or the landing."
  (or eabp-files--dir (expand-file-name eabp-files-default-dir)))

(defun eabp-files-browser-body ()
  "Build the Files view: the current directory rendered as dired cards.
There is no separate roots screen — the view always shows a directory
\(`eabp-files--current-dir'), so it matches the Buffers-tab listing."
  (let ((buf (eabp-files--dired-buffer (eabp-files--current-dir))))
    (if buf
        (apply #'eabp-lazy-column (eabp-render-buffer buf))
      (eabp-empty-state :icon "info"
                        :title "Can't open folder"
                        :caption "Outside the allowed roots, or unreadable."))))

;; ─── Editor view ─────────────────────────────────────────────────────────────

(defun eabp-files--org-p (file)
  "Non-nil when FILE is an org file."
  (and file (string-match-p "\\.org\\'" file)))

(defun eabp-files-editor-body ()
  "Build the editor view for `eabp-files--file'.
Org files in read mode render the foldable outline reader; otherwise the
plain-text editor."
  (let ((file eabp-files--file))
    (if (not (and file (file-readable-p file)))
        (eabp-column (eabp-text "No file open." 'body))
      (if (and eabp-files--read-mode (eabp-files--org-p file))
          (if eabp-files--refile-mode
              (or (eabp-org-reader-refile-list file)
                  (eabp-text "No headings to show." 'caption))
            (let ((items (eabp-org--file-heading-items file)))
              (if items
                  (apply #'eabp-lazy-column
                         (mapcar #'eabp-org-ui--agenda-card items))
                (eabp-empty-state :icon "description"
                                  :title "Empty file"
                                  :caption "No headings found."))))
      (let* ((size (or (file-attribute-size (file-attributes file)) 0))
             (read-only (> size eabp-files-max-bytes))
             (content
              ;; Prefer a live buffer's content (may have unsaved desktop
              ;; edits); fall back to disk.
              (if-let ((buf (get-file-buffer file)))
                  (with-current-buffer buf
                    (buffer-substring-no-properties
                     (point-min)
                     (min (point-max) (1+ eabp-files-max-bytes))))
                (with-temp-buffer
                  (insert-file-contents file nil 0 eabp-files-max-bytes)
                  (buffer-string)))))
        (eabp-column
         (when read-only
           (eabp-text (format "File exceeds %s — opened read-only."
                              (file-size-human-readable eabp-files-max-bytes))
                      'caption))
         (eabp-editor file content
                      :read-only read-only
                      :line-numbers (and eabp-line-numbers
                                         (symbol-name eabp-line-numbers))
                      :complete (and eabp-complete-enabled (not read-only))
                      :on-save (eabp-action "files.save"
                                            :args `((file . ,file))
                                            :when-offline "queue"
                                            :dedupe (concat "save/" file)))))))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(declare-function eabp-org-ui-push-dashboard "eabp-org-ui")
(declare-function eabp-org-ui-snackbar "eabp-org-ui")
(declare-function eabp-org-ui--agenda-card "eabp-org-ui")
(declare-function eabp-org--file-heading-items "eabp-org")

(eabp-defaction "files.cd"
  (lambda (args _)
    (let ((dir (alist-get 'dir args)))
      (setq eabp-files--dir
            (and (stringp dir)
                 (file-directory-p dir)
                 (eabp-files--within-root-p dir)
                 (file-name-as-directory dir)))
      (eabp-org-ui-push-dashboard nil :switch-to "files"))))

(eabp-defaction "files.open"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (file-readable-p file)
                 (eabp-files--within-root-p file))
        (setq eabp-files--file (expand-file-name file))
        ;; Org files open reader-first; everything else in the editor.
        (setq eabp-files--read-mode (eabp-files--org-p eabp-files--file))
        (eabp-org-ui-push-dashboard nil :switch-to "edit")))))

(eabp-defaction "files.toggle-read"
  (lambda (_ _)
    (setq eabp-files--read-mode (not eabp-files--read-mode))
    (eabp-org-ui-push-dashboard nil :switch-to "edit")))

(eabp-defaction "files.toggle-refile"
  (lambda (_ _)
    (setq eabp-files--refile-mode (not eabp-files--refile-mode))
    (eabp-org-ui-push-dashboard nil :switch-to "edit")))

(eabp-defaction "files.delete"
  ;; Allowlisted op: delete the one tapped path, root-guarded, after a
  ;; confirmation (the y/n dialog is bridged to the phone by eabp-minibuffer).
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (eabp-files--within-root-p file)
                 (file-exists-p file))
        (if (yes-or-no-p (format "Delete %s? "
                                 (file-name-nondirectory
                                  (directory-file-name file))))
            (condition-case err
                (progn
                  (if (file-directory-p file)
                      (delete-directory file t)
                    (delete-file file))
                  (eabp-org-ui-snackbar
                   (format "Deleted %s" (file-name-nondirectory
                                         (directory-file-name file)))))
              (error (eabp-org-ui-snackbar
                      (format "Delete failed: %s" (error-message-string err)))))
          (eabp-org-ui-snackbar "Delete cancelled")))
      (eabp-org-ui-push-dashboard nil :switch-to "files"))))

(eabp-defaction "files.rename"
  ;; Allowlisted op: rename within the same directory; the new name is read
  ;; through the bridged minibuffer and the target re-checked against roots.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (eabp-files--within-root-p file)
                 (file-exists-p file))
        (let* ((old (file-name-nondirectory (directory-file-name file)))
               (new (read-string (format "Rename %s to: " old) old)))
          (cond
           ((or (null new) (string-empty-p (string-trim new)))
            (eabp-org-ui-snackbar "Rename cancelled"))
           (t
            (let ((target (expand-file-name
                           new (file-name-directory (directory-file-name file)))))
              (cond
               ((not (eabp-files--within-root-p target))
                (eabp-org-ui-snackbar "Rename rejected (outside roots)"))
               ((file-exists-p target)
                (eabp-org-ui-snackbar "Target already exists"))
               (t
                (condition-case err
                    (progn (rename-file file target)
                           (eabp-org-ui-snackbar (format "Renamed to %s" new)))
                  (error (eabp-org-ui-snackbar
                          (format "Rename failed: %s"
                                  (error-message-string err)))))))))))
        (eabp-org-ui-push-dashboard nil :switch-to "files")))))

;; ─── New file / folder ───────────────────────────────────────────────────────

(defun eabp-files-show-new-dialog ()
  "Dialog to create a new file or folder in the current Files directory.
The name field's value reaches the create handlers two ways: on-submit
carries it in `value', and the Folder/File buttons read it back from UI
state (the same pattern as the capture form)."
  (let ((dir (eabp-files--current-dir)))
    (when dir
      (eabp-send-dialog
       (eabp-column
        (eabp-text "New" 'title)
        (eabp-text (abbreviate-file-name dir) 'caption)
        (eabp-text-input "files-new-name"
                         :label "Name"
                         :hint "notes.org"
                         :single-line t
                         :on-submit (eabp-action "files.create"
                                                 :args '((type . "file"))))
        (eabp-row
         (eabp-button "Cancel" (eabp-action "files.new.cancel") :variant "text")
         (eabp-spacer :weight 1)
         (eabp-button "Folder"
                      (eabp-action "files.create" :args '((type . "dir")))
                      :variant "outlined")
         (eabp-spacer :width 8)
         (eabp-button "File"
                      (eabp-action "files.create" :args '((type . "file"))))))))))

(eabp-defaction "files.new"
  (lambda (_ _)
    ;; Forget any leftover name so a button tap can't read a stale value
    ;; before the user types (UI state is global and persistent).
    (eabp-ui-state-clear "files-new-name")
    (eabp-files-show-new-dialog)))

(eabp-defaction "files.new.cancel"
  (lambda (_ _) (eabp-dismiss-dialog)))

(eabp-defaction "files.create"
  ;; Allowlisted op: create a single-segment file or folder in the current
  ;; directory, re-checked against the roots.  TYPE is "file" or "dir".
  (lambda (args _)
    (let* ((type (or (alist-get 'type args) "file"))
           (name (string-trim (or (alist-get 'value args)
                                  (eabp-ui-state "files-new-name")
                                  "")))
           (dir (eabp-files--current-dir)))
      (cond
       ((or (null dir) (not (eabp-files--within-root-p dir)))
        (eabp-org-ui-snackbar "No directory"))
       ((string-empty-p name)
        (eabp-org-ui-snackbar "Name required"))
       ;; Single segment only — no separators or parent traversal.
       ((string-match-p "/" name)
        (eabp-org-ui-snackbar "Name can't contain '/'"))
       (t
        (let ((target (expand-file-name name dir)))
          (cond
           ((not (eabp-files--within-root-p target))
            (eabp-org-ui-snackbar "Rejected (outside roots)"))
           ((file-exists-p target)
            (eabp-org-ui-snackbar "Already exists"))
           (t
            (condition-case err
                (progn
                  (if (equal type "dir")
                      (make-directory target)
                    (write-region "" nil target nil 'silent))
                  (eabp-ui-state-clear "files-new-name")
                  (eabp-org-ui-snackbar (format "Created %s" name)))
              (error (eabp-org-ui-snackbar
                      (format "Create failed: %s"
                              (error-message-string err))))))))))
      (eabp-dismiss-dialog)
      (eabp-org-ui-push-dashboard nil :switch-to "files"))))

(eabp-defaction "files.save"
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (value (alist-get 'value args)))
      (cond
       ((not (and (stringp file) (stringp value)
                  (eabp-files--within-root-p file)))
        (eabp-org-ui-snackbar "Save rejected"))
       (t
        (condition-case err
            (progn
              ;; Route through a live buffer when one exists so modes,
              ;; hooks, and desktop Emacs all see the change coherently.
              (if-let ((buf (get-file-buffer file)))
                  (with-current-buffer buf
                    (erase-buffer)
                    (insert value)
                    (let ((eabp-org--inhibit-save-refresh t)
                          (save-silently t))
                      (save-buffer)))
                (let ((eabp-org--inhibit-save-refresh t))
                  (write-region value nil file)))
              (when (fboundp 'eabp-org-cache-invalidate)
                (eabp-org-cache-invalidate))
              (eabp-org-ui-snackbar
               (format "Saved %s" (file-name-nondirectory file))))
          (error
           (eabp-org-ui-snackbar
            (format "Save failed: %s" (error-message-string err))))))))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "config.reload"
  (lambda (_ _)
    (condition-case err
        (progn
          (load user-init-file)
          (eabp-org-ui-snackbar "Config reloaded ✓"))
      (error
       (eabp-org-ui-snackbar
        (format "Reload error: %s" (error-message-string err)))))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "files.properties.show"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (if (not (and file (stringp file) (file-readable-p file)))
          (eabp-org-ui-snackbar (format "Cannot open properties: %s" (or file "no file")))
        (condition-case err
            (let* ((buf (or (get-file-buffer file) (find-file-noselect file)))
                   (kwds (with-current-buffer buf (org-collect-keywords '("TITLE" "CATEGORY" "FILETAGS"))))
                   (title (car (alist-get "TITLE" kwds nil nil #'equal)))
                   (category (car (alist-get "CATEGORY" kwds nil nil #'equal)))
                   (filetags-str (car (alist-get "FILETAGS" kwds nil nil #'equal)))
                   (filetags (when filetags-str (split-string filetags-str ":" t "[ \t\n\r]+")))
                   (available-tags (seq-uniq (append filetags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist)))))
              (eabp-send-dialog
               (eabp-column
                (eabp-text "File Properties" 'title)
                (eabp-text (file-name-nondirectory file) 'caption)
                (eabp-text-input "file-prop-title" :label "Title" :value title :single-line t)
                (eabp-text-input "file-prop-category" :label "Category" :value category :single-line t)
                (eabp-text "File Tags" 'caption nil nil nil nil 8)
                (eabp-enum-list "file-prop-tags" available-tags
                                :value filetags :multi-select t :allow-add t)
                (eabp-row
                 (eabp-spacer :weight 1)
                 (eabp-button "Cancel" (eabp-action "dialog.dismiss") :variant "text")
                 (eabp-spacer :width 8)
                 (eabp-button "Save" (eabp-action "files.properties.save" :args `((file . ,file))))))))
          (error
           (eabp-org-ui-snackbar (format "Properties error: %s" (error-message-string err)))))))))

(eabp-defaction "files.properties.save"
  (lambda (args _)
    (let* ((file (alist-get 'file args))
           (buf (or (get-file-buffer file) (find-file-noselect file)))
           (title (eabp-ui-state "file-prop-title"))
           (category (eabp-ui-state "file-prop-category"))
           (tags-val (eabp-ui-state "file-prop-tags"))
           (tags (cond
                  ((vectorp tags-val) (append tags-val nil))
                  ((listp tags-val) tags-val)
                  (t nil))))
      (with-current-buffer buf
        (save-excursion
          (save-restriction
            (widen)
            (let ((update-kwd (lambda (kwd val)
                                (goto-char (point-min))
                                (if (re-search-forward (format "^[ \t]*#\\+%s:[ \t]*\\(.*\\)$" kwd) nil t)
                                    (if (and val (not (string-empty-p val)))
                                        (replace-match val t t nil 1)
                                      (delete-region (line-beginning-position) (min (1+ (line-end-position)) (point-max))))
                                  (when (and val (not (string-empty-p val)))
                                    (goto-char (point-min))
                                    ;; If inserting something else than TITLE and a TITLE exists, insert after it.
                                    (when (not (equal kwd "TITLE"))
                                      (when (re-search-forward "^[ \t]*#\\+TITLE:.*$" nil t)
                                        (forward-line 1)))
                                    (insert (format "#+%s: %s\n" kwd val)))))))
              (funcall update-kwd "TITLE" title)
              (funcall update-kwd "FILETAGS" (when tags (concat ":" (string-join tags ":") ":")))
              (funcall update-kwd "CATEGORY" category))
            (let ((eabp-org--inhibit-save-refresh t)
                  (save-silently t))
              (save-buffer)))))
      (eabp-send "dialog.dismiss" nil)
      (when (fboundp 'eabp-org-cache-invalidate)
        (eabp-org-cache-invalidate))
      (eabp-org-ui-push-dashboard))))

(provide 'eabp-files)
;;; eabp-files.el ends here