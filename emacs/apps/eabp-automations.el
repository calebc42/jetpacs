;;; eabp-automations.el --- Automations management view -*- lexical-binding: t; -*-

;; The phone-side management surface for device triggers (SPEC §11):
;; one card per registration with an enable switch (persisted through
;; Customize), the wire fields at a glance, the last-fired time, and a
;; "Fire now" test button.  Pure rendering — the registry, the actions
;; (`trigger.toggle' / `trigger.test'), and the persistence live in
;; core eabp-triggers.el; authoring stays in elisp (`eabp-deftrigger'
;; in your init).  Org-file-defined rules are the next layer
;; (glasspane-automations, plan Task 13).
;;
;; Deliberately NOT an `eabp-defapp': that would flip the launcher into
;; multi-app mode for everyone.  It is a satellite screen behind a
;; settings link, per the drawer contract.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)
(require 'eabp-triggers)
(require 'eabp-settings)

(defun eabp-automations--summary (reg)
  "One-line wire summary of registration plist REG."
  (let ((params (plist-get reg :params)))
    (string-join
     (delq nil
           (list (plist-get reg :type)
                 (when params
                   (mapconcat (lambda (kv)
                                (format "%s=%s" (car kv) (cdr kv)))
                              params " "))
                 (format "policy %s" (or (plist-get reg :policy) "queue"))
                 (when-let ((throttle (plist-get reg :throttle-s)))
                   (format "throttle %ss" throttle))
                 (when (plist-get reg :on-fire) "on-fire")))
     " · ")))

(defun eabp-automations--last-fired (id)
  "Human line for ID's most recent fire, or a quiet placeholder."
  (if-let ((at (gethash id eabp-triggers--last-fired)))
      (format-time-string "Last fired %b %e %H:%M" at)
    "Never fired"))

(defun eabp-automations--card (id reg)
  "The management card for trigger ID."
  (let ((enabled (eabp-trigger-enabled-p id)))
    (eabp-card
     (list
      (eabp-column
       (eabp-row
        (eabp-box (list (eabp-text id 'title)) :weight 1)
        (eabp-switch (concat "trigger-enabled/" id)
                     :checked enabled
                     :on-change (eabp-action "trigger.toggle"
                                             :args `((id . ,id))
                                             :when-offline "drop")))
       (eabp-text (eabp-automations--summary reg) 'caption)
       (eabp-row
        (eabp-box (list (eabp-text (eabp-automations--last-fired id)
                                   'caption))
                  :weight 1)
        (eabp-button "Fire now"
                     (eabp-action "trigger.test"
                                  :args `((id . ,id))
                                  :when-offline "drop")
                     :variant "text"
                     :icon "play_arrow")))))))

(defun eabp-automations--view (snackbar)
  "The Automations screen: every registered trigger, or an empty state."
  (eabp-shell-nav-view
   "Automations"
   (if (zerop (hash-table-count eabp-triggers--table))
       (eabp-empty-state
        :icon "bolt" :title "No automations"
        :caption (concat "Define device triggers with eabp-deftrigger "
                         "in your init, then manage them here"))
     (apply #'eabp-lazy-column
            (mapcar (lambda (id)
                      (eabp-automations--card
                       id (gethash id eabp-triggers--table)))
                    (sort (hash-table-keys eabp-triggers--table)
                          #'string<))))
   :snackbar snackbar))

(eabp-shell-define-view "automations"
                        :builder #'eabp-automations--view :order 83)

;; Entry point: a card in the settings screen's Emacs section (a
;; companion-local view switch, so it opens offline too).
(eabp-settings-add-link
 15 (lambda ()
      (eabp-card
       (list (eabp-row
              (eabp-icon "bolt")
              (eabp-box (list (eabp-column
                               (eabp-text "Automations" 'label)
                               (eabp-text "Device triggers: enable, test, inspect"
                                          'caption)))
                        :weight 1)
              (eabp-icon "chevron_right")))
       :on-tap (eabp-shell-switch-view "automations"))))

;; Registry changes (a toggle from the phone, a deftrigger evaluated on
;; a live session) re-render this view via the standard shell push.
(defun eabp-automations--on-change ()
  (when (eabp-connected-p)
    (eabp-shell-push)))

(add-hook 'eabp-triggers-changed-hook #'eabp-automations--on-change)

(provide 'eabp-automations)
;;; eabp-automations.el ends here
