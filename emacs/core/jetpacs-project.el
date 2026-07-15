;;; jetpacs-project.el --- Project dashboard (core stock satellite) -*- lexical-binding: t; -*-

;; A "home base" for the current project, in the spirit of `jetpacs-tools.el':
;; almost pure glue over substrates the foundation already ships.  `project.el'
;; is usable on the phone today only by invoking raw commands through the
;; command palette; this gives it a first-class screen.
;;
;; The dashboard tracks one selected root in `jetpacs-project--current'
;; (defaulting to the ambient `project-current'); every action runs with
;; `default-directory' bound to it.  Each entry is a card that runs a built-in
;; project command and lands the result on its mode's substrate through the
;; public buffer navigator (`jetpacs-tablist-view-buffer-function'):
;;
;;   Find file     → a searchable list of `project-files' → `files.open'
;;   Grep          → `project-find-regexp' → the xref results substrate
;;   Compile       → `project-compile'     → the compilation results substrate
;;   Shell         → `project-shell'       → the comint REPL substrate
;;   Buffers       → `project-list-buffers' → the tablist substrate
;;   Version ctrl  → `magit-status' when present, else `project-vc-dir'
;;   Switch project→ pick another `project-known-project-roots' entry
;;   Databases     → the SQL hub (jetpacs-sql.el)
;;
;; Prompting commands (the grep regexp, the compile command) run *inside* the
;; action handler, so the minibuffer bridge turns their prompts into phone
;; dialogs.  Opening a project file needs `jetpacs-files-roots' to admit the
;; project tree, so selecting a project widens the sandbox to its root — the
;; same move `jetpacs-files-shared-dir' makes for /sdcard.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-tablist)   ; jetpacs-tablist-view-buffer-function — the buffer navigator
(require 'jetpacs-shell)
(require 'jetpacs-files)      ; files.open + `jetpacs-files-roots' (the sandbox we widen)
(require 'project)
(require 'xref)               ; xref-buffer-name — where project-find-regexp lands

;; Magit is an optional, app-side dependency; the VC entry falls back to the
;; built-in `project-vc-dir' when it is absent.  `magit-status-setup-buffer'
;; is the non-display entry point that returns the status buffer.
(declare-function magit-status-setup-buffer "magit-status" (&optional directory))

(defcustom jetpacs-project-find-max 200
  "Maximum project files listed at once in the Find file view.
Large trees are capped with a trailing note; the filter narrows instead
of paging."
  :type 'integer :group 'jetpacs)

;; ─── Selected project ────────────────────────────────────────────────────────

(defvar jetpacs-project--current nil
  "The selected project root (a directory string), or nil for none.")

(defvar jetpacs-project--find-filter ""
  "Current substring filter for the Find file sub-view.")

(defun jetpacs-project--root ()
  "The selected project root, defaulting to the ambient project's root.
Resolving the ambient project is memoized into `jetpacs-project--current'."
  (or jetpacs-project--current
      (when-let ((proj (ignore-errors (project-current))))
        (setq jetpacs-project--current (project-root proj)))))

(defun jetpacs-project--name (root)
  "A friendly display name for the project rooted at ROOT."
  (or (let ((default-directory root))
        (when-let ((proj (ignore-errors (project-current))))
          (ignore-errors (project-name proj))))
      (file-name-nondirectory (directory-file-name root))))

(defun jetpacs-project--same-root-p (a b)
  "Non-nil when directories A and B name the same root (no filesystem access)."
  (and a b (string= (directory-file-name (expand-file-name a))
                    (directory-file-name (expand-file-name b)))))

(defun jetpacs-project--widen-roots (root)
  "Admit ROOT into `jetpacs-files-roots' so Find file can open project files.
Mirrors `jetpacs-files-shared-dir' widening the sandbox to reach /sdcard;
keeps a single \"Project\" entry, replaced on each switch, so the guard stays
as tight as the current project."
  (when (and (stringp root) (boundp 'jetpacs-files-roots))
    (setq jetpacs-files-roots
          (cons (cons "Project" (file-name-as-directory root))
                (assoc-delete-all "Project" jetpacs-files-roots)))))

;; ─── Showing a project buffer ────────────────────────────────────────────────

(defun jetpacs-project--view-buffer-of (fn)
  "Call FN (returning a buffer or buffer name) and view the result.
Window excursion contains the pop-to-buffer these commands do; errors land
in the snackbar instead of dying silently.  (Copied from the tools wrapper.)"
  (condition-case err
      (let ((buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

(defun jetpacs-project--run (fn)
  "Call FN with `default-directory' bound to the selected project root.
When no project is selected, notify and return nil."
  (let ((root (jetpacs-project--root)))
    (if (null root)
        (jetpacs-shell-notify "No project selected")
      (let ((default-directory root))
        (funcall fn)))))

;; ─── Cards ───────────────────────────────────────────────────────────────────

(defun jetpacs-project--entry (icon title caption action)
  "A hub row: leading ICON, TITLE/CAPTION, a chevron; tap dispatches ACTION.
Built on `jetpacs-list-item', which pins the leading/trailing edges and gives
the text column the flex weight (no hand-rolled weighted box, no flex trap)."
  (jetpacs-list-item
   :leading (jetpacs-icon icon)
   :title title
   :subtitle caption
   :trailing (jetpacs-icon "chevron_right")
   :on-tap action))

(defun jetpacs-project--header (root)
  "The dashboard header: the project's name and root, or an empty state."
  (if root
      (jetpacs-card
       (list (jetpacs-column
              (jetpacs-text (jetpacs-project--name root) 'title)
              (jetpacs-text (abbreviate-file-name (directory-file-name root))
                            'caption))))
    (jetpacs-empty-state
     :icon "folder_off" :title "No project here"
     :caption "Open a file inside a project, or switch to a known one below.")))

;; ─── Dashboard view ──────────────────────────────────────────────────────────

(defun jetpacs-project--dashboard-body ()
  "The dashboard: header plus one card per project action."
  (let ((root (jetpacs-project--root)))
    (apply #'jetpacs-lazy-column
           (list
            (jetpacs-project--header root)
            (jetpacs-project--entry "search" "Find file"
                                    "Open a file from this project"
                                    (jetpacs-action "project.find-file" :when-offline "drop"))
            (jetpacs-project--entry "travel_explore" "Grep"
                                    "Search the project for a regexp"
                                    (jetpacs-action "project.grep" :when-offline "drop"))
            (jetpacs-project--entry "build" "Compile"
                                    "Run a compile command at the root"
                                    (jetpacs-action "project.compile" :when-offline "drop"))
            (jetpacs-project--entry "terminal" "Shell"
                                    "A shell rooted in the project"
                                    (jetpacs-action "project.shell" :when-offline "drop"))
            (jetpacs-project--entry "view_list" "Buffers"
                                    "Buffers belonging to this project"
                                    (jetpacs-action "project.buffers" :when-offline "drop"))
            (jetpacs-project--entry "account_tree" "Version control"
                                    "Magit, or the built-in VC directory"
                                    (jetpacs-action "project.magit" :when-offline "drop"))
            (jetpacs-project--entry "swap_horiz" "Switch project"
                                    "Pick another known project"
                                    (jetpacs-shell-switch-view "project-switch"))
            (jetpacs-project--entry "database" "Databases"
                                    "SQL connections and schema"
                                    (jetpacs-shell-switch-view "sql"))))))

(defun jetpacs-project--view (snackbar)
  (jetpacs-shell-nav-view "Project" (jetpacs-project--dashboard-body)
                          :snackbar snackbar))

;; ─── Find file sub-view ──────────────────────────────────────────────────────

(defun jetpacs-project--file-card (root file)
  "A card for FILE (absolute), shown relative to ROOT; a tap opens it."
  (let ((rel (file-relative-name file root)))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-icon "description")
            (jetpacs-box (list (jetpacs-text rel 'body nil nil nil 2)) :weight 1)))
     :on-tap (jetpacs-action "project.open-file"
                             :args `((file . ,file)) :when-offline "drop"))))

