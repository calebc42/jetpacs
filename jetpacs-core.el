;;; jetpacs-core.el --- Jetpacs core client, single-file bundle -*- lexical-binding: t; -*-
;;
;; GENERATED FILE -- do not edit by hand.
;; Produced by emacs/build-bundle.el from the emacs/ sources.
;; Concatenated in dependency order; each part keeps its own `provide',
;; so the inter-file `require' forms resolve within this file.
;;
;;; Code:

;;; ==================================================================
;;; BEGIN core/jetpacs.el
;;; ==================================================================

;;; jetpacs.el --- Emacs-Android Bridge Protocol client -*- lexical-binding: t; -*-

;; Version: 1.11.0
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

(defconst jetpacs-api-version "1.11.0"
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
;;; ==================================================================
;;; BEGIN core/jetpacs-config.el
;;; ==================================================================

;;; jetpacs-config.el --- The foundation-owned root and per-app config subtrees -*- lexical-binding: t; -*-

;; Jetpacs owns a namespaced directory tree under the user's Emacs home
;; (`jetpacs-root', i.e. ~/.emacs.d/jetpacs/) rather than colonizing
;; ~/.emacs.d itself.  The user's init.el keeps a single seam line (see
;; docs/starter-init.el) that loads the managed entry point; everything
;; the foundation and its apps write lives under `jetpacs-root'.  The
;; user's own files (init.el, custom.el) stay at the `user-emacs-directory'
;; root, OUTSIDE this tree, so a sync pass can never clobber them.
;;
;; Two ownership tiers, mirrored in this file's verbs:
;;
;;   - SYNC (overwrite): `jetpacs-app-config-sync' rewrites every managed
;;     file to the current bundle defaults, so an app update can evolve
;;     them; edits to those files are expected to be lost.  DO-NOT-EDIT
;;     banners mark them.
;;   - CREATE-ONCE: `jetpacs-app-config-ensure' populates a subtree on the
;;     first run and only loads it thereafter, so user edits survive.
;;
;; The MUST-own-vs-overridable axis is ORTHOGONAL to these file tiers and
;; is carried in Lisp, not on disk: an invariant is a defun / registry
;; mutation / hook (a stray `setq' can't reach it); a default is a
;; `defcustom' the user is meant to override.  See
;; `jetpacs--install-invariants' in jetpacs-apps.el.
;;
;; This module is the generalization of Glasspane's `glasspane-config.el':
;; the same sync/ensure/load contract, promoted into the core and keyed by
;; app-id so any app reuses it (an app becomes a thin caller passing its id
;; and its (FILENAME . CONTENT) file set).

;;; Code:

(require 'jetpacs)

(defconst jetpacs-root
  (expand-file-name "jetpacs/" user-emacs-directory)
  "The foundation-owned directory tree, replacing the mis-named `elisp/'.
Everything Jetpacs and its apps write lives here.  The user's own files
\(init.el, custom.el) stay at the `user-emacs-directory' root, OUTSIDE this
tree, so a sync pass can never clobber them.  Treat this directory as the
foundation's, not the user's.")

(defconst jetpacs-lib-dir
  (expand-file-name "lib/" jetpacs-root)
  "Where adopted single-file bundles live (core + each app), one `require'
each.  SYNC tier: the newest staged copy is adopted over the installed one.
Kept flat and monolithic on purpose — on-device loading is one `require'
per bundle, never a multi-file module graph.")

(defun jetpacs-app-dir (id)
  "Return the config-subtree directory for app ID under `jetpacs-root'.
Keyed by the same app-id as views (\"ID.*\") and UI-state (\"ID.\"), so an
app's on-disk config, in-memory registrations and namespaced state all
share one key.  The directory is not created here — the config verbs do
that when the app opts in."
  (file-name-as-directory
   (expand-file-name id (expand-file-name "apps/" jetpacs-root))))

(defun jetpacs-app-config-load (id)
  "Load every elisp file in app ID's config subtree, in name order.
A missing subtree is fine — nothing loads until the app opts in via
`jetpacs-app-config-ensure' or `jetpacs-app-config-sync'.  Files load in
name order (so extra user files sort predictably among managed ones); an
error in one file is reported and skipped, never fatal."
  (let ((dir (jetpacs-app-dir id)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (condition-case err
            (load file nil 'nomessage)
          (error (message "jetpacs-config: error loading %s: %s"
                          file (error-message-string err))))))))

(defun jetpacs-app-config-sync (id files)
  "Write FILES into app ID's config subtree and load them.
FILES is an alist of (FILENAME . CONTENT).  Every file is overwritten —
the reset-to-current-bundle semantics are the point, so an app update can
evolve its defaults.  Returns the subtree directory."
  (let ((dir (jetpacs-app-dir id))
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (dolist (spec files)
      (write-region (cdr spec) nil (expand-file-name (car spec) dir)
                    nil 'silent))
    (jetpacs-app-config-load id)
    dir))

(defun jetpacs-app-config-ensure (id files)
  "Create app ID's config subtree from FILES on first run; load it after.
A missing subtree is populated via `jetpacs-app-config-sync'; an existing
one is only loaded, never rewritten — so a user's edits to the seeded files
survive an app that merely re-runs this at load time.  An app forces the
overwrite/upgrade path explicitly with `jetpacs-app-config-sync' (e.g.
behind an allowlisted `config.sync' action)."
  (if (file-directory-p (jetpacs-app-dir id))
      (jetpacs-app-config-load id)
    (jetpacs-app-config-sync id files)))

;; ─── Bundle adoption + the managed entry-point bootstrap ─────────────────────
;;
;; jetpacs-init.el (the on-disk entry file the user's one seam line loads) is
;; deliberately thin: it only needs to get lib/jetpacs-core.el in place and
;; `(require 'jetpacs-core)'.  Everything after that lives HERE, in versioned
;; core, so it is testable and evolves with the bundle rather than with a file
;; the user has to re-paste.

(defconst jetpacs-staging-dirs '("/sdcard/Documents/" "/sdcard/Download/")
  "Shared-storage directories bundles are staged into before adoption.
The companion (a separate UID) can only write here, not the Emacs sandbox;
Emacs pulls the newest staged copy into `jetpacs-lib-dir'.")

(defvar jetpacs-installed-bundles nil
  "App bundle file names to adopt and require at startup.
Set by the create-once ~/.emacs.d/jetpacs/apps.el, which the user edits to
install an app.  The core bundle is always loaded and is never listed here.")

(defun jetpacs-config--byte-compile (file)
  "Byte-compile FILE when its .elc is missing or older than the source.
The boot-speed half of adoption: bundles arrive in `jetpacs-lib-dir' as
source, and compiling once here — the user is mid-adopt, not mid-edit —
spares every later boot the full read of ~10k lines (Android kills the
Emacs process freely, so boots are frequent).  Never fatal: on any
failure the .elc is deleted so `require' keeps finding plain source, and
a warning is left — a broken compile must not brick boot.
`byte-compile-warnings' is bound down so compile noise cannot hit the
bridged minibuffer mid-boot.  Native compilation is deliberately NOT
attempted here: async JIT is battery-hostile, and any native rung is a
separate, measured, default-off decision (see PLAN-platform-hardening
Task 22 / the `jetpacs-build-features' probe)."
  (let ((elc (concat file "c")))
    (when (and (file-readable-p file)
               (file-newer-than-file-p file elc))
      (message "Jetpacs: byte-compiling %s..." (file-name-nondirectory file))
      (unless (ignore-errors
                (let ((byte-compile-warnings nil))
                  (byte-compile-file file)))
        (when (file-exists-p elc)
          (ignore-errors (delete-file elc)))
        (display-warning
         'jetpacs
         (format "byte-compile of %s failed; it will load from source"
                 (abbreviate-file-name file)))))))

(defun jetpacs-config-adopt (bundle)
  "Copy the newest staged BUNDLE into `jetpacs-lib-dir'; return its feature.
Newest-wins across `jetpacs-staging-dirs' (browser downloads and companion/
deploy staging both land there).  The installed copy is byte-compiled when
its .elc is missing or stale, so the `require' that follows picks up
bytecode.  A `.el' name maps to its feature symbol."
  (let ((installed (expand-file-name bundle jetpacs-lib-dir)))
    (make-directory jetpacs-lib-dir t)
    (dolist (dir jetpacs-staging-dirs)
      (let ((s (concat dir bundle)))
        (when (and (file-readable-p s)
                   (or (not (file-exists-p installed))
                       (file-newer-than-file-p s installed)))
          (copy-file s installed t)
          (message "jetpacs: adopted %s from %s" bundle dir))))
    (jetpacs-config--byte-compile installed)
    (intern (file-name-base bundle))))

(defun jetpacs-config-seed-file (path content)
  "Create PATH with CONTENT once, making parent dirs; never overwrite.
The create-once tier: `apps.el' and `user.el' are seeded this way so user
edits to them survive every subsequent startup and sync."
  (unless (file-exists-p path)
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8))
      (write-region content nil path nil 'silent))))

(defconst jetpacs-config--user-template
  ";;; user.el --- Your Jetpacs overrides -*- lexical-binding: t; -*-
;; CREATE-ONCE: Jetpacs wrote this once and never touches it again.
;; It loads AFTER Jetpacs's defaults and your saved Settings, so anything
;; here wins.  Put personal tweaks (keybindings, theme, variables) below.

"
  "Seed contents for a fresh ~/.emacs.d/jetpacs/user.el.")

(defconst jetpacs-config--apps-template
  ";;; apps.el --- Jetpacs installed app bundles -*- lexical-binding: t; -*-
;; CREATE-ONCE, yours to edit.  List the app bundle files you download into
;; /sdcard/Download (or Documents); each is adopted into ~/.emacs.d/jetpacs/lib/
;; and required at startup.  The core bundle is always loaded and is NOT listed.

(setq jetpacs-installed-bundles '())   ; e.g. '(\"glasspane.el\")
"
  "Seed contents for a fresh ~/.emacs.d/jetpacs/apps.el.")

(defconst jetpacs-config--apps-migrated-template
  ";;; apps.el --- Jetpacs installed app bundles -*- lexical-binding: t; -*-
;; CREATE-ONCE, yours to edit.  Migrated from your previous init.el bundle list.

(setq jetpacs-installed-bundles '(%s))
"
  "Seed for apps.el after a legacy migration; %s is the discovered bundle list.")

(defun jetpacs-config-migrate-legacy ()
  "Non-destructively move the old ~/.emacs.d/elisp/ layout under `jetpacs-root'.
Copies bundle `.el' files into `jetpacs-lib-dir', each elisp/<app>/ config
subtree into `(jetpacs-app-dir <app>)', and seeds apps.el from the discovered
app bundles so they still load.  Leaves the old elisp/ and custom.el untouched.
Runs at most once: guarded on apps.el not yet existing."
  (let ((old (expand-file-name "elisp/" user-emacs-directory)))
    (when (and (file-directory-p old)
               (not (file-exists-p (expand-file-name "apps.el" jetpacs-root))))
      (make-directory jetpacs-lib-dir t)
      (let (bundles)
        (dolist (f (directory-files old t "\\.el\\'"))
          (let ((name (file-name-nondirectory f)))
            (copy-file f (expand-file-name name jetpacs-lib-dir) t)
            (unless (equal name "jetpacs-core.el")
              (push name bundles))))
        (dolist (d (directory-files old t "\\`[^.]"))
          (when (file-directory-p d)
            (let ((dest (jetpacs-app-dir (file-name-nondirectory d))))
              (unless (file-directory-p dest)
                (copy-directory d dest nil t t)))))
        (jetpacs-config-seed-file
         (expand-file-name "apps.el" jetpacs-root)
         (format jetpacs-config--apps-migrated-template
                 (mapconcat (lambda (b) (format "%S" b))
                            (nreverse bundles) " ")))
        (message "jetpacs: migrated %s into %s"
                 (abbreviate-file-name old) (abbreviate-file-name jetpacs-root))))))

(defun jetpacs-apply-foundation-defaults ()
  "Apply Jetpacs's phone-ergonomics and file-hygiene defaults.
Called by the managed entry point BEFORE `custom-file' and the user's
`user.el' load, so every setting here is overridable — these are DEFAULTS
\(plain setters), not invariants.  Touch/scroll basics, backups and auto-saves
in one place, no lock files (single-user device), auto-revert, and volume keys
paging the buffer on Android."
  (when (fboundp 'pixel-scroll-precision-mode)
    (pixel-scroll-precision-mode 1))
  (setq touch-screen-precision-scroll t
        touch-screen-word-select t
        touch-screen-extend-selection t
        touch-screen-display-keyboard t)
  (when (fboundp 'context-menu-mode) (context-menu-mode 1))
  (setq use-dialog-box t
        use-short-answers t
        inhibit-startup-screen t)
  (when (eq system-type 'android)
    (setq android-pass-multimedia-buttons-to-system nil)
    (global-set-key (kbd "<volume-up>")   #'scroll-down-command)
    (global-set-key (kbd "<volume-down>") #'scroll-up-command))
  (setq backup-directory-alist
        `(("." . ,(expand-file-name "backups/" user-emacs-directory)))
        backup-by-copying t
        create-lockfiles nil)
  (let ((auto-save-dir (expand-file-name "auto-save/" user-emacs-directory)))
    (make-directory auto-save-dir t)
    (setq auto-save-file-name-transforms `((".*" ,auto-save-dir t))))
  (global-auto-revert-mode 1)
  (setq global-auto-revert-non-file-buffers t
        auto-revert-verbose nil)
  (save-place-mode 1)
  (savehist-mode 1)
  (recentf-mode 1))

(defun jetpacs-config-bootstrap ()
  "Wire up the managed root after core has loaded.
Called by jetpacs-init.el once `jetpacs-core' is required: migrate any legacy
layout, load the create-once installed-app list and adopt+require each app,
apply the foundation defaults, then load `custom-file' and the user override.
Invariants are re-asserted separately at connect (`jetpacs-before-connect-hook')."
  (add-to-list 'load-path jetpacs-lib-dir)
  (jetpacs-config-migrate-legacy)
  ;; The core bundle was adopted by the entry file BEFORE core could run, so
  ;; its compile step lives here instead (after the migration, which can
  ;; rewrite lib/jetpacs-core.el): this boot loaded core from source, the
  ;; next one requires the .elc.  `load-prefer-newer' (set by the entry
  ;; file) keeps a stale .elc from ever shadowing a newer synced .el.
  (jetpacs-config--byte-compile (expand-file-name "jetpacs-core.el" jetpacs-lib-dir))
  ;; Installed apps: a create-once, user-owned list.
  (let ((apps (expand-file-name "apps.el" jetpacs-root)))
    (jetpacs-config-seed-file apps jetpacs-config--apps-template)
    (load apps t))
  (dolist (bundle jetpacs-installed-bundles)
    (condition-case err
        (require (jetpacs-config-adopt bundle))
      (error (display-warning
              'jetpacs
              (format "app bundle %s failed to load: %S" bundle err)
              :error))))
  ;; Foundation defaults (overridable) — before custom/user so those win.
  (jetpacs-apply-foundation-defaults)
  ;; custom-file: user data, pinned OUTSIDE the jetpacs/ sync tree.
  (unless custom-file
    (setq custom-file (expand-file-name "custom.el" user-emacs-directory)))
  (when (and custom-file (file-exists-p custom-file))
    (load custom-file nil 'nomessage))
  ;; User override escape hatch — loaded LAST so the user beats every default.
  (let ((user (expand-file-name "user.el" jetpacs-root)))
    (jetpacs-config-seed-file user jetpacs-config--user-template)
    (load user t)))

(provide 'jetpacs-config)
;;; jetpacs-config.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-org.el
;;; ==================================================================

;;; jetpacs-org.el --- Jetpacs Org-Mode Core Layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 calebc42 and contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Provides the unopinionated, primitive-first Org-mode extraction layer
;; for the Jetpacs foundation. Included are the query parser, the built-in
;; org-ql interpreter, heading identity mapping, and typed property extraction.
;;
;; This is the core engine for third-party Tier-1 apps (like Glasspane)
;; or declarative runtimes (like jetpacs-crud.el) to read and query org data.
;;
;; The query grammar is interpreted ONCE (`jetpacs-org--matches-p') over a
;; pluggable data accessor: `jetpacs-org-entry-matches-p' reads the org
;; entry at point, `jetpacs-org-note-matches-p' reads a `vulpea-note'
;; struct off the vulpea index.  vulpea is an OPTIONAL engine: nothing
;; here requires it at load, the note path is only entered when a caller
;; hands us a note, and `jetpacs-org-vulpea-available-p' is the probe.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-id)
(require 'cl-lib)

;; The vulpea note index is an optional engine (installed app-side or by
;; the composer's dependency bootstrap); these are compile-time stubs only.
(declare-function vulpea-note-id "vulpea-note")
(declare-function vulpea-note-path "vulpea-note")
(declare-function vulpea-note-title "vulpea-note")
(declare-function vulpea-note-todo "vulpea-note")
(declare-function vulpea-note-tags "vulpea-note")
(declare-function vulpea-note-priority "vulpea-note")
(declare-function vulpea-note-level "vulpea-note")
(declare-function vulpea-note-properties "vulpea-note")
(declare-function vulpea-note-scheduled "vulpea-note")
(declare-function vulpea-note-deadline "vulpea-note")
(declare-function vulpea-note-closed "vulpea-note")
(declare-function vulpea-note-outline-path "vulpea-note")
(declare-function vulpea-db-query "vulpea-db")
(declare-function vulpea-db-query-by-directory "vulpea-db")

;; ─── Cache layer ───────────────────────────────────────────────────────────────

(defvar jetpacs-org--cache (make-hash-table :test 'equal)
  "Memoised org extraction results.")

(defun jetpacs-org--files-mtime (files)
  "Return the maximum modification time of FILES (or 0 if none exist)."
  (let ((mtime 0.0))
    (dolist (file files)
      (when (file-exists-p file)
        (let* ((attrs (file-attributes (file-truename file)))
               (t-val (float-time (file-attribute-modification-time attrs))))
          (when (> t-val mtime)
            (setq mtime t-val)))))
    mtime))

(defun jetpacs-org--cache-key (namespace &rest parts)
  "Build a cache key from NAMESPACE and PARTS.
Scoped to today's date and the agenda files' mtime to automatically bust
the cache on external edits or date roll-over."
  (cons (format-time-string "%Y-%m-%d")
        (cons (jetpacs-org--files-mtime (org-agenda-files))
              (cons namespace parts))))

(defmacro jetpacs-org-with-cache (namespace key &rest body)
  "Memoise BODY's result in `jetpacs-org--cache' under NAMESPACE and KEY."
  (declare (indent 2))
  (let ((k (gensym "key")) (hit (gensym "hit")))
    `(let* ((,k (jetpacs-org--cache-key ,namespace ,key))
            (,hit (gethash ,k jetpacs-org--cache 'jetpacs-org--miss)))
       (if (eq ,hit 'jetpacs-org--miss)
           (puthash ,k (progn ,@body) jetpacs-org--cache)
         ,hit))))

(defun jetpacs-org-cache-invalidate (&optional namespace)
  "Drop memoised org extractions.
If NAMESPACE is provided, only clear entries matching it. Otherwise clear all."
  (if namespace
      (maphash (lambda (k _v)
                 ;; k is (date mtime namespace . parts)
                 (when (equal (nth 2 k) namespace)
                   (remhash k jetpacs-org--cache)))
               jetpacs-org--cache)
    (clrhash jetpacs-org--cache)))

;; ─── Heading references ────────────────────────────────────────────────────────

(defun jetpacs-org-heading-ref ()
  "Build a location ref for the org heading at point.
Returns an alist with `file'/`pos'/`headline', plus `id' when the entry
already has an ID property. This reference is stable for JSON serialization
and round-trips over the wire."
  (save-excursion
    (unless (org-at-heading-p)
      (ignore-errors (org-back-to-heading t)))
    (let ((id (org-entry-get nil "ID"))
          (ref `((file . ,(or (buffer-file-name) ""))
                 (pos . ,(point))
                 (headline . ,(or (nth 4 (org-heading-components)) "")))))
      (if (and (stringp id) (not (string-empty-p id)))
          (cons `(id . ,id) ref)
        ref))))

(defun jetpacs-org-resolve-ref (ref)
  "Resolve REF to a live marker at its org heading, or signal an error.
REF is an alist as built by `jetpacs-org-heading-ref'. Resolution tries:
1. the stable `id' (survives edits anywhere)
2. the recorded `pos' (trusted only if its headline still matches)
3. a headline search through the file."
  (let ((id (alist-get 'id ref))
        (file (alist-get 'file ref))
        (pos (alist-get 'pos ref))
        (headline (alist-get 'headline ref)))
    (or
     (and (stringp id) (not (string-empty-p id))
          (ignore-errors (org-id-find id 'marker)))
     (and (stringp file) (file-readable-p file)
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (org-with-wide-buffer
               (when (and (integerp pos) (<= (point-min) pos (point-max)))
                 (goto-char pos)
                 (when (ignore-errors (org-back-to-heading t) t)
                   (when (or (not (stringp headline)) (string-empty-p headline)
                             (equal (nth 4 (org-heading-components)) headline))
                     (copy-marker (point)))))))))
     (and (stringp file) (file-readable-p file)
          (stringp headline) (not (string-empty-p headline))
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (org-with-wide-buffer
               (goto-char (point-min))
               (catch 'found
                 (while (re-search-forward org-heading-regexp nil t)
                   (when (equal (nth 4 (org-heading-components)) headline)
                     (throw 'found (copy-marker (line-beginning-position)))))
                 nil)))))
     (error "Heading not found: %s"
            (or headline id file "?")))))

;; ─── Query Parser ──────────────────────────────────────────────────────────────

(defconst jetpacs-org-ql-literals '(today nil t < <= > >= =)
  "Symbols with meaning to org-ql that normalization must not stringify.")

(defun jetpacs-org--normalize-ql-arg (arg)
  "Normalize ARG, a clause argument inside a sexp query."
  (cond
   ((and (consp arg) (eq (car arg) 'quote) (cdr arg))
    (jetpacs-org--normalize-ql-arg (cadr arg)))
   ((consp arg) (jetpacs-org--normalize-ql arg))
   ((keywordp arg) arg)
   ((memq arg jetpacs-org-ql-literals) arg)
   ((symbolp arg) (symbol-name arg))
   (t arg)))

(defun jetpacs-org--normalize-ql (form)
  "Return sexp query FORM with elisp-isms rewritten to org-ql shape.
Quotes are unwrapped and bare symbols in argument positions become strings."
  (if (and (consp form) (eq (car form) 'quote) (cdr form))
      (jetpacs-org--normalize-ql (cadr form))
    (if (not (consp form))
        form
      (cons (car form)
            (mapcar #'jetpacs-org--normalize-ql-arg (cdr form))))))

(defun jetpacs-org--query-tokens (q)
  "Split query Q on whitespace, keeping \"quoted phrases\" whole."
  (let ((pos 0) (tokens nil))
    (while (string-match "\"\\([^\"]*\\)\"\\|\\S-+" q pos)
      (push (or (match-string 1 q) (match-string 0 q)) tokens)
      (setq pos (match-end 0)))
    (nreverse tokens)))

(defun jetpacs-org-parse-query (query)
  "Parse the search QUERY string into an org-ql sexp, or nil if empty.
Accepts three input shapes:
- an org-ql sexp:  (and (todo \"TODO\") (tags \"work\"))
- filter tokens:   todo:TODO,NEXT tags:work priority:A
- free text:       \"exact phrase\" or bare words
Signals `user-error' on a malformed sexp."
  (let ((q (string-trim (or query ""))))
    (cond
     ((string-empty-p q) nil)
     ((string-match-p "\\`'?(" q)
      (let ((form (condition-case nil (read q)
                    (error (user-error "Query has unbalanced parentheses: %s" q)))))
        (jetpacs-org--normalize-ql form)))
     (t
      (let ((clauses
             (mapcar
              (lambda (tok)
                (cond
                 ((string-prefix-p "todo:" tok)
                  `(todo ,@(split-string (substring tok 5) "," t)))
                 ((string-prefix-p "tags:" tok)
                  `(tags ,@(split-string (substring tok 5) "," t)))
                 ((string-prefix-p "priority:" tok)
                  `(priority ,@(split-string (substring tok 9) "," t)))
                 (t `(regexp ,(regexp-quote tok)))))
              (jetpacs-org--query-tokens q))))
        (if (cdr clauses) `(and ,@clauses) (car clauses)))))))

;; ─── Built-in Query Interpreter ────────────────────────────────────────────────

(defun jetpacs-org--planning-day (spec)
  "Resolve a query date SPEC to an absolute day number."
  (cond
   ((eq spec 'today) (time-to-days (current-time)))
   ((integerp spec) (+ (time-to-days (current-time)) spec))
   ((stringp spec) (time-to-days (org-time-string-to-time spec)))
   (t (user-error "Unsupported query date %S" spec))))

(defun jetpacs-org--planning-match-spec (stamp args)
  "Match raw planning STAMP string against ARGS plist (:on / :from / :to).
Empty ARGS means mere presence of the stamp."
  (and (stringp stamp) (not (string-empty-p stamp))
       (let ((day (time-to-days (org-time-string-to-time stamp)))
             (on (plist-get args :on))
             (from (plist-get args :from))
             (to (plist-get args :to)))
         (and (or (not on) (equal day (jetpacs-org--planning-day on)))
              (or (not from) (>= day (jetpacs-org--planning-day from)))
              (or (not to) (<= day (jetpacs-org--planning-day to)))))))

(defun jetpacs-org--planning-match-p (which args)
  "Match the WHICH (\"SCHEDULED\"/\"DEADLINE\") stamp at point against ARGS."
  (jetpacs-org--planning-match-spec (org-entry-get (point) which) args))

(defun jetpacs-org--entry-priority ()
  "The priority character of the heading at point, or nil."
  (save-excursion (org-back-to-heading t) (nth 3 (org-heading-components))))

(defun jetpacs-org--matches-p (tree get)
  "Non-nil when the entry read through accessor GET matches org-ql sexp TREE.
The ONE interpreter of the built-in query grammar.  GET is
\(funcall GET WHAT &rest ARGS) with WHAT one of:
  todo            -> the TODO keyword string, or nil
  done            -> non-nil when the entry counts as done
  tags            -> the entry's tag list
  priority        -> the priority character, or nil
  title           -> the headline/title string, or nil
  level           -> the outline level integer, or nil
  property NAME   -> the property's string value, or nil
  planning WHICH  -> the raw SCHEDULED/DEADLINE stamp string, or nil
  regexp-match RE -> non-nil when RE hits the entry's haystack
Signals `user-error' on unsupported terms."
  (pcase tree
    (`(and . ,cs) (cl-every (lambda (c) (jetpacs-org--matches-p c get)) cs))
    (`(or . ,cs) (and (cl-some (lambda (c) (jetpacs-org--matches-p c get)) cs) t))
    (`(not ,c) (not (jetpacs-org--matches-p c get)))
    (`(todo . ,kws)
     (let ((st (funcall get 'todo)))
       (and st (if kws (and (member st kws) t)
                 (not (funcall get 'done))))))
    (`(done) (and (funcall get 'done) t))
    (`(tags . ,tags)
     (let ((have (funcall get 'tags)))
       (if tags (and (cl-some (lambda (tg) (member tg have)) tags) t)
         (and have t))))
    (`(priority ,(and op (pred symbolp)) ,val)
     (let ((pr (funcall get 'priority))
           (want (if (stringp val) (string-to-char val) val)))
       ;; org urgency runs A > B > C — the higher priority is the smaller
       ;; character, so the comparator flips against the chars.
       (and pr (pcase op
                 ('< (> pr want)) ('<= (>= pr want))
                 ('> (< pr want)) ('>= (<= pr want))
                 ('= (= pr want))
                 (_ (user-error "Unsupported priority comparator %s" op))))))
    (`(priority . ,ps)
     (let ((pr (funcall get 'priority)))
       (if ps (and pr (member (char-to-string pr) ps) t)
         (and pr t))))
    (`(heading . ,texts)
     (let ((hl (or (funcall get 'title) ""))
           (case-fold-search t))
       (cl-every (lambda (s) (string-match-p (regexp-quote s) hl)) texts)))
    (`(regexp . ,res)
     (cl-every (lambda (re) (funcall get 'regexp-match re)) res))
    (`(property ,name . ,val)
     (let ((v (funcall get 'property name)))
       (if val (equal v (car val)) (and v t))))
    (`(level ,n) (eql (funcall get 'level) n))
    (`(level ,n ,m) (let ((l (funcall get 'level))) (and l (<= n l m))))
    (`(scheduled . ,args)
     (jetpacs-org--planning-match-spec (funcall get 'planning "SCHEDULED") args))
    (`(deadline . ,args)
     (jetpacs-org--planning-match-spec (funcall get 'planning "DEADLINE") args))
    (_ (user-error "Query term %S needs the org-ql package installed" tree))))

(defun jetpacs-org--point-get (what &rest args)
  "The grammar accessor over the org entry AT POINT."
  (pcase what
    ('todo (org-get-todo-state))
    ('done (let ((st (org-get-todo-state)))
             (and st (member st org-done-keywords) t)))
    ('tags (org-get-tags nil t))
    ('priority (jetpacs-org--entry-priority))
    ('title (nth 4 (org-heading-components)))
    ('level (org-current-level))
    ('property (org-entry-get (point) (car args)))
    ('planning (org-entry-get (point) (car args)))
    ('regexp-match
     ;; The point haystack is the entry's body up to the next heading.
     (let ((end (save-excursion (outline-next-heading) (point)))
           (case-fold-search t))
       (save-excursion (re-search-forward (car args) end t))))))

(defun jetpacs-org--note-get (note what &rest args)
  "The grammar accessor over a `vulpea-note' NOTE (index only, no file visit)."
  (pcase what
    ('todo (vulpea-note-todo note))
    ;; The index does not record a file's per-file DONE keyword set, so
    ;; done-ness is approximated: a global done keyword (falling back to
    ;; the near-universal \"DONE\" when `org-done-keywords' is unset, as
    ;; it is in a headless scan) or a CLOSED stamp.  Exotic per-file done
    ;; keywords need the org-ql arm.
    ('done (let ((s (vulpea-note-todo note)))
             (or (and s (member s (or org-done-keywords '("DONE"))) t)
                 (and (vulpea-note-closed note) t))))
    ('tags (vulpea-note-tags note))
    ;; vulpea priority may be a char (org's native form) or a string.
    ('priority (let ((p (vulpea-note-priority note)))
                 (cond ((null p) nil)
                       ((characterp p) p)
                       ((and (stringp p) (> (length p) 0)) (aref p 0))
                       (t (let ((s (format "%s" p)))
                            (and (> (length s) 0) (aref s 0)))))))
    ('title (vulpea-note-title note))
    ('level (vulpea-note-level note))
    ;; vulpea indexes drawer keys upper-cased; match case-insensitively.
    ('property (cdr (assoc-string (car args) (vulpea-note-properties note) t)))
    ('planning (let ((s (if (equal (car args) "DEADLINE")
                            (vulpea-note-deadline note)
                          (vulpea-note-scheduled note))))
                 (and (stringp s) s)))
    ('regexp-match
     ;; The index haystack is title + properties — the body is not
     ;; indexed.  SEMANTIC DIFFERENCE from the point accessor, by design.
     (let ((hay (concat (or (vulpea-note-title note) "") " "
                        (mapconcat #'cdr (vulpea-note-properties note) " ")))
           (case-fold-search t))
       (string-match-p (car args) hay)))))

(defun jetpacs-org-entry-matches-p (tree)
  "Non-nil when the org entry at point matches org-ql sexp TREE.
This is the built-in fallback interpreter implementing the common subset
of org-ql. Signals `user-error' on unsupported terms."
  (jetpacs-org--matches-p tree #'jetpacs-org--point-get))

(defun jetpacs-org-note-matches-p (tree note)
  "Non-nil when `vulpea-note' NOTE matches org-ql sexp TREE.
The same grammar as `jetpacs-org-entry-matches-p', evaluated entirely
off the vulpea index (no file visit).  Note the `regexp' term searches
title + properties here (the body is not indexed).  Signals `user-error'
on terms outside `jetpacs-org-note-query-terms' — check
`jetpacs-org-note-query-supported-p' first to route those to org-ql."
  (jetpacs-org--matches-p
   tree (lambda (what &rest args) (apply #'jetpacs-org--note-get note what args))))

(defconst jetpacs-org-note-query-terms
  '(and or not todo done tags priority heading regexp property level
        scheduled deadline)
  "org-ql head symbols the built-in grammar evaluates off the note index.")

(defun jetpacs-org-note-query-supported-p (tree)
  "Non-nil when org-ql sexp TREE uses only index-evaluable terms.
Empty (nil) TREE — no filter — is trivially supported."
  (pcase tree
    ('nil t)
    (`(and . ,cs) (cl-every #'jetpacs-org-note-query-supported-p cs))
    (`(or . ,cs) (cl-every #'jetpacs-org-note-query-supported-p cs))
    (`(not ,c) (jetpacs-org-note-query-supported-p c))
    (`(,head . ,_) (and (memq head jetpacs-org-note-query-terms) t))
    (_ nil)))

;; ─── High-Level Query ──────────────────────────────────────────────────────────

(defun jetpacs-org--search-fallback (tree action)
  "Run parsed query TREE over the agenda files without org-ql.
Calls ACTION at each matching heading."
  (let (items)
    (org-map-entries
     (lambda ()
       (when (jetpacs-org-entry-matches-p tree)
         (push (funcall action) items)))
     nil 'agenda)
    (nreverse items)))

(defun jetpacs-org-query (namespace tree action)
  "Run parsed query sexp TREE over the agenda files, calling ACTION at matches.
Results are cached under NAMESPACE. Automatically dispatches to `org-ql-select'
if available, otherwise falls back to the built-in interpreter."
  (when tree
    (jetpacs-org-with-cache namespace (format "%S" tree)
      (if (fboundp 'org-ql-select)
          (condition-case err
              (org-ql-select (org-agenda-files) tree
                             :action action)
            (user-error (signal (car err) (cdr err)))
            (error (user-error "Query failed: %s" (error-message-string err))))
        (jetpacs-org--search-fallback tree action)))))

;; ─── Vulpea note index (optional engine) ──────────────────────────────────────

(defun jetpacs-org-vulpea-available-p ()
  "Non-nil when the vulpea note index is loadable on this Emacs.
vulpea is never required by the core; apps or the composer's dependency
bootstrap install it, and callers gate their index reads on this probe."
  (and (require 'vulpea nil t) (fboundp 'vulpea-db-query) t))

(defun jetpacs-org-vulpea-source-notes (source)
  "The `vulpea-note' records backing SOURCE, a scope plist.
SOURCE is one of:
  (:dir D)               -> the file-level notes of vault directory D
                            (one note file per record);
  (:file F :heading H)   -> the id'd headings directly under H in F;
  (:file F)              -> the id'd level-1 headings of F.
Headings must already carry `:ID:' properties for the index to see them.
Callers gate on `jetpacs-org-vulpea-available-p'."
  (let ((dir (plist-get source :dir))
        (file (plist-get source :file))
        (heading (plist-get source :heading)))
    (cond
     (dir (vulpea-db-query-by-directory (directory-file-name dir) 0))
     (file
      (let ((want (expand-file-name file)))
        (vulpea-db-query
         (lambda (n)
           (and (equal (expand-file-name (vulpea-note-path n)) want)
                (if heading
                    (equal (vulpea-note-outline-path n) (list heading))
                  (= (vulpea-note-level n) 1)))))))
     (t (user-error "Source needs :dir or :file: %S" source)))))

(defun jetpacs-org-vulpea-query (source &optional tree)
  "Notes of SOURCE matching org-ql sexp TREE, off the vulpea index.
A nil TREE admits every note of the scope.  TREE must stay inside
`jetpacs-org-note-query-terms' (see `jetpacs-org-note-query-supported-p');
route anything else through org-ql over the source file instead."
  (let ((notes (jetpacs-org-vulpea-source-notes source)))
    (if tree
        (cl-remove-if-not (lambda (n) (jetpacs-org-note-matches-p tree n)) notes)
      notes)))

;; ─── Mutations ─────────────────────────────────────────────────────────────────

(defun jetpacs-org-defer-save ()
  "Schedule a save for the current buffer during the next idle moment."
  (let ((buf (current-buffer)))
    (run-with-idle-timer 0.5 nil
      (lambda ()
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (buffer-modified-p)
              (save-buffer))))))))

(defmacro jetpacs-org-with-mutation (ref namespace &rest body)
  "Resolve REF, execute BODY at its heading, bust cache NAMESPACE, and defer save."
  (declare (indent 2))
  `(let ((marker (jetpacs-org-resolve-ref ,ref)))
     (with-current-buffer (marker-buffer marker)
       (save-excursion
         (goto-char marker)
         (prog1 (progn ,@body)
           (jetpacs-org-cache-invalidate ,namespace)
           (jetpacs-org-defer-save))))))

(defun jetpacs-org-set-property (ref namespace prop value)
  "Set PROP to VALUE on the heading at REF."
  (jetpacs-org-with-mutation ref namespace
    (org-entry-put (point) prop value)))

(defun jetpacs-org-toggle-todo (ref namespace &optional state)
  "Set the TODO state at REF to STATE, or toggle if nil."
  (jetpacs-org-with-mutation ref namespace
    (org-todo state)))

(defun jetpacs-org-set-planning (ref namespace which date-str)
  "Set the WHICH planning stamp at REF to DATE-STR.
WHICH is \"SCHEDULED\" or \"DEADLINE\"; an empty or nil DATE-STR removes
the stamp.  `org-add-planning-info' wants the planning type as a symbol
\(scheduled/deadline), and removal is expressed as a trailing remove arg
with no time — the string form and the nonexistent
`org-remove-planning-info' both signalled."
  (let ((type (pcase (upcase (or which ""))
                ("SCHEDULED" 'scheduled)
                ("DEADLINE" 'deadline)
                (_ (user-error "Unsupported planning type: %s" which)))))
    (jetpacs-org-with-mutation ref namespace
      (if (or (null date-str) (string-empty-p date-str))
          (org-add-planning-info nil nil type)
        (org-add-planning-info type date-str)))))

;; ─── Typed extraction ──────────────────────────────────────────────────────────

(defun jetpacs-org-entry-typed-value (prop type)
  "Extract the value of PROP at point according to TYPE.
TYPE is one of `text', `checkbox', `date', `enum', `number', `list'."
  (let ((val (org-entry-get (point) prop)))
    (pcase type
      ('checkbox (equal val "[X]"))
      ('date (and val (not (string-empty-p val)) val))
      ('number (and val (string-to-number val)))
      ('enum
       ;; If there's an allowed values constraint (PROP_ALL), enforce it.
       (let ((allowed (org-entry-get (point) (concat prop "_ALL") t)))
         (if allowed
             (let ((options (split-string allowed "[ \t]+" t)))
               (if (member val options) val nil))
           (and val (not (string-empty-p val)) val))))
      ('list
       (and val (split-string val "[, \t]+" t)))
      (_ (or val "")))))

(provide 'jetpacs-org)
;;; jetpacs-org.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-theme.el
;;; ==================================================================

;;; jetpacs-theme.el --- Mirror the Emacs theme onto the companion -*- lexical-binding: t; -*-

;; The companion's default look is Material You (falling back to a static
;; Emacs-purple scheme); this module is the third rung of that ladder — the
;; phone can look like YOUR Emacs.  It reads the active theme's colors,
;; shapes them into the Material roles the companion's renderer already
;; resolves theme tokens against (SPEC §9: "primary", "surface_variant", …),
;; and pushes them as one `theme.set' frame (SPEC §7).  The companion
;; persists the palette like a cached surface, so the mirrored look
;; survives app restarts while Emacs is away.
;;
;; Two extraction paths:
;;
;;  - Prot's modus themes (built into Emacs; the reference implementation
;;    for this feature): when a modus-* theme is active we read its named
;;    palette via `modus-themes-get-color-value' — `bg-main', `bg-dim',
;;    accent colors, and the `bg-*-subtle' tints that map one-to-one onto
;;    Material's container roles, with modus's contrast guarantees intact.
;;
;;  - Any other theme: resolved face attributes (`default', `link',
;;    `font-lock-*', `error', `shadow', `mode-line-inactive', outline
;;    levels), with container tones derived by blending each accent into
;;    the theme background.
;;
;; Every color is optional on the wire; the companion fills holes from its
;; fallback scheme, so a spartan theme still yields a complete UI.  In a
;; frame that can't resolve colors (batch/tty), no frame is sent at all.
;;
;; Opt-in: (setq jetpacs-theme-sync t) — or flip it in Customize — then the
;; palette follows every `load-theme' (Emacs 29+) and every reconnect.
;; `M-x jetpacs-theme-send' pushes once regardless; `M-x jetpacs-theme-clear'
;; reverts the companion to its own scheme.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'jetpacs)

(defcustom jetpacs-theme-sync nil
  "When non-nil, mirror the active Emacs theme onto the companion app.
The palette is pushed after every successful handshake and (on Emacs 29+)
whenever a theme is enabled or disabled.  When nil the companion keeps its
own scheme: Material You on Android 12+, an Emacs-purple fallback earlier.
Setting this through Customize applies immediately on a live connection;
after a plain `setq', push with \\[jetpacs-theme-send] or reconnect."
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         ;; Live toggle (guarded: :set also runs while this file loads,
         ;; before the functions below exist).
         (when (and (featurep 'jetpacs-theme) (jetpacs-connected-p))
           (if val (jetpacs-theme--push-soon) (jetpacs-theme-clear))))
  :group 'jetpacs)

;; ─── Color plumbing ──────────────────────────────────────────────────────────

(defun jetpacs-theme--rgb (color)
  "COLOR (a name or #RRGGBB string) as a list of three [0,1] floats, or nil.
Hex strings are parsed directly — `color-name-to-rgb' resolves through
the current display, which on a tty/batch frame quantizes #2e3440 to the
nearest terminal color — so theme hexes stay exact on every frame type.
nil for the `unspecified-fg'/`unspecified-bg' placeholders a batch or tty
frame reports, and for anything the display can't resolve."
  (cond
   ((not (stringp color)) nil)
   ((string-prefix-p "unspecified" color) nil)
   ((string-match "\\`#\\([[:xdigit:]]+\\)\\'" color)
    (let* ((hex (match-string 1 color))
           (digits (/ (length hex) 3)))
      (when (and (> digits 0) (= (% (length hex) 3) 0))
        (let ((max (float (1- (expt 16 digits)))))
          (mapcar (lambda (i)
                    (/ (string-to-number
                        (substring hex (* i digits) (* (1+ i) digits))
                        16)
                       max))
                  '(0 1 2))))))
   (t (color-name-to-rgb color))))

(defun jetpacs-theme--hex (color)
  "COLOR normalized to \"#rrggbb\", or nil when unresolvable."
  (when-let ((rgb (jetpacs-theme--rgb color)))
    (apply #'format "#%02x%02x%02x"
           (mapcar (lambda (c) (min 255 (round (* 255 c)))) rgb))))

(defun jetpacs-theme--blend (a b frac)
  "FRAC of color A mixed into (1 - FRAC) of color B, as hex; nil on failure."
  (let ((ra (jetpacs-theme--rgb a))
        (rb (jetpacs-theme--rgb b)))
    (when (and ra rb)
      (apply #'format "#%02x%02x%02x"
             (cl-mapcar (lambda (ca cb)
                          (min 255 (round (* 255 (+ (* frac ca)
                                                    (* (- 1.0 frac) cb))))))
                        ra rb)))))

(defun jetpacs-theme--dark-p (color)
  "Non-nil when COLOR reads as a dark background (relative luminance < 0.5)."
  (when-let ((rgb (jetpacs-theme--rgb color)))
    (< (+ (* 0.2126 (nth 0 rgb))
          (* 0.7152 (nth 1 rgb))
          (* 0.0722 (nth 2 rgb)))
       0.5)))

(defun jetpacs-theme--face-color (attr &rest faces)
  "Inheritance-resolved ATTR of the first of FACES with a usable color, as hex."
  (catch 'hit
    (dolist (f faces)
      (when (facep f)
        (when-let ((hex (jetpacs-theme--hex (face-attribute f attr nil t))))
          (throw 'hit hex))))
    nil))

;; ─── Modus palette access ────────────────────────────────────────────────────

(defun jetpacs-theme--modus-p ()
  "Non-nil when a modus theme is active and its palette API is available.
The API (`modus-themes-get-color-value') exists from modus-themes 4 /
Emacs 30's bundled copy; older bundled versions fall through to the
generic face extraction, which handles modus fine — just without the
palette's purpose-built container tints."
  (and (fboundp 'modus-themes-get-color-value)
       (cl-find-if (lambda (theme)
                     (string-prefix-p "modus-" (symbol-name theme)))
                   custom-enabled-themes)
       t))

(defun jetpacs-theme--modus (key)
  "Hex value of the active modus theme's palette color KEY, or nil."
  (when-let ((value (ignore-errors (modus-themes-get-color-value key))))
    (and (stringp value) (jetpacs-theme--hex value))))

;; ─── Palette construction ────────────────────────────────────────────────────

(defun jetpacs-theme--compact (alist)
  "ALIST without the pairs whose value is nil."
  (cl-remove-if-not #'cdr alist))

(defun jetpacs-theme--colors ()
  "Material color-role alist for the active theme, or nil when unresolvable.

Role mapping follows Material grammar, not face taxonomy: `primary' is
the theme's IDENTITY accent — it lands on the hero chrome (FAB,
buttons, switches), so it comes from the keyword face, where theme
authors put their signature hue (purple in the stock theme, blue in
doom-one, pink in dracula), and from modus's flagship blue.  The link
face is deliberately NOT primary: links are blue in nearly every theme
regardless of its identity, which painted the hero chrome blue under
themes that read as anything-but-blue.  `secondary' is the same hue
muted (Material derives it from primary's hue, never a second
competing accent); `tertiary' is the contrasting accent (constant
face / modus cyan), mirroring Material's hue-shifted tertiary."
  (let* ((modus (jetpacs-theme--modus-p))
         (bg (or (and modus (jetpacs-theme--modus 'bg-main))
                 (jetpacs-theme--face-color :background 'default)))
         (fg (or (and modus (jetpacs-theme--modus 'fg-main))
                 (jetpacs-theme--face-color :foreground 'default))))
    (when (and bg fg)
      (let* ((primary (or (and modus (jetpacs-theme--modus 'blue))
                          (jetpacs-theme--face-color
                           :foreground 'font-lock-keyword-face 'link
                           'font-lock-function-name-face)
                          fg))
             (secondary (or (and modus (jetpacs-theme--modus 'blue-faint))
                            ;; Muted primary: sink it halfway into the
                            ;; theme's mid-gray, like Material's
                            ;; low-chroma secondary tonal palette.
                            (jetpacs-theme--blend
                             primary (jetpacs-theme--blend fg bg 0.5) 0.5)
                            primary))
             (tertiary (or (and modus (jetpacs-theme--modus 'cyan))
                           (jetpacs-theme--face-color
                            :foreground 'font-lock-constant-face)
                           secondary))
             (err (or (and modus (jetpacs-theme--modus 'red))
                      (jetpacs-theme--face-color :foreground 'error)
                      "#b3261e"))
             ;; Container tone: modus ships purpose-built subtle tints
             ;; (documented as legible under fg-main); otherwise sink the
             ;; accent most of the way into the background.
             (container (lambda (accent modus-key)
                          (or (and modus (jetpacs-theme--modus modus-key))
                              (jetpacs-theme--blend accent bg 0.22))))
             (on-container (lambda (accent)
                             (if modus fg
                               (jetpacs-theme--blend accent fg 0.35)))))
        (jetpacs-theme--compact
         `((primary . ,primary)
           (on_primary . ,bg)
           (primary_container . ,(funcall container primary 'bg-blue-subtle))
           (on_primary_container . ,(funcall on-container primary))
           (secondary . ,secondary)
           (on_secondary . ,bg)
           (secondary_container . ,(funcall container secondary 'bg-blue-nuanced))
           (on_secondary_container . ,(funcall on-container secondary))
           (tertiary . ,tertiary)
           (on_tertiary . ,bg)
           (tertiary_container . ,(funcall container tertiary 'bg-cyan-subtle))
           (on_tertiary_container . ,(funcall on-container tertiary))
           (error . ,err)
           (on_error . ,bg)
           (error_container . ,(funcall container err 'bg-red-subtle))
           (on_error_container . ,(funcall on-container err))
           (background . ,bg)
           (on_background . ,fg)
           (surface . ,bg)
           (on_surface . ,fg)
           (surface_variant . ,(or (and modus (jetpacs-theme--modus 'bg-dim))
                                   (jetpacs-theme--face-color
                                    :background 'mode-line-inactive)
                                   (jetpacs-theme--blend fg bg 0.08)))
           (on_surface_variant . ,(or (and modus (jetpacs-theme--modus 'fg-dim))
                                      (jetpacs-theme--face-color
                                       :foreground 'mode-line-inactive)
                                      fg))
           (outline . ,(or (and modus (jetpacs-theme--modus 'border))
                           (jetpacs-theme--face-color :foreground 'shadow)
                           (jetpacs-theme--blend fg bg 0.5)))))))))

(defun jetpacs-theme--syntax ()
  "Editor token-color alist from the theme's font-lock/org/outline faces.
Keys mirror the companion's SyntaxColors; missing faces are simply
omitted and the companion keeps its static color for that token."
  (let* ((heading (cl-loop for f in '(outline-1 outline-2 outline-3
                                      outline-4 outline-5 outline-6)
                           for hex = (jetpacs-theme--face-color :foreground f)
                           when hex collect hex))
         (paren (cl-remove-duplicates
                 (delq nil
                       (mapcar (lambda (f)
                                 (jetpacs-theme--face-color :foreground f))
                               '(font-lock-keyword-face
                                 font-lock-constant-face
                                 font-lock-string-face
                                 font-lock-function-name-face
                                 font-lock-builtin-face
                                 font-lock-type-face)))
                 :test #'equal :from-end t)))
    (jetpacs-theme--compact
     `((comment . ,(jetpacs-theme--face-color
                    :foreground 'font-lock-comment-face))
       (string . ,(jetpacs-theme--face-color
                   :foreground 'font-lock-string-face))
       (keyword . ,(jetpacs-theme--face-color
                    :foreground 'font-lock-keyword-face))
       (function . ,(jetpacs-theme--face-color
                     :foreground 'font-lock-function-name-face))
       (constant . ,(jetpacs-theme--face-color
                     :foreground 'font-lock-constant-face))
       (number . ,(jetpacs-theme--face-color
                   :foreground 'font-lock-number-face
                   'font-lock-constant-face))
       (link . ,(jetpacs-theme--face-color :foreground 'link))
       (meta . ,(jetpacs-theme--face-color
                 :foreground 'font-lock-preprocessor-face 'shadow))
       (todo . ,(jetpacs-theme--face-color :foreground 'org-todo 'error))
       (done . ,(jetpacs-theme--face-color :foreground 'org-done 'success))
       (heading . ,(and heading (vconcat heading)))
       (paren . ,(and paren (vconcat paren)))))))

(defun jetpacs-theme-payload ()
  "The full `theme.set' payload for the active theme, or nil.
nil means the frame can't resolve colors (batch/tty) — callers must not
push in that case, so a colorless session never wipes a good palette."
  (when-let ((colors (jetpacs-theme--colors)))
    `((dark . ,(if (jetpacs-theme--dark-p (alist-get 'surface colors))
                   t :false))
      (colors . ,colors)
      (syntax . ,(jetpacs-theme--syntax)))))

;; ─── Pushing ─────────────────────────────────────────────────────────────────

(defun jetpacs-theme-send ()
  "Push the active Emacs theme's palette to the companion, once.
Works regardless of `jetpacs-theme-sync' — a manual one-shot mirror."
  (interactive)
  (cond
   ((not (jetpacs-connected-p))
    (message "Jetpacs: not connected"))
   ((not (jetpacs-granted-p "theme"))
    (message "Jetpacs: companion predates theme sync; update the app"))
   (t
    (let ((payload (jetpacs-theme-payload)))
      (if (null payload)
          (message "Jetpacs: this frame reports no usable theme colors")
        (jetpacs-send "theme.set" payload)
        (message "Jetpacs: theme pushed"))))))

(defun jetpacs-theme-clear ()
  "Revert the companion to its own scheme (Material You / Emacs purple).
Sends the documented clear form — `colors: null' — which also wipes the
palette the companion had persisted."
  (interactive)
  (when (and (jetpacs-connected-p) (jetpacs-granted-p "theme"))
    (jetpacs-send "theme.set" '((colors . :null)))))

(defvar jetpacs-theme--timer nil
  "Debounce timer for automatic pushes, or nil.")

(defun jetpacs-theme--push-soon (&rest _)
  "Debounced auto-push, gated on `jetpacs-theme-sync' and the theme grant.
Debounced because `load-theme' fires disable+enable back to back, and
re-gated inside the timer because the connection can die in between."
  (when (and jetpacs-theme-sync
             (jetpacs-connected-p)
             (jetpacs-granted-p "theme"))
    (when (timerp jetpacs-theme--timer)
      (cancel-timer jetpacs-theme--timer))
    (setq jetpacs-theme--timer
          (run-at-time
           0.2 nil
           (lambda ()
             (setq jetpacs-theme--timer nil)
             (when (and jetpacs-theme-sync (jetpacs-connected-p))
               (when-let ((payload (jetpacs-theme-payload)))
                 (jetpacs-send "theme.set" payload))))))))

(defun jetpacs-theme--on-connect (_welcome)
  (jetpacs-theme--push-soon))

(add-hook 'jetpacs-connected-hook #'jetpacs-theme--on-connect)

;; Emacs 29+: follow theme switches live. On 28 the palette still refreshes
;; on every (re)connect; push manually after a mid-session load-theme.
(when (boundp 'enable-theme-functions)
  (add-hook 'enable-theme-functions #'jetpacs-theme--push-soon)
  (add-hook 'disable-theme-functions #'jetpacs-theme--push-soon))

(provide 'jetpacs-theme)
;;; jetpacs-theme.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-widgets.el
;;; ==================================================================

;;; jetpacs-widgets.el --- Jetpacs SDUI widget constructors -*- lexical-binding: t; -*-

;; Provides all UI-tree constructors for Jetpacs surfaces.
;; These functions build the alists that are serialized to JSON.
;;
;; Every constructor funnels through `jetpacs--node': type + (KEY VALUE)
;; pairs, where nil values are dropped.  That one rule replaces the old
;; per-constructor `(when x (push …))' boilerplate and keeps the wire
;; format in a single, greppable place per widget.

;;; Code:

(require 'cl-lib)

(defun jetpacs--node (type &rest kvs)
  "Build a widget node alist of TYPE from KVS (alternating KEY VALUE).
Pairs whose VALUE is nil are omitted, so optional attributes read as
plain arguments at the call site.  TYPE nil builds a bare alist (used
by sub-specs like actions, drawer items, and top bars that carry no
`t' discriminator)."
  (let (pairs)
    (while kvs
      (let ((k (pop kvs)) (v (pop kvs)))
        (when v (push (cons k v) pairs))))
    (if type
        (cons (cons 't type) (nreverse pairs))
      (nreverse pairs))))

;; ─── Core & Layout ───────────────────────────────────────────────────────────

(defun jetpacs-text (text &optional style weight color selectable max-lines padding)
  "A text node. STYLE is title/headline/body/caption/label.
WEIGHT is the layout weight. COLOR is a hex string."
  (jetpacs--node "text"
              'text text
              'style (and style (format "%s" style))
              'weight weight
              'color color
              'selectable (and selectable t)
              'max_lines max-lines
              'padding padding))

(cl-defun jetpacs-markup (text &key syntax style padding)
  "A read-only TEXT node with optional client-side highlighting.
SYNTAX (\"org\", \"elisp\") turns on the highlighter; STYLE is the same set
as `jetpacs-text'. Use this for displaying code/org content; for plain labels
use `jetpacs-text'."
  (jetpacs--node "text"
              'text text
              'syntax (and syntax (format "%s" syntax))
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun jetpacs-rich-text (spans &key style padding)
  "A rich-text node rendering SPANS (a list from `jetpacs-span').
Use this for org content Emacs has already parsed into styled runs —
emphasis, links, and #tags render natively rather than as highlighted
monospace. STYLE is the base text style (title/body/caption/label)."
  (jetpacs--node "rich_text"
              'spans (vconcat spans)
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun jetpacs-span (text &key bold italic underline strike code tag baseline color bg on-tap mono)
  "A styled text run for `jetpacs-rich-text'.
BOLD/ITALIC/UNDERLINE/STRIKE/CODE toggle emphasis; TAG themes it like a
#hashtag; BASELINE is \"super\" or \"sub\"; COLOR is a hex foreground
override and BG a hex background (diff shading, hl-line, region, isearch);
ON-TAP makes it a clickable link.  MONO renders the run in a fixed-width
font without the code-styling background — used by the generic buffer
renderer to preserve column alignment (dired, magit, tables, ascii)."
  (jetpacs--node nil
              'text text
              'bold (and bold t)
              'italic (and italic t)
              'underline (and underline t)
              'strike (and strike t)
              'code (and code t)
              'tag (and tag t)
              'baseline baseline
              'color color
              'bg bg
              'on_tap on-tap
              'mono (and mono t)))

(defun jetpacs--children-and-opts (args)
  "Split ARGS into (CHILDREN . OPTS) at the first keyword in ARGS.
Child nodes are alists, never keywords, so the first keyword in ARGS
marks the start of a trailing options plist.  Lets the `&rest'-children
constructors take options without breaking `(jetpacs-row a b c)' callers."
  (let ((i (cl-position-if #'keywordp args)))
    (if i (cons (cl-subseq args 0 i) (cl-subseq args i))
      (cons args nil))))

(defun jetpacs-row (&rest args)
  "A horizontal row of child nodes.
ARGS is child nodes, optionally followed by keywords: :spacing (dp
between children), :align (cross-axis \"top\"/\"center\"/\"bottom\"),
and :scroll (pan sideways on overflow)."
  (let* ((split (jetpacs--children-and-opts args)))
    (jetpacs--node "row"
                'children (vconcat (car split))
                'spacing (plist-get (cdr split) :spacing)
                'align (plist-get (cdr split) :align)
                'scroll (and (plist-get (cdr split) :scroll) t))))

(defun jetpacs-flow-row (&rest args)
  "A horizontal row of children that wraps onto new lines when full.
The right container for chip/tag rows, which overflow a plain `jetpacs-row'.
Optional trailing keywords: :spacing and :run-spacing (dp)."
  (let* ((split (jetpacs--children-and-opts args)))
    (jetpacs--node "flow_row"
                'children (vconcat (car split))
                'spacing (plist-get (cdr split) :spacing)
                'run_spacing (plist-get (cdr split) :run-spacing))))

(defun jetpacs-scroll-row (&rest children)
  "A horizontal row of CHILDREN that pans sideways when it overflows.
The single-line counterpart to `jetpacs-flow-row' (which wraps instead):
use it for chip rails that must stay on one row.  Child weights are
ignored — a scrolling row has no bounded width to distribute."
  (jetpacs--node "row" 'children (vconcat children) 'scroll t))

(defun jetpacs-column (&rest args)
  "A vertical column of child nodes.
ARGS is child nodes, optionally followed by keywords: :spacing (dp
between children), :align (cross-axis \"start\"/\"center\"/\"end\"),
and :scroll (make the column scroll vertically)."
  (let* ((split (jetpacs--children-and-opts args)))
    (jetpacs--node "column"
                'children (vconcat (car split))
                'spacing (plist-get (cdr split) :spacing)
                'align (plist-get (cdr split) :align)
                'scroll (and (plist-get (cdr split) :scroll) t))))

(defun jetpacs-scroll-column (&rest children)
  "A vertically scrollable column of CHILDREN nodes."
  (jetpacs--node "column" 'children (vconcat children) 'scroll t))

(cl-defun jetpacs-border (&key (width 1) color)
  "A border spec of WIDTH dp in COLOR (hex or theme token).
Pass as the :border of `jetpacs-box' / `jetpacs-surface' / `jetpacs-card'."
  (jetpacs--node nil 'width width 'color color))

(cl-defun jetpacs-box (children &key alignment padding weight on-tap
                             width height fill-fraction border)
  "A Box wrapping CHILDREN.
WIDTH/HEIGHT fix the box size (dp); FILL-FRACTION (0.0-1.0) sets it to a
fraction of the parent width; BORDER is an `jetpacs-border' spec."
  (jetpacs--node "box"
              'children (vconcat children)
              'alignment alignment
              'padding padding
              'weight weight
              'on_tap on-tap
              'width width
              'height height
              'fill_fraction fill-fraction
              'border border))

(cl-defun jetpacs-surface (children &key color shape elevation padding fill
                                 width height fill-fraction border)
  "A Surface wrapping CHILDREN.
COLOR is a hex string or a theme token (\"primary\", \"surface_container\",
\"primary_container\", …) that adapts to the device's light/dark theme.
SHAPE is \"rounded\", \"rounded_small\", or \"circle\".  FILL stretches the
surface to full width (e.g. zebra rows in a list).  WIDTH/HEIGHT fix the
size (dp), FILL-FRACTION (0.0-1.0) sets a fraction of parent width, and
BORDER is an `jetpacs-border' spec stroked with SHAPE."
  (jetpacs--node "surface"
              'children (vconcat children)
              'color color
              'shape shape
              'elevation elevation
              'padding padding
              'fill (and fill t)
              'width width
              'height height
              'fill_fraction fill-fraction
              'border border))

(defun jetpacs-lazy-column (&rest children)
  "A scrollable column of CHILDREN."
  (jetpacs--node "lazy_column" 'children (vconcat children)))

(defun jetpacs-scroll-here (node)
  "Mark NODE as the scroll target of its enclosing `jetpacs-lazy-column'.
The client scrolls the list to this child on first show and whenever
the child's index changes (e.g. new transcript output shifting a REPL's
input row down); a re-push that leaves the index unchanged never
disturbs the user's scroll position.  One target per lazy column — the
first flagged child wins."
  (append node '((scroll_here . t))))

(cl-defun jetpacs-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (jetpacs--node "spacer" 'height height 'width width 'weight weight))

(defun jetpacs-divider ()
  "A horizontal divider."
  (jetpacs--node "divider"))

(cl-defun jetpacs-card (children &key on-tap padding weight on-swipe
                              swipe-start swipe-end
                              width height fill-fraction border)
  "An elevated card wrapping CHILDREN.
WIDTH/HEIGHT fix the size (dp), FILL-FRACTION (0.0-1.0) sets a fraction
of parent width, and BORDER is an `jetpacs-border' spec.
SWIPE-START / SWIPE-END are `jetpacs-swipe-action' specs revealed by
dragging the card from that side; a full swipe fires the action and the
card springs back (push the updated list in the handler).  They win
over the legacy single-action ON-SWIPE.  Old companions render no
gesture, so a swipe action must also be reachable by tap or menu."
  (jetpacs--node "card"
              'children (vconcat children)
              'on_tap on-tap
              'on_swipe on-swipe
              'swipe_start swipe-start
              'swipe_end swipe-end
              'padding padding
              'weight weight
              'width width
              'height height
              'fill_fraction fill-fraction
              'border border))

(cl-defun jetpacs-swipe-action (icon label action &key color)
  "A per-side card swipe action (`jetpacs-card' :swipe-start / :swipe-end).
ICON and LABEL are revealed on the swipe background as the card drags;
ACTION is dispatched once on a full swipe.  COLOR optionally tints the
revealed background (hex; defaults to a theme container color)."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_trigger action
              'color color))

(cl-defun jetpacs-tab-item (label &key icon)
  "One tab in a `jetpacs-tabs' row: LABEL with an optional ICON above it."
  (jetpacs--node nil 'label label 'icon icon))

(cl-defun jetpacs-tabs (items children &key initial scrollable pager-only
                              on-change id)
  "An intra-view tab row over swipeable pages (SPEC §9 `tabs').
ITEMS (from `jetpacs-tab-item') label the tabs; CHILDREN is the
same-length list of page nodes.  Switching — tab tap or horizontal
swipe — is companion-local and never round-trips, the `view.switch'
philosophy; ON-CHANGE optionally dispatches on a settled page change
with the new index injected into args as `value'.  INITIAL picks the
starting page; SCROLLABLE lets many tabs pan instead of cramming;
PAGER-ONLY drops the tab row entirely for pure swipe-through content
\(flashcard review).  The user's page survives re-pushes; ID, when
non-nil, keys that client-side state — a push carrying a NEW id resets
to INITIAL (a fresh flashcard lands on its question page).  A companion
that predates the node stacks all pages — gate on
`jetpacs-node-supported-p' and fall back to a chip row plus the
selected child."
  (jetpacs--node "tabs"
              'items (vconcat items)
              'children (vconcat children)
              'initial initial
              'scrollable (and scrollable t)
              'pager_only (and pager-only t)
              'on_change on-change
              'id id))

(cl-defun jetpacs-collapsible (id header children &key collapsed on-long-tap on-swipe)
  "A fold/expand section. ID keys the (client-side) fold state.
HEADER is the always-visible node shown next to the chevron; CHILDREN
(a list of nodes) are revealed when expanded. COLLAPSED non-nil starts
folded. Folding happens entirely on-device — no action round-trip.
ON-LONG-TAP, when non-nil, is an action dispatched on long-press of
the header (used by the org reader to open the heading detail view)."
  (jetpacs--node "collapsible"
              'id id
              'header header
              'children (vconcat children)
              'collapsed (and collapsed t)
              'on_long_tap on-long-tap
              'on_swipe on-swipe))

(cl-defun jetpacs-reorderable-list (items &key on-reorder)
  "A drag-reorderable list of ITEMS.
Each item is an alist with at least (label . STRING) and (level . INT).
ON-REORDER is an action template dispatched with additional keys
\(from_pos . N) (after_pos . M) (new_level . L) when the user drops
a dragged item.  Dragging vertically reorders; horizontally promotes
or demotes."
  (jetpacs--node "reorderable_list"
              'items (vconcat items)
              'on_reorder on-reorder))

(cl-defun jetpacs-table (rows &key aligns on-add-row on-add-col padding)
  "A grid of cells with org-table semantics.
ROWS is a list from `jetpacs-table-row' and `jetpacs-table-rule'.  Columns
size to their widest cell and the grid pans horizontally on-device
when it overflows the screen — the whole table ships once.
ALIGNS is a list of per-column alignments (\"start\", \"center\",
\"end\"); columns beyond its length default to start.
ON-ADD-ROW / ON-ADD-COL, when non-nil, make the client render slim
\"+\" append affordances (a strip below the last row / a gutter after
the last column) that dispatch those actions.  The actions carry no
client-added args — embed the table's location when building them."
  (jetpacs--node "table"
              'rows (vconcat rows)
              'aligns (and aligns (vconcat aligns))
              'on_add_row on-add-row
              'on_add_col on-add-col
              'padding padding))

(cl-defun jetpacs-table-row (cells &key header)
  "A table row of CELLS (from `jetpacs-table-cell').
HEADER marks the row as part of the header group: the client renders
it emphasized, with a heavier rule under the group."
  (jetpacs--node nil
              'cells (vconcat cells)
              'header (and header t)))

(defun jetpacs-table-rule ()
  "A horizontal rule row (an org hline) — a divider line inside the grid."
  (jetpacs--node nil 'rule t))

(cl-defun jetpacs-table-cell (spans &key on-tap on-long-tap)
  "A table cell rendering SPANS (a list from `jetpacs-span').
ON-TAP / ON-LONG-TAP dispatch as-is — embed the cell's file/pos in the
action args when building it (the client adds nothing)."
  (jetpacs--node nil
              'spans (vconcat spans)
              'on_tap on-tap
              'on_long_tap on-long-tap))

;; ─── Interactive ─────────────────────────────────────────────────────────────

(cl-defun jetpacs-action (action &key args (when-offline "queue") dedupe)
  "An action descriptor."
  (jetpacs--node nil
              'action action
              'when_offline when-offline
              'args args
              'dedupe dedupe))

(defun jetpacs-clipboard-action (text)
  "A companion-local action that copies TEXT to the device clipboard.
Handled entirely on-device (like the `view.switch' builtin) — no
round-trip to Emacs, works offline."
  (jetpacs--node nil 'builtin "clipboard.copy" 'text text))

(defun jetpacs-native-settings-action ()
  "Open native Jetpacs settings, even while Emacs is offline."
  (jetpacs--node nil 'builtin "jetpacs.settings.open"))

(cl-defun jetpacs-button (label action &key icon variant weight padding)
  "A button. VARIANT is filled/outlined/text/tonal."
  (jetpacs--node "button"
              'label label
              'on_tap action
              'icon icon
              'variant variant
              'weight weight
              'padding padding))

(cl-defun jetpacs-date-button (label on-pick &key value)
  "A button that opens a date picker. ON-PICK is dispatched with the chosen
date injected into its args as `value' (\"YYYY-MM-DD\"). VALUE seeds the
picker (\"YYYY-MM-DD\")."
  (jetpacs--node "date_button" 'label label 'on_pick on-pick 'value value))

(cl-defun jetpacs-time-button (label on-pick &key value)
  "A button that opens a time picker. ON-PICK is dispatched with the chosen
time injected into its args as `value' (\"HH:MM\"). VALUE seeds the picker."
  (jetpacs--node "time_button" 'label label 'on_pick on-pick 'value value))

(cl-defun jetpacs-image (url &key content-description padding
                          width height aspect-ratio content-scale)
  "An image loaded from URL (an http(s) URL or a readable file:// path).
WIDTH/HEIGHT fix the size (dp); ASPECT-RATIO (w/h) constrains it;
CONTENT-SCALE is \"fit\" (default), \"crop\", or \"fill\".  With no width or
fill given the image fills the available width, as before."
  (jetpacs--node "image"
              'url url
              'content_description content-description
              'padding padding
              'width width
              'height height
              'aspect_ratio aspect-ratio
              'content_scale (and content-scale (format "%s" content-scale))))

;; ─── Visualization ladder (SPEC §9) ──────────────────────────────────────────

(defun jetpacs--chart-point (p)
  "Normalize chart point P to a {y} / {x,y} node.
P is a number (→ {y}), or a two-element list/cons (X Y) (→ {x,y})."
  (cond ((numberp p) (jetpacs--node nil 'y p))
        ((consp p) (jetpacs--node nil 'x (car p) 'y (if (consp (cdr p)) (cadr p) (cdr p))))
        (t (jetpacs--node nil 'y 0))))

(cl-defun jetpacs-chart-series (points &key label color)
  "One chart series over POINTS (numbers, or (X Y) pairs).
LABEL and COLOR (hex or theme token) are optional."
  (jetpacs--node nil
              'label label
              'color color
              'points (vconcat (mapcar #'jetpacs--chart-point points))))

(cl-defun jetpacs-chart (series &key kind height y-range summary on-point-tap)
  "A data-driven chart of SERIES (a list from `jetpacs-chart-series').
KIND is \"line\" (default), \"bar\", \"area\", or \"sparkline\".  HEIGHT is
in dp; Y-RANGE is (MIN MAX); SUMMARY is the accessibility label;
ON-POINT-TAP fires with the tapped point injected as `value'.  Rung 1 of
the visualization ladder — data in, polished chart out, no draw ops."
  (jetpacs--node "chart"
              'series (vconcat series)
              'kind (and kind (format "%s" kind))
              'height height
              'y_range (and y-range (vconcat y-range))
              'summary summary
              'on_point_tap on-point-tap))

(cl-defun jetpacs-canvas (width height ops)
  "A canvas of WIDTH×HEIGHT dp rendering OPS (a list of draw-op nodes).
Ops come from `jetpacs-draw-line'/`-rect'/`-circle'/`-path'/`-text';
coordinates are in the WIDTH×HEIGHT space.  Rung 2 — the elisp-only
escape hatch for visuals no curated node covers."
  (jetpacs--node "canvas" 'width width 'height height 'ops (vconcat ops)))

(cl-defun jetpacs-month-grid (month &key marks selected min-month max-month
                                    on-day-tap on-month-change)
  "An agenda month calendar for MONTH (\"YYYY-MM\") — SPEC §9 `month_grid'.
MARKS is an alist of (\"YYYY-MM-DD\" . SPEC): SPEC is a dot count
\(1-3 dots render under the day) or an alist like
\((dots . N) (color . \"#hex\")).  SELECTED (\"YYYY-MM-DD\") fills one
day; today is always outlined.  MIN-MONTH/MAX-MONTH (\"YYYY-MM\") clamp
the companion-local month navigation (chevrons and horizontal swipe).
ON-DAY-TAP dispatches with the tapped date injected into args as
`value'; ON-MONTH-CHANGE with the newly shown \"YYYY-MM\" — answer it
by pushing fresh marks (marks for unfetched months are simply absent,
never blocking).  An additive node: gate on `jetpacs-node-supported-p';
the fallback recipe is a `jetpacs-flow-row' of `fill_fraction'-sized day
boxes with `on_tap'."
  (jetpacs--node "month_grid"
              'month month
              'marks (and marks
                          (mapcar (lambda (m)
                                    (cons (intern (car m))
                                          (if (numberp (cdr m))
                                              `((dots . ,(cdr m)))
                                            (cdr m))))
                                  marks))
              'selected selected
              'min_month min-month
              'max_month max-month
              'on_day_tap on-day-tap
              'on_month_change on-month-change))

(cl-defun jetpacs-draw-line (x1 y1 x2 y2 &key color stroke)
  "A canvas line op from (X1 Y1) to (X2 Y2)."
  (jetpacs--node nil 'op "line" 'x1 x1 'y1 y1 'x2 x2 'y2 y2
              'color color 'stroke stroke))

(cl-defun jetpacs-draw-rect (x y w h &key color fill stroke radius)
  "A canvas rect op at (X Y) of size W×H; FILL vs stroked; ROUNDED by RADIUS."
  (jetpacs--node nil 'op "rect" 'x x 'y y 'w w 'h h 'color color
              'fill (and fill t) 'stroke stroke 'radius radius))

(cl-defun jetpacs-draw-circle (cx cy r &key color fill stroke)
  "A canvas circle op centred (CX CY) of radius R; FILL vs stroked."
  (jetpacs--node nil 'op "circle" 'cx cx 'cy cy 'r r 'color color
              'fill (and fill t) 'stroke stroke))

(cl-defun jetpacs-draw-path (points &key color fill stroke closed)
  "A canvas path op over POINTS (a list of (X Y) pairs); FILL/CLOSED optional."
  (jetpacs--node nil 'op "path"
              'points (vconcat (mapcar (lambda (p) (vector (nth 0 p) (nth 1 p))) points))
              'color color 'fill (and fill t) 'stroke stroke
              'closed (and closed t)))

(cl-defun jetpacs-draw-text (x y text &key color size align)
  "A canvas text op drawing TEXT at (X Y); ALIGN is start/center/end."
  (jetpacs--node nil 'op "text" 'x x 'y y 'text text 'color color 'size size
              'align (and align (format "%s" align))))

(cl-defun jetpacs-icon-button (icon action &key content-description padding badge)
  "An icon button.
BADGE overlays a count on the icon: a number (rendered capped at 99+)
or the empty string for a bare attention dot; nil for none."
  (jetpacs--node "icon_button"
              'icon icon
              'on_tap action
              'content_description content-description
              'padding padding
              'badge badge))

(cl-defun jetpacs-menu (items &key icon padding)
  "An overflow menu: an icon that opens a dropdown of ITEMS.
ITEMS is a list from `jetpacs-menu-item'. ICON defaults to a vertical
ellipsis. Folding/opening is handled entirely on-device."
  (jetpacs--node "menu" 'items (vconcat items) 'icon icon 'padding padding))

(cl-defun jetpacs-menu-item (label action &key icon)
  "An item in an overflow `jetpacs-menu': LABEL dispatches ACTION when tapped."
  (jetpacs--node nil 'label label 'on_tap action 'icon icon))

(cl-defun jetpacs-text-input (id &key value hint label on-submit single-line
                              multi-line min-lines max-lines monospace syntax
                              password keyboard padding)
  "A text input field.
ID identifies the field. ON-SUBMIT is an action dispatched when done.
The client defaults to single-line; pass MULTI-LINE non-nil for a box that
accepts newlines (Enter inserts a newline rather than submitting, so such a
field should be paired with a submit button). MIN-LINES/MAX-LINES size the box
and MONOSPACE renders it in a fixed-width font (handy for code).
SYNTAX (e.g. \"elisp\", \"org\") turns on client-side highlighting.
PASSWORD masks the entry (dots) and requests a password keyboard — used by
the `read-passwd' bridge; such a field's value must not be logged or
retained beyond the read.
KEYBOARD picks the IME: \"number\", \"decimal\", \"email\", \"phone\", or
\"uri\"; nil (or an unknown value) falls back to the text keyboard, and
PASSWORD always wins."
  (jetpacs--node "text_input"
              'id id
              'value value
              'hint hint
              'label label
              'on_submit on-submit
              ;; `:false' (not t) so the client overrides its single-line default.
              'single_line (cond (multi-line :false)
                                 (single-line t))
              'min_lines min-lines
              'max_lines max-lines
              'monospace (and monospace t)
              'syntax syntax
              'password (and password t)
              'keyboard keyboard
              'padding padding))

(cl-defun jetpacs-enum-list (id options &key value multi-select allow-add on-change padding)
  "An enum list for selecting from OPTIONS.
ID identifies the field. VALUE is a list/vector of currently selected strings.
MULTI-SELECT allows choosing multiple options. ALLOW-ADD shows an input for
adding new options. ON-CHANGE is an action dispatched when the selection
changes."
  (jetpacs--node "enum_list"
              'id id
              'options (vconcat options)
              ;; A bare string VALUE would vconcat into a vector of char
              ;; codes — wrap it as the one-element selection it means.
              'value (and value (vconcat (if (stringp value) (list value) value)))
              'multi_select (and multi-select t)
              'allow_add (and allow-add t)
              'on_change on-change
              'padding padding))

(cl-defun jetpacs-checkbox (id &key checked label on-change padding)
  "A checkbox."
  (jetpacs--node "checkbox"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun jetpacs-switch (id &key checked label on-change padding)
  "A toggle switch."
  (jetpacs--node "switch"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun jetpacs-slider (id on-change &key value min max steps)
  "A continuous slider identified by ID.
ON-CHANGE fires once on release with the position injected into args as
`value'.  VALUE seeds the position; MIN/MAX bound the range (default
0.0/1.0); STEPS, when > 0, makes the slider discrete."
  (jetpacs--node "slider"
              'id id
              'on_change on-change
              'value value
              'min min
              'max max
              'steps steps))

;; ─── Display ─────────────────────────────────────────────────────────────────

(cl-defun jetpacs-icon (name &key size color padding badge)
  "An icon display.
BADGE overlays a count: a number (capped at 99+ on-device) or the empty
string for a bare attention dot; nil for none."
  (jetpacs--node "icon" 'name name 'size size 'color color 'padding padding
              'badge badge))

(cl-defun jetpacs-chip (label &key on-tap selected icon padding)
  "A filter chip."
  (jetpacs--node "chip"
              'label label
              'on_tap on-tap
              'selected (and selected t)
              'icon icon
              'padding padding))

(cl-defun jetpacs-progress (&key variant value padding)
  "A progress indicator. VARIANT is circular/linear. VALUE is 0.0-1.0."
  (jetpacs--node "progress" 'variant variant 'value value 'padding padding))

(cl-defun jetpacs-assist-chip (label &key on-tap icon padding)
  "An assist chip (e.g. a #tag). LABEL is shown; ON-TAP fires on click.
Unlike `jetpacs-chip' (a selectable filter chip) this is a flat, tappable
suggestion chip — pair it with `jetpacs-flow-row' for wrapping tag rows."
  (jetpacs--node "assist_chip"
              'label label
              'on_tap on-tap
              'icon icon
              'padding padding))

(cl-defun jetpacs-section-header (title &key trailing padding)
  "A styled section label. TRAILING is an optional node shown at the end
\(e.g. a count or an `jetpacs-icon-button')."
  (jetpacs--node "section_header" 'title title 'trailing trailing 'padding padding))

(cl-defun jetpacs-empty-state (&key icon title caption on-tap action-label padding)
  "A centered empty-state placeholder.
ICON names a glyph (default \"inbox\"); TITLE and CAPTION describe the
emptiness. When ON-TAP and ACTION-LABEL are both given, an outlined
button is shown beneath the text."
  (jetpacs--node "empty_state"
              'icon icon
              'title title
              'caption caption
              'on_tap on-tap
              'action_label action-label
              'padding padding))

(defconst jetpacs--month-abbrevs
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
   "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
  "Short month labels used by `jetpacs-date-stamp'.")

(defun jetpacs-month-abbrev (n)
  "The three-letter English abbreviation for month N (1 = Jan .. 12 = Dec).
Returns nil when N is not an integer in 1..12."
  (and (integerp n) (>= n 1) (<= n 12)
       (aref jetpacs--month-abbrevs (1- n))))

(cl-defun jetpacs-date-stamp (&key date day month month-index year time padding)
  "A compact date/time chip-card.
Pass DATE as \"YYYY-MM-DD\" to derive DAY, MONTH (abbrev), YEAR and
MONTH-INDEX automatically, or supply those fields directly. TIME is an
optional \"HH:MM\" rendered in a second card below the date. MONTH-INDEX
\(1-12) drives the header tint."
  (when (and date
             (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" date))
    (let ((y (match-string 1 date))
          (m (string-to-number (match-string 2 date)))
          (d (string-to-number (match-string 3 date))))
      (setq year (or year y)
            month-index (or month-index m)
            month (or month (jetpacs-month-abbrev m))
            day (or day (number-to-string d)))))
  (jetpacs--node "date_stamp"
              'day (and day (format "%s" day))
              'month month
              'month_index month-index
              'year (and year (format "%s" year))
              'time time
              'padding padding))

;; ─── Home-screen widgets ─────────────────────────────────────────────────────
;;
;; Rows for `widget:*' surfaces (the home-screen list widgets, including
;; the blank `widget:customN' slots). The companion renders these with
;; RemoteViews, so the vocabulary is deliberately small: two-line rows
;; with an optional trailing icon button, plus bold section dividers.

(cl-defun jetpacs-widget-item (text &key todo done meta icon on-tap in-app
                                 button on-button)
  "A row in a home-screen widget list.
TEXT is the title line. TODO is a state keyword rendered as a colored
prefix while open; DONE strikes the title through. META is the
secondary line and ICON its glyph: \"scheduled\", \"deadline\",
\"event\", or \"folder\". ON-TAP is dispatched when the row is tapped;
IN-APP routes it through the opened companion app (navigation),
otherwise the tap is silent. BUTTON (\"todo_open\", \"todo_done\",
\"add\") shows a trailing icon button that dispatches ON-BUTTON
silently — it never opens the app."
  (jetpacs--node nil
              'text text
              'todo todo
              'done (and done t)
              'meta meta
              'icon icon
              'on_tap on-tap
              'tap_in_app (and in-app t)
              'button button
              'on_button on-button))

(defun jetpacs-widget-divider (label)
  "A bold section divider row (\"Overdue\", \"Today\") in a widget list."
  (jetpacs--node nil 'divider label))

(cl-defun jetpacs-tile (label &key subtitle icon state on-tap in-app)
  "A Quick Settings tile spec for a `tile:customN' slot surface.
LABEL and SUBTITLE are the tile texts (the subtitle shows on Android
10+). ICON names a glyph: \"todo_open\", \"todo_done\", \"add\",
\"refresh\", \"scheduled\", \"deadline\", \"event\", or \"folder\".
STATE is \"active\", \"inactive\" (the default), or \"unavailable\".
ON-TAP is dispatched when the tile is tapped; IN-APP opens the
companion app and routes the action through it, otherwise the tap
fires silently from the shade (no unlock required — compose
accordingly). An un-pushed slot shows as a grayed-out tile."
  (jetpacs--node nil
              'label label
              'subtitle subtitle
              'icon icon
              'state (and state (format "%s" state))
              'on_tap on-tap
              'tap_in_app (and in-app t)))

;; ─── Scaffold ────────────────────────────────────────────────────────────────

(cl-defun jetpacs-toolbar-item (icon label &key snippet placement line
                                on-tap long-press menu)
  "One item in a data-driven editor toolbar (SPEC §9 \"Editor toolbars\").
ICON names the chip glyph and LABEL is its short text.  Exactly one op
per item: SNIPPET is text the companion inserts locally, with the closed
placeholder set ${selection} ${cursor} ${input:Prompt} ${date} ${time}
\(unknown ${...} tokens insert literally); LINE is a builtin line op —
\"promote\", \"demote\", \"move-up\", or \"move-down\"; ON-TAP is an
ordinary action object dispatched to Emacs (the escape hatch); MENU is a
list of sub-items (this constructor with nil ICON) shown as a dropdown —
menus don't nest.  PLACEMENT refines SNIPPET: \"cursor\" (default),
\"line-start\" (prefix the cursor's line, deduped), or \"block\" (own
line\(s)).  LONG-PRESS is a secondary op — an item (nil ICON and LABEL)
carrying one of SNIPPET/LINE/ON-TAP.  Pass the item list to
`jetpacs-editor' :toolbar; `jetpacs-lint-spec' validates the vocabulary."
  (jetpacs--node nil
              'icon icon
              'label label
              'snippet snippet
              'placement placement
              'line line
              'on_tap on-tap
              'long_press long-press
              'menu (and menu (vconcat menu))))

(cl-defun jetpacs-editor (id value &key on-save read-only syntax line-numbers
                          complete chromeless publish-state toolbar)
  "A full-height plain-text editor node.
ID identifies the editor (its unsaved state lives companion-side under
this key). VALUE seeds the buffer. ON-SAVE is dispatched with the full
text injected into args as `value'. READ-ONLY disables editing/saving.
SYNTAX (\"elisp\", \"org\") forces highlighting; when omitted the client
infers it from the file extension in ID.  LINE-NUMBERS is \"absolute\"
or \"relative\" (relative to the cursor) for a gutter, nil for none.
COMPLETE enables Emacs-backed completion: the client sends debounced
`edit.complete' actions while typing and renders the returned candidates
as a suggestion strip (see jetpacs-complete.el).
CHROMELESS hides the filename/undo/save header and sizes the field
compactly instead of full-height — an inline field with the full bridge
\(completion, squiggles, doc line), e.g. the eval REPL input.
PUBLISH-STATE emits debounced `state.changed' with the text under ID,
so button-driven forms can read it back from `jetpacs-ui-state'.
TOOLBAR attaches a keyboard-adjacent formatting toolbar: a list of
`jetpacs-toolbar-item's the companion interprets as data (the default
path), or a string naming a host-registered native toolbar (the Kotlin
alternative — the reference companion registers none); nil for none.
Server-driven so the renderer stays app-agnostic: the app opts an
editor into the affordance."
  (jetpacs--node "editor"
              'id id
              'value value
              'on_save on-save
              'read_only (and read-only t)
              'syntax syntax
              'line_numbers line-numbers
              'complete (and complete t)
              'chromeless (and chromeless t)
              'publish_state (and publish-state t)
              'toolbar (if (and toolbar (listp toolbar))
                           (vconcat toolbar)
                         toolbar)))

(cl-defun jetpacs-scaffold (&key top-bar fab body bottom-bar floating-toolbar
                            snackbar snackbar-action drawer on-refresh)
  "The standard app frame.
SNACKBAR is the transient message text; SNACKBAR-ACTION optionally adds
an action button to it (`jetpacs-snackbar-action') — the undo
affordance.  Old companions show the plain message."
  (jetpacs--node "scaffold"
              'top_bar top-bar
              'fab fab
              'body body
              'bottom_bar bottom-bar
              'floating_toolbar floating-toolbar
              'snackbar snackbar
              'snackbar_action snackbar-action
              'drawer drawer
              'on_refresh on-refresh))

(cl-defun jetpacs-drawer (items &key header)
  "A navigation drawer spec. ITEMS is a list from `jetpacs-drawer-item'."
  (jetpacs--node nil 'header header 'items (vconcat items)))

(defun jetpacs-snackbar-action (label action)
  "An action button on the scaffold snackbar (`jetpacs-scaffold').
LABEL is the button text (\"Undo\"); ACTION dispatches only when the
user taps it — never when the snackbar times out, so a mutation stays
final unless explicitly recalled."
  (jetpacs--node nil 'label label 'on_tap action))

(cl-defun jetpacs-drawer-item (icon label action &key selected badge)
  "An item in the navigation drawer.
BADGE shows a trailing count: a number (capped at 99+ on-device) or the
empty string for a bare attention dot; nil for none."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)
              'badge badge))

(cl-defun jetpacs-top-bar (title &key nav-icon nav-action actions)
  "A TopAppBar spec."
  (jetpacs--node nil
              'title title
              'nav_icon nav-icon
              'nav_action nav-action
              'actions (and actions (vconcat actions))))

(cl-defun jetpacs-fab (icon &key label on-tap extended)
  "A FloatingActionButton spec."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_tap on-tap
              'extended (and extended t)))

(defun jetpacs-bottom-bar (items)
  "A BottomBar spec. ITEMS is a list from `jetpacs-nav-item'."
  (jetpacs--node nil 'items (vconcat items)))

(cl-defun jetpacs-nav-item (icon label action &key selected badge)
  "An item in the bottom bar.
BADGE overlays a count on the tab icon: a number (capped at 99+
on-device) or the empty string for a bare attention dot; nil for none."
  (jetpacs--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)
              'badge badge))

(provide 'jetpacs-widgets)
;;; jetpacs-widgets.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-lint.el
;;; ==================================================================

;;; jetpacs-lint.el --- validate SDUI specs before the wire -*- lexical-binding: t; -*-

;; A spec is a tree of alists built by the `jetpacs-widgets.el' constructors
;; and serialized to JSON by `jetpacs--encode'.  A malformed node — an
;; unknown `t', a non-serializable attribute value, a broken action —
;; either renders as nothing on the companion or, worse, makes
;; `json-serialize' throw and blanks the *whole* push.  This module lets a
;; Tier 1 catch those before they reach the wire:
;;
;;   `jetpacs-lint-spec'       — return a list of problems for a spec (nil = clean).
;;   `jetpacs-lint-payload'    — validate a frame kind + payload against the
;;                            kind schema (the frame-level counterpart).
;;   `jetpacs-render-to-json'  — serialize + parse a spec headless (the wire
;;                            round-trip, so views are testable with no phone).
;;   `jetpacs-lint-on-push'    — when set, `jetpacs-surface-update' replaces each
;;                            invalid node in place with a visible error node,
;;                            so one bad subtree degrades instead of the push.
;;
;; The known-type list is the same vocabulary as `SDUI_NODE_TYPES'
;; (SduiRenderer.kt) and `test/widgets.golden'; the drift test
;; `jetpacs-lint-types-cover-golden' fails if a constructor emits a `t' not
;; listed here.  Since Spec 1.0-rc the tables below also carry the authored
;; per-node key schema (`jetpacs-lint-node-schema') and the frame-kind
;; schema (`jetpacs-lint-kind-schema'); `build-contract.el' publishes both
;; in docs/contract.json (contract_format 2) for non-elisp implementations.

;;; Code:

(require 'cl-lib)
(require 'json)

;; `jetpacs--node' lives in jetpacs-widgets, which loads before this file (bundle
;; order and the core-load test). Declared so an isolated byte-compile of
;; this file alone stays warning-clean.
(declare-function jetpacs--node "jetpacs-widgets" (type &rest kvs))

(defconst jetpacs-lint-node-types
  '("text" "rich_text" "row" "flow_row" "column" "box" "surface"
    "lazy_column" "spacer" "divider" "card" "collapsible"
    "reorderable_list" "table" "tabs" "chart" "canvas" "month_grid"
    "icon" "image"
    "date_stamp" "section_header" "empty_state" "progress" "menu" "button"
    "icon_button" "chip" "assist_chip" "text_input" "editor" "checkbox"
    "switch" "enum_list" "date_button" "time_button" "slider" "scaffold")
  "Node `t' discriminators the reference companion renders.
Mirror of `SDUI_NODE_TYPES' in SduiRenderer.kt.  A `t' outside this set
is almost always a typo; a Tier 1 deliberately targeting an extended
companion gates on `jetpacs-node-supported-p' instead.")

(defconst jetpacs-lint--action-keys
  '(on_tap on_change on_submit on_save on_pick on_reorder on_refresh
    nav_action on_long_tap on_swipe on_add_row on_add_col on_trigger
    on_day_tap on_month_change on_point_tap on_button)
  "Node keys whose value is an embedded action object (SPEC §9).")

(defconst jetpacs-lint-action-fields '(action builtin args when_offline dedupe)
  "The fields an action object may carry (SPEC §5).
`action' and `builtin' are mutually exclusive; a `builtin' additionally
carries the payload keys its kind requires (`jetpacs-lint-action-builtins').")

(defconst jetpacs-lint--when-offline-values '("queue" "drop" "wake")
  "Valid `when_offline' queue policies (SPEC §5); the default is \"queue\".")

(defconst jetpacs-lint-action-builtins
  '(("view.switch" view)
    ("clipboard.copy" text)
    ("jetpacs.settings.open"))
  "Companion-local builtins → the payload keys each requires (SPEC §5).
Each entry is (NAME . REQUIRED-KEYS): an action object using `builtin'
must name one of these and carry every listed key.  `build-contract.el'
derives the discriminated action schema in `contract.json' from this.")

(defconst jetpacs-lint-node-common-keys '(scroll_here dialog_style)
  "Keys legal on any node, attached after construction.
`scroll_here' marks a lazy_column child as its scroll target
\(`jetpacs-scroll-here', SPEC §9); `dialog_style' rides a dialog spec's
root node (`jetpacs-send-dialog', SPEC §7).")

(defconst jetpacs-lint-node-schema
  ;; (TYPE REQUIRED-KEYS OPTIONAL-KEYS) — one row per entry of
  ;; `jetpacs-lint-node-types', same order.
  '(("text"            (text)               (style weight color selectable
                                             max_lines padding syntax))
    ("rich_text"       (spans)              (style padding))
    ("row"             (children)           (spacing align scroll))
    ("flow_row"        (children)           (spacing run_spacing))
    ("column"          (children)           (spacing align scroll))
    ("box"             (children)           (alignment padding weight on_tap
                                             width height fill_fraction border))
    ("surface"         (children)           (color shape elevation padding fill
                                             width height fill_fraction border))
    ("lazy_column"     (children)           ())
    ("spacer"          ()                   (height width weight))
    ("divider"         ()                   ())
    ("card"            (children)           (on_tap on_swipe swipe_start
                                             swipe_end padding weight width
                                             height fill_fraction border))
    ("collapsible"     (id header children) (collapsed on_long_tap on_swipe))
    ("reorderable_list" (items)             (on_reorder))
    ("table"           (rows)               (aligns on_add_row on_add_col
                                             padding))
    ("tabs"            (items children)     (initial scrollable pager_only
                                             on_change id))
    ("chart"           (series)             (kind height y_range summary
                                             on_point_tap))
    ("canvas"          (width height ops)   ())
    ("month_grid"      (month)              (marks selected min_month max_month
                                             on_day_tap on_month_change))
    ("icon"            (name)               (size color padding badge))
    ("image"           (url)                (content_description padding width
                                             height aspect_ratio content_scale))
    ("date_stamp"      ()                   (day month month_index year time
                                             padding))
    ("section_header"  (title)              (trailing padding))
    ("empty_state"     ()                   (icon title caption on_tap
                                             action_label padding))
    ("progress"        ()                   (variant value padding))
    ("menu"            (items)              (icon padding))
    ("button"          (label on_tap)       (icon variant weight padding))
    ("icon_button"     (icon on_tap)        (content_description padding badge))
    ("chip"            (label)              (on_tap selected icon padding))
    ("assist_chip"     (label)              (on_tap icon padding))
    ("text_input"      (id)                 (value hint label on_submit
                                             single_line min_lines max_lines
                                             monospace syntax password keyboard
                                             padding))
    ("editor"          (id)                 (value on_save read_only syntax
                                             line_numbers complete chromeless
                                             publish_state toolbar))
    ("checkbox"        (id)                 (checked label on_change padding))
    ("switch"          (id)                 (checked label on_change padding))
    ("enum_list"       (id options)         (value multi_select allow_add
                                             on_change padding))
    ("date_button"     (label on_pick)      (value))
    ("time_button"     (label on_pick)      (value))
    ("slider"          (id on_change)       (value min max steps))
    ("scaffold"        ()                   (top_bar fab body bottom_bar
                                             floating_toolbar snackbar
                                             snackbar_action drawer on_refresh)))
  "Per-node key schema: (TYPE REQUIRED OPTIONAL), one row per node type.
Authored from `test/widgets.golden' ∪ the `jetpacs-widgets.el' constructor
signatures, hand-reviewed against WIDGETS.md and SPEC §9 (the review is
SPEC-CHANGES.md entry #1).  `jetpacs-lint-spec' reports a missing REQUIRED
key as an error and a key outside the row (and outside
`jetpacs-lint-node-common-keys') as a warning — a warning, not an error,
because companions must ignore unknown keys (the §9 forward-compat rule),
so an author may deliberately target a newer companion.  Value types are
not re-declared here: the numeric/color/action key classes above apply by
key name.  `build-contract.el' publishes this as `node_schema'.")

(defconst jetpacs-lint-kind-schema
  ;; (KIND DIRECTION REQUIRED OPTIONAL) | (KIND DIRECTION node)
  ;; DIRECTION: who sends it — `client' (Emacs), `companion', or `both'.
  ;; `node' marks a payload that is a §9 node tree rather than a fixed
  ;; key set.
  '(;; Handshake (SPEC §3)
    ("session.hello"    client    (protocol client wants) (features))
    ("auth.challenge"   companion (nonce)                 ())
    ("auth.response"    client    (nonce mac)             ())
    ("session.welcome"  companion (server_proof granted node_types surfaces
                                   queued_events)
                                                          (protocol server
                                                           device))
    ;; Envelope-level (SPEC §2)
    ("ack"              both      ()                      ())
    ("error"            both      (code)                  (detail perm settings))
    ("ping"             both      ()                      ())
    ("pong"             both      ()                      ())
    ;; Surfaces, events, offline queue (SPEC §4–§6)
    ("surface.update"   client    (surface revision spec) (ttl_s stale_spec
                                                           current_view))
    ("surface.remove"   client    (surface)               ())
    ("event.action"     companion (action)                (args surface
                                                           revision_seen fields
                                                           queued_at))
    ("state.changed"    companion (id value)              ())
    ("queue.replay"     client    ()                      ())
    ("queue.drained"    companion (delivered expired)     (duplicate_request))
    ;; Dialogs, toasts, pies, reminders, theme (SPEC §7)
    ("dialog.show"      client    node)
    ("dialog.dismiss"   client    ()                      ())
    ("pie_menu.show"    client    (categories)            (center_label buffer))
    ("pie_menu.dismiss" client    ()                      ())
    ("toast.show"       client    (text)                  ())
    ("reminders.set"    client    (reminders)             (owner))
    ("theme.set"        client    ()                      (dark colors syntax))
    ;; Editor sync & completion (SPEC §8).  The companion→client legs
    ;; (edit.open/delta/caret/close/complete) are §5 actions riding
    ;; `event.action', not frame kinds — only the client→companion legs
    ;; appear here.
    ("completions.show" client    (id request_id prefix candidates) ())
    ("diagnostics.show" client    (id session seq diags)  ())
    ("eldoc.show"       client    (id session text)       ())
    ("fontify.show"     client    (id session seq runs)   ())
    ("edit.resync"      client    (id session)            ())
    ;; Device capabilities & triggers (SPEC §10–§11)
    ("capability.invoke" client   (cap)                   (args))
    ("capability.result" companion (ok)                   (result))
    ("triggers.set"      client   (triggers)              ()))
  "Frame-kind schema: kind → sender direction + payload keys.
Mirrors `Kind' in Envelope.kt and the frame vocabulary of SPEC §§2–8,
10–11, authored from the reference implementations' actual send sites.
`jetpacs-lint-payload' enforces it (missing required = error, unknown
key = warning); `build-contract.el' publishes it as `kind_schema'.
Action names (§5 registry entries, e.g. `trigger.fired', `edit.open')
are deliberately NOT enumerated — they are negotiated vocabulary, not
frame kinds.")

(defconst jetpacs-lint--numeric-attrs
  '(padding weight spacing run_spacing elevation size min_lines max_lines
    width height fill_fraction aspect_ratio min max steps initial dots
    ;; canvas draw-op coordinates
    x y w h r cx cy x1 y1 x2 y2 radius stroke)
  "Attributes whose value must be a number.")

(defconst jetpacs-lint--color-attrs '(color bg)
  "Attributes whose value must be a hex string or a theme token.")

(defconst jetpacs-lint--toolbar-ops '(snippet line on_tap menu)
  "The op fields of an editor toolbar item — exactly one per item (SPEC §9).")

(defconst jetpacs-lint--toolbar-placements '("cursor" "line-start" "block")
  "Valid `placement' values on a toolbar snippet item.")

(defconst jetpacs-lint--toolbar-line-ops '("promote" "demote" "move-up" "move-down")
  "Valid builtin `line' op names on a toolbar item.")

;; ─── Declarative view specs (jetpacs-spec.el) ────────────────────────────────

(defconst jetpacs-lint-spec-layouts '("list" "board" "calendar")
  "Layouts a declarative view `:spec' may request.")

(defconst jetpacs-lint-spec-transforms
  '("raw" "string" "date" "date-label" "tags-list" "count" "bool" "ref")
  "The closed transform names a template placeholder's `as' may name.")

(defconst jetpacs-lint-spec-keys
  '(:source :params :layout :template :header :group-by :empty-state :chrome)
  "The keys a view `:spec' plist may carry.")

(defconst jetpacs-lint-spec-chrome-kinds '("tab" "nav")
  "The `:kind' values a spec `:chrome' may declare.")

;; ─── Shape predicates ────────────────────────────────────────────────────────

(defun jetpacs-lint--alist-p (x)
  "Non-nil when X is a non-empty proper list of conses (a node/subspec)."
  (and (consp x) (proper-list-p x) (cl-every #'consp x)))

(defun jetpacs-lint--node-seq-p (x)
  "Non-nil when X is a non-empty list or vector whose elements are all alists.
This is how children, spans, items, rows, and cells are distinguished
from a single nested node and from plain scalar sequences (a vector of
strings like table `aligns' is not a node sequence)."
  (let ((elts (cond ((vectorp x) (append x nil))
                    ((proper-list-p x) x)
                    (t 'bad))))
    (and (listp elts) elts (cl-every #'jetpacs-lint--alist-p elts))))

(defun jetpacs-lint--serializable-scalar-p (val)
  "Non-nil when VAL is a JSON-serializable scalar.
A string, number, vector, the boolean/null keywords, or nil — the leaf
values `json-serialize' accepts.  Containers and actions are validated by
recursion, not here."
  (or (stringp val) (numberp val) (vectorp val)
      (memq val '(t :false :null)) (null val)))

;; ─── Validation ──────────────────────────────────────────────────────────────

(defun jetpacs-lint--check-action (val path report)
  "Validate embedded action VAL at PATH, reporting via REPORT."
  (if (not (jetpacs-lint--alist-p val))
      (funcall report path (format "action must be an object: %S" val))
    (let ((action (alist-get 'action val))
          (builtin (alist-get 'builtin val))
          (wo (alist-get 'when_offline val))
          (args-cell (assq 'args val)))
      (cond ((and action builtin)
             (funcall report path "action has both `action' and `builtin'"))
            ((and (not action) (not builtin))
             (funcall report path "action has neither `action' nor `builtin'"))
            ((and action (not (stringp action)))
             (funcall report path (format "action name must be a string: %S" action)))
            ((and builtin (not (stringp builtin)))
             (funcall report path (format "builtin name must be a string: %S" builtin))))
      ;; A `builtin' names a companion-local action from a closed set; validate
      ;; the name and the payload keys its kind requires (SPEC §5).
      (when (stringp builtin)
        (let ((spec (assoc builtin jetpacs-lint-action-builtins)))
          (if (not spec)
              (funcall report path (format "unknown builtin: %S" builtin))
            (dolist (req (cdr spec))
              (unless (assq req val)
                (funcall report path
                         (format "builtin %s requires `%s'" builtin req)))))))
      (when (and wo (not (member wo jetpacs-lint--when-offline-values)))
        (funcall report path (format "invalid when_offline: %S" wo)))
      (when (and args-cell (cdr args-cell) (not (jetpacs-lint--alist-p (cdr args-cell))))
        (funcall report path "action `args' must be an object")))))

(defun jetpacs-lint--check-color (key val path report)
  "Validate color attribute KEY=VAL at PATH via REPORT."
  (cond ((not (stringp val))
         (funcall report path (format "%s must be a string: %S" key val)))
        ((and (string-prefix-p "#" val)
              (not (string-match-p "\\`#[0-9A-Fa-f]\\{3,8\\}\\'" val)))
         (funcall report path (format "%s is not a valid hex colour: %S" key val)))))

(defun jetpacs-lint--check-scalar (key val path report)
  "Report at PATH via REPORT when scalar KEY=VAL is not JSON-serializable."
  (unless (jetpacs-lint--serializable-scalar-p val)
    (funcall report path
             (format "%s has a non-serializable value: %S" key val))))

(defun jetpacs-lint--check-toolbar-item (item path report &optional no-menu)
  "Validate toolbar-item vocabulary for ITEM at PATH via REPORT (SPEC §9).
Checks the closed op set — exactly one of snippet/line/on_tap/menu —
and the placement/line enums, recursing into `menu' sub-items and
`long_press' with NO-MENU set (menus don't nest).  Action shape and
scalar serializability are the generic walk's job, not repeated here."
  (if (not (jetpacs-lint--alist-p item))
      (funcall report path (format "toolbar item must be an object: %S" item))
    (let ((ops (cl-remove-if-not (lambda (k) (assq k item))
                                 jetpacs-lint--toolbar-ops)))
      (unless (= (length ops) 1)
        (funcall report path
                 (format "toolbar item needs exactly one of %s, has %s"
                         jetpacs-lint--toolbar-ops (or ops "none"))))
      (when (and no-menu (assq 'menu item))
        (funcall report path "menu cannot nest inside menu or long_press"))
      (when-let ((cell (assq 'placement item)))
        (unless (member (cdr cell) jetpacs-lint--toolbar-placements)
          (funcall report path (format "invalid placement: %S" (cdr cell))))
        (unless (assq 'snippet item)
          (funcall report path "placement is only valid with snippet")))
      (when-let ((cell (assq 'line item)))
        (unless (member (cdr cell) jetpacs-lint--toolbar-line-ops)
          (funcall report path (format "invalid line op: %S" (cdr cell)))))
      (when-let ((menu (cdr (assq 'menu item))))
        (when (jetpacs-lint--node-seq-p menu)
          (let ((i 0))
            (dolist (sub (append menu nil))
              (jetpacs-lint--check-toolbar-item sub (cons i (cons 'menu path))
                                                report t)
              (setq i (1+ i))))))
      (when-let ((lp (cdr (assq 'long_press item))))
        (jetpacs-lint--check-toolbar-item lp (cons 'long_press path)
                                          report t)))))

(defun jetpacs-lint--check-schema (node type path report)
  "Enforce TYPE's key schema on NODE at PATH via REPORT (SPEC §9).
A missing required key is an error; a key outside the schema row (and
outside `jetpacs-lint-node-common-keys') is a \"warning: \"-prefixed
problem — companions ignore unknown keys, so an extra key may be a
deliberate newer-companion target, but is more often a typo."
  (when-let ((schema (assoc type jetpacs-lint-node-schema)))
    (dolist (req (nth 1 schema))
      (unless (assq req node)
        (funcall report path (format "%s: missing required `%s'" type req))))
    (dolist (pair node)
      (let ((key (car pair)))
        (unless (or (eq key 't)
                    (memq key (nth 1 schema))
                    (memq key (nth 2 schema))
                    (memq key jetpacs-lint-node-common-keys))
          (funcall report path
                   (format "warning: unknown key `%s' on %s" key type)))))))

(defun jetpacs-lint--walk (node path report)
  "Walk NODE at PATH (reversed key list), reporting problems via REPORT."
  (when (assq 't node)
    (let ((type (alist-get 't node)))
      (if (not (and (stringp type) (member type jetpacs-lint-node-types)))
          (funcall report path (format "unknown or invalid node type: %S" type))
        (jetpacs-lint--check-schema node type path report))))
  (dolist (pair node)
    (let* ((key (car pair)) (val (cdr pair)) (kpath (cons key path)))
      (cond
       ((eq key 't) nil)
       ((memq key jetpacs-lint--action-keys)
        (jetpacs-lint--check-action val kpath report))
       ;; An editor's data-driven toolbar: vocabulary checks per item, then
       ;; the generic walk for actions and scalar serializability.
       ((and (eq key 'toolbar) (jetpacs-lint--node-seq-p val))
        (let ((i 0))
          (dolist (item (append val nil))
            (jetpacs-lint--check-toolbar-item item (cons i kpath) report)
            (jetpacs-lint--walk item (cons i kpath) report)
            (setq i (1+ i)))))
       ((jetpacs-lint--node-seq-p val)
        (let ((i 0))
          (dolist (child (append val nil))
            (jetpacs-lint--walk child (cons i kpath) report)
            (setq i (1+ i)))))
       ((jetpacs-lint--alist-p val)
        (jetpacs-lint--walk val kpath report))
       ((memq key jetpacs-lint--numeric-attrs)
        (unless (numberp val)
          (funcall report kpath (format "%s must be a number: %S" key val))))
       ((memq key jetpacs-lint--color-attrs)
        (jetpacs-lint--check-color key val kpath report))
       (t (jetpacs-lint--check-scalar key val kpath report))))))

;;;###autoload
(defun jetpacs-lint-spec (spec)
  "Return a list of (PATH . PROBLEM) describing problems in SPEC, nil if clean.
PATH is the root-to-node list of keys (and child indices) locating the
problem; PROBLEM is a human-readable string.  A Tier 1 runs this in its
own ERT tests to keep its views wire-valid without a companion attached."
  (let (problems)
    (if (not (jetpacs-lint--alist-p spec))
        (push (cons nil (format "spec is not a node object: %S" spec)) problems)
      (jetpacs-lint--walk
       spec nil
       (lambda (path msg) (push (cons (reverse path) msg) problems))))
    (nreverse problems)))

;;;###autoload
(defun jetpacs-lint-payload (kind payload)
  "Return a list of (PATH . PROBLEM) for a frame's KIND and PAYLOAD alist.
nil = clean.  The frame-kind half of the schema registry: KIND must be
registered in `jetpacs-lint-kind-schema', PAYLOAD must carry the kind's
required keys (errors), and a key outside the schema is a \"warning: \"-
prefixed problem.  A kind whose payload is a §9 node tree
\(`dialog.show') is validated with `jetpacs-lint-spec'.  PAYLOAD nil
means an empty payload."
  (let* ((entry (assoc kind jetpacs-lint-kind-schema))
         problems
         (report (lambda (path msg) (push (cons path msg) problems))))
    (cond
     ((not entry)
      (funcall report nil (format "unknown frame kind: %S" kind)))
     ((eq (nth 2 entry) 'node)
      (setq problems (reverse (jetpacs-lint-spec payload))))
     ((and payload (not (jetpacs-lint--alist-p payload)))
      (funcall report nil (format "payload must be an object: %S" payload)))
     (t
      (dolist (req (nth 2 entry))
        (unless (assq req payload)
          (funcall report (list req)
                   (format "%s: missing required `%s'" kind req))))
      (dolist (pair payload)
        (let ((key (car pair)))
          (unless (or (memq key (nth 2 entry)) (memq key (nth 3 entry)))
            (funcall report (list key)
                     (format "warning: unknown payload key `%s' on %s"
                             key kind)))))))
    (nreverse problems)))

;; ─── Headless render harness ─────────────────────────────────────────────────

;;;###autoload
(defun jetpacs-render-to-json (spec &optional object-type)
  "Serialize SPEC to JSON and parse it back — the wire round-trip, headless.
Returns the parsed structure (OBJECT-TYPE defaults to `alist'), which is
exactly what the companion receives, so a Tier 1 can assert on its views
in batch with no phone.  Signals the same error a live push would if SPEC
is not serializable."
  (json-parse-string
   (json-serialize spec :null-object :null :false-object :false)
   :object-type (or object-type 'alist)
   :null-object :null :false-object :false))

;; ─── On-push guard (opt-in) ──────────────────────────────────────────────────

(defcustom jetpacs-lint-on-push nil
  "When non-nil, validate every surface spec before it is sent.
Invalid nodes are replaced in place by a visible error node, so one bad
subtree degrades to a message instead of a blank or dropped push.  Off by
default: it walks the whole tree on every push, needless once a Tier 1 is
known-good.  A development and test aid."
  :type 'boolean :group 'jetpacs)

(defun jetpacs-lint--error-node (msg)
  "An inline error node carrying MSG (an `empty_state')."
  (jetpacs--node "empty_state" 'icon "error" 'title "Invalid UI" 'caption msg))

(defun jetpacs-lint--node-serializable-p (node)
  "Non-nil when NODE's own scalar attributes are JSON-serializable.
Container and action values are validated by recursion, not here."
  (cl-every
   (lambda (pair)
     (let ((key (car pair)) (val (cdr pair)))
       (or (memq key jetpacs-lint--action-keys)
           (jetpacs-lint--node-seq-p val)
           (jetpacs-lint--alist-p val)
           (jetpacs-lint--serializable-scalar-p val))))
   node))

(defun jetpacs-lint-sanitize-spec (node)
  "Return NODE with each structurally-invalid descendant replaced by an error node.
An unknown `t' or a node with a non-serializable own attribute becomes an
`empty_state' error node; valid containers are recursed so only the bad
subtree is lost."
  (cond
   ((not (jetpacs-lint--alist-p node)) node)
   ((let ((ty (and (assq 't node) (alist-get 't node))))
      (and ty (not (and (stringp ty) (member ty jetpacs-lint-node-types)))))
    (jetpacs-lint--error-node (format "unknown node type: %s" (alist-get 't node))))
   ((not (jetpacs-lint--node-serializable-p node))
    (jetpacs-lint--error-node "node has an invalid attribute value"))
   (t
    (mapcar
     (lambda (pair)
       (let ((key (car pair)) (val (cdr pair)))
         (cond
          ((memq key jetpacs-lint--action-keys) pair)
          ((jetpacs-lint--node-seq-p val)
           (cons key (if (vectorp val)
                         (vconcat (mapcar #'jetpacs-lint-sanitize-spec (append val nil)))
                       (mapcar #'jetpacs-lint-sanitize-spec val))))
          ((jetpacs-lint--alist-p val)
           (cons key (jetpacs-lint-sanitize-spec val)))
          (t pair))))
     node))))

;; ─── Declarative view-spec validation ───────────────────────────────────────

(defun jetpacs-lint--plist-keys (plist)
  "The keys of PLIST, in order."
  (let (ks) (while (cdr plist) (push (car plist) ks) (setq plist (cddr plist)))
       (nreverse ks)))

(defun jetpacs-lint--walk-template (node fields path report)
  "Walk template NODE, reporting placeholders that bind outside FIELDS,
unknown transforms, and malformed embedded actions.  PATH is the reversed
key list; REPORT is called with (PATH MESSAGE)."
  (cond
   ((not (jetpacs-lint--alist-p node))
    (when (vectorp node)
      (let ((i 0)) (dolist (x (append node nil))
                     (jetpacs-lint--walk-template x fields (cons i path) report)
                     (setq i (1+ i))))))
   ((assq 'bind node)                   ; a placeholder
    (let ((f (alist-get 'bind node)) (as (alist-get 'as node)))
      (unless (and (stringp f) (member f fields))
        (funcall report path (format "placeholder binds unknown field: %S" f)))
      (when (and as (not (member as jetpacs-lint-spec-transforms)))
        (funcall report path (format "unknown transform: %S" as)))))
   ((or (assq 'action node) (assq 'builtin node))   ; an embedded action
    (jetpacs-lint--check-action node path report)
    (when-let ((args (cdr (assq 'args node))))
      (jetpacs-lint--walk-template args fields (cons 'args path) report)))
   (t                                   ; an ordinary node: walk its attrs
    (dolist (pair node)
      (unless (memq (car pair) '(t args))
        (jetpacs-lint--walk-template (cdr pair) fields (cons (car pair) path) report))))))

;;;###autoload
(defun jetpacs-lint-view-spec (spec fields)
  "Return a list of (PATH . PROBLEM) for declarative view SPEC, nil if clean.
FIELDS is the field-name strings the bound source declares (from
`jetpacs-source-fields'); every `((bind . F))' must name one.  Proves the spec
is closed data referencing only registered fields, transforms, and actions —
the SPEC §5 enforcement point for the binding grammar."
  (let* (problems
         (report (lambda (path msg) (push (cons (reverse path) msg) problems))))
    (if (not (and (listp spec) (plistp spec)))
        (funcall report nil (format "spec is not a plist: %S" spec))
      (let ((ks (jetpacs-lint--plist-keys spec)))
        (dolist (k ks)
          (unless (memq k jetpacs-lint-spec-keys)
            (funcall report (list k) (format "unknown spec key: %s" k))))
        (unless (memq :source ks) (funcall report nil "spec has no :source"))
        (unless (memq :template ks) (funcall report nil "spec has no :template")))
      (unless (stringp (plist-get spec :source))
        (funcall report (list :source) "must be a string"))
      (let ((layout (plist-get spec :layout)))
        (when (and layout (not (member layout jetpacs-lint-spec-layouts)))
          (funcall report (list :layout) (format "unknown layout: %S" layout))))
      (let ((kind (plist-get (plist-get spec :chrome) :kind)))
        (when (and kind (not (member kind jetpacs-lint-spec-chrome-kinds)))
          (funcall report (list :chrome) (format "unknown chrome kind: %S" kind))))
      (let ((gbf (plist-get (plist-get spec :group-by) :field)))
        (when (and gbf (not (member gbf fields)))
          (funcall report (list :group-by) (format "group-by unknown field: %S" gbf))))
      (dolist (key '(:template :header))
        (when (plist-get spec key)
          (jetpacs-lint--walk-template (plist-get spec key) fields (list key) report))))
    (nreverse problems)))

(provide 'jetpacs-lint)
;;; jetpacs-lint.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-surfaces.el
;;; ==================================================================

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
  ns (gen 0) owner)

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
  "Clear FORM's field state and subscriptions and rotate its generation.
The rotation empties the on-device widgets."
  (let ((prefix (concat (jetpacs-form-ns form) "-")))
    (jetpacs-ui-state-clear prefix)
    (jetpacs-on-state-change-clear prefix))
  (cl-incf (jetpacs-form-gen form)))

(defun jetpacs-form-dispose (form)
  "Reset FORM and drop it from the registry."
  (jetpacs-form-reset form)
  (remhash (jetpacs--form-key (jetpacs-form-ns form) (jetpacs-form-owner form))
           jetpacs--forms))

(defun jetpacs--forms-of-owner (owner)
  "The registered forms owned by OWNER."
  (let (forms)
    (maphash (lambda (_k form) (when (equal (jetpacs-form-owner form) owner)
                                 (push form forms)))
             jetpacs--forms)
    forms))

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
;;; ==================================================================
;;; BEGIN core/jetpacs-source.el
;;; ==================================================================

;;; jetpacs-source.el --- named, owned, engine-agnostic data sources -*- lexical-binding: t; -*-

;; A *source* is a named producer of a list of item alists — the data half of
;; a declarative view (`:spec', jetpacs-spec.el).  Core knows no query engine:
;; an app registers a source with a `:query' thunk (the sole funcall, run
;; server-side, never serialized — §5-safe: the name is data, the function is
;; local) plus machine-readable `:params' and `:fields' metadata so an editor
;; can enumerate what a source takes and produces.
;;
;;   (jetpacs-defsource "glasspane.org"
;;     :params '((:name query :type "text" :required t))
;;     :fields '((:name "headline" :type "text") (:name "scheduled" :type "date")
;;               (:name "tags" :type "string-list") (:name "ref" :type "ref"))
;;     :query   (lambda (p) (glasspane-org-query
;;                           (glasspane-org-parse-query (alist-get 'query p))))
;;     :cache-key (lambda (_p) (glasspane-org--agenda-mtime)))
;;
;; Sources are OWNED (via `jetpacs-current-owner') exactly like actions/views,
;; so `jetpacs-app-unregister' tears them down.  They are UNCACHED by default;
;; supplying `:cache-key' memoises one result per (name, canonical-params,
;; freshness-token).  An error is never cached.

;;; Code:

(require 'cl-lib)
(require 'jetpacs-surfaces)             ; jetpacs--claim / --unclaim / --owned-names / current-owner

(defconst jetpacs-source-field-types
  '("text" "number" "boolean" "date" "string-list" "enum" "ref")
  "The closed, domain-neutral field/param types a source declares.
A source normalizes engine-specific data (Org timestamps, TODO keywords,
tags) into these before core sees it; an `enum' requires a `:values' vector.")

(defvar jetpacs--sources (make-hash-table :test 'equal)
  "Registry of source NAME -> plist (:params :fields :query :cache-key :owner).")

(defvar jetpacs--source-cache (make-hash-table :test 'equal)
  "Memo for sources that opt in via `:cache-key'.
Key is (NAME CANONICAL-PARAMS FRESHNESS-TOKEN); absent for uncached sources.")

;; ─── Schema validation ───────────────────────────────────────────────────────

(defun jetpacs-source--check-type (ctx type values)
  "Validate TYPE is a known field type (enum needs VALUES); CTX labels errors."
  (unless (member type jetpacs-source-field-types)
    (error "jetpacs source %s: unknown type %S (want one of %S)"
           ctx type jetpacs-source-field-types))
  (when (and (equal type "enum") (not (vectorp values)))
    (error "jetpacs source %s: enum type requires a :values vector" ctx)))

(defun jetpacs-source--validate-schema (name params fields)
  "Validate the :params and :fields metadata of source NAME."
  (dolist (p params)
    (jetpacs-source--check-type (format "%s param %s" name (plist-get p :name))
                                (plist-get p :type) (plist-get p :values)))
  (dolist (f fields)
    (jetpacs-source--check-type (format "%s field %s" name (plist-get f :name))
                                (plist-get f :type) (plist-get f :values))))

;; ─── Registration ────────────────────────────────────────────────────────────

(cl-defun jetpacs-defsource (name &key params fields query cache-key)
  "Register (or replace) data source NAME (a string).
PARAMS is a list of `(:name SYM :type TYPE :required BOOL [:values VEC])'
descriptors validated and canonicalized before each query.  FIELDS is the
list of `(:name STRING :type TYPE [:values VEC])' a `:spec' template may
bind.  QUERY is `(PARAMS-ALIST) -> (list item-alist...)', app-supplied and
never serialized.  CACHE-KEY, when non-nil, is `(PARAMS-ALIST) -> TOKEN'
enabling one memoised result per params + token.  Returns NAME."
  (jetpacs-source--validate-schema name params fields)
  (jetpacs--claim "source" name)
  (puthash name (list :params params :fields fields :query query
                      :cache-key cache-key :owner jetpacs-current-owner)
           jetpacs--sources)
  (jetpacs-source-invalidate name)      ; a re-registration must not serve stale rows
  name)

(defun jetpacs-source-remove (name)
  "Unregister source NAME, dropping its cache and ownership record."
  (remhash name jetpacs--sources)
  (jetpacs-source-invalidate name)
  (jetpacs--unclaim "source" name))

(defun jetpacs-source-p (name)
  "Non-nil when NAME is a registered source."
  (and (gethash name jetpacs--sources) t))

(defun jetpacs-source-fields (name)
  "The declared output fields of source NAME (a list of field plists)."
  (plist-get (gethash name jetpacs--sources) :fields))

;; ─── Query + cache ───────────────────────────────────────────────────────────

(defun jetpacs-source--canonical-params (src params)
  "Validate PARAMS against SRC's schema; return a canonical (name-sorted) alist.
A missing required param signals an error.  Only declared params survive, so
the cache key is stable regardless of the caller's alist order or extras."
  (let (out)
    (dolist (pspec (plist-get src :params))
      (let* ((pname (plist-get pspec :name))
             (cell (assq pname params)))
        (when (and (plist-get pspec :required) (null cell))
          (error "jetpacs source: missing required param `%s'" pname))
        (when cell (push (cons pname (cdr cell)) out))))
    (sort out (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))))

(defun jetpacs-source-query (name params)
  "Run source NAME with PARAMS (a symbol-keyed alist); return its item list.
Validates and canonicalizes PARAMS first.  Uncached unless the source
declared a `:cache-key', in which case the result is memoised per (name,
canonical-params, freshness-token).  A query that errors is never cached."
  (let* ((src (or (gethash name jetpacs--sources)
                  (error "No such jetpacs source: %s" name)))
         (canon (jetpacs-source--canonical-params src params))
         (ckfn (plist-get src :cache-key)))
    (if (null ckfn)
        (funcall (plist-get src :query) canon)
      (let* ((key (list name canon (funcall ckfn canon)))
             (hit (gethash key jetpacs--source-cache 'jetpacs--miss)))
        (if (not (eq hit 'jetpacs--miss))
            hit
          ;; puthash only after a successful call, so an error is never cached.
          (let ((result (funcall (plist-get src :query) canon)))
            (puthash key result jetpacs--source-cache)
            result))))))

(defun jetpacs-source-invalidate (&optional name)
  "Drop cached results for source NAME (all sources when NAME is nil)."
  (if (null name)
      (clrhash jetpacs--source-cache)
    (let (keys)
      (maphash (lambda (k _v) (when (equal (car k) name) (push k keys)))
               jetpacs--source-cache)
      (dolist (k keys) (remhash k jetpacs--source-cache)))))

;; ─── Enumeration (for editors / the composer) ────────────────────────────────

(defun jetpacs-source--param-json (p)
  "Serializable form of param descriptor P (symbol keys, per the wire convention)."
  (append (list (cons 'name (symbol-name (plist-get p :name)))
                (cons 'type (plist-get p :type))
                (cons 'required (if (plist-get p :required) t :false)))
          (when (plist-get p :values) (list (cons 'values (plist-get p :values))))))

(defun jetpacs-source--field-json (f)
  "Serializable form of field descriptor F (symbol keys)."
  (append (list (cons 'name (format "%s" (plist-get f :name)))
                (cons 'type (plist-get f :type)))
          (when (plist-get f :values) (list (cons 'values (plist-get f :values))))))

(defun jetpacs-source-catalog ()
  "A JSON-serializable inventory of registered sources — metadata only.
Each entry is (name, params, fields); the `:query' function is never
included.  Lets an editor enumerate available sources and their fields."
  (let (out)
    (maphash
     (lambda (name src)
       (push (list (cons 'name name)
                   (cons 'params (vconcat (mapcar #'jetpacs-source--param-json
                                                  (plist-get src :params))))
                   (cons 'fields (vconcat (mapcar #'jetpacs-source--field-json
                                                  (plist-get src :fields)))))
             out))
     jetpacs--sources)
    (nreverse out)))

(provide 'jetpacs-source)
;;; jetpacs-source.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-triggers.el
;;; ==================================================================

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
Keys: :type :params :policy :dedupe :throttle-s :on-fire :handler.")

(defconst jetpacs-triggers-supported-types
  '("time" "power" "battery.level" "screen" "headset" "airplane"
    "boot" "timezone.changed" "package" "network")
  "The SPEC §11 batch-1 trigger-type catalog.
The fallback when the welcome carries no `device.trigger_types' — a
newer companion reports its own catalog there and that report wins
(see `jetpacs-triggers--supported-p').  Mirrors TriggerHost.kt's
SUPPORTED_TYPES; extend both (and SPEC §11) together.")

(defun jetpacs-triggers--supported-p (type)
  "Non-nil when the companion can host trigger TYPE.
Prefers the session's `device.trigger_types' report; the static
batch-1 catalog covers companions that predate the field.  The point
is to skip a single too-new registration rather than push it and have
the companion reject the whole replace-set."
  (let ((reported (alist-get 'trigger_types
                             (alist-get 'device jetpacs--session))))
    (and (member type (or reported jetpacs-triggers-supported-types)) t)))

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

(cl-defun jetpacs-trigger-register (id &key type params policy dedupe
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
  (jetpacs--claim "trigger" id)
  (puthash id (list :type type :params params :policy policy
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
Exercises the exact dispatch path a device fire takes, minus the wire."
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
must cost itself, never the set."
  (let (specs)
    (maphash
     (lambda (id reg)
       (cond
        ((member id jetpacs-triggers-disabled))
        ((not (jetpacs-triggers--supported-p (plist-get reg :type)))
         (message "Jetpacs triggers: skipping %s — companion lacks type %s"
                  id (plist-get reg :type)))
        (t
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

;;; ==================================================================
;;; BEGIN core/jetpacs-device.el
;;; ==================================================================

;;; jetpacs-device.el --- Device effectors via capability.invoke -*- lexical-binding: t; -*-

;; The Emacs face of SPEC §10's capability catalog: one thin defun per
;; device capability, all funneling through `jetpacs-device--invoke'.  The
;; companion is the validator — these wrappers only shape plain-data
;; args; unknown or refused capabilities come back as typed errors
;; (`cap-unsupported' / `cap-permission' / `cap-failed') which the
;; default callback surfaces in *Messages*.
;;
;; Check `jetpacs-device-cap-p' / `jetpacs-device-can-p' (jetpacs.el) to degrade
;; gracefully in UI; from the REPL just call and read the echo area.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)

(defun jetpacs-device--invoke (cap args &optional callback)
  "Invoke device capability CAP with plain-data alist ARGS.
CALLBACK as in `jetpacs-capability-invoke'; when nil, failures surface
in *Messages* with their typed code."
  (jetpacs-capability-invoke
   cap args
   (or callback
       (lambda (ok payload)
         (unless ok
           (message "Jetpacs device %s: %s [%s]" cap
                    (alist-get 'detail payload)
                    (alist-get 'code payload)))))))

;; ─── Intents: the universal escape hatch ─────────────────────────────────────

(cl-defun jetpacs-device-intent (&key action data package class-name mime
                                   extras (mode "activity"))
  "Fire an Android Intent on the companion (SPEC §10 `intent.start').
ACTION is an intent action string; DATA a URI; PACKAGE / CLASS-NAME
target an explicit component; MIME sets the type; EXTRAS is an alist
of plain data (strings, numbers, booleans — pass :false for false).
MODE is \"activity\" (default), \"broadcast\", or \"service\".
Activity launches are best-effort while the companion is backgrounded.

Example, from the eval REPL:
  (jetpacs-device-intent :action \"android.intent.action.VIEW\"
                      :data \"https://example.com\")"
  (jetpacs-device--invoke
   "intent.start"
   (append (when action `((action . ,action)))
           (when data `((data . ,data)))
           (when package `((package . ,package)))
           (when class-name `((class_name . ,class-name)))
           (when mime `((mime . ,mime)))
           (when extras `((extras . ,extras)))
           `((mode . ,mode)))))

(defun jetpacs-device-app-launch (package)
  "Launch PACKAGE's main activity on the companion."
  (jetpacs-device--invoke "app.launch" `((package . ,package))))

(defun jetpacs-device-apps-list (callback)
  "Fetch the launchable apps and call CALLBACK with ((LABEL . PACKAGE) ...)."
  (jetpacs-device--invoke
   "apps.list" nil
   (lambda (ok payload)
     (if (not ok)
         (message "Jetpacs device apps.list: %s [%s]"
                  (alist-get 'detail payload) (alist-get 'code payload))
       (funcall callback
                (mapcar (lambda (app)
                          (cons (alist-get 'label app)
                                (alist-get 'package app)))
                        (alist-get 'apps (alist-get 'result payload))))))))

(defun jetpacs-device-launch-app ()
  "Pick an installed app in a companion dialog and launch it.
The picker renders on the phone: choosing there keeps Glasspane
foregrounded, which is what makes the activity launch legal — Android
silently drops launches requested while the app is backgrounded (the
reason a desktop `completing-read' picker can never work here)."
  (interactive)
  (jetpacs-device-apps-list
   (lambda (apps)
     (jetpacs-send-dialog
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-section-header "Launch app")
                   (mapcar (lambda (app)
                             (jetpacs-button (car app)
                                          (jetpacs-action
                                           "device.launch"
                                           :args `((package . ,(cdr app)))
                                           :when-offline "drop")
                                          :variant "text"))
                           apps)))))))

(jetpacs-defaction "device.launch"
  (lambda (args _)
    (when-let ((pkg (alist-get 'package args)))
      (jetpacs-dismiss-dialog)
      (jetpacs-device-app-launch pkg))))

;; ─── Launcher shortcuts ──────────────────────────────────────────────────────

(defun jetpacs-device--icon-base64 (file)
  "Read image FILE (a PNG) and return its bytes base64-encoded."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (base64-encode-string (buffer-string) t)))

(defun jetpacs-device--shortcut-spec (id label action icon-file long-label)
  "The plain-data shortcut object `shortcut.pin' and `shortcuts.set' share."
  (append `((id . ,id)
            (label . ,label)
            (action . ,action))
          (when icon-file
            `((icon_png . ,(jetpacs-device--icon-base64 icon-file))))
          (when long-label `((long_label . ,long-label)))))

(cl-defun jetpacs-device-shortcut-pin (id label action &key icon-file long-label)
  "Request a home-screen pinned shortcut — launcher identity for an app.
ID names the shortcut; re-pinning the same ID updates label, icon, and
action in place (how an app ships a logo refresh, no dialog).  LABEL is
the short name under the icon.  ACTION is a `jetpacs-action' descriptor
dispatched through the normal tap pipeline when the shortcut opens the
companion — point it at whatever pushes your app's root view.
ICON-FILE is a PNG the launcher masks to its adaptive-icon shape:
square and full-bleed, 432px or larger recommended (keep the logo
inside the middle ~66%); omitted, the companion's own icon is used.
Android asks the user to confirm a fresh pin, and overlays a small
badge of the companion's icon — that part is OS-enforced."
  (jetpacs-device--invoke
   "shortcut.pin"
   (jetpacs-device--shortcut-spec id label action icon-file long-label)))

(defun jetpacs-device-shortcuts-set (shortcuts)
  "Replace the companion icon's long-press (dynamic) shortcuts.
SHORTCUTS is a list of (ID LABEL ACTION [ICON-FILE [LONG-LABEL]])
entries — fields as in `jetpacs-device-shortcut-pin'.  The whole set is
replaced (`triggers.set' discipline); nil clears it.  Launchers cap the
count (typically four visible), and a set over the max is refused
outright rather than truncated."
  (jetpacs-device--invoke
   "shortcuts.set"
   `((shortcuts
      . ,(vconcat
          (mapcar (lambda (s)
                    (cl-destructuring-bind
                        (id label action &optional icon-file long-label) s
                      (jetpacs-device--shortcut-spec
                       id label action icon-file long-label)))
                  shortcuts))))))

;; ─── Reminders (owner-scoped exact alarms) ───────────────────────────────────

(defvar jetpacs-reminders--warned nil
  "Owners already warned that this companion can't scope reminders per app.")

(defun jetpacs-reminders--warn-unscoped (owner)
  "Warn once per OWNER that reminders can't be armed without clobbering others."
  (unless (member owner jetpacs-reminders--warned)
    (push owner jetpacs-reminders--warned)
    (display-warning
     'jetpacs
     (format "%s: this Jetpacs companion can't scope reminders per app (no \
`reminders.owner' capability) and another app is registered — arming nothing \
rather than erasing another app's alarms.  Update the companion to arm these."
             (or owner "core"))
     :warning)))

(defun jetpacs-reminders-owner-set (reminders &optional owner)
  "Arm REMINDERS as exact alarms scoped to OWNER, replacing only OWNER's set.
REMINDERS is a sequence of reminder objects (each an alist/plist carrying the
wire keys `id', `at_ms', `title', `body').  The set REPLACES this owner's
previously-armed reminders and leaves alarms belonging to OTHER apps
untouched — the safety a bare global `reminders.set' cannot promise.  OWNER
defaults to `jetpacs-current-owner' (the app whose `with-jetpacs-owner' or
`jetpacs-defapp' is active); a nil owner is the unowned/core set.

Negotiates with the companion:
 - granted `reminders.owner' -> send the owner-scoped set;
 - else, only ONE app registered -> a plain global `reminders.set' is safe
   (there is nothing else to clobber);
 - else (owner-unaware companion, a second app present) -> refuse: warn once
   and arm nothing rather than erase another app's alarms.
Returns non-nil when a set was sent."
  (let ((owner (or owner jetpacs-current-owner))
        (vec (vconcat reminders)))
    (cond
     ((jetpacs-granted-p "reminders.owner")
      (jetpacs-send "reminders.set"
                    `((owner . ,(or owner "")) (reminders . ,vec)))
      t)
     ((not (and (fboundp 'jetpacs-apps--multi-p) (jetpacs-apps--multi-p)))
      (jetpacs-send "reminders.set" `((reminders . ,vec)))
      t)
     (t
      (jetpacs-reminders--warn-unscoped owner)
      nil))))

;; ─── Permission-free effectors ───────────────────────────────────────────────

(defun jetpacs-device-vibrate (&optional ms pattern)
  "Vibrate for MS milliseconds (default 200), or by PATTERN.
PATTERN is a list of durations (off, on, off, on, … ms) and wins over MS."
  (jetpacs-device--invoke
   "vibrate"
   (if pattern
       `((pattern . ,(vconcat pattern)))
     `((ms . ,(or ms 200))))))

(cl-defun jetpacs-device-tts (text &key pitch rate)
  "Speak TEXT on the companion. PITCH and RATE are floats around 1.0.
Best-effort and asynchronous: the engine lazy-inits on first use."
  (jetpacs-device--invoke
   "tts.speak"
   (append `((text . ,text))
           (when pitch `((pitch . ,pitch)))
           (when rate `((rate . ,rate))))))

(defun jetpacs-device-volume-set (stream level)
  "Set STREAM volume to LEVEL (0..max, clamped device-side).
STREAM is music, ring, alarm, notification, call, or system."
  (jetpacs-device--invoke "volume.set" `((stream . ,stream) (level . ,level))))

(defun jetpacs-device-ringer-mode (mode)
  "Set the ringer MODE: \"normal\", \"vibrate\", or \"silent\".
Silent needs Do Not Disturb access — a cap-permission error carries
the settings deep-link to grant it."
  (jetpacs-device--invoke "ringer.mode" `((mode . ,mode))))

(defun jetpacs-device-flashlight (on)
  "Switch the torch ON (non-nil) or off."
  (jetpacs-device--invoke "flashlight" `((on . ,(if on t :false)))))

(defun jetpacs-device-media-key (key)
  "Send media KEY: play_pause, play, pause, next, previous, stop,
fast_forward, or rewind."
  (jetpacs-device--invoke "media.key" `((key . ,key))))

(defun jetpacs-device-clipboard-read (callback)
  "Read the companion clipboard and call CALLBACK with its text, or nil.
Android 10+ exposes the clipboard only while the companion is
foregrounded; elsewhere this yields nil (a cap-permission error).
Never log or persist what arrives here."
  (jetpacs-device--invoke
   "clipboard.read" nil
   (lambda (ok payload)
     (funcall callback
              (and ok (alist-get 'text (alist-get 'result payload)))))))

(defun jetpacs-device-settings-open (panel)
  "Open the companion's settings PANEL.
PANEL is wifi, internet, bluetooth, volume, nfc, or any
android.settings.* action string — the compliant \"toggle\" for
radios Android won't let apps flip."
  (jetpacs-device--invoke "settings.open" `((panel . ,panel))))

(defun jetpacs-device-keep-screen-on (on)
  "Keep the companion screen on while Jetpacs UI is showing (ON non-nil).
A window flag, not a wakelock: it clears when Jetpacs UI leaves the
screen, so it cannot pin the device awake in the background."
  (jetpacs-device--invoke "screen.keep_on" `((on . ,(if on t :false)))))

;; ─── Special-access effectors ────────────────────────────────────────────────

(defun jetpacs-device-brightness (level)
  "Set screen brightness LEVEL (0–255).
Needs the modify-system-settings grant; a cap-permission error carries
the deep-link (or use the Device permissions screen)."
  (jetpacs-device--invoke "brightness.set" `((level . ,level))))

(defun jetpacs-device-dnd (mode)
  "Set Do Not Disturb MODE: \"on\", \"off\", or \"priority\".
Needs Do Not Disturb access — see the Device permissions screen."
  (jetpacs-device--invoke "dnd.set" `((mode . ,mode))))

;; ─── The Device permissions screen ───────────────────────────────────────────

(defconst jetpacs-device--perm-info
  '((post_notifications "Notifications" "app")
    (exact_alarms "Exact alarms (reminders, time triggers)"
                  "android.settings.REQUEST_SCHEDULE_EXACT_ALARM")
    (write_settings "Modify system settings (brightness)"
                    "android.settings.action.MANAGE_WRITE_SETTINGS")
    (notification_policy "Do Not Disturb access (ringer, DND, volume)"
                         "android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS")
    ;; No grant link yet: the app appears in that system list only once
    ;; the notification-listener service ships (automation plan Task 9).
    (notification_listener "Notification access (feature not shipped yet)" nil)
    (fine_location "Location (Wi-Fi SSID triggers)" "app")
    (bluetooth_connect "Nearby devices (Bluetooth triggers)" "app"))
  "PERM-KEY LABEL PANEL rows for the Device permissions dialog.
PANEL feeds `settings.open': a grant screen action, or \"app\" for
Glasspane's own app-info page (runtime permissions live there).")

(defun jetpacs-device--perm-row (key label panel perms)
  (let ((granted (eq t (alist-get key perms))))
    (apply #'jetpacs-row
           (delq nil
                 (list
                  (jetpacs-box
                   (list (jetpacs-column
                          (jetpacs-text label 'body)
                          (jetpacs-text (if granted "Granted" "Not granted")
                                     'caption)))
                   :weight 1)
                  (when (and panel (not granted))
                    (jetpacs-button "Grant"
                                 (jetpacs-action "device.perm.open"
                                              :args `((panel . ,panel))
                                              :when-offline "drop")
                                 :variant "text")))))))

(defun jetpacs-device-permissions-dialog ()
  "Show the device-permission map with grant deep-links.
Android never pops a dialog for special-access permissions — the only
compliant flow is deep-linking the user to the grant screen.  The map
refreshes on the next reconnect after granting."
  (interactive)
  (let ((perms (alist-get 'perms (alist-get 'device jetpacs--session))))
    (jetpacs-send-dialog
     (apply #'jetpacs-lazy-column
            (append
             (list (jetpacs-section-header "Device permissions")
                   (jetpacs-text (concat "Special access needs a trip to system "
                                      "settings; the list refreshes on the "
                                      "next reconnect.")
                              'caption))
             (mapcar (lambda (row)
                       (apply #'jetpacs-device--perm-row
                              (append row (list perms))))
                     jetpacs-device--perm-info))))))

(jetpacs-defaction "device.perms"
  (lambda (_args _) (jetpacs-device-permissions-dialog)))

(jetpacs-defaction "device.perm.open"
  (lambda (args _)
    (when-let ((panel (alist-get 'panel args)))
      (jetpacs-dismiss-dialog)
      (jetpacs-device-settings-open panel))))

;; Entry point: native Jetpacs settings. The builtin is intentionally
;; local so permissions and Android configuration remain reachable offline.
(with-eval-after-load 'jetpacs-settings
  (jetpacs-settings-add-native-link
   0 (lambda ()
        (jetpacs-card
         (list (jetpacs-row
                (jetpacs-icon "settings")
                (jetpacs-box (list (jetpacs-column
                                 (jetpacs-text "Open Jetpacs settings" 'label)
                                 (jetpacs-text "Android access, notifications, offline data, pairing"
                                            'caption)))
                          :weight 1)
                (jetpacs-icon "chevron_right")))
         :on-tap (jetpacs-native-settings-action)))))

(provide 'jetpacs-device)
;;; jetpacs-device.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-minibuffer.el
;;; ==================================================================

;;; jetpacs-minibuffer.el --- Bridge minibuffer prompts to the companion -*- lexical-binding: t; -*-

;; When an Jetpacs action handler calls a prompting function (y-or-n-p,
;; read-from-minibuffer, completing-read, …) the user is on their phone,
;; not at a keyboard.  This module intercepts those calls, sends the prompt
;; to the companion as a dialog, and synchronously waits for the reply —
;; exactly as the original function would block for keyboard input, just
;; over the bridge instead.
;;
;; The advice is active ONLY while `jetpacs--in-action-handler' is non-nil,
;; so normal Emacs usage at the keyboard is completely unaffected.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'cl-lib)

;; ─── Configuration ───────────────────────────────────────────────────────────

(defcustom jetpacs-prompt-timeout 60
  "Seconds to wait for the companion to answer a forwarded prompt.
After this the prompt is cancelled (as if the user dismissed the dialog)."
  :type 'integer :group 'jetpacs)

;; ─── Internal state ──────────────────────────────────────────────────────────

;; Owned by jetpacs-surfaces.el (read it via `jetpacs-in-action-p'); declared
;; here so a standalone byte-compile of this file stays warning-clean.
(defvar jetpacs--in-action-handler)

(defvar jetpacs--prompt-reply nil
  "Alist of prompt-id → reply value, filled by the `prompt.reply' action.")

(defvar jetpacs--prompt-cancelled nil
  "Alist of prompt-id → t, set when the companion dismisses the dialog.")

(defvar jetpacs-minibuffer--context-buffers nil
  "List of buffer names displayed during the current action handler.")

(defun jetpacs-minibuffer--record-context-buffer (buffer-or-name)
  "Record BUFFER-OR-NAME as a context buffer if in an action handler."
  (when jetpacs--in-action-handler
    (let ((buf (get-buffer buffer-or-name)))
      (when (and buf (string-prefix-p "*" (buffer-name buf)))
        (cl-pushnew (buffer-name buf) jetpacs-minibuffer--context-buffers :test #'equal)))))

(defun jetpacs-minibuffer--display-buffer-advice (orig-fn buffer-or-name &rest args)
  (jetpacs-minibuffer--record-context-buffer buffer-or-name)
  (apply orig-fn buffer-or-name args))

(advice-add 'display-buffer :around #'jetpacs-minibuffer--display-buffer-advice)

(defun jetpacs-minibuffer--temp-buffer-show-hook ()
  (jetpacs-minibuffer--record-context-buffer (current-buffer)))

(add-hook 'temp-buffer-show-hook #'jetpacs-minibuffer--temp-buffer-show-hook)

(defun jetpacs-minibuffer--context-cards ()
  "Return a list of `jetpacs-card` widgets containing the text of recently displayed context buffers."
  (delq nil
        (mapcar (lambda (bname)
                  (let ((buf (get-buffer bname)))
                    (when buf
                      (jetpacs-card
                       (list (jetpacs-column
                              (jetpacs-text bname 'caption)
                              (jetpacs-text
                               (with-current-buffer buf
                                 (buffer-substring-no-properties (point-min) (min (point-max) (+ (point-min) 4000))))
                               'body nil nil t)))))))
                (reverse jetpacs-minibuffer--context-buffers))))

;; ─── Reply / dismiss handlers ────────────────────────────────────────────────

(defun jetpacs--prompt-reply-handler (args _payload)
  "Handle `prompt.reply' actions from the companion."
  (let ((id (alist-get 'prompt_id args))
        (value (alist-get 'value args)))
    (when id
      (push (cons id value) jetpacs--prompt-reply))))

(defun jetpacs--prompt-dismiss-handler (args _payload)
  "Handle `prompt.dismiss' actions — user dismissed without answering."
  (let ((id (alist-get 'prompt_id args)))
    (when id
      (push (cons id t) jetpacs--prompt-cancelled))))

;; Register via the action dispatch table.  This file is loaded after
;; jetpacs-surfaces has provided itself, so `jetpacs-defaction' is available.
(jetpacs-defaction "prompt.reply"  #'jetpacs--prompt-reply-handler)
(jetpacs-defaction "prompt.dismiss" #'jetpacs--prompt-dismiss-handler)

;; ─── Core: send prompt, wait for reply ───────────────────────────────────────

(defvar jetpacs--prompt-counter 0)

(defun jetpacs--prompt-id ()
  "Generate a unique prompt id."
  (format "prompt-%d-%04x" (cl-incf jetpacs--prompt-counter) (random #x10000)))

(defun jetpacs--send-prompt-dialog (_prompt-id body)
  "Send BODY as a dialog, prepending any recorded context-buffer cards.
A BODY that is itself a `lazy_column' (the completing-read picker) gets
the cards merged into it: nesting one vertical scroll container inside
another crashes the companion's Compose renderer."
  (let ((context-cards (jetpacs-minibuffer--context-cards)))
    (cond
     ((null context-cards)
      (jetpacs-send-dialog body))
     ((equal (alist-get 't body) "lazy_column")
      (jetpacs-send-dialog
       `((t . "lazy_column")
         (children . ,(vconcat context-cards
                               (append (alist-get 'children body) nil))))))
     (t
      (jetpacs-send-dialog
       (apply #'jetpacs-lazy-column (append context-cards (list body))))))))

(defun jetpacs--wait-for-prompt (prompt-id)
  "Block (pumping the event loop) until PROMPT-ID gets a reply or times out.
Returns the reply value, or the symbol `cancelled' if dismissed/timed out."
  (let ((deadline (+ (float-time) jetpacs-prompt-timeout)))
    (while (and (not (assoc prompt-id jetpacs--prompt-reply))
                (not (assoc prompt-id jetpacs--prompt-cancelled))
                (< (float-time) deadline)
                ;; Stay alive only as long as the connection is up.
                (jetpacs-connected-p))
      (accept-process-output nil 0.1))
    (cond
     ((assoc prompt-id jetpacs--prompt-reply)
      (let ((value (alist-get prompt-id jetpacs--prompt-reply nil nil #'equal)))
        ;; Clean up.
        (setq jetpacs--prompt-reply
              (assoc-delete-all prompt-id jetpacs--prompt-reply))
        value))
     (t
      ;; Dismissed, timed out, or disconnected.
      (setq jetpacs--prompt-cancelled
            (assoc-delete-all prompt-id jetpacs--prompt-cancelled))
      'cancelled))))

(defun jetpacs--cleanup-prompt ()
  "Dismiss any leftover dialog after an action handler finishes."
  (jetpacs-dismiss-dialog)
  (setq jetpacs-minibuffer--context-buffers nil))

;; ─── Advice: y-or-n-p ────────────────────────────────────────────────────────

(defun jetpacs--y-or-n-p-advice (orig-fn prompt &rest args)
  "Around advice for `y-or-n-p'.  Intercept during action handlers."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    (let* ((id (jetpacs--prompt-id))
           (dialog-body
            (jetpacs-column
             (jetpacs-text (string-trim-right prompt "[ ?]+") 'title)
             (jetpacs-row
              (jetpacs-button "No"
                           (jetpacs-action "prompt.reply"
                                        :args `((prompt_id . ,id) (value . :false)))
                           :variant "outlined")
              (jetpacs-spacer :width 8)
              (jetpacs-button "Yes"
                           (jetpacs-action "prompt.reply"
                                        :args `((prompt_id . ,id) (value . t))))))))
      (jetpacs--send-prompt-dialog id dialog-body)
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (jetpacs--cleanup-prompt))))
        (not (or (eq reply 'cancelled)
                 (eq reply :false)
                 (eq reply nil)))))))

(advice-add 'y-or-n-p :around #'jetpacs--y-or-n-p-advice)

;; ─── Advice: yes-or-no-p ────────────────────────────────────────────────────

(defun jetpacs--yes-or-no-p-advice (orig-fn prompt &rest args)
  "Around advice for `yes-or-no-p'.  Same as y-or-n-p for the companion."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    ;; Reuse the y-or-n-p bridge — the distinction doesn't matter on a phone.
    (jetpacs--y-or-n-p-advice #'ignore prompt)))

(advice-add 'yes-or-no-p :around #'jetpacs--yes-or-no-p-advice)

;; ─── Advice: map-y-or-n-p ────────────────────────────────────────────────────
;;
;; `map-y-or-n-p' drives `save-some-buffers' and other batch confirmations.
;; It reads raw events via `read-event', which never arrive over the bridge —
;; so from the phone it HANGS forever (no dialog is ever shown, so the prompt
;; timeout can't even fire).  This is the freeze `magit-commit' hits: it runs
;; save-some-buffers before opening the message buffer.  We reimplement the
;; loop as one bridged dialog per object instead of feeding it events.

(defun jetpacs--map-y-or-n-p-advice (orig-fn prompter actor list &rest args)
  "Around advice for `map-y-or-n-p': one bridged dialog per object.
Returns the number of objects ACTOR was called on, matching the original.
LIST may be a list of objects or a generator function; PROMPTER may be a
format string or a function returning a string (ask), t (act silently)
or nil (skip silently)."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompter actor list args)
    (let* ((count 0)
           (all nil)              ; non-nil once "Yes to all" is chosen
           (done nil)             ; non-nil once "Quit"/dismiss stops the loop
           (next (if (functionp list)
                     list
                   (let ((remaining list))
                     (lambda () (when remaining (pop remaining))))))
           obj)
      (while (and (not done) (setq obj (funcall next)))
        (let ((p (cond ((functionp prompter) (funcall prompter obj))
                       ((stringp prompter) (format prompter obj))
                       (t (format "%s? " obj)))))
          (cond
           ;; PROMPTER contract (subr.el): a string asks; any other non-nil
           ;; value acts without asking; nil skips without asking.
           ((and p (not (stringp p)))
            (funcall actor obj) (setq count (1+ count)))
           ((null p) nil)
           ;; A prior "Yes to all" acts on every remaining object silently.
           (all (funcall actor obj) (setq count (1+ count)))
           (t
            (let* ((id (jetpacs--prompt-id))
                   (title (if (stringp p) (string-trim-right p "[ ?]+")
                            (format "%s" p)))
                   (body (jetpacs-column
                          (jetpacs-text title 'title)
                          (jetpacs-flow-row
                           (jetpacs-button
                            "Yes"
                            (jetpacs-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "y"))))
                           (jetpacs-button
                            "No"
                            (jetpacs-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "n")))
                            :variant "outlined")
                           (jetpacs-button
                            "Yes to all"
                            (jetpacs-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "all")))
                            :variant "outlined")
                           (jetpacs-button
                            "Quit"
                            (jetpacs-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "quit")))
                            :variant "text")))))
              (jetpacs--send-prompt-dialog id body)
              ;; `_' catches "quit", the `cancelled' symbol (dismiss/timeout),
              ;; and anything unexpected — all stop the loop.
              (pcase (unwind-protect (jetpacs--wait-for-prompt id)
                       (jetpacs--cleanup-prompt))
                ("y" (funcall actor obj) (setq count (1+ count)))
                ("n" nil)
                ("all" (setq all t) (funcall actor obj) (setq count (1+ count)))
                (_ (setq done t))))))))
      count)))

(advice-add 'map-y-or-n-p :around #'jetpacs--map-y-or-n-p-advice)

;; ─── Advice: read-from-minibuffer ────────────────────────────────────────────

(defun jetpacs--read-from-minibuffer-advice (orig-fn prompt &rest args)
  "Around advice for `read-from-minibuffer'.  Text-input dialog."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    (let* ((id (jetpacs--prompt-id))
           (initial (nth 0 args))  ;; initial-contents
           (input-id (format "prompt-input-%s" id))
           (current-value (if (stringp initial) initial ""))
           (dialog-body
            (jetpacs-column
             (jetpacs-text (string-trim-right prompt "[ :]+") 'title)
             (jetpacs-text-input input-id
                              :label "Input"
                              :value (if (stringp initial) initial nil)
                              :on-submit (jetpacs-action "prompt.reply"
                                                      :args `((prompt_id . ,id))))
             (jetpacs-row
              (jetpacs-button "Cancel"
                           (jetpacs-action "prompt.dismiss"
                                        :args `((prompt_id . ,id)))
                           :variant "text")
              (jetpacs-spacer :width 8)
              (jetpacs-button "OK"
                           (jetpacs-action "prompt.reply"
                                        :args `((prompt_id . ,id))))))))
      (jetpacs-on-state-change input-id (lambda (val) (setq current-value val)))
      (jetpacs--send-prompt-dialog id dialog-body)
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (remhash input-id jetpacs--state-handlers)
                     (jetpacs--cleanup-prompt))))
        (if (eq reply 'cancelled)
            (keyboard-quit)
          (or reply current-value ""))))))

(advice-add 'read-from-minibuffer :around #'jetpacs--read-from-minibuffer-advice)

;; ─── Advice: read-string ─────────────────────────────────────────────────────
;;
;; `read-string' delegates to `read-from-minibuffer' in standard Emacs, so
;; the advice above already covers it.  We add an explicit advice anyway so
;; the interception is guaranteed even if a package replaces `read-string'.

(defun jetpacs--read-string-advice (orig-fn prompt &rest args)
  "Around advice for `read-string'."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    (let ((initial (nth 0 args)))
      (jetpacs--read-from-minibuffer-advice #'ignore prompt initial))))

(advice-add 'read-string :around #'jetpacs--read-string-advice)

;; ─── Advice: read-passwd ─────────────────────────────────────────────────────
;;
;; `read-passwd' (TRAMP, GPG, auth-source) must NOT flow through the plaintext
;; `read-string' bridge: it needs a masked field, and the secret must not
;; linger in UI state.  We also intercept before the raw-event advice below,
;; since stock `read-passwd' reads keys directly.

(defun jetpacs--read-passwd-once (prompt)
  "Prompt for one masked secret over the bridge.
Returns the entered string, or the symbol `cancelled' on dismiss/timeout."
  (let* ((id (jetpacs--prompt-id))
         (input-id (format "prompt-pw-%s" id))
         (current ""))
    (jetpacs-on-state-change input-id (lambda (v) (setq current (or v ""))))
    ;; NOT `jetpacs--send-prompt-dialog': that prepends context-buffer cards, and
    ;; a passphrase prompt must never sit beside buffer contents.
    (jetpacs-send-dialog
     (jetpacs-column
      (jetpacs-text (string-trim-right prompt "[ :]+") 'title)
      (jetpacs-text-input input-id
                       :label "Password"
                       :single-line t
                       :password t
                       :on-submit (jetpacs-action "prompt.reply"
                                               :args `((prompt_id . ,id))))
      (jetpacs-row
       (jetpacs-button "Cancel"
                    (jetpacs-action "prompt.dismiss" :args `((prompt_id . ,id)))
                    :variant "text")
       (jetpacs-spacer :width 8)
       (jetpacs-button "OK"
                    (jetpacs-action "prompt.reply" :args `((prompt_id . ,id)))))))
    (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                   ;; Scrub every trace of the secret from handler state.
                   (remhash input-id jetpacs--state-handlers)
                   (remhash input-id jetpacs--ui-state)
                   (jetpacs--cleanup-prompt))))
      (if (eq reply 'cancelled) 'cancelled (or reply current "")))))

(defun jetpacs--read-passwd-advice (orig-fn prompt &rest args)
  "Around advice for `read-passwd': masked entry, secret never retained.
Honours CONFIRM (ARGS' first element) by prompting twice and comparing,
retrying up to three times before giving up with `keyboard-quit'."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    (let ((confirm (nth 0 args))
          (tries 0))
      (catch 'done
        (while t
          (let ((first (jetpacs--read-passwd-once prompt)))
            (when (eq first 'cancelled) (keyboard-quit))
            (if (not confirm)
                (throw 'done first)
              (let ((again (jetpacs--read-passwd-once
                            (if (stringp confirm) confirm "Confirm password: "))))
                (when (eq again 'cancelled) (keyboard-quit))
                (cond
                 ((equal first again) (throw 'done first))
                 ((>= (setq tries (1+ tries)) 3)
                  (jetpacs-send "toast.show" '((text . "Passwords didn't match")))
                  (keyboard-quit))
                 (t (jetpacs-send "toast.show"
                               '((text . "Passwords didn't match — try again")))))))))))))

(advice-add 'read-passwd :around #'jetpacs--read-passwd-advice)

;; ─── Advice: completing-read ─────────────────────────────────────────────────

(defun jetpacs-minibuffer--filter (candidates query)
  "Return CANDIDATES matching QUERY.
Every whitespace-separated token in QUERY must appear (case-insensitive
substring, orderless-style); candidates that QUERY is a prefix of are
sorted first."
  (if (or (null query) (string-empty-p query))
      candidates
    (let* ((tokens (split-string (downcase query) "[ \t]+" t))
           (matches (cl-remove-if-not
                     (lambda (c)
                       (let ((lc (downcase c)))
                         (cl-every (lambda (tok) (string-search tok lc)) tokens)))
                     candidates)))
      (cl-stable-sort
       matches
       (lambda (a b)
         (and (string-prefix-p query a t)
              (not (string-prefix-p query b t))))))))

(defun jetpacs-minibuffer--annotator (collection predicate)
  "An annotation function for COLLECTION's candidates, or nil.
Honours completion metadata and `completion-extra-properties', so
marginalia-style captions survive the bridge."
  (let* ((md (ignore-errors (completion-metadata "" collection predicate)))
         (annotf (or (and md (completion-metadata-get md 'annotation-function))
                     (plist-get completion-extra-properties
                                :annotation-function))))
    (when annotf
      (lambda (cand)
        (let ((a (ignore-errors (funcall annotf cand))))
          (when (stringp a)
            (let ((s (string-trim (substring-no-properties a))))
              (unless (string-empty-p s) s))))))))

(defun jetpacs-minibuffer--clean (s)
  "Trim S to a plain display string, or \"\" when nil/blank.
For suffixes, which are shown as a separate caption."
  (if (stringp s) (string-trim (substring-no-properties s)) ""))

(defun jetpacs-minibuffer--strip (s)
  "S without text properties, or \"\" when not a string.
For affixation PREFIXES, which are concatenated onto the candidate — their
separator whitespace is intentional and must survive (unlike suffixes)."
  (if (stringp s) (substring-no-properties s) ""))

(defun jetpacs-minibuffer--group-fn (collection predicate)
  "COLLECTION's `group-function' from completion metadata, or nil."
  (let ((md (ignore-errors (completion-metadata "" collection predicate))))
    (and md (completion-metadata-get md 'group-function))))

(defun jetpacs-minibuffer--decorations (collection predicate shown)
  "A hash CAND→(PREFIX . SUFFIX) decorating SHOWN, or nil when undecorated.
Prefers `affixation-function' (M-x key hints, marginalia's aligned columns),
which is computed once over the whole SHOWN batch; falls back to
`annotation-function' for a suffix only."
  (let* ((md (ignore-errors (completion-metadata "" collection predicate)))
         (aff (or (and md (completion-metadata-get md 'affixation-function))
                  (plist-get completion-extra-properties :affixation-function)))
         (ann (or (and md (completion-metadata-get md 'annotation-function))
                  (plist-get completion-extra-properties :annotation-function)))
         (table (make-hash-table :test 'equal)))
    (cond
     (aff
      (dolist (tr (ignore-errors (funcall aff (copy-sequence shown))))
        ;; Each TR is (CANDIDATE PREFIX SUFFIX): PREFIX is concatenated onto
        ;; the label (keep its spacing), SUFFIX becomes a trimmed caption.
        (when (consp tr)
          (puthash (nth 0 tr)
                   (cons (jetpacs-minibuffer--strip (nth 1 tr))
                         (jetpacs-minibuffer--clean (nth 2 tr)))
                   table)))
      table)
     (ann
      (dolist (c shown)
        (let ((s (ignore-errors (funcall ann c))))
          (when (stringp s)
            (puthash c (cons "" (jetpacs-minibuffer--clean s)) table))))
      table)
     (t nil))))

(defun jetpacs-minibuffer--picker-cards (shown id value-prefix decor group-fn)
  "Candidate card nodes for SHOWN, with affixation and group-header nodes.
ID is the prompt id; VALUE-PREFIX is prepended to the reply value.  DECOR is
a hash CAND→(PREFIX . SUFFIX) or nil; GROUP-FN, when non-nil, groups the
candidates with `jetpacs-section-header' dividers whenever its title changes."
  (let (nodes (last-group nil))
    (dolist (c shown)
      (when group-fn
        (let ((g (ignore-errors (funcall group-fn c nil))))
          (when (and (stringp g) (not (equal g last-group)))
            (setq last-group g)
            (push (jetpacs-section-header g) nodes))))
      (let* ((pair (and decor (gethash c decor)))
             (pre (and pair (car pair)))
             (suf (and pair (cdr pair)))
             (label (if (and pre (not (string-empty-p pre))) (concat pre c) c)))
        (push (jetpacs-card
               (list (if (and suf (not (string-empty-p suf)))
                         (jetpacs-row
                          (jetpacs-box (list (jetpacs-text label 'body)) :weight 1)
                          (jetpacs-text suf 'caption))
                       (jetpacs-text label 'body)))
               :on-tap (jetpacs-action "prompt.reply"
                                    :args `((prompt_id . ,id)
                                            (value . ,(concat value-prefix c)))))
              nodes)))
    (nreverse nodes)))

(defun jetpacs--completing-read-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read': a live-filtering picker over the bridge.
As the user types in the filter field, the candidate list re-filters and
re-renders (vertico-style). Tapping a candidate, or pressing Done, replies.
Function collections (files, buffers, dynamic tables) re-complete against
the query each keystroke, so typing a path navigates directories."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (initial-arg (nth 2 args))   ; INITIAL-INPUT: STRING or (STRING . POS)
           ;; `read-file-name' passes its DIR here, so honouring it is what
           ;; makes a bridged file prompt open in the right directory.
           (initial (cond ((stringp initial-arg) initial-arg)
                          ((consp initial-arg) (car initial-arg))
                          (t "")))
           (def (nth 4 args))   ; (predicate require-match initial hist DEF …)
           (id (jetpacs--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           (dynamic (functionp collection))
           ;; Static collections snapshot once and get token filtering;
           ;; `all-completions' handles list/obarray/hash honouring PREDICATE.
           (candidates (unless dynamic
                         (ignore-errors
                           (sort (all-completions "" collection predicate)
                                 #'string<))))
           (group-fn (jetpacs-minibuffer--group-fn collection predicate))
           ;; (PREFIX . MATCHES) for QUERY.  PREFIX is the completion-
           ;; boundaries head (e.g. the directory part of a file name) that
           ;; rebuilds a full value from a returned candidate.
           (matches-for
            (lambda (query)
              (if dynamic
                  (let* ((q (or query ""))
                         (bounds (ignore-errors
                                   (completion-boundaries q collection
                                                          predicate "")))
                         (prefix (substring q 0 (or (car bounds) 0))))
                    (cons prefix
                          (ignore-errors
                            (sort (all-completions q collection predicate)
                                  #'string<))))
                (cons "" (jetpacs-minibuffer--filter candidates query)))))
           (max-display 50)
           (render
            (lambda (query &optional seed)
              (let* ((pm (funcall matches-for query))
                     (prefix (car pm))
                     (matches (cdr pm))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches))
                     ;; Decorations (affixation/annotation) are computed once
                     ;; over the shown batch; group headers come from the
                     ;; collection's group-function.
                     (decor (jetpacs-minibuffer--decorations
                             collection predicate shown))
                     (cards (jetpacs-minibuffer--picker-cards
                             shown id prefix decor group-fn)))
                ;; A lazy (scrollable) column: long candidate lists scroll
                ;; instead of pushing everything below off-screen.  Cancel
                ;; sits in the header row so it is reachable regardless of
                ;; list length or scroll position.
                (apply #'jetpacs-lazy-column
                       (append
                        (list
                         (jetpacs-row
                          (jetpacs-box (list (jetpacs-text title 'title)) :weight 1)
                          (jetpacs-button "Cancel"
                                       (jetpacs-action "prompt.dismiss"
                                                    :args `((prompt_id . ,id)))
                                       :variant "text"))
                         ;; :value only on the SEED (first) render, and only
                         ;; when there is initial input — after that the field
                         ;; is uncontrolled so re-renders never stomp the
                         ;; user's text/cursor (see the on-state-change below).
                         (jetpacs-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter…"
                                          :single-line t
                                          :value (and seed
                                                      (not (string-empty-p query))
                                                      query)
                                          :on-submit (jetpacs-action
                                                      "prompt.reply"
                                                      :args `((prompt_id . ,id))))
                         (jetpacs-text (if (> total max-display)
                                        (format "%d matches · top %d shown" total max-display)
                                      (format "%d matches" total))
                                    'caption))
                        cards))))))
      ;; Re-render on every keystroke (runs during `jetpacs--wait-for-prompt's
      ;; event pump). Cleared after the wait so it can't leak.
      (jetpacs-on-state-change input-id
                            (lambda (val)
                              (jetpacs--send-prompt-dialog id (funcall render val))))
      ;; Seed the first render with INITIAL-INPUT: the field carries it as its
      ;; value, so an immediate submit returns it (like RET on initial input at
      ;; the keyboard) and the list is pre-filtered.  Clearing the field then
      ;; submitting is an explicit empty → DEF, so the empty branch is left
      ;; untouched.
      (jetpacs--send-prompt-dialog id (funcall render initial t))
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (remhash input-id jetpacs--state-handlers)
                     (jetpacs--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         ;; A tapped candidate is exact; a typed query falls back to its top
         ;; match (RET-picks-top, like vertico) so partial input still works.
         ((and (stringp reply) (not (string-empty-p reply)))
          (cond
           (dynamic
            (if (ignore-errors (test-completion reply collection predicate))
                reply
              (let* ((pm (funcall matches-for reply))
                     (top (cadr pm)))
                (if top (concat (car pm) top) reply))))
           ((member reply candidates) reply)
           (t (or (car (jetpacs-minibuffer--filter candidates reply)) reply))))
         ;; Empty submit falls back to the caller's DEF, like RET at the
         ;; keyboard would.
         (t (or (and def (if (consp def) (car def) def)) "")))))))

(advice-add 'completing-read :around #'jetpacs--completing-read-advice)

;; ─── Advice: completing-read-multiple ────────────────────────────────────────
;;
;; CRM reads via `read-from-minibuffer' with a special keymap, so without
;; this it degrades to a bare comma-separated text input.  Bridge it as a
;; multi-select picker: tapping candidates toggles them, the filter's
;; submit adds free text (org tags), Done replies with the selection.

(defvar jetpacs--prompt-toggle-callbacks nil
  "Alist of prompt-id → callback for `prompt.toggle' actions.")

(jetpacs-defaction "prompt.toggle"
  (lambda (args _)
    (let* ((pid (alist-get 'prompt_id args))
           (fn (alist-get pid jetpacs--prompt-toggle-callbacks nil nil #'equal)))
      (when fn (funcall fn (alist-get 'value args))))))

(defun jetpacs--completing-read-multiple-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read-multiple': a multi-select picker."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (id (jetpacs--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           (candidates (ignore-errors
                         (sort (all-completions "" collection predicate)
                               #'string<)))
           (annotate (jetpacs-minibuffer--annotator collection predicate))
           (selected nil)
           (query "")
           (max-display 50)
           (render
            (lambda ()
              (let* ((matches (jetpacs-minibuffer--filter candidates query))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches)))
                (apply #'jetpacs-lazy-column
                       (append
                        (list
                         (jetpacs-row
                          (jetpacs-box (list (jetpacs-text title 'title)) :weight 1)
                          (jetpacs-button "Cancel"
                                       (jetpacs-action "prompt.dismiss"
                                                    :args `((prompt_id . ,id)))
                                       :variant "text")
                          (jetpacs-button (format "Done (%d)" (length selected))
                                       (jetpacs-action "prompt.reply"
                                                    :args `((prompt_id . ,id)
                                                            (value . ,(vconcat (reverse selected)))))))
                         (jetpacs-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter, submit to add"
                                          :single-line t
                                          :on-submit (jetpacs-action
                                                      "prompt.toggle"
                                                      :args `((prompt_id . ,id))))
                         (when selected
                           (apply #'jetpacs-flow-row
                                  (mapcar (lambda (s)
                                            (jetpacs-chip s :selected t
                                                       :on-tap (jetpacs-action
                                                                "prompt.toggle"
                                                                :args `((prompt_id . ,id)
                                                                        (value . ,s)))))
                                          (reverse selected))))
                         (jetpacs-text (format "%d matches" total) 'caption))
                        (mapcar
                         (lambda (c)
                           (let ((a (and annotate (funcall annotate c))))
                             (jetpacs-card
                              (list (if a
                                        (jetpacs-row
                                         (jetpacs-box (list (jetpacs-text c 'body))
                                                   :weight 1)
                                         (jetpacs-text a 'caption))
                                      (jetpacs-text c 'body)))
                              :on-tap (jetpacs-action "prompt.toggle"
                                                   :args `((prompt_id . ,id)
                                                           (value . ,c))))))
                         shown)))))))
      (setf (alist-get id jetpacs--prompt-toggle-callbacks nil nil #'equal)
            (lambda (val)
              (when (and (stringp val) (not (string-empty-p val)))
                (setq selected (if (member val selected)
                                   (delete val selected)
                                 (cons val selected)))
                (jetpacs--send-prompt-dialog id (funcall render)))))
      (jetpacs-on-state-change input-id
                            (lambda (val)
                              (setq query (or val ""))
                              (jetpacs--send-prompt-dialog id (funcall render))))
      (jetpacs--send-prompt-dialog id (funcall render))
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (remhash input-id jetpacs--state-handlers)
                     (setq jetpacs--prompt-toggle-callbacks
                           (assoc-delete-all id jetpacs--prompt-toggle-callbacks))
                     (jetpacs--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         (t (cl-remove-if-not #'stringp (append reply nil))))))))

(advice-add 'completing-read-multiple :around #'jetpacs--completing-read-multiple-advice)

;; ─── Advice: read-char & read-char-exclusive ─────────────────────────────────

(defun jetpacs--read-char-advice (orig-fn prompt &rest args)
  "Around advice for `read-char' and `read-char-exclusive'.
Uses a text input dialog and returns the first character."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    (let ((reply (jetpacs--read-from-minibuffer-advice #'ignore prompt)))
      (if (and (stringp reply) (> (length reply) 0))
          (aref reply 0)
        (keyboard-quit)))))

(advice-add 'read-char :around #'jetpacs--read-char-advice)
(advice-add 'read-char-exclusive :around #'jetpacs--read-char-advice)

;; ─── Advice: read-char-choice ────────────────────────────────────────────────

(defun jetpacs--char-buttons-dialog (id prompt buttons)
  "Show a dialog of PROMPT text plus BUTTONS, with a Cancel row."
  (jetpacs--send-prompt-dialog
   id
   (jetpacs-column
    (jetpacs-text prompt 'body)
    (apply #'jetpacs-flow-row buttons)
    (jetpacs-row
     (jetpacs-spacer :weight 1)
     (jetpacs-button "Cancel"
                  (jetpacs-action "prompt.dismiss" :args `((prompt_id . ,id)))
                  :variant "text")))))

(defun jetpacs--read-char-choice-advice (orig-fn prompt chars &rest args)
  "Around advice for `read-char-choice': each valid char is a button.
The prompt text usually explains the choices ([y]es [n]o …), so it is
shown in full above the buttons; only valid chars can come back."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt chars args)
    (let* ((id (jetpacs--prompt-id))
           (chars (append chars nil)))
      (jetpacs--char-buttons-dialog
       id prompt
       (mapcar (lambda (ch)
                 (jetpacs-button (char-to-string ch)
                              (jetpacs-action "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(char-to-string ch))))
                              :variant "outlined"))
               chars))
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (jetpacs--cleanup-prompt))))
        (if (and (stringp reply) (> (length reply) 0)
                 (memq (aref reply 0) chars))
            (aref reply 0)
          (keyboard-quit))))))

(advice-add 'read-char-choice :around #'jetpacs--read-char-choice-advice)

;; ─── Advice: read-multiple-choice ────────────────────────────────────────────

(defun jetpacs--read-multiple-choice-advice (orig-fn prompt choices &rest args)
  "Around advice for `read-multiple-choice'.
CHOICES are (CHAR NAME [DESC]); the names become buttons, and the full
chosen entry is returned as the original would."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt choices args)
    (let ((id (jetpacs--prompt-id)))
      (jetpacs--char-buttons-dialog
       id prompt
       (mapcar (lambda (choice)
                 (jetpacs-button (capitalize (cadr choice))
                              (jetpacs-action "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(char-to-string (car choice)))))
                              :variant "outlined"))
               choices))
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (jetpacs--cleanup-prompt))))
        (or (and (stringp reply) (> (length reply) 0)
                 (assq (aref reply 0) choices))
            (keyboard-quit))))))

(advice-add 'read-multiple-choice :around #'jetpacs--read-multiple-choice-advice)

;; ─── Advice: read-char-from-minibuffer ───────────────────────────────────────
;;
;; Modern core reads single-char answers here (it echoes in the minibuffer
;; and, unlike `read-char', accepts an allowlist).  Without this the fallback
;; would be a free-text box; with a CHARS allowlist it becomes buttons.

(defun jetpacs--read-char-from-minibuffer-advice (orig-fn prompt &rest args)
  "Around advice for `read-char-from-minibuffer'.
With a CHARS allowlist (ARGS' first element) render each as a button via
the char-choice bridge; otherwise a single-char text prompt."
  (if (not jetpacs--in-action-handler)
      (apply orig-fn prompt args)
    (let ((chars (nth 0 args)))
      (if chars
          (jetpacs--read-char-choice-advice #'ignore prompt chars)
        (jetpacs--read-char-advice #'ignore prompt)))))

(when (fboundp 'read-char-from-minibuffer)
  (advice-add 'read-char-from-minibuffer :around
              #'jetpacs--read-char-from-minibuffer-advice))

;; ─── Advice: read-answer ─────────────────────────────────────────────────────
;;
;; `read-answer' backs the long-form "y, n, or q" prompts an increasing share
;; of core uses.  ANSWERS is (LONG-ANSWER CHAR HELP …); render a button per
;; entry and return the chosen LONG-ANSWER string (the function's contract).

(defun jetpacs--read-answer-advice (orig-fn question answers &rest _)
  "Around advice for `read-answer': one button per answer."
  (if (not jetpacs--in-action-handler)
      (funcall orig-fn question answers)
    (let ((id (jetpacs--prompt-id)))
      (jetpacs--char-buttons-dialog
       id question
       (mapcar (lambda (a)
                 (let ((long (car a)))
                   (jetpacs-button (capitalize long)
                                (jetpacs-action "prompt.reply"
                                             :args `((prompt_id . ,id)
                                                     (value . ,long)))
                                :variant "outlined")))
               answers))
      (let ((reply (unwind-protect (jetpacs--wait-for-prompt id)
                     (jetpacs--cleanup-prompt))))
        (if (and (stringp reply) (assoc reply answers))
            reply
          (keyboard-quit))))))

(when (fboundp 'read-answer)
  (advice-add 'read-answer :around #'jetpacs--read-answer-advice))

;; ─── Advice: raw event readers ───────────────────────────────────────────────
;;
;; `read-event', `read-key', `read-key-sequence' and its -vector sibling read
;; keyboard events directly, bypassing every prompt bridge above.  From the
;; phone they HANG.  `query-replace' (via `perform-replace') and any command
;; that reads a single keystroke land here.  We can't render an arbitrary key
;; event as a dialog cleanly, so this is deliberately crude: turn the read
;; into an answerable text prompt (a key description like "y" or "C-c"), and
;; if it can't be answered, `keyboard-quit' rather than block forever.

(defun jetpacs--raw-event-should-bridge-p (&optional seconds)
  "Non-nil when a raw-event read should be bridged rather than run natively.
Bridges only inside an action handler, and never when events are already
available — a running keyboard macro (`jetpacs-keymap--execute-key' drives
commands through `execute-kbd-macro'), queued `unread-command-events', or a
timed read (SECONDS non-nil, i.e. `read-event' used as a sleep)."
  (and jetpacs--in-action-handler
       (not executing-kbd-macro)
       (not unread-command-events)
       (not seconds)))

(defun jetpacs--bridge-key-prompt (prompt)
  "Prompt the phone for a key description and return it parsed, or quit.
Returns the `kbd' result (a string or vector), or signals `quit' when the
reply is empty or unparseable."
  (let ((reply (jetpacs--read-from-minibuffer-advice
                #'ignore (or (and (stringp prompt) prompt)
                             "Key input expected: "))))
    (if (and (stringp reply) (not (string-empty-p reply)))
        (let ((keys (ignore-errors (kbd reply))))
          (if (and keys (> (length keys) 0)) keys (keyboard-quit)))
      (keyboard-quit))))

(defun jetpacs--read-event-advice (orig-fn &rest args)
  "Around advice for `read-event'/`read-key': bridge or degrade, never hang.
Returns the first event of the parsed key description."
  ;; read-event: (&optional PROMPT INHERIT-INPUT-METHOD SECONDS).
  ;; read-key:   (&optional PROMPT) — nth 2 is simply nil.
  (if (not (jetpacs--raw-event-should-bridge-p (nth 2 args)))
      (apply orig-fn args)
    (aref (jetpacs--bridge-key-prompt (nth 0 args)) 0)))

(advice-add 'read-event :around #'jetpacs--read-event-advice)
(advice-add 'read-key :around #'jetpacs--read-event-advice)

(defun jetpacs--read-key-sequence-advice (orig-fn &rest args)
  "Around advice for `read-key-sequence': return the parsed sequence."
  (if (not (jetpacs--raw-event-should-bridge-p))
      (apply orig-fn args)
    (jetpacs--bridge-key-prompt (or (nth 0 args) "Key sequence: "))))

(defun jetpacs--read-key-sequence-vector-advice (orig-fn &rest args)
  "Around advice for `read-key-sequence-vector': parsed sequence as a vector."
  (if (not (jetpacs--raw-event-should-bridge-p))
      (apply orig-fn args)
    (let ((keys (jetpacs--bridge-key-prompt (or (nth 0 args) "Key sequence: "))))
      (if (vectorp keys) keys (vconcat keys)))))

(advice-add 'read-key-sequence :around #'jetpacs--read-key-sequence-advice)
(advice-add 'read-key-sequence-vector :around #'jetpacs--read-key-sequence-vector-advice)

(provide 'jetpacs-minibuffer)
;;; jetpacs-minibuffer.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-buffer.el
;;; ==================================================================

;;; jetpacs-buffer.el --- Generic buffer renderer (Tier 0) -*- lexical-binding: t; -*-

;; Tier 0 of Jetpacs: render ANY Emacs buffer faithfully from its text plus its
;; text/overlay properties (face, display, invisible, keymap, button,
;; mouse-face), with interactive regions made tappable.  This is the universal
;; substrate — every major mode renders through here for free, no per-package
;; translator required.
;;
;; Per-mode "skins" (Tier 1, e.g. a hand-built org dashboard) are *opt-in*
;; overrides registered in `jetpacs-render-buffer-functions'.  Anything
;; unregistered falls through to the generic renderer below, so a new package
;; is usable on day one and only gets bespoke polish where it's worth it.
;;
;; Emacs stays the single source of truth for styling: this module resolves
;; faces to span attributes and ships them; the device only paints the spans
;; (it never re-fontifies).
;;
;; This file deliberately does NOT depend on any UI/host layer (no org-ui).
;; The only seam back to the host is `jetpacs-buffer-refresh-function', which the
;; host sets so a tap that mutates a buffer can re-push the showing surface.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)   ; jetpacs-defaction / jetpacs-action

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-buffer-max-lines 500
  "Maximum number of lines the generic renderer emits for a buffer.
Buffers longer than this are truncated (with a trailing note) so a huge
magit/log/compilation buffer can't produce an unbounded surface."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-buffer-monospace t
  "When non-nil, the generic renderer paints buffer text monospace.
Most Emacs buffers (dired, magit, tables, source) rely on column alignment,
so monospace is the faithful default.  Tier-1 skins may override per mode."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-buffer-emit-colors t
  "When non-nil, carry a face's foreground color into the rendered span.
Only colors that differ from the default face are emitted, so semantic color
\(diff add/remove, font-lock keywords, warnings) survives while ordinary body
text still uses the device theme's on-surface color."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-line-numbers nil
  "Line numbers in the generic buffer view and the phone editor.
nil shows none; `absolute' shows buffer line numbers; `relative' shows
distances from point (the current line shows its absolute number,
vim's hybrid style).  Configurable from the phone's Settings view."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Absolute" absolute)
                 (const :tag "Relative" relative))
  :group 'jetpacs)

(defconst jetpacs-buffer--line-number-color "#8A8A8A"
  "Dim gray for line-number spans; legible on light and dark themes.")

(defvar jetpacs-buffer-refresh-function nil
  "Function called with no args after an `jetpacs.buffer.act' mutates a buffer.
The host shell sets this to re-push whatever surface is showing the buffer.
Kept as a seam so this module never depends on a specific UI layer.")

(defvar jetpacs-buffer--default-fg-hex nil
  "Hex of the default face foreground, bound for the duration of a render.
Spans whose foreground matches this are emitted without a color so the
device theme owns ordinary text.")

(defvar jetpacs-buffer--default-bg-hex nil
  "Hex of the default face background, bound for the duration of a render.
Spans whose background matches this emit no `:bg', so ordinary text keeps
the device theme's surface color and only semantic backgrounds (diff
shading, hl-line, region, isearch) are carried over.")

;; ─── Face resolution ─────────────────────────────────────────────────────────

(defun jetpacs-buffer--color-hex (color)
  "Return COLOR (a name or hex string) as \"#RRGGBB\", or nil if unresolvable."
  (when (and (stringp color) (not (string-empty-p color)))
    (let ((vals (ignore-errors (color-values color))))
      (when vals
        (apply #'format "#%02X%02X%02X"
               (mapcar (lambda (v) (/ v 256)) vals))))))

(defun jetpacs-buffer--face-refs (face)
  "Normalize a FACE property value into an ordered list of face refs.
Each ref is a face symbol or an attribute plist; earlier refs take
precedence, matching Emacs's left-to-right face merging."
  (cond
   ((null face) nil)
   ((symbolp face) (list face))
   ((and (consp face) (keywordp (car face))) (list face)) ; a single plist
   ((consp face)
    (let (refs)
      (dolist (f face)
        (setq refs (append refs (jetpacs-buffer--face-refs f))))
      refs))
   (t nil)))

(defun jetpacs-buffer--ref-attr (ref attr)
  "Read ATTR from a single face REF (symbol or plist); nil if unspecified.
An anonymous plist that lacks ATTR but names an `:inherit' face resolves
ATTR through the inherited face(s), matching Emacs's own face merging (the
symbol branch already inherits via `face-attribute')."
  (let ((v (cond
            ((symbolp ref) (face-attribute ref attr nil t))
            ((listp ref)
             (if (plist-member ref attr)
                 (plist-get ref attr)
               (let ((inherit (plist-get ref :inherit)))
                 (and inherit
                      (jetpacs-buffer--attr (jetpacs-buffer--face-refs inherit) attr)))))
            (t nil))))
    (if (eq v 'unspecified) nil v)))

(defun jetpacs-buffer--attr (refs attr)
  "First specified value of ATTR across REFS, in priority order."
  (cl-some (lambda (r) (jetpacs-buffer--ref-attr r attr)) refs))

(defconst jetpacs-buffer--bold-weights
  '(bold semi-bold semibold extra-bold extrabold ultra-bold ultrabold heavy black)
  "Weight symbols treated as bold.")

(defun jetpacs-buffer--span-style (face)
  "Return a plist (:bold :italic :underline :strike :color :bg) for FACE.
COLOR/:bg are included only when they resolve and differ from the default
foreground/background, so ordinary text carries neither.  Returns nil for
an unstyled run."
  (condition-case nil
      (let* ((refs (jetpacs-buffer--face-refs face))
             (weight (jetpacs-buffer--attr refs :weight))
             (slant (jetpacs-buffer--attr refs :slant))
             (underline (jetpacs-buffer--attr refs :underline))
             (strike (jetpacs-buffer--attr refs :strike-through))
             (fg (and jetpacs-buffer-emit-colors
                      (jetpacs-buffer--attr refs :foreground)))
             (hex (and fg (jetpacs-buffer--color-hex fg)))
             (bg (and jetpacs-buffer-emit-colors
                      (jetpacs-buffer--attr refs :background)))
             (bghex (and bg (jetpacs-buffer--color-hex bg))))
        (append
         (when (memq weight jetpacs-buffer--bold-weights) '(:bold t))
         (when (memq slant '(italic oblique)) '(:italic t))
         (when underline '(:underline t))
         (when strike '(:strike t))
         (when (and hex (not (equal hex jetpacs-buffer--default-fg-hex)))
           (list :color hex))
         (when (and bghex (not (equal bghex jetpacs-buffer--default-bg-hex)))
           (list :bg bghex))))
    (error nil)))

;; ─── Interactivity ─────────────────────────────────────────────────────────

(defun jetpacs-buffer--widget-p (obj)
  "Non-nil if OBJ is a widget.el widget object.
Own predicate (rather than `widgetp') so detection needs no wid-edit;
when a buffer actually contains widgets, wid-edit is already loaded."
  (and (consp obj) (symbolp (car obj)) (get (car obj) 'widget-type)))

(defun jetpacs-buffer--widget-at (pos)
  "The widget.el widget at POS as (button . W) or (field . W), else nil.
The `button' property distinguishes pressables; `field' marks editable
value boxes (Customize).  Non-widget `field' values (comint, minibuffer)
don't count."
  (let ((b (get-char-property pos 'button)))
    (if (jetpacs-buffer--widget-p b)
        (cons 'button b)
      (let ((f (get-char-property pos 'field)))
        (and (jetpacs-buffer--widget-p f) (cons 'field f))))))

(defun jetpacs-buffer--actionable-p (pos)
  "Non-nil if the char at POS belongs to a tappable region.
True for text/widget buttons, widget editable fields, regions carrying a
`mouse-face', and regions with their own `keymap'/`local-map' (magit
sections, info refs, …).  The major-mode keymap is buffer-local, not a
text property, so this never marks the whole buffer tappable."
  (or (get-char-property pos 'button)
      (jetpacs-buffer--widget-p (get-char-property pos 'field))
      (get-char-property pos 'mouse-face)
      (keymapp (get-char-property pos 'keymap))
      (keymapp (get-char-property pos 'local-map))))

;; ─── Folding ───────────────────────────────────────────────────────────────
;;
;; Universal fold/unfold without any per-mode renderer.  Detection is generic:
;; a line is "expandable" when the text right after it is currently invisible
;; (which is how magit/org/outline/hideshow all hide a collapsed body).  The
;; action is generic too: run whatever command the buffer itself binds to TAB
;; at that heading — `org-cycle', `magit-section-toggle', the outline cycle,
;; etc. — i.e. exactly what the user would press in Emacs.  The allowlist below
;; keeps this from ever running a non-fold TAB (e.g. `indent-for-tab-command').

(defcustom jetpacs-buffer-fold-commands
  '(magit-section-toggle magit-section-cycle magit-section-cycle-global
    org-cycle org-fold-show-entry org-fold-hide-subtree
    outline-toggle-children outline-cycle outline-show-subtree
    outline-hide-subtree hs-toggle-hiding)
  "Commands treated as safe fold toggles for the generic fold affordance.
Only a command in this list will be invoked by `jetpacs.buffer.fold', so the
phone can never trigger an arbitrary command through the fold path."
  :type '(repeat function) :group 'jetpacs)

(defun jetpacs-buffer--invisible-at (pos)
  "Non-nil if the char at POS is currently folded away (invisible)."
  (let ((v (get-char-property pos 'invisible)))
    (and v (invisible-p v))))

(defun jetpacs-buffer--hidden-follows-p (eol limit)
  "Non-nil if a folded (invisible) region begins right after the line at EOL.
Bounded by LIMIT.  This is the generic \"this heading is collapsed\" signal.
Checks the end-of-line chars and the start of the next line, since modes
differ on whether the heading's newline or the body's first char carries the
`invisible' property."
  (or (and (< eol limit) (jetpacs-buffer--invisible-at eol))
      (and (< (1+ eol) limit) (jetpacs-buffer--invisible-at (1+ eol)))
      (save-excursion
        (goto-char (min eol (max (point-min) (1- limit))))
        (forward-line 1)
        (and (< (point) limit) (jetpacs-buffer--invisible-at (point))))))

(defun jetpacs-buffer--fold-span (pos buffer-name text)
  "A tappable affordance span that expands/collapses the fold at heading position POS."
  (jetpacs-span text
             :on-tap (jetpacs-action "jetpacs.buffer.fold"
                                  :args `((buffer . ,buffer-name) (pos . ,pos)))))

;; ─── Region → spans ─────────────────────────────────────────────────────────

(defun jetpacs-buffer--expand-tabs (text col)
  "Expand TABs in TEXT to spaces given the starting column COL.
Returns (EXPANDED-TEXT . END-COL).  Text with no TAB is returned as-is, so
the common line pays only a `string-search'.  Keeps column alignment
faithful (dired, tables, source) since the phone's tab stops differ."
  (if (not (string-search "\t" text))
      (cons text (+ col (length text)))
    (let ((c col) parts)
      (dolist (ch (append text nil))
        (if (eq ch ?\t)
            (let ((n (- tab-width (mod c tab-width))))
              (push (make-string n ?\s) parts)
              (setq c (+ c n)))
          (push (char-to-string ch) parts)
          (setq c (1+ c))))
      (cons (apply #'concat (nreverse parts)) c))))

(defun jetpacs-buffer--offscreen-display-p (disp)
  "Non-nil when display spec DISP renders outside the text area.
Fringe bitmaps (`(left-fringe …)' / `(right-fringe …)') and margin specs
\(`((margin …) …)') show in the fringe/margin, never in the text flow —
the text they cover is a placeholder (magit literally uses \"fringe\" and
\"o\") that must not be rendered.  Also recognises a list of specs whose
members include one."
  (and (consp disp)
       (or (memq (car-safe disp) '(left-fringe right-fringe))
           (eq (car-safe (car-safe disp)) 'margin)
           ;; A list of display specs: offscreen if any member is.
           (and (consp (car-safe disp))
                (cl-some #'jetpacs-buffer--offscreen-display-p disp)))))

(defun jetpacs-buffer--space-width (disp col)
  "Columns a `(space …)' display spec DISP occupies starting at column COL.
Handles `:width N' and `:align-to COL'; pixel/relative forms approximate
to a single space."
  (let ((plist (cdr disp)))
    (cond
     ((plist-member plist :width)
      (let ((w (plist-get plist :width)))
        (max 0 (if (numberp w) (round w) 1))))
     ((plist-member plist :align-to)
      (let ((to (plist-get plist :align-to)))
        (max 1 (- (if (numberp to) (round to) col) col))))
     (t 1))))

(defun jetpacs-buffer--string-spans (str col)
  "Render a propertized STR (an overlay before/after-string) into spans.
Returns (SPANS . END-COL); honors `face'/`font-lock-face', string `display'
overrides, and TAB expansion so injected virtual text matches the buffer.
Runs covered by an offscreen display spec (fringe bitmaps, margin dates —
magit's \"fringe\" and \"o\" placeholders) render nothing."
  (let ((i 0) (n (length str)) (c col) out)
    (while (< i n)
      (let* ((next (or (next-property-change i str) n))
             (disp (get-text-property i 'display str))
             (raw (cond
                   ((stringp disp) disp)
                   ((jetpacs-buffer--offscreen-display-p disp) nil)
                   ((and (consp disp) (eq (car disp) 'space))
                    (make-string (jetpacs-buffer--space-width disp c) ?\s))
                   (t (substring-no-properties str i next))))
             (face (or (get-text-property i 'face str)
                       (get-text-property i 'font-lock-face str)))
             (style (jetpacs-buffer--span-style face)))
        (when raw
          (let ((exp (jetpacs-buffer--expand-tabs raw c)))
            (setq c (cdr exp))
            (unless (string-empty-p (car exp))
              (push (apply #'jetpacs-span (car exp)
                           (append style (when jetpacs-buffer-monospace '(:mono t))))
                    out))))
        (setq i next)))
    (cons (nreverse out) c)))

(defun jetpacs-buffer--overlay-strings (bol eol)
  "Insertions ((POS TIE STRING) …) from overlay before/after-strings on a line.
`before-string' is placed at the overlay start, `after-string' at its end,
when those fall within [BOL, EOL].  Invisible overlays contribute nothing.
Sorted by position, before-strings ahead of after-strings at a tie.  These
are OVERLAY properties, not char properties, so the main span walk (which
uses `get-char-property') never sees them — this surfaces flymake inline
hints, diff-hl markers, and similar virtual text that would otherwise vanish."
  (let (ins)
    (dolist (ov (overlays-in bol (min (1+ eol) (point-max))))
      (let ((iv (overlay-get ov 'invisible)))
        (unless (and iv (invisible-p iv))
          (let ((bs (overlay-get ov 'before-string))
                (as (overlay-get ov 'after-string))
                (os (overlay-start ov))
                (oe (overlay-end ov)))
            (when (and (stringp bs) (>= os bol) (<= os eol))
              (push (list os 0 bs) ins))
            (when (and (stringp as) (>= oe bol) (<= oe eol))
              (push (list oe 1 as) ins))))))
    (sort ins (lambda (a b) (or (< (car a) (car b))
                                (and (= (car a) (car b))
                                     (< (nth 1 a) (nth 1 b))))))))

(defun jetpacs-buffer--line-spans (bol eol buffer-name)
  "Build the list of spans for the buffer text in [BOL, EOL).
Honors `invisible' (skips folded text), string and `(space …)' `display'
overrides, and overlay before/after-strings; expands TABs to `tab-width'
stops; maps `face'/`font-lock-face' to styling; and attaches a tap action
at the start of each actionable property run."
  (let ((pos bol) (col 0) spans
        (inserts (jetpacs-buffer--overlay-strings bol eol)))
    (cl-flet ((flush (upto)
                ;; Emit pending overlay-string insertions at or before UPTO,
                ;; splicing them into the run at the right column.
                (while (and inserts (<= (caar inserts) upto))
                  (let ((ss (jetpacs-buffer--string-spans (nth 2 (pop inserts)) col)))
                    (setq spans (nconc (nreverse (car ss)) spans)
                          col (cdr ss))))))
      (while (< pos eol)
        (flush pos)
        (let ((next (next-char-property-change pos eol)))
          (when (<= next pos) (setq next (1+ pos))) ; defensive: always advance
          (setq next (min next eol))
          (let ((invis (get-char-property pos 'invisible)))
            (unless (and invis (invisible-p invis))
              (let* ((disp (get-char-property pos 'display))
                     (face (or (get-char-property pos 'face)
                               (get-char-property pos 'font-lock-face)))
                     (style (jetpacs-buffer--span-style face))
                     (act (when (jetpacs-buffer--actionable-p pos)
                            (jetpacs-action "jetpacs.buffer.act"
                                         :args `((buffer . ,buffer-name)
                                                 (pos . ,pos)))))
                     text)
                (cond
                 ((stringp disp)
                  (setq text disp col (+ col (length disp))))
                 ;; Fringe/margin display: the covered text is a placeholder
                 ;; that never shows in the text flow — render nothing.
                 ((jetpacs-buffer--offscreen-display-p disp)
                  (setq text nil))
                 ((and (consp disp) (eq (car disp) 'space))
                  (let ((w (jetpacs-buffer--space-width disp col)))
                    (setq text (make-string w ?\s) col (+ col w))))
                 (t
                  (let ((exp (jetpacs-buffer--expand-tabs
                              (buffer-substring-no-properties pos next) col)))
                    (setq text (car exp) col (cdr exp)))))
                (when (and (stringp text) (not (string-empty-p text)))
                  (push (apply #'jetpacs-span text
                               (append style
                                       (when jetpacs-buffer-monospace '(:mono t))
                                       (when act (list :on-tap act))))
                        spans)))))
          (setq pos next)))
      ;; Trailing insertions at EOL (e.g. an after-string at end of line).
      (flush eol))
    (nreverse spans)))

(defun jetpacs-buffer--fold-state (bol eol limit)
  "Return 'folded, 'unfolded, or nil if not a foldable heading."
  (let ((magit-sec (get-char-property bol 'magit-section)))
    (cond
     (magit-sec
      (if (and (fboundp 'magit-section-hidden)
               (magit-section-hidden magit-sec))
          'folded
        'unfolded))
     ((and (bound-and-true-p outline-regexp)
           (save-excursion
             (goto-char bol)
             (looking-at outline-regexp)))
      (if (jetpacs-buffer--hidden-follows-p eol limit)
          'folded
        'unfolded))
     (t nil))))

(defun jetpacs-buffer--line-number-span (ln pt-line fmt)
  "A dim gutter span for line LN. PT-LINE is point's line, FMT the width format.
With `jetpacs-line-numbers' `relative', shows the distance from point —
except on point's own line, which shows its absolute number undimmed
\(vim's hybrid style)."
  (let ((current (and pt-line (= ln pt-line))))
    (jetpacs-span (format fmt (if (and (eq jetpacs-line-numbers 'relative)
                                    (not current))
                               (abs (- ln pt-line))
                             ln))
               :mono t
               :color (unless current jetpacs-buffer--line-number-color))))

(defun jetpacs-buffer--render-region (beg end buffer-name &optional mark-pos)
  "Return a list of `rich_text' nodes for [BEG, END) of the current buffer.
One node per line; blank lines keep their vertical space.  Capped at
`jetpacs-buffer-max-lines'.  When `jetpacs-line-numbers' is enabled each line
is prefixed with a dim gutter span carrying its (absolute or relative)
number — real buffer lines, so folded regions skip numbers faithfully.
MARK-POS, when non-nil, flags the line containing that position as the
enclosing lazy column's scroll target (see `jetpacs-scroll-here')."
  (let* ((jetpacs-buffer--default-fg-hex
          (jetpacs-buffer--color-hex (face-attribute 'default :foreground nil t)))
         (jetpacs-buffer--default-bg-hex
          (jetpacs-buffer--color-hex (face-attribute 'default :background nil t)))
         (pt-line (and jetpacs-line-numbers (line-number-at-pos (point))))
         (num-fmt (and jetpacs-line-numbers
                       (format "%%%dd " (length (number-to-string
                                                 (line-number-at-pos end))))))
         (ln (and jetpacs-line-numbers (line-number-at-pos beg)))
         (count 0)
         nodes)
    (ignore-errors (font-lock-ensure beg end))
    (save-excursion
      (goto-char beg)
      (while (and (< (point) end) (< count jetpacs-buffer-max-lines))
        (let* ((bol (line-beginning-position))
               (eol (min end (line-end-position))))
          (cond
           ;; A page break (^L alone on the line) renders as a divider rather
           ;; than a raw control glyph.
           ((and (< bol eol)
                 (save-excursion (goto-char bol) (looking-at "\f+$")))
            (push (jetpacs-divider) nodes)
            (setq count (1+ count)))
           (t
            (let ((spans (jetpacs-buffer--line-spans bol eol buffer-name)))
              ;; A fully-folded line (no visible spans, hidden at bol) is
              ;; dropped entirely so collapsed content truly disappears instead
              ;; of leaving a blank gap.  Visible lines render; a collapsed
              ;; heading gets a trailing ▸ affordance to expand it, unfolded ▾.
              (unless (and (null spans) (jetpacs-buffer--invisible-at bol))
                (pcase (jetpacs-buffer--fold-state bol eol end)
                  ('folded
                   (setq spans (append (or spans (list (jetpacs-span " ")))
                                       (list (jetpacs-buffer--fold-span bol buffer-name "  ▸")))))
                  ('unfolded
                   (setq spans (append (or spans (list (jetpacs-span " ")))
                                       (list (jetpacs-buffer--fold-span bol buffer-name "  ▾"))))))
                (setq spans (or spans (list (jetpacs-span " "))))
                ;; `line-prefix' (org-indent's virtual indentation, etc.) is a
                ;; text property, not part of the buffer text — prepend it as a
                ;; dim gutter span so the indentation survives.
                (let ((prefix (get-char-property bol 'line-prefix)))
                  (when (stringp prefix)
                    (setq spans (cons (jetpacs-span prefix :mono t
                                                 :color jetpacs-buffer--line-number-color)
                                      spans))))
                (when ln
                  (setq spans (cons (jetpacs-buffer--line-number-span ln pt-line num-fmt)
                                    spans)))
                (push (if (and mark-pos (>= mark-pos bol) (<= mark-pos eol))
                          (jetpacs-scroll-here (jetpacs-rich-text spans))
                        (jetpacs-rich-text spans))
                      nodes)
                (setq count (1+ count)))))))
        (when ln (setq ln (1+ ln)))
        (forward-line 1)))
    (nreverse nodes)))

;; ─── Public: generic renderer + dispatch registry ────────────────────────────

(defun jetpacs-buffer-render (&optional buffer)
  "Render BUFFER (default current) generically into a list of SDUI nodes.
Truncated to `jetpacs-buffer-max-lines'; a caption note is appended if cut."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((name (buffer-name buf))
             (total (count-lines (point-min) (point-max)))
             (nodes (jetpacs-buffer--render-region (point-min) (point-max) name)))
        (if (> total jetpacs-buffer-max-lines)
            (append nodes
                    (list (jetpacs-text
                           (format "… %d more line(s) (showing first %d)"
                                   (- total jetpacs-buffer-max-lines)
                                   jetpacs-buffer-max-lines)
                           'caption)))
          nodes)))))

(defun jetpacs-buffer-render-region (buffer beg end &optional mark-pos)
  "Render [BEG, END) of BUFFER generically into a list of SDUI nodes.
The public region variant of `jetpacs-buffer-render', for callers showing
a slice instead of the whole buffer (an imenu section, a hit context).
BEG and END are clamped to the buffer; the line cap still applies.
MARK-POS, when non-nil, flags its line as the scroll target."
  (let ((buf (get-buffer buffer)))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((beg (max (point-min) (min (or beg (point-min)) (point-max))))
             (end (max beg (min (or end (point-max)) (point-max)))))
        (jetpacs-buffer--render-region beg end (buffer-name buf) mark-pos)))))

(defun jetpacs-buffer-render-tail (buffer lines)
  "Render the last LINES lines of BUFFER into a list of SDUI nodes.
For transcript-shaped buffers (comint REPLs, logs) the interesting end
is the bottom — `jetpacs-buffer-render' caps from the top.  A leading
caption marks elided output."
  (let ((buf (get-buffer buffer)))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let ((beg (save-excursion
                   (goto-char (point-max))
                   (forward-line (- (max 1 lines)))
                   (point))))
        (append
         (when (> beg (point-min))
           (list (jetpacs-text (format "… %d earlier line(s) not shown"
                                    (count-lines (point-min) beg))
                            'caption)))
         (jetpacs-buffer--render-region beg (point-max) (buffer-name buf)))))))

(defvar jetpacs-render-buffer-functions nil
  "Alist of (MAJOR-MODE . FUNCTION) Tier-1 renderer skins.
FUNCTION takes the buffer and returns a list of SDUI nodes.  A mode with no
entry — including any mode derived from an unregistered one — falls through
to the generic `jetpacs-buffer-render'.  Derived modes match their nearest
registered ancestor; the first matching entry wins.")

(defun jetpacs-render-buffer-register (mode fn)
  "Register FN as the Tier-1 renderer skin for MODE (a major-mode symbol)."
  (setf (alist-get mode jetpacs-render-buffer-functions) fn))

(defun jetpacs-render-buffer (&optional buffer)
  "Render BUFFER via its registered skin, else the generic renderer.
Returns a list of SDUI nodes.  This is the single dispatch seam: Tier 1 is
purely additive on top of the Tier 0 substrate."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (with-current-buffer buf
      (let ((fn (seq-some (lambda (cell)
                            (and (derived-mode-p (car cell)) (cdr cell)))
                          jetpacs-render-buffer-functions)))
        (if fn (funcall fn buf) (jetpacs-buffer-render buf))))))

;; ─── Tap dispatch ─────────────────────────────────────────────────────────

(declare-function widget-apply-action "wid-edit" (widget &optional event))
(declare-function widget-field-value-get "wid-edit" (widget &optional no-truncate))
(declare-function widget-field-value-set "wid-edit" (widget value))

(defun jetpacs-buffer--widget-invoke (hit)
  "Activate widget HIT, a (button . W) or (field . W) pair.
Buttons run their :action (State menus, Toggle, checkboxes, links).
A field tap edits the field's raw text through a bridged prompt.
The wid-edit value primitives handle size padding and marker
bookkeeping, and the rewrite runs the same after-change hooks typing
would, so Customize notices the modification (state turns EDITED)."
  (pcase hit
    (`(button . ,w) (widget-apply-action w) t)
    (`(field . ,w)
     (let* ((old (widget-field-value-get w))
            (tag (or (widget-get w :tag) "Edit field"))
            (new (read-string (format "%s: " tag) old)))
       (unless (equal new old)
         (widget-field-value-set w new))
       t))))

(defun jetpacs-buffer-call-shimmed (cmd)
  "Run command CMD with window-display and input-event shims; return (BUF . POS).
The buffer-display functions are neutered so nothing pops a desktop window
and the user's Emacs layout is untouched (`save-window-excursion'), and the
triggering input event is cleared so event-driven goto commands
\(`compile-goto-error', the eww/Info/help follow commands) navigate to
point rather than to a stale pending event.  Returns the buffer made
current and the point reached after CMD runs; errors are swallowed and
report wherever point already is.  Call with the origin buffer current and
point already placed on the target."
  (let (dest-buf dest-pos)
    (save-window-excursion
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                ((symbol-function 'pop-to-buffer-same-window)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                ((symbol-function 'switch-to-buffer)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer)))
                ((symbol-function 'switch-to-buffer-other-window)
                 (lambda (b &rest _) (set-buffer (get-buffer b)) (current-buffer))))
        (condition-case nil
            (let ((last-input-event nil)
                  (last-nonmenu-event nil))
              (call-interactively cmd))
          (error nil))
        (setq dest-buf (current-buffer) dest-pos (point))))
    (cons dest-buf dest-pos)))

(defun jetpacs-buffer-invoke-at (buffer-name pos)
  "Run the tap action at POS in BUFFER-NAME and return non-nil if one fired.
Tries, in order: activate a widget.el widget, push a button, then the
region keymap's binding for RET / mouse-2 / mouse-1.  Runs with the buffer
current and point at POS; commands that only need point (buttons,
magit/dired/info visit) work, those that require a live window may not.
Called inside an action handler, so any minibuffer prompts it raises are
bridged to the companion automatically."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        ;; Clear the triggering input event before running the tap's command.
        ;; Link/visit commands reached through the keymap branch (eww/Info/help
        ;; RET, `compile-goto-error') read `last-input-event' and would jump to
        ;; a stale pending event instead of point; this tap is driven by POS.
        ;; Same guard as `jetpacs-buffer-call-shimmed'.
        (let ((last-input-event nil)
              (last-nonmenu-event nil))
          (cond
           ;; widget.el first: widgets store the widget object in the `button'
           ;; property, which fools button.el's `button-at' into returning a
           ;; bogus marker whose `push-button' then has no :action.
           ((jetpacs-buffer--widget-at (point))
            (jetpacs-buffer--widget-invoke (jetpacs-buffer--widget-at (point))))
           ((button-at (point)) (push-button) t)
           (t
            (let* ((km (or (get-char-property (point) 'keymap)
                           (get-char-property (point) 'local-map)))
                   (cmd (and (keymapp km)
                             (or (lookup-key km (kbd "RET"))
                                 (lookup-key km [return])
                                 (lookup-key km [mouse-2])
                                 (lookup-key km [mouse-1])))))
              (when (commandp cmd)
                (call-interactively cmd)
                t)))))))))

(jetpacs-defaction "jetpacs.buffer.act"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (jetpacs-buffer-invoke-at buffer pos))
      ;; Re-push the showing surface; the tap may have folded a section,
      ;; navigated, or mutated the buffer.
      (when (functionp jetpacs-buffer-refresh-function)
        (funcall jetpacs-buffer-refresh-function)))))

;; ─── Fold dispatch ────────────────────────────────────────────────────────

(defun jetpacs-buffer--run-fold-toggle ()
  "Run the current buffer's own fold toggle at point; non-nil if one ran.
Generic: prefer the command the buffer binds to TAB when it is a known fold
toggle (org-cycle, magit-section-toggle, the outline cycle, …); otherwise
pick the first `jetpacs-buffer-fold-commands' member actually bound in this
buffer.  Never runs a command outside that allowlist."
  (let ((tab (or (key-binding (kbd "TAB")) (key-binding (kbd "<tab>")))))
    (cond
     ((and (commandp tab) (memq tab jetpacs-buffer-fold-commands))
      (call-interactively tab) t)
     (t
      (let ((cmd (cl-find-if
                  (lambda (c)
                    (and (commandp c)
                         (where-is-internal c (current-active-maps))))
                  jetpacs-buffer-fold-commands)))
        (when cmd (call-interactively cmd) t))))))

(defun jetpacs-buffer-toggle-fold-at (buffer-name pos)
  "Toggle the fold at POS in BUFFER-NAME using the buffer's own fold command.
Point is placed on the heading first, so the mode's toggle acts on the right
section.  Runs inside an action handler, so any prompt is bridged."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        (jetpacs-buffer--run-fold-toggle)))))

(jetpacs-defaction "jetpacs.buffer.fold"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (jetpacs-buffer-toggle-fold-at buffer pos))
      (when (functionp jetpacs-buffer-refresh-function)
        (funcall jetpacs-buffer-refresh-function)))))

(provide 'jetpacs-buffer)
;;; jetpacs-buffer.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-shell.el
;;; ==================================================================

;;; jetpacs-shell.el --- Multi-view app shell for Jetpacs -*- lexical-binding: t; -*-

;; The app-agnostic host: a registry of named views pushed together as one
;; multi-view surface (`app:dashboard'), with companion-local tab switching
;; (the `view.switch' builtin), a snackbar queue, drawer/bottom-bar/top-bar
;; chrome helpers, and the refresh/navigation actions every view shares.
;;
;; Tier 1 apps do not build a shell — they register views into this one:
;;
;;   (jetpacs-shell-define-view "myapp.agenda"
;;     :builder #'my-agenda-view
;;     :tab '(:icon "event" :label "Agenda") :order 10)
;;
;; View names live in the app's namespace: name them "<appid>.<view>"
;; (or bare "<appid>" for a single-view app) and claim them with
;; `jetpacs-defapp'.  The registry replaces by name, so two apps using the
;; same bare name would silently hijack each other's screens — the
;; ownership registry warns when that happens (see `jetpacs--claim').
;;
;; A builder is a function of one argument (the snackbar text to attach, or
;; nil) returning a full scaffold view alist — use `jetpacs-shell-tab-view' /
;; `jetpacs-shell-nav-view' for the standard chrome.  Views registered with
;; :tab appear in the bottom bar and become the current tab when the user
;; lands on them; :when gates inclusion per push (e.g. an editor view that
;; only exists while a file is open); :overlay marks a view that, while its
;; predicate holds, is the active view without being a tab (e.g. a detail
;; drill-in).
;;
;; This module also owns the host ends of the core seams: it points the
;; Tier 0 buffer renderer's `jetpacs-buffer-refresh-function' at the shell
;; push, wires `jetpacs-settings' feedback to the snackbar, pushes on connect
;; and after an offline-queue drain, and handles the `view.switched',
;; `nav.tab', and `dashboard.refresh' wire actions.  Apps that need to run
;; on those moments register on the hooks below instead of redefining them.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)

;; ─── View registry ───────────────────────────────────────────────────────────

(defvar jetpacs-shell-views nil
  "Ordered list of (NAME . PLIST) registered shell views.
Managed by `jetpacs-shell-define-view'; kept sorted by :order.")

(declare-function jetpacs-spec--compile "jetpacs-spec")
;; Declarative :spec views are compiled by jetpacs-spec.el, which requires this
;; file; autoload avoids the load cycle (in the bundle the real function is
;; defined after this one, before any push occurs).
(autoload 'jetpacs-spec--compile "jetpacs-spec")

(cl-defun jetpacs-shell-define-view (name &key builder spec tab when overlay (order 100))
  "Register (or replace) shell view NAME.
BUILDER is a function of one argument (snackbar text or nil) returning
the view's scaffold alist.  SPEC is a declarative data-view plist compiled
by jetpacs-spec.el (see docs/BINDING.md) — an alternative to BUILDER;
exactly one of the two is required.  TAB, when non-nil, is a plist
\(:icon :label :badge) placing the view in the bottom bar; landing on a
tab view makes it the current tab.  :badge, when non-nil, is a nullary
function called on every push whose result overlays the tab icon — a
count (capped at 99+ on-device), \"\" for a bare dot, or nil for none;
errors and nil render no badge, so a badge can never break the push.
WHEN, when non-nil, is a predicate gating the view's inclusion in each
push.  OVERLAY, when non-nil, is a predicate: while it holds, this view
is the active one shown on a background push (a detail drill-in over
the current tab).  ORDER sorts views and bottom-bar items."
  (unless (or builder spec)
    (error "jetpacs-shell-define-view %s: needs :builder or :spec" name))
  (when (and builder spec)
    (error "jetpacs-shell-define-view %s: :builder and :spec are exclusive" name))
  (setq jetpacs-shell-views
        (sort (cons (cons name (list :builder builder :spec spec :tab tab :when when
                                     :overlay overlay :order order))
                    (assoc-delete-all name jetpacs-shell-views))
              (lambda (a b)
                (< (plist-get (cdr a) :order) (plist-get (cdr b) :order)))))
  (jetpacs--claim "view" name)
  (jetpacs-shell--schedule-repush)
  name)

(defun jetpacs-shell-remove-view (name)
  "Unregister shell view NAME."
  (setq jetpacs-shell-views (assoc-delete-all name jetpacs-shell-views))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-view-filter-function nil
  "When non-nil, a predicate on a view NAME gating inclusion per push.
The app layer (jetpacs-apps.el) installs the current-app filter here; nil
means every registered view shows — the single-app default.")

(defun jetpacs-shell--view-filtered-p (name)
  "Non-nil when NAME passes `jetpacs-shell-view-filter-function'.
A filter that signals passes the view — a broken app layer must not
blank the phone."
  (or (null jetpacs-shell-view-filter-function)
      (condition-case nil (funcall jetpacs-shell-view-filter-function name)
        (error t))))

(defun jetpacs-shell--visible-views ()
  "The registry entries included in this push (:when + app filter honoured).
A pred that signals counts as nil — a broken predicate must cost its
view, not the push."
  (cl-remove-if-not (lambda (entry)
                      (let ((pred (plist-get (cdr entry) :when)))
                        (and (jetpacs-shell--view-filtered-p (car entry))
                             (or (null pred)
                                 (condition-case nil (funcall pred)
                                   (error nil))))))
                    jetpacs-shell-views))

(defun jetpacs-shell--tab-p (name)
  "Non-nil when view NAME is registered as a bottom-bar tab."
  (plist-get (cdr (assoc name jetpacs-shell-views)) :tab))

(defun jetpacs-shell--overlay-p (name)
  "Non-nil when view NAME is registered as an overlay."
  (plist-get (cdr (assoc name jetpacs-shell-views)) :overlay))

;; ─── Shell state ─────────────────────────────────────────────────────────────

(defvar jetpacs-shell--current-tab nil
  "Name of the current bottom-bar tab, or nil for the first registered tab.")

(defvar jetpacs-shell--snackbar nil
  "Text queued by `jetpacs-shell-notify' for the next push, or nil.")

(defun jetpacs-shell-current-tab ()
  "The current tab name (the first included tab when none is set)."
  (or jetpacs-shell--current-tab
      (car (cl-find-if (lambda (e)
                         (and (plist-get (cdr e) :tab)
                              (jetpacs-shell--view-filtered-p (car e))))
                       jetpacs-shell-views))))

(defun jetpacs-shell-set-current-tab (name)
  "Switch to the registered bottom-bar tab NAME.
A NAME that is not a registered tab is rejected (returns nil and warns).
A valid switch routes through `jetpacs-shell-push' — running
`jetpacs-shell-view-switched-hook' and repushing — and returns NAME; it
never setqs the internal tab var directly."
  (if (jetpacs-shell--tab-p name)
      (progn (jetpacs-shell-push name) name)
    (message "Jetpacs: cannot switch to %S — not a registered tab" name)
    nil))

(defun jetpacs-shell--active-view ()
  "The view a push should land on: a firing overlay, else the current tab."
  (or (car (cl-find-if (lambda (e)
                         (let ((pred (plist-get (cdr e) :overlay)))
                           (and pred
                                (jetpacs-shell--view-filtered-p (car e))
                                (condition-case nil (funcall pred)
                                  (error nil)))))
                       jetpacs-shell-views))
      (jetpacs-shell-current-tab)))

(defun jetpacs-shell-notify (text)
  "Queue TEXT to show as a snackbar on the next shell push.
Note: the companion re-shows a snackbar only when the text *changes*,
so two identical messages back-to-back display once."
  (setq jetpacs-shell--snackbar text))

;; ─── Hooks (the app seams) ───────────────────────────────────────────────────

(defvar jetpacs-shell-view-switched-hook nil
  "Hook run with the view NAME the user is switching to.
Runs before the shell's own tab bookkeeping, for both companion-local
switches (`view.switched') and Emacs-driven tab pushes — but never for
overlay views.  Modules reset their drill-in state here.")

(defvar jetpacs-shell-refresh-hook nil
  "Hook run before a push that must bypass caches.
Runs on the explicit `dashboard.refresh' action and after an offline
queue drain; apps drop their memo caches here.")

(defvar jetpacs-shell-after-push-hook nil
  "Hook run after each successful shell push.
For cheap piggybacked sends (home-screen widgets, reminder syncs); keep
handlers memo-guarded so unchanged data sends nothing.")

;; ─── Chrome: drawer, bottom bar, top bar ─────────────────────────────────────

(defvar jetpacs-shell-drawer-header "Jetpacs"
  "Text rendered at the top of the app drawer.
When `jetpacs-shell-drawer-header-function' returns non-nil, that wins —
the apps layer uses it to show the current app's label once a second
app is registered.")

(defvar jetpacs-shell-drawer-header-function nil
  "When non-nil, a nullary function returning the drawer header, or nil
to fall back to `jetpacs-shell-drawer-header'.")

(defvar jetpacs-shell-chrome-filter-function nil
  "When non-nil, a predicate on an OWNER id gating chrome per push.
Applied to drawer items and default top-bar actions through the owner
recorded at registration time (`jetpacs-current-owner').  The apps layer
\(jetpacs-apps.el) installs the current-app filter here; nil means all
chrome shows — the single-app default.  A nil owner (core, or a
registration made outside `with-jetpacs-owner') always shows.")

(defun jetpacs-shell--chrome-visible-p (owner)
  "Non-nil when chrome registered by OWNER passes the app filter.
A filter that signals passes the item — a broken app layer must not
strip the drawer."
  (or (null owner)
      (null jetpacs-shell-chrome-filter-function)
      (condition-case nil (funcall jetpacs-shell-chrome-filter-function owner)
        (error t))))

(defvar jetpacs-shell-drawer-items nil
  "Ordered list of (ORDER BUILDER . OWNER) drawer entries.
BUILDER is a function of no arguments returning an `jetpacs-drawer-item';
OWNER is the `jetpacs-current-owner' captured at registration (nil =
core), consulted by `jetpacs-shell-chrome-filter-function'.")

(defun jetpacs-shell-add-drawer-item (order builder)
  "Add BUILDER (a nullary function returning a drawer item) at ORDER.
Registrations made under `with-jetpacs-owner' are attributed to that app
and shown only while it is current (once a second app exists)."
  (setq jetpacs-shell-drawer-items
        (sort (cons (cons order (cons builder jetpacs-current-owner))
                    jetpacs-shell-drawer-items)
              (lambda (a b) (< (car a) (car b)))))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-top-actions nil
  "Ordered list of (ORDER BUILDER . OWNER) default top-bar trailing actions.
BUILDER is a function of no arguments returning an icon-button node;
OWNER as in `jetpacs-shell-drawer-items'.")

(defun jetpacs-shell-add-top-action (order builder)
  "Add BUILDER (a nullary function returning an icon button) at ORDER.
Registrations made under `with-jetpacs-owner' are attributed to that app
and shown only while it is current (once a second app exists)."
  (setq jetpacs-shell-top-actions
        (sort (cons (cons order (cons builder jetpacs-current-owner))
                    jetpacs-shell-top-actions)
              (lambda (a b) (< (car a) (car b)))))
  (jetpacs-shell--schedule-repush))

(defun jetpacs-shell-remove-owned-chrome (owner)
  "Drop every drawer item and top action registered by OWNER."
  (setq jetpacs-shell-drawer-items
        (cl-remove-if (lambda (e) (equal (cddr e) owner))
                      jetpacs-shell-drawer-items)
        jetpacs-shell-top-actions
        (cl-remove-if (lambda (e) (equal (cddr e) owner))
                      jetpacs-shell-top-actions))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-default-fab-function nil
  "Function of a view name returning that view's default FAB node, or nil.
Apps set this to offer a global affordance (e.g. a capture button) on
views that don't define their own.")

(defun jetpacs-shell-default-fab (name)
  "The app-provided default FAB for view NAME, or nil."
  (when (functionp jetpacs-shell-default-fab-function)
    (funcall jetpacs-shell-default-fab-function name)))

(defun jetpacs-shell-switch-view (view)
  "Action descriptor for the companion-local `view.switch' builtin."
  `((builtin . "view.switch") (view . ,view)))

(defvar jetpacs-shell-view-resolver-function nil
  "When non-nil, a function from a logical view NAME to the concrete one.
The apps layer resolves core slots to per-app overrides — e.g.
\"settings\" becomes \"glasspane.settings\" while Glasspane is current
and has registered that view.  nil (or a resolver returning nil) keeps
the name as-is.")

(defun jetpacs-shell-resolve-view (name)
  "NAME through `jetpacs-shell-view-resolver-function', erring on NAME."
  (or (and jetpacs-shell-view-resolver-function
           (condition-case nil
               (funcall jetpacs-shell-view-resolver-function name)
             (error nil)))
      name))

(defun jetpacs-shell-drawer ()
  "The navigation drawer built from `jetpacs-shell-drawer-items'.
A builder returning nil contributes nothing — conditional entries
\(e.g. the multi-app \"Apps\" item) just return nil when hidden.
Entries registered under `with-jetpacs-owner' show only while their app
passes `jetpacs-shell-chrome-filter-function'."
  (jetpacs-drawer (delq nil (mapcar (lambda (e)
                                   (when (jetpacs-shell--chrome-visible-p (cddr e))
                                     (funcall (cadr e))))
                                 jetpacs-shell-drawer-items))
               :header (or (and jetpacs-shell-drawer-header-function
                                (condition-case nil
                                    (funcall jetpacs-shell-drawer-header-function)
                                  (error nil)))
                           jetpacs-shell-drawer-header)))

(defun jetpacs-shell-bottom-bar (selected)
  "The bottom bar of the included :tab views, with SELECTED highlighted.
Honours the app filter, so each app shows its own tabs."
  (jetpacs-bottom-bar
   (cl-loop for (name . plist) in jetpacs-shell-views
            for tab = (plist-get plist :tab)
            when (and tab (jetpacs-shell--view-filtered-p name))
            collect (jetpacs-nav-item (plist-get tab :icon)
                                   (plist-get tab :label)
                                   (jetpacs-shell-switch-view name)
                                   :selected (equal name selected)
                                   :badge (when-let ((fn (plist-get tab :badge)))
                                            (condition-case nil (funcall fn)
                                              (error nil)))))))

(cl-defun jetpacs-shell-default-top-bar (title &key extra-actions)
  "The standard top bar: TITLE plus the registered trailing actions.
EXTRA-ACTIONS are prepended (view-specific buttons before the globals).
Actions registered under `with-jetpacs-owner' show only while their app
passes `jetpacs-shell-chrome-filter-function'."
  (jetpacs-top-bar title
                :actions (append extra-actions
                                 (delq nil
                                       (mapcar (lambda (e)
                                                 (when (jetpacs-shell--chrome-visible-p (cddr e))
                                                   (funcall (cadr e))))
                                               jetpacs-shell-top-actions)))))

(cl-defun jetpacs-shell-tab-view (name body &key top-bar (fab nil fab-given) snackbar snackbar-action floating-toolbar)
  "A standard tab view: drawer, bottom bar, pull-to-refresh, default chrome.
NAME selects the bottom-bar highlight; BODY is the content node.  TOP-BAR
defaults to `jetpacs-shell-default-top-bar' on the capitalized name.  When FAB
is not given at all, the app's `jetpacs-shell-default-fab' is used; pass an
explicit nil to render no FAB."
  `((children . ,(vector
                  (jetpacs-scaffold
                   :top-bar (or top-bar (jetpacs-shell-default-top-bar (capitalize name)))
                   :body body
                   :fab (if fab-given fab (jetpacs-shell-default-fab name))
                   :bottom-bar (jetpacs-shell-bottom-bar name)
                   :drawer (jetpacs-shell-drawer)
                   :snackbar snackbar
                   :snackbar-action snackbar-action
                   :floating-toolbar floating-toolbar
                   ;; Tab views support pull-to-refresh; navigation/detail
                   ;; views don't (a stray pull mustn't rebuild them).
                   :on-refresh (jetpacs-action "dashboard.refresh"
                                            :when-offline "drop"))))))

(cl-defun jetpacs-shell-nav-view (title body &key back-to nav-action actions
                                     fab snackbar snackbar-action bottom-bar floating-toolbar)
  "A navigation view: back arrow in the top bar, no tabs or drawer.
BACK-TO names the view the arrow switches to (default: the current tab)
as a companion-local switch; NAV-ACTION overrides it with an explicit
action descriptor.  ACTIONS are trailing top-bar buttons."
  `((children . ,(vector
                  (jetpacs-scaffold
                   :top-bar (jetpacs-top-bar title
                                          :nav-icon "arrow_back"
                                          :nav-action
                                          (or nav-action
                                              (jetpacs-shell-switch-view
                                               (or back-to (jetpacs-shell-current-tab))))
                                          :actions actions)
                   :body body
                   :fab fab
                   :snackbar snackbar
                   :snackbar-action snackbar-action
                   :bottom-bar bottom-bar
                   :floating-toolbar floating-toolbar)))))

;; ─── The push ────────────────────────────────────────────────────────────────

(defvar jetpacs-shell-surface-id "app:dashboard"
  "Surface id the shell pushes to.  One multi-view surface: the companion
switches views locally, so navigation never waits on Emacs.")

(defun jetpacs-shell--build-view (name plist snackbar)
  "Build view NAME from its :builder in PLIST, degrading errors in place.
A broken builder must cost its own screen, not the whole push — with a
Tier 1 being live-coded against a running session, the rest of the app
keeps updating and the broken view *shows* its error."
  (condition-case err
      (if (plist-get plist :spec)
          (jetpacs-spec--compile name (plist-get plist :spec) snackbar)
        (funcall (plist-get plist :builder) snackbar))
    (error
     (jetpacs-shell-nav-view
      (capitalize name)
      (jetpacs-column
       (jetpacs-text (format "Error building view \"%s\"" name) 'title)
       (jetpacs-text (error-message-string err) 'body))
      :snackbar snackbar))))

(defvar jetpacs-shell--repush-timer nil)

(defun jetpacs-shell--schedule-repush ()
  "Debounced push after a registry mutation on a live session.
Loading a Tier 1 file registers views/chrome in a burst; one idle push
after the burst means `eval-buffer' (or `load') against a connected
phone updates the app with no explicit `jetpacs-shell-push' — the
live-coding loop.  A no-op while disconnected: the on-connect push will
carry the registrations."
  (when (and (jetpacs-connected-p) (not (timerp jetpacs-shell--repush-timer)))
    (setq jetpacs-shell--repush-timer
          (run-with-idle-timer 0.5 nil
                               (lambda ()
                                 (setq jetpacs-shell--repush-timer nil)
                                 (jetpacs-shell-push))))))

(cl-defun jetpacs-shell-push (&optional tab &key switch-to)
  "Push every registered view as one multi-view surface.
TAB switches the logical tab before building.  SWITCH-TO additionally
forces the companion onto that view (used when a push *is* the
navigation, e.g. opening a detail); plain background refreshes never
yank the user off whatever they're looking at."
  ;; Any explicit push satisfies a pending registry repush.
  (when (timerp jetpacs-shell--repush-timer)
    (cancel-timer jetpacs-shell--repush-timer)
    (setq jetpacs-shell--repush-timer nil))
  (when tab
    (unless (equal tab jetpacs-shell--current-tab)
      (run-hook-with-args 'jetpacs-shell-view-switched-hook tab))
    (setq jetpacs-shell--current-tab tab))
  (condition-case err
      (let* ((active (jetpacs-shell--active-view))
             (target (or switch-to tab))
             ;; A navigation push lands the user on TARGET, so feedback
             ;; (e.g. "Saved init.el") must attach there, not to the view
             ;; they're leaving.
             (snack-view (or target active))
             (snackbar (prog1 jetpacs-shell--snackbar
                         (setq jetpacs-shell--snackbar nil)))
             (views (mapcar
                     (lambda (entry)
                       (let ((name (car entry)))
                         (cons (intern name)
                               (jetpacs-shell--build-view
                                name (cdr entry)
                                (when (equal name snack-view)
                                  snackbar)))))
                     (jetpacs-shell--visible-views))))
        (jetpacs-surface-push
         jetpacs-shell-surface-id
         `((views . ,views)
           (initial_view . ,active))
         nil nil
         ;; Force the companion onto a view only when this push *is* a
         ;; navigation — see SWITCH-TO above.
         target)
        (run-hooks 'jetpacs-shell-after-push-hook))
    (error
     (message "Jetpacs shell push failed: %s" (error-message-string err)))))

(defun jetpacs-shell-refresh (&rest _)
  "Bypass app caches (via `jetpacs-shell-refresh-hook') and push.
Safe on any hook: extra arguments are ignored."
  (run-hooks 'jetpacs-shell-refresh-hook)
  (jetpacs-shell-push))

;; ─── Host ends of the core seams ─────────────────────────────────────────────

;; A tap that mutates a buffer re-pushes the showing surface through here.
(setq jetpacs-buffer-refresh-function #'jetpacs-shell-push)

;; Settings feedback lands in the snackbar; setting changes re-render.
(defvar jetpacs-settings-notify-function)
(defvar jetpacs-settings-refresh-function)
(with-eval-after-load 'jetpacs-settings
  (setq jetpacs-settings-notify-function #'jetpacs-shell-notify
        jetpacs-settings-refresh-function #'jetpacs-shell-push))

;; ─── Wire actions ────────────────────────────────────────────────────────────

(jetpacs-defaction "view.switched"
  (lambda (args _)
    ;; The companion already flipped the view locally — this event only
    ;; synchronizes Emacs's notion of "where the user is" and refreshes
    ;; the (possibly stale) cached views in the background.
    (let ((view (alist-get 'view args)))
      (when view
        (unless (jetpacs-shell--overlay-p view)
          (run-hook-with-args 'jetpacs-shell-view-switched-hook view)
          (when (jetpacs-shell--tab-p view)
            (setq jetpacs-shell--current-tab view)))
        ;; No :switch-to — never yank the user during a background refresh.
        (jetpacs-shell-push)))))

(jetpacs-defaction "nav.tab"
  ;; Legacy round-trip navigation; superseded by the view.switch builtin
  ;; but kept so stale cached UIs from older pushes still work.
  (lambda (args _)
    (let ((tab (alist-get 'tab args)))
      (jetpacs-shell-push tab))))

(jetpacs-defaction "dashboard.refresh"
  ;; Manual refresh is an explicit "give me fresh data": bypass the memos.
  (lambda (_ _) (jetpacs-shell-refresh)))

(jetpacs-defaction "dialog.dismiss"
  (lambda (_ _) (jetpacs-dismiss-dialog)))

;; The shell's own drawer entry: an explicit data refresh.
(jetpacs-shell-add-drawer-item
 70 (lambda ()
      (jetpacs-drawer-item "refresh" "Refresh data"
                        (jetpacs-action "dashboard.refresh" :when-offline "drop"))))

;; ─── Stock settings screen ───────────────────────────────────────────────────

;; The foundation provides the settings screen itself, so a Tier 1 only
;; registers content: defcustom sections through
;; `jetpacs-settings-register-section' and satellite screens through
;; `jetpacs-settings-add-link' — both appear here with no further wiring,
;; and the bare companion has a working Settings screen before any app
;; loads.  Register sections under `with-jetpacs-owner' and they show only
;; while that app is current (once a second app exists).
;;
;; An app that needs a richer screen defines its own
;; \"<appid>.settings\" view splicing `jetpacs-settings-sections' at the
;; end of its own scrollable body; the stock drawer entry resolves to it
;; while that app is current (`jetpacs-shell-resolve-view'), so the one
;; Settings affordance reaches the right screen in every app.  Do NOT
;; redefine the stock \"settings\" view by name — with several apps
;; loaded the last one would hijack the screen for all of them.

(declare-function jetpacs-settings-sections "jetpacs-settings")
(declare-function jetpacs-settings-register-section "jetpacs-settings")

(defun jetpacs-shell-settings-body ()
  "Every registered settings section and satellite link, as one body.
The stock \"settings\" view renders exactly this.  It is a WHOLE
scrollable body (one lazy column): an app replacing the view either
uses it as its entire body, or — when it has controls of its own —
splices `jetpacs-settings-sections' into its own lazy column instead.
Never nest this node inside another scroll container."
  (apply #'jetpacs-lazy-column (jetpacs-settings-sections)))

(defun jetpacs-shell--settings-view (snackbar)
  "The stock settings screen (see `jetpacs-shell-settings-body')."
  (jetpacs-shell-nav-view "Emacs Settings" (jetpacs-shell-settings-body)
                       :snackbar snackbar))

(defun jetpacs-shell--build-features-row ()
  "The Emacs build-feature matrix as a read-only settings row.
The user-visible doctor line for `jetpacs-build-features': every known
optional build feature, check when this Emacs binary has it, dash when
it doesn't.  Informational only — nothing is settable here."
  (jetpacs-column
   (jetpacs-text "Emacs build features" 'label)
   (jetpacs-text
    (mapconcat (lambda (probe)
                 (format "%s %s" (car probe)
                         (if (jetpacs-feature-p (car probe)) "✓" "—")))
               jetpacs--build-feature-probes "   ")
    'caption)))

(with-eval-after-load 'jetpacs-settings
  ;; The foundation's own knobs, so the stock screen is never empty and
  ;; the theme mirror / dialog style are discoverable without docs.
  ;; Entries degrade per-symbol: a setup that never loads a module shows
  ;; "not loaded yet" for its knob instead of losing the section.
  (jetpacs-settings-register-section
   "Bridge"
   '((jetpacs-theme-sync :label "Mirror Emacs theme")
     (jetpacs-dialog-style :label "Dialog style")
     (jetpacs-reconnect :label "Auto-reconnect")
     (jetpacs-build-features :render jetpacs-shell--build-features-row)))
  (jetpacs-shell-define-view "settings" :builder #'jetpacs-shell--settings-view)
  ;; Two explicit settings domains. Jetpacs Settings is companion-local and
  ;; always works offline; Emacs Settings resolves through the current Tier 1
  ;; so its own defcustom-backed preferences remain part of that screen.
  (jetpacs-shell-add-drawer-item
   59 (lambda ()
        (jetpacs-drawer-item "settings" "Jetpacs Settings"
                          (jetpacs-native-settings-action))))
  (jetpacs-shell-add-drawer-item
   60 (lambda ()
        (jetpacs-drawer-item "tune" "Emacs Settings"
                          (jetpacs-shell-switch-view
                           (jetpacs-shell-resolve-view "settings"))))))

;; ─── Lifecycle pushes ────────────────────────────────────────────────────────

;; After (re)connect, push so the app never shows a stale screen from a
;; previous Emacs session. Depth 10: after the revision snapshot has been
;; absorbed (-50 in jetpacs-surfaces) and any notification re-asserts (0).
(add-hook 'jetpacs-connected-hook
          (lambda (_welcome) (jetpacs-shell-push))
          10)

;; After a replay, queued taps have just mutated state — the cached views
;; on the phone are now behind reality.
(add-hook 'jetpacs-queue-drained-hook #'jetpacs-shell-refresh)

(provide 'jetpacs-shell)
;;; jetpacs-shell.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-spec.el
;;; ==================================================================

;;; jetpacs-spec.el --- declarative data-view compiler -*- lexical-binding: t; -*-

;; The UI half of a declarative view.  `jetpacs-shell-define-view' accepts a
;; `:spec' (a plist) beside `:builder'; this module compiles it, at push time,
;; into the same scaffold node tree a hand-written builder returns:
;;
;;   query a named source -> group -> per-item template instantiation -> layout
;;   -> chrome (tab/nav).
;;
;; The template is RAW wire-node data (ordinary widget constructors are not
;; promised to preserve placeholders, so a template is authored as raw nodes).
;; A leaf may be a PLACEHOLDER `((bind . "field") (as . "transform"))' — the
;; only dynamic element, resolved server-side from the item's fields through a
;; CLOSED, domain-neutral transform set (SPEC §5: no expressions on the wire).
;; `jetpacs-lint-view-spec' (jetpacs-lint.el) proves a spec carries only closed
;; data and registered names.
;;
;; Layouts: list (header + one template per item), calendar (ISO-date groups,
;; ascending, unscheduled last), board (grouped columns; the per-card
;; cross-column "move" menu is a Glasspane opinion left to :builder in v1).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-source)
(require 'jetpacs-shell)
(require 'jetpacs-lint)

;; ─── Placeholders + transforms ───────────────────────────────────────────────

(defun jetpacs-spec--placeholder-p (x)
  "Non-nil when X is a `((bind . FIELD) [(as . TRANSFORM)])' placeholder."
  (and (jetpacs-lint--alist-p x) (assq 'bind x) t))

(defun jetpacs-spec--field-value (item field)
  "The raw value of FIELD (a string) in ITEM (a symbol-keyed alist)."
  (and field (alist-get (intern field) item)))

(defun jetpacs-spec--date-label (iso)
  "\"Mon D\" for an ISO date string ISO, or nil."
  (when (and (stringp iso)
             (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" iso))
    (format "%s %d" (jetpacs-month-abbrev (string-to-number (match-string 2 iso)))
            (string-to-number (match-string 3 iso)))))

(defun jetpacs-spec--transform (as raw)
  "Apply the closed transform named AS to RAW; nil means \"absent\" (dropped).
Transforms are domain-neutral: a source normalizes engine data to canonical
types (ISO dates, string lists) before core sees it."
  (pcase as
    ("raw" raw)
    ("string" (and raw (if (stringp raw) raw (format "%s" raw))))
    ("date" (and (stringp raw)
                 (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" raw) raw))
    ("date-label" (jetpacs-spec--date-label raw))
    ("tags-list" (let ((l (cond ((vectorp raw) (append raw nil)) ((listp raw) raw))))
                   (and l (mapconcat (lambda (s) (format "%s" s)) l " "))))
    ("count" (length (cond ((vectorp raw) (append raw nil)) ((listp raw) raw) (t nil))))
    ("bool" (if raw t :false))
    ("ref" raw)
    (_ raw)))

(defun jetpacs-spec--resolve (ph item source)
  "Resolve placeholder PH against ITEM (SOURCE labels errors)."
  (ignore source)
  (jetpacs-spec--transform (or (alist-get 'as ph) "raw")
                           (jetpacs-spec--field-value item (alist-get 'bind ph))))

;; ─── Instantiation (the only place a field value is computed) ────────────────

(defun jetpacs-spec--instantiate-args (args item source)
  "Instantiate an action's ARGS for ITEM.
ARGS is a placeholder binding the whole args object (e.g. a ref), or an alist
whose values are literals/placeholders and which may carry one `_spread' entry
\(a placeholder for a base object to merge under the literal keys).  A key that
collides with a spread key is an error."
  (cond
   ((jetpacs-spec--placeholder-p args) (jetpacs-spec--resolve args item source))
   ((jetpacs-lint--alist-p args)
    (let* ((spread-cell (assq '_spread args))
           (base (and spread-cell (jetpacs-spec--resolve (cdr spread-cell) item source)))
           (rest (assq-delete-all '_spread (copy-alist args)))
           (merged (delq nil
                         (mapcar (lambda (pair)
                                   (let ((v (jetpacs-spec--instantiate (cdr pair) item source)))
                                     (and v (cons (car pair) v))))
                                 rest))))
      (dolist (pair merged)
        (when (assq (car pair) base)
          (error "jetpacs-spec: args key `%s' collides with the spread object" (car pair))))
      (append base merged)))
   (t args)))

(defun jetpacs-spec--instantiate (node item source)
  "Return NODE with every placeholder resolved against ITEM.
A placeholder resolving to nil drops its containing attribute/child."
  (cond
   ((jetpacs-spec--placeholder-p node) (jetpacs-spec--resolve node item source))
   ((vectorp node)
    (vconcat (delq nil (mapcar (lambda (x) (jetpacs-spec--instantiate x item source))
                               (append node nil)))))
   ((jetpacs-lint--alist-p node)
    (delq nil
          (mapcar
           (lambda (pair)
             (let ((v (if (eq (car pair) 'args)
                          (jetpacs-spec--instantiate-args (cdr pair) item source)
                        (jetpacs-spec--instantiate (cdr pair) item source))))
               (and v (cons (car pair) v))))
           node)))
   (t node)))

;; ─── Grouping ────────────────────────────────────────────────────────────────

(defun jetpacs-spec--group-key (item field)
  "The group key of ITEM by FIELD — its value, or \"\" when absent."
  (or (jetpacs-spec--field-value item field) ""))

(defun jetpacs-spec--column-order (items field order source empty-last)
  "The ordered distinct group values of ITEMS by FIELD.
ORDER is an explicit values vector, else the source field's enum values, else
encounter order; present groups not covered are appended; \"\" goes last when
EMPTY-LAST."
  (let* ((present (delete-dups (mapcar (lambda (it) (jetpacs-spec--group-key it field)) items)))
         (base (cond ((vectorp order) (append order nil))
                     ((and source (jetpacs-source-p source))
                      (let ((fspec (cl-find field (jetpacs-source-fields source)
                                            :key (lambda (f) (plist-get f :name)) :test #'equal)))
                        (and (equal (plist-get fspec :type) "enum")
                             (append (plist-get fspec :values) nil))))))
         (ordered (append (cl-remove-if-not (lambda (v) (member v present)) base)
                          (cl-remove-if (lambda (v) (member v base)) present))))
    (if empty-last
        (append (cl-remove "" ordered :test #'equal)
                (and (member "" ordered) '("")))
      ordered)))

(defun jetpacs-spec--group-label (g layout)
  "A human label for group value G under LAYOUT."
  (cond ((and (stringp g) (string-empty-p g))
         (if (equal layout "calendar") "Unscheduled" "None"))
        ((equal layout "calendar") (or (jetpacs-spec--date-label g) g))
        (t g)))

;; ─── Layouts ─────────────────────────────────────────────────────────────────

(defun jetpacs-spec--cards (template items source)
  "Instantiate TEMPLATE for each of ITEMS."
  (mapcar (lambda (it) (jetpacs-spec--instantiate template it source)) items))

(defun jetpacs-spec--list (spec items template source)
  "The list layout: optional header then one template per item, in a lazy column."
  (apply #'jetpacs-lazy-column
         (append (when (plist-get spec :header)
                   (list (jetpacs-spec--instantiate (plist-get spec :header) nil source)))
                 (jetpacs-spec--cards template items source))))

(defun jetpacs-spec--calendar (spec items template source)
  "The calendar layout: ISO-date groups ascending (unscheduled last), each a
section header + its item templates, flattened into a lazy column."
  (let* ((field (or (plist-get (plist-get spec :group-by) :field) "scheduled"))
         (buckets (make-hash-table :test 'equal)))
    (dolist (it items)
      (let ((k (jetpacs-spec--group-key it field)))
        (puthash k (cons it (gethash k buckets)) buckets)))
    (let ((dates (sort (hash-table-keys buckets)
                       (lambda (a b) (cond ((string-empty-p a) nil)
                                           ((string-empty-p b) t)
                                           (t (string< a b)))))))
      (apply #'jetpacs-lazy-column
             (cl-loop for d in dates append
                      (cons (jetpacs-section-header (jetpacs-spec--group-label d "calendar"))
                            (jetpacs-spec--cards template (nreverse (gethash d buckets)) source)))))))

(defun jetpacs-spec--board (spec items template source)
  "The board layout: one column per group value, panning sideways."
  (let* ((gb (plist-get spec :group-by))
         (field (or (plist-get gb :field) "todo"))
         (groups (jetpacs-spec--column-order items field (plist-get gb :order)
                                             source (plist-get gb :empty-last))))
    (apply #'jetpacs-scroll-row
           (mapcar
            (lambda (g)
              (let ((in-col (cl-remove-if-not
                             (lambda (it) (equal (jetpacs-spec--group-key it field) g)) items)))
                (jetpacs-box
                 (list (apply #'jetpacs-column
                              (cons (jetpacs-section-header
                                     (format "%s (%d)" (jetpacs-spec--group-label g "board")
                                             (length in-col)))
                                    (jetpacs-spec--cards template in-col source))))
                 :padding 4)))
            groups))))

(defun jetpacs-spec--layout-body (spec items)
  "The body node for SPEC over ITEMS."
  (let ((template (plist-get spec :template))
        (source (plist-get spec :source)))
    (pcase (plist-get spec :layout)
      ("board" (jetpacs-spec--board spec items template source))
      ("calendar" (jetpacs-spec--calendar spec items template source))
      (_ (jetpacs-spec--list spec items template source)))))

(defun jetpacs-spec--empty-body (spec)
  "The empty-state node for SPEC (a default when none is declared)."
  (let ((es (plist-get spec :empty-state)))
    (jetpacs-empty-state :icon (or (plist-get es :icon) "inbox")
                         :title (or (plist-get es :title) "Nothing here")
                         :caption (plist-get es :caption))))

;; ─── Chrome + compile ────────────────────────────────────────────────────────

(defun jetpacs-spec--seq (x)
  "X (a vector or list of nodes) as a list, or nil."
  (and x (append x nil)))

(defun jetpacs-spec--wrap (name chrome body snackbar)
  "Wrap BODY in the tab/nav chrome for view NAME."
  (pcase (or (plist-get chrome :kind) "tab")
    ("nav"
     (jetpacs-shell-nav-view (or (plist-get chrome :title) (capitalize name)) body
                             :back-to (plist-get chrome :back)
                             :actions (jetpacs-spec--seq (plist-get chrome :actions))
                             :fab (plist-get chrome :fab)
                             :snackbar snackbar))
    (_
     (apply #'jetpacs-shell-tab-view name body
            :snackbar snackbar
            (append
             (when (plist-get chrome :title)
               (list :top-bar (jetpacs-shell-default-top-bar (plist-get chrome :title))))
             (when (plist-member chrome :fab) (list :fab (plist-get chrome :fab))))))))

(defun jetpacs-spec--compile (name spec snackbar)
  "Compile view NAME's declarative SPEC into a scaffold node tree.
Runs inside `jetpacs-shell--build-view''s condition-case, so a failure here
degrades to that view's error card rather than dropping the push."
  ;; Structural lint before querying: prove the spec is closed data over the
  ;; source's declared fields.  A problem aborts to the shell's error card.
  (let ((problems (jetpacs-lint-view-spec
                   spec (mapcar (lambda (f) (plist-get f :name))
                                (jetpacs-source-fields (plist-get spec :source))))))
    (when problems (error "invalid :spec for %s: %s" name (cdar problems))))
  (let* ((items (jetpacs-source-query (plist-get spec :source) (plist-get spec :params)))
         (body  (if items (jetpacs-spec--layout-body spec items)
                  (jetpacs-spec--empty-body spec))))
    (jetpacs-spec--wrap name (plist-get spec :chrome) body snackbar)))

(provide 'jetpacs-spec)
;;; jetpacs-spec.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-apps.el
;;; ==================================================================

;;; jetpacs-apps.el --- App identity over the shell: jetpacs-defapp + launcher home -*- lexical-binding: t; -*-

;; Groups shell views into named apps, AppSheet-style: a launcher home
;; grid of app cards, one app's tabs in the bottom bar at a time, and an
;; `app.open' action that switches between them.  Pure shell logic — no
;; wire changes beyond the `app.*' action namespace reserved in SPEC §5.
;;
;; THIS IS THE ENTRY POINT for a Tier 1 app.  The contract that keeps
;; coexisting apps isolated:
;;
;;   1. Name your views in your own namespace — "<appid>.<view>" (bare
;;      "<appid>" is fine for a single-view app).  The shell registry
;;      replaces by name; bare names collide across apps.
;;   2. Make registrations under (with-jetpacs-owner "<appid>" ...) —
;;      views, actions, settings sections/links, drawer items, top
;;      actions.  Ownership is what scopes your chrome and settings to
;;      your app, catches collisions, and lets `jetpacs-app-unregister'
;;      tear you down cleanly for live reload.
;;   3. Finish with `jetpacs-defapp' claiming your views.
;;
;; The single-app contract: with zero or one `jetpacs-defapp' registered,
;; NOTHING changes — every view and all chrome shows, no home screen, no
;; drawer entry.  The launcher machinery appears with the second app
;; (AppSheet boots straight into a lone app the same way).
;;
;; Views not claimed by any app (the core Files / Eval / Tools tabs)
;; show in every app.  To contain them instead, claim them in an
;; explicit app of their own:
;;   (jetpacs-defapp "system" :label "Emacs" :icon "terminal"
;;                :views '("files" "eval" "tools") :order 900)

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)

;; ─── Registry ────────────────────────────────────────────────────────────────

(defvar jetpacs-apps--registry nil
  "Ordered list of (ID . PLIST) registered apps.
PLIST keys: :label :icon :views (list of shell view names) :order.")

(defvar jetpacs-apps--current nil
  "Id of the app whose views are currently shown, or nil for the first.")

(defcustom jetpacs-apps-show-vanilla-app t
  "When non-nil, register Jetpacs itself as an app in the launcher.
Disable this if you start adding more apps and want the core views (Buffers, Tools, etc.)
to show up in those apps instead of being isolated in a 'Jetpacs' app."
  :type 'boolean
  :group 'jetpacs
  :set (lambda (sym val)
         (set-default sym val)
         (if (fboundp 'jetpacs-apps--update-vanilla)
             (jetpacs-apps--update-vanilla))))

(defun jetpacs-apps--update-vanilla ()
  "Register or unregister the vanilla Jetpacs app based on settings."
  (if jetpacs-apps-show-vanilla-app
      (jetpacs-defapp "jetpacs" :label "Jetpacs" :icon "rocket_launch"
                      :views '("buffers" "messages" "tools" "files" "eval" "kill-ring" "automations" "customize")
                      :order 900)
    ;; Unregister manually to avoid tearing down the core views entirely.
    (dolist (v '("buffers" "messages" "tools" "files" "eval" "kill-ring" "automations" "customize"))
      (jetpacs--unclaim "view" v))
    (jetpacs-apps-remove "jetpacs")))


(cl-defun jetpacs-defapp (id &key label icon views (order 100))
  "Register (or replace) app ID grouping VIEWS (shell view names).
LABEL and ICON draw the app's launcher-home card; the first :tab view
in VIEWS is the app's landing tab.  ORDER sorts home cards; equal
orders keep registration order.

Name the views you define \"ID.<view>\" (or bare \"ID\") so they can
never collide with another app's; a view named \"ID.settings\" is
reached by the stock Settings drawer entry while this app is current
\(see `jetpacs-shell-resolve-view').  Claiming a core view (\"files\",
\"eval\", ...) into an app is also legal — that contains it to this
app instead of showing everywhere."
  ;; Attribute the app's views to it in the ownership registry, so
  ;; cross-app collisions are caught (`jetpacs--claim' warns, or errors under
  ;; `jetpacs-strict-namespaces') and `jetpacs-app-unregister' can find them
  ;; (see with-jetpacs-owner / jetpacs--claim in jetpacs-surfaces.el).
  (let ((jetpacs-current-owner id))
    (dolist (v views) (jetpacs--claim "view" v)))
  (setq jetpacs-apps--registry
        (sort (append (assoc-delete-all id jetpacs-apps--registry)
                      (list (cons id (list :label (or label (capitalize id))
                                           :icon (or icon "apps")
                                           :views views :order order))))
              (lambda (a b) (< (plist-get (cdr a) :order)
                               (plist-get (cdr b) :order)))))
  (jetpacs-shell--schedule-repush)
  id)

(defun jetpacs-apps-remove (id)
  "Unregister app ID (its views fall back to showing everywhere)."
  (setq jetpacs-apps--registry (assoc-delete-all id jetpacs-apps--registry))
  (jetpacs-shell--schedule-repush))

(defun jetpacs-app-unregister (id)
  "Tear down everything owned by app ID: its actions, views, and settings.
Removes the registrations attributed to ID (through `with-jetpacs-owner' /
`jetpacs-defapp'), drops their ownership records, clears UI-state keyed
under the app's id prefix, and removes the app from the launcher.  For
clean live reload and genuine uninstall — no stale handlers accumulate.
Registrations a Tier 1 made without an owner are not tracked and are not
torn down (wrap them in `with-jetpacs-owner' to make them removable)."
  (dolist (name (jetpacs--owned-names "action" id))
    (remhash name jetpacs-action-handlers)
    (remhash name jetpacs--action-catalog)
    (jetpacs--unclaim "action" name))
  (dolist (name (jetpacs--owned-names "view" id))
    (jetpacs-shell-remove-view name)
    (jetpacs--unclaim "view" name))
  (dolist (title (jetpacs--owned-names "settings" id))
    (when (fboundp 'jetpacs-settings-remove-section)
      (jetpacs-settings-remove-section title))
    (jetpacs--unclaim "settings" title))
  ;; Owner-attributed chrome and settings links, and the app's FAB.
  (jetpacs-shell-remove-owned-chrome id)
  (when (boundp 'jetpacs-settings-links)
    (setq jetpacs-settings-links
          (cl-remove-if (lambda (e) (equal (cddr e) id))
                        jetpacs-settings-links)))
  (when (boundp 'jetpacs-settings-native-links)
    (setq jetpacs-settings-native-links
          (cl-remove-if (lambda (e) (equal (cddr e) id))
                        jetpacs-settings-native-links)))
  (setf (alist-get id jetpacs-apps--fabs nil t #'equal) nil)
  ;; Drop UI-state and its subscriptions keyed under the app's id prefix.
  (jetpacs-ui-state-clear (concat id "."))
  (jetpacs-on-state-change-clear (concat id "."))
  ;; Surfaces
  (dolist (name (jetpacs--owned-names "surface" id))
    (jetpacs-surface-remove name)
    (jetpacs--unclaim "surface" name))
  ;; Data sources (jetpacs-source.el; guard for a lean build without it)
  (dolist (name (jetpacs--owned-names "source" id))
    (when (fboundp 'jetpacs-source-remove) (jetpacs-source-remove name)))
  ;; Forms (jetpacs-form registry)
  (dolist (form (jetpacs--forms-of-owner id)) (jetpacs-form-dispose form))
  ;; Triggers (batch to avoid N redundant pushes)
  (let ((trigger-names (jetpacs--owned-names "trigger" id)))
    (dolist (name trigger-names)
      (remhash name jetpacs-triggers--table)
      (jetpacs--unclaim "trigger" name))
    (when trigger-names
      (jetpacs-triggers-push)
      (when (boundp 'jetpacs-triggers-changed-hook)
        (run-hooks 'jetpacs-triggers-changed-hook))))
  (jetpacs-apps-remove id)
  (jetpacs-shell--schedule-repush)
  id)

(defun jetpacs-apps--owner (view-name)
  "The id of the app claiming VIEW-NAME, or nil when unclaimed."
  (car (cl-find-if (lambda (e) (member view-name (plist-get (cdr e) :views)))
                   jetpacs-apps--registry)))

(defun jetpacs-apps--multi-p ()
  "Non-nil once a second app is registered — the launcher trigger."
  (> (length jetpacs-apps--registry) 1))

(defun jetpacs-apps-current ()
  "The current app id, defaulting to the first registered app."
  (if (assoc jetpacs-apps--current jetpacs-apps--registry)
      jetpacs-apps--current
    (caar jetpacs-apps--registry)))

(defun jetpacs-apps-current-p (id)
  "Non-nil while app ID is the one whose views are showing.
Also non-nil with no second app registered — a lone app is always
current.  For gating dynamic registrations an app makes outside its
`with-jetpacs-owner' blocks."
  (or (not (jetpacs-apps--multi-p))
      (equal id (jetpacs-apps-current))))

(defun jetpacs-apps--landing-tab (id)
  "The view app ID lands on: its first :tab view, else its first view."
  (let ((views (plist-get (cdr (assoc id jetpacs-apps--registry)) :views)))
    (or (cl-find-if #'jetpacs-shell--tab-p views) (car views))))

;; ─── The shell filters (the whole gating mechanism) ──────────────────────────

(defun jetpacs-apps--view-visible-p (name)
  "Single-app: everything shows.  Multi-app: the current app's views
plus every unclaimed view (core tabs, the home grid itself)."
  (or (not (jetpacs-apps--multi-p))
      (let ((owner (jetpacs-apps--owner name)))
        (or (null owner)
            (equal owner (jetpacs-apps-current))))))

;; Core view slots resolve to a per-app override when the current app
;; registered one: "settings" reaches "glasspane.settings" inside
;; Glasspane.  This replaces the single-app-era pattern of redefining
;; the stock view by name (which the last-loaded app would hijack).
(defun jetpacs-apps--resolve-view (name)
  (let ((cur (jetpacs-apps-current)))
    (and cur
         (let ((scoped (concat cur "." name)))
           (and (assoc scoped jetpacs-shell-views) scoped)))))

(defun jetpacs--install-invariants ()
  "Re-assert the multi-app isolation seams.  Idempotent.
These four function-valued vars ARE the whole gating mechanism: which
views are visible, which chrome (drawer items, top actions) shows, which
settings sections show, and the core->per-app view resolver.  They are
INTERNAL — deliberately not `defcustom's and not on any Settings screen —
because a stray `setq' (from user init.el or a mis-behaved app) that nulls
one would leak another app's views, chrome or settings.

Structural ownership, not load-order luck: this installer runs at load
time AND again as the first step of `jetpacs-connect' (via
`jetpacs-before-connect-hook'), which fires after the user's whole init.el
has run — so nothing done during init can survive to the first served
frame.  The seam vars themselves being internal (no user-facing knob) is
the other half; together they make isolation an invariant rather than a
default."
  (setq jetpacs-shell-view-filter-function   #'jetpacs-apps--view-visible-p
        jetpacs-shell-chrome-filter-function #'jetpacs-apps-current-p
        jetpacs-shell-view-resolver-function #'jetpacs-apps--resolve-view)
  ;; The settings-section filter lives in jetpacs-settings, which loads
  ;; after this file in the bundle; only set it once that var is bound.
  (when (boundp 'jetpacs-settings-section-filter-function)
    (setq jetpacs-settings-section-filter-function #'jetpacs-apps-current-p)))

;; Install at load time...
(jetpacs--install-invariants)
;; ...cover the settings filter as soon as its feature arrives (the
;; load-time call above skips it while still unbound)...
(with-eval-after-load 'jetpacs-settings
  (setq jetpacs-settings-section-filter-function #'jetpacs-apps-current-p))
;; ...and re-assert everything at connect, after all user init has run.
(add-hook 'jetpacs-before-connect-hook #'jetpacs--install-invariants)

;; Once a second app exists the drawer header names the app you are in;
;; a lone app keeps whatever `jetpacs-shell-drawer-header' it set.
(defun jetpacs-apps--drawer-header ()
  (when (jetpacs-apps--multi-p)
    (plist-get (cdr (assoc (jetpacs-apps-current) jetpacs-apps--registry))
               :label)))

(setq jetpacs-shell-drawer-header-function #'jetpacs-apps--drawer-header)

;; ─── Per-app default FAB ─────────────────────────────────────────────────────

(defvar jetpacs-apps--fabs nil
  "Alist of (APP-ID . FN); FN takes a view name and returns a FAB node.")

(defun jetpacs-apps--default-fab (name)
  "The current app's default FAB for view NAME, or nil."
  (let ((fn (cdr (assoc (jetpacs-apps-current) jetpacs-apps--fabs))))
    (when fn (funcall fn name))))

(defun jetpacs-apps-set-default-fab (id fn)
  "Give app ID the default FAB builder FN (view name -> FAB node or nil).
The app's FAB appears on its tab views that pass no explicit :fab —
and, unlike setting `jetpacs-shell-default-fab-function' directly, never
on another app's views."
  (setf (alist-get id jetpacs-apps--fabs nil t #'equal) nil)
  (push (cons id fn) jetpacs-apps--fabs)
  (setq jetpacs-shell-default-fab-function #'jetpacs-apps--default-fab)
  (jetpacs-shell--schedule-repush))

;; ─── The launcher home ───────────────────────────────────────────────────────

(defun jetpacs-apps--card (id plist)
  "The home-grid card for app ID."
  (jetpacs-card
   (list (jetpacs-box
          (list (jetpacs-column
                 (jetpacs-icon (plist-get plist :icon) :size 40)
                 (jetpacs-spacer :height 8)
                 (jetpacs-text (plist-get plist :label) 'title)))
          :alignment "center" :padding 16))
   :on-tap (jetpacs-action "app.open" :args `((app . ,id))
                        :when-offline "drop")))

(defun jetpacs-apps--home-view (snackbar)
  "The launcher home: a grid of app cards."
  (jetpacs-shell-nav-view
   "Apps"
   (apply #'jetpacs-flow-row
          (mapcar (lambda (e) (jetpacs-apps--card (car e) (cdr e)))
                  jetpacs-apps--registry))
   :snackbar snackbar))

(jetpacs-shell-define-view "home"
  :builder #'jetpacs-apps--home-view
  :when #'jetpacs-apps--multi-p
  :order 1)

;; Everyday nav: the Apps entry rides the drawer, but only exists once
;; there is more than one app (the drawer contract: no dead entries).
(jetpacs-shell-add-drawer-item
 5 (lambda ()
     (when (jetpacs-apps--multi-p)
       (jetpacs-drawer-item "apps" "Apps" (jetpacs-shell-switch-view "home")))))

;; ─── Wire action ─────────────────────────────────────────────────────────────

(jetpacs-defaction "app.open"
  (lambda (args _)
    (let ((app (alist-get 'app args)))
      (if (not (assoc app jetpacs-apps--registry))
          (message "Jetpacs apps: unknown app %s" app)
        (setq jetpacs-apps--current app)
        (let ((tab (jetpacs-apps--landing-tab app)))
          (if tab
              (jetpacs-shell-push tab :switch-to tab)
            (jetpacs-shell-push)))))))

(with-eval-after-load 'jetpacs-settings
  (jetpacs-settings-register-section
   "Jetpacs System"
   '((jetpacs-apps-show-vanilla-app :label "Show Jetpacs in App drawer"))))

(jetpacs-apps--update-vanilla)

(provide 'jetpacs-apps)
;;; jetpacs-apps.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-tablist.el
;;; ==================================================================

;;; jetpacs-tablist.el --- Generic tabulated-list renderer (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: `tabulated-list-mode' is a declarative UI framework — columns
;; come from `tabulated-list-format', rows carry their id and entry as text
;; properties — so ONE renderer covers every derivative (package menu,
;; process list, bookmarks, timers, and any package built on it).
;;
;; Registered as a skin for `tabulated-list-mode' in
;; `jetpacs-render-buffer-functions'; anything the buffer view shows in a
;; tabulated-list derivative renders as sortable cards instead of monospace
;; text.  Row taps reuse the existing `jetpacs.buffer.act' seam (push button /
;; RET at position), so activation adds no new dispatch surface; the only
;; new wire actions are `tablist.sort' and `tablist.refresh', both validated
;; against the buffer's own column format.
;;
;; Modes can specialize without replacing the walk via three hook alists
;; (header, row, filter) — jetpacs-package-browser.el is the worked example.
;;
;; Host seams (this file depends on no UI layer): re-pushes go through
;; `jetpacs-buffer-refresh-function' (owned by jetpacs-buffer), and opening a
;; buffer as the current view goes through `jetpacs-tablist-view-buffer-function'
;; which the host shell points at its buffer-view navigation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)

;; ─── Configuration and host seams ────────────────────────────────────────────

(defcustom jetpacs-tablist-max-rows 100
  "Maximum rows rendered from one tabulated-list buffer.
Large lists (a full MELPA package menu is thousands of rows) are capped
with a trailing note; skins narrow with filters rather than paging."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-tablist-view-buffer-function
  (lambda (name) (message "Jetpacs: no host to view buffer %s" name))
  "Function of a buffer name that navigates the companion to that buffer.
Set by the host shell (the org-ui dashboard points it at the buffer view).")

;; ─── Per-mode skin hooks ─────────────────────────────────────────────────────

(defvar jetpacs-tablist-header-functions nil
  "Alist of (MODE . FN); FN of the buffer returns extra header nodes.
Rendered between the title row and the sort chips.  Nearest derived
mode wins, like `jetpacs-render-buffer-functions'.")

(defvar jetpacs-tablist-row-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY POS) returns a row node, or nil
to fall back to the generic row.  Called with the list buffer current.")

(defvar jetpacs-tablist-filter-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY) says whether to keep a row.
Filtering runs before the row cap, so narrowed views see deep rows.")

(defun jetpacs-tablist--mode-fn (alist)
  "The nearest-derived-mode function from ALIST for the current buffer."
  (cl-loop for (mode . fn) in alist
           when (derived-mode-p mode) return fn))

;; ─── Reading the list ────────────────────────────────────────────────────────

(defun jetpacs-tablist--rows ()
  "Collect (POS ID ENTRY) for each printed row of the current buffer.
Walking the printed buffer (rather than `tabulated-list-entries', which
may be a function) respects the mode's current sort and filtering."
  (save-excursion
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (let ((id (tabulated-list-get-id))
              (entry (tabulated-list-get-entry)))
          (when (and id entry)
            (push (list (point) id entry) rows)))
        (forward-line 1))
      (nreverse rows))))

(defun jetpacs-tablist-col-string (col)
  "The display string of entry column COL (a string or (LABEL . PROPS))."
  (cond ((stringp col) col)
        ((consp col) (format "%s" (car col)))
        (t (format "%s" col))))

(defun jetpacs-tablist-entry-col (entry name)
  "ENTRY's column named NAME per the current buffer's format, or nil.
Part of the skin-author API: row/filter hooks use this to read a column
by its header label instead of a fragile index."
  (let ((i (cl-position name tabulated-list-format :key #'car :test #'equal)))
    (and i (< i (length entry))
         (jetpacs-tablist-col-string (aref entry i)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-tablist--sort-chips ()
  "A chip row for the sortable columns of the current buffer, or nil."
  (let* ((key (car tabulated-list-sort-key))
         (desc (cdr tabulated-list-sort-key))
         (chips (cl-loop for col across tabulated-list-format
                         for name = (car col)
                         when (nth 2 col) ; sortable
                         collect (jetpacs-chip
                                  (if (equal name key)
                                      (concat name (if desc " ↓" " ↑"))
                                    name)
                                  :selected (equal name key)
                                  :on-tap (jetpacs-action
                                           "tablist.sort"
                                           :args `((buffer . ,(buffer-name))
                                                   (column . ,name))
                                           :when-offline "drop")))))
    (when chips (apply #'jetpacs-flow-row chips))))

(defun jetpacs-tablist--default-row (buf-name pos entry)
  "Generic row card: first column as title, the rest as a caption."
  (let* ((cols (mapcar #'jetpacs-tablist-col-string (append entry nil)))
         (rest (string-join (cl-remove-if #'string-empty-p (cdr cols)) "  ·  ")))
    (jetpacs-card
     (list (apply #'jetpacs-column
                  (delq nil
                        (list (jetpacs-text (or (car cols) "") 'label)
                              (unless (string-empty-p rest)
                                (jetpacs-text rest 'caption))))))
     :on-tap (jetpacs-action "jetpacs.buffer.act"
                          :args `((buffer . ,buf-name) (pos . ,pos))
                          :when-offline "drop"))))

(defun jetpacs-tablist-render (buf)
  "Tier-1 skin: BUF (a tabulated-list buffer) as sortable, tappable cards."
  (with-current-buffer buf
    (let* ((name (buffer-name))
           (header-fn (jetpacs-tablist--mode-fn jetpacs-tablist-header-functions))
           (row-fn (jetpacs-tablist--mode-fn jetpacs-tablist-row-functions))
           (filter-fn (jetpacs-tablist--mode-fn jetpacs-tablist-filter-functions))
           (rows (jetpacs-tablist--rows))
           (rows (if filter-fn
                     (cl-remove-if-not
                      (lambda (r) (funcall filter-fn (nth 1 r) (nth 2 r)))
                      rows)
                   rows))
           (total (length rows))
           (shown (cl-subseq rows 0 (min total jetpacs-tablist-max-rows))))
      (append
       (list (jetpacs-row
              (jetpacs-box (list (jetpacs-text (format "%d rows" total) 'caption))
                        :weight 1)
              (jetpacs-icon-button "refresh"
                                (jetpacs-action "tablist.refresh"
                                             :args `((buffer . ,name))
                                             :when-offline "drop")
                                :content-description "Refresh list")))
       (when header-fn (funcall header-fn buf))
       (let ((chips (jetpacs-tablist--sort-chips)))
         (and chips (list chips)))
       (mapcar (lambda (r)
                 (or (and row-fn
                          (funcall row-fn (nth 1 r) (nth 2 r) (nth 0 r)))
                     (jetpacs-tablist--default-row name (nth 0 r) (nth 2 r))))
               shown)
       (when (> total (length shown))
         (list (jetpacs-text
                (format "Showing %d of %d — narrow with a filter."
                        (length shown) total)
                'caption)))))))

(jetpacs-render-buffer-register 'tabulated-list-mode #'jetpacs-tablist-render)

;; ─── Generic actions ─────────────────────────────────────────────────────────

(defun jetpacs-tablist-refresh-view ()
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

(jetpacs-defaction "tablist.sort"
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) "")))
          (col (alist-get 'column args)))
      (when buf
        (with-current-buffer buf
          (when (and (derived-mode-p 'tabulated-list-mode)
                     (cl-find col tabulated-list-format
                              :key #'car :test #'equal))
            ;; Same column: flip direction; new column: ascending.
            (setq tabulated-list-sort-key
                  (cons col (and (equal (car tabulated-list-sort-key) col)
                                 (not (cdr tabulated-list-sort-key)))))
            (tabulated-list-print t)))
        (jetpacs-tablist-refresh-view)))))

(jetpacs-defaction "tablist.refresh"
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) ""))))
      (when buf
        (with-current-buffer buf
          (when (derived-mode-p 'tabulated-list-mode)
            (ignore-errors (revert-buffer))))
        (jetpacs-tablist-refresh-view)))))

(provide 'jetpacs-tablist)
;;; jetpacs-tablist.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-comint.el
;;; ==================================================================

;;; jetpacs-comint.el --- Generic comint renderer (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: `comint-mode' is the substrate under every process REPL —
;; M-x shell, ielm, the inferior language shells — so ONE skin covers
;; them all, the same bet jetpacs-tablist makes on tabulated-list-mode.
;; The transcript renders through the Tier 0 walk (fontification and
;; tappable regions survive), tail-first because a REPL's interesting
;; end is the bottom; below it sit a status/interrupt row and an input
;; row whose submit dispatches `comint.send'.
;;
;; Boundary (docs/SPEC.md §5): `comint.send' delivers input only to the
;; live process of an existing comint buffer — a REPL the user already
;; opened (from the palette, M-x, or a curated entry point).  It never
;; starts a process, so the wire gains no new execution surface beyond
;; the sanctioned M-x escape hatch.
;;
;; Output arrives asynchronously; while the buffer is drilled into, the
;; buffer view's live-refresh watch (jetpacs-emacs-ui) re-pushes as it
;; lands, so the transcript follows along.  The input's widget id stays
;; stable across those background pushes — the client's seed guard
;; preserves half-typed text — and rotates after each send, which is how
;; a server-driven client clears a field.
;;
;; Known gap: a password prompt raised from the process filter
;; (`comint-watch-for-password-prompt') runs outside any action handler,
;; so it is NOT bridged to the phone; it blocks in the desktop
;; minibuffer like any other filter-time prompt.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)

(defcustom jetpacs-comint-tail-lines 200
  "Transcript lines rendered from the tail of a comint buffer."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-comint--gen (make-hash-table :test 'equal)
  "Buffer name -> send counter, spliced into the input's widget id.
A send bumps it, handing the client a fresh (empty) field; background
transcript refreshes don't, so the seed guard keeps half-typed input.")

(defun jetpacs-comint--refresh ()
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-comint-render (buf)
  "Tier-1 skin: comint BUF as status row + transcript tail + input row."
  (with-current-buffer buf
    (let* ((name (buffer-name))
           (proc (get-buffer-process buf))
           (live (and proc (process-live-p proc))))
      (append
       (list (jetpacs-row
              (jetpacs-box (list (jetpacs-text
                               (if live
                                   (format "%s — %s" (process-name proc)
                                           (process-status proc))
                                 "no live process")
                               'caption))
                        :weight 1)
              (and live
                   (jetpacs-icon-button "stop"
                                     (jetpacs-action "comint.interrupt"
                                                  :args `((buffer . ,name))
                                                  :when-offline "drop")
                                     :content-description "Interrupt (C-c C-c)"))))
       (jetpacs-buffer-render-tail buf jetpacs-comint-tail-lines)
       (when live
         ;; The input row is the scroll target: it sits at the bottom, and
         ;; every output line shifts its index, so the view follows the
         ;; transcript — the terminal "tail -f" feel.
         (list (jetpacs-scroll-here
                (jetpacs-text-input
                 (format "comint/%s/%d" name (gethash name jetpacs-comint--gen 0))
                 :hint "Input — Enter sends"
                 :single-line t :monospace t
                 :on-submit (jetpacs-action "comint.send"
                                         :args `((buffer . ,name)))))))))))

(jetpacs-render-buffer-register 'comint-mode #'jetpacs-comint-render)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun jetpacs-comint--live-buffer (name)
  "The comint buffer NAME when it has a live process, else nil (messaged).
The gate for both wire actions: an arbitrary name off the wire can only
ever reach the process of an already-open comint buffer."
  (let ((buf (and (stringp name) (get-buffer name))))
    (cond
     ((not (and buf (with-current-buffer buf (derived-mode-p 'comint-mode))))
      (message "%s is not a comint buffer" (or name "?"))
      nil)
     ((not (let ((proc (get-buffer-process buf)))
             (and proc (process-live-p proc))))
      (message "%s has no live process" name)
      nil)
     (t buf))))

(jetpacs-defaction "comint.send"
  (lambda (args _)
    (let ((buf (jetpacs-comint--live-buffer (alist-get 'buffer args)))
          (input (alist-get 'value args)))
      (when (and buf (stringp input))
        (condition-case err
            (with-current-buffer buf
              (goto-char (point-max))
              (insert input)
              (comint-send-input))
          (error (message "Send failed: %s" (error-message-string err))))
        (cl-incf (gethash (buffer-name buf) jetpacs-comint--gen 0))
        (jetpacs-comint--refresh)))))

(jetpacs-defaction "comint.interrupt"
  (lambda (args _)
    (let ((buf (jetpacs-comint--live-buffer (alist-get 'buffer args))))
      (when buf
        (with-current-buffer buf
          (ignore-errors (comint-interrupt-subjob)))
        (jetpacs-comint--refresh)))))

(provide 'jetpacs-comint)
;;; jetpacs-comint.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-results.el
;;; ==================================================================

;;; jetpacs-results.el --- Generic results/loci navigator (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: the `next-error' protocol is the substrate under every
;; "list of loci → jump into a source buffer" mode — occur, grep/rgrep
;; and compilation (grep-mode derives from compilation-mode, so it is
;; covered for free), xref, and anything else built on them.  ONE skin
;; renders them all as tappable cards, the same bet jetpacs-tablist makes
;; on tabulated-list-mode and jetpacs-comint makes on comint-mode.
;;
;; Under the Tier 0 generic renderer these buffers already render and
;; their rows are already tappable — but a tap runs the mode's own visit
;; command, which pops a *desktop* window and leaves the phone sitting on
;; the results buffer.  This substrate re-points the tap at the phone: it
;; follows the locus and shows the *source location* in the companion's
;; buffer view (narrowed around the line, scrolled to it).
;;
;; Two kinds of producer feed the same visit/stepper/seam:
;;   * buffer-loci — a position in a results buffer whose own goto command
;;     jumps to source (occur/compilation/xref).  Addressed by (buffer,pos).
;;   * file-loci  — a plain (file,line), e.g. the Files content search,
;;     handed in via `jetpacs-results-set-file-loci' and addressed by index
;;     into that server-built set (no path travels over the wire).
;;
;; The visit mechanism is uniform and parses no mode internals: place
;; point on the locus row, run the row's own RET/mouse-2 command (from its
;; text-property keymap, else the major-mode map) with the buffer-display
;; functions shimmed so nothing pops a desktop window, and read where
;; point lands.  Whatever `occur'/`compile'/`xref' would have visited is
;; exactly where the phone is taken.
;;
;; A visit arms a stepper: while you are looking at a visited locus, the
;; drill-in top bar offers prev/next-match chrome (`results.step') that
;; walks the same result set and re-navigates without a trip back to the
;; list — the touch-native form of `next-error'/`previous-error'.  The
;; host asks for that chrome through `jetpacs-results-buffer-view-actions'.
;;
;; Host seam (this module depends on no UI layer): the source location is
;; shown through `jetpacs-results-visit-region-function', the single jump
;; primitive the buffer view host (jetpacs-emacs-ui) points at its region
;; view for every producer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)   ; jetpacs-defaction / jetpacs-action
(require 'jetpacs-buffer)     ; jetpacs-render-buffer-register

;; ─── Configuration and host seam ─────────────────────────────────────────────

(defcustom jetpacs-results-max-loci 300
  "Maximum locus cards rendered from one results buffer.
A huge grep/compilation buffer is capped with a trailing note; the row
count in the header still reflects the true total."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-results-context-lines 100
  "Lines of source context shown below a visited locus.
The region view opens a window starting `jetpacs-results-context-before'
lines above the locus and running this many lines past it, so the hit and
its surroundings are visible without the buffer view's from-the-top cap."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-results-context-before 20
  "Lines of source context shown above a visited locus."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-results-visit-region-function
  (lambda (name &rest _) (message "Jetpacs: no host to view %s" name))
  "Function of (BUFFER-NAME BEG END LABEL &optional POINT) showing a
buffer slice with POINT's line as the scroll target.  Set by the buffer
view host (jetpacs-emacs-ui); kept as a seam so this module never depends
on the UI layer.")

(defvar jetpacs-results--nav nil
  "The active locus-stepper context, or nil.
A plist set by `results.visit'/`results.step': always (:kind KIND :index I
:count N :dest SRC-NAME), plus the kind-specific source to step from —
:buffer RESULTS-BUFFER-NAME for `buffer', or :loci FILE-LOCI for `file'.
While it holds and the buffer view is showing SRC-NAME's locus, the drill-in
top bar offers prev/next-match chrome (`jetpacs-results-buffer-view-actions').")

(defvar jetpacs-results--file-set nil
  "The active file-locus result set, or nil.
A list of file loci (each a plist (:file PATH :line N :text STRING)) set by
a file-producing search (e.g. the Files content search) through
`jetpacs-results-set-file-loci'.  Its result cards tap `results.visit' with
their index into this list; nothing off the wire carries a file path.")

(defun jetpacs-results-set-file-loci (loci)
  "Store LOCI as the active file-locus result set for `results.visit'.
LOCI is a list of plists (:file PATH :line N :text STRING).  A file
producer calls this as it renders its result cards (which tap
`results.visit' with the matching index), so the visit and the prev/next
stepper are shared with the buffer-backed occur/grep/xref producers."
  (setq jetpacs-results--file-set loci))

;; Modes this substrate skins.  compilation-mode covers grep-mode, rgrep,
;; and any `define-compilation-mode' derivative by derivation; occur and
;; the xref results buffer are their own modes.  The list also gates the
;; visit action: an arbitrary buffer name off the wire can only ever reach
;; a buffer that is actually one of these results modes.
(defconst jetpacs-results-modes
  '(occur-mode compilation-mode xref--xref-buffer-mode)
  "Major modes rendered and visited as loci by this substrate.")

(defun jetpacs-results--buffer-p (buf)
  "Non-nil when BUF is live and one of `jetpacs-results-modes'."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (apply #'derived-mode-p jetpacs-results-modes))))

;; ─── Reading the loci ─────────────────────────────────────────────────────────

(defun jetpacs-results--locus-pos (bol eol)
  "Return the position on line [BOL, EOL) carrying a jump, or nil.
Generic across the family: occur marks matches with `occur-target',
compilation with `compilation-message', xref rows are `button's, and any
mode may carry a `mouse-face'/text-property keymap over the loci.  Checks
the line start first (where all three put the property) then the first
non-blank char, so an indented or mid-line marker is still found."
  (cl-flet ((jump-at (p)
              (and (< p eol)
                   (or (get-text-property p 'occur-target)
                       (get-text-property p 'compilation-message)
                       (get-text-property p 'xref-item)
                       (get-char-property p 'button)
                       (get-char-property p 'mouse-face)
                       (let ((km (or (get-char-property p 'keymap)
                                     (get-char-property p 'local-map))))
                         (and (keymapp km)
                              (or (lookup-key km (kbd "RET"))
                                  (lookup-key km [return])
                                  (lookup-key km [mouse-2]))))))))
    (cond
     ((jump-at bol) bol)
     (t (let ((p (save-excursion
                   (goto-char bol)
                   (skip-chars-forward " \t" eol)
                   (point))))
          (and (> p bol) (jump-at p) p))))))

(defun jetpacs-results--loci (buf)
  "Collect (POS . TEXT) for each locus row of results buffer BUF.
POS is the actionable position on the line; TEXT is the trimmed line.
Walking the printed buffer respects the mode's current ordering/filtering."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let (loci)
        (while (not (eobp))
          (let* ((bol (line-beginning-position))
                 (eol (line-end-position))
                 (pos (and (> eol bol) (jetpacs-results--locus-pos bol eol))))
            (when pos
              (push (cons pos (string-trim
                               (buffer-substring-no-properties bol eol)))
                    loci)))
          (forward-line 1))
        (nreverse loci)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-results--card (name pos text)
  "A tappable card for the locus at POS in results buffer NAME."
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-box (list (jetpacs-rich-text
                           (list (jetpacs-span (if (string-empty-p text) " " text)
                                            :mono t))))
                    :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap (jetpacs-action "results.visit"
                        :args `((buffer . ,name) (pos . ,pos))
                        :when-offline "drop")))

(defun jetpacs-results-render (buf)
  "Tier-1 skin: results BUF as a count header + one tappable card per locus.
Returns a list of SDUI nodes, per the `jetpacs-render-buffer' contract."
  (with-current-buffer buf
    (let* ((name (buffer-name buf))
           (loci (jetpacs-results--loci buf))
           (total (length loci))
           (shown (if (> total jetpacs-results-max-loci)
                      (cl-subseq loci 0 jetpacs-results-max-loci)
                    loci)))
      (if (null loci)
          ;; No parsed loci — the mode may be mid-run (an empty *grep*),
          ;; or nothing matched.  Fall back to the faithful Tier 0 text so
          ;; the buffer is never blank.
          (jetpacs-buffer-render buf)
        (append
         (list (jetpacs-text
                (format "%d result%s" total (if (= total 1) "" "s"))
                'caption))
         (mapcar (lambda (l) (jetpacs-results--card name (car l) (cdr l))) shown)
         (when (> total (length shown))
           (list (jetpacs-text
                  (format "Showing %d of %d — narrow the search."
                          (length shown) total)
                  'caption))))))))

(dolist (mode jetpacs-results-modes)
  (jetpacs-render-buffer-register mode #'jetpacs-results-render))

;; ─── Visiting a locus ─────────────────────────────────────────────────────────

(defun jetpacs-results--visit-command (pos)
  "The visit command for the locus at POS: text-prop keymap, else major map.
occur/compilation/xref all bind RET (and mouse-2) to their goto command;
compilation additionally carries a text-property keymap over each error."
  (let ((km (or (get-char-property pos 'keymap)
                (get-char-property pos 'local-map))))
    (or (and (keymapp km)
             (or (lookup-key km (kbd "RET"))
                 (lookup-key km [return])
                 (lookup-key km [mouse-2])))
        (let ((maj (current-local-map)))
          (and maj
               (or (lookup-key maj (kbd "RET"))
                   (lookup-key maj [return])
                   (lookup-key maj [mouse-2])))))))

(defun jetpacs-results--follow (buf pos)
  "Follow the locus at POS in results BUF; return (DEST-BUFFER . DEST-POS) or nil.
Runs the row's own goto command through `jetpacs-buffer-call-shimmed', so
nothing pops a desktop window (the user's Emacs layout is untouched) and a
stale input event cannot hijack the jump; reads where point lands.  Returns
nil when the command doesn't leave the results buffer (e.g. the target file
is gone)."
  (with-current-buffer buf
    (goto-char (min (max (point-min) pos) (point-max)))
    (let ((cmd (jetpacs-results--visit-command (point))))
      (when (commandp cmd)
        (let* ((dest (jetpacs-buffer-call-shimmed cmd))
               (dest-buf (car dest)))
          ;; A visit that never left the results buffer is a failure, not a jump.
          (and dest-buf (not (eq dest-buf buf)) dest))))))

(defun jetpacs-results--region-around (buf pos)
  "Return (BEG END LABEL POINT) framing POS in BUF for the region view.
The window runs `jetpacs-results-context-before' lines above POS and
`jetpacs-results-context-lines' past it; LABEL is \"buffer:line\"."
  (with-current-buffer buf
    (save-excursion
      (goto-char (min (max (point-min) pos) (point-max)))
      (let* ((line (line-number-at-pos))
             (target (line-beginning-position))
             (beg (save-excursion (forward-line (- jetpacs-results-context-before))
                                  (point)))
             (end (save-excursion
                    (forward-line (1+ jetpacs-results-context-lines))
                    (point))))
        (list beg end (format "%s:%d" (buffer-name buf) line) target)))))

(defun jetpacs-results--index-of (loci pos)
  "Index in LOCI of the locus at POS, or 0 if not found."
  (or (cl-position pos loci :key #'car :test #'=) 0))

(defun jetpacs-results--show (dest index count nav-extra)
  "Open DEST (a (BUFFER . POS) pair) in the buffer view; arm the stepper.
Narrows to the locus, scrolls to the line, and heads the slice with an
i/N counter; NAV-EXTRA (a plist) supplies the kind-specific step source
merged into `jetpacs-results--nav'.  Returns non-nil."
  (pcase-let ((`(,beg ,end ,label ,point)
               (jetpacs-results--region-around (car dest) (cdr dest))))
    (setq jetpacs-results--nav
          (append (list :index index :count count :dest (buffer-name (car dest)))
                  nav-extra))
    (funcall jetpacs-results-visit-region-function
             (buffer-name (car dest)) beg end
             (format "%s  ·  %d/%d" label (1+ index) count)
             point)
    t))

(defun jetpacs-results--goto-buffer (results-buf loci index)
  "Visit buffer-locus LOCI[INDEX] of RESULTS-BUF; arm a `buffer'-kind nav.
Follows via the mode's own goto command (shimmed so nothing pops a desktop
window).  INDEX is clamped into the loci range."
  (let* ((count (length loci))
         (index (max 0 (min index (1- count))))
         (pos (car (nth index loci)))
         (dest (and pos (ignore-errors (jetpacs-results--follow results-buf pos)))))
    (if (null dest)
        (progn (message "Couldn't open that location") nil)
      (jetpacs-results--show dest index count
                          (list :kind 'buffer :buffer (buffer-name results-buf))))))

(defun jetpacs-results--file-dest (locus)
  "Resolve a file LOCUS (:file :line) to (BUFFER . POS), or nil.
Visits the file read-only-safely via `find-file-noselect'; nil when the
file is gone or unreadable."
  (let ((file (plist-get locus :file))
        (line (plist-get locus :line)))
    (when (and (stringp file) (file-readable-p file))
      (condition-case nil
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (save-excursion
                (goto-char (point-min))
                (forward-line (1- (max 1 (truncate (or line 1)))))
                (cons buf (point)))))
        (error nil)))))

(defun jetpacs-results--goto-file (loci index)
  "Visit file-locus LOCI[INDEX]; arm a `file'-kind nav.  INDEX is clamped."
  (let* ((count (length loci))
         (index (max 0 (min index (1- count))))
         (dest (jetpacs-results--file-dest (nth index loci))))
    (if (null dest)
        (progn (message "Couldn't open that location") nil)
      (jetpacs-results--show dest index count (list :kind 'file :loci loci)))))

(jetpacs-defaction "results.visit"
  ;; Show a locus in context and arm the stepper.  Two entry shapes:
  ;;   (buffer NAME) (pos P) — a results-mode buffer's own goto at P; NAME
  ;;     must be one of `jetpacs-results-modes', so a name off the wire can
  ;;     only ever drive a real results buffer's own visit.
  ;;   (index I)             — entry I of the active `jetpacs-results--file-set'
  ;;     (a server-built list; no path travels over the wire).
  (lambda (args _)
    (let ((buf-name (alist-get 'buffer args))
          (pos (alist-get 'pos args))
          (index (alist-get 'index args)))
      (cond
       ((and buf-name (numberp pos))
        (let ((buf (get-buffer buf-name)))
          (if (not (jetpacs-results--buffer-p buf))
              (message "%s is not a results buffer" buf-name)
            (let ((loci (jetpacs-results--loci buf)))
              (when loci
                (jetpacs-results--goto-buffer
                 buf loci (jetpacs-results--index-of loci pos)))))))
       ((numberp index)
        (let ((set jetpacs-results--file-set))
          (if (and set (>= index 0) (< index (length set)))
              (jetpacs-results--goto-file set index)
            (message "results.visit: no such result"))))
       (t (message "results.visit: nothing to visit"))))))

(jetpacs-defaction "results.step"
  ;; Step to the prev/next locus of the armed result set without returning
  ;; to the list.  DIR is +1 or -1.  Buffer-kind loci are recomputed each
  ;; step (so a reverted results buffer still steps sanely); file-kind loci
  ;; step over the snapshot armed at visit time.
  (lambda (args _)
    (let* ((nav jetpacs-results--nav)
           (dir (alist-get 'dir args)))
      (if (not (and nav (numberp dir)))
          (message "No results to step through")
        (let ((target (+ (plist-get nav :index) dir)))
          (cl-flet ((step (loci goto)
                      (cond
                       ((null loci) (message "No results"))
                       ((< target 0) (message "First match"))
                       ((>= target (length loci)) (message "Last match"))
                       (t (funcall goto loci target)))))
            (pcase (plist-get nav :kind)
              ('buffer
               (let ((buf (get-buffer (plist-get nav :buffer))))
                 (if (not (jetpacs-results--buffer-p buf))
                     (progn (setq jetpacs-results--nav nil)
                            (message "Those results are gone"))
                   (step (jetpacs-results--loci buf)
                         (lambda (loci i) (jetpacs-results--goto-buffer buf loci i))))))
              ('file
               (step (plist-get nav :loci) #'jetpacs-results--goto-file))
              (_ (message "No results to step through")))))))))

(defun jetpacs-results--nav-live-p (nav)
  "Non-nil when the stepper NAV can still step (its source survives)."
  (pcase (plist-get nav :kind)
    ('buffer (get-buffer (plist-get nav :buffer)))
    ('file (plist-get nav :loci))
    (_ nil)))

(defun jetpacs-results-buffer-view-actions (viewed-buffer-name)
  "Prev/next-match top-bar actions for the buffer view, or nil.
Returns icon-button nodes when `jetpacs-results--nav' is armed and
VIEWED-BUFFER-NAME is the source buffer the last locus visit navigated to
\(and the result set is still live); only the in-range direction is offered
at each end.  The buffer view host calls this to add stepper chrome to the
drill-in top bar — see jetpacs-emacs-ui."
  (let ((nav jetpacs-results--nav))
    (when (and nav
               (equal viewed-buffer-name (plist-get nav :dest))
               (jetpacs-results--nav-live-p nav))
      (let ((i (plist-get nav :index)) (n (plist-get nav :count)))
        (delq nil
              (list
               (when (> i 0)
                 (jetpacs-icon-button
                  "chevron_left"
                  (jetpacs-action "results.step" :args '((dir . -1))
                               :when-offline "drop")
                  :content-description (format "Previous match (%d of %d)" i n)))
               (when (< (1+ i) n)
                 (jetpacs-icon-button
                  "chevron_right"
                  (jetpacs-action "results.step" :args '((dir . 1))
                               :when-offline "drop")
                  :content-description (format "Next match (%d of %d)"
                                              (+ i 2) n)))))))))

(provide 'jetpacs-results)
;;; jetpacs-results.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-hypertext.el
;;; ==================================================================

;;; jetpacs-hypertext.el --- Generic hypertext/document substrate (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: one document card grammar under every "rendered rich
;; document" buffer — the shr consumers (eww, elfeed-show, nov.el,
;; devdocs), plus help-mode and Info-mode.  The same bet jetpacs-tablist
;; makes on tabulated-list-mode and jetpacs-results makes on the
;; next-error protocol: ONE renderer, thin per-family adapters.
;;
;; Under the Tier 0 generic renderer these buffers already render as
;; styled text, but images fall back to placeholder text, tables to flat
;; monospace, and structure (headings, links) is linearized.  This
;; substrate lifts them to real cards: headings as section navigation,
;; paragraphs as rich_text, links as tappable spans, images as
;; `jetpacs-image', tables as native `jetpacs-table'.
;;
;; The design is two-phase, and that is what keeps the adapters thin:
;;
;;   1. An ADAPTER scans a buffer into a neutral DOCUMENT MODEL — a flat
;;      list of segment plists (heading / para / pre / quote / rule /
;;      image / table).  Each family (shr props, help buttons, Info node
;;      structure) has its own scanner; none of them touches the wire.
;;   2. The EMITTER (`jetpacs-hypertext--emit') maps the model onto the
;;      existing widget vocabulary.  It is the only place that knows the
;;      SDUI nodes, so a new adapter never re-derives them.
;;
;; This file (the substrate core) defines the model and the emitter.
;; The adapters and the mode registrations arrive in later stages; the
;; model shape is final now, so those stages only add scanners.
;;
;; Fidelity floor: an unrecognised segment degrades to a plain paragraph,
;; never dropped — worst case equals Tier 0, never worse.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dom)                 ; DOM walking for the eww table pass
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)     ; jetpacs-defaction
(require 'jetpacs-config)       ; jetpacs-root (the image cache lives under it)
(require 'jetpacs-buffer)      ; jetpacs-render-buffer-register / call-shimmed

;; Forward declarations for the optional document packages this substrate
;; reads at render time.  None is required at load: the core stays app-free
;; (test/core-load-test.el), and each render path checks these at runtime.
(defvar eww-data)
(defvar eww-history)
(defvar eww-history-position)
(defvar help-xref-stack)
(defvar help-xref-forward-stack)
(defvar help-xref-stack-item)
(defvar Info-history)
(defvar Info-history-forward)
(defvar Info-current-node)

;; ─── The document model ───────────────────────────────────────────────────────
;;
;; A model is a list of segment plists.  Every segment carries `:kind';
;; the rest of its keys depend on the kind:
;;
;;   (:kind heading :level N :text STR [:spans SPANS])
;;       A section label.  LEVEL (1-6) is preserved for the Stage-3 table
;;       of contents; inline emission ignores it (the wire section_header
;;       has one style).  TEXT is the plain label; SPANS is a fallback
;;       flattened to text.
;;   (:kind para  :spans SPANS)  | (:kind para  :text STR)
;;       A paragraph.  SPANS is a list of `jetpacs-span'; TEXT is the
;;       plain-text fallback when the adapter has no styled runs.
;;   (:kind pre   :text STR [:syntax SYM])
;;       A preformatted / code block, rendered monospace on a surface.
;;   (:kind quote :spans SPANS) | (:kind quote :text STR)
;;       A blockquote, rendered as a paragraph on a tinted surface.
;;   (:kind rule)
;;       A horizontal rule.
;;   (:kind image :url STR :alt STR :file STR :data STR :content-type SYM)
;;       An image, emitted as a real `jetpacs-image': a readable FILE as
;;       file://, an http(s) URL untouched (the device fetches), DATA (or a
;;       base64 data: URL) through the write-once content cache.  When none
;;       resolves, the ALT/URL degrades to a caption.
;;   (:kind table [:rows ROWS] [:table-id N] [:text STR])
;;       A table.  ROWS — row plists (:header BOOL :cells CELLS), each cell
;;       a string or a list of `jetpacs-span' — emits a native
;;       `jetpacs-table'.  Without rows, TEXT (the rendered region,
;;       verbatim) emits as a monospace block; TABLE-ID is the shr render
;;       counter the eww DOM pass uses to recover ROWS.

(defun jetpacs-hypertext--nonempty (s)
  "Return S when it is a non-empty string, else nil."
  (and (stringp s) (not (string-empty-p s)) s))

(defun jetpacs-hypertext--spans-text (spans)
  "Concatenate the plain text of SPANS (span alists from `jetpacs-span')."
  (mapconcat (lambda (s) (or (alist-get 'text s) "")) spans ""))

(defun jetpacs-hypertext--cell-text (cell)
  "Plain text of a table CELL (a list of spans)."
  (if (stringp cell) cell (jetpacs-hypertext--spans-text cell)))

;; ─── The image cache ─────────────────────────────────────────────────────────
;;
;; Images whose bytes exist only inside Emacs (an shr `display' descriptor's
;; :data, a data: URI) can't ride the wire — `jetpacs-image' carries a URL or a
;; readable file:// path.  They are written once into a content-addressed
;; cache under `jetpacs-root' (disposable by definition; a sync pass may drop
;; it) and emitted as file:// paths.  http(s) images are NEVER cached: the
;; device fetches them itself, which is the battery-cheapest path and always
;; current.

(defcustom jetpacs-hypertext-image-cache-max (* 20 1024 1024)
  "Byte cap for the hypertext image cache.
When a write pushes the cache past this, oldest files (by mtime) are
deleted until it fits.  The cache is content-addressed (sha1), so a
re-render re-writes at most what it still shows."
  :type 'integer :group 'jetpacs)

(defun jetpacs-hypertext--image-cache-dir ()
  "The image cache directory (not created until first write)."
  (expand-file-name "cache/hypertext-images/" jetpacs-root))

(defconst jetpacs-hypertext--image-extensions
  '((png . "png") (jpeg . "jpg") (gif . "gif") (webp . "webp")
    (svg . "svg") (bmp . "bmp") (tiff . "tiff") (xpm . "xpm"))
  "Image type symbol -> cache file extension.")

(defun jetpacs-hypertext--image-cache-sweep (dir)
  "Delete oldest-mtime files in DIR until it fits the cache cap."
  (let* ((files (directory-files dir t "\\`[^.]" t))
         (total (apply #'+ (mapcar (lambda (f)
                                     (or (file-attribute-size
                                          (file-attributes f))
                                         0))
                                   files))))
    (when (> total jetpacs-hypertext-image-cache-max)
      (dolist (f (sort files
                       (lambda (a b)
                         (time-less-p (file-attribute-modification-time
                                       (file-attributes a))
                                      (file-attribute-modification-time
                                       (file-attributes b))))))
        (when (> total jetpacs-hypertext-image-cache-max)
          (let ((size (or (file-attribute-size (file-attributes f)) 0)))
            (ignore-errors (delete-file f))
            (setq total (- total size))))))))

(defun jetpacs-hypertext--image-cache-put (data type)
  "Write image DATA (a unibyte string) into the cache; return its file path.
Content-addressed and write-once: the name is DATA's sha1 plus TYPE's
extension, and an existing file is returned untouched.  Returns nil when
the write fails (unwritable root) — the caller degrades to a placeholder."
  (condition-case nil
      (let* ((dir (jetpacs-hypertext--image-cache-dir))
             (ext (or (cdr (assq type jetpacs-hypertext--image-extensions))
                      "img"))
             (path (expand-file-name (concat (sha1 data) "." ext) dir)))
        (unless (file-exists-p path)
          (make-directory dir t)
          (let ((coding-system-for-write 'binary))
            (write-region data nil path nil 'silent))
          (jetpacs-hypertext--image-cache-sweep dir))
        path)
    (error nil)))

(defun jetpacs-hypertext-image-cache-clear ()
  "Delete every file in the hypertext image cache."
  (interactive)
  (let ((dir (jetpacs-hypertext--image-cache-dir)))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\`[^.]" t))
        (ignore-errors (delete-file f)))
      (message "Hypertext image cache cleared"))))

(defconst jetpacs-hypertext--data-uri-types
  '(("image/png" . png) ("image/jpeg" . jpeg) ("image/gif" . gif)
    ("image/webp" . webp) ("image/svg+xml" . svg) ("image/bmp" . bmp))
  "data: URI MIME type -> image type symbol.")

(defun jetpacs-hypertext--decode-data-uri (url)
  "Decode a base64 data: image URL into (DATA . TYPE), or nil."
  (when (and (stringp url)
             (string-match "\\`data:\\([^;,]+\\);base64,\\(.*\\)\\'" url))
    (let ((type (cdr (assoc (downcase (match-string 1 url))
                            jetpacs-hypertext--data-uri-types)))
          (data (ignore-errors (base64-decode-string (match-string 2 url)))))
      (and data type (cons data type)))))

;; ─── The emitter ──────────────────────────────────────────────────────────────

(defun jetpacs-hypertext--paragraph (seg)
  "A paragraph body node from SEG's :spans (preferred) or :text."
  (let ((spans (plist-get seg :spans))
        (text (plist-get seg :text)))
    (cond
     ((and spans (> (length spans) 0)) (jetpacs-rich-text spans))
     ((jetpacs-hypertext--nonempty text) (jetpacs-text text))
     (t (jetpacs-text "")))))

(defun jetpacs-hypertext--heading (seg)
  "A section_header node from heading SEG (its plain text, level aside)."
  (jetpacs-section-header
   (or (jetpacs-hypertext--nonempty (plist-get seg :text))
       (jetpacs-hypertext--nonempty
        (jetpacs-hypertext--spans-text (plist-get seg :spans)))
       "")))

(defun jetpacs-hypertext--pre (seg)
  "A preformatted/code block node from SEG on a tinted surface."
  (jetpacs-surface
   (list (jetpacs-markup (or (plist-get seg :text) "")
                         :syntax (plist-get seg :syntax)))
   :color "surface_container" :shape "rounded_small" :padding 3))

(defun jetpacs-hypertext--quote (seg)
  "A blockquote node from SEG: its paragraph body on a tinted surface."
  (jetpacs-surface
   (list (jetpacs-hypertext--paragraph seg))
   :color "surface_container" :shape "rounded_small" :padding 3))

(defun jetpacs-hypertext--image (seg)
  "A real `jetpacs-image' node from image SEG, resolved in battery order:
a readable :file passes through as file:// (nov.el extracts EPUB resources
to disk); an http(s) :url passes through untouched (the DEVICE fetches —
no Emacs I/O, always current); bytes that exist only inside Emacs (:data,
or a base64 data: URI in :url) go through the write-once content cache.
Unresolvable images degrade to an alt-text caption — never dropped."
  (let* ((alt (jetpacs-hypertext--nonempty (plist-get seg :alt)))
         (url (plist-get seg :url))
         (file (plist-get seg :file))
         (data (plist-get seg :data))
         (resolved
          (cond
           ((and file (file-readable-p file))
            (concat "file://" file))
           ((and url (string-match-p "\\`https?://" url))
            url)
           (data
            (let ((path (jetpacs-hypertext--image-cache-put
                         data (plist-get seg :content-type))))
              (and path (concat "file://" path))))
           ((jetpacs-hypertext--decode-data-uri url)
            (let* ((decoded (jetpacs-hypertext--decode-data-uri url))
                   (path (jetpacs-hypertext--image-cache-put
                          (car decoded) (cdr decoded))))
              (and path (concat "file://" path)))))))
    (if resolved
        (jetpacs-image resolved :content-description alt)
      (jetpacs-text (format "[image: %s]" (or alt url "…")) 'caption))))

(defun jetpacs-hypertext--table (seg)
  "A table node from SEG: native `jetpacs-table' when :rows were recovered
\(the eww DOM pass), else its rendered :text verbatim as a monospace block —
shr's own alignment, exactly what Tier 0 shows, never a reflow."
  (let ((rows (plist-get seg :rows)))
    (cond
     (rows
      (jetpacs-table
       (mapcar
        (lambda (row)
          (jetpacs-table-row
           (mapcar (lambda (cell)
                     (jetpacs-table-cell
                      (if (stringp cell) (list (jetpacs-span cell)) cell)))
                   (plist-get row :cells))
           :header (and (plist-get row :header) t)))
        rows)))
     ((jetpacs-hypertext--nonempty (plist-get seg :text))
      (jetpacs-hypertext--pre (list :text (plist-get seg :text))))
     (t (jetpacs-text "")))))

(defun jetpacs-hypertext--emit-segment (seg)
  "Map one document SEG (a segment plist) to an SDUI node.
An unrecognised kind degrades to a plain paragraph — never dropped."
  (pcase (plist-get seg :kind)
    ('heading (jetpacs-hypertext--heading seg))
    ('para    (jetpacs-hypertext--paragraph seg))
    ('pre     (jetpacs-hypertext--pre seg))
    ('quote   (jetpacs-hypertext--quote seg))
    ('rule    (jetpacs-divider))
    ('image   (jetpacs-hypertext--image seg))
    ('table   (jetpacs-hypertext--table seg))
    (_        (jetpacs-hypertext--paragraph seg))))

(defun jetpacs-hypertext--emit (model &optional title)
  "Emit document MODEL (a list of segment plists) as a list of SDUI nodes.
TITLE, when a non-empty string, leads with a title text node.  This is
the single place that knows the wire vocabulary; adapters build MODEL and
never touch nodes."
  (append
   (when (jetpacs-hypertext--nonempty title)
     (list (jetpacs-text title 'title)))
   (mapcar #'jetpacs-hypertext--emit-segment model)))

;; ─── shr props contract (the drift firewall) ─────────────────────────────────
;;
;; Everything this file knows about shr's *rendered-buffer* markup lives in
;; this section, so an shr change across Emacs versions is a one-spot edit.
;; Links and inline emphasis are NOT read here — they ride the Tier 0
;; line-span builder (`jetpacs-buffer--line-spans'), which already turns shr's
;; mouse-face/keymap link runs into `jetpacs.buffer.act' taps and maps face
;; emphasis to span styling.  Only block structure is shr-specific.

(defconst jetpacs-hypertext--shr-heading-faces
  '((shr-h1 . 1) (shr-h2 . 2) (shr-h3 . 3)
    (shr-h4 . 4) (shr-h5 . 5) (shr-h6 . 6))
  "shr heading faces mapped to their level (1-6).")

(defun jetpacs-hypertext--face-list (pos)
  "The `face'/`font-lock-face' value at POS as a list of refs (nil-safe)."
  (let ((f (or (get-text-property pos 'face)
               (get-text-property pos 'font-lock-face))))
    (cond ((null f) nil)
          ((and (consp f) (keywordp (car f))) (list f)) ; a single plist
          ((listp f) f)
          (t (list f)))))

(defun jetpacs-hypertext--collapse-ws (s)
  "Collapse whitespace runs in S (a heading rendered across wrapped lines)
to single spaces, and trim — so a filled multi-line heading reads as one
label."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " s)))

(defun jetpacs-hypertext--shr-placeholder-image-p (type data)
  "Non-nil when TYPE/DATA is shr's not-yet-fetched placeholder rectangle.
In batch or before a fetch completes, `shr-put-image' displays a generated
gray-gradient SVG; caching that would show gray boxes instead of images, so
the resolver treats it as no data at all."
  (and (eq type 'svg)
       (stringp data)
       (string-match-p "url(#background)" data)))

(defun jetpacs-hypertext--shr-image-at (pos)
  "An image segment plist for the shr image run at POS, or nil.
Reads shr's rendered-buffer markup: the `image-url' property (the real
source URL), `shr-alt' (the alt text), and the `display' image descriptor's
:file / :data / :type — with the placeholder rectangle discarded."
  (let* ((url (get-text-property pos 'image-url))
         (alt (get-text-property pos 'shr-alt))
         (disp (get-text-property pos 'display))
         (desc (and (eq (car-safe disp) 'image) (cdr disp)))
         (type (plist-get desc :type))
         (file (plist-get desc :file))
         (data (plist-get desc :data)))
    (when (jetpacs-hypertext--shr-placeholder-image-p type data)
      (setq data nil type nil))
    (when (or url alt desc)
      (list :kind 'image
            :url (jetpacs-hypertext--nonempty url)
            :alt (jetpacs-hypertext--nonempty alt)
            :file (jetpacs-hypertext--nonempty file)
            :data (and (stringp data) (not (string-empty-p data)) data)
            :content-type type))))

(defun jetpacs-hypertext--image-run-p (pos)
  "Non-nil when POS is inside an shr image run."
  (or (get-text-property pos 'image-url)
      (get-text-property pos 'shr-alt)
      (eq (car-safe (get-text-property pos 'display)) 'image)))

(defun jetpacs-hypertext--block-table-id (beg end)
  "The `shr-table-id' of the rendered table block [BEG, END), or nil.
shr stamps the table's start with `shr-table-id' (a per-render counter), the
key the eww DOM pass uses to pair a rendered region with its <table>."
  (let ((pos beg) id)
    (while (and (< pos end) (not id))
      (setq id (get-text-property pos 'shr-table-id)
            pos (or (next-single-property-change pos 'shr-table-id nil end)
                    end)))
    id))

(defun jetpacs-hypertext--table-block-p (beg end)
  "Non-nil when the block [BEG, END) is an shr-rendered table region."
  (or (jetpacs-hypertext--block-table-id beg end)
      (let ((pos beg) found)
        (while (and (< pos end) (not found))
          (setq found (get-text-property pos 'shr-table-indent)
                pos (or (next-single-property-change
                         pos 'shr-table-indent nil end)
                        end)))
        found)))

(defun jetpacs-hypertext--block-images (beg end)
  "Image segments when block [BEG, END) is image-only, else nil.
Walks the block's property runs collecting shr image runs; any non-image,
non-whitespace text makes this nil — a mixed block stays a paragraph whose
inline images degrade to their alt text (the fidelity floor)."
  (let ((pos beg) images stray)
    (while (and (< pos end) (not stray))
      (let ((next (or (next-property-change pos nil end) end)))
        (if (jetpacs-hypertext--image-run-p pos)
            (let ((seg (jetpacs-hypertext--shr-image-at pos)))
              ;; One image's alt text may split into several property runs
              ;; (help-echo boundaries, fill) — collapse consecutive equals.
              (when (and seg (not (equal seg (car images))))
                (push seg images)))
          (unless (string-blank-p (buffer-substring-no-properties pos next))
            (setq stray t)))
        (setq pos next)))
    (and (not stray) (nreverse images))))

(defun jetpacs-hypertext--heading-level-at (pos)
  "Heading level 1-6 if POS is faced as an shr heading, else nil."
  (cl-some (lambda (f)
             (and (symbolp f)
                  (cdr (assq f jetpacs-hypertext--shr-heading-faces))))
           (jetpacs-hypertext--face-list pos)))

;; ─── Adapter: shr-rendered buffers (eww, and every shr consumer) ─────────────
;;
;; shr separates block elements with a blank line, so the model is recovered
;; block by block: a block faced as an shr heading becomes a heading segment;
;; everything else becomes a paragraph whose spans (links + emphasis) come
;; from the Tier 0 line-span builder, reflowed across the block's lines.
;; Images and native tables are resolved in Stage 4; until then an image's
;; alt text and a table's cells degrade into paragraph prose (the fidelity
;; floor — never below Tier 0).

(defun jetpacs-hypertext--block-end (limit)
  "End of the block whose first line starts at point: the last non-blank
line's end before a blank line or LIMIT.  Point is at a non-blank line's
beginning; the buffer is not moved."
  (save-excursion
    (let ((end (min (line-end-position) limit)))
      (while (and (< (line-end-position) limit)
                  (zerop (forward-line 1))
                  (< (point) limit)
                  (not (looking-at-p "[ \t]*$")))
        (setq end (min (line-end-position) limit)))
      end)))

(defun jetpacs-hypertext--block-heading-level (beg end)
  "Heading level if any run in [BEG, END) is faced as an shr heading."
  (let ((pos beg) lvl)
    (while (and (< pos end) (not lvl))
      (setq lvl (jetpacs-hypertext--heading-level-at pos)
            pos (next-single-property-change pos 'face nil end)))
    lvl))

(defun jetpacs-hypertext--block-spans (beg end buffer-name)
  "Spans for paragraph block [BEG, END), reflowed across its lines.
Reuses `jetpacs-buffer--line-spans' with monospace and color emission off
\(eww prose is proportional and themed by the device), so shr links become
`jetpacs.buffer.act' taps and face emphasis maps to span styling for free;
non-empty lines are joined by a space so the paragraph reflows."
  (let ((jetpacs-buffer-monospace nil)
        (jetpacs-buffer-emit-colors nil)
        chunks)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((line (jetpacs-buffer--line-spans
                     (line-beginning-position)
                     (min (line-end-position) end)
                     buffer-name)))
          (when line (push line chunks)))
        (forward-line 1)))
    (setq chunks (nreverse chunks))
    (apply #'append
           (cl-loop for chunk in chunks
                    for i from 0
                    collect (if (zerop i) chunk
                              (cons (jetpacs-span " ") chunk))))))

(defun jetpacs-hypertext--skip-inter-block (limit)
  "Advance point over inter-block blank space up to LIMIT, stopping at an
shr image run.  On an Emacs built without SVG support, `shr-tag-img'
renders an image as a lone space rather than a placeholder glyph carrying
its alt text; that space is meaningful markup, not inter-block whitespace,
so the block scan must not skip it — otherwise the image is dropped below
the Tier-0 fidelity floor instead of degrading to its URL/alt caption."
  (while (and (< (point) limit)
              (memq (char-after) '(?\s ?\t ?\n))
              (not (jetpacs-hypertext--image-run-p (point))))
    (forward-char 1)))

(defun jetpacs-hypertext--scan-shr (buf)
  "Scan shr-rendered BUF into a document model (heading + paragraph segments)."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let ((name (buffer-name buf)) (limit (point-max)) segments)
        (while (< (point) limit)
          (jetpacs-hypertext--skip-inter-block limit)
          (when (< (point) limit)
            (let* ((beg (line-beginning-position))
                   (end (jetpacs-hypertext--block-end limit))
                   (level nil) (images nil))
              (cond
               ;; A rendered table region: keep its lines verbatim as the
               ;; monospace fallback; the eww DOM pass may upgrade it to
               ;; native rows via its shr-table-id.  A table block with no id
               ;; of its own continues the previous table (shr stamps the id
               ;; once, at the table's start; a blank row splits the region).
               ((jetpacs-hypertext--table-block-p beg end)
                (let ((id (jetpacs-hypertext--block-table-id beg end))
                      (text (buffer-substring-no-properties beg end))
                      (prev (car segments)))
                  (if (and (null id) prev
                           (eq (plist-get prev :kind) 'table))
                      (setcar segments
                              (plist-put (copy-sequence prev) :text
                                         (concat (plist-get prev :text)
                                                 "\n" text)))
                    (push (list :kind 'table :table-id id :text text)
                          segments))))
               ;; An image-only block: one segment per image.
               ((setq images (jetpacs-hypertext--block-images beg end))
                (dolist (img images) (push img segments)))
               ((setq level (jetpacs-hypertext--block-heading-level beg end))
                (push (list :kind 'heading :level level
                            :text (jetpacs-hypertext--collapse-ws
                                   (buffer-substring-no-properties beg end)))
                      segments))
               (t
                (let ((spans (jetpacs-hypertext--block-spans beg end name)))
                  (when spans
                    (push (list :kind 'para :spans spans) segments)))))
              (goto-char end))))
        (nreverse segments)))))

(defun jetpacs-hypertext--eww-title (buf)
  "The document title for BUF from `eww-data', or nil."
  (with-current-buffer buf
    (and (boundp 'eww-data) eww-data
         (jetpacs-hypertext--nonempty (plist-get eww-data :title)))))

;; ─── The eww DOM table pass ──────────────────────────────────────────────────
;;
;; shr renders a <table> as aligned monospace text; the real structure is
;; only in the HTML.  eww keeps that HTML (`eww-data' :source), so table
;; segments are upgraded to native rows by re-parsing it and pairing each
;; rendered region's `shr-table-id' with the document-order <table> list.
;; Anything ambiguous — nested tables (render order diverges from document
;; order), ragged rows (colspans), oversize — stays the monospace fallback:
;; exactly what Tier 0 shows today, never a wrong table.

(defcustom jetpacs-hypertext-table-max-rows 100
  "Row cap for native table recovery.
A <table> with more rows than this keeps its monospace rendering (a phone
table this size wants a purpose-built view, not a widget)."
  :type 'integer :group 'jetpacs)

(defun jetpacs-hypertext--dom-table-rows (table)
  "Row plists from DOM TABLE node, or nil when irregular.
Rows are the <tr>s in document order; a row's cells are its <th>/<td>
children flattened to text; a row containing a <th> is a header row.
Ragged tables (colspan/rowspan artifacts) and oversize tables return nil —
the caller keeps the monospace fallback."
  (let* ((trs (dom-by-tag table 'tr))
         (rows
          (mapcar
           (lambda (tr)
             (let ((cells (seq-filter
                           (lambda (c) (memq (dom-tag c) '(th td)))
                           (dom-non-text-children tr))))
               (list :header (and (seq-find (lambda (c) (eq (dom-tag c) 'th))
                                            cells)
                                  t)
                     :cells (mapcar
                             (lambda (c)
                               (jetpacs-hypertext--collapse-ws (dom-texts c "")))
                             cells))))
           trs))
         (widths (delete-dups (mapcar (lambda (r) (length (plist-get r :cells)))
                                      rows))))
    (and rows
         (<= (length rows) jetpacs-hypertext-table-max-rows)
         (= (length widths) 1)              ; every row the same cell count
         (> (car widths) 0)
         rows)))

(defun jetpacs-hypertext--eww-resolve-tables (model buf)
  "Upgrade MODEL's table segments with native rows from BUF's eww source.
Returns MODEL (segments upgraded where recovery is unambiguous).  Requires
libxml (positive knowledge — the probe, not the version) and the page
source in `eww-data'; a document containing nested tables is left entirely
alone, since shr's table-id render order diverges from document order there."
  (let ((source (with-current-buffer buf
                  (and (boundp 'eww-data) eww-data
                       (plist-get eww-data :source)))))
    (if (not (and (cl-some (lambda (s) (and (eq (plist-get s :kind) 'table)
                                            (plist-get s :table-id)))
                           model)
                  (jetpacs-feature-p 'libxml)
                  (stringp source)))
        model
      (let* ((dom (with-temp-buffer
                    (insert source)
                    (libxml-parse-html-region (point-min) (point-max))))
             (tables (and dom (dom-by-tag dom 'table))))
        (if (or (null tables)
                (cl-some (lambda (tbl) (> (length (dom-by-tag tbl 'table)) 1))
                         tables))
            model
          (mapcar
           (lambda (seg)
             (let* ((id (and (eq (plist-get seg :kind) 'table)
                             (plist-get seg :table-id)))
                    (table (and (integerp id) (> id 0) (nth (1- id) tables)))
                    (rows (and table (jetpacs-hypertext--dom-table-rows table))))
               (if rows
                   (plist-put (copy-sequence seg) :rows rows)
                 seg)))
           model))))))

(defun jetpacs-hypertext-render (buf)
  "Tier 0.5 renderer for shr-rendered document buffers (registered for eww).
Falls back to the Tier 0 generic renderer for an empty or still-loading
buffer, or one shr left no recoverable structure in — the results-substrate
precedent."
  (with-current-buffer buf
    (if (< (buffer-size) 1)
        (jetpacs-buffer-render buf)
      (let ((model (jetpacs-hypertext--scan-shr buf)))
        (if model
            (jetpacs-hypertext--render-document
             buf (jetpacs-hypertext--eww-resolve-tables model buf)
             (jetpacs-hypertext--eww-title buf))
          (jetpacs-buffer-render buf))))))

;; ─── Document navigation (the nav toolbar + hypertext.nav action) ────────────
;;
;; A rendered document navigates by running the mode's OWN commands (eww/help
;; history, Info node motion) — never a command named on the wire.  The wire
;; carries only an op symbol; the op->command allowlist and the mode gate live
;; here, exactly like `results.visit'.

(defconst jetpacs-hypertext--nav-ops
  '((eww-mode  (back . eww-back-url) (forward . eww-forward-url)
               (reload . eww-reload))
    (help-mode (back . help-go-back) (forward . help-go-forward))
    (Info-mode (prev . Info-prev) (next . Info-next) (up . Info-up)
               (toc . Info-toc)
               (back . Info-history-back) (forward . Info-history-forward)))
  "Per-mode document-nav op -> the mode's own command.
The op symbol is all the wire carries; the command is resolved here, so no
command name ever travels over the wire.")

(defconst jetpacs-hypertext--nav-icons
  '((back    . ("arrow_back"    . "Back"))
    (forward . ("arrow_forward" . "Forward"))
    (reload  . ("refresh"       . "Reload"))
    (prev    . ("chevron_left"  . "Previous"))
    (next    . ("chevron_right" . "Next"))
    (up      . ("arrow_upward"  . "Up"))
    (toc     . ("toc"           . "Contents")))
  "Nav op -> (ICON . LABEL) for the toolbar.")

(defun jetpacs-hypertext--nav-mode (&optional buffer)
  "The `jetpacs-hypertext--nav-ops' mode key BUFFER derives from, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (cl-some (lambda (cell) (and (derived-mode-p (car cell)) (car cell)))
             jetpacs-hypertext--nav-ops)))

(defun jetpacs-hypertext--nav-command (mode op)
  "The command for nav OP (a symbol) in MODE, or nil if not allowlisted."
  (cdr (assq op (cdr (assq mode jetpacs-hypertext--nav-ops)))))

(defun jetpacs-hypertext--nav-live-ops (mode)
  "The live nav ops for MODE in the current buffer, in display order.
Liveness is exact where cheap (the history stacks); Info node motion
\(prev/next/up/toc) is always offered — the command self-messages at a node
boundary and the shim swallows it."
  (pcase mode
    ('eww-mode
     (append
      (and (bound-and-true-p eww-history)
           (< eww-history-position (length eww-history)) '(back))
      (and (boundp 'eww-history-position)
           (> eww-history-position 1) '(forward))
      '(reload)))
    ('help-mode
     (append (and (bound-and-true-p help-xref-stack) '(back))
             (and (bound-and-true-p help-xref-forward-stack) '(forward))))
    ('Info-mode
     (append '(prev next up toc)
             (and (bound-and-true-p Info-history) '(back))
             (and (bound-and-true-p Info-history-forward) '(forward))))
    (_ nil)))

(defun jetpacs-hypertext--nav-toolbar (buffer-name mode)
  "An icon-button row of the live nav ops for MODE in the current buffer,
or nil when there are none."
  (let ((ops (jetpacs-hypertext--nav-live-ops mode)))
    (when ops
      (apply #'jetpacs-row
             (append
              (mapcar
               (lambda (op)
                 (let ((ico (cdr (assq op jetpacs-hypertext--nav-icons))))
                   (jetpacs-icon-button
                    (car ico)
                    (jetpacs-action "hypertext.nav"
                                 :args `((buffer . ,buffer-name)
                                         (op . ,(symbol-name op))))
                    :content-description (cdr ico))))
               ops)
              (list :spacing 4))))))

(jetpacs-defaction "hypertext.nav"
  ;; Navigate a rendered document buffer by running its mode's OWN command.
  ;; BUFFER must derive from a registered document mode and OP must be in
  ;; that mode's allowlist, so a name off the wire can only ever drive a
  ;; real document buffer's own navigation (the `results.visit' contract).
  (lambda (args _)
    (let* ((buffer (alist-get 'buffer args))
           (op (alist-get 'op args))
           (buf (and (stringp buffer) (get-buffer buffer))))
      (when (and buf (stringp op))
        (with-current-buffer buf
          (let* ((mode (jetpacs-hypertext--nav-mode buf))
                 (cmd (and mode (jetpacs-hypertext--nav-command
                                 mode (intern-soft op)))))
            (if (commandp cmd)
                (jetpacs-buffer-call-shimmed cmd)
              (message "hypertext.nav: %s not available here" op))))
        (when (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function))))))

(defun jetpacs-hypertext--render-document (buf segments title)
  "Assemble a rendered document for BUF: the nav toolbar (if any) atop the
emitted SEGMENTS, led by TITLE.  Runs in BUF for buffer-local nav state."
  (with-current-buffer buf
    (let* ((mode (jetpacs-hypertext--nav-mode buf))
           (toolbar (and mode (jetpacs-hypertext--nav-toolbar
                               (buffer-name buf) mode))))
      (append (and toolbar (list toolbar))
              (jetpacs-hypertext--emit segments title)))))

;; ─── Generic line scanner (for the non-shr text families) ────────────────────
;;
;; help and Info are not shr buffers; their structure is line-oriented and
;; alignment-bearing (argument lists, menus), so — unlike the shr adapter's
;; block reflow — each non-blank line becomes its own paragraph, preserving
;; layout.  Links and buttons (help xrefs, Info menu entries and *note refs)
;; ride the Tier 0 line-span builder into `jetpacs.buffer.act' taps for free.

(defun jetpacs-hypertext--scan-lines (buf &optional classify)
  "Scan BUF into a model, one segment per non-blank line (layout preserved).
CLASSIFY, if non-nil, is called with (BEG END) at each non-blank line and
returns a heading level (integer) to make that line a heading, the symbol
`skip' to drop it (e.g. an Info underline rule), or nil for a paragraph."
  (with-current-buffer buf
    (let ((jetpacs-buffer-emit-colors nil)   ; document text is theme-coloured
          (name (buffer-name buf))
          segments)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((bol (line-beginning-position))
                (eol (line-end-position)))
            (unless (>= bol eol)              ; blank line
              (let ((class (and classify (funcall classify bol eol))))
                (cond
                 ((eq class 'skip))
                 ((integerp class)
                  (push (list :kind 'heading :level class
                              :text (jetpacs-hypertext--collapse-ws
                                     (buffer-substring-no-properties bol eol)))
                        segments))
                 (t
                  (let ((spans (jetpacs-buffer--line-spans bol eol name)))
                    (when spans
                      (push (list :kind 'para :spans spans) segments))))))))
          (forward-line 1)))
      (nreverse segments))))

;; ─── Adapter: help-mode ──────────────────────────────────────────────────────

(defun jetpacs-hypertext--help-title (buf)
  "A title for help BUF from `help-xref-stack-item' (the current subject)."
  (with-current-buffer buf
    (and (boundp 'help-xref-stack-item)
         (consp help-xref-stack-item)
         (jetpacs-hypertext--nonempty
          (format "%s" (cadr help-xref-stack-item))))))

(defun jetpacs-hypertext-render-help (buf)
  "Tier 0.5 renderer for help-mode: a nav toolbar and the help subject over
the help text, whose xref buttons are tappable through the Tier 0 line-span
builder."
  (with-current-buffer buf
    (if (< (buffer-size) 1)
        (jetpacs-buffer-render buf)
      (jetpacs-hypertext--render-document
       buf (jetpacs-hypertext--scan-lines buf)
       (jetpacs-hypertext--help-title buf)))))

;; ─── Adapter: Info-mode ──────────────────────────────────────────────────────

(defun jetpacs-hypertext--info-underlined-level (eol)
  "Heading level if the line ending at EOL is underlined by a rule line just
below it (Info section headings): * chapter = 1, = section = 2, - sub = 3."
  (save-excursion
    (goto-char eol)
    (when (zerop (forward-line 1))
      (let ((u (string-trim (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position)))))
        (cond ((string-match-p "\\`\\*\\{2,\\}\\'" u) 1)
              ((string-match-p "\\`=\\{2,\\}\\'" u) 2)
              ((string-match-p "\\`-\\{2,\\}\\'" u) 3))))))

(defun jetpacs-hypertext--info-line-class (beg end)
  "Classify an Info line [BEG, END): a heading level, `skip', or nil."
  (let ((text (string-trim (buffer-substring-no-properties beg end))))
    (if (string-match-p "\\`\\(=\\{2,\\}\\|-\\{2,\\}\\|\\*\\{2,\\}\\)\\'" text)
        'skip                               ; a bare underline rule — drop it
      (jetpacs-hypertext--info-underlined-level end))))

(defun jetpacs-hypertext--info-title (buf)
  "A title for Info BUF: its current node name (breadcrumb)."
  (with-current-buffer buf
    (and (boundp 'Info-current-node)
         (jetpacs-hypertext--nonempty (format "%s" Info-current-node)))))

(defun jetpacs-hypertext-render-info (buf)
  "Tier 0.5 renderer for Info-mode: a nav toolbar and the node name over the
node body, with menu entries and cross-references tappable via the Tier 0
line-span builder and === / --- underlined headings lifted to sections."
  (with-current-buffer buf
    (if (< (buffer-size) 1)
        (jetpacs-buffer-render buf)
      (jetpacs-hypertext--render-document
       buf (jetpacs-hypertext--scan-lines
            buf #'jetpacs-hypertext--info-line-class)
       (jetpacs-hypertext--info-title buf)))))

;; ─── Registrations & third-party riders ─────────────────────────────────────

(defun jetpacs-hypertext-register-shr-mode (mode)
  "Register MODE (a major-mode symbol) to render as a hypertext document.
The one-line rider seam for any package whose buffers are shr-rendered
HTML — feed readers, EPUB readers, doc browsers:

  (with-eval-after-load \\='elfeed-show
    (jetpacs-hypertext-register-shr-mode \\='elfeed-show-mode))

Register each concrete mode, never `special-mode' itself: dispatch is by
`derived-mode-p', and half of Emacs derives from special-mode."
  (when (memq mode '(special-mode fundamental-mode text-mode))
    (error "Register the package's own mode, not %s (dispatch is derived-mode-p)"
           mode))
  (jetpacs-render-buffer-register mode #'jetpacs-hypertext-render))

;; eww, help, and Info are built-ins this foundation may name directly.
(jetpacs-render-buffer-register 'eww-mode #'jetpacs-hypertext-render)
(jetpacs-render-buffer-register 'help-mode #'jetpacs-hypertext-render-help)
(jetpacs-render-buffer-register 'Info-mode #'jetpacs-hypertext-render-info)

;; The known third-party shr consumers ride as soon as they load; none is
;; ever required from here (the core stays app-free — test/core-load-test.el
;; proves it).
(with-eval-after-load 'elfeed-show
  (jetpacs-hypertext-register-shr-mode 'elfeed-show-mode))
(with-eval-after-load 'nov
  (jetpacs-hypertext-register-shr-mode 'nov-mode))
(with-eval-after-load 'devdocs
  (jetpacs-hypertext-register-shr-mode 'devdocs-mode))

(provide 'jetpacs-hypertext)
;;; jetpacs-hypertext.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-sections.el
;;; ==================================================================

;;; jetpacs-sections.el --- Generic magit-section substrate (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: one renderer for every buffer built on the magit-section
;; library — magit status/log/diff/refs, forge topics, kubernetes.el, and
;; every `taxy-magit-section' consumer (ement's room list, org-ql views).
;; The same bet jetpacs-tablist makes on tabulated-list-mode and
;; jetpacs-hypertext makes on shr: ONE renderer per framework, and every
;; package built on it arrives pre-skinned.
;;
;; Under Tier 0 these buffers already render acceptably (sections fold and
;; tap).  What this substrate adds: the section TREE becomes real
;; `jetpacs-collapsible' cards — folding is instant and client-side, no
;; round-trip — with Emacs's own fold state mirrored at render time, and a
;; long-press on any section header opens a context menu of that section's
;; OWN key bindings (stage this hunk, discard, visit …) served through the
;; bridged `completing-read', so the phone gets magit's per-section verbs
;; without one command name ever crossing the wire (the `keymap.run'
;; contract: the wire carries keys and positions; the buffer's own keymaps
;; decide what they mean).
;;
;; The library is third-party (NonGNU ELPA): nothing here requires it.
;; Reading the tree uses `slot-value' (eieio is built-in) on the buffer's
;; `magit-root-section', and registration waits for the library via
;; `with-eval-after-load'.  Registering `magit-section-mode' covers every
;; derived mode through the dispatch's `derived-mode-p' walk.
;;
;; Body lines ride the Tier 0 line-span builder unchanged (monospace and
;; colors on — diffs keep their +/- shading, taps keep working), so this
;; file knows only the tree shape.  Buffers whose root section is missing
;; fall through to the Tier 0 renderer — the substrate is pure polish,
;; never a prerequisite.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eieio)                ; slot-value on section objects (built-in)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)      ; jetpacs-defaction / jetpacs-action
(require 'jetpacs-buffer)       ; line spans, dispatch registry, refresh seam
(require 'jetpacs-results)      ; the region-view seam + RET resolution

;; The magit-section library, never required from core:
(declare-function magit-section-ident "ext:magit-section" (section))
(defvar magit-root-section)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-sections-max-lines 500
  "Total body-line budget for one rendered section buffer.
A huge magit diff can't produce an unbounded surface: past the budget,
remaining sections still render their headers (the tree stays navigable)
but bodies are elided with a note.  Same spirit as `jetpacs-buffer-max-lines'."
  :type 'integer :group 'jetpacs)

(defconst jetpacs-sections--menu-denylist
  '(self-insert-command digit-argument negative-argument universal-argument
    undefined ignore keyboard-quit keyboard-escape-quit
    mouse-drag-region mouse-set-point mouse-set-region
    magit-mouse-toggle-section)
  "Commands never offered in the section context menu.")

;; ─── Reading the tree ───────────────────────────────────────────────────────

(defun jetpacs-sections--root ()
  "The current buffer's magit-section root, or nil (not a section buffer)."
  (and (featurep 'magit-section)
       (bound-and-true-p magit-root-section)))

(defun jetpacs-sections--pos (sec slot)
  "Marker SLOT of section SEC as a position, or nil."
  (let ((m (slot-value sec slot)))
    (and (markerp m) (marker-position m))))

(defun jetpacs-sections--slot (sec slot)
  "SLOT of section SEC.
The slot name crosses a function boundary deliberately: the magit-section
class is never loaded at compile time, and some slot names (`hidden',
`washer') are declared by no compile-time class — a constant name at the
call site draws an unknown-slot warning."
  (slot-value sec slot))

(defun jetpacs-sections--hidden-p (sec)
  "Whether SEC is folded in Emacs."
  (jetpacs-sections--slot sec 'hidden))

(defun jetpacs-sections--id (sec)
  "A stable collapsible id for SEC: its ident path, hashed.
`magit-section-ident' is the library's own stable identity (it survives a
refresh, which is what keeps client-side fold state attached to the same
section).  Falls back to the start position when the ident isn't
printable (exotic value slots)."
  (or (condition-case nil
          (md5 (format "%S" (magit-section-ident sec)))
        (error nil))
      (format "sec@%s" (jetpacs-sections--pos sec 'start))))

;; ─── Emitting nodes ─────────────────────────────────────────────────────────

(defun jetpacs-sections--strip-taps (spans)
  "Copies of SPANS without their tap actions (for collapsible headers,
where a tap must mean fold/unfold, not the span's own action)."
  (mapcar (lambda (sp) (assq-delete-all 'on_tap (copy-alist sp))) spans))

(defun jetpacs-sections--header-node (sec name)
  "The always-visible header node for SEC: its heading line's own spans
\(faces intact — branch colors, file names), taps stripped."
  (let* ((start (jetpacs-sections--pos sec 'start))
         (spans (save-excursion
                  (goto-char start)
                  (jetpacs-buffer--line-spans start (line-end-position) name))))
    (jetpacs-rich-text (or (jetpacs-sections--strip-taps spans)
                        (list (jetpacs-span " "))))))

(defun jetpacs-sections--retarget-taps (spans)
  "SPANS with their generic tap actions re-pointed at `sections.visit'.
The Tier 0 line-span builder wires taps to `jetpacs.buffer.act', which
runs the RET command in place — in a magit buffer that command visits a
thing by popping a desktop window the phone never sees.  `sections.visit'
runs the same command under the follow shim and shows the destination in
the phone's region view instead.  Fold-affordance taps and spans without
taps pass through untouched."
  (mapcar
   (lambda (sp)
     (let ((tap (alist-get 'on_tap sp)))
       (if (not (equal (alist-get 'action tap) "jetpacs.buffer.act"))
           sp
         (let ((copy (copy-alist sp)))
           (setf (alist-get 'on_tap copy)
                 (jetpacs-action "sections.visit"
                              :args (alist-get 'args tap)))
           copy))))
   spans))

(defun jetpacs-sections--body-lines (beg end name budget)
  "Body lines [BEG, END) as rich_text nodes, consuming BUDGET (a cons cell).
Taps are visit-routed (see `jetpacs-sections--retarget-taps').  Once the
budget is spent, emits one elision note and stops."
  (let (nodes)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((bol (line-beginning-position))
              (eol (min (line-end-position) end)))
          (cond
           ((<= (car budget) 0)
            (push (jetpacs-text
                   (format "… %d more line(s) in Emacs"
                           (count-lines (point) end))
                   'caption)
                  nodes)
            (goto-char end))
           (t
            (when (< bol eol)
              (let ((spans (jetpacs-buffer--line-spans bol eol name)))
                (when spans
                  (push (jetpacs-rich-text
                         (jetpacs-sections--retarget-taps spans))
                        nodes))))
            (cl-decf (car budget))
            (forward-line 1))))))
    (nreverse nodes)))

(defun jetpacs-sections--child-nodes (sec name budget begin)
  "SEC's revealed content from BEGIN to its end: own body lines interleaved
with child sections, in buffer order."
  (let ((end (or (jetpacs-sections--pos sec 'end) begin))
        (pos begin)
        nodes)
    (dolist (child (slot-value sec 'children))
      (let ((cstart (jetpacs-sections--pos child 'start))
            (cend (jetpacs-sections--pos child 'end)))
        (when (and cstart (> cstart pos))
          (setq nodes (nconc nodes (jetpacs-sections--body-lines
                                    pos cstart name budget))))
        (setq nodes (nconc nodes (jetpacs-sections--emit child name budget)))
        (setq pos (or cend pos))))
    (when (< pos end)
      (setq nodes (nconc nodes (jetpacs-sections--body-lines
                                pos end name budget))))
    nodes))

(defun jetpacs-sections--emit (sec name budget)
  "Section SEC as a list of nodes.
A section with a heading and content becomes a collapsible card (fold
state mirroring Emacs's, long-press opening the section menu); a bare
heading becomes its line, taps intact; a heading-less container is
transparent — only its children show."
  (let* ((start (jetpacs-sections--pos sec 'start))
         (content (jetpacs-sections--pos sec 'content))
         (end (jetpacs-sections--pos sec 'end))
         (children (slot-value sec 'children)))
    (cond
     ;; Heading + revealed content → a collapsible card.
     ((and content (< content end))
      (list (jetpacs-collapsible
             (jetpacs-sections--id sec)
             (jetpacs-sections--header-node sec name)
             (jetpacs-sections--child-nodes sec name budget content)
             :collapsed (and (jetpacs-sections--hidden-p sec) t)
             :on-long-tap (jetpacs-action "sections.menu"
                                       :args `((buffer . ,name)
                                               (pos . ,start))))))
     ;; Unwashed lazy section: content == end with a washer pending.  A
     ;; card whose stub child runs the buffer's own fold toggle — showing
     ;; the section washes it in Emacs, and the refresh re-push renders
     ;; the real body.
     ((and content (jetpacs-sections--slot sec 'washer))
      (list (jetpacs-collapsible
             (jetpacs-sections--id sec)
             (jetpacs-sections--header-node sec name)
             (list (jetpacs-rich-text
                    (list (jetpacs-span
                           "Tap to load…"
                           :on-tap (jetpacs-action
                                    "jetpacs.buffer.fold"
                                    :args `((buffer . ,name)
                                            (pos . ,start)))))))
             :collapsed nil
             :on-long-tap (jetpacs-action "sections.menu"
                                       :args `((buffer . ,name)
                                               (pos . ,start))))))
     ;; Empty section (content == end, nothing pending) → its heading
     ;; line, taps intact.
     (content
      (jetpacs-sections--body-lines start end name budget))
     ;; Heading-less container (the root's shape) → children only.
     ((and (null content) children)
      (jetpacs-sections--child-nodes sec name budget start))
     ;; A bare heading (one-line info section) → its line, taps intact.
     (t
      (jetpacs-sections--body-lines start end name budget)))))

(defun jetpacs-sections-render (buf)
  "Tier 0.5 renderer for magit-section buffers: the section tree as
collapsible cards.  Falls through to the Tier 0 renderer when the buffer
has no section root (still populating, or not really a section buffer)."
  (with-current-buffer buf
    (let ((root (jetpacs-sections--root)))
      (if (or (null root) (< (buffer-size) 1))
          (jetpacs-buffer-render buf)
        ;; The scanner must see the whole tree, including bodies Emacs has
        ;; folded away (`hidden' mirrors into :collapsed instead) — an
        ;; invisibility-spec of nil makes `invisible' props inert for the
        ;; duration of the walk without touching buffer state.
        (let ((buffer-invisibility-spec nil)
              (budget (cons jetpacs-sections-max-lines nil)))
          (or (jetpacs-sections--emit root (buffer-name buf) budget)
              (jetpacs-buffer-render buf)))))))

;; ─── Visiting the thing at a row ─────────────────────────────────────────────
;;
;; RET in a section buffer visits the thing at point — a hunk line opens
;; the file at that hunk, a commit opens its revision buffer — by popping
;; a desktop window.  `sections.visit' is the phone's version: the same
;; command under the follow shim, destination shown through the region
;; view (the results substrate's jump primitive, one seam for every
;; producer).  A command that stays in the buffer is an in-place act; the
;; handler falls back to a re-push, so toggles and stages keep working.

(defun jetpacs-sections--visit (buf pos)
  "Follow the thing at POS in section buffer BUF.
Runs the region's own RET command under `jetpacs-buffer-call-shimmed'; a
command that leaves the buffer shows its destination in the region view
and returns non-nil, one that acts in place returns nil."
  (with-current-buffer buf
    (goto-char (min (max (point-min) (truncate pos)) (point-max)))
    (let ((cmd (jetpacs-results--visit-command (point))))
      (when (commandp cmd)
        (let* ((dest (jetpacs-buffer-call-shimmed cmd))
               (dest-buf (car dest)))
          (when (and dest-buf (not (eq dest-buf buf)))
            (pcase-let ((`(,beg ,end ,label ,point)
                         (jetpacs-results--region-around dest-buf (cdr dest))))
              (funcall jetpacs-results-visit-region-function
                       (buffer-name dest-buf) beg end label point))
            t))))))

(jetpacs-defaction "sections.visit"
  ;; BUFFER must be a live magit-section buffer (the results.visit
  ;; contract), POS the tapped row.  Follow if the row's command jumps;
  ;; re-push if it acted in place (stage, toggle) or couldn't follow.
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (pos (alist-get 'pos args))
           (buf (and (stringp name) (get-buffer name))))
      (if (not (and buf (numberp pos)
                    (with-current-buffer buf
                      (and (derived-mode-p 'magit-section-mode)
                           (jetpacs-sections--root)))))
          (message "sections.visit: not a section buffer")
        (unless (ignore-errors (jetpacs-sections--visit buf pos))
          (when (functionp jetpacs-buffer-refresh-function)
            (funcall jetpacs-buffer-refresh-function)))))))

;; ─── The section context menu ───────────────────────────────────────────────
;;
;; Long-press a section header → the section's own key bindings as a
;; bridged picker → the chosen KEY is replayed at the section's position.
;; Exactly the `jetpacs.keymap.run' contract: no command names on the wire.

(defun jetpacs-sections--menu-label (cmd)
  "A human label for command CMD: prefix-stripped, dashes to spaces."
  (let ((s (symbol-name cmd)))
    (dolist (prefix '("magit-section-" "magit-" "forge-" "kubernetes-"))
      (when (string-prefix-p prefix s)
        (setq s (substring s (length prefix)))))
    (capitalize (string-replace "-" " " s))))

(defun jetpacs-sections--menu-candidates (pos)
  "The section menu at POS: an alist of (LABEL . KEY-STRING).
Single keys from the region's own keymap (the section's verbs), plus the
fold toggle.  Key description strings are what get replayed — commands
are resolved by the buffer's own keymaps at dispatch time."
  (let ((km (or (get-char-property pos 'keymap)
                (get-char-property pos 'local-map)))
        cands)
    (when (keymapp km)
      (map-keymap
       (lambda (event binding)
         (when (and (commandp binding)
                    (not (memq binding jetpacs-sections--menu-denylist))
                    (or (and (integerp event) (< 31 event 127))
                        (memq event '(return tab))))
           (let ((key (key-description (vector event))))
             (push (cons (format "%s (%s)"
                                 (jetpacs-sections--menu-label binding) key)
                         key)
                   cands))))
       km))
    (nreverse
     (cons (cons "Toggle fold (TAB)" "TAB")
           cands))))

(jetpacs-defaction "sections.menu"
  ;; BUFFER must be a live magit-section buffer (the results.visit
  ;; contract: a name off the wire only ever drives that buffer's own
  ;; bindings), POS the section to act on.  The picker is the bridged
  ;; `completing-read'; the choice replays its KEY at POS.
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (pos (alist-get 'pos args))
           (buf (and (stringp name) (get-buffer name))))
      (if (not (and buf (numberp pos)
                    (with-current-buffer buf
                      (and (derived-mode-p 'magit-section-mode)
                           (jetpacs-sections--root)))))
          (message "sections.menu: not a section buffer")
        (with-current-buffer buf
          (goto-char (min (max (point-min) (truncate pos)) (point-max)))
          (let* ((cands (jetpacs-sections--menu-candidates (point)))
                 (choice (completing-read "Section action: "
                                          (mapcar #'car cands) nil t))
                 (key (cdr (assoc choice cands))))
            (when key
              (let ((last-input-event nil)
                    (last-nonmenu-event nil))
                (execute-kbd-macro (kbd key)))
              (when (functionp jetpacs-buffer-refresh-function)
                (funcall jetpacs-buffer-refresh-function)))))))))

;; The library is third-party: register only once it exists.  The base mode
;; covers magit, forge, kubernetes.el, taxy-magit-section — everything that
;; derives properly.
(with-eval-after-load 'magit-section
  (jetpacs-render-buffer-register 'magit-section-mode #'jetpacs-sections-render))

(provide 'jetpacs-sections)
;;; jetpacs-sections.el ends here
;;; ==================================================================
;;; BEGIN core/jetpacs-transient.el
;;; ==================================================================

;;; jetpacs-transient.el --- Render transient prefixes as touch dialogs -*- lexical-binding: t; -*-

;; Transient prefixes (all of magit, and a growing share of modern packages)
;; are declarative specs: groups, keys, descriptions, switches and options
;; live in the `transient--layout' symbol property.  This module renders a
;; prefix as a touch dialog — infix switches/options as toggle chips,
;; suffixes as buttons — instead of transient's keyboard-driven popup.
;;
;; The integration point is an advice on `transient-setup': when a prefix
;; command runs inside an Jetpacs action handler (an M-x from the phone, or a
;; tap in a magit buffer), the keyboard popup — which would hang waiting
;; for key events — becomes a dialog instead.  Suffixes that are themselves
;; prefixes (magit-dispatch → magit-commit) re-enter the same advice, so
;; nesting works for free.
;;
;; Dispatch stays semantic: `transient.toggle' and `transient.invoke' only
;; accept the currently shown prefix, and only arguments/commands present
;; in its own layout.  Argument state is per-prefix; at invoke time
;; `transient-args' is rebound so the suffix sees the chips exactly as it
;; would see transient's own state.

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar jetpacs-transient--current nil
  "(PREFIX . BUFFER-NAME) of the transient dialog being shown, or nil.
Suffixes run with BUFFER-NAME current so predicates and commands see the
context the prefix was invoked from (a magit status buffer, say).")

(defvar jetpacs-transient--values nil
  "Alist of PREFIX → list of active argument strings (\"--all\", \"--author=X\").")

;; ─── Reading the layout ──────────────────────────────────────────────────────

(defun jetpacs-transient--desc (plist fallback)
  "Resolve PLIST's :description (string or function) or FALLBACK."
  (let ((d (plist-get plist :description)))
    (cond ((stringp d) d)
          ((functionp d)
           (or (ignore-errors
                 (let ((s (funcall d)))
                   (and (stringp s) (substring-no-properties s))))
               fallback))
          (t fallback))))

(defun jetpacs-transient--visible-p (plist)
  "Evaluate PLIST's :if-style predicates; include the child on error.
Only the common forms are handled; anything unrecognised is visible."
  (cl-flet ((safe (f) (ignore-errors (funcall f))))
    (cond ((plist-member plist :if)
           (safe (plist-get plist :if)))
          ((plist-member plist :if-not)
           (not (safe (plist-get plist :if-not))))
          ((plist-member plist :if-non-nil)
           (symbol-value (plist-get plist :if-non-nil)))
          ((plist-member plist :if-nil)
           (not (symbol-value (plist-get plist :if-nil))))
          ((plist-member plist :if-mode)
           (derived-mode-p (plist-get plist :if-mode)))
          ((plist-member plist :if-not-mode)
           (not (derived-mode-p (plist-get plist :if-not-mode))))
          (t t))))

;; The `transient--layout' shape changed across transient versions, and the
;; two shapes are NOT compatible:
;;
;;   0.7.x (Emacs 30 bundled): the property is a LIST of group vectors, each
;;     [LEVEL CLASS PLIST CHILDREN] (4 slots); a suffix/infix leaf is a nested
;;     list (LEVEL CLASS (:key … :command …)).
;;   newer (what a MELPA/Android magit pulls): the property is a single ROOT
;;     vector, groups are [CLASS PLIST CHILDREN] (3 slots), and a leaf inlines
;;     its plist as (transient-CLASS :key … :command …).
;;
;; The helpers below normalise both: a group's plist is the last plist-shaped
;; slot, its children the last list slot; a leaf's plist is found wherever the
;; version put it.  (This is why magit-commit crashed — the old reader did
;; `dolist' on the new root VECTOR and indexed slots that had moved.)

(defun jetpacs-transient--vec-plist (g)
  "The property plist of a group vector G (nil or a keyword-keyed list)."
  (let ((n (length g)))
    (when (> n 1)
      (let ((cand (aref g (- n 2))))
        (and (consp cand) (keywordp (car cand)) cand)))))

(defun jetpacs-transient--vec-children (g)
  "The child-node list of a group vector G (its last slot when a list)."
  (let ((n (length g)))
    (when (> n 0)
      (let ((last (aref g (1- n))))
        (and (listp last) last)))))

(defun jetpacs-transient--leaf-plist (c)
  "The property plist of a suffix/infix leaf node C, across versions.
Handles a bare plist, the newer inline (transient-CLASS :k v …), and the
older nested (LEVEL CLASS (:k v …)) / (LEVEL CLASS :k v …).  Non-cons
children — the layout intersperses bare \"\" strings as visual
separators — yield nil."
  (and (consp c)
       (cond
        ((keywordp (car c)) c)
        ((and (car c) (symbolp (car c))
              (string-prefix-p "transient-" (symbol-name (car c))))
         (cdr c))
        ((integerp (car c))
         (let ((rest (cddr c)))                   ; drop LEVEL + CLASS
           (cond ((keywordp (car-safe rest)) rest) ; inline after level
                 ((and (consp (car-safe rest))     ; nested (…)
                       (keywordp (car-safe (car rest))))
                  (car rest))
                 (t nil))))
        (t nil))))

(defun jetpacs-transient--groups (prefix)
  "Flatten PREFIX's layout into (DESCRIPTION . CHILDREN) groups.
Each child is a plist with :kind (`infix' or `suffix'), :description,
:argument and :command.  Nested column containers are flattened; group
and child visibility predicates are honoured where recognisable.  Robust
to both the list-of-groups and single-root-vector layout shapes."
  (let (groups)
    (cl-labels
        ((walk-group (g inherited-desc)
           (when (vectorp g)
             (let* ((plist (jetpacs-transient--vec-plist g))
                    (children (jetpacs-transient--vec-children g))
                    (desc (jetpacs-transient--desc plist inherited-desc)))
               (when (jetpacs-transient--visible-p plist)
                 (if (cl-some #'vectorp children)
                     ;; A container of sub-groups (columns/rows) or the root:
                     ;; recurse into each vector child.
                     (dolist (sub children)
                       (when (vectorp sub) (walk-group sub desc)))
                   (let ((kids (delq nil (mapcar #'parse-child children))))
                     (when kids
                       (push (cons desc kids) groups))))))))
         (parse-child (c)
           (let ((plist (jetpacs-transient--leaf-plist c)))
             (when plist
               (let ((arg (plist-get plist :argument))
                     (cmd (plist-get plist :command)))
                 (when (jetpacs-transient--visible-p plist)
                   (cond
                    ((stringp arg)
                     (list :kind 'infix
                           :argument arg
                           :description (jetpacs-transient--desc plist arg)))
                    ((commandp cmd)
                     (list :kind 'suffix
                           :command cmd
                           :description
                           (jetpacs-transient--desc
                            plist
                            (capitalize
                             (replace-regexp-in-string
                              "-" " " (symbol-name cmd)))))))))))))
      (let ((layout (get prefix 'transient--layout)))
        (cond
         ;; Newer: a single root container vector.
         ((vectorp layout) (walk-group layout nil))
         ;; Older: a list of top-level group vectors.
         ((listp layout) (dolist (g layout) (walk-group g nil))))))
    (nreverse groups)))

(defun jetpacs-transient--child (prefix key value)
  "Find the child plist in PREFIX's layout whose KEY equals VALUE."
  (cl-loop for (_desc . kids) in (jetpacs-transient--groups prefix)
           thereis (cl-find value kids
                            :key (lambda (k) (plist-get k key))
                            :test #'equal)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-transient--arg-active (prefix arg)
  "The active value for ARG in PREFIX's state, or nil.
For options (\"--author=\") any stored value with that prefix counts."
  (let ((values (alist-get prefix jetpacs-transient--values)))
    (if (string-suffix-p "=" arg)
        (cl-find arg values :test #'string-prefix-p)
      (car (member arg values)))))

(defun jetpacs-transient--dialog (prefix)
  "Build the dialog spec for PREFIX from its layout and argument state."
  (apply
   #'jetpacs-lazy-column
   (append
    (list (jetpacs-row
           (jetpacs-box
            (list (jetpacs-text
                   (capitalize (replace-regexp-in-string
                                "-" " " (symbol-name prefix)))
                   'title))
            :weight 1)
           (jetpacs-button "Close"
                        (jetpacs-action "dialog.dismiss")
                        :variant "text")))
    (cl-loop
     for (desc . kids) in (jetpacs-transient--groups prefix)
     append
     (delq nil
           (list
            (when desc (jetpacs-section-header desc))
            (apply
             #'jetpacs-flow-row
             (mapcar
              (lambda (k)
                (if (eq (plist-get k :kind) 'infix)
                    (let* ((arg (plist-get k :argument))
                           (active (jetpacs-transient--arg-active prefix arg)))
                      (jetpacs-chip (if (and active (not (equal active arg)))
                                     active ; show "--author=X", not "--author="
                                   (plist-get k :description))
                                 :selected (and active t)
                                 :on-tap (jetpacs-action
                                          "transient.toggle"
                                          :args `((argument . ,arg))
                                          :when-offline "drop")))
                  (jetpacs-button (plist-get k :description)
                               (jetpacs-action
                                "transient.invoke"
                                :args `((command . ,(symbol-name
                                                     (plist-get k :command))))
                                :when-offline "drop")
                               :variant "outlined")))
              kids))))))))

(defun jetpacs-transient-show (prefix)
  "Render PREFIX as a touch dialog and record it as current."
  (setq jetpacs-transient--current (cons prefix (buffer-name)))
  (jetpacs-send-dialog (jetpacs-transient--dialog prefix)))

;; ─── Interception ────────────────────────────────────────────────────────────

(defun jetpacs--transient-setup-advice (orig-fn &optional name &rest args)
  "When a prefix is invoked from the phone, dialog instead of popup.
Without this, `transient-setup' would block waiting for key events that
can never arrive over the bridge."
  (if (and jetpacs--in-action-handler name (get name 'transient--layout))
      (jetpacs-transient-show name)
    (apply orig-fn name args)))

(advice-add 'transient-setup :around #'jetpacs--transient-setup-advice)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "transient.show"
  ;; Open a prefix by name.  Equivalent surface to M-x (which is already an
  ;; allowlisted path): only commands that ARE transient prefixes qualify.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (and sym (commandp sym) (get sym 'transient--layout))
          (jetpacs-transient-show sym)
        (jetpacs-send "toast.show"
                   `((text . ,(format "%s is not a transient prefix"
                                      (or name "?")))))))))

(jetpacs-defaction "transient.toggle"
  (lambda (args _)
    (let* ((prefix (car jetpacs-transient--current))
           (arg (alist-get 'argument args))
           (child (and prefix (jetpacs-transient--child prefix :argument arg))))
      (when child
        (let* ((values (alist-get prefix jetpacs-transient--values))
               (active (jetpacs-transient--arg-active prefix arg)))
          (setf (alist-get prefix jetpacs-transient--values)
                (if active
                    (remove active values)
                  (cons (if (string-suffix-p "=" arg)
                            ;; Options carry a value: prompt for it (the
                            ;; minibuffer bridge turns this into a dialog).
                            (concat arg (read-string
                                         (format "%s " (plist-get child :description))))
                          arg)
                        values)))
          (jetpacs-send-dialog (jetpacs-transient--dialog prefix)))))))

(jetpacs-defaction "transient.invoke"
  (lambda (args _)
    (let* ((prefix (car jetpacs-transient--current))
           (buf (cdr jetpacs-transient--current))
           (name (alist-get 'command args))
           (sym (and (stringp name) (intern-soft name)))
           (child (and prefix sym
                       (jetpacs-transient--child prefix :command sym))))
      (when child
        (jetpacs-dismiss-dialog)
        (let ((values (copy-sequence
                       (alist-get prefix jetpacs-transient--values)))
              (orig (symbol-function 'transient-args)))
          (with-current-buffer (or (and buf (get-buffer buf))
                                   (current-buffer))
            ;; The suffix asks `transient-args' for the popup state it
            ;; would have had; hand it the chips.
            (cl-letf (((symbol-function 'transient-args)
                       (lambda (p)
                         (if (eq p prefix) values (funcall orig p)))))
              (condition-case err
                  (call-interactively sym)
                (quit nil)
                (error (jetpacs-send
                        "toast.show"
                        `((text . ,(format "%s failed: %s" name
                                           (error-message-string err))))))))))
        (when (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function))))))

(provide 'jetpacs-transient)
;;; jetpacs-transient.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-keymap.el
;;; ==================================================================

;;; jetpacs-keymap.el --- Keymap surfacing for the radial pie menu -*- lexical-binding: t; -*-

;; The input complement to the Tier 0 generic buffer renderer.  Two UIs,
;; split by how good the available labels are:
;;
;;   * Tier 0 default — a searchable COMMAND PALETTE.  Raw keymap dumps
;;     have dozens of bindings with machine-made labels; a live-filtering
;;     list (the bridged `completing-read' picker) beats a pie menu for
;;     that.  `jetpacs.keymap.show' extracts the buffer's bindings and runs
;;     the picker; choosing an entry executes the key in-buffer (with
;;     minibuffer prompts auto-bridged as always).
;;
;;   * Tier 1 — the RADIAL PIE MENU, reserved for curated, bounded menus.
;;     Today that means a live transient.el session (`transient--prefix'
;;     non-nil): human-written suffix descriptions, ≤~10 items — the pie's
;;     sweet spot.  Executing a command that *activates* a transient
;;     (e.g. picking `magit-dispatch' from the palette) opens the pie
;;     automatically; when the transient ends the pie is dismissed.
;;
;; The grouping/category machinery below (`jetpacs-keymap--group-bindings')
;; is retained for future Tier 1 skins that want to send curated pie
;; specs for a whole mode; the default path no longer uses it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jetpacs-surfaces)   ; jetpacs-defaction, jetpacs-action, jetpacs-send

;; Forward declaration: defined in jetpacs-buffer.el, set by jetpacs-emacs-ui.el
(defvar jetpacs-buffer-refresh-function)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-keymap-show-global nil
  "When non-nil, include global-map bindings in the pie menu.
Usually these are ambient (C-x C-s, C-g, etc.) and not useful on a phone;
the mode-specific bindings are what matter."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-keymap-max-segments 8
  "Maximum number of top-level categories in the pie menu.
Excess categories are merged into an \"Other\" overflow group."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-keymap-max-bindings 200
  "Maximum number of bindings to extract from a buffer's keymaps.
Safety cap so a mode with hundreds of bindings doesn't produce an
unbounded spec."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-keymap-denylist
  '(self-insert-command
    digit-argument negative-argument universal-argument
    undefined ignore keyboard-quit keyboard-escape-quit
    abort-recursive-edit abort-minibuffers
    exit-minibuffer minibuffer-keyboard-quit
    newline newline-and-indent open-line
    ;; Mouse/menu noise
    mouse-set-point mouse-set-region mouse-drag-region
    mac-mouse-turn-on-fullscreen
    ;; Too generic
    undo undo-redo
    ;; Forward/backward char — not useful on phone
    forward-char backward-char
    next-line previous-line
    scroll-up-command scroll-down-command
    beginning-of-buffer end-of-buffer
    move-beginning-of-line move-end-of-line)
  "Commands excluded from the pie menu.
These are either noise (self-insert), globally ambient, or navigation
that doesn't make sense on a phone touchscreen."
  :type '(repeat symbol) :group 'jetpacs)

;; ─── Binding extraction ────────────────────────────────────────────────────

(defun jetpacs-keymap--key-printable-p (key)
  "Non-nil if KEY (a key vector) represents a printable/keyboard binding.
Excludes mouse events, menu-bar, tool-bar, header-line, mode-line, and
function keys beyond F12."
  (let ((first (aref key 0)))
    (not (or (and (symbolp first)
                  (let ((name (symbol-name first)))
                    (or (string-prefix-p "mouse-" name)
                        (string-prefix-p "drag-mouse-" name)
                        (string-prefix-p "double-mouse-" name)
                        (string-prefix-p "triple-mouse-" name)
                        (string-prefix-p "down-mouse-" name)
                        (string-prefix-p "wheel-" name)
                        (string-match-p "\\`\\(menu-bar\\|tool-bar\\|header-line\\|mode-line\\|tab-bar\\|tab-line\\|vertical-scroll-bar\\|horizontal-scroll-bar\\)" name))))
            ;; Event types that are conses (e.g. (menu-bar ...))
            (consp first)))))

(defun jetpacs-keymap--walk-keymap (keymap prefix-keys)
  "Walk KEYMAP and return a list of (KEY-VEC . COMMAND) pairs.
PREFIX-KEYS is a key vector prepended to each binding (for recursive
descent into prefix keymaps).  Only leaf (commandp) bindings are
returned; intermediate prefix keymaps are recursed into."
  (let (bindings)
    (when (keymapp keymap)
      (map-keymap
       (lambda (event def)
         (let* ((key-vec (vconcat prefix-keys (vector event)))
                ;; Unwrap menu-item forms to get the real definition
                (def (if (and (consp def) (eq (car def) 'menu-item))
                         (nth 2 def)
                       def))
                ;; Resolve the underlying value for type checks, but
                ;; keep the original symbol for storage so symbol-name
                ;; works downstream.
                (resolved (if (and (symbolp def) (fboundp def))
                              (indirect-function def)
                            def)))
           (cond
            ;; Skip non-printable keys
            ((not (jetpacs-keymap--key-printable-p key-vec)) nil)
            ;; Recurse into prefix keymaps (but limit depth to 3)
            ((and (keymapp resolved) (< (length key-vec) 4))
             (setq bindings
                   (append bindings
                           (jetpacs-keymap--walk-keymap resolved key-vec))))
            ;; Leaf binding — store the symbol, not the resolved function
            ((commandp def)
             (push (cons key-vec def) bindings)))))
       keymap))
    (nreverse bindings)))

(defun jetpacs-keymap--extract-bindings (buffer)
  "Extract printable key->command bindings from BUFFER's active keymaps.
Returns a list of (KEY-DESC COMMAND SOURCE) where KEY-DESC is a string
like \"s\" or \"C-c C-t\", COMMAND is a symbol, and SOURCE is a symbol
identifying the keymap (major-mode name, minor-mode name, or `global')."
  (with-current-buffer buffer
    (let ((local-map (current-local-map))
          (minor-maps (current-minor-mode-maps))
          (global-map (current-global-map))
          (seen (make-hash-table :test 'equal))
          result count)
      (setq count 0)
      ;; Helper: add bindings from a keymap, tagged with SOURCE
      (cl-flet ((collect (keymap source)
                  (when (and keymap (< count jetpacs-keymap-max-bindings))
                    (dolist (pair (jetpacs-keymap--walk-keymap keymap []))
                      (when (< count jetpacs-keymap-max-bindings)
                        (let* ((key-vec (car pair))
                               (cmd (cdr pair))
                               (desc (key-description key-vec)))
                          (unless (or (gethash desc seen)
                                     (memq cmd jetpacs-keymap-denylist)
                                     ;; Skip commands with names starting
                                     ;; with internal prefixes
                                     (string-prefix-p "menu-bar" desc)
                                     (string-prefix-p "<" desc))
                            (puthash desc t seen)
                            (push (list desc cmd source) result)
                            (setq count (1+ count)))))))))
        ;; Highest priority first: minor modes, then local, then global
        (dolist (mm minor-maps)
          (let* ((var (car mm))
                 (map (cdr mm))
                 (source (or var 'minor)))
            (collect map source)))
        (collect local-map major-mode)
        (when jetpacs-keymap-show-global
          (collect global-map 'global)))
      (nreverse result))))

;; ─── Transient.el integration ──────────────────────────────────────────────

(defun jetpacs-keymap--transient-available-p ()
  "Non-nil if transient.el is loaded."
  (featurep 'transient))

(defun jetpacs-keymap--transient-prefix-p (command)
  "Non-nil if COMMAND is a transient prefix (has a layout definition)."
  (and (jetpacs-keymap--transient-available-p)
       (symbolp command)
       (get command 'transient--layout)))

(defun jetpacs-keymap--transient-active-p ()
  "Non-nil if a transient session is currently active."
  (and (jetpacs-keymap--transient-available-p)
       (bound-and-true-p transient--prefix)))

(defun jetpacs-keymap--extract-transient-layout (prefix-symbol)
  "Extract bindings from PREFIX-SYMBOL's transient layout (without activating it).
Returns a list of (:key KEY :label LABEL :command CMD :is-infix BOOL) plists."
  (let ((layout (get prefix-symbol 'transient--layout))
        (result nil))
    (when layout
      (jetpacs-keymap--walk-transient-node layout result)
      (nreverse result))))

(defun jetpacs-keymap--walk-transient-node (thing result)
  "Recursively walk a transient layout node THING, pushing bindings onto RESULT.
THING can be a vector (group), a list starting with a transient class
symbol (suffix/infix), or a plain list of children to recurse over."
  (cond
   ;; Vector = group node: [CLASS-OR-LEVEL PLIST CHILDREN...]
   ;; Convert to list, skip the first 2 elements (class + plist), recurse children.
   ((vectorp thing)
    (dolist (child (cddr (append thing nil)))
      (jetpacs-keymap--walk-transient-node child result)))

   ;; List whose car is a transient-* class symbol → suffix or infix
   ;; Format: (transient-suffix :key "s" :command magit-stage ...)
   ;; The plist is (cdr thing), NOT (cadr thing).
   ((and (consp thing)
         (symbolp (car thing))
         (string-prefix-p "transient-" (symbol-name (car thing)))
         (plist-get (cdr thing) :key))
    (let* ((plist (cdr thing))
           (key (string-trim-right (plist-get plist :key)))
           (cmd (plist-get plist :command))
           (desc (or (plist-get plist :description)
                     (and (symbolp cmd) (symbol-name cmd))
                     ""))
           (class-name (symbol-name (car thing)))
           (is-infix (or (string-match-p "option" class-name)
                         (string-match-p "switch" class-name)
                         (string-match-p "infix" class-name))))
      (when (and key cmd)
        (when (functionp desc)
          (setq desc (condition-case nil (funcall desc) (error ""))))
        (push (list :key key
                    :label (if (stringp desc) desc "")
                    :command cmd
                    :is-infix is-infix)
              result))))

   ;; Plain list → iterate over each element and recurse
   ((listp thing)
    (dolist (elt thing)
      (jetpacs-keymap--walk-transient-node elt result)))))

(defun jetpacs-keymap--active-transient-bindings ()
  "Extract bindings from the currently active transient session.
Returns a list similar to `jetpacs-keymap--extract-transient-layout'
but reflecting the live state (current infix values, etc.)."
  (when (jetpacs-keymap--transient-active-p)
    (let (result)
      (dolist (obj (bound-and-true-p transient-current-suffixes))
        (condition-case nil
            (let ((key (and (slot-boundp obj 'key) (eieio-oref obj 'key)))
                  (cmd (and (slot-boundp obj 'command) (eieio-oref obj 'command)))
                  (desc (condition-case nil
                            (let ((d (eieio-oref obj 'description)))
                              (if (functionp d) (funcall d) d))
                          (error "")))
                  (is-infix (and (fboundp 'transient-infix-p)
                                 (funcall 'transient-infix-p obj))))
              (when (and key cmd)
                (push (list :key key
                            :label (or desc "")
                            :command cmd
                            :is-infix is-infix)
                      result)))
          (error nil)))
      (nreverse result))))

;; ─── Grouping ──────────────────────────────────────────────────────────────

(defun jetpacs-keymap--single-key-p (key-desc)
  "Non-nil if KEY-DESC is a single unmodified key (like \"s\", \"g\", \"?\")."
  (and (= (length key-desc) 1)
       (not (string-match-p "[CM]-" key-desc))))

(defun jetpacs-keymap--prefix-of (key-desc)
  "Return the prefix group for KEY-DESC, or nil for single keys.
E.g. \"C-c C-t\" -> \"C-c\", \"C-x 4 f\" -> \"C-x\", \"M-g g\" -> \"M-g\"."
  (when (string-match "\\`\\([CMSs]-[^ ]+\\) " key-desc)
    (match-string 1 key-desc)))

(defun jetpacs-keymap--group-bindings (bindings buffer-name)
  "Group BINDINGS into categories for the pie menu.
BUFFER-NAME is used in action args.
Returns an alist of (CATEGORY-LABEL ICON . BINDING-SPECS) suitable for
the companion's pie menu JSON."
  (let ((single-keys nil)
        (prefix-groups (make-hash-table :test 'equal))
        (categories nil))
    ;; Partition bindings
    (dolist (b bindings)
      (let ((key-desc (nth 0 b)))
        (if (jetpacs-keymap--single-key-p key-desc)
            (push b single-keys)
          (let ((prefix (or (jetpacs-keymap--prefix-of key-desc) "Other")))
            (push b (gethash prefix prefix-groups))))))
    ;; Build categories
    ;; 1. Single-key commands (the "hot keys") — most important
    (when single-keys
      (push (cons "Keys"
                  (cons "keyboard"
                        (jetpacs-keymap--bindings-to-specs
                         (nreverse single-keys) buffer-name)))
            categories))
    ;; 2. Prefix groups (C-c, C-x, M-g, etc.)
    (let ((prefix-list nil))
      (maphash (lambda (prefix bindings)
                 (push (cons prefix (nreverse bindings)) prefix-list))
               prefix-groups)
      ;; Sort by prefix name
      (setq prefix-list (sort prefix-list
                              (lambda (a b) (string< (car a) (car b)))))
      (dolist (pg prefix-list)
        (push (cons (car pg)
                    (cons "code"
                          (jetpacs-keymap--bindings-to-specs
                           (cdr pg) buffer-name)))
              categories)))
    ;; Enforce max categories
    (setq categories (nreverse categories))
    (when (> (length categories) jetpacs-keymap-max-segments)
      ;; Merge excess into "Other"
      (let ((keep (seq-take categories (1- jetpacs-keymap-max-segments)))
            (overflow (seq-drop categories (1- jetpacs-keymap-max-segments))))
        (setq categories
              (append keep
                      (list (cons "Other"
                                  (cons "more_horiz"
                                        (apply #'append
                                               (mapcar #'cddr overflow)))))))))
    categories))

(defun jetpacs-keymap--bindings-to-specs (bindings buffer-name)
  "Convert a list of (KEY-DESC CMD SOURCE) BINDINGS into JSON-ready specs."
  (mapcar
   (lambda (b)
     (let* ((key-desc (nth 0 b))
            (cmd (nth 1 b))
            (is-transient-prefix (jetpacs-keymap--transient-prefix-p cmd))
            (children (when is-transient-prefix
                        (jetpacs-keymap--transient-children-specs cmd buffer-name)))
            (label (jetpacs-keymap--command-label cmd)))
       (append
        `((key . ,key-desc)
          (label . ,label)
          (action . ,(jetpacs-action "jetpacs.keymap.run"
                                  :args `((buffer . ,buffer-name)
                                          (key . ,key-desc))
                                  :when-offline "drop")))
        (when is-transient-prefix
          `((is_prefix . t)))
        (when children
          `((children . ,(vconcat children)))))))
   bindings))

(defun jetpacs-keymap--transient-children-specs (prefix-cmd buffer-name)
  "Build child binding specs for transient prefix PREFIX-CMD."
  (let ((layout-bindings (jetpacs-keymap--extract-transient-layout prefix-cmd)))
    (mapcar
     (lambda (b)
       (let ((key (plist-get b :key))
             (label (plist-get b :label))
             (cmd (plist-get b :command))
             (is-infix (plist-get b :is-infix)))
         (append
          `((key . ,key)
            (label . ,(or label (symbol-name cmd))))
          (when is-infix `((is_infix . t)))
          `((action . ,(jetpacs-action "jetpacs.keymap.run"
                                    :args `((buffer . ,buffer-name)
                                            (key . ,key)
                                            (transient_prefix
                                             . ,(symbol-name prefix-cmd)))
                                    :when-offline "drop"))))))
     layout-bindings)))

(defun jetpacs-keymap--command-label (cmd)
  "Human-readable label for command CMD.
Strips only the current buffer's major-mode stem (so `org-agenda-list'
becomes \"agenda-list\" in an org buffer but keeps its full name
elsewhere).  For a hyphenated mode like `magit-status-mode', the first
segment (\"magit-\") is also tried.  Never strips blindly: the old
greedy last-dash strip turned `forward-paragraph' into \"paragraph\"."
  (if (not (symbolp cmd))
      (format "%s" cmd)
    (let* ((name (symbol-name cmd))
           (stem (string-remove-suffix "-mode" (symbol-name major-mode)))
           (head (car (split-string stem "-"))))
      (cond
       ((and (string-prefix-p (concat stem "-") name)
             (> (length name) (1+ (length stem))))
        (substring name (1+ (length stem))))
       ((and (string-prefix-p (concat head "-") name)
             (> (length name) (1+ (length head))))
        (substring name (1+ (length head))))
       (t name)))))

;; ─── Pie menu spec builder ─────────────────────────────────────────────────

(defun jetpacs-keymap--build-pie-spec (buffer)
  "Build the full pie-menu JSON spec for BUFFER's keybindings."
  (with-current-buffer buffer
    (let* ((mode-label (symbol-name major-mode))
           (buffer-name (buffer-name buffer))
           ;; Check for active transient first
           (is-transient (jetpacs-keymap--transient-active-p))
           (categories
            (if is-transient
                ;; Active transient: show its bindings as a single category
                (let* ((bindings (jetpacs-keymap--active-transient-bindings))
                       (specs (mapcar
                               (lambda (b)
                                 (let ((key (plist-get b :key))
                                       (label (plist-get b :label))
                                       (is-infix (plist-get b :is-infix)))
                                   (append
                                    `((key . ,key)
                                      (label . ,(or label "")))
                                    (when is-infix `((is_infix . t)))
                                    `((action
                                       . ,(jetpacs-action
                                           "jetpacs.keymap.run"
                                           :args `((buffer . ,buffer-name)
                                                   (key . ,key)
                                                   (transient_active . t))
                                           :when-offline "drop"))))))
                               bindings)))
                  (list (cons "Transient"
                              (cons "terminal" specs))))
              ;; Normal mode: extract from active keymaps
              (let ((bindings (jetpacs-keymap--extract-bindings buffer)))
                (jetpacs-keymap--group-bindings bindings buffer-name)))))
      `((center_label . ,mode-label)
        (buffer . ,buffer-name)
        (categories
         . ,(vconcat
             (mapcar
              (lambda (cat)
                `((label . ,(car cat))
                  (icon . ,(cadr cat))
                  (bindings . ,(vconcat (cddr cat)))))
              categories)))))))

;; ─── Tier 1 registry: curated pie menus per major mode ─────────────────────

(defvar jetpacs-keymap-tier1-menus nil
  "Alist of (MAJOR-MODE . BUILDER) curated Tier 1 pie menus.
BUILDER is called with the buffer and returns a pie-menu spec alist
\(same shape as `jetpacs-keymap--build-pie-spec').  A buffer whose mode
derives from a registered mode gets its curated pie instead of the
default command palette; the first matching entry wins.")

(defun jetpacs-keymap-register-tier1 (mode builder)
  "Register BUILDER as the curated Tier 1 pie menu for MODE."
  (setf (alist-get mode jetpacs-keymap-tier1-menus) builder))

(defun jetpacs-keymap--tier1-builder (buf)
  "The registered Tier 1 menu builder for BUF's major mode, or nil."
  (with-current-buffer buf
    (seq-some (lambda (cell)
                (and (derived-mode-p (car cell)) (cdr cell)))
              jetpacs-keymap-tier1-menus)))

;; ─── Menu-bar mining ────────────────────────────────────────────────────────
;;
;; A mode's menu-bar keymap is the ONE place its author writes human labels and
;; :help strings — exactly the curated metadata a raw keymap dump lacks.  We
;; mine the local and minor-mode menus (not the generic global File/Edit menu)
;; into palette entries: breadcrumb-labeled, help-annotated, dispatched by
;; command symbol.  Same class of curated, mode-owned command the palette
;; already runs, so this stays inside the command-dispatch boundary.

(defcustom jetpacs-keymap-menu-max-items 150
  "Cap on menu-derived palette entries mined from a buffer's menus."
  :type 'integer :group 'jetpacs)

(defun jetpacs-keymap--menu-pred (props key)
  "Non-nil when PROPS' KEY predicate (`:enable'/`:visible') passes or is absent.
A predicate that signals is treated as passing — better to offer a command
that turns out disabled than to hide one on a spurious error."
  (let ((m (plist-member props key)))
    (or (not m)
        (condition-case nil (eval (plist-get props key) t) (error t)))))

(defun jetpacs-keymap--menu-item-parse (binding)
  "Parse a menu keymap BINDING into (LABEL REAL HELP), or nil.
Handles the `menu-item' form and the older (STRING . REAL) /
\(STRING HELP . REAL) forms; applies `:filter' and drops items whose
`:enable'/`:visible' predicate is nil, and separators."
  (cond
   ((and (consp binding) (eq (car binding) 'menu-item))
    (let* ((label (nth 1 binding))
           (real (nth 2 binding))
           (props (nthcdr 3 binding))
           (filter (plist-get props :filter)))
      (when (functionp filter)
        (setq real (ignore-errors (funcall filter real))))
      (when (and (stringp label)
                 (not (string-prefix-p "--" label)) ; separator
                 (jetpacs-keymap--menu-pred props :enable)
                 (jetpacs-keymap--menu-pred props :visible))
        (list label real (plist-get props :help)))))
   ((and (consp binding) (stringp (car binding)))
    (let ((label (car binding))
          (rest (cdr binding)))
      (unless (string-prefix-p "--" label)
        (if (and (consp rest) (stringp (car rest)))
            (list label (cdr rest) (car rest))   ; (STRING HELP . REAL)
          (list label rest nil)))))              ; (STRING . REAL)
   (t nil)))

(defun jetpacs-keymap--menu-entries (keymap)
  "Flatten menu-bar KEYMAP into (LABEL-PATH HELP COMMAND) leaves.
Submenus recurse with a breadcrumb label path (\"File ▸ Save As…\");
disabled/invisible items, separators, and non-command leaves are dropped."
  (let (out)
    (cl-labels
        ((walk (km crumb depth)
           (when (and (keymapp km) (< depth 5)
                      (< (length out) jetpacs-keymap-menu-max-items))
             (map-keymap
              (lambda (_event binding)
                (when (< (length out) jetpacs-keymap-menu-max-items)
                  (when-let ((parsed (jetpacs-keymap--menu-item-parse binding)))
                    (let* ((label (nth 0 parsed))
                           (real (nth 1 parsed))
                           (help (nth 2 parsed))
                           (path (if crumb (concat crumb " ▸ " label) label)))
                      (cond
                       ((keymapp real) (walk real path (1+ depth)))
                       ((commandp real) (push (list path help real) out)))))))
              km))))
      (walk keymap nil 0))
    (nreverse out)))

(defun jetpacs-keymap--menu-maps (buf)
  "Menu-bar keymaps to mine for BUF: minor-mode and local (plus global when
`jetpacs-keymap-show-global').  The global menu is skipped by default — its
File/Edit/… entries are generic noise next to the mode's own menu."
  (with-current-buffer buf
    (let (maps)
      (dolist (km (current-minor-mode-maps))
        (let ((menu (and (keymapp km) (lookup-key km [menu-bar]))))
          (when (keymapp menu) (push menu maps))))
      (when-let* ((lm (current-local-map))
                  (menu (lookup-key lm [menu-bar])))
        (when (keymapp menu) (push menu maps)))
      (when jetpacs-keymap-show-global
        (let ((menu (lookup-key (current-global-map) [menu-bar])))
          (when (keymapp menu) (push menu maps))))
      (nreverse maps))))

(defun jetpacs-keymap--menu-candidates (buf)
  "Palette candidates mined from BUF's menu-bar keymaps.
Returns an alist of (DISPLAY . (command . SYMBOL)), deduped by command."
  (let (result (seen (make-hash-table :test 'eq)))
    (dolist (menu (jetpacs-keymap--menu-maps buf))
      (dolist (entry (jetpacs-keymap--menu-entries menu))
        (let* ((path (nth 0 entry))
               (help (nth 1 entry))
               (cmd (nth 2 entry))
               (display (if (and (stringp help) (not (string-empty-p help)))
                            (format "%s — %s" path (car (split-string help "\n" t)))
                          path)))
          (unless (or (gethash cmd seen) (memq cmd jetpacs-keymap-denylist))
            (puthash cmd t seen)
            (push (cons display (cons 'command cmd)) result)))))
    (nreverse result)))

;; ─── Command palette (Tier 0 default) ──────────────────────────────────────

(defun jetpacs-keymap--palette-candidates (buf)
  "Alist of (DISPLAY . TARGET) for BUF's key bindings and menu items.
TARGET is (key . KEY-DESC) for a keybinding or (command . SYMBOL) for a
menu-derived entry.  Keybindings come first (they carry the shortcut), then
the human-labeled menu entries."
  (with-current-buffer buf
    (append
     (mapcar (lambda (b)
               (pcase-let ((`(,key ,cmd ,_source) b))
                 (cons (format "%s  ·  %s" key (jetpacs-keymap--command-label cmd))
                       (cons 'key key))))
             (jetpacs-keymap--extract-bindings buf))
     (jetpacs-keymap--menu-candidates buf))))

(defun jetpacs-keymap--show-palette (buf)
  "Show a searchable command palette for BUF's keybindings and menu items.
Runs inside an action handler, so `completing-read' is bridged to the
companion as a live-filtering picker dialog.  A key binding is executed as
its key (so an activated transient opens its Tier 1 pie); a menu entry —
which may carry no key — is run by command symbol."
  (let* ((candidates (jetpacs-keymap--palette-candidates buf))
         (choice (cond
                  ((null candidates)
                   (message "Jetpacs keymap: no bindings extracted from %s"
                            (buffer-name buf))
                   nil)
                  (t (condition-case nil
                         (completing-read
                          (format "%s commands" (buffer-name buf))
                          (mapcar #'car candidates) nil t)
                       (quit nil)))))
         (target (cdr (assoc choice candidates))))
    (pcase target
      (`(key . ,key) (jetpacs-keymap--execute-key buf key))
      (`(command . ,cmd) (jetpacs-keymap--execute-command buf cmd)))))

;; ─── Key execution & pie-menu sync ──────────────────────────────────────────

(defun jetpacs-keymap--sync-pie (buf)
  "Reconcile the companion's radial overlay with transient state.
A live transient keeps (or opens) its Tier 1 pie menu; anything else
dismisses the overlay — so the pie can never linger after the command
it belonged to has finished."
  (if (jetpacs-keymap--transient-active-p)
      (jetpacs-send "pie_menu.show" (jetpacs-keymap--build-pie-spec buf))
    (jetpacs-send "pie_menu.dismiss" nil)))

(defun jetpacs-keymap--execute-key (buf key)
  "Execute KEY in BUF, then sync the pie menu and refresh the surface."
  (with-current-buffer buf
    (condition-case err
        (execute-kbd-macro (kbd key))
      (error
       (message "Jetpacs keymap: %s failed: %s" key (error-message-string err)))))
  (jetpacs-keymap--sync-pie buf)
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

(defun jetpacs-keymap--execute-command (buf cmd)
  "Run CMD interactively in BUF, then sync the pie menu and refresh the surface.
Menu entries may carry no key sequence, so they dispatch by symbol; any
minibuffer prompt CMD raises is bridged as always."
  (with-current-buffer buf
    (condition-case err
        (call-interactively cmd)
      (error
       (message "Jetpacs keymap: %s failed: %s" cmd (error-message-string err)))))
  (jetpacs-keymap--sync-pie buf)
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

;; ─── Action handlers ───────────────────────────────────────────────────────

(jetpacs-defaction "jetpacs.keymap.show"
  (lambda (args _)
    (let* ((buffer-name (or (alist-get 'buffer args)
                            (and (bound-and-true-p jetpacs-emacs-ui--viewing-buffer)
                                 jetpacs-emacs-ui--viewing-buffer)
                            (buffer-name (current-buffer))))
           (buf (get-buffer buffer-name)))
      (cond
       ((not buf)
        (message "Jetpacs keymap: no such buffer %s" buffer-name))
       ;; Tier 1: a live transient has curated labels and a small, bounded
       ;; suffix set — exactly what the radial menu is good at.
       ((jetpacs-keymap--transient-active-p)
        (jetpacs-send "pie_menu.show" (jetpacs-keymap--build-pie-spec buf)))
       ;; Tier 1: a curated pie registered for this major mode (e.g. magit).
       ((when-let ((builder (jetpacs-keymap--tier1-builder buf)))
          (jetpacs-send "pie_menu.show" (funcall builder buf))
          t))
       ;; Tier 0 default: the searchable command palette.
       (t (jetpacs-keymap--show-palette buf))))))

(jetpacs-defaction "jetpacs.keymap.run"
  (lambda (args _)
    (let* ((buffer-name (alist-get 'buffer args))
           (key (alist-get 'key args))
           (transient-prefix-name (alist-get 'transient_prefix args))
           (transient-active (alist-get 'transient_active args))
           (buf (get-buffer buffer-name)))
      (when (and buf key)
        (with-current-buffer buf
          (condition-case err
              (cond
               ;; Active transient session: find and call the suffix directly
               (transient-active
                (jetpacs-keymap--run-transient-key key))
               ;; Known transient prefix: invoke the prefix first, then the suffix
               (transient-prefix-name
                (let ((prefix-cmd (intern-soft transient-prefix-name)))
                  (when (commandp prefix-cmd)
                    ;; Call the prefix to activate the transient
                    (call-interactively prefix-cmd)
                    ;; Now run the suffix key in the transient
                    (when (jetpacs-keymap--transient-active-p)
                      (jetpacs-keymap--run-transient-key key)))))
               ;; Normal key dispatch
               (t
                (execute-kbd-macro (kbd key))))
            (error
             (message "Jetpacs keymap.run %s failed: %s" key
                      (error-message-string err)))))
        ;; Keep the overlay honest: still-active transient re-shows its pie
        ;; (with fresh infix values); a finished one dismisses it.
        (jetpacs-keymap--sync-pie buf)
        ;; Re-push the surface
        (when (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function))))))

(defun jetpacs-keymap--run-transient-key (key)
  "Dispatch KEY within the currently active transient session.
Finds the suffix object with matching key and calls its command directly,
which is more reliable than simulating keystrokes through the transient's
`overriding-terminal-local-map'."
  (let ((target-cmd nil))
    (dolist (obj (bound-and-true-p transient-current-suffixes))
      (condition-case nil
          (when (and (slot-boundp obj 'key)
                     (equal key (eieio-oref obj 'key)))
            (setq target-cmd (and (slot-boundp obj 'command)
                                  (eieio-oref obj 'command))))
        (error nil)))
    (if (and target-cmd (commandp target-cmd))
        (call-interactively target-cmd)
      ;; Fallback: try feeding the key through the event loop
      (setq unread-command-events
            (append (listify-key-sequence (kbd key))
                    unread-command-events)))))

(jetpacs-defaction "jetpacs.keymap.dismiss"
  (lambda (_ _)
    (jetpacs-send "pie_menu.dismiss" nil)))

(provide 'jetpacs-keymap)
;;; jetpacs-keymap.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-sync.el
;;; ==================================================================

;;; jetpacs-sync.el --- Live editor-buffer sync + diagnostics push -*- lexical-binding: t; -*-

;; V2 of the phone-editor bridge: instead of shipping a text window with
;; each completion request, the companion keeps a per-file *session shadow
;; buffer* here continuously current via incremental deltas:
;;
;;   edit.open  {file session text}                  seed / reseed (seq 0)
;;   edit.delta {file session seq start del text len} one splice
;;   edit.close {file session}                        editor gone
;;
;; Offsets and lengths are in Unicode code points, which are exactly Emacs
;; buffer characters — the phone converts from its UTF-16 indices, so this
;; side never does encoding math.  Deltas are seq-numbered and each carries
;; the expected resulting length; any mismatch (dropped frame, Emacs
;; restart, phone bug) marks the session stale and sends one `edit.resync'
;; frame, to which the phone answers with a fresh edit.open.  Wrong state
;; can therefore only ever cause a missing feature, never a wrong edit.
;;
;; Riding on the synced shadow:
;;   * slim completion — jetpacs-complete.el completes at a bare cursor offset
;;   * diagnostics — flymake runs in the shadow and changed diagnostics are
;;     pushed as `diagnostics.show' frames (squiggles on the phone)
;; Eldoc and eglot-managed shadows are the planned next passengers.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'bytecomp)   ; the in-process elisp backend let-binds its variables
(require 'jetpacs)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)  ; face→span-style resolution for fontify pushes

(defcustom jetpacs-sync-diagnostics t
  "When non-nil, run flymake over synced editor buffers and push results.
Each check may spawn a subprocess (elisp byte-compile, external linters),
which costs CPU on the machine running Emacs — set to nil on battery-
constrained setups to keep sync (and completion) without diagnostics."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-sync-diagnostics-delay 3.0
  "Seconds after an edit before collected diagnostics are pushed.
Long enough for flymake's own no-changes timeout plus a typical backend
run; each new delta re-arms the timer, so pushes happen once per pause
in typing, not once per delta."
  :type 'number :group 'jetpacs)

(defcustom jetpacs-sync-eldoc t
  "When non-nil, answer the editor's caret reports with eldoc content.
The phone shows the result (e.g. an elisp function signature with the
current argument) in a line above the keyboard.  Only synchronous
eldoc backends contribute; async ones (LSP) land with the eglot phase."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-sync-fontify t
  "When non-nil, push Emacs's own fontification to the phone editor.
After each edit the session buffer is font-locked and its face runs
ship as a `fontify.show' frame — so the editor shows the user's real
theme and every mode Emacs can highlight, with the client-side
highlighter only bridging the moments between keystroke and reply.
Set to nil to fall back to client-side highlighting entirely."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-sync-fontify-max-chars 65536
  "Buffers larger than this skip fontify pushes.
Whole-buffer fontification and run extraction happen synchronously in
the delta handler; past this size the client-side highlighter is the
better trade."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-sync-eglot t
  "When non-nil, LSP-able files sync into their real buffers with eglot.
Files whose mode is in `jetpacs-sync-eglot-modes' are visited for real
\(`find-file-noselect') instead of shadowed in memory, and `eglot-ensure'
runs there — so the language server sees true paths and project roots,
and every phone edit becomes an incremental didChange.  Servers must be
findable on `exec-path' (on Android, Termux's usr/bin via the shared-uid
build)."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-sync-eglot-modes
  '(python-mode python-ts-mode sh-mode bash-ts-mode
    c-mode c-ts-mode c++-mode c++-ts-mode rust-mode rust-ts-mode)
  "Major modes whose files use the real-buffer + eglot session strategy.
Everything else uses the hidden in-memory shadow (elisp and org never
need a language server; their in-process backends are better)."
  :type '(repeat symbol) :group 'jetpacs)

(defvar jetpacs-sync-shadow-setup-hook nil
  "Hook run in each freshly created shadow buffer, after its major mode.
Shadows are initialized with `delay-mode-hooks', so ordinary mode hooks
— and any buffer-local capfs or eldoc functions your init adds there —
never run.  Use this hook to opt specific setup back in, e.g.:

  (add-hook \\='jetpacs-sync-shadow-setup-hook
            (lambda ()
              (when (derived-mode-p \\='org-mode)
                (add-hook \\='completion-at-point-functions
                          #\\='my/org-tag-completion nil t))))

Runs for both the session shadows here and the v1 completion shadows.")

;; ─── Session registry ────────────────────────────────────────────────────────

(defvar jetpacs-sync--sessions (make-hash-table :test 'equal)
  "Map of file -> session plist.
Keys: :session (phone-chosen id), :seq (last applied delta), :stale
\(mismatch seen; swallow deltas until re-open), :collect-timer,
:last-diags (last pushed diagnostics, or the symbol `unset').")

(defun jetpacs-sync--buffer-name (file)
  (format " *jetpacs-sync: %s*" file))

(defun jetpacs-sync--mode-for (file)
  "The major mode FILE would get from `auto-mode-alist', or `fundamental-mode'.
Never visits FILE — the mode is chosen from the name alone.  Honors
`major-mode-remap-alist' like `find-file' does, so a config that remaps
to tree-sitter modes (python-ts-mode & co.) gets them in the hidden
shadows too, not just in real-file eglot buffers."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (when (and (symbolp mode) mode)
      (setq mode (cond
                  ((fboundp 'major-mode-remap) (major-mode-remap mode))
                  ((bound-and-true-p major-mode-remap-alist)
                   (or (cdr (assq mode major-mode-remap-alist)) mode))
                  (t mode))))
    (if (and (symbolp mode) mode (fboundp mode)) mode 'fundamental-mode)))

(defvar-local jetpacs-sync--prepared nil
  "Non-nil once a real-file session buffer has been prepared.")

(defun jetpacs-sync--eglot-file-p (file)
  "Non-nil when FILE should sync into its real buffer under eglot."
  (and jetpacs-sync-eglot
       (memq (jetpacs-sync--mode-for file) jetpacs-sync-eglot-modes)
       (file-exists-p file)
       (require 'eglot nil t)))

(declare-function eglot-current-server "eglot")
(declare-function eglot--guess-contact "eglot")
(declare-function eglot--connect "eglot")
(defvar eglot-sync-connect)

(defvar-local jetpacs-sync--eglot-attempt 0
  "When the last eglot connect attempt started, as a float-time.")

(defun jetpacs-sync--ensure-eglot ()
  "Connect the current real-file buffer to its language server, if any.
NOT `eglot-ensure': that defers the connect to `post-command-hook',
which never fires in an Emacs driven headless through a socket — the
same trap as flymake's deferred start.  Connect directly instead,
fully async (`eglot-sync-connect' nil) so the action handler never
blocks on a cold server.  No server program, or a missing executable,
degrades silently to the non-LSP experience.  The attempt timestamp
stops a reopen from racing a still-initializing connect into a second
server process."
  (when (and (fboundp 'eglot-current-server)
             (fboundp 'eglot--guess-contact)
             (not (ignore-errors (eglot-current-server)))
             (> (- (float-time) jetpacs-sync--eglot-attempt) 30))
    (setq jetpacs-sync--eglot-attempt (float-time))
    (condition-case err
        (let ((eglot-sync-connect nil))
          (apply #'eglot--connect (eglot--guess-contact)))
      (error
       (when (bound-and-true-p jetpacs-complete-debug)
         (message "Jetpacs sync: eglot connect failed: %s"
                  (error-message-string err)))))))

(defun jetpacs-sync--prepare-real-buffer (buf)
  "Per-open session setup for a real file buffer BUF; returns BUF.
The buffer-local pieces run once; the eglot connect attempt runs on
every open, so a server the OS reaped while backgrounded comes back
the next time the file is opened on the phone."
  (with-current-buffer buf
    (unless jetpacs-sync--prepared
      (setq jetpacs-sync--prepared t)
      ;; Phone keystrokes must not litter #autosave# files; the phone's
      ;; explicit Save owns persistence.
      (setq-local buffer-auto-save-file-name nil)
      (run-hooks 'jetpacs-sync-shadow-setup-hook))
    (jetpacs-sync--ensure-eglot))
  buf)

(defun jetpacs-sync--buffer (file)
  "Get or create the session buffer for FILE.
LSP-able files (`jetpacs-sync-eglot-modes') sync into their REAL buffer via
`find-file-noselect', so eglot sees true paths and project roots and
every applied delta becomes an incremental didChange.  Everything else
gets the hidden in-memory shadow: right major mode for live capfs and
flymake backends, `delay-mode-hooks' so no heavyweight tooling attaches,
leading-space name so it stays out of buffer lists."
  (if (jetpacs-sync--eglot-file-p file)
      (jetpacs-sync--prepare-real-buffer (find-file-noselect file))
    (jetpacs-sync--hidden-shadow file)))

(defun jetpacs-sync--hidden-shadow (file)
  "Get or create the hidden in-memory shadow buffer for FILE."
  (let ((name (jetpacs-sync--buffer-name file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          ;; A mode whose init signals (heavier modes can, on the Android
          ;; build) must not take the whole session down with it — fall
          ;; back to fundamental-mode, where word completion still works.
          (condition-case err
              (delay-mode-hooks (funcall (jetpacs-sync--mode-for file)))
            (error
             (message "Jetpacs sync: %s init failed (%s); shadow is fundamental"
                      (jetpacs-sync--mode-for file) (error-message-string err))
             (delay-mode-hooks (fundamental-mode))))
          (when (derived-mode-p 'emacs-lisp-mode)
            (setq-local jetpacs-sync--elisp-repl
                        (and (member file jetpacs-sync-elisp-repl-files) t))
            ;; The stock backend spawns a second Emacs, which the Android
            ;; port cannot do (Emacs there is a shared library inside an
            ;; app process, not a spawnable executable) — swap in the
            ;; in-process backend (see `jetpacs-sync--flymake-elisp').
            (remove-hook 'flymake-diagnostic-functions
                         #'elisp-flymake-byte-compile t)
            (add-hook 'flymake-diagnostic-functions
                      #'jetpacs-sync--flymake-elisp nil t))
          (run-hooks 'jetpacs-sync-shadow-setup-hook)
          (current-buffer)))))

(defun jetpacs-sync-session (file)
  "Return FILE's live session plist, or nil when absent or stale."
  (let ((st (gethash file jetpacs-sync--sessions)))
    (and st (not (plist-get st :stale)) st)))

(defun jetpacs-sync-session-buffer (file session seq)
  "Return FILE's session buffer when SESSION and SEQ match the live state.
This is the gate the slim completion path uses: a match guarantees the
buffer text is exactly what the phone editor shows."
  (let* ((st (jetpacs-sync-session file))
         (buf (and st (plist-get st :buffer))))
    (and st
         (equal session (plist-get st :session))
         (equal seq (plist-get st :seq))
         (buffer-live-p buf)
         buf)))

;; ─── Resync ──────────────────────────────────────────────────────────────────

(defun jetpacs-sync-request-resync (file session)
  "Mark FILE's session stale and ask the phone for a fresh edit.open.
Stale sessions swallow further deltas silently, so one desync costs one
resync frame, not one per queued delta."
  (let ((st (gethash file jetpacs-sync--sessions)))
    (if st
        (puthash file (plist-put st :stale t) jetpacs-sync--sessions)
      ;; Unknown file (e.g. Emacs restarted mid-session): a stale
      ;; placeholder absorbs the rest of the in-flight delta burst.
      (puthash file (list :session session :seq -1 :stale t)
               jetpacs-sync--sessions)))
  (jetpacs-send "edit.resync" `((id . ,file) (session . ,session))))

;; ─── Diagnostics ─────────────────────────────────────────────────────────────

(defun jetpacs-sync--severity (type)
  "Map a flymake diagnostic TYPE to \"error\", \"warning\", or \"note\"."
  (pcase (condition-case nil
             (flymake--lookup-type-property type 'flymake-category)
           (error nil))
    ('flymake-error "error")
    ('flymake-note "note")
    (_ "warning")))

(defun jetpacs-sync--collect-and-push (file)
  "Push FILE's current flymake diagnostics if they changed since last push.
Positions go out as 0-based code-point offsets (buffer position - 1);
the frame carries the seq they were computed against so the phone can
refuse to draw squiggles over text that has moved on."
  (let* ((st (jetpacs-sync-session file))
         (buf (and st (plist-get st :buffer))))
    (when (and st (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((diags (mapcar
                       (lambda (d)
                         `((beg . ,(1- (flymake-diagnostic-beg d)))
                           (end . ,(1- (flymake-diagnostic-end d)))
                           (type . ,(jetpacs-sync--severity
                                     (flymake-diagnostic-type d)))
                           (text . ,(or (flymake-diagnostic-text d) ""))))
                       (flymake-diagnostics)))
               ;; The dedupe stamp includes the seq: the phone only renders
               ;; a push whose seq matches its editor, so content-identical
               ;; diagnostics recomputed after an edit (e.g. break + undo)
               ;; must still go out — otherwise squiggles never reappear.
               (stamp (cons (plist-get st :seq) diags)))
          (let ((changed (not (equal stamp (plist-get st :last-diags)))))
            (when changed
              (puthash file (plist-put st :last-diags stamp)
                       jetpacs-sync--sessions)
              (jetpacs-send "diagnostics.show"
                         `((id . ,file)
                           (session . ,(plist-get st :session))
                           (seq . ,(plist-get st :seq))
                           (diags . ,(vconcat diags)))))
            ;; LSP servers publish asynchronously — the publish hook above
            ;; catches late arrivals, and this bounded chase covers servers
            ;; without notifications. Stops after THREE quiet rounds; zero
            ;; cost once stable.
            (let ((quiet (if changed 0
                           (1+ (or (plist-get st :quiet-collects) 0)))))
              (puthash file (plist-put st :quiet-collects quiet)
                       jetpacs-sync--sessions)
              (when (< quiet 3)
                (puthash file
                         (plist-put st :collect-timer
                                    (run-at-time jetpacs-sync-diagnostics-delay
                                                 nil
                                                 #'jetpacs-sync--collect-and-push
                                                 file))
                         jetpacs-sync--sessions)))))))))

(defun jetpacs-sync--arm-diagnostics (file)
  "(Re)arm FILE's diagnostics collection after an edit.
Enables flymake in the shadow on first use (only when the mode installed
real backends — an org or plain-text shadow never spawns checkers), then
schedules one collect+push `jetpacs-sync-diagnostics-delay' out.  Repeated
deltas keep pushing the timer back, so diagnostics cost one flymake pass
per pause in typing."
  (when jetpacs-sync-diagnostics
    (let* ((st (jetpacs-sync-session file))
           ;; The session's OWN buffer — for eglot sessions that's the real
           ;; file buffer, not the hidden shadow name (missing this lookup
           ;; silently disarmed diagnostics for every LSP session).
           (buf (and st (plist-get st :buffer))))
      (when (and st (buffer-live-p buf))
        (with-current-buffer buf
          (when (remq t flymake-diagnostic-functions)
            (unless flymake-mode (flymake-mode 1))
            ;; Kick a check explicitly on EVERY edit, not just at enable:
            ;; flymake's own rescheduling rides idle/post-command timers
            ;; that are unreliable while Emacs runs headless in the
            ;; background on Android.  The elisp backend is in-process and
            ;; cheap, and this runs once per pause in typing.
            (ignore-errors (flymake-start))))
        (when-let ((tm (plist-get st :collect-timer)))
          (cancel-timer tm))
        ;; A fresh edit restarts the quiet-round counter for the chase.
        (puthash file (plist-put st :quiet-collects 0) jetpacs-sync--sessions)
        (puthash file
                 (plist-put st :collect-timer
                            (run-at-time jetpacs-sync-diagnostics-delay nil
                                         #'jetpacs-sync--collect-and-push file))
                 jetpacs-sync--sessions)))))

;; ─── Eldoc ───────────────────────────────────────────────────────────────────

(defun jetpacs-sync--format-docs (docs)
  "Join collected eldoc DOCS into one capped line, or nil when empty.
Each doc is (STRING . PLIST); rendered as \"THING: FIRST-LINE\"."
  (when docs
    (truncate-string-to-width
     (mapconcat
      (lambda (d)
        (let ((line (car (split-string (substring-no-properties (car d))
                                       "\n")))
              (thing (plist-get (cdr d) :thing)))
          (if thing (format "%s: %s" thing line) line)))
      (reverse docs) "  •  ")
     200)))

(defun jetpacs-sync--eldoc-deliver (file session docs)
  "Push DOCS for FILE's SESSION as an eldoc.show frame, deduped.
Safe to call any number of times per caret round — synchronous
backends deliver during the handler, async ones (LSP hover) whenever
their reply lands; the phone simply renders the latest.  Transitions
to empty push too, so the doc line clears when the cursor leaves."
  (let ((st (jetpacs-sync-session file)))
    (when (and st (equal session (plist-get st :session)))
      (let ((text (jetpacs-sync--format-docs docs)))
        (unless (equal text (plist-get st :last-eldoc))
          (puthash file (plist-put st :last-eldoc text)
                   jetpacs-sync--sessions)
          (jetpacs-send "eldoc.show"
                     `((id . ,file)
                       (session . ,session)
                       (text . ,(or text "")))))))))

(defun jetpacs-sync--run-eldoc (file session)
  "Run the buffer's eldoc backends at point; deliver results to the phone.
Synchronous backends (all the elisp ones) deliver before this returns.
Async backends — eglot's LSP hover — invoke the collecting closure
later, from the jsonrpc filter, and each late arrival re-delivers the
accumulated docs.  Point may have moved by then; the closure never
touches the buffer, only strings already handed to it."
  (let (docs)
    (run-hook-wrapped
     'eldoc-documentation-functions
     (lambda (fn)
       (condition-case nil
           (let ((r (funcall fn (lambda (doc &rest plist)
                                  (when (stringp doc)
                                    (push (cons doc plist) docs)
                                    (jetpacs-sync--eldoc-deliver
                                     file session docs))))))
             (when (stringp r) (push (cons r nil) docs)))
         (error nil))
       nil))                            ; nil → run every backend
    (jetpacs-sync--eldoc-deliver file session docs)))

(jetpacs-defaction "edit.caret"
  ;; Best-effort by design: a mismatched session/seq (the caret raced a
  ;; delta) just yields nothing — the delta path owns resync, and the
  ;; next caret report lands on fresh state anyway.
  (lambda (args _)
    (when jetpacs-sync-eldoc
      (let ((file (alist-get 'file args))
            (session (alist-get 'session args))
            (seq (alist-get 'seq args))
            (cursor (alist-get 'cursor args)))
        (when (and (stringp file) (numberp session)
                   (numberp seq) (numberp cursor))
          (when-let ((buf (jetpacs-sync-session-buffer file session seq)))
            (with-current-buffer buf
              (save-excursion
                (goto-char (min (1+ (max 0 (truncate cursor)))
                                (point-max)))
                (jetpacs-sync--run-eldoc file session)))))))))

;; ─── In-process elisp flymake backend ────────────────────────────────────────
;;
;; `elisp-flymake-byte-compile' isolates compilation in a freshly spawned
;; "emacs -batch".  On the Android port there is no Emacs executable to
;; spawn — Emacs is a shared library inside an app process — and Android's
;; phantom-process killer reaps background children anyway.  So elisp
;; shadows use this backend instead: a paren-balance scan plus an
;; in-process `byte-compile-file' over a temp copy.  Same warnings, no
;; subprocess, and instant even on slow devices.

(defvar jetpacs-sync-elisp-repl-files nil
  "Editor ids whose elisp shadows hold REPL input rather than a file.
REPL input is evaluated with lexical binding (`eval' with LEXICAL t),
so these shadows byte-compile their diagnostics copy with a
`lexical-binding: t' cookie line prepended: warnings match eval
semantics, and the no-cookie warning — noise against a one-expression
REPL line — can never fire.  Views register their editor id here (the
eval REPL adds \"eval.el\").")

(defvar-local jetpacs-sync--elisp-repl nil
  "Non-nil in the session shadow of an `jetpacs-sync-elisp-repl-files' entry.")

(defun jetpacs-sync--elisp-paren-diags ()
  "Unbalanced-paren diagnostics for the current buffer, or nil."
  (save-excursion
    (condition-case err
        (let ((pos (point-min)))
          (while (setq pos (scan-sexps pos 1)))
          nil)
      (scan-error
       (let* ((beg (min (max (point-min) (or (nth 2 err) (point-min)))
                        (point-max)))
              (end (min (max (1+ beg) (or (nth 3 err) beg)) (point-max))))
         (list (flymake-make-diagnostic
                (current-buffer) beg end :error
                (or (nth 1 err) "Unbalanced parentheses"))))))))

(defun jetpacs-sync--elisp-compile-diags ()
  "In-process byte-compile diagnostics for the current buffer.
Compiles a temp copy so nothing touches the user's files.  File shadows
copy the text verbatim, so warning positions map straight back; REPL
shadows (`jetpacs-sync--elisp-repl') get a `lexical-binding: t' cookie
line prepended — matching how the REPL evaluates — and positions are
shifted back by the cookie's length."
  (let* ((cookie (if jetpacs-sync--elisp-repl
                     ";;; -*- lexical-binding: t; -*-\n"
                   ""))
         (shift (length cookie))
         (src (concat cookie (buffer-substring-no-properties
                              (point-min) (point-max))))
         (buf (current-buffer))
         (tmp (make-temp-file "jetpacs-flymake" nil ".el"))
         diags)
    (unwind-protect
        (let ((coding-system-for-write 'utf-8))
          (write-region src nil tmp nil 'silent)
          (let ((byte-compile-log-warning-function
                 (lambda (string &optional position _fill level)
                   (with-current-buffer buf
                     (let* ((beg (min (max (point-min)
                                           (- (if (numberp position) position 1)
                                              shift))
                                      (point-max)))
                            ;; Underline the whole form at the position.
                            (end (min (or (ignore-errors (scan-sexps beg 1))
                                          (1+ beg))
                                      (point-max))))
                       (push (flymake-make-diagnostic
                              buf beg (max end (min (1+ beg) (point-max)))
                              (if (eq level :error) :error :warning)
                              string)
                             diags)))))
                (inhibit-message t))
            (ignore-errors (byte-compile-file tmp))))
      (ignore-errors (delete-file tmp))
      (ignore-errors (delete-file (byte-compile-dest-file tmp))))
    (nreverse diags)))

(defun jetpacs-sync--flymake-elisp (report-fn &rest _)
  "Flymake backend for elisp shadow buffers: no subprocesses, ever.
Reports unbalanced parens directly (byte-compiling unbalanced input
yields one useless end-of-file error), otherwise in-process compile
warnings — wrong arity, unused lexical variables, undefined functions."
  (funcall report-fn
           (or (jetpacs-sync--elisp-paren-diags)
               (jetpacs-sync--elisp-compile-diags))))

;; ─── LSP publish → immediate collect ─────────────────────────────────────────
;;
;; The polling chase alone loses a race on cold servers: pylsp's first
;; publish on a phone can take longer than the quiet-round budget, and a
;; publish that lands after the chain stopped went nowhere until the next
;; keystroke.  Event-driven instead: the moment eglot receives a
;; publishDiagnostics notification for a synced file, collect shortly
;; after (the small delay lets eglot hand the report to flymake first).

(defun jetpacs-sync--session-for-path (path)
  "The session FILE key whose buffer visits PATH, or nil."
  (let ((true (ignore-errors (file-truename path)))
        found)
    (when true
      (maphash (lambda (file st)
                 (when-let ((buf (plist-get st :buffer)))
                   (when (and (not found)
                              (buffer-live-p buf)
                              (buffer-file-name buf)
                              (equal (ignore-errors
                                       (file-truename (buffer-file-name buf)))
                                     true))
                     (setq found file))))
               jetpacs-sync--sessions))
    found))

(with-eval-after-load 'eglot
  (add-hook 'eglot-managed-mode-hook
            (lambda ()
              (when (eglot-current-server)
                (when-let* ((buf-file (buffer-file-name))
                            (file (jetpacs-sync--session-for-path buf-file)))
                  (jetpacs-sync--arm-diagnostics file)))))

  (cl-defmethod eglot-handle-notification :after
    (_server (_method (eql textDocument/publishDiagnostics))
             &key uri &allow-other-keys)
    "Collect for the synced file the server just diagnosed."
    (when jetpacs-sync-diagnostics
      (when-let* ((path (ignore-errors
                          (if (fboundp 'eglot-uri-to-path)
                              (eglot-uri-to-path uri)
                            (eglot--uri-to-path uri))))
                  (file (jetpacs-sync--session-for-path path)))
        (run-at-time 0.5 nil #'jetpacs-sync--collect-and-push file)))))

;; ─── Fontification push ──────────────────────────────────────────────────────
;;
;; The other direction of "Emacs owns styling": the same face→span
;; resolution Tier 0 uses for read-only buffers, applied to the live
;; editor.  After each applied delta the session buffer is font-locked
;; and its face runs ship to the phone as 0-based code-point ranges.
;; The phone renders them whenever its text matches the stamped seq and
;; falls back to its client-side highlighter in the gaps — Emacs colors
;; at rest, approximation only while a keystroke is in flight.

(defun jetpacs-sync--fontify-runs ()
  "Face runs for the current buffer as wire alists.
Each run is ((b . BEG) (e . END) [(c . \"#RRGGBB\")] [(bold . t)] ...)
with 0-based code-point offsets.  Unstyled stretches ship nothing."
  (ignore-errors (font-lock-ensure))
  (let ((jetpacs-buffer--default-fg-hex
         (jetpacs-buffer--color-hex (face-attribute 'default :foreground nil t)))
        (jetpacs-buffer--default-bg-hex
         (jetpacs-buffer--color-hex (face-attribute 'default :background nil t)))
        (pos (point-min))
        runs)
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos 'face nil (point-max)))
            (style (jetpacs-buffer--span-style (get-text-property pos 'face))))
        (when style
          (push (append
                 `((b . ,(1- pos)) (e . ,(1- next)))
                 (when-let ((c (plist-get style :color))) `((c . ,c)))
                 (when-let ((bg (plist-get style :bg))) `((bg . ,bg)))
                 (when (plist-get style :bold) '((bold . t)))
                 (when (plist-get style :italic) '((italic . t)))
                 (when (plist-get style :underline) '((underline . t)))
                 (when (plist-get style :strike) '((strike . t))))
                runs))
        (setq pos next)))
    (nreverse runs)))

(defun jetpacs-sync--push-fontify (file)
  "Push FILE's current fontification, seq-stamped and deduped.
Like diagnostics, the stamp includes the seq: identical runs after an
edit still re-push, because the phone hides anything stamped stale."
  (when jetpacs-sync-fontify
    (let* ((st (jetpacs-sync-session file))
           (buf (and st (plist-get st :buffer))))
      (when (and st (buffer-live-p buf)
                 (<= (buffer-size buf) jetpacs-sync-fontify-max-chars))
        (with-current-buffer buf
          (let* ((runs (jetpacs-sync--fontify-runs))
                 (stamp (cons (plist-get st :seq) runs)))
            (unless (equal stamp (plist-get st :last-fontify))
              (puthash file (plist-put st :last-fontify stamp)
                       jetpacs-sync--sessions)
              (jetpacs-send "fontify.show"
                         `((id . ,file)
                           (session . ,(plist-get st :session))
                           (seq . ,(plist-get st :seq))
                           (runs . ,(vconcat runs)))))))))))

;; ─── Delta application ───────────────────────────────────────────────────────

(defun jetpacs-sync-open (file session text)
  "Seed (or reseed) FILE's session buffer with TEXT under SESSION, seq 0."
  (let ((buf (jetpacs-sync--buffer file)))
    (with-current-buffer buf
      ;; Real-file buffers usually already hold exactly this text (the
      ;; phone was seeded from them) — skip the no-op replacement so the
      ;; buffer isn't marked modified and eglot sees no phantom change.
      (unless (and (= (buffer-size) (length text))
                   (equal (buffer-string) text))
        (erase-buffer)
        (insert text)))
    (let ((old (gethash file jetpacs-sync--sessions)))
      (when-let ((tm (and old (plist-get old :collect-timer))))
        (cancel-timer tm)))
    ;; `unset' (not nil) so the first collect always pushes — the phone may
    ;; have dropped its diagnostics when it re-opened.
    (puthash file (list :session session :seq 0 :buffer buf
                        :last-diags 'unset)
             jetpacs-sync--sessions))
  (jetpacs-sync--arm-diagnostics file)
  (jetpacs-sync--push-fontify file))

(defun jetpacs-sync-apply-delta (file session seq start del text len)
  "Apply one splice to FILE's shadow; non-nil on success.
The splice replaces DEL code points at 0-based offset START with TEXT.
Applies only when SESSION matches and SEQ is exactly one past the last
applied delta; LEN (the phone's resulting document length) is verified
after the splice.  Any mismatch triggers one resync round instead."
  (let* ((raw (gethash file jetpacs-sync--sessions))
         (st (and raw (not (plist-get raw :stale)) raw)))
    (cond
     ;; Already stale: the resync was requested when the mismatch was
     ;; first seen — swallow the rest of the in-flight burst silently.
     ((and raw (plist-get raw :stale)) nil)
     ((not (and st
                (equal session (plist-get st :session))
                (equal seq (1+ (plist-get st :seq)))
                (buffer-live-p (plist-get st :buffer))))
      (jetpacs-sync-request-resync file session)
      nil)
     (t
      (with-current-buffer (plist-get st :buffer)
        (let* ((beg (min (1+ (max 0 start)) (point-max)))
               (end (min (+ beg (max 0 del)) (point-max))))
          (delete-region beg end)
          (goto-char beg)
          (insert text))
        (if (and (numberp len) (/= (buffer-size) len))
            (progn (jetpacs-sync-request-resync file session) nil)
          (puthash file (plist-put st :seq seq) jetpacs-sync--sessions)
          (jetpacs-sync--arm-diagnostics file)
          (jetpacs-sync--push-fontify file)
          t))))))

(defun jetpacs-sync-close (file)
  "Tear down FILE's session: cancel timers, drop state, kill the shadow.
Only hidden in-memory shadows are killed — a real file buffer (the
eglot strategy) may belong to the user, and keeping it also keeps the
language server warm for the next open."
  (let ((st (gethash file jetpacs-sync--sessions)))
    (when-let ((tm (and st (plist-get st :collect-timer))))
      (cancel-timer tm)))
  (remhash file jetpacs-sync--sessions)
  (when-let ((buf (get-buffer (jetpacs-sync--buffer-name file))))
    (kill-buffer buf)))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "edit.open"
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (session (alist-get 'session args))
          (text (alist-get 'text args)))
      (when (and (stringp file) (stringp text) (numberp session))
        (jetpacs-sync-open file session text)
        (when (bound-and-true-p jetpacs-complete-debug)
          (message "Jetpacs sync: open %s session=%s len=%d mode=%s"
                   (file-name-nondirectory file) session (length text)
                   (with-current-buffer (jetpacs-sync--buffer file)
                     major-mode)))))))

(jetpacs-defaction "edit.delta"
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (session (alist-get 'session args))
          (seq (alist-get 'seq args))
          (start (alist-get 'start args))
          (del (alist-get 'del args))
          (text (alist-get 'text args))
          (len (alist-get 'len args)))
      (when (and (stringp file) (numberp session) (numberp seq)
                 (numberp start) (numberp del) (stringp text))
        (let ((ok (jetpacs-sync-apply-delta file session seq start del text len)))
          (when (bound-and-true-p jetpacs-complete-debug)
            (message "Jetpacs sync: delta %s seq=%s %s"
                     (file-name-nondirectory file) seq
                     (if ok "applied" "REJECTED (resync)"))))))))

(jetpacs-defaction "edit.close"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (stringp file)
        (jetpacs-sync-close file)))))

(provide 'jetpacs-sync)
;;; jetpacs-sync.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-complete.el
;;; ==================================================================

;;; jetpacs-complete.el --- Completion-at-point bridge (Tier 0 IDE) -*- lexical-binding: t; -*-

;; Brings Emacs completion to the phone editor.  The companion sends an
;; `edit.complete' action with a window of the editor's text and the cursor
;; position; this module replays that text into a hidden shadow buffer with
;; the file's major mode, runs the buffer's own
;; `completion-at-point-functions', and replies with a `completions.show'
;; frame carrying the completed prefix plus candidate labels/annotations.
;; The phone renders them as a suggestion strip above the keyboard and
;; applies the accepted candidate locally — no round-trip on insert.
;;
;; Corfu/company/posframe never enter the picture: they are UIs over capf,
;; and the phone brings its own UI.  Emacs is the completion *server*.
;;
;; The shadow buffer never visits the file (no disk access, no LSP session,
;; no mode hooks — see `delay-mode-hooks' below), so a completion request
;; can't mutate anything.  This keeps the command-dispatch boundary intact:
;; `edit.complete' is a pure query.
;;
;; v2 (planned): incremental delta sync into the shadow buffer + eglot
;; integration, turning Emacs into a language-server multiplexer for the
;; phone.  The wire shapes here are designed to survive that upgrade.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-surfaces)
(require 'jetpacs-sync)

(defcustom jetpacs-complete-enabled t
  "When non-nil, the phone editor offers Emacs-backed completion.
Set to nil to stop the companion from issuing completion requests
entirely (the editor node is pushed without its `complete' flag)."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-complete-max-candidates 30
  "Maximum number of candidates returned per completion request.
The phone strip shows a handful; anything past this cap is wasted
bytes on the wire."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-complete-debug nil
  "When non-nil, echo each completion request to *Messages*.
Each `edit.complete' from the phone logs the file, the prefix it
resolved, and how many candidates it returned — a live trace of the
bridge working, without a device attached to logcat.  Development aid;
leave nil in normal use."
  :type 'boolean :group 'jetpacs)

;; ─── Shadow buffers ──────────────────────────────────────────────────────────

(defun jetpacs-complete--shadow-buffer (file)
  "Get or create the hidden shadow buffer for FILE.
The buffer carries FILE's major mode so the right capfs are live, but
mode hooks are delayed: no LSP client, flycheck, or other machinery
spins up over a throwaway completion buffer.  The leading space in the
name keeps it out of buffer lists and disables undo."
  (let ((name (format " *jetpacs-complete: %s*" file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (condition-case nil
              (delay-mode-hooks (funcall (jetpacs-sync--mode-for file)))
            (error (delay-mode-hooks (fundamental-mode))))
          (run-hooks 'jetpacs-sync-shadow-setup-hook)
          (current-buffer)))))

;; ─── Candidate harvesting ────────────────────────────────────────────────────

(defun jetpacs-complete--capf-data ()
  "Run the buffer's capfs at point; return (BEG END TABLE . PROPS) or nil.
A capf that signals — e.g. text-mode's `ispell-completion-at-point'
with no dictionary installed — counts as producing nothing, so the
generic word fallback still gets its turn."
  (let ((res (condition-case nil
                 (run-hook-wrapped 'completion-at-point-functions
                                   #'completion--capf-wrapper 'all)
               (error nil))))
    (when (and (consp res) (consp (cdr res)) (numberp (cadr res)))
      (cdr res))))

(defun jetpacs-complete--word-fallback ()
  "Dabbrev-style fallback: words in the buffer sharing the token at point.
Returns (PREFIX . CANDIDATES) or nil.  Used when no capf produces
anything — plain text, org prose, unknown modes — so the strip is never
uselessly empty in a buffer full of repeated identifiers."
  (let* ((end (point))
         (beg (save-excursion (skip-syntax-backward "w_") (point))))
    (when (< beg end)
      (let ((prefix (buffer-substring-no-properties beg end))
            (case-fold-search nil)
            cands)
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward
                  (concat "\\_<" (regexp-quote prefix) "\\(?:\\sw\\|\\s_\\)+")
                  nil t)
            ;; Skip the token being completed itself.
            (unless (= (match-beginning 0) beg)
              (cl-pushnew (match-string-no-properties 0) cands :test #'equal))))
        (when cands (cons prefix (nreverse cands)))))))

(defun jetpacs-complete--annotate (fn cand)
  "Apply annotation function FN to CAND, trimmed; nil when absent or failing."
  (when fn
    (let ((a (condition-case nil (funcall fn cand) (error nil))))
      (when (and (stringp a) (not (string-empty-p (string-trim a))))
        (string-trim a)))))

(defun jetpacs-complete--collect ()
  "Harvest completions at point in the current buffer.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Each candidate node is an
alist of `label' plus optional `annotation' and `kind', ready for
serialization.  Candidates are sorted shortest-first (the likeliest
next keystroke saver), capped at `jetpacs-complete-max-candidates'."
  (let* ((data (jetpacs-complete--capf-data))
         (beg (nth 0 data))
         (table (nth 2 data))
         (props (nthcdr 3 data))
         (ann-fn (plist-get props :annotation-function))
         (kind-fn (plist-get props :company-kind))
         ;; Optional capf extension (SPEC §8): what a candidate INSERTS
         ;; when it differs from its display label — a wikilink chip
         ;; shows "[[Title" but lands "[[id:…][Title]]" in the buffer.
         (insert-fn (plist-get props :jetpacs-insert-function))
         ;; The phone replaces text *before* the cursor, so the prefix is
         ;; [BEG, point) even when the capf's END extends past point.
         (prefix (and data (buffer-substring-no-properties beg (point))))
         ;; Lazy tables can signal when queried (ispell again), hence the
         ;; condition-case: a broken table degrades to the fallback.
         (cands (and prefix
                     (condition-case nil
                         (all-completions prefix table
                                          (plist-get props :predicate))
                       (error nil))))
         ;; An empty prefix is legitimate LSP member completion (right
         ;; after "." the server returns a small, precise list) but on an
         ;; unconstrained table (elisp's obarray) it means *everything* —
         ;; keep the former, drop the latter by sheer size.
         (cands (if (and cands (string-empty-p prefix)
                         (> (length cands) 500))
                    nil
                  cands)))
    ;; Empty capf result → generic word fallback (org prose, unknown modes).
    (unless cands
      (when-let ((fb (jetpacs-complete--word-fallback)))
        (setq prefix (car fb) cands (cdr fb)
              ann-fn nil kind-fn nil insert-fn nil)))
    (when cands
      (setq cands (sort (delete-dups
                         (mapcar #'substring-no-properties cands))
                        (lambda (a b) (or (< (length a) (length b))
                                          (and (= (length a) (length b))
                                               (string< a b))))))
      ;; Sole candidate == what's already typed: nothing to offer.
      (setq cands (delete prefix cands))
      (when cands
        (cons prefix
              (mapcar (lambda (c)
                        `((label . ,c)
                          ,@(when-let ((a (jetpacs-complete--annotate ann-fn c)))
                              `((annotation . ,a)))
                          ,@(when-let ((ins (and insert-fn
                                                 (condition-case nil
                                                     (funcall insert-fn c)
                                                   (error nil)))))
                              (and (stringp ins) (not (equal ins c))
                                   `((insert . ,ins))))
                          ,@(when-let ((k (and kind-fn
                                               (condition-case nil
                                                   (funcall kind-fn c)
                                                 (error nil)))))
                              `((kind . ,(symbol-name k))))))
                      (seq-take cands jetpacs-complete-max-candidates)))))))

(defun jetpacs-complete-in-text (file text cursor)
  "Complete FILE's TEXT at CURSOR (a 0-based offset into TEXT).
Replays TEXT into FILE's shadow buffer and harvests candidates there.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Separated from the action
handler so tests can call it directly.

This is the v1 windowed path, kept as the fallback for clients that
ship text with the request; the slim path is `jetpacs-complete-in-session'."
  (with-current-buffer (jetpacs-complete--shadow-buffer file)
    (erase-buffer)
    (insert text)
    (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
    (jetpacs-complete--collect)))

(defun jetpacs-complete-in-session (file session seq cursor)
  "Complete in FILE's synced session shadow at CURSOR (0-based code points).
The v2 slim path: no text crosses the wire because jetpacs-sync already
holds the whole document.  SESSION and SEQ must match the live sync
state exactly — a mismatch means the phone edited past us, so reply
nothing and ask for a resync instead of completing against stale text.
Returns (PREFIX . CANDIDATE-NODES) or nil."
  (let ((buf (jetpacs-sync-session-buffer file session seq)))
    (if (not buf)
        (progn (jetpacs-sync-request-resync file session) nil)
      (with-current-buffer buf
        (save-excursion
          (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
          (jetpacs-complete--collect))))))

;; ─── Action handler ──────────────────────────────────────────────────────────

;; Reply shape: the phone recomputes the replace range as
;; [cursor - length(prefix), cursor) in its own string units and validates
;; the prefix still sits there before applying — so no absolute offsets
;; cross the wire and a stale reply degrades to "strip doesn't show",
;; never to a wrong edit.
(jetpacs-defaction "edit.complete"
  (lambda (args _)
    (when jetpacs-complete-enabled
      (let ((file (alist-get 'file args))
            (req (alist-get 'request_id args))
            (text (alist-get 'text args))
            (session (alist-get 'session args))
            (seq (alist-get 'seq args))
            (cursor (alist-get 'cursor args)))
        (when (and (stringp file) (numberp cursor)
                   (or (stringp text) (numberp session)))
          (let ((result (condition-case err
                            (if (stringp text)
                                ;; v1: request carries its own text window.
                                (jetpacs-complete-in-text file text cursor)
                              ;; v2: complete in the jetpacs-sync shadow.
                              (jetpacs-complete-in-session file session seq cursor))
                          (error (message "Jetpacs complete failed: %s"
                                          (error-message-string err))
                                 nil))))
            (when jetpacs-complete-debug
              (if result
                  (message "Jetpacs complete: %s prefix=%S -> %d candidate(s)"
                           (file-name-nondirectory file)
                           (car result) (length (cdr result)))
                (message "Jetpacs complete: %s -> nothing to offer at cursor"
                         (file-name-nondirectory file))))
            ;; Always reply, even empty, so the phone can clear its strip.
            (jetpacs-send "completions.show"
                       `((id . ,file)
                         (request_id . ,(or req 0))
                         (prefix . ,(or (car result) ""))
                         (candidates . ,(vconcat (cdr result)))))))))))

(provide 'jetpacs-complete)
;;; jetpacs-complete.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-settings.el
;;; ==================================================================

;;; jetpacs-settings.el --- Schema-driven settings from defcustom metadata -*- lexical-binding: t; -*-

;; Renders an allowlisted set of defcustom variables as companion widgets
;; derived from their `custom-type' schemas, and applies edits through
;; Customize: candidate values are validated with the type's widget
;; `:match', set via `customize-set-variable' (so `:set' setters run),
;; and persisted via `customize-save-variable'.
;;
;; The registry is the security boundary: `settings.set' / `settings.reset'
;; only touch symbols present in `jetpacs-settings-registry', never arbitrary
;; names off the wire.  Exposing a new setting is one registry entry.
;; The rendering/apply machinery itself is public and gate-agnostic —
;; jetpacs-customize.el reuses it under its own `customize.*' actions with a
;; `custom-variable-p' gate; the registry rule above binds `settings.*' only.
;;
;; Widget mapping by type: boolean -> switch (the client switch publishes
;; state.changed rather than dispatching an action, so per-id handlers are
;; registered at load), choice-of-consts -> single-select enum list,
;; string/file/directory -> text input, integer/number -> numeric text
;; input, anything else -> a raw elisp-expression input read with `read'.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-config)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)

(declare-function custom-file "cus-edit" (&optional no-error))

;; The host shell points these at its snackbar and dashboard push; this
;; module stays independent of any particular screen.
(defvar jetpacs-settings-notify-function #'message
  "Function of one string, used to surface rejections and save failures.")

(defvar jetpacs-settings-refresh-function #'ignore
  "Function called after a setting changes so the client re-renders.")

(defvar jetpacs-settings-after-set-hook nil
  "Hook run with (SYMBOL VALUE) after a setting is applied from the wire.
For propagation the defcustom's `:set' doesn't cover — e.g. an app whose
views memoise derived data registers its cache invalidation here.")

(defvar jetpacs-settings-registry nil
  "Sections of settings exposed to the companion.
Each element is (TITLE . ENTRIES); an entry is (SYMBOL . PLIST) where
PLIST supports :label (display name) and :after-set (function of the
new value, for propagation the defcustom's `:set' doesn't cover).
Only symbols listed here can be modified from the wire.

An entry may instead carry :render (a nullary node builder): a
READ-ONLY informational row rendered in place — it is excluded from
the wire-set gate and gets no state handler, so its SYMBOL is just a
self-documenting key, never settable.

Empty by default: the machinery is app-agnostic, and each Tier 1 app
exposes its own variables through `jetpacs-settings-register-section'.")

(defun jetpacs-settings-register-section (title entries)
  "Register (or replace) the settings section TITLE with ENTRIES.
ENTRIES is a list of (SYMBOL . PLIST) — see `jetpacs-settings-registry'.
Also registers the state.changed handlers the entries' switch widgets
publish through, so a queued toggle can replay before the settings
screen has ever rendered this session."
  (when (fboundp 'jetpacs--claim) (jetpacs--claim "settings" title))
  (setq jetpacs-settings-registry
        (append (assoc-delete-all title jetpacs-settings-registry)
                (list (cons title entries))))
  (jetpacs-settings--register-state-handlers (list (cons title entries))))

(defun jetpacs-settings-remove-section (title)
  "Unregister the settings section TITLE (used by `jetpacs-app-unregister')."
  (setq jetpacs-settings-registry (assoc-delete-all title jetpacs-settings-registry)))

(defun jetpacs-settings--entry (sym)
  "Registry entry for SYM, or nil if SYM is not exposed.
Read-only :render rows are not entries in this sense — they are never
reachable from the wire's settings.set/settings.reset gate."
  (cl-loop for (_title . entries) in jetpacs-settings-registry
           thereis (let ((entry (assq sym entries)))
                     (and entry
                          (not (plist-get (cdr entry) :render))
                          entry))))

;; ─── Persistence ─────────────────────────────────────────────────────────────

(defvar jetpacs-settings--custom-file-warned nil
  "Non-nil once we've warned that `custom-file' sits in the sync tree.")

(defun jetpacs-settings--warn-if-custom-file-managed (cf)
  "Warn once if custom-file CF resolves inside `jetpacs-root'.
A phone Settings save rewrites the file `custom-file' names and reports
success blind to that file's directory; if CF lived under the Jetpacs sync
tree, the next bundle sync would silently revert every saved setting.  We
still save (the user asked to), but flag it loudly so it gets moved back to
~/.emacs.d/custom.el.  Mirrors the tier rule: user data must never sit in a
sync-overwrite dir."
  (when (and cf
             (not jetpacs-settings--custom-file-warned)
             (boundp 'jetpacs-root) jetpacs-root
             ;; A trailing-slash prefix test, not `file-in-directory-p':
             ;; the latter returns nil when the dir doesn't yet exist on
             ;; disk (true before the first sync creates `jetpacs-root'),
             ;; and this still rejects a sibling like `jetpacs-evil/'.
             (string-prefix-p
              (file-name-as-directory (expand-file-name jetpacs-root))
              (expand-file-name cf)
              (memq system-type '(windows-nt ms-dos cygwin))))
    (setq jetpacs-settings--custom-file-warned t)
    (display-warning
     'jetpacs
     (format "custom-file %s is inside the Jetpacs sync tree (%s); saved settings \
will be lost on the next bundle sync.  Move it to %s."
             (abbreviate-file-name cf)
             (abbreviate-file-name jetpacs-root)
             (abbreviate-file-name
              (expand-file-name "custom.el" user-emacs-directory)))
     :error)))

(defun jetpacs-settings-save-variable (symbol value)
  "Persist SYMBOL as VALUE through Customize, surfacing failures.
Returns non-nil on success.  Failures are reported through
`jetpacs-settings-notify-function' instead of being silently dropped;
notably, `customize-save-variable' quietly skips saving when there is
no file to save into (started with -q, or no init file), which would
otherwise look like a save and then vanish on restart.  A `custom-file'
that exists but sits under `jetpacs-root' is a subtler version of the same
trap (a sync would clobber it): we save but warn via
`jetpacs-settings--warn-if-custom-file-managed'."
  (require 'cus-edit)
  (condition-case err
      (let ((cf (custom-file t)))
        (if cf
            (progn
              (jetpacs-settings--warn-if-custom-file-managed cf)
              (customize-save-variable symbol value)
              t)
          (set-default symbol value)
          (funcall jetpacs-settings-notify-function
                   "Applied for this session only: no init file to save settings into")
          nil))
    (error
     (funcall jetpacs-settings-notify-function
              (format "Applied for this session, but saving failed: %s"
                      (error-message-string err)))
     nil)))

;; ─── Type classification ─────────────────────────────────────────────────────

(defun jetpacs-settings--type (sym)
  "The `custom-type' schema of SYM, or nil for plain defvars."
  (get sym 'custom-type))

(defun jetpacs-settings--const-option (alt)
  "If choice alternative ALT is a const, return (TAG . VALUE); else nil."
  (when (and (consp alt) (eq (car alt) 'const))
    (let ((args (cdr alt)) (tag nil))
      (while (keywordp (car args))
        (when (eq (car args) :tag)
          (setq tag (cadr args)))
        (setq args (cddr args)))
      (cons (or tag (format "%s" (car args))) (car args)))))

(defun jetpacs-settings--choice-options (type)
  "For a (choice ...) TYPE, alist of (TAG . VALUE) for its const arms.
Non-const arms (e.g. a free string alternative) are simply not offered;
a current value outside the consts still displays, printed."
  (delq nil (mapcar #'jetpacs-settings--const-option (cdr type))))

(defun jetpacs-settings--kind (type)
  "Classify custom TYPE into a widget kind symbol."
  (pcase (if (consp type) (car type) type)
    ('boolean 'boolean)
    ((or 'string 'regexp 'file 'directory) 'string)
    ((or 'integer 'natnum 'number 'float) 'number)
    ('choice (if (jetpacs-settings--choice-options type) 'choice 'raw))
    (_ 'raw)))

(defun jetpacs-settings--valid-p (sym value)
  "Whether VALUE structurally satisfies SYM's custom type."
  (let ((type (jetpacs-settings--type sym)))
    (or (null type)
        (condition-case nil
            (and (widget-apply (widget-convert type) :match value) t)
          (error nil)))))

;; ─── Setting values ──────────────────────────────────────────────────────────

(defun jetpacs-settings-apply (sym value &optional after-set)
  "Validate, set, propagate and persist VALUE for SYM.
AFTER-SET, when non-nil, is called with VALUE once the set has run —
the propagation a caller's gate attaches (a registry entry's
:after-set); it is the caller's because this function no longer knows
which gate admitted SYM.  Returns non-nil when the value was accepted
\(even if only applied for the session because persisting failed)."
  (if (not (jetpacs-settings--valid-p sym value))
      (progn
        (funcall jetpacs-settings-notify-function
                 (format "Invalid value for %s" sym))
        nil)
    (customize-set-variable sym value)
    (when after-set (funcall after-set value))
    ;; App views may memoise data derived from this variable; per the
    ;; cache contract every mutation must reach the registered droppers.
    (run-hook-with-args 'jetpacs-settings-after-set-hook sym value)
    (jetpacs-settings-save-variable sym value)
    t))

(defun jetpacs-settings--decode (sym wire)
  "Decode client-sent WIRE into a candidate value for SYM.
Returns (VALUE) on success, `skip' for a no-op (e.g. an enum
deselection), nil when undecodable."
  (let* ((type (jetpacs-settings--type sym))
         (kind (jetpacs-settings--kind type))
         (trim (lambda (s) (replace-regexp-in-string
                            "\\`[ \t\n\r]+\\|[ \t\n\r]+\\'" "" s))))
    (pcase kind
      ('choice
       (let ((tag (car (append wire nil))))
         (if (null tag)
             'skip                      ; deselect: keep the current value
           (let ((opt (assoc tag (jetpacs-settings--choice-options type))))
             (and opt (list (cdr opt)))))))
      ('boolean (list (eq wire t)))
      ('string (and (stringp wire) (list wire)))
      ('number
       (when (stringp wire)
         (let ((s (funcall trim wire)))
           (and (string-match "\\`-?[0-9]+\\(\\.[0-9]+\\)?\\'" s)
                (list (string-to-number s))))))
      (_ (when (stringp wire)
           (condition-case nil
               (list (car (read-from-string wire)))
             (error nil)))))))

(defun jetpacs-settings-apply-wire (sym wire &optional after-set)
  "Decode client-sent WIRE and apply it to SYM; non-nil unless rejected.
An undecodable payload notifies and returns nil; a no-op (e.g. an enum
deselection) returns non-nil without touching SYM.  AFTER-SET is passed
through to `jetpacs-settings-apply'.  Callers gate SYM before calling —
this function validates the value, not the symbol."
  (pcase (jetpacs-settings--decode sym wire)
    ('skip t)
    ('nil (funcall jetpacs-settings-notify-function
                   (format "Invalid value for %s" sym))
          nil)
    (`(,value) (jetpacs-settings-apply sym value after-set))))

;; ─── Standard values / reset ─────────────────────────────────────────────────

(defun jetpacs-settings--standard-value (sym)
  "SYM's uncustomized default from the defcustom, evaluated."
  (let ((std (get sym 'standard-value)))
    (and std (eval (car std) t))))

(defun jetpacs-settings-modified-p (sym)
  "Whether SYM's current global value differs from its standard default.
Safe on any symbol: unbound means unmodified, and a standard-value form
that fails to evaluate counts as unmodified rather than erroring (the
customize browser calls this across arbitrary defcustoms)."
  (and (boundp sym)
       (get sym 'standard-value)
       (not (equal (default-value sym)
                   (condition-case nil (jetpacs-settings--standard-value sym)
                     (error (default-value sym)))))))

(defun jetpacs-settings-reset (sym &optional after-set)
  "Reset SYM to its defcustom standard value; non-nil on success.
Notifies instead of erroring when SYM has no standard value to return
to.  AFTER-SET is passed through to `jetpacs-settings-apply'."
  (if (not (get sym 'standard-value))
      (progn
        (funcall jetpacs-settings-notify-function "Cannot reset this setting")
        nil)
    (when (jetpacs-settings-apply sym (jetpacs-settings--standard-value sym) after-set)
      (funcall jetpacs-settings-notify-function
               (format "%s reset to default" sym))
      t)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun jetpacs-settings--doc-line (sym)
  "First line of SYM's docstring, or nil."
  (let ((doc (documentation-property sym 'variable-documentation)))
    (and doc (car (split-string (substitute-command-keys doc) "\n" t)))))

(cl-defun jetpacs-settings-item (sym &key label (id-prefix "setting/")
                                  (set-action "settings.set")
                                  (reset-action "settings.reset"))
  "Widget column rendering SYM's control from its `custom-type' schema.
LABEL defaults to the symbol name.  ID-PREFIX keys the control's widget
id; a switch under it publishes state.changed, so pair a non-default
prefix with `jetpacs-settings-watch-toggle'.  SET-ACTION and RESET-ACTION
name the wire actions the controls dispatch, each carrying the symbol
name under `name' — the settings screen uses the registry-gated
`settings.*', the customize browser the `custom-variable-p'-gated
`customize.*'."
  (if (not (boundp sym))
      (jetpacs-text (format "%s is not loaded yet" sym) 'caption)
    (let* ((name (symbol-name sym))
           (label (or label name))
           (doc (jetpacs-settings--doc-line sym))
           (value (default-value sym))
           (type (jetpacs-settings--type sym))
           (kind (jetpacs-settings--kind type))
           (wid-id (concat id-prefix name))
           (set (jetpacs-action set-action :args `((name . ,name))))
           (reset (and (jetpacs-settings-modified-p sym)
                       (jetpacs-icon-button
                        "history"
                        (jetpacs-action reset-action :args `((name . ,name)))
                        :content-description (format "Reset %s to default" label))))
           (control
            (pcase kind
              ('boolean
               (jetpacs-switch wid-id :checked (and value t) :label label))
              ('choice
               (let* ((opts (jetpacs-settings--choice-options type))
                      (current (car (rassoc value opts)))
                      (labels (mapcar #'car opts)))
                 (unless current
                   ;; Value set outside the const arms (e.g. a custom
                   ;; drawer name): show it, printed, as the selection.
                   (setq current (prin1-to-string value)
                         labels (append labels (list current))))
                 (jetpacs-enum-list wid-id labels :value (list current)
                                 :on-change set)))
              ('string
               (jetpacs-text-input wid-id :value (and (stringp value) value)
                                :label label :single-line t
                                :on-submit set))
              ('number
               (jetpacs-text-input wid-id
                                :value (and (numberp value)
                                            (number-to-string value))
                                :label label :single-line t
                                :on-submit set))
              (_
               (jetpacs-text-input wid-id :value (prin1-to-string value)
                                :label label :single-line t :monospace t
                                :hint "Elisp expression"
                                :on-submit set)))))
      (apply #'jetpacs-column
             (delq nil
                   (list
                    ;; Booleans carry their label inside the switch row;
                    ;; everything else gets a plain label row. The weighted
                    ;; box keeps the reset button on-screen (columns render
                    ;; fillMaxWidth and would swallow the row).
                    (jetpacs-row
                     (jetpacs-box (list (if (eq kind 'boolean)
                                         control
                                       (jetpacs-text label 'label)))
                               :weight 1)
                     reset)
                    (when doc (jetpacs-text doc 'caption))
                    (unless (eq kind 'boolean) control)))))))

(defun jetpacs-settings--item (entry)
  "Widget column for registry ENTRY (a :render row renders itself)."
  (let ((render (plist-get (cdr entry) :render)))
    (if render
        (funcall render)
      (jetpacs-settings-item (car entry) :label (plist-get (cdr entry) :label)))))

(defvar jetpacs-settings-links nil
  "Ordered list of (ORDER BUILDER . OWNER) Emacs navigation entries.
BUILDER is a nullary function returning a node (usually a tappable card
leading to another screen). Apps register satellite screens here—the
package browser, Customize, tools—instead of each claiming a drawer slot;
`jetpacs-settings-sections' renders them under \"Emacs Settings\".
OWNER is the `jetpacs-current-owner' captured at
registration (nil = core).")

(defvar jetpacs-settings-native-links nil
  "Ordered native Jetpacs entries rendered before Emacs settings.
These actions must be local builtins so Android configuration
remains reachable while Emacs is disconnected. Entries have the same
(ORDER BUILDER . OWNER) shape and ownership filtering as `jetpacs-settings-links'.")

(defun jetpacs-settings-add-link (order builder)
  "Add BUILDER (a nullary node builder) to the settings screen at ORDER.
Registrations made under `with-jetpacs-owner' are attributed to that app
and shown only while it is current (once a second app exists)."
  (setq jetpacs-settings-links
        (sort (cons (cons order (cons builder
                                      (bound-and-true-p jetpacs-current-owner)))
                    jetpacs-settings-links)
              (lambda (a b) (< (car a) (car b))))))

(defun jetpacs-settings-add-native-link (order builder)
  "Add native Jetpacs settings BUILDER at ORDER.
The card renders under \"Jetpacs Settings\" before Emacs-owned preferences.
BUILDER should dispatch a local builtin."
  (setq jetpacs-settings-native-links
        (sort (cons (cons order (cons builder
                                      (bound-and-true-p jetpacs-current-owner)))
                    jetpacs-settings-native-links)
              (lambda (a b) (< (car a) (car b))))))

(defvar jetpacs-settings-section-filter-function nil
  "When non-nil, a predicate on an OWNER id gating settings content.
Applied to each registered section (owner from the ownership registry)
and satellite link (owner captured at `jetpacs-settings-add-link' time).
The apps layer installs the current-app filter here; nil means every
section shows — the single-app default.  A nil owner (core, or a
registration made outside `with-jetpacs-owner') always shows.")

(defun jetpacs-settings--owner-visible-p (owner)
  "Non-nil when settings content registered by OWNER passes the filter.
A filter that signals passes the content — a broken app layer must not
blank the settings screen."
  (or (null owner)
      (null jetpacs-settings-section-filter-function)
      (condition-case nil
          (funcall jetpacs-settings-section-filter-function owner)
        (error t))))

(defun jetpacs-settings-sections ()
  "Flat list of native Jetpacs settings followed by Emacs settings.
Sections and links attributed to an app (registered under
`with-jetpacs-owner') render only while that app passes
`jetpacs-settings-section-filter-function'."
  (let ((native-links
         (cl-remove-if-not
          (lambda (e) (jetpacs-settings--owner-visible-p (cddr e)))
          jetpacs-settings-native-links))
        (emacs-links
         (cl-remove-if-not
          (lambda (e) (jetpacs-settings--owner-visible-p (cddr e)))
          jetpacs-settings-links)))
    (append
     (when native-links
       (append (list (jetpacs-divider)
                     (jetpacs-section-header "Jetpacs Settings"))
               (mapcar (lambda (e) (funcall (cadr e))) native-links)))
     (when (or jetpacs-settings-registry emacs-links)
       (append (list (jetpacs-divider)
                     (jetpacs-section-header "Emacs Settings"))
               (cl-loop for (title . entries) in jetpacs-settings-registry
                        when (jetpacs-settings--owner-visible-p
                              (and (fboundp 'jetpacs--owner-of)
                                   (jetpacs--owner-of "settings" title)))
                        append (append (list (jetpacs-section-header title))
                                       (mapcar #'jetpacs-settings--item entries)))
               (mapcar (lambda (e) (funcall (cadr e))) emacs-links))))))

;; ─── Actions and state handlers ──────────────────────────────────────────────

(jetpacs-defaction "settings.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (jetpacs-settings--entry sym))))
      (if (not entry)
          (funcall jetpacs-settings-notify-function
                   (format "Setting %s is not editable from the app"
                           (or name "?")))
        (jetpacs-settings-apply-wire sym (alist-get 'value args)
                                  (plist-get (cdr entry) :after-set)))
      (funcall jetpacs-settings-refresh-function))))

(jetpacs-defaction "settings.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (jetpacs-settings--entry sym))))
      (if (not entry)
          (funcall jetpacs-settings-notify-function "Cannot reset this setting")
        (jetpacs-settings-reset sym (plist-get (cdr entry) :after-set)))
      (funcall jetpacs-settings-refresh-function))))

(defun jetpacs-settings-watch-toggle (sym id &optional after-set)
  "Register the state.changed handler applying SYM's switch under widget ID.
The client's switch widget publishes state.changed instead of
dispatching an action, so a boolean setting only works once a handler
exists for its widget id.  Non-boolean payloads under ID (e.g. a text
input's published state) are ignored; those save through their submit
action instead.  AFTER-SET is passed through to `jetpacs-settings-apply'."
  (jetpacs-on-state-change
   id (lambda (val)
        (when (memq val '(t :false))
          (jetpacs-settings-apply sym (eq val t) after-set)
          (funcall jetpacs-settings-refresh-function)))))

(defun jetpacs-settings--register-state-handlers (sections)
  "Register the switch handlers for every symbol in SECTIONS.
A queued toggle can replay before the settings screen has ever rendered
this session — so handlers are registered when the section is, not at
render."
  (dolist (section sections)
    (dolist (entry (cdr section))
      (unless (plist-get (cdr entry) :render)
        (jetpacs-settings-watch-toggle
         (car entry)
         (concat "setting/" (symbol-name (car entry)))
         (plist-get (cdr entry) :after-set))))))

(provide 'jetpacs-settings)
;;; jetpacs-settings.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-files.el
;;; ==================================================================

;;; jetpacs-files.el --- File browser & editor for Jetpacs -*- lexical-binding: t; -*-

;; A dired-style file browser plus a plain-text editor, rendered through
;; Jetpacs surfaces. Together with the eval tab this is the self-hosting
;; plumbing: init.el (and anything else) can be edited, saved, and
;; reloaded from the phone, so the desktop side never needs touching
;; once jetpacs is in the init file.
;;
;; Registers two shell views:
;;   "files" — root list / directory listing (a bottom-bar tab)
;;   "edit"  — editor for `jetpacs-files--file' (present while a file is open)
;;
;; App seams — this module knows nothing about org (or any file type):
;;   `jetpacs-files-editor-body-functions'    replace the editor body per file
;;   `jetpacs-files-editor-actions-functions' add top-bar buttons per file
;;   `jetpacs-files-open-hook'                react to a file being opened
;;   `jetpacs-files-after-save-hook'          react to a phone-side save

;;; Code:

(require 'jetpacs)
(require 'jetpacs-surfaces)
(require 'jetpacs-widgets)
(require 'jetpacs-buffer) ; Tier 0 renderer + the major-mode→skin registry
(require 'jetpacs-results) ; content-search results ride the shared loci substrate
(require 'jetpacs-complete) ; capf bridge: the editor's `complete' flag
(require 'jetpacs-shell)
(require 'dired)
(require 'cl-lib)

(defcustom jetpacs-files-roots
  `(("Config" . ,user-emacs-directory)
    ("Org"    . ,(or (and (boundp 'org-directory) org-directory) "~/org/"))
    ("Home"   . "~/"))
  "Root directories the Files browser is confined to.
Navigation, opening, and file operations are all refused outside these
roots (`jetpacs-files--within-root-p').  Labels are unused now that the Files
view lands directly in `jetpacs-files-default-dir' rather than on a roots list,
but the alist shape is kept for back-compatibility."
  :type '(alist :key-type string :value-type directory)
  :group 'jetpacs)

(defcustom jetpacs-files-default-dir "~/"
  "Directory the Files tab opens to (and the navigation ceiling).
Must lie within `jetpacs-files-roots'.  The Files view shows this directory's
full listing — the same view you get from the Buffers tab on its dired
buffer — instead of a separate shortcut screen."
  :type 'directory :group 'jetpacs)

(defcustom jetpacs-files-shared-storage 'auto
  "How the Files browser exposes Android shared storage (/sdcard).
Emacs's HOME is a private per-app sandbox, so /sdcard is otherwise
unreachable from the Files tab even though the phone and the rest of the
platform live there.  When `auto' (the default) the browser probes for the
device's primary shared-storage directory and, if it is accessible, offers a
one-tap shortcut to it from the landing view — the standalone counterpart to
what Termux's `termux-setup-storage' arranges via ~/storage/shared.  A
string names an explicit directory to expose instead; nil disables the
shortcut entirely.

Access still depends on Emacs holding the storage permission: when it does
not, no directory is accessible and the shortcut simply does not appear."
  :type '(choice (const :tag "Auto-detect /sdcard" auto)
                 (const :tag "Disabled" nil)
                 (directory :tag "Explicit path"))
  :group 'jetpacs)

(defcustom jetpacs-files-max-bytes (* 256 1024)
  "Files larger than this open read-only.
Editor saves travel inside a broadcast intent on the companion side,
which has a hard payload ceiling (~500 KB across all extras), so big
files must not round-trip through the editor."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-files--dir nil
  "Directory being browsed, or nil for the landing dir (`jetpacs-files-default-dir').")

(defvar jetpacs-files--file nil
  "Absolute path of the file open in the editor, or nil.")

;; ─── App seams ───────────────────────────────────────────────────────────────

(defvar jetpacs-files-editor-body-functions nil
  "Abnormal hook: functions of FILE returning the editor view's body, or nil.
Tried in order before the plain-text editor; the first non-nil result
wins.  Apps register alternate renderings here (e.g. a foldable outline
reader for their file type).")

(defvar jetpacs-files-editor-actions-functions nil
  "Abnormal hook: functions of FILE returning top-bar action nodes.
The returned lists are appended into the editor view's top bar; apps add
their per-file-type buttons (mode toggles, metadata dialogs) here.")

(defvar jetpacs-files-open-hook nil
  "Hook run with FILE when the phone opens it in the editor.
Apps set their per-file-type editor state here (e.g. reader-first).")

(defvar jetpacs-files-after-save-hook nil
  "Hook run with FILE after a phone-triggered save succeeds.
Apps whose views memoise data derived from files drop caches here.")

(defvar jetpacs-files-editor-toolbar-function #'ignore
  "Function of FILE returning the editor toolbar to request, or nil.
Either a list of `jetpacs-toolbar-item's the companion interprets as data
\(SPEC §9 \"Editor toolbars\", the default path) or a string naming a
host-registered native toolbar.  Apps point this at their file-type
mapping so the toolbar choice ships in the editor spec instead of being
inferred client-side.")

;; ─── Browser view (dired under the hood) ─────────────────────────────────────

;; The directory listing is backed by a real dired buffer — the standard Emacs
;; file engine — but presented through a card skin registered for
;; `dired-mode'.  So the same buffer renders as touch cards here and as a raw,
;; faithful listing from the Buffers tab: Tier 0 and Tier 1 over one model.
;; The Files tab lands directly in `jetpacs-files-default-dir' (no separate roots
;; screen) so it matches the full listing you get from the Buffers tab.

(defun jetpacs-files--within-root-p (path)
  "Non-nil when PATH is inside (or is) one of `jetpacs-files-roots'.
Uses `file-in-directory-p', which compares path components — a bare
string-prefix check would let root \"~/org\" authorize \"~/org-secrets\",
and this predicate is the security boundary for every file operation
the phone can trigger."
  (let ((full (expand-file-name path)))
    (cl-some (lambda (root)
               (file-in-directory-p full (expand-file-name (cdr root))))
             jetpacs-files-roots)))

;; ─── Shared storage (/sdcard) ────────────────────────────────────────────────
;;
;; Emacs runs in a private sandbox whose HOME is nowhere near /sdcard, so a
;; standalone (non-Termux) install can't browse to the shared storage where the
;; phone, downloaded app bundles, and org files all live.  Termux users get
;; ~/storage/shared from `termux-setup-storage'; this gives everyone the same
;; reach, without requiring Termux — but only when Emacs actually holds the
;; storage permission (else the directory isn't accessible and we stay quiet).

(defun jetpacs-files--detect-shared-dir ()
  "Detect the primary shared-storage directory, or nil.
Honours `jetpacs-files-shared-storage'.  For `auto', returns the first of the
usual Android locations that exists and is readable; a string is taken as an
explicit directory (still gated on accessibility)."
  (pcase jetpacs-files-shared-storage
    ('nil nil)
    ((and (pred stringp) dir)
     (and (file-accessible-directory-p dir) (file-name-as-directory dir)))
    (_
     (cl-some (lambda (d)
                (and d (file-accessible-directory-p d) (file-name-as-directory d)))
              (list (getenv "EXTERNAL_STORAGE")
                    "/sdcard"
                    "/storage/emulated/0"
                    "/storage/self/primary")))))

(defvar jetpacs-files--shared-dir 'unset
  "Memoized `jetpacs-files-shared-dir' result — a directory, nil, or the
`unset' sentinel before first detection.")

(defun jetpacs-files-shared-dir ()
  "The shared-storage directory the Files browser exposes, or nil.
Detected once (see `jetpacs-files--detect-shared-dir').  On first successful
detection the directory is also added to `jetpacs-files-roots', so navigation
and file operations there clear the within-root guard — this is what widens
the sandbox to reach /sdcard.  Returns nil (adding nothing) when no shared
storage is accessible, so the feature degrades silently without it."
  (when (eq jetpacs-files--shared-dir 'unset)
    (setq jetpacs-files--shared-dir (jetpacs-files--detect-shared-dir))
    (when jetpacs-files--shared-dir
      (add-to-list 'jetpacs-files-roots
                   (cons "Storage" jetpacs-files--shared-dir) t)))
  jetpacs-files--shared-dir)

(defun jetpacs-files--shared-storage-card ()
  "Shortcut card to shared storage for the Files landing view, or nil.
Shown only at the landing directory, when shared storage is accessible and is
not itself the landing — one tap to the /sdcard tree Termux exposes at
~/storage/shared."
  (when-let (((null jetpacs-files--dir))
             (shared (jetpacs-files-shared-dir)))
    (unless (file-equal-p shared (jetpacs-files--current-dir))
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "sd_storage")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Shared storage" 'body)
                               (jetpacs-text (abbreviate-file-name
                                           (directory-file-name shared))
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-action "files.cd"
                            :args `((dir . ,(directory-file-name shared))))))))

(defun jetpacs-files--entry-menu (path)
  "Overflow menu of single-file operations for PATH.
Each item is an allowlisted action (see the command-dispatch boundary): the
handler runs one specific, root-guarded operation — never arbitrary dispatch."
  (jetpacs-menu
   (list
    (jetpacs-menu-item "Rename"
                    (jetpacs-action "files.rename" :args `((file . ,path)))
                    :icon "edit")
    (jetpacs-menu-item "Delete"
                    (jetpacs-action "files.delete" :args `((file . ,path)))
                    :icon "delete"))))

(defun jetpacs-files--card-for (path)
  "A tappable card for PATH — a folder (cd) or a file (open), with an op menu."
  (if (file-directory-p path)
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "folder")
              (jetpacs-box (list (jetpacs-text (file-name-nondirectory
                                          (directory-file-name path))
                                         'body))
                        :weight 1)
              (jetpacs-files--entry-menu path)))
       :on-tap (jetpacs-action "files.cd" :args `((dir . ,path))))
    (let ((size (or (file-attribute-size (file-attributes path)) 0)))
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "description")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text (file-name-nondirectory path) 'body)
                               (jetpacs-text (file-size-human-readable size) 'caption)))
                        :weight 1)
              (jetpacs-files--entry-menu path)))
       :on-tap (jetpacs-action "files.open" :args `((file . ,path)))))))

(defun jetpacs-files--dired-cards (buffer)
  "Dired skin: render dired BUFFER as a list of file/dir cards.
Directories sort first, then files.  A \"..\" card heads the list only when
the parent is still within the allowed roots — at the ceiling there is no
\"..\".  Returns a list of nodes, per the renderer contract."
  (with-current-buffer buffer
    (let ((dir (expand-file-name default-directory))
          paths)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          ;; Filter . and .. by their *local* names; the full path is what we
          ;; render.  Non-file lines (header, "total N") yield nil and skip.
          (let ((local (dired-get-filename 'no-dir t)))
            (when (and local (not (member local '("." ".."))))
              (push (dired-get-filename nil t) paths)))
          (forward-line 1)))
      (setq paths (delq nil (nreverse paths)))
      (let* ((dirs (sort (cl-remove-if-not #'file-directory-p paths) #'string<))
             (files (sort (cl-remove-if #'file-directory-p paths) #'string<))
             (parent (file-name-directory (directory-file-name dir)))
             (up-card
              (when (and parent (jetpacs-files--within-root-p parent))
                (jetpacs-card
                 (list (jetpacs-row (jetpacs-icon "arrow_upward") (jetpacs-text ".." 'body)))
                 :on-tap (jetpacs-action "files.cd" :args `((dir . ,parent)))))))
        (delq nil (cons up-card
                        (mapcar #'jetpacs-files--card-for (append dirs files))))))))

;; Register the skin globally: any dired buffer — the Files view here or one
;; opened from the Buffers tab — renders as cards.  This is the single dispatch
;; seam from jetpacs-buffer.el; the Files feature owns dired's app-wide look.
(jetpacs-render-buffer-register 'dired-mode #'jetpacs-files--dired-cards)

(defun jetpacs-files--dired-buffer (dir)
  "Return a freshly-reverted dired buffer for DIR, or nil.
Refuses DIR outside `jetpacs-files-roots' or unreadable; the within-root guard
turns the Android sandbox's raw stat errors into a graceful nil."
  (when (and (stringp dir) (file-directory-p dir) (jetpacs-files--within-root-p dir))
    (condition-case nil
        (let ((buf (dired-noselect dir)))
          (with-current-buffer buf (revert-buffer nil t))
          buf)
      (error nil))))

(defun jetpacs-files--current-dir ()
  "The directory the Files view is showing — `jetpacs-files--dir' or the landing."
  (or jetpacs-files--dir (expand-file-name jetpacs-files-default-dir)))

(defun jetpacs-files-browser-body ()
  "Build the Files view: the current directory rendered as dired cards.
There is no separate roots screen — the view always shows a directory
\(`jetpacs-files--current-dir'), so it matches the Buffers-tab listing.
While content-search results exist, a re-entry card heads the list."
  (let ((buf (jetpacs-files--dired-buffer (jetpacs-files--current-dir)))
        (results-card (jetpacs-files--grep-results-card))
        (shared-card (jetpacs-files--shared-storage-card)))
    (if buf
        (apply #'jetpacs-lazy-column
               (append (and results-card (list results-card))
                       (and shared-card (list shared-card))
                       (jetpacs-render-buffer buf)))
      (jetpacs-empty-state :icon "info"
                        :title "Can't open folder"
                        :caption "Outside the allowed roots, or unreadable."))))

;; ─── Content search ──────────────────────────────────────────────────────────
;;
;; A pure-elisp recursive scan: portable (no external grep needed on the
;; host) and bounded — capped hits and files, capped file size, VCS/build
;; directories skipped, binaries (NUL early in the file) skipped.  The
;; scan starts at the directory being browsed, which is inside
;; `jetpacs-files-roots' by construction, so the root guard holds; the query
;; is matched as a literal string, never a regexp off the wire.

(defcustom jetpacs-files-grep-max-hits 200
  "Content search stops after this many matching lines."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-files-grep-max-files 2000
  "Content search stops after examining this many files.
Search from a subdirectory rather than the root to keep scans quick."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-files-grep-max-file-bytes (* 1024 1024)
  "Files larger than this are skipped by the content search."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-files-grep-exclude-dirs
  '(".git" ".hg" ".svn" "node_modules" ".gradle" "build" "dist" "target")
  "Directory names the content search never descends into."
  :type '(repeat string) :group 'jetpacs)

(defvar jetpacs-files--grep nil
  "Latest content search, or nil.
A plist (:query Q :dir D :hits ((FILE LINE TEXT) ...) :truncated BOOL).")

(defun jetpacs-files--grep-scan (dir query)
  "Search QUERY (a literal, case-insensitive) under DIR.
Returns the plist stored in `jetpacs-files--grep'; one hit per line."
  (let ((re (regexp-quote query))
        (case-fold-search t)
        (hits-left jetpacs-files-grep-max-hits)
        (files-left jetpacs-files-grep-max-files)
        hits truncated)
    (catch 'done
      (dolist (file (directory-files-recursively
                     dir "" nil
                     (lambda (d)
                       (not (member (file-name-nondirectory
                                     (directory-file-name d))
                                    jetpacs-files-grep-exclude-dirs)))))
        (when (<= (cl-decf files-left) 0)
          (setq truncated t)
          (throw 'done nil))
        (when (and (file-readable-p file)
                   ;; Backups and auto-saves are stale copies: they double
                   ;; every hit, and centralized backups carry the full
                   ;; path slash-encoded as "!" in their names.
                   (not (backup-file-name-p file))
                   (not (auto-save-file-name-p (file-name-nondirectory file)))
                   (let ((size (file-attribute-size (file-attributes file))))
                     (and size (<= size jetpacs-files-grep-max-file-bytes))))
          (with-temp-buffer
            (when (ignore-errors (insert-file-contents file) t)
              (goto-char (point-min))
              ;; Binary guard: a NUL early in the file means don't line-match.
              (unless (search-forward "\0" (min 1024 (point-max)) t)
                (while (re-search-forward re nil t)
                  (push (list file
                              (line-number-at-pos)
                              (buffer-substring-no-properties
                               (line-beginning-position)
                               (min (line-end-position)
                                    (+ (line-beginning-position) 200))))
                        hits)
                  (when (<= (cl-decf hits-left) 0)
                    (setq truncated t)
                    (throw 'done nil))
                  (end-of-line))))))))
    (list :query query :dir dir :hits (nreverse hits) :truncated truncated)))

(defun jetpacs-files--grep-body ()
  "The search-results view body: one tappable card per matching line.
The hits are handed to the shared results substrate as file loci
\(`jetpacs-results-set-file-loci'), so a card tap follows the locus — the
same visit path as occur/grep/xref — and arms the prev/next-match stepper
in the source view.  A tap reads the hit in context; the pencil opens it
in the editor."
  (let* ((g jetpacs-files--grep)
         (dir (plist-get g :dir))
         (hits (plist-get g :hits))
         (loci (mapcar (lambda (hit)
                         (pcase-let ((`(,file ,line ,text) hit))
                           (list :file file :line line :text text)))
                       hits)))
    (jetpacs-results-set-file-loci loci)
    (if (null hits)
        (jetpacs-empty-state :icon "manage_search" :title "No matches"
                          :caption (format "\"%s\" under %s"
                                           (plist-get g :query)
                                           (abbreviate-file-name dir)))
      (apply #'jetpacs-lazy-column
             (cons
              (jetpacs-text (format "%d matching line%s under %s%s"
                                 (length hits)
                                 (if (= (length hits) 1) "" "s")
                                 (abbreviate-file-name dir)
                                 (if (plist-get g :truncated)
                                     " — stopped early, narrow the search"
                                   ""))
                         'caption)
              (cl-loop
               for hit in hits for i from 0 collect
               (pcase-let* ((`(,file ,line ,text) hit)
                            (rel (file-relative-name file dir))
                            (subdir (file-name-directory rel)))
                 (jetpacs-card
                  (list (jetpacs-column
                         (jetpacs-row
                          (jetpacs-box
                           (list (apply #'jetpacs-column
                                        (delq nil
                                              (list
                                               (jetpacs-text (file-name-nondirectory file)
                                                          'label)
                                               (when subdir
                                                 (jetpacs-text subdir 'caption
                                                            nil nil nil 1))))))
                           :weight 1)
                          (jetpacs-text (format "L%d" line) 'caption)
                          (jetpacs-icon-button
                           "edit"
                           (jetpacs-action "files.open"
                                        :args `((file . ,file)))
                           :content-description "Open in editor"))
                         (jetpacs-rich-text
                          (list (jetpacs-span (string-trim text) :mono t)))))
                  :on-tap (jetpacs-action "results.visit"
                                       :args `((index . ,i))
                                       :when-offline "drop")))))))))

(defun jetpacs-files--grep-results-card ()
  "The re-entry card the browser shows while results exist, or nil."
  (when jetpacs-files--grep
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-icon "manage_search")
            (jetpacs-box (list (jetpacs-text
                             (format "Results: \"%s\" (%d)"
                                     (plist-get jetpacs-files--grep :query)
                                     (length (plist-get jetpacs-files--grep :hits)))
                             'body))
                      :weight 1)
            (jetpacs-icon "chevron_right")))
     :on-tap (jetpacs-shell-switch-view "grep"))))

;; ─── Editor view ─────────────────────────────────────────────────────────────

(defun jetpacs-files-editor-body ()
  "Build the editor view for `jetpacs-files--file'.
An app-registered body (see `jetpacs-files-editor-body-functions') wins;
otherwise the plain-text editor."
  (let ((file jetpacs-files--file))
    (if (not (and file (file-readable-p file)))
        (jetpacs-column (jetpacs-text "No file open." 'body))
      (or (run-hook-with-args-until-success
           'jetpacs-files-editor-body-functions file)
          (let* ((size (or (file-attribute-size (file-attributes file)) 0))
                 (read-only (> size jetpacs-files-max-bytes))
                 (content
                  ;; Prefer a live buffer's content (may have unsaved desktop
                  ;; edits); fall back to disk.
                  (if-let ((buf (get-file-buffer file)))
                      (with-current-buffer buf
                        (buffer-substring-no-properties
                         (point-min)
                         (min (point-max) (1+ jetpacs-files-max-bytes))))
                    (with-temp-buffer
                      (insert-file-contents file nil 0 jetpacs-files-max-bytes)
                      (buffer-string)))))
            (jetpacs-column
             (when read-only
               (jetpacs-text (format "File exceeds %s — opened read-only."
                                  (file-size-human-readable jetpacs-files-max-bytes))
                          'caption))
             (jetpacs-editor file content
                          :read-only read-only
                          :line-numbers (and jetpacs-line-numbers
                                             (symbol-name jetpacs-line-numbers))
                          :complete (and jetpacs-complete-enabled (not read-only))
                          :toolbar (funcall jetpacs-files-editor-toolbar-function file)
                          :on-save (jetpacs-action "files.save"
                                                :args `((file . ,file))
                                                :when-offline "queue"
                                                :dedupe (concat "save/" file)))))))))

;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun jetpacs-files--files-view (snackbar)
  "The Files tab: the current directory's cards, back arrow inside subdirs."
  (let ((grep-btn (jetpacs-icon-button
                   "manage_search"
                   (jetpacs-action "files.grep" :when-offline "drop")
                   :content-description "Search file contents")))
    (jetpacs-shell-tab-view
     "files" (jetpacs-files-browser-body)
     :top-bar (if jetpacs-files--dir
                  (jetpacs-top-bar (abbreviate-file-name jetpacs-files--dir)
                                :nav-icon "arrow_back"
                                :nav-action (jetpacs-action "files.cd"
                                                         :args '((dir . :null)))
                                :actions (list grep-btn))
                (jetpacs-shell-default-top-bar "Files"
                                            :extra-actions (list grep-btn)))
     ;; A create FAB — the view always shows a directory (the landing dir or
     ;; a subdirectory), so it's always offered.
     :fab (jetpacs-fab "add" :label "New" :on-tap (jetpacs-action "files.new"))
     :snackbar snackbar)))

(defun jetpacs-files--edit-view (snackbar)
  "The editor view for the open file, with app-contributed top-bar actions."
  (jetpacs-shell-nav-view
   (if jetpacs-files--file
       (file-name-nondirectory jetpacs-files--file)
     "Editor")
   (jetpacs-files-editor-body)
   :back-to "files"
   :actions (when jetpacs-files--file
              (apply #'append
                     (delq nil
                           (mapcar (lambda (fn) (funcall fn jetpacs-files--file))
                                   jetpacs-files-editor-actions-functions))))
   :snackbar snackbar))

(jetpacs-shell-define-view "files"
  :builder #'jetpacs-files--files-view
  :tab '(:icon "folder_open" :label "Files")
  :order 40)

(jetpacs-shell-define-view "edit"
  :builder #'jetpacs-files--edit-view
  :when (lambda () (and jetpacs-files--file t))
  :order 100)

(defun jetpacs-files--grep-view (snackbar)
  "The content-search results view; ✕ discards the results."
  (jetpacs-shell-nav-view
   (format "\"%s\"" (plist-get jetpacs-files--grep :query))
   (jetpacs-files--grep-body)
   :back-to "files"
   :actions (list (jetpacs-icon-button
                   "close"
                   (jetpacs-action "files.grep-clear" :when-offline "drop")
                   :content-description "Discard search results"))
   :snackbar snackbar))

(jetpacs-shell-define-view "grep"
  :builder #'jetpacs-files--grep-view
  :when (lambda () (and jetpacs-files--grep t))
  :order 101)

;; Leaving the editor for the files view closes the file (the next push
;; drops the edit view). Unsaved companion-side text is discarded with it.
(add-hook 'jetpacs-shell-view-switched-hook
          (lambda (view)
            (when (and (equal view "files") jetpacs-files--file)
              (setq jetpacs-files--file nil))))

(defun jetpacs-files-current-file ()
  "Absolute path of the file currently open in the editor, or nil."
  jetpacs-files--file)

(defun jetpacs-files-open (file)
  "Open FILE in the editor and switch to the editor view.
FILE must be a readable path within the browsable roots; otherwise nothing
happens and nil is returned.  On success sets the open file, runs
`jetpacs-files-open-hook' with the expanded path, switches to the editor
view, and returns that path."
  (when (and (stringp file)
             (file-readable-p file)
             (jetpacs-files--within-root-p file))
    (setq jetpacs-files--file (expand-file-name file))
    (run-hook-with-args 'jetpacs-files-open-hook jetpacs-files--file)
    (jetpacs-shell-push nil :switch-to "edit")
    jetpacs-files--file))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "files.cd"
  (lambda (args _)
    (let ((dir (alist-get 'dir args)))
      (setq jetpacs-files--dir
            (and (stringp dir)
                 (file-directory-p dir)
                 (jetpacs-files--within-root-p dir)
                 (file-name-as-directory dir)))
      (jetpacs-shell-push nil :switch-to "files"))))

(jetpacs-defaction "files.open"
  (lambda (args _)
    (jetpacs-files-open (alist-get 'file args))))

(jetpacs-defaction "files.grep"
  ;; The query arrives through the bridged minibuffer (this runs inside an
  ;; action handler), so the search icon needs no input widget of its own.
  ;; Scope is the directory being browsed — within the roots by
  ;; construction — and the scan is bounded by the grep defcustoms.
  (lambda (_ __)
    (let* ((dir (jetpacs-files--current-dir))
           (query (condition-case nil
                      (string-trim
                       (read-string (format "Search in %s for: "
                                            (abbreviate-file-name dir))))
                    (quit ""))))
      (if (string-empty-p query)
          (jetpacs-shell-push)
        (setq jetpacs-files--grep (jetpacs-files--grep-scan dir query))
        (jetpacs-shell-push nil :switch-to "grep")))))

(jetpacs-defaction "files.grep-clear"
  (lambda (_ __)
    (setq jetpacs-files--grep nil)
    (jetpacs-shell-push nil :switch-to "files")))

;; The content-search hits are visited through the shared results
;; substrate (`results.visit' by index into the file-locus set armed in
;; `jetpacs-files--grep-body'), which also arms the prev/next stepper — so
;; there is no files-specific visit action or view-region seam anymore.

(jetpacs-defaction "files.delete"
  ;; Allowlisted op: delete the one tapped path, root-guarded, after a
  ;; confirmation (the y/n dialog is bridged to the phone by jetpacs-minibuffer).
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (jetpacs-files--within-root-p file)
                 (file-exists-p file))
        (if (yes-or-no-p (format "Delete %s? "
                                 (file-name-nondirectory
                                  (directory-file-name file))))
            (condition-case err
                (progn
                  (if (file-directory-p file)
                      (delete-directory file t)
                    (delete-file file))
                  (jetpacs-shell-notify
                   (format "Deleted %s" (file-name-nondirectory
                                         (directory-file-name file)))))
              (error (jetpacs-shell-notify
                      (format "Delete failed: %s" (error-message-string err)))))
          (jetpacs-shell-notify "Delete cancelled")))
      (jetpacs-shell-push nil :switch-to "files"))))

(jetpacs-defaction "files.rename"
  ;; Allowlisted op: rename within the same directory; the new name is read
  ;; through the bridged minibuffer and the target re-checked against roots.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (jetpacs-files--within-root-p file)
                 (file-exists-p file))
        (let* ((old (file-name-nondirectory (directory-file-name file)))
               (new (read-string (format "Rename %s to: " old) old)))
          (cond
           ((or (null new) (string-empty-p (string-trim new)))
            (jetpacs-shell-notify "Rename cancelled"))
           (t
            (let ((target (expand-file-name
                           new (file-name-directory (directory-file-name file)))))
              (cond
               ((not (jetpacs-files--within-root-p target))
                (jetpacs-shell-notify "Rename rejected (outside roots)"))
               ((file-exists-p target)
                (jetpacs-shell-notify "Target already exists"))
               (t
                (condition-case err
                    (progn (rename-file file target)
                           (jetpacs-shell-notify (format "Renamed to %s" new)))
                  (error (jetpacs-shell-notify
                          (format "Rename failed: %s"
                                  (error-message-string err)))))))))))
        (jetpacs-shell-push nil :switch-to "files")))))

;; ─── New file / folder ───────────────────────────────────────────────────────

(defun jetpacs-files-show-new-dialog ()
  "Dialog to create a new file or folder in the current Files directory.
The name field's value reaches the create handlers two ways: on-submit
carries it in `value', and the Folder/File buttons read it back from UI
state (the same pattern as the capture form)."
  (let ((dir (jetpacs-files--current-dir)))
    (when dir
      (jetpacs-send-dialog
       (jetpacs-column
        (jetpacs-text "New" 'title)
        (jetpacs-text (abbreviate-file-name dir) 'caption)
        (jetpacs-text-input "files-new-name"
                         :label "Name"
                         :hint "notes.org"
                         :single-line t
                         :on-submit (jetpacs-action "files.create"
                                                 :args '((type . "file"))))
        (jetpacs-row
         (jetpacs-button "Cancel" (jetpacs-action "files.new.cancel") :variant "text")
         (jetpacs-spacer :weight 1)
         (jetpacs-button "Folder"
                      (jetpacs-action "files.create" :args '((type . "dir")))
                      :variant "outlined")
         (jetpacs-spacer :width 8)
         (jetpacs-button "File"
                      (jetpacs-action "files.create" :args '((type . "file"))))))))))

(jetpacs-defaction "files.new"
  (lambda (_ _)
    ;; Forget any leftover name so a button tap can't read a stale value
    ;; before the user types (UI state is global and persistent).
    (jetpacs-ui-state-clear "files-new-name")
    (jetpacs-files-show-new-dialog)))

(jetpacs-defaction "files.new.cancel"
  (lambda (_ _) (jetpacs-dismiss-dialog)))

(jetpacs-defaction "files.create"
  ;; Allowlisted op: create a single-segment file or folder in the current
  ;; directory, re-checked against the roots.  TYPE is "file" or "dir".
  (lambda (args _)
    (let* ((type (or (alist-get 'type args) "file"))
           (name (string-trim (or (alist-get 'value args)
                                  (jetpacs-ui-state "files-new-name")
                                  "")))
           (dir (jetpacs-files--current-dir)))
      (cond
       ((or (null dir) (not (jetpacs-files--within-root-p dir)))
        (jetpacs-shell-notify "No directory"))
       ((string-empty-p name)
        (jetpacs-shell-notify "Name required"))
       ;; Single segment only — no separators or parent traversal.
       ((string-match-p "/" name)
        (jetpacs-shell-notify "Name can't contain '/'"))
       (t
        (let ((target (expand-file-name name dir)))
          (cond
           ((not (jetpacs-files--within-root-p target))
            (jetpacs-shell-notify "Rejected (outside roots)"))
           ((file-exists-p target)
            (jetpacs-shell-notify "Already exists"))
           (t
            (condition-case err
                (progn
                  (if (equal type "dir")
                      (make-directory target)
                    (write-region "" nil target nil 'silent))
                  (jetpacs-ui-state-clear "files-new-name")
                  (jetpacs-shell-notify (format "Created %s" name)))
              (error (jetpacs-shell-notify
                      (format "Create failed: %s"
                              (error-message-string err))))))))))
      (jetpacs-dismiss-dialog)
      (jetpacs-shell-push nil :switch-to "files"))))

(jetpacs-defaction "files.save"
  ;; Saves run inside the action handler, so `jetpacs--in-action-handler' is
  ;; bound — app after-save-hook refreshers key off that to avoid doubling
  ;; the explicit push below.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (value (alist-get 'value args)))
      (cond
       ((not (and (stringp file) (stringp value)
                  (jetpacs-files--within-root-p file)))
        (jetpacs-shell-notify "Save rejected"))
       (t
        (condition-case err
            (progn
              ;; Route through a live buffer when one exists so modes,
              ;; hooks, and desktop Emacs all see the change coherently.
              (if-let ((buf (get-file-buffer file)))
                  (with-current-buffer buf
                    (erase-buffer)
                    (insert value)
                    (let ((save-silently t))
                      (save-buffer)))
                (write-region value nil file))
              (run-hook-with-args 'jetpacs-files-after-save-hook file)
              (jetpacs-shell-notify
               ;; Re-loading init in a running session never applies
               ;; cleanly (defvars keep old values, hooks double up), so
               ;; the honest instruction is a restart.
               (if (and user-init-file (file-equal-p file user-init-file))
                   "Saved init — restart Emacs to apply config changes"
                 (format "Saved %s" (file-name-nondirectory file)))))
          (error
           (jetpacs-shell-notify
            (format "Save failed: %s" (error-message-string err))))))))
    (jetpacs-shell-push)))

(jetpacs-defaction "config.reload"
  ;; Retired: `load user-init-file' mid-session never applies cleanly
  ;; (defvars keep their values, hooks double-register), so the drawer
  ;; entry is gone.  The handler stays as a stub so a stale cached UI
  ;; from an older push gets the instruction instead of a dropped tap.
  (lambda (_ _)
    (jetpacs-shell-notify "Reload was removed — restart Emacs to apply config changes")
    (jetpacs-shell-push)))

(provide 'jetpacs-files)
;;; jetpacs-files.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-witheditor.el
;;; ==================================================================

;;; jetpacs-witheditor.el --- Bridge with-editor buffers to the phone -*- lexical-binding: t; -*-

;; When magit (or any with-editor client) runs a command that needs an
;; editor — a commit message, an interactive rebase todo — git launches
;; Emacs as its editor and a with-editor buffer appears, expecting the user
;; to edit it and press `C-c C-c' (finish) or `C-c C-k' (cancel).  Over the
;; bridge there is no keyboard, so that buffer would just sit there and the
;; whole operation hangs (this is the second half of the magit-commit hang;
;; the first is `map-y-or-n-p' in jetpacs-minibuffer.el).
;;
;; This module detects the buffer and pushes a dialog with a message editor
;; plus Commit/Cancel buttons, wired to `with-editor-finish' /
;; `with-editor-cancel'.  Two allowlisted actions (`witheditor.finish',
;; `witheditor.cancel') carry the buffer name and are validated against a
;; live with-editor buffer — never arbitrary dispatch (SPEC.md §5).
;;
;; Core never hard-depends on with-editor/magit: the hooks are installed via
;; `with-eval-after-load', so this file loads fine without them installed.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)

(defcustom jetpacs-witheditor-action-window 30
  "Seconds after a phone action within which a with-editor buffer bridges.
The git editor callback lands asynchronously AFTER the action handler that
started the commit has returned, so the bridge can't test
`jetpacs--in-action-handler' — instead it treats an editor buffer appearing
this soon after a dispatched action as phone-initiated.  Outside the
window (a commit made at the desktop while the phone happens to be
connected) nothing is pushed to the phone."
  :type 'integer :group 'jetpacs)

(defvar-local jetpacs-witheditor--bridged nil
  "Non-nil once this buffer's with-editor session has been bridged.
Guards against the enable/disable double-fire of `with-editor-mode-hook'
and the overlap with `git-commit-setup-hook' (both fire for a commit).")

(defvar jetpacs-witheditor--active nil
  "Buffer name of the with-editor session currently shown as a dialog, or nil.
Lets the post-finish/cancel hooks dismiss the phone dialog when the
session ends from the desktop side (or any path that isn't our actions).")

;; ─── Message region ──────────────────────────────────────────────────────────

(defun jetpacs-witheditor--message-region ()
  "Return (BEG . END) of the editable message in the current buffer.
Git's template appends a `# Please enter the commit message...' comment
block (and, with `commit.verbose', a `>8' scissors line) after the
message; those comment lines are excluded so editing can't clobber them."
  (save-excursion
    (goto-char (point-min))
    (cons (point-min)
          (if (re-search-forward "^#" nil t)
              (line-beginning-position)
            (point-max)))))

(defun jetpacs-witheditor--current-message ()
  "The current message text (before the comment tail), trailing blank trimmed."
  (let ((r (jetpacs-witheditor--message-region)))
    (string-trim-right
     (buffer-substring-no-properties (car r) (cdr r)))))

;; ─── Presentation ────────────────────────────────────────────────────────────

(defun jetpacs-witheditor--state-id (name)
  "UI-state / editor id for the with-editor buffer named NAME."
  (concat "witheditor:" name))

(defun jetpacs-witheditor--present (buf)
  "Push a dialog to edit and finish/cancel with-editor buffer BUF."
  (with-current-buffer buf
    (let* ((name (buffer-name buf))
           (eid (jetpacs-witheditor--state-id name))
           (content (jetpacs-witheditor--current-message))
           ;; Rebase todos and other non-commit editor buffers get their
           ;; buffer name; only a real commit gets the friendly title.
           (title (if (bound-and-true-p git-commit-mode)
                      "Commit message"
                    name)))
      ;; Seed UI state so the Commit button reads the initial text even if
      ;; the user finishes without editing (publish-state only emits on
      ;; change — same pattern as the eval REPL / capture form).
      (jetpacs-ui-state-put eid content)
      (setq jetpacs-witheditor--active name)
      (jetpacs-send-dialog
       (jetpacs-column
        (jetpacs-text title 'title)
        (jetpacs-editor eid content
                     :chromeless t
                     :publish-state t)
        (jetpacs-row
         (jetpacs-button "Cancel"
                      (jetpacs-action "witheditor.cancel" :args `((buffer . ,name)))
                      :variant "text")
         (jetpacs-spacer :weight 1)
         (jetpacs-button "Commit"
                      (jetpacs-action "witheditor.finish"
                                   :args `((buffer . ,name))))))))))

(defvar jetpacs--last-action-time)     ; jetpacs-surfaces.el
(defvar jetpacs--in-action-handler)    ; jetpacs-minibuffer.el

(defun jetpacs-witheditor--phone-initiated-p ()
  "Non-nil when the current editor buffer plausibly stems from a phone action.
True inside an action handler, or within `jetpacs-witheditor-action-window'
seconds of one (the git callback lands after the handler returned)."
  (or jetpacs--in-action-handler
      (< (- (float-time) jetpacs--last-action-time)
         jetpacs-witheditor-action-window)))

(defun jetpacs-witheditor--maybe-bridge ()
  "Bridge the current with-editor buffer to the phone, once, when connected.
Runs from `git-commit-setup-hook' / `with-editor-mode-hook'.  Bridges only
flows the phone plausibly started (see `jetpacs-witheditor--phone-initiated-p')
— a commit made at the desktop while the phone is connected must NOT pop
an uninvited dialog on it."
  (when (and (bound-and-true-p with-editor-mode)
             (jetpacs-connected-p)
             (jetpacs-witheditor--phone-initiated-p)
             (not jetpacs-witheditor--bridged))
    (setq jetpacs-witheditor--bridged t)
    (jetpacs-witheditor--present (current-buffer))))

(defun jetpacs-witheditor--session-ended ()
  "Dismiss the phone dialog when a bridged session ends outside our actions.
On `with-editor-post-finish/cancel-hook': the user may have finished the
commit at the desktop (C-c C-c there) while the phone dialog was up."
  (when jetpacs-witheditor--active
    (setq jetpacs-witheditor--active nil)
    (when (jetpacs-connected-p)
      (jetpacs-dismiss-dialog))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun jetpacs-witheditor--find-buffer (name)
  "Return the live with-editor buffer named NAME, or nil.
The handlers refuse any buffer that is not a live with-editor session —
this is the validation the command-dispatch boundary requires."
  (let ((buf (and (stringp name) (get-buffer name))))
    (and buf
         (buffer-live-p buf)
         (with-current-buffer buf (bound-and-true-p with-editor-mode))
         buf)))

(jetpacs-defaction "witheditor.finish"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (jetpacs-witheditor--find-buffer name))
           (value (or (alist-get 'value args)
                      (and buf (jetpacs-ui-state (jetpacs-witheditor--state-id name))))))
      (when buf
        (with-current-buffer buf
          ;; Replace only the message region, leaving git's comment/scissors
          ;; tail intact (git strips it on commit).
          (let ((r (jetpacs-witheditor--message-region)))
            (delete-region (car r) (cdr r))
            (goto-char (point-min))
            (insert (if (stringp value) value "") "\n"))
          (jetpacs-ui-state-clear (jetpacs-witheditor--state-id name))
          ;; Clear BEFORE finishing: the post-finish hook must not
          ;; double-dismiss (it would race a dialog a later flow opened).
          (setq jetpacs-witheditor--active nil)
          (when (fboundp 'with-editor-finish)
            (with-editor-finish nil)))
        (jetpacs-dismiss-dialog)
        (jetpacs-shell-push)))))

(jetpacs-defaction "witheditor.cancel"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (jetpacs-witheditor--find-buffer name)))
      (when buf
        (with-current-buffer buf
          (jetpacs-ui-state-clear (jetpacs-witheditor--state-id name))
          (setq jetpacs-witheditor--active nil)
          (when (fboundp 'with-editor-cancel)
            (with-editor-cancel nil)))
        (jetpacs-dismiss-dialog)
        (jetpacs-shell-push)))))

;; ─── Hooks (installed only once with-editor/git-commit are present) ───────────

(with-eval-after-load 'with-editor
  (add-hook 'with-editor-mode-hook #'jetpacs-witheditor--maybe-bridge)
  ;; Dismiss our dialog when the session ends from the desktop side.
  (add-hook 'with-editor-post-finish-hook #'jetpacs-witheditor--session-ended)
  (add-hook 'with-editor-post-cancel-hook #'jetpacs-witheditor--session-ended))

(with-eval-after-load 'git-commit
  (add-hook 'git-commit-setup-hook #'jetpacs-witheditor--maybe-bridge))

(provide 'jetpacs-witheditor)
;;; jetpacs-witheditor.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-emacs-ui.el
;;; ==================================================================

;;; jetpacs-emacs-ui.el --- Jetpacs Emacs REPL & Buffer Viewer -*- lexical-binding: t; -*-

;; Provides an in-app Emacs interaction layer:
;;   * Buffer viewer (switch buffers, see content)
;;   * *Messages* tail
;;   * M-x command runner (interactive command dialog)
;;   * Elisp eval REPL
;;
;; Registers three shell views — "buffers", "eval" (a bottom-bar tab), and
;; "messages" — plus their drawer entries and the M-x top-bar action.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-surfaces)
(require 'jetpacs-widgets)
(require 'jetpacs-buffer)
(require 'jetpacs-tablist)
(require 'jetpacs-results)
(require 'jetpacs-shell)
(require 'jetpacs-witheditor)
(require 'imenu)
(require 'cl-lib)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar jetpacs-emacs-ui--viewing-buffer nil
  "Name of the buffer currently being viewed, or nil for the buffer list.")

(defvar jetpacs-emacs-ui--section nil
  "Active section narrowing for the buffer view, or nil.
A plist (:buffer NAME :beg POS :end POS :label STRING :point POS);
while set for the viewed buffer, the view renders just that slice,
with :point (when non-nil) marked as the scroll target.  Set by
`imenu.show' or `jetpacs-emacs-ui-view-region', cleared by `imenu.clear'
or leaving the buffer.")

(defun jetpacs-emacs-ui-view-region (buffer-name beg end label &optional point)
  "Open the buffer view on BUFFER-NAME narrowed to [BEG, END).
LABEL heads the slice; POINT, when non-nil, marks the scroll-target
line.  The navigation entry other modules use to show \"this spot in
that buffer\" — grep hits, and any future jump affordance."
  (setq jetpacs-emacs-ui--viewing-buffer buffer-name
        jetpacs-emacs-ui--section (list :buffer buffer-name :beg beg :end end
                                     :label label :point point))
  (jetpacs-shell-push nil :switch-to "buffers"))

;; The results/xref navigator (occur, grep, compilation, xref, and the
;; Files content search) shows every visited locus in this region view —
;; one host jump primitive for every "list of loci → source location"
;; surface.
(setq jetpacs-results-visit-region-function #'jetpacs-emacs-ui-view-region)

;; Navigating to a buffer (the tablist skins open package descriptions and
;; list buffers this way) is this module's buffer view.
(setq jetpacs-tablist-view-buffer-function
      (lambda (name)
        (setq jetpacs-emacs-ui--viewing-buffer name)
        (jetpacs-shell-push nil :switch-to "buffers")))

(defvar jetpacs-emacs-ui--eval-history nil
  "List of (input . output) pairs from the eval REPL, newest first.")

(defcustom jetpacs-emacs-ui-eval-history-max 50
  "Maximum eval-history entries kept (and shipped in the dashboard spec)."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-emacs-ui-eval-output-max 2000
  "Eval results longer than this many characters are truncated for display."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-emacs-ui--messages-line-count 100
  "Number of tail lines to show from *Messages*.")

;; ─── Buffer List ─────────────────────────────────────────────────────────────

(defun jetpacs-emacs-ui--buffer-list-body ()
  "Build UI for the buffer list."
  (let* ((bufs (cl-remove-if
                (lambda (b) (string-prefix-p " " (buffer-name b)))
                (buffer-list)))
         (cards (mapcar
                 (lambda (buf)
                   (let* ((name (buffer-name buf))
                          (file (buffer-file-name buf))
                          (modified (buffer-modified-p buf))
                          (subtitle (cond
                                    (file (abbreviate-file-name file))
                                    (t (format "%d lines"
                                              (with-current-buffer buf
                                                (count-lines (point-min) (point-max)))))))
                          (prefix (if modified "● " "")))
                     (jetpacs-card
                      (list (jetpacs-column
                             (jetpacs-text (concat prefix name) 'body)
                             (jetpacs-text subtitle 'caption)))
                      :on-tap (jetpacs-action "emacs.buffer.view"
                                           :args `((buffer . ,name))))))
                 bufs)))
    (if cards
        (apply #'jetpacs-lazy-column cards)
      (jetpacs-text "No buffers." 'body))))

;; ─── Buffer Content Viewer ───────────────────────────────────────────────────

(defun jetpacs-emacs-ui--buffer-view-body (buffer-name)
  "Build UI showing the contents of BUFFER-NAME.
Rendered through the Tier 0 generic renderer (`jetpacs-render-buffer'), so the
buffer's faces and tappable regions survive — any major mode works without a
bespoke translator.  With an imenu section active for this buffer, only
that slice renders, under a dismissible header."
  (let ((buf (get-buffer buffer-name))
        (section (and (equal (plist-get jetpacs-emacs-ui--section :buffer)
                             buffer-name)
                      jetpacs-emacs-ui--section)))
    (cond
     ((not buf)
      (jetpacs-text (format "Buffer '%s' not found." buffer-name) 'body))
     (section
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-row
                    (jetpacs-box (list (jetpacs-text (plist-get section :label)
                                               'label))
                              :weight 1)
                    (jetpacs-icon-button "close"
                                      (jetpacs-action "imenu.clear"
                                                   :when-offline "drop")
                                      :content-description "Show whole buffer"))
                   (jetpacs-buffer-render-region buf
                                              (plist-get section :beg)
                                              (plist-get section :end)
                                              (plist-get section :point)))))
     (t (apply #'jetpacs-lazy-column (jetpacs-render-buffer buf))))))

;; ─── imenu sections ──────────────────────────────────────────────────────────
;;
;; imenu is the per-buffer index of definitions/sections any major mode
;; provides declaratively.  The picker is a bridged `completing-read'
;; (the same vertico-style dialog M-x uses), and the chosen entry
;; renders as a region slice — the phone has no scroll-to-position, so
;; "jump" means "show me that section".

(defun jetpacs-emacs-ui--imenu-flatten (alist prefix)
  "Flatten an imenu ALIST into ((LABEL . POSITION) ...), in index order.
Nested submenus join their path with \" / \"; the *Rescan* pseudo-entry
and unresolvable positions are dropped.  PREFIX is the path so far."
  (let (out)
    (dolist (item alist)
      (when (and (consp item) (car item))
        (let* ((label (if (string-empty-p prefix)
                          (format "%s" (car item))
                        (format "%s / %s" prefix (car item))))
               (tail (cdr item))
               ;; (NAME . POS) or the general (NAME POS FUNCTION ...) form.
               (pos (cond ((number-or-marker-p tail) tail)
                          ((and (consp tail) (number-or-marker-p (car tail)))
                           (car tail)))))
          (cond
           ((and (listp tail) (not pos))  ; a submenu
            (setq out (append out (jetpacs-emacs-ui--imenu-flatten tail label))))
           ((and pos
                 (not (equal (format "%s" (car item)) "*Rescan*"))
                 (>= (if (markerp pos) (or (marker-position pos) 0) pos) 1))
            (setq out (append out (list (cons label
                                              (if (markerp pos)
                                                  (marker-position pos)
                                                pos))))))))))
    out))

;; ─── Live buffer refresh ─────────────────────────────────────────────────────
;;
;; A buffer drilled into on the phone is a one-shot snapshot: it's rendered at
;; tap time and then frozen.  Self-updating buffers — compilation, grep, async
;; shell, *Messages* — need to re-push as they change.  While a buffer is being
;; viewed, a light timer compares `buffer-chars-modified-tick' and re-pushes on
;; change; the reconcile runs after every push, so the watch tracks
;; `jetpacs-emacs-ui--viewing-buffer' however it was set or cleared.

(defcustom jetpacs-emacs-ui-live-refresh t
  "When non-nil, a buffer drilled into on the phone refreshes as it changes.
Self-updating buffers (compilation, grep, async shell, *Messages*) re-push
while viewed instead of freezing at the snapshot taken when you opened them."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-emacs-ui-live-interval 1.0
  "Seconds between change checks for the buffer being viewed.
Polls only while a buffer is actively drilled into and the bridge is
connected; each check is a cheap tick comparison and pushes only on change."
  :type 'number :group 'jetpacs)

(defvar jetpacs-emacs-ui--live-timer nil)
(defvar jetpacs-emacs-ui--live-buffer nil
  "The buffer object currently watched for live refresh, or nil.")
(defvar jetpacs-emacs-ui--live-tick nil
  "`buffer-chars-modified-tick' of the watched buffer at its last push.")

(defun jetpacs-emacs-ui--live-tick-of (buf)
  "The `buffer-chars-modified-tick' of BUF, or nil if BUF is dead."
  (and (buffer-live-p buf)
       (with-current-buffer buf (buffer-chars-modified-tick))))

(defun jetpacs-emacs-ui--live-stop ()
  "Tear down the live-refresh watch."
  (when (timerp jetpacs-emacs-ui--live-timer)
    (cancel-timer jetpacs-emacs-ui--live-timer))
  (setq jetpacs-emacs-ui--live-timer nil
        jetpacs-emacs-ui--live-buffer nil
        jetpacs-emacs-ui--live-tick nil))

(defun jetpacs-emacs-ui--live-poll ()
  "Timer body: re-push when the watched buffer changed since its last push."
  (let ((buf jetpacs-emacs-ui--live-buffer))
    (if (or (not jetpacs-emacs-ui-live-refresh)
            (not (jetpacs-connected-p))
            (not (buffer-live-p buf))
            ;; The user navigated away from (or swapped) the viewed buffer.
            (not (equal (buffer-name buf) jetpacs-emacs-ui--viewing-buffer)))
        (jetpacs-emacs-ui--live-stop)
      (let ((tick (jetpacs-emacs-ui--live-tick-of buf)))
        (unless (equal tick jetpacs-emacs-ui--live-tick)
          ;; Safe to push here: a timer, not a change hook.
          (jetpacs-shell-push)
          ;; Re-read the tick AFTER the push so a message the push itself
          ;; logged (when the viewed buffer *is* *Messages*) can't drive an
          ;; endless self-refresh — only genuinely new changes re-trigger.
          (setq jetpacs-emacs-ui--live-tick (jetpacs-emacs-ui--live-tick-of buf)))))))

(defun jetpacs-emacs-ui--reconcile-live-watch ()
  "Start/stop the live-refresh watch to match the buffer being viewed.
Runs after every shell push, so the watch follows
`jetpacs-emacs-ui--viewing-buffer' no matter which code path changed it."
  (let* ((name (and jetpacs-emacs-ui-live-refresh
                    (jetpacs-connected-p)
                    jetpacs-emacs-ui--viewing-buffer))
         (buf (and name (get-buffer name))))
    (cond
     ((not (buffer-live-p buf)) (jetpacs-emacs-ui--live-stop))
     ((eq buf jetpacs-emacs-ui--live-buffer) nil) ; already watching it
     (t
      (jetpacs-emacs-ui--live-stop)
      (setq jetpacs-emacs-ui--live-buffer buf
            jetpacs-emacs-ui--live-tick (jetpacs-emacs-ui--live-tick-of buf)
            jetpacs-emacs-ui--live-timer
            (run-at-time jetpacs-emacs-ui-live-interval jetpacs-emacs-ui-live-interval
                         #'jetpacs-emacs-ui--live-poll))))))

(add-hook 'jetpacs-shell-after-push-hook #'jetpacs-emacs-ui--reconcile-live-watch)

;; ─── *Messages* Tail ─────────────────────────────────────────────────────────

(defun jetpacs-emacs-ui--messages-tail ()
  "The last `jetpacs-emacs-ui--messages-line-count' lines of *Messages*."
  (if-let ((msgs-buf (get-buffer "*Messages*")))
      (with-current-buffer msgs-buf
        (let* ((lines (split-string
                       (buffer-substring-no-properties (point-min) (point-max))
                       "\n" t))
               (tail (last lines jetpacs-emacs-ui--messages-line-count)))
          (mapconcat #'identity tail "\n")))
    "No *Messages* buffer."))

(defun jetpacs-emacs-ui--messages-line (line stripe)
  "One zebra row for the Messages view.
LINE is selectable (long-press to copy); STRIPE non-nil tints the row
with a theme-adaptive container color so lines read as distinct entries."
  (let ((text (jetpacs-text (if (string-empty-p line) " " line)
                         'mono nil nil t nil 4)))
    (if stripe
        (jetpacs-surface (list text)
                      :color "surface_container"
                      :shape "rounded_small"
                      :fill t)
      text)))

(defun jetpacs-emacs-ui--messages-body ()
  "Build the Messages view: zebra-striped, selectable lines + copy all.
Each *Messages* line is its own row (alternate rows tinted) so entries
are visually delineated; every row is long-press selectable, and Copy
all uses the companion-local clipboard builtin."
  (let* ((content (jetpacs-emacs-ui--messages-tail))
         (i 0)
         (rows (mapcar (lambda (line)
                         (prog1 (jetpacs-emacs-ui--messages-line line (cl-oddp i))
                           (setq i (1+ i))))
                       (split-string content "\n"))))
    (jetpacs-column
     (jetpacs-row
      (jetpacs-text (format "Last %d lines" jetpacs-emacs-ui--messages-line-count)
                 'caption)
      (jetpacs-spacer :weight 1)
      (jetpacs-button "Copy all" (jetpacs-clipboard-action content) :variant "text"))
     (jetpacs-box
      (list (apply #'jetpacs-lazy-column rows))
      :weight 1))))

;; ─── *Messages* → device toasts ──────────────────────────────────────────────

(defcustom jetpacs-forward-messages t
  "When non-nil, echo-area messages mirror to the companion as toasts.
Throttled to at most one per second (latest wins); Jetpacs's own bridge
chatter is filtered out so it can never echo back to the phone."
  :type 'boolean :group 'jetpacs)

(defvar jetpacs-emacs-ui--toast-last 0
  "Time of the last toast sent, for throttling.")
(defvar jetpacs-emacs-ui--toast-timer nil)
(defvar jetpacs-emacs-ui--toast-pending nil
  "Latest message held back by the throttle, flushed by the timer.")
(defvar jetpacs-emacs-ui--in-toast nil
  "Reentrancy guard: non-nil while forwarding a message.")

(defun jetpacs-emacs-ui--toast-send (text)
  (setq jetpacs-emacs-ui--toast-last (float-time))
  (jetpacs-send "toast.show" `((text . ,text))))

(defun jetpacs-emacs-ui--message-advice (format-string &rest args)
  "Mirror `message' output to the companion as a toast.
Runs as :after advice on `message'; never signals, never recurses.
Honours `inhibit-message': output the caller silenced for the echo area
\(e.g. the flymake shadow compile's \"Wrote ....elc\") stays silent on
the phone too."
  (when (and jetpacs-forward-messages
             (not inhibit-message)
             (not jetpacs-emacs-ui--in-toast)
             format-string
             (jetpacs-connected-p))
    (let* ((jetpacs-emacs-ui--in-toast t)
           (msg (ignore-errors (apply #'format-message format-string args))))
      (when (and (stringp msg)
                 (not (string-empty-p (string-trim msg)))
                 (not (string-prefix-p "Jetpacs" msg)))
        (when (> (length msg) 200)
          (setq msg (concat (substring msg 0 200) "…")))
        (if (> (- (float-time) jetpacs-emacs-ui--toast-last) 1.0)
            (jetpacs-emacs-ui--toast-send msg)
          ;; Throttle window: hold only the LATEST message and flush once.
          (setq jetpacs-emacs-ui--toast-pending msg)
          (unless (timerp jetpacs-emacs-ui--toast-timer)
            (setq jetpacs-emacs-ui--toast-timer
                  (run-at-time
                   1.0 nil
                   (lambda ()
                     (setq jetpacs-emacs-ui--toast-timer nil)
                     (when jetpacs-emacs-ui--toast-pending
                       (jetpacs-emacs-ui--toast-send
                        (prog1 jetpacs-emacs-ui--toast-pending
                          (setq jetpacs-emacs-ui--toast-pending nil))))))))))))
  nil)

(advice-add 'message :after #'jetpacs-emacs-ui--message-advice)

;; ─── Eval REPL ───────────────────────────────────────────────────────────────

(defun jetpacs-emacs-ui--eval-card (entry)
  "One REPL history card for ENTRY (INPUT . OUTPUT).
Input line, then the (selectable) result, with copy and re-run buttons."
  (let* ((input (car entry))
         (output (cdr entry))
         (shown (if (> (length output) jetpacs-emacs-ui-eval-output-max)
                    (concat (substring output 0 jetpacs-emacs-ui-eval-output-max)
                            " …")
                  output)))
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-row
             (jetpacs-box (list (jetpacs-text (concat "λ> " input) 'label))
                       :weight 1)
             (jetpacs-icon-button "content_copy"
                               (jetpacs-clipboard-action output)
                               :content-description "Copy result")
             (jetpacs-icon-button "play_arrow"
                               (jetpacs-action "emacs.eval.submit"
                                            :args `((value . ,input)))
                               :content-description "Re-run"))
            (jetpacs-text shown 'mono nil nil t))))))

;; REPL input is one-shot expressions, not a file: tell the sync bridge so
;; its byte-compile diagnostics run under lexical binding (matching the
;; `eval' below) instead of warning about a missing lexical-binding cookie.
(with-eval-after-load 'jetpacs-sync
  (add-to-list 'jetpacs-sync-elisp-repl-files "eval.el"))

(defun jetpacs-emacs-ui--eval-body ()
  "Build UI for the elisp eval REPL.
History (newest first) scrolls in a weighted region; the input field and
Eval button stay pinned below it, so they can never be pushed off-screen
by a long history — the layout bug the old plain-column version had."
  (let* ((history-cards (mapcar #'jetpacs-emacs-ui--eval-card
                                jetpacs-emacs-ui--eval-history))
         ;; A chromeless editor instead of a plain text_input: the id names
         ;; a virtual elisp file, so the full bridge lights up in the REPL —
         ;; completion chips from the live obarray, paren/byte-compile
         ;; squiggles as you type, eldoc signatures in the doc line, and
         ;; Emacs-theme fontification. publish-state keeps the Eval button's
         ;; ui-state read working exactly like the old field.
         (input-field (jetpacs-editor "eval.el" ""
                                   :chromeless t
                                   :publish-state t
                                   :complete t
                                   :syntax "elisp")))
    (jetpacs-column
     (jetpacs-box
      (list (if history-cards
                (apply #'jetpacs-lazy-column history-cards)
              (jetpacs-empty-state :icon "code"
                                :title "Elisp REPL"
                                :caption (concat "Results appear here, newest "
                                                 "first. * ** and *** hold the "
                                                 "last three results."))))
      :weight 1)
     (jetpacs-divider)
     (jetpacs-box
      (list
       (jetpacs-row
        (jetpacs-box (list input-field) :weight 1)
        (jetpacs-spacer :width 8)
        (jetpacs-icon-button "send" (jetpacs-action "emacs.eval.submit")
                          :content-description "Eval")))
      :padding 8))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

;; Buffer list / view
(jetpacs-defaction "emacs.buffer.view"
  (lambda (args _)
    (setq jetpacs-emacs-ui--viewing-buffer (alist-get 'buffer args)
          jetpacs-emacs-ui--section nil)
    (jetpacs-shell-push)))

(jetpacs-defaction "emacs.buffer.back"
  (lambda (_ _)
    (setq jetpacs-emacs-ui--viewing-buffer nil
          jetpacs-emacs-ui--section nil)
    (jetpacs-shell-push)))

;; imenu sections
(jetpacs-defaction "imenu.show"
  (lambda (args _)
    (let* ((name (or (alist-get 'buffer args) jetpacs-emacs-ui--viewing-buffer))
           (buf (and (stringp name) (get-buffer name))))
      (if (not buf)
          (message "No buffer to index")
        (let ((flat (with-current-buffer buf
                      (condition-case nil
                          (jetpacs-emacs-ui--imenu-flatten
                           (imenu--make-index-alist t) "")
                        (error nil)))))
          (if (null flat)
              (message "No sections found in %s" name)
            (let ((choice (condition-case nil
                              (completing-read "Section: " (mapcar #'car flat)
                                               nil t)
                            (quit nil))))
              (when-let ((pos (cdr (assoc choice flat))))
                (with-current-buffer buf
                  ;; The section runs from the entry's line to the next
                  ;; index position after it (in any submenu), else eob.
                  (let* ((beg (save-excursion (goto-char (min pos (point-max)))
                                              (line-beginning-position)))
                         (after (sort (cl-remove-if (lambda (p) (<= p pos))
                                                    (mapcar #'cdr flat))
                                      #'<))
                         (end (or (car after) (point-max))))
                    (setq jetpacs-emacs-ui--section
                          (list :buffer name :beg beg :end end
                                :label choice))))
                (jetpacs-shell-push)))))))))

(jetpacs-defaction "imenu.clear"
  (lambda (_ _)
    (setq jetpacs-emacs-ui--section nil)
    (jetpacs-shell-push)))

(defun jetpacs-emacs-ui--eval-record (input output)
  "Push (INPUT . OUTPUT) onto the eval history, bounded by the max."
  (push (cons input output) jetpacs-emacs-ui--eval-history)
  (when (> (length jetpacs-emacs-ui--eval-history) jetpacs-emacs-ui-eval-history-max)
    (setcdr (nthcdr (1- jetpacs-emacs-ui-eval-history-max)
                    jetpacs-emacs-ui--eval-history)
            nil)))

;; The REPL result-variable convention: `*' holds the last result, `**'
;; and `***' the two before it, referable from the next expression.
;; These are the same special variables ielm defines, so the Eval tab
;; and an ielm session share recent results when both are in play.
(defvar * nil "Most recent Eval-tab result (the ielm convention).")
(defvar ** nil "Second most recent Eval-tab result.")
(defvar *** nil "Third most recent Eval-tab result.")

;; Eval REPL
(jetpacs-defaction "emacs.eval.submit"
  (lambda (args _)
    ;; The Eval button carries no value, so fall back to the field's latest
    ;; value recorded by `state.changed' (same pattern as the capture form).
    ;; "eval.el" is the editor-based field; "eval-input" the legacy one.
    (let* ((expr (or (alist-get 'value args)
                     (jetpacs-ui-state "eval.el")
                     (jetpacs-ui-state "eval-input")
                     ""))
           (result (condition-case err
                       ;; Wrap in progn so multi-sexp input evaluates fully
                       ;; (bare `read' silently ignored everything after the
                       ;; first form).
                       (let ((val (eval (car (read-from-string
                                              (format "(progn %s\n)" expr)))
                                        t)))
                         ;; ielm's rotation, verbatim: *** ← ** ← * ← VAL.
                         (setq *** ** ** * * val)
                         (format "%S" val))
                     (error (format "ERROR: %s" (error-message-string err))))))
      (unless (string-empty-p (string-trim expr))
        (jetpacs-emacs-ui--eval-record expr result))
      (jetpacs-shell-push))))

;; M-x — runs `completing-read' over all commands, which the minibuffer
;; bridge turns into a live-filtering (vertico-style) picker dialog. The
;; chosen command is then run with `call-interactively' (its own prompts,
;; if any, are bridged too). Result lands in the Eval tab's history.
(jetpacs-defaction "emacs.mx.show"
  (lambda (_ _)
    (let ((cmd-name (condition-case nil
                        (completing-read "M-x " obarray #'commandp t)
                      (quit nil))))
      (when (and (stringp cmd-name) (not (string-empty-p cmd-name)))
        (let ((cmd (intern-soft cmd-name)))
          (cond
           ((not (commandp cmd))
            (jetpacs-emacs-ui--eval-record (concat "M-x " cmd-name)
                                        (format "'%s' is not a command." cmd-name)))
           (t
            (condition-case err
                (progn
                  (call-interactively cmd)
                  (jetpacs-emacs-ui--eval-record (concat "M-x " cmd-name)
                                              "Command executed."))
              (error
               (jetpacs-emacs-ui--eval-record
                (concat "M-x " cmd-name)
                (format "ERROR: %s" (error-message-string err))))))))
        (jetpacs-shell-push "eval")))))

;; Messages refresh
(jetpacs-defaction "emacs.messages.refresh"
  (lambda (_ _)
    (jetpacs-shell-push)))

;; Clear eval history
(jetpacs-defaction "emacs.eval.clear"
  (lambda (_ _)
    (setq jetpacs-emacs-ui--eval-history nil)
    (jetpacs-shell-push)))


;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun jetpacs-emacs-ui--buffers-view (snackbar)
  "The Buffers view: list of live buffers, or the drilled-in buffer.
The list gets tab-style chrome (drawer, bottom bar, pull-to-refresh)
even though Buffers has no bottom-bar item of its own — it is reached
from the drawer.  Drilling into a buffer swaps to back-arrow chrome
with a keyboard FAB that opens the buffer's keymap."
  (if jetpacs-emacs-ui--viewing-buffer
      (jetpacs-shell-nav-view
       jetpacs-emacs-ui--viewing-buffer
       (jetpacs-emacs-ui--buffer-view-body jetpacs-emacs-ui--viewing-buffer)
       ;; Content swap within the buffers view: stays an Emacs round-trip
       ;; (the list must be rebuilt).
       :nav-action (jetpacs-action "emacs.buffer.back")
       ;; When a section is showing a locus reached from occur/grep/xref,
       ;; the results substrate contributes prev/next-match chrome; else
       ;; nil.  Gated on an active section so it never shows on the whole
       ;; buffer.  Then the imenu sections button.
       :actions (append
                 (when jetpacs-emacs-ui--section
                   (jetpacs-results-buffer-view-actions
                    jetpacs-emacs-ui--viewing-buffer))
                 (list (jetpacs-icon-button
                        "toc"
                        (jetpacs-action "imenu.show"
                                     :args `((buffer . ,jetpacs-emacs-ui--viewing-buffer))
                                     :when-offline "drop")
                        :content-description "Sections (imenu)")))
       :fab (jetpacs-fab "keyboard"
                      :on-tap (jetpacs-action "jetpacs.keymap.show"
                               :args `((buffer . ,jetpacs-emacs-ui--viewing-buffer))
                               :when-offline "drop"))
       :snackbar snackbar)
    (jetpacs-shell-tab-view "buffers" (jetpacs-emacs-ui--buffer-list-body)
                         :snackbar snackbar)))

(defun jetpacs-emacs-ui--eval-view (snackbar)
  "The Eval tab: REPL history over a pinned input row."
  (jetpacs-shell-tab-view
   "eval" (jetpacs-emacs-ui--eval-body)
   :top-bar (jetpacs-shell-default-top-bar
             "Eval"
             :extra-actions (list (jetpacs-icon-button
                                   "delete"
                                   (jetpacs-action "emacs.eval.clear")
                                   :content-description "Clear history")))
   :fab nil
   :snackbar snackbar))

(defun jetpacs-emacs-ui--messages-view (snackbar)
  "The Messages view: the *Messages* tail with a refresh button."
  (jetpacs-shell-nav-view
   "Messages" (jetpacs-emacs-ui--messages-body)
   :actions (list (jetpacs-icon-button
                   "refresh"
                   (jetpacs-action "emacs.messages.refresh" :when-offline "drop")
                   :content-description "Refresh"))
   :snackbar snackbar))

(jetpacs-shell-define-view "buffers" :builder #'jetpacs-emacs-ui--buffers-view
                        :order 60)
(jetpacs-shell-define-view "eval" :builder #'jetpacs-emacs-ui--eval-view
                        :tab '(:icon "code" :label "Eval") :order 50)
(jetpacs-shell-define-view "messages" :builder #'jetpacs-emacs-ui--messages-view
                        :order 90)

;; Landing anywhere but the current tab drops a buffer drill-in (and its
;; imenu section).  Named so re-evaluating the file doesn't stack lambdas.
(defun jetpacs-emacs-ui--on-view-switched (view)
  (unless (equal view (jetpacs-shell-current-tab))
    (setq jetpacs-emacs-ui--viewing-buffer nil
          jetpacs-emacs-ui--section nil)))
(add-hook 'jetpacs-shell-view-switched-hook #'jetpacs-emacs-ui--on-view-switched)

(jetpacs-shell-add-drawer-item
 10 (lambda () (jetpacs-drawer-item "view_list" "Buffers"
                                 (jetpacs-shell-switch-view "buffers"))))
(jetpacs-shell-add-drawer-item
 20 (lambda () (jetpacs-drawer-item "history" "Messages"
                                 (jetpacs-shell-switch-view "messages"))))

;; M-x is available from every tab's top bar (no drawer entry needed).
(jetpacs-shell-add-top-action
 20 (lambda () (jetpacs-icon-button "terminal" (jetpacs-action "emacs.mx.show"))))

(provide 'jetpacs-emacs-ui)
;;; jetpacs-emacs-ui.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-package-browser.el
;;; ==================================================================

;;; jetpacs-package-browser.el --- Package browser skin for the tablist renderer -*- lexical-binding: t; -*-

;; The stock tablist skin, and the worked example of the pattern:
;; package-menu-mode derives from tabulated-list-mode, so the generic walk
;; in jetpacs-tablist.el is reused; this file only registers the three skin
;; hooks (header, row, filter) plus its curated actions.  A Tier-1 skin in
;; shape, it ships in the core because package management, like Settings,
;; is chrome every app's user needs.
;;
;; It adds search + status chips, install/delete per row, and archive
;; refresh / upgrade-all — the actions validate package names against the
;; archive/installed lists, keeping the wire semantic (see the
;; command-dispatch boundary: nothing on the wire names arbitrary code).

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-tablist)
(require 'jetpacs-settings)
(require 'jetpacs-shell)

(defvar jetpacs-pkg--search ""
  "Current package search string (matches name and summary).")

(defvar jetpacs-pkg--status "all"
  "Current package status filter chip.")

(defconst jetpacs-pkg--statuses
  '(("all")
    ("installed" "installed" "dependency" "unsigned" "external" "held")
    ("available" "available" "new")
    ("built-in" "built-in")
    ("upgradable" "obsolete"))
  "Chip name -> package-menu status strings it admits.")

(defun jetpacs-pkg--toast (text)
  (jetpacs-send "toast.show" `((text . ,text))))

(defun jetpacs-pkg--filter (id entry)
  "Keep package row (ID ENTRY) when it matches the search and status chips."
  (let ((statuses (cdr (assoc jetpacs-pkg--status jetpacs-pkg--statuses)))
        (status (or (jetpacs-tablist-entry-col entry "Status") ""))
        (hay (concat (jetpacs-tablist-col-string (aref entry 0)) " "
                     (and (package-desc-p id)
                          (or (package-desc-summary id) "")))))
    (and (or (null statuses) (member status statuses))
         (or (string-empty-p jetpacs-pkg--search)
             (string-match-p (regexp-quote jetpacs-pkg--search)
                             (downcase hay))))))

(defun jetpacs-pkg--header (_buf)
  (list
   (jetpacs-text-input "pkg-search"
                    :value jetpacs-pkg--search
                    :label "Search packages" :single-line t
                    :on-submit (jetpacs-action "packages.search"))
   (apply #'jetpacs-flow-row
          (mapcar (lambda (chip)
                    (let ((s (car chip)))
                      (jetpacs-chip (capitalize s)
                                 :selected (equal jetpacs-pkg--status s)
                                 :on-tap (jetpacs-action
                                          "packages.status-filter"
                                          :args `((status . ,s))
                                          :when-offline "drop"))))
                  jetpacs-pkg--statuses))
   (jetpacs-row
    (jetpacs-button "Refresh archives"
                 (jetpacs-action "packages.refresh-archives" :when-offline "drop")
                 :variant "text")
    (jetpacs-spacer :weight 1)
    (when (fboundp 'package-upgrade-all)
      (jetpacs-button "Upgrade all"
                   (jetpacs-action "packages.upgrade-all" :when-offline "drop")
                   :variant "text")))))

(defun jetpacs-pkg--row (id entry _pos)
  (when (package-desc-p id)
    (let* ((sym (package-desc-name id))
           (name (symbol-name sym))
           (version (or (jetpacs-tablist-entry-col entry "Version") ""))
           (status (or (jetpacs-tablist-entry-col entry "Status") ""))
           (summary (or (package-desc-summary id) ""))
           (installed (assq sym package-alist)))
      (jetpacs-card
       (list
        (jetpacs-row
         (jetpacs-box
          (list (jetpacs-column
                 (jetpacs-row (jetpacs-text name 'label)
                           (jetpacs-text version 'caption)
                           (jetpacs-text status 'caption))
                 (jetpacs-text summary 'caption)))
          :weight 1)
         (cond
          (installed
           (jetpacs-icon-button "delete"
                             (jetpacs-action "packages.delete"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Uninstall %s" name)))
          ((not (equal status "built-in"))
           (jetpacs-icon-button "arrow_downward"
                             (jetpacs-action "packages.install"
                                          :args `((package . ,name))
                                          :when-offline "drop")
                             :content-description (format "Install %s" name))))))
       :on-tap (jetpacs-action "packages.describe"
                            :args `((package . ,name))
                            :when-offline "drop")))))

(setf (alist-get 'package-menu-mode jetpacs-tablist-header-functions)
      #'jetpacs-pkg--header)
(setf (alist-get 'package-menu-mode jetpacs-tablist-row-functions)
      #'jetpacs-pkg--row)
(setf (alist-get 'package-menu-mode jetpacs-tablist-filter-functions)
      #'jetpacs-pkg--filter)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun jetpacs-pkg--buffer ()
  "The live *Packages* menu buffer, creating (without fetching) if needed."
  (require 'package)
  (unless package--initialized (package-initialize))
  (or (get-buffer "*Packages*")
      (save-window-excursion
        (list-packages t)
        (get-buffer "*Packages*"))))

(defun jetpacs-pkg--revert ()
  "Re-generate the package menu after an install/delete and re-push."
  (let ((buf (get-buffer "*Packages*")))
    (when buf
      (with-current-buffer buf
        (ignore-errors (revert-buffer)))))
  (jetpacs-tablist-refresh-view))

(jetpacs-defaction "packages.show"
  (lambda (_ __)
    (let ((buf (jetpacs-pkg--buffer)))
      (when (and buf (null package-archive-contents))
        (jetpacs-pkg--toast
         "Archives not fetched yet - tap Refresh archives"))
      (funcall jetpacs-tablist-view-buffer-function (buffer-name buf)))))

(jetpacs-defaction "packages.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq jetpacs-pkg--search
            (downcase (or (and (stringp q) q) "")))
      (jetpacs-tablist-refresh-view))))

(jetpacs-defaction "packages.status-filter"
  (lambda (args _)
    (let ((s (alist-get 'status args)))
      (when (assoc s jetpacs-pkg--statuses)
        (setq jetpacs-pkg--status s)
        (jetpacs-tablist-refresh-view)))))

(jetpacs-defaction "packages.install"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (assq sym package-archive-contents)))
          (jetpacs-pkg--toast (format "%s is not in the archives" name))
        (jetpacs-pkg--toast (format "Installing %s…" name))
        (condition-case err
            (progn
              (package-install sym)
              (jetpacs-pkg--toast (format "Installed %s" name)))
          (error (jetpacs-pkg--toast
                  (format "Install failed: %s" (error-message-string err)))))
        (jetpacs-pkg--revert)))))

(jetpacs-defaction "packages.delete"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name)))
           (desc (and sym (cadr (assq sym package-alist)))))
      (if (not desc)
          (jetpacs-pkg--toast (format "%s is not installed" name))
        (condition-case err
            (progn
              (package-delete desc)
              (jetpacs-pkg--toast (format "Deleted %s" name)))
          (error (jetpacs-pkg--toast
                  ;; Typically: something still depends on it.
                  (format "Delete failed: %s" (error-message-string err)))))
        (jetpacs-pkg--revert)))))

(jetpacs-defaction "packages.refresh-archives"
  (lambda (_ __)
    (jetpacs-pkg--toast "Refreshing package archives…")
    (condition-case err
        (progn
          (require 'package)
          (unless package--initialized (package-initialize))
          (package-refresh-contents)
          (jetpacs-pkg--toast "Archives refreshed"))
      (error (jetpacs-pkg--toast
              (format "Refresh failed: %s" (error-message-string err)))))
    (jetpacs-pkg--revert)))

(jetpacs-defaction "packages.upgrade-all"
  (lambda (_ __)
    (if (not (fboundp 'package-upgrade-all))
        (jetpacs-pkg--toast "Upgrade-all needs Emacs 29+")
      (jetpacs-pkg--toast "Upgrading all packages…")
      (condition-case err
          (progn
            (package-upgrade-all nil)
            (jetpacs-pkg--toast "Upgrades complete"))
        (error (jetpacs-pkg--toast
                (format "Upgrade failed: %s" (error-message-string err)))))
      (jetpacs-pkg--revert))))

(jetpacs-defaction "packages.describe"
  (lambda (args _)
    (let* ((name (alist-get 'package args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym
                 (or (assq sym package-archive-contents)
                     (assq sym package-alist)
                     (assq sym package--builtins)))
        (save-window-excursion (describe-package sym))
        (funcall jetpacs-tablist-view-buffer-function "*Help*")))))

;; The browser's entry point: a card in the settings screen's Emacs
;; section (drawer slots stay reserved for everyday navigation).
(jetpacs-settings-add-link
 10 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "archive")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Packages" 'label)
                               (jetpacs-text "Install and manage Emacs packages"
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-action "packages.show" :when-offline "drop"))))

(provide 'jetpacs-package-browser)
;;; jetpacs-package-browser.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-customize.el
;;; ==================================================================

;;; jetpacs-customize.el --- Customize browser over the defcustom group tree -*- lexical-binding: t; -*-

;; The M-x customize counterpart of the tablist story.  For
;; tabulated-list the printed buffer is itself the declarative source,
;; so jetpacs-tablist walks it; a Custom-mode buffer is widget.el *layout*
;; — positions and markers, not data — and the wrong thing to scrape.
;; The declarative framework behind Customize is the metadata: the
;; defgroup tree plus each variable's `custom-type' schema, and
;; jetpacs-settings.el already renders those schemas as native controls.
;; So this app skips Custom-mode entirely: `custom-group-members'
;; provides the structure, the shared settings item renderer and apply
;; pipeline provide the leaves, and edits persist through Customize
;; (`customize-set-variable' + `customize-save-variable') like every
;; other setting.  A Custom buffer opened by hand still renders through
;; Tier 0, whose widget support can push its buttons and edit fields.
;;
;; Boundary (docs/SPEC.md §5): `customize.set' / `customize.reset'
;; accept any symbol satisfying `custom-variable-p' — deliberately wider
;; than the `settings.*' registry gate, and exactly as powerful as
;; M-x customize itself (which the M-x escape hatch already exposes).
;; Values remain plain data validated against the variable's declared
;; type before they are applied; nothing off the wire is funcalled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cus-edit)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-settings)
(require 'jetpacs-shell)

;; ─── View state ──────────────────────────────────────────────────────────────

(defcustom jetpacs-customize-max-items 50
  "Maximum subgroups and maximum variables rendered per customize screen.
Huge groups (or a broad search) are capped with a trailing note; narrow
with the search box rather than paging."
  :type 'integer :group 'jetpacs)

(defvar jetpacs-customize--path '(emacs)
  "Breadcrumb of group symbols from the root to the group being shown.")

(defvar jetpacs-customize--search ""
  "Current search string; non-empty switches to the flat variable list.")

(defvar jetpacs-customize--modified-only nil
  "Non-nil limits the view to variables changed from their defaults.")

(defun jetpacs-customize--group ()
  "The group currently being browsed."
  (car (last jetpacs-customize--path)))

(defun jetpacs-customize--flat-p ()
  "Non-nil when showing the flat variable list instead of the group tree."
  (or jetpacs-customize--modified-only
      (not (string-empty-p jetpacs-customize--search))))

;; ─── Reading the group tree ──────────────────────────────────────────────────

(defun jetpacs-customize--group-p (sym)
  "Non-nil when SYM names a customization group, loading it if deferred.
`custom-load-symbol' pulls in members a package declared via
`custom-autoload' — the same load Customize performs opening a group."
  (when sym
    (ignore-errors (custom-load-symbol sym))
    (and (or (get sym 'custom-group)
             (get sym 'group-documentation))
         t)))

(defun jetpacs-customize--members (group)
  "GROUP's members as (GROUPS VARIABLES FACES), each a list of symbols."
  (let (groups vars faces)
    (dolist (m (custom-group-members group nil))
      (pcase (cadr m)
        ('custom-group (push (car m) groups))
        ('custom-variable (push (car m) vars))
        ('custom-face (push (car m) faces))))
    (list (nreverse groups) (nreverse vars) (nreverse faces))))

(defun jetpacs-customize--flat-vars ()
  "All customizable variables passing the search and modified filters."
  (let ((q jetpacs-customize--search) out)
    (mapatoms
     (lambda (sym)
       (when (and (custom-variable-p sym)
                  (or (string-empty-p q)
                      (string-match-p (regexp-quote q) (symbol-name sym)))
                  (or (not jetpacs-customize--modified-only)
                      (jetpacs-settings-modified-p sym)))
         (push sym out))))
    (sort out #'string-lessp)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defvar jetpacs-customize--watched (make-hash-table :test 'eq)
  "Symbols whose switch state handler has been registered this session.
The settings registry registers its handlers at load, so queued toggles
always replay; customize covers arbitrary variables, so handlers are
registered when a variable first renders.  A toggle queued offline
against a variable this session has never rendered lands in
`jetpacs-ui-state' without applying — the documented cost of not
enumerating every defcustom up front.")

(defun jetpacs-customize--watch (sym)
  "Register SYM's switch handler under custom/SYM once."
  (unless (gethash sym jetpacs-customize--watched)
    (puthash sym t jetpacs-customize--watched)
    (jetpacs-settings-watch-toggle sym (concat "custom/" (symbol-name sym)))))

(defun jetpacs-customize--var-item (sym)
  "SYM as a native settings card dispatching customize.* actions."
  (if (not (boundp sym))
      ;; Autoloaded defcustom whose library isn't loaded: no type schema
      ;; to render a control from yet.
      (jetpacs-card
       (list (jetpacs-text (symbol-name sym) 'label)
             (jetpacs-text "Not loaded — tap to load its library" 'caption))
       :on-tap (jetpacs-action "customize.load"
                            :args `((name . ,(symbol-name sym)))
                            :when-offline "drop"))
    (jetpacs-customize--watch sym)
    (jetpacs-card (list (jetpacs-settings-item
                      sym
                      :id-prefix "custom/"
                      :set-action "customize.set"
                      :reset-action "customize.reset")))))

(defun jetpacs-customize--group-card (sym)
  "A tappable card descending into group SYM."
  (let ((doc (get sym 'group-documentation)))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-box
             (list (apply #'jetpacs-column
                          (delq nil
                                (list (jetpacs-text (symbol-name sym) 'label)
                                      (when doc
                                        (jetpacs-text (car (split-string doc "\n"))
                                                   'caption))))))
             :weight 1)
            (jetpacs-icon "chevron_right")))
     :on-tap (jetpacs-action "customize.browse"
                          :args `((group . ,(symbol-name sym)))
                          :when-offline "drop"))))

(defun jetpacs-customize--crumbs ()
  "The breadcrumb path as one line: link-styled ancestors › bold current.
Tapping an ancestor pops back to it (customize.browse truncates the
path when the group is already on it)."
  (let ((current (jetpacs-customize--group)))
    (jetpacs-rich-text
     (cl-loop for g in jetpacs-customize--path
              for i from 0
              unless (zerop i) collect (jetpacs-span " › ")
              collect (if (eq g current)
                          (jetpacs-span (capitalize (symbol-name g)) :bold t)
                        (jetpacs-span (capitalize (symbol-name g))
                                   :on-tap (jetpacs-action
                                            "customize.browse"
                                            :args `((group . ,(symbol-name g)))
                                            :when-offline "drop"))))
     :style 'body)))

(defun jetpacs-customize--cap-note (total what)
  "The trailing truncation note, as a list, when TOTAL exceeds the cap."
  (when (> total jetpacs-customize-max-items)
    (list (jetpacs-text (format "Showing %d of %d %s — narrow with the search."
                             jetpacs-customize-max-items total what)
                     'caption))))

(defun jetpacs-customize--group-nodes ()
  "The browse view: breadcrumbs, subgroup cards, variable items."
  (pcase-let* ((group (jetpacs-customize--group))
               (`(,groups ,vars ,faces) (jetpacs-customize--members group))
               (doc (get group 'group-documentation)))
    (append
     (list (jetpacs-customize--crumbs))
     (when doc (list (jetpacs-text (car (split-string doc "\n")) 'caption)))
     (when groups
       (append
        (list (jetpacs-section-header (format "Groups (%d)" (length groups))))
        (mapcar #'jetpacs-customize--group-card
                (cl-subseq groups 0 (min (length groups)
                                         jetpacs-customize-max-items)))
        (jetpacs-customize--cap-note (length groups) "groups")))
     (when vars
       (append
        (list (jetpacs-section-header (format "Variables (%d)" (length vars))))
        (mapcar #'jetpacs-customize--var-item
                (cl-subseq vars 0 (min (length vars)
                                       jetpacs-customize-max-items)))
        (jetpacs-customize--cap-note (length vars) "variables")))
     (when faces
       (list (jetpacs-text (format "%d face%s — edit faces in Emacs"
                                (length faces)
                                (if (= (length faces) 1) "" "s"))
                        'caption)))
     (unless (or groups vars faces)
       (list (jetpacs-empty-state :icon "tune" :title "Nothing here"
                               :caption "This group declares no members."))))))

(defun jetpacs-customize--flat-nodes ()
  "The search/modified view: a flat, capped list of variable items."
  (let* ((syms (jetpacs-customize--flat-vars))
         (total (length syms)))
    (if (null syms)
        (list (jetpacs-empty-state
               :icon "search" :title "No matching variables"
               :caption "Search matches customizable variable names."))
      (append
       (list (jetpacs-text (format "%d variable%s" total (if (= total 1) "" "s"))
                        'caption))
       (mapcar #'jetpacs-customize--var-item
               (cl-subseq syms 0 (min total jetpacs-customize-max-items)))
       (jetpacs-customize--cap-note total "variables")))))

(defun jetpacs-customize--body ()
  ;; lazy_column, not column: the scaffold body has no scroll container
  ;; on the client, so a plain column taller than the screen is simply
  ;; unreachable below the fold.
  (apply #'jetpacs-lazy-column
         (append
          ;; The framing: the Settings screen is the curated Tier 1
          ;; experience; this browser is the escape hatch to everything
          ;; else, and "everything else" is desktop-oriented.
          (list (jetpacs-text
                 (concat "These are desktop Emacs's own options — many "
                         "won't affect the phone experience. Curated "
                         "options live in Settings.")
                 'caption)
                (jetpacs-text-input "customize-search"
                                 :value jetpacs-customize--search
                                 :label "Search all variables" :single-line t
                                 :on-submit (jetpacs-action "customize.search"))
                (jetpacs-flow-row
                 (jetpacs-chip "Modified"
                            :selected jetpacs-customize--modified-only
                            :on-tap (jetpacs-action "customize.modified-filter"
                                                 :when-offline "drop"))))
          (if (jetpacs-customize--flat-p)
              (jetpacs-customize--flat-nodes)
            (jetpacs-customize--group-nodes)))))

(defun jetpacs-customize--view (snackbar)
  "The shell view: back pops one level until the root, then leaves."
  (jetpacs-shell-nav-view
   "Customize" (jetpacs-customize--body)
   :nav-action (unless (and (null (cdr jetpacs-customize--path))
                            (not (jetpacs-customize--flat-p)))
                 (jetpacs-action "customize.up" :when-offline "drop"))
   :snackbar snackbar))

(jetpacs-shell-define-view "customize" :builder #'jetpacs-customize--view :order 85)

;; Entry point: a card in the settings screen's Emacs section (a
;; companion-local view switch, so it works offline).
(jetpacs-settings-add-link
 20 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "tune")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Customize" 'label)
                               (jetpacs-text "Browse and edit any Emacs option"
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-shell-switch-view "customize"))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(jetpacs-defaction "customize.show"
  ;; Open the browser, optionally at GROUP (for cross-links from other
  ;; screens); with no group it resumes wherever the user last was.
  (lambda (args _)
    (let* ((name (alist-get 'group args))
           (sym (and (stringp name) (intern-soft name))))
      (when (jetpacs-customize--group-p sym)
        (setq jetpacs-customize--path (if (eq sym 'emacs) '(emacs)
                                     (list 'emacs sym))
              jetpacs-customize--search ""
              jetpacs-customize--modified-only nil)))
    (jetpacs-shell-push nil :switch-to "customize")))

(jetpacs-defaction "customize.browse"
  (lambda (args _)
    (let* ((name (alist-get 'group args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (jetpacs-customize--group-p sym))
          (jetpacs-shell-notify (format "%s is not a customization group"
                                     (or name "?")))
        (setq jetpacs-customize--search ""
              jetpacs-customize--modified-only nil
              jetpacs-customize--path
              (let ((at (cl-position sym jetpacs-customize--path)))
                (if at ; a breadcrumb tap: pop back to that depth
                    (cl-subseq jetpacs-customize--path 0 (1+ at))
                  (append jetpacs-customize--path (list sym))))))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.up"
  ;; The view's back arrow: dismiss the flat list first, then pop one
  ;; group; the arrow only leaves the view once both are spent (the
  ;; builder omits the action at the root, restoring the default back).
  (lambda (_ __)
    (cond ((jetpacs-customize--flat-p)
           (setq jetpacs-customize--search ""
                 jetpacs-customize--modified-only nil))
          ((cdr jetpacs-customize--path)
           (setq jetpacs-customize--path (butlast jetpacs-customize--path))))
    (jetpacs-shell-push)))

(jetpacs-defaction "customize.search"
  (lambda (args _)
    (let ((q (alist-get 'value args)))
      (setq jetpacs-customize--search
            (downcase (string-trim (or (and (stringp q) q) ""))))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.modified-filter"
  (lambda (_ __)
    (setq jetpacs-customize--modified-only (not jetpacs-customize--modified-only))
    (jetpacs-shell-push)))

(jetpacs-defaction "customize.load"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (when (and sym (custom-variable-p sym))
        (condition-case err
            (custom-load-symbol sym)
          (error (jetpacs-shell-notify (error-message-string err)))))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (custom-variable-p sym)))
          (jetpacs-shell-notify
           (format "%s is not a customizable variable" (or name "?")))
        ;; A deferred defcustom must load before its type can validate.
        (ignore-errors (custom-load-symbol sym))
        (jetpacs-settings-apply-wire sym (alist-get 'value args)))
      (jetpacs-shell-push))))

(jetpacs-defaction "customize.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (not (and sym (custom-variable-p sym)))
          (jetpacs-shell-notify "Cannot reset this setting")
        (jetpacs-settings-reset sym))
      (jetpacs-shell-push))))

(provide 'jetpacs-customize)
;;; jetpacs-customize.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-tools.el
;;; ==================================================================

;;; jetpacs-tools.el --- Built-in Emacs tools: bookmarks, kill ring, shell, processes, timers -*- lexical-binding: t; -*-

;; Entry points for screens the substrates already cover.
;; `bookmark-bmenu-mode', `process-menu-mode' and `timer-list-mode' all
;; derive from `tabulated-list-mode', so the Tier 0.5 tablist renderer
;; draws them today — each needs only a semantic action that creates the
;; buffer and navigates the buffer view to it (the packages.show
;; pattern).  A shell entry does the same for `M-x shell', rendered by
;; the comint substrate (jetpacs-comint.el).  The kill ring is pure data —
;; no buffer at all — so it renders as its own view of cards, each with
;; a companion-local copy button (works offline, no round trip).
;;
;; One "Tools" drawer item opens a hub view of these; five separate
;; drawer entries would crowd the drawer.

;;; Code:

(require 'cl-lib)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-tablist)
(require 'jetpacs-shell)

(declare-function bookmark-maybe-load-default-file "bookmark")
(declare-function bookmark-bmenu-list "bookmark")
(declare-function bookmark-get-bookmark "bookmark")
(declare-function bookmark-jump "bookmark")

;; ─── Showing a tool buffer ───────────────────────────────────────────────────

(defun jetpacs-tools--view-buffer-of (fn)
  "Call FN (returning a buffer or buffer name) and view the result.
Window excursion contains the pop-to-buffer these commands do; errors
land in the snackbar instead of dying silently."
  (condition-case err
      (let ((buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

(jetpacs-defaction "tools.bookmarks"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda ()
       (require 'bookmark)
       (bookmark-maybe-load-default-file)
       (bookmark-bmenu-list)
       "*Bookmark List*"))))

(jetpacs-defaction "tools.processes"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda () (list-processes) "*Process List*"))))

(jetpacs-defaction "tools.timers"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda ()
       (unless (fboundp 'list-timers) (require 'timer-list))
       ;; Called as a function, so its `disabled' novice flag (which
       ;; guards the interactive command loop) does not apply.
       (list-timers)
       "*timer-list*"))))

(jetpacs-defaction "tools.shell"
  (lambda (_ __)
    (jetpacs-tools--view-buffer-of
     (lambda ()
       (require 'shell)
       (shell)))))

;; ─── Bookmark rows: tap = jump ───────────────────────────────────────────────

(defun jetpacs-tools--bookmark-name (id)
  "The bookmark name from a bmenu row ID (a name string or a record)."
  (cond ((stringp id) id)
        ((and (consp id) (stringp (car id))) (car id))))

(defun jetpacs-tools--bookmark-row (id entry _pos)
  "Tablist row skin for bookmark-bmenu: tapping jumps to the bookmark."
  (let ((name (jetpacs-tools--bookmark-name id)))
    (when name
      (let ((file (or (jetpacs-tablist-entry-col entry "File") "")))
        (jetpacs-card
         (list (apply #'jetpacs-column
                      (delq nil
                            (list (jetpacs-text name 'label)
                                  (unless (string-empty-p file)
                                    (jetpacs-text file 'caption))))))
         :on-tap (jetpacs-action "tools.bookmark-jump"
                              :args `((bookmark . ,name))
                              :when-offline "drop"))))))

(setf (alist-get 'bookmark-bmenu-mode jetpacs-tablist-row-functions)
      #'jetpacs-tools--bookmark-row)

(jetpacs-defaction "tools.bookmark-jump"
  ;; Validated against the bookmark alist; the jump runs inside the
  ;; action handler, so a relocation prompt (file moved) is bridged.
  ;; The whole flow sits in the condition-case — even loading the
  ;; bookmark file can signal (a corrupt file must cost a snackbar, not
  ;; the action dispatcher).
  (lambda (args _)
    (let ((name (alist-get 'bookmark args)))
      (when (stringp name)
        (condition-case err
            (progn
              (require 'bookmark)
              (bookmark-maybe-load-default-file)
              (when (bookmark-get-bookmark name t)
                (let ((target (save-window-excursion
                                (bookmark-jump name)
                                (buffer-name (current-buffer)))))
                  (funcall jetpacs-tablist-view-buffer-function target))))
          (error (jetpacs-shell-notify
                  (format "Bookmark failed: %s"
                          (error-message-string err)))))))))

;; ─── Kill ring ───────────────────────────────────────────────────────────────

(defcustom jetpacs-tools-kill-ring-max 50
  "Kill-ring entries shown in the Kill ring view."
  :type 'integer :group 'jetpacs)

(defun jetpacs-tools--kill-card (text)
  "A card for one kill: a trimmed preview plus a copy-to-phone button.
The copy is the companion-local clipboard builtin, so it works offline
and carries the full (untrimmed) text."
  (let* ((clean (substring-no-properties text))
         (preview (string-trim
                   (if (> (length clean) 500) (substring clean 0 500) clean))))
    (jetpacs-card
     (list (jetpacs-row
            (jetpacs-box (list (jetpacs-text (if (string-empty-p preview) " " preview)
                                       'body nil nil t 4))
                      :weight 1)
            (jetpacs-icon-button "content_copy"
                              (jetpacs-clipboard-action clean)
                              :content-description "Copy to phone clipboard"))))))

(defun jetpacs-tools--kill-ring-body ()
  (let ((kills (cl-subseq kill-ring
                          0 (min (length kill-ring) jetpacs-tools-kill-ring-max))))
    (if (null kills)
        (jetpacs-empty-state :icon "content_paste" :title "Kill ring is empty"
                          :caption "Text killed in Emacs shows up here.")
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-text (format "%d of %d kills, newest first"
                                      (length kills) (length kill-ring))
                              'caption)
                   (mapcar #'jetpacs-tools--kill-card kills))))))

(defun jetpacs-tools--kill-ring-view (snackbar)
  (jetpacs-shell-nav-view "Kill ring" (jetpacs-tools--kill-ring-body)
                       :back-to "tools"
                       :snackbar snackbar))

;; ─── The hub view and drawer entry ───────────────────────────────────────────

(defun jetpacs-tools--entry (icon title caption action)
  (jetpacs-card
   (list (jetpacs-row
          (jetpacs-icon icon)
          (jetpacs-box (list (jetpacs-column (jetpacs-text title 'label)
                                       (jetpacs-text caption 'caption)))
                    :weight 1)
          (jetpacs-icon "chevron_right")))
   :on-tap action))

(defun jetpacs-tools--view (snackbar)
  (jetpacs-shell-nav-view
   "Tools"
   (jetpacs-lazy-column
    (jetpacs-tools--entry "bookmark" "Bookmarks"
                       "Jump to saved places"
                       (jetpacs-action "tools.bookmarks" :when-offline "drop"))
    (jetpacs-tools--entry "content_paste" "Kill ring"
                       "Copy recent kills to the phone clipboard"
                       (jetpacs-shell-switch-view "kill-ring"))
    (jetpacs-tools--entry "terminal" "Shell"
                       "M-x shell, rendered as a REPL"
                       (jetpacs-action "tools.shell" :when-offline "drop"))
    (jetpacs-tools--entry "dns" "Remote hosts"
                       "Files, shells, and services over TRAMP"
                       (jetpacs-shell-switch-view "hosts"))
    (jetpacs-tools--entry "memory" "Processes"
                       "Subprocesses of this Emacs"
                       (jetpacs-action "tools.processes" :when-offline "drop"))
    (jetpacs-tools--entry "timer" "Timers"
                       "Active Emacs timers"
                       (jetpacs-action "tools.timers" :when-offline "drop")))
   :snackbar snackbar))

(jetpacs-shell-define-view "tools" :builder #'jetpacs-tools--view :order 86)
(jetpacs-shell-define-view "kill-ring" :builder #'jetpacs-tools--kill-ring-view
                        :order 87)

(jetpacs-shell-add-drawer-item
 50 (lambda ()
      (jetpacs-drawer-item "build" "Tools" (jetpacs-shell-switch-view "tools"))))

(provide 'jetpacs-tools)
;;; jetpacs-tools.el ends here

;;; ==================================================================
;;; BEGIN core/jetpacs-hosts.el
;;; ==================================================================

;;; jetpacs-hosts.el --- Remote hosts hub: TRAMP endpoints as cards -*- lexical-binding: t; -*-

;; The server pillar's one piece of construction.  Everything else about
;; driving a remote host from the phone is composition over what already
;; ships: TRAMP makes the existing skins remote — dired cards, comint
;; shells, compile/grep results, magit-section buffers, `daemons.el'
;; (tabulated-list → the tablist substrate), Emacs-Guix's bui lists — and
;; the minibuffer bridge already turns ssh password prompts into phone
;; dialogs.  What was missing is the front door: a card per host with the
;; things you actually do one-handed — browse its files, open a shell on
;; it, glance at its services, cut the connection.
;;
;; Hosts come from two places: the `jetpacs-hosts' defcustom (explicit,
;; wins) and `~/.ssh/config' Host entries (free coverage of everything
;; already configured; wildcard patterns are skipped).  The computed list
;; is also the action allowlist: the wire carries a host LABEL, never a
;; TRAMP path — the handler resolves the label against the list and
;; refuses anything else (the results.visit contract).
;;
;; Battery/latency guardrails, in order of importance: rendering NEVER
;; touches the network (connection state is read from tramp's existing
;; connection table, not probed); connect-ish actions bind
;; `tramp-connection-timeout' down to `jetpacs-hosts-connect-timeout' so a
;; dead host costs seconds, not a minute of blocked bridge; and the
;; Disconnect button exists precisely so lingering ssh masters don't
;; outlive their usefulness.  TRAMP operations are synchronous by nature —
;; this screen exposes glance-and-act operations, not long pipelines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)      ; jetpacs-defaction / jetpacs-action
(require 'jetpacs-tablist)       ; jetpacs-tablist-view-buffer-function (the
                                ;   buffer-view seam, set by jetpacs-emacs-ui)
(require 'jetpacs-shell)

;; TRAMP is built-in but heavy; it loads itself the moment a remote path
;; is touched.  Nothing here requires it up front.
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-list-connections "tramp-cmds" ())
(declare-function tramp-cleanup-connection "tramp-cmds"
                  (vec &optional keep-debug keep-password))
(declare-function tramp-file-name-host "tramp" (vec))
(declare-function tramp-file-name-method "tramp" (vec))
(declare-function dired-noselect "dired" (dir-or-list &optional switches))

;; Forward declaration so the timeout let-binding is DYNAMIC even before
;; tramp loads (an undeclared symbol would bind lexically — and silently
;; not reach tramp at all).
(defvar tramp-connection-timeout)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-hosts nil
  "Remote hosts shown in the Hosts hub: an alist of (LABEL . TRAMP-DIR).
LABEL is what the card shows (and all the wire ever carries); TRAMP-DIR
is where its actions land, e.g. (\"build box\" . \"/ssh:build:~/\").
Entries here win over same-labelled `~/.ssh/config' discoveries."
  :type '(alist :key-type string :value-type string) :group 'jetpacs)

(defcustom jetpacs-hosts-from-ssh-config t
  "When non-nil, `~/.ssh/config' Host entries also appear in the hub.
Each concrete Host name (wildcard patterns are skipped) becomes an
/ssh: card pointing at its home directory — zero configuration for
machines ssh already knows."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-hosts-connect-timeout 10
  "Seconds a hub action waits for a TRAMP connection before giving up.
Bound over `tramp-connection-timeout' (default 60s) while a hub action
connects: on a phone, a dead host must cost seconds, not a minute of
blocked bridge."
  :type 'integer :group 'jetpacs)

;; ─── The host list (and action allowlist) ───────────────────────────────────

(defun jetpacs-hosts--ssh-config-hosts (file)
  "Concrete Host names from ssh config FILE, in order, duplicates removed.
A `Host' line may carry several names; patterns (any of `*?!') and the
negations ssh uses for exclusions are skipped.  Returns nil when FILE is
missing or unreadable."
  (when (and (stringp file) (file-readable-p file))
    (let (hosts)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*[Hh]ost[ \t]+\\(.+\\)$" nil t)
          (dolist (name (split-string (match-string 1)))
            (unless (string-match-p "[*?!]" name)
              (push name hosts)))))
      (delete-dups (nreverse hosts)))))

(defun jetpacs-hosts--all ()
  "The live host alist (LABEL . TRAMP-DIR): `jetpacs-hosts' first, then
ssh-config discoveries not shadowed by an explicit label.  This list is
the allowlist every hub action resolves against."
  (let ((all (copy-sequence jetpacs-hosts)))
    (when jetpacs-hosts-from-ssh-config
      (dolist (name (jetpacs-hosts--ssh-config-hosts
                     (expand-file-name "~/.ssh/config")))
        (unless (assoc name all)
          (setq all (nconc all (list (cons name (format "/ssh:%s:~/" name))))))))
    all))

(defun jetpacs-hosts--resolve (label)
  "LABEL's TRAMP directory from the live host list, or nil."
  (cdr (assoc label (jetpacs-hosts--all))))

;; ─── Connection state (read, never probed) ───────────────────────────────────

(defun jetpacs-hosts--connected-p (dir)
  "Whether DIR's host has a live TRAMP connection right now.
Reads tramp's own connection table; never opens one.  When tramp isn't
even loaded, nothing is connected."
  (and (featurep 'tramp)
       (fboundp 'tramp-list-connections)
       (condition-case nil
           (let ((vec (tramp-dissect-file-name dir)))
             (and vec
                  (cl-some (lambda (live)
                             (and (equal (tramp-file-name-host live)
                                         (tramp-file-name-host vec))
                                  (equal (tramp-file-name-method live)
                                         (tramp-file-name-method vec))))
                           (tramp-list-connections))))
         (error nil))))

;; ─── Opening things on a host ────────────────────────────────────────────────

(defun jetpacs-hosts--view-buffer-of (fn)
  "Call FN (returning a buffer or name) under the connect guardrails and
view the result — the tools-hub pattern, plus the timeout clamp.  A
password prompt raised mid-connect is bridged automatically (we are
inside an action handler); a dead host costs a snackbar."
  (condition-case err
      (let* ((tramp-connection-timeout jetpacs-hosts-connect-timeout) ;dynamic
             (buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

(defun jetpacs-hosts--with-host (args fn)
  "Resolve ARGS' host label against the allowlist and call FN with
\(LABEL . DIR); refuse anything the list doesn't know."
  (let* ((label (alist-get 'host args))
         (dir (and (stringp label) (jetpacs-hosts--resolve label))))
    (if (not dir)
        (jetpacs-shell-notify "Unknown host")
      (funcall fn label dir))))

(jetpacs-defaction "hosts.files"
  ;; Browse the host: a dired buffer on its TRAMP dir, rendered by the
  ;; dired cards skin through the buffer view.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (_label dir)
       (jetpacs-hosts--view-buffer-of
        (lambda ()
          (require 'dired)
          (dired-noselect dir)))))))

(jetpacs-defaction "hosts.shell"
  ;; A shell ON the host: M-x shell with a remote default-directory —
  ;; TRAMP runs the remote shell, the comint substrate renders it.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (label dir)
       (jetpacs-hosts--view-buffer-of
        (lambda ()
          (require 'shell)
          (let ((default-directory dir))
            (shell (generate-new-buffer-name (format "*shell %s*" label))))))))))

(jetpacs-defaction "hosts.services"
  ;; The host's services via daemons.el (third-party, soft): its
  ;; tabulated-list buffer rides the tablist substrate for free, and
  ;; daemons.el itself runs systemctl over TRAMP when default-directory
  ;; is remote.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (_label dir)
       (if (not (require 'daemons nil t))
           (jetpacs-shell-notify "daemons.el is not installed")
         (jetpacs-hosts--view-buffer-of
          (lambda ()
            (let ((default-directory dir))
              (save-window-excursion (funcall (intern "daemons")))
              "*daemons*"))))))))

(jetpacs-defaction "hosts.disconnect"
  ;; Cut the host's TRAMP connection (and its lingering ssh master) —
  ;; the battery-hygiene button.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (label dir)
       (if (not (jetpacs-hosts--connected-p dir))
           (jetpacs-shell-notify "Not connected")
         (condition-case err
             (progn
               (tramp-cleanup-connection (tramp-dissect-file-name dir))
               (jetpacs-shell-notify (format "Disconnected %s" label)))
           (error (jetpacs-shell-notify (error-message-string err)))))
       (jetpacs-shell-push)))))

;; ─── The hub view ────────────────────────────────────────────────────────────

(defvar jetpacs-hosts--daemons-available 'unknown
  "Cached `daemons.el' availability (a load-path scan is disk I/O;
render must stay cheap).  Reset to `unknown' after installing it.")

(defun jetpacs-hosts--daemons-p ()
  (when (eq jetpacs-hosts--daemons-available 'unknown)
    (setq jetpacs-hosts--daemons-available
          (and (locate-library "daemons") t)))
  jetpacs-hosts--daemons-available)

(defun jetpacs-hosts--card (entry)
  "A card for host ENTRY (LABEL . DIR): name, endpoint, state, actions."
  (let* ((label (car entry))
         (dir (cdr entry))
         (connected (jetpacs-hosts--connected-p dir))
         (args `((host . ,label))))
    (jetpacs-card
     (list
      (jetpacs-column
       (apply #'jetpacs-row
              (delq nil
                    (list
                     (jetpacs-box (list (jetpacs-column
                                   (jetpacs-text label 'label)
                                   (jetpacs-text dir 'caption)))
                               :weight 1)
                     (when connected
                       (jetpacs-chip "Connected" :icon "link")))))
       (apply #'jetpacs-row
              (append
               (delq nil
                     (list
                      (jetpacs-button "Files"
                                   (jetpacs-action "hosts.files" :args args
                                                :when-offline "drop")
                                   :icon "folder" :variant "tonal")
                      (jetpacs-button "Shell"
                                   (jetpacs-action "hosts.shell" :args args
                                                :when-offline "drop")
                                   :icon "terminal" :variant "tonal")
                      (when (jetpacs-hosts--daemons-p)
                        (jetpacs-button "Services"
                                     (jetpacs-action "hosts.services" :args args
                                                  :when-offline "drop")
                                     :icon "settings_suggest" :variant "tonal"))
                      (when connected
                        (jetpacs-icon-button "link_off"
                                          (jetpacs-action "hosts.disconnect"
                                                       :args args
                                                       :when-offline "drop")
                                          :content-description "Disconnect"))))
               '(:spacing 4))))))))

(defun jetpacs-hosts--body ()
  (let ((hosts (jetpacs-hosts--all)))
    (if (null hosts)
        (jetpacs-empty-state
         :icon "dns" :title "No hosts configured"
         :caption (concat "Add (LABEL . \"/ssh:host:~/\") pairs to "
                          "jetpacs-hosts, or list machines in ~/.ssh/config "
                          "— concrete Host entries appear here automatically."))
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-text
                    "Passwords prompt on the phone; connections stay up until you disconnect."
                    'caption)
                   (mapcar #'jetpacs-hosts--card hosts))))))

(defun jetpacs-hosts--view (snackbar)
  (jetpacs-shell-nav-view "Remote hosts" (jetpacs-hosts--body)
                       :back-to "tools"
                       :snackbar snackbar))

(jetpacs-shell-define-view "hosts" :builder #'jetpacs-hosts--view :order 88)

(provide 'jetpacs-hosts)
;;; jetpacs-hosts.el ends here
;;; ==================================================================
;;; BEGIN core/jetpacs-automations.el
;;; ==================================================================

;;; jetpacs-automations.el --- Automations management view -*- lexical-binding: t; -*-

;; The phone-side management surface for device triggers (SPEC §11):
;; one card per registration with an enable switch (persisted through
;; Customize), the wire fields at a glance, the last-fired time, and a
;; "Fire now" test button.  Pure rendering — the registry, the actions
;; (`trigger.toggle' / `trigger.test'), and the persistence live in
;; jetpacs-triggers.el; authoring stays in elisp (`jetpacs-deftrigger'
;; in your init).  Rule layers on top are app territory (the glasspane
;; repo's glasspane-automations.el reads them from org files).
;;
;; Deliberately NOT an `jetpacs-defapp': that would flip the launcher into
;; multi-app mode for everyone.  It is a satellite screen behind a
;; settings link, per the drawer contract.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-triggers)
(require 'jetpacs-settings)

(defun jetpacs-automations--summary (reg)
  "One-line wire summary of registration plist REG."
  (let ((params (plist-get reg :params)))
    (string-join
     (delq nil
           (list (plist-get reg :type)
                 (when params
                   (mapconcat (lambda (kv)
                                (format "%s=%s" (car kv) (cdr kv)))
                              params " "))
                 (format "policy %s" (or (plist-get reg :policy) "queue"))
                 (when-let ((throttle (plist-get reg :throttle-s)))
                   (format "throttle %ss" throttle))
                 (when (plist-get reg :on-fire) "on-fire")))
     " · ")))

(defun jetpacs-automations--last-fired (id)
  "Human line for ID's most recent fire, or a quiet placeholder."
  (if-let ((at (gethash id jetpacs-triggers--last-fired)))
      (format-time-string "Last fired %b %e %H:%M" at)
    "Never fired"))

(defun jetpacs-automations--card (id reg)
  "The management card for trigger ID."
  (let ((enabled (jetpacs-trigger-enabled-p id)))
    (jetpacs-card
     (list
      (jetpacs-column
       (jetpacs-row
        (jetpacs-box (list (jetpacs-text id 'title)) :weight 1)
        (jetpacs-switch (concat "trigger-enabled/" id)
                     :checked enabled
                     :on-change (jetpacs-action "trigger.toggle"
                                             :args `((id . ,id))
                                             :when-offline "drop")))
       (jetpacs-text (jetpacs-automations--summary reg) 'caption)
       (jetpacs-row
        (jetpacs-box (list (jetpacs-text (jetpacs-automations--last-fired id)
                                   'caption))
                  :weight 1)
        (jetpacs-button "Fire now"
                     (jetpacs-action "trigger.test"
                                  :args `((id . ,id))
                                  :when-offline "drop")
                     :variant "text"
                     :icon "play_arrow")))))))

(defun jetpacs-automations--view (snackbar)
  "The Automations screen: every registered trigger, or an empty state."
  (jetpacs-shell-nav-view
   "Automations"
   (if (zerop (hash-table-count jetpacs-triggers--table))
       (jetpacs-empty-state
        :icon "bolt" :title "No automations"
        :caption (concat "Define device triggers with jetpacs-deftrigger "
                         "in your init, then manage them here"))
     (apply #'jetpacs-lazy-column
            (mapcar (lambda (id)
                      (jetpacs-automations--card
                       id (gethash id jetpacs-triggers--table)))
                    (sort (hash-table-keys jetpacs-triggers--table)
                          #'string<))))
   :snackbar snackbar))

(jetpacs-shell-define-view "automations"
                        :builder #'jetpacs-automations--view :order 83)

;; Entry point: a card in the settings screen's Emacs section (a
;; companion-local view switch, so it opens offline too).
(jetpacs-settings-add-link
 15 (lambda ()
      (jetpacs-card
       (list (jetpacs-row
              (jetpacs-icon "bolt")
              (jetpacs-box (list (jetpacs-column
                               (jetpacs-text "Automations" 'label)
                               (jetpacs-text "Device triggers: enable, test, inspect"
                                          'caption)))
                        :weight 1)
              (jetpacs-icon "chevron_right")))
       :on-tap (jetpacs-shell-switch-view "automations"))))

;; Registry changes (a toggle from the phone, a deftrigger evaluated on
;; a live session) re-render this view.  Debounced: an automations
;; reload fires this hook once per rule, and one idle push after the
;; burst beats a full view rebuild per rule (the scheduler no-ops
;; while disconnected).
(defun jetpacs-automations--on-change ()
  (jetpacs-shell--schedule-repush))

(add-hook 'jetpacs-triggers-changed-hook #'jetpacs-automations--on-change)

(provide 'jetpacs-automations)
;;; jetpacs-automations.el ends here

(provide 'jetpacs-core)
;;; jetpacs-core.el ends here
