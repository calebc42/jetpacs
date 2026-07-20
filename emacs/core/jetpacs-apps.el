;;; jetpacs-apps.el --- App identity over the shell: jetpacs-defapp + launcher home -*- lexical-binding: t; -*-

;; Groups shell views into named apps, AppSheet-style: a launcher home
;; grid of app cards, one app's tabs in the bottom bar at a time, and an
;; `app.open' action that switches between them.  Pure shell logic — no
;; wire changes beyond the `app.*' action namespace reserved in SPEC §5.
;;
;; THIS IS THE ENTRY POINT for a Tier 1 app.  The contract that keeps
;; coexisting apps isolated:
;;
;;   1. Name your views in your own namespace — "<appid>.<view>" (bare
;;      "<appid>" is fine for a single-view app).  The shell registry
;;      replaces by name; bare names collide across apps.
;;   2. Make registrations under (with-jetpacs-owner "<appid>" ...) —
;;      views, actions, settings sections/links, drawer items, top
;;      actions.  Ownership is what scopes your chrome and settings to
;;      your app, catches collisions, and lets `jetpacs-app-unregister'
;;      tear you down cleanly for live reload.
;;   3. Finish with `jetpacs-defapp' claiming your views.
;;
;; The single-app contract: with zero or one `jetpacs-defapp' registered,
;; NOTHING changes — every view and all chrome shows, no home screen, no
;; drawer entry.  The launcher machinery appears with the second app
;; (AppSheet boots straight into a lone app the same way).
;;
;; Views not claimed by any app (the core Files / Eval / Tools tabs)
;; show in every app.  To contain them instead, claim them in an
;; explicit app of their own:
;;   (jetpacs-defapp "system" :label "Emacs" :icon "terminal"
;;                :views '("files" "eval" "tools") :order 900)

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)

;; ─── Registry ────────────────────────────────────────────────────────────────

(defvar jetpacs-apps--registry nil
  "Ordered list of (ID . PLIST) registered apps.
PLIST keys: :label :icon :views (list of shell view names) :order.")

(defvar jetpacs-apps--current nil
  "Id of the app whose views are currently shown, or nil for the default.")

(defcustom jetpacs-apps-default-app "jetpacs"
  "App id to land on when none has been opened this session.
The vanilla \"Jetpacs\" app holds the core chrome (Buffers, Files, Eval,
Tools…), so it is the home base: installing another app must not silently
hide those tabs or boot you into the just-installed app.  Falls back to the
first registered app when this id is not registered — e.g. the vanilla app
is off via `jetpacs-apps-show-vanilla-app'.  nil restores raw
first-registered (AppSheet order) selection."
  :type '(choice (const :tag "First registered (AppSheet order)" nil)
                 (string :tag "App id"))
  :group 'jetpacs)

(defcustom jetpacs-apps-show-vanilla-app t
  "When non-nil, register Jetpacs itself as an app in the launcher.
Disable this if you start adding more apps and want the core
views (Buffers, Tools, etc.) to show up in those apps instead
of being isolated in a `Jetpacs' app."
  :type 'boolean
  :group 'jetpacs
  :set (lambda (sym val)
         (set-default sym val)
         (if (fboundp 'jetpacs-apps--update-vanilla)
             (jetpacs-apps--update-vanilla))))

(defun jetpacs-apps--update-vanilla ()
  "Register or unregister the vanilla Jetpacs app based on settings."
  (if jetpacs-apps-show-vanilla-app
      ;; "welcome" (the first-run Start tab, jetpacs-demo.el) stays after
      ;; the landing tab in this list: `app.open' lands on the FIRST :tab
      ;; view, and welcome retires once the tour exists.
      (jetpacs-defapp "jetpacs" :label "Jetpacs" :icon "rocket_launch"
                      :views '("buffers" "messages" "tools" "files" "eval" "kill-ring" "automations" "customize" "welcome")
                      :order 900)
    ;; Unregister manually to avoid tearing down the core views entirely.
    (dolist (v '("buffers" "messages" "tools" "files" "eval" "kill-ring" "automations" "customize" "welcome"))
      (jetpacs--unclaim "view" v))
    (jetpacs-apps-remove "jetpacs")))


