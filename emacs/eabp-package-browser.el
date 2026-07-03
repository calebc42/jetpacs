;;; eabp-package-browser.el --- Package browser skin for the tablist renderer -*- lexical-binding: t; -*-

;; The first Tier 1 tablist skin, and the worked example of the pattern:
;; package-menu-mode derives from tabulated-list-mode, so the generic walk
;; in eabp-tablist.el is reused; this file only registers the three skin
;; hooks (header, row, filter) plus its curated actions.
;;
;; It adds search + status chips, install/delete per row, and archive
;; refresh / upgrade-all — the actions validate package names against the
;; archive/installed lists, keeping the wire semantic (see the
;; command-dispatch boundary: nothing on the wire names arbitrary code).

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-tablist)
(require 'eabp-shell)

(defvar eabp-pkg--search ""
  "Current package search string (matches name and summary).")

(defvar eabp-pkg--status "all"
  "Current package status filter chip.")

(defconst eabp-pkg--statuses
  '(("all")
    ("installed" "installed" "dependency" "unsigned" "external" "held")
    ("available" "available" "new")
    ("built-in" "built-in")
    ("upgradable" "obsolete"))
  "Chip name -> package-menu status strings it admits.")

(defun eabp-pkg--toast (text)
  (eabp-send "toast.show" `((text . ,text))))

(defun eabp-pkg--filter (id entry)
  "Keep package row (ID ENTRY) when it matches the search and status chips."
  (let ((statuses (cdr (assoc eabp-pkg--status eabp-pkg--statuses)))
        (status (or (eabp-tablist-entry-col entry "Status") ""))
        (hay (concat (eabp-tablist-col-string (aref entry 0)) " "
                     (and (package-desc-p id)
                          (or (package-desc-summary id) "")))))
    (and (or (null statuses) (member status statuses))
         (or (string-empty-p eabp-pkg--search)
             (string-match-p (regexp-quote eabp-pkg--search)
                             (downcase hay))))))

(defun eabp-pkg--header (_buf)
  (list
   (eabp-text-input "pkg-search"
                    :value eabp-pkg--search
                    :label "Search packages" :single-line t
                    :on-submit (eabp-action "packages.search"))
   (apply #'eabp-flow-row
          (mapcar (lambda (chip)
                    (let ((s (car chip)))
                      (eabp-chip (capitalize s)
                                 :selected (equal eabp-pkg--status s)
                                 :on-tap (eabp-action
                                          "packages.status-filter"
                                          :args `((status . ,s))
                                          :when-offline "drop"))))
                  eabp-pkg--statuses))
   (eabp-row
    (eabp-button "Refresh archives"
                 (eabp-action "packages.refresh-archives" :when-offline "drop")
                 :variant "text")
    (eabp-spacer :weight 1)
    (when (fboundp 'package-upgrade-all)
      (eabp-button "Upgrade all"
                   (eabp-action "packages.upgrade-all" :when-offline "drop")
                   :variant "text")))))

