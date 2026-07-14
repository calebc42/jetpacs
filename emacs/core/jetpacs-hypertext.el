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
(require 'jetpacs-buffer)      ; jetpacs-render-buffer-register / call-shimmed

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

(provide 'jetpacs-hypertext)
;;; jetpacs-hypertext.el ends here
