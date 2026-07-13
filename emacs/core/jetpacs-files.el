;;; jetpacs-files.el --- File browser & editor for Jetpacs -*- lexical-binding: t; -*-

;; A dired-style file browser plus a plain-text editor, rendered through
;; Jetpacs surfaces. Together with the eval tab this is the self-hosting
;; plumbing: init.el (and anything else) can be edited, saved, and
;; reloaded from the phone, so the desktop side never needs touching
;; once jetpacs is in the init file.
;;
;; Registers two shell views:
;;   "files" — root list / directory listing (a bottom-bar tab)
;;   "edit"  — editor for `jetpacs-files--file' (present while a file is open)
;;
;; App seams — this module knows nothing about org (or any file type):
;;   `jetpacs-files-editor-body-functions'    replace the editor body per file
;;   `jetpacs-files-editor-actions-functions' add top-bar buttons per file
;;   `jetpacs-files-open-hook'                react to a file being opened
;;   `jetpacs-files-after-save-hook'          react to a phone-side save

;;; Code:

(require 'jetpacs)
(require 'jetpacs-surfaces)
(require 'jetpacs-widgets)
(require 'jetpacs-buffer) ; Tier 0 renderer + the major-mode→skin registry
(require 'jetpacs-results) ; content-search results ride the shared loci substrate
(require 'jetpacs-complete) ; capf bridge: the editor's `complete' flag
(require 'jetpacs-shell)
(require 'dired)
(require 'cl-lib)

(defcustom jetpacs-files-roots
  `(("Config" . ,user-emacs-directory)
    ("Org"    . ,(or (and (boundp 'org-directory) org-directory) "~/org/"))
    ("Home"   . "~/"))
  "Root directories the Files browser is confined to.
Navigation, opening, and file operations are all refused outside these
roots (`jetpacs-files--within-root-p').  Labels are unused now that the Files
view lands directly in `jetpacs-files-default-dir' rather than on a roots list,
but the alist shape is kept for back-compatibility."
  :type '(alist :key-type string :value-type directory)
  :group 'jetpacs)

(defcustom jetpacs-files-default-dir "~/"
  "Directory the Files tab opens to (and the navigation ceiling).
Must lie within `jetpacs-files-roots'.  The Files view shows this directory's
full listing — the same view you get from the Buffers tab on its dired
buffer — instead of a separate shortcut screen."
  :type 'directory :group 'jetpacs)

(defcustom jetpacs-files-shared-storage 'auto
  "How the Files browser exposes Android shared storage (/sdcard).
Emacs's HOME is a private per-app sandbox, so /sdcard is otherwise
unreachable from the Files tab even though the phone and the rest of the
platform live there.  When `auto' (the default) the browser probes for the
device's primary shared-storage directory and, if it is accessible, offers a
one-tap shortcut to it from the landing view — the standalone counterpart to
what Termux's `termux-setup-storage' arranges via ~/storage/shared.  A
string names an explicit directory to expose instead; nil disables the
shortcut entirely.

Access still depends on Emacs holding the storage permission: when it does
not, no directory is accessible and the shortcut simply does not appear."
  :type '(choice (const :tag "Auto-detect /sdcard" auto)
                 (const :tag "Disabled" nil)
                 (directory :tag "Explicit path"))
  :group 'jetpacs)

(defcustom jetpacs-files-max-bytes (* 256 1024)
  "Files larger than this open read-only.
Editor saves travel inside a broadcast intent on the companion side,
which has a hard payload ceiling (~500 KB across all extras), so big
files must not round-trip through the editor."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-files--dir nil
  "Directory being browsed, or nil for the landing dir (`jetpacs-files-default-dir').")

(defvar jetpacs-files--file nil
  "Absolute path of the file open in the editor, or nil.")

;; ─── App seams ───────────────────────────────────────────────────────────────

(defvar jetpacs-files-editor-body-functions nil
  "Abnormal hook: functions of FILE returning the editor view's body, or nil.
Tried in order before the plain-text editor; the first non-nil result
wins.  Apps register alternate renderings here (e.g. a foldable outline
reader for their file type).")

(defvar jetpacs-files-editor-actions-functions nil
  "Abnormal hook: functions of FILE returning top-bar action nodes.
The returned lists are appended into the editor view's top bar; apps add
their per-file-type buttons (mode toggles, metadata dialogs) here.")

(defvar jetpacs-files-open-hook nil
  "Hook run with FILE when the phone opens it in the editor.
Apps set their per-file-type editor state here (e.g. reader-first).")

(defvar jetpacs-files-after-save-hook nil
  "Hook run with FILE after a phone-triggered save succeeds.
Apps whose views memoise data derived from files drop caches here.")

(defvar jetpacs-files-editor-toolbar-function #'ignore
  "Function of FILE returning the editor toolbar to request, or nil.
Either a list of `jetpacs-toolbar-item's the companion interprets as data
\(SPEC §9 \"Editor toolbars\", the default path) or a string naming a
host-registered native toolbar.  Apps point this at their file-type
mapping so the toolbar choice ships in the editor spec instead of being
inferred client-side.")

;; ─── Browser view (dired under the hood) ─────────────────────────────────────

;; The directory listing is backed by a real dired buffer — the standard Emacs
;; file engine — but presented through a card skin registered for
;; `dired-mode'.  So the same buffer renders as touch cards here and as a raw,
;; faithful listing from the Buffers tab: Tier 0 and Tier 1 over one model.
;; The Files tab lands directly in `jetpacs-files-default-dir' (no separate roots
;; screen) so it matches the full listing you get from the Buffers tab.

(defun jetpacs-files--within-root-p (path)
  "Non-nil when PATH is inside (or is) one of `jetpacs-files-roots'.
Uses `file-in-directory-p', which compares path components — a bare
string-prefix check would let root \"~/org\" authorize \"~/org-secrets\",
and this predicate is the security boundary for every file operation
the phone can trigger."
  (let ((full (expand-file-name path)))
    (cl-some (lambda (root)
               (file-in-directory-p full (expand-file-name (cdr root))))
             jetpacs-files-roots)))

;; ─── Shared storage (/sdcard) ────────────────────────────────────────────────
;;
;; Emacs runs in a private sandbox whose HOME is nowhere near /sdcard, so a
;; standalone (non-Termux) install can't browse to the shared storage where the
;; phone, downloaded app bundles, and org files all live.  Termux users get
;; ~/storage/shared from `termux-setup-storage'; this gives everyone the same
;; reach, without requiring Termux — but only when Emacs actually holds the
;; storage permission (else the directory isn't accessible and we stay quiet).

(defun jetpacs-files--detect-shared-dir ()
  "Detect the primary shared-storage directory, or nil.
Honours `jetpacs-files-shared-storage'.  For `auto', returns the first of the
usual Android locations that exists and is readable; a string is taken as an
explicit directory (still gated on accessibility)."
  (pcase jetpacs-files-shared-storage
    ('nil nil)
    ((and (pred stringp) dir)
     (and (file-accessible-directory-p dir) (file-name-as-directory dir)))
    (_
     (cl-some (lambda (d)
                (and d (file-accessible-directory-p d) (file-name-as-directory d)))
              (list (getenv "EXTERNAL_STORAGE")
                    "/sdcard"
                    "/storage/emulated/0"
                    "/storage/self/primary")))))

(defvar jetpacs-files--shared-dir 'unset
  "Memoized `jetpacs-files-shared-dir' result — a directory, nil, or the
`unset' sentinel before first detection.")

(defun jetpacs-files-shared-dir ()
  "The shared-storage directory the Files browser exposes, or nil.
Detected once (see `jetpacs-files--detect-shared-dir').  On first successful
detection the directory is also added to `jetpacs-files-roots', so navigation
and file operations there clear the within-root guard — this is what widens
the sandbox to reach /sdcard.  Returns nil (adding nothing) when no shared
storage is accessible, so the feature degrades silently without it."
  (when (eq jetpacs-files--shared-dir 'unset)
    (setq jetpacs-files--shared-dir (jetpacs-files--detect-shared-dir))
    (when jetpacs-files--shared-dir
      (add-to-list 'jetpacs-files-roots
                   (cons "Storage" jetpacs-files--shared-dir) t)))
  jetpacs-files--shared-dir)

(defun jetpacs-files--shared-storage-card ()
  "Shortcut card to shared storage for the Files landing view, or nil.
Shown only at the landing directory, when shared storage is accessible and is
not itself the landing — one tap to the /sdcard tree Termux exposes at
~/storage/shared."
  (when-let (((null jetpacs-files--dir))
             (shared (jetpacs-files-shared-dir)))
    (unless (file-equal-p shared (jetpacs-files--current-dir))
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "sd_storage")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Shared storage" 'body)
                               (jetpacs-text (abbreviate-file-name
                                           (directory-file-name shared))
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-action "files.cd"
                            :args `((dir . ,(directory-file-name shared))))))))

(defun jetpacs-files--entry-menu (path)
  "Overflow menu of single-file operations for PATH.
Each item is an allowlisted action (see the command-dispatch boundary): the
handler runs one specific, root-guarded operation — never arbitrary dispatch."
  (jetpacs-menu
   (list
    (jetpacs-menu-item "Rename"
                    (jetpacs-action "files.rename" :args `((file . ,path)))
                    :icon "edit")
    (jetpacs-menu-item "Delete"
                    (jetpacs-action "files.delete" :args `((file . ,path)))
                    :icon "delete"))))

(defun jetpacs-files--card-for (path)
  "A tappable card for PATH — a folder (cd) or a file (open), with an op menu."
  (if (file-directory-p path)
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "folder")
              (jetpacs-box (list (jetpacs-text (file-name-nondirectory
                                          (directory-file-name path))
                                         'body))
                        :weight 1)
              (jetpacs-files--entry-menu path)))
       :on-tap (jetpacs-action "files.cd" :args `((dir . ,path))))
    (let ((size (or (file-attribute-size (file-attributes path)) 0)))
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "description")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text (file-name-nondirectory path) 'body)
                               (jetpacs-text (file-size-human-readable size) 'caption)))
                        :weight 1)
              (jetpacs-files--entry-menu path)))
       :on-tap (jetpacs-action "files.open" :args `((file . ,path)))))))

(defun jetpacs-files--dired-cards (buffer)
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
              (when (and parent (jetpacs-files--within-root-p parent))
                (jetpacs-card
                 (list (jetpacs-row (jetpacs-icon "arrow_upward") (jetpacs-text ".." 'body)))
                 :on-tap (jetpacs-action "files.cd" :args `((dir . ,parent)))))))
        (delq nil (cons up-card
                        (mapcar #'jetpacs-files--card-for (append dirs files))))))))

;; Register the skin globally: any dired buffer — the Files view here or one
;; opened from the Buffers tab — renders as cards.  This is the single dispatch
;; seam from jetpacs-buffer.el; the Files feature owns dired's app-wide look.
(jetpacs-render-buffer-register 'dired-mode #'jetpacs-files--dired-cards)

(defun jetpacs-files--dired-buffer (dir)
  "Return a freshly-reverted dired buffer for DIR, or nil.
Refuses DIR outside `jetpacs-files-roots' or unreadable; the within-root guard
turns the Android sandbox's raw stat errors into a graceful nil."
  (when (and (stringp dir) (file-directory-p dir) (jetpacs-files--within-root-p dir))
    (condition-case nil
        (let ((buf (dired-noselect dir)))
          (with-current-buffer buf (revert-buffer nil t))
          buf)
      (error nil))))

(defun jetpacs-files--current-dir ()
  "The directory the Files view is showing — `jetpacs-files--dir' or the landing."
  (or jetpacs-files--dir (expand-file-name jetpacs-files-default-dir)))

(defun jetpacs-files-browser-body ()
  "Build the Files view: the current directory rendered as dired cards.
There is no separate roots screen — the view always shows a directory
\(`jetpacs-files--current-dir'), so it matches the Buffers-tab listing.
While content-search results exist, a re-entry card heads the list."
  (let ((buf (jetpacs-files--dired-buffer (jetpacs-files--current-dir)))
        (results-card (jetpacs-files--grep-results-card))
        (shared-card (jetpacs-files--shared-storage-card)))
    (if buf
        (apply #'jetpacs-lazy-column
               (append (and results-card (list results-card))
                       (and shared-card (list shared-card))
                       (jetpacs-render-buffer buf)))
      (jetpacs-empty-state :icon "info"
                        :title "Can't open folder"
                        :caption "Outside the allowed roots, or unreadable."))))

;; ─── Content search ──────────────────────────────────────────────────────────
;;
;; A pure-elisp recursive scan: portable (no external grep needed on the
;; host) and bounded — capped hits and files, capped file size, VCS/build
;; directories skipped, binaries (NUL early in the file) skipped.  The
;; scan starts at the directory being browsed, which is inside
;; `jetpacs-files-roots' by construction, so the root guard holds; the query
;; is matched as a literal string, never a regexp off the wire.

(defcustom jetpacs-files-grep-max-hits 200
  "Content search stops after this many matching lines."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-files-grep-max-files 2000
  "Content search stops after examining this many files.
Search from a subdirectory rather than the root to keep scans quick."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-files-grep-max-file-bytes (* 1024 1024)
  "Files larger than this are skipped by the content search."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-files-grep-exclude-dirs
  '(".git" ".hg" ".svn" "node_modules" ".gradle" "build" "dist" "target")
  "Directory names the content search never descends into."
  :type '(repeat string) :group 'jetpacs)

(defvar jetpacs-files--grep nil
  "Latest content search, or nil.
A plist (:query Q :dir D :hits ((FILE LINE TEXT) ...) :truncated BOOL).")

(defun jetpacs-files--grep-scan (dir query)
  "Search QUERY (a literal, case-insensitive) under DIR.
Returns the plist stored in `jetpacs-files--grep'; one hit per line."
  (let ((re (regexp-quote query))
        (case-fold-search t)
        (hits-left jetpacs-files-grep-max-hits)
        (files-left jetpacs-files-grep-max-files)
        hits truncated)
    (catch 'done
      (dolist (file (directory-files-recursively
                     dir "" nil
                     (lambda (d)
                       (not (member (file-name-nondirectory
                                     (directory-file-name d))
                                    jetpacs-files-grep-exclude-dirs)))))
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
                     (and size (<= size jetpacs-files-grep-max-file-bytes))))
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

(defun jetpacs-files--grep-body ()
  "The search-results view body: one tappable card per matching line.
The hits are handed to the shared results substrate as file loci
\(`jetpacs-results-set-file-loci'), so a card tap follows the locus — the
same visit path as occur/grep/xref — and arms the prev/next-match stepper
in the source view.  A tap reads the hit in context; the pencil opens it
in the editor."
  (let* ((g jetpacs-files--grep)
         (dir (plist-get g :dir))
         (hits (plist-get g :hits))
         (loci (mapcar (lambda (hit)
                         (pcase-let ((`(,file ,line ,text) hit))
                           (list :file file :line line :text text)))
                       hits)))
    (jetpacs-results-set-file-loci loci)
    (if (null hits)
        (jetpacs-empty-state :icon "manage_search" :title "No matches"
                          :caption (format "\"%s\" under %s"
                                           (plist-get g :query)
                                           (abbreviate-file-name dir)))
      (apply #'jetpacs-lazy-column
             (cons
              (jetpacs-text (format "%d matching line%s under %s%s"
                                 (length hits)
                                 (if (= (length hits) 1) "" "s")
                                 (abbreviate-file-name dir)
                                 (if (plist-get g :truncated)
                                     " — stopped early, narrow the search"
                                   ""))
                         'caption)
              (cl-loop
               for hit in hits for i from 0 collect
               (pcase-let* ((`(,file ,line ,text) hit)
                            (rel (file-relative-name file dir))
                            (subdir (file-name-directory rel)))
                 (jetpacs-card
                  (list (jetpacs-column
                         (jetpacs-row
                          (jetpacs-box
                           (list (apply #'jetpacs-column
                                        (delq nil
                                              (list
                                               (jetpacs-text (file-name-nondirectory file)
                                                          'label)
                                               (when subdir
                                                 (jetpacs-text subdir 'caption
                                                            nil nil nil 1))))))
                           :weight 1)
                          (jetpacs-text (format "L%d" line) 'caption)
                          (jetpacs-icon-button
                           "edit"
                           (jetpacs-action "files.open"
                                        :args `((file . ,file)))
                           :content-description "Open in editor"))
                         (jetpacs-rich-text
                          (list (jetpacs-span (string-trim text) :mono t)))))
                  :on-tap (jetpacs-action "results.visit"
                                       :args `((index . ,i))
                                       :when-offline "drop")))))))))

(defun jetpacs-files--grep-results-card ()
  "The re-entry card the browser shows while results exist, or nil."
  (when jetpacs-files--grep
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-icon "manage_search")
            (jetpacs-box (list (jetpacs-text
                             (format "Results: \"%s\" (%d)"
                                     (plist-get jetpacs-files--grep :query)
                                     (length (plist-get jetpacs-files--grep :hits)))
                             'body))
                      :weight 1)
            (jetpacs-icon "chevron_right")))
     :on-tap (jetpacs-shell-switch-view "grep"))))

;; ─── Editor view ─────────────────────────────────────────────────────────────

(defun jetpacs-files-editor-body ()
  "Build the editor view for `jetpacs-files--file'.
An app-registered body (see `jetpacs-files-editor-body-functions') wins;
otherwise the plain-text editor."
  (let ((file jetpacs-files--file))
    (if (not (and file (file-readable-p file)))
        (jetpacs-column (jetpacs-text "No file open." 'body))
      (or (run-hook-with-args-until-success
           'jetpacs-files-editor-body-functions file)
          (let* ((size (or (file-attribute-size (file-attributes file)) 0))
                 (read-only (> size jetpacs-files-max-bytes))
                 (content
                  ;; Prefer a live buffer's content (may have unsaved desktop
                  ;; edits); fall back to disk.
                  (if-let ((buf (get-file-buffer file)))
                      (with-current-buffer buf
                        (buffer-substring-no-properties
                         (point-min)
                         (min (point-max) (1+ jetpacs-files-max-bytes))))
                    (with-temp-buffer
                      (insert-file-contents file nil 0 jetpacs-files-max-bytes)
                      (buffer-string)))))
            (jetpacs-column
             (when read-only
               (jetpacs-text (format "File exceeds %s — opened read-only."
                                  (file-size-human-readable jetpacs-files-max-bytes))
                          'caption))
             (jetpacs-editor file content
                          :read-only read-only
                          :line-numbers (and jetpacs-line-numbers
                                             (symbol-name jetpacs-line-numbers))
                          :complete (and jetpacs-complete-enabled (not read-only))
                          :toolbar (funcall jetpacs-files-editor-toolbar-function file)
                          :on-save (jetpacs-action "files.save"
                                                :args `((file . ,file))
                                                :when-offline "queue"
                                                :dedupe (concat "save/" file)))))))))

;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun jetpacs-files--files-view (snackbar)
  "The Files tab: the current directory's cards, back arrow inside subdirs."
  (let ((grep-btn (jetpacs-icon-button
                   "manage_search"
                   (jetpacs-action "files.grep" :when-offline "drop")
                   :content-description "Search file contents")))
    (jetpacs-shell-tab-view
     "files" (jetpacs-files-browser-body)
     :top-bar (if jetpacs-files--dir
                  (jetpacs-top-bar (abbreviate-file-name jetpacs-files--dir)
                                :nav-icon "arrow_back"
                                :nav-action (jetpacs-action "files.cd"
                                                         :args '((dir . :null)))
                                :actions (list grep-btn))
                (jetpacs-shell-default-top-bar "Files"
                                            :extra-actions (list grep-btn)))
     ;; A create FAB — the view always shows a directory (the landing dir or
     ;; a subdirectory), so it's always offered.
     :fab (jetpacs-fab "add" :label "New" :on-tap (jetpacs-action "files.new"))
     :snackbar snackbar)))

(defun jetpacs-files--edit-view (snackbar)
  "The editor view for the open file, with app-contributed top-bar actions."
  (jetpacs-shell-nav-view
   (if jetpacs-files--file
       (file-name-nondirectory jetpacs-files--file)
     "Editor")
   (jetpacs-files-editor-body)
   :back-to "files"
   :actions (when jetpacs-files--file
              (apply #'append
                     (delq nil
                           (mapcar (lambda (fn) (funcall fn jetpacs-files--file))
                                   jetpacs-files-editor-actions-functions))))
   :snackbar snackbar))

(jetpacs-shell-define-view "files"
  :builder #'jetpacs-files--files-view
  :tab '(:icon "folder_open" :label "Files")
  :order 40)

(jetpacs-shell-define-view "edit"
  :builder #'jetpacs-files--edit-view
  :when (lambda () (and jetpacs-files--file t))
  :order 100)

(defun jetpacs-files--grep-view (snackbar)
  "The content-search results view; ✕ discards the results."
  (jetpacs-shell-nav-view
   (format "\"%s\"" (plist-get jetpacs-files--grep :query))
   (jetpacs-files--grep-body)
   :back-to "files"
   :actions (list (jetpacs-icon-button
                   "close"
                   (jetpacs-action "files.grep-clear" :when-offline "drop")
                   :content-description "Discard search results"))
   :snackbar snackbar))

(jetpacs-shell-define-view "grep"
  :builder #'jetpacs-files--grep-view
  :when (lambda () (and jetpacs-files--grep t))
  :order 101)

;; Leaving the editor for the files view closes the file (the next push
;; drops the edit view). Unsaved companion-side text is discarded with it.
(add-hook 'jetpacs-shell-view-switched-hook
          (lambda (view)
            (when (and (equal view "files") jetpacs-files--file)
              (setq jetpacs-files--file nil))))

(defun jetpacs-files-current-file ()
  "Absolute path of the file currently open in the editor, or nil."
  jetpacs-files--file)

(defun jetpacs-files-open (file)
  "Open FILE in the editor and switch to the editor view.
FILE must be a readable path within the browsable roots; otherwise nothing
happens and nil is returned.  On success sets the open file, runs
`jetpacs-files-open-hook' with the expanded path, switches to the editor
view, and returns that path."
  (when (and (stringp file)
             (file-readable-p file)
             (jetpacs-files--within-root-p file))
    (setq jetpacs-files--file (expand-file-name file))
    (run-hook-with-args 'jetpacs-files-open-hook jetpacs-files--file)
    (jetpacs-shell-push nil :switch-to "edit")
    jetpacs-files--file))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "files.cd"
  (lambda (args _)
    (let ((dir (alist-get 'dir args)))
      (setq jetpacs-files--dir
            (and (stringp dir)
                 (file-directory-p dir)
                 (jetpacs-files--within-root-p dir)
                 (file-name-as-directory dir)))
      (jetpacs-shell-push nil :switch-to "files"))))

(jetpacs-defaction "files.open"
  (lambda (args _)
    (jetpacs-files-open (alist-get 'file args))))

(jetpacs-defaction "files.grep"
  ;; The query arrives through the bridged minibuffer (this runs inside an
  ;; action handler), so the search icon needs no input widget of its own.
  ;; Scope is the directory being browsed — within the roots by
  ;; construction — and the scan is bounded by the grep defcustoms.
  (lambda (_ __)
    (let* ((dir (jetpacs-files--current-dir))
           (query (condition-case nil
                      (string-trim
                       (read-string (format "Search in %s for: "
                                            (abbreviate-file-name dir))))
                    (quit ""))))
      (if (string-empty-p query)
          (jetpacs-shell-push)
        (setq jetpacs-files--grep (jetpacs-files--grep-scan dir query))
        (jetpacs-shell-push nil :switch-to "grep")))))

(jetpacs-defaction "files.grep-clear"
  (lambda (_ __)
    (setq jetpacs-files--grep nil)
    (jetpacs-shell-push nil :switch-to "files")))

;; The content-search hits are visited through the shared results
;; substrate (`results.visit' by index into the file-locus set armed in
;; `jetpacs-files--grep-body'), which also arms the prev/next stepper — so
;; there is no files-specific visit action or view-region seam anymore.

(jetpacs-defaction "files.delete"
  ;; Allowlisted op: delete the one tapped path, root-guarded, after a
  ;; confirmation (the y/n dialog is bridged to the phone by jetpacs-minibuffer).
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (jetpacs-files--within-root-p file)
                 (file-exists-p file))
        (if (yes-or-no-p (format "Delete %s? "
                                 (file-name-nondirectory
                                  (directory-file-name file))))
            (condition-case err
                (progn
                  (if (file-directory-p file)
                      (delete-directory file t)
                    (delete-file file))
                  (jetpacs-shell-notify
                   (format "Deleted %s" (file-name-nondirectory
                                         (directory-file-name file)))))
              (error (jetpacs-shell-notify
                      (format "Delete failed: %s" (error-message-string err)))))
          (jetpacs-shell-notify "Delete cancelled")))
      (jetpacs-shell-push nil :switch-to "files"))))

(jetpacs-defaction "files.rename"
  ;; Allowlisted op: rename within the same directory; the new name is read
  ;; through the bridged minibuffer and the target re-checked against roots.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (jetpacs-files--within-root-p file)
                 (file-exists-p file))
        (let* ((old (file-name-nondirectory (directory-file-name file)))
               (new (read-string (format "Rename %s to: " old) old)))
          (cond
           ((or (null new) (string-empty-p (string-trim new)))
            (jetpacs-shell-notify "Rename cancelled"))
           (t
            (let ((target (expand-file-name
                           new (file-name-directory (directory-file-name file)))))
              (cond
               ((not (jetpacs-files--within-root-p target))
                (jetpacs-shell-notify "Rename rejected (outside roots)"))
               ((file-exists-p target)
                (jetpacs-shell-notify "Target already exists"))
               (t
                (condition-case err
                    (progn (rename-file file target)
                           (jetpacs-shell-notify (format "Renamed to %s" new)))
                  (error (jetpacs-shell-notify
                          (format "Rename failed: %s"
                                  (error-message-string err)))))))))))
        (jetpacs-shell-push nil :switch-to "files")))))

;; ─── New file / folder ───────────────────────────────────────────────────────

(defun jetpacs-files-show-new-dialog ()
  "Dialog to create a new file or folder in the current Files directory.
The name field's value reaches the create handlers two ways: on-submit
carries it in `value', and the Folder/File buttons read it back from UI
state (the same pattern as the capture form)."
  (let ((dir (jetpacs-files--current-dir)))
    (when dir
      (jetpacs-send-dialog
       (jetpacs-column
        (jetpacs-text "New" 'title)
        (jetpacs-text (abbreviate-file-name dir) 'caption)
        (jetpacs-text-input "files-new-name"
                         :label "Name"
                         :hint "notes.org"
                         :single-line t
                         :on-submit (jetpacs-action "files.create"
                                                 :args '((type . "file"))))
        (jetpacs-row
         (jetpacs-button "Cancel" (jetpacs-action "files.new.cancel") :variant "text")
         (jetpacs-spacer :weight 1)
         (jetpacs-button "Folder"
                      (jetpacs-action "files.create" :args '((type . "dir")))
                      :variant "outlined")
         (jetpacs-spacer :width 8)
         (jetpacs-button "File"
                      (jetpacs-action "files.create" :args '((type . "file"))))))))))

(jetpacs-defaction "files.new"
  (lambda (_ _)
    ;; Forget any leftover name so a button tap can't read a stale value
    ;; before the user types (UI state is global and persistent).
    (jetpacs-ui-state-clear "files-new-name")
    (jetpacs-files-show-new-dialog)))

(jetpacs-defaction "files.new.cancel"
  (lambda (_ _) (jetpacs-dismiss-dialog)))

(jetpacs-defaction "files.create"
  ;; Allowlisted op: create a single-segment file or folder in the current
  ;; directory, re-checked against the roots.  TYPE is "file" or "dir".
  (lambda (args _)
    (let* ((type (or (alist-get 'type args) "file"))
           (name (string-trim (or (alist-get 'value args)
                                  (jetpacs-ui-state "files-new-name")
                                  "")))
           (dir (jetpacs-files--current-dir)))
      (cond
       ((or (null dir) (not (jetpacs-files--within-root-p dir)))
        (jetpacs-shell-notify "No directory"))
       ((string-empty-p name)
        (jetpacs-shell-notify "Name required"))
       ;; Single segment only — no separators or parent traversal.
       ((string-match-p "/" name)
        (jetpacs-shell-notify "Name can't contain '/'"))
       (t
        (let ((target (expand-file-name name dir)))
          (cond
           ((not (jetpacs-files--within-root-p target))
            (jetpacs-shell-notify "Rejected (outside roots)"))
           ((file-exists-p target)
            (jetpacs-shell-notify "Already exists"))
           (t
            (condition-case err
                (progn
                  (if (equal type "dir")
                      (make-directory target)
                    (write-region "" nil target nil 'silent))
                  (jetpacs-ui-state-clear "files-new-name")
                  (jetpacs-shell-notify (format "Created %s" name)))
              (error (jetpacs-shell-notify
                      (format "Create failed: %s"
                              (error-message-string err))))))))))
      (jetpacs-dismiss-dialog)
      (jetpacs-shell-push nil :switch-to "files"))))

(jetpacs-defaction "files.save"
  ;; Saves run inside the action handler, so `jetpacs--in-action-handler' is
  ;; bound — app after-save-hook refreshers key off that to avoid doubling
  ;; the explicit push below.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (value (alist-get 'value args)))
      (cond
       ((not (and (stringp file) (stringp value)
                  (jetpacs-files--within-root-p file)))
        (jetpacs-shell-notify "Save rejected"))
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
              (run-hook-with-args 'jetpacs-files-after-save-hook file)
              (jetpacs-shell-notify
               ;; Re-loading init in a running session never applies
               ;; cleanly (defvars keep old values, hooks double up), so
               ;; the honest instruction is a restart.
               (if (and user-init-file (file-equal-p file user-init-file))
                   "Saved init — restart Emacs to apply config changes"
                 (format "Saved %s" (file-name-nondirectory file)))))
          (error
           (jetpacs-shell-notify
            (format "Save failed: %s" (error-message-string err))))))))
    (jetpacs-shell-push)))

(jetpacs-defaction "config.reload"
  ;; Retired: `load user-init-file' mid-session never applies cleanly
  ;; (defvars keep their values, hooks double-register), so the drawer
  ;; entry is gone.  The handler stays as a stub so a stale cached UI
  ;; from an older push gets the instruction instead of a dropped tap.
  (lambda (_ _)
    (jetpacs-shell-notify "Reload was removed — restart Emacs to apply config changes")
    (jetpacs-shell-push)))

(provide 'jetpacs-files)
;;; jetpacs-files.el ends here
