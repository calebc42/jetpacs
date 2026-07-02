;;; glasspane.el --- Glasspane Emacs client, single-file bundle -*- lexical-binding: t; -*-
;;
;; GENERATED FILE -- do not edit by hand.
;; Produced by emacs/build-bundle.el from the emacs/eabp-*.el sources.
;; Concatenated in dependency order; each part keeps its own `provide',
;; so the inter-file `require' forms resolve within this file.
;;
;;; Code:

;;; ==================================================================
;;; BEGIN eabp.el
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
;;; ==================================================================
;;; BEGIN eabp-widgets.el
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

(cl-defun eabp-span (text &key bold italic underline strike code tag baseline color on-tap mono)
  "A styled text run for `eabp-rich-text'.
BOLD/ITALIC/UNDERLINE/STRIKE/CODE toggle emphasis; TAG themes it like a
#hashtag; BASELINE is \"super\" or \"sub\"; COLOR is a hex override; ON-TAP
makes it a clickable link.  MONO renders the run in a fixed-width font
without the code-styling background — used by the generic buffer renderer to
preserve column alignment (dired, magit, tables, ascii)."
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

(cl-defun eabp-spacer (&key height width weight)
  "A spacer of HEIGHT and WIDTH (in dp), or WEIGHT (for flex)."
  (eabp--node "spacer" 'height height 'width width 'weight weight))

(defun eabp-divider ()
  "A horizontal divider."
  (eabp--node "divider"))

(cl-defun eabp-card (children &key on-tap padding weight)
  "An elevated card wrapping CHILDREN."
  (eabp--node "card"
              'children (vconcat children)
              'on_tap on-tap
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
                              multi-line min-lines max-lines monospace syntax padding)
  "A text input field.
ID identifies the field. ON-SUBMIT is an action dispatched when done.
The client defaults to single-line; pass MULTI-LINE non-nil for a box that
accepts newlines (Enter inserts a newline rather than submitting, so such a
field should be paired with a submit button). MIN-LINES/MAX-LINES size the box
and MONOSPACE renders it in a fixed-width font (handy for code).
SYNTAX (e.g. \"elisp\", \"org\") turns on client-side highlighting."
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
              'value (and value (vconcat value))
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

;; ─── Scaffold ────────────────────────────────────────────────────────────────

(cl-defun eabp-editor (id value &key on-save read-only syntax line-numbers complete)
  "A full-height plain-text editor node.
ID identifies the editor (its unsaved state lives companion-side under
this key). VALUE seeds the buffer. ON-SAVE is dispatched with the full
text injected into args as `value'. READ-ONLY disables editing/saving.
SYNTAX (\"elisp\", \"org\") forces highlighting; when omitted the client
infers it from the file extension in ID.  LINE-NUMBERS is \"absolute\"
or \"relative\" (relative to the cursor) for a gutter, nil for none.
COMPLETE enables Emacs-backed completion: the client sends debounced
`edit.complete' actions while typing and renders the returned candidates
as a suggestion strip (see eabp-complete.el)."
  (eabp--node "editor"
              'id id
              'value value
              'on_save on-save
              'read_only (and read-only t)
              'syntax syntax
              'line_numbers line-numbers
              'complete (and complete t)))

(cl-defun eabp-scaffold (&key top-bar fab body bottom-bar snackbar drawer on-refresh)
  "A full-screen scaffold wrapper.
DRAWER (see `eabp-drawer') adds a hamburger navigation drawer whose
open/close state is handled entirely companion-side.  ON-REFRESH, when
given, enables pull-to-refresh on the body, dispatching that action."
  (eabp--node "scaffold"
              'top_bar top-bar
              'fab fab
              'body body
              'bottom_bar bottom-bar
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
;;; BEGIN eabp-surfaces.el
;;; ==================================================================

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
(eabp-defaction "org.clock.in-last"
                ;; The home-screen widget's "Clock In (Last)" button — it was
                ;; emitting this action with no handler registered.
                (lambda (&rest _)
                  (condition-case err
                      (org-clock-in-last)
                    (error (message "EABP clock-in-last failed: %s"
                                    (error-message-string err))))))

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
;;; ==================================================================
;;; BEGIN eabp-minibuffer.el
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

(defun eabp--completing-read-advice (orig-fn prompt collection &rest args)
  "Around advice for `completing-read': a live-filtering picker over the bridge.
As the user types in the filter field, the candidate list re-filters and
re-renders (vertico-style). Tapping a candidate, or pressing Done, replies."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt collection args)
    (let* ((predicate (nth 0 args))
           (id (eabp--prompt-id))
           (input-id (format "prompt-input-%s" id))
           (title (string-trim-right prompt "[ :]+"))
           ;; `all-completions' handles every collection kind (list, obarray,
           ;; hash table, completion function) honouring PREDICATE.
           (candidates (ignore-errors
                         (sort (all-completions "" collection predicate) #'string<)))
           (max-display 50)
           (render
            (lambda (query)
              (let* ((matches (eabp-minibuffer--filter candidates query))
                     (total (length matches))
                     (shown (if (> total max-display)
                                (cl-subseq matches 0 max-display)
                              matches))
                     (cards (mapcar
                             (lambda (c)
                               (eabp-card
                                (list (eabp-text c 'body))
                                :on-tap (eabp-action "prompt.reply"
                                                     :args `((prompt_id . ,id)
                                                             (value . ,c)))))
                             shown)))
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
                         ;; No :value — the field is uncontrolled after seeding
                         ;; so re-renders never stomp the user's text/cursor.
                         (eabp-text-input input-id
                                          :label "Filter"
                                          :hint "type to filter…"
                                          :single-line t
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
      (eabp--send-prompt-dialog id (funcall render ""))
      (let ((reply (unwind-protect (eabp--wait-for-prompt id)
                     (remhash input-id eabp--state-handlers)
                     (eabp--cleanup-prompt))))
        (cond
         ((eq reply 'cancelled) (keyboard-quit))
         ;; A tapped candidate is exact; a typed query falls back to its top
         ;; match (RET-picks-top, like vertico) so partial input still works.
         ((and (stringp reply) (not (string-empty-p reply)))
          (if (member reply candidates)
              reply
            (or (car (eabp-minibuffer--filter candidates reply)) reply)))
         (t ""))))))

(advice-add 'completing-read :around #'eabp--completing-read-advice)

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

(defun eabp--read-char-choice-advice (orig-fn prompt chars &rest args)
  "Around advice for `read-char-choice'.
Forces the user to select a valid character from CHARS."
  (if (not eabp--in-action-handler)
      (apply orig-fn prompt chars args)
    (catch 'done
      (while t
        (let* ((reply (eabp--read-from-minibuffer-advice #'ignore prompt))
               (char (when (and (stringp reply) (> (length reply) 0))
                       (aref reply 0))))
          (if (and char (memq char chars))
              (throw 'done char)
            (when (fboundp 'eabp-org-ui-snackbar)
              (eabp-org-ui-snackbar "Invalid choice. Please try again."))))))))

(advice-add 'read-char-choice :around #'eabp--read-char-choice-advice)

(provide 'eabp-minibuffer)
;;; eabp-minibuffer.el ends here

;;; ==================================================================
;;; BEGIN eabp-buffer.el
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
  "Read ATTR from a single face REF (symbol or plist); nil if unspecified."
  (let ((v (cond
            ((symbolp ref) (face-attribute ref attr nil t))
            ((listp ref) (plist-get ref attr))
            (t nil))))
    (if (eq v 'unspecified) nil v)))

(defun eabp-buffer--attr (refs attr)
  "First specified value of ATTR across REFS, in priority order."
  (cl-some (lambda (r) (eabp-buffer--ref-attr r attr)) refs))

(defconst eabp-buffer--bold-weights
  '(bold semi-bold semibold extra-bold extrabold ultra-bold ultrabold heavy black)
  "Weight symbols treated as bold.")

(defun eabp-buffer--span-style (face)
  "Return a plist (:bold :italic :underline :strike :color) for FACE.
COLOR is included only when it resolves and differs from the default
foreground.  Returns nil for an unstyled run."
  (condition-case nil
      (let* ((refs (eabp-buffer--face-refs face))
             (weight (eabp-buffer--attr refs :weight))
             (slant (eabp-buffer--attr refs :slant))
             (underline (eabp-buffer--attr refs :underline))
             (strike (eabp-buffer--attr refs :strike-through))
             (fg (and eabp-buffer-emit-colors
                      (eabp-buffer--attr refs :foreground)))
             (hex (and fg (eabp-buffer--color-hex fg))))
        (append
         (when (memq weight eabp-buffer--bold-weights) '(:bold t))
         (when (memq slant '(italic oblique)) '(:italic t))
         (when underline '(:underline t))
         (when strike '(:strike t))
         (when (and hex (not (equal hex eabp-buffer--default-fg-hex)))
           (list :color hex))))
    (error nil)))

;; ─── Interactivity ─────────────────────────────────────────────────────────

(defun eabp-buffer--actionable-p (pos)
  "Non-nil if the char at POS belongs to a tappable region.
True for text/widget buttons, regions carrying a `mouse-face', and regions
with their own `keymap'/`local-map' (magit sections, info refs, …).  The
major-mode keymap is buffer-local, not a text property, so this never marks
the whole buffer tappable."
  (or (get-char-property pos 'button)
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

(defun eabp-buffer--line-spans (bol eol buffer-name)
  "Build the list of spans for the buffer text in [BOL, EOL).
Honors `invisible' (skips folded text) and string `display' overrides, maps
faces to styling, and attaches a tap action at the start of each actionable
property run."
  (let ((pos bol) spans)
    (while (< pos eol)
      (let ((next (next-char-property-change pos eol)))
        (when (<= next pos) (setq next (1+ pos))) ; defensive: always advance
        (setq next (min next eol))
        (let ((invis (get-char-property pos 'invisible)))
          (unless (and invis (invisible-p invis))
            (let* ((disp (get-char-property pos 'display))
                   (text (if (stringp disp)
                             disp
                           (buffer-substring-no-properties pos next)))
                   (style (eabp-buffer--span-style (get-char-property pos 'face)))
                   (act (when (eabp-buffer--actionable-p pos)
                          (eabp-action "eabp.buffer.act"
                                       :args `((buffer . ,buffer-name)
                                               (pos . ,pos))))))
              (when (and (stringp text) (not (string-empty-p text)))
                (push (apply #'eabp-span text
                             (append style
                                     (when eabp-buffer-monospace '(:mono t))
                                     (when act (list :on-tap act))))
                      spans)))))
        (setq pos next)))
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

(defun eabp-buffer--render-region (beg end buffer-name)
  "Return a list of `rich_text' nodes for [BEG, END) of the current buffer.
One node per line; blank lines keep their vertical space.  Capped at
`eabp-buffer-max-lines'.  When `eabp-line-numbers' is enabled each line
is prefixed with a dim gutter span carrying its (absolute or relative)
number — real buffer lines, so folded regions skip numbers faithfully."
  (let* ((eabp-buffer--default-fg-hex
          (eabp-buffer--color-hex (face-attribute 'default :foreground nil t)))
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
               (eol (min end (line-end-position)))
               (spans (eabp-buffer--line-spans bol eol buffer-name)))
          ;; A fully-folded line (no visible spans, hidden at bol) is dropped
          ;; entirely so collapsed content truly disappears instead of leaving
          ;; a blank gap.  Visible lines render; a collapsed heading gets a
          ;; trailing ▸ affordance to expand it from the app, unfolded gets ▾.
          (unless (and (null spans) (eabp-buffer--invisible-at bol))
            (pcase (eabp-buffer--fold-state bol eol end)
              ('folded
               (setq spans (append (or spans (list (eabp-span " ")))
                                   (list (eabp-buffer--fold-span bol buffer-name "  ▸")))))
              ('unfolded
               (setq spans (append (or spans (list (eabp-span " ")))
                                   (list (eabp-buffer--fold-span bol buffer-name "  ▾"))))))
            (setq spans (or spans (list (eabp-span " "))))
            (when ln
              (setq spans (cons (eabp-buffer--line-number-span ln pt-line num-fmt)
                                spans)))
            (push (eabp-rich-text spans) nodes)
            (setq count (1+ count))))
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

(defun eabp-buffer-invoke-at (buffer-name pos)
  "Run the tap action at POS in BUFFER-NAME and return non-nil if one fired.
Tries, in order: push a button, then the region keymap's binding for RET /
mouse-2 / mouse-1.  Runs with the buffer current and point at POS; commands
that only need point (buttons, magit/dired/info visit) work, those that
require a live window may not.  Called inside an action handler, so any
minibuffer prompts it raises are bridged to the companion automatically."
  (let ((buf (get-buffer buffer-name)))
    (when (and buf (numberp pos))
      (with-current-buffer buf
        (goto-char (min (max (point-min) (truncate pos)) (point-max)))
        (cond
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
;;; BEGIN eabp-org-rich.el
;;; ==================================================================

;;; eabp-org-rich.el --- Org → rich-text SDUI emitter -*- lexical-binding: t; -*-

;; Turns org content into EABP `rich_text' nodes (styled span runs) instead of
;; the syntax-highlighted monospace `eabp-markup' produces. Emacs does the
;; parsing via `org-element', so the device never re-parses org — it only paints
;; the spans. Inline emphasis (bold/italic/underline/strike/code/verbatim),
;; links (tappable), timestamps, and #hashtags all map to native styling.
;;
;; Block-level content that doesn't fit a single styled paragraph — source
;; blocks, tables, example blocks — falls back to `eabp-markup' so code keeps
;; its highlighted, fixed-width look.
;;
;; Entry point: `eabp-org-rich-body' (an org body string -> a list of nodes).

;;; Code:

(require 'org)
(require 'org-element)
(require 'cl-lib)
(require 'eabp-widgets)

;; ─── Dynamic context for interactive elements ───────────────────────────────

(defvar eabp-org-rich--file nil
  "File path being rendered; enables interactive checkboxes when non-nil.")

(defvar eabp-org-rich--body-offset nil
  "Offset mapping temp-buffer positions to real-file positions.
real-pos = offset + temp-pos.  Set by `eabp-org-rich-body' when
FILE and OFFSET are supplied.")

;; ─── Inline spans ────────────────────────────────────────────────────────────

(defun eabp-org-rich--flag (style key)
  "Return STYLE (a plist of emphasis flags) with KEY turned on.
Prepended so `plist-get' sees the new value first; STYLE is never mutated."
  (cons key (cons t style)))

(defun eabp-org-rich--leaf (text style)
  "Build a span for TEXT carrying the emphasis flags set in STYLE."
  (apply #'eabp-span (or text "")
         (append (when (plist-get style :bold)      '(:bold t))
                 (when (plist-get style :italic)    '(:italic t))
                 (when (plist-get style :underline) '(:underline t))
                 (when (plist-get style :strike)    '(:strike t))
                 (when (plist-get style :code)      '(:code t))
                 (when (plist-get style :tag)       '(:tag t))
                 (when (plist-get style :baseline)
                   (list :baseline (plist-get style :baseline))))))

(defconst eabp-org-rich--image-re
  "\\.\\(png\\|jpe?g\\|gif\\|webp\\|bmp\\|svg\\)\\'"
  "Matches link targets that should render as inline images.")

(defun eabp-org-rich--image-url (type target)
  "Return a renderable URL for a link of TYPE to TARGET if it's an image.
http(s) image URLs pass through; local file/attachment paths become
file:// URIs the companion can try to load. Returns nil for non-images."
  (when (and (stringp target)
             (string-match-p eabp-org-rich--image-re (downcase target)))
    (let ((ty (and type (downcase type))))
      (cond
       ((member ty '("http" "https")) (concat ty ":" target))
       ((or (null ty) (equal ty "file"))
        (concat "file://" (expand-file-name target)))
       ((equal ty "attachment")
        (let ((dir (ignore-errors (org-attach-dir))))
          (when dir (concat "file://" (expand-file-name target dir)))))))))

(defun eabp-org-rich--text-spans (text style)
  "Split TEXT into plain runs and #hashtag runs, all under STYLE.
A hashtag must follow start-of-string or a non-word character, so `C#'
and URL fragments aren't mistaken for tags."
  (let ((spans nil) (start 0) (len (length text)))
    (while (string-match "\\(?:^\\|[^[:alnum:]_]\\)\\(#[[:alnum:]_-]+\\)" text start)
      (let ((mb (match-beginning 1)) (me (match-end 1)))
        (when (> mb start)
          (push (eabp-org-rich--leaf (substring text start mb) style) spans))
        (push (eabp-org-rich--leaf (substring text mb me)
                                   (eabp-org-rich--flag style :tag))
              spans)
        (setq start me)))
    (when (< start len)
      (push (eabp-org-rich--leaf (substring text start) style) spans))
    (nreverse spans)))

(defun eabp-org-rich--linkify (spans action)
  "Attach ON-TAP ACTION to every span in SPANS that doesn't already have one."
  (mapcar (lambda (sp)
            (if (assq 'on_tap sp) sp (cons (cons 'on_tap action) sp)))
          spans))

(defun eabp-org-rich--inline (objects style)
  "Convert a list of org inline OBJECTS (strings and elements) to spans.
STYLE carries inherited emphasis flags as recursion descends into
bold/italic/... containers."
  (let (spans)
    (dolist (obj objects)
      (cond
       ((stringp obj)
        (setq spans (append spans (eabp-org-rich--text-spans obj style))))
       ((null obj) nil)
       (t
        (pcase (org-element-type obj)
          ('bold (setq spans (append spans
                                     (eabp-org-rich--inline
                                      (org-element-contents obj)
                                      (eabp-org-rich--flag style :bold)))))
          ('italic (setq spans (append spans
                                       (eabp-org-rich--inline
                                        (org-element-contents obj)
                                        (eabp-org-rich--flag style :italic)))))
          ('underline (setq spans (append spans
                                          (eabp-org-rich--inline
                                           (org-element-contents obj)
                                           (eabp-org-rich--flag style :underline)))))
          ('strike-through (setq spans (append spans
                                               (eabp-org-rich--inline
                                                (org-element-contents obj)
                                                (eabp-org-rich--flag style :strike)))))
          ('code (setq spans (append spans
                                     (list (eabp-org-rich--leaf
                                            (org-element-property :value obj)
                                            (eabp-org-rich--flag style :code))))))
          ('verbatim (setq spans (append spans
                                         (list (eabp-org-rich--leaf
                                                (org-element-property :value obj)
                                                (eabp-org-rich--flag style :code))))))
          ('link
           (let* ((raw (org-element-property :raw-link obj))
                  (contents (org-element-contents obj))
                  (child (if contents
                             (eabp-org-rich--inline contents style)
                           (list (eabp-org-rich--leaf (or raw "link") style))))
                  (action (eabp-action "org.link.open"
                                       :args (list (cons 'link raw)))))
             (setq spans (append spans (eabp-org-rich--linkify child action)))))
          ('timestamp
           (setq spans (append spans
                               (list (eabp-org-rich--leaf
                                      (org-element-property :raw-value obj)
                                      (eabp-org-rich--flag style :code))))))
          ('entity
           ;; Render org entities (\alpha, \rightarrow, …) as their Unicode form.
           (let ((utf8 (or (org-element-property :utf-8 obj)
                           (org-element-property :name obj))))
             (when utf8
               (setq spans (append spans (list (eabp-org-rich--leaf utf8 style)))))))
          ('subscript
           (setq spans (append spans
                               (eabp-org-rich--inline
                                (org-element-contents obj)
                                (cons :baseline (cons "sub" style))))))
          ('superscript
           (setq spans (append spans
                               (eabp-org-rich--inline
                                (org-element-contents obj)
                                (cons :baseline (cons "super" style))))))
          ('footnote-reference
           ;; A superscript, link-colored marker; tapping reports the inline
           ;; definition (when the reference carries one) via snackbar.
           (let* ((label (org-element-property :label obj))
                  (marker (format "[%s]" (if (and (stringp label)
                                                  (string-prefix-p "fn:" label))
                                             (substring label 3)
                                           (or label "*"))))
                  (def (string-trim
                        (or (ignore-errors
                              (org-element-interpret-data
                               (org-element-contents obj)))
                            "")))
                  (action (eabp-action "org.footnote.show"
                                       :args (list (cons 'label (or label ""))
                                                   (cons 'def def)))))
             (setq spans
                   (append spans
                           (list (eabp-span marker
                                            :baseline "super"
                                            :tag t
                                            :on-tap action))))))
          ('line-break
           (setq spans (append spans (list (eabp-span "\n")))))
          (_
           ;; Anything else (latex fragment, export snippet, …): fall back to
           ;; its interpreted source text.
           (let ((txt (ignore-errors (org-element-interpret-data obj))))
             (when (stringp txt)
               (setq spans (append spans
                                   (eabp-org-rich--text-spans
                                    (string-trim-right txt) style))))))))))
    spans))

;; ─── Block elements ──────────────────────────────────────────────────────────

(defun eabp-org-rich--item (item)
  "Render a plain-list ITEM to a node (bullet/number + content, plus sub-elements).

When `eabp-org-rich--file' and `eabp-org-rich--body-offset' are set
(the reader passes them), checkbox items get a tappable icon that
toggles the checkbox via Emacs without entering edit mode."
  (let* ((bullet (or (org-element-property :bullet item) "- "))
         (checkbox (org-element-property :checkbox item))
         (contents (org-element-contents item))
         (para (cl-find-if (lambda (c) (eq (org-element-type c) 'paragraph)) contents))
         (inline (when para (eabp-org-rich--inline (org-element-contents para) nil)))
         (lead-text (concat (string-trim-right bullet) " "))
         (head
          (if (and checkbox eabp-org-rich--file eabp-org-rich--body-offset)
              ;; Interactive checkbox — a tappable icon beside the item text.
              (let* ((checked (eq checkbox 'on))
                     (item-pos (+ eabp-org-rich--body-offset
                                  (org-element-property :begin item)))
                     (cb-icon (pcase checkbox
                                ('on  "check_box")
                                ('off "check_box_outline_blank")
                                (_    "indeterminate_check_box")))
                     (cb (eabp-box
                          (list (eabp-icon cb-icon :size 20))
                          :on-tap (eabp-action
                                   "checkbox.toggle"
                                   :args `((file . ,eabp-org-rich--file)
                                           (pos  . ,item-pos))))))
                (eabp-row cb
                          (eabp-box
                           (list (eabp-rich-text
                                  (cons (eabp-span lead-text)
                                        (or inline (list (eabp-span ""))))))
                           :weight 1)))
            ;; No checkbox, or no file context — plain text as before.
            (let* ((mark (pcase checkbox
                           ('on "☑ ") ('off "☐ ") ('trans "◪ ") (_ "")))
                   (lead (eabp-span (concat lead-text mark))))
              (eabp-rich-text (cons lead (or inline (list (eabp-span ""))))))))
         (rest-contents (delq para (copy-sequence contents)))
         (sub-nodes (delq nil (mapcar #'eabp-org-rich--element rest-contents))))
    (if sub-nodes
        (eabp-column head
                     (eabp-row (eabp-spacer :width 16)
                               (eabp-box (list (apply #'eabp-column sub-nodes)) :weight 1)))
      head)))

(defun eabp-org-rich--list (el)
  "Render a plain-list EL to a column of item nodes."
  (let ((items (delq nil
                     (mapcar (lambda (item)
                               (when (eq (org-element-type item) 'item)
                                 (eabp-org-rich--item item)))
                             (org-element-contents el)))))
    (when items (apply #'eabp-column items))))

(defun eabp-org-rich--paragraph-image (el)
  "If paragraph EL is just a single image link, return an `eabp-image' node."
  (let* ((contents (org-element-contents el))
         (non-blank (cl-remove-if (lambda (c) (and (stringp c) (string-blank-p c)))
                                  contents)))
    (when (and (= (length non-blank) 1)
               (consp (car non-blank))
               (eq (org-element-type (car non-blank)) 'link))
      (let* ((lnk (car non-blank))
             (url (eabp-org-rich--image-url (org-element-property :type lnk)
                                            (org-element-property :path lnk))))
        (when url (eabp-image url))))))

(defun eabp-org-rich--element (el)
  "Render one top-level org element EL to a node, or nil to skip it."
  (pcase (org-element-type el)
    ('paragraph
     (or (eabp-org-rich--paragraph-image el)
         (let ((spans (eabp-org-rich--inline (org-element-contents el) nil)))
           (when spans (eabp-rich-text spans)))))
    ('plain-list (eabp-org-rich--list el))
    ('src-block
     (eabp-markup (or (org-element-property :value el) "")
                  :syntax (or (org-element-property :language el) "text")))
    ((or 'example-block 'fixed-width)
     (eabp-markup (or (org-element-property :value el) "")))
    ('quote-block
     (let ((inner (delq nil (mapcar #'eabp-org-rich--element
                                    (org-element-contents el)))))
       (when inner (apply #'eabp-column inner))))
    ('table
     (eabp-markup (string-trim (org-element-interpret-data el)) :syntax "org"))
    ('horizontal-rule (eabp-divider))
    ;; Structural noise the reader handles elsewhere (properties drawer) or
    ;; that carries no display value on its own.
    ((or 'keyword 'comment 'comment-block 'planning
         'property-drawer 'drawer 'node-property)
     nil)
    (_
     (let ((txt (ignore-errors (string-trim (org-element-interpret-data el)))))
       (when (and (stringp txt) (not (string-empty-p txt)))
         (eabp-markup txt :syntax "org"))))))

(defun eabp-org-rich--top-elements (tree)
  "Return the top-level elements of parsed TREE, descending through a section."
  (let (out)
    (dolist (el (org-element-contents tree))
      (if (eq (org-element-type el) 'section)
          (setq out (append out (org-element-contents el)))
        (setq out (append out (list el)))))
    out))

;;;###autoload
(defun eabp-org-rich-body (body &optional base-dir file offset)
  "Parse org BODY string into a list of EABP rich/markup nodes.
Paragraphs and lists become native `rich_text'; code/tables/examples
fall back to highlighted `eabp-markup'. BASE-DIR resolves relative image
paths (pass the org file's directory).

FILE and OFFSET enable interactive elements (checkboxes): OFFSET maps
temp-buffer positions to real file positions (real = offset + temp).
Returns nil for empty input."
  (if (or (null body) (string-empty-p (string-trim body)))
      nil
    (let ((eabp-org-rich--file file)
          (eabp-org-rich--body-offset offset))
      (with-temp-buffer
        (insert body)
        (when (and base-dir (file-directory-p base-dir))
          (setq default-directory base-dir))
        (let ((org-inhibit-startup t)
              (org-element-use-cache nil))
          (delay-mode-hooks (org-mode))
          (let ((tree (org-element-parse-buffer)))
            (delq nil (mapcar #'eabp-org-rich--element
                              (eabp-org-rich--top-elements tree)))))))))

(provide 'eabp-org-rich)
;;; eabp-org-rich.el ends here

;;; ==================================================================
;;; BEGIN eabp-org-reader.el
;;; ==================================================================

;;; eabp-org-reader.el --- Foldable org outline renderer for EABP -*- lexical-binding: t; -*-

;; Renders an org buffer (or a single subtree) into a tree of EABP widgets:
;; each heading becomes an `eabp-collapsible' whose header is the org-highlighted
;; heading line and whose children are an optional (collapsed) PROPERTIES drawer,
;; the heading's own body as highlighted org text, and its child headings —
;; recursively. Folding is resolved entirely on the device (see the `collapsible'
;; widget), so the whole subtree is shipped once and folds without a round-trip.
;;
;; Two entry points feed the UI layer (eabp-org-ui):
;;   `eabp-org-reader-file'    — whole file, every top-level heading foldable
;;   `eabp-org-reader-subtree' — one heading's content inline + children foldable

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'eabp-widgets)
(require 'eabp-org-rich)

(defcustom eabp-org-reader-max-headings 400
  "Cap on headings rendered in one reader pass, to bound very large files."
  :type 'integer :group 'eabp)

;; ─── Parsing ───────────────────────────────────────────────────────────────────

(defun eabp-org-reader--record (pos next)
  "Build a record for the heading at POS, whose body ends at NEXT.
Returns a plist with :level :pos :line :props :body :body-start.
:body-start is the real-buffer position of the first non-blank char
in the body, used to map temp-buffer positions back for interactive
elements (checkboxes)."
  (save-excursion
    (goto-char pos)
    (let* ((comps (org-heading-components))
           (level (or (nth 0 comps) 1))
           (line (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))
           (props (ignore-errors (org-entry-properties pos 'standard)))
           (body-info
            (progn
              (goto-char pos)
              (ignore-errors (org-end-of-meta-data t))
              (let* ((b (min (point) next))
                     (raw (buffer-substring-no-properties b next))
                     (trimmed (string-trim-left raw "\\(?:[ \t]*[\n\r]\\)+"))
                     (trim-count (- (length raw) (length trimmed))))
                (list (string-trim-right trimmed) (+ b trim-count)))))
           (body (car body-info))
           (body-start (cadr body-info)))
      (list :level level :pos pos :line line :props props
            :body body :body-start body-start))))

(defun eabp-org-reader--collect (beg end include-first)
  "Collect heading records between BEG and END.
INCLUDE-FIRST non-nil includes the heading at BEG (used for subtrees)."
  (let (positions records)
    (save-excursion
      (goto-char beg)
      (when (and include-first (org-at-heading-p))
        (push (line-beginning-position) positions)
        (end-of-line))                  ; don't re-match this heading below
      (while (re-search-forward org-heading-regexp end t)
        (push (line-beginning-position) positions)))
    (setq positions (nreverse positions))
    (cl-loop for cell on positions
             for pos = (car cell)
             for next = (or (cadr cell) end)
             do (push (eabp-org-reader--record pos next) records))
    (nreverse records)))

(defun eabp-org-reader--build-tree (records)
  "Nest flat RECORDS into a tree by :level. Each node gains a :children list."
  (let* ((root (list :level 0 :children nil))
         (stack (list root)))
    (dolist (rec records)
      (let ((node (append rec (list :children nil)))
            (level (plist-get rec :level)))
        (while (>= (plist-get (car stack) :level) level)
          (pop stack))
        (let ((parent (car stack)))
          (plist-put parent :children
                     (append (plist-get parent :children) (list node))))
        (push node stack)))
    (plist-get root :children)))

;; ─── Rendering ──────────────────────────────────────────────────────────────────

(defun eabp-org-reader--props-node (props file pos)
  "A collapsed PROPERTIES drawer node for PROPS (an alist of KEY . VALUE)."
  (let ((text (mapconcat (lambda (kv) (format ":%s: %s" (car kv) (cdr kv)))
                         props "\n")))
    (eabp-collapsible (format "fold-props/%s/%s" file pos)
                      (eabp-text "PROPERTIES" 'label)
                      (list (eabp-text text 'mono))
                      :collapsed t)))

(defun eabp-org-reader--content-nodes (n file &optional skip-props)
  "Inline content nodes for tree node N: PROPERTIES drawer, body, child headings.
When SKIP-PROPS is non-nil, omit the PROPERTIES drawer (used when the
detail view already shows properties in its own section)."
  (let ((pos (plist-get n :pos))
        (props (plist-get n :props))
        (body (plist-get n :body))
        (body-start (plist-get n :body-start))
        (children (plist-get n :children)))
    (delq nil
          (append
           (when (and props (not skip-props))
             (list (eabp-org-reader--props-node props file pos)))
           (when (and body (not (string-empty-p body)))
             ;; Native rich text (emphasis, links, #tags) instead of the
             ;; monospace org highlighter; code/tables still fall back to it.
             ;; file + offset enable interactive checkboxes.
             (eabp-org-rich-body body (and file (file-name-directory file))
                                file (when body-start (1- body-start))))
           (mapcar (lambda (c) (eabp-org-reader--heading-node c file)) children)))))

(defun eabp-org-reader--heading-node (n file)
  "Render tree node N (and its subtree) to a foldable `eabp-collapsible'.
Long-pressing the header opens the heading detail view when FILE is available."
  (let* ((pos (plist-get n :pos))
         (ref (when file
                `((file . ,file) (pos . ,pos) (headline . "")))))
    (eabp-collapsible (format "fold/%s/%s" file pos)
                      (eabp-markup (plist-get n :line) :syntax "org")
                      (eabp-org-reader--content-nodes n file)
                      :on-long-tap (when ref
                                     (eabp-action "heading.tap" :args ref)))))

;; ─── Entry points ───────────────────────────────────────────────────────────────

(defun eabp-org-reader--cap (records)
  "Truncate RECORDS to `eabp-org-reader-max-headings'."
  (if (> (length records) eabp-org-reader-max-headings)
      (cl-subseq records 0 eabp-org-reader-max-headings)
    records))

(defun eabp-org-reader-file (file)
  "Render the whole org FILE to a list of foldable widget nodes.
Content before the first heading is not shown."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (let* ((records (eabp-org-reader--cap
                        (eabp-org-reader--collect (point-min) (point-max) nil)))
              (tree (eabp-org-reader--build-tree records)))
         (mapcar (lambda (n) (eabp-org-reader--heading-node n file)) tree))))))

(defun eabp-org-reader-subtree (file pos &optional skip-props)
  "Render the org subtree at POS in FILE.
The drilled-into heading's own PROPERTIES/body render inline (its title is
already in the top bar); its child headings render as foldable sections.
Returns a list of widget nodes (possibly empty).
When SKIP-PROPS is non-nil, the top-level PROPERTIES drawer is omitted."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (goto-char (min pos (point-max)))
       (unless (org-at-heading-p) (ignore-errors (org-back-to-heading t)))
       (let* ((beg (point))
              (end (save-excursion (org-end-of-subtree t t)))
              (records (eabp-org-reader--cap
                        (eabp-org-reader--collect beg end t)))
              (tree (eabp-org-reader--build-tree records))
              (root (car tree)))
         (when root
           (eabp-org-reader--content-nodes root file skip-props)))))))

(defun eabp-org-reader-refile-list (file)
  "Render all headings in FILE as a flat reorderable item list.
Returns a single `eabp-reorderable-list' node for refile mode."
  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (let* ((records (eabp-org-reader--cap
                        (eabp-org-reader--collect (point-min) (point-max) nil)))
              (items (mapcar (lambda (r)
                               `((label . ,(plist-get r :line))
                                 (level . ,(plist-get r :level))
                                 (pos   . ,(plist-get r :pos))
                                 (file  . ,file)))
                             records)))
         (eabp-reorderable-list
          items
          :on-reorder (eabp-action "heading.reorder"
                                   :args `((file . ,file)))))))))

(provide 'eabp-org-reader)
;;; eabp-org-reader.el ends here

;;; ==================================================================
;;; BEGIN eabp-org.el
;;; ==================================================================

;;; eabp-org.el --- EABP Org-Mode Data Extraction -*- lexical-binding: t; -*-

;; Provides functions to extract structured data from org-mode buffers.
;; This layer is pure Elisp and has no bridge dependencies.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-clock)
(require 'org-capture)
(require 'org-id)
(require 'cl-lib)

;; ─── Refresh coordination ──────────────────────────────────────────────────────

(defvar eabp-org--inhibit-save-refresh nil
  "When non-nil, the `after-save-hook' dashboard refresh is suppressed.
Bound around our own programmatic saves (heading edits, file saves) so an
explicit dashboard push isn't doubled by the save-hook firing on top.")

;; The dashboard pushes every view on every action (so navigation stays
;; instant and offline-capable), which means the expensive extractions here
;; — a full `org-agenda' run, an `org-map-entries' sweep — used to execute
;; on every chip tap and snackbar.  They are memoised now; this table is
;; dropped through `eabp-org-cache-invalidate', the single seam every
;; mutation path (heading actions, saves, capture, queue replay) already
;; calls.
(defvar eabp-org--cache (make-hash-table :test 'equal)
  "Memoised org extraction results.
Keys are built by `eabp-org--cache-key' and include today's date, so
day-relative readers (the agenda) roll over at midnight even without an
explicit invalidation.")

(defun eabp-org--cache-key (&rest parts)
  "Build a cache key from PARTS, scoped to today's date."
  (cons (format-time-string "%Y-%m-%d") parts))

(defmacro eabp-org--with-cache (key &rest body)
  "Memoise BODY's result in `eabp-org--cache' under KEY."
  (declare (indent 1))
  (let ((k (gensym "key")) (hit (gensym "hit")))
    `(let* ((,k ,key)
            (,hit (gethash ,k eabp-org--cache 'eabp-org--miss)))
       (if (eq ,hit 'eabp-org--miss)
           (puthash ,k (progn ,@body) eabp-org--cache)
         ,hit))))

(defun eabp-org-cache-invalidate ()
  "Drop every memoised org extraction.
Called by every mutation path (heading actions, phone/desktop saves,
capture, offline-queue drain), so the readers recompute from fresh org
state on the next dashboard push."
  (clrhash eabp-org--cache))

;; ─── Heading references ────────────────────────────────────────────────────────
;;
;; Every heading the UI lists carries a `ref' — a small, JSON-safe alist that
;; lets a later action (drill-in, todo-set, schedule, clock-in) find the same
;; heading again. The round-trip is: build with `eabp-org--heading-ref' while
;; point is on the heading, ship it to the device inside an action's `:args',
;; and resolve it back to a live marker with `eabp-org--resolve-ref'.

(defun eabp-org--heading-ref ()
  "Build a location ref for the org heading at point.
Returns an alist with `file'/`pos'/`headline', plus `id' when the entry
already has an ID property (never created here — we don't mutate files).
nil-valued keys are omitted so the alist serialises cleanly to JSON."
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

(defun eabp-org--resolve-ref (ref)
  "Resolve REF to a live marker at its org heading, or signal an error.
REF is an alist as built by `eabp-org--heading-ref' (extra keys such as a
consed-on `state' are ignored). Resolution tries, in order: the stable
`id' (survives edits anywhere), the recorded `pos' accepted only if its
headline still matches, then a headline search through the file."
  (let ((id (alist-get 'id ref))
        (file (alist-get 'file ref))
        (pos (alist-get 'pos ref))
        (headline (alist-get 'headline ref)))
    (or
     ;; 1. Stable org ID — robust against edits elsewhere in the file.
     (and (stringp id) (not (string-empty-p id))
          (ignore-errors (org-id-find id 'marker)))
     ;; 2. Recorded position, trusted only if the headline still matches.
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
     ;; 3. Headline search — the heading moved but still exists in the file.
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

(defun eabp-org--agenda-items (&optional span start-day)
  "Extract agenda items for SPAN (\\='day, \\='week, or \\='month).
START-DAY is an optional string (e.g. \"2026-11-01\") to start the agenda on.
Returns a list of alists representing agenda items.  Memoised; see
`eabp-org-cache-invalidate'."
  (eabp-org--with-cache (eabp-org--cache-key 'agenda (or span 'day) start-day)
    (eabp-org--agenda-items-1 span start-day)))

(defconst eabp-org--agenda-buffer "*EABP Agenda*"
  "Private buffer the agenda extraction builds into (and kills after).")

(defun eabp-org--agenda-items-1 (span start-day)
  "Uncached worker for `eabp-org--agenda-items'."
  (let ((org-agenda-span (or span 'day))
        (org-agenda-start-day start-day)
        (org-agenda-files (org-agenda-files))
        ;; Build into a private buffer so a user's open *Org Agenda* on the
        ;; desktop is never clobbered (and never killed) by an extraction.
        ;; `org-agenda-buffer-tmp-name' is the supported redirect: `org-agenda'
        ;; REBINDS `org-agenda-buffer-name' in its own let* and recomputes it,
        ;; so binding that variable directly gets shadowed — the build then
        ;; lands in *Org Agenda* while we look for (and fail to find, and fail
        ;; to kill) our own name.
        (org-agenda-buffer-tmp-name eabp-org--agenda-buffer)
        (org-agenda-sticky nil)
        (inhibit-redisplay t)
        items)
    (unwind-protect
        (save-window-excursion
          (let ((org-agenda-window-setup 'current-window))
            (org-agenda nil "a")
            (with-current-buffer eabp-org--agenda-buffer
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((marker (get-text-property (point) 'org-marker))
                   (tags (get-text-property (point) 'tags))
                   (time (get-text-property (point) 'time))
                   (type (get-text-property (point) 'type))
                   (date-abs (get-text-property (point) 'date))
                   ;; org ≥9.6 stores the gregorian (MONTH DAY YEAR) list
                   ;; directly; older code stored the absolute day number.
                   ;; Feeding the list to calendar-gregorian-from-absolute
                   ;; signals, which emptied the whole agenda.
                   (date-list (cond ((consp date-abs) date-abs)
                                    ((numberp date-abs)
                                     (calendar-gregorian-from-absolute date-abs))))
                   (date-str (when date-list (format "%04d-%02d-%02d" (nth 2 date-list) (nth 0 date-list) (nth 1 date-list)))))
              (when marker
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker)
                    (let* ((components (org-heading-components))
                           (todo (nth 2 components))
                           (priority (nth 3 components))
                           (headline (nth 4 components)))
                      (push `((headline . ,headline)
                              (todo . ,todo)
                              (priority . ,(if priority (char-to-string priority) nil))
                              (tags . ,(vconcat tags))
                              (file . ,(buffer-file-name))
                              (pos . ,(marker-position marker))
                              (time . ,time)
                              (date . ,date-str)
                              (type . ,(when type (format "%s" type)))
                              (ref . ,(eabp-org--heading-ref)))
                            items))))))
            (forward-line 1)))))
      ;; Kill by buffer object, not name, and even when extraction errored.
      (when-let ((buf (get-buffer eabp-org--agenda-buffer)))
        (kill-buffer buf)))
    (nreverse items)))

(defun eabp-org--todo-items (&optional files)
  "Extract TODO items from FILES (or agenda files).
Memoised; see `eabp-org-cache-invalidate'."
  (eabp-org--with-cache (eabp-org--cache-key 'todos files)
    (eabp-org--todo-items-1 files)))

(defun eabp-org--todo-items-1 (files)
  "Uncached worker for `eabp-org--todo-items'."
  (let (items)
    (org-map-entries
     (lambda ()
       (let* ((components (org-heading-components))
              (todo (nth 2 components))
              (priority (nth 3 components))
              (headline (nth 4 components))
              (tags (org-get-tags)))
         (when todo
           (push `((headline . ,headline)
                   (todo . ,todo)
                   (priority . ,(if priority (char-to-string priority) nil))
                   (tags . ,(vconcat tags))
                   (file . ,(buffer-file-name))
                   (pos . ,(point))
                   (ref . ,(eabp-org--heading-ref)))
                 items))))
     "TODO<>\"\"" (or files 'agenda))
    (nreverse items)))

(defun eabp-org--heading-item-at ()
  "Build a heading item alist for the org entry at point.
Same shape as `eabp-org--todo-items' entries (headline/todo/priority/
tags/file/pos/ref); used by the search layer."
  (let* ((components (org-heading-components))
         (todo (nth 2 components))
         (priority (nth 3 components))
         (headline (nth 4 components))
         (tags (org-get-tags)))
    `((headline . ,headline)
      (todo . ,todo)
      (priority . ,(if priority (char-to-string priority) nil))
      (tags . ,(vconcat tags))
      (file . ,(buffer-file-name))
      (pos . ,(point))
      (ref . ,(eabp-org--heading-ref)))))

(defun eabp-org--search-substring (query)
  "Case-insensitive substring search of agenda files for QUERY.
Matches headline text or any tag. Returns a list of heading items."
  (let ((q (downcase (string-trim query))) items)
    (org-map-entries
     (lambda ()
       (let* ((comps (org-heading-components))
              (headline (downcase (or (nth 4 comps) "")))
              (tags (org-get-tags)))
         (when (or (string-search q headline)
                   (cl-some (lambda (tg) (string-search q (downcase tg))) tags))
           (push (eabp-org--heading-item-at) items))))
     nil 'agenda)
    (nreverse items)))

(defun eabp-org--search (query)
  "Search agenda files for QUERY; return a list of heading items.
Uses `org-ql' when available, falling back to a substring match.
Memoised; see `eabp-org-cache-invalidate'."
  (if (string-empty-p (string-trim query))
      nil
    (eabp-org--with-cache (eabp-org--cache-key 'search query)
      (let ((ql-query (if (and (stringp query) (string-prefix-p "(" (string-trim query)))
                          (condition-case nil (read query) (error query))
                        query)))
        (if (fboundp 'org-ql-select)
            (condition-case nil
                (org-ql-select (org-agenda-files) ql-query
                               :action #'eabp-org--heading-item-at)
              (error (eabp-org--search-substring query)))
          (eabp-org--search-substring query))))))

(defun eabp-org--file-list ()
  "List of agenda files and basic stats."
  (mapcar (lambda (f) 
            `((file . ,f)
              (name . ,(file-name-nondirectory f))))
          (org-agenda-files)))

(defun eabp-org--heading-at (pos file)
  "Get full heading detail at POS in FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (let* ((components (org-heading-components))
             (todo (nth 2 components))
             (priority (nth 3 components))
             (headline (nth 4 components))
             (tags (org-get-tags))
             (props (org-entry-properties))
             ;; Basic body extraction:
             (end (save-excursion (org-end-of-subtree t t)))
             (body-start (save-excursion (forward-line 1) (point)))
             (body (if (< body-start end)
                       (buffer-substring-no-properties body-start end)
                     "")))
        `((headline . ,headline)
          (todo . ,todo)
          (priority . ,(if priority (char-to-string priority) nil))
          (tags . ,(vconcat tags))
          (properties . ,props)
          (body . ,body))))))

(defun eabp-org--parse-template-prompts (template-string)
  "Return the ordered field names to collect for TEMPLATE-STRING.
Each `%^{NAME}' or `%^{NAME|default}' contributes NAME (the default is
dropped from the label but honoured at fill time). A `%?' body position
adds a leading \"Headline\" field. Duplicates are removed."
  (let (prompts (start 0))
    (while (string-match "%\\^{\\([^}]+\\)}" template-string start)
      ;; Capture the match BEFORE `split-string' runs — it calls `string-match'
      ;; internally and would clobber the match data, leaving `match-end' wrong
      ;; and the loop spinning forever.
      (let ((spec (match-string 1 template-string))
            (end (match-end 0)))
        (push (string-trim (car (split-string spec "|"))) prompts)
        (setq start end)))
    (setq prompts (nreverse prompts))
    (delete-dups
     (if (string-match-p "%\\?" template-string)
         (cons "Headline" prompts)
       prompts))))

(defun eabp-org--capture-templates ()
  "Return list of capture templates."
  (mapcar (lambda (tmpl)
            (let ((key (nth 0 tmpl))
                  (desc (nth 1 tmpl))
                  (template-string (nth 4 tmpl)))
              `((key . ,key)
                (description . ,desc)
                (prompts . ,(vconcat (eabp-org--parse-template-prompts 
                                      (if (stringp template-string) template-string "")))))))
          org-capture-templates))

(defun eabp-org--fill-template (tmpl values)
  "Fill org capture TMPL string from VALUES (NAME -> user input alist).
`%?' becomes the Headline value; each `%^{NAME|default}' becomes the user
value for NAME, else its default, else empty. Any *other* interactive
escape that survives (`%^{…}' with no value, `%^t', `%^g', …) is then
stripped, so `org-capture' can never block on a minibuffer prompt — which
on the phone would hang behind the bridge."
  (let ((headline (or (cdr (assoc "Headline" values)) "")))
    ;; %? — free-form body position.
    (setq tmpl (replace-regexp-in-string "%\\?" headline tmpl t t))
    ;; %^{NAME|default} — scan the template's own tokens so NAME always
    ;; matches what `eabp-org--parse-template-prompts' produced.
    (setq tmpl (replace-regexp-in-string
                "%\\^{\\([^}]*\\)}"
                (lambda (m)
                  ;; M is the whole "%^{ … }" match; parse it directly rather
                  ;; than via match-data (unreliable inside this callback).
                  (let* ((spec (substring m 3 -1))
                         (bar (string-search "|" spec))
                         (name (string-trim (if bar (substring spec 0 bar) spec)))
                         (default (and bar (substring spec (1+ bar))))
                         (val (cdr (assoc name values))))
                    (cond ((and (stringp val) (not (string-empty-p val))) val)
                          ((stringp default) default)
                          (t ""))))
                tmpl t t))
    ;; Neutralise any remaining caret (interactive) escapes; leave plain
    ;; ones like %U %t %i %a for org to expand non-interactively.
    (replace-regexp-in-string "%\\^.?" "" tmpl t t)))

(defun eabp-org--do-capture (template-key values &optional extra-body)
  "Run capture for TEMPLATE-KEY with VALUES alist (NAME -> user input).
EXTRA-BODY, when non-empty, is appended below the filled template —
the carrier for text shared from another app via the share sheet."
  (let ((entry (assoc template-key org-capture-templates)))
    (when entry
      (let* ((tmpl (nth 4 entry))
             (filled (if (stringp tmpl)
                         (eabp-org--fill-template tmpl values)
                       tmpl))
             (filled (if (and (stringp filled)
                              (stringp extra-body)
                              (not (string-empty-p (string-trim extra-body))))
                         (concat filled "\n" (string-trim extra-body))
                       filled))
             ;; Shallow-copy the entry, swap in the filled template, and force
             ;; :immediate-finish so the capture buffer never waits for the
             ;; C-c C-c a phone user can't press.
             (new-entry (copy-sequence entry)))
        (setcar (nthcdr 4 new-entry) filled)
        (setcdr (nthcdr 4 new-entry)
                (append (nthcdr 5 new-entry) '(:immediate-finish t)))
        ;; `org-capture-entry' short-circuits template selection inside
        ;; `org-capture', so binding it to the FILLED copy is what makes the
        ;; pre-filled template the one that actually runs.  (Binding it to
        ;; the original — as this code once did — re-ran the raw %^{...}
        ;; prompts and double-asked the user through the bridge.)
        (let ((org-capture-entry new-entry))
          ;; Safety net: a fully pre-filled template shouldn't prompt at all,
          ;; but if any escape slips through, never let `org-capture' block
          ;; Emacs forever on a minibuffer the phone can't answer. `with-timeout'
          ;; fires even while a synchronous read is waiting.
          (with-timeout (30 (message "eabp: capture timed out (a prompt was left unanswered)"))
            (org-capture)))))))

(defun eabp-org--item-hm (time)
  "Normalize an agenda item's raw `time' property to \"HH:MM\", or nil.
The property comes straight from the agenda's time grid and looks like
\" 9:15......\" or \"14:00-15:00\" — leading space, no zero padding,
grid filler dots."
  (when (stringp time)
    (let ((s (string-trim time)))
      (when (string-match "\\`\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)" s)
        (format "%02d:%s"
                (string-to-number (match-string 1 s))
                (match-string 2 s))))))

(defun eabp-org--upcoming-reminders (&optional horizon-hours)
  "Timed agenda items within HORIZON-HOURS (default 24) as reminder specs.
Only items with a clock time qualify (a date alone isn't an alarm).
Each spec is ((id . STR) (at_ms . MS) (title . STR) (body . STR)),
ready for the companion's `reminders.set' frame."
  (let* ((horizon (* (or horizon-hours 24) 3600))
         (now (float-time))
         (items (append (eabp-org--agenda-items 'day nil)
                        (eabp-org--agenda-items
                         'day (format-time-string "%Y-%m-%d"
                                                  (time-add nil 86400)))))
         reminders)
    (dolist (it items)
      (let ((date (alist-get 'date it))
            (hm (eabp-org--item-hm (alist-get 'time it)))
            (headline (alist-get 'headline it))
            (type (alist-get 'type it)))
        (when (and (stringp date) hm)
          (let ((at (float-time (org-time-string-to-time
                                 (concat date " " hm)))))
            (when (and (> at now) (< (- at now) horizon))
              (push `((id . ,(format "%s/%s" date (or headline "?")))
                      (at_ms . ,(truncate (* at 1000)))
                      (title . ,(or headline "Org reminder"))
                      (body . ,(concat hm (when (stringp type)
                                            (concat " · " type)))))
                    reminders))))))
    (nreverse reminders)))

(defun eabp-org--clock-status ()
  "Current clock status."
  (when (org-clock-is-active)
    `((task . ,org-clock-current-task)
      (start . ,(float-time org-clock-start-time))
      (file . ,(buffer-file-name (marker-buffer org-clock-marker)))
      (pos . ,(marker-position org-clock-marker)))))

(defun eabp-org--recent-clocks (n)
  "Last N clocked tasks."
  (let (items)
    (dolist (m org-clock-history)
      (when (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (goto-char m)
            (let* ((components (org-heading-components))
                   (headline (nth 4 components)))
              (push `((headline . ,headline)
                      (file . ,(buffer-file-name))
                      (pos . ,(marker-position m))
                      (ref . ,(eabp-org--heading-ref)))
                    items))))))
    (cl-subseq (nreverse items) 0 (min n (length items)))))

(provide 'eabp-org)
;;; eabp-org.el ends here

;;; ==================================================================
;;; BEGIN eabp-keymap.el
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

;; ─── Command palette (Tier 0 default) ──────────────────────────────────────

(defun eabp-keymap--palette-candidates (buf)
  "Return an alist of (DISPLAY . KEY-DESC) for BUF's extracted bindings."
  (with-current-buffer buf
    (mapcar (lambda (b)
              (pcase-let ((`(,key ,cmd ,_source) b))
                (cons (format "%s  ·  %s" key (eabp-keymap--command-label cmd))
                      key)))
            (eabp-keymap--extract-bindings buf))))

(defun eabp-keymap--show-palette (buf)
  "Show a searchable command palette for BUF's keybindings.
Runs inside an action handler, so `completing-read' is bridged to the
companion as a live-filtering picker dialog.  The chosen binding's key
is executed in BUF; if that activates a transient, its Tier 1 pie menu
opens automatically (see `eabp-keymap--sync-pie')."
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
         (key (cdr (assoc choice candidates))))
    (when key
      (eabp-keymap--execute-key buf key))))

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
;;; BEGIN eabp-magit.el
;;; ==================================================================

;;; eabp-magit.el --- Curated Tier 1 magit pie menu -*- lexical-binding: t; -*-

;; The first curated Tier 1 radial menu: magit-status.  Four categories
;; fan out as a speed dial; each opens a pie of hand-labelled bindings.
;; Entries marked as prefixes (Commit, Push, Branch, …) are magit's
;; transient commands — running one activates the transient, and
;; `eabp-keymap--sync-pie' then pushes the live transient's own pie, so
;; the drill-in continues seamlessly into magit's real menus.
;;
;; This is pure data plus key dispatch: nothing here requires magit at
;; load time.  Keys are executed in the magit buffer through the same
;; allowlisted `eabp.keymap.run' action as everything else.

;;; Code:

(require 'eabp-keymap)

(defconst eabp-magit--menu
  '(("Stage" "add"
     ("s"   "Stage")
     ("u"   "Unstage")
     ("S"   "Stage all")
     ("U"   "Unstage all")
     ("k"   "Discard")
     ("g"   "Refresh"))
    ("Share" "sync"
     ("c"   "Commit" t)
     ("P"   "Push" t)
     ("F"   "Pull" t)
     ("f"   "Fetch" t)
     ("!"   "Run" t))
    ("Branch" "call_split"
     ("b"   "Branch" t)
     ("m"   "Merge" t)
     ("r"   "Rebase" t)
     ("z"   "Stash" t)
     ("t"   "Tag" t))
    ("Inspect" "history"
     ("l"   "Log" t)
     ("d"   "Diff" t)
     ("y"   "Refs" t)
     ("$"   "Process")))
  "Curated magit-status pie menu: (CATEGORY ICON (KEY LABEL [PREFIX-P])...).
PREFIX-P marks a transient prefix — the pie shows a ▸ and running it
drills into the live transient's own pie.")

(defun eabp-magit--binding-spec (entry buffer-name)
  "Build one pie binding spec from ENTRY (KEY LABEL [PREFIX-P])."
  (pcase-let ((`(,key ,label ,prefix-p) entry))
    (append
     `((key . ,key)
       (label . ,label)
       (action . ,(eabp-action "eabp.keymap.run"
                               :args `((buffer . ,buffer-name)
                                       (key . ,key))
                               :when-offline "drop")))
     (when prefix-p '((is_prefix . t))))))

(defun eabp-magit-pie-spec (buffer)
  "Curated Tier 1 pie-menu spec for magit BUFFER."
  (let ((buffer-name (buffer-name buffer)))
    `((center_label . "Magit")
      (buffer . ,buffer-name)
      (categories
       . ,(vconcat
           (mapcar
            (lambda (cat)
              (pcase-let ((`(,label ,icon . ,entries) cat))
                `((label . ,label)
                  (icon . ,icon)
                  (bindings . ,(vconcat
                                (mapcar (lambda (e)
                                          (eabp-magit--binding-spec e buffer-name))
                                        entries))))))
            eabp-magit--menu))))))

(eabp-keymap-register-tier1 'magit-status-mode #'eabp-magit-pie-spec)

(provide 'eabp-magit)
;;; eabp-magit.el ends here

;;; ==================================================================
;;; BEGIN eabp-emacs-ui.el
;;; ==================================================================

;;; eabp-emacs-ui.el --- EABP Emacs REPL & Buffer Viewer -*- lexical-binding: t; -*-

;; Provides an in-app Emacs interaction layer:
;;   * Buffer viewer (switch buffers, see content)
;;   * *Messages* tail
;;   * M-x command runner (interactive command dialog)
;;   * Elisp eval REPL
;;
;; Integrates with the dashboard as additional bottom-bar tabs.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer)
(require 'cl-lib)

;; The generic (Tier 0) buffer renderer re-pushes the showing surface after a
;; tap mutates a buffer.  Point it at the dashboard host (resolved lazily at
;; call time, so the org-ui load order doesn't matter here).
(setq eabp-buffer-refresh-function #'eabp-org-ui-push-dashboard)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar eabp-emacs-ui--viewing-buffer nil
  "Name of the buffer currently being viewed, or nil for the buffer list.")

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
bespoke translator."
  (let ((buf (get-buffer buffer-name)))
    (if (not buf)
        (eabp-text (format "Buffer '%s' not found." buffer-name) 'body)
      (apply #'eabp-lazy-column (eabp-render-buffer buf)))))

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
Runs as :after advice on `message'; never signals, never recurses."
  (when (and eabp-forward-messages
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

(defun eabp-emacs-ui--eval-body ()
  "Build UI for the elisp eval REPL.
History (newest first) scrolls in a weighted region; the input field and
Eval button stay pinned below it, so they can never be pushed off-screen
by a long history — the layout bug the old plain-column version had."
  (let* ((history-cards (mapcar #'eabp-emacs-ui--eval-card
                                eabp-emacs-ui--eval-history))
         (input-field (eabp-text-input "eval-input"
                                       :label "Elisp Expression"
                                       :hint "(message \"hello\")"
                                       :multi-line t
                                       :min-lines 2
                                       :max-lines 6
                                       :monospace t
                                       :syntax "elisp"
                                       :on-submit (eabp-action "emacs.eval.submit"))))
    (eabp-column
     (eabp-box
      (list (if history-cards
                (apply #'eabp-lazy-column history-cards)
              (eabp-empty-state :icon "code"
                                :title "Elisp REPL"
                                :caption "Results appear here, newest first.")))
      :weight 1)
     input-field
     (eabp-row
      (eabp-spacer :weight 1)
      (eabp-button "Eval" (eabp-action "emacs.eval.submit"))))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

;; Buffer list / view
(eabp-defaction "emacs.buffer.view"
  (lambda (args _)
    (setq eabp-emacs-ui--viewing-buffer (alist-get 'buffer args))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "emacs.buffer.back"
  (lambda (_ _)
    (setq eabp-emacs-ui--viewing-buffer nil)
    (eabp-org-ui-push-dashboard)))

(defun eabp-emacs-ui--eval-record (input output)
  "Push (INPUT . OUTPUT) onto the eval history, bounded by the max."
  (push (cons input output) eabp-emacs-ui--eval-history)
  (when (> (length eabp-emacs-ui--eval-history) eabp-emacs-ui-eval-history-max)
    (setcdr (nthcdr (1- eabp-emacs-ui-eval-history-max)
                    eabp-emacs-ui--eval-history)
            nil)))

;; Eval REPL
(eabp-defaction "emacs.eval.submit"
  (lambda (args _)
    ;; The Eval button carries no value, so fall back to the field's latest
    ;; value recorded by `state.changed' (same pattern as the capture form).
    (let* ((expr (or (alist-get 'value args)
                     (eabp-ui-state "eval-input")
                     ""))
           (result (condition-case err
                       ;; Wrap in progn so multi-sexp input evaluates fully
                       ;; (bare `read' silently ignored everything after the
                       ;; first form).
                       (let ((val (eval (car (read-from-string
                                              (format "(progn %s\n)" expr)))
                                        t)))
                         (format "%S" val))
                     (error (format "ERROR: %s" (error-message-string err))))))
      (unless (string-empty-p (string-trim expr))
        (eabp-emacs-ui--eval-record expr result))
      (eabp-org-ui-push-dashboard))))

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
        (eabp-org-ui-push-dashboard "eval")))))

;; Messages refresh
(eabp-defaction "emacs.messages.refresh"
  (lambda (_ _)
    (eabp-org-ui-push-dashboard)))

;; Clear eval history
(eabp-defaction "emacs.eval.clear"
  (lambda (_ _)
    (setq eabp-emacs-ui--eval-history nil)
    (eabp-org-ui-push-dashboard)))

(provide 'eabp-emacs-ui)
;;; eabp-emacs-ui.el ends here

;;; ==================================================================
;;; BEGIN eabp-complete.el
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

;; ─── Shadow buffers ──────────────────────────────────────────────────────────

(defun eabp-complete--mode-for (file)
  "The major mode FILE would get from `auto-mode-alist', or `fundamental-mode'.
Never visits FILE — the mode is chosen from the name alone."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (if (and (symbolp mode) mode (fboundp mode)) mode 'fundamental-mode)))

(defun eabp-complete--shadow-buffer (file)
  "Get or create the hidden shadow buffer for FILE.
The buffer carries FILE's major mode so the right capfs are live, but
mode hooks are delayed: no LSP client, flycheck, or other machinery
spins up over a throwaway completion buffer.  The leading space in the
name keeps it out of buffer lists and disables undo."
  (let ((name (format " *eabp-complete: %s*" file)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (delay-mode-hooks (funcall (eabp-complete--mode-for file)))
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
         ;; An empty prefix would ask the table for *everything* (the whole
         ;; obarray in elisp buffers) — cheap to refuse, useless to answer.
         ;; Lazy tables can signal when queried (ispell again), hence the
         ;; condition-case: a broken table degrades to the fallback.
         (cands (and prefix (not (string-empty-p prefix))
                     (condition-case nil
                         (all-completions prefix table
                                          (plist-get props :predicate))
                       (error nil)))))
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
handler so tests can call it directly."
  (with-current-buffer (eabp-complete--shadow-buffer file)
    (erase-buffer)
    (insert text)
    (goto-char (min (1+ (max 0 (truncate cursor))) (point-max)))
    (eabp-complete--collect)))

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
            (cursor (alist-get 'cursor args)))
        (when (and (stringp file) (stringp text) (numberp cursor))
          (let ((result (condition-case err
                            (eabp-complete-in-text file text cursor)
                          (error (message "EABP complete failed: %s"
                                          (error-message-string err))
                                 nil))))
            ;; Always reply, even empty, so the phone can clear its strip.
            (eabp-send "completions.show"
                       `((id . ,file)
                         (request_id . ,(or req 0))
                         (prefix . ,(or (car result) ""))
                         (candidates . ,(vconcat (cdr result)))))))))))

(provide 'eabp-complete)
;;; eabp-complete.el ends here

;;; ==================================================================
;;; BEGIN eabp-files.el
;;; ==================================================================

;;; eabp-files.el --- File browser & editor for EABP -*- lexical-binding: t; -*-

;; A dired-style file browser plus a plain-text editor, rendered through
;; EABP surfaces. Together with the eval tab this is the self-hosting
;; plumbing: init.el (and anything else) can be edited, saved, and
;; reloaded from the phone, so the desktop side never needs touching
;; once eabp is in the init file.
;;
;; Views contributed to the dashboard (wired in eabp-org-ui):
;;   "files" — root list / directory listing
;;   "edit"  — editor for `eabp-files--file' (present while a file is open)

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-buffer) ; Tier 0 renderer + the major-mode→skin registry
(require 'eabp-complete) ; capf bridge: the editor's `complete' flag
(require 'eabp-org)   ; for eabp-org--inhibit-save-refresh / cache invalidation
(require 'eabp-org-reader)
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

(defvar eabp-files--read-mode nil
  "When non-nil, org files open in the foldable reader instead of the editor.")

(defvar eabp-files--refile-mode nil
  "When non-nil, org reader shows a flat drag-to-reorder heading list.")

;; ─── Browser view (dired under the hood) ─────────────────────────────────────

;; The directory listing is backed by a real dired buffer — the standard Emacs
;; file engine — but presented through a Tier-1 card skin registered for
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
  "Tier-1 dired skin: render dired BUFFER as a list of file/dir cards.
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
\(`eabp-files--current-dir'), so it matches the Buffers-tab listing."
  (let ((buf (eabp-files--dired-buffer (eabp-files--current-dir))))
    (if buf
        (apply #'eabp-lazy-column (eabp-render-buffer buf))
      (eabp-empty-state :icon "info"
                        :title "Can't open folder"
                        :caption "Outside the allowed roots, or unreadable."))))

;; ─── Editor view ─────────────────────────────────────────────────────────────

(defun eabp-files--org-p (file)
  "Non-nil when FILE is an org file."
  (and file (string-match-p "\\.org\\'" file)))

(defun eabp-files-editor-body ()
  "Build the editor view for `eabp-files--file'.
Org files in read mode render the foldable outline reader; otherwise the
plain-text editor."
  (let ((file eabp-files--file))
    (if (not (and file (file-readable-p file)))
        (eabp-column (eabp-text "No file open." 'body))
      (if (and eabp-files--read-mode (eabp-files--org-p file))
          (if eabp-files--refile-mode
              (or (eabp-org-reader-refile-list file)
                  (eabp-text "No headings to show." 'caption))
            (apply #'eabp-lazy-column (or (eabp-org-reader-file file)
                                          (list (eabp-text "No headings to show." 'caption)))))
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
                      :on-save (eabp-action "files.save"
                                            :args `((file . ,file))
                                            :when-offline "queue"
                                            :dedupe (concat "save/" file)))))))))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(declare-function eabp-org-ui-push-dashboard "eabp-org-ui")
(declare-function eabp-org-ui-snackbar "eabp-org-ui")

(eabp-defaction "files.cd"
  (lambda (args _)
    (let ((dir (alist-get 'dir args)))
      (setq eabp-files--dir
            (and (stringp dir)
                 (file-directory-p dir)
                 (eabp-files--within-root-p dir)
                 (file-name-as-directory dir)))
      (eabp-org-ui-push-dashboard nil :switch-to "files"))))

(eabp-defaction "files.open"
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file)
                 (file-readable-p file)
                 (eabp-files--within-root-p file))
        (setq eabp-files--file (expand-file-name file))
        ;; Org files open reader-first; everything else in the editor.
        (setq eabp-files--read-mode (eabp-files--org-p eabp-files--file))
        (eabp-org-ui-push-dashboard nil :switch-to "edit")))))

(eabp-defaction "files.toggle-read"
  (lambda (_ _)
    (setq eabp-files--read-mode (not eabp-files--read-mode))
    (eabp-org-ui-push-dashboard nil :switch-to "edit")))

(eabp-defaction "files.toggle-refile"
  (lambda (_ _)
    (setq eabp-files--refile-mode (not eabp-files--refile-mode))
    (eabp-org-ui-push-dashboard nil :switch-to "edit")))

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
                  (eabp-org-ui-snackbar
                   (format "Deleted %s" (file-name-nondirectory
                                         (directory-file-name file)))))
              (error (eabp-org-ui-snackbar
                      (format "Delete failed: %s" (error-message-string err)))))
          (eabp-org-ui-snackbar "Delete cancelled")))
      (eabp-org-ui-push-dashboard nil :switch-to "files"))))

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
            (eabp-org-ui-snackbar "Rename cancelled"))
           (t
            (let ((target (expand-file-name
                           new (file-name-directory (directory-file-name file)))))
              (cond
               ((not (eabp-files--within-root-p target))
                (eabp-org-ui-snackbar "Rename rejected (outside roots)"))
               ((file-exists-p target)
                (eabp-org-ui-snackbar "Target already exists"))
               (t
                (condition-case err
                    (progn (rename-file file target)
                           (eabp-org-ui-snackbar (format "Renamed to %s" new)))
                  (error (eabp-org-ui-snackbar
                          (format "Rename failed: %s"
                                  (error-message-string err)))))))))))
        (eabp-org-ui-push-dashboard nil :switch-to "files")))))

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
        (eabp-org-ui-snackbar "No directory"))
       ((string-empty-p name)
        (eabp-org-ui-snackbar "Name required"))
       ;; Single segment only — no separators or parent traversal.
       ((string-match-p "/" name)
        (eabp-org-ui-snackbar "Name can't contain '/'"))
       (t
        (let ((target (expand-file-name name dir)))
          (cond
           ((not (eabp-files--within-root-p target))
            (eabp-org-ui-snackbar "Rejected (outside roots)"))
           ((file-exists-p target)
            (eabp-org-ui-snackbar "Already exists"))
           (t
            (condition-case err
                (progn
                  (if (equal type "dir")
                      (make-directory target)
                    (write-region "" nil target nil 'silent))
                  (eabp-ui-state-clear "files-new-name")
                  (eabp-org-ui-snackbar (format "Created %s" name)))
              (error (eabp-org-ui-snackbar
                      (format "Create failed: %s"
                              (error-message-string err))))))))))
      (eabp-dismiss-dialog)
      (eabp-org-ui-push-dashboard nil :switch-to "files"))))

(eabp-defaction "files.save"
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (value (alist-get 'value args)))
      (cond
       ((not (and (stringp file) (stringp value)
                  (eabp-files--within-root-p file)))
        (eabp-org-ui-snackbar "Save rejected"))
       (t
        (condition-case err
            (progn
              ;; Route through a live buffer when one exists so modes,
              ;; hooks, and desktop Emacs all see the change coherently.
              (if-let ((buf (get-file-buffer file)))
                  (with-current-buffer buf
                    (erase-buffer)
                    (insert value)
                    (let ((eabp-org--inhibit-save-refresh t)
                          (save-silently t))
                      (save-buffer)))
                (let ((eabp-org--inhibit-save-refresh t))
                  (write-region value nil file)))
              (when (fboundp 'eabp-org-cache-invalidate)
                (eabp-org-cache-invalidate))
              (eabp-org-ui-snackbar
               (format "Saved %s" (file-name-nondirectory file))))
          (error
           (eabp-org-ui-snackbar
            (format "Save failed: %s" (error-message-string err))))))))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "config.reload"
  (lambda (_ _)
    (condition-case err
        (progn
          (load user-init-file)
          (eabp-org-ui-snackbar "Config reloaded ✓"))
      (error
       (eabp-org-ui-snackbar
        (format "Reload error: %s" (error-message-string err)))))
    (eabp-org-ui-push-dashboard)))

(provide 'eabp-files)
;;; eabp-files.el ends here
;;; ==================================================================
;;; BEGIN eabp-org-ui.el
;;; ==================================================================

;;; eabp-org-ui.el --- EABP Org-Mode UI Screens -*- lexical-binding: t; -*-

;; Builds EABP surface specs for the org-client and handles inbound actions.

;;; Code:

(require 'eabp)
(require 'eabp-surfaces)
(require 'eabp-widgets)
(require 'eabp-org)
(require 'eabp-org-reader)
(require 'eabp-files)
(require 'eabp-keymap)
(require 'eabp-magit)
(require 'cl-lib)

(defvar eabp-org-ui--current-tab "agenda"
  "Currently active tab in the dashboard.")

(defvar eabp-org-ui--detail-ref nil
  "Reference alist (id/file/pos/headline) of the heading being viewed, or nil.")

(defvar eabp-org-ui--detail-read-mode t
  "When non-nil, detail view shows the foldable reader instead of the editor.")

(defvar eabp-org-ui--tasks-filter "ALL"
  "Current filter for the Tasks tab.")

(defvar eabp-org-ui--search-query ""
  "Last submitted query for the Search view.")

(defcustom eabp-org-custom-agendas nil
  "Alist of custom agenda views (Name . Query) for EABP."
  :type '(alist :key-type string :value-type string)
  :group 'eabp)

(defvar eabp-org-ui--search-results nil
  "Cached heading items from the last search.")

(defvar eabp-org-ui--snackbar nil
  "Transient snackbar text, consumed (and cleared) by the next dashboard push.")

(defun eabp-org-ui-snackbar (text)
  "Queue TEXT to show as a snackbar on the next dashboard push.
Note: the companion re-shows a snackbar only when the text *changes*,
so two identical messages back-to-back display once."
  (setq eabp-org-ui--snackbar text))

;; Forward-declare so the dashboard can reference it before eabp-emacs-ui loads
(defvar eabp-emacs-ui--viewing-buffer nil)

;; ─── Main Dashboard ──────────────────────────────────────────────────────────

(cl-defun eabp-org-ui-push-dashboard (&optional tab &key switch-to)
  "Push the dashboard as a multi-view surface.
Every tab is rendered as a named view in one push; the companion
switches between them locally (the `view.switch' builtin), so tab
navigation never waits on Emacs. TAB switches the logical tab before
building. SWITCH-TO additionally forces the companion onto that view
\(used when a push *is* the navigation, e.g. opening a detail)."
  (when tab
    (unless (equal tab eabp-org-ui--current-tab)
      (setq eabp-emacs-ui--viewing-buffer nil))
    (setq eabp-org-ui--current-tab tab))

  ;; Require the emacs-ui lazily (avoids load-order issues)
  (require 'eabp-emacs-ui)

  (condition-case err
      (let* ((active (eabp-org-ui--active-view))
             (target (or switch-to tab))
             ;; A navigation push lands the user on TARGET, so feedback
             ;; (e.g. "Saved init.el") must attach there, not to the view
             ;; they're leaving.
             (snack-view (or target active))
             (snackbar (prog1 eabp-org-ui--snackbar
                         (setq eabp-org-ui--snackbar nil)))
             (views (mapcar
                     (lambda (name)
                       (cons (intern name)
                             (eabp-org-ui--view name
                                                (when (equal name snack-view)
                                                  snackbar))))
                     (eabp-org-ui--view-names))))
        (eabp-surface-push
         "app:dashboard"
         `((views . ,views)
           (initial_view . ,active))
         nil nil
         ;; Force the companion onto a view only when this push *is* a
         ;; navigation (tab arg or detail open) — background refreshes must
         ;; not yank the user off whatever they're looking at.
         target)
        ;; Piggyback the cheap companions of a dashboard push: upcoming
        ;; reminder alarms and the home-screen widget. Both are memo-guarded
        ;; so unchanged data sends nothing.
        (eabp-org-ui--sync-reminders)
        (eabp-org-ui--push-widget))
    (error
     (message "EABP dashboard push failed: %s" (error-message-string err)))))

(defvar eabp-org-ui--last-reminders 'unset
  "Reminder list from the previous sync, to suppress identical sends.")

(defun eabp-org-ui--sync-reminders ()
  "Send upcoming timed items to the companion as exact-alarm reminders."
  (let ((rems (condition-case nil (eabp-org--upcoming-reminders) (error nil))))
    (unless (equal rems eabp-org-ui--last-reminders)
      (setq eabp-org-ui--last-reminders rems)
      (eabp-send "reminders.set" `((reminders . ,(vconcat rems)))))))

(defvar eabp-org-ui--last-widget 'unset
  "Widget lines from the previous push, to suppress identical pushes.")

(defun eabp-org-ui--widget-lines ()
  "Today's agenda as short \"HH:MM  Headline\" strings for the widget."
  (mapcar (lambda (it)
            (let ((hm (eabp-org--item-hm (alist-get 'time it))))
              (concat (if hm (concat hm "  ") "")
                      (or (alist-get 'headline it) ""))))
          (seq-take (condition-case nil
                        (eabp-org--agenda-items 'day nil)
                      (error nil))
                    6)))

(defun eabp-org-ui--push-widget ()
  "Push the `widget:agenda' surface backing the home-screen widget."
  (let ((lines (eabp-org-ui--widget-lines)))
    (unless (equal lines eabp-org-ui--last-widget)
      (setq eabp-org-ui--last-widget lines)
      (eabp-surface-push
       "widget:agenda"
       `((title . ,(format-time-string "Agenda · %a %b %d"))
         (lines . ,(vconcat lines)))))))

(defun eabp-org-ui--active-view ()
  "Name of the view that should be considered active for this push."
  (cond (eabp-org-ui--detail-ref "detail")
        (t eabp-org-ui--current-tab)))

(defun eabp-org-ui--view-names ()
  "All view names included in a dashboard push."
  (append '("agenda" "tasks" "clock" "buffers" "eval" "files" "search"
            "settings" "messages")
          (when eabp-files--file '("edit"))
          (when eabp-org-ui--detail-ref '("detail"))))

(defun eabp-org-ui--view (name snackbar)
  "Build the full scaffold view NAME. SNACKBAR is attached when non-nil."
  (let* ((is-detail (equal name "detail"))
         (is-edit (equal name "edit"))
         (is-files (equal name "files"))
         (is-search (equal name "search"))
         (is-buffer-view (and (equal name "buffers")
                              eabp-emacs-ui--viewing-buffer))
         (is-settings (equal name "settings"))
         (is-messages (equal name "messages"))
         (is-tab (and (not is-buffer-view)
                      (member name '("agenda" "tasks" "clock" "buffers" "eval" "files"))))
         (body (condition-case body-err
                   (cond
                    (is-detail
                     (eabp-org-ui--detail-body eabp-org-ui--detail-ref))
                    (is-edit
                     (eabp-files-editor-body))
                    (is-files
                     (eabp-files-browser-body))
                    (is-search
                     (eabp-org-ui--search-body))
                    (is-buffer-view
                     (eabp-emacs-ui--buffer-view-body eabp-emacs-ui--viewing-buffer))
                    (t
                     (pcase name
                       ("agenda"   (eabp-org-ui--agenda-body))
                       ("tasks"    (eabp-org-ui--tasks-body))
                       ("clock"    (eabp-org-ui--clock-body))
                       ("buffers"  (eabp-emacs-ui--buffer-list-body))
                       ("eval"     (eabp-emacs-ui--eval-body))
                       ("settings" (eabp-org-ui--settings-body))
                       ("messages" (eabp-emacs-ui--messages-body))
                       (_          (eabp-text "Unknown tab")))))
                 (error
                  (eabp-column
                   (eabp-text "Error building tab" 'title)
                   (eabp-text (format "%s" (error-message-string body-err)) 'body)))))
         (top-bar (cond
                   (is-detail
                    ;; Back is pure navigation: builtin = instant, local,
                    ;; works offline. heading.back stays registered for
                    ;; compatibility but nothing emits it anymore.
                    (eabp-top-bar "Detail"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)
                                  :actions (list
                                            (eabp-icon-button
                                             "note_add"
                                             (eabp-action "heading.add-note"
                                                          :args eabp-org-ui--detail-ref
                                                          :when-offline "drop")
                                             :content-description "Add note")
                                            (eabp-icon-button
                                             "drive_file_move"
                                             (eabp-action "heading.refile"
                                                          :args eabp-org-ui--detail-ref
                                                          :when-offline "drop")
                                             :content-description "Refile")
                                            (eabp-icon-button
                                             "archive"
                                             (eabp-action "heading.archive"
                                                          :args eabp-org-ui--detail-ref
                                                          :when-offline "drop")
                                             :content-description "Archive")
                                            (eabp-icon-button
                                             (if eabp-org-ui--detail-read-mode "edit" "visibility")
                                             (eabp-action "detail.toggle-read")
                                             :content-description
                                             (if eabp-org-ui--detail-read-mode "Edit" "Read")))))
                   (is-edit
                    (eabp-top-bar (if eabp-files--file
                                      (file-name-nondirectory eabp-files--file)
                                    "Editor")
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view "files")
                                  :actions (when (eabp-files--org-p eabp-files--file)
                                             (delq nil
                                                   (list
                                                    (when eabp-files--read-mode
                                                      (eabp-icon-button
                                                       (if eabp-files--refile-mode "visibility" "swap_vert")
                                                       (eabp-action "files.toggle-refile")
                                                       :content-description
                                                       (if eabp-files--refile-mode "Reader" "Refile")))
                                                    (eabp-icon-button
                                                     (if eabp-files--read-mode "edit" "visibility")
                                                     (eabp-action "files.toggle-read")
                                                     :content-description
                                                     (if eabp-files--read-mode "Edit" "Read")))))))
                   ((and is-files eabp-files--dir)
                    (eabp-top-bar (abbreviate-file-name eabp-files--dir)
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-action "files.cd" :args '((dir . :null)))))
                   (is-search
                    (eabp-top-bar "Search"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)))
                   (is-settings
                    (eabp-top-bar "Settings"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)))
                   (is-messages
                    (eabp-top-bar "Messages"
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-org-ui--switch-view
                                               eabp-org-ui--current-tab)
                                  :actions (list
                                            (eabp-icon-button
                                             "refresh"
                                             (eabp-action "emacs.messages.refresh"
                                                          :when-offline "drop")
                                             :content-description "Refresh"))))
                   (is-buffer-view
                    ;; Content swap within the buffers view: stays an
                    ;; Emacs round-trip (the list must be rebuilt).
                    (eabp-top-bar (or eabp-emacs-ui--viewing-buffer "Buffer")
                                  :nav-icon "arrow_back"
                                  :nav-action (eabp-action "emacs.buffer.back")))
                   (t
                    (eabp-top-bar (capitalize name)
                                  :actions (append
                                            ;; A top-bar Eval button: always
                                            ;; reachable even if the input grows.
                                            (when (equal name "eval")
                                              (list (eabp-icon-button
                                                     "play_arrow"
                                                     (eabp-action "emacs.eval.submit")
                                                     :content-description "Eval")))
                                            (list
                                             (eabp-icon-button
                                              "search"
                                              (eabp-org-ui--switch-view "search")
                                              :content-description "Search")
                                             (eabp-icon-button "terminal"
                                                               (eabp-action "emacs.mx.show"))
                                             (eabp-icon-button "refresh"
                                                               (eabp-action "dashboard.refresh"
                                                                            :when-offline "drop"))))))))
         (fab (cond
               ((or is-detail is-edit is-search is-settings is-messages) nil)
               ;; Buffer view: keyboard FAB opens the radial keymap menu
               (is-buffer-view
                (eabp-fab "keyboard"
                          :on-tap (eabp-action "eabp.keymap.show"
                                   :args `((buffer . ,eabp-emacs-ui--viewing-buffer))
                                   :when-offline "drop")))
               ;; Files: a create FAB — the view always shows a directory now
               ;; (the landing dir or a subdirectory), so it's always offered.
               (is-files
                (eabp-fab "add" :label "New"
                          :on-tap (eabp-action "files.new")))
               ((equal name "eval")
                (eabp-fab "delete" :label "Clear"
                          :on-tap (eabp-action "emacs.eval.clear")))
               (t
                (eabp-fab "add" :label "Capture"
                          :on-tap (eabp-action "org.capture.show")))))
         (drawer (when is-tab (eabp-org-ui--drawer)))
         (bottom-bar
          (when is-tab
            (eabp-bottom-bar
             (mapcar (lambda (spec)
                       (pcase-let ((`(,icon ,label ,view) spec))
                         (eabp-nav-item icon label
                                        (eabp-org-ui--switch-view view)
                                        :selected (equal name view))))
                     '(("event" "Agenda" "agenda")
                       ("checklist" "Tasks" "tasks")
                       ("schedule" "Clock" "clock")
                       ("folder_open" "Files" "files")
                       ("code" "Eval" "eval")))))))
    `((children . ,(vector (eabp-scaffold :top-bar top-bar :body body
                                          :fab fab :bottom-bar bottom-bar
                                          :drawer drawer
                                          :snackbar snackbar
                                          ;; Tab views support pull-to-refresh;
                                          ;; navigation/detail views don't (a
                                          ;; stray pull mustn't rebuild them).
                                          :on-refresh
                                          (when is-tab
                                            (eabp-action "dashboard.refresh"
                                                         :when-offline "drop"))))))))

(defun eabp-org-ui--drawer ()
  "The navigation drawer shown on tab views."
  (eabp-drawer
   (list
    (eabp-drawer-item "view_list" "Buffers"
                      (eabp-org-ui--switch-view "buffers"))
    (eabp-drawer-item "history" "Messages"
                      (eabp-org-ui--switch-view "messages"))
    (eabp-drawer-item "terminal" "M-x"
                      (eabp-action "emacs.mx.show"))
    (eabp-drawer-item "sync" "Reload config"
                      (eabp-action "config.reload"))
    (eabp-drawer-item "settings" "Settings"
                      (eabp-org-ui--switch-view "settings"))
    (eabp-drawer-item "refresh" "Refresh data"
                      (eabp-action "dashboard.refresh" :when-offline "drop")))
   :header "EABP"))

(defun eabp-org-ui--switch-view (view)
  "Action descriptor for the companion-local `view.switch' builtin."
  `((builtin . "view.switch") (view . ,view)))

;; ─── Tab Bodies ──────────────────────────────────────────────────────────────

;; ── Agenda navigation ──
;; The agenda is anchored on a date (UI state "agenda-anchor", nil = today).
;; The ‹ › buttons shift the anchor by one day/week/month according to the
;; active span, and the anchor feeds `eabp-org--agenda-items' as START-DAY —
;; whose cache keys already include it, so each visited range memoises
;; independently.

(defun eabp-org-ui--agenda-anchor ()
  "The agenda's anchor date as \"YYYY-MM-DD\"; today when unset."
  (let ((a (eabp-ui-state "agenda-anchor")))
    (if (and (stringp a) (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" a))
        a
      (format-time-string "%Y-%m-%d"))))

(defun eabp-org-ui--shift-date (date n unit)
  "Shift DATE (\"YYYY-MM-DD\") by N UNITs (`day', `week', or `month').
Month arithmetic clamps the day into the target month, so Jan 31 + 1
month is Feb 28, not an invalid date."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (if (eq unit 'month)
        (let* ((total (+ (* 12 y) (1- m) n))
               (ny (/ total 12))
               (nm (1+ (% total 12))))
          (format "%04d-%02d-%02d" ny nm
                  (min d (calendar-last-day-of-month nm ny))))
      (let ((days (* n (if (eq unit 'week) 7 1))))
        ;; Noon avoids DST-transition off-by-one-day surprises.
        (format-time-string "%Y-%m-%d"
                            (time-add (encode-time 0 0 12 d m y)
                                      (* days 86400)))))))

(defun eabp-org-ui--format-date (date fmt)
  "Render DATE (\"YYYY-MM-DD\") through `format-time-string' FMT."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (format-time-string fmt (encode-time 0 0 12 d m y))))

(defun eabp-org-ui--agenda-nav-row (mode anchor)
  "The ‹ [range label] [today] › navigation row for the agenda header."
  (let* ((today (format-time-string "%Y-%m-%d"))
         (at-today (pcase mode
                     ("month" (equal (substring anchor 0 7) (substring today 0 7)))
                     (_ (equal anchor today))))
         (label (pcase mode
                  ("month" (eabp-org-ui--format-date anchor "%B %Y"))
                  ("week" (concat "Week of "
                                  (eabp-org-ui--format-date anchor "%b %d")))
                  (_ (if at-today
                         (concat "Today · " (eabp-org-ui--format-date anchor "%a, %b %d"))
                       (eabp-org-ui--format-date anchor "%a, %b %d"))))))
    (apply #'eabp-row
           (delq nil
                 (list
                  (eabp-icon-button "chevron_left"
                                    (eabp-action "agenda.nav" :args '((dir . -1)))
                                    :content-description "Previous")
                  (eabp-box (list (eabp-text label 'label))
                            :weight 1 :alignment "center")
                  (unless at-today
                    (eabp-icon-button "today" (eabp-action "agenda.today")
                                      :content-description "Back to today"))
                  (eabp-icon-button "chevron_right"
                                    (eabp-action "agenda.nav" :args '((dir . 1)))
                                    :content-description "Next"))))))

;; ── Agenda cards ──

(defun eabp-org-ui--agenda-type-icon (type)
  "Return (ICON . COLOR) for an agenda item TYPE string (color may be nil)."
  (cond
   ((null type) '("event" . nil))
   ((string-match-p "past-scheduled" type) '("history" . "#E53935"))
   ((string-match-p "deadline" type) '("flag" . nil))
   ((string-match-p "scheduled" type) '("schedule" . nil))
   (t '("event" . nil))))

(defun eabp-org-ui--agenda-type-label (type)
  "Short human label for an agenda item TYPE string, or nil to omit."
  (pcase type
    ("past-scheduled" "overdue")
    ("upcoming-deadline" "deadline soon")
    ("deadline" "deadline")
    ("scheduled" "scheduled")
    (_ nil)))

(defun eabp-org-ui--agenda-card (it)
  "A detail-rich agenda card for item IT.
Leading time (or a type icon), priority-prefixed headline (struck
through when done), a todo/type/file caption, tag chips when present,
and a quick complete button for open todos."
  (let* ((headline (or (alist-get 'headline it) "Untitled"))
         (todo (alist-get 'todo it))
         ;; Normalized "HH:MM" — the raw property is a time-grid string
         ;; like " 9:15......".
         (time (eabp-org--item-hm (alist-get 'time it)))
         (type (alist-get 'type it))
         (file (alist-get 'file it))
         (priority (alist-get 'priority it))
         (tags (append (alist-get 'tags it) nil))
         (ref (alist-get 'ref it))
         (done (and todo (member todo (or (default-value 'org-done-keywords)
                                          '("DONE" "CANCELLED")))))
         (icon+color (eabp-org-ui--agenda-type-icon type))
         (caption (string-join
                   (delq nil (list todo
                                   (and (stringp type)
                                        (eabp-org-ui--agenda-type-label type))
                                   (and file (file-name-nondirectory file))))
                   "  ·  "))
         (lead (if (and (stringp time) (not (string-empty-p time)))
                   (eabp-text time 'label)
                 (eabp-icon (car icon+color) :size 18 :color (cdr icon+color))))
         (headline-node
          (eabp-rich-text
           (delq nil
                 (list
                  (when priority
                    (eabp-span (format "[#%s] " priority) :bold t :color "#F57C00"))
                  (if done
                      (eabp-span headline :strike t)
                    (eabp-span headline))))))
         (middle
          (apply #'eabp-column
                 (delq nil
                       (list
                        headline-node
                        (unless (string-empty-p caption)
                          (eabp-text caption 'caption))
                        (when tags
                          (apply #'eabp-flow-row
                                 (mapcar (lambda (tg)
                                           (eabp-assist-chip (concat "#" tg)))
                                         tags)))))))
         (complete-btn
          (when (and todo (not done))
            (eabp-icon-button
             "check"
             (eabp-action "heading.todo-set"
                          :args (cons '(state . "DONE") ref)
                          :dedupe (format "todo-set/%s"
                                          (or (alist-get 'id ref)
                                              (alist-get 'headline ref)
                                              "?")))
             :content-description "Mark done"))))
    (eabp-card
     (list (apply #'eabp-row
                  (delq nil (list lead
                                  (eabp-box (list middle) :weight 1)
                                  complete-btn))))
     :on-tap (eabp-action "heading.tap" :args ref))))

(defun eabp-org-ui--agenda-day-view (items)
  (let ((cards (mapcar #'eabp-org-ui--agenda-card items)))
    (if cards
        (apply #'eabp-lazy-column cards)
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for this day."))))

(defun eabp-org-ui--agenda-week-view (items)
  (let ((elements nil)
        (current-date nil))
    (dolist (it items)
      (let ((date (alist-get 'date it)))
        (unless (equal date current-date)
          (setq current-date date)
          (push (eabp-section-header (or date "Unknown Date")) elements))
        (push (eabp-org-ui--agenda-card it) elements)))
    (if elements
        (apply #'eabp-lazy-column (nreverse elements))
      (eabp-empty-state :icon "event_busy"
                        :title "No agenda items"
                        :caption "Nothing scheduled for this week."))))

(defun eabp-org-ui--agenda-month-view (items anchor)
  "Month grid for ITEMS, showing the month containing ANCHOR (YYYY-MM-DD)."
  (let* ((today (format-time-string "%Y-%m-%d"))
         (month-prefix (substring anchor 0 7))
         (sel (eabp-ui-state "agenda-selected-date"))
         ;; A remembered selection only counts inside the shown month;
         ;; otherwise select today (when visible) or the anchor day.
         (selected-date (cond
                         ((and (stringp sel) (string-prefix-p month-prefix sel)) sel)
                         ((string-prefix-p month-prefix today) today)
                         (t anchor)))
         (items-by-date (seq-group-by (lambda (it) (alist-get 'date it)) items))
         (selected-items (cdr (assoc selected-date items-by-date)))
         (month (string-to-number (substring anchor 5 7)))
         (year (string-to-number (substring anchor 0 4)))
         (days-in-month (calendar-last-day-of-month month year))
         (first-day-of-month (calendar-day-of-week (list month 1 year)))
         (grid-rows nil)
         (current-day 1)
         (week-header (apply #'eabp-row
                             (mapcar (lambda (d) (eabp-box (list (eabp-text d 'caption)) :weight 1 :alignment "center"))
                                     '("S" "M" "T" "W" "T" "F" "S")))))
    (while (<= current-day days-in-month)
      (let ((row-cells nil))
        (dotimes (dow 7)
          (if (or (and (= current-day 1) (< dow first-day-of-month))
                  (> current-day days-in-month))
              (push (eabp-box (list (eabp-spacer)) :weight 1) row-cells)
            (let* ((date-str (format "%04d-%02d-%02d" year month current-day))
                   (day-items (cdr (assoc date-str items-by-date)))
                   (is-selected (equal date-str selected-date))
                   (text-color (if is-selected "#FFFFFF" nil))
                   (bg-color (if is-selected "#1976D2" nil))
                   (cell-content (list
                                  (eabp-surface
                                   (list
                                    (eabp-text (number-to-string current-day) 'body nil text-color)
                                    (if day-items
                                        (eabp-icon "circle" :size 6 :color (if is-selected "#FFFFFF" "#1976D2") :padding 2)
                                      (eabp-spacer :height 8)))
                                   :color bg-color :shape "rounded" :padding 4))))
              (push (eabp-box cell-content :weight 1 :alignment "center"
                              :on-tap (eabp-action "agenda.select-date" :args `((date . ,date-str))))
                    row-cells)
              (setq current-day (1+ current-day)))))
        (push (apply #'eabp-row (nreverse row-cells)) grid-rows)))
    (eabp-column
     week-header
     (eabp-spacer :height 8)
     (apply #'eabp-column (nreverse grid-rows))
     (eabp-divider)
     (eabp-section-header (format "Events for %s" selected-date))
     (if selected-items
         (apply #'eabp-lazy-column (mapcar #'eabp-org-ui--agenda-card selected-items))
       (eabp-text "No events" 'caption)))))

(defun eabp-org-ui--agenda-body ()
  (let* ((mode (or (eabp-ui-state "agenda-mode") "day"))
         (is-span (member mode '("day" "week" "month")))
         (anchor (eabp-org-ui--agenda-anchor))
         ;; The month span always starts on the 1st so the grid and the
         ;; extraction agree on the visible range.
         (start-day (cond ((equal mode "month") (concat (substring anchor 0 7) "-01"))
                          (is-span anchor)))
         (items (cond
                 ((equal mode "day") (condition-case nil (eabp-org--agenda-items 'day start-day) (error nil)))
                 ((equal mode "week") (condition-case nil (eabp-org--agenda-items 'week start-day) (error nil)))
                 ((equal mode "month") (condition-case nil (eabp-org--agenda-items 'month start-day) (error nil)))
                 (t (condition-case nil (eabp-org--search (cdr (assoc mode eabp-org-custom-agendas))) (error nil)))))
         (custom-chips (mapcar (lambda (ca)
                                 (let ((name (car ca)))
                                   (eabp-chip name
                                              :selected (equal mode name)
                                              :on-tap (eabp-action "agenda.set-mode" :args `((mode . ,name))))))
                               eabp-org-custom-agendas)))
    (apply #'eabp-column
           (delq nil
                 (list
                  (apply #'eabp-flow-row
                         (eabp-chip "Day"
                                    :selected (equal mode "day")
                                    :on-tap (eabp-action "agenda.set-mode" :args '((mode . "day"))))
                         (eabp-chip "Week"
                                    :selected (equal mode "week")
                                    :on-tap (eabp-action "agenda.set-mode" :args '((mode . "week"))))
                         (eabp-chip "Month"
                                    :selected (equal mode "month")
                                    :on-tap (eabp-action "agenda.set-mode" :args '((mode . "month"))))
                         custom-chips)
                  (when is-span
                    (eabp-org-ui--agenda-nav-row mode anchor))
                  (eabp-spacer :height 4)
                  (cond
                   ((equal mode "day")
                    (eabp-org-ui--agenda-day-view items))
                   ((equal mode "week")
                    (eabp-org-ui--agenda-week-view items))
                   ((equal mode "month")
                    (eabp-org-ui--agenda-month-view items anchor))
                   (t
                    (if items
                        (apply #'eabp-lazy-column (mapcar #'eabp-org-ui--agenda-card items))
                      (eabp-empty-state :icon "event_busy"
                                        :title "No results"
                                        :caption "This custom agenda found no items.")))))))))

(defun eabp-org-ui--tasks-body ()
  (let* ((items (condition-case nil
                    (eabp-org--todo-items)
                  (error nil)))
         (filtered (if (equal eabp-org-ui--tasks-filter "ALL") items
                     (cl-remove-if-not
                      (lambda (it)
                        (equal (alist-get 'todo it) eabp-org-ui--tasks-filter))
                      items)))
         (cards (mapcar (lambda (it)
                          (let ((headline (or (alist-get 'headline it) "?"))
                                (todo (or (alist-get 'todo it) ""))
                                (ref (alist-get 'ref it)))
                            (eabp-card
                             (list (eabp-row
                                    (eabp-box
                                     (list (eabp-column
                                            (eabp-text headline 'body)
                                            (eabp-text todo 'caption)))
                                     :weight 1)
                                    (eabp-icon-button
                                     "check"
                                     (eabp-action "heading.todo-set"
                                                  :args (cons '(state . "DONE") ref)
                                                  :dedupe (format "todo-set/%s"
                                                                  (or (alist-get 'id ref)
                                                                      (alist-get 'headline ref)
                                                                      "?"))))))
                             :on-tap (eabp-action "heading.tap" :args ref))))
                        filtered)))
    (eabp-column
     (apply #'eabp-flow-row
            (mapcar (lambda (kw)
                      (eabp-chip kw
                                 :selected (equal eabp-org-ui--tasks-filter kw)
                                 :on-tap (eabp-action "tasks.filter"
                                                      :args `((filter . ,kw)))))
                    (cons "ALL" (or (default-value 'org-todo-keywords-1)
                                    '("TODO" "DONE")))))
     (if cards
         (apply #'eabp-lazy-column cards)
       (eabp-empty-state :icon "task_alt"
                         :title "No tasks"
                         :caption "Nothing matches this filter.")))))

;; The old agenda-files-only "files" body is superseded by the full
;; browser in eabp-files.el (eabp-files-browser-body).

(defun eabp-org-ui--clock-body ()
  (let* ((status (eabp-org--clock-status))
         (recent (condition-case nil
                     (eabp-org--recent-clocks 5)
                   (error nil)))
         (status-card
          (if status
              (let* ((start (alist-get 'start status))
                     (mins (when start
                             (max 0 (floor (/ (- (float-time) start) 60))))))
                (eabp-card
                 (list (eabp-column
                        (eabp-text "Currently Clocked In" 'caption)
                        (eabp-text (or (alist-get 'task status) "?") 'headline)
                        (eabp-text (if mins (format "%d min elapsed" mins) "")
                                   'caption)
                        (eabp-button "Clock Out" (eabp-action "org.clock.out"))))))
            (eabp-empty-state :icon "schedule"
                              :title "Not clocked in"
                              :caption "Pick a recent task below to start.")))
         (recent-cards
          (mapcar (lambda (r)
                    (eabp-card
                     (list (eabp-text (or (alist-get 'headline r) "?") 'body))
                     :on-tap (eabp-action "heading.clock-in"
                                          :args (alist-get 'ref r))))
                  recent))
         (all-children (append (list status-card)
                               (when recent-cards
                                 (cons (eabp-section-header "Recent Tasks")
                                       recent-cards)))))
    (apply #'eabp-column all-children)))

(defun eabp-org-ui--result-card (it)
  "Render a search/heading item IT to a tappable card with tag chips."
  (let* ((headline (or (alist-get 'headline it) "?"))
         (todo (alist-get 'todo it))
         (file (alist-get 'file it))
         (tags (append (alist-get 'tags it) nil))
         (ref (alist-get 'ref it))
         (caption (string-join
                   (delq nil (list todo (when file (file-name-nondirectory file))))
                   "  ·  "))
         (children (delq nil
                         (list
                          (eabp-text headline 'body)
                          (unless (string-empty-p caption)
                            (eabp-text caption 'caption))
                          (when tags
                            (apply #'eabp-flow-row
                                   (mapcar (lambda (tg)
                                             (eabp-assist-chip (concat "#" tg)))
                                           tags)))))))
    (eabp-card (list (apply #'eabp-column children))
               :on-tap (eabp-action "heading.tap" :args ref))))

(defun eabp-org-ui--search-body ()
  (let* ((q (or eabp-org-ui--search-query ""))
         (results eabp-org-ui--search-results)
         (input (eabp-text-input "search-query"
                                 :value q
                                 :hint "Search headings (text or org-ql query)"
                                 :single-line t
                                 :on-submit (eabp-action "org.search.run")))
         (todo-val (or (eabp-ui-state "search-filter-todo") "Any"))
         (tags-val (or (eabp-ui-state "search-filter-tags") []))
         (text-val (or (eabp-ui-state "search-filter-text") ""))
         (available-tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist))
         (builder (eabp-card
                   (list
                    (eabp-column
                     (eabp-text "Query Builder" 'headline)
                     (eabp-text "Status:" 'caption)
                     (eabp-enum-list "search-filter-todo" '("Any" "TODO" "DONE")
                                     :value todo-val
                                     :on-change (eabp-action "search.update-filter" :args '((field . "todo"))))
                     (eabp-text "Tags:" 'caption)
                     (eabp-enum-list "search-filter-tags" available-tags
                                     :value tags-val
                                     :multi-select t
                                     :on-change (eabp-action "search.update-filter" :args '((field . "tags"))))
                     (eabp-text "Text Contains:" 'caption)
                     (eabp-text-input "search-filter-text"
                                      :value text-val
                                      :hint "Search text..."
                                      :single-line t
                                      :on-submit (eabp-action "search.update-filter" :args '((field . "text"))))))
                   :padding 16))
         (cards (mapcar #'eabp-org-ui--result-card results)))
    (eabp-column
     builder
     (eabp-spacer :height 8)
     (eabp-row
      (eabp-box (list input) :weight 1)
      (eabp-button "Search" (eabp-action "org.search.run" :args `((value . ,q))))
      (eabp-button "Save" (eabp-action "agenda.save-custom" :args `((query . ,q)))))
     (cond
      (cards (apply #'eabp-lazy-column cards))
      ((and (stringp q) (not (string-empty-p q)))
       (eabp-empty-state :icon "manage_search"
                         :title "No matches"
                         :caption (format "Nothing matched \"%s\"." q)))
      (t
       (eabp-empty-state :icon "search"
                         :title "Search your notes"
                         :caption "Type a query and press search."))))))

(defun eabp-org-ui--settings-body ()
  (let* ((available-tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist))
         (enum-list (eabp-enum-list "settings-tags" available-tags
                                    :value available-tags
                                    :multi-select t
                                    :allow-add t
                                    :on-change (eabp-action "settings.tags")))
         (linenum-value (pcase eabp-line-numbers
                          ('absolute "Absolute")
                          ('relative "Relative")
                          (_ "Off"))))
    (eabp-column
     (eabp-section-header "Display")
     (eabp-text "Line numbers in the buffer view and editor." 'caption)
     (eabp-enum-list "settings-linenum" '("Off" "Absolute" "Relative")
                     :value (list linenum-value)
                     :on-change (eabp-action "settings.line-numbers"))
     (eabp-divider)
     (eabp-section-header "Global Org Tags")
     (eabp-text "Manage the global tag list (org-tag-alist)." 'caption)
     enum-list)))

(defun eabp-org-ui--todo-chips (current keywords ref)
  "A row of chips for KEYWORDS with CURRENT selected; taps carry REF."
  (apply #'eabp-flow-row
         (mapcar (lambda (kw)
                   (eabp-chip kw
                              :selected (equal kw current)
                              :on-tap (eabp-action
                                       "heading.todo-set"
                                       :args (cons (cons 'state kw) ref))))
                 keywords)))

(defun eabp-org-ui--ts-date (ts)
  "Return the YYYY-MM-DD date inside org timestamp string TS, or nil."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" ts))
    (match-string 1 ts)))

(defun eabp-org-ui--ts-time (ts)
  "Return the HH:MM time inside org timestamp string TS, or nil."
  (when (and (stringp ts)
             (string-match "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)" ts))
    (match-string 1 ts)))

(defun eabp-org-ui--ts-repeater (ts)
  "Return the repeater cookie (e.g. \"+1w\", \".+2d\") inside TS, or nil.
The one part of a timestamp the date-stamp chip can't display."
  (when (and (stringp ts)
             (string-match "\\([.+]?\\+[0-9]+[hdwmy]\\)" ts))
    (match-string 1 ts)))

(defun eabp-org-ui--priority-chips (current ref)
  "A row of priority chips (A..C plus None) with CURRENT selected; taps carry REF."
  (let* ((hi (or (bound-and-true-p org-priority-highest) ?A))
         (lo (or (bound-and-true-p org-priority-lowest) ?C))
         (levels (mapcar #'char-to-string (number-sequence hi lo))))
    (apply #'eabp-flow-row
           (append
            (mapcar (lambda (p)
                      (eabp-chip p
                                 :selected (equal p current)
                                 :on-tap (eabp-action
                                          "heading.priority"
                                          :args (cons (cons 'value p) ref))))
                    levels)
            (list (eabp-chip "None"
                             :selected (null current)
                             :on-tap (eabp-action
                                      "heading.priority"
                                      :args (cons '(value . "") ref))))))))

(defun eabp-org-ui--property-row (key value ref pos)
  "A two-column KEY → editable VALUE row for the detail Properties editor.
KEY renders without org's colons.  ID is shown read-only (editing it
breaks links); every other value is an inline input whose submit runs
`heading.prop-set' — submitting an empty value removes the property."
  (eabp-row
   (eabp-box (list (eabp-text key 'label)) :weight 2)
   (eabp-box
    (list (if (equal key "ID")
              (eabp-text value 'caption nil nil t)
            (eabp-text-input (format "prop-%s/%s" pos key)
                             :value value
                             :single-line t
                             :on-submit (eabp-action "heading.prop-set"
                                                     :args (cons `(name . ,key) ref)))))
    :weight 3)))

(defun eabp-org-ui--properties-section (props ref pos)
  "The Properties collapsible: KEY → VALUE rows plus an + Add button.
Always present (even with no properties yet) so + Add is reachable."
  (eabp-collapsible
   (format "detail-props/%s" pos)
   (eabp-text (if props (format "Properties (%d)" (length props)) "Properties")
              'label)
   (delq nil
         (append
          (mapcar (lambda (kv)
                    (eabp-org-ui--property-row (car kv) (or (cdr kv) "") ref pos))
                  props)
          (list
           (when props
             (eabp-text "Submit an empty value to remove a property." 'caption))
           (eabp-row
            (eabp-spacer :weight 1)
            (eabp-button "+ Add property"
                         (eabp-action "heading.prop-add" :args ref)
                         :variant "outlined")))))
   :collapsed t))

(defun eabp-org-ui--detail-body (ref)
  (condition-case err
      (let* ((marker (eabp-org--resolve-ref ref))
             (buf (marker-buffer marker))
             (file (buffer-file-name buf))
             (pos (marker-position marker))
             (meta (with-current-buffer buf
                     (org-with-wide-buffer
                      (goto-char pos)
                      (let ((comps (org-heading-components)))
                        (list :headline (or (nth 4 comps) "")
                              :todo (nth 2 comps)
                              :priority (and (nth 3 comps)
                                             (char-to-string (nth 3 comps)))
                              :tags (org-get-tags pos t)
                              :scheduled (org-entry-get pos "SCHEDULED")
                              :deadline (org-entry-get pos "DEADLINE")
                              :keywords (or org-todo-keywords-1 '("TODO" "DONE")))))))
             (headline (plist-get meta :headline))
             (todo (plist-get meta :todo))
             (priority (plist-get meta :priority))
             (tags (plist-get meta :tags))
             (scheduled (plist-get meta :scheduled))
             (deadline (plist-get meta :deadline))
             (keywords (plist-get meta :keywords))
             (is-clocked-in (and (bound-and-true-p org-clock-hd-marker)
                                 (marker-buffer org-clock-hd-marker)
                                 (equal buf (marker-buffer org-clock-hd-marker))
                                 (with-current-buffer buf
                                   (= (line-number-at-pos marker)
                                      (line-number-at-pos org-clock-hd-marker)))))
             (sched-button
              (lambda (label when)
                (eabp-button label
                             (eabp-action "heading.schedule"
                                          :args (cons (cons 'when when) ref))
                             :variant "text"))))
        (if (not eabp-org-ui--detail-read-mode)
            (let ((content (with-current-buffer buf
                             (org-with-wide-buffer
                              (goto-char pos)
                              (org-mark-subtree)
                              (buffer-substring-no-properties (region-beginning) (region-end))))))
              (eabp-column
               (eabp-editor (format "detail-%s" pos) content
                            :syntax "org"
                            :line-numbers (and eabp-line-numbers
                                               (symbol-name eabp-line-numbers))
                            :on-save (eabp-action "detail.save"
                                                  :args `((ref . ,ref))
                                                  :when-offline "queue"
                                                  :dedupe (format "save-detail/%s" pos)))))
          (let ((sdate (eabp-org-ui--ts-date scheduled))
                (ddate (eabp-org-ui--ts-date deadline))
                (entry-props (ignore-errors
                               (with-current-buffer buf
                                 (org-with-wide-buffer
                                  (goto-char pos)
                                  (org-entry-properties pos 'standard))))))
            (apply #'eabp-lazy-column
                   (delq nil
                         (append
                          (list
                           ;; File breadcrumb
                           (eabp-text (file-name-nondirectory (or file "?")) 'caption)
                           ;; Headline
                           (eabp-text headline 'title)
                           ;; State (always visible)
                           (eabp-org-ui--todo-chips todo keywords ref)
                           ;; Priority (always visible)
                           (eabp-org-ui--priority-chips priority ref)
                           (eabp-divider)
                           ;; ▸ Scheduling (collapsible — expanded when any date is set)
                           ;; The date-stamp chip IS the display (date + time);
                           ;; the raw "<2026-07-02 Thu>" caption is gone. Only a
                           ;; repeater cookie — which the chip can't show —
                           ;; surfaces as a caption.
                           (eabp-collapsible
                            (format "detail-sched/%s" pos)
                            (eabp-text "Scheduling" 'label)
                            (list
                             (eabp-row
                              (if sdate
                                  (eabp-date-stamp :date sdate
                                                   :time (eabp-org-ui--ts-time scheduled))
                                (eabp-spacer :width 0))
                              (eabp-box
                               (list
                                (apply #'eabp-column
                                       (delq nil
                                             (list
                                              (eabp-text "Scheduled" 'label)
                                              (unless sdate
                                                (eabp-text "Not scheduled" 'caption))
                                              (when-let ((rep (eabp-org-ui--ts-repeater scheduled)))
                                                (eabp-text (concat "Repeats " rep) 'caption))
                                              (eabp-flow-row
                                               (eabp-date-button "Set date"
                                                                 (eabp-action "heading.schedule" :args ref)
                                                                 :value sdate)
                                               (eabp-time-button "Set time"
                                                                 (eabp-action "heading.schedule-time" :args ref)
                                                                 :value (eabp-org-ui--ts-time scheduled))
                                               (funcall sched-button "Today" "+0d")
                                               (funcall sched-button "+1d" "+1d")
                                               (funcall sched-button "+1w" "+1w")
                                               (eabp-button "Clear"
                                                            (eabp-action "heading.schedule"
                                                                         :args (cons '(clear . t) ref))
                                                            :variant "text"))))))
                               :weight 1))
                             (eabp-divider)
                             (eabp-row
                              (if ddate
                                  (eabp-date-stamp :date ddate
                                                   :time (eabp-org-ui--ts-time deadline))
                                (eabp-spacer :width 0))
                              (eabp-box
                               (list
                                (apply #'eabp-column
                                       (delq nil
                                             (list
                                              (eabp-text "Deadline" 'label)
                                              (unless ddate
                                                (eabp-text "No deadline" 'caption))
                                              (when-let ((rep (eabp-org-ui--ts-repeater deadline)))
                                                (eabp-text (concat "Repeats " rep) 'caption))
                                              (eabp-flow-row
                                               (eabp-date-button "Set date"
                                                                 (eabp-action "heading.deadline" :args ref)
                                                                 :value ddate)
                                               (eabp-button "Clear"
                                                            (eabp-action "heading.deadline"
                                                                         :args (cons '(clear . t) ref))
                                                            :variant "text"))))))
                               :weight 1)))
                            :collapsed (not (or sdate ddate)))
                           ;; ▸ Tags (collapsible)
                           (let ((available (seq-uniq (append tags (mapcar (lambda (x) (if (consp x) (car x) x)) org-tag-alist)))))
                             (eabp-collapsible
                              (format "detail-tags-fold/%s" pos)
                              (eabp-text (if tags (format "Tags (%d)" (length tags)) "Tags") 'label)
                              (list
                               (eabp-enum-list (format "detail-tags/%s" pos) available
                                               :value tags :multi-select t :allow-add t
                                               :on-change (eabp-action "heading.tags" :args ref)))
                              :collapsed (null tags)))
                           ;; ▸ Clock (collapsible)
                           (eabp-collapsible
                            (format "detail-clock/%s" pos)
                            (eabp-text "Clock" 'label)
                            (list
                             (if is-clocked-in
                                 (eabp-button "Clock Out" (eabp-action "org.clock.out"))
                               (eabp-button "Clock In" (eabp-action "heading.clock-in" :args ref))))
                            :collapsed (not is-clocked-in))
                           ;; TODO: Add LOGBOOK collapsible section
                           ;; ▸ Properties (collapsible — collapsed by default)
                           (eabp-org-ui--properties-section entry-props ref pos)
                           (eabp-divider))
                          ;; Reader: body (highlighted) and child headings (foldable).
                          ;; Properties are shown above, so skip them here.
                          (eabp-org-reader-subtree file pos t)))))))
    (error
     (eabp-column
      (eabp-text "Error loading heading" 'title)
      (eabp-text (error-message-string err) 'body)))))

;; ─── Capture Dialog ──────────────────────────────────────────────────────────

(defvar eabp-org-ui--shared-text nil
  "Body text shared from another app, pending the next capture submit.")
(defvar eabp-org-ui--shared-subject nil
  "Subject shared from another app; seeds the capture Headline field.")

(defun eabp-org-ui-show-capture-dialog ()
  (condition-case err
      (let* ((templates (eabp-org--capture-templates))
             (template-buttons
              (mapcar (lambda (t-info)
                        (eabp-button
                         (alist-get 'description t-info)
                         (eabp-action "org.capture.select"
                                      :args `((key . ,(alist-get 'key t-info))))
                         :variant "outlined"))
                      templates))
             (dialog-body
              (apply #'eabp-column
                     (eabp-text "Quick Capture" 'title)
                     (eabp-text "Select a template:" 'caption)
                     (append
                      ;; Shared-in content shows a preview so the user knows
                      ;; what this capture will carry.
                      (when eabp-org-ui--shared-text
                        (list (eabp-card
                               (list (eabp-text
                                      (truncate-string-to-width
                                       eabp-org-ui--shared-text 200 nil nil "…")
                                      'caption)))))
                      template-buttons
                      (list (eabp-button "Cancel"
                                         (eabp-action "org.capture.cancel")
                                         :variant "text"))))))
        (eabp-send-dialog dialog-body))
    (error
     (message "EABP capture dialog error: %s" (error-message-string err)))))

(defun eabp-org-ui-show-capture-form (template-key)
  ;; Forget values from any previous capture so they can't leak into
  ;; this submit (`eabp--ui-state' is global and persistent).
  (eabp-ui-state-clear "cap-")
  ;; A shared-in subject pre-fills the Headline field; it must also land
  ;; in UI state, since state.changed only fires for edits the user makes.
  (when eabp-org-ui--shared-subject
    (eabp-ui-state-put "cap-Headline" eabp-org-ui--shared-subject))
  (condition-case err
      (let* ((templates (eabp-org--capture-templates))
             (tmpl (cl-find-if
                    (lambda (t-info) (equal (alist-get 'key t-info) template-key))
                    templates))
             (prompts (append (alist-get 'prompts tmpl) nil)) ;; coerce vector to list
             (inputs (mapcar (lambda (p)
                               (eabp-text-input
                                (format "cap-%s" p) :label p
                                :value (and (equal p "Headline")
                                            eabp-org-ui--shared-subject)))
                             prompts))
             (dialog-body
              (apply #'eabp-column
                     (eabp-text (format "Capture: %s" (alist-get 'description tmpl)) 'title)
                     (append inputs
                             (list
                              (eabp-row
                               (eabp-button "Cancel"
                                            (eabp-action "org.capture.cancel")
                                            :variant "text")
                               (eabp-button "Capture"
                                            (eabp-action "org.capture.submit"
                                                         :args `((key . ,template-key))))))))))
        (eabp-send-dialog dialog-body))
    (error
     (message "EABP capture form error: %s" (error-message-string err)))))

;; ─── Action Handlers ─────────────────────────────────────────────────────────

(eabp-defaction "view.switched"
  (lambda (args _)
    ;; The companion already flipped the view locally — this event only
    ;; synchronizes Emacs's notion of "where the user is" and refreshes
    ;; the (possibly stale) cached views in the background.
    (let ((view (alist-get 'view args)))
      (when view
        (unless (equal view "detail")
          (setq eabp-org-ui--detail-ref nil)
          (unless (equal view eabp-org-ui--current-tab)
            (setq eabp-emacs-ui--viewing-buffer nil))
          (when (member view '("agenda" "tasks" "clock" "files" "eval"))
            (setq eabp-org-ui--current-tab view)))
        ;; Back from the editor closes the file (the next push drops the
        ;; edit view). Unsaved companion-side text is discarded with it.
        (when (and (equal view "files") eabp-files--file)
          (setq eabp-files--file nil))
        ;; No :switch-to — never yank the user during a background refresh.
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "nav.tab"
  ;; Legacy round-trip navigation; superseded by the view.switch builtin
  ;; but kept so stale cached UIs from older pushes still work.
  (lambda (args _)
    (let ((tab (alist-get 'tab args)))
      (eabp-org-ui-push-dashboard tab))))

(eabp-defaction "dashboard.refresh"
  (lambda (_ _)
    ;; Manual refresh is an explicit "give me fresh data": bypass the memo.
    (eabp-org-cache-invalidate)
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "heading.tap"
  (lambda (args _)
    ;; ARGS is the ref alist (id/file/pos/headline) the card embedded.
    ;; This push IS the navigation, so it forces the detail view.
    (setq eabp-org-ui--detail-ref args)
    (setq eabp-org-ui--detail-read-mode t)
    (eabp-org-ui-push-dashboard nil :switch-to "detail")))

(eabp-defaction "detail.toggle-read"
  (lambda (_ _)
    (setq eabp-org-ui--detail-read-mode (not eabp-org-ui--detail-read-mode))
    (eabp-org-ui-push-dashboard nil :switch-to "detail")))

(eabp-defaction "detail.save"
  (lambda (args _)
    (let ((ref (alist-get 'ref args))
          (value (alist-get 'value args)))
      (when (and ref value)
        (condition-case err
            (let* ((marker (eabp-org--resolve-ref ref))
                   (buf (marker-buffer marker))
                   (pos (marker-position marker)))
              (with-current-buffer buf
                (org-with-wide-buffer
                 (goto-char pos)
                 (org-mark-subtree)
                 (delete-region (region-beginning) (region-end))
                 (insert value)
                 (goto-char pos)
                 (setq eabp-org-ui--detail-ref (eabp-org--heading-ref))
                 (let ((eabp-org--inhibit-save-refresh t)
                       (save-silently t))
                   (save-buffer))))
              (when (fboundp 'eabp-org-cache-invalidate)
                (eabp-org-cache-invalidate))
              (setq eabp-org-ui--detail-read-mode t)
              (eabp-org-ui-snackbar "Saved heading"))
          (error
           (eabp-org-ui-snackbar (format "Save failed: %s" (error-message-string err))))))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.back"
  ;; Legacy: detail's back button is now a companion-local view.switch.
  ;; Kept for stale cached UIs.
  (lambda (_ _)
    (setq eabp-org-ui--detail-ref nil)
    (eabp-org-ui-push-dashboard nil :switch-to eabp-org-ui--current-tab)))

(eabp-defaction "tasks.filter"
  (lambda (args _)
    (setq eabp-org-ui--tasks-filter (alist-get 'filter args))
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "org.search.run"
  ;; The query arrives as the search field's submitted `value'. Run it,
  ;; cache the results, and land the user on the search view.
  (lambda (args _)
    (let ((q (or (alist-get 'value args) "")))
      (setq eabp-org-ui--search-query q
            eabp-org-ui--search-results
            (condition-case err
                (eabp-org--search q)
              (error
               (message "EABP search error: %s" (error-message-string err))
               nil)))
      (eabp-org-ui-push-dashboard nil :switch-to "search"))))

(eabp-defaction "org.capture.show"
  (lambda (_ _)
    (eabp-org-ui-show-capture-dialog)))

(eabp-defaction "org.capture.select"
  (lambda (args _)
    (eabp-org-ui-show-capture-form (alist-get 'key args))))

(eabp-defaction "org.capture.cancel"
  (lambda (_ _)
    (setq eabp-org-ui--shared-text nil
          eabp-org-ui--shared-subject nil)
    (eabp-dismiss-dialog)))

(eabp-defaction "org.capture.share"
  ;; Android share sheet → capture: stash the shared text/subject and open
  ;; the template picker.  Queued offline, so sharing works with Emacs dead
  ;; — the capture dialog appears on the next replay.
  (lambda (args _)
    (let ((text (alist-get 'text args))
          (subject (alist-get 'subject args)))
      (setq eabp-org-ui--shared-text
            (and (stringp text) (not (string-empty-p (string-trim text)))
                 (string-trim text))
            eabp-org-ui--shared-subject
            (and (stringp subject) (not (string-empty-p (string-trim subject)))
                 (string-trim subject)))
      ;; A share with only a subject still captures: use it as the text too.
      (unless eabp-org-ui--shared-text
        (setq eabp-org-ui--shared-text eabp-org-ui--shared-subject))
      (eabp-org-ui-show-capture-dialog))))

(eabp-defaction "org.capture.submit"
  (lambda (args _)
    (let ((key (alist-get 'key args)))
      (condition-case err
          (let* ((templates (eabp-org--capture-templates))
                 (tmpl (cl-find-if
                        (lambda (t-info) (equal (alist-get 'key t-info) key))
                        templates))
                 (prompts (append (alist-get 'prompts tmpl) nil))
                 ;; Field values arrived earlier as state.changed events and
                 ;; were recorded into `eabp--ui-state' by eabp-surfaces.
                 (values (mapcar
                          (lambda (p)
                            (let ((v (eabp-ui-state (format "cap-%s" p))))
                              (cons p (if (stringp v) v ""))))
                          prompts)))
            (eabp-org--do-capture key values eabp-org-ui--shared-text)
            (setq eabp-org-ui--shared-text nil
                  eabp-org-ui--shared-subject nil)
            (eabp-org-cache-invalidate)
            (eabp-ui-state-clear "cap-")
            (eabp-org-ui-snackbar "Captured ✓")
            (eabp-dismiss-dialog)
            (eabp-org-ui-push-dashboard))
        (error
         (message "EABP capture submit error: %s" (error-message-string err))
         (setq eabp-org-ui--shared-text nil
               eabp-org-ui--shared-subject nil)
         (eabp-ui-state-clear "cap-")
         (eabp-dismiss-dialog))))))

(defun eabp-org-ui--at-ref (args fn &optional save)
  "Resolve ARGS to its heading and call FN with point there.
With SAVE non-nil, save the buffer afterwards (guarded against
triggering our own after-save refresh on top of the explicit push).
Returns non-nil on success; messages and returns nil on failure."
  (condition-case err
      (let ((marker (eabp-org--resolve-ref args)))
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (funcall fn))
          (when save
            (let ((eabp-org--inhibit-save-refresh t)
                  (save-silently t))
              (save-buffer))))
        (eabp-org-cache-invalidate)
        t)
    (error
     (message "EABP: heading action failed: %s" (error-message-string err))
     (eabp-org-ui-snackbar "Couldn't find that heading — refreshing")
     (eabp-org-ui-push-dashboard)
     nil)))

(eabp-defaction "heading.todo-set"
  (lambda (args _)
    (let ((state (alist-get 'state args)))
      (when (and state
                 (eabp-org-ui--at-ref args (lambda () (org-todo state)) t))
        (eabp-org-ui-snackbar (format "State → %s" state))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.schedule"
  (lambda (args _)
    ;; CLEAR removes the timestamp; otherwise WHEN (relative, e.g. "+1d") or
    ;; VALUE (concrete "YYYY-MM-DD", from the date picker) sets it.
    (let* ((clear (alist-get 'clear args))
           (date (or (alist-get 'when args) (alist-get 'value args)))
           (ok (cond
                (clear (eabp-org-ui--at-ref args (lambda () (org-schedule '(4))) t))
                ((and (stringp date) (not (string-empty-p date)))
                 (eabp-org-ui--at-ref args (lambda () (org-schedule nil date)) t)))))
      (when ok
        (eabp-org-ui-snackbar (if clear "Schedule cleared" (format "Scheduled %s" date)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.schedule-time"
  ;; Adds/updates the clock time on the existing SCHEDULED date (today if
  ;; none yet). VALUE is the "HH:MM" the time picker injected.
  (lambda (args _)
    (let ((time (alist-get 'value args)))
      (when (and (stringp time) (not (string-empty-p time))
                 (eabp-org-ui--at-ref
                  args
                  (lambda ()
                    (let* ((sched (org-entry-get nil "SCHEDULED"))
                           (date (or (eabp-org-ui--ts-date sched)
                                     (format-time-string "%Y-%m-%d"))))
                      (org-schedule nil (format "%s %s" date time))))
                  t))
        (eabp-org-ui-snackbar (format "Scheduled %s" time))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "org.footnote.show"
  ;; A tapped footnote marker in rich text: surface its inline definition
  ;; (when the reference carried one) or just its label.
  (lambda (args _)
    (let ((def (alist-get 'def args))
          (label (alist-get 'label args)))
      (eabp-org-ui-snackbar
       (if (and (stringp def) (not (string-empty-p def)))
           (format "Footnote: %s" def)
         (format "Footnote %s" (or label ""))))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.deadline"
  (lambda (args _)
    (let* ((clear (alist-get 'clear args))
           (date (or (alist-get 'when args) (alist-get 'value args)))
           (ok (cond
                (clear (eabp-org-ui--at-ref args (lambda () (org-deadline '(4))) t))
                ((and (stringp date) (not (string-empty-p date)))
                 (eabp-org-ui--at-ref args (lambda () (org-deadline nil date)) t)))))
      (when ok
        (eabp-org-ui-snackbar (if clear "Deadline cleared" (format "Deadline %s" date)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.priority"
  (lambda (args _)
    ;; Empty VALUE means None (remove); otherwise the first char is the priority.
    (let* ((val (alist-get 'value args))
           (remove (or (null val) (string-empty-p val)))
           (ok (eabp-org-ui--at-ref
                args
                (lambda ()
                  (if remove (org-priority 'remove)
                    (org-priority (string-to-char val))))
                t)))
      (when ok
        (eabp-org-ui-snackbar (if remove "Priority cleared"
                                (format "Priority %s" val)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.refile"
  ;; Bridged picker over org-refile targets; refiles the whole subtree.
  (lambda (args _)
    (condition-case err
        (let ((marker (eabp-org--resolve-ref args)))
          (with-current-buffer (marker-buffer marker)
            (org-with-wide-buffer
             (goto-char marker)
             (let* ((org-refile-targets (or org-refile-targets
                                            '((org-agenda-files :maxlevel . 3))))
                    (targets (org-refile-get-targets))
                    (choice (condition-case nil
                                (completing-read "Refile to: "
                                                 (mapcar #'car targets) nil t)
                              (quit nil)))
                    (target (and choice (assoc choice targets))))
               (if (not target)
                   (eabp-org-ui-snackbar "Refile cancelled")
                 (org-refile nil nil target)
                 (let ((eabp-org--inhibit-save-refresh t)
                       (save-silently t))
                   (org-save-all-org-buffers))
                 (eabp-org-cache-invalidate)
                 (setq eabp-org-ui--detail-ref nil)
                 (eabp-org-ui-snackbar (format "Refiled to %s" choice))))))
          (eabp-org-ui-push-dashboard nil :switch-to eabp-org-ui--current-tab))
      (error
       (eabp-org-ui-snackbar (format "Refile failed: %s"
                                     (error-message-string err)))
       (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.archive"
  ;; Bridged y/n confirm, then org-archive-subtree; saves source + archive.
  (lambda (args _)
    (let ((headline (or (alist-get 'headline args) "this heading")))
      (if (not (yes-or-no-p (format "Archive \"%s\"? " headline)))
          (eabp-org-ui-snackbar "Archive cancelled")
        (when (eabp-org-ui--at-ref
               args
               (lambda ()
                 (org-archive-subtree)
                 (let ((eabp-org--inhibit-save-refresh t)
                       (save-silently t))
                   (org-save-all-org-buffers))))
          (setq eabp-org-ui--detail-ref nil)
          (eabp-org-ui-snackbar "Archived")))
      (eabp-org-ui-push-dashboard nil :switch-to eabp-org-ui--current-tab))))

(eabp-defaction "heading.add-note"
  ;; Quick logbook note: bridged prompt, written where org-log-into-drawer
  ;; says notes belong, in org's own note format.
  (lambda (args _)
    (let ((note (string-trim (condition-case nil
                                 (read-string "Note: ")
                               (quit "")))))
      (if (string-empty-p note)
          (eabp-org-ui-snackbar "Note cancelled")
        (when (eabp-org-ui--at-ref
               args
               (lambda ()
                 (goto-char (org-log-beginning t))
                 (insert (format "- Note taken on %s \\\\\n  %s\n"
                                 (format-time-string
                                  (org-time-stamp-format t t))
                                 note)))
               t)
          (eabp-org-ui-snackbar "Note added")))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.prop-set"
  ;; VALUE arrives injected by the row input's on-submit; NAME rides in
  ;; args. An empty value deletes the property.
  (lambda (args _)
    (let* ((name (alist-get 'name args))
           (value (string-trim (or (alist-get 'value args) "")))
           (ok (and (stringp name) (not (string-empty-p name))
                    (eabp-org-ui--at-ref
                     args
                     (lambda ()
                       (if (string-empty-p value)
                           (org-delete-property name)
                         (org-set-property name value)))
                     t))))
      (when ok
        (eabp-org-ui-snackbar (if (string-empty-p value)
                                  (format "Removed %s" name)
                                (format "%s → %s" name value)))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "heading.prop-add"
  ;; The bridged read-string asks for the key; the new (empty) property
  ;; then appears as a row whose value column is ready to fill in.
  (lambda (args _)
    (let ((name (string-trim (condition-case nil
                                 (read-string "New property name: ")
                               (quit "")))))
      (cond
       ((string-empty-p name) nil)
       ((string-match-p "[: \t]" name)
        (eabp-org-ui-snackbar "Property names can't contain colons or spaces"))
       ((eabp-org-ui--at-ref args
                             (lambda () (org-set-property (upcase name) ""))
                             t)
        (eabp-org-ui-snackbar (format "Added %s — fill in its value" (upcase name)))))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.tags"
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (tags (cond
                  ((vectorp val) (append val nil))
                  ((listp val) val)
                  ((stringp val) (split-string val "[ \t:,]+" t))
                  (t nil)))
           (ok (eabp-org-ui--at-ref args (lambda () (org-set-tags tags)) t)))
      (when ok
        (eabp-org-ui-snackbar (if tags (format "Tags: %s" (string-join tags " "))
                                "Tags cleared"))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "settings.line-numbers"
  ;; Single-select enum: value arrives as a JSON array with (at most) one
  ;; entry.  Deselecting everything counts as Off.
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (choice (car (append val nil)))
           (sym (pcase choice
                  ("Absolute" 'absolute)
                  ("Relative" 'relative)
                  (_ nil))))
      (setq eabp-line-numbers sym)
      (ignore-errors (customize-save-variable 'eabp-line-numbers sym))
      (eabp-org-ui-snackbar (format "Line numbers: %s" (or choice "Off")))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "settings.tags"
  (lambda (args _)
    (let* ((val (alist-get 'value args))
           (tags-list (cond
                       ((vectorp val) (append val nil))
                       ((listp val) val)
                       (t nil))))
      (when tags-list
        ;; Keep existing keys/chars if possible, else just use the string
        (let ((new-alist (mapcar (lambda (tg)
                                   (let ((existing (assoc tg org-tag-alist)))
                                     (if existing existing tg)))
                                 tags-list)))
          (setq org-tag-alist new-alist)
          (customize-save-variable 'org-tag-alist org-tag-alist)))
      (eabp-org-ui-snackbar "Settings saved")
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "search.update-filter"
  (lambda (args _)
    (let ((field (alist-get 'field args))
          (value (alist-get 'value args)))
      (eabp-ui-state-put (concat "search-filter-" field) value)
      (let* ((todo (eabp-ui-state "search-filter-todo"))
             (tags (eabp-ui-state "search-filter-tags"))
             (text (eabp-ui-state "search-filter-text"))
             (clauses nil))
        (when (and (stringp todo) (not (equal todo "Any")))
          (push `(todo ,todo) clauses))
        (when (vectorp tags)
          (dolist (tg (append tags nil))
            (push `(tags ,tg) clauses)))
        (when (and (stringp text) (not (string-empty-p text)))
          (push `(regexp ,text) clauses))
        (let ((q (if clauses
                     (if (= (length clauses) 1)
                         (format "%S" (car clauses))
                       (format "%S" `(and ,@(nreverse clauses))))
                   "")))
          (setq eabp-org-ui--search-query q)
          (eabp-ui-state-put "search-query" q)))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "agenda.save-custom"
  (lambda (args _)
    (let* ((query (alist-get 'query args))
           (name (read-string "Agenda Name: ")))
      (when (and (stringp name) (not (string-empty-p name)))
        ;; Remove existing if overriding
        (setq eabp-org-custom-agendas (assoc-delete-all name eabp-org-custom-agendas))
        (add-to-list 'eabp-org-custom-agendas (cons name query) t)
        (customize-save-variable 'eabp-org-custom-agendas eabp-org-custom-agendas)
        (eabp-org-ui-snackbar (format "Saved custom agenda: %s" name))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "agenda.set-mode"
  (lambda (args _)
    (let ((mode (alist-get 'mode args)))
      (eabp-ui-state-put "agenda-mode" mode)
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "agenda.nav"
  ;; Shift the agenda anchor by DIR (±1) in units of the active span.
  (lambda (args _)
    (let* ((dir (alist-get 'dir args))
           (dir (if (numberp dir) dir 1))
           (mode (or (eabp-ui-state "agenda-mode") "day"))
           (unit (pcase mode ("week" 'week) ("month" 'month) (_ 'day)))
           (anchor (eabp-org-ui--agenda-anchor)))
      ;; Month steps walk 1st → 1st so ±1 never skips a short month.
      (when (eq unit 'month)
        (setq anchor (concat (substring anchor 0 7) "-01")))
      (eabp-ui-state-put "agenda-anchor"
                         (eabp-org-ui--shift-date anchor dir unit))
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "agenda.today"
  ;; Reset the anchor (and any month-grid selection) back to today.
  (lambda (_ _)
    (eabp-ui-state-put "agenda-anchor" nil)
    (eabp-ui-state-put "agenda-selected-date" nil)
    (eabp-org-ui-push-dashboard)))

(eabp-defaction "agenda.select-date"
  (lambda (args _)
    (let ((date (alist-get 'date args)))
      (eabp-ui-state-put "agenda-selected-date" date)
      (eabp-org-ui-push-dashboard))))

(eabp-defaction "heading.clock-in"
  (lambda (args _)
    (when (eabp-org-ui--at-ref args #'org-clock-in)
      (eabp-org-ui-snackbar "Clocked in")
      (eabp-org-ui-push-dashboard "clock"))))

(eabp-defaction "org.link.open"
  ;; A tappable link inside rich org text. Emacs resolves it (id:, file:,
  ;; http(s):, attachment:, …) via the org link machinery; we report the
  ;; outcome back as a snackbar since the action itself happens Emacs-side.
  (lambda (args _)
    (let ((link (alist-get 'link args)))
      (when (and (stringp link) (not (string-empty-p link)))
        (condition-case err
            (progn
              (org-link-open-from-string link)
              (eabp-org-ui-snackbar (format "Opened %s" link)))
          (error
           (eabp-org-ui-snackbar
            (format "Couldn't open %s: %s" link (error-message-string err)))))
        (eabp-org-ui-push-dashboard)))))

(eabp-defaction "checkbox.toggle"
  ;; Toggle a checkbox in an org file from the reader view.  The companion
  ;; sends FILE and POS (the real-buffer position of the list item line).
  (lambda (args _)
    (let ((file (alist-get 'file args))
          (pos  (alist-get 'pos args)))
      (when (and file pos (file-readable-p file))
        (condition-case err
            (progn
              (with-current-buffer (find-file-noselect file)
                (org-with-wide-buffer
                 (goto-char pos)
                 (org-toggle-checkbox))
                (let ((eabp-org--inhibit-save-refresh t)
                      (save-silently t))
                  (save-buffer)))
              (eabp-org-cache-invalidate)
              (eabp-org-ui-push-dashboard))
          (error
           (eabp-org-ui-snackbar
            (format "Toggle failed: %s" (error-message-string err)))))))))

(eabp-defaction "heading.reorder"
  (lambda (args _)
    (let* ((file      (alist-get 'file args))
           (from-pos  (alist-get 'from_pos args))
           (after-pos (alist-get 'after_pos args))  ;; 0 or nil = move to top
           (new-level (alist-get 'new_level args)))
      (when (and file from-pos (file-readable-p file))
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (goto-char from-pos)
           (org-back-to-heading t)
           (let* ((from-level (org-outline-level))
                  (subtree-beg (point))
                  (subtree-end (save-excursion (org-end-of-subtree t t) (point)))
                  (subtree-size (- subtree-end subtree-beg)))
             ;; Cut the subtree
             (org-cut-subtree)
             ;; Navigate to the insertion point
             (if (and after-pos (> after-pos 0))
                 (let ((target (if (> after-pos from-pos)
                                   (- after-pos subtree-size)
                                 after-pos)))
                   (goto-char (min target (point-max)))
                   (org-back-to-heading t)
                   (org-end-of-subtree t t))
               ;; Move to top of file (before first heading)
               (goto-char (point-min))
               (when (re-search-forward org-heading-regexp nil t)
                 (goto-char (line-beginning-position))))
             ;; Paste at the new level (or original level if nil)
             (org-paste-subtree (or new-level from-level)))))
        (let ((eabp-org--inhibit-save-refresh t)
              (save-silently t))
          (with-current-buffer (find-file-noselect file)
            (save-buffer)))
        (eabp-org-cache-invalidate)
        (eabp-org-ui-push-dashboard nil :switch-to "edit")))))

(eabp-defaction "file.view"
  ;; Legacy (old cached UIs): now routes into the eabp-files editor.
  (lambda (args _)
    (let ((file (alist-get 'file args)))
      (when (and (stringp file) (file-readable-p file))
        (setq eabp-files--file (expand-file-name file))
        (eabp-org-ui-push-dashboard nil :switch-to "edit")))))

;; ─── Auto-refresh ────────────────────────────────────────────────────────────

(defvar eabp-org-ui--save-refresh-timer nil)

(defcustom eabp-org-ui-save-refresh-delay 2
  "Idle seconds after saving an agenda file before re-pushing the dashboard.
Debounces bursts of saves (e.g. `org-save-all-org-buffers') into one push."
  :type 'integer :group 'eabp)

(defun eabp-org-ui--after-save-refresh ()
  "Schedule a dashboard refresh if an org agenda file was just saved.
No-op for saves EABP itself performs (ID creation, action handlers),
which would otherwise refresh twice or loop."
  (when (and (eabp-connected-p)
             (not (bound-and-true-p eabp-org--inhibit-save-refresh))
             buffer-file-name
             (derived-mode-p 'org-mode)
             (ignore-errors
               (member (expand-file-name buffer-file-name)
                       (mapcar #'expand-file-name (org-agenda-files)))))
    (eabp-org-cache-invalidate)
    (when (timerp eabp-org-ui--save-refresh-timer)
      (cancel-timer eabp-org-ui--save-refresh-timer))
    (setq eabp-org-ui--save-refresh-timer
          (run-with-idle-timer eabp-org-ui-save-refresh-delay nil
                               #'eabp-org-ui-push-dashboard))))

(add-hook 'after-save-hook #'eabp-org-ui--after-save-refresh)

(defun eabp-org-ui--refresh-if-connected (&rest _)
  "Re-push the dashboard when there's a live session.
Safe to put on any hook: a no-op while disconnected.  Invalidates the
extraction cache first — this runs on clock in/out, which mutate the
org buffer without necessarily saving it."
  (when (eabp-connected-p)
    (eabp-org-cache-invalidate)
    (eabp-org-ui-push-dashboard)))

;; After (re)connect, push the dashboard so the app never shows a stale
;; screen from a previous Emacs session. Depth 10: after the revision
;; snapshot has been absorbed (-50 in eabp-surfaces) and after the
;; org-clock notification re-assert (0).
(add-hook 'eabp-connected-hook
          (lambda (_welcome) (eabp-org-ui-push-dashboard))
          10)

;; After a replay, queued taps have just mutated org state — the cached
;; views on the phone are now behind reality.
(add-hook 'eabp-queue-drained-hook
          (lambda (_payload)
            (eabp-org-cache-invalidate)
            (eabp-org-ui-push-dashboard)))

;; Clock state shows on the Clock tab and the dashboard generally —
;; keep it live. Depth 90: after eabp-surfaces' notification hooks.
(add-hook 'org-clock-in-hook  #'eabp-org-ui--refresh-if-connected 90)
(add-hook 'org-clock-out-hook #'eabp-org-ui--refresh-if-connected 90)

(provide 'eabp-org-ui)
;;; eabp-org-ui.el ends here
(provide 'glasspane)
;;; glasspane.el ends here
