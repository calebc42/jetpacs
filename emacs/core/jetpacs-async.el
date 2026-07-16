;;; jetpacs-async.el --- Declarative async loading for Jetpacs views -*- lexical-binding: t; -*-

;; The B1 tier of the DSL-ergonomics plan (docs/PLAN-dsl-ergonomics.md):
;; a keyed loader state machine so a Tier 1 stops hand-rolling the three
;; display states of every fetch — kick a request off in a handler, stash
;; the result in a defvar, re-push, branch on pending/ready/error by hand.
;;
;; `jetpacs-async' is called from *inside* a view builder (like React's
;; use-async / vui's `use-async'): it returns the current (STATUS . PAYLOAD)
;; for a KEY, starting the loader once on first sight and caching the result.
;; The builder stays a pure function of the cache; the one controlled
;; impurity is the idempotent first-call start.  A loader's completion
;; schedules a single coalesced `jetpacs-shell-push', so the view re-renders
;; and reads the ready value on the next build.
;;
;; Eviction rides the push cycle.  Each build stamps every KEY it asks for
;; with the current generation; `jetpacs-shell-after-push-hook' then sweeps
;; entries no build asked for this generation (running any cancel thunk the
;; loader registered) and advances the generation — the precise mirror of a
;; component unmount, so a view that stops asking for data stops paying for
;; it.  App teardown (`jetpacs-app-unregister') additionally drops every
;; entry scoped to that owner.
;;
;; Unlike the pure `jetpacs-widgets' composites this module carries mutable
;; runtime state and a push dependency, so it lives on its own and is
;; required by `jetpacs-shell'.  It adds nothing to the wire vocabulary.

;;; Code:

(require 'cl-lib)

;; Resolved at runtime / load time from other core modules; forward-declared
;; here so this file byte-compiles clean and can load before them.
(defvar jetpacs-current-owner)                 ; jetpacs-surfaces.el
(defvar jetpacs-shell-after-push-hook)         ; jetpacs-shell.el
(declare-function jetpacs-shell-push "jetpacs-shell")

(cl-defstruct (jetpacs-async--entry (:constructor jetpacs-async--entry-make)
                                    (:copier nil))
  "One cached async load.
STATUS is `pending', `ready', or `error'; VALUE is the resolved value or
the error message string; GEN is the push-generation stamp driving the
sweep; OWNER scopes the entry to an app for teardown; CANCEL is an optional
thunk the loader registered to abort itself (kill a process, cancel a
timer)."
  status value gen owner cancel)

(defvar jetpacs-async--cache (make-hash-table :test 'equal)
  "Map of KEY -> `jetpacs-async--entry'.  KEY is compared `equal'.")

(defvar jetpacs-async--generation 0
  "Advanced after each shell push.
Each live entry is stamped with the generation of the build that last asked
for it; entries left behind an older generation belong to views that stopped
asking, and are swept (see `jetpacs-async--after-push').")

(defvar jetpacs-async--push-timer nil
  "Debounce timer coalescing the completion pushes of one tick into one.")

;; ─── Completion push (debounced) ─────────────────────────────────────────────

(defun jetpacs-async--schedule-push ()
  "Schedule one shell push after a completion, coalescing a burst.
Deferred through a zero-delay timer, not called inline: a loader that
resolves synchronously does so *while a build is running*, and pushing from
within a build would recurse."
  (unless (timerp jetpacs-async--push-timer)
    (setq jetpacs-async--push-timer
          (run-at-time 0 nil #'jetpacs-async--flush-push))))

(defun jetpacs-async--flush-push ()
  "Run the pending coalesced push now (the debounce timer's target)."
  (when (timerp jetpacs-async--push-timer)
    (cancel-timer jetpacs-async--push-timer))
  (setq jetpacs-async--push-timer nil)
  (when (fboundp 'jetpacs-shell-push)
    (jetpacs-shell-push)))

;; ─── The loader ──────────────────────────────────────────────────────────────

(defun jetpacs-async--message (err)
  "Normalize ERR (a message string or an error object) to a message string."
  (cond ((stringp err) err)
        ((and (consp err) (symbolp (car err))) (error-message-string err))
        (t (format "%s" err))))

(defun jetpacs-async--settle (entry status value)
  "Set ENTRY to STATUS with VALUE and schedule the coalesced re-render.
A completion for an entry already swept from the cache still schedules a
push; it is harmless (the next build simply does not read the orphan)."
  (setf (jetpacs-async--entry-status entry) status
        (jetpacs-async--entry-value entry) value)
  (jetpacs-async--schedule-push))

(defun jetpacs-async--start (entry loader)
  "Start LOADER for ENTRY, catching a synchronous throw.
LOADER is (lambda (resolve reject) ...): it calls RESOLVE with the value or
REJECT with an error string, and may return a cleanup thunk stored as the
entry's cancel."
  (let ((resolve (lambda (value) (jetpacs-async--settle entry 'ready value)))
        (reject  (lambda (err)
                   (jetpacs-async--settle entry 'error
                                          (jetpacs-async--message err)))))
    (condition-case err
        (let ((cleanup (funcall loader resolve reject)))
          (when (functionp cleanup)
            (setf (jetpacs-async--entry-cancel entry) cleanup)))
      (error (jetpacs-async--settle entry 'error (error-message-string err))))))

(defun jetpacs-async--read (entry)
  "The (STATUS . PAYLOAD) pair a caller reads from ENTRY."
  (pcase (jetpacs-async--entry-status entry)
    ('ready (cons 'ready (jetpacs-async--entry-value entry)))
    ('error (cons 'error (jetpacs-async--entry-value entry)))
    (_      '(pending))))

;;;###autoload
(cl-defun jetpacs-async (key loader &key owner)
  "Return the async state for KEY as (STATUS . PAYLOAD).
STATUS is `pending', `ready', or `error'.

Call this from inside a view builder.  On the first call for a fresh KEY
\(compared `equal') start LOADER once and return `(pending)'.  LOADER is a
function (lambda (RESOLVE REJECT) ...): call RESOLVE with the value or
REJECT with an error string; either stores the result and schedules a
single coalesced `jetpacs-shell-push', so the view re-renders and a later
call returns `(ready . VALUE)' / `(error . MESSAGE)' from cache.  A LOADER
that throws synchronously is caught and becomes `(error . MESSAGE)' — it
never takes down the push.  LOADER may return a cleanup thunk (a function),
run when the entry is swept, to abort itself (kill a process, cancel a
timer).

The first call always reports `(pending)', even for a loader that resolves
synchronously: the value it produced surfaces on the next build (via the
push its completion scheduled), keeping one code path for sync and async
sources alike.

Eviction: a KEY not asked for in a given push is swept after that push, so
a view that stops asking for data stops paying for it.  OWNER scopes the
entry to an app for teardown (defaults to the current `with-jetpacs-owner');
`jetpacs-app-unregister' drops every entry it owns.

Usage:

  (pcase (jetpacs-async (list \\='stock product-id)
                        (lambda (resolve reject)
                          (grocy--fetch-stock product-id resolve reject)))
    (`(pending . ,_) (jetpacs-progress))
    (`(error   . ,e) (jetpacs-error e))
    (`(ready   . ,d) (stock-card d)))"
  (let ((entry (gethash key jetpacs-async--cache)))
    (if entry
        ;; Seen before: mark it live for this generation, read the cache.
        (progn
          (setf (jetpacs-async--entry-gen entry) jetpacs-async--generation)
          (jetpacs-async--read entry))
      ;; Fresh: register a pending entry, start the loader once, report pending.
      (setq entry (jetpacs-async--entry-make
                   :status 'pending
                   :gen jetpacs-async--generation
                   :owner (or owner (bound-and-true-p jetpacs-current-owner))))
      (puthash key entry jetpacs-async--cache)
      (jetpacs-async--start entry loader)
      '(pending))))

;; ─── Eviction ────────────────────────────────────────────────────────────────

(defun jetpacs-async--run-cancel (entry)
  "Run ENTRY's registered cancel thunk once, swallowing its errors."
  (let ((cancel (jetpacs-async--entry-cancel entry)))
    (when cancel
      (setf (jetpacs-async--entry-cancel entry) nil)
      (condition-case err
          (funcall cancel)
        (error (message "jetpacs-async: cancel failed: %s"
                        (error-message-string err)))))))

(defun jetpacs-async--after-push ()
  "Sweep entries no build asked for this generation, then advance it.
An entry stamped with the current generation was read by the build that
just pushed and survives; one stamped earlier belongs to a view that
stopped asking, so its cancel runs and the entry is dropped.  Registered on
`jetpacs-shell-after-push-hook'."
  (let ((gen jetpacs-async--generation))
    (maphash (lambda (key entry)
               (when (< (jetpacs-async--entry-gen entry) gen)
                 (jetpacs-async--run-cancel entry)
                 (remhash key jetpacs-async--cache)))
             jetpacs-async--cache))
  (cl-incf jetpacs-async--generation))

(defun jetpacs-async-clear-owner (owner)
  "Drop every async entry scoped to OWNER (an app id), running its cancels.
Called from `jetpacs-app-unregister', so a torn-down app leaks no loads."
  (maphash (lambda (key entry)
             (when (equal (jetpacs-async--entry-owner entry) owner)
               (jetpacs-async--run-cancel entry)
               (remhash key jetpacs-async--cache)))
           jetpacs-async--cache))

(defun jetpacs-async-reset ()
  "Drop all async state, running every cancel thunk.  For teardown and tests."
  (maphash (lambda (_key entry) (jetpacs-async--run-cancel entry))
           jetpacs-async--cache)
  (clrhash jetpacs-async--cache)
  (setq jetpacs-async--generation 0)
  (when (timerp jetpacs-async--push-timer)
    (cancel-timer jetpacs-async--push-timer))
  (setq jetpacs-async--push-timer nil))

;; The sweep rides the shell's post-push hook.  Registered once the shell is
;; loaded (this file is required by `jetpacs-shell', so it may load first).
(with-eval-after-load 'jetpacs-shell
  (add-hook 'jetpacs-shell-after-push-hook #'jetpacs-async--after-push))

(provide 'jetpacs-async)
;;; jetpacs-async.el ends here
