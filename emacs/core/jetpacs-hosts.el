;;; jetpacs-hosts.el --- Remote hosts hub: TRAMP endpoints as cards -*- lexical-binding: t; -*-

;; The server pillar's one piece of construction.  Everything else about
;; driving a remote host from the phone is composition over what already
;; ships: TRAMP makes the existing skins remote — dired cards, comint
;; shells, compile/grep results, magit-section buffers, `daemons.el'
;; (tabulated-list → the tablist substrate), Emacs-Guix's bui lists — and
;; the minibuffer bridge already turns ssh password prompts into phone
;; dialogs.  What was missing is the front door: a card per host with the
;; things you actually do one-handed — browse its files, open a shell on
;; it, glance at its services, cut the connection.
;;
;; Hosts come from two places: the `jetpacs-hosts' defcustom (explicit,
;; wins) and `~/.ssh/config' Host entries (free coverage of everything
;; already configured; wildcard patterns are skipped).  The computed list
;; is also the action allowlist: the wire carries a host LABEL, never a
;; TRAMP path — the handler resolves the label against the list and
;; refuses anything else (the results.visit contract).
;;
;; Battery/latency guardrails, in order of importance: rendering NEVER
;; touches the network (connection state is read from tramp's existing
;; connection table, not probed); connect-ish actions bind
;; `tramp-connection-timeout' down to `jetpacs-hosts-connect-timeout' so a
;; dead host costs seconds, not a minute of blocked bridge; and the
;; Disconnect button exists precisely so lingering ssh masters don't
;; outlive their usefulness.  TRAMP operations are synchronous by nature —
;; this screen exposes glance-and-act operations, not long pipelines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)      ; jetpacs-defaction / jetpacs-action
(require 'jetpacs-tablist)       ; jetpacs-tablist-view-buffer-function (the
                                ;   buffer-view seam, set by jetpacs-emacs-ui)
(require 'jetpacs-shell)

;; TRAMP is built-in but heavy; it loads itself the moment a remote path
;; is touched.  Nothing here requires it up front.
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-list-connections "tramp-cmds" ())
(declare-function tramp-cleanup-connection "tramp-cmds"
                  (vec &optional keep-debug keep-password))
(declare-function tramp-file-name-host "tramp" (vec))
(declare-function tramp-file-name-method "tramp" (vec))
(declare-function dired-noselect "dired" (dir-or-list &optional switches))

;; Forward declaration so the timeout let-binding is DYNAMIC even before
;; tramp loads (an undeclared symbol would bind lexically — and silently
;; not reach tramp at all).
(defvar tramp-connection-timeout)

;; ─── Configuration ─────────────────────────────────────────────────────────

(defcustom jetpacs-hosts nil
  "Remote hosts shown in the Hosts hub: an alist of (LABEL . TRAMP-DIR).
LABEL is what the card shows (and all the wire ever carries); TRAMP-DIR
is where its actions land, e.g. (\"build box\" . \"/ssh:build:~/\").
Entries here win over same-labelled `~/.ssh/config' discoveries."
  :type '(alist :key-type string :value-type string) :group 'jetpacs)

(defcustom jetpacs-hosts-from-ssh-config t
  "When non-nil, `~/.ssh/config' Host entries also appear in the hub.
Each concrete Host name (wildcard patterns are skipped) becomes an
/ssh: card pointing at its home directory — zero configuration for
machines ssh already knows."
  :type 'boolean :group 'jetpacs)

(defcustom jetpacs-hosts-connect-timeout 10
  "Seconds a hub action waits for a TRAMP connection before giving up.
Bound over `tramp-connection-timeout' (default 60s) while a hub action
connects: on a phone, a dead host must cost seconds, not a minute of
blocked bridge."
  :type 'integer :group 'jetpacs)

;; ─── The host list (and action allowlist) ───────────────────────────────────

(defun jetpacs-hosts--ssh-config-hosts (file)
  "Concrete Host names from ssh config FILE, in order, duplicates removed.
A `Host' line may carry several names; patterns (any of `*?!') and the
negations ssh uses for exclusions are skipped.  Returns nil when FILE is
missing or unreadable."
  (when (and (stringp file) (file-readable-p file))
    (let (hosts)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*[Hh]ost[ \t]+\\(.+\\)$" nil t)
          (dolist (name (split-string (match-string 1)))
            (unless (string-match-p "[*?!]" name)
              (push name hosts)))))
      (delete-dups (nreverse hosts)))))