(defun jetpacs-project--find-body ()
  "The Find file body: a filter field over a capped list of `project-files'."
  (let ((root (jetpacs-project--root)))
    (if (null root)
        (jetpacs-empty-state :icon "folder_off" :title "No project selected"
                             :caption "Switch to a project first.")
      (let* ((default-directory root)
             (proj (ignore-errors (project-current nil root)))
             (files (and proj (ignore-errors (project-files proj))))
             (filter (downcase (string-trim jetpacs-project--find-filter)))
             (matches (if (string-empty-p filter)
                          files
                        (cl-remove-if-not
                         (lambda (f)
                           (string-search filter (downcase (file-relative-name f root))))
                         files)))
             (total (length matches))
             (shown (cl-subseq matches 0 (min total jetpacs-project-find-max))))
        (apply #'jetpacs-lazy-column
               (append
                (list (jetpacs-text-input "project/find"
                                          :value jetpacs-project--find-filter
                                          :label "Filter files" :single-line t
                                          :hint "type a path fragment"
                                          :on-submit (jetpacs-action "project.find-file"))
                      (jetpacs-text
                       (format "%d file%s%s" total (if (= total 1) "" "s")
                               (if (> total jetpacs-project-find-max)
                                   (format ", showing %d" jetpacs-project-find-max) ""))
                       'caption))
                (if (null shown)
                    (list (jetpacs-empty-state :icon "search"
                                               :title "No matching files"))
                  (mapcar (lambda (f) (jetpacs-project--file-card root f)) shown))))))))

(defun jetpacs-project--find-view (snackbar)
  (jetpacs-shell-nav-view "Find file" (jetpacs-project--find-body)
                          :back-to "project" :snackbar snackbar))

;; ─── Switch project sub-view ─────────────────────────────────────────────────

(defun jetpacs-project--known-roots ()
  "The remembered project roots, or nil."
  (condition-case nil (project-known-project-roots) (error nil)))

(defun jetpacs-project--switch-card (root current)
  "A card for known ROOT; CURRENT (the selected root) is marked, others switch."
  (let ((activep (jetpacs-project--same-root-p root current)))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-icon "folder")
            (jetpacs-box (list (jetpacs-column
                                (jetpacs-text (file-name-nondirectory
                                               (directory-file-name root))
                                              'label)
                                (jetpacs-text (abbreviate-file-name
                                               (directory-file-name root))
                                              'caption)))
                         :weight 1)
            (if activep
                (jetpacs-icon "check_circle" :color "primary")
              (jetpacs-icon "chevron_right"))))
     :on-tap (unless activep
               (jetpacs-action "project.switch"
                               :args `((root . ,root)) :when-offline "drop")))))

(defun jetpacs-project--switch-body ()
  (let ((roots (jetpacs-project--known-roots))
        (current (jetpacs-project--root)))
    (if (null roots)
        (jetpacs-empty-state :icon "folder_open" :title "No known projects"
                             :caption "Projects you visit are remembered here.")
      (apply #'jetpacs-lazy-column
             (mapcar (lambda (root) (jetpacs-project--switch-card root current))
                     roots)))))

(defun jetpacs-project--switch-view (snackbar)
  (jetpacs-shell-nav-view "Switch project" (jetpacs-project--switch-body)
                          :back-to "project" :snackbar snackbar))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "project.show"
  ;; Round-trip entry point (for cross-links): ensure the sandbox admits the
  ;; project, then land on the dashboard.
  (lambda (_ __)
    (jetpacs-project--widen-roots (jetpacs-project--root))
    (jetpacs-shell-push nil :switch-to "project")))

(jetpacs-defaction "project.find-file"
  ;; Opens (or refilters) the Find file view.  A submit from the filter field
  ;; arrives with the typed text as `value'; the entry card taps it bare.
  (lambda (args _)
    (jetpacs-project--widen-roots (jetpacs-project--root))
    (let ((value (alist-get 'value args)))
      (setq jetpacs-project--find-filter (if (stringp value) value "")))
    (jetpacs-shell-push nil :switch-to "project-find")))

(jetpacs-defaction "project.open-file"
  ;; Widen the sandbox to the project (defence in depth) then delegate to the
  ;; files editor, which re-checks the root guard and switches to the editor.
  (lambda (args _)
    (jetpacs-project--widen-roots (jetpacs-project--root))
    (let ((file (alist-get 'file args)))
      (unless (and (stringp file) (jetpacs-files-open file))
        (jetpacs-shell-notify "Can't open that file")))))

(jetpacs-defaction "project.grep"
  (lambda (_ __)
    (jetpacs-project--run
     (lambda ()
       (let ((regexp (condition-case nil
                         (string-trim (read-string "Grep project for (regexp): "))
                       (quit ""))))
         (if (string-empty-p regexp)
             (jetpacs-shell-push)
           (jetpacs-project--view-buffer-of
            (lambda () (project-find-regexp regexp) xref-buffer-name))))))))

(jetpacs-defaction "project.compile"
  (lambda (_ __)
    (jetpacs-project--run
     (lambda ()
       (jetpacs-project--view-buffer-of
        (lambda ()
          ;; `project-compile' is interactive-only (it reads the compile
          ;; command); drive it through `call-interactively', with
          ;; `last-input-event' cleared so no stale event hijacks the prompt.
          (let ((last-input-event nil))
            (call-interactively #'project-compile))
          "*compilation*"))))))

(jetpacs-defaction "project.shell"
  (lambda (_ __)
    (jetpacs-project--run
     (lambda ()
       (jetpacs-project--view-buffer-of #'project-shell)))))

(jetpacs-defaction "project.buffers"
  (lambda (_ __)
    (jetpacs-project--run
     (lambda ()
       (jetpacs-project--view-buffer-of
        (lambda () (project-list-buffers) "*Buffer List*"))))))

(jetpacs-defaction "project.magit"
  (lambda (_ __)
    (jetpacs-project--run
     (lambda ()
       (jetpacs-project--view-buffer-of
        (lambda ()
          (if (fboundp 'magit-status-setup-buffer)
              (magit-status-setup-buffer default-directory)
            (progn (project-vc-dir) "*vc-dir*"))))))))

(jetpacs-defaction "project.switch"
  (lambda (args _)
    (let ((root (alist-get 'root args)))
      (if (and (stringp root) (file-directory-p root))
          (progn
            (setq jetpacs-project--current (file-name-as-directory root)
                  jetpacs-project--find-filter "")
            (jetpacs-project--widen-roots jetpacs-project--current)
            (jetpacs-shell-push nil :switch-to "project"))
        (jetpacs-shell-notify (format "Not a directory: %s" (or root "?")))
        (jetpacs-shell-push)))))

;; ─── Registration ────────────────────────────────────────────────────────────

(jetpacs-shell-define-view "project" :builder #'jetpacs-project--view :order 80)
(jetpacs-shell-define-view "project-find" :builder #'jetpacs-project--find-view
                           :order 80)
(jetpacs-shell-define-view "project-switch" :builder #'jetpacs-project--switch-view
                           :order 80)

(jetpacs-shell-add-drawer-item
 30 (lambda ()
      (jetpacs-drawer-item "dashboard" "Project"
                           (jetpacs-shell-switch-view "project"))))

(provide 'jetpacs-project)
;;; jetpacs-project.el ends here