(cl-defun jetpacs-defapp (id &key label icon views (order 100))
  "Register (or replace) app ID grouping VIEWS (shell view names).
LABEL and ICON draw the app's launcher-home card; the first :tab view
in VIEWS is the app's landing tab.  ORDER sorts home cards; equal
orders keep registration order.

Name the views you define \"ID.<view>\" (or bare \"ID\") so they can
never collide with another app's; a view named \"ID.settings\" is
reached by the stock Settings drawer entry while this app is current
\(see `jetpacs-shell-resolve-view').  Claiming a core view (\"files\",
\"eval\", ...) into an app is also legal — that contains it to this
app instead of showing everywhere."
  ;; Attribute the app's views to it in the ownership registry, so
  ;; cross-app collisions are caught (`jetpacs--claim' warns, or errors under
  ;; `jetpacs-strict-namespaces') and `jetpacs-app-unregister' can find them
  ;; (see with-jetpacs-owner / jetpacs--claim in jetpacs-surfaces.el).
  (let ((jetpacs-current-owner id))
    ;; A re-`jetpacs-defapp' with a shrunk :views set must release the views
    ;; it dropped, or their ownership records outlive the claim and mislead
    ;; `jetpacs-app-unregister' (which tears down by owned name).
    (dolist (v (jetpacs--owned-names "view" id))
      (unless (member v views) (jetpacs--unclaim "view" v)))
    (dolist (v views) (jetpacs--claim "view" v)))
  (setq jetpacs-apps--registry
        (sort (append (assoc-delete-all id jetpacs-apps--registry)
                      (list (cons id (list :label (or label (capitalize id))
                                           :icon (or icon "apps")
                                           :views views :order order))))
              (lambda (a b) (< (plist-get (cdr a) :order)
                               (plist-get (cdr b) :order)))))
  (jetpacs-shell--schedule-repush)
  id)

(defun jetpacs-apps-remove (id)
  "Unregister app ID (its views fall back to showing everywhere)."
  (setq jetpacs-apps--registry (assoc-delete-all id jetpacs-apps--registry))
  (jetpacs-shell--schedule-repush))

(defun jetpacs-app-unregister (id)
  "Tear down everything owned by app ID: its actions, views, and settings.
Removes the registrations attributed to ID (through `with-jetpacs-owner' /
`jetpacs-defapp'), drops their ownership records, clears UI-state keyed
under the app's id prefix, and removes the app from the launcher.  For
clean live reload and genuine uninstall — no stale handlers accumulate.
Registrations a Tier 1 made without an owner are not tracked and are not
torn down (wrap them in `with-jetpacs-owner' to make them removable)."
  (dolist (name (jetpacs--owned-names "action" id))
    (remhash name jetpacs-action-handlers)
    (remhash name jetpacs--action-catalog)
    (jetpacs--unclaim "action" name))
  (dolist (name (jetpacs--owned-names "view" id))
    (jetpacs-shell-remove-view name)
    (jetpacs--unclaim "view" name))
  (dolist (title (jetpacs--owned-names "settings" id))
    (when (fboundp 'jetpacs-settings-remove-section)
      (jetpacs-settings-remove-section title))
    (jetpacs--unclaim "settings" title))
  ;; Owner-attributed chrome and settings links, and the app's FAB.
  (jetpacs-shell-remove-owned-chrome id)
  (when (boundp 'jetpacs-settings-links)
    (setq jetpacs-settings-links
          (cl-remove-if (lambda (e) (equal (cddr e) id))
                        jetpacs-settings-links)))
  (when (boundp 'jetpacs-settings-native-links)
    (setq jetpacs-settings-native-links
          (cl-remove-if (lambda (e) (equal (cddr e) id))
                        jetpacs-settings-native-links)))
  (setf (alist-get id jetpacs-apps--fabs nil t #'equal) nil)
  ;; Drop UI-state and its subscriptions keyed under the app's id prefix.
  (jetpacs-ui-state-clear (concat id "."))
  (jetpacs-on-state-change-clear (concat id "."))
  ;; Surfaces
  (dolist (name (jetpacs--owned-names "surface" id))
    (jetpacs-surface-remove name)
    (jetpacs--unclaim "surface" name))
  ;; Data sources (jetpacs-source.el; guard for a lean build without it)
  (dolist (name (jetpacs--owned-names "source" id))
    (when (fboundp 'jetpacs-source-remove) (jetpacs-source-remove name)))
  ;; Async loaders (jetpacs-async.el; guard for a lean build without it)
  (when (fboundp 'jetpacs-async-clear-owner)
    (jetpacs-async-clear-owner id))
  ;; Forms (jetpacs-form registry)
  (dolist (form (jetpacs--forms-of-owner id)) (jetpacs-form-dispose form))
  ;; Triggers (batch to avoid N redundant pushes)
  (let ((trigger-names (jetpacs--owned-names "trigger" id)))
    (dolist (name trigger-names)
      (remhash name jetpacs-triggers--table)
      (jetpacs--unclaim "trigger" name))
    (when trigger-names
      (jetpacs-triggers-push)
      (when (boundp 'jetpacs-triggers-changed-hook)
        (run-hooks 'jetpacs-triggers-changed-hook))))
  (jetpacs-apps-remove id)
  (jetpacs-shell--schedule-repush)
  id)

(defun jetpacs-apps--owner (view-name)
  "The id of the app claiming VIEW-NAME, or nil when unclaimed."
  (car (cl-find-if (lambda (e) (member view-name (plist-get (cdr e) :views)))
                   jetpacs-apps--registry)))

(defun jetpacs-apps--multi-p ()
  "Non-nil once a second app is registered — the launcher trigger."
  (> (length jetpacs-apps--registry) 1))

(defun jetpacs-apps-current ()
  "The current app id.
When nothing has been opened this session it defaults to
`jetpacs-apps-default-app' (the core \"Jetpacs\" home base), so installing an
app never silently hides the core tabs; failing that, the first registered
app."
  (cond ((assoc jetpacs-apps--current jetpacs-apps--registry)
         jetpacs-apps--current)
        ((and jetpacs-apps-default-app
              (assoc jetpacs-apps-default-app jetpacs-apps--registry))
         jetpacs-apps-default-app)
        (t (caar jetpacs-apps--registry))))

(defun jetpacs-apps-current-p (id)
  "Non-nil while app ID is the one whose views are showing.
Also non-nil with no second app registered — a lone app is always
current.  For gating dynamic registrations an app makes outside its
`with-jetpacs-owner' blocks."
  (or (not (jetpacs-apps--multi-p))
      (equal id (jetpacs-apps-current))))

;; ─── The shell filters (the whole gating mechanism) ──────────────────────────

(defun jetpacs-apps--view-visible-p (name)
  "Single-app: everything shows.  Multi-app: the current app's views
plus every unclaimed view (core tabs, the home grid itself), plus any
currently-firing OVERLAY.

An overlay is a transient drill-in destination (the Glasspane heading
detail), and it can be fired from ANOTHER app's host view — the shared
core file editor lives in the vanilla Jetpacs app, yet tapping a heading
there drills into `glasspane.detail'.  Gating overlays by owner drops
that view from the push while the other app is current, so the drill-in
has nothing to land on.  A firing overlay therefore bypasses the owner
check; a dormant one (its `:overlay' predicate nil) is still filtered,
so no other app's detail leaks in."
  (or (not (jetpacs-apps--multi-p))
      (let ((owner (jetpacs-apps--owner name)))
        (or (null owner)
            (equal owner (jetpacs-apps-current))
            (let ((pred (plist-get (cdr (assoc name jetpacs-shell-views))
                                   :overlay)))
              (and pred (condition-case nil (funcall pred) (error nil))))))))

;; Core view slots resolve to a per-app override when the current app
;; registered one: "settings" reaches "glasspane.settings" inside
;; Glasspane.  This replaces the single-app-era pattern of redefining
;; the stock view by name (which the last-loaded app would hijack).
(defun jetpacs-apps--resolve-view (name)
  (let ((cur (jetpacs-apps-current)))
    (and cur
         (let ((scoped (concat cur "." name)))
           (and (assoc scoped jetpacs-shell-views) scoped)))))

(defun jetpacs--install-invariants ()
  "Re-assert the multi-app isolation seams.  Idempotent.
These four function-valued vars ARE the whole gating mechanism: which
views are visible, which chrome (drawer items, top actions) shows, which
settings sections show, and the core->per-app view resolver.  They are
INTERNAL — deliberately not `defcustom's and not on any Settings screen —
because a stray `setq' (from user init.el or a mis-behaved app) that nulls
one would leak another app's views, chrome or settings.

Structural ownership, not load-order luck: this installer runs at load
time AND again as the first step of `jetpacs-connect' (via
`jetpacs-before-connect-hook'), which fires after the user's whole init.el
has run — so nothing done during init can survive to the first served
frame.  The seam vars themselves being internal (no user-facing knob) is
the other half; together they make isolation an invariant rather than a
default."
  (setq jetpacs-shell-view-filter-function   #'jetpacs-apps--view-visible-p
        jetpacs-shell-chrome-filter-function #'jetpacs-apps-current-p
        jetpacs-shell-view-resolver-function #'jetpacs-apps--resolve-view)
  ;; The settings-section filter lives in jetpacs-settings, which loads
  ;; after this file in the bundle; only set it once that var is bound.
  (when (boundp 'jetpacs-settings-section-filter-function)
    (setq jetpacs-settings-section-filter-function #'jetpacs-apps-current-p)))

;; Install at load time...
(jetpacs--install-invariants)
;; ...cover the settings filter as soon as its feature arrives (the
;; load-time call above skips it while still unbound)...
(with-eval-after-load 'jetpacs-settings
  (setq jetpacs-settings-section-filter-function #'jetpacs-apps-current-p))
;; ...and re-assert everything at connect, after all user init has run.
(add-hook 'jetpacs-before-connect-hook #'jetpacs--install-invariants)

;; Once a second app exists the drawer header names the app you are in;
;; a lone app keeps whatever `jetpacs-shell-drawer-header' it set.
(defun jetpacs-apps--drawer-header ()
  (when (jetpacs-apps--multi-p)
    (plist-get (cdr (assoc (jetpacs-apps-current) jetpacs-apps--registry))
               :label)))

(setq jetpacs-shell-drawer-header-function #'jetpacs-apps--drawer-header)

;; ─── Per-app default FAB ─────────────────────────────────────────────────────

(defvar jetpacs-apps--fabs nil
  "Alist of (APP-ID . FN); FN takes a view name and returns a FAB node.")

(defun jetpacs-apps--default-fab (name)
  "The current app's default FAB for view NAME, or nil."
  (let ((fn (cdr (assoc (jetpacs-apps-current) jetpacs-apps--fabs))))
    (when fn (funcall fn name))))

(defun jetpacs-apps-set-default-fab (id fn)
  "Give app ID the default FAB builder FN (view name -> FAB node or nil).
The app's FAB appears on its tab views that pass no explicit :fab —
and, unlike setting `jetpacs-shell-default-fab-function' directly, never
on another app's views."
  (setf (alist-get id jetpacs-apps--fabs nil t #'equal) nil)
  (push (cons id fn) jetpacs-apps--fabs)
  (setq jetpacs-shell-default-fab-function #'jetpacs-apps--default-fab)
  (jetpacs-shell--schedule-repush))

;; ─── The launcher home ───────────────────────────────────────────────────────

(defun jetpacs-apps--card (id plist)
  "The home-grid card for app ID."
  (jetpacs-card
   (list (jetpacs-box
          (list (jetpacs-column
                 (jetpacs-icon (plist-get plist :icon) :size 40)
                 (jetpacs-spacer :height 8)
                 (jetpacs-text (plist-get plist :label) 'title)))
          :alignment "center" :padding 16))
   :on-tap (jetpacs-action "app.open" :args `((app . ,id))
                        :when-offline "drop")))

(defun jetpacs-apps--home-view (snackbar)
  "The launcher home: a grid of app cards."
  (jetpacs-shell-nav-view
   "Apps"
   (apply #'jetpacs-flow-row
          (mapcar (lambda (e) (jetpacs-apps--card (car e) (cdr e)))
                  jetpacs-apps--registry))
   :snackbar snackbar))

(jetpacs-shell-define-view "home"
  :builder #'jetpacs-apps--home-view
  :when #'jetpacs-apps--multi-p
  :order 1)

;; Everyday nav: the Apps entry rides the drawer, but only exists once
;; there is more than one app (the drawer contract: no dead entries).
(jetpacs-shell-add-drawer-item
 5 (lambda ()
     (when (jetpacs-apps--multi-p)
       (jetpacs-drawer-item "apps" "Apps" (jetpacs-shell-switch-view "home")))))

;; ─── Wire action ─────────────────────────────────────────────────────────────

(jetpacs-defaction "app.open"
  (lambda (args _)
    (let ((app (alist-get 'app args)))
      (if (not (assoc app jetpacs-apps--registry))
          (message "Jetpacs apps: unknown app %s" app)
        (setq jetpacs-apps--current app)
        (let* ((views (plist-get (cdr (assoc app jetpacs-apps--registry)) :views))
               (tab (cl-find-if #'jetpacs-shell--tab-p views)) ; a real tab, or nil
               (landing (or tab (car views))))                 ; where to send the client
          (if tab
              ;; A tab app: the push sets the current tab (its hook + guard).
              (jetpacs-shell-push tab :switch-to tab)
            ;; A tab-less app: there is no tab to be on, so clear the current
            ;; tab (never leave it reporting the app we just left, nor a
            ;; non-tab view) and force the client onto the landing view.
            (setq jetpacs-shell--current-tab nil)
            (if landing
                (jetpacs-shell-push nil :switch-to landing)
              (jetpacs-shell-push))))))))

(with-eval-after-load 'jetpacs-settings
  ;; The Jetpacs (app) settings surface: dialog presentation and the app/
  ;; system knobs.  Rendered on the "settings-jetpacs" sub-screen (see
  ;; `jetpacs-settings-jetpacs-body'); Dialog style moved here from Bridge.
  (jetpacs-settings-register-section
   "Jetpacs"
   '((jetpacs-dialog-style :label "Dialog style")
     (jetpacs-apps-show-vanilla-app :label "Show Jetpacs in App drawer"))))

(jetpacs-apps--update-vanilla)

(provide 'jetpacs-apps)
;;; jetpacs-apps.el ends here
