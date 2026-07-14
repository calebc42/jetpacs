;;; jetpacs-hypertext.el --- Generic hypertext/document substrate (Tier 0.5) -*- lexical-binding: t; -*-

;; Tier 0.5: one document card grammar under every "rendered rich
;; document" buffer — the shr consumers (eww, elfeed-show, nov.el,
;; devdocs), plus help-mode and Info-mode.  The same bet jetpacs-tablist
;; makes on tabulated-list-mode and jetpacs-results makes on the
;; next-error protocol: ONE renderer, thin per-family adapters.
;;
;; Under the Tier 0 generic renderer these buffers already render as
;; styled text, but images fall back to placeholder text, tables to flat
;; monospace, and structure (headings, links) is linearized.  This
;; substrate lifts them to real cards: headings as section navigation,
;; paragraphs as rich_text, links as tappable spans, images as
;; `jetpacs-image', tables as native `jetpacs-table'.
;;
;; The design is two-phase, and that is what keeps the adapters thin:
;;
;;   1. An ADAPTER scans a buffer into a neutral DOCUMENT MODEL — a flat
;;      list of segment plists (heading / para / pre / quote / rule /
;;      image / table).  Each family (shr props, help buttons, Info node
;;      structure) has its own scanner; none of them touches the wire.
;;   2. The EMITTER (`jetpacs-hypertext--emit') maps the model onto the
;;      existing widget vocabulary.  It is the only place that knows the
;;      SDUI nodes, so a new adapter never re-derives them.
;;
;; This file (the substrate core) defines the model and the emitter.
;; The adapters and the mode registrations arrive in later stages; the
;; model shape is final now, so those stages only add scanners.
;;
;; Fidelity floor: an unrecognised segment degrades to a plain paragraph,
;; never dropped — worst case equals Tier 0, never worse.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)     ; jetpacs-defaction
(require 'jetpacs-buffer)      ; jetpacs-render-buffer-register / call-shimmed

;; Forward declarations for the optional document packages this substrate
;; reads at render time.  None is required at load: the core stays app-free
;; (test/core-load-test.el), and each render path checks these at runtime.
(defvar eww-data)
(defvar eww-history)
(defvar eww-history-position)
(defvar help-xref-stack)
(defvar help-xref-forward-stack)
(defvar help-xref-stack-item)
(defvar Info-history)
(defvar Info-history-forward)
(defvar Info-current-node)

;; ─── The document model ───────────────────────────────────────────────────────
;;
;; A model is a list of segment plists.  Every segment carries `:kind';
;; the rest of its keys depend on the kind:
;;
;;   (:kind heading :level N :text STR [:spans SPANS])
;;       A section label.  LEVEL (1-6) is preserved for the Stage-3 table
;;       of contents; inline emission ignores it (the wire section_header
;;       has one style).  TEXT is the plain label; SPANS is a fallback
;;       flattened to text.
;;   (:kind para  :spans SPANS)  | (:kind para  :text STR)
;;       A paragraph.  SPANS is a list of `jetpacs-span'; TEXT is the
;;       plain-text fallback when the adapter has no styled runs.
;;   (:kind pre   :text STR [:syntax SYM])
;;       A preformatted / code block, rendered monospace on a surface.
;;   (:kind quote :spans SPANS) | (:kind quote :text STR)
;;       A blockquote, rendered as a paragraph on a tinted surface.
;;   (:kind rule)
;;       A horizontal rule.
;;   (:kind image :url STR :alt STR :file STR :data STR :content-type STR)
;;       An image.  Stage 1 emits its ALT/URL as a caption placeholder;
;;       Stage 4 resolves FILE/URL/DATA to a real `jetpacs-image'.
;;   (:kind table :rows ROWS)
;;       A table.  ROWS is a list of row plists (:header BOOL :cells
;;       CELLS); each cell is a list of `jetpacs-span'.  Stage 1 emits
;;       monospace rows; Stage 4 emits a native `jetpacs-table'.

(defun jetpacs-hypertext--nonempty (s)
  "Return S when it is a non-empty string, else nil."
  (and (stringp s) (not (string-empty-p s)) s))

(defun jetpacs-hypertext--spans-text (spans)
  "Concatenate the plain text of SPANS (span alists from `jetpacs-span')."
  (mapconcat (lambda (s) (or (alist-get 'text s) "")) spans ""))

(defun jetpacs-hypertext--cell-text (cell)
  "Plain text of a table CELL (a list of spans)."
  (if (stringp cell) cell (jetpacs-hypertext--spans-text cell)))

;; ─── The emitter ──────────────────────────────────────────────────────────────

(defun jetpacs-hypertext--paragraph (seg)
  "A paragraph body node from SEG's :spans (preferred) or :text."
  (let ((spans (plist-get seg :spans))
        (text (plist-get seg :text)))
    (cond
     ((and spans (> (length spans) 0)) (jetpacs-rich-text spans))
     ((jetpacs-hypertext--nonempty text) (jetpacs-text text))
     (t (jetpacs-text "")))))

(defun jetpacs-hypertext--heading (seg)
  "A section_header node from heading SEG (its plain text, level aside)."
  (jetpacs-section-header
   (or (jetpacs-hypertext--nonempty (plist-get seg :text))
       (jetpacs-hypertext--nonempty
        (jetpacs-hypertext--spans-text (plist-get seg :spans)))
       "")))

(defun jetpacs-hypertext--pre (seg)
  "A preformatted/code block node from SEG on a tinted surface."
  (jetpacs-surface
   (list (jetpacs-markup (or (plist-get seg :text) "")
                         :syntax (plist-get seg :syntax)))
   :color "surface_container" :shape "rounded_small" :padding 3))

(defun jetpacs-hypertext--quote (seg)
  "A blockquote node from SEG: its paragraph body on a tinted surface."
  (jetpacs-surface
   (list (jetpacs-hypertext--paragraph seg))
   :color "surface_container" :shape "rounded_small" :padding 3))

(defun jetpacs-hypertext--image (seg)
  "Stage 1 placeholder for image SEG: its alt text (or URL) as a caption.
Stage 4 replaces this with a real `jetpacs-image' resolved from
FILE/URL/DATA."
  (jetpacs-text
   (format "[image: %s]"
           (or (jetpacs-hypertext--nonempty (plist-get seg :alt))
               (jetpacs-hypertext--nonempty (plist-get seg :url))
               "…"))
   'caption))

(defun jetpacs-hypertext--table (seg)
  "Stage 1 placeholder for table SEG: monospace rows on a tinted surface.
Stage 4 replaces this with a native `jetpacs-table'."
  (jetpacs-surface
   (mapcar
    (lambda (row)
      (jetpacs-rich-text
       (list (jetpacs-span
              (mapconcat #'jetpacs-hypertext--cell-text
                         (plist-get row :cells) " | ")
              :mono t
              :bold (and (plist-get row :header) t)))))
    (plist-get seg :rows))
   :color "surface_container" :shape "rounded_small" :padding 3))

(defun jetpacs-hypertext--emit-segment (seg)
  "Map one document SEG (a segment plist) to an SDUI node.
An unrecognised kind degrades to a plain paragraph — never dropped."
  (pcase (plist-get seg :kind)
    ('heading (jetpacs-hypertext--heading seg))
    ('para    (jetpacs-hypertext--paragraph seg))
    ('pre     (jetpacs-hypertext--pre seg))
    ('quote   (jetpacs-hypertext--quote seg))
    ('rule    (jetpacs-divider))
    ('image   (jetpacs-hypertext--image seg))
    ('table   (jetpacs-hypertext--table seg))
    (_        (jetpacs-hypertext--paragraph seg))))

(defun jetpacs-hypertext--emit (model &optional title)
  "Emit document MODEL (a list of segment plists) as a list of SDUI nodes.
TITLE, when a non-empty string, leads with a title text node.  This is
the single place that knows the wire vocabulary; adapters build MODEL and
never touch nodes."
  (append
   (when (jetpacs-hypertext--nonempty title)
     (list (jetpacs-text title 'title)))
   (mapcar #'jetpacs-hypertext--emit-segment model)))

;; ─── shr props contract (the drift firewall) ─────────────────────────────────
;;
;; Everything this file knows about shr's *rendered-buffer* markup lives in
;; this section, so an shr change across Emacs versions is a one-spot edit.
;; Links and inline emphasis are NOT read here — they ride the Tier 0
;; line-span builder (`jetpacs-buffer--line-spans'), which already turns shr's
;; mouse-face/keymap link runs into `jetpacs.buffer.act' taps and maps face
;; emphasis to span styling.  Only block structure is shr-specific.

(defconst jetpacs-hypertext--shr-heading-faces
  '((shr-h1 . 1) (shr-h2 . 2) (shr-h3 . 3)
    (shr-h4 . 4) (shr-h5 . 5) (shr-h6 . 6))
  "shr heading faces mapped to their level (1-6).")

(defun jetpacs-hypertext--face-list (pos)
  "The `face'/`font-lock-face' value at POS as a list of refs (nil-safe)."
  (let ((f (or (get-text-property pos 'face)
               (get-text-property pos 'font-lock-face))))
    (cond ((null f) nil)
          ((and (consp f) (keywordp (car f))) (list f)) ; a single plist
          ((listp f) f)
          (t (list f)))))

(defun jetpacs-hypertext--collapse-ws (s)
  "Collapse whitespace runs in S (a heading rendered across wrapped lines)
to single spaces, and trim — so a filled multi-line heading reads as one
label."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " s)))

(defun jetpacs-hypertext--heading-level-at (pos)
  "Heading level 1-6 if POS is faced as an shr heading, else nil."
  (cl-some (lambda (f)
             (and (symbolp f)
                  (cdr (assq f jetpacs-hypertext--shr-heading-faces))))
           (jetpacs-hypertext--face-list pos)))

;; ─── Adapter: shr-rendered buffers (eww, and every shr consumer) ─────────────
;;
;; shr separates block elements with a blank line, so the model is recovered
;; block by block: a block faced as an shr heading becomes a heading segment;
;; everything else becomes a paragraph whose spans (links + emphasis) come
;; from the Tier 0 line-span builder, reflowed across the block's lines.
;; Images and native tables are resolved in Stage 4; until then an image's
;; alt text and a table's cells degrade into paragraph prose (the fidelity
;; floor — never below Tier 0).

(defun jetpacs-hypertext--block-end (limit)
  "End of the block whose first line starts at point: the last non-blank
line's end before a blank line or LIMIT.  Point is at a non-blank line's
beginning; the buffer is not moved."
  (save-excursion
    (let ((end (min (line-end-position) limit)))
      (while (and (< (line-end-position) limit)
                  (zerop (forward-line 1))
                  (< (point) limit)
                  (not (looking-at-p "[ \t]*$")))
        (setq end (min (line-end-position) limit)))
      end)))

(defun jetpacs-hypertext--block-heading-level (beg end)
  "Heading level if any run in [BEG, END) is faced as an shr heading."
  (let ((pos beg) lvl)
    (while (and (< pos end) (not lvl))
      (setq lvl (jetpacs-hypertext--heading-level-at pos)
            pos (next-single-property-change pos 'face nil end)))
    lvl))

(defun jetpacs-hypertext--block-spans (beg end buffer-name)
  "Spans for paragraph block [BEG, END), reflowed across its lines.
Reuses `jetpacs-buffer--line-spans' with monospace and color emission off
\(eww prose is proportional and themed by the device), so shr links become
`jetpacs.buffer.act' taps and face emphasis maps to span styling for free;
non-empty lines are joined by a space so the paragraph reflows."
  (let ((jetpacs-buffer-monospace nil)
        (jetpacs-buffer-emit-colors nil)
        chunks)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((line (jetpacs-buffer--line-spans
                     (line-beginning-position)
                     (min (line-end-position) end)
                     buffer-name)))
          (when line (push line chunks)))
        (forward-line 1)))
    (setq chunks (nreverse chunks))
    (apply #'append
           (cl-loop for chunk in chunks
                    for i from 0
                    collect (if (zerop i) chunk
                              (cons (jetpacs-span " ") chunk))))))

(defun jetpacs-hypertext--scan-shr (buf)
  "Scan shr-rendered BUF into a document model (heading + paragraph segments)."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let ((name (buffer-name buf)) (limit (point-max)) segments)
        (while (< (point) limit)
          (skip-chars-forward " \t\n" limit)
          (when (< (point) limit)
            (let* ((beg (line-beginning-position))
                   (end (jetpacs-hypertext--block-end limit))
                   (level (jetpacs-hypertext--block-heading-level beg end)))
              (if level
                  (push (list :kind 'heading :level level
                              :text (jetpacs-hypertext--collapse-ws
                                     (buffer-substring-no-properties beg end)))
                        segments)
                (let ((spans (jetpacs-hypertext--block-spans beg end name)))
                  (when spans
                    (push (list :kind 'para :spans spans) segments))))
              (goto-char end))))
        (nreverse segments)))))

(defun jetpacs-hypertext--eww-title (buf)
  "The document title for BUF from `eww-data', or nil."
  (with-current-buffer buf
    (and (boundp 'eww-data) eww-data
         (jetpacs-hypertext--nonempty (plist-get eww-data :title)))))

(defun jetpacs-hypertext-render (buf)
  "Tier 0.5 renderer for shr-rendered document buffers (registered for eww).
Falls back to the Tier 0 generic renderer for an empty or still-loading
buffer, or one shr left no recoverable structure in — the results-substrate
precedent."
  (with-current-buffer buf
    (if (< (buffer-size) 1)
        (jetpacs-buffer-render buf)
      (let ((model (jetpacs-hypertext--scan-shr buf)))
        (if model
            (jetpacs-hypertext--render-document
             buf model (jetpacs-hypertext--eww-title buf))
          (jetpacs-buffer-render buf))))))

;; ─── Document navigation (the nav toolbar + hypertext.nav action) ────────────
;;
;; A rendered document navigates by running the mode's OWN commands (eww/help
;; history, Info node motion) — never a command named on the wire.  The wire
;; carries only an op symbol; the op->command allowlist and the mode gate live
;; here, exactly like `results.visit'.

(defconst jetpacs-hypertext--nav-ops
  '((eww-mode  (back . eww-back-url) (forward . eww-forward-url)
               (reload . eww-reload))
    (help-mode (back . help-go-back) (forward . help-go-forward))
    (Info-mode (prev . Info-prev) (next . Info-next) (up . Info-up)
               (toc . Info-toc)
               (back . Info-history-back) (forward . Info-history-forward)))
  "Per-mode document-nav op -> the mode's own command.
The op symbol is all the wire carries; the command is resolved here, so no
command name ever travels over the wire.")

(defconst jetpacs-hypertext--nav-icons
  '((back    . ("arrow_back"    . "Back"))
    (forward . ("arrow_forward" . "Forward"))
    (reload  . ("refresh"       . "Reload"))
    (prev    . ("chevron_left"  . "Previous"))
    (next    . ("chevron_right" . "Next"))
    (up      . ("arrow_upward"  . "Up"))
    (toc     . ("toc"           . "Contents")))
  "Nav op -> (ICON . LABEL) for the toolbar.")

(defun jetpacs-hypertext--nav-mode (&optional buffer)
  "The `jetpacs-hypertext--nav-ops' mode key BUFFER derives from, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (cl-some (lambda (cell) (and (derived-mode-p (car cell)) (car cell)))
             jetpacs-hypertext--nav-ops)))

(defun jetpacs-hypertext--nav-command (mode op)
  "The command for nav OP (a symbol) in MODE, or nil if not allowlisted."
  (cdr (assq op (cdr (assq mode jetpacs-hypertext--nav-ops)))))

(defun jetpacs-hypertext--nav-live-ops (mode)
  "The live nav ops for MODE in the current buffer, in display order.
Liveness is exact where cheap (the history stacks); Info node motion
\(prev/next/up/toc) is always offered — the command self-messages at a node
boundary and the shim swallows it."
  (pcase mode
    ('eww-mode
     (append
      (and (bound-and-true-p eww-history)
           (< eww-history-position (length eww-history)) '(back))
      (and (boundp 'eww-history-position)
           (> eww-history-position 1) '(forward))
      '(reload)))
    ('help-mode
     (append (and (bound-and-true-p help-xref-stack) '(back))
             (and (bound-and-true-p help-xref-forward-stack) '(forward))))
    ('Info-mode
     (append '(prev next up toc)
             (and (bound-and-true-p Info-history) '(back))
             (and (bound-and-true-p Info-history-forward) '(forward))))
    (_ nil)))

(defun jetpacs-hypertext--nav-toolbar (buffer-name mode)
  "An icon-button row of the live nav ops for MODE in the current buffer,
or nil when there are none."
  (let ((ops (jetpacs-hypertext--nav-live-ops mode)))
    (when ops
      (apply #'jetpacs-row
             (append
              (mapcar
               (lambda (op)
                 (let ((ico (cdr (assq op jetpacs-hypertext--nav-icons))))
                   (jetpacs-icon-button
                    (car ico)
                    (jetpacs-action "hypertext.nav"
                                 :args `((buffer . ,buffer-name)
                                         (op . ,(symbol-name op))))
                    :content-description (cdr ico))))
               ops)
              (list :spacing 4))))))

(jetpacs-defaction "hypertext.nav"
  ;; Navigate a rendered document buffer by running its mode's OWN command.
  ;; BUFFER must derive from a registered document mode and OP must be in
  ;; that mode's allowlist, so a name off the wire can only ever drive a
  ;; real document buffer's own navigation (the `results.visit' contract).
  (lambda (args _)
    (let* ((buffer (alist-get 'buffer args))
           (op (alist-get 'op args))
           (buf (and (stringp buffer) (get-buffer buffer))))
      (when (and buf (stringp op))
        (with-current-buffer buf
          (let* ((mode (jetpacs-hypertext--nav-mode buf))
                 (cmd (and mode (jetpacs-hypertext--nav-command
                                 mode (intern-soft op)))))
            (if (commandp cmd)
                (jetpacs-buffer-call-shimmed cmd)
              (message "hypertext.nav: %s not available here" op))))
        (when (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function))))))

(defun jetpacs-hypertext--render-document (buf segments title)
  "Assemble a rendered document for BUF: the nav toolbar (if any) atop the
emitted SEGMENTS, led by TITLE.  Runs in BUF for buffer-local nav state."
  (with-current-buffer buf
    (let* ((mode (jetpacs-hypertext--nav-mode buf))
           (toolbar (and mode (jetpacs-hypertext--nav-toolbar
                               (buffer-name buf) mode))))
      (append (and toolbar (list toolbar))
              (jetpacs-hypertext--emit segments title)))))

;; ─── Generic line scanner (for the non-shr text families) ────────────────────
;;
;; help and Info are not shr buffers; their structure is line-oriented and
;; alignment-bearing (argument lists, menus), so — unlike the shr adapter's
;; block reflow — each non-blank line becomes its own paragraph, preserving
;; layout.  Links and buttons (help xrefs, Info menu entries and *note refs)
;; ride the Tier 0 line-span builder into `jetpacs.buffer.act' taps for free.

(defun jetpacs-hypertext--scan-lines (buf &optional classify)
  "Scan BUF into a model, one segment per non-blank line (layout preserved).
CLASSIFY, if non-nil, is called with (BEG END) at each non-blank line and
returns a heading level (integer) to make that line a heading, the symbol
`skip' to drop it (e.g. an Info underline rule), or nil for a paragraph."
  (with-current-buffer buf
    (let ((jetpacs-buffer-emit-colors nil)   ; document text is theme-coloured
          (name (buffer-name buf))
          segments)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((bol (line-beginning-position))
                (eol (line-end-position)))
            (unless (>= bol eol)              ; blank line
              (let ((class (and classify (funcall classify bol eol))))
                (cond
                 ((eq class 'skip))
                 ((integerp class)
                  (push (list :kind 'heading :level class
                              :text (jetpacs-hypertext--collapse-ws
                                     (buffer-substring-no-properties bol eol)))
                        segments))
                 (t
                  (let ((spans (jetpacs-buffer--line-spans bol eol name)))
                    (when spans
                      (push (list :kind 'para :spans spans) segments))))))))
          (forward-line 1)))
      (nreverse segments))))

;; ─── Adapter: help-mode ──────────────────────────────────────────────────────

(defun jetpacs-hypertext--help-title (buf)
  "A title for help BUF from `help-xref-stack-item' (the current subject)."
  (with-current-buffer buf
    (and (boundp 'help-xref-stack-item)
         (consp help-xref-stack-item)
         (jetpacs-hypertext--nonempty
          (format "%s" (cadr help-xref-stack-item))))))

(defun jetpacs-hypertext-render-help (buf)
  "Tier 0.5 renderer for help-mode: a nav toolbar and the help subject over
the help text, whose xref buttons are tappable through the Tier 0 line-span
builder."
  (with-current-buffer buf
    (if (< (buffer-size) 1)
        (jetpacs-buffer-render buf)
      (jetpacs-hypertext--render-document
       buf (jetpacs-hypertext--scan-lines buf)
       (jetpacs-hypertext--help-title buf)))))

;; ─── Adapter: Info-mode ──────────────────────────────────────────────────────

(defun jetpacs-hypertext--info-underlined-level (eol)
  "Heading level if the line ending at EOL is underlined by a rule line just
below it (Info section headings): * chapter = 1, = section = 2, - sub = 3."
  (save-excursion
    (goto-char eol)
    (when (zerop (forward-line 1))
      (let ((u (string-trim (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position)))))
        (cond ((string-match-p "\\`\\*\\{2,\\}\\'" u) 1)
              ((string-match-p "\\`=\\{2,\\}\\'" u) 2)
              ((string-match-p "\\`-\\{2,\\}\\'" u) 3))))))

(defun jetpacs-hypertext--info-line-class (beg end)
  "Classify an Info line [BEG, END): a heading level, `skip', or nil."
  (let ((text (string-trim (buffer-substring-no-properties beg end))))
    (if (string-match-p "\\`\\(=\\{2,\\}\\|-\\{2,\\}\\|\\*\\{2,\\}\\)\\'" text)
        'skip                               ; a bare underline rule — drop it
      (jetpacs-hypertext--info-underlined-level end))))

(defun jetpacs-hypertext--info-title (buf)
  "A title for Info BUF: its current node name (breadcrumb)."
  (with-current-buffer buf
    (and (boundp 'Info-current-node)
         (jetpacs-hypertext--nonempty (format "%s" Info-current-node)))))

(defun jetpacs-hypertext-render-info (buf)
  "Tier 0.5 renderer for Info-mode: a nav toolbar and the node name over the
node body, with menu entries and cross-references tappable via the Tier 0
line-span builder and === / --- underlined headings lifted to sections."
  (with-current-buffer buf
    (if (< (buffer-size) 1)
        (jetpacs-buffer-render buf)
      (jetpacs-hypertext--render-document
       buf (jetpacs-hypertext--scan-lines
            buf #'jetpacs-hypertext--info-line-class)
       (jetpacs-hypertext--info-title buf)))))

;; eww, help, and Info are built-ins this foundation may name directly;
;; third-party shr consumers (elfeed-show, nov, devdocs) register softly in a
;; later stage.
(jetpacs-render-buffer-register 'eww-mode #'jetpacs-hypertext-render)
(jetpacs-render-buffer-register 'help-mode #'jetpacs-hypertext-render-help)
(jetpacs-render-buffer-register 'Info-mode #'jetpacs-hypertext-render-info)

(provide 'jetpacs-hypertext)
;;; jetpacs-hypertext.el ends here
