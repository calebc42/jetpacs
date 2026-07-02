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
  "EABP protocol version this client speaks."
  :type 'integer :group 'eabp)

(defcustom eabp-wants
  '("surfaces.widget" "surfaces.notification" "surfaces.dialog"
    "capabilities" "triggers" "queue.replay")
  "Capability set Emacs requests during the handshake.
The companion grants the intersection with what it supports; anything it
doesn't recognise is simply not granted (forward-compat)."
  :type '(repeat string) :group 'eabp)

(defvar eabp--process nil
  "The live network process, or nil when disconnected.")

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
    ("session.welcome" (eabp--on-welcome payload))
    ("ping" (eabp-send "pong" nil (alist-get 'id frame)))
    ("pong" nil)
    ;; Bare acks (e.g. to fire-and-forget surface.updates) are expected
    ;; noise; anything that wanted the ack used `eabp-request'.
    ("ack" nil)
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
  "Record the negotiated session from a `session.welcome' PAYLOAD."
  (setq eabp--session payload)
  (let ((granted (alist-get 'granted payload))
        (queued  (or (alist-get 'queued_events payload) 0)))
    (message "EABP: handshake ok. granted=%s queued_events=%s" granted queued)
    (run-hook-with-args 'eabp-connected-hook payload)
    ;; Request replay AFTER the connected hooks: the revision snapshot has
    ;; been absorbed and initial surfaces pushed, so replayed events land
    ;; on a coherent state.
    (when (> queued 0)
      (eabp-send "queue.replay"))))

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
          eabp--session nil)
    (clrhash eabp--pending)
    (eabp--schedule-reconnect))))

(defun eabp--send-hello ()
  "Open the session per the spec handshake."
  (eabp-send
   "session.hello"
   `((protocol . ,eabp-protocol-version)
     (client   . ,(format "emacs/%s eabp.el/0.1" emacs-version))
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
  (setq eabp--buffer "" eabp--session nil)
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