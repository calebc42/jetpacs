;;; jetpacs-keymap.el --- Keymap surfacing for the radial pie menu -*- lexical-binding: t; -*-

;; The input complement to the Tier 0 generic buffer renderer.  Two UIs,
;; split by how good the available labels are:
;;
;;   * Tier 0 default — a searchable COMMAND PALETTE.  Raw keymap dumps
;;     have dozens of bindings with machine-made labels; a live-filtering
;;     list (the bridged `completing-read' picker) beats a pie menu for
;;     that.  `jetpacs.keymap.show' extracts the buffer's bindings and runs
;;     the picker; choosing an entry executes the key in-buffer (with
;;     minibuffer prompts auto-bridged as always).
;;
;;   * Tier 1 — the RADIAL PIE MENU, reserved for curated, bounded menus.
;;     Today that means a live transient.el session (`transient--prefix'
;;     non-nil): human-written suffix descriptions, ≤~10 items — the pie's
;;     sweet spot.  Executing a command that *activates* a transient
;;     (e.g. picking `magit-dispatch' from the palette) opens the pie
;;     automatically; when the transient ends the pie is dismissed.
;;
;; The grouping/category machinery below (`jetpacs-keymap--group-bindings')
;; is retained for future Tier 1 skins that want to send curated pie
;; specs for a whole mode; the default path no longer uses it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jetpacs-surfaces)   ; jetpacs-defaction, jetpacs-action, jetpacs-send

;; Forward declaration: defined in jetpacs-buffer.el, set by jetpacs-emacs-ui.el
(defvar jetpacs-buffer-refresh-function)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-keymap-show-global nil
  "When non-nil, include global-map bindings in the pie menu.
Usually these are ambient (C-x C-s, C-g, etc.) and not useful on a phone;
the mode-specific bindings are what matter."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-keymap-max-segments 8
  "Maximum number of top-level categories in the pie menu.
Excess categories are merged into an \"Other\" overflow group."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-keymap-max-bindings 200
  "Maximum number of bindings to extract from a buffer's keymaps.
Safety cap so a mode with hundreds of bindings doesn't produce an
unbounded spec."
  :type 'integer :group 'jetpacs)

(defcustom jetpacs-keymap-denylist
  '(self-insert-command
    digit-argument negative-argument universal-argument
    undefined ignore keyboard-quit keyboard-escape-quit
    abort-recursive-edit abort-minibuffers
    exit-minibuffer minibuffer-keyboard-quit
    newline newline-and-indent open-line
    ;; Mouse/menu noise
    mouse-set-point mouse-set-region mouse-drag-region
    mac-mouse-turn-on-fullscreen
    ;; Too generic
    undo undo-redo
    ;; Forward/backward char — not useful on phone
    forward-char backward-char
    next-line previous-line
    scroll-up-command scroll-down-command
    beginning-of-buffer end-of-buffer
    move-beginning-of-line move-end-of-line)
  "Commands excluded from the pie menu.
These are either noise (self-insert), globally ambient, or navigation
that doesn't make sense on a phone touchscreen."
  :type '(repeat symbol) :group 'jetpacs)

;; ─── Binding extraction ────────────────────────────────────────────────────

(defun jetpacs-keymap--key-printable-p (key)
  "Non-nil if KEY (a key vector) represents a printable/keyboard binding.
Excludes mouse events, menu-bar, tool-bar, header-line, mode-line, and
function keys beyond F12."
  (let ((first (aref key 0)))
    (not (or (and (symbolp first)
                  (let ((name (symbol-name first)))
                    (or (string-prefix-p "mouse-" name)
                        (string-prefix-p "drag-mouse-" name)
                        (string-prefix-p "double-mouse-" name)
                        (string-prefix-p "triple-mouse-" name)
                        (string-prefix-p "down-mouse-" name)
                        (string-prefix-p "wheel-" name)
                        (string-match-p "\\`\\(menu-bar\\|tool-bar\\|header-line\\|mode-line\\|tab-bar\\|tab-line\\|vertical-scroll-bar\\|horizontal-scroll-bar\\)" name))))
            ;; Event types that are conses (e.g. (menu-bar ...))
            (consp first)))))

