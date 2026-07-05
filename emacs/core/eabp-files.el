;;; eabp-files.el --- File browser & editor for EABP -*- lexical-binding: t; -*-

;; A dired-style file browser plus a plain-text editor, rendered through
;; EABP surfaces. Together with the eval tab this is the self-hosting
;; plumbing: init.el (and anything else) can be edited, saved, and
;; reloaded from the phone, so the desktop side never needs touching
;; once eabp is in the init file.
;;
;; Registers two shell views:
;;   "files" — root list / directory listing (a bottom-bar tab)
;;   "edit"  — editor for `eabp-files--file' (present while a file is open)
;;
;; App seams — this module knows nothing about org (or any file type):
;;   `eabp-files-editor-body-functions'    replace the editor body per file
;;   `eabp-files-editor-actions-functions' add top-bar buttons per file
;;   `eabp-files-open-hook'                react to a file being opened
;;   `eabp-files-after-save-hook'          react to a phone-side save

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer) ; Tier 0 renderer + the major-mode→skin registry
(require 'eabp-complete) ; capf bridge: the editor's `complete' flag
(require 'eabp-shell)
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

;; ─── App seams ───────────────────────────────────────────────────────────────

(defvar eabp-files-editor-body-functions nil
  "Abnormal hook: functions of FILE returning the editor view's body, or nil.
Tried in order before the plain-text editor; the first non-nil result
wins.  Apps register alternate renderings here (e.g. a foldable outline
reader for their file type).")

(defvar eabp-files-editor-actions-functions nil
  "Abnormal hook: functions of FILE returning top-bar action nodes.
The returned lists are appended into the editor view's top bar; apps add
their per-file-type buttons (mode toggles, metadata dialogs) here.")

(defvar eabp-files-open-hook nil
  "Hook run with FILE when the phone opens it in the editor.
Apps set their per-file-type editor state here (e.g. reader-first).")

(defvar eabp-files-after-save-hook nil
  "Hook run with FILE after a phone-triggered save succeeds.
Apps whose views memoise data derived from files drop caches here.")

(defvar eabp-files-editor-toolbar-function #'ignore
  "Function of FILE returning the editor toolbar name to request, or nil.
Apps point this at their file-type mapping (e.g. \"org\" for org files)
so the toolbar choice ships in the editor spec instead of being inferred
client-side.")

;; ─── Browser view (dired under the hood) ─────────────────────────────────────

;; The directory listing is backed by a real dired buffer — the standard Emacs
;; file engine — but presented through a card skin registered for
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
  "Dired skin: render dired BUFFER as a list of file/dir cards.
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
\(`eabp-files--current-dir'), so it matches the Buffers-tab listing.
While content-search results exist, a re-entry card heads the list."
  (let ((buf (eabp-files--dired-buffer (eabp-files--current-dir)))
        (results-card (eabp-files--grep-results-card)))
    (if buf
        (apply #'eabp-lazy-column
               (append (and results-card (list results-card))
                       (eabp-render-buffer buf)))
      (eabp-empty-state :icon "info"
                        :title "Can't open folder"
                        :caption "Outside the allowed roots, or unreadable."))))

;; ─── Content search ──────────────────────────────────────────────────────────
;;
;; A pure-elisp recursive scan: portable (no external grep needed on the
;; host) and bounded — capped hits and files, capped file size, VCS/build
;; directories skipped, binaries (NUL early in the file) skipped.  The
;; scan starts at the directory being browsed, which is inside
;; `eabp-files-roots' by construction, so the root guard holds; the query
;; is matched as a literal string, never a regexp off the wire.

(defcustom eabp-files-grep-max-hits 200
  "Content search stops after this many matching lines."
  :type 'integer :group 'eabp)

(defcustom eabp-files-grep-max-files 2000
  "Content search stops after examining this many files.
Search from a subdirectory rather than the root to keep scans quick."
  :type 'integer :group 'eabp)

(defcustom eabp-files-grep-max-file-bytes (* 1024 1024)
  "Files larger than this are skipped by the content search."
  :type 'integer :group 'eabp)

(defcustom eabp-files-grep-exclude-dirs
  '(".git" ".hg" ".svn" "node_modules" ".gradle" "build" "dist" "target")
  "Directory names the content search never descends into."
  :type '(repeat string) :group 'eabp)

(defvar eabp-files--grep nil
  "Latest content search, or nil.
A plist (:query Q :dir D :hits ((FILE LINE TEXT) ...) :truncated BOOL).")

(defvar eabp-files-view-region-function
  (lambda (name &rest _) (message "EABP: no host to view %s" name))
  "Function of (BUFFER-NAME BEG END LABEL &optional POINT) showing a
buffer slice with POINT's line as the scroll target.  Set by
eabp-emacs-ui (its buffer view); kept as a seam so this module never
depends on the buffer-view host.")

(defun eabp-files--grep-scan (dir query)
  "Search QUERY (a literal, case-insensitive) under DIR.
Returns the plist stored in `eabp-files--grep'; one hit per line."
  (let ((re (regexp-quote query))
        (case-fold-search t)
        (hits-left eabp-files-grep-max-hits)
        (files-left eabp-files-grep-max-files)
        hits truncated)
    (catch 'done
      (dolist (file (directory-files-recursively
                     dir "" nil
                     (lambda (d)
                       (not (member (file-name-nondirectory
                                     (directory-file-name d))
                                    eabp-files-grep-exclude-dirs)))))
        (when (<= (cl-decf files-left) 0)
          (setq truncated t)
          (throw 'done nil))
        (when (and (file-readable-p file)
                   ;; Backups and auto-saves are stale copies: they double
                   ;; every hit, and centralized backups carry the full
                   ;; path slash-encoded as "!" in their names.
                   (not (backup-file-name-p file))
                   (not (auto-save-file-name-p (file-name-nondirectory file)))
                   (let ((size (file-attribute-size (file-attributes file))))
                     (and size (<= size eabp-files-grep-max-file-bytes))))
          (with-temp-buffer
            (when (ignore-errors (insert-file-contents file) t)
              (goto-char (point-min))
              ;; Binary guard: a NUL early in the file means don't line-match.
              (unless (search-forward "\0" (min 1024 (point-max)) t)
                (while (re-search-forward re nil t)
                  (push (list file
                              (line-number-at-pos)
                              (buffer-substring-no-properties
                               (line-beginning-position)
                               (min (line-end-position)
                                    (+ (line-beginning-position) 200))))
                        hits)
                  (when (<= (cl-decf hits-left) 0)
                    (setq truncated t)
                    (throw 'done nil))
                  (end-of-line))))))))
    (list :query query :dir dir :hits (nreverse hits) :truncated truncated)))

(defun eabp-files--grep-body ()
  "The search-results view body: one tappable card per matching line."
  (let* ((g eabp-files--grep)
         (dir (plist-get g :dir))
         (hits (plist-get g :hits)))
    (if (null hits)
        (eabp-empty-state :icon "manage_search" :title "No matches"
                          :caption (format "\"%s\" under %s"
                                           (plist-get g :query)
                                           (abbreviate-file-name dir)))
      (apply #'eabp-lazy-column
             (cons
              (eabp-text (format "%d matching line%s under %s%s"
                                 (length hits)
                                 (if (= (length hits) 1) "" "s")
                                 (abbreviate-file-name dir)
                                 (if (plist-get g :truncated)
                                     " — stopped early, narrow the search"
                                   ""))
                         'caption)
              (mapcar (lambda (hit)
                        (pcase-let* ((`(,file ,line ,text) hit)
                                     (rel (file-relative-name file dir))
                                     (subdir (file-name-directory rel)))
                          (eabp-card
                           (list (eabp-column
                                  (eabp-row
                                   (eabp-box
                                    (list (apply #'eabp-column
                                                 (delq nil
                                                       (list
                                                        (eabp-text (file-name-nondirectory file)
                                                                   'label)
                                                        (when subdir
                                                          (eabp-text subdir 'caption
                                                                     nil nil nil 1))))))
                                    :weight 1)
                                   (eabp-text (format "L%d" line) 'caption)
                                   (eabp-icon-button
                                    "edit"
                                    (eabp-action "files.open"
                                                 :args `((file . ,file)))
                                    :content-description "Open in editor"))
                                  (eabp-rich-text
                                   (list (eabp-span (string-trim text) :mono t)))))
                           ;; Tap = read the hit in context (scrolled to the
                           ;; line); the pencil opens the editor.
                           :on-tap (eabp-action "files.grep-visit"
                                                :args `((file . ,file)
                                                        (line . ,line))
                                                :when-offline "drop"))))
                      hits))))))

(defun eabp-files--grep-results-card ()
  "The re-entry card the browser shows while results exist, or nil."
  (when eabp-files--grep
    (eabp-card
     (list (eabp-row
            (eabp-icon "manage_search")
            (eabp-box (list (eabp-text
                             (format "Results: \"%s\" (%d)"
                                     (plist-get eabp-files--grep :query)
                                     (length (plist-get eabp-files--grep :hits)))
                             'body))
                      :weight 1)
            (eabp-icon "chevron_right")))
     :on-tap (eabp-shell-switch-view "grep"))))

;; ─── Editor view ─────────────────────────────────────────────────────────────

(defun eabp-files-editor-body ()
  "Build the editor view for `eabp-files--file'.
An app-registered body (see `eabp-files-editor-body-functions') wins;
otherwise the plain-text editor."
  (let ((file eabp-files--file))
    (if (not (and file (file-readable-p file)))
        (eabp-column (eabp-text "No file open." 'body))
      (or (run-hook-with-args-until-success
           'eabp-files-editor-body-functions file)
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
                          :toolbar (funcall eabp-files-editor-toolbar-function file)
                          :on-save (eabp-action "files.save"
                                                :args `((file . ,file))
                                                :when-offline "queue"
                                                :dedupe (concat "save/" file)))))))))

;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun eabp-files--files-view (snackbar)
  "The Files tab: the current directory's cards, back arrow inside subdirs."
  (let ((grep-btn (eabp-icon-button
                   "manage_search"
                   (eabp-action "files.grep" :when-offline "drop")
                   :content-description "Search file contents")))
    (eabp-shell-tab-view
     "files" (eabp-files-browser-body)
     :top-bar (if eabp-files--dir
                  (eabp-top-bar (abbreviate-file-name eabp-files--dir)
                                :nav-icon "arrow_back"
                                :nav-action (eabp-action "files.cd"
                                                         :args '((dir . :null)))
                                :actions (list grep-btn))
                (eabp-shell-default-top-bar "Files"
                                            :extra-actions (list grep-btn)))
     ;; A create FAB — the view always shows a directory (the landing dir or
     ;; a subdirectory), so it's always offered.
     :fab (eabp-fab "add" :label "New" :on-tap (eabp-action "files.new"))
     :snackbar snackbar)))

(defun eabp-files--edit-view (snackbar)
  "The editor view for the open file, with app-contributed top-bar actions."
  (eabp-shell-nav-view
   (if eabp-files--file
       (file-name-nondirectory eabp-files--file)
     "Editor")
   (eabp-files-editor-body)
   :back-to "files"
   :actions (when eabp-files--file
              (apply #'append
                     (delq nil
                           (mapcar (lambda (fn) (funcall fn eabp-files--file))
                                   eabp-files-editor-actions-functions))))
   :snackbar snackbar))

(eabp-shell-define-view "files"
  :builder #'eabp-files--files-view
  :tab '(:icon "folder_open" :label "Files")
  :order 40)

(eabp-shell-define-view "edit"
  :builder #'eabp-files--edit-view
  :when (lambda () (and eabp-files--file t))
  :order 100)

(defun eabp-files--grep-view (snackbar)
  "The content-search results view; ✕ discards the results."
  (eabp-shell-nav-view
   (format "\"%s\"" (plist-get eabp-files--grep :query))
   (eabp-files--grep-body)
   :back-to "files"
   :actions (list (eabp-icon-button
                   "close"
                   (eabp-action "files.grep-clear" :when-offline "drop")
                   :content-description "Discard search results"))
   :snackbar snackbar))

(eabp-shell-define-view "grep"
  :builder #'eabp-files--grep-view
  :when (lambda () (and eabp-files--grep t))
  :order 101)

;; Leaving the editor for the files view closes the file (the next push
;; drops the edit view). Unsaved companion-side text is discarded with it.
(add-hook 'eabp-shell-view-switched-hook
          (lambda (view)
            (when (and (equal view "files") eabp-files--file)
              (setq eabp-files--file nil))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "files.cd"
  (lambda (args _)
    (let ((dir (alist-get 'dir args)))
      (setq eabp-files--dir
            (and (stringp dir)
                 (file-directory-p dir)
                 (eabp-files--within-root-p dir)
                 (file-name-as-directory dir)))
      (eabp-shell-push nil :switch-to "files"))))

(eabp-defaction "files.open"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (file-readable-p file)
                 (eabp-files--within-root-p file))
        (setq eabp-files--file (expand-file-name file))
        (run-hook-with-args 'eabp-files-open-hook eabp-files--file)
        (eabp-shell-push nil :switch-to "edit")))))

(eabp-defaction "files.grep"
  ;; The query arrives through the bridged minibuffer (this runs inside an
  ;; action handler), so the search icon needs no input widget of its own.
  ;; Scope is the directory being browsed — within the roots by
  ;; construction — and the scan is bounded by the grep defcustoms.
  (lambda (_ __)
    (let* ((dir (eabp-files--current-dir))
           (query (condition-case nil
                      (string-trim
                       (read-string (format "Search in %s for: "
                                            (abbreviate-file-name dir))))
                    (quit ""))))
      (if (string-empty-p query)
          (eabp-shell-push)
        (setq eabp-files--grep (eabp-files--grep-scan dir query))
        (eabp-shell-push nil :switch-to "grep")))))

(eabp-defaction "files.grep-clear"
  (lambda (_ __)
    (setq eabp-files--grep nil)
    (eabp-shell-push nil :switch-to "files")))

(eabp-defaction "files.grep-visit"
  ;; Show a hit in context: the file's buffer in the buffer view,
  ;; narrowed around the line with the hit marked as the scroll target.
  ;; Region render dodges the buffer view's from-the-top line cap, so
  ;; hits deep in big files are reachable.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (line (alist-get 'line args)))
      (when (and (stringp file) (numberp line)
                 (eabp-files--within-root-p file)
                 (file-readable-p file))
        (condition-case err
            (let ((buf (find-file-noselect file)))
              (with-current-buffer buf
                (save-excursion
                  (goto-char (point-min))
                  (forward-line (1- (max 1 (truncate line))))
                  (let ((target (point))
                        (beg (save-excursion (forward-line -30) (point)))
                        (end (save-excursion (forward-line 170) (point))))
                    (funcall eabp-files-view-region-function
                             (buffer-name buf) beg end
                             (format "%s:%d" (file-name-nondirectory file)
                                     (truncate line))
                             target)))))
          (error (eabp-shell-notify (error-message-string err))))))))

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
                  (eabp-shell-notify
                   (format "Deleted %s" (file-name-nondirectory
                                         (directory-file-name file)))))
              (error (eabp-shell-notify
                      (format "Delete failed: %s" (error-message-string err)))))
          (eabp-shell-notify "Delete cancelled")))
      (eabp-shell-push nil :switch-to "files"))))

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
            (eabp-shell-notify "Rename cancelled"))
           (t
            (let ((target (expand-file-name
                           new (file-name-directory (directory-file-name file)))))
              (cond
               ((not (eabp-files--within-root-p target))
                (eabp-shell-notify "Rename rejected (outside roots)"))
               ((file-exists-p target)
                (eabp-shell-notify "Target already exists"))
               (t
                (condition-case err
                    (progn (rename-file file target)
                           (eabp-shell-notify (format "Renamed to %s" new)))
                  (error (eabp-shell-notify
                          (format "Rename failed: %s"
                                  (error-message-string err)))))))))))
        (eabp-shell-push nil :switch-to "files")))))

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
        (eabp-shell-notify "No directory"))
       ((string-empty-p name)
        (eabp-shell-notify "Name required"))
       ;; Single segment only — no separators or parent traversal.
       ((string-match-p "/" name)
        (eabp-shell-notify "Name can't contain '/'"))
       (t
        (let ((target (expand-file-name name dir)))
          (cond
           ((not (eabp-files--within-root-p target))
            (eabp-shell-notify "Rejected (outside roots)"))
           ((file-exists-p target)
            (eabp-shell-notify "Already exists"))
           (t
            (condition-case err
                (progn
                  (if (equal type "dir")
                      (make-directory target)
                    (write-region "" nil target nil 'silent))
                  (eabp-ui-state-clear "files-new-name")
                  (eabp-shell-notify (format "Created %s" name)))
              (error (eabp-shell-notify
                      (format "Create failed: %s"
                              (error-message-string err))))))))))
      (eabp-dismiss-dialog)
      (eabp-shell-push nil :switch-to "files"))))

