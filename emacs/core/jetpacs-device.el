;;; jetpacs-device.el --- Device effectors via capability.invoke -*- lexical-binding: t; -*-

;; The Emacs face of SPEC §10's capability catalog: one thin defun per
;; device capability, all funneling through `jetpacs-device--invoke'.  The
;; companion is the validator — these wrappers only shape plain-data
;; args; unknown or refused capabilities come back as typed errors
;; (`cap-unsupported' / `cap-permission' / `cap-failed') which the
;; default callback surfaces in *Messages*.
;;
;; Check `jetpacs-device-cap-p' / `jetpacs-device-can-p' (jetpacs.el) to degrade
;; gracefully in UI; from the REPL just call and read the echo area.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)

(defun jetpacs-device--invoke (cap args &optional callback)
  "Invoke device capability CAP with plain-data alist ARGS.
CALLBACK as in `jetpacs-capability-invoke'; when nil, failures surface
in *Messages* with their typed code."
  (jetpacs-capability-invoke
   cap args
   (or callback
       (lambda (ok payload)
         (unless ok
           (message "Jetpacs device %s: %s [%s]" cap
                    (alist-get 'detail payload)
                    (alist-get 'code payload)))))))

;; ─── Intents: the universal escape hatch ─────────────────────────────────────

(cl-defun jetpacs-device-intent (&key action data package class-name mime
                                   extras (mode "activity"))
  "Fire an Android Intent on the companion (SPEC §10 `intent.start').
ACTION is an intent action string; DATA a URI; PACKAGE / CLASS-NAME
target an explicit component; MIME sets the type; EXTRAS is an alist
of plain data (strings, numbers, booleans — pass :false for false).
MODE is \"activity\" (default), \"broadcast\", or \"service\".
Activity launches are best-effort while the companion is backgrounded.

Example, from the eval REPL:
  (jetpacs-device-intent :action \"android.intent.action.VIEW\"
                      :data \"https://example.com\")"
  (jetpacs-device--invoke
   "intent.start"
   (append (when action `((action . ,action)))
           (when data `((data . ,data)))
           (when package `((package . ,package)))
           (when class-name `((class_name . ,class-name)))
           (when mime `((mime . ,mime)))
           (when extras `((extras . ,extras)))
           `((mode . ,mode)))))

(defun jetpacs-device-app-launch (package)
  "Launch PACKAGE's main activity on the companion."
  (jetpacs-device--invoke "app.launch" `((package . ,package))))

(defun jetpacs-device-apps-list (callback)
  "Fetch the launchable apps and call CALLBACK with ((LABEL . PACKAGE) ...)."
  (jetpacs-device--invoke
   "apps.list" nil
   (lambda (ok payload)
     (if (not ok)
         (message "Jetpacs device apps.list: %s [%s]"
                  (alist-get 'detail payload) (alist-get 'code payload))
       (funcall callback
                (mapcar (lambda (app)
                          (cons (alist-get 'label app)
                                (alist-get 'package app)))
                        (alist-get 'apps (alist-get 'result payload))))))))

(defun jetpacs-device-launch-app ()
  "Pick an installed app in a companion dialog and launch it.
The picker renders on the phone: choosing there keeps Glasspane
foregrounded, which is what makes the activity launch legal — Android
silently drops launches requested while the app is backgrounded (the
reason a desktop `completing-read' picker can never work here)."
  (interactive)
  (jetpacs-device-apps-list
   (lambda (apps)
     (jetpacs-send-dialog
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-section-header "Launch app")
                   (mapcar (lambda (app)
                             (jetpacs-button (car app)
                                          (jetpacs-action
                                           "device.launch"
                                           :args `((package . ,(cdr app)))
                                           :when-offline "drop")
                                          :variant "text"))
                           apps)))))))

