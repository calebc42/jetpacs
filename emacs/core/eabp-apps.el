;;; eabp-apps.el --- App identity over the shell: eabp-defapp + launcher home -*- lexical-binding: t; -*-

;; Groups shell views into named apps, AppSheet-style: a launcher home
;; grid of app cards, one app's tabs in the bottom bar at a time, and an
;; `app.open' action that switches between them.  Pure shell logic — no
;; wire changes beyond the `app.*' action namespace reserved in SPEC §5.
;;
;; The single-app contract: with zero or one `eabp-defapp' registered,
;; NOTHING changes — every view shows, no home screen, no drawer entry.
;; The launcher machinery appears with the second app (AppSheet boots
;; straight into a lone app the same way).
;;
;; Views not claimed by any app (the core Files / Eval / Tools tabs)
;; show in every app.  To contain them instead, claim them in an
;; explicit app of their own:
;;   (eabp-defapp "system" :label "Emacs" :icon "terminal"
;;                :views '("files" "eval" "tools") :order 900)

;;; Code:

(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)

;; ─── Registry ────────────────────────────────────────────────────────────────

(defvar eabp-apps--registry nil
  "Ordered list of (ID . PLIST) registered apps.
PLIST keys: :label :icon :views (list of shell view names) :order.")

(defvar eabp-apps--current nil
  "Id of the app whose views are currently shown, or nil for the first.")

(cl-defun eabp-defapp (id &key label icon views (order 100))
  "Register (or replace) app ID grouping VIEWS (shell view names).
LABEL and ICON draw the app's launcher-home card; the first :tab view
in VIEWS is the app's landing tab.  ORDER sorts home cards; equal
orders keep registration order."
  ;; Attribute the app's views to it in the ownership registry, so
  ;; cross-app collisions are caught (`eabp--claim' warns, or errors under
  ;; `eabp-strict-namespaces') and `eabp-app-unregister' can find them
  ;; (see with-eabp-owner / eabp--claim in eabp-surfaces.el).
  (let ((eabp-current-owner id))
    (dolist (v views) (eabp--claim "view" v)))
  (setq eabp-apps--registry
        (sort (append (assoc-delete-all id eabp-apps--registry)
                      (list (cons id (list :label (or label (capitalize id))
                                           :icon (or icon "apps")
                                           :views views :order order))))
              (lambda (a b) (< (plist-get (cdr a) :order)
                               (plist-get (cdr b) :order)))))
  (eabp-shell--schedule-repush)
  id)

(defun eabp-apps-remove (id)
  "Unregister app ID (its views fall back to showing everywhere)."
  (setq eabp-apps--registry (assoc-delete-all id eabp-apps--registry))
  (eabp-shell--schedule-repush))

(defun eabp-app-unregister (id)
  "Tear down everything owned by app ID: its actions, views, and settings.
Removes the registrations attributed to ID (through `with-eabp-owner' /
`eabp-defapp'), drops their ownership records, clears UI-state keyed
under the app's id prefix, and removes the app from the launcher.  For
clean live reload and genuine uninstall — no stale handlers accumulate.
Registrations a Tier 1 made without an owner are not tracked and are not
torn down (wrap them in `with-eabp-owner' to make them removable)."
  (dolist (name (eabp--owned-names "action" id))
    (remhash name eabp-action-handlers)
    (eabp--unclaim "action" name))
  (dolist (name (eabp--owned-names "view" id))
    (eabp-shell-remove-view name)
    (eabp--unclaim "view" name))
  (dolist (title (eabp--owned-names "settings" id))
    (when (fboundp 'eabp-settings-remove-section)
      (eabp-settings-remove-section title))
    (eabp--unclaim "settings" title))
  ;; Drop UI-state and its subscriptions keyed under the app's id prefix.
  (eabp-ui-state-clear (concat id "."))
  (eabp-on-state-change-clear (concat id "."))
  (eabp-apps-remove id)
  (eabp-shell--schedule-repush)
  id)

(defun eabp-apps--owner (view-name)
  "The id of the app claiming VIEW-NAME, or nil when unclaimed."
  (car (cl-find-if (lambda (e) (member view-name (plist-get (cdr e) :views)))
                   eabp-apps--registry)))

(defun eabp-apps--multi-p ()
  "Non-nil once a second app is registered — the launcher trigger."
  (> (length eabp-apps--registry) 1))

(defun eabp-apps-current ()
  "The current app id, defaulting to the first registered app."
  (if (assoc eabp-apps--current eabp-apps--registry)
      eabp-apps--current
    (caar eabp-apps--registry)))

(defun eabp-apps--landing-tab (id)
  "The view app ID lands on: its first :tab view, else its first view."
  (let ((views (plist-get (cdr (assoc id eabp-apps--registry)) :views)))
    (or (cl-find-if #'eabp-shell--tab-p views) (car views))))

;; ─── The shell filter (the whole gating mechanism) ───────────────────────────

(defun eabp-apps--view-visible-p (name)
  "Single-app: everything shows.  Multi-app: the current app's views
plus every unclaimed view (core tabs, the home grid itself)."
  (or (not (eabp-apps--multi-p))
      (let ((owner (eabp-apps--owner name)))
        (or (null owner)
            (equal owner (eabp-apps-current))))))

(setq eabp-shell-view-filter-function #'eabp-apps--view-visible-p)

;; ─── The launcher home ───────────────────────────────────────────────────────

(defun eabp-apps--card (id plist)
  "The home-grid card for app ID."
  (eabp-card
   (list (eabp-box
          (list (eabp-column
                 (eabp-icon (plist-get plist :icon) :size 40)
                 (eabp-spacer :height 8)
                 (eabp-text (plist-get plist :label) 'title)))
          :alignment "center" :padding 16))
   :on-tap (eabp-action "app.open" :args `((app . ,id))
                        :when-offline "drop")))

(defun eabp-apps--home-view (snackbar)
  "The launcher home: a grid of app cards."
  (eabp-shell-nav-view
   "Apps"
   (apply #'eabp-flow-row
          (mapcar (lambda (e) (eabp-apps--card (car e) (cdr e)))
                  eabp-apps--registry))
   :snackbar snackbar))

(eabp-shell-define-view "home"
  :builder #'eabp-apps--home-view
  :when #'eabp-apps--multi-p
  :order 1)

;; Everyday nav: the Apps entry rides the drawer, but only exists once
;; there is more than one app (the drawer contract: no dead entries).
(eabp-shell-add-drawer-item
 5 (lambda ()
     (when (eabp-apps--multi-p)
       (eabp-drawer-item "apps" "Apps" (eabp-shell-switch-view "home")))))

;; ─── Wire action ─────────────────────────────────────────────────────────────

(eabp-defaction "app.open"
  (lambda (args _)
    (let ((app (alist-get 'app args)))
      (if (not (assoc app eabp-apps--registry))
          (message "EABP apps: unknown app %s" app)
        (setq eabp-apps--current app)
        (let ((tab (eabp-apps--landing-tab app)))
          (if tab
              (eabp-shell-push tab :switch-to tab)
            (eabp-shell-push)))))))

(provide 'eabp-apps)
;;; eabp-apps.el ends here
