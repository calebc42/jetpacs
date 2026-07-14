;;; jetpacs-tools.el --- Built-in Emacs tools: bookmarks, kill ring, shell, processes, timers -*- lexical-binding: t; -*-

;; Entry points for screens the substrates already cover.
;; `bookmark-bmenu-mode', `process-menu-mode' and `timer-list-mode' all
;; derive from `tabulated-list-mode', so the Tier 0.5 tablist renderer
;; draws them today — each needs only a semantic action that creates the
;; buffer and navigates the buffer view to it (the packages.show
;; pattern).  A shell entry does the same for `M-x shell', rendered by
;; the comint substrate (jetpacs-comint.el).  The kill ring is pure data —
;; no buffer at all — so it renders as its own view of cards, each with
;; a companion-local copy button (works offline, no round trip).
;;
;; One "Tools" drawer item opens a hub view of these; five separate
;; drawer entries would crowd the drawer.

;;; Code:

(require 'cl-lib)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-tablist)
(require 'jetpacs-shell)

(declare-function bookmark-maybe-load-default-file "bookmark")
(declare-function bookmark-bmenu-list "bookmark")
(declare-function bookmark-get-bookmark "bookmark")
(declare-function bookmark-jump "bookmark")

;; ─── Showing a tool buffer ───────────────────────────────────────────────────

(defun jetpacs-tools--view-buffer-of (fn)
  "Call FN (returning a buffer or buffer name) and view the result.
Window excursion contains the pop-to-buffer these commands do; errors
land in the snackbar instead of dying silently."
  (condition-case err
      (let ((buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

(jetpacs-defaction "tools.bookmarks"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda ()
       (require 'bookmark)
       (bookmark-maybe-load-default-file)
       (bookmark-bmenu-list)
       "*Bookmark List*"))))

(jetpacs-defaction "tools.processes"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda () (list-processes) "*Process List*"))))

(jetpacs-defaction "tools.timers"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda ()
       (unless (fboundp 'list-timers) (require 'timer-list))
       ;; Called as a function, so its `disabled' novice flag (which
       ;; guards the interactive command loop) does not apply.
       (list-timers)
       "*timer-list*"))))

(jetpacs-defaction "tools.shell"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda ()
       (require 'shell)
       (shell)))))

;; ─── Bookmark rows: tap = jump ───────────────────────────────────────────────

(defun jetpacs-tools--bookmark-name (id)
  "The bookmark name from a bmenu row ID (a name string or a record)."
  (cond ((stringp id) id)
        ((and (consp id) (stringp (car id))) (car id))))

(defun jetpacs-tools--bookmark-row (id entry _pos)
  "Tablist row skin for bookmark-bmenu: tapping jumps to the bookmark."
  (let ((name (jetpacs-tools--bookmark-name id)))
    (when name
      (let ((file (or (jetpacs-tablist-entry-col entry "File") "")))
        (jetpacs-card
         (list (apply #'jetpacs-column
                      (delq nil
                            (list (jetpacs-text name 'label)
                                  (unless (string-empty-p file)
                                    (jetpacs-text file 'caption))))))
         :on-tap (jetpacs-action "tools.bookmark-jump"
                              :args `((bookmark . ,name))
                              :when-offline "drop"))))))