(defun eabp-pkg--row (id entry _pos)
  (when (package-desc-p id)
    (let* ((sym (package-desc-name id))
           (name (symbol-name sym))
           (version (or (eabp-tablist-entry-col entry "Version") ""))
           (status (or (eabp-tablist-entry-col entry "Status") ""))
           (summary (or (package-desc-summary id) ""))
           (installed (assq sym package-alist)))
      (eabp-card
       (list
        (eabp-row
         (eabp-box
          (list (eabp-column
                 (eabp-row (eabp-text name 'label)
                           (eabp-text version 'caption)
                           (eabp-text status 'caption))
                 (eabp-text summary 'caption)))
          :weight 1)
         (cond
          (installed
           (eabp-icon-button "delete"
                             (eabp-action "packages.delete"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Uninstall %s" name)))
          ((not (equal status "built-in"))
           (eabp-icon-button "arrow_downward"
                             (eabp-action "packages.install"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Install %s" name))))))
       :on-tap (eabp-action "packages.describe"
                            :args `((package . ,name))
                            :when-offline "drop")))))

(setf (alist-get 'package-menu-mode eabp-tablist-header-functions)
      #'eabp-pkg--header)
(setf (alist-get 'package-menu-mode eabp-tablist-row-functions)
      #'eabp-pkg--row)
(setf (alist-get 'package-menu-mode eabp-tablist-filter-functions)
      #'eabp-pkg--filter)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun eabp-pkg--buffer ()
  "The live *Packages* menu buffer, creating (without fetching) if needed."
  (require 'package)
  (unless package--initialized (package-initialize))
  (or (get-buffer "*Packages*")
      (save-window-excursion
        (list-packages t)
        (get-buffer "*Packages*"))))

(defun eabp-pkg--revert ()
  "Re-generate the package menu after an install/delete and re-push."
  (let ((buf (get-buffer "*Packages*")))
    (when buf
      (with-current-buffer buf
        (ignore-errors (revert-buffer)))))
  (eabp-tablist-refresh-view))

(eabp-defaction "packages.show"
  (lambda (_ __)
    (let ((buf (eabp-pkg--buffer)))
      (when (and buf (null package-archive-contents))
        (eabp-pkg--toast
         "Archives not fetched yet - tap Refresh archives"))
      (funcall eabp-tablist-view-buffer-function (buffer-name buf)))))

(eabp-defaction "packages.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq eabp-pkg--search
            (downcase (or (and (stringp q) q) "")))
      (eabp-tablist-refresh-view))))

(eabp-defaction "packages.status-filter"
  (lambda (args _)
    (let ((s (alist-get 'status args)))
      (when (assoc s eabp-pkg--statuses)
        (setq eabp-pkg--status s)
        (eabp-tablist-refresh-view)))))

(eabp-defaction "packages.install"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (assq sym package-archive-contents)))
          (eabp-pkg--toast (format "%s is not in the archives" name))
        (eabp-pkg--toast (format "Installing %s…" name))
        (condition-case err
            (progn
              (package-install sym)
              (eabp-pkg--toast (format "Installed %s" name)))
          (error (eabp-pkg--toast
                  (format "Install failed: %s" (error-message-string err)))))
        (eabp-pkg--revert)))))

(eabp-defaction "packages.delete"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name)))
           (desc (and sym (cadr (assq sym package-alist)))))
      (if (not desc)
          (eabp-pkg--toast (format "%s is not installed" name))
        (condition-case err
            (progn
              (package-delete desc)
              (eabp-pkg--toast (format "Deleted %s" name)))
          (error (eabp-pkg--toast
                  ;; Typically: something still depends on it.
                  (format "Delete failed: %s" (error-message-string err)))))
        (eabp-pkg--revert)))))

(eabp-defaction "packages.refresh-archives"
  (lambda (_ __)
    (eabp-pkg--toast "Refreshing package archives…")
    (condition-case err
        (progn
          (require 'package)
          (unless package--initialized (package-initialize))
          (package-refresh-contents)
          (eabp-pkg--toast "Archives refreshed"))
      (error (eabp-pkg--toast
              (format "Refresh failed: %s" (error-message-string err)))))
    (eabp-pkg--revert)))

(eabp-defaction "packages.upgrade-all"
  (lambda (_ __)
    (if (not (fboundp 'package-upgrade-all))
        (eabp-pkg--toast "Upgrade-all needs Emacs 29+")
      (eabp-pkg--toast "Upgrading all packages…")
      (condition-case err
          (progn
            (package-upgrade-all nil)
            (eabp-pkg--toast "Upgrades complete"))
        (error (eabp-pkg--toast
                (format "Upgrade failed: %s" (error-message-string err)))))
      (eabp-pkg--revert))))

(eabp-defaction "packages.describe"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym
                 (or (assq sym package-archive-contents)
                     (assq sym package-alist)
                     (assq sym package--builtins)))
        (save-window-excursion (describe-package sym))
        (funcall eabp-tablist-view-buffer-function "*Help*")))))

;; The browser's drawer entry in the shell.
(eabp-shell-add-drawer-item
 40 (lambda ()
      (eabp-drawer-item "archive" "Packages"
                        (eabp-action "packages.show" :when-offline "drop"))))

(provide 'eabp-package-browser)
;;; eabp-package-browser.el ends here