(eabp-defaction "files.save"
  ;; Saves run inside the action handler, so `eabp--in-action-handler' is
  ;; bound — app after-save-hook refreshers key off that to avoid doubling
  ;; the explicit push below.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (value (alist-get 'value args)))
      (cond
       ((not (and (stringp file) (stringp value)
                  (eabp-files--within-root-p file)))
        (eabp-shell-notify "Save rejected"))
       (t
        (condition-case err
            (progn
              ;; Route through a live buffer when one exists so modes,
              ;; hooks, and desktop Emacs all see the change coherently.
              (if-let ((buf (get-file-buffer file)))
                  (with-current-buffer buf
                    (erase-buffer)
                    (insert value)
                    (let ((save-silently t))
                      (save-buffer)))
                (write-region value nil file))
              (run-hook-with-args 'eabp-files-after-save-hook file)
              (eabp-shell-notify
               ;; Re-loading init in a running session never applies
               ;; cleanly (defvars keep old values, hooks double up), so
               ;; the honest instruction is a restart.
               (if (and user-init-file (file-equal-p file user-init-file))
                   "Saved init — restart Emacs to apply config changes"
                 (format "Saved %s" (file-name-nondirectory file)))))
          (error
           (eabp-shell-notify
            (format "Save failed: %s" (error-message-string err))))))))
    (eabp-shell-push)))

(eabp-defaction "config.reload"
  ;; Retired: `load user-init-file' mid-session never applies cleanly
  ;; (defvars keep their values, hooks double-register), so the drawer
  ;; entry is gone.  The handler stays as a stub so a stale cached UI
  ;; from an older push gets the instruction instead of a dropped tap.
  (lambda (_ _)
    (eabp-shell-notify "Reload was removed — restart Emacs to apply config changes")
    (eabp-shell-push)))

(provide 'eabp-files)
;;; eabp-files.el ends here
