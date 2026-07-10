;;; jetpacs-package-browser.el --- Package browser skin for the tablist renderer -*- lexical-binding: t; -*-

;; The stock tablist skin, and the worked example of the pattern:
;; package-menu-mode derives from tabulated-list-mode, so the generic walk
;; in jetpacs-tablist.el is reused; this file only registers the three skin
;; hooks (header, row, filter) plus its curated actions.  A Tier-1 skin in
;; shape, it ships in the core because package management, like Settings,
;; is chrome every app's user needs.
;;
;; It adds search + status chips, install/delete per row, and archive
;; refresh / upgrade-all — the actions validate package names against the
;; archive/installed lists, keeping the wire semantic (see the
;; command-dispatch boundary: nothing on the wire names arbitrary code).

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-tablist)
(require 'jetpacs-settings)
(require 'jetpacs-shell)

(defvar jetpacs-pkg--search ""
  "Current package search string (matches name and summary).")

(defvar jetpacs-pkg--status "all"
  "Current package status filter chip.")

(defconst jetpacs-pkg--statuses
  '(("all")
    ("installed" "installed" "dependency" "unsigned" "external" "held")
    ("available" "available" "new")
    ("built-in" "built-in")
    ("upgradable" "obsolete"))
  "Chip name -> package-menu status strings it admits.")

(defun jetpacs-pkg--toast (text)
  (jetpacs-send "toast.show" `((text . ,text))))

(defun jetpacs-pkg--filter (id entry)
  "Keep package row (ID ENTRY) when it matches the search and status chips."
  (let ((statuses (cdr (assoc jetpacs-pkg--status jetpacs-pkg--statuses)))
        (status (or (jetpacs-tablist-entry-col entry "Status") ""))
        (hay (concat (jetpacs-tablist-col-string (aref entry 0)) " "
                     (and (package-desc-p id)
                          (or (package-desc-summary id) "")))))
    (and (or (null statuses) (member status statuses))
         (or (string-empty-p jetpacs-pkg--search)
             (string-match-p (regexp-quote jetpacs-pkg--search)
                             (downcase hay))))))

(defun jetpacs-pkg--header (_buf)
  (list
   (jetpacs-text-input "pkg-search"
                    :value jetpacs-pkg--search
                    :label "Search packages" :single-line t
                    :on-submit (jetpacs-action "packages.search"))
   (apply #'jetpacs-flow-row
          (mapcar (lambda (chip)
                    (let ((s (car chip)))
                      (jetpacs-chip (capitalize s)
                                 :selected (equal jetpacs-pkg--status s)
                                 :on-tap (jetpacs-action
                                          "packages.status-filter"
                                          :args `((status . ,s))
                                          :when-offline "drop"))))
                  jetpacs-pkg--statuses))
   (jetpacs-row
    (jetpacs-button "Refresh archives"
                 (jetpacs-action "packages.refresh-archives" :when-offline "drop")
                 :variant "text")
    (jetpacs-spacer :weight 1)
    (when (fboundp 'package-upgrade-all)
      (jetpacs-button "Upgrade all"
                   (jetpacs-action "packages.upgrade-all" :when-offline "drop")
                   :variant "text")))))