(jetpacs-defaction "device.launch"
  (lambda (args _)
    (when-let ((pkg (alist-get 'package args)))
      (jetpacs-dismiss-dialog)
      (jetpacs-device-app-launch pkg))))

;; ─── Launcher shortcuts ──────────────────────────────────────────────────────

(defun jetpacs-device--icon-base64 (file)
  "Read image FILE (a PNG) and return its bytes base64-encoded."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (base64-encode-string (buffer-string) t)))

(defun jetpacs-device--shortcut-spec (id label action icon-file long-label)
  "The plain-data shortcut object `shortcut.pin' and `shortcuts.set' share."
  (append `((id . ,id)
            (label . ,label)
            (action . ,action))
          (when icon-file
            `((icon_png . ,(jetpacs-device--icon-base64 icon-file))))
          (when long-label `((long_label . ,long-label)))))

(cl-defun jetpacs-device-shortcut-pin (id label action &key icon-file long-label)
  "Request a home-screen pinned shortcut — launcher identity for an app.
ID names the shortcut; re-pinning the same ID updates label, icon, and
action in place (how an app ships a logo refresh, no dialog).  LABEL is
the short name under the icon.  ACTION is a `jetpacs-action' descriptor
dispatched through the normal tap pipeline when the shortcut opens the
companion — point it at whatever pushes your app's root view.
ICON-FILE is a PNG the launcher masks to its adaptive-icon shape:
square and full-bleed, 432px or larger recommended (keep the logo
inside the middle ~66%); omitted, the companion's own icon is used.
Android asks the user to confirm a fresh pin, and overlays a small
badge of the companion's icon — that part is OS-enforced."
  (jetpacs-device--invoke
   "shortcut.pin"
   (jetpacs-device--shortcut-spec id label action icon-file long-label)))

(defun jetpacs-device-shortcuts-set (shortcuts)
  "Replace the companion icon's long-press (dynamic) shortcuts.
SHORTCUTS is a list of (ID LABEL ACTION [ICON-FILE [LONG-LABEL]])
entries — fields as in `jetpacs-device-shortcut-pin'.  The whole set is
replaced (`triggers.set' discipline); nil clears it.  Launchers cap the
count (typically four visible), and a set over the max is refused
outright rather than truncated."
  (jetpacs-device--invoke
   "shortcuts.set"
   `((shortcuts
      . ,(vconcat
          (mapcar (lambda (s)
                    (cl-destructuring-bind
                        (id label action &optional icon-file long-label) s
                      (jetpacs-device--shortcut-spec
                       id label action icon-file long-label)))
                  shortcuts))))))

;; ─── Reminders (owner-scoped exact alarms) ───────────────────────────────────

(defvar jetpacs-reminders--warned nil
  "Owners already warned that this companion can't scope reminders per app.")

(defun jetpacs-reminders--warn-unscoped (owner)
  "Warn once per OWNER that reminders can't be armed without clobbering others."
  (unless (member owner jetpacs-reminders--warned)
    (push owner jetpacs-reminders--warned)
    (display-warning
     'jetpacs
     (format "%s: this Jetpacs companion can't scope reminders per app (no \
`reminders.owner' capability) and another app is registered — arming nothing \
rather than erasing another app's alarms.  Update the companion to arm these."
             (or owner "core"))
     :warning)))

(defun jetpacs-reminders-owner-set (reminders &optional owner)
  "Arm REMINDERS as exact alarms scoped to OWNER, replacing only OWNER's set.
REMINDERS is a sequence of reminder objects (each an alist/plist carrying the
wire keys `id', `at_ms', `title', `body').  The set REPLACES this owner's
previously-armed reminders and leaves alarms belonging to OTHER apps
untouched — the safety a bare global `reminders.set' cannot promise.  OWNER
defaults to `jetpacs-current-owner' (the app whose `with-jetpacs-owner' or
`jetpacs-defapp' is active); a nil owner is the unowned/core set.

Negotiates with the companion:
 - granted `reminders.owner' -> send the owner-scoped set;
 - else, only ONE app registered -> a plain global `reminders.set' is safe
   (there is nothing else to clobber);
 - else (owner-unaware companion, a second app present) -> refuse: warn once
   and arm nothing rather than erase another app's alarms.
Returns non-nil when a set was sent."
  (let ((owner (or owner jetpacs-current-owner))
        (vec (vconcat reminders)))
    (cond
     ((jetpacs-granted-p "reminders.owner")
      (jetpacs-send "reminders.set"
                    `((owner . ,(or owner "")) (reminders . ,vec)))
      t)
     ((not (and (fboundp 'jetpacs-apps--multi-p) (jetpacs-apps--multi-p)))
      (jetpacs-send "reminders.set" `((reminders . ,vec)))
      t)
     (t
      (jetpacs-reminders--warn-unscoped owner)
      nil))))

;; ─── Permission-free effectors ───────────────────────────────────────────────

(defun jetpacs-device-vibrate (&optional ms pattern)
  "Vibrate for MS milliseconds (default 200), or by PATTERN.
PATTERN is a list of durations (off, on, off, on, … ms) and wins over MS."
  (jetpacs-device--invoke
   "vibrate"
   (if pattern
       `((pattern . ,(vconcat pattern)))
     `((ms . ,(or ms 200))))))

(cl-defun jetpacs-device-tts (text &key pitch rate)
  "Speak TEXT on the companion. PITCH and RATE are floats around 1.0.
Best-effort and asynchronous: the engine lazy-inits on first use."
  (jetpacs-device--invoke
   "tts.speak"
   (append `((text . ,text))
           (when pitch `((pitch . ,pitch)))
           (when rate `((rate . ,rate))))))

(defun jetpacs-device-volume-set (stream level)
  "Set STREAM volume to LEVEL (0..max, clamped device-side).
STREAM is music, ring, alarm, notification, call, or system."
  (jetpacs-device--invoke "volume.set" `((stream . ,stream) (level . ,level))))

(defun jetpacs-device-ringer-mode (mode)
  "Set the ringer MODE: \"normal\", \"vibrate\", or \"silent\".
Silent needs Do Not Disturb access — a cap-permission error carries
the settings deep-link to grant it."
  (jetpacs-device--invoke "ringer.mode" `((mode . ,mode))))

(defun jetpacs-device-flashlight (on)
  "Switch the torch ON (non-nil) or off."
  (jetpacs-device--invoke "flashlight" `((on . ,(if on t :false)))))

(defun jetpacs-device-media-key (key)
  "Send media KEY: play_pause, play, pause, next, previous, stop,
fast_forward, or rewind."
  (jetpacs-device--invoke "media.key" `((key . ,key))))

(defun jetpacs-device-clipboard-read (callback)
  "Read the companion clipboard and call CALLBACK with its text, or nil.
Android 10+ exposes the clipboard only while the companion is
foregrounded; elsewhere this yields nil (a cap-permission error).
Never log or persist what arrives here."
  (jetpacs-device--invoke
   "clipboard.read" nil
   (lambda (ok payload)
     (funcall callback
              (and ok (alist-get 'text (alist-get 'result payload)))))))

(defun jetpacs-device-settings-open (panel)
  "Open the companion's settings PANEL.
PANEL is wifi, internet, bluetooth, volume, nfc, or any
android.settings.* action string — the compliant \"toggle\" for
radios Android won't let apps flip."
  (jetpacs-device--invoke "settings.open" `((panel . ,panel))))

(defun jetpacs-device-keep-screen-on (on)
  "Keep the companion screen on while Jetpacs UI is showing (ON non-nil).
A window flag, not a wakelock: it clears when Jetpacs UI leaves the
screen, so it cannot pin the device awake in the background."
  (jetpacs-device--invoke "screen.keep_on" `((on . ,(if on t :false)))))

;; ─── Special-access effectors ────────────────────────────────────────────────

(defun jetpacs-device-brightness (level)
  "Set screen brightness LEVEL (0–255).
Needs the modify-system-settings grant; a cap-permission error carries
the deep-link (or use the Device permissions screen)."
  (jetpacs-device--invoke "brightness.set" `((level . ,level))))

(defun jetpacs-device-dnd (mode)
  "Set Do Not Disturb MODE: \"on\", \"off\", or \"priority\".
Needs Do Not Disturb access — see the Device permissions screen."
  (jetpacs-device--invoke "dnd.set" `((mode . ,mode))))

;; ─── The Device permissions screen ───────────────────────────────────────────

(defconst jetpacs-device--perm-info
  '((post_notifications "Notifications" "app")
    (exact_alarms "Exact alarms (reminders, time triggers)"
                  "android.settings.REQUEST_SCHEDULE_EXACT_ALARM")
    (write_settings "Modify system settings (brightness)"
                    "android.settings.action.MANAGE_WRITE_SETTINGS")
    (notification_policy "Do Not Disturb access (ringer, DND, volume)"
                         "android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS")
    ;; No grant link yet: the app appears in that system list only once
    ;; the notification-listener service ships (automation plan Task 9).
    (notification_listener "Notification access (feature not shipped yet)" nil)
    (fine_location "Location (Wi-Fi SSID triggers)" "app")
    (bluetooth_connect "Nearby devices (Bluetooth triggers)" "app"))
  "PERM-KEY LABEL PANEL rows for the Device permissions dialog.
PANEL feeds `settings.open': a grant screen action, or \"app\" for
Glasspane's own app-info page (runtime permissions live there).")

(defun jetpacs-device--perm-row (key label panel perms)
  (let ((granted (eq t (alist-get key perms))))
    (apply #'jetpacs-row
           (delq nil
                 (list
                  (jetpacs-box
                   (list (jetpacs-column
                          (jetpacs-text label 'body)
                          (jetpacs-text (if granted "Granted" "Not granted")
                                     'caption)))
                   :weight 1)
                  (when (and panel (not granted))
                    (jetpacs-button "Grant"
                                 (jetpacs-action "device.perm.open"
                                              :args `((panel . ,panel))
                                              :when-offline "drop")
                                 :variant "text")))))))

