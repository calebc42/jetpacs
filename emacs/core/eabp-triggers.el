;;; eabp-triggers.el --- Device trigger registration & fire dispatch -*- lexical-binding: t; -*-

;; The Emacs half of SPEC §11: a registry of device triggers, the
;; replace-set push (`triggers.set'), dispatch of inbound
;; `trigger.fired' events to per-id handlers, and the authoring layer —
;; `eabp-deftrigger', enable/disable (persisted through Customize), and
;; the trigger.toggle / trigger.test actions the Automations view
;; (emacs/apps/eabp-automations.el) renders against.
;;
;; Load order: (require 'eabp-surfaces) then this file — `trigger.fired'
;; arrives as an ordinary event.action, so dispatch rides the standard
;; action allowlist.

;;; Code:

(require 'cl-lib)
(require 'eabp)
(require 'eabp-surfaces)

(defvar eabp-triggers--table (make-hash-table :test 'equal)
  "Map of trigger id (string) -> registration plist.
Keys: :type :params :policy :dedupe :throttle-s :on-fire :handler.")

(defcustom eabp-triggers-disabled nil
  "Trigger ids excluded from the pushed set (the Automations toggles).
A disabled trigger stays registered — handler, params, everything — but
is omitted from `triggers.set', so replace-set semantics guarantee the
companion can never fire it.  Persisted through Customize when toggled
from the phone."
  :type '(repeat string) :group 'eabp)

(defvar eabp-triggers--last-fired (make-hash-table :test 'equal)
  "Map of trigger id -> `current-time' of its most recent (test-)fire.")

(defvar eabp-triggers-changed-hook nil
  "Hook run after any registry change (register, unregister, toggle).
The Automations view re-pushes here; keep handlers cheap.")

(cl-defun eabp-trigger-register (id &key type params policy dedupe
                                    throttle-s on-fire handler)
  "Register device trigger ID and push the updated set.
TYPE (string, required) names a SPEC §11 catalog type; PARAMS is the
plain-data match config alist for that type.  POLICY is the §5
`when_offline' vocabulary (\"queue\" | \"drop\" | \"wake\", default
queue); DEDUPE collapses queued fires sharing the key; THROTTLE-S is
the host-side minimum seconds between fires.  ON-FIRE is the reserved
companion-local response list (SPEC §11) — plain data, sent verbatim.
HANDLER is called with (DATA ARGS) when the trigger fires: DATA is the
type-shaped payload, ARGS the full `trigger.fired' args alist.
Re-registering an existing ID replaces it."
  (unless (and (stringp id) (not (string-empty-p id)))
    (error "Trigger id must be a non-empty string"))
  (unless (stringp type)
    (error "Trigger %s needs a :type string" id))
  (puthash id (list :type type :params params :policy policy
                    :dedupe dedupe :throttle-s throttle-s
                    :on-fire on-fire :handler handler)
           eabp-triggers--table)
  (eabp-triggers-push)
  (run-hooks 'eabp-triggers-changed-hook)
  id)

(defmacro eabp-deftrigger (name &rest props)
  "Define device trigger NAME (an unquoted symbol) — `eabp-defaction' feel.
PROPS are `eabp-trigger-register' keywords (:type :params :policy
:dedupe :throttle-s :on-fire :handler); the trigger id is NAME's print
name.  Re-evaluating replaces the registration and re-pushes the set:

  (eabp-deftrigger my/charge-sync
    :type \"power\" :params \\='((state . \"connected\")) :policy \"wake\"
    :handler (lambda (data _args) (my/org-sync)))"
  (declare (indent defun))
  `(eabp-trigger-register ,(symbol-name name) ,@props))

(defun eabp-trigger-unregister (id)
  "Remove trigger ID and push the updated set (so it can never fire stale)."
  (remhash id eabp-triggers--table)
  (eabp-triggers-push)
  (run-hooks 'eabp-triggers-changed-hook))

(defun eabp-trigger-enabled-p (id)
  "Non-nil when trigger ID is included in pushed sets."
  (not (member id eabp-triggers-disabled)))

(defun eabp-trigger-set-enabled (id enabled &optional persist)
  "Include (ENABLED non-nil) or exclude trigger ID from the pushed set.
Re-pushes immediately (replace-set makes the change atomic on the
companion).  With PERSIST, the disabled list is saved through the
settings seam so it survives restarts."
  (setq eabp-triggers-disabled
        (if enabled
            (delete id eabp-triggers-disabled)
          (cl-adjoin id eabp-triggers-disabled :test #'equal)))
  (when persist
    (require 'eabp-settings)
    (eabp-settings-save-variable 'eabp-triggers-disabled
                                 eabp-triggers-disabled))
  (eabp-triggers-push)
  (run-hooks 'eabp-triggers-changed-hook))

(defun eabp-trigger-test-fire (id)
  "Run trigger ID's handler with synthetic fire args (`test' flag set).
Exercises the exact dispatch path a device fire takes, minus the wire."
  (interactive
   (list (completing-read "Test-fire trigger: "
                          (hash-table-keys eabp-triggers--table) nil t)))
  (let ((reg (gethash id eabp-triggers--table)))
    (unless reg (error "No trigger registered as %s" id))
    (eabp-triggers--on-fired
     `((id . ,id) (type . ,(plist-get reg :type))
       (at_ms . ,(truncate (* 1000 (float-time)))) (test . t))
     nil)))

(defun eabp-triggers--specs ()
  "The `triggers' payload vector built from the registry.
Wire fields only — handlers stay Emacs-side; nil fields are omitted so
the frame stays additive-friendly; disabled ids are excluded, which is
what disables them (replace-set: absent = can never fire)."
  (let (specs)
    (maphash
     (lambda (id reg)
       (unless (member id eabp-triggers-disabled)
         (push (append
                `((id . ,id)
                  (type . ,(plist-get reg :type)))
                (when-let ((params (plist-get reg :params)))
                  `((params . ,params)))
                (when-let ((policy (plist-get reg :policy)))
                  `((policy . ,policy)))
                (when-let ((dedupe (plist-get reg :dedupe)))
                  `((dedupe . ,dedupe)))
                (when-let ((throttle (plist-get reg :throttle-s)))
                  `((throttle_s . ,throttle)))
                (when-let ((on-fire (plist-get reg :on-fire)))
                  `((on_fire . ,on-fire))))
               specs)))
     eabp-triggers--table)
    ;; Stable order (by id) so identical registries produce identical
    ;; frames — replace-set pushes are diff-able in logs and tests.
    (vconcat (sort specs
                   (lambda (a b)
                     (string< (alist-get 'id a) (alist-get 'id b)))))))

(defun eabp-triggers-push ()
  "Push the full trigger set to the companion (replace-set, idempotent).
No-op unless connected and the session granted `triggers' — pushing an
empty set is meaningful (it clears the companion's table), so this
sends even when the registry is empty."
  (when (and (eabp-connected-p) (eabp-granted-p "triggers"))
    (eabp-send "triggers.set" `((triggers . ,(eabp-triggers--specs))))))

(defun eabp-triggers--on-fired (args _payload)
  "Dispatch a `trigger.fired' event to its registration's handler.
ARGS carries {id, type, data, at_ms} per SPEC §11."
  (let* ((id (alist-get 'id args))
         (reg (and (stringp id) (gethash id eabp-triggers--table)))
         (handler (plist-get reg :handler)))
    (cond
     ((null reg)
      ;; Replace-set means this shouldn't happen; a fire queued before an
      ;; unregister can still race in.  Log, never error.
      (message "EABP: fire for unregistered trigger %s" id))
     (t
      (puthash id (current-time) eabp-triggers--last-fired)
      ;; A nil handler is legal: an on_fire-only rule the client tracks
      ;; but doesn't act on.
      (when handler
        (funcall handler (alist-get 'data args) args))))))

(eabp-defaction "trigger.fired" #'eabp-triggers--on-fired)

;; Management actions for the Automations view (trigger.* is core's
;; namespace, and these are registry operations, so they live here; the
;; view in emacs/apps/eabp-automations.el is pure rendering).

(eabp-defaction "trigger.toggle"
  (lambda (args _)
    (let ((id (alist-get 'id args)))
      (when (gethash id eabp-triggers--table)
        ;; `value' is the switch state the companion injected (SPEC §5).
        (eabp-trigger-set-enabled id (eq (alist-get 'value args) t) t)))))

(eabp-defaction "trigger.test"
  (lambda (args _)
    (let ((id (alist-get 'id args)))
      (when (gethash id eabp-triggers--table)
        (eabp-trigger-test-fire id)))))

(defun eabp-triggers--on-connect (_welcome)
  "Re-push the trigger set after every handshake (replace-set = idempotent)."
  (eabp-triggers-push))

(add-hook 'eabp-connected-hook #'eabp-triggers--on-connect)

(provide 'eabp-triggers)
;;; eabp-triggers.el ends here
