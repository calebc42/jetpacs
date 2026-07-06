;;; glasspane-notes.el --- Vulpea bridge: wikilink completion + backlinks -*- lexical-binding: t; -*-

;; The linking loop over vulpea's note database (the PKM engine
;; decision — vulpea v2, org-roam as fallback never materialized):
;;
;;   PKM 3 — typing "[[" in the phone editor offers note titles from
;;   the vulpea index through the existing capf bridge; accepting one
;;   inserts a full "[[id:…][Title]]" link (the candidate `insert'
;;   attr, SPEC §8).
;;
;;   PKM 4 — the heading detail view grows "Linked references" (notes
;;   linking here, from the db) and on-demand "Unlinked mentions"
;;   (vulpea's async ripgrep pass) with a one-tap link.materialize.
;;
;; Everything degrades to absent when vulpea isn't installed or has no
;; database yet — no errors, no empty chrome.  The starter init
;; installs vulpea and enables `vulpea-db-autosync-mode'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-shell)
(require 'eabp-sync)
(require 'glasspane-org)

(declare-function vulpea-db-search-by-title "vulpea-db-query")
(declare-function vulpea-db-query-by-links-some "vulpea-db-query")
(declare-function vulpea-db-get-by-id "vulpea-db-query")
(declare-function vulpea-note-unlinked-mentions-async "vulpea-mentions")
(declare-function vulpea-note-id "vulpea-note")
(declare-function vulpea-note-title "vulpea-note")
(declare-function vulpea-note-path "vulpea-note")

(defun glasspane-notes-available-p ()
  "Non-nil when the vulpea note database is usable."
  (and (featurep 'vulpea)
       (fboundp 'vulpea-db-search-by-title)))

;; ─── PKM 3: wikilink completion ──────────────────────────────────────────────

(defcustom glasspane-notes-completion-limit 20
  "Notes offered per wikilink completion request."
  :type 'integer :group 'eabp)

(defun glasspane-notes--matches (partial)
  "Vulpea notes whose title (or alias) matches PARTIAL, capped."
  (condition-case nil
      (seq-take (vulpea-db-search-by-title partial)
                glasspane-notes-completion-limit)
    (error nil)))

(defun glasspane-notes--wikilink-capf ()
  "Complete \"[[partial\" with note titles; insert full id links.
Candidates keep the \"[[\" so the phone replaces the whole open
bracket with the link (the strip validates the prefix by position,
so the brackets must be part of it)."
  (when (and (derived-mode-p 'org-mode)
             (glasspane-notes-available-p))
    (save-excursion
      (when (looking-back "\\[\\[\\([^][\n]*\\)"
                          (max (point-min) (- (point) 120)))
        (let* ((beg (match-beginning 0))
               (partial (match-string 1))
               (notes (glasspane-notes--matches partial))
               (table (mapcar (lambda (n)
                                (cons (concat "[[" (vulpea-note-title n)) n))
                              notes)))
          (when table
            (list beg (point)
                  ;; A function table owns its own matching: vulpea
                  ;; already filtered by PARTIAL case-insensitively, so
                  ;; every candidate passes.  try-completion (the
                  ;; :exclusive-no validation probe) must also succeed,
                  ;; or the capf wrapper discards this capf entirely.
                  (lambda (string _pred action)
                    (cond
                     ((eq action t) (mapcar #'car table))
                     ((null action) (and table string))
                     ((eq action 'lambda) (and (assoc string table) t))
                     ((eq action 'metadata)
                      '(metadata (category . glasspane-wikilink)))))
                  :annotation-function
                  (lambda (c)
                    (when-let ((n (cdr (assoc c table))))
                      (file-name-nondirectory (vulpea-note-path n))))
                  :eabp-insert-function
                  (lambda (c)
                    (when-let ((n (cdr (assoc c table))))
                      (format "[[id:%s][%s]]"
                              (vulpea-note-id n) (vulpea-note-title n))))
                  :exclusive 'no)))))))

;; The capf bridge builds shadow buffers through this hook; installing
;; the capf there (buffer-locally, front of the list) keeps wikilink
;; completion scoped to the phone editor — desktop org buffers are the
;; user's own capf business.
(defun glasspane-notes--setup-shadow ()
  (when (derived-mode-p 'org-mode)
    (add-hook 'completion-at-point-functions
              #'glasspane-notes--wikilink-capf -10 t)))

(add-hook 'eabp-sync-shadow-setup-hook #'glasspane-notes--setup-shadow)

;; ─── PKM 4: backlinks + unlinked mentions ────────────────────────────────────

(defvar glasspane-notes--mentions (make-hash-table :test 'equal)
  "Note id -> computed unlinked-mentions list, `pending', or `error'.
Dropped wholesale by the cache seam.")

(defun glasspane-notes--note-card (note)
  "A tappable card for NOTE (opens its file in the editor)."
  (eabp-card
   (list (eabp-column
          (eabp-text (vulpea-note-title note) 'body)
          (eabp-text (file-name-nondirectory (vulpea-note-path note))
                     'caption)))
   :on-tap (eabp-action "files.open"
                        :args `((file . ,(vulpea-note-path note)))
                        :when-offline "drop")))

(defun glasspane-notes--mention-card (mention note-id)
  "A card for MENTION (:note :path :line :context :matched plist)."
  (let ((source (plist-get mention :note)))
    (eabp-card
     (list
      (eabp-column
       (eabp-text (if source (vulpea-note-title source)
                    (file-name-nondirectory (or (plist-get mention :path) "")))
                  'body)
       (eabp-text (or (plist-get mention :context) "") 'caption)
       (eabp-row
        (eabp-spacer :weight 1)
        (eabp-button "Link it"
                     (eabp-action "link.materialize"
                                  :args `((id . ,note-id)
                                          (path . ,(plist-get mention :path))
                                          (line . ,(plist-get mention :line))
                                          (matched . ,(plist-get mention :matched)))
                                  :when-offline "queue")
                     :variant "text" :icon "link"))))
     :on-tap (when-let ((path (plist-get mention :path)))
               (eabp-action "files.open" :args `((file . ,path))
                            :when-offline "drop")))))

(defun glasspane-notes-detail-nodes (ref)
  "Backlink section nodes for the detail REF (needs an `id'), or nil."
  (when-let* (((glasspane-notes-available-p))
              (id (alist-get 'id ref)))
    (let* ((backlinks (condition-case nil
                          (vulpea-db-query-by-links-some (list id))
                        (error nil)))
           (mentions (gethash id glasspane-notes--mentions 'unfetched)))
      (append
       (list (eabp-divider)
             (eabp-collapsible
              (concat "backlinks/" id)
              (eabp-section-header
               (format "Linked references (%d)" (length backlinks)))
              (or (mapcar #'glasspane-notes--note-card backlinks)
                  (list (eabp-text "Nothing links here yet." 'caption)))
              :collapsed (null backlinks)))
       (list (eabp-collapsible
              (concat "mentions/" id)
              (eabp-section-header
               (pcase mentions
                 ('unfetched "Unlinked mentions")
                 ('pending "Unlinked mentions (searching…)")
                 ('error "Unlinked mentions (search failed)")
                 (found (format "Unlinked mentions (%d)" (length found)))))
              (pcase mentions
                ('unfetched
                 (list (eabp-button
                        "Find mentions"
                        (eabp-action "notes.mentions" :args `((id . ,id))
                                     :when-offline "drop")
                        :variant "text" :icon "manage_search")))
                ('pending (list (eabp-progress :variant "linear")))
                ('error (list (eabp-text "ripgrep unavailable or the search failed."
                                         'caption)))
                ('nil (list (eabp-text "No unlinked mentions." 'caption)))
                (found (mapcar (lambda (m)
                                 (glasspane-notes--mention-card m id))
                               found)))
              :collapsed (eq mentions 'unfetched)))))))

;; The mention grep is the battery-risk item: computed only on the
;; explicit button tap, cached per note, dropped by the standard seam.
(eabp-defaction "notes.mentions"
  (lambda (args _)
    (let ((id (alist-get 'id args)))
      (when (and (stringp id) (glasspane-notes-available-p)
                 (fboundp 'vulpea-note-unlinked-mentions-async))
        (when-let ((note (vulpea-db-get-by-id id)))
          (puthash id 'pending glasspane-notes--mentions)
          (vulpea-note-unlinked-mentions-async
           note
           (lambda (mentions)
             (puthash id mentions glasspane-notes--mentions)
             (eabp-shell-push))
           (lambda (_err)
             (puthash id 'error glasspane-notes--mentions)
             (eabp-shell-push)))
          (eabp-shell-push))))))

(eabp-defaction "link.materialize"
  ;; Replace the first un-linked occurrence of MATCHED on LINE in PATH
  ;; with a real id link.  Titles match case-insensitively (search UX);
  ;; the replacement keeps the text exactly as written in the file.
  (lambda (args _)
    (let ((id (alist-get 'id args))
          (path (alist-get 'path args))
          (line (alist-get 'line args))
          (matched (alist-get 'matched args)))
      (when (and (stringp id) (stringp path) (integerp line)
                 (stringp matched) (not (string-empty-p matched))
                 (file-writable-p path))
        (with-current-buffer (find-file-noselect path)
          (org-with-wide-buffer
           (goto-char (point-min))
           (forward-line (1- line))
           (let ((end (line-end-position))
                 (case-fold-search t))
             (when (search-forward matched end t)
               (replace-match (format "[[id:%s][%s]]" id (match-string 0))
                              t t)
               (let ((save-silently t)) (save-buffer))
               (remhash id glasspane-notes--mentions)
               (glasspane-org-cache-invalidate)
               (eabp-shell-notify "Linked")
               (eabp-shell-push)))))))))

(add-hook 'eabp-shell-refresh-hook
          (lambda () (clrhash glasspane-notes--mentions)))

(provide 'glasspane-notes)
;;; glasspane-notes.el ends here
