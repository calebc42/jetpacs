;;; glasspane-demo.el --- Guided-tour demo files for the mobile IDE -*- lexical-binding: t; -*-

;; Writes a set of small tour files into `glasspane-demo-directory' so the
;; phone editor's IDE features can be demoed on demand: completion,
;; eldoc signatures, and flymake squiggles today; each file also marks
;; what upgrades once the eglot phase lands.  A companion org corpus
;; (`glasspane-demo-setup-org') resets `org-directory' to a de-personalized
;; set of files exercising tables, babel, LaTeX, drawers, and the agenda.
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
    ("demo.c" . "\
/* Glasspane mobile IDE tour - C.
 *
 * Tree-sitter: with the c grammar installed and c-mode remapped to
 * c-ts-mode in your init, this file's colors come from tree-sitter,
 * pushed by Emacs (fontify.show) in your real theme.
 *
 * LSP: with clangd on the exec-path (Termux), eglot adds completion,
 * hover, and diagnostics. Without it: word completion still works.
 */

#include <stdio.h>

static long fibonacci(int n) {
    return n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2);
}

static void print_sequence(int count) {
    for (int i = 0; i < count; i++) {
        printf(\"%ld\\n\", fibonacci(i));
    }
}

/* 1. Completion: on the line below, type   fib   and pause.
 * 2. With clangd: add an undefined call like  missing();  inside
 *    main and pause for the squiggle. */


int main(void) {
    print_sequence(10);
    return 0;
}
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

;; ─── Demo org corpus ─────────────────────────────────────────────────────────
;; A small, de-personalized set of org files exercising every rendering
;; feature the phone supports: native tables with #+TBLFM recalculation,
;; babel blocks (run-button gating included), LaTeX fragments (for when
;; preview lands), drawers, statistics cookies, footnotes, id: links,
;; repeaters, and custom TODO keywords.  Written into `org-directory' by
;; `glasspane-demo-setup-org' — same ship-inside-the-bundle rationale as
;; the tour files above.

(defconst glasspane-demo--org-files
  '(("health.org" . "\
#+TITLE: Health & Fitness
#+STARTUP: overview
#+TODO: TODO IN-PROGRESS | DONE CANCELLED

* Training Log
:PROPERTIES:
:ID:       8f5d7c3a-c707-4cf3-bcdb-4d8019d57bc6
:END:
Tap a cell to edit it — the totals row recalculates in Emacs.

| Date             | Push-Ups | Squats | Miles |
|------------------+----------+--------+-------|
| [2026-06-29 Mon] |       40 |     60 |   2.5 |
| [2026-07-01 Wed] |       45 |     65 |   3.1 |
| [2026-07-03 Fri] |       50 |     70 |   2.8 |
|------------------+----------+--------+-------|
| Total            |      135 |    195 |   8.4 |
#+TBLFM: @>$2=vsum(@I..@II)::@>$3=vsum(@I..@II)::@>$4=vsum(@I..@II);%.1f

** Weekly routine [2/4]
- [X] Run 5K
- [X] Yoga session
- [ ] Long hike
- [ ] Strength training

* Goals
:PROPERTIES:
:ID:       6cb4432e-b24a-437d-9278-0421d01155eb
:END:
** IN-PROGRESS [#A] Hike a rim-to-rim canyon route             :fitness:goal:
DEADLINE: <2026-08-15 Sat>
:PROPERTIES:
:Effort:   8h
:ID:       d825ffc9-1160-49cc-b2d0-113c7436deb7
:END:
:LOGBOOK:
CLOCK: [2026-07-01 Wed 06:30]--[2026-07-01 Wed 07:15] =>  0:45
:END:
Need to build up to *20+ mile* days.  Current max: /about 12 miles/.

** IN-PROGRESS Run a sub-25 minute 5K                                 :goal:
SCHEDULED: <2026-07-06 Mon> DEADLINE: <2026-08-01 Sat>
:PROPERTIES:
:ID:       6c4b91a5-b4f6-43ea-8ad9-56d1ac8e8e03
:END:
:LOGBOOK:
CLOCK: [2026-07-02 Thu 18:10]--[2026-07-02 Thu 18:40] =>  0:30
- Note taken on [2026-07-02 Thu 18:45] \\\\
  Negative splits felt easier this week.
:END:
Recent attempts:

| Date             |  Time |
|------------------+-------|
| [2026-06-20 Sat] | 28:11 |
| [2026-06-27 Sat] | 27:42 |

** TODO Weekly long run                                            :fitness:
SCHEDULED: <2026-07-05 Sun +1w>
:PROPERTIES:
:ID:       a91d1e27-afc6-4b24-b5bc-e916730f6043
:END:

** DONE Complete 30-day yoga challenge                        :fitness:goal:
CLOSED: [2026-06-26 Fri 18:00]
:PROPERTIES:
:ID:       a5504036-77b4-42f5-89bd-ffbad8038822
:END:

* Reference
:PROPERTIES:
:ID:       3d83cd97-6188-4074-9c66-6c273c6a89d5
:END:
:NUTRITION:
Protein target: 140 g/day.  Hydration: 3 L minimum.
:END:
Resting heart rate trend: 58 \\rightarrow 54 bpm since March.
")
    ("inbox.org" . "\
#+TITLE: Inbox
#+STARTUP: overview
#+TODO: TODO IDEA | DONE

* TODO Read /Designing Data-Intensive Applications/, chapter 6     :reading:
SCHEDULED: <2026-07-06 Mon>
:PROPERTIES:
:Effort:   1h
:ID:       5359bbea-6de3-4aba-bc86-fb46122005d3
:END:
The partitioning chapter pairs well with the replication notes[fn:1].

** Highlights so far
:PROPERTIES:
:ID:       e372b40c-f1fe-490a-9832-3b517af0309c
:END:
- Rebalancing strategies: fixed partitions vs. dynamic splitting
- Request routing belongs in a /separate/ layer

* TODO Look into Nix flakes for a reproducible dev setup          :computer:
:PROPERTIES:
:Effort:   1h
:ID:       2bfc9a36-831f-4bcc-8431-d7373a47e151
:END:

* TODO Fix the leaky faucet in the guest bathroom                     :home:
SCHEDULED: <2026-07-07 Tue>
:PROPERTIES:
:ID:       eda8dcb1-311e-400a-b713-25b73941bcaf
:END:

* IDEA Kanban board backed by plain org files                      :project:
:PROPERTIES:
:ID:       a0a70496-49c8-475d-bbc6-b507e8c43d82
:END:
Columns map to TODO keywords; drag-and-drop rewrites the keyword.
Could run on the [[id:86b18efc-f950-4c22-b006-5af19d0e1a74][home server]].

* TODO [#B] Renew the domain registration                            :admin:
SCHEDULED: <2026-07-08 Wed> DEADLINE: <2026-07-31 Fri>
:PROPERTIES:
:Effort:   10min
:ID:       cff8c2b4-da5a-46c1-aab4-9661c6e65368
:END:
Registrar dashboard: [[https://example.com/domains][example.com/domains]]

* TODO Order a replacement HEPA filter                          :home:errand:
SCHEDULED: <2026-07-05 Sun>
:PROPERTIES:
:ID:       2bf199b2-ab05-430d-a48c-81550252f6c3
:END:

* TODO [#A] Back up phone photos [0/3]                             :digital:
DEADLINE: <2026-07-09 Thu>
:PROPERTIES:
:Effort:   30min
:ID:       68fbf216-c578-41f1-b570-2b52ed092d13
:END:
- [ ] Mount the network share
- [ ] Sync the camera folder
- [ ] Verify checksums

* Footnotes

[fn:1] Chapter 5, replication — reread the section on quorums.
")
    ("project.org" . "\
#+TITLE: Projects
#+STARTUP: overview
#+TODO: TODO IN-PROGRESS | DONE CANCELLED

* Mobile companion app                                            :software:
:PROPERTIES:
:ID:       f95e563c-62e9-4c8a-bff6-eef9194f9660
:END:
** DONE [#A] Phase 1 — Core features
DEADLINE: <2026-06-15 Mon>
:PROPERTIES:
:Effort:   20h
:ID:       9bfcf1a9-b6bb-48fd-9b21-898804c6036e
:END:
*** DONE Foldable document reader
CLOSED: [2026-06-11 Thu 16:45]
:PROPERTIES:
:ID:       61a44fea-a312-4b53-93a5-3e9147d4c2bf
:END:
*** DONE Agenda with day/week/month views
CLOSED: [2026-06-12 Fri 10:20]
:PROPERTIES:
:ID:       0b6cfc7f-0a29-438a-a25d-2d2d07c97677
:END:
*** DONE Search across files
CLOSED: [2026-06-12 Fri 17:02]
:PROPERTIES:
:ID:       9142df4e-e85a-4cf1-9675-943e16da5e47
:END:

** IN-PROGRESS [#B] Phase 2 — Rich content
SCHEDULED: <2026-07-01 Wed>
:PROPERTIES:
:ID:       933b2dfe-0b63-46ad-a4c4-6bfa8a847b2c
:END:
*** DONE Native tables with formula recalculation
CLOSED: [2026-07-04 Sat 18:30]
:PROPERTIES:
:ID:       abcfe479-27c0-4d86-b336-ad8d56e3c700
:END:
*** TODO Inline LaTeX previews
:PROPERTIES:
:ID:       c8d7b18d-de46-4934-aab4-ef46096a4de5
:END:
*** TODO Transcluded sections
:PROPERTIES:
:ID:       71a8da2a-c295-4b30-807b-bb845bf72fd7
:END:

** TODO [#C] Phase 3 — Polish & distribution
SCHEDULED: <2026-08-01 Sat>
:PROPERTIES:
:ID:       7ca33acb-b76d-4e5b-b980-cae51fccb33b
:END:
*** TODO Packaging for app stores
*** TODO Landing page and README
*** TODO Demo video

** Build size tracking
:PROPERTIES:
:ID:       5e097c4d-442a-4376-b691-7b513864a666
:END:
Run the block to regenerate the table below it.

#+begin_src emacs-lisp :results table
(mapcar (lambda (r) (list (car r) (cdr r)))
        '((\"v0.1\" . 3.9) (\"v0.2\" . 4.6) (\"v0.3\" . 5.2)))
#+end_src

#+RESULTS:
| v0.1 | 3.9 |
| v0.2 | 4.6 |
| v0.3 | 5.2 |

* Home server                                                     :selfhost:
:PROPERTIES:
:ID:       86b18efc-f950-4c22-b006-5af19d0e1a74
:END:
** DONE [#B] Migrate file sync to the new VPS                    :migration:
CLOSED: [2026-06-30 Tue 21:00]
:PROPERTIES:
:Effort:   4h
:ID:       ec0731bb-ff11-4632-b25c-5409ee1325c6
:END:

** TODO Set up a WireGuard tunnel to the phone                  :networking:
SCHEDULED: <2026-07-10 Fri>
:PROPERTIES:
:Effort:   2h
:ID:       b66f76ee-b3d6-414e-a7c9-cf7888ba26c9
:END:

** TODO [#A] Fix the failing backup cron job                        :urgent:
DEADLINE: <2026-07-05 Sun>
:PROPERTIES:
:Effort:   1h
:ID:       17ada464-8c94-4827-afe1-981cc8955492
:END:
The unit fires but the target never mounts.  Current crontab entry:

#+begin_example
0 3 * * * /usr/local/bin/backup.sh --incremental
#+end_example

Check the mount from the phone:

#+begin_src sh :results output
df -h | head -3
#+end_src

* Side projects                                                        :fun:
:PROPERTIES:
:ID:       4fa298a0-5c68-442a-ba4c-b3c71adc00cf
:END:
** TODO CLI pomodoro timer in Rust                                    :rust:
:PROPERTIES:
:Effort:   4h
:ID:       f263c776-dc0c-4998-8c34-72cbc93b77c7
:END:
The run button only appears for languages this Emacs can execute:

#+begin_src rust
fn main() {
    println!(\"25:00 — focus\");
}
#+end_src

** DONE ASCII-art welcome banner for the terminal
CLOSED: [2026-06-20 Sat 12:00]
:PROPERTIES:
:ID:       bbdf1a74-406f-4c12-866a-046462853f63
:END:
")
    ("notes.org" . "\
#+TITLE: Study Notes
#+STARTUP: overview

* Calculus — the Gaussian integral                                    :math:
:PROPERTIES:
:ID:       53e5ad9b-a66d-480b-b91a-050f526515ab
:END:
The definite integral every statistics course leans on:

\\[ \\int_{-\\infty}^{\\infty} e^{-x^2} \\, dx = \\sqrt{\\pi} \\]

Inline fragments work too: the normal density peaks at
\\(1/\\sqrt{2\\pi\\sigma^2}\\).

* Physics — mass–energy equivalence                                :physics:
:PROPERTIES:
:ID:       94bff2e9-8e82-40d5-9403-b9278cc3a1ec
:END:
Einstein's E = mc^{2} relates rest mass to energy.  Water is H_{2}O;
the decay \\alpha \\rightarrow \\beta + \\gamma conserves both.

* Chemistry reference table                                           :chem:
:PROPERTIES:
:ID:       4ff4f602-382c-4e15-9ce5-faf3d7525daa
:END:
Alignment cookies pin each column: left, center, right.

| Element  | Symbol | Atomic mass |
| <l>      |  <c>   |         <r> |
|----------+--------+-------------|
| Hydrogen |   H    |       1.008 |
| Carbon   |   C    |      12.011 |
| Nitrogen |   N    |      14.007 |
| Oxygen   |   O    |      15.999 |

* Babel playground                                                    :code:
:PROPERTIES:
:ID:       ba4b6d51-efe5-44b7-a702-a302d5c3e27d
:END:
Tap the play button on a block to execute it in Emacs on this device.

#+begin_src emacs-lisp
(emacs-version)
#+end_src

#+begin_src emacs-lisp :results table
(mapcar (lambda (n) (list n (* n n) (* n n n)))
        (number-sequence 1 5))
#+end_src

#+RESULTS:
| 1 |  1 |   1 |
| 2 |  4 |   8 |
| 3 |  9 |  27 |
| 4 | 16 |  64 |
| 5 | 25 | 125 |

Shell blocks need =(shell . t)= in =org-babel-load-languages=:

#+begin_src sh :results output
uname -o && whoami
#+end_src

* A linked image
:PROPERTIES:
:ID:       c60ffce1-4449-4689-87a0-d8489b262e42
:END:
Remote images render inline when the device is online:

[[https://picsum.photos/seed/orgdemo/600/300.jpg]]
")
    ("quotes.org" . "\
#+TITLE: Quotes
#+STARTUP: overview

* Marcus Aurelius
:PROPERTIES:
:ID:       8249dcbc-7d87-4c0e-a8b2-58fbd1245091
:END:
#+begin_quote
You have power over your mind — not outside events.  Realize this,
and you will find strength.
#+end_quote
Captured: [2026-05-15 Fri 08:30]

* Alan Kay
:PROPERTIES:
:ID:       8fee047a-29e5-4ef0-93df-cc8462ac56b4
:END:
#+begin_quote
The best way to predict the future is to /invent/ it.
#+end_quote
Captured: [2026-05-28 Thu 14:22]

* Grace Hopper
:PROPERTIES:
:ID:       9142df4e-0000-4cf1-9675-943e16da5e47
:END:
#+begin_quote
The most dangerous phrase in the language is, \\\"We've always done it
this way.\\\"
#+end_quote
Captured: [2026-06-05 Fri 19:45]

* Antoine de Saint-Exupéry
:PROPERTIES:
:ID:       933b2dfe-0000-46ad-a4c4-6bfa8a847b2c
:END:
#+begin_verse
Perfection is achieved, not when there is nothing more to add,
but when there is nothing left to take away.
#+end_verse
Captured: [2026-06-18 Thu 09:12]

* Carver Mead
:PROPERTIES:
:ID:       abcfe479-0000-4d86-b336-ad8d56e3c700
:END:
#+begin_quote
Listen to the technology; find out what it's telling you.
#+end_quote
Captured: [2026-07-01 Wed 16:40]
")
    ("trackers.org" . "\
#+TITLE: Task Tracker
#+STARTUP: overview
#+TODO: TODO IN-PROGRESS | DONE CANCELLED

* IN-PROGRESS [#A] Prepare the quarterly demo                         :work:
DEADLINE: <2026-07-06 Mon>
:PROPERTIES:
:Effort:   45min
:ID:       eda8dcb1-0000-400a-b713-25b73941bcaf
:END:
:LOGBOOK:
CLOCK: [2026-07-03 Fri 08:20]--[2026-07-03 Fri 08:34] =>  0:14
CLOCK: [2026-07-02 Thu 09:00]--[2026-07-02 Thu 10:21] =>  1:21
:END:
Slides: [[https://example.com/slides][deck draft]]

* TODO [#A] Finish the agenda screen                              :software:
SCHEDULED: <2026-07-06 Mon>
:PROPERTIES:
:Effort:   2h
:ID:       a0a70496-0000-475d-bbc6-b507e8c43d82
:END:
:LOGBOOK:
CLOCK: [2026-06-29 Mon 02:39]--[2026-06-29 Mon 04:00] =>  1:21
:END:
** TODO Wire up the date-picker component
DEADLINE: <2026-07-07 Tue>
:PROPERTIES:
:ID:       86b18efc-0000-4c22-b006-5af19d0e1a74
:END:
** DONE Parse the agenda payload on the client
CLOSED: [2026-07-01 Wed 14:32]
:PROPERTIES:
:ID:       cff8c2b4-0000-46c1-aab4-9661c6e65368
:END:
** DONE Add the swipe-to-archive gesture
CLOSED: [2026-06-29 Mon 02:13]
:PROPERTIES:
:ID:       2bf199b2-0000-430d-a48c-81550252f6c3
:END:
:LOGBOOK:
CLOCK: [2026-06-29 Mon 02:08]--[2026-06-29 Mon 02:13] =>  0:05
:END:

* TODO Weekly grocery run                                           :errand:
SCHEDULED: <2026-07-07 Tue +1w>
:PROPERTIES:
:ID:       68fbf216-0000-41f1-b570-2b52ed092d13
:LAST_REPEAT: [2026-06-30 Tue 18:37]
:END:
:LOGBOOK:
- State \"DONE\"       from \"TODO\"       [2026-06-30 Tue 18:37]
:END:

* IN-PROGRESS Call the insurance company about the claim      :phone:errand:
SCHEDULED: <2026-07-06 Mon>
:PROPERTIES:
:ID:       f95e563c-0000-4c8a-bff6-eef9194f9660
:END:

* IN-PROGRESS [#B] Write a blog post about server-driven UI        :writing:
SCHEDULED: <2026-07-08 Wed> DEADLINE: <2026-07-12 Sun>
:PROPERTIES:
:Effort:   2h
:ID:       9bfcf1a9-0000-48fd-9b21-898804c6036e
:END:
:LOGBOOK:
CLOCK: [2026-07-02 Thu 22:20]--[2026-07-02 Thu 22:33] =>  0:13
CLOCK: [2026-07-01 Wed 20:05]--[2026-07-01 Wed 20:35] =>  0:30
:END:
Outline: what /server-driven/ buys you on mobile, and where it hurts.

* DONE [#B] Set up folder sync between phone and laptop              :sync:
CLOSED: [2026-06-27 Sat 11:40]
:PROPERTIES:
:Effort:   1h
:ID:       61a44fea-0000-4b53-93a5-3e9147d4c2bf
:END:

* DONE Clean the kitchen                                              :home:
CLOSED: [2026-07-03 Fri 21:30]
:PROPERTIES:
:ID:       0b6cfc7f-0000-438a-a25d-2d2d07c97677
:END:

* DONE Send the invoice to the client                         :work:finance:
CLOSED: [2026-07-02 Thu 09:15]
:PROPERTIES:
:Effort:   15min
:ID:       9142df4e-1111-4cf1-9675-943e16da5e47
:END:
"))
  "Alist of (FILENAME . CONTENT) written by `glasspane-demo-setup-org'.")

;;;###autoload
(defun glasspane-demo-setup-org (&optional dir)
  "Write the demo org corpus into DIR (default `org-directory').
Overwrites exactly the files named in `glasspane-demo--org-files' —
other files in the directory are untouched.  Returns DIR."
  (interactive)
  (let ((dir (file-name-as-directory
              (expand-file-name
               (or dir
                   (and (boundp 'org-directory) org-directory)
                   "~/org/"))))
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (dolist (spec glasspane-demo--org-files)
      (write-region (cdr spec) nil (expand-file-name (car spec) dir)
                    nil 'silent))
    ;; Agenda/search memos now describe files that no longer exist.
    (when (fboundp 'glasspane-org-cache-invalidate)
      (glasspane-org-cache-invalidate))
    (when (called-interactively-p 'interactive)
      (message "Demo org corpus written to %s" dir))
    dir))

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

(eabp-defaction "demo.setup-org"
  ;; Same shape as demo.setup: argument-free, fixed file set, fixed target
  ;; (`org-directory').  Overwrites the six corpus files — reset-to-pristine
  ;; is the point — but never touches anything else in the directory.
  (lambda (_ _)
    (let ((dir (glasspane-demo-setup-org)))
      (when (fboundp 'eabp-shell-notify)
        (eabp-shell-notify
         (format "Demo org corpus in %s" (abbreviate-file-name dir)))))
    (when (fboundp 'eabp-shell-push)
      (eabp-shell-push))))

(provide 'glasspane-demo)
;;; glasspane-demo.el ends here
