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
  "Pick an installed companion-side app with completion and launch it."
  (interactive)
  (eabp-device-apps-list
   (lambda (apps)
     (let ((choice (completing-read "Launch on phone: " apps nil t)))
       (when-let ((pkg (cdr (assoc choice apps))))
         (eabp-device-app-launch pkg))))))

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

(provide 'eabp-device)
;;; eabp-device.el ends here
