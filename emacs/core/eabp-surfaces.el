;;; eabp-surfaces.el --- Surfaces, actions & UI state for EABP -*- lexical-binding: t; -*-

;; Builds on eabp.el (the transport). Provides:
;;   * surface.update / surface.remove senders, with auto monotonic revisions
;;   * an inbound `event.action' handler + an action dispatch table
;;   * the `state.changed' UI-state store and per-widget change handlers
;;
;; Load order: (require 'eabp) then (require 'eabp-surfaces).
;; No application knowledge lives here: app surfaces (the shell dashboard,
;; the org-clock notification, ...) are pushed by the layers above through
;; the generic senders.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'cl-lib)

;; ─── Monotonic revision counter (survives Emacs restarts) ────────────────────

(defcustom eabp-revision-file
  (expand-file-name "eabp-revision" user-emacs-directory)
  "File holding the last-used surface revision, so revisions stay monotonic
across Emacs restarts (the companion rejects non-newer revisions)."
  :type 'string :group 'eabp)

(defvar eabp--revision nil "Cached in-memory revision counter.")

(defun eabp--revision-load ()
  "Ensure the in-memory counter is initialised from `eabp-revision-file'."
  (unless eabp--revision
    (setq eabp--revision
          (if (file-exists-p eabp-revision-file)
              (string-to-number
               (with-temp-buffer
                 (insert-file-contents eabp-revision-file)
                 (buffer-string)))
            0))))

(defun eabp--revision-persist ()
  "Write the in-memory counter back to `eabp-revision-file'."
  (ignore-errors
    (with-temp-file eabp-revision-file
      (insert (number-to-string eabp--revision)))))

(defun eabp--next-revision ()
  "Return the next monotonic revision, persisting it."
  (eabp--revision-load)
  (setq eabp--revision (1+ eabp--revision))
  (eabp--revision-persist)
  eabp--revision)

