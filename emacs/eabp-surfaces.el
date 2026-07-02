;;; eabp-surfaces.el --- Surfaces, UI tree & org-clock for EABP -*- lexical-binding: t; -*-

;; Builds on eabp.el (the transport). Provides:
;;   * UI-tree constructors (text / row / column / button / action)
;;   * surface.update / surface.remove senders, with auto monotonic revisions
;;   * an inbound `event.action' handler + an action dispatch table
;;   * an org-clock integration that pushes a chronometer notification surface
;;
;; Load order: (require 'eabp) then (require 'eabp-surfaces).

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
  "Send a `surface.update' for SURFACE at REVISION with SPEC."
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

(defun eabp-defaction (name fn)
  "Register FN as the handler for action NAME."
  (puthash name fn eabp-action-handlers))

(defun eabp--on-action (payload _frame)
  "Dispatch an inbound `event.action' PAYLOAD to its registered handler.
Binds `eabp--in-action-handler' so minibuffer prompts are intercepted
and forwarded to the companion as dialogs."
  (let* ((action (alist-get 'action payload))
         (args   (alist-get 'args payload))
         (fn     (gethash action eabp-action-handlers)))
    (if fn
        (let ((eabp--in-action-handler t))
          (condition-case err
              (funcall fn args payload)
            ;; Cancelling a bridged prompt raises `quit' (keyboard-quit),
            ;; which `error' does not catch — treat it as a clean abort
            ;; rather than letting it unwind through the process filter.
            (quit (message "EABP action %s cancelled" action))
            (error (message "EABP action %s failed: %s"
                            action (error-message-string err)))))
      (message "EABP: no handler for action %s" action))))

(eabp-register-handler "event.action" #'eabp--on-action)

;; ─── State changed handlers ──────────────────────────────────────────────────

(defvar eabp--state-handlers (make-hash-table :test 'equal)
  "Map of widget id -> callback for state changes.")

(defun eabp-on-state-change (id fn)
  "Register FN to handle state.changed for widget ID."
  (puthash id fn eabp--state-handlers))

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

;; ─── org-clock integration ───────────────────────────────────────────────────

(defun eabp-clock-in-notification ()
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

(defun eabp-clock-out-notification ()
  "Remove the org-clock notification surface."
  (eabp-surface-remove "notification:org-clock"))

;; Closing the loop: a tap on "Clock out" arrives here as an event.action.
(eabp-defaction "org.clock.out"
                (lambda (&rest _) (when (org-clock-is-active) (org-clock-out))))
(eabp-defaction "org.clock.switch"
                ;; Placeholder: jump to the running task. Swap for a real
                ;; task-picker (e.g. org-clock-in to a recent task) when ready.
                (lambda (&rest _) (org-clock-goto)))

(add-hook 'org-clock-in-hook  #'eabp-clock-in-notification)
(add-hook 'org-clock-out-hook #'eabp-clock-out-notification)

;; On (re)connect, re-assert current clock state so the companion's cache
;; matches reality after an Emacs restart. (Runs after the revision snapshot
;; has been absorbed — see the -50 depth above.)
(add-hook 'eabp-connected-hook
          (lambda (_welcome)
            (when (and (fboundp 'org-clock-is-active) (org-clock-is-active))
              (eabp-clock-in-notification))))

;; Initial Dashboard Push
(eval-after-load 'eabp-org-ui
  '(add-hook 'eabp-connected-hook
             (lambda (_) (eabp-org-ui-push-dashboard)) 50))

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