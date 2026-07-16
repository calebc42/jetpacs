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

(cl-defun jetpacs-notification-action (label action &key icon dismiss
                                             reply reply-hint reply-key)
  "An action button for a notification `meta.actions' (SPEC §9).
LABEL is the button text; ACTION is a §5 action object (see `jetpacs-action')
dispatched when the button is tapped.

ICON is an optional §9 icon name, best-effort: a companion maps it to a
platform glyph, and modern Android does not draw action icons in the
shade (label only), so never make the icon load-bearing.

DISMISS non-nil cancels the notification when the button is tapped — the
Done / Snooze affordance.

REPLY non-nil turns the button into an inline text reply.  REPLY-HINT is
its placeholder and REPLY-KEY (a string, default \"reply\") the key the
typed text arrives under in the dispatched action's `event.action' `fields'.
A non-nil REPLY-HINT or REPLY-KEY implies REPLY."
  (append `((label . ,label) (on_tap . ,action))
          (when icon    `((icon . ,icon)))
          (when dismiss `((dismiss . t)))
          (when (or reply reply-hint reply-key)
            (let ((input (append (when reply-hint `((hint . ,reply-hint)))
                                 (when reply-key  `((key . ,reply-key))))))
              `((input . ,(or input (make-hash-table :test 'equal))))))))

(cl-defun jetpacs-notification-spec (&key channel ongoing chronometer
                                       priority category body actions)
  "Build a notification surface spec.
CHRONOMETER is an alist like `((base_ms . 1718038200000)).
BODY is a list of UI-tree nodes.  ACTIONS is a list of
`jetpacs-notification-action' entries rendered as the platform
notification's action buttons (SPEC §9)."
  (let ((meta (append
               (when channel     `((channel . ,channel)))
               (when ongoing     `((ongoing . t)))
               (when priority    `((priority . ,priority)))
               (when category    `((category . ,category)))
               (when chronometer `((chronometer . ,chronometer)))
               (when actions     `((actions . ,(vconcat actions)))))))
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
  (jetpacs--claim "surface" surface)
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

(defvar jetpacs--action-catalog (make-hash-table :test 'equal)
  "Map of action NAME -> plist (:args :doc :owner) — metadata only, no handler.")

(defun jetpacs--action-arg-json (a)
  "Serializable form of an action-arg descriptor A (symbol keys)."
  (append (list (cons 'name (format "%s" (plist-get a :name)))
                (cons 'type (plist-get a :type))
                (cons 'required (if (plist-get a :required) t :false)))
          (when (plist-get a :values) (list (cons 'values (plist-get a :values))))))

(cl-defun jetpacs-defaction (name fn &key args doc)
  "Register FN as the handler for action NAME.
FN is called with the action's ARGS-alist and the raw PAYLOAD.  Attributes
NAME to `jetpacs-current-owner' (see `with-jetpacs-owner'); a cross-owner
re-registration warns (or errors under `jetpacs-strict-namespaces').

ARGS, when given, is a closed arg schema — each entry
\(:name SYM :type text|number|enum|date|ref|bool :required BOOL [:values VEC]) —
and DOC a one-line description, published through `jetpacs-action-catalog' so
an editor can enumerate the action.  Metadata is optional and never gates
dispatch; a re-registration without it clears any stale metadata."
  (jetpacs--claim "action" name)
  (puthash name fn jetpacs-action-handlers)
  (if (or args doc)
      (puthash name (list :args args :doc doc :owner jetpacs-current-owner)
               jetpacs--action-catalog)
    (remhash name jetpacs--action-catalog))
  name)

(defun jetpacs-action-catalog (&optional owner)
  "Serializable action metadata (name, doc, args), optionally filtered to OWNER.
Metadata only — never the handler function."
  (let (out)
    (maphash
     (lambda (name meta)
       (when (or (null owner) (equal (plist-get meta :owner) owner))
         (push (append (list (cons 'action name)
                             (cons 'doc (or (plist-get meta :doc) :null)))
                       (when (plist-get meta :args)
                         (list (cons 'args (vconcat (mapcar #'jetpacs--action-arg-json
                                                            (plist-get meta :args)))))))
               out)))
     jetpacs--action-catalog)
    (nreverse out)))

(defvar jetpacs--in-action-handler nil
  "Non-nil while a Jetpacs action handler runs (bound by `jetpacs--on-action').
Read it through the public predicate `jetpacs-in-action-p'.")

(defun jetpacs-in-action-p ()
  "Non-nil when called within the dynamic extent of an action handler.
True only for the synchronous body of a handler; an async continuation a
handler schedules runs after the flag is unbound and so sees nil."
  jetpacs--in-action-handler)

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
  (let* ((action  (alist-get 'action payload))
         (args    (alist-get 'args payload))
         (confirm (alist-get 'confirm payload))
         (fn      (gethash action jetpacs-action-handlers)))
    (if fn
        (progn
          (setq jetpacs--last-action-time (float-time))
          (let ((jetpacs--in-action-handler t)
                (completing-read-function #'completing-read-default)
                (read-file-name-function #'read-file-name-default)
                (read-buffer-function nil)
                (disabled-command-function nil))
            (condition-case err
                ;; The declarative confirm gate (`jetpacs-action' :confirm,
                ;; 1.23.0): prompt via the bridged `y-or-n-p' — a native
                ;; dialog on the companion — before the handler runs.
                ;; Declining is a clean no-op; the gate sits inside the
                ;; in-action-handler binding so the prompt bridges, and
                ;; inside the condition-case so a cancelled dialog (quit)
                ;; aborts quietly like any bridged prompt.
                (if (and (stringp confirm) (not (string-empty-p confirm))
                         (not (y-or-n-p confirm)))
                    (message "Jetpacs action %s declined" action)
                  (funcall fn args payload))
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

(defun jetpacs-ui-state-list (id)
  "The value of widget ID coerced to a list of strings.
A multi-select or enum value arrives as a vector, a list, a plain string, or
a JSON-array string; normalize to a list of strings: nil -> nil; a vector or
list keeps only its string members; a JSON-array string is decoded (keeping
string members); any other string becomes a one-element list; a malformed
JSON-array string and non-string members are discarded."
  (let ((v (jetpacs-ui-state id)))
    (cond
     ((null v) nil)
     ((vectorp v) (seq-filter #'stringp (append v nil)))
     ((consp v) (seq-filter #'stringp v))
     ((stringp v)
      (if (string-match-p "\\`[[:space:]]*\\[" v)
          (let ((parsed (ignore-errors
                          (json-parse-string v :array-type 'list))))
            (and (listp parsed) (seq-filter #'stringp parsed)))
        (list v)))
     (t nil))))

;; ─── Form lifecycle registry ─────────────────────────────────────────────────
;; The reset idiom every dialog needs: seed -> read -> clear.  A field's widget
;; id carries a generation suffix; bumping it on reset is what actually empties
;; the on-device widget (the companion keys field state by id).  Forms are
;; owned, so `jetpacs-app-unregister' disposes them.

(cl-defstruct (jetpacs-form (:constructor jetpacs--make-form) (:copier nil))
  ns (gen 0) owner errors)   ; ERRORS: alist of field-key -> inline error string

(defvar jetpacs--forms (make-hash-table :test 'equal)
  "Registry of \"OWNER\\0NS\" -> `jetpacs-form'.")

(defun jetpacs--form-key (ns owner)
  "The registry key for form NS under OWNER."
  (format "%s\0%s" (or owner "") ns))

(defun jetpacs-form (ns &optional owner)
  "The form for namespace NS under OWNER (default `jetpacs-current-owner').
Created on first use.  NS should be app-unique; field ids are prefixed with
it so one clear resets the whole form."
  (let* ((owner (or owner jetpacs-current-owner))
         (key (jetpacs--form-key ns owner)))
    (or (gethash key jetpacs--forms)
        (puthash key (jetpacs--make-form :ns ns :owner owner) jetpacs--forms))))

(defun jetpacs-form-field-id (form field)
  "The current widget id for FIELD in FORM — \"NS-FIELD-GEN\".
The GEN suffix rotates on `jetpacs-form-reset'."
  (format "%s-%s-%d" (jetpacs-form-ns form) field (jetpacs-form-gen form)))

(defun jetpacs-form-value (form field)
  "The current UI-state value of FIELD in FORM."
  (jetpacs-ui-state (jetpacs-form-field-id form field)))

(defun jetpacs-form-seed (form field value)
  "Set FIELD to VALUE only when it has no value yet (pre-fill an edit dialog)."
  (let ((id (jetpacs-form-field-id form field)))
    (unless (jetpacs-ui-state id) (jetpacs-ui-state-put id value))))

(defun jetpacs-form-reset (form)
  "Clear FORM's field state, inline errors, and subscriptions and rotate gen.
The rotation empties the on-device widgets."
  (let ((prefix (concat (jetpacs-form-ns form) "-")))
    (jetpacs-ui-state-clear prefix)
    (jetpacs-on-state-change-clear prefix))
  (setf (jetpacs-form-errors form) nil)
  (cl-incf (jetpacs-form-gen form)))

(defun jetpacs-form-dispose (form)
  "Reset FORM and drop it from the registry."
  (jetpacs-form-reset form)
  (remhash (jetpacs--form-key (jetpacs-form-ns form) (jetpacs-form-owner form))
           jetpacs--forms))

(defun jetpacs-test-reset-state ()
  "Reset all per-session UI/session state — the test-fixture seam.
Clears the ui-state store, the state-change subscriptions, the form
registry, and the last-action timestamp; when the module is loaded, also
the shell's route params, current tab, and pending snackbar, the async
cache and its pending push timer (`jetpacs-async-reset'), the source
memo cache (`jetpacs-source-invalidate'), and the devtools recording
\(`jetpacs-devtools-reset') — so an ERT fixture gets a pristine session
without binding internals.  Public since 1.23.0 — a Tier 1 test suite
that let-binds `jetpacs--ui-state' and friends is the bug report this
answers; scope completed in 1.24.0.  Never called by the core at
runtime; a live session's state is owned by the connection lifecycle."
  (clrhash jetpacs--ui-state)
  (clrhash jetpacs--state-handlers)
  (clrhash jetpacs--forms)
  ;; 0 = the load-time "no recent action" state; a stale stamp keeps
  ;; `jetpacs-witheditor--phone-initiated-p' true for its whole window.
  (setq jetpacs--last-action-time 0)
  (when (boundp 'jetpacs-shell--route-params)
    (clrhash jetpacs-shell--route-params))
  (when (boundp 'jetpacs-shell--current-tab)
    (setq jetpacs-shell--current-tab nil))
  (when (boundp 'jetpacs-shell--snackbar)
    (setq jetpacs-shell--snackbar nil))
  (when (fboundp 'jetpacs-async-reset)
    (jetpacs-async-reset))
  (when (fboundp 'jetpacs-source-invalidate)
    (jetpacs-source-invalidate))
  (when (fboundp 'jetpacs-devtools-reset)
    (jetpacs-devtools-reset)))

(defun jetpacs--forms-of-owner (owner)
  "The registered forms owned by OWNER."
  (let (forms)
    (maphash (lambda (_k form) (when (equal (jetpacs-form-owner form) owner)
                                 (push form forms)))
             jetpacs--forms)
    forms))

;; ─── Declarative form specs (typed, validated) ───────────────────────────────
;; Grocy's seven dialogs each repeated the same shape: per-field text-inputs, a
;; submit handler that reads each field, parses (string->number), validates, and
;; resets.  A field-spec collapses that: declare the fields once, and get back
;; (a) rendered input nodes and (b) a submit that hands the handler a *parsed,
;; typed, validated* alist — invalid input paints inline field errors and never
;; dispatches.  Builds on the form registry above; no new wire node.

(defvar jetpacs-form-refresh-function nil
  "When non-nil, a nullary function the form layer calls to re-render the
showing surface: after a failed submit stores inline field errors, and after a
date field's picker updates its value.  The shell points this at
`jetpacs-shell-push'; nil (no shell) just leaves the state for the next render.")

(cl-defun jetpacs-field (id type &key label required validate options hint multi)
  "A field spec for `jetpacs-form-render' / `jetpacs-form-submit'.
ID names the field (a symbol or string); the parsed result keys on it as a
symbol.  TYPE is one of the symbols `text', `number', `decimal', `date',
`enum', or `bool'.  LABEL is the field label; REQUIRED demands a non-empty
value; VALIDATE is a function of the *parsed* value returning an error string
\(or nil for OK); OPTIONS are the `enum' choices (strings); HINT is the input
placeholder; MULTI makes an `enum' multi-select (its value is a list).
Returns a plain plist — a bare `(:id … :type …)' plist works too."
  (list :id id :type type :label label :required required :validate validate
        :options options :hint hint :multi multi))

(defun jetpacs-form--key (field)
  "The string field key of FIELD (its :id)."
  (format "%s" (plist-get field :id)))

(defun jetpacs-form--fid (form field)
  "The current widget id for FIELD in FORM (gen-suffixed)."
  (jetpacs-form-field-id form (jetpacs-form--key field)))

(defun jetpacs-form--coerce (type str label)
  "Coerce trimmed, non-empty STR to TYPE; return (VALUE . ERROR)."
  (pcase type
    ('number
     (if (string-match-p "\\`[+-]?[0-9]+\\'" str)
         (cons (string-to-number str) nil)
       (cons nil (format "%s must be a whole number" label))))
    ('decimal
     (if (string-match-p "\\`[+-]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\'" str)
         (cons (string-to-number str) nil)
       (cons nil (format "%s must be a number" label))))
    ('date
     (if (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" str)
         (cons str nil)
       (cons nil (format "%s must be a date (YYYY-MM-DD)" label))))
    (_ (cons str nil))))                ; text

(defun jetpacs-form--parse-field (form field)
  "Return (VALUE . ERROR) for FIELD read from FORM.
Reads the field's raw ui-state, coerces by :type, then applies :required and
:validate.  ERROR nil means the typed VALUE is good."
  (let* ((type     (plist-get field :type))
         (label    (or (plist-get field :label) (jetpacs-form--key field)))
         (required (plist-get field :required))
         (validate (plist-get field :validate))
         (fid      (jetpacs-form--fid form field))
         (res
          (pcase type
            ('enum
             (let ((sel (jetpacs-ui-state-list fid)))
               (if (null sel)
                   (cons nil (and required (format "%s is required" label)))
                 (cons (if (plist-get field :multi) sel (car sel)) nil))))
            ('bool
             (cons (equal "true" (jetpacs-ui-state fid)) nil))
            (_                          ; text/number/decimal/date
             (let* ((raw (jetpacs-ui-state fid))
                    (str (and (stringp raw) (string-trim raw))))
               (if (or (null str) (string-empty-p str))
                   (cons nil (and required (format "%s is required" label)))
                 (jetpacs-form--coerce type str label)))))))
    (cond
     ((cdr res) res)                                        ; already errored
     ((and (null (car res)) (not (eq type 'bool)) (not required)) res) ; absent, optional
     (validate
      (let ((msg (condition-case e (funcall validate (car res))
                   (error (error-message-string e)))))
        (if (stringp msg) (cons (car res) msg) res)))
     (t res))))

(defun jetpacs-form--field-node (form field)
  "Render one FIELD of FORM as an input node, seeded and showing its error."
  (let* ((type  (plist-get field :type))
         (label (plist-get field :label))
         (hint  (plist-get field :hint))
         (fid   (jetpacs-form--fid form field))
         (val   (jetpacs-ui-state fid))
         (err   (cdr (assoc (jetpacs-form--key field) (jetpacs-form-errors form))))
         (input
          (pcase type
            ('number  (jetpacs-text-input fid :value val :label label :hint hint
                                       :keyboard "number"))
            ('decimal (jetpacs-text-input fid :value val :label label :hint hint
                                       :keyboard "decimal"))
            ('bool    (jetpacs-checkbox fid :checked (equal "true" val) :label label))
            ('date
             (apply #'jetpacs-column
                    (delq nil
                          (list (and label (jetpacs-text label 'label))
                                (jetpacs-date-button
                                 (if (and (stringp val) (not (string-empty-p val)))
                                     val (or hint "Pick a date"))
                                 (jetpacs-action "jetpacs.form.set"
                                              :args `((id . ,fid)))
                                 :value (and (stringp val) val))))))
            ('enum
             (apply #'jetpacs-column
                    (delq nil
                          (list (and label (jetpacs-text label 'label))
                                (jetpacs-enum-list
                                 fid (mapcar (lambda (o)
                                               (if (stringp o) o
                                                 (or (plist-get o :value)
                                                     (format "%s" o))))
                                             (plist-get field :options))
                                 :value (jetpacs-ui-state-list fid)
                                 :multi-select (plist-get field :multi))))))
            (_        (jetpacs-text-input fid :value val :label label :hint hint)))))
    (if err
        (jetpacs-column input (jetpacs-text err 'caption nil "error") :spacing 2)
      input)))

(defun jetpacs-form-render (form fields)
  "Render FIELDS (a list of `jetpacs-field' specs) for FORM.
Returns a list of input nodes — seeded from current values and painting any
inline errors a failed submit stored — to splice into your form column.  Pair
it with a submit button dispatching an action built from `jetpacs-form-submit'."
  (mapcar (lambda (field) (jetpacs-form--field-node form field)) fields))

(defun jetpacs-form-submit (form fields handler)
  "Return an `event.action' handler that submits FORM's FIELDS through HANDLER.
The returned function parses and validates every field; on **success** it
resets FORM (clearing the on-device widgets) and calls
\(funcall HANDLER VALUES ARGS), where VALUES is the parsed, typed alist
\((ID . VALUE) …) keyed by each field's :id as a symbol and ARGS is the submit
action's own args (context the app baked in).  On **failure** it stores the
inline field errors, re-renders via `jetpacs-form-refresh-function', and never
calls HANDLER.  Register it: (jetpacs-defaction \"app.save\"
  (jetpacs-form-submit form fields (lambda (values _args) …)))."
  (lambda (args _payload)
    (let (values errors)
      (dolist (field fields)
        (let ((parsed (jetpacs-form--parse-field form field)))
          (if (cdr parsed)
              (push (cons (jetpacs-form--key field) (cdr parsed)) errors)
            (push (cons (intern (jetpacs-form--key field)) (car parsed)) values))))
      (if errors
          (progn
            (setf (jetpacs-form-errors form) (nreverse errors))
            (when (functionp jetpacs-form-refresh-function)
              (funcall jetpacs-form-refresh-function)))
        ;; Clean: reset first (so any push the handler makes shows a fresh
        ;; form), then hand the handler the already-parsed values.
        (jetpacs-form-reset form)
        (funcall handler (nreverse values) args)))))

;; Date fields can't ride `state.changed' (a `date_button' dispatches an
;; action), so their picker writes the chosen date into ui-state through this
;; core action, then refreshes so the button re-renders with the value.
(jetpacs-defaction "jetpacs.form.set"
  (lambda (args _)
    (let ((id (alist-get 'id args)) (value (alist-get 'value args)))
      (when (and id value) (jetpacs-ui-state-put id value)))
    (when (functionp jetpacs-form-refresh-function)
      (funcall jetpacs-form-refresh-function))))

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