(defun jetpacs-pkg--row (id entry _pos)
  (when (package-desc-p id)
    (let* ((sym (package-desc-name id))
           (name (symbol-name sym))
           (version (or (jetpacs-tablist-entry-col entry "Version") ""))
           (status (or (jetpacs-tablist-entry-col entry "Status") ""))
           (summary (or (package-desc-summary id) ""))
           (installed (assq sym package-alist)))
      (jetpacs-card
       (list
        (jetpacs-row
         (jetpacs-box
          (list (jetpacs-column
                 (jetpacs-row (jetpacs-text name 'label)
                           (jetpacs-text version 'caption)
                           (jetpacs-text status 'caption))
                 (jetpacs-text summary 'caption)))
          :weight 1)
         (cond
          (installed
           (jetpacs-icon-button "delete"
                             (jetpacs-action "packages.delete"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Uninstall %s" name)))
          ((not (equal status "built-in"))
           (jetpacs-icon-button "arrow_downward"
                             (jetpacs-action "packages.install"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Install %s" name))))))
       :on-tap (jetpacs-action "packages.describe"
                            :args `((package . ,name))
                            :when-offline "drop")))))

(setf (alist-get 'package-menu-mode jetpacs-tablist-header-functions)
      #'jetpacs-pkg--header)
(setf (alist-get 'package-menu-mode jetpacs-tablist-row-functions)
      #'jetpacs-pkg--row)
(setf (alist-get 'package-menu-mode jetpacs-tablist-filter-functions)
      #'jetpacs-pkg--filter)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun jetpacs-pkg--buffer ()
  "The live *Packages* menu buffer, creating (without fetching) if needed."
  (require 'package)
  (unless package--initialized (package-initialize))
  (or (get-buffer "*Packages*")
      (save-window-excursion
        (list-packages t)
        (get-buffer "*Packages*"))))

(defun jetpacs-pkg--revert ()
  "Re-generate the package menu after an install/delete and re-push."
  (let ((buf (get-buffer "*Packages*")))
    (when buf
      (with-current-buffer buf
        (ignore-errors (revert-buffer)))))
  (jetpacs-tablist-refresh-view))

(jetpacs-defaction "packages.show"
  (lambda (_ __)
    (let ((buf (jetpacs-pkg--buffer)))
      (when (and buf (null package-archive-contents))
        (jetpacs-pkg--toast
         "Archives not fetched yet - tap Refresh archives"))
      (funcall jetpacs-tablist-view-buffer-function (buffer-name buf)))))

(jetpacs-defaction "packages.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq jetpacs-pkg--search
            (downcase (or (and (stringp q) q) "")))
      (jetpacs-tablist-refresh-view))))

(jetpacs-defaction "packages.status-filter"
  (lambda (args _)
    (let ((s (alist-get 'status args)))
      (when (assoc s jetpacs-pkg--statuses)
        (setq jetpacs-pkg--status s)
        (jetpacs-tablist-refresh-view)))))

(jetpacs-defaction "packages.install"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (assq sym package-archive-contents)))
          (jetpacs-pkg--toast (format "%s is not in the archives" name))
        (jetpacs-pkg--toast (format "Installing %s…" name))
        (condition-case err
            (progn
              (package-install sym)
              (jetpacs-pkg--toast (format "Installed %s" name)))
          (error (jetpacs-pkg--toast
                  (format "Install failed: %s" (error-message-string err)))))
        (jetpacs-pkg--revert)))))

(jetpacs-defaction "packages.delete"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name)))
           (desc (and sym (cadr (assq sym package-alist)))))
      (if (not desc)
          (jetpacs-pkg--toast (format "%s is not installed" name))
        (condition-case err
            (progn
              (package-delete desc)
              (jetpacs-pkg--toast (format "Deleted %s" name)))
          (error (jetpacs-pkg--toast
                  ;; Typically: something still depends on it.
                  (format "Delete failed: %s" (error-message-string err)))))
        (jetpacs-pkg--revert)))))

(jetpacs-defaction "packages.refresh-archives"
  (lambda (_ __)
    (jetpacs-pkg--toast "Refreshing package archives…")
    (condition-case err
        (progn
          (require 'package)
          (unless package--initialized (package-initialize))
          (package-refresh-contents)
          (jetpacs-pkg--toast "Archives refreshed"))
      (error (jetpacs-pkg--toast
              (format "Refresh failed: %s" (error-message-string err)))))
    (jetpacs-pkg--revert)))

(jetpacs-defaction "packages.upgrade-all"
  (lambda (_ __)
    (if (not (fboundp 'package-upgrade-all))
        (jetpacs-pkg--toast "Upgrade-all needs Emacs 29+")
      (jetpacs-pkg--toast "Upgrading all packages…")
      (condition-case err
          (progn
            (package-upgrade-all nil)
            (jetpacs-pkg--toast "Upgrades complete"))
        (error (jetpacs-pkg--toast
                (format "Upgrade failed: %s" (error-message-string err)))))
      (jetpacs-pkg--revert))))

(jetpacs-defaction "packages.describe"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym
                 (or (assq sym package-archive-contents)
                     (assq sym package-alist)
                     (assq sym package--builtins)))
        (save-window-excursion (describe-package sym))
        (funcall jetpacs-tablist-view-buffer-function "*Help*")))))

;; The browser's entry point: a card in the settings screen's Emacs
;; section (drawer slots stay reserved for everyday navigation).
(jetpacs-settings-add-link
 10 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "archive")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Packages" 'label)
                               (jetpacs-text "Install and manage Emacs packages"
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-action "packages.show" :when-offline "drop"))))

(provide 'jetpacs-package-browser)
;;; jetpacs-package-browser.el ends here
