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
        (pos (point-min))
        runs)
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos 'face nil (point-max)))
            (style (eabp-buffer--span-style (get-text-property pos 'face))))
        (when style
          (push (append
                 `((b . ,(1- pos)) (e . ,(1- next)))
                 (when-let ((c (plist-get style :color))) `((c . ,c)))
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
