;;; eabp.el --- Emacs-Android Bridge Protocol client -*- lexical-binding: t; -*-

;; EABP transport, Emacs side. Under the protocol Emacs is the CLIENT and the
;; Android companion is the durable SERVER. This file owns the wire: connecting,
;; framing, the session handshake, and a generic send/request layer that the
;; surface/capability/trigger code (later phases) builds on.
;;
;; v0 framing is newline-delimited JSON over a loopback TCP socket, which the
;; spec blesses for prototyping. The 1.0 target is a Unix domain socket
;; (:family 'local) in a shared-signature dir; only `eabp--make-process'
;; changes for that. Everything above the process stays the same.
;;
;; Requires Emacs 28+ for the C-level `json-serialize' / `json-parse-string'
;; (well-defined null/false handling) and `string-search'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup eabp nil
  "Emacs-Android Bridge Protocol."
  :group 'comm)

(defcustom eabp-host "127.0.0.1"
  "Host of the companion's EABP server (loopback in v0)."
  :type 'string :group 'eabp)

(defcustom eabp-port 8765
  "TCP port the companion's EABP server listens on (v0).
Note: this is NOT the old simple-httpd port (8080). The companion now
listens; Emacs dials in here."
  :type 'integer :group 'eabp)

(defcustom eabp-protocol-version 1
  "EABP protocol version this client speaks.
This is the wire/vocabulary version — the envelope `v' and the SPEC's
version number.  Bump it only on a wire-breaking change."
  :type 'integer :group 'eabp)