(setf (alist-get 'bookmark-bmenu-mode jetpacs-tablist-row-functions)
      #'jetpacs-tools--bookmark-row)

(jetpacs-defaction "tools.bookmark-jump"
  ;; Validated against the bookmark alist; the jump runs inside the
  ;; action handler, so a relocation prompt (file moved) is bridged.
  ;; The whole flow sits in the condition-case — even loading the
  ;; bookmark file can signal (a corrupt file must cost a snackbar, not
  ;; the action dispatcher).
  (lambda (args _)
    (let ((name (alist-get 'bookmark args)))
      (when (stringp name)
        (condition-case err
            (progn
              (require 'bookmark)
              (bookmark-maybe-load-default-file)
              (when (bookmark-get-bookmark name t)
                (let ((target (save-window-excursion
                                (bookmark-jump name)
                                (buffer-name (current-buffer)))))
                  (funcall jetpacs-tablist-view-buffer-function target))))
          (error (jetpacs-shell-notify
                  (format "Bookmark failed: %s"
                          (error-message-string err)))))))))

;; ─── Kill ring ───────────────────────────────────────────────────────────────

(defcustom jetpacs-tools-kill-ring-max 50
  "Kill-ring entries shown in the Kill ring view."
  :type 'integer :group 'jetpacs)

(defun jetpacs-tools--kill-card (text)
  "A card for one kill: a trimmed preview plus a copy-to-phone button.
The copy is the companion-local clipboard builtin, so it works offline
and carries the full (untrimmed) text."
  (let* ((clean (substring-no-properties text))
         (preview (string-trim
                   (if (> (length clean) 500) (substring clean 0 500) clean))))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-box (list (jetpacs-text (if (string-empty-p preview) " " preview)
                                       'body nil nil t 4))
                      :weight 1)
            (jetpacs-icon-button "content_copy"
                              (jetpacs-clipboard-action clean)
                              :content-description "Copy to phone clipboard"))))))

(defun jetpacs-tools--kill-ring-body ()
  (let ((kills (cl-subseq kill-ring
                          0 (min (length kill-ring) jetpacs-tools-kill-ring-max))))
    (if (null kills)
        (jetpacs-empty-state :icon "content_paste" :title "Kill ring is empty"
                          :caption "Text killed in Emacs shows up here.")
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-text (format "%d of %d kills, newest first"
                                      (length kills) (length kill-ring))
                              'caption)
                   (mapcar #'jetpacs-tools--kill-card kills))))))

(defun jetpacs-tools--kill-ring-view (snackbar)
  (jetpacs-shell-nav-view "Kill ring" (jetpacs-tools--kill-ring-body)
                       :back-to "tools"
                       :snackbar snackbar))

;; ─── The hub view and drawer entry ───────────────────────────────────────────

(defun jetpacs-tools--entry (icon title caption action)
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-icon icon)
          (jetpacs-box (list (jetpacs-column (jetpacs-text title 'label)
                                       (jetpacs-text caption 'caption)))
                    :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap action))

(defun jetpacs-tools--view (snackbar)
  (jetpacs-shell-nav-view
   "Tools"
   (jetpacs-lazy-column
    (jetpacs-tools--entry "bookmark" "Bookmarks"
                       "Jump to saved places"
                       (jetpacs-action "tools.bookmarks" :when-offline "drop"))
    (jetpacs-tools--entry "content_paste" "Kill ring"
                       "Copy recent kills to the phone clipboard"
                       (jetpacs-shell-switch-view "kill-ring"))
    (jetpacs-tools--entry "terminal" "Shell"
                       "M-x shell, rendered as a REPL"
                       (jetpacs-action "tools.shell" :when-offline "drop"))
    (jetpacs-tools--entry "dns" "Remote hosts"
                       "Files, shells, and services over TRAMP"
                       (jetpacs-shell-switch-view "hosts"))
    (jetpacs-tools--entry "memory" "Processes"
                       "Subprocesses of this Emacs"
                       (jetpacs-action "tools.processes" :when-offline "drop"))
    (jetpacs-tools--entry "timer" "Timers"
                       "Active Emacs timers"
                       (jetpacs-action "tools.timers" :when-offline "drop")))
   :snackbar snackbar))

(jetpacs-shell-define-view "tools" :builder #'jetpacs-tools--view :order 86)
(jetpacs-shell-define-view "kill-ring" :builder #'jetpacs-tools--kill-ring-view
                        :order 87)

(jetpacs-shell-add-drawer-item
 50 (lambda ()
      (jetpacs-drawer-item "build" "Tools" (jetpacs-shell-switch-view "tools"))))

(provide 'jetpacs-tools)
;;; jetpacs-tools.el ends here
