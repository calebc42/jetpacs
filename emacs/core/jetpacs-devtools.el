;;; jetpacs-devtools.el --- Live instrumentation for the push loop -*- lexical-binding: t; -*-

;; The measurement layer (AUDIT-architecture-vui-vulpea.md item 1.4):
;; per-builder wall clock, serialized bytes per outbound frame, the last
;; spec each view pushed, and a push-storm warning.  Every downstream
;; perf decision — background build reuse, transcript delta frames, the
;; renderer skippable model — is gated on "measure first", and this
;; module is what makes those gates satisfiable.
;;
;; Zero wire cost: it observes two existing seams — the
;; `jetpacs--frame-observer' hook inside `jetpacs-send' (exact encoded
;; frame sizes, no re-serialization) and a timing wrapper inside
;; `jetpacs-shell--build-view' — and never sends anything itself.
;; Recording is a few float ops and a hash-table put per push; the
;; retained specs are references to trees the shell just built, not
;; copies.  `M-x jetpacs-devtools-report' renders what has been seen.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)

(defgroup jetpacs-devtools nil
  "Live instrumentation for the Jetpacs push loop."
  :group 'jetpacs)

(defcustom jetpacs-devtools-enabled t
  "When non-nil, record builder timings, frame sizes, and last specs.
The cost is a few arithmetic ops per push; disable only if a profiler
fingers the recorder itself."
  :type 'boolean :group 'jetpacs-devtools)

(defcustom jetpacs-devtools-storm-threshold 8
  "Number of `surface.update' frames within `jetpacs-devtools-storm-window'
seconds that triggers the push-storm warning.  A settled app pushes on
user action and data change; a builder that mints a fresh `jetpacs-async'
key every build (or a hook loop) pushes continuously — the storm warning
is the tripwire for that class of bug."
  :type 'natnum :group 'jetpacs-devtools)

(defcustom jetpacs-devtools-storm-window 10
  "Seconds of history the push-storm check considers."
  :type 'natnum :group 'jetpacs-devtools)

;; ─── State ───────────────────────────────────────────────────────────────────

(defvar jetpacs-devtools--builds (make-hash-table :test 'equal)
  "View name -> plist (:last-ms N :max-ms N :count N :at TIME).")

(defvar jetpacs-devtools--specs (make-hash-table :test 'equal)
  "View name -> the spec its builder last produced (a reference, not a copy).")

(defvar jetpacs-devtools--frames (make-hash-table :test 'equal)
  "Surface id -> plist (:last-bytes N :count N :at TIME), from `surface.update' frames.")

(defvar jetpacs-devtools--frame-count 0
  "Total outbound frames observed (all kinds).")

(defvar jetpacs-devtools--frame-bytes 0
  "Total outbound bytes observed (all kinds).")

(defvar jetpacs-devtools--push-times nil
  "Recent `surface.update' send times (floats), newest first, capped.")

(defvar jetpacs-devtools--storm-warned-at 0
  "Last time the storm warning fired, for rate-limiting to one per window.")

;; ─── Recorders (called from the seams) ───────────────────────────────────────

(defun jetpacs-devtools--record-build (view ms spec)
  "Record that VIEW's builder took MS milliseconds and produced SPEC."
  (when jetpacs-devtools-enabled
    (let ((rec (gethash view jetpacs-devtools--builds)))
      (puthash view (list :last-ms ms
                          :max-ms (max ms (or (plist-get rec :max-ms) 0.0))
                          :count (1+ (or (plist-get rec :count) 0))
                          :at (current-time))
               jetpacs-devtools--builds))
    (puthash view spec jetpacs-devtools--specs)))

(defun jetpacs-devtools--storm-p (times now threshold window)
  "Non-nil when THRESHOLD of TIMES (floats, any order) fall within WINDOW
seconds before NOW.  Pure, for tests."
  (>= (cl-count-if (lambda (tm) (<= (- now tm) window)) times)
      threshold))

(defun jetpacs-devtools--observe-frame (kind payload bytes)
  "The `jetpacs--frame-observer': tally KIND/PAYLOAD/BYTES, watch for storms."
  (when jetpacs-devtools-enabled
    (cl-incf jetpacs-devtools--frame-count)
    (cl-incf jetpacs-devtools--frame-bytes bytes)
    (when (equal kind "surface.update")
      (let* ((surface (or (alist-get 'surface payload) "?"))
             (rec (gethash surface jetpacs-devtools--frames))
             (now (float-time)))
        (puthash surface (list :last-bytes bytes
                               :count (1+ (or (plist-get rec :count) 0))
                               :at (current-time))
                 jetpacs-devtools--frames)
        (push now jetpacs-devtools--push-times)
        (let ((tail (nthcdr 63 jetpacs-devtools--push-times)))
          (when tail (setcdr tail nil)))
        (when (and (jetpacs-devtools--storm-p
                    jetpacs-devtools--push-times now
                    jetpacs-devtools-storm-threshold
                    jetpacs-devtools-storm-window)
                   (> (- now jetpacs-devtools--storm-warned-at)
                      jetpacs-devtools-storm-window))
          (setq jetpacs-devtools--storm-warned-at now)
          (display-warning
           'jetpacs
           (format (concat "push storm: %d surface updates in %ds — "
                           "a builder may re-trigger every push (e.g. a fresh "
                           "`jetpacs-async' key per build); see M-x jetpacs-devtools-report")
                   jetpacs-devtools-storm-threshold
                   jetpacs-devtools-storm-window)
           :warning))))))

;; ─── Public surface ──────────────────────────────────────────────────────────

(defun jetpacs-devtools-last-spec (view)
  "The spec VIEW's builder last produced, or nil.
The raw material for \"what did the phone actually receive\" questions;
pretty-print it with `pp'."
  (gethash view jetpacs-devtools--specs))

(defun jetpacs-devtools-reset ()
  "Drop all recorded instrumentation."
  (interactive)
  (clrhash jetpacs-devtools--builds)
  (clrhash jetpacs-devtools--specs)
  (clrhash jetpacs-devtools--frames)
  (setq jetpacs-devtools--frame-count 0
        jetpacs-devtools--frame-bytes 0
        jetpacs-devtools--push-times nil
        jetpacs-devtools--storm-warned-at 0))

(defun jetpacs-devtools-report ()
  "Render the instrumentation report into *jetpacs-devtools*."
  (interactive)
  (let ((buf (get-buffer-create "*jetpacs-devtools*"))
        (now (float-time)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Jetpacs devtools — %s%s\n\n"
                        (format-time-string "%F %T")
                        (if jetpacs-devtools-enabled "" "  [recording DISABLED]")))
        (insert (format "Frames sent: %d total, %d bytes; surface pushes in last %ds: %d\n\n"
                        jetpacs-devtools--frame-count
                        jetpacs-devtools--frame-bytes
                        jetpacs-devtools-storm-window
                        (cl-count-if (lambda (tm) (<= (- now tm) jetpacs-devtools-storm-window))
                                     jetpacs-devtools--push-times)))
        (insert "Surfaces (last surface.update):\n")
        (let (rows)
          (maphash (lambda (s rec) (push (cons s rec) rows)) jetpacs-devtools--frames)
          (if (null rows)
              (insert "  (none observed)\n")
            (dolist (row (cl-sort rows #'> :key (lambda (r) (plist-get (cdr r) :last-bytes))))
              (insert (format "  %-28s %8d bytes  x%-4d %s\n"
                              (car row)
                              (plist-get (cdr row) :last-bytes)
                              (plist-get (cdr row) :count)
                              (format-time-string "%T" (plist-get (cdr row) :at)))))))
        (insert "\nBuilders (wall clock):\n")
        (let (rows)
          (maphash (lambda (v rec) (push (cons v rec) rows)) jetpacs-devtools--builds)
          (if (null rows)
              (insert "  (none observed)\n")
            (dolist (row (cl-sort rows #'> :key (lambda (r) (plist-get (cdr r) :last-ms))))
              (insert (format "  %-28s last %7.1f ms  max %7.1f ms  x%d\n"
                              (car row)
                              (plist-get (cdr row) :last-ms)
                              (plist-get (cdr row) :max-ms)
                              (plist-get (cdr row) :count))))))
        (insert "\nLast specs retained per view — (jetpacs-devtools-last-spec VIEW)\n"))
      (special-mode))
    (display-buffer buf)))

;; The observer costs one nil test per send until this file loads —
;; and this file ships in the core bundle, so on a live session the
;; hook is simply always installed.
(setq jetpacs--frame-observer #'jetpacs-devtools--observe-frame)

(provide 'jetpacs-devtools)
;;; jetpacs-devtools.el ends here
