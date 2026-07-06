;;; eabp-device.el --- Device effectors via capability.invoke -*- lexical-binding: t; -*-

;; The Emacs face of SPEC §10's capability catalog: one thin defun per
;; device capability, all funneling through `eabp-device--invoke'.  The
;; companion is the validator — these wrappers only shape plain-data
;; args; unknown or refused capabilities come back as typed errors
;; (`cap-unsupported' / `cap-permission' / `cap-failed') which the
;; default callback surfaces in *Messages*.
;;
;; Check `eabp-device-cap-p' / `eabp-device-can-p' (eabp.el) to degrade
;; gracefully in UI; from the REPL just call and read the echo area.

;;; Code:

(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)

(defun eabp-device--invoke (cap args &optional callback)
  "Invoke device capability CAP with plain-data alist ARGS.
CALLBACK as in `eabp-capability-invoke'; when nil, failures surface
in *Messages* with their typed code."
  (eabp-capability-invoke
   cap args
   (or callback
       (lambda (ok payload)
         (unless ok
           (message "EABP device %s: %s [%s]" cap
                    (alist-get 'detail payload)
                    (alist-get 'code payload)))))))

;; ─── Intents: the universal escape hatch ─────────────────────────────────────

(cl-defun eabp-device-intent (&key action data package class-name mime
                                   extras (mode "activity"))
  "Fire an Android Intent on the companion (SPEC §10 `intent.start').
ACTION is an intent action string; DATA a URI; PACKAGE / CLASS-NAME
target an explicit component; MIME sets the type; EXTRAS is an alist
of plain data (strings, numbers, booleans — pass :false for false).
MODE is \"activity\" (default), \"broadcast\", or \"service\".
Activity launches are best-effort while the companion is backgrounded.

Example, from the eval REPL:
  (eabp-device-intent :action \"android.intent.action.VIEW\"
                      :data \"https://example.com\")"
  (eabp-device--invoke
   "intent.start"
   (append (when action `((action . ,action)))
           (when data `((data . ,data)))
           (when package `((package . ,package)))
           (when class-name `((class_name . ,class-name)))
           (when mime `((mime . ,mime)))
           (when extras `((extras . ,extras)))
           `((mode . ,mode)))))

(defun eabp-device-app-launch (package)
  "Launch PACKAGE's main activity on the companion."
  (eabp-device--invoke "app.launch" `((package . ,package))))

(defun eabp-device-apps-list (callback)
  "Fetch the launchable apps and call CALLBACK with ((LABEL . PACKAGE) ...)."
  (eabp-device--invoke
   "apps.list" nil
   (lambda (ok payload)
     (if (not ok)
         (message "EABP device apps.list: %s [%s]"
                  (alist-get 'detail payload) (alist-get 'code payload))
       (funcall callback
                (mapcar (lambda (app)
                          (cons (alist-get 'label app)
                                (alist-get 'package app)))
                        (alist-get 'apps (alist-get 'result payload))))))))

(defun eabp-device-launch-app ()
  "Pick an installed app in a companion dialog and launch it.
The picker renders on the phone: choosing there keeps Glasspane
foregrounded, which is what makes the activity launch legal — Android
silently drops launches requested while the app is backgrounded (the
reason a desktop `completing-read' picker can never work here)."
  (interactive)
  (eabp-device-apps-list
   (lambda (apps)
     (eabp-send-dialog
      (apply #'eabp-lazy-column
             (cons (eabp-section-header "Launch app")
                   (mapcar (lambda (app)
                             (eabp-button (car app)
                                          (eabp-action
                                           "device.launch"
                                           :args `((package . ,(cdr app)))
                                           :when-offline "drop")
                                          :variant "text"))
                           apps)))))))