(defun eabp--absorb-revision-snapshot (welcome)
  "Raise the local revision counter to the companion's cache floor.
WELCOME is the `session.welcome' payload; its `surfaces' key maps each
cached surface id to the revision the companion holds. This is the
recovery path for a deleted revision file, a fresh machine, or any other
way the local counter could fall behind reality: after this, the next
`eabp--next-revision' is guaranteed newer than anything the companion has,
so updates can never be silently rejected as stale."
  (let ((snapshot (alist-get 'surfaces welcome)))
    (when (consp snapshot)
      (eabp--revision-load)
      (let ((floor (apply #'max 0 (mapcar #'cdr snapshot))))
        (when (> floor eabp--revision)
          (message "EABP: revision counter %d -> %d (companion snapshot)"
                   eabp--revision floor)
          (setq eabp--revision floor)
          (eabp--revision-persist))))))

;; Depth -50: must run before anything else on the hook pushes a surface
;; (e.g. the org-clock re-assert below), or that push could be rejected.
(add-hook 'eabp-connected-hook #'eabp--absorb-revision-snapshot -50)

(cl-defun eabp-notification-spec (&key channel ongoing chronometer
                                       priority category body)
  "Build a notification surface spec.
CHRONOMETER is an alist like `((base_ms . 1718038200000)).
BODY is a list of UI-tree nodes."
  (let ((meta (append
               (when channel     `((channel . ,channel)))
               (when ongoing     `((ongoing . t)))
               (when priority    `((priority . ,priority)))
               (when category    `((category . ,category)))
               (when chronometer `((chronometer . ,chronometer))))))
    `((meta . ,(or meta (make-hash-table :test 'equal)))
      (children . ,(vconcat body)))))

;; ─── Surface senders ─────────────────────────────────────────────────────────

(defun eabp-surface-update (surface revision spec &optional ttl-s stale-spec current-view)
  "Send a `surface.update' for SURFACE at REVISION with SPEC.
When `eabp-lint-on-push' is set (and eabp-lint is loaded), SPEC is
validated first and any invalid node replaced by a visible error node,
so one bad subtree degrades instead of blanking the whole push."
  (when (and (bound-and-true-p eabp-lint-on-push)
             (fboundp 'eabp-lint-spec))
    (let ((problems (eabp-lint-spec spec)))
      (when problems
        (dolist (p problems)
          (display-warning 'eabp (format "surface %s spec lint: %s @ %S"
                                         surface (cdr p) (car p))
                           :warning))
        (setq spec (eabp-lint-sanitize-spec spec)))))
  (eabp-send "surface.update"
             (append `((surface . ,surface) (revision . ,revision) (spec . ,spec))
                     (when ttl-s     `((ttl_s . ,ttl-s)))
                     (when stale-spec `((stale_spec . ,stale-spec)))
                     (when current-view `((current_view . ,current-view))))))

(defun eabp-surface-push (surface spec &optional ttl-s stale-spec current-view)
  "Send SURFACE with an auto-incremented monotonic revision."
  (eabp-surface-update surface (eabp--next-revision) spec ttl-s stale-spec current-view))

(defun eabp-surface-remove (surface)
  "Send a `surface.remove' for SURFACE."
  (eabp-send "surface.remove" `((surface . ,surface))))

;; ─── Inbound actions (companion -> Emacs) ────────────────────────────────────

(defvar eabp-action-handlers (make-hash-table :test 'equal)
  "Map of action name (string) -> function called with (ARGS PAYLOAD).")

;; ─── Registration ownership (multi-tenant collision detection) ───────────────

(defvar eabp-current-owner nil
  "The app/module id currently registering handlers, views, or settings.
Bound by `with-eabp-owner' and `eabp-defapp'.  nil = anonymous (core).
Threaded through the registration seams so two coexisting Tier 1s can't
silently clobber each other's action, view, or settings name.")

(defcustom eabp-strict-namespaces nil
  "When non-nil, a cross-owner registration collision signals an error.
Off by default: collisions warn (via `display-warning') so a mistake is
visible without breaking a load.  Turn on to fail closed."
  :type 'boolean :group 'eabp)

(defvar eabp--registration-owners (make-hash-table :test 'equal)
  "Map of \"KIND:NAME\" -> owner id, backing `eabp--claim'.")

(defun eabp--claim (kind name)
  "Attribute KIND:NAME to `eabp-current-owner'; warn on a cross-owner clash.
Same-owner re-registration (the live-reload case) is silent.  A clash is
when a DIFFERENT explicit owner already holds the name.  Returns NAME."
  (when (and name eabp-current-owner)
    (let* ((key (format "%s:%s" kind name))
           (prev (gethash key eabp--registration-owners)))
      (when (and prev (not (equal prev eabp-current-owner)))
        (let ((msg (format "%s %S is claimed by both `%s' and `%s'"
                           kind name prev eabp-current-owner)))
          (if eabp-strict-namespaces
              (error "EABP namespace collision: %s" msg)
            (display-warning 'eabp msg :warning))))
      (puthash key eabp-current-owner eabp--registration-owners)))
  name)

(defmacro with-eabp-owner (id &rest body)
  "Run BODY with `eabp-current-owner' bound to ID (a string).
Wrap a Tier 1's registrations so its actions/views/settings are
attributed to it and cross-owner collisions are detected."
  (declare (indent 1) (debug (form body)))
  `(let ((eabp-current-owner ,id)) ,@body))

(defun eabp--owned-names (kind owner)
  "List the NAMEs of KIND currently attributed to OWNER."
  (let (names)
    (maphash (lambda (key val)
               (when (and (equal val owner)
                          (string-prefix-p (concat kind ":") key))
                 (push (substring key (1+ (length kind))) names)))
             eabp--registration-owners)
    names))

(defun eabp--unclaim (kind name)
  "Drop the ownership record for KIND:NAME."
  (remhash (format "%s:%s" kind name) eabp--registration-owners))

(defvar eabp--last-action-time 0
  "`float-time' of the most recent dispatched action.
Lets async continuations of a phone-initiated flow (e.g. git calling back
into Emacs for a commit message after `magit-commit' already returned)
distinguish themselves from desktop-initiated activity.")

(defun eabp-defaction (name fn)
  "Register FN as the handler for action NAME.
Attributes NAME to `eabp-current-owner' (see `with-eabp-owner'); a
cross-owner re-registration warns (or errors under
`eabp-strict-namespaces')."
  (eabp--claim "action" name)
  (puthash name fn eabp-action-handlers))

(defun eabp--on-action (payload _frame)
  "Dispatch an inbound `event.action' PAYLOAD to its registered handler.
Binds `eabp--in-action-handler' so minibuffer prompts are intercepted
and forwarded to the companion as dialogs.  Also pins the completion
redirection variables back to their built-ins for the duration: packages
like ivy/counsel/consult reroute prompts through `read-file-name-function'
/ `read-buffer-function' / `completing-read-function' BEFORE the advised
primitives run, and would otherwise reach a keyboard UI the phone can't
drive.  `disabled-command-function' is nil'd so a novice.el disabled
command runs instead of raw-reading a confirmation char (another hang)."
  (let* ((action (alist-get 'action payload))
         (args   (alist-get 'args payload))
         (fn     (gethash action eabp-action-handlers)))
    (if fn
        (progn
          (setq eabp--last-action-time (float-time))
          (let ((eabp--in-action-handler t)
                (completing-read-function #'completing-read-default)
                (read-file-name-function #'read-file-name-default)
                (read-buffer-function nil)
                (disabled-command-function nil))
            (condition-case err
                (funcall fn args payload)
              ;; Cancelling a bridged prompt raises `quit' (keyboard-quit),
              ;; which `error' does not catch — treat it as a clean abort
              ;; rather than letting it unwind through the process filter.
              (quit (message "EABP action %s cancelled" action))
              (error (message "EABP action %s failed: %s"
                              action (error-message-string err))))))
      (message "EABP: no handler for action %s" action))))

(eabp-register-handler "event.action" #'eabp--on-action)

;; ─── State changed handlers ──────────────────────────────────────────────────

(defvar eabp--state-handlers (make-hash-table :test 'equal)
  "Map of widget id -> callback for state changes.")

(defun eabp-on-state-change (id fn)
  "Register FN to handle state.changed for widget ID."
  (puthash id fn eabp--state-handlers))

(defun eabp-on-state-change-clear (prefix)
  "Remove all state.changed subscriptions whose id starts with PREFIX.
The subscription counterpart to `eabp-ui-state-clear'; used by
`eabp-app-unregister' so a torn-down app leaves no live callbacks."
  (let (keys)
    (maphash (lambda (k _v) (when (string-prefix-p prefix k) (push k keys)))
             eabp--state-handlers)
    (dolist (k keys) (remhash k eabp--state-handlers))))

(defvar eabp--ui-state (make-hash-table :test 'equal)
  "Global map of widget id -> current value, updated by `state.changed'.")

(defun eabp-ui-state (id)
  "Get the current value for widget ID."
  (gethash id eabp--ui-state))

(defun eabp-ui-state-put (id val)
  "Set the current value for widget ID."
  (puthash id val eabp--ui-state))

(defun eabp-ui-state-clear (prefix)
  "Clear all UI state keys starting with PREFIX."
  (let ((keys nil))
    (maphash (lambda (k _v)
               (when (string-prefix-p prefix k)
                 (push k keys)))
             eabp--ui-state)
    (dolist (k keys)
      (remhash k eabp--ui-state))))

(defun eabp--on-state-changed (payload _frame)
  "Dispatch inbound `state.changed' to its registered handler."
  (let* ((id (alist-get 'id payload))
         (val (alist-get 'value payload)))
    (puthash id val eabp--ui-state)
    (let ((fn (gethash id eabp--state-handlers)))
      (when fn
        (condition-case err
            (funcall fn val)
          (error (message "EABP state change for %s failed: %s"
                          id (error-message-string err))))))))

(eabp-register-handler "state.changed" #'eabp--on-state-changed)

;; Queue replay is requested by the transport itself (`eabp--on-welcome' in
;; eabp.el) after the connected hooks have run, so replayed events land on a
;; coherent state.  A second request used to live here too; the companion's
;; replay guard absorbed the duplicate, but one requester is enough.

(provide 'eabp-surfaces)

;; Load the minibuffer bridge AFTER `provide' so `eabp-defaction' and the
;; rest of the surfaces infrastructure are available when it registers its
;; prompt.reply / prompt.dismiss action handlers.
;;
;; In the single-file glasspane.el bundle, this require will fail silently,
;; but that's fine because eabp-minibuffer is evaluated immediately afterward.
(require 'eabp-minibuffer nil t)
;;; eabp-surfaces.el ends here