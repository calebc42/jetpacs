;;; eabp-core.el --- EABP core client, single-file bundle -*- lexical-binding: t; -*-
;;
;; GENERATED FILE -- do not edit by hand.
;; Produced by emacs/build-bundle.el from the emacs/ sources.
;; Concatenated in dependency order; each part keeps its own `provide',
;; so the inter-file `require' forms resolve within this file.
;;
;;; Code:

;;; ==================================================================
;;; BEGIN core/eabp.el
;;; ==================================================================

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
;;; ==================================================================
;;; BEGIN core/eabp-widgets.el
;;; ==================================================================

;;; eabp-widgets.el --- EABP SDUI widget constructors -*- lexical-binding: t; -*-

;; Provides all UI-tree constructors for EABP surfaces.
;; These functions build the alists that are serialized to JSON.
;;
;; Every constructor funnels through `eabp--node': type + (KEY VALUE)
;; pairs, where nil values are dropped.  That one rule replaces the old
;; per-constructor `(when x (push …))' boilerplate and keeps the wire
;; format in a single, greppable place per widget.

;;; Code:

(require 'cl-lib)

(defun eabp--node (type &rest kvs)
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

(defun eabp-text (text &optional style weight color selectable max-lines padding)
  "A text node. STYLE is title/headline/body/caption/label.
WEIGHT is the layout weight. COLOR is a hex string."
  (eabp--node "text"
              'text text
              'style (and style (format "%s" style))
              'weight weight
              'color color
              'selectable (and selectable t)
              'max_lines max-lines
              'padding padding))

(cl-defun eabp-markup (text &key syntax style padding)
  "A read-only TEXT node with optional client-side highlighting.
SYNTAX (\"org\", \"elisp\") turns on the highlighter; STYLE is the same set
as `eabp-text'. Use this for displaying code/org content; for plain labels
use `eabp-text'."
  (eabp--node "text"
              'text text
              'syntax (and syntax (format "%s" syntax))
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun eabp-rich-text (spans &key style padding)
  "A rich-text node rendering SPANS (a list from `eabp-span').
Use this for org content Emacs has already parsed into styled runs —
emphasis, links, and #tags render natively rather than as highlighted
monospace. STYLE is the base text style (title/body/caption/label)."
  (eabp--node "rich_text"
              'spans (vconcat spans)
              'style (and style (format "%s" style))
              'padding padding))

(cl-defun eabp-span (text &key bold italic underline strike code tag baseline color bg on-tap mono)
  "A styled text run for `eabp-rich-text'.
BOLD/ITALIC/UNDERLINE/STRIKE/CODE toggle emphasis; TAG themes it like a
#hashtag; BASELINE is \"super\" or \"sub\"; COLOR is a hex foreground
override and BG a hex background (diff shading, hl-line, region, isearch);
ON-TAP makes it a clickable link.  MONO renders the run in a fixed-width
font without the code-styling background — used by the generic buffer
renderer to preserve column alignment (dired, magit, tables, ascii)."
  (eabp--node nil
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

(defun eabp-row (&rest children)
  "A horizontal row of CHILDREN nodes."
  (eabp--node "row" 'children (vconcat children)))

(defun eabp-flow-row (&rest children)
  "A horizontal row of CHILDREN that wraps onto new lines when full.
The right container for chip/tag rows, which overflow a plain `eabp-row'."
  (eabp--node "flow_row" 'children (vconcat children)))

(defun eabp-column (&rest children)
  "A vertical column of CHILDREN nodes."
  (eabp--node "column" 'children (vconcat children)))

(cl-defun eabp-box (children &key alignment padding weight on-tap)
  "A Box wrapping CHILDREN."
  (eabp--node "box"
              'children (vconcat children)
              'alignment alignment
              'padding padding
              'weight weight
              'on_tap on-tap))

(cl-defun eabp-surface (children &key color shape elevation padding fill)
  "A Surface wrapping CHILDREN.
COLOR is a hex string or a theme token (\"primary\", \"surface_container\",
\"primary_container\", …) that adapts to the device's light/dark theme.
SHAPE is \"rounded\", \"rounded_small\", or \"circle\".  FILL stretches the
surface to full width (e.g. zebra rows in a list)."
  (eabp--node "surface"
              'children (vconcat children)
              'color color
              'shape shape
              'elevation elevation
              'padding padding
              'fill (and fill t)))

(defun eabp-lazy-column (&rest children)
  "A scrollable column of CHILDREN."
  (eabp--node "lazy_column" 'children (vconcat children)))

(defun eabp-scroll-here (node)
  "Mark NODE as the scroll target of its enclosing `eabp-lazy-column'.
The client scrolls the list to this child on first show and whenever
the child's index changes (e.g. new transcript output shifting a REPL's
input row down); a re-push that leaves the index unchanged never
disturbs the user's scroll position.  One target per lazy column — the
first flagged child wins."
  (append node '((scroll_here . t))))

(cl-defun eabp-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (eabp--node "spacer" 'height height 'width width 'weight weight))

(defun eabp-divider ()
  "A horizontal divider."
  (eabp--node "divider"))

(cl-defun eabp-card (children &key on-tap padding weight on-swipe)
  "An elevated card wrapping CHILDREN."
  (eabp--node "card"
              'children (vconcat children)
              'on_tap on-tap
              'on_swipe on-swipe
              'padding padding
              'weight weight))

(cl-defun eabp-collapsible (id header children &key collapsed on-long-tap)
  "A fold/expand section. ID keys the (client-side) fold state.
HEADER is the always-visible node shown next to the chevron; CHILDREN
\(a list of nodes) are revealed when expanded. COLLAPSED non-nil starts
folded. Folding happens entirely on-device — no action round-trip.
ON-LONG-TAP, when non-nil, is an action dispatched on long-press of
the header (used by the org reader to open the heading detail view)."
  (eabp--node "collapsible"
              'id id
              'header header
              'children (vconcat children)
              'collapsed (and collapsed t)
              'on_long_tap on-long-tap))

(cl-defun eabp-reorderable-list (items &key on-reorder)
  "A drag-reorderable list of ITEMS.
Each item is an alist with at least (label . STRING) and (level . INT).
ON-REORDER is an action template dispatched with additional keys
\(from_pos . N) (after_pos . M) (new_level . L) when the user drops
a dragged item.  Dragging vertically reorders; horizontally promotes
or demotes."
  (eabp--node "reorderable_list"
              'items (vconcat items)
              'on_reorder on-reorder))

(cl-defun eabp-table (rows &key aligns on-add-row on-add-col padding)
  "A grid of cells with org-table semantics.
ROWS is a list from `eabp-table-row' and `eabp-table-rule'.  Columns
size to their widest cell and the grid pans horizontally on-device
when it overflows the screen — the whole table ships once.
ALIGNS is a list of per-column alignments (\"start\", \"center\",
\"end\"); columns beyond its length default to start.
ON-ADD-ROW / ON-ADD-COL, when non-nil, make the client render slim
\"+\" append affordances (a strip below the last row / a gutter after
the last column) that dispatch those actions.  The actions carry no
client-added args — embed the table's location when building them."
  (eabp--node "table"
              'rows (vconcat rows)
              'aligns (and aligns (vconcat aligns))
              'on_add_row on-add-row
              'on_add_col on-add-col
              'padding padding))

(cl-defun eabp-table-row (cells &key header)
  "A table row of CELLS (from `eabp-table-cell').
HEADER marks the row as part of the header group: the client renders
it emphasized, with a heavier rule under the group."
  (eabp--node nil
              'cells (vconcat cells)
              'header (and header t)))

(defun eabp-table-rule ()
  "A horizontal rule row (an org hline) — a divider line inside the grid."
  (eabp--node nil 'rule t))

(cl-defun eabp-table-cell (spans &key on-tap on-long-tap)
  "A table cell rendering SPANS (a list from `eabp-span').
ON-TAP / ON-LONG-TAP dispatch as-is — embed the cell's file/pos in the
action args when building it (the client adds nothing)."
  (eabp--node nil
              'spans (vconcat spans)
              'on_tap on-tap
              'on_long_tap on-long-tap))

;; ─── Interactive ─────────────────────────────────────────────────────────────

(cl-defun eabp-action (action &key args (when-offline "queue") dedupe)
  "An action descriptor."
  (eabp--node nil
              'action action
              'when_offline when-offline
              'args args
              'dedupe dedupe))

(defun eabp-clipboard-action (text)
  "A companion-local action that copies TEXT to the device clipboard.
Handled entirely on-device (like the `view.switch' builtin) — no
round-trip to Emacs, works offline."
  (eabp--node nil 'builtin "clipboard.copy" 'text text))

(cl-defun eabp-button (label action &key icon variant weight padding)
  "A button. VARIANT is filled/outlined/text/tonal."
  (eabp--node "button"
              'label label
              'on_tap action
              'icon icon
              'variant variant
              'weight weight
              'padding padding))

(cl-defun eabp-date-button (label on-pick &key value)
  "A button that opens a date picker. ON-PICK is dispatched with the chosen
date injected into its args as `value' (\"YYYY-MM-DD\"). VALUE seeds the
picker (\"YYYY-MM-DD\")."
  (eabp--node "date_button" 'label label 'on_pick on-pick 'value value))

(cl-defun eabp-time-button (label on-pick &key value)
  "A button that opens a time picker. ON-PICK is dispatched with the chosen
time injected into its args as `value' (\"HH:MM\"). VALUE seeds the picker."
  (eabp--node "time_button" 'label label 'on_pick on-pick 'value value))

(cl-defun eabp-image (url &key content-description padding)
  "An image loaded from URL (an http(s) URL or a readable file:// path)."
  (eabp--node "image"
              'url url
              'content_description content-description
              'padding padding))

(cl-defun eabp-icon-button (icon action &key content-description padding)
  "An icon button."
  (eabp--node "icon_button"
              'icon icon
              'on_tap action
              'content_description content-description
              'padding padding))

(cl-defun eabp-menu (items &key icon padding)
  "An overflow menu: an icon that opens a dropdown of ITEMS.
ITEMS is a list from `eabp-menu-item'. ICON defaults to a vertical
ellipsis. Folding/opening is handled entirely on-device."
  (eabp--node "menu" 'items (vconcat items) 'icon icon 'padding padding))

(cl-defun eabp-menu-item (label action &key icon)
  "An item in an overflow `eabp-menu': LABEL dispatches ACTION when tapped."
  (eabp--node nil 'label label 'on_tap action 'icon icon))

(cl-defun eabp-text-input (id &key value hint label on-submit single-line
                              multi-line min-lines max-lines monospace syntax
                              password padding)
  "A text input field.
ID identifies the field. ON-SUBMIT is an action dispatched when done.
The client defaults to single-line; pass MULTI-LINE non-nil for a box that
accepts newlines (Enter inserts a newline rather than submitting, so such a
field should be paired with a submit button). MIN-LINES/MAX-LINES size the box
and MONOSPACE renders it in a fixed-width font (handy for code).
SYNTAX (e.g. \"elisp\", \"org\") turns on client-side highlighting.
PASSWORD masks the entry (dots) and requests a password keyboard — used by
the `read-passwd' bridge; such a field's value must not be logged or
retained beyond the read."
  (eabp--node "text_input"
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
              'padding padding))

(cl-defun eabp-enum-list (id options &key value multi-select allow-add on-change padding)
  "An enum list for selecting from OPTIONS.
ID identifies the field. VALUE is a list/vector of currently selected strings.
MULTI-SELECT allows choosing multiple options. ALLOW-ADD shows an input for
adding new options. ON-CHANGE is an action dispatched when the selection
changes."
  (eabp--node "enum_list"
              'id id
              'options (vconcat options)
              ;; A bare string VALUE would vconcat into a vector of char
              ;; codes — wrap it as the one-element selection it means.
              'value (and value (vconcat (if (stringp value) (list value) value)))
              'multi_select (and multi-select t)
              'allow_add (and allow-add t)
              'on_change on-change
              'padding padding))

(cl-defun eabp-checkbox (id &key checked label on-change padding)
  "A checkbox."
  (eabp--node "checkbox"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

(cl-defun eabp-switch (id &key checked label on-change padding)
  "A toggle switch."
  (eabp--node "switch"
              'id id
              'checked (and checked t)
              'label label
              'on_change on-change
              'padding padding))

;; ─── Display ─────────────────────────────────────────────────────────────────

(cl-defun eabp-icon (name &key size color padding)
  "An icon display."
  (eabp--node "icon" 'name name 'size size 'color color 'padding padding))

(cl-defun eabp-chip (label &key on-tap selected icon padding)
  "A filter chip."
  (eabp--node "chip"
              'label label
              'on_tap on-tap
              'selected (and selected t)
              'icon icon
              'padding padding))

(cl-defun eabp-progress (&key variant value padding)
  "A progress indicator. VARIANT is circular/linear. VALUE is 0.0-1.0."
  (eabp--node "progress" 'variant variant 'value value 'padding padding))

(cl-defun eabp-assist-chip (label &key on-tap icon padding)
  "An assist chip (e.g. a #tag). LABEL is shown; ON-TAP fires on click.
Unlike `eabp-chip' (a selectable filter chip) this is a flat, tappable
suggestion chip — pair it with `eabp-flow-row' for wrapping tag rows."
  (eabp--node "assist_chip"
              'label label
              'on_tap on-tap
              'icon icon
              'padding padding))

(cl-defun eabp-section-header (title &key trailing padding)
  "A styled section label. TRAILING is an optional node shown at the end
\(e.g. a count or an `eabp-icon-button')."
  (eabp--node "section_header" 'title title 'trailing trailing 'padding padding))

(cl-defun eabp-empty-state (&key icon title caption on-tap action-label padding)
  "A centered empty-state placeholder.
ICON names a glyph (default \"inbox\"); TITLE and CAPTION describe the
emptiness. When ON-TAP and ACTION-LABEL are both given, an outlined
button is shown beneath the text."
  (eabp--node "empty_state"
              'icon icon
              'title title
              'caption caption
              'on_tap on-tap
              'action_label action-label
              'padding padding))

(defconst eabp--month-abbrevs
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
   "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
  "Short month labels used by `eabp-date-stamp'.")

(cl-defun eabp-date-stamp (&key date day month month-index year time padding)
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
            month (or month (aref eabp--month-abbrevs (1- m)))
            day (or day (number-to-string d)))))
  (eabp--node "date_stamp"
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

(cl-defun eabp-widget-item (text &key todo done meta icon on-tap in-app
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
  (eabp--node nil
              'text text
              'todo todo
              'done (and done t)
              'meta meta
              'icon icon
              'on_tap on-tap
              'tap_in_app (and in-app t)
              'button button
              'on_button on-button))

(defun eabp-widget-divider (label)
  "A bold section divider row (\"Overdue\", \"Today\") in a widget list."
  (eabp--node nil 'divider label))

(cl-defun eabp-tile (label &key subtitle icon state on-tap in-app)
  "A Quick Settings tile spec for a `tile:customN' slot surface.
LABEL and SUBTITLE are the tile texts (the subtitle shows on Android
10+). ICON names a glyph: \"todo_open\", \"todo_done\", \"add\",
\"refresh\", \"scheduled\", \"deadline\", \"event\", or \"folder\".
STATE is \"active\", \"inactive\" (the default), or \"unavailable\".
ON-TAP is dispatched when the tile is tapped; IN-APP opens the
companion app and routes the action through it, otherwise the tap
fires silently from the shade (no unlock required — compose
accordingly). An un-pushed slot shows as a grayed-out tile."
  (eabp--node nil
              'label label
              'subtitle subtitle
              'icon icon
              'state (and state (format "%s" state))
              'on_tap on-tap
              'tap_in_app (and in-app t)))

;; ─── Scaffold ────────────────────────────────────────────────────────────────

(cl-defun eabp-editor (id value &key on-save read-only syntax line-numbers
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
as a suggestion strip (see eabp-complete.el).
CHROMELESS hides the filename/undo/save header and sizes the field
compactly instead of full-height — an inline field with the full bridge
\(completion, squiggles, doc line), e.g. the eval REPL input.
PUBLISH-STATE emits debounced `state.changed' with the text under ID,
so button-driven forms can read it back from `eabp-ui-state'.
TOOLBAR names a keyboard-adjacent formatting toolbar the client should
attach (\"org\" today); nil for none.  Server-driven so the renderer
stays app-agnostic: the app opts an editor into the affordance."
  (eabp--node "editor"
              'id id
              'value value
              'on_save on-save
              'read_only (and read-only t)
              'syntax syntax
              'line_numbers line-numbers
              'complete (and complete t)
              'chromeless (and chromeless t)
              'publish_state (and publish-state t)
              'toolbar toolbar))

(cl-defun eabp-scaffold (&key top-bar fab body bottom-bar floating-toolbar snackbar drawer on-refresh)
  "The standard app frame."
  (eabp--node "scaffold"
              'top_bar top-bar
              'fab fab
              'body body
              'bottom_bar bottom-bar
              'floating_toolbar floating-toolbar
              'snackbar snackbar
              'drawer drawer
              'on_refresh on-refresh))

(cl-defun eabp-drawer (items &key header)
  "A navigation drawer spec. ITEMS is a list from `eabp-drawer-item'."
  (eabp--node nil 'header header 'items (vconcat items)))

(cl-defun eabp-drawer-item (icon label action &key selected)
  "An item in the navigation drawer."
  (eabp--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)))

(cl-defun eabp-top-bar (title &key nav-icon nav-action actions)
  "A TopAppBar spec."
  (eabp--node nil
              'title title
              'nav_icon nav-icon
              'nav_action nav-action
              'actions (and actions (vconcat actions))))

(cl-defun eabp-fab (icon &key label on-tap extended)
  "A FloatingActionButton spec."
  (eabp--node nil
              'icon icon
              'label label
              'on_tap on-tap
              'extended (and extended t)))

(defun eabp-bottom-bar (items)
  "A BottomBar spec. ITEMS is a list from `eabp-nav-item'."
  (eabp--node nil 'items (vconcat items)))

(cl-defun eabp-nav-item (icon label action &key selected)
  "An item in the bottom bar."
  (eabp--node nil
              'icon icon
              'label label
              'on_tap action
              'selected (and selected t)))

(provide 'eabp-widgets)
;;; eabp-widgets.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-surfaces.el
;;; ==================================================================

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

(defvar eabp--last-action-time 0
  "`float-time' of the most recent dispatched action.
Lets async continuations of a phone-initiated flow (e.g. git calling back
into Emacs for a commit message after `magit-commit' already returned)
distinguish themselves from desktop-initiated activity.")

(defun eabp-defaction (name fn)
  "Register FN as the handler for action NAME."
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
;;; ==================================================================
;;; BEGIN core/eabp-minibuffer.el
;;; ==================================================================

;;; eabp-minibuffer.el --- Bridge minibuffer prompts to the companion -*- lexical-binding: t; -*-

;; When an EABP action handler calls a prompting function (y-or-n-p,
;; read-from-minibuffer, completing-read, …) the user is on their phone,
;; not at a keyboard.  This module intercepts those calls, sends the prompt
;; to the companion as a dialog, and synchronously waits for the reply —
;; exactly as the original function would block for keyboard input, just
;; over the bridge instead.
;;
;; The advice is active ONLY while `eabp--in-action-handler' is non-nil,
;; so normal Emacs usage at the keyboard is completely unaffected.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'cl-lib)

;; ─── Configuration ───────────────────────────────────────────────────────────

(defcustom eabp-prompt-timeout 60
  "Seconds to wait for the companion to answer a forwarded prompt.
After this the prompt is cancelled (as if the user dismissed the dialog)."
  :type 'integer :group 'eabp)

;; ─── Internal state ──────────────────────────────────────────────────────────

(defvar eabp--in-action-handler nil
  "Non-nil while an EABP action handler is executing.
Bound by `eabp--on-action' in eabp-surfaces.el.  The minibuffer advice
checks this to decide whether to intercept.")

(defvar eabp--prompt-reply nil
  "Alist of prompt-id → reply value, filled by the `prompt.reply' action.")

(defvar eabp--prompt-cancelled nil
  "Alist of prompt-id → t, set when the companion dismisses the dialog.")

(defvar eabp-minibuffer--context-buffers nil
  "List of buffer names displayed during the current action handler.")

(defun eabp-minibuffer--record-context-buffer (buffer-or-name)
  "Record BUFFER-OR-NAME as a context buffer if in an action handler."
  (when eabp--in-action-handler
    (let ((buf (get-buffer buffer-or-name)))
      (when (and buf (string-prefix-p "*" (buffer-name buf)))
        (cl-pushnew (buffer-name buf) eabp-minibuffer--context-buffers :test #'equal)))))

(defun eabp-minibuffer--display-buffer-advice (orig-fn buffer-or-name &rest args)
  (eabp-minibuffer--record-context-buffer buffer-or-name)
  (apply orig-fn buffer-or-name args))

(advice-add 'display-buffer :around #'eabp-minibuffer--display-buffer-advice)

(defun eabp-minibuffer--temp-buffer-show-hook ()
  (eabp-minibuffer--record-context-buffer (current-buffer)))

(add-hook 'temp-buffer-show-hook #'eabp-minibuffer--temp-buffer-show-hook)

(defun eabp-minibuffer--context-cards ()
  "Return a list of `eabp-card` widgets containing the text of recently displayed context buffers."
  (delq nil
        (mapcar (lambda (bname)
                  (let ((buf (get-buffer bname)))
                    (when buf
                      (eabp-card
                       (list (eabp-column
                              (eabp-text bname 'caption)
                              (eabp-text
                               (with-current-buffer buf
                                 (buffer-substring-no-properties (point-min) (min (point-max) (+ (point-min) 4000))))
                               'body nil nil t)))))))
                (reverse eabp-minibuffer--context-buffers))))

;; ─── Reply / dismiss handlers ────────────────────────────────────────────────

(defun eabp--prompt-reply-handler (args _payload)
  "Handle `prompt.reply' actions from the companion."
  (let ((id (alist-get 'prompt_id args))
        (value (alist-get 'value args)))
    (when id
      (push (cons id value) eabp--prompt-reply))))

(defun eabp--prompt-dismiss-handler (args _payload)
  "Handle `prompt.dismiss' actions — user dismissed without answering."
  (let ((id (alist-get 'prompt_id args)))
    (when id
      (push (cons id t) eabp--prompt-cancelled))))

;; Register via the action dispatch table.  This file is loaded after
;; eabp-surfaces has provided itself, so `eabp-defaction' is available.
(eabp-defaction "prompt.reply"  #'eabp--prompt-reply-handler)
(eabp-defaction "prompt.dismiss" #'eabp--prompt-dismiss-handler)

;; ─── Core: send prompt, wait for reply ───────────────────────────────────────

(defvar eabp--prompt-counter 0)

(defun eabp--prompt-id ()
  "Generate a unique prompt id."
  (format "prompt-%d-%04x" (cl-incf eabp--prompt-counter) (random #x10000)))

(defun eabp--send-prompt-dialog (_prompt-id body)
  "Send BODY as a dialog, prepending any recorded context-buffer cards.
A BODY that is itself a `lazy_column' (the completing-read picker) gets
the cards merged into it: nesting one vertical scroll container inside
another crashes the companion's Compose renderer."
  (let ((context-cards (eabp-minibuffer--context-cards)))
    (cond
     ((null context-cards)
      (eabp-send-dialog body))
     ((equal (alist-get 't body) "lazy_column")
      (eabp-send-dialog
       `((t . "lazy_column")
         (children . ,(vconcat context-cards
                               (append (alist-get 'children body) nil))))))
     (t
      (eabp-send-dialog
       (apply #'eabp-lazy-column (append context-cards (list body))))))))

(defun eabp--wait-for-prompt (prompt-id)
  "Block (pumping the event loop) until PROMPT-ID gets a reply or times out.
Returns the reply value, or the symbol `cancelled' if dismissed/timed out."
  (let ((deadline (+ (float-time) eabp-prompt-timeout)))
    (while (and (not (assoc prompt-id eabp--prompt-reply))
                (not (assoc prompt-id eabp--prompt-cancelled))
                (< (float-time) deadline)
                ;; Stay alive only as long as the connection is up.
                (eabp-connected-p))
      (accept-process-output nil 0.1))
    (cond
     ((assoc prompt-id eabp--prompt-reply)
      (let ((value (alist-get prompt-id eabp--prompt-reply nil nil #'equal)))
        ;; Clean up.
        (setq eabp--prompt-reply
              (assoc-delete-all prompt-id eabp--prompt-reply))
        value))
     (t
      ;; Dismissed, timed out, or disconnected.
      (setq eabp--prompt-cancelled
            (assoc-delete-all prompt-id eabp--prompt-cancelled))
      'cancelled))))

(defun eabp--cleanup-prompt ()
  "Dismiss any leftover dialog after an action handler finishes."
  (eabp-dismiss-dialog)
  (setq eabp-minibuffer--context-buffers nil))

;; ─── Advice: y-or-n-p ────────────────────────────────────────────────────────

(defun eabp--y-or-n-p-advice (orig-fn prompt &rest args)
  "Around advice for `y-or-n-p'.  Intercept during action handlers."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let* ((id (eabp--prompt-id))
           (dialog-body
            (eabp-column
             (eabp-text (string-trim-right prompt "[ ?]+") 'title)
             (eabp-row
              (eabp-button "No"
                           (eabp-action "prompt.reply"
                                        :args `((prompt_id . ,id) (value . :false)))
                           :variant "outlined")
              (eabp-spacer :width 8)
              (eabp-button "Yes"
                           (eabp-action "prompt.reply"
                                        :args `((prompt_id . ,id) (value . t))))))))
      (eabp--send-prompt-dialog id dialog-body)
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (not (or (eq reply 'cancelled)
                 (eq reply :false)
                 (eq reply nil)))))))

(advice-add 'y-or-n-p :around #'eabp--y-or-n-p-advice)

;; ─── Advice: yes-or-no-p ────────────────────────────────────────────────────

(defun eabp--yes-or-no-p-advice (orig-fn prompt &rest args)
  "Around advice for `yes-or-no-p'.  Same as y-or-n-p for the companion."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    ;; Reuse the y-or-n-p bridge — the distinction doesn't matter on a phone.
    (eabp--y-or-n-p-advice #'ignore prompt)))

(advice-add 'yes-or-no-p :around #'eabp--yes-or-no-p-advice)

;; ─── Advice: map-y-or-n-p ────────────────────────────────────────────────────
;;
;; `map-y-or-n-p' drives `save-some-buffers' and other batch confirmations.
;; It reads raw events via `read-event', which never arrive over the bridge —
;; so from the phone it HANGS forever (no dialog is ever shown, so the prompt
;; timeout can't even fire).  This is the freeze `magit-commit' hits: it runs
;; save-some-buffers before opening the message buffer.  We reimplement the
;; loop as one bridged dialog per object instead of feeding it events.

(defun eabp--map-y-or-n-p-advice (orig-fn prompter actor list &rest args)
  "Around advice for `map-y-or-n-p': one bridged dialog per object.
Returns the number of objects ACTOR was called on, matching the original.
LIST may be a list of objects or a generator function; PROMPTER may be a
format string or a function returning a string (ask), t (act silently)
or nil (skip silently)."
  (if (not eabp--in-action-handler)
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
            (let* ((id (eabp--prompt-id))
                   (title (if (stringp p) (string-trim-right p "[ ?]+")
                            (format "%s" p)))
                   (body (eabp-column
                          (eabp-text title 'title)
                          (eabp-flow-row
                           (eabp-button
                            "Yes"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "y"))))
                           (eabp-button
                            "No"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "n")))
                            :variant "outlined")
                           (eabp-button
                            "Yes to all"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "all")))
                            :variant "outlined")
                           (eabp-button
                            "Quit"
                            (eabp-action "prompt.reply"
                                         :args `((prompt_id . ,id) (value . "quit")))
                            :variant "text")))))
              (eabp--send-prompt-dialog id body)
              ;; `_' catches "quit", the `cancelled' symbol (dismiss/timeout),
              ;; and anything unexpected — all stop the loop.
              (pcase (unwind-protect (eabp--wait-for-prompt id)
                       (eabp--cleanup-prompt))
                ("y" (funcall actor obj) (setq count (1+ count)))
                ("n" nil)
                ("all" (setq all t) (funcall actor obj) (setq count (1+ count)))
                (_ (setq done t))))))))
      count)))

(advice-add 'map-y-or-n-p :around #'eabp--map-y-or-n-p-advice)

;; ─── Advice: read-from-minibuffer ────────────────────────────────────────────

(defun eabp--read-from-minibuffer-advice (orig-fn prompt &rest args)
  "Around advice for `read-from-minibuffer'.  Text-input dialog."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let* ((id (eabp--prompt-id))
           (initial (nth 0 args))  ;; initial-contents
           (input-id (format "prompt-input-%s" id))
           (current-value (if (stringp initial) initial ""))
           (dialog-body
            (eabp-column
             (eabp-text (string-trim-right prompt "[ :]+") 'title)
             (eabp-text-input input-id
                              :label "Input"
                              :value (if (stringp initial) initial nil)
                              :on-submit (eabp-action "prompt.reply"
                                                      :args `((prompt_id . ,id))))
             (eabp-row
              (eabp-button "Cancel"
                           (eabp-action "prompt.dismiss"
                                        :args `((prompt_id . ,id)))
                           :variant "text")
              (eabp-spacer :width 8)
              (eabp-button "OK"
                           (eabp-action "prompt.reply"
                                        :args `((prompt_id . ,id))))))))
      (eabp-on-state-change input-id (lambda (val) (setq current-value val)))
      (eabp--send-prompt-dialog id dialog-body)
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (eabp--cleanup-prompt))))
        (if (eq reply 'cancelled)
            (keyboard-quit)
          (or reply current-value ""))))))

(advice-add 'read-from-minibuffer :around #'eabp--read-from-minibuffer-advice)

;; ─── Advice: read-string ─────────────────────────────────────────────────────
;;
;; `read-string' delegates to `read-from-minibuffer' in standard Emacs, so
;; the advice above already covers it.  We add an explicit advice anyway so
;; the interception is guaranteed even if a package replaces `read-string'.

(defun eabp--read-string-advice (orig-fn prompt &rest args)
  "Around advice for `read-string'."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((initial (nth 0 args)))
      (eabp--read-from-minibuffer-advice #'ignore prompt initial))))

(advice-add 'read-string :around #'eabp--read-string-advice)

;; ─── Advice: read-passwd ─────────────────────────────────────────────────────
;;
;; `read-passwd' (TRAMP, GPG, auth-source) must NOT flow through the plaintext
;; `read-string' bridge: it needs a masked field, and the secret must not
;; linger in UI state.  We also intercept before the raw-event advice below,
;; since stock `read-passwd' reads keys directly.

(defun eabp--read-passwd-once (prompt)
  "Prompt for one masked secret over the bridge.
Returns the entered string, or the symbol `cancelled' on dismiss/timeout."
  (let* ((id (eabp--prompt-id))
         (input-id (format "prompt-pw-%s" id))
         (current ""))
    (eabp-on-state-change input-id (lambda (v) (setq current (or v ""))))
    ;; NOT `eabp--send-prompt-dialog': that prepends context-buffer cards, and
    ;; a passphrase prompt must never sit beside buffer contents.
    (eabp-send-dialog
     (eabp-column
      (eabp-text (string-trim-right prompt "[ :]+") 'title)
      (eabp-text-input input-id
                       :label "Password"
                       :single-line t
                       :password t
                       :on-submit (eabp-action "prompt.reply"
                                               :args `((prompt_id . ,id))))
      (eabp-row
       (eabp-button "Cancel"
                    (eabp-action "prompt.dismiss" :args `((prompt_id . ,id)))
                    :variant "text")
       (eabp-spacer :width 8)
       (eabp-button "OK"
                    (eabp-action "prompt.reply" :args `((prompt_id . ,id)))))))
    (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                   ;; Scrub every trace of the secret from handler state.
                   (remhash input-id eabp--state-handlers)
                   (remhash input-id eabp--ui-state)
                   (eabp--cleanup-prompt))))
      (if (eq reply 'cancelled) 'cancelled (or reply current "")))))

(defun eabp--read-passwd-advice (orig-fn prompt &rest args)
  "Around advice for `read-passwd': masked entry, secret never retained.
Honours CONFIRM (ARGS' first element) by prompting twice and comparing,
retrying up to three times before giving up with `keyboard-quit'."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((confirm (nth 0 args))
          (tries 0))
      (catch 'done
        (while t
          (let ((first (eabp--read-passwd-once prompt)))
            (when (eq first 'cancelled) (keyboard-quit))
            (if (not confirm)
                (throw 'done first)
              (let ((again (eabp--read-passwd-once
                            (if (stringp confirm) confirm "Confirm password: "))))
                (when (eq again 'cancelled) (keyboard-quit))
                (cond
                 ((equal first again) (throw 'done first))
                 ((>= (setq tries (1+ tries)) 3)
                  (eabp-send "toast.show" '((text . "Passwords didn't match")))
                  (keyboard-quit))
                 (t (eabp-send "toast.show"
                               '((text . "Passwords didn't match — try again")))))))))))))

(advice-add 'read-passwd :around #'eabp--read-passwd-advice)

;; ─── Advice: completing-read ─────────────────────────────────────────────────

(defun eabp-minibuffer--filter (candidates query)
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

(defun eabp-minibuffer--annotator (collection predicate)
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

(defun eabp-minibuffer--clean (s)
  "Trim S to a plain display string, or \"\" when nil/blank.
For suffixes, which are shown as a separate caption."
  (if (stringp s) (string-trim (substring-no-properties s)) ""))

(defun eabp-minibuffer--strip (s)
  "S without text properties, or \"\" when not a string.
For affixation PREFIXES, which are concatenated onto the candidate — their
separator whitespace is intentional and must survive (unlike suffixes)."
  (if (stringp s) (substring-no-properties s) ""))

(defun eabp-minibuffer--group-fn (collection predicate)
  "COLLECTION's `group-function' from completion metadata, or nil."
  (let ((md (ignore-errors (completion-metadata "" collection predicate))))
    (and md (completion-metadata-get md 'group-function))))

(defun eabp-minibuffer--decorations (collection predicate shown)
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
                   (cons (eabp-minibuffer--strip (nth 1 tr))
                         (eabp-minibuffer--clean (nth 2 tr)))
                   table)))
      table)
     (ann
      (dolist (c shown)
        (let ((s (ignore-errors (funcall ann c))))
          (when (stringp s)
            (puthash c (cons "" (eabp-minibuffer--clean s)) table))))
      table)
     (t nil))))

(defun eabp-minibuffer--picker-cards (shown id value-prefix decor group-fn)
  "Candidate card nodes for SHOWN, with affixation and group-header nodes.
ID is the prompt id; VALUE-PREFIX is prepended to the reply value.  DECOR is
a hash CAND→(PREFIX . SUFFIX) or nil; GROUP-FN, when non-nil, groups the
candidates with `eabp-section-header' dividers whenever its title changes."
  (let (nodes (last-group nil))
    (dolist (c shown)
      (when group-fn
        (let ((g (ignore-errors (funcall group-fn c nil))))
          (when (and (stringp g) (not (equal g last-group)))
            (setq last-group g)
            (push (eabp-section-header g) nodes))))
      (let* ((pair (and decor (gethash c decor)))
             (pre (and pair (car pair)))
             (suf (and pair (cdr pair)))
             (label (if (and pre (not (string-empty-p pre))) (concat pre c) c)))
        (push (eabp-card
               (list (if (and suf (not (string-empty-p suf)))
                         (eabp-row
                          (eabp-box (list (eabp-text label 'body)) :weight 1)
                          (eabp-text suf 'caption))
                       (eabp-text label 'body)))
               :on-tap (eabp-action "prompt.reply"
                                    :args `((prompt_id . ,id)
                                            (value . ,(concat value-prefix c)))))
              nodes)))
    (nreverse nodes)))

(defun eabp--completing-read-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read': a live-filtering picker over the bridge.
As the user types in the filter field, the candidate list re-filters and
re-renders (vertico-style). Tapping a candidate, or pressing Done, replies.
Function collections (files, buffers, dynamic tables) re-complete against
the query each keystroke, so typing a path navigates directories."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (initial-arg (nth 2 args))   ; INITIAL-INPUT: STRING or (STRING . POS)
           ;; `read-file-name' passes its DIR here, so honouring it is what
           ;; makes a bridged file prompt open in the right directory.
           (initial (cond ((stringp initial-arg) initial-arg)
                          ((consp initial-arg) (car initial-arg))
                          (t "")))
           (def (nth 4 args))   ; (predicate require-match initial hist DEF …)
           (id (eabp--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           (dynamic (functionp collection))
           ;; Static collections snapshot once and get token filtering;
           ;; `all-completions' handles list/obarray/hash honouring PREDICATE.
           (candidates (unless dynamic
                         (ignore-errors
                           (sort (all-completions "" collection predicate)
                                 #'string<))))
           (group-fn (eabp-minibuffer--group-fn collection predicate))
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
                (cons "" (eabp-minibuffer--filter candidates query)))))
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
                     (decor (eabp-minibuffer--decorations
                             collection predicate shown))
                     (cards (eabp-minibuffer--picker-cards
                             shown id prefix decor group-fn)))
                ;; A lazy (scrollable) column: long candidate lists scroll
                ;; instead of pushing everything below off-screen.  Cancel
                ;; sits in the header row so it is reachable regardless of
                ;; list length or scroll position.
                (apply #'eabp-lazy-column
                       (append
                        (list
                         (eabp-row
                          (eabp-box (list (eabp-text title 'title)) :weight 1)
                          (eabp-button "Cancel"
                                       (eabp-action "prompt.dismiss"
                                                    :args `((prompt_id . ,id)))
                                       :variant "text"))
                         ;; :value only on the SEED (first) render, and only
                         ;; when there is initial input — after that the field
                         ;; is uncontrolled so re-renders never stomp the
                         ;; user's text/cursor (see the on-state-change below).
                         (eabp-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter…"
                                          :single-line t
                                          :value (and seed
                                                      (not (string-empty-p query))
                                                      query)
                                          :on-submit (eabp-action
                                                      "prompt.reply"
                                                      :args `((prompt_id . ,id))))
                         (eabp-text (if (> total max-display)
                                        (format "%d matches · top %d shown" total max-display)
                                      (format "%d matches" total))
                                    'caption))
                        cards))))))
      ;; Re-render on every keystroke (runs during `eabp--wait-for-prompt's
      ;; event pump). Cleared after the wait so it can't leak.
      (eabp-on-state-change input-id
                            (lambda (val)
                              (eabp--send-prompt-dialog id (funcall render val))))
      ;; Seed the first render with INITIAL-INPUT: the field carries it as its
      ;; value, so an immediate submit returns it (like RET on initial input at
      ;; the keyboard) and the list is pre-filtered.  Clearing the field then
      ;; submitting is an explicit empty → DEF, so the empty branch is left
      ;; untouched.
      (eabp--send-prompt-dialog id (funcall render initial t))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (eabp--cleanup-prompt))))
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
           (t (or (car (eabp-minibuffer--filter candidates reply)) reply))))
         ;; Empty submit falls back to the caller's DEF, like RET at the
         ;; keyboard would.
         (t (or (and def (if (consp def) (car def) def)) "")))))))

(advice-add 'completing-read :around #'eabp--completing-read-advice)

;; ─── Advice: completing-read-multiple ────────────────────────────────────────
;;
;; CRM reads via `read-from-minibuffer' with a special keymap, so without
;; this it degrades to a bare comma-separated text input.  Bridge it as a
;; multi-select picker: tapping candidates toggles them, the filter's
;; submit adds free text (org tags), Done replies with the selection.

(defvar eabp--prompt-toggle-callbacks nil
  "Alist of prompt-id → callback for `prompt.toggle' actions.")

(eabp-defaction "prompt.toggle"
  (lambda (args _)
    (let* ((pid (alist-get 'prompt_id args))
           (fn (alist-get pid eabp--prompt-toggle-callbacks nil nil #'equal)))
      (when fn (funcall fn (alist-get 'value args))))))

(defun eabp--completing-read-multiple-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read-multiple': a multi-select picker."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (id (eabp--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           (candidates (ignore-errors
                         (sort (all-completions "" collection predicate)
                               #'string<)))
           (annotate (eabp-minibuffer--annotator collection predicate))
           (selected nil)
           (query "")
           (max-display 50)
           (render
            (lambda ()
              (let* ((matches (eabp-minibuffer--filter candidates query))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches)))
                (apply #'eabp-lazy-column
                       (append
                        (list
                         (eabp-row
                          (eabp-box (list (eabp-text title 'title)) :weight 1)
                          (eabp-button "Cancel"
                                       (eabp-action "prompt.dismiss"
                                                    :args `((prompt_id . ,id)))
                                       :variant "text")
                          (eabp-button (format "Done (%d)" (length selected))
                                       (eabp-action "prompt.reply"
                                                    :args `((prompt_id . ,id)
                                                            (value . ,(vconcat (reverse selected)))))))
                         (eabp-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter, submit to add"
                                          :single-line t
                                          :on-submit (eabp-action
                                                      "prompt.toggle"
                                                      :args `((prompt_id . ,id))))
                         (when selected
                           (apply #'eabp-flow-row
                                  (mapcar (lambda (s)
                                            (eabp-chip s :selected t
                                                       :on-tap (eabp-action
                                                                "prompt.toggle"
                                                                :args `((prompt_id . ,id)
                                                                        (value . ,s)))))
                                          (reverse selected))))
                         (eabp-text (format "%d matches" total) 'caption))
                        (mapcar
                         (lambda (c)
                           (let ((a (and annotate (funcall annotate c))))
                             (eabp-card
                              (list (if a
                                        (eabp-row
                                         (eabp-box (list (eabp-text c 'body))
                                                   :weight 1)
                                         (eabp-text a 'caption))
                                      (eabp-text c 'body)))
                              :on-tap (eabp-action "prompt.toggle"
                                                   :args `((prompt_id . ,id)
                                                           (value . ,c))))))
                         shown)))))))
      (setf (alist-get id eabp--prompt-toggle-callbacks nil nil #'equal)
            (lambda (val)
              (when (and (stringp val) (not (string-empty-p val)))
                (setq selected (if (member val selected)
                                   (delete val selected)
                                 (cons val selected)))
                (eabp--send-prompt-dialog id (funcall render)))))
      (eabp-on-state-change input-id
                            (lambda (val)
                              (setq query (or val ""))
                              (eabp--send-prompt-dialog id (funcall render))))
      (eabp--send-prompt-dialog id (funcall render))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (setq eabp--prompt-toggle-callbacks
                           (assoc-delete-all id eabp--prompt-toggle-callbacks))
                     (eabp--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         (t (cl-remove-if-not #'stringp (append reply nil))))))))

(advice-add 'completing-read-multiple :around #'eabp--completing-read-multiple-advice)

;; ─── Advice: read-char & read-char-exclusive ─────────────────────────────────

(defun eabp--read-char-advice (orig-fn prompt &rest args)
  "Around advice for `read-char' and `read-char-exclusive'.
Uses a text input dialog and returns the first character."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((reply (eabp--read-from-minibuffer-advice #'ignore prompt)))
      (if (and (stringp reply) (> (length reply) 0))
          (aref reply 0)
        (keyboard-quit)))))

(advice-add 'read-char :around #'eabp--read-char-advice)
(advice-add 'read-char-exclusive :around #'eabp--read-char-advice)

;; ─── Advice: read-char-choice ────────────────────────────────────────────────

(defun eabp--char-buttons-dialog (id prompt buttons)
  "Show a dialog of PROMPT text plus BUTTONS, with a Cancel row."
  (eabp--send-prompt-dialog
   id
   (eabp-column
    (eabp-text prompt 'body)
    (apply #'eabp-flow-row buttons)
    (eabp-row
     (eabp-spacer :weight 1)
     (eabp-button "Cancel"
                  (eabp-action "prompt.dismiss" :args `((prompt_id . ,id)))
                  :variant "text")))))

(defun eabp--read-char-choice-advice (orig-fn prompt chars &rest args)
  "Around advice for `read-char-choice': each valid char is a button.
The prompt text usually explains the choices ([y]es [n]o …), so it is
shown in full above the buttons; only valid chars can come back."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt chars args)
    (let* ((id (eabp--prompt-id))
           (chars (append chars nil)))
      (eabp--char-buttons-dialog
       id prompt
       (mapcar (lambda (ch)
                 (eabp-button (char-to-string ch)
                              (eabp-action "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(char-to-string ch))))
                              :variant "outlined"))
               chars))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (if (and (stringp reply) (> (length reply) 0)
                 (memq (aref reply 0) chars))
            (aref reply 0)
          (keyboard-quit))))))

(advice-add 'read-char-choice :around #'eabp--read-char-choice-advice)

;; ─── Advice: read-multiple-choice ────────────────────────────────────────────

(defun eabp--read-multiple-choice-advice (orig-fn prompt choices &rest args)
  "Around advice for `read-multiple-choice'.
CHOICES are (CHAR NAME [DESC]); the names become buttons, and the full
chosen entry is returned as the original would."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt choices args)
    (let ((id (eabp--prompt-id)))
      (eabp--char-buttons-dialog
       id prompt
       (mapcar (lambda (choice)
                 (eabp-button (capitalize (cadr choice))
                              (eabp-action "prompt.reply"
                                           :args `((prompt_id . ,id)
                                                   (value . ,(char-to-string (car choice)))))
                              :variant "outlined"))
               choices))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (or (and (stringp reply) (> (length reply) 0)
                 (assq (aref reply 0) choices))
            (keyboard-quit))))))

(advice-add 'read-multiple-choice :around #'eabp--read-multiple-choice-advice)

;; ─── Advice: read-char-from-minibuffer ───────────────────────────────────────
;;
;; Modern core reads single-char answers here (it echoes in the minibuffer
;; and, unlike `read-char', accepts an allowlist).  Without this the fallback
;; would be a free-text box; with a CHARS allowlist it becomes buttons.

(defun eabp--read-char-from-minibuffer-advice (orig-fn prompt &rest args)
  "Around advice for `read-char-from-minibuffer'.
With a CHARS allowlist (ARGS' first element) render each as a button via
the char-choice bridge; otherwise a single-char text prompt."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt args)
    (let ((chars (nth 0 args)))
      (if chars
          (eabp--read-char-choice-advice #'ignore prompt chars)
        (eabp--read-char-advice #'ignore prompt)))))

(when (fboundp 'read-char-from-minibuffer)
  (advice-add 'read-char-from-minibuffer :around
              #'eabp--read-char-from-minibuffer-advice))

;; ─── Advice: read-answer ─────────────────────────────────────────────────────
;;
;; `read-answer' backs the long-form "y, n, or q" prompts an increasing share
;; of core uses.  ANSWERS is (LONG-ANSWER CHAR HELP …); render a button per
;; entry and return the chosen LONG-ANSWER string (the function's contract).

(defun eabp--read-answer-advice (orig-fn question answers &rest _)
  "Around advice for `read-answer': one button per answer."
  (if (not eabp--in-action-handler)
      (funcall orig-fn question answers)
    (let ((id (eabp--prompt-id)))
      (eabp--char-buttons-dialog
       id question
       (mapcar (lambda (a)
                 (let ((long (car a)))
                   (eabp-button (capitalize long)
                                (eabp-action "prompt.reply"
                                             :args `((prompt_id . ,id)
                                                     (value . ,long)))
                                :variant "outlined")))
               answers))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (eabp--cleanup-prompt))))
        (if (and (stringp reply) (assoc reply answers))
            reply
          (keyboard-quit))))))

(when (fboundp 'read-answer)
  (advice-add 'read-answer :around #'eabp--read-answer-advice))

;; ─── Advice: raw event readers ───────────────────────────────────────────────
;;
;; `read-event', `read-key', `read-key-sequence' and its -vector sibling read
;; keyboard events directly, bypassing every prompt bridge above.  From the
;; phone they HANG.  `query-replace' (via `perform-replace') and any command
;; that reads a single keystroke land here.  We can't render an arbitrary key
;; event as a dialog cleanly, so this is deliberately crude: turn the read
;; into an answerable text prompt (a key description like "y" or "C-c"), and
;; if it can't be answered, `keyboard-quit' rather than block forever.

(defun eabp--raw-event-should-bridge-p (&optional seconds)
  "Non-nil when a raw-event read should be bridged rather than run natively.
Bridges only inside an action handler, and never when events are already
available — a running keyboard macro (`eabp-keymap--execute-key' drives
commands through `execute-kbd-macro'), queued `unread-command-events', or a
timed read (SECONDS non-nil, i.e. `read-event' used as a sleep)."
  (and eabp--in-action-handler
       (not executing-kbd-macro)
       (not unread-command-events)
       (not seconds)))

(defun eabp--bridge-key-prompt (prompt)
  "Prompt the phone for a key description and return it parsed, or quit.
Returns the `kbd' result (a string or vector), or signals `quit' when the
reply is empty or unparseable."
  (let ((reply (eabp--read-from-minibuffer-advice
                #'ignore (or (and (stringp prompt) prompt)
                             "Key input expected: "))))
    (if (and (stringp reply) (not (string-empty-p reply)))
        (let ((keys (ignore-errors (kbd reply))))
          (if (and keys (> (length keys) 0)) keys (keyboard-quit)))
      (keyboard-quit))))

(defun eabp--read-event-advice (orig-fn &rest args)
  "Around advice for `read-event'/`read-key': bridge or degrade, never hang.
Returns the first event of the parsed key description."
  ;; read-event: (&optional PROMPT INHERIT-INPUT-METHOD SECONDS).
  ;; read-key:   (&optional PROMPT) — nth 2 is simply nil.
  (if (not (eabp--raw-event-should-bridge-p (nth 2 args)))
      (apply orig-fn args)
    (aref (eabp--bridge-key-prompt (nth 0 args)) 0)))

(advice-add 'read-event :around #'eabp--read-event-advice)
(advice-add 'read-key :around #'eabp--read-event-advice)

(defun eabp--read-key-sequence-advice (orig-fn &rest args)
  "Around advice for `read-key-sequence': return the parsed sequence."
  (if (not (eabp--raw-event-should-bridge-p))
      (apply orig-fn args)
    (eabp--bridge-key-prompt (or (nth 0 args) "Key sequence: "))))

(defun eabp--read-key-sequence-vector-advice (orig-fn &rest args)
  "Around advice for `read-key-sequence-vector': parsed sequence as a vector."
  (if (not (eabp--raw-event-should-bridge-p))
      (apply orig-fn args)
    (let ((keys (eabp--bridge-key-prompt (or (nth 0 args) "Key sequence: "))))
      (if (vectorp keys) keys (vconcat keys)))))

(advice-add 'read-key-sequence :around #'eabp--read-key-sequence-advice)
(advice-add 'read-key-sequence-vector :around #'eabp--read-key-sequence-vector-advice)

(provide 'eabp-minibuffer)
;;; eabp-minibuffer.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-buffer.el
;;; ==================================================================

;;; eabp-buffer.el --- Generic buffer renderer (Tier 0) -*- lexical-binding: t; -*-

;; Tier 0 of EABP: render ANY Emacs buffer faithfully from its text plus its
;; text/overlay properties (face, display, invisible, keymap, button,
;; mouse-face), with interactive regions made tappable.  This is the universal
;; substrate — every major mode renders through here for free, no per-package
;; translator required.
;;
;; Per-mode "skins" (Tier 1, e.g. a hand-built org dashboard) are *opt-in*
;; overrides registered in `eabp-render-buffer-functions'.  Anything
;; unregistered falls through to the generic renderer below, so a new package
;; is usable on day one and only gets bespoke polish where it's worth it.
;;
;; Emacs stays the single source of truth for styling: this module resolves
;; faces to span attributes and ships them; the device only paints the spans
;; (it never re-fontifies).
;;
;; This file deliberately does NOT depend on any UI/host layer (no org-ui).
;; The only seam back to the host is `eabp-buffer-refresh-function', which the
;; host sets so a tap that mutates a buffer can re-push the showing surface.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'eabp-widgets)
(require 'eabp-surfaces)   ; eabp-defaction / eabp-action

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom eabp-buffer-max-lines 500
  "Maximum number of lines the generic renderer emits for a buffer.
Buffers longer than this are truncated (with a trailing note) so a huge
magit/log/compilation buffer can't produce an unbounded surface."
  :type 'integer :group 'eabp)

(defcustom eabp-buffer-monospace t
  "When non-nil, the generic renderer paints buffer text monospace.
Most Emacs buffers (dired, magit, tables, source) rely on column alignment,
so monospace is the faithful default.  Tier-1 skins may override per mode."
  :type 'boolean :group 'eabp)

(defcustom eabp-buffer-emit-colors t
  "When non-nil, carry a face's foreground color into the rendered span.
Only colors that differ from the default face are emitted, so semantic color
\(diff add/remove, font-lock keywords, warnings) survives while ordinary body
text still uses the device theme's on-surface color."
  :type 'boolean :group 'eabp)

(defcustom eabp-line-numbers nil
  "Line numbers in the generic buffer view and the phone editor.
nil shows none; `absolute' shows buffer line numbers; `relative' shows
distances from point (the current line shows its absolute number,
vim's hybrid style).  Configurable from the phone's Settings view."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Absolute" absolute)
                 (const :tag "Relative" relative))
  :group 'eabp)

(defconst eabp-buffer--line-number-color "#8A8A8A"
  "Dim gray for line-number spans; legible on light and dark themes.")

(defvar eabp-buffer-refresh-function nil
  "Function called with no args after an `eabp.buffer.act' mutates a buffer.
The host shell sets this to re-push whatever surface is showing the buffer.
Kept as a seam so this module never depends on a specific UI layer.")

(defvar eabp-buffer--default-fg-hex nil
  "Hex of the default face foreground, bound for the duration of a render.
Spans whose foreground matches this are emitted without a color so the
device theme owns ordinary text.")

(defvar eabp-buffer--default-bg-hex nil
  "Hex of the default face background, bound for the duration of a render.
Spans whose background matches this emit no `:bg', so ordinary text keeps
the device theme's surface color and only semantic backgrounds (diff
shading, hl-line, region, isearch) are carried over.")

;; ─── Face resolution ─────────────────────────────────────────────────────────

(defun eabp-buffer--color-hex (color)
  "Return COLOR (a name or hex string) as \"#RRGGBB\", or nil if unresolvable."
  (when (and (stringp color) (not (string-empty-p color)))
    (let ((vals (ignore-errors (color-values color))))
      (when vals
        (apply #'format "#%02X%02X%02X"
               (mapcar (lambda (v) (/ v 256)) vals))))))

(defun eabp-buffer--face-refs (face)
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
        (setq refs (append refs (eabp-buffer--face-refs f))))
      refs))
   (t nil)))

(defun eabp-buffer--ref-attr (ref attr)
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
                      (eabp-buffer--attr (eabp-buffer--face-refs inherit) attr)))))
            (t nil))))
    (if (eq v 'unspecified) nil v)))

(defun eabp-buffer--attr (refs attr)
  "First specified value of ATTR across REFS, in priority order."
  (cl-some (lambda (r) (eabp-buffer--ref-attr r attr)) refs))

(defconst eabp-buffer--bold-weights
  '(bold semi-bold semibold extra-bold extrabold ultra-bold ultrabold heavy black)
  "Weight symbols treated as bold.")

(defun eabp-buffer--span-style (face)
  "Return a plist (:bold :italic :underline :strike :color :bg) for FACE.
COLOR/:bg are included only when they resolve and differ from the default
foreground/background, so ordinary text carries neither.  Returns nil for
an unstyled run."
  (condition-case nil
      (let* ((refs (eabp-buffer--face-refs face))
             (weight (eabp-buffer--attr refs :weight))
             (slant (eabp-buffer--attr refs :slant))
             (underline (eabp-buffer--attr refs :underline))
             (strike (eabp-buffer--attr refs :strike-through))
             (fg (and eabp-buffer-emit-colors
                      (eabp-buffer--attr refs :foreground)))
             (hex (and fg (eabp-buffer--color-hex fg)))
             (bg (and eabp-buffer-emit-colors
                      (eabp-buffer--attr refs :background)))
             (bghex (and bg (eabp-buffer--color-hex bg))))
        (append
         (when (memq weight eabp-buffer--bold-weights) '(:bold t))
         (when (memq slant '(italic oblique)) '(:italic t))
         (when underline '(:underline t))
         (when strike '(:strike t))
         (when (and hex (not (equal hex eabp-buffer--default-fg-hex)))
           (list :color hex))
         (when (and bghex (not (equal bghex eabp-buffer--default-bg-hex)))
           (list :bg bghex))))
    (error nil)))

;; ─── Interactivity ─────────────────────────────────────────────────────────

(defun eabp-buffer--widget-p (obj)
  "Non-nil if OBJ is a widget.el widget object.
Own predicate (rather than `widgetp') so detection needs no wid-edit;
when a buffer actually contains widgets, wid-edit is already loaded."
  (and (consp obj) (symbolp (car obj)) (get (car obj) 'widget-type)))

(defun eabp-buffer--widget-at (pos)
  "The widget.el widget at POS as (button . W) or (field . W), else nil.
The `button' property distinguishes pressables; `field' marks editable
value boxes (Customize).  Non-widget `field' values (comint, minibuffer)
don't count."
  (let ((b (get-char-property pos 'button)))
    (if (eabp-buffer--widget-p b)
        (cons 'button b)
      (let ((f (get-char-property pos 'field)))
        (and (eabp-buffer--widget-p f) (cons 'field f))))))

(defun eabp-buffer--actionable-p (pos)
  "Non-nil if the char at POS belongs to a tappable region.
True for text/widget buttons, widget editable fields, regions carrying a
`mouse-face', and regions with their own `keymap'/`local-map' (magit
sections, info refs, …).  The major-mode keymap is buffer-local, not a
text property, so this never marks the whole buffer tappable."
  (or (get-char-property pos 'button)
      (eabp-buffer--widget-p (get-char-property pos 'field))
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

(defcustom eabp-buffer-fold-commands
  '(magit-section-toggle magit-section-cycle magit-section-cycle-global
    org-cycle org-fold-show-entry org-fold-hide-subtree
    outline-toggle-children outline-cycle outline-show-subtree
    outline-hide-subtree hs-toggle-hiding)
  "Commands treated as safe fold toggles for the generic fold affordance.
Only a command in this list will be invoked by `eabp.buffer.fold', so the
phone can never trigger an arbitrary command through the fold path."
  :type '(repeat function) :group 'eabp)

(defun eabp-buffer--invisible-at (pos)
  "Non-nil if the char at POS is currently folded away (invisible)."
  (let ((v (get-char-property pos 'invisible)))
    (and v (invisible-p v))))

(defun eabp-buffer--hidden-follows-p (eol limit)
  "Non-nil if a folded (invisible) region begins right after the line at EOL.
Bounded by LIMIT.  This is the generic \"this heading is collapsed\" signal.
Checks the end-of-line chars and the start of the next line, since modes
differ on whether the heading's newline or the body's first char carries the
`invisible' property."
  (or (and (< eol limit) (eabp-buffer--invisible-at eol))
      (and (< (1+ eol) limit) (eabp-buffer--invisible-at (1+ eol)))
      (save-excursion
        (goto-char (min eol (max (point-min) (1- limit))))
        (forward-line 1)
        (and (< (point) limit) (eabp-buffer--invisible-at (point))))))

(defun eabp-buffer--fold-span (pos buffer-name text)
  "A tappable affordance span that expands/collapses the fold at heading position POS."
  (eabp-span text
             :on-tap (eabp-action "eabp.buffer.fold"
                                  :args `((buffer . ,buffer-name) (pos . ,pos)))))

;; ─── Region → spans ─────────────────────────────────────────────────────────

(defun eabp-buffer--expand-tabs (text col)
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

(defun eabp-buffer--offscreen-display-p (disp)
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
                (cl-some #'eabp-buffer--offscreen-display-p disp)))))

(defun eabp-buffer--space-width (disp col)
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

(defun eabp-buffer--string-spans (str col)
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
                   ((eabp-buffer--offscreen-display-p disp) nil)
                   ((and (consp disp) (eq (car disp) 'space))
                    (make-string (eabp-buffer--space-width disp c) ?\s))
                   (t (substring-no-properties str i next))))
             (face (or (get-text-property i 'face str)
                       (get-text-property i 'font-lock-face str)))
             (style (eabp-buffer--span-style face)))
        (when raw
          (let ((exp (eabp-buffer--expand-tabs raw c)))
            (setq c (cdr exp))
            (unless (string-empty-p (car exp))
              (push (apply #'eabp-span (car exp)
                           (append style (when eabp-buffer-monospace '(:mono t))))
                    out))))
        (setq i next)))
    (cons (nreverse out) c)))

(defun eabp-buffer--overlay-strings (bol eol)
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

(defun eabp-buffer--line-spans (bol eol buffer-name)
  "Build the list of spans for the buffer text in [BOL, EOL).
Honors `invisible' (skips folded text), string and `(space …)' `display'
overrides, and overlay before/after-strings; expands TABs to `tab-width'
stops; maps `face'/`font-lock-face' to styling; and attaches a tap action
at the start of each actionable property run."
  (let ((pos bol) (col 0) spans
        (inserts (eabp-buffer--overlay-strings bol eol)))
    (cl-flet ((flush (upto)
                ;; Emit pending overlay-string insertions at or before UPTO,
                ;; splicing them into the run at the right column.
                (while (and inserts (<= (caar inserts) upto))
                  (let ((ss (eabp-buffer--string-spans (nth 2 (pop inserts)) col)))
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
                     (style (eabp-buffer--span-style face))
                     (act (when (eabp-buffer--actionable-p pos)
                            (eabp-action "eabp.buffer.act"
                                         :args `((buffer . ,buffer-name)
                                                 (pos . ,pos)))))
                     text)
                (cond
                 ((stringp disp)
                  (setq text disp col (+ col (length disp))))
                 ;; Fringe/margin display: the covered text is a placeholder
                 ;; that never shows in the text flow — render nothing.
                 ((eabp-buffer--offscreen-display-p disp)
                  (setq text nil))
                 ((and (consp disp) (eq (car disp) 'space))
                  (let ((w (eabp-buffer--space-width disp col)))
                    (setq text (make-string w ?\s) col (+ col w))))
                 (t
                  (let ((exp (eabp-buffer--expand-tabs
                              (buffer-substring-no-properties pos next) col)))
                    (setq text (car exp) col (cdr exp)))))
                (when (and (stringp text) (not (string-empty-p text)))
                  (push (apply #'eabp-span text
                               (append style
                                       (when eabp-buffer-monospace '(:mono t))
                                       (when act (list :on-tap act))))
                        spans)))))
          (setq pos next)))
      ;; Trailing insertions at EOL (e.g. an after-string at end of line).
      (flush eol))
    (nreverse spans)))

(defun eabp-buffer--fold-state (bol eol limit)
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
      (if (eabp-buffer--hidden-follows-p eol limit)
          'folded
        'unfolded))
     (t nil))))

(defun eabp-buffer--line-number-span (ln pt-line fmt)
  "A dim gutter span for line LN. PT-LINE is point's line, FMT the width format.
With `eabp-line-numbers' `relative', shows the distance from point —
except on point's own line, which shows its absolute number undimmed
\(vim's hybrid style)."
  (let ((current (and pt-line (= ln pt-line))))
    (eabp-span (format fmt (if (and (eq eabp-line-numbers 'relative)
                                    (not current))
                               (abs (- ln pt-line))
                             ln))
               :mono t
               :color (unless current eabp-buffer--line-number-color))))

(defun eabp-buffer--render-region (beg end buffer-name &optional mark-pos)
  "Return a list of `rich_text' nodes for [BEG, END) of the current buffer.
One node per line; blank lines keep their vertical space.  Capped at
`eabp-buffer-max-lines'.  When `eabp-line-numbers' is enabled each line
is prefixed with a dim gutter span carrying its (absolute or relative)
number — real buffer lines, so folded regions skip numbers faithfully.
MARK-POS, when non-nil, flags the line containing that position as the
enclosing lazy column's scroll target (see `eabp-scroll-here')."
  (let* ((eabp-buffer--default-fg-hex
          (eabp-buffer--color-hex (face-attribute 'default :foreground nil t)))
         (eabp-buffer--default-bg-hex
          (eabp-buffer--color-hex (face-attribute 'default :background nil t)))
         (pt-line (and eabp-line-numbers (line-number-at-pos (point))))
         (num-fmt (and eabp-line-numbers
                       (format "%%%dd " (length (number-to-string
                                                 (line-number-at-pos end))))))
         (ln (and eabp-line-numbers (line-number-at-pos beg)))
         (count 0)
         nodes)
    (ignore-errors (font-lock-ensure beg end))
    (save-excursion
      (goto-char beg)
      (while (and (< (point) end) (< count eabp-buffer-max-lines))
        (let* ((bol (line-beginning-position))
               (eol (min end (line-end-position))))
          (cond
           ;; A page break (^L alone on the line) renders as a divider rather
           ;; than a raw control glyph.
           ((and (< bol eol)
                 (save-excursion (goto-char bol) (looking-at "\f+$")))
            (push (eabp-divider) nodes)
            (setq count (1+ count)))
           (t
            (let ((spans (eabp-buffer--line-spans bol eol buffer-name)))
              ;; A fully-folded line (no visible spans, hidden at bol) is
              ;; dropped entirely so collapsed content truly disappears instead
              ;; of leaving a blank gap.  Visible lines render; a collapsed
              ;; heading gets a trailing ▸ affordance to expand it, unfolded ▾.
              (unless (and (null spans) (eabp-buffer--invisible-at bol))
                (pcase (eabp-buffer--fold-state bol eol end)
                  ('folded
                   (setq spans (append (or spans (list (eabp-span " ")))
                                       (list (eabp-buffer--fold-span bol buffer-name "  ▸")))))
                  ('unfolded
                   (setq spans (append (or spans (list (eabp-span " ")))
                                       (list (eabp-buffer--fold-span bol buffer-name "  ▾"))))))
                (setq spans (or spans (list (eabp-span " "))))
                ;; `line-prefix' (org-indent's virtual indentation, etc.) is a
                ;; text property, not part of the buffer text — prepend it as a
                ;; dim gutter span so the indentation survives.
                (let ((prefix (get-char-property bol 'line-prefix)))
                  (when (stringp prefix)
                    (setq spans (cons (eabp-span prefix :mono t
                                                 :color eabp-buffer--line-number-color)
                                      spans))))
                (when ln
                  (setq spans (cons (eabp-buffer--line-number-span ln pt-line num-fmt)
                                    spans)))
                (push (if (and mark-pos (>= mark-pos bol) (<= mark-pos eol))
                          (eabp-scroll-here (eabp-rich-text spans))
                        (eabp-rich-text spans))
                      nodes)
                (setq count (1+ count)))))))
        (when ln (setq ln (1+ ln)))
        (forward-line 1)))
    (nreverse nodes)))

;; ─── Public: generic renderer + dispatch registry ────────────────────────────

(defun eabp-buffer-render (&optional buffer)
  "Render BUFFER (default current) generically into a list of SDUI nodes.
Truncated to `eabp-buffer-max-lines'; a caption note is appended if cut."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((name (buffer-name buf))
             (total (count-lines (point-min) (point-max)))
             (nodes (eabp-buffer--render-region (point-min) (point-max) name)))
        (if (> total eabp-buffer-max-lines)
            (append nodes
                    (list (eabp-text
                           (format "… %d more line(s) (showing first %d)"
                                   (- total eabp-buffer-max-lines)
                                   eabp-buffer-max-lines)
                           'caption)))
          nodes)))))

(defun eabp-buffer-render-region (buffer beg end &optional mark-pos)
  "Render [BEG, END) of BUFFER generically into a list of SDUI nodes.
The public region variant of `eabp-buffer-render', for callers showing
a slice instead of the whole buffer (an imenu section, a hit context).
BEG and END are clamped to the buffer; the line cap still applies.
MARK-POS, when non-nil, flags its line as the scroll target."
  (let ((buf (get-buffer buffer)))
    (unless buf (error "No such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((beg (max (point-min) (min (or beg (point-min)) (point-max))))
             (end (max beg (min (or end (point-max)) (point-max)))))
        (eabp-buffer--render-region beg end (buffer-name buf) mark-pos)))))

(defun eabp-buffer-render-tail (buffer lines)
  "Render the last LINES lines of BUFFER into a list of SDUI nodes.
For transcript-shaped buffers (comint REPLs, logs) the interesting end
is the bottom — `eabp-buffer-render' caps from the top.  A leading
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
           (list (eabp-text (format "… %d earlier line(s) not shown"
                                    (count-lines (point-min) beg))
                            'caption)))
         (eabp-buffer--render-region beg (point-max) (buffer-name buf)))))))

(defvar eabp-render-buffer-functions nil
  "Alist of (MAJOR-MODE . FUNCTION) Tier-1 renderer skins.
FUNCTION takes the buffer and returns a list of SDUI nodes.  A mode with no
entry — including any mode derived from an unregistered one — falls through
to the generic `eabp-buffer-render'.  Derived modes match their nearest
registered ancestor; the first matching entry wins.")

(defun eabp-render-buffer-register (mode fn)
  "Register FN as the Tier-1 renderer skin for MODE (a major-mode symbol)."
  (setf (alist-get mode eabp-render-buffer-functions) fn))

(defun eabp-render-buffer (&optional buffer)
  "Render BUFFER via its registered skin, else the generic renderer.
Returns a list of SDUI nodes.  This is the single dispatch seam: Tier 1 is
purely additive on top of the Tier 0 substrate."
  (let ((buf (get-buffer (or buffer (current-buffer)))))
    (with-current-buffer buf
      (let ((fn (seq-some (lambda (cell)
                            (and (derived-mode-p (car cell)) (cdr cell)))
                          eabp-render-buffer-functions)))
        (if fn (funcall fn buf) (eabp-buffer-render buf))))))

;; ─── Tap dispatch ─────────────────────────────────────────────────────────

(declare-function widget-apply-action "wid-edit" (widget &optional event))
(declare-function widget-field-value-get "wid-edit" (widget &optional no-truncate))
(declare-function widget-field-value-set "wid-edit" (widget value))

(defun eabp-buffer--widget-invoke (hit)
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

(defun eabp-buffer-invoke-at (buffer-name pos)
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
         ((eabp-buffer--widget-at (point))
          (eabp-buffer--widget-invoke (eabp-buffer--widget-at (point))))
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

(eabp-defaction "eabp.buffer.act"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (eabp-buffer-invoke-at buffer pos))
      ;; Re-push the showing surface; the tap may have folded a section,
      ;; navigated, or mutated the buffer.
      (when (functionp eabp-buffer-refresh-function)
        (funcall eabp-buffer-refresh-function)))))

;; ─── Fold dispatch ────────────────────────────────────────────────────────

(defun eabp-buffer--run-fold-toggle ()
  "Run the current buffer's own fold toggle at point; non-nil if one ran.
Generic: prefer the command the buffer binds to TAB when it is a known fold
toggle (org-cycle, magit-section-toggle, the outline cycle, …); otherwise
pick the first `eabp-buffer-fold-commands' member actually bound in this
buffer.  Never runs a command outside that allowlist."
  (let ((tab (or (key-binding (kbd "TAB")) (key-binding (kbd "<tab>")))))
    (cond
     ((and (commandp tab) (memq tab eabp-buffer-fold-commands))
      (call-interactively tab) t)
     (t
      (let ((cmd (cl-find-if
                  (lambda (c)
                    (and (commandp c)
                         (where-is-internal c (current-active-maps))))
                  eabp-buffer-fold-commands)))
        (when cmd (call-interactively cmd) t))))))

(defun eabp-buffer-toggle-fold-at (buffer-name pos)
  "Toggle the fold at POS in BUFFER-NAME using the buffer's own fold command.
Point is placed on the heading first, so the mode's toggle acts on the right
section.  Runs inside an action handler, so any prompt is bridged."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        (eabp-buffer--run-fold-toggle)))))

(eabp-defaction "eabp.buffer.fold"
  (lambda (args _)
    (let ((buffer (alist-get 'buffer args))
          (pos (alist-get 'pos args)))
      (ignore-errors (eabp-buffer-toggle-fold-at buffer pos))
      (when (functionp eabp-buffer-refresh-function)
        (funcall eabp-buffer-refresh-function)))))

(provide 'eabp-buffer)
;;; eabp-buffer.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-shell.el
;;; ==================================================================

;;; eabp-shell.el --- Multi-view app shell for EABP -*- lexical-binding: t; -*-

;; The app-agnostic host: a registry of named views pushed together as one
;; multi-view surface (`app:dashboard'), with companion-local tab switching
;; (the `view.switch' builtin), a snackbar queue, drawer/bottom-bar/top-bar
;; chrome helpers, and the refresh/navigation actions every view shares.
;;
;; Tier 1 apps do not build a shell — they register views into this one:
;;
;;   (eabp-shell-define-view "agenda"
;;     :builder #'my-agenda-view
;;     :tab '(:icon "event" :label "Agenda") :order 10)
;;
;; A builder is a function of one argument (the snackbar text to attach, or
;; nil) returning a full scaffold view alist — use `eabp-shell-tab-view' /
;; `eabp-shell-nav-view' for the standard chrome.  Views registered with
;; :tab appear in the bottom bar and become the current tab when the user
;; lands on them; :when gates inclusion per push (e.g. an editor view that
;; only exists while a file is open); :overlay marks a view that, while its
;; predicate holds, is the active view without being a tab (e.g. a detail
;; drill-in).
;;
;; This module also owns the host ends of the core seams: it points the
;; Tier 0 buffer renderer's `eabp-buffer-refresh-function' at the shell
;; push, wires `eabp-settings' feedback to the snackbar, pushes on connect
;; and after an offline-queue drain, and handles the `view.switched',
;; `nav.tab', and `dashboard.refresh' wire actions.  Apps that need to run
;; on those moments register on the hooks below instead of redefining them.

;;; Code:

(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

;; ─── View registry ───────────────────────────────────────────────────────────

(defvar eabp-shell-views nil
  "Ordered list of (NAME . PLIST) registered shell views.
Managed by `eabp-shell-define-view'; kept sorted by :order.")

(cl-defun eabp-shell-define-view (name &key builder tab when overlay (order 100))
  "Register (or replace) shell view NAME.
BUILDER is a function of one argument (snackbar text or nil) returning
the view's scaffold alist.  TAB, when non-nil, is a plist (:icon :label)
placing the view in the bottom bar; landing on a tab view makes it the
current tab.  WHEN, when non-nil, is a predicate gating the view's
inclusion in each push.  OVERLAY, when non-nil, is a predicate: while it
holds, this view is the active one shown on a background push (a detail
drill-in over the current tab).  ORDER sorts views and bottom-bar items."
  (setq eabp-shell-views
        (sort (cons (cons name (list :builder builder :tab tab :when when
                                     :overlay overlay :order order))
                    (assoc-delete-all name eabp-shell-views))
              (lambda (a b)
                (< (plist-get (cdr a) :order) (plist-get (cdr b) :order)))))
  (eabp-shell--schedule-repush)
  name)

(defun eabp-shell-remove-view (name)
  "Unregister shell view NAME."
  (setq eabp-shell-views (assoc-delete-all name eabp-shell-views))
  (eabp-shell--schedule-repush))

(defun eabp-shell--visible-views ()
  "The registry entries included in this push (:when honoured).
A pred that signals counts as nil — a broken predicate must cost its
view, not the push."
  (cl-remove-if-not (lambda (entry)
                      (let ((pred (plist-get (cdr entry) :when)))
                        (or (null pred)
                            (condition-case nil (funcall pred) (error nil)))))
                    eabp-shell-views))

(defun eabp-shell--tab-p (name)
  "Non-nil when view NAME is registered as a bottom-bar tab."
  (plist-get (cdr (assoc name eabp-shell-views)) :tab))

(defun eabp-shell--overlay-p (name)
  "Non-nil when view NAME is registered as an overlay."
  (plist-get (cdr (assoc name eabp-shell-views)) :overlay))

;; ─── Shell state ─────────────────────────────────────────────────────────────

(defvar eabp-shell--current-tab nil
  "Name of the current bottom-bar tab, or nil for the first registered tab.")

(defvar eabp-shell--snackbar nil
  "Text queued by `eabp-shell-notify' for the next push, or nil.")

(defun eabp-shell-current-tab ()
  "The current tab name (the first registered tab when none is set)."
  (or eabp-shell--current-tab
      (car (cl-find-if (lambda (e) (plist-get (cdr e) :tab))
                       eabp-shell-views))))

(defun eabp-shell--active-view ()
  "The view a push should land on: a firing overlay, else the current tab."
  (or (car (cl-find-if (lambda (e)
                         (let ((pred (plist-get (cdr e) :overlay)))
                           (and pred
                                (condition-case nil (funcall pred)
                                  (error nil)))))
                       eabp-shell-views))
      (eabp-shell-current-tab)))

(defun eabp-shell-notify (text)
  "Queue TEXT to show as a snackbar on the next shell push.
Note: the companion re-shows a snackbar only when the text *changes*,
so two identical messages back-to-back display once."
  (setq eabp-shell--snackbar text))

;; ─── Hooks (the app seams) ───────────────────────────────────────────────────

(defvar eabp-shell-view-switched-hook nil
  "Hook run with the view NAME the user is switching to.
Runs before the shell's own tab bookkeeping, for both companion-local
switches (`view.switched') and Emacs-driven tab pushes — but never for
overlay views.  Modules reset their drill-in state here.")

(defvar eabp-shell-refresh-hook nil
  "Hook run before a push that must bypass caches.
Runs on the explicit `dashboard.refresh' action and after an offline
queue drain; apps drop their memo caches here.")

(defvar eabp-shell-after-push-hook nil
  "Hook run after each successful shell push.
For cheap piggybacked sends (home-screen widgets, reminder syncs); keep
handlers memo-guarded so unchanged data sends nothing.")

;; ─── Chrome: drawer, bottom bar, top bar ─────────────────────────────────────

(defvar eabp-shell-drawer-header "Glasspane"
  "Text rendered at the top of the app drawer.")

(defvar eabp-shell-drawer-items nil
  "Ordered list of (ORDER . BUILDER) drawer entries.
BUILDER is a function of no arguments returning an `eabp-drawer-item'.")

(defun eabp-shell-add-drawer-item (order builder)
  "Add BUILDER (a nullary function returning a drawer item) at ORDER."
  (setq eabp-shell-drawer-items
        (sort (cons (cons order builder) eabp-shell-drawer-items)
              (lambda (a b) (< (car a) (car b)))))
  (eabp-shell--schedule-repush))

(defvar eabp-shell-top-actions nil
  "Ordered list of (ORDER . BUILDER) default top-bar trailing actions.
BUILDER is a function of no arguments returning an icon-button node.")

(defun eabp-shell-add-top-action (order builder)
  "Add BUILDER (a nullary function returning an icon button) at ORDER."
  (setq eabp-shell-top-actions
        (sort (cons (cons order builder) eabp-shell-top-actions)
              (lambda (a b) (< (car a) (car b)))))
  (eabp-shell--schedule-repush))

(defvar eabp-shell-default-fab-function nil
  "Function of a view name returning that view's default FAB node, or nil.
Apps set this to offer a global affordance (e.g. a capture button) on
views that don't define their own.")

(defun eabp-shell-default-fab (name)
  "The app-provided default FAB for view NAME, or nil."
  (when (functionp eabp-shell-default-fab-function)
    (funcall eabp-shell-default-fab-function name)))

(defun eabp-shell-switch-view (view)
  "Action descriptor for the companion-local `view.switch' builtin."
  `((builtin . "view.switch") (view . ,view)))

(defun eabp-shell-drawer ()
  "The navigation drawer built from `eabp-shell-drawer-items'."
  (eabp-drawer (mapcar (lambda (e) (funcall (cdr e))) eabp-shell-drawer-items)
               :header eabp-shell-drawer-header))

(defun eabp-shell-bottom-bar (selected)
  "The bottom bar of all :tab views, with SELECTED highlighted."
  (eabp-bottom-bar
   (cl-loop for (name . plist) in eabp-shell-views
            for tab = (plist-get plist :tab)
            when tab
            collect (eabp-nav-item (plist-get tab :icon)
                                   (plist-get tab :label)
                                   (eabp-shell-switch-view name)
                                   :selected (equal name selected)))))

(cl-defun eabp-shell-default-top-bar (title &key extra-actions)
  "The standard top bar: TITLE plus the registered trailing actions.
EXTRA-ACTIONS are prepended (view-specific buttons before the globals)."
  (eabp-top-bar title
                :actions (append extra-actions
                                 (mapcar (lambda (e) (funcall (cdr e)))
                                         eabp-shell-top-actions))))

(cl-defun eabp-shell-tab-view (name body &key top-bar (fab nil fab-given) snackbar)
  "A standard tab view: drawer, bottom bar, pull-to-refresh, default chrome.
NAME selects the bottom-bar highlight; BODY is the content node.  TOP-BAR
defaults to `eabp-shell-default-top-bar' on the capitalized name.  When FAB
is not given at all, the app's `eabp-shell-default-fab' is used; pass an
explicit nil to render no FAB."
  `((children . ,(vector
                  (eabp-scaffold
                   :top-bar (or top-bar (eabp-shell-default-top-bar (capitalize name)))
                   :body body
                   :fab (if fab-given fab (eabp-shell-default-fab name))
                   :bottom-bar (eabp-shell-bottom-bar name)
                   :drawer (eabp-shell-drawer)
                   :snackbar snackbar
                   ;; Tab views support pull-to-refresh; navigation/detail
                   ;; views don't (a stray pull mustn't rebuild them).
                   :on-refresh (eabp-action "dashboard.refresh"
                                            :when-offline "drop"))))))

(cl-defun eabp-shell-nav-view (title body &key back-to nav-action actions
                                     fab snackbar bottom-bar floating-toolbar)
  "A navigation view: back arrow in the top bar, no tabs or drawer.
BACK-TO names the view the arrow switches to (default: the current tab)
as a companion-local switch; NAV-ACTION overrides it with an explicit
action descriptor.  ACTIONS are trailing top-bar buttons."
  `((children . ,(vector
                  (eabp-scaffold
                   :top-bar (eabp-top-bar title
                                          :nav-icon "arrow_back"
                                          :nav-action
                                          (or nav-action
                                              (eabp-shell-switch-view
                                               (or back-to (eabp-shell-current-tab))))
                                          :actions actions)
                   :body body
                   :fab fab
                   :snackbar snackbar
                   :bottom-bar bottom-bar
                   :floating-toolbar floating-toolbar)))))

;; ─── The push ────────────────────────────────────────────────────────────────

(defvar eabp-shell-surface-id "app:dashboard"
  "Surface id the shell pushes to.  One multi-view surface: the companion
switches views locally, so navigation never waits on Emacs.")

(defun eabp-shell--build-view (name plist snackbar)
  "Build view NAME from its :builder in PLIST, degrading errors in place.
A broken builder must cost its own screen, not the whole push — with a
Tier 1 being live-coded against a running session, the rest of the app
keeps updating and the broken view *shows* its error."
  (condition-case err
      (funcall (plist-get plist :builder) snackbar)
    (error
     (eabp-shell-nav-view
      (capitalize name)
      (eabp-column
       (eabp-text (format "Error building view \"%s\"" name) 'title)
       (eabp-text (error-message-string err) 'body))
      :snackbar snackbar))))

(defvar eabp-shell--repush-timer nil)

(defun eabp-shell--schedule-repush ()
  "Debounced push after a registry mutation on a live session.
Loading a Tier 1 file registers views/chrome in a burst; one idle push
after the burst means `eval-buffer' (or `load') against a connected
phone updates the app with no explicit `eabp-shell-push' — the
live-coding loop.  A no-op while disconnected: the on-connect push will
carry the registrations."
  (when (and (eabp-connected-p) (not (timerp eabp-shell--repush-timer)))
    (setq eabp-shell--repush-timer
          (run-with-idle-timer 0.5 nil
                               (lambda ()
                                 (setq eabp-shell--repush-timer nil)
                                 (eabp-shell-push))))))

(cl-defun eabp-shell-push (&optional tab &key switch-to)
  "Push every registered view as one multi-view surface.
TAB switches the logical tab before building.  SWITCH-TO additionally
forces the companion onto that view (used when a push *is* the
navigation, e.g. opening a detail); plain background refreshes never
yank the user off whatever they're looking at."
  ;; Any explicit push satisfies a pending registry repush.
  (when (timerp eabp-shell--repush-timer)
    (cancel-timer eabp-shell--repush-timer)
    (setq eabp-shell--repush-timer nil))
  (when tab
    (unless (equal tab eabp-shell--current-tab)
      (run-hook-with-args 'eabp-shell-view-switched-hook tab))
    (setq eabp-shell--current-tab tab))
  (condition-case err
      (let* ((active (eabp-shell--active-view))
             (target (or switch-to tab))
             ;; A navigation push lands the user on TARGET, so feedback
             ;; (e.g. "Saved init.el") must attach there, not to the view
             ;; they're leaving.
             (snack-view (or target active))
             (snackbar (prog1 eabp-shell--snackbar
                         (setq eabp-shell--snackbar nil)))
             (views (mapcar
                     (lambda (entry)
                       (let ((name (car entry)))
                         (cons (intern name)
                               (eabp-shell--build-view
                                name (cdr entry)
                                (when (equal name snack-view)
                                  snackbar)))))
                     (eabp-shell--visible-views))))
        (eabp-surface-push
         eabp-shell-surface-id
         `((views . ,views)
           (initial_view . ,active))
         nil nil
         ;; Force the companion onto a view only when this push *is* a
         ;; navigation — see SWITCH-TO above.
         target)
        (run-hooks 'eabp-shell-after-push-hook))
    (error
     (message "EABP shell push failed: %s" (error-message-string err)))))

(defun eabp-shell-refresh (&rest _)
  "Bypass app caches (via `eabp-shell-refresh-hook') and push.
Safe on any hook: extra arguments are ignored."
  (run-hooks 'eabp-shell-refresh-hook)
  (eabp-shell-push))

;; ─── Host ends of the core seams ─────────────────────────────────────────────

;; A tap that mutates a buffer re-pushes the showing surface through here.
(setq eabp-buffer-refresh-function #'eabp-shell-push)

;; Settings feedback lands in the snackbar; setting changes re-render.
(defvar eabp-settings-notify-function)
(defvar eabp-settings-refresh-function)
(with-eval-after-load 'eabp-settings
  (setq eabp-settings-notify-function #'eabp-shell-notify
        eabp-settings-refresh-function #'eabp-shell-push))

;; ─── Wire actions ────────────────────────────────────────────────────────────

(eabp-defaction "view.switched"
  (lambda (args _)
    ;; The companion already flipped the view locally — this event only
    ;; synchronizes Emacs's notion of "where the user is" and refreshes
    ;; the (possibly stale) cached views in the background.
    (let ((view (alist-get 'view args)))
      (when view
        (unless (eabp-shell--overlay-p view)
          (run-hook-with-args 'eabp-shell-view-switched-hook view)
          (when (eabp-shell--tab-p view)
            (setq eabp-shell--current-tab view)))
        ;; No :switch-to — never yank the user during a background refresh.
        (eabp-shell-push)))))

(eabp-defaction "nav.tab"
  ;; Legacy round-trip navigation; superseded by the view.switch builtin
  ;; but kept so stale cached UIs from older pushes still work.
  (lambda (args _)
    (let ((tab (alist-get 'tab args)))
      (eabp-shell-push tab))))

(eabp-defaction "dashboard.refresh"
  ;; Manual refresh is an explicit "give me fresh data": bypass the memos.
  (lambda (_ _) (eabp-shell-refresh)))

(eabp-defaction "dialog.dismiss"
  (lambda (_ _) (eabp-dismiss-dialog)))

;; The shell's own drawer entry: an explicit data refresh.
(eabp-shell-add-drawer-item
 70 (lambda ()
      (eabp-drawer-item "refresh" "Refresh data"
                        (eabp-action "dashboard.refresh" :when-offline "drop"))))

;; ─── Lifecycle pushes ────────────────────────────────────────────────────────

;; After (re)connect, push so the app never shows a stale screen from a
;; previous Emacs session. Depth 10: after the revision snapshot has been
;; absorbed (-50 in eabp-surfaces) and any notification re-asserts (0).
(add-hook 'eabp-connected-hook
          (lambda (_welcome) (eabp-shell-push))
          10)

;; After a replay, queued taps have just mutated state — the cached views
;; on the phone are now behind reality.
(add-hook 'eabp-queue-drained-hook #'eabp-shell-refresh)

(provide 'eabp-shell)
;;; eabp-shell.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-tablist.el
;;; ==================================================================

;;; eabp-tablist.el --- Generic tabulated-list renderer (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: `tabulated-list-mode' is a declarative UI framework — columns
;; come from `tabulated-list-format', rows carry their id and entry as text
;; properties — so ONE renderer covers every derivative (package menu,
;; process list, bookmarks, timers, and any package built on it).
;;
;; Registered as a skin for `tabulated-list-mode' in
;; `eabp-render-buffer-functions'; anything the buffer view shows in a
;; tabulated-list derivative renders as sortable cards instead of monospace
;; text.  Row taps reuse the existing `eabp.buffer.act' seam (push button /
;; RET at position), so activation adds no new dispatch surface; the only
;; new wire actions are `tablist.sort' and `tablist.refresh', both validated
;; against the buffer's own column format.
;;
;; Modes can specialize without replacing the walk via three hook alists
;; (header, row, filter) — eabp-package-browser.el is the worked example.
;;
;; Host seams (this file depends on no UI layer): re-pushes go through
;; `eabp-buffer-refresh-function' (owned by eabp-buffer), and opening a
;; buffer as the current view goes through `eabp-tablist-view-buffer-function'
;; which the host shell points at its buffer-view navigation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

;; ─── Configuration and host seams ────────────────────────────────────────────

(defcustom eabp-tablist-max-rows 100
  "Maximum rows rendered from one tabulated-list buffer.
Large lists (a full MELPA package menu is thousands of rows) are capped
with a trailing note; skins narrow with filters rather than paging."
  :type 'integer :group 'eabp)

(defvar eabp-tablist-view-buffer-function
  (lambda (name) (message "EABP: no host to view buffer %s" name))
  "Function of a buffer name that navigates the companion to that buffer.
Set by the host shell (the org-ui dashboard points it at the buffer view).")

;; ─── Per-mode skin hooks ─────────────────────────────────────────────────────

(defvar eabp-tablist-header-functions nil
  "Alist of (MODE . FN); FN of the buffer returns extra header nodes.
Rendered between the title row and the sort chips.  Nearest derived
mode wins, like `eabp-render-buffer-functions'.")

(defvar eabp-tablist-row-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY POS) returns a row node, or nil
to fall back to the generic row.  Called with the list buffer current.")

(defvar eabp-tablist-filter-functions nil
  "Alist of (MODE . FN); FN of (ID ENTRY) says whether to keep a row.
Filtering runs before the row cap, so narrowed views see deep rows.")

(defun eabp-tablist--mode-fn (alist)
  "The nearest-derived-mode function from ALIST for the current buffer."
  (cl-loop for (mode . fn) in alist
           when (derived-mode-p mode) return fn))

;; ─── Reading the list ────────────────────────────────────────────────────────

(defun eabp-tablist--rows ()
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

(defun eabp-tablist-col-string (col)
  "The display string of entry column COL (a string or (LABEL . PROPS))."
  (cond ((stringp col) col)
        ((consp col) (format "%s" (car col)))
        (t (format "%s" col))))

(defun eabp-tablist-entry-col (entry name)
  "ENTRY's column named NAME per the current buffer's format, or nil.
Part of the skin-author API: row/filter hooks use this to read a column
by its header label instead of a fragile index."
  (let ((i (cl-position name tabulated-list-format :key #'car :test #'equal)))
    (and i (< i (length entry))
         (eabp-tablist-col-string (aref entry i)))))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-tablist--sort-chips ()
  "A chip row for the sortable columns of the current buffer, or nil."
  (let* ((key (car tabulated-list-sort-key))
         (desc (cdr tabulated-list-sort-key))
         (chips (cl-loop for col across tabulated-list-format
                         for name = (car col)
                         when (nth 2 col) ; sortable
                         collect (eabp-chip
                                  (if (equal name key)
                                      (concat name (if desc " ↓" " ↑"))
                                    name)
                                  :selected (equal name key)
                                  :on-tap (eabp-action
                                           "tablist.sort"
                                           :args `((buffer . ,(buffer-name))
                                                   (column . ,name))
                                           :when-offline "drop")))))
    (when chips (apply #'eabp-flow-row chips))))

(defun eabp-tablist--default-row (buf-name pos entry)
  "Generic row card: first column as title, the rest as a caption."
  (let* ((cols (mapcar #'eabp-tablist-col-string (append entry nil)))
         (rest (string-join (cl-remove-if #'string-empty-p (cdr cols)) "  ·  ")))
    (eabp-card
     (list (apply #'eabp-column
                  (delq nil
                        (list (eabp-text (or (car cols) "") 'label)
                              (unless (string-empty-p rest)
                                (eabp-text rest 'caption))))))
     :on-tap (eabp-action "eabp.buffer.act"
                          :args `((buffer . ,buf-name) (pos . ,pos))
                          :when-offline "drop"))))

(defun eabp-tablist-render (buf)
  "Tier-1 skin: BUF (a tabulated-list buffer) as sortable, tappable cards."
  (with-current-buffer buf
    (let* ((name (buffer-name))
           (header-fn (eabp-tablist--mode-fn eabp-tablist-header-functions))
           (row-fn (eabp-tablist--mode-fn eabp-tablist-row-functions))
           (filter-fn (eabp-tablist--mode-fn eabp-tablist-filter-functions))
           (rows (eabp-tablist--rows))
           (rows (if filter-fn
                     (cl-remove-if-not
                      (lambda (r) (funcall filter-fn (nth 1 r) (nth 2 r)))
                      rows)
                   rows))
           (total (length rows))
           (shown (cl-subseq rows 0 (min total eabp-tablist-max-rows))))
      (append
       (list (eabp-row
              (eabp-box (list (eabp-text (format "%d rows" total) 'caption))
                        :weight 1)
              (eabp-icon-button "refresh"
                                (eabp-action "tablist.refresh"
                                             :args `((buffer . ,name))
                                             :when-offline "drop")
                                :content-description "Refresh list")))
       (when header-fn (funcall header-fn buf))
       (let ((chips (eabp-tablist--sort-chips)))
         (and chips (list chips)))
       (mapcar (lambda (r)
                 (or (and row-fn
                          (funcall row-fn (nth 1 r) (nth 2 r) (nth 0 r)))
                     (eabp-tablist--default-row name (nth 0 r) (nth 2 r))))
               shown)
       (when (> total (length shown))
         (list (eabp-text
                (format "Showing %d of %d — narrow with a filter."
                        (length shown) total)
                'caption)))))))

(eabp-render-buffer-register 'tabulated-list-mode #'eabp-tablist-render)

;; ─── Generic actions ─────────────────────────────────────────────────────────

(defun eabp-tablist-refresh-view ()
  (when (functionp eabp-buffer-refresh-function)
    (funcall eabp-buffer-refresh-function)))

(eabp-defaction "tablist.sort"
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
        (eabp-tablist-refresh-view)))))

(eabp-defaction "tablist.refresh"
  (lambda (args _)
    (let ((buf (get-buffer (or (alist-get 'buffer args) ""))))
      (when buf
        (with-current-buffer buf
          (when (derived-mode-p 'tabulated-list-mode)
            (ignore-errors (revert-buffer))))
        (eabp-tablist-refresh-view)))))

(provide 'eabp-tablist)
;;; eabp-tablist.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-comint.el
;;; ==================================================================

;;; eabp-comint.el --- Generic comint renderer (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: `comint-mode' is the substrate under every process REPL —
;; M-x shell, ielm, the inferior language shells — so ONE skin covers
;; them all, the same bet eabp-tablist makes on tabulated-list-mode.
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
;; buffer view's live-refresh watch (eabp-emacs-ui) re-pushes as it
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
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

(defcustom eabp-comint-tail-lines 200
  "Transcript lines rendered from the tail of a comint buffer."
  :type 'integer :group 'eabp)

(defvar eabp-comint--gen (make-hash-table :test 'equal)
  "Buffer name -> send counter, spliced into the input's widget id.
A send bumps it, handing the client a fresh (empty) field; background
transcript refreshes don't, so the seed guard keeps half-typed input.")

(defun eabp-comint--refresh ()
  (when (functionp eabp-buffer-refresh-function)
    (funcall eabp-buffer-refresh-function)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-comint-render (buf)
  "Tier-1 skin: comint BUF as status row + transcript tail + input row."
  (with-current-buffer buf
    (let* ((name (buffer-name))
           (proc (get-buffer-process buf))
           (live (and proc (process-live-p proc))))
      (append
       (list (eabp-row
              (eabp-box (list (eabp-text
                               (if live
                                   (format "%s — %s" (process-name proc)
                                           (process-status proc))
                                 "no live process")
                               'caption))
                        :weight 1)
              (and live
                   (eabp-icon-button "stop"
                                     (eabp-action "comint.interrupt"
                                                  :args `((buffer . ,name))
                                                  :when-offline "drop")
                                     :content-description "Interrupt (C-c C-c)"))))
       (eabp-buffer-render-tail buf eabp-comint-tail-lines)
       (when live
         ;; The input row is the scroll target: it sits at the bottom, and
         ;; every output line shifts its index, so the view follows the
         ;; transcript — the terminal "tail -f" feel.
         (list (eabp-scroll-here
                (eabp-text-input
                 (format "comint/%s/%d" name (gethash name eabp-comint--gen 0))
                 :hint "Input — Enter sends"
                 :single-line t :monospace t
                 :on-submit (eabp-action "comint.send"
                                         :args `((buffer . ,name)))))))))))

(eabp-render-buffer-register 'comint-mode #'eabp-comint-render)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun eabp-comint--live-buffer (name)
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

(eabp-defaction "comint.send"
  (lambda (args _)
    (let ((buf (eabp-comint--live-buffer (alist-get 'buffer args)))
          (input (alist-get 'value args)))
      (when (and buf (stringp input))
        (condition-case err
            (with-current-buffer buf
              (goto-char (point-max))
              (insert input)
              (comint-send-input))
          (error (message "Send failed: %s" (error-message-string err))))
        (cl-incf (gethash (buffer-name buf) eabp-comint--gen 0))
        (eabp-comint--refresh)))))

(eabp-defaction "comint.interrupt"
  (lambda (args _)
    (let ((buf (eabp-comint--live-buffer (alist-get 'buffer args))))
      (when buf
        (with-current-buffer buf
          (ignore-errors (comint-interrupt-subjob)))
        (eabp-comint--refresh)))))

(provide 'eabp-comint)
;;; eabp-comint.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-transient.el
;;; ==================================================================

;;; eabp-transient.el --- Render transient prefixes as touch dialogs -*- lexical-binding: t; -*-

;; Transient prefixes (all of magit, and a growing share of modern packages)
;; are declarative specs: groups, keys, descriptions, switches and options
;; live in the `transient--layout' symbol property.  This module renders a
;; prefix as a touch dialog — infix switches/options as toggle chips,
;; suffixes as buttons — instead of transient's keyboard-driven popup.
;;
;; The integration point is an advice on `transient-setup': when a prefix
;; command runs inside an EABP action handler (an M-x from the phone, or a
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
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar eabp-transient--current nil
  "(PREFIX . BUFFER-NAME) of the transient dialog being shown, or nil.
Suffixes run with BUFFER-NAME current so predicates and commands see the
context the prefix was invoked from (a magit status buffer, say).")

(defvar eabp-transient--values nil
  "Alist of PREFIX → list of active argument strings (\"--all\", \"--author=X\").")

;; ─── Reading the layout ──────────────────────────────────────────────────────

(defun eabp-transient--desc (plist fallback)
  "Resolve PLIST's :description (string or function) or FALLBACK."
  (let ((d (plist-get plist :description)))
    (cond ((stringp d) d)
          ((functionp d)
           (or (ignore-errors
                 (let ((s (funcall d)))
                   (and (stringp s) (substring-no-properties s))))
               fallback))
          (t fallback))))

(defun eabp-transient--visible-p (plist)
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

(defun eabp-transient--vec-plist (g)
  "The property plist of a group vector G (nil or a keyword-keyed list)."
  (let ((n (length g)))
    (when (> n 1)
      (let ((cand (aref g (- n 2))))
        (and (consp cand) (keywordp (car cand)) cand)))))

(defun eabp-transient--vec-children (g)
  "The child-node list of a group vector G (its last slot when a list)."
  (let ((n (length g)))
    (when (> n 0)
      (let ((last (aref g (1- n))))
        (and (listp last) last)))))

(defun eabp-transient--leaf-plist (c)
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

(defun eabp-transient--groups (prefix)
  "Flatten PREFIX's layout into (DESCRIPTION . CHILDREN) groups.
Each child is a plist with :kind (`infix' or `suffix'), :description,
:argument and :command.  Nested column containers are flattened; group
and child visibility predicates are honoured where recognisable.  Robust
to both the list-of-groups and single-root-vector layout shapes."
  (let (groups)
    (cl-labels
        ((walk-group (g inherited-desc)
           (when (vectorp g)
             (let* ((plist (eabp-transient--vec-plist g))
                    (children (eabp-transient--vec-children g))
                    (desc (eabp-transient--desc plist inherited-desc)))
               (when (eabp-transient--visible-p plist)
                 (if (cl-some #'vectorp children)
                     ;; A container of sub-groups (columns/rows) or the root:
                     ;; recurse into each vector child.
                     (dolist (sub children)
                       (when (vectorp sub) (walk-group sub desc)))
                   (let ((kids (delq nil (mapcar #'parse-child children))))
                     (when kids
                       (push (cons desc kids) groups))))))))
         (parse-child (c)
           (let ((plist (eabp-transient--leaf-plist c)))
             (when plist
               (let ((arg (plist-get plist :argument))
                     (cmd (plist-get plist :command)))
                 (when (eabp-transient--visible-p plist)
                   (cond
                    ((stringp arg)
                     (list :kind 'infix
                           :argument arg
                           :description (eabp-transient--desc plist arg)))
                    ((commandp cmd)
                     (list :kind 'suffix
                           :command cmd
                           :description
                           (eabp-transient--desc
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

(defun eabp-transient--child (prefix key value)
  "Find the child plist in PREFIX's layout whose KEY equals VALUE."
  (cl-loop for (_desc . kids) in (eabp-transient--groups prefix)
           thereis (cl-find value kids
                            :key (lambda (k) (plist-get k key))
                            :test #'equal)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-transient--arg-active (prefix arg)
  "The active value for ARG in PREFIX's state, or nil.
For options (\"--author=\") any stored value with that prefix counts."
  (let ((values (alist-get prefix eabp-transient--values)))
    (if (string-suffix-p "=" arg)
        (cl-find arg values :test #'string-prefix-p)
      (car (member arg values)))))

(defun eabp-transient--dialog (prefix)
  "Build the dialog spec for PREFIX from its layout and argument state."
  (apply
   #'eabp-lazy-column
   (append
    (list (eabp-row
           (eabp-box
            (list (eabp-text
                   (capitalize (replace-regexp-in-string
                                "-" " " (symbol-name prefix)))
                   'title))
            :weight 1)
           (eabp-button "Close"
                        (eabp-action "dialog.dismiss")
                        :variant "text")))
    (cl-loop
     for (desc . kids) in (eabp-transient--groups prefix)
     append
     (delq nil
           (list
            (when desc (eabp-section-header desc))
            (apply
             #'eabp-flow-row
             (mapcar
              (lambda (k)
                (if (eq (plist-get k :kind) 'infix)
                    (let* ((arg (plist-get k :argument))
                           (active (eabp-transient--arg-active prefix arg)))
                      (eabp-chip (if (and active (not (equal active arg)))
                                     active ; show "--author=X", not "--author="
                                   (plist-get k :description))
                                 :selected (and active t)
                                 :on-tap (eabp-action
                                          "transient.toggle"
                                          :args `((argument . ,arg))
                                          :when-offline "drop")))
                  (eabp-button (plist-get k :description)
                               (eabp-action
                                "transient.invoke"
                                :args `((command . ,(symbol-name
                                                     (plist-get k :command))))
                                :when-offline "drop")
                               :variant "outlined")))
              kids))))))))

(defun eabp-transient-show (prefix)
  "Render PREFIX as a touch dialog and record it as current."
  (setq eabp-transient--current (cons prefix (buffer-name)))
  (eabp-send-dialog (eabp-transient--dialog prefix)))

;; ─── Interception ────────────────────────────────────────────────────────────

(defun eabp--transient-setup-advice (orig-fn &optional name &rest args)
  "When a prefix is invoked from the phone, dialog instead of popup.
Without this, `transient-setup' would block waiting for key events that
can never arrive over the bridge."
  (if (and eabp--in-action-handler name (get name 'transient--layout))
      (eabp-transient-show name)
    (apply orig-fn name args)))

(advice-add 'transient-setup :around #'eabp--transient-setup-advice)

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "transient.show"
  ;; Open a prefix by name.  Equivalent surface to M-x (which is already an
  ;; allowlisted path): only commands that ARE transient prefixes qualify.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name))))
      (if (and sym (commandp sym) (get sym 'transient--layout))
          (eabp-transient-show sym)
        (eabp-send "toast.show"
                   `((text . ,(format "%s is not a transient prefix"
                                      (or name "?")))))))))

(eabp-defaction "transient.toggle"
  (lambda (args _)
    (let* ((prefix (car eabp-transient--current))
           (arg (alist-get 'argument args))
           (child (and prefix (eabp-transient--child prefix :argument arg))))
      (when child
        (let* ((values (alist-get prefix eabp-transient--values))
               (active (eabp-transient--arg-active prefix arg)))
          (setf (alist-get prefix eabp-transient--values)
                (if active
                    (remove active values)
                  (cons (if (string-suffix-p "=" arg)
                            ;; Options carry a value: prompt for it (the
                            ;; minibuffer bridge turns this into a dialog).
                            (concat arg (read-string
                                         (format "%s " (plist-get child :description))))
                          arg)
                        values)))
          (eabp-send-dialog (eabp-transient--dialog prefix)))))))

(eabp-defaction "transient.invoke"
  (lambda (args _)
    (let* ((prefix (car eabp-transient--current))
           (buf (cdr eabp-transient--current))
           (name (alist-get 'command args))
           (sym (and (stringp name) (intern-soft name)))
           (child (and prefix sym
                       (eabp-transient--child prefix :command sym))))
      (when child
        (eabp-dismiss-dialog)
        (let ((values (copy-sequence
                       (alist-get prefix eabp-transient--values)))
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
                (error (eabp-send
                        "toast.show"
                        `((text . ,(format "%s failed: %s" name
                                           (error-message-string err))))))))))
        (when (functionp eabp-buffer-refresh-function)
          (funcall eabp-buffer-refresh-function))))))

(provide 'eabp-transient)
;;; eabp-transient.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-keymap.el
;;; ==================================================================

;;; eabp-keymap.el --- Keymap surfacing for the radial pie menu -*- lexical-binding: t; -*-

;; The input complement to the Tier 0 generic buffer renderer.  Two UIs,
;; split by how good the available labels are:
;;
;;   * Tier 0 default — a searchable COMMAND PALETTE.  Raw keymap dumps
;;     have dozens of bindings with machine-made labels; a live-filtering
;;     list (the bridged `completing-read' picker) beats a pie menu for
;;     that.  `eabp.keymap.show' extracts the buffer's bindings and runs
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
;; The grouping/category machinery below (`eabp-keymap--group-bindings')
;; is retained for future Tier 1 skins that want to send curated pie
;; specs for a whole mode; the default path no longer uses it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'eabp-surfaces)   ; eabp-defaction, eabp-action, eabp-send

;; Forward declaration: defined in eabp-buffer.el, set by eabp-emacs-ui.el
(defvar eabp-buffer-refresh-function)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom eabp-keymap-show-global nil
  "When non-nil, include global-map bindings in the pie menu.
Usually these are ambient (C-x C-s, C-g, etc.) and not useful on a phone;
the mode-specific bindings are what matter."
  :type 'boolean :group 'eabp)

(defcustom eabp-keymap-max-segments 8
  "Maximum number of top-level categories in the pie menu.
Excess categories are merged into an \"Other\" overflow group."
  :type 'integer :group 'eabp)

(defcustom eabp-keymap-max-bindings 200
  "Maximum number of bindings to extract from a buffer's keymaps.
Safety cap so a mode with hundreds of bindings doesn't produce an
unbounded spec."
  :type 'integer :group 'eabp)

(defcustom eabp-keymap-denylist
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
  :type '(repeat symbol) :group 'eabp)

;; ─── Binding extraction ────────────────────────────────────────────────────

(defun eabp-keymap--key-printable-p (key)
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

(defun eabp-keymap--walk-keymap (keymap prefix-keys)
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
            ((not (eabp-keymap--key-printable-p key-vec)) nil)
            ;; Recurse into prefix keymaps (but limit depth to 3)
            ((and (keymapp resolved) (< (length key-vec) 4))
             (setq bindings
                   (append bindings
                           (eabp-keymap--walk-keymap resolved key-vec))))
            ;; Leaf binding — store the symbol, not the resolved function
            ((commandp def)
             (push (cons key-vec def) bindings)))))
       keymap))
    (nreverse bindings)))

(defun eabp-keymap--extract-bindings (buffer)
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
                  (when (and keymap (< count eabp-keymap-max-bindings))
                    (dolist (pair (eabp-keymap--walk-keymap keymap []))
                      (when (< count eabp-keymap-max-bindings)
                        (let* ((key-vec (car pair))
                               (cmd (cdr pair))
                               (desc (key-description key-vec)))
                          (unless (or (gethash desc seen)
                                     (memq cmd eabp-keymap-denylist)
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
        (when eabp-keymap-show-global
          (collect global-map 'global)))
      (nreverse result))))

;; ─── Transient.el integration ──────────────────────────────────────────────

(defun eabp-keymap--transient-available-p ()
  "Non-nil if transient.el is loaded."
  (featurep 'transient))

(defun eabp-keymap--transient-prefix-p (command)
  "Non-nil if COMMAND is a transient prefix (has a layout definition)."
  (and (eabp-keymap--transient-available-p)
       (symbolp command)
       (get command 'transient--layout)))

(defun eabp-keymap--transient-active-p ()
  "Non-nil if a transient session is currently active."
  (and (eabp-keymap--transient-available-p)
       (bound-and-true-p transient--prefix)))

(defun eabp-keymap--extract-transient-layout (prefix-symbol)
  "Extract bindings from PREFIX-SYMBOL's transient layout (without activating it).
Returns a list of (:key KEY :label LABEL :command CMD :is-infix BOOL) plists."
  (let ((layout (get prefix-symbol 'transient--layout))
        (result nil))
    (when layout
      (eabp-keymap--walk-transient-node layout result)
      (nreverse result))))

(defun eabp-keymap--walk-transient-node (thing result)
  "Recursively walk a transient layout node THING, pushing bindings onto RESULT.
THING can be a vector (group), a list starting with a transient class
symbol (suffix/infix), or a plain list of children to recurse over."
  (cond
   ;; Vector = group node: [CLASS-OR-LEVEL PLIST CHILDREN...]
   ;; Convert to list, skip the first 2 elements (class + plist), recurse children.
   ((vectorp thing)
    (dolist (child (cddr (append thing nil)))
      (eabp-keymap--walk-transient-node child result)))

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
      (eabp-keymap--walk-transient-node elt result)))))

(defun eabp-keymap--active-transient-bindings ()
  "Extract bindings from the currently active transient session.
Returns a list similar to `eabp-keymap--extract-transient-layout'
but reflecting the live state (current infix values, etc.)."
  (when (eabp-keymap--transient-active-p)
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

(defun eabp-keymap--single-key-p (key-desc)
  "Non-nil if KEY-DESC is a single unmodified key (like \"s\", \"g\", \"?\")."
  (and (= (length key-desc) 1)
       (not (string-match-p "[CM]-" key-desc))))

(defun eabp-keymap--prefix-of (key-desc)
  "Return the prefix group for KEY-DESC, or nil for single keys.
E.g. \"C-c C-t\" -> \"C-c\", \"C-x 4 f\" -> \"C-x\", \"M-g g\" -> \"M-g\"."
  (when (string-match "\\`\\([CMSs]-[^ ]+\\) " key-desc)
    (match-string 1 key-desc)))

(defun eabp-keymap--group-bindings (bindings buffer-name)
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
        (if (eabp-keymap--single-key-p key-desc)
            (push b single-keys)
          (let ((prefix (or (eabp-keymap--prefix-of key-desc) "Other")))
            (push b (gethash prefix prefix-groups))))))
    ;; Build categories
    ;; 1. Single-key commands (the "hot keys") — most important
    (when single-keys
      (push (cons "Keys"
                  (cons "keyboard"
                        (eabp-keymap--bindings-to-specs
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
                          (eabp-keymap--bindings-to-specs
                           (cdr pg) buffer-name)))
              categories)))
    ;; Enforce max categories
    (setq categories (nreverse categories))
    (when (> (length categories) eabp-keymap-max-segments)
      ;; Merge excess into "Other"
      (let ((keep (seq-take categories (1- eabp-keymap-max-segments)))
            (overflow (seq-drop categories (1- eabp-keymap-max-segments))))
        (setq categories
              (append keep
                      (list (cons "Other"
                                  (cons "more_horiz"
                                        (apply #'append
                                               (mapcar #'cddr overflow)))))))))
    categories))

(defun eabp-keymap--bindings-to-specs (bindings buffer-name)
  "Convert a list of (KEY-DESC CMD SOURCE) BINDINGS into JSON-ready specs."
  (mapcar
   (lambda (b)
     (let* ((key-desc (nth 0 b))
            (cmd (nth 1 b))
            (is-transient-prefix (eabp-keymap--transient-prefix-p cmd))
            (children (when is-transient-prefix
                        (eabp-keymap--transient-children-specs cmd buffer-name)))
            (label (eabp-keymap--command-label cmd)))
       (append
        `((key . ,key-desc)
          (label . ,label)
          (action . ,(eabp-action "eabp.keymap.run"
                                  :args `((buffer . ,buffer-name)
                                          (key . ,key-desc))
                                  :when-offline "drop")))
        (when is-transient-prefix
          `((is_prefix . t)))
        (when children
          `((children . ,(vconcat children)))))))
   bindings))

(defun eabp-keymap--transient-children-specs (prefix-cmd buffer-name)
  "Build child binding specs for transient prefix PREFIX-CMD."
  (let ((layout-bindings (eabp-keymap--extract-transient-layout prefix-cmd)))
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
          `((action . ,(eabp-action "eabp.keymap.run"
                                    :args `((buffer . ,buffer-name)
                                            (key . ,key)
                                            (transient_prefix
                                             . ,(symbol-name prefix-cmd)))
                                    :when-offline "drop"))))))
     layout-bindings)))

(defun eabp-keymap--command-label (cmd)
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

(defun eabp-keymap--build-pie-spec (buffer)
  "Build the full pie-menu JSON spec for BUFFER's keybindings."
  (with-current-buffer buffer
    (let* ((mode-label (symbol-name major-mode))
           (buffer-name (buffer-name buffer))
           ;; Check for active transient first
           (is-transient (eabp-keymap--transient-active-p))
           (categories
            (if is-transient
                ;; Active transient: show its bindings as a single category
                (let* ((bindings (eabp-keymap--active-transient-bindings))
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
                                       . ,(eabp-action
                                           "eabp.keymap.run"
                                           :args `((buffer . ,buffer-name)
                                                   (key . ,key)
                                                   (transient_active . t))
                                           :when-offline "drop"))))))
                               bindings)))
                  (list (cons "Transient"
                              (cons "terminal" specs))))
              ;; Normal mode: extract from active keymaps
              (let ((bindings (eabp-keymap--extract-bindings buffer)))
                (eabp-keymap--group-bindings bindings buffer-name)))))
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

(defvar eabp-keymap-tier1-menus nil
  "Alist of (MAJOR-MODE . BUILDER) curated Tier 1 pie menus.
BUILDER is called with the buffer and returns a pie-menu spec alist
\(same shape as `eabp-keymap--build-pie-spec').  A buffer whose mode
derives from a registered mode gets its curated pie instead of the
default command palette; the first matching entry wins.")

(defun eabp-keymap-register-tier1 (mode builder)
  "Register BUILDER as the curated Tier 1 pie menu for MODE."
  (setf (alist-get mode eabp-keymap-tier1-menus) builder))

(defun eabp-keymap--tier1-builder (buf)
  "The registered Tier 1 menu builder for BUF's major mode, or nil."
  (with-current-buffer buf
    (seq-some (lambda (cell)
                (and (derived-mode-p (car cell)) (cdr cell)))
              eabp-keymap-tier1-menus)))

;; ─── Menu-bar mining ────────────────────────────────────────────────────────
;;
;; A mode's menu-bar keymap is the ONE place its author writes human labels and
;; :help strings — exactly the curated metadata a raw keymap dump lacks.  We
;; mine the local and minor-mode menus (not the generic global File/Edit menu)
;; into palette entries: breadcrumb-labeled, help-annotated, dispatched by
;; command symbol.  Same class of curated, mode-owned command the palette
;; already runs, so this stays inside the command-dispatch boundary.

(defcustom eabp-keymap-menu-max-items 150
  "Cap on menu-derived palette entries mined from a buffer's menus."
  :type 'integer :group 'eabp)

(defun eabp-keymap--menu-pred (props key)
  "Non-nil when PROPS' KEY predicate (`:enable'/`:visible') passes or is absent.
A predicate that signals is treated as passing — better to offer a command
that turns out disabled than to hide one on a spurious error."
  (let ((m (plist-member props key)))
    (or (not m)
        (condition-case nil (eval (plist-get props key) t) (error t)))))

(defun eabp-keymap--menu-item-parse (binding)
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
                 (eabp-keymap--menu-pred props :enable)
                 (eabp-keymap--menu-pred props :visible))
        (list label real (plist-get props :help)))))
   ((and (consp binding) (stringp (car binding)))
    (let ((label (car binding))
          (rest (cdr binding)))
      (unless (string-prefix-p "--" label)
        (if (and (consp rest) (stringp (car rest)))
            (list label (cdr rest) (car rest))   ; (STRING HELP . REAL)
          (list label rest nil)))))              ; (STRING . REAL)
   (t nil)))

(defun eabp-keymap--menu-entries (keymap)
  "Flatten menu-bar KEYMAP into (LABEL-PATH HELP COMMAND) leaves.
Submenus recurse with a breadcrumb label path (\"File ▸ Save As…\");
disabled/invisible items, separators, and non-command leaves are dropped."
  (let (out)
    (cl-labels
        ((walk (km crumb depth)
           (when (and (keymapp km) (< depth 5)
                      (< (length out) eabp-keymap-menu-max-items))
             (map-keymap
              (lambda (_event binding)
                (when (< (length out) eabp-keymap-menu-max-items)
                  (when-let ((parsed (eabp-keymap--menu-item-parse binding)))
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

(defun eabp-keymap--menu-maps (buf)
  "Menu-bar keymaps to mine for BUF: minor-mode and local (plus global when
`eabp-keymap-show-global').  The global menu is skipped by default — its
File/Edit/… entries are generic noise next to the mode's own menu."
  (with-current-buffer buf
    (let (maps)
      (dolist (km (current-minor-mode-maps))
        (let ((menu (and (keymapp km) (lookup-key km [menu-bar]))))
          (when (keymapp menu) (push menu maps))))
      (when-let* ((lm (current-local-map))
                  (menu (lookup-key lm [menu-bar])))
        (when (keymapp menu) (push menu maps)))
      (when eabp-keymap-show-global
        (let ((menu (lookup-key (current-global-map) [menu-bar])))
          (when (keymapp menu) (push menu maps))))
      (nreverse maps))))

(defun eabp-keymap--menu-candidates (buf)
  "Palette candidates mined from BUF's menu-bar keymaps.
Returns an alist of (DISPLAY . (command . SYMBOL)), deduped by command."
  (let (result (seen (make-hash-table :test 'eq)))
    (dolist (menu (eabp-keymap--menu-maps buf))
      (dolist (entry (eabp-keymap--menu-entries menu))
        (let* ((path (nth 0 entry))
               (help (nth 1 entry))
               (cmd (nth 2 entry))
               (display (if (and (stringp help) (not (string-empty-p help)))
                            (format "%s — %s" path (car (split-string help "\n" t)))
                          path)))
          (unless (or (gethash cmd seen) (memq cmd eabp-keymap-denylist))
            (puthash cmd t seen)
            (push (cons display (cons 'command cmd)) result)))))
    (nreverse result)))

;; ─── Command palette (Tier 0 default) ──────────────────────────────────────

(defun eabp-keymap--palette-candidates (buf)
  "Alist of (DISPLAY . TARGET) for BUF's key bindings and menu items.
TARGET is (key . KEY-DESC) for a keybinding or (command . SYMBOL) for a
menu-derived entry.  Keybindings come first (they carry the shortcut), then
the human-labeled menu entries."
  (with-current-buffer buf
    (append
     (mapcar (lambda (b)
               (pcase-let ((`(,key ,cmd ,_source) b))
                 (cons (format "%s  ·  %s" key (eabp-keymap--command-label cmd))
                       (cons 'key key))))
             (eabp-keymap--extract-bindings buf))
     (eabp-keymap--menu-candidates buf))))

(defun eabp-keymap--show-palette (buf)
  "Show a searchable command palette for BUF's keybindings and menu items.
Runs inside an action handler, so `completing-read' is bridged to the
companion as a live-filtering picker dialog.  A key binding is executed as
its key (so an activated transient opens its Tier 1 pie); a menu entry —
which may carry no key — is run by command symbol."
  (let* ((candidates (eabp-keymap--palette-candidates buf))
         (choice (cond
                  ((null candidates)
                   (message "EABP keymap: no bindings extracted from %s"
                            (buffer-name buf))
                   nil)
                  (t (condition-case nil
                         (completing-read
                          (format "%s commands" (buffer-name buf))
                          (mapcar #'car candidates) nil t)
                       (quit nil)))))
         (target (cdr (assoc choice candidates))))
    (pcase target
      (`(key . ,key) (eabp-keymap--execute-key buf key))
      (`(command . ,cmd) (eabp-keymap--execute-command buf cmd)))))

;; ─── Key execution & pie-menu sync ──────────────────────────────────────────

(defun eabp-keymap--sync-pie (buf)
  "Reconcile the companion's radial overlay with transient state.
A live transient keeps (or opens) its Tier 1 pie menu; anything else
dismisses the overlay — so the pie can never linger after the command
it belonged to has finished."
  (if (eabp-keymap--transient-active-p)
      (eabp-send "pie_menu.show" (eabp-keymap--build-pie-spec buf))
    (eabp-send "pie_menu.dismiss" nil)))

(defun eabp-keymap--execute-key (buf key)
  "Execute KEY in BUF, then sync the pie menu and refresh the surface."
  (with-current-buffer buf
    (condition-case err
        (execute-kbd-macro (kbd key))
      (error
       (message "EABP keymap: %s failed: %s" key (error-message-string err)))))
  (eabp-keymap--sync-pie buf)
  (when (functionp eabp-buffer-refresh-function)
    (funcall eabp-buffer-refresh-function)))

(defun eabp-keymap--execute-command (buf cmd)
  "Run CMD interactively in BUF, then sync the pie menu and refresh the surface.
Menu entries may carry no key sequence, so they dispatch by symbol; any
minibuffer prompt CMD raises is bridged as always."
  (with-current-buffer buf
    (condition-case err
        (call-interactively cmd)
      (error
       (message "EABP keymap: %s failed: %s" cmd (error-message-string err)))))
  (eabp-keymap--sync-pie buf)
  (when (functionp eabp-buffer-refresh-function)
    (funcall eabp-buffer-refresh-function)))

;; ─── Action handlers ───────────────────────────────────────────────────────

(eabp-defaction "eabp.keymap.show"
  (lambda (args _)
    (let* ((buffer-name (or (alist-get 'buffer args)
                            (and (bound-and-true-p eabp-emacs-ui--viewing-buffer)
                                 eabp-emacs-ui--viewing-buffer)
                            (buffer-name (current-buffer))))
           (buf (get-buffer buffer-name)))
      (cond
       ((not buf)
        (message "EABP keymap: no such buffer %s" buffer-name))
       ;; Tier 1: a live transient has curated labels and a small, bounded
       ;; suffix set — exactly what the radial menu is good at.
       ((eabp-keymap--transient-active-p)
        (eabp-send "pie_menu.show" (eabp-keymap--build-pie-spec buf)))
       ;; Tier 1: a curated pie registered for this major mode (e.g. magit).
       ((when-let ((builder (eabp-keymap--tier1-builder buf)))
          (eabp-send "pie_menu.show" (funcall builder buf))
          t))
       ;; Tier 0 default: the searchable command palette.
       (t (eabp-keymap--show-palette buf))))))

(eabp-defaction "eabp.keymap.run"
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
                (eabp-keymap--run-transient-key key))
               ;; Known transient prefix: invoke the prefix first, then the suffix
               (transient-prefix-name
                (let ((prefix-cmd (intern-soft transient-prefix-name)))
                  (when (commandp prefix-cmd)
                    ;; Call the prefix to activate the transient
                    (call-interactively prefix-cmd)
                    ;; Now run the suffix key in the transient
                    (when (eabp-keymap--transient-active-p)
                      (eabp-keymap--run-transient-key key)))))
               ;; Normal key dispatch
               (t
                (execute-kbd-macro (kbd key))))
            (error
             (message "EABP keymap.run %s failed: %s" key
                      (error-message-string err)))))
        ;; Keep the overlay honest: still-active transient re-shows its pie
        ;; (with fresh infix values); a finished one dismisses it.
        (eabp-keymap--sync-pie buf)
        ;; Re-push the surface
        (when (functionp eabp-buffer-refresh-function)
          (funcall eabp-buffer-refresh-function))))))

(defun eabp-keymap--run-transient-key (key)
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

(eabp-defaction "eabp.keymap.dismiss"
  (lambda (_ _)
    (eabp-send "pie_menu.dismiss" nil)))

(provide 'eabp-keymap)
;;; eabp-keymap.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-sync.el
;;; ==================================================================

;;; eabp-sync.el --- Live editor-buffer sync + diagnostics push -*- lexical-binding: t; -*-

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
;;   * slim completion — eabp-complete.el completes at a bare cursor offset
;;   * diagnostics — flymake runs in the shadow and changed diagnostics are
;;     pushed as `diagnostics.show' frames (squiggles on the phone)
;; Eldoc and eglot-managed shadows are the planned next passengers.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'bytecomp)   ; the in-process elisp backend let-binds its variables
(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-buffer)  ; face→span-style resolution for fontify pushes

(defcustom eabp-sync-diagnostics t
  "When non-nil, run flymake over synced editor buffers and push results.
Each check may spawn a subprocess (elisp byte-compile, external linters),
which costs CPU on the machine running Emacs — set to nil on battery-
constrained setups to keep sync (and completion) without diagnostics."
  :type 'boolean :group 'eabp)

(defcustom eabp-sync-diagnostics-delay 3.0
  "Seconds after an edit before collected diagnostics are pushed.
Long enough for flymake's own no-changes timeout plus a typical backend
run; each new delta re-arms the timer, so pushes happen once per pause
in typing, not once per delta."
  :type 'number :group 'eabp)

(defcustom eabp-sync-eldoc t
  "When non-nil, answer the editor's caret reports with eldoc content.
The phone shows the result (e.g. an elisp function signature with the
current argument) in a line above the keyboard.  Only synchronous
eldoc backends contribute; async ones (LSP) land with the eglot phase."
  :type 'boolean :group 'eabp)

(defcustom eabp-sync-fontify t
  "When non-nil, push Emacs's own fontification to the phone editor.
After each edit the session buffer is font-locked and its face runs
ship as a `fontify.show' frame — so the editor shows the user's real
theme and every mode Emacs can highlight, with the client-side
highlighter only bridging the moments between keystroke and reply.
Set to nil to fall back to client-side highlighting entirely."
  :type 'boolean :group 'eabp)

(defcustom eabp-sync-fontify-max-chars 65536
  "Buffers larger than this skip fontify pushes.
Whole-buffer fontification and run extraction happen synchronously in
the delta handler; past this size the client-side highlighter is the
better trade."
  :type 'integer :group 'eabp)

(defcustom eabp-sync-eglot t
  "When non-nil, LSP-able files sync into their real buffers with eglot.
Files whose mode is in `eabp-sync-eglot-modes' are visited for real
\(`find-file-noselect') instead of shadowed in memory, and `eglot-ensure'
runs there — so the language server sees true paths and project roots,
and every phone edit becomes an incremental didChange.  Servers must be
findable on `exec-path' (on Android, Termux's usr/bin via the shared-uid
build)."
  :type 'boolean :group 'eabp)

(defcustom eabp-sync-eglot-modes
  '(python-mode python-ts-mode sh-mode bash-ts-mode
    c-mode c-ts-mode c++-mode c++-ts-mode rust-mode rust-ts-mode)
  "Major modes whose files use the real-buffer + eglot session strategy.
Everything else uses the hidden in-memory shadow (elisp and org never
need a language server; their in-process backends are better)."
  :type '(repeat symbol) :group 'eabp)

(defvar eabp-sync-shadow-setup-hook nil
  "Hook run in each freshly created shadow buffer, after its major mode.
Shadows are initialized with `delay-mode-hooks', so ordinary mode hooks
— and any buffer-local capfs or eldoc functions your init adds there —
never run.  Use this hook to opt specific setup back in, e.g.:

  (add-hook \\='eabp-sync-shadow-setup-hook
            (lambda ()
              (when (derived-mode-p \\='org-mode)
                (add-hook \\='completion-at-point-functions
                          #\\='my/org-tag-completion nil t))))

Runs for both the session shadows here and the v1 completion shadows.")

;; ─── Session registry ────────────────────────────────────────────────────────

(defvar eabp-sync--sessions (make-hash-table :test 'equal)
  "Map of file -> session plist.
Keys: :session (phone-chosen id), :seq (last applied delta), :stale
\(mismatch seen; swallow deltas until re-open), :collect-timer,
:last-diags (last pushed diagnostics, or the symbol `unset').")

(defun eabp-sync--buffer-name (file)
  (format " *eabp-sync: %s*" file))

(defun eabp-sync--mode-for (file)
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

(defvar-local eabp-sync--prepared nil
  "Non-nil once a real-file session buffer has been prepared.")

(defun eabp-sync--eglot-file-p (file)
  "Non-nil when FILE should sync into its real buffer under eglot."
  (and eabp-sync-eglot
       (memq (eabp-sync--mode-for file) eabp-sync-eglot-modes)
       (file-exists-p file)
       (require 'eglot nil t)))

(declare-function eglot-current-server "eglot")
(declare-function eglot--guess-contact "eglot")
(declare-function eglot--connect "eglot")
(defvar eglot-sync-connect)

(defvar-local eabp-sync--eglot-attempt 0
  "When the last eglot connect attempt started, as a float-time.")

(defun eabp-sync--ensure-eglot ()
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
             (> (- (float-time) eabp-sync--eglot-attempt) 30))
    (setq eabp-sync--eglot-attempt (float-time))
    (condition-case err
        (let ((eglot-sync-connect nil))
          (apply #'eglot--connect (eglot--guess-contact)))
      (error
       (when (bound-and-true-p eabp-complete-debug)
         (message "EABP sync: eglot connect failed: %s"
                  (error-message-string err)))))))

(defun eabp-sync--prepare-real-buffer (buf)
  "Per-open session setup for a real file buffer BUF; returns BUF.
The buffer-local pieces run once; the eglot connect attempt runs on
every open, so a server the OS reaped while backgrounded comes back
the next time the file is opened on the phone."
  (with-current-buffer buf
    (unless eabp-sync--prepared
      (setq eabp-sync--prepared t)
      ;; Phone keystrokes must not litter #autosave# files; the phone's
      ;; explicit Save owns persistence.
      (setq-local buffer-auto-save-file-name nil)
      (run-hooks 'eabp-sync-shadow-setup-hook))
    (eabp-sync--ensure-eglot))
  buf)

(defun eabp-sync--buffer (file)
  "Get or create the session buffer for FILE.
LSP-able files (`eabp-sync-eglot-modes') sync into their REAL buffer via
`find-file-noselect', so eglot sees true paths and project roots and
every applied delta becomes an incremental didChange.  Everything else
gets the hidden in-memory shadow: right major mode for live capfs and
flymake backends, `delay-mode-hooks' so no heavyweight tooling attaches,
leading-space name so it stays out of buffer lists."
  (if (eabp-sync--eglot-file-p file)
      (eabp-sync--prepare-real-buffer (find-file-noselect file))
    (eabp-sync--hidden-shadow file)))

(defun eabp-sync--hidden-shadow (file)
  "Get or create the hidden in-memory shadow buffer for FILE."
  (let ((name (eabp-sync--buffer-name file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          ;; A mode whose init signals (heavier modes can, on the Android
          ;; build) must not take the whole session down with it — fall
          ;; back to fundamental-mode, where word completion still works.
          (condition-case err
              (delay-mode-hooks (funcall (eabp-sync--mode-for file)))
            (error
             (message "EABP sync: %s init failed (%s); shadow is fundamental"
                      (eabp-sync--mode-for file) (error-message-string err))
             (delay-mode-hooks (fundamental-mode))))
          (when (derived-mode-p 'emacs-lisp-mode)
            (setq-local eabp-sync--elisp-repl
                        (and (member file eabp-sync-elisp-repl-files) t))
            ;; The stock backend spawns a second Emacs, which the Android
            ;; port cannot do (Emacs there is a shared library inside an
            ;; app process, not a spawnable executable) — swap in the
            ;; in-process backend (see `eabp-sync--flymake-elisp').
            (remove-hook 'flymake-diagnostic-functions
                         #'elisp-flymake-byte-compile t)
            (add-hook 'flymake-diagnostic-functions
                      #'eabp-sync--flymake-elisp nil t))
          (run-hooks 'eabp-sync-shadow-setup-hook)
          (current-buffer)))))

(defun eabp-sync-session (file)
  "Return FILE's live session plist, or nil when absent or stale."
  (let ((st (gethash file eabp-sync--sessions)))
    (and st (not (plist-get st :stale)) st)))

(defun eabp-sync-session-buffer (file session seq)
  "Return FILE's session buffer when SESSION and SEQ match the live state.
This is the gate the slim completion path uses: a match guarantees the
buffer text is exactly what the phone editor shows."
  (let* ((st (eabp-sync-session file))
         (buf (and st (plist-get st :buffer))))
    (and st
         (equal session (plist-get st :session))
         (equal seq (plist-get st :seq))
         (buffer-live-p buf)
         buf)))

;; ─── Resync ──────────────────────────────────────────────────────────────────

(defun eabp-sync-request-resync (file session)
  "Mark FILE's session stale and ask the phone for a fresh edit.open.
Stale sessions swallow further deltas silently, so one desync costs one
resync frame, not one per queued delta."
  (let ((st (gethash file eabp-sync--sessions)))
    (if st
        (puthash file (plist-put st :stale t) eabp-sync--sessions)
      ;; Unknown file (e.g. Emacs restarted mid-session): a stale
      ;; placeholder absorbs the rest of the in-flight delta burst.
      (puthash file (list :session session :seq -1 :stale t)
               eabp-sync--sessions)))
  (eabp-send "edit.resync" `((id . ,file) (session . ,session))))

;; ─── Diagnostics ─────────────────────────────────────────────────────────────

(defun eabp-sync--severity (type)
  "Map a flymake diagnostic TYPE to \"error\", \"warning\", or \"note\"."
  (pcase (condition-case nil
             (flymake--lookup-type-property type 'flymake-category)
           (error nil))
    ('flymake-error "error")
    ('flymake-note "note")
    (_ "warning")))

(defun eabp-sync--collect-and-push (file)
  "Push FILE's current flymake diagnostics if they changed since last push.
Positions go out as 0-based code-point offsets (buffer position - 1);
the frame carries the seq they were computed against so the phone can
refuse to draw squiggles over text that has moved on."
  (let* ((st (eabp-sync-session file))
         (buf (and st (plist-get st :buffer))))
    (when (and st (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((diags (mapcar
                       (lambda (d)
                         `((beg . ,(1- (flymake-diagnostic-beg d)))
                           (end . ,(1- (flymake-diagnostic-end d)))
                           (type . ,(eabp-sync--severity
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
                       eabp-sync--sessions)
              (eabp-send "diagnostics.show"
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
                       eabp-sync--sessions)
              (when (< quiet 3)
                (puthash file
                         (plist-put st :collect-timer
                                    (run-at-time eabp-sync-diagnostics-delay
                                                 nil
                                                 #'eabp-sync--collect-and-push
                                                 file))
                         eabp-sync--sessions)))))))))

(defun eabp-sync--arm-diagnostics (file)
  "(Re)arm FILE's diagnostics collection after an edit.
Enables flymake in the shadow on first use (only when the mode installed
real backends — an org or plain-text shadow never spawns checkers), then
schedules one collect+push `eabp-sync-diagnostics-delay' out.  Repeated
deltas keep pushing the timer back, so diagnostics cost one flymake pass
per pause in typing."
  (when eabp-sync-diagnostics
    (let* ((st (eabp-sync-session file))
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
        (puthash file (plist-put st :quiet-collects 0) eabp-sync--sessions)
        (puthash file
                 (plist-put st :collect-timer
                            (run-at-time eabp-sync-diagnostics-delay nil
                                         #'eabp-sync--collect-and-push file))
                 eabp-sync--sessions)))))

;; ─── Eldoc ───────────────────────────────────────────────────────────────────

(defun eabp-sync--format-docs (docs)
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

(defun eabp-sync--eldoc-deliver (file session docs)
  "Push DOCS for FILE's SESSION as an eldoc.show frame, deduped.
Safe to call any number of times per caret round — synchronous
backends deliver during the handler, async ones (LSP hover) whenever
their reply lands; the phone simply renders the latest.  Transitions
to empty push too, so the doc line clears when the cursor leaves."
  (let ((st (eabp-sync-session file)))
    (when (and st (equal session (plist-get st :session)))
      (let ((text (eabp-sync--format-docs docs)))
        (unless (equal text (plist-get st :last-eldoc))
          (puthash file (plist-put st :last-eldoc text)
                   eabp-sync--sessions)
          (eabp-send "eldoc.show"
                     `((id . ,file)
                       (session . ,session)
                       (text . ,(or text "")))))))))

(defun eabp-sync--run-eldoc (file session)
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
                                    (eabp-sync--eldoc-deliver
                                     file session docs))))))
             (when (stringp r) (push (cons r nil) docs)))
         (error nil))
       nil))                            ; nil → run every backend
    (eabp-sync--eldoc-deliver file session docs)))

(eabp-defaction "edit.caret"
  ;; Best-effort by design: a mismatched session/seq (the caret raced a
  ;; delta) just yields nothing — the delta path owns resync, and the
  ;; next caret report lands on fresh state anyway.
  (lambda (args _)
    (when eabp-sync-eldoc
      (let ((file (alist-get 'file args))
            (session (alist-get 'session args))
            (seq (alist-get 'seq args))
            (cursor (alist-get 'cursor args)))
        (when (and (stringp file) (numberp session)
                   (numberp seq) (numberp cursor))
          (when-let ((buf (eabp-sync-session-buffer file session seq)))
            (with-current-buffer buf
              (save-excursion
                (goto-char (min (1+ (max 0 (truncate cursor)))
                                (point-max)))
                (eabp-sync--run-eldoc file session)))))))))

;; ─── In-process elisp flymake backend ────────────────────────────────────────
;;
;; `elisp-flymake-byte-compile' isolates compilation in a freshly spawned
;; "emacs -batch".  On the Android port there is no Emacs executable to
;; spawn — Emacs is a shared library inside an app process — and Android's
;; phantom-process killer reaps background children anyway.  So elisp
;; shadows use this backend instead: a paren-balance scan plus an
;; in-process `byte-compile-file' over a temp copy.  Same warnings, no
;; subprocess, and instant even on slow devices.

(defvar eabp-sync-elisp-repl-files nil
  "Editor ids whose elisp shadows hold REPL input rather than a file.
REPL input is evaluated with lexical binding (`eval' with LEXICAL t),
so these shadows byte-compile their diagnostics copy with a
`lexical-binding: t' cookie line prepended: warnings match eval
semantics, and the no-cookie warning — noise against a one-expression
REPL line — can never fire.  Views register their editor id here (the
eval REPL adds \"eval.el\").")

(defvar-local eabp-sync--elisp-repl nil
  "Non-nil in the session shadow of an `eabp-sync-elisp-repl-files' entry.")

(defun eabp-sync--elisp-paren-diags ()
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

(defun eabp-sync--elisp-compile-diags ()
  "In-process byte-compile diagnostics for the current buffer.
Compiles a temp copy so nothing touches the user's files.  File shadows
copy the text verbatim, so warning positions map straight back; REPL
shadows (`eabp-sync--elisp-repl') get a `lexical-binding: t' cookie
line prepended — matching how the REPL evaluates — and positions are
shifted back by the cookie's length."
  (let* ((cookie (if eabp-sync--elisp-repl
                     ";;; -*- lexical-binding: t; -*-\n"
                   ""))
         (shift (length cookie))
         (src (concat cookie (buffer-substring-no-properties
                              (point-min) (point-max))))
         (buf (current-buffer))
         (tmp (make-temp-file "eabp-flymake" nil ".el"))
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

(defun eabp-sync--flymake-elisp (report-fn &rest _)
  "Flymake backend for elisp shadow buffers: no subprocesses, ever.
Reports unbalanced parens directly (byte-compiling unbalanced input
yields one useless end-of-file error), otherwise in-process compile
warnings — wrong arity, unused lexical variables, undefined functions."
  (funcall report-fn
           (or (eabp-sync--elisp-paren-diags)
               (eabp-sync--elisp-compile-diags))))

;; ─── LSP publish → immediate collect ─────────────────────────────────────────
;;
;; The polling chase alone loses a race on cold servers: pylsp's first
;; publish on a phone can take longer than the quiet-round budget, and a
;; publish that lands after the chain stopped went nowhere until the next
;; keystroke.  Event-driven instead: the moment eglot receives a
;; publishDiagnostics notification for a synced file, collect shortly
;; after (the small delay lets eglot hand the report to flymake first).

(defun eabp-sync--session-for-path (path)
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
               eabp-sync--sessions))
    found))

(with-eval-after-load 'eglot
  (cl-defmethod eglot-handle-notification :after
    (_server (_method (eql textDocument/publishDiagnostics))
             &key uri &allow-other-keys)
    "Collect for the synced file the server just diagnosed."
    (when eabp-sync-diagnostics
      (when-let* ((path (ignore-errors
                          (if (fboundp 'eglot-uri-to-path)
                              (eglot-uri-to-path uri)
                            (eglot--uri-to-path uri))))
                  (file (eabp-sync--session-for-path path)))
        (run-at-time 0.5 nil #'eabp-sync--collect-and-push file)))))

;; ─── Fontification push ──────────────────────────────────────────────────────
;;
;; The other direction of "Emacs owns styling": the same face→span
;; resolution Tier 0 uses for read-only buffers, applied to the live
;; editor.  After each applied delta the session buffer is font-locked
;; and its face runs ship to the phone as 0-based code-point ranges.
;; The phone renders them whenever its text matches the stamped seq and
;; falls back to its client-side highlighter in the gaps — Emacs colors
;; at rest, approximation only while a keystroke is in flight.

(defun eabp-sync--fontify-runs ()
  "Face runs for the current buffer as wire alists.
Each run is ((b . BEG) (e . END) [(c . \"#RRGGBB\")] [(bold . t)] ...)
with 0-based code-point offsets.  Unstyled stretches ship nothing."
  (ignore-errors (font-lock-ensure))
  (let ((eabp-buffer--default-fg-hex
         (eabp-buffer--color-hex (face-attribute 'default :foreground nil t)))
        (eabp-buffer--default-bg-hex
         (eabp-buffer--color-hex (face-attribute 'default :background nil t)))
        (pos (point-min))
        runs)
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos 'face nil (point-max)))
            (style (eabp-buffer--span-style (get-text-property pos 'face))))
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

(defun eabp-sync--push-fontify (file)
  "Push FILE's current fontification, seq-stamped and deduped.
Like diagnostics, the stamp includes the seq: identical runs after an
edit still re-push, because the phone hides anything stamped stale."
  (when eabp-sync-fontify
    (let* ((st (eabp-sync-session file))
           (buf (and st (plist-get st :buffer))))
      (when (and st (buffer-live-p buf)
                 (<= (buffer-size buf) eabp-sync-fontify-max-chars))
        (with-current-buffer buf
          (let* ((runs (eabp-sync--fontify-runs))
                 (stamp (cons (plist-get st :seq) runs)))
            (unless (equal stamp (plist-get st :last-fontify))
              (puthash file (plist-put st :last-fontify stamp)
                       eabp-sync--sessions)
              (eabp-send "fontify.show"
                         `((id . ,file)
                           (session . ,(plist-get st :session))
                           (seq . ,(plist-get st :seq))
                           (runs . ,(vconcat runs)))))))))))

;; ─── Delta application ───────────────────────────────────────────────────────

(defun eabp-sync-open (file session text)
  "Seed (or reseed) FILE's session buffer with TEXT under SESSION, seq 0."
  (let ((buf (eabp-sync--buffer file)))
    (with-current-buffer buf
      ;; Real-file buffers usually already hold exactly this text (the
      ;; phone was seeded from them) — skip the no-op replacement so the
      ;; buffer isn't marked modified and eglot sees no phantom change.
      (unless (and (= (buffer-size) (length text))
                   (equal (buffer-string) text))
        (erase-buffer)
        (insert text)))
    (let ((old (gethash file eabp-sync--sessions)))
      (when-let ((tm (and old (plist-get old :collect-timer))))
        (cancel-timer tm)))
    ;; `unset' (not nil) so the first collect always pushes — the phone may
    ;; have dropped its diagnostics when it re-opened.
    (puthash file (list :session session :seq 0 :buffer buf
                        :last-diags 'unset)
             eabp-sync--sessions))
  (eabp-sync--arm-diagnostics file)
  (eabp-sync--push-fontify file))

(defun eabp-sync-apply-delta (file session seq start del text len)
  "Apply one splice to FILE's shadow; non-nil on success.
The splice replaces DEL code points at 0-based offset START with TEXT.
Applies only when SESSION matches and SEQ is exactly one past the last
applied delta; LEN (the phone's resulting document length) is verified
after the splice.  Any mismatch triggers one resync round instead."
  (let* ((raw (gethash file eabp-sync--sessions))
         (st (and raw (not (plist-get raw :stale)) raw)))
    (cond
     ;; Already stale: the resync was requested when the mismatch was
     ;; first seen — swallow the rest of the in-flight burst silently.
     ((and raw (plist-get raw :stale)) nil)
     ((not (and st
                (equal session (plist-get st :session))
                (equal seq (1+ (plist-get st :seq)))
                (buffer-live-p (plist-get st :buffer))))
      (eabp-sync-request-resync file session)
      nil)
     (t
      (with-current-buffer (plist-get st :buffer)
        (let* ((beg (min (1+ (max 0 start)) (point-max)))
               (end (min (+ beg (max 0 del)) (point-max))))
          (delete-region beg end)
          (goto-char beg)
          (insert text))
        (if (and (numberp len) (/= (buffer-size) len))
            (progn (eabp-sync-request-resync file session) nil)
          (puthash file (plist-put st :seq seq) eabp-sync--sessions)
          (eabp-sync--arm-diagnostics file)
          (eabp-sync--push-fontify file)
          t))))))

(defun eabp-sync-close (file)
  "Tear down FILE's session: cancel timers, drop state, kill the shadow.
Only hidden in-memory shadows are killed — a real file buffer (the
eglot strategy) may belong to the user, and keeping it also keeps the
language server warm for the next open."
  (let ((st (gethash file eabp-sync--sessions)))
    (when-let ((tm (and st (plist-get st :collect-timer))))
      (cancel-timer tm)))
  (remhash file eabp-sync--sessions)
  (when-let ((buf (get-buffer (eabp-sync--buffer-name file))))
    (kill-buffer buf)))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "edit.open"
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (session (alist-get 'session args))
          (text (alist-get 'text args)))
      (when (and (stringp file) (stringp text) (numberp session))
        (eabp-sync-open file session text)
        (when (bound-and-true-p eabp-complete-debug)
          (message "EABP sync: open %s session=%s len=%d mode=%s"
                   (file-name-nondirectory file) session (length text)
                   (with-current-buffer (eabp-sync--buffer file)
                     major-mode)))))))

(eabp-defaction "edit.delta"
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
        (let ((ok (eabp-sync-apply-delta file session seq start del text len)))
          (when (bound-and-true-p eabp-complete-debug)
            (message "EABP sync: delta %s seq=%s %s"
                     (file-name-nondirectory file) seq
                     (if ok "applied" "REJECTED (resync)"))))))))

(eabp-defaction "edit.close"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (stringp file)
        (eabp-sync-close file)))))

(provide 'eabp-sync)
;;; eabp-sync.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-complete.el
;;; ==================================================================

;;; eabp-complete.el --- Completion-at-point bridge (Tier 0 IDE) -*- lexical-binding: t; -*-

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
(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-sync)

(defcustom eabp-complete-enabled t
  "When non-nil, the phone editor offers Emacs-backed completion.
Set to nil to stop the companion from issuing completion requests
entirely (the editor node is pushed without its `complete' flag)."
  :type 'boolean :group 'eabp)

(defcustom eabp-complete-max-candidates 30
  "Maximum number of candidates returned per completion request.
The phone strip shows a handful; anything past this cap is wasted
bytes on the wire."
  :type 'integer :group 'eabp)

(defcustom eabp-complete-debug nil
  "When non-nil, echo each completion request to *Messages*.
Each `edit.complete' from the phone logs the file, the prefix it
resolved, and how many candidates it returned — a live trace of the
bridge working, without a device attached to logcat.  Development aid;
leave nil in normal use."
  :type 'boolean :group 'eabp)

;; ─── Shadow buffers ──────────────────────────────────────────────────────────

(defun eabp-complete--shadow-buffer (file)
  "Get or create the hidden shadow buffer for FILE.
The buffer carries FILE's major mode so the right capfs are live, but
mode hooks are delayed: no LSP client, flycheck, or other machinery
spins up over a throwaway completion buffer.  The leading space in the
name keeps it out of buffer lists and disables undo."
  (let ((name (format " *eabp-complete: %s*" file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (condition-case nil
              (delay-mode-hooks (funcall (eabp-sync--mode-for file)))
            (error (delay-mode-hooks (fundamental-mode))))
          (run-hooks 'eabp-sync-shadow-setup-hook)
          (current-buffer)))))

;; ─── Candidate harvesting ────────────────────────────────────────────────────

(defun eabp-complete--capf-data ()
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

(defun eabp-complete--word-fallback ()
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

(defun eabp-complete--annotate (fn cand)
  "Apply annotation function FN to CAND, trimmed; nil when absent or failing."
  (when fn
    (let ((a (condition-case nil (funcall fn cand) (error nil))))
      (when (and (stringp a) (not (string-empty-p (string-trim a))))
        (string-trim a)))))

(defun eabp-complete--collect ()
  "Harvest completions at point in the current buffer.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Each candidate node is an
alist of `label' plus optional `annotation' and `kind', ready for
serialization.  Candidates are sorted shortest-first (the likeliest
next keystroke saver), capped at `eabp-complete-max-candidates'."
  (let* ((data (eabp-complete--capf-data))
         (beg (nth 0 data))
         (table (nth 2 data))
         (props (nthcdr 3 data))
         (ann-fn (plist-get props :annotation-function))
         (kind-fn (plist-get props :company-kind))
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
      (when-let ((fb (eabp-complete--word-fallback)))
        (setq prefix (car fb) cands (cdr fb) ann-fn nil kind-fn nil)))
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
                          ,@(when-let ((a (eabp-complete--annotate ann-fn c)))
                              `((annotation . ,a)))
                          ,@(when-let ((k (and kind-fn
                                               (condition-case nil
                                                   (funcall kind-fn c)
                                                 (error nil)))))
                              `((kind . ,(symbol-name k))))))
                      (seq-take cands eabp-complete-max-candidates)))))))

(defun eabp-complete-in-text (file text cursor)
  "Complete FILE's TEXT at CURSOR (a 0-based offset into TEXT).
Replays TEXT into FILE's shadow buffer and harvests candidates there.
Returns (PREFIX . CANDIDATE-NODES) or nil.  Separated from the action
handler so tests can call it directly.

This is the v1 windowed path, kept as the fallback for clients that
ship text with the request; the slim path is `eabp-complete-in-session'."
  (with-current-buffer (eabp-complete--shadow-buffer file)
    (erase-buffer)
    (insert text)
    (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
    (eabp-complete--collect)))

(defun eabp-complete-in-session (file session seq cursor)
  "Complete in FILE's synced session shadow at CURSOR (0-based code points).
The v2 slim path: no text crosses the wire because eabp-sync already
holds the whole document.  SESSION and SEQ must match the live sync
state exactly — a mismatch means the phone edited past us, so reply
nothing and ask for a resync instead of completing against stale text.
Returns (PREFIX . CANDIDATE-NODES) or nil."
  (let ((buf (eabp-sync-session-buffer file session seq)))
    (if (not buf)
        (progn (eabp-sync-request-resync file session) nil)
      (with-current-buffer buf
        (save-excursion
          (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
          (eabp-complete--collect))))))

;; ─── Action handler ──────────────────────────────────────────────────────────

;; Reply shape: the phone recomputes the replace range as
;; [cursor - length(prefix), cursor) in its own string units and validates
;; the prefix still sits there before applying — so no absolute offsets
;; cross the wire and a stale reply degrades to "strip doesn't show",
;; never to a wrong edit.
(eabp-defaction "edit.complete"
  (lambda (args _)
    (when eabp-complete-enabled
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
                                (eabp-complete-in-text file text cursor)
                              ;; v2: complete in the eabp-sync shadow.
                              (eabp-complete-in-session file session seq cursor))
                          (error (message "EABP complete failed: %s"
                                          (error-message-string err))
                                 nil))))
            (when eabp-complete-debug
              (if result
                  (message "EABP complete: %s prefix=%S -> %d candidate(s)"
                           (file-name-nondirectory file)
                           (car result) (length (cdr result)))
                (message "EABP complete: %s -> nothing to offer at cursor"
                         (file-name-nondirectory file))))
            ;; Always reply, even empty, so the phone can clear its strip.
            (eabp-send "completions.show"
                       `((id . ,file)
                         (request_id . ,(or req 0))
                         (prefix . ,(or (car result) ""))
                         (candidates . ,(vconcat (cdr result)))))))))))

(provide 'eabp-complete)
;;; eabp-complete.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-settings.el
;;; ==================================================================

;;; eabp-settings.el --- Schema-driven settings from defcustom metadata -*- lexical-binding: t; -*-

;; Renders an allowlisted set of defcustom variables as companion widgets
;; derived from their `custom-type' schemas, and applies edits through
;; Customize: candidate values are validated with the type's widget
;; `:match', set via `customize-set-variable' (so `:set' setters run),
;; and persisted via `customize-save-variable'.
;;
;; The registry is the security boundary: `settings.set' / `settings.reset'
;; only touch symbols present in `eabp-settings-registry', never arbitrary
;; names off the wire.  Exposing a new setting is one registry entry.
;; The rendering/apply machinery itself is public and gate-agnostic —
;; eabp-customize.el reuses it under its own `customize.*' actions with a
;; `custom-variable-p' gate; the registry rule above binds `settings.*' only.
;;
;; Widget mapping by type: boolean -> switch (the client switch publishes
;; state.changed rather than dispatching an action, so per-id handlers are
;; registered at load), choice-of-consts -> single-select enum list,
;; string/file/directory -> text input, integer/number -> numeric text
;; input, anything else -> a raw elisp-expression input read with `read'.

;;; Code:

(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)

(declare-function custom-file "cus-edit" (&optional no-error))

;; The host shell points these at its snackbar and dashboard push; this
;; module stays independent of any particular screen.
(defvar eabp-settings-notify-function #'message
  "Function of one string, used to surface rejections and save failures.")

(defvar eabp-settings-refresh-function #'ignore
  "Function called after a setting changes so the client re-renders.")

(defvar eabp-settings-after-set-hook nil
  "Hook run with (SYMBOL VALUE) after a setting is applied from the wire.
For propagation the defcustom's `:set' doesn't cover — e.g. an app whose
views memoise derived data registers its cache invalidation here.")

(defvar eabp-settings-registry nil
  "Sections of settings exposed to the companion.
Each element is (TITLE . ENTRIES); an entry is (SYMBOL . PLIST) where
PLIST supports :label (display name) and :after-set (function of the
new value, for propagation the defcustom's `:set' doesn't cover).
Only symbols listed here can be modified from the wire.

Empty by default: the machinery is app-agnostic, and each Tier 1 app
exposes its own variables through `eabp-settings-register-section'.")

(defun eabp-settings-register-section (title entries)
  "Register (or replace) the settings section TITLE with ENTRIES.
ENTRIES is a list of (SYMBOL . PLIST) — see `eabp-settings-registry'.
Also registers the state.changed handlers the entries' switch widgets
publish through, so a queued toggle can replay before the settings
screen has ever rendered this session."
  (setq eabp-settings-registry
        (append (assoc-delete-all title eabp-settings-registry)
                (list (cons title entries))))
  (eabp-settings--register-state-handlers (list (cons title entries))))

(defun eabp-settings--entry (sym)
  "Registry entry for SYM, or nil if SYM is not exposed."
  (cl-loop for (_title . entries) in eabp-settings-registry
           thereis (assq sym entries)))

;; ─── Persistence ─────────────────────────────────────────────────────────────

(defun eabp-settings-save-variable (symbol value)
  "Persist SYMBOL as VALUE through Customize, surfacing failures.
Returns non-nil on success.  Failures are reported through
`eabp-settings-notify-function' instead of being silently dropped;
notably, `customize-save-variable' quietly skips saving when there is
no file to save into (started with -q, or no init file), which would
otherwise look like a save and then vanish on restart."
  (require 'cus-edit)
  (condition-case err
      (if (custom-file t)
          (progn (customize-save-variable symbol value) t)
        (set-default symbol value)
        (funcall eabp-settings-notify-function
                 "Applied for this session only: no init file to save settings into")
        nil)
    (error
     (funcall eabp-settings-notify-function
              (format "Applied for this session, but saving failed: %s"
                      (error-message-string err)))
     nil)))

;; ─── Type classification ─────────────────────────────────────────────────────

(defun eabp-settings--type (sym)
  "The `custom-type' schema of SYM, or nil for plain defvars."
  (get sym 'custom-type))

(defun eabp-settings--const-option (alt)
  "If choice alternative ALT is a const, return (TAG . VALUE); else nil."
  (when (and (consp alt) (eq (car alt) 'const))
    (let ((args (cdr alt)) (tag nil))
      (while (keywordp (car args))
        (when (eq (car args) :tag)
          (setq tag (cadr args)))
        (setq args (cddr args)))
      (cons (or tag (format "%s" (car args))) (car args)))))

(defun eabp-settings--choice-options (type)
  "For a (choice ...) TYPE, alist of (TAG . VALUE) for its const arms.
Non-const arms (e.g. a free string alternative) are simply not offered;
a current value outside the consts still displays, printed."
  (delq nil (mapcar #'eabp-settings--const-option (cdr type))))

(defun eabp-settings--kind (type)
  "Classify custom TYPE into a widget kind symbol."
  (pcase (if (consp type) (car type) type)
    ('boolean 'boolean)
    ((or 'string 'regexp 'file 'directory) 'string)
    ((or 'integer 'natnum 'number 'float) 'number)
    ('choice (if (eabp-settings--choice-options type) 'choice 'raw))
    (_ 'raw)))

(defun eabp-settings--valid-p (sym value)
  "Whether VALUE structurally satisfies SYM's custom type."
  (let ((type (eabp-settings--type sym)))
    (or (null type)
        (condition-case nil
            (and (widget-apply (widget-convert type) :match value) t)
          (error nil)))))

;; ─── Setting values ──────────────────────────────────────────────────────────

(defun eabp-settings-apply (sym value &optional after-set)
  "Validate, set, propagate and persist VALUE for SYM.
AFTER-SET, when non-nil, is called with VALUE once the set has run —
the propagation a caller's gate attaches (a registry entry's
:after-set); it is the caller's because this function no longer knows
which gate admitted SYM.  Returns non-nil when the value was accepted
\(even if only applied for the session because persisting failed)."
  (if (not (eabp-settings--valid-p sym value))
      (progn
        (funcall eabp-settings-notify-function
                 (format "Invalid value for %s" sym))
        nil)
    (customize-set-variable sym value)
    (when after-set (funcall after-set value))
    ;; App views may memoise data derived from this variable; per the
    ;; cache contract every mutation must reach the registered droppers.
    (run-hook-with-args 'eabp-settings-after-set-hook sym value)
    (eabp-settings-save-variable sym value)
    t))

(defun eabp-settings--decode (sym wire)
  "Decode client-sent WIRE into a candidate value for SYM.
Returns (VALUE) on success, `skip' for a no-op (e.g. an enum
deselection), nil when undecodable."
  (let* ((type (eabp-settings--type sym))
         (kind (eabp-settings--kind type))
         (trim (lambda (s) (replace-regexp-in-string
                            "\\`[ \t\n\r]+\\|[ \t\n\r]+\\'" "" s))))
    (pcase kind
      ('choice
       (let ((tag (car (append wire nil))))
         (if (null tag)
             'skip                      ; deselect: keep the current value
           (let ((opt (assoc tag (eabp-settings--choice-options type))))
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

(defun eabp-settings-apply-wire (sym wire &optional after-set)
  "Decode client-sent WIRE and apply it to SYM; non-nil unless rejected.
An undecodable payload notifies and returns nil; a no-op (e.g. an enum
deselection) returns non-nil without touching SYM.  AFTER-SET is passed
through to `eabp-settings-apply'.  Callers gate SYM before calling —
this function validates the value, not the symbol."
  (pcase (eabp-settings--decode sym wire)
    ('skip t)
    ('nil (funcall eabp-settings-notify-function
                   (format "Invalid value for %s" sym))
          nil)
    (`(,value) (eabp-settings-apply sym value after-set))))

;; ─── Standard values / reset ─────────────────────────────────────────────────

(defun eabp-settings--standard-value (sym)
  "SYM's uncustomized default from the defcustom, evaluated."
  (let ((std (get sym 'standard-value)))
    (and std (eval (car std) t))))

(defun eabp-settings-modified-p (sym)
  "Whether SYM's current global value differs from its standard default.
Safe on any symbol: unbound means unmodified, and a standard-value form
that fails to evaluate counts as unmodified rather than erroring (the
customize browser calls this across arbitrary defcustoms)."
  (and (boundp sym)
       (get sym 'standard-value)
       (not (equal (default-value sym)
                   (condition-case nil (eabp-settings--standard-value sym)
                     (error (default-value sym)))))))

(defun eabp-settings-reset (sym &optional after-set)
  "Reset SYM to its defcustom standard value; non-nil on success.
Notifies instead of erroring when SYM has no standard value to return
to.  AFTER-SET is passed through to `eabp-settings-apply'."
  (if (not (get sym 'standard-value))
      (progn
        (funcall eabp-settings-notify-function "Cannot reset this setting")
        nil)
    (when (eabp-settings-apply sym (eabp-settings--standard-value sym) after-set)
      (funcall eabp-settings-notify-function
               (format "%s reset to default" sym))
      t)))

;; ─── Rendering ───────────────────────────────────────────────────────────────

(defun eabp-settings--doc-line (sym)
  "First line of SYM's docstring, or nil."
  (let ((doc (documentation-property sym 'variable-documentation)))
    (and doc (car (split-string (substitute-command-keys doc) "\n" t)))))

(cl-defun eabp-settings-item (sym &key label (id-prefix "setting/")
                                  (set-action "settings.set")
                                  (reset-action "settings.reset"))
  "Widget column rendering SYM's control from its `custom-type' schema.
LABEL defaults to the symbol name.  ID-PREFIX keys the control's widget
id; a switch under it publishes state.changed, so pair a non-default
prefix with `eabp-settings-watch-toggle'.  SET-ACTION and RESET-ACTION
name the wire actions the controls dispatch, each carrying the symbol
name under `name' — the settings screen uses the registry-gated
`settings.*', the customize browser the `custom-variable-p'-gated
`customize.*'."
  (if (not (boundp sym))
      (eabp-text (format "%s is not loaded yet" sym) 'caption)
    (let* ((name (symbol-name sym))
           (label (or label name))
           (doc (eabp-settings--doc-line sym))
           (value (default-value sym))
           (type (eabp-settings--type sym))
           (kind (eabp-settings--kind type))
           (wid-id (concat id-prefix name))
           (set (eabp-action set-action :args `((name . ,name))))
           (reset (and (eabp-settings-modified-p sym)
                       (eabp-icon-button
                        "history"
                        (eabp-action reset-action :args `((name . ,name)))
                        :content-description (format "Reset %s to default" label))))
           (control
            (pcase kind
              ('boolean
               (eabp-switch wid-id :checked (and value t) :label label))
              ('choice
               (let* ((opts (eabp-settings--choice-options type))
                      (current (car (rassoc value opts)))
                      (labels (mapcar #'car opts)))
                 (unless current
                   ;; Value set outside the const arms (e.g. a custom
                   ;; drawer name): show it, printed, as the selection.
                   (setq current (prin1-to-string value)
                         labels (append labels (list current))))
                 (eabp-enum-list wid-id labels :value (list current)
                                 :on-change set)))
              ('string
               (eabp-text-input wid-id :value (and (stringp value) value)
                                :label label :single-line t
                                :on-submit set))
              ('number
               (eabp-text-input wid-id
                                :value (and (numberp value)
                                            (number-to-string value))
                                :label label :single-line t
                                :on-submit set))
              (_
               (eabp-text-input wid-id :value (prin1-to-string value)
                                :label label :single-line t :monospace t
                                :hint "Elisp expression"
                                :on-submit set)))))
      (apply #'eabp-column
             (delq nil
                   (list
                    ;; Booleans carry their label inside the switch row;
                    ;; everything else gets a plain label row. The weighted
                    ;; box keeps the reset button on-screen (columns render
                    ;; fillMaxWidth and would swallow the row).
                    (eabp-row
                     (eabp-box (list (if (eq kind 'boolean)
                                         control
                                       (eabp-text label 'label)))
                               :weight 1)
                     reset)
                    (when doc (eabp-text doc 'caption))
                    (unless (eq kind 'boolean) control)))))))

(defun eabp-settings--item (entry)
  "Widget column for registry ENTRY."
  (eabp-settings-item (car entry) :label (plist-get (cdr entry) :label)))

(defvar eabp-settings-links nil
  "Ordered list of (ORDER . BUILDER) navigation entries for the settings screen.
BUILDER is a nullary function returning a node (usually a tappable card
leading to another screen).  Apps register their satellite screens here
— the package browser, the customize browser — instead of each claiming
a drawer slot; `eabp-settings-sections' renders them under a trailing
\"Emacs\" section.")

(defun eabp-settings-add-link (order builder)
  "Add BUILDER (a nullary node builder) to the settings screen at ORDER."
  (setq eabp-settings-links
        (sort (cons (cons order builder) eabp-settings-links)
              (lambda (a b) (< (car a) (car b))))))

(defun eabp-settings-sections ()
  "Flat list of nodes rendering every registry section, then the links."
  (append
   (cl-loop for (title . entries) in eabp-settings-registry
            append (append (list (eabp-divider)
                                 (eabp-section-header title))
                           (mapcar #'eabp-settings--item entries)))
   (when eabp-settings-links
     (append (list (eabp-divider) (eabp-section-header "Emacs"))
             (mapcar (lambda (e) (funcall (cdr e))) eabp-settings-links)))))

;; ─── Actions and state handlers ──────────────────────────────────────────────

(eabp-defaction "settings.set"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (eabp-settings--entry sym))))
      (if (not entry)
          (funcall eabp-settings-notify-function
                   (format "Setting %s is not editable from the app"
                           (or name "?")))
        (eabp-settings-apply-wire sym (alist-get 'value args)
                                  (plist-get (cdr entry) :after-set)))
      (funcall eabp-settings-refresh-function))))

(eabp-defaction "settings.reset"
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (sym (and (stringp name) (intern-soft name)))
           (entry (and sym (eabp-settings--entry sym))))
      (if (not entry)
          (funcall eabp-settings-notify-function "Cannot reset this setting")
        (eabp-settings-reset sym (plist-get (cdr entry) :after-set)))
      (funcall eabp-settings-refresh-function))))

(defun eabp-settings-watch-toggle (sym id &optional after-set)
  "Register the state.changed handler applying SYM's switch under widget ID.
The client's switch widget publishes state.changed instead of
dispatching an action, so a boolean setting only works once a handler
exists for its widget id.  Non-boolean payloads under ID (e.g. a text
input's published state) are ignored; those save through their submit
action instead.  AFTER-SET is passed through to `eabp-settings-apply'."
  (eabp-on-state-change
   id (lambda (val)
        (when (memq val '(t :false))
          (eabp-settings-apply sym (eq val t) after-set)
          (funcall eabp-settings-refresh-function)))))

(defun eabp-settings--register-state-handlers (sections)
  "Register the switch handlers for every symbol in SECTIONS.
A queued toggle can replay before the settings screen has ever rendered
this session — so handlers are registered when the section is, not at
render."
  (dolist (section sections)
    (dolist (entry (cdr section))
      (eabp-settings-watch-toggle
       (car entry)
       (concat "setting/" (symbol-name (car entry)))
       (plist-get (cdr entry) :after-set)))))

(provide 'eabp-settings)
;;; eabp-settings.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-files.el
;;; ==================================================================

;;; eabp-files.el --- File browser & editor for EABP -*- lexical-binding: t; -*-

;; A dired-style file browser plus a plain-text editor, rendered through
;; EABP surfaces. Together with the eval tab this is the self-hosting
;; plumbing: init.el (and anything else) can be edited, saved, and
;; reloaded from the phone, so the desktop side never needs touching
;; once eabp is in the init file.
;;
;; Registers two shell views:
;;   "files" — root list / directory listing (a bottom-bar tab)
;;   "edit"  — editor for `eabp-files--file' (present while a file is open)
;;
;; App seams — this module knows nothing about org (or any file type):
;;   `eabp-files-editor-body-functions'    replace the editor body per file
;;   `eabp-files-editor-actions-functions' add top-bar buttons per file
;;   `eabp-files-open-hook'                react to a file being opened
;;   `eabp-files-after-save-hook'          react to a phone-side save

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer) ; Tier 0 renderer + the major-mode→skin registry
(require 'eabp-complete) ; capf bridge: the editor's `complete' flag
(require 'eabp-shell)
(require 'dired)
(require 'cl-lib)

(defcustom eabp-files-roots
  `(("Config" . ,user-emacs-directory)
    ("Org"    . ,(or (and (boundp 'org-directory) org-directory) "~/org/"))
    ("Home"   . "~/"))
  "Root directories the Files browser is confined to.
Navigation, opening, and file operations are all refused outside these
roots (`eabp-files--within-root-p').  Labels are unused now that the Files
view lands directly in `eabp-files-default-dir' rather than on a roots list,
but the alist shape is kept for back-compatibility."
  :type '(alist :key-type string :value-type directory)
  :group 'eabp)

(defcustom eabp-files-default-dir "~/"
  "Directory the Files tab opens to (and the navigation ceiling).
Must lie within `eabp-files-roots'.  The Files view shows this directory's
full listing — the same view you get from the Buffers tab on its dired
buffer — instead of a separate shortcut screen."
  :type 'directory :group 'eabp)

(defcustom eabp-files-max-bytes (* 256 1024)
  "Files larger than this open read-only.
Editor saves travel inside a broadcast intent on the companion side,
which has a hard payload ceiling (~500 KB across all extras), so big
files must not round-trip through the editor."
  :type 'integer :group 'eabp)

(defvar eabp-files--dir nil
  "Directory being browsed, or nil for the landing dir (`eabp-files-default-dir').")

(defvar eabp-files--file nil
  "Absolute path of the file open in the editor, or nil.")

;; ─── App seams ───────────────────────────────────────────────────────────────

(defvar eabp-files-editor-body-functions nil
  "Abnormal hook: functions of FILE returning the editor view's body, or nil.
Tried in order before the plain-text editor; the first non-nil result
wins.  Apps register alternate renderings here (e.g. a foldable outline
reader for their file type).")

(defvar eabp-files-editor-actions-functions nil
  "Abnormal hook: functions of FILE returning top-bar action nodes.
The returned lists are appended into the editor view's top bar; apps add
their per-file-type buttons (mode toggles, metadata dialogs) here.")

(defvar eabp-files-open-hook nil
  "Hook run with FILE when the phone opens it in the editor.
Apps set their per-file-type editor state here (e.g. reader-first).")

(defvar eabp-files-after-save-hook nil
  "Hook run with FILE after a phone-triggered save succeeds.
Apps whose views memoise data derived from files drop caches here.")

(defvar eabp-files-editor-toolbar-function #'ignore
  "Function of FILE returning the editor toolbar name to request, or nil.
Apps point this at their file-type mapping (e.g. \"org\" for org files)
so the toolbar choice ships in the editor spec instead of being inferred
client-side.")

;; ─── Browser view (dired under the hood) ─────────────────────────────────────

;; The directory listing is backed by a real dired buffer — the standard Emacs
;; file engine — but presented through a card skin registered for
;; `dired-mode'.  So the same buffer renders as touch cards here and as a raw,
;; faithful listing from the Buffers tab: Tier 0 and Tier 1 over one model.
;; The Files tab lands directly in `eabp-files-default-dir' (no separate roots
;; screen) so it matches the full listing you get from the Buffers tab.

(defun eabp-files--within-root-p (path)
  "Non-nil when PATH is inside (or is) one of `eabp-files-roots'.
Uses `file-in-directory-p', which compares path components — a bare
string-prefix check would let root \"~/org\" authorize \"~/org-secrets\",
and this predicate is the security boundary for every file operation
the phone can trigger."
  (let ((full (expand-file-name path)))
    (cl-some (lambda (root)
               (file-in-directory-p full (expand-file-name (cdr root))))
             eabp-files-roots)))

(defun eabp-files--entry-menu (path)
  "Overflow menu of single-file operations for PATH.
Each item is an allowlisted action (see the command-dispatch boundary): the
handler runs one specific, root-guarded operation — never arbitrary dispatch."
  (eabp-menu
   (list
    (eabp-menu-item "Rename"
                    (eabp-action "files.rename" :args `((file . ,path)))
                    :icon "edit")
    (eabp-menu-item "Delete"
                    (eabp-action "files.delete" :args `((file . ,path)))
                    :icon "delete"))))

(defun eabp-files--card-for (path)
  "A tappable card for PATH — a folder (cd) or a file (open), with an op menu."
  (if (file-directory-p path)
      (eabp-card
       (list (eabp-row
              (eabp-icon "folder")
              (eabp-box (list (eabp-text (file-name-nondirectory
                                          (directory-file-name path))
                                         'body))
                        :weight 1)
              (eabp-files--entry-menu path)))
       :on-tap (eabp-action "files.cd" :args `((dir . ,path))))
    (let ((size (or (file-attribute-size (file-attributes path)) 0)))
      (eabp-card
       (list (eabp-row
              (eabp-icon "description")
              (eabp-box (list (eabp-column
                               (eabp-text (file-name-nondirectory path) 'body)
                               (eabp-text (file-size-human-readable size) 'caption)))
                        :weight 1)
              (eabp-files--entry-menu path)))
       :on-tap (eabp-action "files.open" :args `((file . ,path)))))))

(defun eabp-files--dired-cards (buffer)
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
              (when (and parent (eabp-files--within-root-p parent))
                (eabp-card
                 (list (eabp-row (eabp-icon "arrow_upward") (eabp-text ".." 'body)))
                 :on-tap (eabp-action "files.cd" :args `((dir . ,parent)))))))
        (delq nil (cons up-card
                        (mapcar #'eabp-files--card-for (append dirs files))))))))

;; Register the skin globally: any dired buffer — the Files view here or one
;; opened from the Buffers tab — renders as cards.  This is the single dispatch
;; seam from eabp-buffer.el; the Files feature owns dired's app-wide look.
(eabp-render-buffer-register 'dired-mode #'eabp-files--dired-cards)

(defun eabp-files--dired-buffer (dir)
  "Return a freshly-reverted dired buffer for DIR, or nil.
Refuses DIR outside `eabp-files-roots' or unreadable; the within-root guard
turns the Android sandbox's raw stat errors into a graceful nil."
  (when (and (stringp dir) (file-directory-p dir) (eabp-files--within-root-p dir))
    (condition-case nil
        (let ((buf (dired-noselect dir)))
          (with-current-buffer buf (revert-buffer nil t))
          buf)
      (error nil))))

(defun eabp-files--current-dir ()
  "The directory the Files view is showing — `eabp-files--dir' or the landing."
  (or eabp-files--dir (expand-file-name eabp-files-default-dir)))

(defun eabp-files-browser-body ()
  "Build the Files view: the current directory rendered as dired cards.
There is no separate roots screen — the view always shows a directory
\(`eabp-files--current-dir'), so it matches the Buffers-tab listing.
While content-search results exist, a re-entry card heads the list."
  (let ((buf (eabp-files--dired-buffer (eabp-files--current-dir)))
        (results-card (eabp-files--grep-results-card)))
    (if buf
        (apply #'eabp-lazy-column
               (append (and results-card (list results-card))
                       (eabp-render-buffer buf)))
      (eabp-empty-state :icon "info"
                        :title "Can't open folder"
                        :caption "Outside the allowed roots, or unreadable."))))

;; ─── Content search ──────────────────────────────────────────────────────────
;;
;; A pure-elisp recursive scan: portable (no external grep needed on the
;; host) and bounded — capped hits and files, capped file size, VCS/build
;; directories skipped, binaries (NUL early in the file) skipped.  The
;; scan starts at the directory being browsed, which is inside
;; `eabp-files-roots' by construction, so the root guard holds; the query
;; is matched as a literal string, never a regexp off the wire.

(defcustom eabp-files-grep-max-hits 200
  "Content search stops after this many matching lines."
  :type 'integer :group 'eabp)

(defcustom eabp-files-grep-max-files 2000
  "Content search stops after examining this many files.
Search from a subdirectory rather than the root to keep scans quick."
  :type 'integer :group 'eabp)

(defcustom eabp-files-grep-max-file-bytes (* 1024 1024)
  "Files larger than this are skipped by the content search."
  :type 'integer :group 'eabp)

(defcustom eabp-files-grep-exclude-dirs
  '(".git" ".hg" ".svn" "node_modules" ".gradle" "build" "dist" "target")
  "Directory names the content search never descends into."
  :type '(repeat string) :group 'eabp)

(defvar eabp-files--grep nil
  "Latest content search, or nil.
A plist (:query Q :dir D :hits ((FILE LINE TEXT) ...) :truncated BOOL).")

(defvar eabp-files-view-region-function
  (lambda (name &rest _) (message "EABP: no host to view %s" name))
  "Function of (BUFFER-NAME BEG END LABEL &optional POINT) showing a
buffer slice with POINT's line as the scroll target.  Set by
eabp-emacs-ui (its buffer view); kept as a seam so this module never
depends on the buffer-view host.")

(defun eabp-files--grep-scan (dir query)
  "Search QUERY (a literal, case-insensitive) under DIR.
Returns the plist stored in `eabp-files--grep'; one hit per line."
  (let ((re (regexp-quote query))
        (case-fold-search t)
        (hits-left eabp-files-grep-max-hits)
        (files-left eabp-files-grep-max-files)
        hits truncated)
    (catch 'done
      (dolist (file (directory-files-recursively
                     dir "" nil
                     (lambda (d)
                       (not (member (file-name-nondirectory
                                     (directory-file-name d))
                                    eabp-files-grep-exclude-dirs)))))
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
                     (and size (<= size eabp-files-grep-max-file-bytes))))
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

(defun eabp-files--grep-body ()
  "The search-results view body: one tappable card per matching line."
  (let* ((g eabp-files--grep)
         (dir (plist-get g :dir))
         (hits (plist-get g :hits)))
    (if (null hits)
        (eabp-empty-state :icon "manage_search" :title "No matches"
                          :caption (format "\"%s\" under %s"
                                           (plist-get g :query)
                                           (abbreviate-file-name dir)))
      (apply #'eabp-lazy-column
             (cons
              (eabp-text (format "%d matching line%s under %s%s"
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
                          (eabp-card
                           (list (eabp-column
                                  (eabp-row
                                   (eabp-box
                                    (list (apply #'eabp-column
                                                 (delq nil
                                                       (list
                                                        (eabp-text (file-name-nondirectory file)
                                                                   'label)
                                                        (when subdir
                                                          (eabp-text subdir 'caption
                                                                     nil nil nil 1))))))
                                    :weight 1)
                                   (eabp-text (format "L%d" line) 'caption)
                                   (eabp-icon-button
                                    "edit"
                                    (eabp-action "files.open"
                                                 :args `((file . ,file)))
                                    :content-description "Open in editor"))
                                  (eabp-rich-text
                                   (list (eabp-span (string-trim text) :mono t)))))
                           ;; Tap = read the hit in context (scrolled to the
                           ;; line); the pencil opens the editor.
                           :on-tap (eabp-action "files.grep-visit"
                                                :args `((file . ,file)
                                                        (line . ,line))
                                                :when-offline "drop"))))
                      hits))))))

(defun eabp-files--grep-results-card ()
  "The re-entry card the browser shows while results exist, or nil."
  (when eabp-files--grep
    (eabp-card
     (list (eabp-row
            (eabp-icon "manage_search")
            (eabp-box (list (eabp-text
                             (format "Results: \"%s\" (%d)"
                                     (plist-get eabp-files--grep :query)
                                     (length (plist-get eabp-files--grep :hits)))
                             'body))
                      :weight 1)
            (eabp-icon "chevron_right")))
     :on-tap (eabp-shell-switch-view "grep"))))

;; ─── Editor view ─────────────────────────────────────────────────────────────

(defun eabp-files-editor-body ()
  "Build the editor view for `eabp-files--file'.
An app-registered body (see `eabp-files-editor-body-functions') wins;
otherwise the plain-text editor."
  (let ((file eabp-files--file))
    (if (not (and file (file-readable-p file)))
        (eabp-column (eabp-text "No file open." 'body))
      (or (run-hook-with-args-until-success
           'eabp-files-editor-body-functions file)
          (let* ((size (or (file-attribute-size (file-attributes file)) 0))
                 (read-only (> size eabp-files-max-bytes))
                 (content
                  ;; Prefer a live buffer's content (may have unsaved desktop
                  ;; edits); fall back to disk.
                  (if-let ((buf (get-file-buffer file)))
                      (with-current-buffer buf
                        (buffer-substring-no-properties
                         (point-min)
                         (min (point-max) (1+ eabp-files-max-bytes))))
                    (with-temp-buffer
                      (insert-file-contents file nil 0 eabp-files-max-bytes)
                      (buffer-string)))))
            (eabp-column
             (when read-only
               (eabp-text (format "File exceeds %s — opened read-only."
                                  (file-size-human-readable eabp-files-max-bytes))
                          'caption))
             (eabp-editor file content
                          :read-only read-only
                          :line-numbers (and eabp-line-numbers
                                             (symbol-name eabp-line-numbers))
                          :complete (and eabp-complete-enabled (not read-only))
                          :toolbar (funcall eabp-files-editor-toolbar-function file)
                          :on-save (eabp-action "files.save"
                                                :args `((file . ,file))
                                                :when-offline "queue"
                                                :dedupe (concat "save/" file)))))))))

;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun eabp-files--files-view (snackbar)
  "The Files tab: the current directory's cards, back arrow inside subdirs."
  (let ((grep-btn (eabp-icon-button
                   "manage_search"
                   (eabp-action "files.grep" :when-offline "drop")
                   :content-description "Search file contents")))
    (eabp-shell-tab-view
     "files" (eabp-files-browser-body)
     :top-bar (if eabp-files--dir
                  (eabp-top-bar (abbreviate-file-name eabp-files--dir)
                                :nav-icon "arrow_back"
                                :nav-action (eabp-action "files.cd"
                                                         :args '((dir . :null)))
                                :actions (list grep-btn))
                (eabp-shell-default-top-bar "Files"
                                            :extra-actions (list grep-btn)))
     ;; A create FAB — the view always shows a directory (the landing dir or
     ;; a subdirectory), so it's always offered.
     :fab (eabp-fab "add" :label "New" :on-tap (eabp-action "files.new"))
     :snackbar snackbar)))

(defun eabp-files--edit-view (snackbar)
  "The editor view for the open file, with app-contributed top-bar actions."
  (eabp-shell-nav-view
   (if eabp-files--file
       (file-name-nondirectory eabp-files--file)
     "Editor")
   (eabp-files-editor-body)
   :back-to "files"
   :actions (when eabp-files--file
              (apply #'append
                     (delq nil
                           (mapcar (lambda (fn) (funcall fn eabp-files--file))
                                   eabp-files-editor-actions-functions))))
   :snackbar snackbar))

(eabp-shell-define-view "files"
  :builder #'eabp-files--files-view
  :tab '(:icon "folder_open" :label "Files")
  :order 40)

(eabp-shell-define-view "edit"
  :builder #'eabp-files--edit-view
  :when (lambda () (and eabp-files--file t))
  :order 100)

(defun eabp-files--grep-view (snackbar)
  "The content-search results view; ✕ discards the results."
  (eabp-shell-nav-view
   (format "\"%s\"" (plist-get eabp-files--grep :query))
   (eabp-files--grep-body)
   :back-to "files"
   :actions (list (eabp-icon-button
                   "close"
                   (eabp-action "files.grep-clear" :when-offline "drop")
                   :content-description "Discard search results"))
   :snackbar snackbar))

(eabp-shell-define-view "grep"
  :builder #'eabp-files--grep-view
  :when (lambda () (and eabp-files--grep t))
  :order 101)

;; Leaving the editor for the files view closes the file (the next push
;; drops the edit view). Unsaved companion-side text is discarded with it.
(add-hook 'eabp-shell-view-switched-hook
          (lambda (view)
            (when (and (equal view "files") eabp-files--file)
              (setq eabp-files--file nil))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "files.cd"
  (lambda (args _)
    (let ((dir (alist-get 'dir args)))
      (setq eabp-files--dir
            (and (stringp dir)
                 (file-directory-p dir)
                 (eabp-files--within-root-p dir)
                 (file-name-as-directory dir)))
      (eabp-shell-push nil :switch-to "files"))))

(eabp-defaction "files.open"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (file-readable-p file)
                 (eabp-files--within-root-p file))
        (setq eabp-files--file (expand-file-name file))
        (run-hook-with-args 'eabp-files-open-hook eabp-files--file)
        (eabp-shell-push nil :switch-to "edit")))))

(eabp-defaction "files.grep"
  ;; The query arrives through the bridged minibuffer (this runs inside an
  ;; action handler), so the search icon needs no input widget of its own.
  ;; Scope is the directory being browsed — within the roots by
  ;; construction — and the scan is bounded by the grep defcustoms.
  (lambda (_ __)
    (let* ((dir (eabp-files--current-dir))
           (query (condition-case nil
                      (string-trim
                       (read-string (format "Search in %s for: "
                                            (abbreviate-file-name dir))))
                    (quit ""))))
      (if (string-empty-p query)
          (eabp-shell-push)
        (setq eabp-files--grep (eabp-files--grep-scan dir query))
        (eabp-shell-push nil :switch-to "grep")))))

(eabp-defaction "files.grep-clear"
  (lambda (_ __)
    (setq eabp-files--grep nil)
    (eabp-shell-push nil :switch-to "files")))

(eabp-defaction "files.grep-visit"
  ;; Show a hit in context: the file's buffer in the buffer view,
  ;; narrowed around the line with the hit marked as the scroll target.
  ;; Region render dodges the buffer view's from-the-top line cap, so
  ;; hits deep in big files are reachable.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (line (alist-get 'line args)))
      (when (and (stringp file) (numberp line)
                 (eabp-files--within-root-p file)
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
                    (funcall eabp-files-view-region-function
                             (buffer-name buf) beg end
                             (format "%s:%d" (file-name-nondirectory file)
                                     (truncate line))
                             target)))))
          (error (eabp-shell-notify (error-message-string err))))))))

(eabp-defaction "files.delete"
  ;; Allowlisted op: delete the one tapped path, root-guarded, after a
  ;; confirmation (the y/n dialog is bridged to the phone by eabp-minibuffer).
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (eabp-files--within-root-p file)
                 (file-exists-p file))
        (if (yes-or-no-p (format "Delete %s? "
                                 (file-name-nondirectory
                                  (directory-file-name file))))
            (condition-case err
                (progn
                  (if (file-directory-p file)
                      (delete-directory file t)
                    (delete-file file))
                  (eabp-shell-notify
                   (format "Deleted %s" (file-name-nondirectory
                                         (directory-file-name file)))))
              (error (eabp-shell-notify
                      (format "Delete failed: %s" (error-message-string err)))))
          (eabp-shell-notify "Delete cancelled")))
      (eabp-shell-push nil :switch-to "files"))))

(eabp-defaction "files.rename"
  ;; Allowlisted op: rename within the same directory; the new name is read
  ;; through the bridged minibuffer and the target re-checked against roots.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (eabp-files--within-root-p file)
                 (file-exists-p file))
        (let* ((old (file-name-nondirectory (directory-file-name file)))
               (new (read-string (format "Rename %s to: " old) old)))
          (cond
           ((or (null new) (string-empty-p (string-trim new)))
            (eabp-shell-notify "Rename cancelled"))
           (t
            (let ((target (expand-file-name
                           new (file-name-directory (directory-file-name file)))))
              (cond
               ((not (eabp-files--within-root-p target))
                (eabp-shell-notify "Rename rejected (outside roots)"))
               ((file-exists-p target)
                (eabp-shell-notify "Target already exists"))
               (t
                (condition-case err
                    (progn (rename-file file target)
                           (eabp-shell-notify (format "Renamed to %s" new)))
                  (error (eabp-shell-notify
                          (format "Rename failed: %s"
                                  (error-message-string err)))))))))))
        (eabp-shell-push nil :switch-to "files")))))

;; ─── New file / folder ───────────────────────────────────────────────────────

(defun eabp-files-show-new-dialog ()
  "Dialog to create a new file or folder in the current Files directory.
The name field's value reaches the create handlers two ways: on-submit
carries it in `value', and the Folder/File buttons read it back from UI
state (the same pattern as the capture form)."
  (let ((dir (eabp-files--current-dir)))
    (when dir
      (eabp-send-dialog
       (eabp-column
        (eabp-text "New" 'title)
        (eabp-text (abbreviate-file-name dir) 'caption)
        (eabp-text-input "files-new-name"
                         :label "Name"
                         :hint "notes.org"
                         :single-line t
                         :on-submit (eabp-action "files.create"
                                                 :args '((type . "file"))))
        (eabp-row
         (eabp-button "Cancel" (eabp-action "files.new.cancel") :variant "text")
         (eabp-spacer :weight 1)
         (eabp-button "Folder"
                      (eabp-action "files.create" :args '((type . "dir")))
                      :variant "outlined")
         (eabp-spacer :width 8)
         (eabp-button "File"
                      (eabp-action "files.create" :args '((type . "file"))))))))))

(eabp-defaction "files.new"
  (lambda (_ _)
    ;; Forget any leftover name so a button tap can't read a stale value
    ;; before the user types (UI state is global and persistent).
    (eabp-ui-state-clear "files-new-name")
    (eabp-files-show-new-dialog)))

(eabp-defaction "files.new.cancel"
  (lambda (_ _) (eabp-dismiss-dialog)))

(eabp-defaction "files.create"
  ;; Allowlisted op: create a single-segment file or folder in the current
  ;; directory, re-checked against the roots.  TYPE is "file" or "dir".
  (lambda (args _)
    (let* ((type (or (alist-get 'type args) "file"))
           (name (string-trim (or (alist-get 'value args)
                                  (eabp-ui-state "files-new-name")
                                  "")))
           (dir (eabp-files--current-dir)))
      (cond
       ((or (null dir) (not (eabp-files--within-root-p dir)))
        (eabp-shell-notify "No directory"))
       ((string-empty-p name)
        (eabp-shell-notify "Name required"))
       ;; Single segment only — no separators or parent traversal.
       ((string-match-p "/" name)
        (eabp-shell-notify "Name can't contain '/'"))
       (t
        (let ((target (expand-file-name name dir)))
          (cond
           ((not (eabp-files--within-root-p target))
            (eabp-shell-notify "Rejected (outside roots)"))
           ((file-exists-p target)
            (eabp-shell-notify "Already exists"))
           (t
            (condition-case err
                (progn
                  (if (equal type "dir")
                      (make-directory target)
                    (write-region "" nil target nil 'silent))
                  (eabp-ui-state-clear "files-new-name")
                  (eabp-shell-notify (format "Created %s" name)))
              (error (eabp-shell-notify
                      (format "Create failed: %s"
                              (error-message-string err))))))))))
      (eabp-dismiss-dialog)
      (eabp-shell-push nil :switch-to "files"))))

(eabp-defaction "files.save"
  ;; Saves run inside the action handler, so `eabp--in-action-handler' is
  ;; bound — app after-save-hook refreshers key off that to avoid doubling
  ;; the explicit push below.
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (value (alist-get 'value args)))
      (cond
       ((not (and (stringp file) (stringp value)
                  (eabp-files--within-root-p file)))
        (eabp-shell-notify "Save rejected"))
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
              (run-hook-with-args 'eabp-files-after-save-hook file)
              (eabp-shell-notify
               ;; Re-loading init in a running session never applies
               ;; cleanly (defvars keep old values, hooks double up), so
               ;; the honest instruction is a restart.
               (if (and user-init-file (file-equal-p file user-init-file))
                   "Saved init — restart Emacs to apply config changes"
                 (format "Saved %s" (file-name-nondirectory file)))))
          (error
           (eabp-shell-notify
            (format "Save failed: %s" (error-message-string err))))))))
    (eabp-shell-push)))

(eabp-defaction "config.reload"
  ;; Retired: `load user-init-file' mid-session never applies cleanly
  ;; (defvars keep their values, hooks double-register), so the drawer
  ;; entry is gone.  The handler stays as a stub so a stale cached UI
  ;; from an older push gets the instruction instead of a dropped tap.
  (lambda (_ _)
    (eabp-shell-notify "Reload was removed — restart Emacs to apply config changes")
    (eabp-shell-push)))

(provide 'eabp-files)
;;; eabp-files.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-witheditor.el
;;; ==================================================================

;;; eabp-witheditor.el --- Bridge with-editor buffers to the phone -*- lexical-binding: t; -*-

;; When magit (or any with-editor client) runs a command that needs an
;; editor — a commit message, an interactive rebase todo — git launches
;; Emacs as its editor and a with-editor buffer appears, expecting the user
;; to edit it and press `C-c C-c' (finish) or `C-c C-k' (cancel).  Over the
;; bridge there is no keyboard, so that buffer would just sit there and the
;; whole operation hangs (this is the second half of the magit-commit hang;
;; the first is `map-y-or-n-p' in eabp-minibuffer.el).
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

(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)

(defcustom eabp-witheditor-action-window 30
  "Seconds after a phone action within which a with-editor buffer bridges.
The git editor callback lands asynchronously AFTER the action handler that
started the commit has returned, so the bridge can't test
`eabp--in-action-handler' — instead it treats an editor buffer appearing
this soon after a dispatched action as phone-initiated.  Outside the
window (a commit made at the desktop while the phone happens to be
connected) nothing is pushed to the phone."
  :type 'integer :group 'eabp)

(defvar-local eabp-witheditor--bridged nil
  "Non-nil once this buffer's with-editor session has been bridged.
Guards against the enable/disable double-fire of `with-editor-mode-hook'
and the overlap with `git-commit-setup-hook' (both fire for a commit).")

(defvar eabp-witheditor--active nil
  "Buffer name of the with-editor session currently shown as a dialog, or nil.
Lets the post-finish/cancel hooks dismiss the phone dialog when the
session ends from the desktop side (or any path that isn't our actions).")

;; ─── Message region ──────────────────────────────────────────────────────────

(defun eabp-witheditor--message-region ()
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

(defun eabp-witheditor--current-message ()
  "The current message text (before the comment tail), trailing blank trimmed."
  (let ((r (eabp-witheditor--message-region)))
    (string-trim-right
     (buffer-substring-no-properties (car r) (cdr r)))))

;; ─── Presentation ────────────────────────────────────────────────────────────

(defun eabp-witheditor--state-id (name)
  "UI-state / editor id for the with-editor buffer named NAME."
  (concat "witheditor:" name))

(defun eabp-witheditor--present (buf)
  "Push a dialog to edit and finish/cancel with-editor buffer BUF."
  (with-current-buffer buf
    (let* ((name (buffer-name buf))
           (eid (eabp-witheditor--state-id name))
           (content (eabp-witheditor--current-message))
           ;; Rebase todos and other non-commit editor buffers get their
           ;; buffer name; only a real commit gets the friendly title.
           (title (if (bound-and-true-p git-commit-mode)
                      "Commit message"
                    name)))
      ;; Seed UI state so the Commit button reads the initial text even if
      ;; the user finishes without editing (publish-state only emits on
      ;; change — same pattern as the eval REPL / capture form).
      (eabp-ui-state-put eid content)
      (setq eabp-witheditor--active name)
      (eabp-send-dialog
       (eabp-column
        (eabp-text title 'title)
        (eabp-editor eid content
                     :chromeless t
                     :publish-state t)
        (eabp-row
         (eabp-button "Cancel"
                      (eabp-action "witheditor.cancel" :args `((buffer . ,name)))
                      :variant "text")
         (eabp-spacer :weight 1)
         (eabp-button "Commit"
                      (eabp-action "witheditor.finish"
                                   :args `((buffer . ,name))))))))))

(defvar eabp--last-action-time)     ; eabp-surfaces.el
(defvar eabp--in-action-handler)    ; eabp-minibuffer.el

(defun eabp-witheditor--phone-initiated-p ()
  "Non-nil when the current editor buffer plausibly stems from a phone action.
True inside an action handler, or within `eabp-witheditor-action-window'
seconds of one (the git callback lands after the handler returned)."
  (or eabp--in-action-handler
      (< (- (float-time) eabp--last-action-time)
         eabp-witheditor-action-window)))

(defun eabp-witheditor--maybe-bridge ()
  "Bridge the current with-editor buffer to the phone, once, when connected.
Runs from `git-commit-setup-hook' / `with-editor-mode-hook'.  Bridges only
flows the phone plausibly started (see `eabp-witheditor--phone-initiated-p')
— a commit made at the desktop while the phone is connected must NOT pop
an uninvited dialog on it."
  (when (and (bound-and-true-p with-editor-mode)
             (eabp-connected-p)
             (eabp-witheditor--phone-initiated-p)
             (not eabp-witheditor--bridged))
    (setq eabp-witheditor--bridged t)
    (eabp-witheditor--present (current-buffer))))

(defun eabp-witheditor--session-ended ()
  "Dismiss the phone dialog when a bridged session ends outside our actions.
On `with-editor-post-finish/cancel-hook': the user may have finished the
commit at the desktop (C-c C-c there) while the phone dialog was up."
  (when eabp-witheditor--active
    (setq eabp-witheditor--active nil)
    (when (eabp-connected-p)
      (eabp-dismiss-dialog))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun eabp-witheditor--find-buffer (name)
  "Return the live with-editor buffer named NAME, or nil.
The handlers refuse any buffer that is not a live with-editor session —
this is the validation the command-dispatch boundary requires."
  (let ((buf (and (stringp name) (get-buffer name))))
    (and buf
         (buffer-live-p buf)
         (with-current-buffer buf (bound-and-true-p with-editor-mode))
         buf)))

(eabp-defaction "witheditor.finish"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (eabp-witheditor--find-buffer name))
           (value (or (alist-get 'value args)
                      (and buf (eabp-ui-state (eabp-witheditor--state-id name))))))
      (when buf
        (with-current-buffer buf
          ;; Replace only the message region, leaving git's comment/scissors
          ;; tail intact (git strips it on commit).
          (let ((r (eabp-witheditor--message-region)))
            (delete-region (car r) (cdr r))
            (goto-char (point-min))
            (insert (if (stringp value) value "") "\n"))
          (eabp-ui-state-clear (eabp-witheditor--state-id name))
          ;; Clear BEFORE finishing: the post-finish hook must not
          ;; double-dismiss (it would race a dialog a later flow opened).
          (setq eabp-witheditor--active nil)
          (when (fboundp 'with-editor-finish)
            (with-editor-finish nil)))
        (eabp-dismiss-dialog)
        (eabp-shell-push)))))

(eabp-defaction "witheditor.cancel"
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (buf (eabp-witheditor--find-buffer name)))
      (when buf
        (with-current-buffer buf
          (eabp-ui-state-clear (eabp-witheditor--state-id name))
          (setq eabp-witheditor--active nil)
          (when (fboundp 'with-editor-cancel)
            (with-editor-cancel nil)))
        (eabp-dismiss-dialog)
        (eabp-shell-push)))))

;; ─── Hooks (installed only once with-editor/git-commit are present) ───────────

(with-eval-after-load 'with-editor
  (add-hook 'with-editor-mode-hook #'eabp-witheditor--maybe-bridge)
  ;; Dismiss our dialog when the session ends from the desktop side.
  (add-hook 'with-editor-post-finish-hook #'eabp-witheditor--session-ended)
  (add-hook 'with-editor-post-cancel-hook #'eabp-witheditor--session-ended))

(with-eval-after-load 'git-commit
  (add-hook 'git-commit-setup-hook #'eabp-witheditor--maybe-bridge))

(provide 'eabp-witheditor)
;;; eabp-witheditor.el ends here

;;; ==================================================================
;;; BEGIN core/eabp-emacs-ui.el
;;; ==================================================================

;;; eabp-emacs-ui.el --- EABP Emacs REPL & Buffer Viewer -*- lexical-binding: t; -*-

;; Provides an in-app Emacs interaction layer:
;;   * Buffer viewer (switch buffers, see content)
;;   * *Messages* tail
;;   * M-x command runner (interactive command dialog)
;;   * Elisp eval REPL
;;
;; Registers three shell views — "buffers", "eval" (a bottom-bar tab), and
;; "messages" — plus their drawer entries and the M-x top-bar action.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer)
(require 'eabp-tablist)
(require 'eabp-shell)
(require 'eabp-witheditor)
(require 'imenu)
(require 'cl-lib)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar eabp-emacs-ui--viewing-buffer nil
  "Name of the buffer currently being viewed, or nil for the buffer list.")

(defvar eabp-emacs-ui--section nil
  "Active section narrowing for the buffer view, or nil.
A plist (:buffer NAME :beg POS :end POS :label STRING :point POS);
while set for the viewed buffer, the view renders just that slice,
with :point (when non-nil) marked as the scroll target.  Set by
`imenu.show' or `eabp-emacs-ui-view-region', cleared by `imenu.clear'
or leaving the buffer.")

(defun eabp-emacs-ui-view-region (buffer-name beg end label &optional point)
  "Open the buffer view on BUFFER-NAME narrowed to [BEG, END).
LABEL heads the slice; POINT, when non-nil, marks the scroll-target
line.  The navigation entry other modules use to show \"this spot in
that buffer\" — grep hits, and any future jump affordance."
  (setq eabp-emacs-ui--viewing-buffer buffer-name
        eabp-emacs-ui--section (list :buffer buffer-name :beg beg :end end
                                     :label label :point point))
  (eabp-shell-push nil :switch-to "buffers"))

;; eabp-files stays independent of this module (it loads first); its
;; grep hits navigate here through the seam.
(defvar eabp-files-view-region-function)
(with-eval-after-load 'eabp-files
  (setq eabp-files-view-region-function #'eabp-emacs-ui-view-region))

;; Navigating to a buffer (the tablist skins open package descriptions and
;; list buffers this way) is this module's buffer view.
(setq eabp-tablist-view-buffer-function
      (lambda (name)
        (setq eabp-emacs-ui--viewing-buffer name)
        (eabp-shell-push nil :switch-to "buffers")))

(defvar eabp-emacs-ui--eval-history nil
  "List of (input . output) pairs from the eval REPL, newest first.")

(defcustom eabp-emacs-ui-eval-history-max 50
  "Maximum eval-history entries kept (and shipped in the dashboard spec)."
  :type 'integer :group 'eabp)

(defcustom eabp-emacs-ui-eval-output-max 2000
  "Eval results longer than this many characters are truncated for display."
  :type 'integer :group 'eabp)

(defvar eabp-emacs-ui--messages-line-count 100
  "Number of tail lines to show from *Messages*.")

;; ─── Buffer List ─────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--buffer-list-body ()
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
                     (eabp-card
                      (list (eabp-column
                             (eabp-text (concat prefix name) 'body)
                             (eabp-text subtitle 'caption)))
                      :on-tap (eabp-action "emacs.buffer.view"
                                           :args `((buffer . ,name))))))
                 bufs)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-text "No buffers." 'body))))

;; ─── Buffer Content Viewer ───────────────────────────────────────────────────

(defun eabp-emacs-ui--buffer-view-body (buffer-name)
  "Build UI showing the contents of BUFFER-NAME.
Rendered through the Tier 0 generic renderer (`eabp-render-buffer'), so the
buffer's faces and tappable regions survive — any major mode works without a
bespoke translator.  With an imenu section active for this buffer, only
that slice renders, under a dismissible header."
  (let ((buf (get-buffer buffer-name))
        (section (and (equal (plist-get eabp-emacs-ui--section :buffer)
                             buffer-name)
                      eabp-emacs-ui--section)))
    (cond
     ((not buf)
      (eabp-text (format "Buffer '%s' not found." buffer-name) 'body))
     (section
      (apply #'eabp-lazy-column
             (cons (eabp-row
                    (eabp-box (list (eabp-text (plist-get section :label)
                                               'label))
                              :weight 1)
                    (eabp-icon-button "close"
                                      (eabp-action "imenu.clear"
                                                   :when-offline "drop")
                                      :content-description "Show whole buffer"))
                   (eabp-buffer-render-region buf
                                              (plist-get section :beg)
                                              (plist-get section :end)
                                              (plist-get section :point)))))
     (t (apply #'eabp-lazy-column (eabp-render-buffer buf))))))

;; ─── imenu sections ──────────────────────────────────────────────────────────
;;
;; imenu is the per-buffer index of definitions/sections any major mode
;; provides declaratively.  The picker is a bridged `completing-read'
;; (the same vertico-style dialog M-x uses), and the chosen entry
;; renders as a region slice — the phone has no scroll-to-position, so
;; "jump" means "show me that section".

(defun eabp-emacs-ui--imenu-flatten (alist prefix)
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
            (setq out (append out (eabp-emacs-ui--imenu-flatten tail label))))
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
;; `eabp-emacs-ui--viewing-buffer' however it was set or cleared.

(defcustom eabp-emacs-ui-live-refresh t
  "When non-nil, a buffer drilled into on the phone refreshes as it changes.
Self-updating buffers (compilation, grep, async shell, *Messages*) re-push
while viewed instead of freezing at the snapshot taken when you opened them."
  :type 'boolean :group 'eabp)

(defcustom eabp-emacs-ui-live-interval 1.0
  "Seconds between change checks for the buffer being viewed.
Polls only while a buffer is actively drilled into and the bridge is
connected; each check is a cheap tick comparison and pushes only on change."
  :type 'number :group 'eabp)

(defvar eabp-emacs-ui--live-timer nil)
(defvar eabp-emacs-ui--live-buffer nil
  "The buffer object currently watched for live refresh, or nil.")
(defvar eabp-emacs-ui--live-tick nil
  "`buffer-chars-modified-tick' of the watched buffer at its last push.")

(defun eabp-emacs-ui--live-tick-of (buf)
  "The `buffer-chars-modified-tick' of BUF, or nil if BUF is dead."
  (and (buffer-live-p buf)
       (with-current-buffer buf (buffer-chars-modified-tick))))

(defun eabp-emacs-ui--live-stop ()
  "Tear down the live-refresh watch."
  (when (timerp eabp-emacs-ui--live-timer)
    (cancel-timer eabp-emacs-ui--live-timer))
  (setq eabp-emacs-ui--live-timer nil
        eabp-emacs-ui--live-buffer nil
        eabp-emacs-ui--live-tick nil))

(defun eabp-emacs-ui--live-poll ()
  "Timer body: re-push when the watched buffer changed since its last push."
  (let ((buf eabp-emacs-ui--live-buffer))
    (if (or (not eabp-emacs-ui-live-refresh)
            (not (eabp-connected-p))
            (not (buffer-live-p buf))
            ;; The user navigated away from (or swapped) the viewed buffer.
            (not (equal (buffer-name buf) eabp-emacs-ui--viewing-buffer)))
        (eabp-emacs-ui--live-stop)
      (let ((tick (eabp-emacs-ui--live-tick-of buf)))
        (unless (equal tick eabp-emacs-ui--live-tick)
          ;; Safe to push here: a timer, not a change hook.
          (eabp-shell-push)
          ;; Re-read the tick AFTER the push so a message the push itself
          ;; logged (when the viewed buffer *is* *Messages*) can't drive an
          ;; endless self-refresh — only genuinely new changes re-trigger.
          (setq eabp-emacs-ui--live-tick (eabp-emacs-ui--live-tick-of buf)))))))

(defun eabp-emacs-ui--reconcile-live-watch ()
  "Start/stop the live-refresh watch to match the buffer being viewed.
Runs after every shell push, so the watch follows
`eabp-emacs-ui--viewing-buffer' no matter which code path changed it."
  (let* ((name (and eabp-emacs-ui-live-refresh
                    (eabp-connected-p)
                    eabp-emacs-ui--viewing-buffer))
         (buf (and name (get-buffer name))))
    (cond
     ((not (buffer-live-p buf)) (eabp-emacs-ui--live-stop))
     ((eq buf eabp-emacs-ui--live-buffer) nil) ; already watching it
     (t
      (eabp-emacs-ui--live-stop)
      (setq eabp-emacs-ui--live-buffer buf
            eabp-emacs-ui--live-tick (eabp-emacs-ui--live-tick-of buf)
            eabp-emacs-ui--live-timer
            (run-at-time eabp-emacs-ui-live-interval eabp-emacs-ui-live-interval
                         #'eabp-emacs-ui--live-poll))))))

(add-hook 'eabp-shell-after-push-hook #'eabp-emacs-ui--reconcile-live-watch)

;; ─── *Messages* Tail ─────────────────────────────────────────────────────────

(defun eabp-emacs-ui--messages-tail ()
  "The last `eabp-emacs-ui--messages-line-count' lines of *Messages*."
  (if-let ((msgs-buf (get-buffer "*Messages*")))
      (with-current-buffer msgs-buf
        (let* ((lines (split-string
                       (buffer-substring-no-properties (point-min) (point-max))
                       "\n" t))
               (tail (last lines eabp-emacs-ui--messages-line-count)))
          (mapconcat #'identity tail "\n")))
    "No *Messages* buffer."))

(defun eabp-emacs-ui--messages-line (line stripe)
  "One zebra row for the Messages view.
LINE is selectable (long-press to copy); STRIPE non-nil tints the row
with a theme-adaptive container color so lines read as distinct entries."
  (let ((text (eabp-text (if (string-empty-p line) " " line)
                         'mono nil nil t nil 4)))
    (if stripe
        (eabp-surface (list text)
                      :color "surface_container"
                      :shape "rounded_small"
                      :fill t)
      text)))

(defun eabp-emacs-ui--messages-body ()
  "Build the Messages view: zebra-striped, selectable lines + copy all.
Each *Messages* line is its own row (alternate rows tinted) so entries
are visually delineated; every row is long-press selectable, and Copy
all uses the companion-local clipboard builtin."
  (let* ((content (eabp-emacs-ui--messages-tail))
         (i 0)
         (rows (mapcar (lambda (line)
                         (prog1 (eabp-emacs-ui--messages-line line (cl-oddp i))
                           (setq i (1+ i))))
                       (split-string content "\n"))))
    (eabp-column
     (eabp-row
      (eabp-text (format "Last %d lines" eabp-emacs-ui--messages-line-count)
                 'caption)
      (eabp-spacer :weight 1)
      (eabp-button "Copy all" (eabp-clipboard-action content) :variant "text"))
     (eabp-box
      (list (apply #'eabp-lazy-column rows))
      :weight 1))))

;; ─── *Messages* → device toasts ──────────────────────────────────────────────

(defcustom eabp-forward-messages t
  "When non-nil, echo-area messages mirror to the companion as toasts.
Throttled to at most one per second (latest wins); EABP's own bridge
chatter is filtered out so it can never echo back to the phone."
  :type 'boolean :group 'eabp)

(defvar eabp-emacs-ui--toast-last 0
  "Time of the last toast sent, for throttling.")
(defvar eabp-emacs-ui--toast-timer nil)
(defvar eabp-emacs-ui--toast-pending nil
  "Latest message held back by the throttle, flushed by the timer.")
(defvar eabp-emacs-ui--in-toast nil
  "Reentrancy guard: non-nil while forwarding a message.")

(defun eabp-emacs-ui--toast-send (text)
  (setq eabp-emacs-ui--toast-last (float-time))
  (eabp-send "toast.show" `((text . ,text))))

(defun eabp-emacs-ui--message-advice (format-string &rest args)
  "Mirror `message' output to the companion as a toast.
Runs as :after advice on `message'; never signals, never recurses.
Honours `inhibit-message': output the caller silenced for the echo area
\(e.g. the flymake shadow compile's \"Wrote ....elc\") stays silent on
the phone too."
  (when (and eabp-forward-messages
             (not inhibit-message)
             (not eabp-emacs-ui--in-toast)
             format-string
             (eabp-connected-p))
    (let* ((eabp-emacs-ui--in-toast t)
           (msg (ignore-errors (apply #'format-message format-string args))))
      (when (and (stringp msg)
                 (not (string-empty-p (string-trim msg)))
                 (not (string-prefix-p "EABP" msg)))
        (when (> (length msg) 200)
          (setq msg (concat (substring msg 0 200) "…")))
        (if (> (- (float-time) eabp-emacs-ui--toast-last) 1.0)
            (eabp-emacs-ui--toast-send msg)
          ;; Throttle window: hold only the LATEST message and flush once.
          (setq eabp-emacs-ui--toast-pending msg)
          (unless (timerp eabp-emacs-ui--toast-timer)
            (setq eabp-emacs-ui--toast-timer
                  (run-at-time
                   1.0 nil
                   (lambda ()
                     (setq eabp-emacs-ui--toast-timer nil)
                     (when eabp-emacs-ui--toast-pending
                       (eabp-emacs-ui--toast-send
                        (prog1 eabp-emacs-ui--toast-pending
                          (setq eabp-emacs-ui--toast-pending nil))))))))))))
  nil)

(advice-add 'message :after #'eabp-emacs-ui--message-advice)

;; ─── Eval REPL ───────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--eval-card (entry)
  "One REPL history card for ENTRY (INPUT . OUTPUT).
Input line, then the (selectable) result, with copy and re-run buttons."
  (let* ((input (car entry))
         (output (cdr entry))
         (shown (if (> (length output) eabp-emacs-ui-eval-output-max)
                    (concat (substring output 0 eabp-emacs-ui-eval-output-max)
                            " …")
                  output)))
    (eabp-card
     (list (eabp-column
            (eabp-row
             (eabp-box (list (eabp-text (concat "λ> " input) 'label))
                       :weight 1)
             (eabp-icon-button "content_copy"
                               (eabp-clipboard-action output)
                               :content-description "Copy result")
             (eabp-icon-button "play_arrow"
                               (eabp-action "emacs.eval.submit"
                                            :args `((value . ,input)))
                               :content-description "Re-run"))
            (eabp-text shown 'mono nil nil t))))))

;; REPL input is one-shot expressions, not a file: tell the sync bridge so
;; its byte-compile diagnostics run under lexical binding (matching the
;; `eval' below) instead of warning about a missing lexical-binding cookie.
(with-eval-after-load 'eabp-sync
  (add-to-list 'eabp-sync-elisp-repl-files "eval.el"))

(defun eabp-emacs-ui--eval-body ()
  "Build UI for the elisp eval REPL.
History (newest first) scrolls in a weighted region; the input field and
Eval button stay pinned below it, so they can never be pushed off-screen
by a long history — the layout bug the old plain-column version had."
  (let* ((history-cards (mapcar #'eabp-emacs-ui--eval-card
                                eabp-emacs-ui--eval-history))
         ;; A chromeless editor instead of a plain text_input: the id names
         ;; a virtual elisp file, so the full bridge lights up in the REPL —
         ;; completion chips from the live obarray, paren/byte-compile
         ;; squiggles as you type, eldoc signatures in the doc line, and
         ;; Emacs-theme fontification. publish-state keeps the Eval button's
         ;; ui-state read working exactly like the old field.
         (input-field (eabp-editor "eval.el" ""
                                   :chromeless t
                                   :publish-state t
                                   :complete t
                                   :syntax "elisp")))
    (eabp-column
     (eabp-box
      (list (if history-cards
                (apply #'eabp-lazy-column history-cards)
              (eabp-empty-state :icon "code"
                                :title "Elisp REPL"
                                :caption (concat "Results appear here, newest "
                                                 "first. * ** and *** hold the "
                                                 "last three results."))))
      :weight 1)
     (eabp-divider)
     (eabp-box
      (list
       (eabp-row
        (eabp-box (list input-field) :weight 1)
        (eabp-spacer :width 8)
        (eabp-icon-button "send" (eabp-action "emacs.eval.submit")
                          :content-description "Eval")))
      :padding 8))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

;; Buffer list / view
(eabp-defaction "emacs.buffer.view"
  (lambda (args _)
    (setq eabp-emacs-ui--viewing-buffer (alist-get 'buffer args)
          eabp-emacs-ui--section nil)
    (eabp-shell-push)))

(eabp-defaction "emacs.buffer.back"
  (lambda (_ _)
    (setq eabp-emacs-ui--viewing-buffer nil
          eabp-emacs-ui--section nil)
    (eabp-shell-push)))

;; imenu sections
(eabp-defaction "imenu.show"
  (lambda (args _)
    (let* ((name (or (alist-get 'buffer args) eabp-emacs-ui--viewing-buffer))
           (buf (and (stringp name) (get-buffer name))))
      (if (not buf)
          (message "No buffer to index")
        (let ((flat (with-current-buffer buf
                      (condition-case nil
                          (eabp-emacs-ui--imenu-flatten
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
                    (setq eabp-emacs-ui--section
                          (list :buffer name :beg beg :end end
                                :label choice))))
                (eabp-shell-push)))))))))

(eabp-defaction "imenu.clear"
  (lambda (_ _)
    (setq eabp-emacs-ui--section nil)
    (eabp-shell-push)))

(defun eabp-emacs-ui--eval-record (input output)
  "Push (INPUT . OUTPUT) onto the eval history, bounded by the max."
  (push (cons input output) eabp-emacs-ui--eval-history)
  (when (> (length eabp-emacs-ui--eval-history) eabp-emacs-ui-eval-history-max)
    (setcdr (nthcdr (1- eabp-emacs-ui-eval-history-max)
                    eabp-emacs-ui--eval-history)
            nil)))

;; The REPL result-variable convention: `*' holds the last result, `**'
;; and `***' the two before it, referable from the next expression.
;; These are the same special variables ielm defines, so the Eval tab
;; and an ielm session share recent results when both are in play.
(defvar * nil "Most recent Eval-tab result (the ielm convention).")
(defvar ** nil "Second most recent Eval-tab result.")
(defvar *** nil "Third most recent Eval-tab result.")

;; Eval REPL
(eabp-defaction "emacs.eval.submit"
  (lambda (args _)
    ;; The Eval button carries no value, so fall back to the field's latest
    ;; value recorded by `state.changed' (same pattern as the capture form).
    ;; "eval.el" is the editor-based field; "eval-input" the legacy one.
    (let* ((expr (or (alist-get 'value args)
                     (eabp-ui-state "eval.el")
                     (eabp-ui-state "eval-input")
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
        (eabp-emacs-ui--eval-record expr result))
      (eabp-shell-push))))

;; M-x — runs `completing-read' over all commands, which the minibuffer
;; bridge turns into a live-filtering (vertico-style) picker dialog. The
;; chosen command is then run with `call-interactively' (its own prompts,
;; if any, are bridged too). Result lands in the Eval tab's history.
(eabp-defaction "emacs.mx.show"
  (lambda (_ _)
    (let ((cmd-name (condition-case nil
                        (completing-read "M-x " obarray #'commandp t)
                      (quit nil))))
      (when (and (stringp cmd-name) (not (string-empty-p cmd-name)))
        (let ((cmd (intern-soft cmd-name)))
          (cond
           ((not (commandp cmd))
            (eabp-emacs-ui--eval-record (concat "M-x " cmd-name)
                                        (format "'%s' is not a command." cmd-name)))
           (t
            (condition-case err
                (progn
                  (call-interactively cmd)
                  (eabp-emacs-ui--eval-record (concat "M-x " cmd-name)
                                              "Command executed."))
              (error
               (eabp-emacs-ui--eval-record
                (concat "M-x " cmd-name)
                (format "ERROR: %s" (error-message-string err))))))))
        (eabp-shell-push "eval")))))

;; Messages refresh
(eabp-defaction "emacs.messages.refresh"
  (lambda (_ _)
    (eabp-shell-push)))

;; Clear eval history
(eabp-defaction "emacs.eval.clear"
  (lambda (_ _)
    (setq eabp-emacs-ui--eval-history nil)
    (eabp-shell-push)))


;; ─── Shell views ─────────────────────────────────────────────────────────────

(defun eabp-emacs-ui--buffers-view (snackbar)
  "The Buffers view: list of live buffers, or the drilled-in buffer.
The list gets tab-style chrome (drawer, bottom bar, pull-to-refresh)
even though Buffers has no bottom-bar item of its own — it is reached
from the drawer.  Drilling into a buffer swaps to back-arrow chrome
with a keyboard FAB that opens the buffer's keymap."
  (if eabp-emacs-ui--viewing-buffer
      (eabp-shell-nav-view
       eabp-emacs-ui--viewing-buffer
       (eabp-emacs-ui--buffer-view-body eabp-emacs-ui--viewing-buffer)
       ;; Content swap within the buffers view: stays an Emacs round-trip
       ;; (the list must be rebuilt).
       :nav-action (eabp-action "emacs.buffer.back")
       :actions (list (eabp-icon-button
                       "toc"
                       (eabp-action "imenu.show"
                                    :args `((buffer . ,eabp-emacs-ui--viewing-buffer))
                                    :when-offline "drop")
                       :content-description "Sections (imenu)"))
       :fab (eabp-fab "keyboard"
                      :on-tap (eabp-action "eabp.keymap.show"
                               :args `((buffer . ,eabp-emacs-ui--viewing-buffer))
                               :when-offline "drop"))
       :snackbar snackbar)
    (eabp-shell-tab-view "buffers" (eabp-emacs-ui--buffer-list-body)
                         :snackbar snackbar)))

(defun eabp-emacs-ui--eval-view (snackbar)
  "The Eval tab: REPL history over a pinned input row."
  (eabp-shell-tab-view
   "eval" (eabp-emacs-ui--eval-body)
   :top-bar (eabp-shell-default-top-bar
             "Eval"
             :extra-actions (list (eabp-icon-button
                                   "delete"
                                   (eabp-action "emacs.eval.clear")
                                   :content-description "Clear history")))
   :fab nil
   :snackbar snackbar))

(defun eabp-emacs-ui--messages-view (snackbar)
  "The Messages view: the *Messages* tail with a refresh button."
  (eabp-shell-nav-view
   "Messages" (eabp-emacs-ui--messages-body)
   :actions (list (eabp-icon-button
                   "refresh"
                   (eabp-action "emacs.messages.refresh" :when-offline "drop")
                   :content-description "Refresh"))
   :snackbar snackbar))

(eabp-shell-define-view "buffers" :builder #'eabp-emacs-ui--buffers-view
                        :order 60)
(eabp-shell-define-view "eval" :builder #'eabp-emacs-ui--eval-view
                        :tab '(:icon "code" :label "Eval") :order 50)
(eabp-shell-define-view "messages" :builder #'eabp-emacs-ui--messages-view
                        :order 90)

;; Landing anywhere but the current tab drops a buffer drill-in (and its
;; imenu section).  Named so re-evaluating the file doesn't stack lambdas.
(defun eabp-emacs-ui--on-view-switched (view)
  (unless (equal view (eabp-shell-current-tab))
    (setq eabp-emacs-ui--viewing-buffer nil
          eabp-emacs-ui--section nil)))
(add-hook 'eabp-shell-view-switched-hook #'eabp-emacs-ui--on-view-switched)

(eabp-shell-add-drawer-item
 10 (lambda () (eabp-drawer-item "view_list" "Buffers"
                                 (eabp-shell-switch-view "buffers"))))
(eabp-shell-add-drawer-item
 20 (lambda () (eabp-drawer-item "history" "Messages"
                                 (eabp-shell-switch-view "messages"))))

;; M-x is available from every tab's top bar (no drawer entry needed).
(eabp-shell-add-top-action
 20 (lambda () (eabp-icon-button "terminal" (eabp-action "emacs.mx.show"))))

(provide 'eabp-emacs-ui)
;;; eabp-emacs-ui.el ends here

(provide 'eabp-core)
;;; eabp-core.el ends here
