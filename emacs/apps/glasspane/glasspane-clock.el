;;; glasspane-clock.el --- org-clock chronometer notification -*- lexical-binding: t; -*-

;; Tier 1 org integration: mirrors the running org clock to the companion
;; as an ongoing chronometer notification with Clock out / Switch task
;; buttons, and re-asserts it on reconnect so the phone's cache matches
;; reality after an Emacs restart.
;;
;; This is app-layer code — the core (eabp-surfaces) knows nothing about
;; org; it only carries the `notification:org-clock' surface this module
;; pushes through the generic senders.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'org-clock)

(defun glasspane-clock-in-notification ()
  "Push the org-clock chronometer notification surface."
  (when (and (boundp 'org-clock-current-task) org-clock-current-task)
    (eabp-surface-push
     "notification:org-clock"
     (eabp-notification-spec
      :channel "clocking" :ongoing t :category "stopwatch"
      :chronometer `((base_ms . ,(truncate (* (float-time org-clock-start-time) 1000))))
      :body (list
             (eabp-text (format "Clocked in: %s" org-clock-current-task) 'title)
             (eabp-row
              (eabp-button "Clock out"
                           (eabp-action "org.clock.out" :when-offline "wake"))
              (eabp-button "Switch task"
                           (eabp-action "org.clock.switch" :when-offline "wake"))))))))

(defun glasspane-clock-out-notification ()
  "Remove the org-clock notification surface."
  (eabp-surface-remove "notification:org-clock"))

;; Closing the loop: a tap on "Clock out" arrives here as an event.action.
(eabp-defaction "org.clock.out"
                (lambda (&rest _) (when (org-clock-is-active) (org-clock-out))))
(eabp-defaction "org.clock.switch"
                ;; Placeholder: jump to the running task. Swap for a real
                ;; task-picker (e.g. org-clock-in to a recent task) when ready.
                (lambda (&rest _) (org-clock-goto)))
(eabp-defaction "org.clock.in-last"
                ;; The home-screen widget's "Clock In (Last)" button.
                (lambda (&rest _)
                  (condition-case err
                      (org-clock-in-last)
                    (error (message "EABP clock-in-last failed: %s"
                                    (error-message-string err))))))

(add-hook 'org-clock-in-hook  #'glasspane-clock-in-notification)
(add-hook 'org-clock-out-hook #'glasspane-clock-out-notification)

;; On (re)connect, re-assert current clock state so the companion's cache
;; matches reality after an Emacs restart. (Runs after the revision snapshot
;; has been absorbed — see the -50 depth in eabp-surfaces.)
(add-hook 'eabp-connected-hook
          (lambda (_welcome)
            (when (and (fboundp 'org-clock-is-active) (org-clock-is-active))
              (glasspane-clock-in-notification))))

(provide 'glasspane-clock)
;;; glasspane-clock.el ends here
