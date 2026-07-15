;;; jetpacs.el --- Emacs-Android Bridge Protocol client -*- lexical-binding: t; -*-

;; Version: 1.12.0
;; Package-Requires: ((emacs "30.1"))
;; URL: https://github.com/calebc42/jetpacs

;; The Version: header MUST equal `jetpacs-api-version' (a test pins it):
;; a `package-vc-install' of this repo reports the same number the API
;; constant promises.  Install straight from git, no MELPA needed:
;;
;;   (package-vc-install
;;    '(jetpacs :url "https://github.com/calebc42/jetpacs"
;;              :lisp-dir "emacs/core"))
;;
;; `:lisp-dir' scopes the install to the multi-file core, so package.el
;; never sees the generated root bundle jetpacs-core.el.

;; Jetpacs transport, Emacs side. Under the protocol Emacs is the CLIENT and the
;; Android companion is the durable SERVER. This file owns the wire: connecting,
;; framing, the session handshake, and a generic send/request layer that the
;; surface/capability/trigger code (later phases) builds on.
;;
;; v0 framing is newline-delimited JSON over a loopback TCP socket, which the
;; spec blesses for prototyping. The 1.0 target is a Unix domain socket
;; (:family 'local) in a shared-signature dir; only `jetpacs--make-process'
;; changes for that. Everything above the process stays the same.
;;
;; Requires Emacs 28+ for the C-level `json-serialize' / `json-parse-string'
;; (well-defined null/false handling) and `string-search'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup jetpacs nil
  "Emacs-Android Bridge Protocol."
  :group 'comm)

(defcustom jetpacs-host "127.0.0.1"
  "Host of the companion's Jetpacs server (loopback in v0)."
  :type 'string :group 'jetpacs)

(defcustom jetpacs-port 8765
  "TCP port the companion's Jetpacs server listens on (v0).
Note: this is NOT the old simple-httpd port (8080). The companion now
listens; Emacs dials in here."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-protocol-version 1
  "Jetpacs protocol version this client speaks.
This is the wire/vocabulary version — the envelope `v' and the SPEC's
version number.  Bump it only on a wire-breaking change."
  :type 'integer :group 'jetpacs)

