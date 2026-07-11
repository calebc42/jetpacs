;;; jetpacs-surfaces.el --- Surfaces, actions & UI state for Jetpacs -*- lexical-binding: t; -*-

;; Builds on jetpacs.el (the transport). Provides:
;;   * surface.update / surface.remove senders, with auto monotonic revisions
;;   * an inbound `event.action' handler + an action dispatch table
;;   * the `state.changed' UI-state store and per-widget change handlers
;;
;; Load order: (require 'jetpacs) then (require 'jetpacs-surfaces).
;; No application knowledge lives here: app surfaces (the shell dashboard,
;; the org-clock notification, ...) are pushed by the layers above through
;; the generic senders.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'cl-lib)

;; ─── Monotonic revision counter (survives Emacs restarts) ────────────────────

(defcustom jetpacs-revision-file
  (expand-file-name "jetpacs-revision" user-emacs-directory)
  "File holding the last-used surface revision, so revisions stay monotonic
across Emacs restarts (the companion rejects non-newer revisions)."
  :type 'string :group 'jetpacs)

(defvar jetpacs--revision nil "Cached in-memory revision counter.")

(defun jetpacs--revision-load ()
  "Ensure the in-memory counter is initialised from `jetpacs-revision-file'."
  (unless jetpacs--revision
    (setq jetpacs--revision
          (if (file-exists-p jetpacs-revision-file)
              (string-to-number
               (with-temp-buffer
                 (insert-file-contents jetpacs-revision-file)
                 (buffer-string)))
            0))))

(defun jetpacs--revision-persist ()
  "Write the in-memory counter back to `jetpacs-revision-file'."
  (ignore-errors
    (with-temp-file jetpacs-revision-file
      (insert (number-to-string jetpacs--revision)))))

(defun jetpacs--next-revision ()
  "Return the next monotonic revision, persisting it."
  (jetpacs--revision-load)
  (setq jetpacs--revision (1+ jetpacs--revision))
  (jetpacs--revision-persist)
  jetpacs--revision)

