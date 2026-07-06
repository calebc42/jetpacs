;;; glasspane-automations.el --- Automations as literate org -*- lexical-binding: t; -*-

;; Automation plan Task 13: rules live in an org file — readable,
;; editable on the phone with the org editor that already exists,
;; version-controllable.  One heading per rule:
;;
;;   * Charge sync
;;   :PROPERTIES:
;;   :TRIGGER: power connected
;;   :POLICY: wake
;;   :THROTTLE: 300
;;   :END:
;;   #+begin_src elisp
;;   (my/org-sync)
;;   #+end_src
;;
;; The drawer holds the wire fields (a shorthand `:TRIGGER:', raw
;; `:PARAMS:'/`:ON_FIRE:' for anything richer); the body's first elisp
;; src block is the handler, evaluated with `data' and `args' in scope.
;; Marking the heading DONE removes the rule from the pushed set — org
;; semantics as the enable switch.
;;
;; TRUST BOUNDARY: the src blocks are user-authored code from the
;; user's own file, the same trust as init.el.  This file must only
;; ever be loaded from the local `org-directory' — never from anything
;; that arrived over the wire or the share sheet.
;;
;; Property drawers are case-insensitive per the org case conventions
;; (org-element normalizes keys; the ERT suite pins a lowercase
;; drawer).  TODO keywords stay case-sensitive.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)
(require 'eabp)
(require 'eabp-triggers)
(require 'eabp-shell)
(require 'glasspane-org)

(defcustom glasspane-automations-file nil
  "The org file holding trigger rules.
nil means automations.org inside `org-directory'."
  :type '(choice (const :tag "automations.org in org-directory" nil) file)
  :group 'eabp)

(defvar glasspane-automations--ids nil
  "Trigger ids registered from the org file (replaced on each reload).")

(defun glasspane-automations--file ()
  (or glasspane-automations-file
      (expand-file-name "automations.org" org-directory)))

;; ─── Parsing ─────────────────────────────────────────────────────────────────

