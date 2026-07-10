;;; jetpacs-automations.el --- Automations management view -*- lexical-binding: t; -*-

;; The phone-side management surface for device triggers (SPEC §11):
;; one card per registration with an enable switch (persisted through
;; Customize), the wire fields at a glance, the last-fired time, and a
;; "Fire now" test button.  Pure rendering — the registry, the actions
;; (`trigger.toggle' / `trigger.test'), and the persistence live in
;; jetpacs-triggers.el; authoring stays in elisp (`jetpacs-deftrigger'
;; in your init).  Rule layers on top are app territory (the glasspane
;; repo's glasspane-automations.el reads them from org files).
;;
;; Deliberately NOT an `jetpacs-defapp': that would flip the launcher into
;; multi-app mode for everyone.  It is a satellite screen behind a
;; settings link, per the drawer contract.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-triggers)
(require 'jetpacs-settings)

(defun jetpacs-automations--summary (reg)
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

(defun jetpacs-automations--last-fired (id)
  "Human line for ID's most recent fire, or a quiet placeholder."
  (if-let ((at (gethash id jetpacs-triggers--last-fired)))
      (format-time-string "Last fired %b %e %H:%M" at)
    "Never fired"))

(defun jetpacs-automations--card (id reg)
  "The management card for trigger ID."
  (let ((enabled (jetpacs-trigger-enabled-p id)))
    (jetpacs-card
     (list
      (jetpacs-column
       (jetpacs-row
        (jetpacs-box (list (jetpacs-text id 'title)) :weight 1)
        (jetpacs-switch (concat "trigger-enabled/" id)
                     :checked enabled
                     :on-change (jetpacs-action "trigger.toggle"
                                             :args `((id . ,id))
                                             :when-offline "drop")))
       (jetpacs-text (jetpacs-automations--summary reg) 'caption)
       (jetpacs-row
        (jetpacs-box (list (jetpacs-text (jetpacs-automations--last-fired id)
                                   'caption))
                  :weight 1)
        (jetpacs-button "Fire now"
                     (jetpacs-action "trigger.test"
                                  :args `((id . ,id))
                                  :when-offline "drop")
                     :variant "text"
                     :icon "play_arrow")))))))

(defun jetpacs-automations--view (snackbar)
  "The Automations screen: every registered trigger, or an empty state."
  (jetpacs-shell-nav-view
   "Automations"
   (if (zerop (hash-table-count jetpacs-triggers--table))
       (jetpacs-empty-state
        :icon "bolt" :title "No automations"
        :caption (concat "Define device triggers with jetpacs-deftrigger "
                         "in your init, then manage them here"))
     (apply #'jetpacs-lazy-column
            (mapcar (lambda (id)
                      (jetpacs-automations--card
                       id (gethash id jetpacs-triggers--table)))
                    (sort (hash-table-keys jetpacs-triggers--table)
                          #'string<))))
   :snackbar snackbar))

(jetpacs-shell-define-view "automations"
                        :builder #'jetpacs-automations--view :order 83)

;; Entry point: a card in the settings screen's Emacs section (a
;; companion-local view switch, so it opens offline too).
(jetpacs-settings-add-link
 15 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "bolt")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Automations" 'label)
                               (jetpacs-text "Device triggers: enable, test, inspect"
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-shell-switch-view "automations"))))

;; Registry changes (a toggle from the phone, a deftrigger evaluated on
;; a live session) re-render this view.  Debounced: an automations
;; reload fires this hook once per rule, and one idle push after the
;; burst beats a full view rebuild per rule (the scheduler no-ops
;; while disconnected).
(defun jetpacs-automations--on-change ()
  (jetpacs-shell--schedule-repush))

(add-hook 'jetpacs-triggers-changed-hook #'jetpacs-automations--on-change)

(provide 'jetpacs-automations)
;;; jetpacs-automations.el ends here
