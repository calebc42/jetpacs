;;; jetpacs-sections.el --- Generic magit-section substrate (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: one renderer for every buffer built on the magit-section
;; library — magit status/log/diff/refs, forge topics, kubernetes.el, and
;; every `taxy-magit-section' consumer (ement's room list, org-ql views).
;; The same bet jetpacs-tablist makes on tabulated-list-mode and
;; jetpacs-hypertext makes on shr: ONE renderer per framework, and every
;; package built on it arrives pre-skinned.
;;
;; Under Tier 0 these buffers already render acceptably (sections fold and
;; tap).  What this substrate adds: the section TREE becomes real
;; `jetpacs-collapsible' cards — folding is instant and client-side, no
;; round-trip — with Emacs's own fold state mirrored at render time, and a
;; long-press on any section header opens a context menu of that section's
;; OWN key bindings (stage this hunk, discard, visit …) served through the
;; bridged `completing-read', so the phone gets magit's per-section verbs
;; without one command name ever crossing the wire (the `keymap.run'
;; contract: the wire carries keys and positions; the buffer's own keymaps
;; decide what they mean).
;;
;; The library is third-party (NonGNU ELPA): nothing here requires it.
;; Reading the tree uses `slot-value' (eieio is built-in) on the buffer's
;; `magit-root-section', and registration waits for the library via
;; `with-eval-after-load'.  Registering `magit-section-mode' covers every
;; derived mode through the dispatch's `derived-mode-p' walk.
;;
;; Body lines ride the Tier 0 line-span builder unchanged (monospace and
;; colors on — diffs keep their +/- shading, taps keep working), so this
;; file knows only the tree shape.  Buffers whose root section is missing
;; fall through to the Tier 0 renderer — the substrate is pure polish,
;; never a prerequisite.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eieio)                ; slot-value on section objects (built-in)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)      ; jetpacs-defaction / jetpacs-action
(require 'jetpacs-buffer)       ; line spans, dispatch registry, refresh seam
(require 'jetpacs-results)      ; the region-view seam + RET resolution

;; The magit-section library, never required from core:
(declare-function magit-section-ident "ext:magit-section" (section))
(defvar magit-root-section)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-sections-max-lines 500
  "Total body-line budget for one rendered section buffer.
A huge magit diff can't produce an unbounded surface: past the budget,
remaining sections still render their headers (the tree stays navigable)
but bodies are elided with a note.  Same spirit as `jetpacs-buffer-max-lines'."
  :type 'integer :group 'jetpacs)

(defconst jetpacs-sections--menu-denylist
  '(self-insert-command digit-argument negative-argument universal-argument
    undefined ignore keyboard-quit keyboard-escape-quit
    mouse-drag-region mouse-set-point mouse-set-region
    magit-mouse-toggle-section)
  "Commands never offered in the section context menu.")

;; ─── Reading the tree ───────────────────────────────────────────────────────

(defun jetpacs-sections--root ()
  "The current buffer's magit-section root, or nil (not a section buffer)."
  (and (featurep 'magit-section)
       (bound-and-true-p magit-root-section)))

(defun jetpacs-sections--pos (sec slot)
  "Marker SLOT of section SEC as a position, or nil."
  (let ((m (slot-value sec slot)))
    (and (markerp m) (marker-position m))))

(defun jetpacs-sections--slot (sec slot)
  "SLOT of section SEC.
The slot name crosses a function boundary deliberately: the magit-section
class is never loaded at compile time, and some slot names (`hidden',
`washer') are declared by no compile-time class — a constant name at the
call site draws an unknown-slot warning."
  (slot-value sec slot))

(defun jetpacs-sections--hidden-p (sec)
  "Whether SEC is folded in Emacs."
  (jetpacs-sections--slot sec 'hidden))

(defun jetpacs-sections--id (sec)
  "A stable collapsible id for SEC: its ident path, hashed.
`magit-section-ident' is the library's own stable identity (it survives a
refresh, which is what keeps client-side fold state attached to the same
section).  Falls back to the start position when the ident isn't
printable (exotic value slots)."
  (or (condition-case nil
          (md5 (format "%S" (magit-section-ident sec)))
        (error nil))
      (format "sec@%s" (jetpacs-sections--pos sec 'start))))

;; ─── Emitting nodes ─────────────────────────────────────────────────────────

(defun jetpacs-sections--strip-taps (spans)
  "Copies of SPANS without their tap actions (for collapsible headers,
where a tap must mean fold/unfold, not the span's own action)."
  (mapcar (lambda (sp) (assq-delete-all 'on_tap (copy-alist sp))) spans))

(defun jetpacs-sections--header-node (sec name)
  "The always-visible header node for SEC: its heading line's own spans
\(faces intact — branch colors, file names), taps stripped."
  (let* ((start (jetpacs-sections--pos sec 'start))
         (spans (save-excursion
                  (goto-char start)
                  (jetpacs-buffer--line-spans start (line-end-position) name))))
    (jetpacs-rich-text (or (jetpacs-sections--strip-taps spans)
                        (list (jetpacs-span " "))))))

(defun jetpacs-sections--retarget-taps (spans)
  "SPANS with their generic tap actions re-pointed at `sections.visit'.
The Tier 0 line-span builder wires taps to `jetpacs.buffer.act', which
runs the RET command in place — in a magit buffer that command visits a
thing by popping a desktop window the phone never sees.  `sections.visit'
runs the same command under the follow shim and shows the destination in
the phone's region view instead.  Fold-affordance taps and spans without
taps pass through untouched."
  (mapcar
   (lambda (sp)
     (let ((tap (alist-get 'on_tap sp)))
       (if (not (equal (alist-get 'action tap) "jetpacs.buffer.act"))
           sp
         (let ((copy (copy-alist sp)))
           (setf (alist-get 'on_tap copy)
                 (jetpacs-action "sections.visit"
                              :args (alist-get 'args tap)))
           copy))))
   spans))

(defun jetpacs-sections--body-lines (beg end name budget)
  "Body lines [BEG, END) as rich_text nodes, consuming BUDGET (a cons cell).
Taps are visit-routed (see `jetpacs-sections--retarget-taps').  Once the
budget is spent, emits one elision note and stops."
  (let (nodes)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((bol (line-beginning-position))
              (eol (min (line-end-position) end)))
          (cond
           ((<= (car budget) 0)
            (push (jetpacs-text
                   (format "… %d more line(s) in Emacs"
                           (count-lines (point) end))
                   'caption)
                  nodes)
            (goto-char end))
           (t
            (when (< bol eol)
              (let ((spans (jetpacs-buffer--line-spans bol eol name)))
                (when spans
                  (push (jetpacs-rich-text
                         (jetpacs-sections--retarget-taps spans))
                        nodes))))
            (cl-decf (car budget))
            (forward-line 1))))))
    (nreverse nodes)))

(defun jetpacs-sections--child-nodes (sec name budget begin)
  "SEC's revealed content from BEGIN to its end: own body lines interleaved
with child sections, in buffer order."
  (let ((end (or (jetpacs-sections--pos sec 'end) begin))
        (pos begin)
        nodes)
    (dolist (child (slot-value sec 'children))
      (let ((cstart (jetpacs-sections--pos child 'start))
            (cend (jetpacs-sections--pos child 'end)))
        (when (and cstart (> cstart pos))
          (setq nodes (nconc nodes (jetpacs-sections--body-lines
                                    pos cstart name budget))))
        (setq nodes (nconc nodes (jetpacs-sections--emit child name budget)))
        (setq pos (or cend pos))))
    (when (< pos end)
      (setq nodes (nconc nodes (jetpacs-sections--body-lines
                                pos end name budget))))
    nodes))

(defun jetpacs-sections--emit (sec name budget)
  "Section SEC as a list of nodes.
A section with a heading and content becomes a collapsible card (fold
state mirroring Emacs's, long-press opening the section menu); a bare
heading becomes its line, taps intact; a heading-less container is
transparent — only its children show."
  (let* ((start (jetpacs-sections--pos sec 'start))
         (content (jetpacs-sections--pos sec 'content))
         (end (jetpacs-sections--pos sec 'end))
         (children (slot-value sec 'children)))
    (cond
     ;; Heading + revealed content → a collapsible card.
     ((and content (< content end))
      (list (jetpacs-collapsible
             (jetpacs-sections--id sec)
             (jetpacs-sections--header-node sec name)
             (jetpacs-sections--child-nodes sec name budget content)
             :collapsed (and (jetpacs-sections--hidden-p sec) t)
             :on-long-tap (jetpacs-action "sections.menu"
                                       :args `((buffer . ,name)
                                               (pos . ,start))))))
     ;; Unwashed lazy section: content == end with a washer pending.  A
     ;; card whose stub child runs the buffer's own fold toggle — showing
     ;; the section washes it in Emacs, and the refresh re-push renders
     ;; the real body.
     ((and content (jetpacs-sections--slot sec 'washer))
      (list (jetpacs-collapsible
             (jetpacs-sections--id sec)
             (jetpacs-sections--header-node sec name)
             (list (jetpacs-rich-text
                    (list (jetpacs-span
                           "Tap to load…"
                           :on-tap (jetpacs-action
                                    "jetpacs.buffer.fold"
                                    :args `((buffer . ,name)
                                            (pos . ,start)))))))
             :collapsed nil
             :on-long-tap (jetpacs-action "sections.menu"
                                       :args `((buffer . ,name)
                                               (pos . ,start))))))
     ;; Empty section (content == end, nothing pending) → its heading
     ;; line, taps intact.
     (content
      (jetpacs-sections--body-lines start end name budget))
     ;; Heading-less container (the root's shape) → children only.
     ((and (null content) children)
      (jetpacs-sections--child-nodes sec name budget start))
     ;; A bare heading (one-line info section) → its line, taps intact.
     (t
      (jetpacs-sections--body-lines start end name budget)))))

(defun jetpacs-sections-render (buf)
  "Tier 0.5 renderer for magit-section buffers: the section tree as
collapsible cards.  Falls through to the Tier 0 renderer when the buffer
has no section root (still populating, or not really a section buffer)."
  (with-current-buffer buf
    (let ((root (jetpacs-sections--root)))
      (if (or (null root) (< (buffer-size) 1))
          (jetpacs-buffer-render buf)
        ;; The scanner must see the whole tree, including bodies Emacs has
        ;; folded away (`hidden' mirrors into :collapsed instead) — an
        ;; invisibility-spec of nil makes `invisible' props inert for the
        ;; duration of the walk without touching buffer state.
        (let ((buffer-invisibility-spec nil)
              (budget (cons jetpacs-sections-max-lines nil)))
          (or (jetpacs-sections--emit root (buffer-name buf) budget)
              (jetpacs-buffer-render buf)))))))

;; ─── Visiting the thing at a row ─────────────────────────────────────────────
;;
;; RET in a section buffer visits the thing at point — a hunk line opens
;; the file at that hunk, a commit opens its revision buffer — by popping
;; a desktop window.  `sections.visit' is the phone's version: the same
;; command under the follow shim, destination shown through the region
;; view (the results substrate's jump primitive, one seam for every
;; producer).  A command that stays in the buffer is an in-place act; the
;; handler falls back to a re-push, so toggles and stages keep working.

(defun jetpacs-sections--visit (buf pos)
  "Follow the thing at POS in section buffer BUF.
Runs the region's own RET command under `jetpacs-buffer-call-shimmed'; a
command that leaves the buffer shows its destination in the region view
and returns non-nil, one that acts in place returns nil."
  (with-current-buffer buf
    (goto-char (min (max (point-min) (truncate pos)) (point-max)))
    (let ((cmd (jetpacs-results--visit-command (point))))
      (when (commandp cmd)
        (let* ((dest (jetpacs-buffer-call-shimmed cmd))
               (dest-buf (car dest)))
          (when (and dest-buf (not (eq dest-buf buf)))
            (pcase-let ((`(,beg ,end ,label ,point)
                         (jetpacs-results--region-around dest-buf (cdr dest))))
              (funcall jetpacs-results-visit-region-function
                       (buffer-name dest-buf) beg end label point))
            t))))))

(jetpacs-defaction "sections.visit"
  ;; BUFFER must be a live magit-section buffer (the results.visit
  ;; contract), POS the tapped row.  Follow if the row's command jumps;
  ;; re-push if it acted in place (stage, toggle) or couldn't follow.
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (pos (alist-get 'pos args))
           (buf (and (stringp name) (get-buffer name))))
      (if (not (and buf (numberp pos)
                    (with-current-buffer buf
                      (and (derived-mode-p 'magit-section-mode)
                           (jetpacs-sections--root)))))
          (message "sections.visit: not a section buffer")
        (unless (ignore-errors (jetpacs-sections--visit buf pos))
          (when (functionp jetpacs-buffer-refresh-function)
            (funcall jetpacs-buffer-refresh-function)))))))

;; ─── The section context menu ───────────────────────────────────────────────
;;
;; Long-press a section header → the section's own key bindings as a
;; bridged picker → the chosen KEY is replayed at the section's position.
;; Exactly the `jetpacs.keymap.run' contract: no command names on the wire.

(defun jetpacs-sections--menu-label (cmd)
  "A human label for command CMD: prefix-stripped, dashes to spaces."
  (let ((s (symbol-name cmd)))
    (dolist (prefix '("magit-section-" "magit-" "forge-" "kubernetes-"))
      (when (string-prefix-p prefix s)
        (setq s (substring s (length prefix)))))
    (capitalize (string-replace "-" " " s))))

(defun jetpacs-sections--menu-candidates (pos)
  "The section menu at POS: an alist of (LABEL . KEY-STRING).
Single keys from the region's own keymap (the section's verbs), plus the
fold toggle.  Key description strings are what get replayed — commands
are resolved by the buffer's own keymaps at dispatch time."
  (let ((km (or (get-char-property pos 'keymap)
                (get-char-property pos 'local-map)))
        cands)
    (when (keymapp km)
      (map-keymap
       (lambda (event binding)
         (when (and (commandp binding)
                    (not (memq binding jetpacs-sections--menu-denylist))
                    (or (and (integerp event) (< 31 event 127))
                        (memq event '(return tab))))
           (let ((key (key-description (vector event))))
             (push (cons (format "%s (%s)"
                                 (jetpacs-sections--menu-label binding) key)
                         key)
                   cands))))
       km))
    (nreverse
     (cons (cons "Toggle fold (TAB)" "TAB")
           cands))))

(jetpacs-defaction "sections.menu"
  ;; BUFFER must be a live magit-section buffer (the results.visit
  ;; contract: a name off the wire only ever drives that buffer's own
  ;; bindings), POS the section to act on.  The picker is the bridged
  ;; `completing-read'; the choice replays its KEY at POS.
  (lambda (args _)
    (let* ((name (alist-get 'buffer args))
           (pos (alist-get 'pos args))
           (buf (and (stringp name) (get-buffer name))))
      (if (not (and buf (numberp pos)
                    (with-current-buffer buf
                      (and (derived-mode-p 'magit-section-mode)
                           (jetpacs-sections--root)))))
          (message "sections.menu: not a section buffer")
        (with-current-buffer buf
          (goto-char (min (max (point-min) (truncate pos)) (point-max)))
          (let* ((cands (jetpacs-sections--menu-candidates (point)))
                 (choice (completing-read "Section action: "
                                          (mapcar #'car cands) nil t))
                 (key (cdr (assoc choice cands))))
            (when key
              (let ((last-input-event nil)
                    (last-nonmenu-event nil))
                (execute-kbd-macro (kbd key)))
              (when (functionp jetpacs-buffer-refresh-function)
                (funcall jetpacs-buffer-refresh-function)))))))))

;; The library is third-party: register only once it exists.  The base mode
;; covers magit, forge, kubernetes.el, taxy-magit-section — everything that
;; derives properly.
(with-eval-after-load 'magit-section
  (jetpacs-render-buffer-register 'magit-section-mode #'jetpacs-sections-render))

(provide 'jetpacs-sections)
;;; jetpacs-sections.el ends here