(eabp-defaction "device.launch"
  (lambda (args _)
    (when-let ((pkg (alist-get 'package args)))
      (eabp-dismiss-dialog)
      (eabp-device-app-launch pkg))))

;; ─── Permission-free effectors ───────────────────────────────────────────────

(defun eabp-device-vibrate (&optional ms pattern)
  "Vibrate for MS milliseconds (default 200), or by PATTERN.
PATTERN is a list of durations (off, on, off, on, … ms) and wins over MS."
  (eabp-device--invoke
   "vibrate"
   (if pattern
       `((pattern . ,(vconcat pattern)))
     `((ms . ,(or ms 200))))))

(cl-defun eabp-device-tts (text &key pitch rate)
  "Speak TEXT on the companion. PITCH and RATE are floats around 1.0.
Best-effort and asynchronous: the engine lazy-inits on first use."
  (eabp-device--invoke
   "tts.speak"
   (append `((text . ,text))
           (when pitch `((pitch . ,pitch)))
           (when rate `((rate . ,rate))))))

(defun eabp-device-volume-set (stream level)
  "Set STREAM volume to LEVEL (0..max, clamped device-side).
STREAM is music, ring, alarm, notification, call, or system."
  (eabp-device--invoke "volume.set" `((stream . ,stream) (level . ,level))))

(defun eabp-device-ringer-mode (mode)
  "Set the ringer MODE: \"normal\", \"vibrate\", or \"silent\".
Silent needs Do Not Disturb access — a cap-permission error carries
the settings deep-link to grant it."
  (eabp-device--invoke "ringer.mode" `((mode . ,mode))))

(defun eabp-device-flashlight (on)
  "Switch the torch ON (non-nil) or off."
  (eabp-device--invoke "flashlight" `((on . ,(if on t :false)))))

(defun eabp-device-media-key (key)
  "Send media KEY: play_pause, play, pause, next, previous, stop,
fast_forward, or rewind."
  (eabp-device--invoke "media.key" `((key . ,key))))

(defun eabp-device-clipboard-read (callback)
  "Read the companion clipboard and call CALLBACK with its text, or nil.
Android 10+ exposes the clipboard only while the companion is
foregrounded; elsewhere this yields nil (a cap-permission error).
Never log or persist what arrives here."
  (eabp-device--invoke
   "clipboard.read" nil
   (lambda (ok payload)
     (funcall callback
              (and ok (alist-get 'text (alist-get 'result payload)))))))

(defun eabp-device-settings-open (panel)
  "Open the companion's settings PANEL.
PANEL is wifi, internet, bluetooth, volume, nfc, or any
android.settings.* action string — the compliant \"toggle\" for
radios Android won't let apps flip."
  (eabp-device--invoke "settings.open" `((panel . ,panel))))

(defun eabp-device-keep-screen-on (on)
  "Keep the companion screen on while EABP UI is showing (ON non-nil).
A window flag, not a wakelock: it clears when EABP UI leaves the
screen, so it cannot pin the device awake in the background."
  (eabp-device--invoke "screen.keep_on" `((on . ,(if on t :false)))))

;; ─── Special-access effectors ────────────────────────────────────────────────

(defun eabp-device-brightness (level)
  "Set screen brightness LEVEL (0–255).
Needs the modify-system-settings grant; a cap-permission error carries
the deep-link (or use the Device permissions screen)."
  (eabp-device--invoke "brightness.set" `((level . ,level))))

(defun eabp-device-dnd (mode)
  "Set Do Not Disturb MODE: \"on\", \"off\", or \"priority\".
Needs Do Not Disturb access — see the Device permissions screen."
  (eabp-device--invoke "dnd.set" `((mode . ,mode))))

;; ─── The Device permissions screen ───────────────────────────────────────────

(defconst eabp-device--perm-info
  '((post_notifications "Notifications" "app")
    (exact_alarms "Exact alarms (reminders, time triggers)"
                  "android.settings.REQUEST_SCHEDULE_EXACT_ALARM")
    (write_settings "Modify system settings (brightness)"
                    "android.settings.action.MANAGE_WRITE_SETTINGS")
    (notification_policy "Do Not Disturb access (ringer, DND, volume)"
                         "android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS")
    (notification_listener "Notification access (notification triggers)"
                           "android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
    (fine_location "Location (Wi-Fi SSID triggers)" "app")
    (bluetooth_connect "Nearby devices (Bluetooth triggers)" "app"))
  "PERM-KEY LABEL PANEL rows for the Device permissions dialog.
PANEL feeds `settings.open': a grant screen action, or \"app\" for
Glasspane's own app-info page (runtime permissions live there).")

(defun eabp-device--perm-row (key label panel perms)
  (let ((granted (eq t (alist-get key perms))))
    (eabp-row
     (eabp-box
      (list (eabp-column
             (eabp-text label 'body)
             (eabp-text (if granted "Granted" "Not granted") 'caption)))
      :weight 1)
     (unless granted
       (eabp-button "Grant"
                    (eabp-action "device.perm.open"
                                 :args `((panel . ,panel))
                                 :when-offline "drop")
                    :variant "text")))))

(defun eabp-device-permissions-dialog ()
  "Show the device-permission map with grant deep-links.
Android never pops a dialog for special-access permissions — the only
compliant flow is deep-linking the user to the grant screen.  The map
refreshes on the next reconnect after granting."
  (interactive)
  (let ((perms (alist-get 'perms (alist-get 'device eabp--session))))
    (eabp-send-dialog
     (apply #'eabp-lazy-column
            (append
             (list (eabp-section-header "Device permissions")
                   (eabp-text (concat "Special access needs a trip to system "
                                      "settings; the list refreshes on the "
                                      "next reconnect.")
                              'caption))
             (mapcar (lambda (row)
                       (apply #'eabp-device--perm-row
                              (append row (list perms))))
                     eabp-device--perm-info))))))

(eabp-defaction "device.perms"
  (lambda (_args _) (eabp-device-permissions-dialog)))

(eabp-defaction "device.perm.open"
  (lambda (args _)
    (when-let ((panel (alist-get 'panel args)))
      (eabp-dismiss-dialog)
      (eabp-device-settings-open panel))))

;; Entry point: a card on the settings screen (satellite contract).
(with-eval-after-load 'eabp-settings
  (eabp-settings-add-link
   18 (lambda ()
        (eabp-card
         (list (eabp-row
                (eabp-icon "key")
                (eabp-box (list (eabp-column
                                 (eabp-text "Device permissions" 'label)
                                 (eabp-text "Grant special access for effectors and triggers"
                                            'caption)))
                          :weight 1)
                (eabp-icon "chevron_right")))
         :on-tap (eabp-action "device.perms" :when-offline "drop")))))

(provide 'eabp-device)
;;; eabp-device.el ends here
