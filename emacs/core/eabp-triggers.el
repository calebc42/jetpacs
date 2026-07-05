;;; eabp-triggers.el --- Device trigger registration & fire dispatch -*- lexical-binding: t; -*-

;; The Emacs half of SPEC §11: a registry of device triggers, the
;; replace-set push (`triggers.set'), and dispatch of inbound
;; `trigger.fired' events to per-id handlers.
;;
;; This is deliberately just the wire contract.  The authoring layer —
;; `eabp-deftrigger', enable/disable persistence, the Automations view —
;; comes later (PLAN-automation-and-launcher Task 12) and builds on the
;; functions here.  The companion side (persisted trigger table, boot
;; receiver, the actual listeners) is Task 6; until it lands the
;; companion does not grant the `triggers' capability and
;; `eabp-triggers-push' stays a no-op.
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
  (eabp-triggers-push))

(defun eabp-trigger-unregister (id)
  "Remove trigger ID and push the updated set (so it can never fire stale)."
  (remhash id eabp-triggers--table)
  (eabp-triggers-push))

(defun eabp-triggers--specs ()
  "The `triggers' payload vector built from the registry.
Wire fields only — handlers stay Emacs-side; nil fields are omitted
so the frame stays additive-friendly."
  (let (specs)
    (maphash
     (lambda (id reg)
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
             specs))
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
     ((null handler)
      ;; Legal: an on_fire-only rule the client tracks but doesn't act on.
      nil)
     (t (funcall handler (alist-get 'data args) args)))))

(eabp-defaction "trigger.fired" #'eabp-triggers--on-fired)

(defun eabp-triggers--on-connect (_welcome)
  "Re-push the trigger set after every handshake (replace-set = idempotent)."
  (eabp-triggers-push))

(add-hook 'eabp-connected-hook #'eabp-triggers--on-connect)

(provide 'eabp-triggers)
;;; eabp-triggers.el ends here
