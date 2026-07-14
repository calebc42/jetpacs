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
(require 'dom)                 ; DOM walking for the eww table pass
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)     ; jetpacs-defaction
(require 'jetpacs-config)       ; jetpacs-root (the image cache lives under it)
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
;;   (:kind image :url STR :alt STR :file STR :data STR :content-type SYM)
;;       An image, emitted as a real `jetpacs-image': a readable FILE as
;;       file://, an http(s) URL untouched (the device fetches), DATA (or a
;;       base64 data: URL) through the write-once content cache.  When none
;;       resolves, the ALT/URL degrades to a caption.
;;   (:kind table [:rows ROWS] [:table-id N] [:text STR])
;;       A table.  ROWS — row plists (:header BOOL :cells CELLS), each cell
;;       a string or a list of `jetpacs-span' — emits a native
;;       `jetpacs-table'.  Without rows, TEXT (the rendered region,
;;       verbatim) emits as a monospace block; TABLE-ID is the shr render
;;       counter the eww DOM pass uses to recover ROWS.

(defun jetpacs-hypertext--nonempty (s)
  "Return S when it is a non-empty string, else nil."
  (and (stringp s) (not (string-empty-p s)) s))

(defun jetpacs-hypertext--spans-text (spans)
  "Concatenate the plain text of SPANS (span alists from `jetpacs-span')."
  (mapconcat (lambda (s) (or (alist-get 'text s) "")) spans ""))

(defun jetpacs-hypertext--cell-text (cell)
  "Plain text of a table CELL (a list of spans)."
  (if (stringp cell) cell (jetpacs-hypertext--spans-text cell)))

;; ─── The image cache ─────────────────────────────────────────────────────────
;;
;; Images whose bytes exist only inside Emacs (an shr `display' descriptor's
;; :data, a data: URI) can't ride the wire — `jetpacs-image' carries a URL or a
;; readable file:// path.  They are written once into a content-addressed
;; cache under `jetpacs-root' (disposable by definition; a sync pass may drop
;; it) and emitted as file:// paths.  http(s) images are NEVER cached: the
;; device fetches them itself, which is the battery-cheapest path and always
;; current.

(defcustom jetpacs-hypertext-image-cache-max (* 20 1024 1024)
  "Byte cap for the hypertext image cache.
When a write pushes the cache past this, oldest files (by mtime) are
deleted until it fits.  The cache is content-addressed (sha1), so a
re-render re-writes at most what it still shows."
  :type 'integer :group 'jetpacs)

(defun jetpacs-hypertext--image-cache-dir ()
  "The image cache directory (not created until first write)."
  (expand-file-name "cache/hypertext-images/" jetpacs-root))

(defconst jetpacs-hypertext--image-extensions
  '((png . "png") (jpeg . "jpg") (gif . "gif") (webp . "webp")
    (svg . "svg") (bmp . "bmp") (tiff . "tiff") (xpm . "xpm"))
  "Image type symbol -> cache file extension.")

(defun jetpacs-hypertext--image-cache-sweep (dir)
  "Delete oldest-mtime files in DIR until it fits the cache cap."
  (let* ((files (directory-files dir t "\\`[^.]" t))
         (total (apply #'+ (mapcar (lambda (f)
                                     (or (file-attribute-size
                                          (file-attributes f))
                                         0))
                                   files))))
    (when (> total jetpacs-hypertext-image-cache-max)
      (dolist (f (sort files
                       (lambda (a b)
                         (time-less-p (file-attribute-modification-time
                                       (file-attributes a))
                                      (file-attribute-modification-time
                                       (file-attributes b))))))
        (when (> total jetpacs-hypertext-image-cache-max)
          (let ((size (or (file-attribute-size (file-attributes f)) 0)))
            (ignore-errors (delete-file f))
            (setq total (- total size))))))))

(defun jetpacs-hypertext--image-cache-put (data type)
  "Write image DATA (a unibyte string) into the cache; return its file path.
Content-addressed and write-once: the name is DATA's sha1 plus TYPE's
extension, and an existing file is returned untouched.  Returns nil when
the write fails (unwritable root) — the caller degrades to a placeholder."
  (condition-case nil
      (let* ((dir (jetpacs-hypertext--image-cache-dir))
             (ext (or (cdr (assq type jetpacs-hypertext--image-extensions))
                      "img"))
             (path (expand-file-name (concat (sha1 data) "." ext) dir)))
        (unless (file-exists-p path)
          (make-directory dir t)
          (let ((coding-system-for-write 'binary))
            (write-region data nil path nil 'silent))
          (jetpacs-hypertext--image-cache-sweep dir))
        path)
    (error nil)))

(defun jetpacs-hypertext-image-cache-clear ()
  "Delete every file in the hypertext image cache."
  (interactive)
  (let ((dir (jetpacs-hypertext--image-cache-dir)))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\`[^.]" t))
        (ignore-errors (delete-file f)))
      (message "Hypertext image cache cleared"))))

(defconst jetpacs-hypertext--data-uri-types
  '(("image/png" . png) ("image/jpeg" . jpeg) ("image/gif" . gif)
    ("image/webp" . webp) ("image/svg+xml" . svg) ("image/bmp" . bmp))
  "data: URI MIME type -> image type symbol.")

(defun jetpacs-hypertext--decode-data-uri (url)
  "Decode a base64 data: image URL into (DATA . TYPE), or nil."
  (when (and (stringp url)
             (string-match "\\`data:\\([^;,]+\\);base64,\\(.*\\)\\'" url))
    (let ((type (cdr (assoc (downcase (match-string 1 url))
                            jetpacs-hypertext--data-uri-types)))
          (data (ignore-errors (base64-decode-string (match-string 2 url)))))
      (and data type (cons data type)))))

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
  "A real `jetpacs-image' node from image SEG, resolved in battery order:
a readable :file passes through as file:// (nov.el extracts EPUB resources
to disk); an http(s) :url passes through untouched (the DEVICE fetches —
no Emacs I/O, always current); bytes that exist only inside Emacs (:data,
or a base64 data: URI in :url) go through the write-once content cache.
Unresolvable images degrade to an alt-text caption — never dropped."
  (let* ((alt (jetpacs-hypertext--nonempty (plist-get seg :alt)))
         (url (plist-get seg :url))
         (file (plist-get seg :file))
         (data (plist-get seg :data))
         (resolved
          (cond
           ((and file (file-readable-p file))
            (concat "file://" file))
           ((and url (string-match-p "\\`https?://" url))
            url)
           (data
            (let ((path (jetpacs-hypertext--image-cache-put
                         data (plist-get seg :content-type))))
              (and path (concat "file://" path))))
           ((jetpacs-hypertext--decode-data-uri url)
            (let* ((decoded (jetpacs-hypertext--decode-data-uri url))
                   (path (jetpacs-hypertext--image-cache-put
                          (car decoded) (cdr decoded))))
              (and path (concat "file://" path)))))))
    (if resolved
        (jetpacs-image resolved :content-description alt)
      (jetpacs-text (format "[image: %s]" (or alt url "…")) 'caption))))

(defun jetpacs-hypertext--table (seg)
  "A table node from SEG: native `jetpacs-table' when :rows were recovered
\(the eww DOM pass), else its rendered :text verbatim as a monospace block —
shr's own alignment, exactly what Tier 0 shows, never a reflow."
  (let ((rows (plist-get seg :rows)))
    (cond
     (rows
      (jetpacs-table
       (mapcar
        (lambda (row)
          (jetpacs-table-row
           (mapcar (lambda (cell)
                     (jetpacs-table-cell
                      (if (stringp cell) (list (jetpacs-span cell)) cell)))
                   (plist-get row :cells))
           :header (and (plist-get row :header) t)))
        rows)))
     ((jetpacs-hypertext--nonempty (plist-get seg :text))
      (jetpacs-hypertext--pre (list :text (plist-get seg :text))))
     (t (jetpacs-text "")))))

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

(defun jetpacs-hypertext--shr-placeholder-image-p (type data)
  "Non-nil when TYPE/DATA is shr's not-yet-fetched placeholder rectangle.
In batch or before a fetch completes, `shr-put-image' displays a generated
gray-gradient SVG; caching that would show gray boxes instead of images, so
the resolver treats it as no data at all."
  (and (eq type 'svg)
       (stringp data)
       (string-match-p "url(#background)" data)))

(defun jetpacs-hypertext--shr-image-at (pos)
  "An image segment plist for the shr image run at POS, or nil.
Reads shr's rendered-buffer markup: the `image-url' property (the real
source URL), `shr-alt' (the alt text), and the `display' image descriptor's
:file / :data / :type — with the placeholder rectangle discarded."
  (let* ((url (get-text-property pos 'image-url))
         (alt (get-text-property pos 'shr-alt))
         (disp (get-text-property pos 'display))
         (desc (and (eq (car-safe disp) 'image) (cdr disp)))
         (type (plist-get desc :type))
         (file (plist-get desc :file))
         (data (plist-get desc :data)))
    (when (jetpacs-hypertext--shr-placeholder-image-p type data)
      (setq data nil type nil))
    (when (or url alt desc)
      (list :kind 'image
            :url (jetpacs-hypertext--nonempty url)
            :alt (jetpacs-hypertext--nonempty alt)
            :file (jetpacs-hypertext--nonempty file)
            :data (and (stringp data) (not (string-empty-p data)) data)
            :content-type type))))

(defun jetpacs-hypertext--image-run-p (pos)
  "Non-nil when POS is inside an shr image run."
  (or (get-text-property pos 'image-url)
      (get-text-property pos 'shr-alt)
      (eq (car-safe (get-text-property pos 'display)) 'image)))

(defun jetpacs-hypertext--block-table-id (beg end)
  "The `shr-table-id' of the rendered table block [BEG, END), or nil.
shr stamps the table's start with `shr-table-id' (a per-render counter), the
key the eww DOM pass uses to pair a rendered region with its <table>."
  (let ((pos beg) id)
    (while (and (< pos end) (not id))
      (setq id (get-text-property pos 'shr-table-id)
            pos (or (next-single-property-change pos 'shr-table-id nil end)
                    end)))
    id))

(defun jetpacs-hypertext--table-block-p (beg end)
  "Non-nil when the block [BEG, END) is an shr-rendered table region."
  (or (jetpacs-hypertext--block-table-id beg end)
      (let ((pos beg) found)
        (while (and (< pos end) (not found))
          (setq found (get-text-property pos 'shr-table-indent)
                pos (or (next-single-property-change
                         pos 'shr-table-indent nil end)
                        end)))
        found)))

(defun jetpacs-hypertext--block-images (beg end)
  "Image segments when block [BEG, END) is image-only, else nil.
Walks the block's property runs collecting shr image runs; any non-image,
non-whitespace text makes this nil — a mixed block stays a paragraph whose
inline images degrade to their alt text (the fidelity floor)."
  (let ((pos beg) images stray)
    (while (and (< pos end) (not stray))
      (let ((next (or (next-property-change pos nil end) end)))
        (if (jetpacs-hypertext--image-run-p pos)
            (let ((seg (jetpacs-hypertext--shr-image-at pos)))
              ;; One image's alt text may split into several property runs
              ;; (help-echo boundaries, fill) — collapse consecutive equals.
              (when (and seg (not (equal seg (car images))))
                (push seg images)))
          (unless (string-blank-p (buffer-substring-no-properties pos next))
            (setq stray t)))
        (setq pos next)))
    (and (not stray) (nreverse images))))

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

(defun jetpacs-hypertext--skip-inter-block (limit)
  "Advance point over inter-block blank space up to LIMIT, stopping at an
shr image run.  On an Emacs built without SVG support, `shr-tag-img'
renders an image as a lone space rather than a placeholder glyph carrying
its alt text; that space is meaningful markup, not inter-block whitespace,
so the block scan must not skip it — otherwise the image is dropped below
the Tier-0 fidelity floor instead of degrading to its URL/alt caption."
  (while (and (< (point) limit)
              (memq (char-after) '(?\s ?\t ?\n))
              (not (jetpacs-hypertext--image-run-p (point))))
    (forward-char 1)))

(defun jetpacs-hypertext--scan-shr (buf)
  "Scan shr-rendered BUF into a document model (heading + paragraph segments)."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let ((name (buffer-name buf)) (limit (point-max)) segments)
        (while (< (point) limit)
          (jetpacs-hypertext--skip-inter-block limit)
          (when (< (point) limit)
            (let* ((beg (line-beginning-position))
                   (end (jetpacs-hypertext--block-end limit))
                   (level nil) (images nil))
              (cond
               ;; A rendered table region: keep its lines verbatim as the
               ;; monospace fallback; the eww DOM pass may upgrade it to
               ;; native rows via its shr-table-id.  A table block with no id
               ;; of its own continues the previous table (shr stamps the id
               ;; once, at the table's start; a blank row splits the region).
               ((jetpacs-hypertext--table-block-p beg end)
                (let ((id (jetpacs-hypertext--block-table-id beg end))
                      (text (buffer-substring-no-properties beg end))
                      (prev (car segments)))
                  (if (and (null id) prev
                           (eq (plist-get prev :kind) 'table))
                      (setcar segments
                              (plist-put (copy-sequence prev) :text
                                         (concat (plist-get prev :text)
                                                 "\n" text)))
                    (push (list :kind 'table :table-id id :text text)
                          segments))))
               ;; An image-only block: one segment per image.
               ((setq images (jetpacs-hypertext--block-images beg end))
                (dolist (img images) (push img segments)))
               ((setq level (jetpacs-hypertext--block-heading-level beg end))
                (push (list :kind 'heading :level level
                            :text (jetpacs-hypertext--collapse-ws
                                   (buffer-substring-no-properties beg end)))
                      segments))
               (t
                (let ((spans (jetpacs-hypertext--block-spans beg end name)))
                  (when spans
                    (push (list :kind 'para :spans spans) segments)))))
              (goto-char end))))
        (nreverse segments)))))

(defun jetpacs-hypertext--eww-title (buf)
  "The document title for BUF from `eww-data', or nil."
  (with-current-buffer buf
    (and (boundp 'eww-data) eww-data
         (jetpacs-hypertext--nonempty (plist-get eww-data :title)))))

;; ─── The eww DOM table pass ──────────────────────────────────────────────────
;;
;; shr renders a <table> as aligned monospace text; the real structure is
;; only in the HTML.  eww keeps that HTML (`eww-data' :source), so table
;; segments are upgraded to native rows by re-parsing it and pairing each
;; rendered region's `shr-table-id' with the document-order <table> list.
;; Anything ambiguous — nested tables (render order diverges from document
;; order), ragged rows (colspans), oversize — stays the monospace fallback:
;; exactly what Tier 0 shows today, never a wrong table.

(defcustom jetpacs-hypertext-table-max-rows 100
  "Row cap for native table recovery.
A <table> with more rows than this keeps its monospace rendering (a phone
table this size wants a purpose-built view, not a widget)."
  :type 'integer :group 'jetpacs)

(defun jetpacs-hypertext--dom-table-rows (table)
  "Row plists from DOM TABLE node, or nil when irregular.
Rows are the <tr>s in document order; a row's cells are its <th>/<td>
children flattened to text; a row containing a <th> is a header row.
Ragged tables (colspan/rowspan artifacts) and oversize tables return nil —
the caller keeps the monospace fallback."
  (let* ((trs (dom-by-tag table 'tr))
         (rows
          (mapcar
           (lambda (tr)
             (let ((cells (seq-filter
                           (lambda (c) (memq (dom-tag c) '(th td)))
                           (dom-non-text-children tr))))
               (list :header (and (seq-find (lambda (c) (eq (dom-tag c) 'th))
                                            cells)
                                  t)
                     :cells (mapcar
                             (lambda (c)
                               (jetpacs-hypertext--collapse-ws (dom-texts c "")))
                             cells))))
           trs))
         (widths (delete-dups (mapcar (lambda (r) (length (plist-get r :cells)))
                                      rows))))
    (and rows
         (<= (length rows) jetpacs-hypertext-table-max-rows)
         (= (length widths) 1)              ; every row the same cell count
         (> (car widths) 0)
         rows)))

(defun jetpacs-hypertext--eww-resolve-tables (model buf)
  "Upgrade MODEL's table segments with native rows from BUF's eww source.
Returns MODEL (segments upgraded where recovery is unambiguous).  Requires
libxml (positive knowledge — the probe, not the version) and the page
source in `eww-data'; a document containing nested tables is left entirely
alone, since shr's table-id render order diverges from document order there."
  (let ((source (with-current-buffer buf
                  (and (boundp 'eww-data) eww-data
                       (plist-get eww-data :source)))))
    (if (not (and (cl-some (lambda (s) (and (eq (plist-get s :kind) 'table)
                                            (plist-get s :table-id)))
                           model)
                  (jetpacs-feature-p 'libxml)
                  (stringp source)))
        model
      (let* ((dom (with-temp-buffer
                    (insert source)
                    (libxml-parse-html-region (point-min) (point-max))))
             (tables (and dom (dom-by-tag dom 'table))))
        (if (or (null tables)
                (cl-some (lambda (tbl) (> (length (dom-by-tag tbl 'table)) 1))
                         tables))
            model
          (mapcar
           (lambda (seg)
             (let* ((id (and (eq (plist-get seg :kind) 'table)
                             (plist-get seg :table-id)))
                    (table (and (integerp id) (> id 0) (nth (1- id) tables)))
                    (rows (and table (jetpacs-hypertext--dom-table-rows table))))
               (if rows
                   (plist-put (copy-sequence seg) :rows rows)
                 seg)))
           model))))))

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
             buf (jetpacs-hypertext--eww-resolve-tables model buf)
             (jetpacs-hypertext--eww-title buf))
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

;; ─── Registrations & third-party riders ─────────────────────────────────────

(defun jetpacs-hypertext-register-shr-mode (mode)
  "Register MODE (a major-mode symbol) to render as a hypertext document.
The one-line rider seam for any package whose buffers are shr-rendered
HTML — feed readers, EPUB readers, doc browsers:

  (with-eval-after-load \\='elfeed-show
    (jetpacs-hypertext-register-shr-mode \\='elfeed-show-mode))

Register each concrete mode, never `special-mode' itself: dispatch is by
`derived-mode-p', and half of Emacs derives from special-mode."
  (when (memq mode '(special-mode fundamental-mode text-mode))
    (error "Register the package's own mode, not %s (dispatch is derived-mode-p)"
           mode))
  (jetpacs-render-buffer-register mode #'jetpacs-hypertext-render))

;; eww, help, and Info are built-ins this foundation may name directly.
(jetpacs-render-buffer-register 'eww-mode #'jetpacs-hypertext-render)
(jetpacs-render-buffer-register 'help-mode #'jetpacs-hypertext-render-help)
(jetpacs-render-buffer-register 'Info-mode #'jetpacs-hypertext-render-info)

;; The known third-party shr consumers ride as soon as they load; none is
;; ever required from here (the core stays app-free — test/core-load-test.el
;; proves it).
(with-eval-after-load 'elfeed-show
  (jetpacs-hypertext-register-shr-mode 'elfeed-show-mode))
(with-eval-after-load 'nov
  (jetpacs-hypertext-register-shr-mode 'nov-mode))
(with-eval-after-load 'devdocs
  (jetpacs-hypertext-register-shr-mode 'devdocs-mode))

(provide 'jetpacs-hypertext)
;;; jetpacs-hypertext.el ends here
