;;; jetpacs.el --- Emacs-Android Bridge Protocol client -*- lexical-binding: t; -*-

;; Author: calebch42 <calebch42@gmail.com>
;; Maintainer: calebch42 <calebch42@gmail.com>
;; Version: 2.0.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: comm, tools
;; URL: https://github.com/calebc42/jetpacs

;;; Commentary:

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
;; EBP 2 (SPEC-2): the message shape is JSON-RPC 2.0 — requests carry an
;; `id' and are answered exactly once (result XOR error), notifications
;; carry no `id' and are never answered — framed as
;; `Content-Length: N\r\n\r\n{json}' over a loopback TCP socket. The 1.0
;; transport target is a Unix domain socket (:family 'local) in a
;; shared-signature dir; only `jetpacs--make-process' changes for that.
;; Everything above the process stays the same.
;;
;; Payload representation is unchanged from v1 on purpose: params and
;; results are alists with `:null'/`:false' sentinels, so the ~40 consumer
;; modules above this file never see the envelope swap — the layer-stack
;; promise, kept.
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

(defcustom jetpacs-protocol-version 2
  "Jetpacs protocol version this client speaks.
This is the wire/vocabulary version — offered in `session.hello' and the
SPEC's version number.  v2 is the JSON-RPC 2.0 envelope (SPEC-2).  Bump
it only on a wire-breaking change."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-max-frame-bytes (* 4 1024 1024)
  "The frame cap (SPEC-2 §2.2), in body bytes.
Enforced on both halves: an outbound frame over the cap is refused
locally (dropped with a log — prefer a missing update to an oversized
frame); an inbound body over the cap is discarded byte-exactly without
ever being buffered or parsed, refused with `1400 frame-too-large' on
the log.error channel, and the connection lives."
  :type 'integer :group 'jetpacs)

(defconst jetpacs-api-version "2.0.0"
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
  "Accumulates partial inbound frame bytes (unibyte) between filter calls.")

