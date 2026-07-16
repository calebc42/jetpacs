;;; jetpacs-comint.el --- Generic comint renderer (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: `comint-mode' is the substrate under every process REPL —
;; M-x shell, ielm, the inferior language shells — so ONE skin covers
;; them all, the same bet jetpacs-tablist makes on tabulated-list-mode.
;; The transcript renders through the Tier 0 walk (fontification and
;; tappable regions survive), tail-first because a REPL's interesting
;; end is the bottom; below it sit a status/interrupt row and an input
;; row whose submit dispatches `comint.send'.
;;
;; Boundary (ebp/SPEC.md §5): `comint.send' delivers input only to the
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