(defconst jetpacs-api-version "1.12.0"
  "Semver of the Tier 1 elisp API surface (constructors + seams).
Independent of `jetpacs-protocol-version' (the wire).  A third-party Tier 1
requires the core and checks this: minor bumps are additive and safe,
major bumps may remove a symbol one minor cycle after it is marked
obsolete.  The frozen public-symbol list lives in docs/API-STABILITY.md.")

(defcustom jetpacs-wants
  '("surfaces.widget" "surfaces.notification" "surfaces.dialog"
    "capabilities" "triggers" "queue.replay" "theme" "reminders.owner")
  "Capability set Emacs requests during the handshake.
The companion grants the intersection with what it supports; anything it
doesn't recognise is simply not granted (forward-compat)."
  :type '(repeat string) :group 'jetpacs)

(defcustom jetpacs-auth-token nil
  "Pairing token from the companion app's pairing screen.
The companion challenges every connection; this token (never sent on
the wire — only nonce-bound HMACs are) answers the challenge, and the
companion proves it holds the same token back before the session is
trusted.  Copy the ready-made setq line by tapping it on the app's
\"Waiting for Emacs\" screen.  nil leaves the bridge unpaired: connects
are refused with guidance in *Messages*."
  :type '(choice (const :tag "Unpaired" nil) string)
  :group 'jetpacs)

(defvar jetpacs--process nil
  "The live network process, or nil when disconnected.")

(defvar jetpacs--auth-server-nonce nil
  "Server nonce of the in-flight auth round, or nil.")

(defvar jetpacs--auth-client-nonce nil
  "Our nonce for the in-flight auth round, or nil.")

(defvar jetpacs--buffer ""
  "Accumulates partial inbound NDJSON bytes between filter calls.")

(defvar jetpacs--id-counter 0
  "Monotonic source for sender-unique message ids.")

(defvar jetpacs--pending (make-hash-table :test 'equal)
  "Map of outstanding request id -> reply callback.")

(defvar jetpacs--session nil
  "Alist of negotiated session info after `session.welcome', or nil.")

(defvar jetpacs-connected-hook nil
  "Hook run with the welcome payload (alist) after a successful handshake.")

;; ─── Envelope ────────────────────────────────────────────────────────────────

(defun jetpacs--next-id ()
  "Return a fresh sender-unique message id."
  (format "m-%x-%04x" (cl-incf jetpacs--id-counter) (random #x10000)))

(defun jetpacs--encode (kind payload &optional reply-to id)
  "Encode one Jetpacs frame to a compact JSON string.
PAYLOAD is an alist (or nil for an empty object). REPLY-TO is the id this
frame answers, or nil for a top-level message."
  (json-serialize
   `((v . ,jetpacs-protocol-version)
     (id . ,(or id (jetpacs--next-id)))
     (reply_to . ,(or reply-to :null))
     (kind . ,kind)
     (payload . ,(or payload (make-hash-table :test 'equal))))
   :null-object :null
   :false-object :false))

(defun jetpacs--raw-send (line)
  "Write LINE plus a newline to the companion if connected.
Never signals: the liveness check races the async connect and its
failure sentinel (the process can die between the check and the write),
and a send must degrade to a dropped frame — the wire is fire-and-forget,
so no caller is prepared for an error out of a send."
  (if (and jetpacs--process (process-live-p jetpacs--process))
      (condition-case err
          (process-send-string jetpacs--process (concat line "\n"))
        (error (message "Jetpacs: send failed; dropping frame (%s)"
                        (error-message-string err))))
    (message "Jetpacs: not connected; dropping frame")))

(defun jetpacs-send (kind &optional payload reply-to)
  "Send a fire-and-forget frame. Returns its message id."
  (let ((id (jetpacs--next-id)))
    (jetpacs--raw-send (jetpacs--encode kind payload reply-to id))
    id))

(defun jetpacs-request (kind payload callback)
  "Send a frame and call CALLBACK with the reply frame's payload alist.
Correlation is by `reply_to' matching this frame's id.  When
disconnected the frame is dropped and CALLBACK is never registered —
otherwise every dropped request would leak a pending-table entry."
  (let ((id (jetpacs--next-id)))
    (if (and jetpacs--process (process-live-p jetpacs--process))
        (progn
          (puthash id callback jetpacs--pending)
          (jetpacs--raw-send (jetpacs--encode kind payload nil id)))
      (message "Jetpacs: not connected; dropping request %s" kind))
    id))

(defcustom jetpacs-dialog-style nil
  "Default presentation for companion dialogs (SPEC §7).
nil renders the centered dialog window; \"sheet\" renders the same spec
as a modal bottom sheet (the native mobile idiom for pickers and
menus); \"sheet_full\" opens the sheet fully expanded.  Old companions
ignore the style and show the centered dialog."
  :type '(choice (const :tag "Centered dialog" nil)
                 (const :tag "Bottom sheet" "sheet")
                 (const :tag "Bottom sheet, fully expanded" "sheet_full"))
  :group 'jetpacs)

(defun jetpacs-send-dialog (spec &optional style)
  "Push a dialog SPEC to the companion.
STYLE overrides `jetpacs-dialog-style' for this dialog: nil for the
centered window, \"sheet\" or \"sheet_full\" for a bottom sheet.  The
style rides the spec root as `dialog_style' — additive, so an old
companion just shows the centered dialog."
  (let ((style (or style jetpacs-dialog-style)))
    (jetpacs-send "dialog.show"
                  (if style (cons (cons 'dialog_style style) spec) spec))))

(defun jetpacs-dismiss-dialog ()
  "Dismiss the current dialog on the companion."
  (jetpacs-send "dialog.dismiss" nil))

;; ─── Pairing auth ────────────────────────────────────────────────────────────

(defun jetpacs--hmac-sha256-hex (key message)
  "RFC 2104 HMAC-SHA256 of MESSAGE keyed by KEY, as lowercase hex.
Pure elisp over `secure-hash', so it works on any build (the native
Android port has no guaranteed gnutls MAC support).  KEY and MESSAGE
are encoded as UTF-8."
  (let* ((block 64)
         (raw (encode-coding-string key 'utf-8 t))
         (raw (if (> (length raw) block)
                  (secure-hash 'sha256 raw nil nil t)
                raw))
         (raw (concat raw (make-string (- block (length raw)) 0)))
         (ipad (apply #'unibyte-string
                      (mapcar (lambda (c) (logxor c #x36)) raw)))
         (opad (apply #'unibyte-string
                      (mapcar (lambda (c) (logxor c #x5c)) raw))))
    (secure-hash 'sha256
                 (concat opad
                         (secure-hash 'sha256
                                      (concat ipad (encode-coding-string
                                                    message 'utf-8 t))
                                      nil nil t)))))

(defun jetpacs--paired-p ()
  "Non-nil when a non-empty pairing token is configured.
When nil the bridge runs unpaired: the companion is not challenged and any
welcome is accepted (the legacy path — the companion won't send one anyway)."
  (and (stringp jetpacs-auth-token) (not (string-empty-p jetpacs-auth-token))))

(defun jetpacs--auth-nonce ()
  "A fresh nonce (64 hex chars).  Needs uniqueness, not secrecy."
  (secure-hash 'sha256 (format "%s:%s:%s:%s"
                               (random most-positive-fixnum)
                               (float-time) (emacs-pid) (current-time-string))))

(defun jetpacs--on-auth-challenge (payload)
  "Answer the companion's pairing challenge from PAYLOAD."
  (let ((snonce (alist-get 'nonce payload)))
    (cond
     ((not (stringp snonce))
      (message "Jetpacs: malformed auth challenge"))
     ((not (jetpacs--paired-p))
      (message (concat "Jetpacs: pairing required — open the companion app, tap "
                       "the (setq jetpacs-auth-token ...) line on its pairing "
                       "screen, add it to your init, and reconnect")))
     (t
      (setq jetpacs--auth-server-nonce snonce
            jetpacs--auth-client-nonce (jetpacs--auth-nonce))
      (jetpacs-send "auth.response"
                 `((nonce . ,jetpacs--auth-client-nonce)
                   (mac . ,(jetpacs--hmac-sha256-hex
                            jetpacs-auth-token
                            (format "jetpacs1:client:%s:%s"
                                    snonce jetpacs--auth-client-nonce)))))))))

(defun jetpacs--auth-verify-welcome (payload)
  "Non-nil when PAYLOAD's server_proof matches our challenge state.
Fails closed: once a token is configured, a welcome without a valid
proof — a companion that skipped the challenge, or a rogue app squatting
the port — is refused.  With no token configured, any welcome passes
\(the unpaired legacy path; the companion won't send one anyway)."
  (or (not (jetpacs--paired-p))
      (and jetpacs--auth-server-nonce jetpacs--auth-client-nonce
           (equal (alist-get 'server_proof payload)
                  (jetpacs--hmac-sha256-hex
                   jetpacs-auth-token
                   (format "jetpacs1:server:%s:%s"
                           jetpacs--auth-client-nonce
                           jetpacs--auth-server-nonce))))))

;; ─── Inbound framing & dispatch ──────────────────────────────────────────────

(defun jetpacs--filter (_proc chunk)
  "Accumulate CHUNK and handle every complete newline-terminated frame.
Partial frames stay buffered until the rest arrives."
  (setq jetpacs--buffer (concat jetpacs--buffer chunk))
  (let (pos)
    (while (setq pos (string-search "\n" jetpacs--buffer))
      (let ((line (substring jetpacs--buffer 0 pos)))
        (setq jetpacs--buffer (substring jetpacs--buffer (1+ pos)))
        (unless (string-empty-p (string-trim line))
          (jetpacs--handle-line line))))))

(defun jetpacs--handle-line (line)
  "Parse one JSON LINE into a frame and route it."
  (condition-case err
      (let* ((frame (json-parse-string
                     line
                     :object-type 'alist :array-type 'list
                     :null-object :null :false-object :false))
             (kind (alist-get 'kind frame))
             (reply-to (alist-get 'reply_to frame))
             (payload (alist-get 'payload frame)))
        ;; Resolve any waiting request first.
        (when (and reply-to (not (eq reply-to :null)))
          (when-let ((cb (gethash reply-to jetpacs--pending)))
            (remhash reply-to jetpacs--pending)
            (funcall cb payload)))
        (jetpacs--dispatch kind payload frame))
    (error (message "Jetpacs: bad frame: %s" (error-message-string err)))))

(defvar jetpacs--kind-handlers (make-hash-table :test 'equal)
  "Map of frame kind (string) -> handler called with (PAYLOAD FRAME).
Extension point for the layers above the transport (surfaces, queue,
capabilities): they register here instead of patching `jetpacs--dispatch'.")

(defun jetpacs-register-handler (kind fn)
  "Register FN as the handler for inbound frames of KIND.
FN is called with two arguments, the frame's PAYLOAD alist and the full
FRAME alist. A later registration for the same KIND replaces the earlier
one. Built-in kinds (session.welcome, ping/pong, ack, error) are handled
by the transport itself and cannot be overridden here."
  (puthash kind fn jetpacs--kind-handlers))

(defun jetpacs--dispatch (kind payload frame)
  "Route a frame by KIND: built-ins first, then registered handlers."
  (pcase kind
    ("auth.challenge" (jetpacs--on-auth-challenge payload))
    ("session.welcome" (jetpacs--on-welcome payload))
    ("ping" (jetpacs-send "pong" nil (alist-get 'id frame)))
    ("pong" nil)
    ;; Bare acks (e.g. to fire-and-forget surface.updates) are expected
    ;; noise; anything that wanted the ack used `jetpacs-request'.
    ("ack" nil)
    ;; Reply-only kind: consumed by the pending map above (SPEC §10).
    ("capability.result" nil)
    ("queue.drained"
     (message "Jetpacs: replay complete (%s delivered, %s expired)"
              (or (alist-get 'delivered payload) 0)
              (or (alist-get 'expired payload) 0))
     (run-hook-with-args 'jetpacs-queue-drained-hook payload))
    ("error"
     (message "Jetpacs error [%s]: %s"
              (alist-get 'code payload) (alist-get 'detail payload)))
    (_
     (if-let ((fn (gethash kind jetpacs--kind-handlers)))
         (condition-case err
             (funcall fn payload frame)
           (error (message "Jetpacs: handler for %s failed: %s"
                           kind (error-message-string err))))
       (message "Jetpacs: unhandled kind %s" kind)))))

(defvar jetpacs-queue-drained-hook nil
  "Hook run with the `queue.drained' payload after a replay completes.
Replayed events may have mutated org state; UI layers re-push here.")

(defun jetpacs--on-welcome (payload)
  "Record the negotiated session from a `session.welcome' PAYLOAD.
Refuses the session outright when the server's pairing proof is missing
or wrong — nothing is trusted from an unproven peer."
  (if (not (jetpacs--auth-verify-welcome payload))
      (progn
        (message (concat "Jetpacs: server failed pairing proof — refusing the "
                         "session. Is something impersonating the companion, "
                         "or does the app predate pairing support?"))
        (when jetpacs--process (delete-process jetpacs--process)))
    (setq jetpacs--auth-server-nonce nil
          jetpacs--auth-client-nonce nil)
    (setq jetpacs--session payload)
    (let ((granted (alist-get 'granted payload))
          (queued  (or (alist-get 'queued_events payload) 0)))
      (message "Jetpacs: handshake ok. granted=%s queued_events=%s" granted queued)
      (run-hook-with-args 'jetpacs-connected-hook payload)
      ;; Request replay AFTER the connected hooks: the revision snapshot has
      ;; been absorbed and initial surfaces pushed, so replayed events land
      ;; on a coherent state.
      (when (> queued 0)
        (jetpacs-send "queue.replay")))))

;; ─── Session queries & device capabilities (SPEC §10) ────────────────────────

(defun jetpacs-granted-p (capability)
  "Non-nil when the current session granted CAPABILITY (a string).
Layers gate their pushes on this: a companion that doesn't grant
`triggers' never receives a `triggers.set', per the negotiation rule."
  (and jetpacs--session
       (member capability (alist-get 'granted jetpacs--session))
       t))

(defun jetpacs-node-supported-p (node-type)
  "Non-nil when the connected companion renders NODE-TYPE (string or symbol).
Reads the welcome's `node_types' catalog (SPEC §3, §9).  A Tier 1 gates
a newer node on this and renders a fallback when it is unsupported:

  (if (jetpacs-node-supported-p \\='chart)
      (my/chart data)
    (my/chart-fallback-table data))

Returns non-nil PERMISSIVELY when the companion sent no catalog at all —
an older companion predating node negotiation must not be treated as
supporting nothing.  Support is positive knowledge only: a present
catalog that omits NODE-TYPE returns nil."
  (let ((catalog (alist-get 'node_types jetpacs--session))
        (name (if (symbolp node-type) (symbol-name node-type) node-type)))
    (cond ((null jetpacs--session) nil)   ; not connected
          ((null catalog) t)           ; companion predates negotiation
          (t (and (seq-contains-p catalog name) t)))))

(defmacro jetpacs-node-or (node-type primary fallback)
  "Evaluate PRIMARY when the companion renders NODE-TYPE, else FALLBACK.
Only one branch runs; both are local node-building forms (never wire data).
A disconnected companion, or a connected one whose catalog omits NODE-TYPE,
takes FALLBACK; a connected companion that sent no catalog at all is treated
permissively and takes PRIMARY (see `jetpacs-node-supported-p')."
  (declare (indent 1))
  `(if (jetpacs-node-supported-p ,node-type) ,primary ,fallback))

(defconst jetpacs--build-feature-probes
  '((sqlite      . sqlite-available-p)
    (treesit     . treesit-available-p)
    (native-comp . native-comp-available-p)
    (libxml      . libxml-available-p))
  "The known optional-build features and the predicate probing each.
The car set is the whole vocabulary of `jetpacs-build-features' — a flat
list of symbols on purpose, so it never grows into a second negotiation
vocabulary (no versions, no metadata).")

(defconst jetpacs-build-features
  (let (features)
    (dolist (probe jetpacs--build-feature-probes)
      (when (and (fboundp (cdr probe))
                 (ignore-errors (funcall (cdr probe))))
        (push (car probe) features)))
    (nreverse features))
  "Optional compile-time features the running Emacs build actually has.
A version floor is not a build guarantee: sqlite, tree-sitter, native
compilation and libxml are compile-time options of the particular
binary, so anything that would use them needs positive knowledge — the
same discipline as the welcome's `node_types'.  This is a REPORTING
surface only: nothing in the core gates on it, and consumers keep their
feature-local guards (e.g. `(sqlite-available-p)') at the point of
consumption, exactly as before.  Echoed to the companion in the
`session.hello' `features' field so build skew shows up in logs the
way version skew already does.")

(defun jetpacs-feature-p (feature)
  "Non-nil when the running Emacs build has FEATURE (symbol or string).
Membership in `jetpacs-build-features'; see there for what this is
\(and is not) for."
  (and (memq (if (stringp feature) (intern feature) feature)
             jetpacs-build-features)
       t))

(defun jetpacs-device-caps ()
  "Capability names invocable via `jetpacs-capability-invoke', or nil.
From the welcome's `device' report; empty until a session with the
`capabilities' grant is up."
  (alist-get 'caps (alist-get 'device jetpacs--session)))

(defun jetpacs-device-cap-p (cap)
  "Non-nil when the companion offers device capability CAP (a string)."
  (and (member cap (jetpacs-device-caps)) t))

(defun jetpacs-device-can-p (perm)
  "Non-nil when the companion reports device permission PERM as granted.
PERM is a string or symbol keying the welcome's `device.perms' map,
e.g. \"write_settings\".  The map is a welcome-time snapshot — the
companion re-checks at invoke time, so this is for degrading UI
gracefully, not for enforcement."
  (eq t (alist-get (if (symbolp perm) perm (intern perm))
                   (alist-get 'perms (alist-get 'device jetpacs--session)))))

(defun jetpacs-capability-invoke (cap &optional args callback)
  "Invoke device capability CAP (a string) with plain-data alist ARGS.
CALLBACK, when non-nil, receives (OK PAYLOAD): OK is non-nil iff the
invoke succeeded; PAYLOAD is the `capability.result' payload on
success, or the error payload (`code', `detail', and for
cap-permission possibly `perm' / `settings') on failure.  When
disconnected the frame is dropped like any other request."
  (jetpacs-request "capability.invoke"
                `((cap . ,cap)
                  (args . ,(or args (make-hash-table :test 'equal))))
                (lambda (payload)
                  (when callback
                    (funcall callback
                             (eq t (alist-get 'ok payload))
                             payload)))))

;; ─── Connection lifecycle ────────────────────────────────────────────────────

(defcustom jetpacs-reconnect t
  "When non-nil, automatically reconnect after losing the companion.
On Android the OS routinely pauses Emacs and kills its sockets; auto
reconnect (with backoff) is what makes the bridge feel always-on."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-reconnect-initial-delay 5
  "Seconds to wait before the first reconnect attempt."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-reconnect-max-delay 60
  "Ceiling for the reconnect backoff, in seconds."
  :type 'integer :group 'jetpacs)

(defvar jetpacs--reconnect-timer nil)
(defvar jetpacs--reconnect-delay 5)
(defvar jetpacs--user-disconnected nil
  "Non-nil after an explicit `jetpacs-disconnect'; suppresses auto-reconnect.")

(defun jetpacs--cancel-reconnect ()
  (when (timerp jetpacs--reconnect-timer)
    (cancel-timer jetpacs--reconnect-timer))
  (setq jetpacs--reconnect-timer nil))

(defun jetpacs--schedule-reconnect ()
  "Arm the reconnect timer with exponential backoff."
  (when (and jetpacs-reconnect
             (not jetpacs--user-disconnected)
             (not jetpacs--reconnect-timer))
    (setq jetpacs--reconnect-timer
          (run-at-time jetpacs--reconnect-delay nil #'jetpacs--reconnect-attempt))
    (setq jetpacs--reconnect-delay
          (min (* 2 jetpacs--reconnect-delay) jetpacs-reconnect-max-delay))))

(defun jetpacs--reconnect-attempt ()
  (setq jetpacs--reconnect-timer nil)
  (unless (and jetpacs--process (process-live-p jetpacs--process))
    (condition-case nil
        (setq jetpacs--process (jetpacs--make-process))
      ;; Synchronous failure (no listener): try again later. Async failures
      ;; surface through the sentinel, which reschedules too.
      (error (jetpacs--schedule-reconnect)))))

(defun jetpacs--sentinel (_proc event)
  "React to connection EVENTs. Sends the hello once the socket opens."
  (cond
   ((string-prefix-p "open" event)
    (setq jetpacs--reconnect-delay jetpacs-reconnect-initial-delay)
    (jetpacs--cancel-reconnect)
    (jetpacs--send-hello))
   ((or (string-prefix-p "failed" event)
        (string-prefix-p "connection broken" event)
        (string-prefix-p "deleted" event)
        (string-prefix-p "finished" event))
    (message "Jetpacs: disconnected (%s)" (string-trim event))
    (setq jetpacs--process nil
          jetpacs--buffer ""
          jetpacs--session nil
          jetpacs--auth-server-nonce nil
          jetpacs--auth-client-nonce nil)
    (clrhash jetpacs--pending)
    (jetpacs--schedule-reconnect))))

(defun jetpacs--send-hello ()
  "Open the session per the spec handshake."
  (jetpacs-send
   "session.hello"
   `((protocol . ,jetpacs-protocol-version)
     (client   . ,(format "emacs/%s jetpacs.el/%s" emacs-version jetpacs-api-version))
     (features . ,(vconcat (mapcar #'symbol-name jetpacs-build-features)))
     (wants    . ,(vconcat jetpacs-wants)))))

(defun jetpacs--make-process ()
  "Create the network process. v0 = loopback TCP.
For 1.0, replace host/service/family with:
  :family \\='local :service \"/path/to/jetpacs.sock\"
and nothing else here changes."
  (make-network-process
   :name "jetpacs"
   :host jetpacs-host
   :service jetpacs-port
   :family 'ipv4
   :coding 'utf-8-unix
   :nowait t                 ; async connect; sentinel fires "open" on success
   :filter #'jetpacs--filter
   :sentinel #'jetpacs--sentinel))

(defvar jetpacs-before-connect-hook nil
  "Hook run at the very start of `jetpacs-connect', before the socket opens.
By the time connect fires — on `after-init-hook', or a 0-delay timer when
the bundle loads post-init — the user's whole init.el has already run.  So
this is where invariants that must hold regardless of user code are
re-asserted: whatever a stray `setq' during init did is overwritten before
the first frame is served.  See `jetpacs--install-invariants'.")

;;;###autoload
(defun jetpacs-connect ()
  "Connect to the companion and run the handshake."
  (interactive)
  (run-hooks 'jetpacs-before-connect-hook)
  (setq jetpacs--user-disconnected nil
        jetpacs--reconnect-delay jetpacs-reconnect-initial-delay)
  (jetpacs--cancel-reconnect)
  (when (and jetpacs--process (process-live-p jetpacs--process))
    (delete-process jetpacs--process))
  (setq jetpacs--buffer "" jetpacs--session nil
        jetpacs--auth-server-nonce nil jetpacs--auth-client-nonce nil)
  (clrhash jetpacs--pending)
  (condition-case err
      (setq jetpacs--process (jetpacs--make-process))
    (error (message "Jetpacs: connect failed: %s" (error-message-string err))
           (jetpacs--schedule-reconnect))))

(defun jetpacs-disconnect ()
  "Close the companion connection and stop auto-reconnecting."
  (interactive)
  (setq jetpacs--user-disconnected t)
  (jetpacs--cancel-reconnect)
  (when jetpacs--process (delete-process jetpacs--process))
  (setq jetpacs--process nil))

(defun jetpacs-connected-p ()
  "Non-nil once the socket is live AND the handshake has completed."
  (and jetpacs--process (process-live-p jetpacs--process) jetpacs--session t))

(defun jetpacs-ping ()
  "Debug helper: round-trip a ping/pong with the companion."
  (interactive)
  (jetpacs-request "ping" nil
                (lambda (_payload) (message "Jetpacs: pong received"))))

;; Auto-connect: at init when loaded from init.el; when the library is
;; loaded (or reloaded) later, `after-init-hook' has already run and would
;; never fire — connect from a zero-delay timer instead, so the handshake
;; can't start until the whole file (or bundle) has finished loading.
(if after-init-time
    (run-at-time 0 nil #'jetpacs-connect)
  (add-hook 'after-init-hook #'jetpacs-connect))

(provide 'jetpacs)
;;; jetpacs.el ends here