(defconst glasspane-automations--types eabp-triggers-supported-types
  "Trigger types rules may use — the shipped SPEC §11 catalog.
An unknown type would make the companion reject the whole replace-set
\(and `eabp-triggers--specs' skips it as a second line of defense), so
unknown rules are caught at parse time with a message naming the rule.
Notably NOT here yet: wifi.ssid / bluetooth.device — hardware-gated,
see the automation plan.")

(defun glasspane-automations--parse-trigger (str)
  "Parse the `:TRIGGER:' shorthand STR into (TYPE . PARAMS).
Grammar: the first token names the type; the rest is per-type sugar —
\"power connected\", \"screen off\", \"battery.level below 20\",
\"time every 3600\", \"package added com.example\".  Anything richer
goes in `:PARAMS:'.  Returns nil for an empty or unknown-type string."
  (pcase-let* ((tokens (split-string (or str "") "[ \t]+" t))
               (`(,type . ,rest) tokens))
    (when (and type (member type glasspane-automations--types))
      (cons type
            (pcase type
              ((or "power" "screen" "headset" "airplane")
               (when (car rest) `((state . ,(car rest)))))
              ("battery.level"
               (pcase rest
                 (`("below" ,n) `((below . ,(string-to-number n))))
                 (`("above" ,n) `((above . ,(string-to-number n))))))
              ("time"
               (pcase rest
                 (`("every" ,s) `((every_s . ,(string-to-number s))))
                 (`("at" ,ms) `((at_ms . ,(string-to-number ms))))))
              ("package"
               (append (when (car rest) `((event . ,(car rest))))
                       (when (cadr rest) `((package . ,(cadr rest))))))
              (_ nil))))))

(defun glasspane-automations--read (str)
  "Read STR as one elisp datum, or nil when STR is nil/empty.
For `:PARAMS:' / `:ON_FIRE:' — data from the user's own file."
  (when (and (stringp str) (not (string-empty-p (string-trim str))))
    (car (read-from-string str))))

(defun glasspane-automations--handler (src headline)
  "Build the rule handler from SRC, the elisp block body.
The forms run with `data' and `args' bound to the fire payload.  Same
trust as init.el — see the file header."
  (condition-case err
      (eval `(lambda (data args)
               (ignore data args)
               ,(car (read-from-string (format "(progn %s)" src))))
            t)
    (error
     (message "EABP automations: bad handler in %S: %s"
              headline (error-message-string err))
     nil)))

(defun glasspane-automations--rules ()
  "Parse the automations file into registration plists.
A rule = a headline with a `:TRIGGER:' property that is not DONE."
  (let ((file (glasspane-automations--file))
        rules)
    (when (file-readable-p file)
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (org-element-map (org-element-parse-buffer) 'headline
           (lambda (hl)
             (when-let ((trigger (org-element-property :TRIGGER hl)))
               (let* ((headline (org-element-property :raw-value hl))
                      (done (eq (org-element-property :todo-type hl) 'done))
                      (parsed (glasspane-automations--parse-trigger trigger)))
                 (cond
                  (done nil)            ; org semantics as the enable switch
                  ((null parsed)
                   (message "EABP automations: skipping %S — unknown trigger %S"
                            headline trigger))
                  (t
                   (let* ((src (car (org-element-map hl 'src-block
                                      (lambda (blk)
                                        (when (member (downcase
                                                       (or (org-element-property
                                                            :language blk)
                                                           ""))
                                                      '("elisp" "emacs-lisp"))
                                          (org-element-property :value blk))))))
                          (params (or (glasspane-automations--read
                                       (org-element-property :PARAMS hl))
                                      (cdr parsed))))
                     (push (list :id (format "org/%s" headline)
                                 :type (car parsed)
                                 :params params
                                 :policy (org-element-property :POLICY hl)
                                 :dedupe (org-element-property :DEDUPE hl)
                                 :throttle-s
                                 (when-let ((th (org-element-property
                                                 :THROTTLE hl)))
                                   (string-to-number th))
                                 :on-fire (glasspane-automations--read
                                           (org-element-property :ON_FIRE hl))
                                 :handler (when src
                                            (glasspane-automations--handler
                                             src headline)))
                           rules)))))))))))
    (nreverse rules)))

;; ─── Loading ─────────────────────────────────────────────────────────────────

(defun glasspane-automations-reload ()
  "Re-read the automations file and replace the org-defined triggers.
Previously org-defined ids not in the file anymore are unregistered —
the file is the source of truth for the `org/' id namespace."
  (interactive)
  (let* ((rules (glasspane-automations--rules))
         (ids (mapcar (lambda (r) (plist-get r :id)) rules)))
    ;; Unregister leavers first, then (re)register — each call pushes,
    ;; and replace-set makes the intermediate states harmless.
    (dolist (stale (cl-set-difference glasspane-automations--ids ids
                                      :test #'equal))
      (eabp-trigger-unregister stale))
    (dolist (r rules)
      (apply #'eabp-trigger-register (plist-get r :id)
             (cl-loop for (k v) on r by #'cddr
                      unless (eq k :id) append (list k v))))
    (setq glasspane-automations--ids ids)
    (when (called-interactively-p 'interactive)
      (message "EABP automations: %d rule(s) active" (length ids)))
    ids))

(defvar eabp-files-after-save-hook)

(defun glasspane-automations--after-save (file)
  "Reload when the phone saves the automations FILE."
  (when (equal (expand-file-name file)
               (expand-file-name (glasspane-automations--file)))
    (glasspane-automations-reload)))

(with-eval-after-load 'eabp-files
  (add-hook 'eabp-files-after-save-hook #'glasspane-automations--after-save))

;; Load rules when the file exists; a missing file is simply zero rules.
(when (file-readable-p (glasspane-automations--file))
  (glasspane-automations-reload))

(provide 'glasspane-automations)
;;; glasspane-automations.el ends here