(defun jetpacs-device-permissions-dialog ()
  "Show the device-permission map with grant deep-links.
Android never pops a dialog for special-access permissions — the only
compliant flow is deep-linking the user to the grant screen.  The map
refreshes on the next reconnect after granting."
  (interactive)
  (let ((perms (alist-get 'perms (alist-get 'device jetpacs--session))))
    (jetpacs-send-dialog
     (apply #'jetpacs-lazy-column
            (append
             (list (jetpacs-section-header "Device permissions")
                   (jetpacs-text (concat "Special access needs a trip to system "
                                      "settings; the list refreshes on the "
                                      "next reconnect.")
                              'caption))
             (mapcar (lambda (row)
                       (apply #'jetpacs-device--perm-row
                              (append row (list perms))))
                     jetpacs-device--perm-info))))))

(jetpacs-defaction "device.perms"
  (lambda (_args _) (jetpacs-device-permissions-dialog)))

(jetpacs-defaction "device.perm.open"
  (lambda (args _)
    (when-let ((panel (alist-get 'panel args)))
      (jetpacs-dismiss-dialog)
      (jetpacs-device-settings-open panel))))

;; Entry point: native Jetpacs settings. The builtin is intentionally
;; local so permissions and Android configuration remain reachable offline.
(with-eval-after-load 'jetpacs-settings
  (jetpacs-settings-add-native-link
   0 (lambda ()
        (jetpacs-card
         (list (jetpacs-row
                (jetpacs-icon "settings")
                (jetpacs-box (list (jetpacs-column
                                 (jetpacs-text "Open Jetpacs settings" 'label)
                                 (jetpacs-text "Android access, notifications, offline data, pairing"
                                            'caption)))
                          :weight 1)
                (jetpacs-icon "chevron_right")))
         :on-tap (jetpacs-native-settings-action)))))

(provide 'jetpacs-device)
;;; jetpacs-device.el ends here