(defconst eabp-api-version "1.0.0"
  "Semver of the Tier 1 elisp API surface (constructors + seams).
Independent of `eabp-protocol-version' (the wire).  A third-party Tier 1
requires the core and checks this: minor bumps are additive and safe,
major bumps may remove a symbol one minor cycle after it is marked
obsolete.  The frozen public-symbol list lives in docs/API-STABILITY.md.")

(defcustom eabp-wants
  '("surfaces.widget" "surfaces.notification" "surfaces.dialog"
    "capabilities" "triggers" "queue.replay")
  "Capability set Emacs requests during the handshake.
The companion grants the intersection with what it supports; anything it
doesn't recognise is simply not granted (forward-compat)."
  :type '(repeat string) :group 'eabp)

(defcustom eabp-auth-token nil
  "Pairing token from the companion app's pairing screen.
The companion challenges every connection; this token (never sent on
the wire — only nonce-bound HMACs are) answers the challenge, and the
companion proves it holds the same token back before the session is
trusted.  Copy the ready-made setq line by tapping it on the app's
\"Waiting for Emacs\" screen.  nil leaves the bridge unpaired: connects
are refused with guidance in *Messages*."
  :type '(choice (const :tag "Unpaired" nil) string)
  :group 'eabp)

(defvar eabp--process nil
  "The live network process, or nil when disconnected.")

(defvar eabp--auth-server-nonce nil
  "Server nonce of the in-flight auth round, or nil.")

(defvar eabp--auth-client-nonce nil
  "Our nonce for the in-flight auth round, or nil.")

(defvar eabp--buffer ""
  "Accumulates partial inbound NDJSON bytes between filter calls.")

(defvar eabp--id-counter 0
  "Monotonic source for sender-unique message ids.")

(defvar eabp--pending (make-hash-table :test 'equal)
  "Map of outstanding request id -> reply callback.")

(defvar eabp--session nil
  "Alist of negotiated session info after `session.welcome', or nil.")

(defvar eabp-connected-hook nil
  "Hook run with the welcome payload (alist) after a successful handshake.")

;; ─── Envelope ────────────────────────────────────────────────────────────────

(defun eabp--next-id ()
  "Return a fresh sender-unique message id."
  (format "m-%x-%04x" (cl-incf eabp--id-counter) (random #x10000)))

(defun eabp--encode (kind payload &optional reply-to id)
  "Encode one EABP frame to a compact JSON string.
PAYLOAD is an alist (or nil for an empty object). REPLY-TO is the id this
frame answers, or nil for a top-level message."
  (json-serialize
   `((v . ,eabp-protocol-version)
     (id . ,(or id (eabp--next-id)))
     (reply_to . ,(or reply-to :null))
     (kind . ,kind)
     (payload . ,(or payload (make-hash-table :test 'equal))))
   :null-object :null
   :false-object :false))

(defun eabp--raw-send (line)
  "Write LINE plus a newline to the companion if connected."
  (if (and eabp--process (process-live-p eabp--process))
      (process-send-string eabp--process (concat line "\n"))
    (message "EABP: not connected; dropping frame")))

(defun eabp-send (kind &optional payload reply-to)
  "Send a fire-and-forget frame. Returns its message id."
  (let ((id (eabp--next-id)))
    (eabp--raw-send (eabp--encode kind payload reply-to id))
    id))

(defun eabp-request (kind payload callback)
  "Send a frame and call CALLBACK with the reply frame's payload alist.
Correlation is by `reply_to' matching this frame's id.  When
disconnected the frame is dropped and CALLBACK is never registered —
otherwise every dropped request would leak a pending-table entry."
  (let ((id (eabp--next-id)))
    (if (and eabp--process (process-live-p eabp--process))
        (progn
          (puthash id callback eabp--pending)
          (eabp--raw-send (eabp--encode kind payload nil id)))
      (message "EABP: not connected; dropping request %s" kind))
    id))

(defun eabp-send-dialog (spec)
  "Push a dialog spec to the companion."
  (eabp-send "dialog.show" spec))

(defun eabp-dismiss-dialog ()
  "Dismiss the current dialog on the companion."
  (eabp-send "dialog.dismiss" nil))

;; ─── Pairing auth ────────────────────────────────────────────────────────────

(defun eabp--hmac-sha256-hex (key message)
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

(defun eabp--auth-nonce ()
  "A fresh nonce (64 hex chars).  Needs uniqueness, not secrecy."
  (secure-hash 'sha256 (format "%s:%s:%s:%s"
                               (random most-positive-fixnum)
                               (float-time) (emacs-pid) (current-time-string))))

(defun eabp--on-auth-challenge (payload)
  "Answer the companion's pairing challenge from PAYLOAD."
  (let ((snonce (alist-get 'nonce payload)))
    (cond
     ((not (stringp snonce))
      (message "EABP: malformed auth challenge"))
     ((not (and (stringp eabp-auth-token)
                (not (string-empty-p eabp-auth-token))))
      (message (concat "EABP: pairing required — open the companion app, tap "
                       "the (setq eabp-auth-token ...) line on its pairing "
                       "screen, add it to your init, and reconnect")))
     (t
      (setq eabp--auth-server-nonce snonce
            eabp--auth-client-nonce (eabp--auth-nonce))
      (eabp-send "auth.response"
                 `((nonce . ,eabp--auth-client-nonce)
                   (mac . ,(eabp--hmac-sha256-hex
                            eabp-auth-token
                            (format "eabp1:client:%s:%s"
                                    snonce eabp--auth-client-nonce)))))))))

(defun eabp--auth-verify-welcome (payload)
  "Non-nil when PAYLOAD's server_proof matches our challenge state.
Fails closed: once a token is configured, a welcome without a valid
proof — a companion that skipped the challenge, or a rogue app squatting
the port — is refused.  With no token configured, any welcome passes
\(the unpaired legacy path; the companion won't send one anyway)."
  (or (not (and (stringp eabp-auth-token)
                (not (string-empty-p eabp-auth-token))))
      (and eabp--auth-server-nonce eabp--auth-client-nonce
           (equal (alist-get 'server_proof payload)
                  (eabp--hmac-sha256-hex
                   eabp-auth-token
                   (format "eabp1:server:%s:%s"
                           eabp--auth-client-nonce
                           eabp--auth-server-nonce))))))

;; ─── Inbound framing & dispatch ──────────────────────────────────────────────

(defun eabp--filter (_proc chunk)
  "Accumulate CHUNK and handle every complete newline-terminated frame.
Partial frames stay buffered until the rest arrives."
  (setq eabp--buffer (concat eabp--buffer chunk))
  (let (pos)
    (while (setq pos (string-search "\n" eabp--buffer))
      (let ((line (substring eabp--buffer 0 pos)))
        (setq eabp--buffer (substring eabp--buffer (1+ pos)))
        (unless (string-empty-p (string-trim line))
          (eabp--handle-line line))))))

(defun eabp--handle-line (line)
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
          (when-let ((cb (gethash reply-to eabp--pending)))
            (remhash reply-to eabp--pending)
            (funcall cb payload)))
        (eabp--dispatch kind payload frame))
    (error (message "EABP: bad frame: %s" (error-message-string err)))))

(defvar eabp--kind-handlers (make-hash-table :test 'equal)
  "Map of frame kind (string) -> handler called with (PAYLOAD FRAME).
Extension point for the layers above the transport (surfaces, queue,
capabilities): they register here instead of patching `eabp--dispatch'.")

(defun eabp-register-handler (kind fn)
  "Register FN as the handler for inbound frames of KIND.
FN is called with two arguments, the frame's PAYLOAD alist and the full
FRAME alist. A later registration for the same KIND replaces the earlier
one. Built-in kinds (session.welcome, ping/pong, ack, error) are handled
by the transport itself and cannot be overridden here."
  (puthash kind fn eabp--kind-handlers))

(defun eabp--dispatch (kind payload frame)
  "Route a frame by KIND: built-ins first, then registered handlers."
  (pcase kind
    ("auth.challenge" (eabp--on-auth-challenge payload))
    ("session.welcome" (eabp--on-welcome payload))
    ("ping" (eabp-send "pong" nil (alist-get 'id frame)))
    ("pong" nil)
    ;; Bare acks (e.g. to fire-and-forget surface.updates) are expected
    ;; noise; anything that wanted the ack used `eabp-request'.
    ("ack" nil)
    ;; Reply-only kind: consumed by the pending map above (SPEC §10).
    ("capability.result" nil)
    ("queue.drained"
     (message "EABP: replay complete (%s delivered, %s expired)"
              (or (alist-get 'delivered payload) 0)
              (or (alist-get 'expired payload) 0))
     (run-hook-with-args 'eabp-queue-drained-hook payload))
    ("error"
     (message "EABP error [%s]: %s"
              (alist-get 'code payload) (alist-get 'detail payload)))
    (_
     (if-let ((fn (gethash kind eabp--kind-handlers)))
         (condition-case err
             (funcall fn payload frame)
           (error (message "EABP: handler for %s failed: %s"
                           kind (error-message-string err))))
       (message "EABP: unhandled kind %s" kind)))))

(defvar eabp-queue-drained-hook nil
  "Hook run with the `queue.drained' payload after a replay completes.
Replayed events may have mutated org state; UI layers re-push here.")

(defun eabp--on-welcome (payload)
  "Record the negotiated session from a `session.welcome' PAYLOAD.
Refuses the session outright when the server's pairing proof is missing
or wrong — nothing is trusted from an unproven peer."
  (if (not (eabp--auth-verify-welcome payload))
      (progn
        (message (concat "EABP: server failed pairing proof — refusing the "
                         "session. Is something impersonating the companion, "
                         "or does the app predate pairing support?"))
        (when eabp--process (delete-process eabp--process)))
    (setq eabp--auth-server-nonce nil
          eabp--auth-client-nonce nil)
    (setq eabp--session payload)
    (let ((granted (alist-get 'granted payload))
          (queued  (or (alist-get 'queued_events payload) 0)))
      (message "EABP: handshake ok. granted=%s queued_events=%s" granted queued)
      (run-hook-with-args 'eabp-connected-hook payload)
      ;; Request replay AFTER the connected hooks: the revision snapshot has
      ;; been absorbed and initial surfaces pushed, so replayed events land
      ;; on a coherent state.
      (when (> queued 0)
        (eabp-send "queue.replay")))))

;; ─── Session queries & device capabilities (SPEC §10) ────────────────────────

(defun eabp-granted-p (capability)
  "Non-nil when the current session granted CAPABILITY (a string).
Layers gate their pushes on this: a companion that doesn't grant
`triggers' never receives a `triggers.set', per the negotiation rule."
  (and eabp--session
       (member capability (alist-get 'granted eabp--session))
       t))

(defun eabp-node-supported-p (node-type)
  "Non-nil when the connected companion renders NODE-TYPE (string or symbol).
Reads the welcome's `node_types' catalog (SPEC §3, §9).  A Tier 1 gates
a newer node on this and renders a fallback when it is unsupported:

  (if (eabp-node-supported-p \\='chart)
      (my/chart data)
    (my/chart-fallback-table data))

Returns non-nil PERMISSIVELY when the companion sent no catalog at all —
an older companion predating node negotiation must not be treated as
supporting nothing.  Support is positive knowledge only: a present
catalog that omits NODE-TYPE returns nil."
  (let ((catalog (alist-get 'node_types eabp--session))
        (name (if (symbolp node-type) (symbol-name node-type) node-type)))
    (cond ((null eabp--session) nil)   ; not connected
          ((null catalog) t)           ; companion predates negotiation
          (t (and (seq-contains-p catalog name) t)))))

(defun eabp-device-caps ()
  "Capability names invocable via `eabp-capability-invoke', or nil.
From the welcome's `device' report; empty until a session with the
`capabilities' grant is up."
  (alist-get 'caps (alist-get 'device eabp--session)))

(defun eabp-device-cap-p (cap)
  "Non-nil when the companion offers device capability CAP (a string)."
  (and (member cap (eabp-device-caps)) t))

(defun eabp-device-can-p (perm)
  "Non-nil when the companion reports device permission PERM as granted.
PERM is a string or symbol keying the welcome's `device.perms' map,
e.g. \"write_settings\".  The map is a welcome-time snapshot — the
companion re-checks at invoke time, so this is for degrading UI
gracefully, not for enforcement."
  (eq t (alist-get (if (symbolp perm) perm (intern perm))
                   (alist-get 'perms (alist-get 'device eabp--session)))))

(defun eabp-capability-invoke (cap &optional args callback)
  "Invoke device capability CAP (a string) with plain-data alist ARGS.
CALLBACK, when non-nil, receives (OK PAYLOAD): OK is non-nil iff the
invoke succeeded; PAYLOAD is the `capability.result' payload on
success, or the error payload (`code', `detail', and for
cap-permission possibly `perm' / `settings') on failure.  When
disconnected the frame is dropped like any other request."
  (eabp-request "capability.invoke"
                `((cap . ,cap)
                  (args . ,(or args (make-hash-table :test 'equal))))
                (lambda (payload)
                  (when callback
                    (funcall callback
                             (eq t (alist-get 'ok payload))
                             payload)))))

;; ─── Connection lifecycle ────────────────────────────────────────────────────

(defcustom eabp-reconnect t
  "When non-nil, automatically reconnect after losing the companion.
On Android the OS routinely pauses Emacs and kills its sockets; auto
reconnect (with backoff) is what makes the bridge feel always-on."
  :type 'boolean :group 'eabp)

(defcustom eabp-reconnect-initial-delay 5
  "Seconds to wait before the first reconnect attempt."
  :type 'integer :group 'eabp)

(defcustom eabp-reconnect-max-delay 60
  "Ceiling for the reconnect backoff, in seconds."
  :type 'integer :group 'eabp)

(defvar eabp--reconnect-timer nil)
(defvar eabp--reconnect-delay 5)
(defvar eabp--user-disconnected nil
  "Non-nil after an explicit `eabp-disconnect'; suppresses auto-reconnect.")

(defun eabp--cancel-reconnect ()
  (when (timerp eabp--reconnect-timer)
    (cancel-timer eabp--reconnect-timer))
  (setq eabp--reconnect-timer nil))

(defun eabp--schedule-reconnect ()
  "Arm the reconnect timer with exponential backoff."
  (when (and eabp-reconnect
             (not eabp--user-disconnected)
             (not eabp--reconnect-timer))
    (setq eabp--reconnect-timer
          (run-at-time eabp--reconnect-delay nil #'eabp--reconnect-attempt))
    (setq eabp--reconnect-delay
          (min (* 2 eabp--reconnect-delay) eabp-reconnect-max-delay))))

(defun eabp--reconnect-attempt ()
  (setq eabp--reconnect-timer nil)
  (unless (and eabp--process (process-live-p eabp--process))
    (condition-case nil
        (setq eabp--process (eabp--make-process))
      ;; Synchronous failure (no listener): try again later. Async failures
      ;; surface through the sentinel, which reschedules too.
      (error (eabp--schedule-reconnect)))))

(defun eabp--sentinel (_proc event)
  "React to connection EVENTs. Sends the hello once the socket opens."
  (cond
   ((string-prefix-p "open" event)
    (setq eabp--reconnect-delay eabp-reconnect-initial-delay)
    (eabp--cancel-reconnect)
    (eabp--send-hello))
   ((or (string-prefix-p "failed" event)
        (string-prefix-p "connection broken" event)
        (string-prefix-p "deleted" event)
        (string-prefix-p "finished" event))
    (message "EABP: disconnected (%s)" (string-trim event))
    (setq eabp--process nil
          eabp--buffer ""
          eabp--session nil
          eabp--auth-server-nonce nil
          eabp--auth-client-nonce nil)
    (clrhash eabp--pending)
    (eabp--schedule-reconnect))))

(defun eabp--send-hello ()
  "Open the session per the spec handshake."
  (eabp-send
   "session.hello"
   `((protocol . ,eabp-protocol-version)
     (client   . ,(format "emacs/%s eabp.el/%s" emacs-version eabp-api-version))
     (wants    . ,(vconcat eabp-wants)))))

(defun eabp--make-process ()
  "Create the network process. v0 = loopback TCP.
For 1.0, replace host/service/family with:
  :family \\='local :service \"/path/to/eabp.sock\"
and nothing else here changes."
  (make-network-process
   :name "eabp"
   :host eabp-host
   :service eabp-port
   :family 'ipv4
   :coding 'utf-8-unix
   :nowait t                 ; async connect; sentinel fires "open" on success
   :filter #'eabp--filter
   :sentinel #'eabp--sentinel))

;;;###autoload
(defun eabp-connect ()
  "Connect to the companion and run the handshake."
  (interactive)
  (setq eabp--user-disconnected nil
        eabp--reconnect-delay eabp-reconnect-initial-delay)
  (eabp--cancel-reconnect)
  (when (and eabp--process (process-live-p eabp--process))
    (delete-process eabp--process))
  (setq eabp--buffer "" eabp--session nil
        eabp--auth-server-nonce nil eabp--auth-client-nonce nil)
  (clrhash eabp--pending)
  (condition-case err
      (setq eabp--process (eabp--make-process))
    (error (message "EABP: connect failed: %s" (error-message-string err))
           (eabp--schedule-reconnect))))

(defun eabp-disconnect ()
  "Close the companion connection and stop auto-reconnecting."
  (interactive)
  (setq eabp--user-disconnected t)
  (eabp--cancel-reconnect)
  (when eabp--process (delete-process eabp--process))
  (setq eabp--process nil))

(defun eabp-connected-p ()
  "Non-nil once the socket is live AND the handshake has completed."
  (and eabp--process (process-live-p eabp--process) eabp--session t))

(defun eabp-ping ()
  "Debug helper: round-trip a ping/pong with the companion."
  (interactive)
  (eabp-request "ping" nil
                (lambda (_payload) (message "EABP: pong received"))))

;; Auto-connect: at init when loaded from init.el; when the library is
;; loaded (or reloaded) later, `after-init-hook' has already run and would
;; never fire — connect from a zero-delay timer instead, so the handshake
;; can't start until the whole file (or bundle) has finished loading.
(if after-init-time
    (run-at-time 0 nil #'eabp-connect)
  (add-hook 'after-init-hook #'eabp-connect))

(provide 'eabp)
;;; eabp.el ends here