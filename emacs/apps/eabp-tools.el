;;; eabp-tools.el --- Built-in Emacs tools: bookmarks, kill ring, shell, processes, timers -*- lexical-binding: t; -*-

;; Entry points for screens the substrates already cover.
;; `bookmark-bmenu-mode', `process-menu-mode' and `timer-list-mode' all
;; derive from `tabulated-list-mode', so the Tier 0.5 tablist renderer
;; draws them today — each needs only a semantic action that creates the
;; buffer and navigates the buffer view to it (the packages.show
;; pattern).  A shell entry does the same for `M-x shell', rendered by
;; the comint substrate (eabp-comint.el).  The kill ring is pure data —
;; no buffer at all — so it renders as its own view of cards, each with
;; a companion-local copy button (works offline, no round trip).
;;
;; One "Tools" drawer item opens a hub view of these; five separate
;; drawer entries would crowd the drawer.

;;; Code:

(require 'cl-lib)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-tablist)
(require 'eabp-shell)

(declare-function bookmark-maybe-load-default-file "bookmark")
(declare-function bookmark-bmenu-list "bookmark")
(declare-function bookmark-get-bookmark "bookmark")
(declare-function bookmark-jump "bookmark")

;; ─── Showing a tool buffer ───────────────────────────────────────────────────

(defun eabp-tools--view-buffer-of (fn)
  "Call FN (returning a buffer or buffer name) and view the result.
Window excursion contains the pop-to-buffer these commands do; errors
land in the snackbar instead of dying silently."
  (condition-case err
      (let ((buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall eabp-tablist-view-buffer-function buf)
          (eabp-shell-notify "Nothing to show")))
    (error (eabp-shell-notify (error-message-string err)))))

(eabp-defaction "tools.bookmarks"
  (lambda (_ __)
    (eabp-tools--view-buffer-of
     (lambda ()
       (require 'bookmark)
       (bookmark-maybe-load-default-file)
       (bookmark-bmenu-list)
       "*Bookmark List*"))))

(eabp-defaction "tools.processes"
  (lambda (_ __)
    (eabp-tools--view-buffer-of
     (lambda () (list-processes) "*Process List*"))))

(eabp-defaction "tools.timers"
  (lambda (_ __)
    (eabp-tools--view-buffer-of
     (lambda ()
       (unless (fboundp 'list-timers) (require 'timer-list))
       ;; Called as a function, so its `disabled' novice flag (which
       ;; guards the interactive command loop) does not apply.
       (list-timers)
       "*timer-list*"))))

(eabp-defaction "tools.shell"
  (lambda (_ __)
    (eabp-tools--view-buffer-of
     (lambda ()
       (require 'shell)
       (shell)))))

;; ─── Bookmark rows: tap = jump ───────────────────────────────────────────────

(defun eabp-tools--bookmark-name (id)
  "The bookmark name from a bmenu row ID (a name string or a record)."
  (cond ((stringp id) id)
        ((and (consp id) (stringp (car id))) (car id))))

(defun eabp-tools--bookmark-row (id entry _pos)
  "Tablist row skin for bookmark-bmenu: tapping jumps to the bookmark."
  (let ((name (eabp-tools--bookmark-name id)))
    (when name
      (let ((file (or (eabp-tablist-entry-col entry "File") "")))
        (eabp-card
         (list (apply #'eabp-column
                      (delq nil
                            (list (eabp-text name 'label)
                                  (unless (string-empty-p file)
                                    (eabp-text file 'caption))))))
         :on-tap (eabp-action "tools.bookmark-jump"
                              :args `((bookmark . ,name))
                              :when-offline "drop"))))))

(setf (alist-get 'bookmark-bmenu-mode eabp-tablist-row-functions)
      #'eabp-tools--bookmark-row)

(eabp-defaction "tools.bookmark-jump"
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
                  (funcall eabp-tablist-view-buffer-function target))))
          (error (eabp-shell-notify
                  (format "Bookmark failed: %s"
                          (error-message-string err)))))))))

;; ─── Kill ring ───────────────────────────────────────────────────────────────

(defcustom eabp-tools-kill-ring-max 50
  "Kill-ring entries shown in the Kill ring view."
  :type 'integer :group 'eabp)

(defun eabp-tools--kill-card (text)
  "A card for one kill: a trimmed preview plus a copy-to-phone button.
The copy is the companion-local clipboard builtin, so it works offline
and carries the full (untrimmed) text."
  (let* ((clean (substring-no-properties text))
         (preview (string-trim
                   (if (> (length clean) 500) (substring clean 0 500) clean))))
    (eabp-card
     (list (eabp-row
            (eabp-box (list (eabp-text (if (string-empty-p preview) " " preview)
                                       'body nil nil t 4))
                      :weight 1)
            (eabp-icon-button "content_copy"
                              (eabp-clipboard-action clean)
                              :content-description "Copy to phone clipboard"))))))

(defun eabp-tools--kill-ring-body ()
  (let ((kills (cl-subseq kill-ring
                          0 (min (length kill-ring) eabp-tools-kill-ring-max))))
    (if (null kills)
        (eabp-empty-state :icon "content_paste" :title "Kill ring is empty"
                          :caption "Text killed in Emacs shows up here.")
      (apply #'eabp-lazy-column
             (cons (eabp-text (format "%d of %d kills, newest first"
                                      (length kills) (length kill-ring))
                              'caption)
                   (mapcar #'eabp-tools--kill-card kills))))))

(defun eabp-tools--kill-ring-view (snackbar)
  (eabp-shell-nav-view "Kill ring" (eabp-tools--kill-ring-body)
                       :back-to "tools"
                       :snackbar snackbar))

;; ─── The hub view and drawer entry ───────────────────────────────────────────

(defun eabp-tools--entry (icon title caption action)
  (eabp-card
   (list (eabp-row
          (eabp-icon icon)
          (eabp-box (list (eabp-column (eabp-text title 'label)
                                       (eabp-text caption 'caption)))
                    :weight 1)
          (eabp-icon "chevron_right")))
   :on-tap action))

(defun eabp-tools--view (snackbar)
  (eabp-shell-nav-view
   "Tools"
   (eabp-lazy-column
    (eabp-tools--entry "bookmark" "Bookmarks"
                       "Jump to saved places"
                       (eabp-action "tools.bookmarks" :when-offline "drop"))
    (eabp-tools--entry "content_paste" "Kill ring"
                       "Copy recent kills to the phone clipboard"
                       (eabp-shell-switch-view "kill-ring"))
    (eabp-tools--entry "terminal" "Shell"
                       "M-x shell, rendered as a REPL"
                       (eabp-action "tools.shell" :when-offline "drop"))
    (eabp-tools--entry "memory" "Processes"
                       "Subprocesses of this Emacs"
                       (eabp-action "tools.processes" :when-offline "drop"))
    (eabp-tools--entry "timer" "Timers"
                       "Active Emacs timers"
                       (eabp-action "tools.timers" :when-offline "drop")))
   :snackbar snackbar))

(eabp-shell-define-view "tools" :builder #'eabp-tools--view :order 86)
(eabp-shell-define-view "kill-ring" :builder #'eabp-tools--kill-ring-view
                        :order 87)

(eabp-shell-add-drawer-item
 50 (lambda ()
      (eabp-drawer-item "build" "Tools" (eabp-shell-switch-view "tools"))))

(provide 'eabp-tools)
;;; eabp-tools.el ends here