(defun jetpacs-hosts--all ()
  "The live host alist (LABEL . TRAMP-DIR): `jetpacs-hosts' first, then
ssh-config discoveries not shadowed by an explicit label.  This list is
the allowlist every hub action resolves against."
  (let ((all (copy-sequence jetpacs-hosts)))
    (when jetpacs-hosts-from-ssh-config
      (dolist (name (jetpacs-hosts--ssh-config-hosts
                     (expand-file-name "~/.ssh/config")))
        (unless (assoc name all)
          (setq all (nconc all (list (cons name (format "/ssh:%s:~/" name))))))))
    all))

(defun jetpacs-hosts--resolve (label)
  "LABEL's TRAMP directory from the live host list, or nil."
  (cdr (assoc label (jetpacs-hosts--all))))

;; ─── Connection state (read, never probed) ───────────────────────────────────

(defun jetpacs-hosts--connected-p (dir)
  "Whether DIR's host has a live TRAMP connection right now.
Reads tramp's own connection table; never opens one.  When tramp isn't
even loaded, nothing is connected."
  (and (featurep 'tramp)
       (fboundp 'tramp-list-connections)
       (condition-case nil
           (let ((vec (tramp-dissect-file-name dir)))
             (and vec
                  (cl-some (lambda (live)
                             (and (equal (tramp-file-name-host live)
                                         (tramp-file-name-host vec))
                                  (equal (tramp-file-name-method live)
                                         (tramp-file-name-method vec))))
                           (tramp-list-connections))))
         (error nil))))

;; ─── Opening things on a host ────────────────────────────────────────────────

(defun jetpacs-hosts--view-buffer-of (fn)
  "Call FN (returning a buffer or name) under the connect guardrails and
view the result — the tools-hub pattern, plus the timeout clamp.  A
password prompt raised mid-connect is bridged automatically (we are
inside an action handler); a dead host costs a snackbar."
  (condition-case err
      (let* ((tramp-connection-timeout jetpacs-hosts-connect-timeout) ;dynamic
             (buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

(defun jetpacs-hosts--with-host (args fn)
  "Resolve ARGS' host label against the allowlist and call FN with
\(LABEL . DIR); refuse anything the list doesn't know."
  (let* ((label (alist-get 'host args))
         (dir (and (stringp label) (jetpacs-hosts--resolve label))))
    (if (not dir)
        (jetpacs-shell-notify "Unknown host")
      (funcall fn label dir))))

(jetpacs-defaction "hosts.files"
  ;; Browse the host: a dired buffer on its TRAMP dir, rendered by the
  ;; dired cards skin through the buffer view.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (_label dir)
       (jetpacs-hosts--view-buffer-of
        (lambda ()
          (require 'dired)
          (dired-noselect dir)))))))

(jetpacs-defaction "hosts.shell"
  ;; A shell ON the host: M-x shell with a remote default-directory —
  ;; TRAMP runs the remote shell, the comint substrate renders it.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (label dir)
       (jetpacs-hosts--view-buffer-of
        (lambda ()
          (require 'shell)
          (let ((default-directory dir))
            (shell (generate-new-buffer-name (format "*shell %s*" label))))))))))

(jetpacs-defaction "hosts.services"
  ;; The host's services via daemons.el (third-party, soft): its
  ;; tabulated-list buffer rides the tablist substrate for free, and
  ;; daemons.el itself runs systemctl over TRAMP when default-directory
  ;; is remote.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (_label dir)
       (if (not (require 'daemons nil t))
           (jetpacs-shell-notify "daemons.el is not installed")
         (jetpacs-hosts--view-buffer-of
          (lambda ()
            (let ((default-directory dir))
              (save-window-excursion (funcall (intern "daemons")))
              "*daemons*"))))))))

(jetpacs-defaction "hosts.disconnect"
  ;; Cut the host's TRAMP connection (and its lingering ssh master) —
  ;; the battery-hygiene button.
  (lambda (args _)
    (jetpacs-hosts--with-host args
     (lambda (label dir)
       (if (not (jetpacs-hosts--connected-p dir))
           (jetpacs-shell-notify "Not connected")
         (condition-case err
             (progn
               (tramp-cleanup-connection (tramp-dissect-file-name dir))
               (jetpacs-shell-notify (format "Disconnected %s" label)))
           (error (jetpacs-shell-notify (error-message-string err)))))
       (jetpacs-shell-push)))))

;; ─── The hub view ────────────────────────────────────────────────────────────

(defvar jetpacs-hosts--daemons-available 'unknown
  "Cached `daemons.el' availability (a load-path scan is disk I/O;
render must stay cheap).  Reset to `unknown' after installing it.")

(defun jetpacs-hosts--daemons-p ()
  (when (eq jetpacs-hosts--daemons-available 'unknown)
    (setq jetpacs-hosts--daemons-available
          (and (locate-library "daemons") t)))
  jetpacs-hosts--daemons-available)

(defun jetpacs-hosts--card (entry)
  "A card for host ENTRY (LABEL . DIR): name, endpoint, state, actions."
  (let* ((label (car entry))
         (dir (cdr entry))
         (connected (jetpacs-hosts--connected-p dir))
         (args `((host . ,label))))
    (jetpacs-card
     (list
      (jetpacs-column
       (apply #'jetpacs-row
              (delq nil
                    (list
                     (jetpacs-box (list (jetpacs-column
                                   (jetpacs-text label 'label)
                                   (jetpacs-text dir 'caption)))
                               :weight 1)
                     (when connected
                       (jetpacs-chip "Connected" :icon "link")))))
       (apply #'jetpacs-row
              (append
               (delq nil
                     (list
                      (jetpacs-button "Files"
                                   (jetpacs-action "hosts.files" :args args
                                                :when-offline "drop")
                                   :icon "folder" :variant "tonal")
                      (jetpacs-button "Shell"
                                   (jetpacs-action "hosts.shell" :args args
                                                :when-offline "drop")
                                   :icon "terminal" :variant "tonal")
                      (when (jetpacs-hosts--daemons-p)
                        (jetpacs-button "Services"
                                     (jetpacs-action "hosts.services" :args args
                                                  :when-offline "drop")
                                     :icon "settings_suggest" :variant "tonal"))
                      (when connected
                        (jetpacs-icon-button "link_off"
                                          (jetpacs-action "hosts.disconnect"
                                                       :args args
                                                       :when-offline "drop")
                                          :content-description "Disconnect"))))
               '(:spacing 4))))))))

(defun jetpacs-hosts--body ()
  (let ((hosts (jetpacs-hosts--all)))
    (if (null hosts)
        (jetpacs-empty-state
         :icon "dns" :title "No hosts configured"
         :caption (concat "Add (LABEL . \"/ssh:host:~/\") pairs to "
                          "jetpacs-hosts, or list machines in ~/.ssh/config "
                          "— concrete Host entries appear here automatically."))
      (apply #'jetpacs-lazy-column
             (cons (jetpacs-text
                    "Passwords prompt on the phone; connections stay up until you disconnect."
                    'caption)
                   (mapcar #'jetpacs-hosts--card hosts))))))

(defun jetpacs-hosts--view (snackbar)
  (jetpacs-shell-nav-view "Remote hosts" (jetpacs-hosts--body)
                       :back-to "tools"
                       :snackbar snackbar))

(jetpacs-shell-define-view "hosts" :builder #'jetpacs-hosts--view :order 88)

(provide 'jetpacs-hosts)
;;; jetpacs-hosts.el ends here