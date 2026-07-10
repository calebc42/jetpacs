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

(defconst jetpacs-api-version "1.0.0"
  "Semver of the Tier 1 elisp API surface (constructors + seams).
Independent of `jetpacs-protocol-version' (the wire).  A third-party Tier 1
requires the core and checks this: minor bumps are additive and safe,
major bumps may remove a symbol one minor cycle after it is marked
obsolete.  The frozen public-symbol list lives in docs/API-STABILITY.md.")

(defcustom jetpacs-wants
  '("surfaces.widget" "surfaces.notification" "surfaces.dialog"
    "capabilities" "triggers" "queue.replay")
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
  "Write LINE plus a newline to the companion if connected."
  (if (and jetpacs--process (process-live-p jetpacs--process))
      (process-send-string jetpacs--process (concat line "\n"))
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

;;;###autoload
(defun jetpacs-connect ()
  "Connect to the companion and run the handshake."
  (interactive)
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
            month (or month (aref jetpacs--month-abbrevs (1- m)))
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
;;   `jetpacs-render-to-json'  — serialize + parse a spec headless (the wire
;;                            round-trip, so views are testable with no phone).
;;   `jetpacs-lint-on-push'    — when set, `jetpacs-surface-update' replaces each
;;                            invalid node in place with a visible error node,
;;                            so one bad subtree degrades instead of the push.
;;
;; The known-type list is the same vocabulary as `SDUI_NODE_TYPES'
;; (SduiRenderer.kt) and `test/widgets.golden'; the drift test
;; `jetpacs-lint-types-cover-golden' fails if a constructor emits a `t' not
;; listed here.

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
    on_day_tap on_month_change)
  "Node keys whose value is an embedded action object (SPEC §9).")

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
      (when (and wo (not (member wo '("queue" "drop" "wake"))))
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

(defun jetpacs-lint--walk (node path report)
  "Walk NODE at PATH (reversed key list), reporting problems via REPORT."
  (when (assq 't node)
    (let ((type (alist-get 't node)))
      (unless (and (stringp type) (member type jetpacs-lint-node-types))
        (funcall report path (format "unknown or invalid node type: %S" type)))))
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

;; Entry point: a card on the settings screen (satellite contract).
(with-eval-after-load 'jetpacs-settings
  (jetpacs-settings-add-link
   18 (lambda ()
        (jetpacs-card
         (list (jetpacs-row
                (jetpacs-icon "key")
                (jetpacs-box (list (jetpacs-column
                                 (jetpacs-text "Device permissions" 'label)
                                 (jetpacs-text "Grant special access for effectors and triggers"
                                            'caption)))
                          :weight 1)
                (jetpacs-icon "chevron_right")))
         :on-tap (jetpacs-action "device.perms" :when-offline "drop")))))

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

(defvar jetpacs--in-action-handler nil
  "Non-nil while an Jetpacs action handler is executing.
Bound by `jetpacs--on-action' in jetpacs-surfaces.el.  The minibuffer advice
checks this to decide whether to intercept.")

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
              t))))))))

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
;;   (jetpacs-shell-define-view "agenda"
;;     :builder #'my-agenda-view
;;     :tab '(:icon "event" :label "Agenda") :order 10)
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

(cl-defun jetpacs-shell-define-view (name &key builder tab when overlay (order 100))
  "Register (or replace) shell view NAME.
BUILDER is a function of one argument (snackbar text or nil) returning
the view's scaffold alist.  TAB, when non-nil, is a plist
\(:icon :label :badge) placing the view in the bottom bar; landing on a
tab view makes it the current tab.  :badge, when non-nil, is a nullary
function called on every push whose result overlays the tab icon — a
count (capped at 99+ on-device), \"\" for a bare dot, or nil for none;
errors and nil render no badge, so a badge can never break the push.
WHEN, when non-nil, is a predicate gating the view's inclusion in each
push.  OVERLAY, when non-nil, is a predicate: while it holds, this view
is the active one shown on a background push (a detail drill-in over
the current tab).  ORDER sorts views and bottom-bar items."
  (setq jetpacs-shell-views
        (sort (cons (cons name (list :builder builder :tab tab :when when
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

(defvar jetpacs-shell-drawer-header "Glasspane"
  "Text rendered at the top of the app drawer.")

(defvar jetpacs-shell-drawer-items nil
  "Ordered list of (ORDER . BUILDER) drawer entries.
BUILDER is a function of no arguments returning an `jetpacs-drawer-item'.")

(defun jetpacs-shell-add-drawer-item (order builder)
  "Add BUILDER (a nullary function returning a drawer item) at ORDER."
  (setq jetpacs-shell-drawer-items
        (sort (cons (cons order builder) jetpacs-shell-drawer-items)
              (lambda (a b) (< (car a) (car b)))))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-top-actions nil
  "Ordered list of (ORDER . BUILDER) default top-bar trailing actions.
BUILDER is a function of no arguments returning an icon-button node.")

(defun jetpacs-shell-add-top-action (order builder)
  "Add BUILDER (a nullary function returning an icon button) at ORDER."
  (setq jetpacs-shell-top-actions
        (sort (cons (cons order builder) jetpacs-shell-top-actions)
              (lambda (a b) (< (car a) (car b)))))
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

(defun jetpacs-shell-drawer ()
  "The navigation drawer built from `jetpacs-shell-drawer-items'.
A builder returning nil contributes nothing — conditional entries
\(e.g. the multi-app \"Apps\" item) just return nil when hidden."
  (jetpacs-drawer (delq nil (mapcar (lambda (e) (funcall (cdr e)))
                                 jetpacs-shell-drawer-items))
               :header jetpacs-shell-drawer-header))

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
EXTRA-ACTIONS are prepended (view-specific buttons before the globals)."
  (jetpacs-top-bar title
                :actions (append extra-actions
                                 (mapcar (lambda (e) (funcall (cdr e)))
                                         jetpacs-shell-top-actions))))

(cl-defun jetpacs-shell-tab-view (name body &key top-bar (fab nil fab-given) snackbar)
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
                   ;; Tab views support pull-to-refresh; navigation/detail
                   ;; views don't (a stray pull mustn't rebuild them).
                   :on-refresh (jetpacs-action "dashboard.refresh"
                                            :when-offline "drop"))))))

(cl-defun jetpacs-shell-nav-view (title body &key back-to nav-action actions
                                     fab snackbar bottom-bar floating-toolbar)
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
      (funcall (plist-get plist :builder) snackbar)
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
;;; BEGIN core/jetpacs-apps.el
;;; ==================================================================

;;; jetpacs-apps.el --- App identity over the shell: jetpacs-defapp + launcher home -*- lexical-binding: t; -*-

;; Groups shell views into named apps, AppSheet-style: a launcher home
;; grid of app cards, one app's tabs in the bottom bar at a time, and an
;; `app.open' action that switches between them.  Pure shell logic — no
;; wire changes beyond the `app.*' action namespace reserved in SPEC §5.
;;
;; The single-app contract: with zero or one `jetpacs-defapp' registered,
;; NOTHING changes — every view shows, no home screen, no drawer entry.
;; The launcher machinery appears with the second app (AppSheet boots
;; straight into a lone app the same way).
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

(cl-defun jetpacs-defapp (id &key label icon views (order 100))
  "Register (or replace) app ID grouping VIEWS (shell view names).
LABEL and ICON draw the app's launcher-home card; the first :tab view
in VIEWS is the app's landing tab.  ORDER sorts home cards; equal
orders keep registration order."
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
    (jetpacs--unclaim "action" name))
  (dolist (name (jetpacs--owned-names "view" id))
    (jetpacs-shell-remove-view name)
    (jetpacs--unclaim "view" name))
  (dolist (title (jetpacs--owned-names "settings" id))
    (when (fboundp 'jetpacs-settings-remove-section)
      (jetpacs-settings-remove-section title))
    (jetpacs--unclaim "settings" title))
  ;; Drop UI-state and its subscriptions keyed under the app's id prefix.
  (jetpacs-ui-state-clear (concat id "."))
  (jetpacs-on-state-change-clear (concat id "."))
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

(defun jetpacs-apps--landing-tab (id)
  "The view app ID lands on: its first :tab view, else its first view."
  (let ((views (plist-get (cdr (assoc id jetpacs-apps--registry)) :views)))
    (or (cl-find-if #'jetpacs-shell--tab-p views) (car views))))

;; ─── The shell filter (the whole gating mechanism) ───────────────────────────

(defun jetpacs-apps--view-visible-p (name)
  "Single-app: everything shows.  Multi-app: the current app's views
plus every unclaimed view (core tabs, the home grid itself)."
  (or (not (jetpacs-apps--multi-p))
      (let ((owner (jetpacs-apps--owner name)))
        (or (null owner)
            (equal owner (jetpacs-apps-current))))))

(setq jetpacs-shell-view-filter-function #'jetpacs-apps--view-visible-p)

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
  "Registry entry for SYM, or nil if SYM is not exposed."
  (cl-loop for (_title . entries) in jetpacs-settings-registry
           thereis (assq sym entries)))

;; ─── Persistence ─────────────────────────────────────────────────────────────

(defun jetpacs-settings-save-variable (symbol value)
  "Persist SYMBOL as VALUE through Customize, surfacing failures.
Returns non-nil on success.  Failures are reported through
`jetpacs-settings-notify-function' instead of being silently dropped;
notably, `customize-save-variable' quietly skips saving when there is
no file to save into (started with -q, or no init file), which would
otherwise look like a save and then vanish on restart."
  (require 'cus-edit)
  (condition-case err
      (if (custom-file t)
          (progn (customize-save-variable symbol value) t)
        (set-default symbol value)
        (funcall jetpacs-settings-notify-function
                 "Applied for this session only: no init file to save settings into")
        nil)
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
  "Widget column for registry ENTRY."
  (jetpacs-settings-item (car entry) :label (plist-get (cdr entry) :label)))

(defvar jetpacs-settings-links nil
  "Ordered list of (ORDER . BUILDER) navigation entries for the settings screen.
BUILDER is a nullary function returning a node (usually a tappable card
leading to another screen).  Apps register their satellite screens here
— the package browser, the customize browser — instead of each claiming
a drawer slot; `jetpacs-settings-sections' renders them under a trailing
\"Emacs\" section.")

(defun jetpacs-settings-add-link (order builder)
  "Add BUILDER (a nullary node builder) to the settings screen at ORDER."
  (setq jetpacs-settings-links
        (sort (cons (cons order builder) jetpacs-settings-links)
              (lambda (a b) (< (car a) (car b))))))

(defun jetpacs-settings-sections ()
  "Flat list of nodes rendering every registry section, then the links."
  (append
   (cl-loop for (title . entries) in jetpacs-settings-registry
            append (append (list (jetpacs-divider)
                                 (jetpacs-section-header title))
                           (mapcar #'jetpacs-settings--item entries)))
   (when jetpacs-settings-links
     (append (list (jetpacs-divider) (jetpacs-section-header "Emacs"))
             (mapcar (lambda (e) (funcall (cdr e))) jetpacs-settings-links)))))

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
      (jetpacs-settings-watch-toggle
       (car entry)
       (concat "setting/" (symbol-name (car entry)))
       (plist-get (cdr entry) :after-set)))))

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
        (results-card (jetpacs-files--grep-results-card)))
    (if buf
        (apply #'jetpacs-lazy-column
               (append (and results-card (list results-card))
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

(defvar jetpacs-files-view-region-function
  (lambda (name &rest _) (message "Jetpacs: no host to view %s" name))
  "Function of (BUFFER-NAME BEG END LABEL &optional POINT) showing a
buffer slice with POINT's line as the scroll target.  Set by
jetpacs-emacs-ui (its buffer view); kept as a seam so this module never
depends on the buffer-view host.")

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
  "The search-results view body: one tappable card per matching line."
  (let* ((g jetpacs-files--grep)
         (dir (plist-get g :dir))
         (hits (plist-get g :hits)))
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
              (mapcar (lambda (hit)
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
                           ;; Tap = read the hit in context (scrolled to the
                           ;; line); the pencil opens the editor.
                           :on-tap (jetpacs-action "files.grep-visit"
                                                :args `((file . ,file)
                                                        (line . ,line))
                                                :when-offline "drop"))))
                      hits))))))

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
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (file-readable-p file)
                 (jetpacs-files--within-root-p file))
        (setq jetpacs-files--file (expand-file-name file))
        (run-hook-with-args 'jetpacs-files-open-hook jetpacs-files--file)
        (jetpacs-shell-push nil :switch-to "edit")))))

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

(jetpacs-defaction "files.grep-visit"
  ;; Show a hit in context: the file's buffer in the buffer view,
  ;; narrowed around the line with the hit marked as the scroll target.
  ;; Region render dodges the buffer view's from-the-top line cap, so
  ;; hits deep in big files are reachable.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (line (alist-get 'line args)))
      (when (and (stringp file) (numberp line)
                 (jetpacs-files--within-root-p file)
                 (file-readable-p file))
        (condition-case err
            (let ((buf (find-file-noselect file)))
              (with-current-buffer buf
                (save-excursion
                  (goto-char (point-min))
                  (forward-line (1- (max 1 (truncate line))))
                  (let ((target (point))
                        (beg (save-excursion (forward-line -30) (point)))
                        (end (save-excursion (forward-line 170) (point))))
                    (funcall jetpacs-files-view-region-function
                             (buffer-name buf) beg end
                             (format "%s:%d" (file-name-nondirectory file)
                                     (truncate line))
                             target)))))
          (error (jetpacs-shell-notify (error-message-string err))))))))

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

;; jetpacs-files stays independent of this module (it loads first); its
;; grep hits navigate here through the seam.
(defvar jetpacs-files-view-region-function)
(with-eval-after-load 'jetpacs-files
  (setq jetpacs-files-view-region-function #'jetpacs-emacs-ui-view-region))

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
       :actions (list (jetpacs-icon-button
                       "toc"
                       (jetpacs-action "imenu.show"
                                    :args `((buffer . ,jetpacs-emacs-ui--viewing-buffer))
                                    :when-offline "drop")
                       :content-description "Sections (imenu)"))
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

(provide 'jetpacs-core)
;;; jetpacs-core.el ends here
