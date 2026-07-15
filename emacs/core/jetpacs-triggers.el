;;; jetpacs-triggers.el --- Device trigger registration & fire dispatch -*- lexical-binding: t; -*-

;; The Emacs half of SPEC §11: a registry of device triggers, the
;; replace-set push (`triggers.set'), dispatch of inbound
;; `trigger.fired' events to per-id handlers, and the authoring layer —
;; `jetpacs-deftrigger', enable/disable (persisted through Customize), and
;; the trigger.toggle / trigger.test actions the Automations view
;; (emacs/apps/jetpacs-automations.el) renders against.
;;
;; Load order: (require 'jetpacs-surfaces) then this file — `trigger.fired'
;; arrives as an ordinary event.action, so dispatch rides the standard
;; action allowlist.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-surfaces)

(defvar jetpacs-triggers--table (make-hash-table :test 'equal)
  "Map of trigger id (string) -> registration plist.
Keys: :type :params :when :policy :dedupe :throttle-s :on-fire :handler.")

(defconst jetpacs-triggers-supported-types
  '("time" "power" "battery.level" "screen" "headset" "airplane"
    "boot" "timezone.changed" "package" "network")
  "The SPEC §11 batch-1 trigger-type catalog.
The fallback when the welcome carries no `device.trigger_types' — a
newer companion reports its own catalog there and that report wins
(see `jetpacs-triggers--supported-p').  Mirrors TriggerHost.kt's
SUPPORTED_TYPES batch 1.  This list is FROZEN: types added after
batch 1 negotiate via the welcome report only and are never appended
here, because a companion old enough to omit the report is also too
old to host them.")

(defun jetpacs-triggers--supported-p (type)
  "Non-nil when the companion can host trigger TYPE.
Prefers the session's `device.trigger_types' report; the static
batch-1 catalog covers companions that predate the field.  The point
is to skip a single too-new registration rather than push it and have
the companion reject the whole replace-set."
  (let ((reported (alist-get 'trigger_types
                             (alist-get 'device jetpacs--session))))
    (and (member type (or reported jetpacs-triggers-supported-types)) t)))

(defun jetpacs-triggers--when-supported-p (gate)
  "Non-nil when every predicate type in GATE is sample-able here.
GATE is a `:when' list of predicate alists; the authority is the
session's `device.state_types' report (SPEC §11).  Deliberately NO
static fallback, unlike `jetpacs-triggers--supported-p': a companion
that predates `when' silently ignores unknown keys inside a trigger
entry, so pushing a gate it cannot evaluate would arm the trigger
UNGATED — \"notify below 20%\" becomes \"notify always\", strictly
worse than a skip.  Absent report = nothing is supported, and the
caller must skip the whole registration, never strip the gate and
push the rest."
  (let ((reported (alist-get 'state_types
                             (alist-get 'device jetpacs--session))))
    (and (seq-every-p (lambda (p) (member (alist-get 'type p) reported))
                      gate)
         t)))

(defcustom jetpacs-triggers-disabled nil
  "Trigger ids excluded from the pushed set (the Automations toggles).
A disabled trigger stays registered — handler, params, everything — but
is omitted from `triggers.set', so replace-set semantics guarantee the
companion can never fire it.  Persisted through Customize when toggled
from the phone."
  :type '(repeat string) :group 'jetpacs)

(defvar jetpacs-triggers--last-fired (make-hash-table :test 'equal)
  "Map of trigger id -> `current-time' of its most recent (test-)fire.")

(defvar jetpacs-triggers-changed-hook nil
  "Hook run after any registry change (register, unregister, toggle).
The Automations view re-pushes here; keep handlers cheap.")

(cl-defun jetpacs-trigger-register (id &key type params when policy dedupe
                                    throttle-s on-fire handler)
  "Register device trigger ID and push the updated set.
TYPE (string, required) names a SPEC §11 catalog type; PARAMS is the
plain-data match config alist for that type.  WHEN is a state gate: a
list of predicate alists (each `type' + match fields, SPEC §11 \"State
predicates & sampling\"), ANDed by the companion at fire time — a
failed gate suppresses the ENTIRE fire, event and on_fire both.  A
gate this companion can't evaluate makes the whole registration skip
\(see `jetpacs-triggers--when-supported-p'; test a gate live with
`jetpacs-device-state').  POLICY is the §5 `when_offline' vocabulary
\(\"queue\" | \"drop\" | \"wake\", default queue); DEDUPE collapses
queued fires sharing the key; THROTTLE-S is the host-side minimum
seconds between fires.  ON-FIRE is the companion-local response list
\(SPEC §11) — plain data, sent verbatim.  HANDLER is called with
\(DATA ARGS) when the trigger fires: DATA is the type-shaped payload,
ARGS the full `trigger.fired' args alist.  Re-registering an existing
ID replaces it."
  (unless (and (stringp id) (not (string-empty-p id)))
    (error "Trigger id must be a non-empty string"))
  (unless (stringp type)
    (error "Trigger %s needs a :type string" id))
  (jetpacs--claim "trigger" id)
  (puthash id (list :type type :params params :when when :policy policy
                    :dedupe dedupe :throttle-s throttle-s
                    :on-fire on-fire :handler handler)
           jetpacs-triggers--table)
  (jetpacs-triggers-push)
  (run-hooks 'jetpacs-triggers-changed-hook)
  id)

(defmacro jetpacs-deftrigger (name &rest props)
  "Define device trigger NAME (an unquoted symbol) — `jetpacs-defaction' feel.
PROPS are `jetpacs-trigger-register' keywords (:type :params :policy
:dedupe :throttle-s :on-fire :handler); the trigger id is NAME's print
name.  Re-evaluating replaces the registration and re-pushes the set:

  (jetpacs-deftrigger my/charge-sync
    :type \"power\" :params \\='((state . \"connected\")) :policy \"wake\"
    :handler (lambda (data _args) (my/org-sync)))"
  (declare (indent defun))
  `(jetpacs-trigger-register ,(symbol-name name) ,@props))

(defun jetpacs-trigger-unregister (id)
  "Remove trigger ID and push the updated set (so it can never fire stale)."
  (remhash id jetpacs-triggers--table)
  (jetpacs--unclaim "trigger" id)
  (jetpacs-triggers-push)
  (run-hooks 'jetpacs-triggers-changed-hook))

(defun jetpacs-trigger-enabled-p (id)
  "Non-nil when trigger ID is included in pushed sets."
  (not (member id jetpacs-triggers-disabled)))

(defun jetpacs-trigger-set-enabled (id enabled &optional persist)
  "Include (ENABLED non-nil) or exclude trigger ID from the pushed set.
Re-pushes immediately (replace-set makes the change atomic on the
companion).  With PERSIST, the disabled list is saved through the
settings seam so it survives restarts."
  (setq jetpacs-triggers-disabled
        (if enabled
            (delete id jetpacs-triggers-disabled)
          (cl-adjoin id jetpacs-triggers-disabled :test #'equal)))
  (when persist
    (require 'jetpacs-settings)
    (jetpacs-settings-save-variable 'jetpacs-triggers-disabled
                                 jetpacs-triggers-disabled))
  (jetpacs-triggers-push)
  (run-hooks 'jetpacs-triggers-changed-hook))

(defun jetpacs-trigger-test-fire (id)
  "Run trigger ID's handler with synthetic fire args (`test' flag set).
Exercises the exact dispatch path a device fire takes, minus the wire.
Deliberately BYPASSES the registration's `:when' gate (the gate is
companion-side, and this never leaves Emacs): it tests the dispatch
path, not the gate — evaluate a gate with `jetpacs-device-state'."
  (interactive
   (list (completing-read "Test-fire trigger: "
                          (hash-table-keys jetpacs-triggers--table) nil t)))
  (let ((reg (gethash id jetpacs-triggers--table)))
    (unless reg (error "No trigger registered as %s" id))
    (jetpacs-triggers--on-fired
     `((id . ,id) (type . ,(plist-get reg :type))
       (at_ms . ,(truncate (* 1000 (float-time)))) (test . t))
     nil)))

(defun jetpacs-triggers--specs ()
  "The `triggers' payload vector built from the registry.
Wire fields only — handlers stay Emacs-side; nil fields are omitted so
the frame stays additive-friendly; disabled ids are excluded, which is
what disables them (replace-set: absent = can never fire).  A type
this companion doesn't support is skipped with a message: the
companion rejects a replace-set wholesale, so one too-new registration
must cost itself, never the set.  A `:when'-gated registration whose
gate this companion can't evaluate is likewise skipped WHOLE — never
stripped of its gate and pushed, which would arm it ungated (SPEC
§11's normative client rule)."
  (let (specs)
    (maphash
     (lambda (id reg)
       (cond
        ((member id jetpacs-triggers-disabled))
        ((not (jetpacs-triggers--supported-p (plist-get reg :type)))
         (message "Jetpacs triggers: skipping %s — companion lacks type %s"
                  id (plist-get reg :type)))
        ((and (plist-get reg :when)
              (not (jetpacs-triggers--when-supported-p (plist-get reg :when))))
         (message (concat "Jetpacs triggers: skipping %s — companion can't "
                          "evaluate its `when' gate")
                  id))
        (t
         (push (append
                `((id . ,id)
                  (type . ,(plist-get reg :type)))
                (when-let ((params (plist-get reg :params)))
                  `((params . ,params)))
                (when-let ((gate (plist-get reg :when)))
                  `((when . ,(vconcat gate))))
                (when-let ((policy (plist-get reg :policy)))
                  `((policy . ,policy)))
                (when-let ((dedupe (plist-get reg :dedupe)))
                  `((dedupe . ,dedupe)))
                (when-let ((throttle (plist-get reg :throttle-s)))
                  `((throttle_s . ,throttle)))
                (when-let ((on-fire (plist-get reg :on-fire)))
                  `((on_fire . ,on-fire))))
               specs))))
     jetpacs-triggers--table)
    ;; Stable order (by id) so identical registries produce identical
    ;; frames — replace-set pushes are diff-able in logs and tests.
    (vconcat (sort specs
                   (lambda (a b)
                     (string< (alist-get 'id a) (alist-get 'id b)))))))

(defvar jetpacs-triggers--push-timer nil)

(defun jetpacs-triggers-push-now ()
  "Push the full trigger set to the companion (replace-set, idempotent).
No-op unless connected and the session granted `triggers' — pushing an
empty set is meaningful (it clears the companion's table), so this
sends even when the registry is empty.  Satisfies any pending
debounced push (`jetpacs-triggers-push')."
  (when (timerp jetpacs-triggers--push-timer)
    (cancel-timer jetpacs-triggers--push-timer)
    (setq jetpacs-triggers--push-timer nil))
  (when (and (jetpacs-connected-p) (jetpacs-granted-p "triggers"))
    (jetpacs-send "triggers.set" `((triggers . ,(jetpacs-triggers--specs))))))

(defun jetpacs-triggers-push ()
  "Debounced `jetpacs-triggers-push-now'.
Registry changes come in bursts — an init file or an automations
reload registering rule after rule — and replace-set means only the
final state matters, so one idle push after the burst replaces a frame
per rule (battery is first-order here).  A no-op while disconnected:
the on-connect push carries the registrations."
  (when (and (jetpacs-connected-p) (not (timerp jetpacs-triggers--push-timer)))
    (setq jetpacs-triggers--push-timer
          (run-with-idle-timer 0.2 nil
                               (lambda ()
                                 (setq jetpacs-triggers--push-timer nil)
                                 (jetpacs-triggers-push-now))))))

(defun jetpacs-triggers--on-fired (args _payload)
  "Dispatch a `trigger.fired' event to its registration's handler.
ARGS carries {id, type, data, at_ms} per SPEC §11."
  (let* ((id (alist-get 'id args))
         (reg (and (stringp id) (gethash id jetpacs-triggers--table)))
         (handler (plist-get reg :handler)))
    (cond
     ((null reg)
      ;; Replace-set means this shouldn't happen; a fire queued before an
      ;; unregister can still race in.  Log, never error.
      (message "Jetpacs: fire for unregistered trigger %s" id))
     (t
      (puthash id (current-time) jetpacs-triggers--last-fired)
      ;; A nil handler is legal: an on_fire-only rule the client tracks
      ;; but doesn't act on.
      (when handler
        (funcall handler (alist-get 'data args) args))))))

(jetpacs-defaction "trigger.fired" #'jetpacs-triggers--on-fired)

;; Management actions for the Automations view (trigger.* is core's
;; namespace, and these are registry operations, so they live here; the
;; view in emacs/apps/jetpacs-automations.el is pure rendering).

(jetpacs-defaction "trigger.toggle"
  (lambda (args _)
    (let ((id (alist-get 'id args)))
      (when (gethash id jetpacs-triggers--table)
        ;; `value' is the switch state the companion injected (SPEC §5).
        (jetpacs-trigger-set-enabled id (eq (alist-get 'value args) t) t)))))

(jetpacs-defaction "trigger.test"
  (lambda (args _)
    (let ((id (alist-get 'id args)))
      (when (gethash id jetpacs-triggers--table)
        (jetpacs-trigger-test-fire id)))))

(defun jetpacs-triggers--on-connect (_welcome)
  "Re-push the trigger set after every handshake (replace-set = idempotent).
Immediate, not debounced: a fresh session must arm without waiting on
idle time."
  (jetpacs-triggers-push-now))

(add-hook 'jetpacs-connected-hook #'jetpacs-triggers--on-connect)

(provide 'jetpacs-triggers)
;;; jetpacs-triggers.el ends here