(defun jetpacs-keymap--walk-keymap (keymap prefix-keys)
  "Walk KEYMAP and return a list of (KEY-VEC . COMMAND) pairs.
PREFIX-KEYS is a key vector prepended to each binding (for recursive
descent into prefix keymaps).  Only leaf (commandp) bindings are
returned; intermediate prefix keymaps are recursed into."
  (let (bindings)
    (when (keymapp keymap)
      (map-keymap
       (lambda (event def)
         (let* ((key-vec (vconcat prefix-keys (vector event)))
                ;; Unwrap menu-item forms to get the real definition
                (def (if (and (consp def) (eq (car def) 'menu-item))
                         (nth 2 def)
                       def))
                ;; Resolve the underlying value for type checks, but
                ;; keep the original symbol for storage so symbol-name
                ;; works downstream.
                (resolved (if (and (symbolp def) (fboundp def))
                              (indirect-function def)
                            def)))
           (cond
            ;; Skip non-printable keys
            ((not (jetpacs-keymap--key-printable-p key-vec)) nil)
            ;; Recurse into prefix keymaps (but limit depth to 3)
            ((and (keymapp resolved) (< (length key-vec) 4))
             (setq bindings
                   (append bindings
                           (jetpacs-keymap--walk-keymap resolved key-vec))))
            ;; Leaf binding — store the symbol, not the resolved function
            ((commandp def)
             (push (cons key-vec def) bindings)))))
       keymap))
    (nreverse bindings)))

(defun jetpacs-keymap--extract-bindings (buffer)
  "Extract printable key->command bindings from BUFFER's active keymaps.
Returns a list of (KEY-DESC COMMAND SOURCE) where KEY-DESC is a string
like \"s\" or \"C-c C-t\", COMMAND is a symbol, and SOURCE is a symbol
identifying the keymap (major-mode name, minor-mode name, or `global')."
  (with-current-buffer buffer
    (let ((local-map (current-local-map))
          (minor-maps (current-minor-mode-maps))
          (global-map (current-global-map))
          (seen (make-hash-table :test 'equal))
          result count)
      (setq count 0)
      ;; Helper: add bindings from a keymap, tagged with SOURCE
      (cl-flet ((collect (keymap source)
                  (when (and keymap (< count jetpacs-keymap-max-bindings))
                    (dolist (pair (jetpacs-keymap--walk-keymap keymap []))
                      (when (< count jetpacs-keymap-max-bindings)
                        (let* ((key-vec (car pair))
                               (cmd (cdr pair))
                               (desc (key-description key-vec)))
                          (unless (or (gethash desc seen)
                                     (memq cmd jetpacs-keymap-denylist)
                                     ;; Skip commands with names starting
                                     ;; with internal prefixes
                                     (string-prefix-p "menu-bar" desc)
                                     (string-prefix-p "<" desc))
                            (puthash desc t seen)
                            (push (list desc cmd source) result)
                            (setq count (1+ count)))))))))
        ;; Highest priority first: minor modes, then local, then global
        (dolist (mm minor-maps)
          (let* ((var (car mm))
                 (map (cdr mm))
                 (source (or var 'minor)))
            (collect map source)))
        (collect local-map major-mode)
        (when jetpacs-keymap-show-global
          (collect global-map 'global)))
      (nreverse result))))

;; ─── Transient.el integration ──────────────────────────────────────────────

(defun jetpacs-keymap--transient-available-p ()
  "Non-nil if transient.el is loaded."
  (featurep 'transient))

(defun jetpacs-keymap--transient-prefix-p (command)
  "Non-nil if COMMAND is a transient prefix (has a layout definition)."
  (and (jetpacs-keymap--transient-available-p)
       (symbolp command)
       (get command 'transient--layout)))

(defun jetpacs-keymap--transient-active-p ()
  "Non-nil if a transient session is currently active."
  (and (jetpacs-keymap--transient-available-p)
       (bound-and-true-p transient--prefix)))

(defun jetpacs-keymap--extract-transient-layout (prefix-symbol)
  "Extract bindings from PREFIX-SYMBOL's transient layout (without activating it).
Returns a list of (:key KEY :label LABEL :command CMD :is-infix BOOL) plists."
  (let ((layout (get prefix-symbol 'transient--layout))
        (result nil))
    (when layout
      (jetpacs-keymap--walk-transient-node layout result)
      (nreverse result))))

(defun jetpacs-keymap--walk-transient-node (thing result)
  "Recursively walk a transient layout node THING, pushing bindings onto RESULT.
THING can be a vector (group), a list starting with a transient class
symbol (suffix/infix), or a plain list of children to recurse over."
  (cond
   ;; Vector = group node: [CLASS-OR-LEVEL PLIST CHILDREN...]
   ;; Convert to list, skip the first 2 elements (class + plist), recurse children.
   ((vectorp thing)
    (dolist (child (cddr (append thing nil)))
      (jetpacs-keymap--walk-transient-node child result)))

   ;; List whose car is a transient-* class symbol → suffix or infix
   ;; Format: (transient-suffix :key "s" :command magit-stage ...)
   ;; The plist is (cdr thing), NOT (cadr thing).
   ((and (consp thing)
         (symbolp (car thing))
         (string-prefix-p "transient-" (symbol-name (car thing)))
         (plist-get (cdr thing) :key))
    (let* ((plist (cdr thing))
           (key (string-trim-right (plist-get plist :key)))
           (cmd (plist-get plist :command))
           (desc (or (plist-get plist :description)
                     (and (symbolp cmd) (symbol-name cmd))
                     ""))
           (class-name (symbol-name (car thing)))
           (is-infix (or (string-match-p "option" class-name)
                         (string-match-p "switch" class-name)
                         (string-match-p "infix" class-name))))
      (when (and key cmd)
        (when (functionp desc)
          (setq desc (condition-case nil (funcall desc) (error ""))))
        (push (list :key key
                    :label (if (stringp desc) desc "")
                    :command cmd
                    :is-infix is-infix)
              result))))

   ;; Plain list → iterate over each element and recurse
   ((listp thing)
    (dolist (elt thing)
      (jetpacs-keymap--walk-transient-node elt result)))))

(defun jetpacs-keymap--active-transient-bindings ()
  "Extract bindings from the currently active transient session.
Returns a list similar to `jetpacs-keymap--extract-transient-layout'
but reflecting the live state (current infix values, etc.)."
  (when (jetpacs-keymap--transient-active-p)
    (let (result)
      (dolist (obj (bound-and-true-p transient-current-suffixes))
        (condition-case nil
            (let ((key (and (slot-boundp obj 'key) (eieio-oref obj 'key)))
                  (cmd (and (slot-boundp obj 'command) (eieio-oref obj 'command)))
                  (desc (condition-case nil
                            (let ((d (eieio-oref obj 'description)))
                              (if (functionp d) (funcall d) d))
                          (error "")))
                  (is-infix (and (fboundp 'transient-infix-p)
                                 (funcall 'transient-infix-p obj))))
              (when (and key cmd)
                (push (list :key key
                            :label (or desc "")
                            :command cmd
                            :is-infix is-infix)
                      result)))
          (error nil)))
      (nreverse result))))

;; ─── Grouping ──────────────────────────────────────────────────────────────

(defun jetpacs-keymap--single-key-p (key-desc)
  "Non-nil if KEY-DESC is a single unmodified key (like \"s\", \"g\", \"?\")."
  (and (= (length key-desc) 1)
       (not (string-match-p "[CM]-" key-desc))))

(defun jetpacs-keymap--prefix-of (key-desc)
  "Return the prefix group for KEY-DESC, or nil for single keys.
E.g. \"C-c C-t\" -> \"C-c\", \"C-x 4 f\" -> \"C-x\", \"M-g g\" -> \"M-g\"."
  (when (string-match "\\`\\([CMSs]-[^ ]+\\) " key-desc)
    (match-string 1 key-desc)))

(defun jetpacs-keymap--group-bindings (bindings buffer-name)
  "Group BINDINGS into categories for the pie menu.
BUFFER-NAME is used in action args.
Returns an alist of (CATEGORY-LABEL ICON . BINDING-SPECS) suitable for
the companion's pie menu JSON."
  (let ((single-keys nil)
        (prefix-groups (make-hash-table :test 'equal))
        (categories nil))
    ;; Partition bindings
    (dolist (b bindings)
      (let ((key-desc (nth 0 b)))
        (if (jetpacs-keymap--single-key-p key-desc)
            (push b single-keys)
          (let ((prefix (or (jetpacs-keymap--prefix-of key-desc) "Other")))
            (push b (gethash prefix prefix-groups))))))
    ;; Build categories
    ;; 1. Single-key commands (the "hot keys") — most important
    (when single-keys
      (push (cons "Keys"
                  (cons "keyboard"
                        (jetpacs-keymap--bindings-to-specs
                         (nreverse single-keys) buffer-name)))
            categories))
    ;; 2. Prefix groups (C-c, C-x, M-g, etc.)
    (let ((prefix-list nil))
      (maphash (lambda (prefix bindings)
                 (push (cons prefix (nreverse bindings)) prefix-list))
               prefix-groups)
      ;; Sort by prefix name
      (setq prefix-list (sort prefix-list
                              (lambda (a b) (string< (car a) (car b)))))
      (dolist (pg prefix-list)
        (push (cons (car pg)
                    (cons "code"
                          (jetpacs-keymap--bindings-to-specs
                           (cdr pg) buffer-name)))
              categories)))
    ;; Enforce max categories
    (setq categories (nreverse categories))
    (when (> (length categories) jetpacs-keymap-max-segments)
      ;; Merge excess into "Other"
      (let ((keep (seq-take categories (1- jetpacs-keymap-max-segments)))
            (overflow (seq-drop categories (1- jetpacs-keymap-max-segments))))
        (setq categories
              (append keep
                      (list (cons "Other"
                                  (cons "more_horiz"
                                        (apply #'append
                                               (mapcar #'cddr overflow)))))))))
    categories))

(defun jetpacs-keymap--bindings-to-specs (bindings buffer-name)
  "Convert a list of (KEY-DESC CMD SOURCE) BINDINGS into JSON-ready specs."
  (mapcar
   (lambda (b)
     (let* ((key-desc (nth 0 b))
            (cmd (nth 1 b))
            (is-transient-prefix (jetpacs-keymap--transient-prefix-p cmd))
            (children (when is-transient-prefix
                        (jetpacs-keymap--transient-children-specs cmd buffer-name)))
            (label (jetpacs-keymap--command-label cmd)))
       (append
        `((key . ,key-desc)
          (label . ,label)
          (action . ,(jetpacs-action "jetpacs.keymap.run"
                                  :args `((buffer . ,buffer-name)
                                          (key . ,key-desc))
                                  :when-offline "drop")))
        (when is-transient-prefix
          `((is_prefix . t)))
        (when children
          `((children . ,(vconcat children)))))))
   bindings))

(defun jetpacs-keymap--transient-children-specs (prefix-cmd buffer-name)
  "Build child binding specs for transient prefix PREFIX-CMD."
  (let ((layout-bindings (jetpacs-keymap--extract-transient-layout prefix-cmd)))
    (mapcar
     (lambda (b)
       (let ((key (plist-get b :key))
             (label (plist-get b :label))
             (cmd (plist-get b :command))
             (is-infix (plist-get b :is-infix)))
         (append
          `((key . ,key)
            (label . ,(or label (symbol-name cmd))))
          (when is-infix `((is_infix . t)))
          `((action . ,(jetpacs-action "jetpacs.keymap.run"
                                    :args `((buffer . ,buffer-name)
                                            (key . ,key)
                                            (transient_prefix
                                             . ,(symbol-name prefix-cmd)))
                                    :when-offline "drop"))))))
     layout-bindings)))

(defun jetpacs-keymap--command-label (cmd)
  "Human-readable label for command CMD.
Strips only the current buffer's major-mode stem (so `org-agenda-list'
becomes \"agenda-list\" in an org buffer but keeps its full name
elsewhere).  For a hyphenated mode like `magit-status-mode', the first
segment (\"magit-\") is also tried.  Never strips blindly: the old
greedy last-dash strip turned `forward-paragraph' into \"paragraph\"."
  (if (not (symbolp cmd))
      (format "%s" cmd)
    (let* ((name (symbol-name cmd))
           (stem (string-remove-suffix "-mode" (symbol-name major-mode)))
           (head (car (split-string stem "-"))))
      (cond
       ((and (string-prefix-p (concat stem "-") name)
             (> (length name) (1+ (length stem))))
        (substring name (1+ (length stem))))
       ((and (string-prefix-p (concat head "-") name)
             (> (length name) (1+ (length head))))
        (substring name (1+ (length head))))
       (t name)))))

;; ─── Pie menu spec builder ─────────────────────────────────────────────────

(defun jetpacs-keymap--build-pie-spec (buffer)
  "Build the full pie-menu JSON spec for BUFFER's keybindings."
  (with-current-buffer buffer
    (let* ((mode-label (symbol-name major-mode))
           (buffer-name (buffer-name buffer))
           ;; Check for active transient first
           (is-transient (jetpacs-keymap--transient-active-p))
           (categories
            (if is-transient
                ;; Active transient: show its bindings as a single category
                (let* ((bindings (jetpacs-keymap--active-transient-bindings))
                       (specs (mapcar
                               (lambda (b)
                                 (let ((key (plist-get b :key))
                                       (label (plist-get b :label))
                                       (is-infix (plist-get b :is-infix)))
                                   (append
                                    `((key . ,key)
                                      (label . ,(or label "")))
                                    (when is-infix `((is_infix . t)))
                                    `((action
                                       . ,(jetpacs-action
                                           "jetpacs.keymap.run"
                                           :args `((buffer . ,buffer-name)
                                                   (key . ,key)
                                                   (transient_active . t))
                                           :when-offline "drop"))))))
                               bindings)))
                  (list (cons "Transient"
                              (cons "terminal" specs))))
              ;; Normal mode: extract from active keymaps
              (let ((bindings (jetpacs-keymap--extract-bindings buffer)))
                (jetpacs-keymap--group-bindings bindings buffer-name)))))
      `((center_label . ,mode-label)
        (buffer . ,buffer-name)
        (categories
         . ,(vconcat
             (mapcar
              (lambda (cat)
                `((label . ,(car cat))
                  (icon . ,(cadr cat))
                  (bindings . ,(vconcat (cddr cat)))))
              categories)))))))

;; ─── Tier 1 registry: curated pie menus per major mode ─────────────────────

(defvar jetpacs-keymap-tier1-menus nil
  "Alist of (MAJOR-MODE . BUILDER) curated Tier 1 pie menus.
BUILDER is called with the buffer and returns a pie-menu spec alist
\(same shape as `jetpacs-keymap--build-pie-spec').  A buffer whose mode
derives from a registered mode gets its curated pie instead of the
default command palette; the first matching entry wins.")

(defun jetpacs-keymap-register-tier1 (mode builder)
  "Register BUILDER as the curated Tier 1 pie menu for MODE."
  (setf (alist-get mode jetpacs-keymap-tier1-menus) builder))

(defun jetpacs-keymap--tier1-builder (buf)
  "The registered Tier 1 menu builder for BUF's major mode, or nil."
  (with-current-buffer buf
    (seq-some (lambda (cell)
                (and (derived-mode-p (car cell)) (cdr cell)))
              jetpacs-keymap-tier1-menus)))

;; ─── Menu-bar mining ────────────────────────────────────────────────────────
;;
;; A mode's menu-bar keymap is the ONE place its author writes human labels and
;; :help strings — exactly the curated metadata a raw keymap dump lacks.  We
;; mine the local and minor-mode menus (not the generic global File/Edit menu)
;; into palette entries: breadcrumb-labeled, help-annotated, dispatched by
;; command symbol.  Same class of curated, mode-owned command the palette
;; already runs, so this stays inside the command-dispatch boundary.

(defcustom jetpacs-keymap-menu-max-items 150
  "Cap on menu-derived palette entries mined from a buffer's menus."
  :type 'integer :group 'jetpacs)

(defun jetpacs-keymap--menu-pred (props key)
  "Non-nil when PROPS' KEY predicate (`:enable'/`:visible') passes or is absent.
A predicate that signals is treated as passing — better to offer a command
that turns out disabled than to hide one on a spurious error."
  (let ((m (plist-member props key)))
    (or (not m)
        (condition-case nil (eval (plist-get props key) t) (error t)))))

(defun jetpacs-keymap--menu-item-parse (binding)
  "Parse a menu keymap BINDING into (LABEL REAL HELP), or nil.
Handles the `menu-item' form and the older (STRING . REAL) /
\(STRING HELP . REAL) forms; applies `:filter' and drops items whose
`:enable'/`:visible' predicate is nil, and separators."
  (cond
   ((and (consp binding) (eq (car binding) 'menu-item))
    (let* ((label (nth 1 binding))
           (real (nth 2 binding))
           (props (nthcdr 3 binding))
           (filter (plist-get props :filter)))
      (when (functionp filter)
        (setq real (ignore-errors (funcall filter real))))
      (when (and (stringp label)
                 (not (string-prefix-p "--" label)) ; separator
                 (jetpacs-keymap--menu-pred props :enable)
                 (jetpacs-keymap--menu-pred props :visible))
        (list label real (plist-get props :help)))))
   ((and (consp binding) (stringp (car binding)))
    (let ((label (car binding))
          (rest (cdr binding)))
      (unless (string-prefix-p "--" label)
        (if (and (consp rest) (stringp (car rest)))
            (list label (cdr rest) (car rest))   ; (STRING HELP . REAL)
          (list label rest nil)))))              ; (STRING . REAL)
   (t nil)))

(defun jetpacs-keymap--menu-entries (keymap)
  "Flatten menu-bar KEYMAP into (LABEL-PATH HELP COMMAND) leaves.
Submenus recurse with a breadcrumb label path (\"File ▸ Save As…\");
disabled/invisible items, separators, and non-command leaves are dropped."
  (let (out)
    (cl-labels
        ((walk (km crumb depth)
           (when (and (keymapp km) (< depth 5)
                      (< (length out) jetpacs-keymap-menu-max-items))
             (map-keymap
              (lambda (_event binding)
                (when (< (length out) jetpacs-keymap-menu-max-items)
                  (when-let ((parsed (jetpacs-keymap--menu-item-parse binding)))
                    (let* ((label (nth 0 parsed))
                           (real (nth 1 parsed))
                           (help (nth 2 parsed))
                           (path (if crumb (concat crumb " ▸ " label) label)))
                      (cond
                       ((keymapp real) (walk real path (1+ depth)))
                       ((commandp real) (push (list path help real) out)))))))
              km))))
      (walk keymap nil 0))
    (nreverse out)))

(defun jetpacs-keymap--menu-maps (buf)
  "Menu-bar keymaps to mine for BUF: minor-mode and local (plus global when
`jetpacs-keymap-show-global').  The global menu is skipped by default — its
File/Edit/… entries are generic noise next to the mode's own menu."
  (with-current-buffer buf
    (let (maps)
      (dolist (km (current-minor-mode-maps))
        (let ((menu (and (keymapp km) (lookup-key km [menu-bar]))))
          (when (keymapp menu) (push menu maps))))
      (when-let* ((lm (current-local-map))
                  (menu (lookup-key lm [menu-bar])))
        (when (keymapp menu) (push menu maps)))
      (when jetpacs-keymap-show-global
        (let ((menu (lookup-key (current-global-map) [menu-bar])))
          (when (keymapp menu) (push menu maps))))
      (nreverse maps))))

(defun jetpacs-keymap--menu-candidates (buf)
  "Palette candidates mined from BUF's menu-bar keymaps.
Returns an alist of (DISPLAY . (command . SYMBOL)), deduped by command."
  (let (result (seen (make-hash-table :test 'eq)))
    (dolist (menu (jetpacs-keymap--menu-maps buf))
      (dolist (entry (jetpacs-keymap--menu-entries menu))
        (let* ((path (nth 0 entry))
               (help (nth 1 entry))
               (cmd (nth 2 entry))
               (display (if (and (stringp help) (not (string-empty-p help)))
                            (format "%s — %s" path (car (split-string help "\n" t)))
                          path)))
          (unless (or (gethash cmd seen) (memq cmd jetpacs-keymap-denylist))
            (puthash cmd t seen)
            (push (cons display (cons 'command cmd)) result)))))
    (nreverse result)))

;; ─── Command palette (Tier 0 default) ──────────────────────────────────────

(defun jetpacs-keymap--palette-candidates (buf)
  "Alist of (DISPLAY . TARGET) for BUF's key bindings and menu items.
TARGET is (key . KEY-DESC) for a keybinding or (command . SYMBOL) for a
menu-derived entry.  Keybindings come first (they carry the shortcut), then
the human-labeled menu entries."
  (with-current-buffer buf
    (append
     (mapcar (lambda (b)
               (pcase-let ((`(,key ,cmd ,_source) b))
                 (cons (format "%s  ·  %s" key (jetpacs-keymap--command-label cmd))
                       (cons 'key key))))
             (jetpacs-keymap--extract-bindings buf))
     (jetpacs-keymap--menu-candidates buf))))

(defun jetpacs-keymap--show-palette (buf)
  "Show a searchable command palette for BUF's keybindings and menu items.
Runs inside an action handler, so `completing-read' is bridged to the
companion as a live-filtering picker dialog.  A key binding is executed as
its key (so an activated transient opens its Tier 1 pie); a menu entry —
which may carry no key — is run by command symbol."
  (let* ((candidates (jetpacs-keymap--palette-candidates buf))
         (choice (cond
                  ((null candidates)
                   (message "Jetpacs keymap: no bindings extracted from %s"
                            (buffer-name buf))
                   nil)
                  (t (condition-case nil
                         (completing-read
                          (format "%s commands" (buffer-name buf))
                          (mapcar #'car candidates) nil t)
                       (quit nil)))))
         (target (cdr (assoc choice candidates))))
    (pcase target
      (`(key . ,key) (jetpacs-keymap--execute-key buf key))
      (`(command . ,cmd) (jetpacs-keymap--execute-command buf cmd)))))

;; ─── Key execution & pie-menu sync ──────────────────────────────────────────

(defun jetpacs-keymap--sync-pie (buf)
  "Reconcile the companion's radial overlay with transient state.
A live transient keeps (or opens) its Tier 1 pie menu; anything else
dismisses the overlay — so the pie can never linger after the command
it belonged to has finished."
  (if (jetpacs-keymap--transient-active-p)
      (jetpacs-send "pie_menu.show" (jetpacs-keymap--build-pie-spec buf))
    (jetpacs-send "pie_menu.dismiss" nil)))

(defun jetpacs-keymap--execute-key (buf key)
  "Execute KEY in BUF, then sync the pie menu and refresh the surface."
  (with-current-buffer buf
    (condition-case err
        (execute-kbd-macro (kbd key))
      (error
       (message "Jetpacs keymap: %s failed: %s" key (error-message-string err)))))
  (jetpacs-keymap--sync-pie buf)
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

(defun jetpacs-keymap--execute-command (buf cmd)
  "Run CMD interactively in BUF, then sync the pie menu and refresh the surface.
Menu entries may carry no key sequence, so they dispatch by symbol; any
minibuffer prompt CMD raises is bridged as always."
  (with-current-buffer buf
    (condition-case err
        (call-interactively cmd)
      (error
       (message "Jetpacs keymap: %s failed: %s" cmd (error-message-string err)))))
  (jetpacs-keymap--sync-pie buf)
  (when (functionp jetpacs-buffer-refresh-function)
    (funcall jetpacs-buffer-refresh-function)))

;; ─── Action handlers ───────────────────────────────────────────────────────

(jetpacs-defaction "jetpacs.keymap.show"
  (lambda (args _)
    (let* ((buffer-name (or (alist-get 'buffer args)
                            (and (bound-and-true-p jetpacs-emacs-ui--viewing-buffer)
                                 jetpacs-emacs-ui--viewing-buffer)
                            (buffer-name (current-buffer))))
           (buf (get-buffer buffer-name)))
      (cond
       ((not buf)
        (message "Jetpacs keymap: no such buffer %s" buffer-name))
       ;; Tier 1: a live transient has curated labels and a small, bounded
       ;; suffix set — exactly what the radial menu is good at.
       ((jetpacs-keymap--transient-active-p)
        (jetpacs-send "pie_menu.show" (jetpacs-keymap--build-pie-spec buf)))
       ;; Tier 1: a curated pie registered for this major mode (e.g. magit).
       ((when-let ((builder (jetpacs-keymap--tier1-builder buf)))
          (jetpacs-send "pie_menu.show" (funcall builder buf))
          t))
       ;; Tier 0 default: the searchable command palette.
       (t (jetpacs-keymap--show-palette buf))))))

(jetpacs-defaction "jetpacs.keymap.run"
  (lambda (args _)
    (let* ((buffer-name (alist-get 'buffer args))
           (key (alist-get 'key args))
           (transient-prefix-name (alist-get 'transient_prefix args))
           (transient-active (alist-get 'transient_active args))
           (buf (get-buffer buffer-name)))
      (when (and buf key)
        (with-current-buffer buf
          (condition-case err
              (cond
               ;; Active transient session: find and call the suffix directly
               (transient-active
                (jetpacs-keymap--run-transient-key key))
               ;; Known transient prefix: invoke the prefix first, then the suffix
               (transient-prefix-name
                (let ((prefix-cmd (intern-soft transient-prefix-name)))
                  (when (commandp prefix-cmd)
                    ;; Call the prefix to activate the transient
                    (call-interactively prefix-cmd)
                    ;; Now run the suffix key in the transient
                    (when (jetpacs-keymap--transient-active-p)
                      (jetpacs-keymap--run-transient-key key)))))
               ;; Normal key dispatch
               (t
                (execute-kbd-macro (kbd key))))
            (error
             (message "Jetpacs keymap.run %s failed: %s" key
                      (error-message-string err)))))
        ;; Keep the overlay honest: still-active transient re-shows its pie
        ;; (with fresh infix values); a finished one dismisses it.
        (jetpacs-keymap--sync-pie buf)
        ;; Re-push the surface
        (when (functionp jetpacs-buffer-refresh-function)
          (funcall jetpacs-buffer-refresh-function))))))

(defun jetpacs-keymap--run-transient-key (key)
  "Dispatch KEY within the currently active transient session.
Finds the suffix object with matching key and calls its command directly,
which is more reliable than simulating keystrokes through the transient's
`overriding-terminal-local-map'."
  (let ((target-cmd nil))
    (dolist (obj (bound-and-true-p transient-current-suffixes))
      (condition-case nil
          (when (and (slot-boundp obj 'key)
                     (equal key (eieio-oref obj 'key)))
            (setq target-cmd (and (slot-boundp obj 'command)
                                  (eieio-oref obj 'command))))
        (error nil)))
    (if (and target-cmd (commandp target-cmd))
        (call-interactively target-cmd)
      ;; Fallback: try feeding the key through the event loop
      (setq unread-command-events
            (append (listify-key-sequence (kbd key))
                    unread-command-events)))))

(jetpacs-defaction "jetpacs.keymap.dismiss"
  (lambda (_ _)
    (jetpacs-send "pie_menu.dismiss" nil)))

(provide 'jetpacs-keymap)
;;; jetpacs-keymap.el ends here