(defun jetpacs--absorb-revision-snapshot (welcome)
  "Raise the local revision counter to the companion's cache floor.
WELCOME is the `session.welcome' payload; its `surfaces' key maps each
cached surface id to the revision the companion holds. This is the
recovery path for a deleted revision file, a fresh machine, or any other
way the local counter could fall behind reality: after this, the next
`jetpacs--next-revision' is guaranteed newer than anything the companion has,
so updates can never be silently rejected as stale."
  (let ((snapshot (alist-get 'surfaces welcome)))
    (when (consp snapshot)
      (jetpacs--revision-load)
      (let ((floor (apply #'max 0 (mapcar #'cdr snapshot))))
        (when (> floor jetpacs--revision)
          (message "Jetpacs: revision counter %d -> %d (companion snapshot)"
                   jetpacs--revision floor)
          (setq jetpacs--revision floor)
          (jetpacs--revision-persist))))))

;; Depth -50: must run before anything else on the hook pushes a surface
;; (e.g. the org-clock re-assert below), or that push could be rejected.
(add-hook 'jetpacs-connected-hook #'jetpacs--absorb-revision-snapshot -50)

(cl-defun jetpacs-notification-spec (&key channel ongoing chronometer
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

(defun jetpacs-surface-update (surface revision spec &optional ttl-s stale-spec current-view)
  "Send a `surface.update' for SURFACE at REVISION with SPEC.
When `jetpacs-lint-on-push' is set (and jetpacs-lint is loaded), SPEC is
validated first and any invalid node replaced by a visible error node,
so one bad subtree degrades instead of blanking the whole push."
  (when (and (bound-and-true-p jetpacs-lint-on-push)
             (fboundp 'jetpacs-lint-spec))
    (let ((problems (jetpacs-lint-spec spec)))
      (when problems
        (dolist (p problems)
          (display-warning 'jetpacs (format "surface %s spec lint: %s @ %S"
                                         surface (cdr p) (car p))
                           :warning))
        (setq spec (jetpacs-lint-sanitize-spec spec)))))
  (jetpacs-send "surface.update"
             (append `((surface . ,surface) (revision . ,revision) (spec . ,spec))
                     (when ttl-s     `((ttl_s . ,ttl-s)))
                     (when stale-spec `((stale_spec . ,stale-spec)))
                     (when current-view `((current_view . ,current-view))))))

(defun jetpacs-surface-push (surface spec &optional ttl-s stale-spec current-view)
  "Send SURFACE with an auto-incremented monotonic revision."
  (jetpacs-surface-update surface (jetpacs--next-revision) spec ttl-s stale-spec current-view))

(defun jetpacs-surface-remove (surface)
  "Send a `surface.remove' for SURFACE."
  (jetpacs-send "surface.remove" `((surface . ,surface))))

;; ─── Inbound actions (companion -> Emacs) ────────────────────────────────────

(defvar jetpacs-action-handlers (make-hash-table :test 'equal)
  "Map of action name (string) -> function called with (ARGS PAYLOAD).")

;; ─── Registration ownership (multi-tenant collision detection) ───────────────

(defvar jetpacs-current-owner nil
  "The app/module id currently registering handlers, views, or settings.
Bound by `with-jetpacs-owner' and `jetpacs-defapp'.  nil = anonymous (core).
Threaded through the registration seams so two coexisting Tier 1s can't
silently clobber each other's action, view, or settings name.")

(defcustom jetpacs-strict-namespaces nil
  "When non-nil, a cross-owner registration collision signals an error.
Off by default: collisions warn (via `display-warning') so a mistake is
visible without breaking a load.  Turn on to fail closed."
  :type 'boolean :group 'jetpacs)

(defvar jetpacs--registration-owners (make-hash-table :test 'equal)
  "Map of \"KIND:NAME\" -> owner id, backing `jetpacs--claim'.")

(defun jetpacs--claim (kind name)
  "Attribute KIND:NAME to `jetpacs-current-owner'; warn on a cross-owner clash.
Same-owner re-registration (the live-reload case) is silent.  A clash is
when a DIFFERENT explicit owner already holds the name.  Returns NAME."
  (when (and name jetpacs-current-owner)
    (let* ((key (format "%s:%s" kind name))
           (prev (gethash key jetpacs--registration-owners)))
      (when (and prev (not (equal prev jetpacs-current-owner)))
        (let ((msg (format "%s %S is claimed by both `%s' and `%s'"
                           kind name prev jetpacs-current-owner)))
          (if jetpacs-strict-namespaces
              (error "Jetpacs namespace collision: %s" msg)
            (display-warning 'jetpacs msg :warning))))
      (puthash key jetpacs-current-owner jetpacs--registration-owners)))
  name)

(defmacro with-jetpacs-owner (id &rest body)
  "Run BODY with `jetpacs-current-owner' bound to ID (a string).
Wrap a Tier 1's registrations so its actions/views/settings are
attributed to it and cross-owner collisions are detected."
  (declare (indent 1) (debug (form body)))
  `(let ((jetpacs-current-owner ,id)) ,@body))

(defun jetpacs--owner-of (kind name)
  "The owner id attributed to KIND:NAME, or nil when unclaimed/core."
  (gethash (format "%s:%s" kind name) jetpacs--registration-owners))

(defun jetpacs--owned-names (kind owner)
  "List the NAMEs of KIND currently attributed to OWNER."
  (let (names)
    (maphash (lambda (key val)
               (when (and (equal val owner)
                          (string-prefix-p (concat kind ":") key))
                 (push (substring key (1+ (length kind))) names)))
             jetpacs--registration-owners)
    names))

(defun jetpacs--unclaim (kind name)
  "Drop the ownership record for KIND:NAME."
  (remhash (format "%s:%s" kind name) jetpacs--registration-owners))

(defvar jetpacs--last-action-time 0
  "`float-time' of the most recent dispatched action.
Lets async continuations of a phone-initiated flow (e.g. git calling back
into Emacs for a commit message after `magit-commit' already returned)
distinguish themselves from desktop-initiated activity.")

(defun jetpacs-defaction (name fn)
  "Register FN as the handler for action NAME.
Attributes NAME to `jetpacs-current-owner' (see `with-jetpacs-owner'); a
cross-owner re-registration warns (or errors under
`jetpacs-strict-namespaces')."
  (jetpacs--claim "action" name)
  (puthash name fn jetpacs-action-handlers))

(defun jetpacs--on-action (payload _frame)
  "Dispatch an inbound `event.action' PAYLOAD to its registered handler.
Binds `jetpacs--in-action-handler' so minibuffer prompts are intercepted
and forwarded to the companion as dialogs.  Also pins the completion
redirection variables back to their built-ins for the duration: packages
like ivy/counsel/consult reroute prompts through `read-file-name-function'
/ `read-buffer-function' / `completing-read-function' BEFORE the advised
primitives run, and would otherwise reach a keyboard UI the phone can't
drive.  `disabled-command-function' is nil'd so a novice.el disabled
command runs instead of raw-reading a confirmation char (another hang)."
  (let* ((action (alist-get 'action payload))
         (args   (alist-get 'args payload))
         (fn     (gethash action jetpacs-action-handlers)))
    (if fn
        (progn
          (setq jetpacs--last-action-time (float-time))
          (let ((jetpacs--in-action-handler t)
                (completing-read-function #'completing-read-default)
                (read-file-name-function #'read-file-name-default)
                (read-buffer-function nil)
                (disabled-command-function nil))
            (condition-case err
                (funcall fn args payload)
              ;; Cancelling a bridged prompt raises `quit' (keyboard-quit),
              ;; which `error' does not catch — treat it as a clean abort
              ;; rather than letting it unwind through the process filter.
              (quit (message "Jetpacs action %s cancelled" action))
              (error (message "Jetpacs action %s failed: %s"
                              action (error-message-string err))))))
      (message "Jetpacs: no handler for action %s" action))))

(jetpacs-register-handler "event.action" #'jetpacs--on-action)

;; ─── State changed handlers ──────────────────────────────────────────────────

(defvar jetpacs--state-handlers (make-hash-table :test 'equal)
  "Map of widget id -> callback for state changes.")

(defun jetpacs-on-state-change (id fn)
  "Register FN to handle state.changed for widget ID."
  (puthash id fn jetpacs--state-handlers))

(defun jetpacs-on-state-change-clear (prefix)
  "Remove all state.changed subscriptions whose id starts with PREFIX.
The subscription counterpart to `jetpacs-ui-state-clear'; used by
`jetpacs-app-unregister' so a torn-down app leaves no live callbacks."
  (let (keys)
    (maphash (lambda (k _v) (when (string-prefix-p prefix k) (push k keys)))
             jetpacs--state-handlers)
    (dolist (k keys) (remhash k jetpacs--state-handlers))))

(defvar jetpacs--ui-state (make-hash-table :test 'equal)
  "Global map of widget id -> current value, updated by `state.changed'.")

(defun jetpacs-ui-state (id)
  "Get the current value for widget ID."
  (gethash id jetpacs--ui-state))

(defun jetpacs-ui-state-put (id val)
  "Set the current value for widget ID."
  (puthash id val jetpacs--ui-state))

(defun jetpacs-ui-state-clear (prefix)
  "Clear all UI state keys starting with PREFIX."
  (let ((keys nil))
    (maphash (lambda (k _v)
               (when (string-prefix-p prefix k)
                 (push k keys)))
             jetpacs--ui-state)
    (dolist (k keys)
      (remhash k jetpacs--ui-state))))

(defun jetpacs--on-state-changed (payload _frame)
  "Dispatch inbound `state.changed' to its registered handler."
  (let* ((id (alist-get 'id payload))
         (val (alist-get 'value payload)))
    (puthash id val jetpacs--ui-state)
    (let ((fn (gethash id jetpacs--state-handlers)))
      (when fn
        (condition-case err
            (funcall fn val)
          (error (message "Jetpacs state change for %s failed: %s"
                          id (error-message-string err))))))))

(jetpacs-register-handler "state.changed" #'jetpacs--on-state-changed)

;; Queue replay is requested by the transport itself (`jetpacs--on-welcome' in
;; jetpacs.el) after the connected hooks have run, so replayed events land on a
;; coherent state.  A second request used to live here too; the companion's
;; replay guard absorbed the duplicate, but one requester is enough.

(provide 'jetpacs-surfaces)

;; Load the minibuffer bridge AFTER `provide' so `jetpacs-defaction' and the
;; rest of the surfaces infrastructure are available when it registers its
;; prompt.reply / prompt.dismiss action handlers.
;;
;; In the single-file glasspane.el bundle, this require will fail silently,
;; but that's fine because jetpacs-minibuffer is evaluated immediately afterward.
(require 'jetpacs-minibuffer nil t)
;;; jetpacs-surfaces.el ends here