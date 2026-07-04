;;; glasspane-demo.el --- Guided-tour demo files for the mobile IDE -*- lexical-binding: t; -*-

;; Writes a set of small tour files into `glasspane-demo-directory' so the
;; phone editor's IDE features can be demoed on demand: completion,
;; eldoc signatures, and flymake squiggles today; each file also marks
;; what upgrades once the eglot phase lands.
;;
;; The files ship *inside the bundle* rather than as repo files because
;; Emacs's home on Android is app-private storage — adb can't push into
;; it, but Emacs itself can write there.  Run `M-x glasspane-demo-setup' (or
;; the `demo.setup' action from the phone) and the files appear under
;; the Files tab.  Setup always overwrites, so a mangled demo resets to
;; pristine by running it again.

;;; Code:

(require 'eabp-surfaces)

(defcustom glasspane-demo-directory "~/glasspane-demo/"
  "Directory `glasspane-demo-setup' writes the tour files into.
Must lie within `eabp-files-roots' to be reachable from the phone's
Files browser (the default is inside the Home root)."
  :type 'directory :group 'eabp)

(defconst glasspane-demo--files
  `(("demo.el" . "\
;;; demo.el --- Glasspane mobile IDE tour -*- lexical-binding: t; -*-

;; Welcome!  This buffer is live-synced to your Emacs while you type.
;; Everything below runs against the real Emacs image on this device.

;; ── 1. Completion ────────────────────────────────────────────────
;; On the blank line below, type   (buffer-sub   and pause.
;; Chips appear above the keyboard; tap one to accept — mobile TAB.


;; ── 2. Signatures (eldoc) ────────────────────────────────────────
;; Tap to place the cursor inside the `concat' call below and pause.
;; Its signature appears in the doc line above the keyboard.

(defun demo-greet (name)
  \"Return a friendly greeting for NAME.\"
  (concat \"Hello, \" name \"!\"))

;; ── 3. Diagnostics (flymake) ─────────────────────────────────────
;; A few seconds after this file opens, the real byte-compiler flags
;; the two functions below with squiggles.  Tap inside one to read
;; its message in the doc line.

(defun demo-unused (thing)
  \"THING is never used, and the byte-compiler notices.\"
  42)

(defun demo-wrong-arity ()
  \"Calls `demo-greet' with one argument too many.\"
  (demo-greet \"world\" 'oops))

;; ── 4. Break something yourself ──────────────────────────────────
;; Delete the closing paren of any defun above and pause: a squiggle
;; appears.  Undo, pause, and it clears.

(provide 'demo)
;;; demo.el ends here
")
    ("demo.py" . "\
\"\"\"Glasspane mobile IDE tour - Python.

With pylsp installed in Termux (pip install python-lsp-server) and
the eglot bridge on, this file gets REAL language-server completion,
hover, and diagnostics.  Without a server it degrades gracefully to
same-buffer word completion.
\"\"\"


def fibonacci(n: int) -> int:
    \"\"\"Return the n-th Fibonacci number (naive on purpose).\"\"\"
    if n < 2:
        return n
    return fibonacci(n - 1) + fibonacci(n - 2)


def fibonacci_sequence(count: int) -> list[int]:
    \"\"\"Return the first COUNT Fibonacci numbers.\"\"\"
    return [fibonacci(i) for i in range(count)]


# 1. Completion: on the line below, type   fib   and pause.
#    With pylsp: type   fibonacci_sequence(10).   for list methods.


# 2. Diagnostics (needs pyflakes: pip install pyflakes in Termux).
#    Both lines below earn squiggles from the server:
import os  # <- 'os' imported but unused


def uses_an_undefined_name():
    return undefined_name  # <- undefined name

if __name__ == \"__main__\":
    print(fibonacci_sequence(10))
")
    ("demo.sh" . "\
#!/data/data/com.termux/files/usr/bin/bash
# Glasspane mobile IDE tour - Shell.
#
# The most on-brand language here: sh-mode is built into Emacs, and
# bash-language-server installs straight into Termux
# (npm install -g bash-language-server) for full LSP via eglot.
# Without it: same-buffer word completion still works.

greet_user() {
    local name=\"$1\"
    echo \"Hello, ${name}!\"
}

count_greetings() {
    local total=\"$1\"
    for i in $(seq 1 \"$total\"); do
        greet_user \"friend #$i\"
    done
}

# 1. Completion: on the line below, type   gre   and pause.


count_greetings 3
")
    ("demo.org" . "\
#+title: Glasspane mobile IDE tour — Org

This file opens in the foldable reader; toggle to the raw editor
to try the features below.

* What works in org today
- Word completion from this buffer: type =comp= in the scratch
  section and pause.
- The org formatting toolbar sits under the editor.

* TODO Try tag completion                                    :server:
If your init opts =my/org-tag-completion= into shadow buffers via
=eabp-sync-shadow-setup-hook=, typing =:ser= at the end of a
headline completes your =:server:= tag from the phone.

* Scratch space
Type here — completion offers words already in this file, like
completion or formatting or headline.
"))
  "Alist of (FILENAME . CONTENT) written by `glasspane-demo-setup'.")

;;;###autoload
(defun glasspane-demo-setup (&optional dir)
  "Write the mobile-IDE tour files into DIR (default `glasspane-demo-directory').
Existing copies are overwritten so the tour always starts pristine.
Returns the directory the files were written to."
  (interactive)
  (let ((dir (file-name-as-directory
              (expand-file-name (or dir glasspane-demo-directory))))
        ;; The tour files contain non-ASCII (section rules, em-dashes);
        ;; pin utf-8 so no platform default can make write-region prompt.
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (dolist (spec glasspane-demo--files)
      (write-region (cdr spec) nil (expand-file-name (car spec) dir)
                    nil 'silent))
    (when (called-interactively-p 'interactive)
      (message "EABP demo files written to %s" dir))
    dir))

(eabp-defaction "demo.setup"
  ;; Allowlisted and argument-free: always writes the fixed file set into
  ;; `glasspane-demo-directory' — nothing on the wire chooses paths or content.
  (lambda (_ _)
    (glasspane-demo-setup)
    (when (fboundp 'eabp-shell-notify)
      (eabp-shell-notify
       (format "Demo files in %s"
               (abbreviate-file-name
                (expand-file-name glasspane-demo-directory)))))))

(provide 'glasspane-demo)
;;; glasspane-demo.el ends here