(defvar jetpacs--skip-remaining 0
  "Bytes of an oversized inbound body still to discard.
Non-zero puts the filter in skip mode: the receiver-side half of the
frame cap (SPEC-2 §2.2) — the body is dropped as it streams, never
accumulated, never parsed.")

(defvar jetpacs--skip-total 0
  "Announced size of the oversized inbound frame being skipped.")

(defvar jetpacs--rpc-id 0
  "Monotonic per-connection source of request ids (SPEC-2 §2.3).
Reset on every connect; ids and their outstanding requests die with the
connection.")

(defvar jetpacs--pending (make-hash-table :test 'eql)
  "Map of outstanding request id -> callback called with (RESULT ERR).
Every entry is concluded exactly once: by the response, or by a local
`code' -1 error when the connection dies — never silence.")

(defvar jetpacs--session nil
  "Alist of negotiated session info after `session.welcome', or nil.")

(defvar jetpacs-connected-hook nil
  "Hook run with the welcome payload (alist) after a successful handshake.
Run through `jetpacs--run-session-hook', so a member that signals costs
only itself.")

;; ─── Session hooks ───────────────────────────────────────────────────────────

(defun jetpacs--run-session-hook (hook &rest args)
  "Run HOOK's members with ARGS, isolating each member's errors.
The session's own bring-up rides these hooks next to app-registered
members: the dashboard push, the trigger arm and the theme are all
`jetpacs-connected-hook' members.  `run-hook-with-args' would let the
first member that signals skip every later one, so one app's bug could
silently cost the phone its whole UI — the foundation must survive a
broken Tier 1, the same way a broken builder costs its own screen and a
broken predicate its own view.  A failing member is reported by name:
the error is the app's to fix, so it must not be swallowed."
  (run-hook-wrapped
   hook
   (lambda (fn)
     (condition-case err
         (apply fn args)
       (error (message "Jetpacs: %s member `%s' failed: %s"
                       hook fn (error-message-string err))))
     ;; Always nil: `run-hook-wrapped' stops at the first non-nil, and no
     ;; member's return value may end the session's bring-up.
     nil)))

;; ─── Envelope (JSON-RPC 2.0 over Content-Length frames, SPEC-2 §2) ──────────

(defun jetpacs--encode-frame (message)
  "Encode MESSAGE (a JSON-RPC alist) as one framed unibyte string.
Returns nil when the body exceeds `jetpacs-max-frame-bytes' — the
sender-side half of the frame cap: refuse locally, never send."
  (let ((body (encode-coding-string
               (json-serialize message :null-object :null :false-object :false)
               'utf-8 t)))
    (if (> (length body) jetpacs-max-frame-bytes)
        (progn
          (message "Jetpacs: refusing oversized outbound frame (%d bytes > %d); dropped"
                   (length body) jetpacs-max-frame-bytes)
          nil)
      (concat (encode-coding-string
               (format "Content-Length: %d\r\n\r\n" (length body)) 'ascii t)
              body))))

(defun jetpacs--raw-send (bytes)
  "Write framed BYTES to the companion if connected.
Never signals: the liveness check races the async connect and its
failure sentinel (the process can die between the check and the write),
and a send must degrade to a dropped frame — no caller is prepared for
an error out of a send.  Returns non-nil only when written."
  (if (and jetpacs--process (process-live-p jetpacs--process))
      (condition-case err
          (progn (process-send-string jetpacs--process bytes) t)
        (error (message "Jetpacs: send failed; dropping frame (%s)"
                        (error-message-string err))
               nil))
    (message "Jetpacs: not connected; dropping frame")
    nil))

(defvar jetpacs--frame-observer nil
  "When non-nil, a function called with (METHOD PARAMS BYTES) after each
notification is encoded — including frames dropped while disconnected,
since what it measures is the traffic the client *generates*.  BYTES is
the framed size on the wire (header + UTF-8 body).  Installed by
jetpacs-devtools; nil costs one test per send.")

(defun jetpacs-send (method &optional params)
  "Send a fire-and-forget JSON-RPC notification (SPEC-2 §2.1).
PARAMS is an alist (or nil for an empty object).  A notification
carries no id and is never answered.  Returns non-nil only when the
frame was actually written — refused-oversize and disconnected sends
return nil."
  (let ((bytes (jetpacs--encode-frame
                `((jsonrpc . "2.0")
                  (method . ,method)
                  (params . ,(or params (make-hash-table :test 'equal)))))))
    (when bytes
      (when jetpacs--frame-observer
        (funcall jetpacs--frame-observer method params (length bytes)))
      (jetpacs--raw-send bytes))))

(defun jetpacs-request (method params callback)
  "Send a JSON-RPC request; CALLBACK is called once with (RESULT ERR).
Exactly one outcome: on success ERR is nil and RESULT is the response's
result alist — which may itself be nil for an empty result, meaning
\"success, nothing to say\", never failure (SPEC-2 §2.1).  On failure
RESULT is nil and ERR is the error alist (`code', `message', optional
`data').  When the connection dies with the request outstanding,
CALLBACK receives a local ERR with `code' -1 — an answer, never silence
\(SPEC-2 §2.3).  When already disconnected the frame is dropped and
CALLBACK is never registered — otherwise every dropped request would
leak a pending-table entry.  Returns the request id, or nil when
dropped."
  (if (not (and jetpacs--process (process-live-p jetpacs--process)))
      (progn (message "Jetpacs: not connected; dropping request %s" method)
             nil)
    (let* ((id (cl-incf jetpacs--rpc-id))
           (bytes (jetpacs--encode-frame
                   `((jsonrpc . "2.0")
                     (id . ,id)
                     (method . ,method)
                     (params . ,(or params (make-hash-table :test 'equal)))))))
      (when bytes
        (puthash id callback jetpacs--pending)
        (jetpacs--raw-send bytes)
        id))))

(defun jetpacs--respond (id result)
  "Answer inbound request ID with RESULT (nil = empty result)."
  (let ((bytes (jetpacs--encode-frame
                `((jsonrpc . "2.0")
                  (id . ,id)
                  (result . ,(or result (make-hash-table :test 'equal)))))))
    (when bytes (jetpacs--raw-send bytes))))

(defun jetpacs--respond-error (id code msg &optional data)
  "Answer inbound request ID with a typed error (SPEC-2 §2.4).
ID may be :null when the offending frame's id was undetectable."
  (let ((bytes (jetpacs--encode-frame
                `((jsonrpc . "2.0")
                  (id . ,id)
                  (error . ((code . ,code)
                            (message . ,msg)
                            ,@(when data `((data . ,data)))))))))
    (when bytes (jetpacs--raw-send bytes))))

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

(defun jetpacs--on-hello-reply (result err)
  "Handle `session.hello's response — the challenge (SPEC-2 §3).
The challenge arriving as the hello's own response makes the handshake
ordering structural: there is no frame to receive out of order."
  (let ((snonce (and (null err) (alist-get 'nonce result))))
    (cond
     (err
      (message "Jetpacs: hello refused [%s]: %s"
               (alist-get 'code err) (alist-get 'message err)))
     ((not (stringp snonce))
      (message "Jetpacs: malformed auth challenge"))
     ((not (jetpacs--paired-p))
      (message (concat "Jetpacs: pairing required — open the companion app, tap "
                       "the (setq jetpacs-auth-token ...) line on its pairing "
                       "screen, add it to your init, and reconnect")))
     (t
      (setq jetpacs--auth-server-nonce snonce
            jetpacs--auth-client-nonce (jetpacs--auth-nonce))
      (jetpacs-request
       "auth.response"
       `((nonce . ,jetpacs--auth-client-nonce)
         (mac . ,(jetpacs--hmac-sha256-hex
                  jetpacs-auth-token
                  (format "ebp1:client:%s:%s"
                          snonce jetpacs--auth-client-nonce))))
       #'jetpacs--on-welcome-reply)))))

(defun jetpacs--on-welcome-reply (result err)
  "Handle `auth.response's response — the welcome, or a typed refusal."
  (if err
      (message "Jetpacs: pairing refused [%s]: %s"
               (alist-get 'code err) (alist-get 'message err))
    (jetpacs--on-welcome result)))

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
                   (format "ebp1:server:%s:%s"
                           jetpacs--auth-client-nonce
                           jetpacs--auth-server-nonce))))))

;; ─── Inbound framing & dispatch ──────────────────────────────────────────────

(defun jetpacs--filter (_proc chunk)
  "Accumulate CHUNK and handle every complete Content-Length frame.
CHUNK arrives unibyte (binary process coding); a body is decoded as
UTF-8 only once complete.  An oversized body is discarded byte-exactly
as it streams — never accumulated, never parsed — and refused with
`1400 frame-too-large' on log.error: the receiver-side half of the
frame cap (SPEC-2 §2.2)."
  (setq jetpacs--buffer (concat jetpacs--buffer chunk))
  (catch 'jetpacs--need-more
    (while t
      ;; Skip mode: swallow an oversized body without buffering it.
      (when (> jetpacs--skip-remaining 0)
        (let ((n (min jetpacs--skip-remaining (length jetpacs--buffer))))
          (setq jetpacs--buffer (substring jetpacs--buffer n)
                jetpacs--skip-remaining (- jetpacs--skip-remaining n)))
        (when (> jetpacs--skip-remaining 0)
          (throw 'jetpacs--need-more nil))
        (message "Jetpacs: skipped oversized inbound frame (%d bytes > %d)"
                 jetpacs--skip-total jetpacs-max-frame-bytes)
        (jetpacs-send "log.error"
                      `((code . 1400)
                        (message . "frame skipped unread")
                        (data . ((kind . "frame-too-large")
                                 (bytes . ,jetpacs--skip-total)
                                 (max . ,jetpacs-max-frame-bytes))))))
      (let ((header-end (string-search "\r\n\r\n" jetpacs--buffer)))
        (unless header-end (throw 'jetpacs--need-more nil))
        (let* ((header (substring jetpacs--buffer 0 header-end))
               (case-fold-search t)
               (len (and (string-match
                          "^content-length:[ \t]*\\([0-9]+\\)" header)
                         (string-to-number (match-string 1 header))))
               (body-start (+ header-end 4)))
          (cond
           ;; A header section without Content-Length is a framing desync:
           ;; there is no way to find the next frame. Fail closed.
           ((null len)
            (message "Jetpacs: frame header without Content-Length; disconnecting")
            (when jetpacs--process (delete-process jetpacs--process))
            (throw 'jetpacs--need-more nil))
           ((> len jetpacs-max-frame-bytes)
            (setq jetpacs--skip-total len
                  jetpacs--skip-remaining len
                  jetpacs--buffer (substring jetpacs--buffer body-start)))
           ((< (- (length jetpacs--buffer) body-start) len)
            (throw 'jetpacs--need-more nil))
           (t
            (let ((body (substring jetpacs--buffer body-start
                                   (+ body-start len))))
              (setq jetpacs--buffer
                    (substring jetpacs--buffer (+ body-start len)))
              (jetpacs--handle-frame
               (decode-coding-string body 'utf-8))))))))))

(defun jetpacs--handle-frame (text)
  "Parse one JSON-RPC message TEXT and route it (SPEC-2 §2.3)."
  (condition-case err
      (let ((msg (json-parse-string
                  text
                  :object-type 'alist :array-type 'list
                  :null-object :null :false-object :false)))
        (let ((id (alist-get 'id msg))
              (method (alist-get 'method msg))
              (jsonrpc (alist-get 'jsonrpc msg)))
          (cond
           ;; Batch arrays are prohibited (§2.2); a non-object or
           ;; version-less frame is not JSON-RPC. Log and drop.
           ((not (equal jsonrpc "2.0"))
            (message "Jetpacs: dropping non-JSON-RPC frame"))
           ;; An error answered at an unidentifiable id (id null).
           ((and (eq id :null) (alist-get 'error msg))
            (let ((e (alist-get 'error msg)))
              (message "Jetpacs: peer refused an unidentifiable frame [%s]: %s"
                       (alist-get 'code e) (alist-get 'message e))))
           ;; A response: conclude the outstanding request.
           ((and id (not method))
            (let ((cb (gethash id jetpacs--pending)))
              (if (not cb)
                  (message "Jetpacs: response for unknown request id %s" id)
                (remhash id jetpacs--pending)
                (funcall cb
                         (let ((r (alist-get 'result msg)))
                           (if (eq r :null) nil r))
                         (alist-get 'error msg)))))
           ;; An inbound request: answered exactly once, result XOR error.
           ((and id method)
            (jetpacs--dispatch-request id method (alist-get 'params msg)))
           ;; A notification: never answered.
           (method
            (jetpacs--dispatch-notification method (alist-get 'params msg)))
           (t (message "Jetpacs: unclassifiable frame dropped")))))
    (error (message "Jetpacs: bad frame: %s" (error-message-string err)))))

(defconst jetpacs--client-sent-methods
  '("session.hello" "auth.response" "capability.invoke" "queue.replay"
    "triggers.set" "reminders.set" "surface.update" "surface.remove"
    "dialog.show" "dialog.dismiss" "pie_menu.show" "pie_menu.dismiss"
    "toast.show" "theme.set" "completions.show" "diagnostics.show"
    "eldoc.show" "fontify.show" "edit.resync" "edit.apply")
  "Methods only Emacs sends.
Receiving one is a §2.3 direction violation: a protocol error for a
request, a logged drop for a notification.")

(defvar jetpacs--kind-handlers (make-hash-table :test 'equal)
  "Map of method (string) -> notification handler called with (PARAMS MSG).
Extension point for the layers above the transport (surfaces, queue,
capabilities): they register here instead of patching the dispatcher.")

(defvar jetpacs--request-handlers (make-hash-table :test 'equal)
  "Map of method (string) -> inbound-request handler called with (PARAMS).
The handler returns the result alist (nil = empty result) or signals to
produce a -32603.  Empty in the first cut — the seam exists for the §8
promotions — but the refusal duties below are live regardless: stock
fail-open dispatch is exactly the bug SPEC-2 §2.3 exists to kill.")

(defun jetpacs-register-handler (method fn)
  "Register FN as the handler for inbound notifications of METHOD.
FN is called with two arguments, the notification's PARAMS alist and
the full message alist.  A later registration for the same METHOD
replaces the earlier one.  Envelope-level traffic (responses, log.error,
rpc.cancel) is handled by the transport itself and cannot be overridden
here."
  (puthash method fn jetpacs--kind-handlers))

(defun jetpacs--dispatch-request (id method params)
  "Answer inbound request ID/METHOD exactly once (SPEC-2 §2.3)."
  (let ((handler (gethash method jetpacs--request-handlers)))
    (cond
     ((member method jetpacs--client-sent-methods)
      (jetpacs--respond-error id -32600
                              (format "'%s' travels client → companion" method)
                              '((kind . "wrong-direction"))))
     ((null handler)
      ;; Unknown method → -32601, hand-rolled and explicit: the connection
      ;; lives (forward compat), but the request is never left dangling
      ;; and never answered with fail-open success.
      (jetpacs--respond-error id -32601
                              (format "unknown method '%s'" method)
                              '((kind . "method-not-found"))))
     (t
      (condition-case err
          (jetpacs--respond id (funcall handler params))
        (error (jetpacs--respond-error id -32603 (error-message-string err)
                                       '((kind . "internal")))))))))

(defun jetpacs--dispatch-notification (method params)
  "Route an inbound notification: built-ins, then registered handlers."
  (pcase method
    ;; The unsolicited-fault channel (§2.3): an error object minus the id.
    ("log.error"
     (message "Jetpacs companion fault [%s]: %s"
              (alist-get 'code params) (alist-get 'message params)))
    ;; Nothing cancellable Emacs-side in the first cut.
    ("rpc.cancel" nil)
    (_
     (cond
      ((member method jetpacs--client-sent-methods)
       (message "Jetpacs: dropped wrong-direction method %s" method))
      ((gethash method jetpacs--kind-handlers)
       (condition-case err
           (funcall (gethash method jetpacs--kind-handlers)
                    params `((method . ,method) (params . ,params)))
         (error (message "Jetpacs: handler for %s failed: %s"
                         method (error-message-string err)))))
      ;; Unknown notification: logged and dropped, connection lives —
      ;; the forward-compat rule, notification half.
      (t (message "Jetpacs: unhandled method %s" method))))))

(defvar jetpacs-queue-drained-hook nil
  "Hook run with the replay's drain summary after a replay completes.
Replayed events may have mutated org state; UI layers re-push here.")

(defun jetpacs--on-queue-drained (result err)
  "Conclude a `queue.replay' request with its drain summary RESULT.
v1's `queue.drained' frame dissolved into this response."
  (if err
      (message "Jetpacs: replay failed [%s]: %s"
               (alist-get 'code err) (alist-get 'message err))
    (message "Jetpacs: replay complete (%s delivered, %s expired)"
             (or (alist-get 'delivered result) 0)
             (or (alist-get 'expired result) 0))
    (jetpacs--run-session-hook 'jetpacs-queue-drained-hook result)))

(defun jetpacs--on-welcome (payload)
  "Record the negotiated session from the welcome PAYLOAD (§3).
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
      (jetpacs--run-session-hook 'jetpacs-connected-hook payload)
      ;; Request replay AFTER the connected hooks: the revision snapshot has
      ;; been absorbed and initial surfaces pushed, so replayed events land
      ;; on a coherent state.
      (when (> queued 0)
        (jetpacs-request "queue.replay" nil #'jetpacs--on-queue-drained)))))

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
invoke succeeded.  On success PAYLOAD is the result alist (a `result'
key when the capability returned data).  On failure PAYLOAD is shaped
like v1's error payload — `code' holds the readable kind string from
the error's `data.kind', `detail' the message, and for cap-permission
`perm' / `settings' ride alongside — so Tier 1 callers are untouched by
the envelope swap.  When disconnected the frame is dropped like any
other request."
  (jetpacs-request "capability.invoke"
                `((cap . ,cap)
                  (args . ,(or args (make-hash-table :test 'equal))))
                (lambda (result err)
                  (when callback
                    (if (null err)
                        (funcall callback t result)
                      (let* ((data (alist-get 'data err))
                             (perm (alist-get 'perm data))
                             (settings (alist-get 'settings data)))
                        (funcall callback nil
                                 (append
                                  `((code . ,(or (alist-get 'kind data)
                                                 (alist-get 'code err)))
                                    (detail . ,(alist-get 'message err)))
                                  (when perm `((perm . ,perm)))
                                  (when settings `((settings . ,settings)))))))))))

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

(defun jetpacs--fail-pending (why)
  "Conclude every outstanding request with a local error — never silence.
The -1 code is local by construction (SPEC-2 §2.4 reserves it off the
wire); callbacks see `((code . -1) …)' exactly once, per §2.3's
requests-die-with-the-connection rule."
  (let ((pending jetpacs--pending))
    (setq jetpacs--pending (make-hash-table :test 'eql))
    (maphash (lambda (_id cb)
               (condition-case err
                   (funcall cb nil `((code . -1)
                                     (message . ,why)
                                     (data . ((kind . "connection-dead")))))
                 (error (message "Jetpacs: pending callback failed: %s"
                                 (error-message-string err)))))
             pending)))

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
          jetpacs--skip-remaining 0
          jetpacs--session nil
          jetpacs--auth-server-nonce nil
          jetpacs--auth-client-nonce nil)
    (jetpacs--fail-pending "connection closed")
    (jetpacs--schedule-reconnect))))

(defun jetpacs--send-hello ()
  "Open the session: the first of §3's two request/response pairs.
The challenge is the hello's response; see `jetpacs--on-hello-reply'."
  (jetpacs-request
   "session.hello"
   `((protocol . ,jetpacs-protocol-version)
     (client   . ,(format "emacs/%s jetpacs.el/%s" emacs-version jetpacs-api-version))
     (features . ,(vconcat (mapcar #'symbol-name jetpacs-build-features)))
     (wants    . ,(vconcat jetpacs-wants)))
   #'jetpacs--on-hello-reply))

(defun jetpacs--make-process ()
  "Create the network process. v0 transport = loopback TCP.
Binary coding: the Content-Length framing is byte-accurate, so the
filter must see raw bytes and decode UTF-8 itself per frame.  For 1.0,
replace host/service/family with:
  :family \\='local :service \"/path/to/jetpacs.sock\"
and nothing else here changes."
  (make-network-process
   :name "jetpacs"
   :host jetpacs-host
   :service jetpacs-port
   :family 'ipv4
   :coding 'binary
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
  (jetpacs--run-session-hook 'jetpacs-before-connect-hook)
  (setq jetpacs--user-disconnected nil
        jetpacs--reconnect-delay jetpacs-reconnect-initial-delay)
  (jetpacs--cancel-reconnect)
  (when (and jetpacs--process (process-live-p jetpacs--process))
    (delete-process jetpacs--process))
  (setq jetpacs--buffer "" jetpacs--skip-remaining 0 jetpacs--rpc-id 0
        jetpacs--session nil
        jetpacs--auth-server-nonce nil jetpacs--auth-client-nonce nil)
  (jetpacs--fail-pending "reconnecting")
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

;; v1's ping/pong dropped without replacement (SPEC-2 §4): no written
;; semantics existed. Liveness, if ever needed, is a self-correlating
;; request; `jetpacs-connected-p' answers the question people asked of it.

;; Auto-connect: at init when loaded from init.el; when the library is
;; loaded (or reloaded) later, `after-init-hook' has already run and would
;; never fire — connect from a zero-delay timer instead, so the handshake
;; can't start until the whole file (or bundle) has finished loading.
(if after-init-time
    (run-at-time 0 nil #'jetpacs-connect)
  (add-hook 'after-init-hook #'jetpacs-connect))

(provide 'jetpacs)
;;; jetpacs.el ends here