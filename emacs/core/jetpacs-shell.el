;;; jetpacs-shell.el --- Multi-view app shell for Jetpacs -*- lexical-binding: t; -*-

;; The app-agnostic host: a registry of named views pushed together as one
;; multi-view surface (`app:dashboard'), with companion-local tab switching
;; (the `view.switch' builtin), a snackbar queue, drawer/bottom-bar/top-bar
;; chrome helpers, and the refresh/navigation actions every view shares.
;;
;; Tier 1 apps do not build a shell — they register views into this one:
;;
;;   (jetpacs-shell-define-view "myapp.agenda"
;;     :builder #'my-agenda-view
;;     :tab '(:icon "event" :label "Agenda") :order 10)
;;
;; View names live in the app's namespace: name them "<appid>.<view>"
;; (or bare "<appid>" for a single-view app) and claim them with
;; `jetpacs-defapp'.  The registry replaces by name, so two apps using the
;; same bare name would silently hijack each other's screens — the
;; ownership registry warns when that happens (see `jetpacs--claim').
;;
;; A builder is a function of one argument (the snackbar text to attach, or
;; nil) returning a full scaffold view alist — use `jetpacs-shell-tab-view' /
;; `jetpacs-shell-nav-view' for the standard chrome.  Views registered with
;; :tab appear in the bottom bar and become the current tab when the user
;; lands on them; :when gates inclusion per push (e.g. an editor view that
;; only exists while a file is open); :overlay marks a view that, while its
;; predicate holds, is the active view without being a tab (e.g. a detail
;; drill-in).
;;
;; This module also owns the host ends of the core seams: it points the
;; Tier 0 buffer renderer's `jetpacs-buffer-refresh-function' at the shell
;; push, wires `jetpacs-settings' feedback to the snackbar, pushes on connect
;; and after an offline-queue drain, and handles the `view.switched',
;; `nav.tab', and `dashboard.refresh' wire actions.  Apps that need to run
;; on those moments register on the hooks below instead of redefining them.

;;; Code:

(require 'cl-lib)
(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-buffer)
(require 'jetpacs-async)
(require 'jetpacs-devtools)

;; ─── View registry ───────────────────────────────────────────────────────────

(defvar jetpacs-shell-views nil
  "Ordered list of (NAME . PLIST) registered shell views.
Managed by `jetpacs-shell-define-view'; kept sorted by :order.")

(defvar jetpacs-shell--route-params (make-hash-table :test 'equal)
  "Map of view NAME -> its current route-param alist (see the Route params
section).  Set by `jetpacs-shell-navigate'; a 2-arg view builder receives the
alist as its second argument, and any builder can read it via
`jetpacs-route-param'.")

(declare-function jetpacs-spec--compile "jetpacs-spec")
;; Declarative :spec views are compiled by jetpacs-spec.el, which requires this
;; file; autoload avoids the load cycle (in the bundle the real function is
;; defined after this one, before any push occurs).
(autoload 'jetpacs-spec--compile "jetpacs-spec")

(cl-defun jetpacs-shell-define-view (name &key builder spec tab when overlay (order 100))
  "Register (or replace) shell view NAME.
BUILDER is a function of the snackbar text (or nil) returning the view's
scaffold alist.  A BUILDER that declares a *second* argument is a
param-routed detail: it receives this view's current route-param alist
\(set by `jetpacs-shell-navigate'), so the screen is a pure function of its
params rather than of a module state var.  SPEC is a declarative data-view
plist compiled
by jetpacs-spec.el (see docs/BINDING.md) — an alternative to BUILDER;
exactly one of the two is required.  TAB, when non-nil, is a plist
\(:icon :label :badge) placing the view in the bottom bar; landing on a
tab view makes it the current tab.  :badge, when non-nil, is a nullary
function called on every push whose result overlays the tab icon — a
count (capped at 99+ on-device), \"\" for a bare dot, or nil for none;
errors and nil render no badge, so a badge can never break the push.
WHEN, when non-nil, is a predicate gating the view's inclusion in each
push.  OVERLAY, when non-nil, is a predicate: while it holds, this view
is the active one shown on a background push (a detail drill-in over
the current tab).  ORDER sorts views and bottom-bar items."
  (unless (or builder spec)
    (error "jetpacs-shell-define-view %s: needs :builder or :spec" name))
  (when (and builder spec)
    (error "jetpacs-shell-define-view %s: :builder and :spec are exclusive" name))
  (setq jetpacs-shell-views
        (sort (cons (cons name (list :builder builder :spec spec :tab tab :when when
                                     :overlay overlay :order order))
                    (assoc-delete-all name jetpacs-shell-views))
              (lambda (a b)
                (< (plist-get (cdr a) :order) (plist-get (cdr b) :order)))))
  (jetpacs--claim "view" name)
  (jetpacs-shell--schedule-repush)
  name)

(defun jetpacs-shell-remove-view (name)
  "Unregister shell view NAME."
  (setq jetpacs-shell-views (assoc-delete-all name jetpacs-shell-views))
  (remhash name jetpacs-shell--route-params)
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-view-filter-function nil
  "When non-nil, a predicate on a view NAME gating inclusion per push.
The app layer (jetpacs-apps.el) installs the current-app filter here; nil
means every registered view shows — the single-app default.")

(defun jetpacs-shell--view-filtered-p (name)
  "Non-nil when NAME passes `jetpacs-shell-view-filter-function'.
A filter that signals passes the view — a broken app layer must not
blank the phone."
  (or (null jetpacs-shell-view-filter-function)
      (condition-case nil (funcall jetpacs-shell-view-filter-function name)
        (error t))))

(defun jetpacs-shell--visible-views ()
  "The registry entries included in this push (:when + app filter honoured).
A pred that signals counts as nil — a broken predicate must cost its
view, not the push."
  (cl-remove-if-not (lambda (entry)
                      (let ((pred (plist-get (cdr entry) :when)))
                        (and (jetpacs-shell--view-filtered-p (car entry))
                             (or (null pred)
                                 (condition-case nil (funcall pred)
                                   (error nil))))))
                    jetpacs-shell-views))

(defun jetpacs-shell--tab-p (name)
  "Non-nil when view NAME is registered as a bottom-bar tab."
  (plist-get (cdr (assoc name jetpacs-shell-views)) :tab))

(defun jetpacs-shell--overlay-p (name)
  "Non-nil when view NAME is registered as an overlay."
  (plist-get (cdr (assoc name jetpacs-shell-views)) :overlay))

;; ─── Shell state ─────────────────────────────────────────────────────────────

(defvar jetpacs-shell--current-tab nil
  "Name of the current bottom-bar tab, or nil for the first registered tab.")

(defvar jetpacs-shell--snackbar nil
  "Text queued by `jetpacs-shell-notify' for the next push, or nil.")

(defun jetpacs-shell-current-tab ()
  "The current tab name (the first included tab when none is set).
The fallback selects among `jetpacs-shell--visible-views' — honouring
:when, not just the app filter — because a :when-gated tab (the
first-run welcome tab) must not become the landing view of a push that
excludes it."
  (or jetpacs-shell--current-tab
      (car (cl-find-if (lambda (e) (plist-get (cdr e) :tab))
                       (jetpacs-shell--visible-views)))))

(defun jetpacs-shell-set-current-tab (name)
  "Switch to the registered bottom-bar tab NAME.
A NAME that is not a registered tab is rejected (returns nil and warns).
A valid switch routes through `jetpacs-shell-push' — running
`jetpacs-shell-view-switched-hook' and repushing — and returns NAME; it
never setqs the internal tab var directly."
  (if (jetpacs-shell--tab-p name)
      (progn (jetpacs-shell-push name) name)
    (message "Jetpacs: cannot switch to %S — not a registered tab" name)
    nil))

(defun jetpacs-shell--active-view ()
  "The view a push should land on: a firing overlay, else the current tab."
  (or (car (cl-find-if (lambda (e)
                         (let ((pred (plist-get (cdr e) :overlay)))
                           (and pred
                                (jetpacs-shell--view-filtered-p (car e))
                                (condition-case nil (funcall pred)
                                  (error nil)))))
                       jetpacs-shell-views))
      (jetpacs-shell-current-tab)))

(defun jetpacs-shell-notify (text)
  "Queue TEXT to show as a snackbar on the next shell push.
Note: the companion re-shows a snackbar only when the text *changes*,
so two identical messages back-to-back display once."
  (setq jetpacs-shell--snackbar text))

;; The buffer navigator lives in jetpacs-tablist.el; every satellite that lands
;; command output here already requires it, so a forward declaration keeps this
;; module free of a hard tablist dependency.
(defvar jetpacs-tablist-view-buffer-function)

(defun jetpacs-shell-view-buffer-of (fn)
  "Call FN (returning a buffer or buffer name) and view the result.
Window excursion contains the pop-to-buffer these commands do; errors land
in the snackbar instead of dying silently.  The shared wrapper the stock
satellites (tools, project, sql, hosts) land command output through."
  (condition-case err
      (let ((buf (save-window-excursion (funcall fn))))
        (when (bufferp buf) (setq buf (buffer-name buf)))
        (if (and (stringp buf) (get-buffer buf))
            (funcall jetpacs-tablist-view-buffer-function buf)
          (jetpacs-shell-notify "Nothing to show")))
    (error (jetpacs-shell-notify (error-message-string err)))))

;; ─── Route params (parameterized navigation) ─────────────────────────────────
;; A detail screen used to need a module state var plus a set-the-var-then-
;; switch action (grocy--selected-product-id + a `grocy.open-product' handler
;; that setq'd it and pushed :switch-to).  Route params replace that: navigate
;; carries an alist to the target view, whose builder is then a pure function
;; of its params — no per-app state var, no set-and-switch action.
;; (`jetpacs-shell--route-params' is declared up by the view registry so
;; `jetpacs-shell-remove-view' can clean it.)

(defun jetpacs-shell-route-params (&optional name)
  "The current route-param alist for view NAME (default: the active view).
Handy as an :overlay predicate — a param-routed detail is active exactly
while its params are set: :overlay (lambda () (jetpacs-shell-route-params \"v\"))."
  (gethash (or name (jetpacs-shell--active-view)) jetpacs-shell--route-params))

(defun jetpacs-route-param (key &optional name)
  "The value of route param KEY for view NAME (default: the active view)."
  (alist-get key (jetpacs-shell-route-params name)))

(cl-defun jetpacs-shell-navigate (view &optional params)
  "Navigate to VIEW carrying route PARAMS (an alist), pushing so the
companion lands on it.  VIEW's builder receives PARAMS as its second
argument when it declares one (else reads them via `jetpacs-route-param');
this replaces the module-state-var + set-and-switch drill-in idiom.  Pair
with an :overlay predicate that fires while the params are set, so a fresh
push (reconnect) still lands on the detail; switching to a tab clears every
route (`jetpacs-shell--clear-routes-on-tab'), dismissing the drill-in."
  (puthash view params jetpacs-shell--route-params)
  (jetpacs-shell-push nil :switch-to view))

(defun jetpacs-shell-clear-route (view)
  "Clear VIEW's route params and push — the explicit back for a param route."
  (remhash view jetpacs-shell--route-params)
  (jetpacs-shell-push))

(defun jetpacs-shell--builder-wants-params (fn)
  "Non-nil when builder FN accepts a second (route-params) argument."
  (let ((max (cdr (func-arity fn))))
    (or (eq max 'many) (and (integerp max) (>= max 2)))))

(defun jetpacs-shell--clear-routes-on-tab (name)
  "Drop all route params when the user lands on tab NAME.
Registered on `jetpacs-shell-view-switched-hook', so leaving a param-routed
detail for a bottom-bar tab dismisses it (its :overlay stops firing)."
  (when (jetpacs-shell--tab-p name)
    (clrhash jetpacs-shell--route-params)))

;; ─── Hooks (the app seams) ───────────────────────────────────────────────────

(defvar jetpacs-shell-view-switched-hook nil
  "Hook run with the view NAME the user is switching to.
Runs before the shell's own tab bookkeeping, for both companion-local
switches (`view.switched') and Emacs-driven tab pushes — but never for
overlay views.  Modules reset their drill-in state here.")

;; Landing on a tab dismisses any param-routed detail drill-in.
(add-hook 'jetpacs-shell-view-switched-hook #'jetpacs-shell--clear-routes-on-tab)

(defvar jetpacs-shell-refresh-hook nil
  "Hook run before a push that must bypass caches.
Runs on the explicit `dashboard.refresh' action and after an offline
queue drain; apps drop their memo caches here.")

(defvar jetpacs-shell-after-push-hook nil
  "Hook run after each successful shell push.
For cheap piggybacked sends (home-screen widgets, reminder syncs); keep
handlers memo-guarded so unchanged data sends nothing.")

;; ─── Chrome: drawer, bottom bar, top bar ─────────────────────────────────────

(defvar jetpacs-shell-drawer-header "Jetpacs"
  "Text rendered at the top of the app drawer.
When `jetpacs-shell-drawer-header-function' returns non-nil, that wins —
the apps layer uses it to show the current app's label once a second
app is registered.")

(defvar jetpacs-shell-drawer-header-function nil
  "When non-nil, a nullary function returning the drawer header, or nil
to fall back to `jetpacs-shell-drawer-header'.")

(defvar jetpacs-shell-chrome-filter-function nil
  "When non-nil, a predicate on an OWNER id gating chrome per push.
Applied to drawer items and default top-bar actions through the owner
recorded at registration time (`jetpacs-current-owner').  The apps layer
\(jetpacs-apps.el) installs the current-app filter here; nil means all
chrome shows — the single-app default.  A nil owner (core, or a
registration made outside `with-jetpacs-owner') always shows.")

(defun jetpacs-shell--chrome-visible-p (owner)
  "Non-nil when chrome registered by OWNER passes the app filter.
A filter that signals passes the item — a broken app layer must not
strip the drawer."
  (or (null owner)
      (null jetpacs-shell-chrome-filter-function)
      (condition-case nil (funcall jetpacs-shell-chrome-filter-function owner)
        (error t))))

(defvar jetpacs-shell-drawer-items nil
  "Ordered list of (ORDER BUILDER . OWNER) drawer entries.
BUILDER is a function of no arguments returning an `jetpacs-drawer-item';
OWNER is the `jetpacs-current-owner' captured at registration (nil =
core), consulted by `jetpacs-shell-chrome-filter-function'.")

(defun jetpacs-shell-add-drawer-item (order builder)
  "Add BUILDER (a nullary function returning a drawer item) at ORDER.
Registrations made under `with-jetpacs-owner' are attributed to that app
and shown only while it is current (once a second app exists)."
  (setq jetpacs-shell-drawer-items
        (sort (cons (cons order (cons builder jetpacs-current-owner))
                    jetpacs-shell-drawer-items)
              (lambda (a b) (< (car a) (car b)))))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-top-actions nil
  "Ordered list of (ORDER BUILDER . OWNER) default top-bar trailing actions.
BUILDER is a function of no arguments returning an icon-button node;
OWNER as in `jetpacs-shell-drawer-items'.")

(defun jetpacs-shell-add-top-action (order builder)
  "Add BUILDER (a nullary function returning an icon button) at ORDER.
Registrations made under `with-jetpacs-owner' are attributed to that app
and shown only while it is current (once a second app exists)."
  (setq jetpacs-shell-top-actions
        (sort (cons (cons order (cons builder jetpacs-current-owner))
                    jetpacs-shell-top-actions)
              (lambda (a b) (< (car a) (car b)))))
  (jetpacs-shell--schedule-repush))

(defun jetpacs-shell-remove-owned-chrome (owner)
  "Drop every drawer item and top action registered by OWNER."
  (setq jetpacs-shell-drawer-items
        (cl-remove-if (lambda (e) (equal (cddr e) owner))
                      jetpacs-shell-drawer-items)
        jetpacs-shell-top-actions
        (cl-remove-if (lambda (e) (equal (cddr e) owner))
                      jetpacs-shell-top-actions))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-default-fab-function nil
  "Function of a view name returning that view's default FAB node, or nil.
Apps set this to offer a global affordance (e.g. a capture button) on
views that don't define their own.")

(defun jetpacs-shell-default-fab (name)
  "The app-provided default FAB for view NAME, or nil."
  (when (functionp jetpacs-shell-default-fab-function)
    (funcall jetpacs-shell-default-fab-function name)))

(defun jetpacs-shell-switch-view (view)
  "Action descriptor for the companion-local `view.switch' builtin."
  `((builtin . "view.switch") (view . ,view)))

(defvar jetpacs-shell-view-resolver-function nil
  "When non-nil, a function from a logical view NAME to the concrete one.
The apps layer resolves core slots to per-app overrides — e.g.
\"settings\" becomes \"glasspane.settings\" while Glasspane is current
and has registered that view.  nil (or a resolver returning nil) keeps
the name as-is.")

(defun jetpacs-shell-resolve-view (name)
  "NAME through `jetpacs-shell-view-resolver-function', erring on NAME."
  (or (and jetpacs-shell-view-resolver-function
           (condition-case nil
               (funcall jetpacs-shell-view-resolver-function name)
             (error nil)))
      name))

(defun jetpacs-shell-drawer ()
  "The navigation drawer built from `jetpacs-shell-drawer-items'.
A builder returning nil contributes nothing — conditional entries
\(e.g. the multi-app \"Apps\" item) just return nil when hidden.
Entries registered under `with-jetpacs-owner' show only while their app
passes `jetpacs-shell-chrome-filter-function'."
  (jetpacs-drawer (delq nil (mapcar (lambda (e)
                                   (when (jetpacs-shell--chrome-visible-p (cddr e))
                                     (funcall (cadr e))))
                                 jetpacs-shell-drawer-items))
               :header (or (and jetpacs-shell-drawer-header-function
                                (condition-case nil
                                    (funcall jetpacs-shell-drawer-header-function)
                                  (error nil)))
                           jetpacs-shell-drawer-header)))

(defun jetpacs-shell-bottom-bar (selected)
  "The bottom bar of the included :tab views, with SELECTED highlighted.
Honours the app filter (each app shows its own tabs) and :when — a
gated tab (the first-run welcome tab) must leave the bar in the same
push that stops including its view."
  (jetpacs-bottom-bar
   (cl-loop for (name . plist) in (jetpacs-shell--visible-views)
            for tab = (plist-get plist :tab)
            when tab
            collect (jetpacs-nav-item (plist-get tab :icon)
                                   (plist-get tab :label)
                                   (jetpacs-shell-switch-view name)
                                   :selected (equal name selected)
                                   :badge (when-let ((fn (plist-get tab :badge)))
                                            (condition-case nil (funcall fn)
                                              (error nil)))))))

(cl-defun jetpacs-shell-default-top-bar (title &key extra-actions)
  "The standard top bar: TITLE plus the registered trailing actions.
EXTRA-ACTIONS are prepended (view-specific buttons before the globals).
Actions registered under `with-jetpacs-owner' show only while their app
passes `jetpacs-shell-chrome-filter-function'."
  (jetpacs-top-bar title
                :actions (append extra-actions
                                 (delq nil
                                       (mapcar (lambda (e)
                                                 (when (jetpacs-shell--chrome-visible-p (cddr e))
                                                   (funcall (cadr e))))
                                               jetpacs-shell-top-actions)))))

(cl-defun jetpacs-shell-tab-view (name body &key top-bar (fab nil fab-given) snackbar snackbar-action floating-toolbar)
  "A standard tab view: drawer, bottom bar, pull-to-refresh, default chrome.
NAME selects the bottom-bar highlight; BODY is the content node.  TOP-BAR
defaults to `jetpacs-shell-default-top-bar' on the capitalized name.  When FAB
is not given at all, the app's `jetpacs-shell-default-fab' is used; pass an
explicit nil to render no FAB."
  `((children . ,(vector
                  (jetpacs-scaffold
                   :top-bar (or top-bar (jetpacs-shell-default-top-bar (capitalize name)))
                   :body body
                   :fab (if fab-given fab (jetpacs-shell-default-fab name))
                   :bottom-bar (jetpacs-shell-bottom-bar name)
                   :drawer (jetpacs-shell-drawer)
                   :snackbar snackbar
                   :snackbar-action snackbar-action
                   :floating-toolbar floating-toolbar
                   ;; Tab views support pull-to-refresh; navigation/detail
                   ;; views don't (a stray pull mustn't rebuild them).
                   :on-refresh (jetpacs-action "dashboard.refresh"
                                            :when-offline "drop"))))))

(cl-defun jetpacs-shell-nav-view (title body &key back-to nav-action actions
                                     fab snackbar snackbar-action bottom-bar floating-toolbar)
  "A navigation view: back arrow in the top bar, no tabs or drawer.
BACK-TO names the view the arrow switches to (default: the current tab)
as a companion-local switch; NAV-ACTION overrides it with an explicit
action descriptor.  ACTIONS are trailing top-bar buttons."
  `((children . ,(vector
                  (jetpacs-scaffold
                   :top-bar (jetpacs-top-bar title
                                          :nav-icon "arrow_back"
                                          :nav-action
                                          (or nav-action
                                              (jetpacs-shell-switch-view
                                               (or back-to (jetpacs-shell-current-tab))))
                                          :actions actions)
                   :body body
                   :fab fab
                   :snackbar snackbar
                   :snackbar-action snackbar-action
                   :bottom-bar bottom-bar
                   :floating-toolbar floating-toolbar)))))

;; ─── The push ────────────────────────────────────────────────────────────────

(defvar jetpacs-shell-surface-id "app:dashboard"
  "Surface id the shell pushes to.  One multi-view surface: the companion
switches views locally, so navigation never waits on Emacs.")

(defun jetpacs-shell--build-view (name plist snackbar)
  "Build view NAME from its :builder in PLIST, degrading errors in place.
A broken builder must cost its own screen, not the whole push — with a
Tier 1 being live-coded against a running session, the rest of the app
keeps updating and the broken view *shows* its error."
  (let* ((start (current-time))
         (spec
          (condition-case err
              (if (plist-get plist :spec)
                  (jetpacs-spec--compile name (plist-get plist :spec) snackbar)
                (let ((builder (plist-get plist :builder)))
                  ;; A builder that declares a second argument is a param-routed
                  ;; detail — hand it this view's current route params.
                  (if (jetpacs-shell--builder-wants-params builder)
                      (funcall builder snackbar (gethash name jetpacs-shell--route-params))
                    (funcall builder snackbar))))
            (error
             (jetpacs-shell-nav-view
              (capitalize name)
              (jetpacs-column
               (jetpacs-text (format "Error building view \"%s\"" name) 'title)
               (jetpacs-text (error-message-string err) 'body))
              :snackbar snackbar)))))
    ;; A degraded error view is recorded too: it IS what was pushed, and
    ;; its wall clock includes the crash path.
    (jetpacs-devtools--record-build
     name (* 1000.0 (float-time (time-subtract (current-time) start))) spec)
    spec))

(declare-function jetpacs-lint-spec "jetpacs-lint")

;;;###autoload
(defun jetpacs-lint-views (&optional errors-only)
  "Lint every registered shell view by building and checking it.
Builds each view (a builder crash is caught and reported, not degraded), lints
the result, and returns an alist of (VIEW-NAME . PROBLEMS) for the views with
problems — nil when all clean.  The one-line CI gate for an app:
\(should-not (jetpacs-lint-views t)).  With ERRORS-ONLY non-nil, `warning:'-
prefixed problems (the forward-compat heuristics) are dropped, leaving only
structural errors."
  (let (out)
    (dolist (entry jetpacs-shell-views)
      (let* ((name (car entry)) (plist (cdr entry))
             (problems
              (condition-case err
                  (let ((spec (if (plist-get plist :spec)
                                  (jetpacs-spec--compile name (plist-get plist :spec) nil)
                                (let ((b (plist-get plist :builder)))
                                  (if (jetpacs-shell--builder-wants-params b)
                                      (funcall b nil (gethash name jetpacs-shell--route-params))
                                    (funcall b nil))))))
                    (jetpacs-lint-spec spec))
                (error (list (cons nil (format "build error: %s"
                                               (error-message-string err))))))))
        (when errors-only
          (setq problems (cl-remove-if
                          (lambda (p) (string-prefix-p "warning: " (cdr p)))
                          problems)))
        (when problems (push (cons name problems) out))))
    (nreverse out)))

(defvar jetpacs-shell--repush-timer nil)

(defun jetpacs-shell--schedule-repush ()
  "Debounced push after a registry mutation on a live session.
Loading a Tier 1 file registers views/chrome in a burst; one idle push
after the burst means `eval-buffer' (or `load') against a connected
phone updates the app with no explicit `jetpacs-shell-push' — the
live-coding loop.  A no-op while disconnected: the on-connect push will
carry the registrations."
  (when (and (jetpacs-connected-p) (not (timerp jetpacs-shell--repush-timer)))
    (setq jetpacs-shell--repush-timer
          (run-with-idle-timer 0.5 nil
                               (lambda ()
                                 (setq jetpacs-shell--repush-timer nil)
                                 (jetpacs-shell-push))))))

(cl-defun jetpacs-shell-push (&optional tab &key switch-to)
  "Push every registered view as one multi-view surface.
TAB switches the logical tab before building.  SWITCH-TO additionally
forces the companion onto that view (used when a push *is* the
navigation, e.g. opening a detail); plain background refreshes never
yank the user off whatever they're looking at."
  ;; Any explicit push satisfies a pending registry repush.
  (when (timerp jetpacs-shell--repush-timer)
    (cancel-timer jetpacs-shell--repush-timer)
    (setq jetpacs-shell--repush-timer nil))
  ;; Only a registered tab may become the current tab — the invariant
  ;; `jetpacs-shell-current-tab' relies on.  A non-tab TAB (a stale `nav.tab'
  ;; payload, say) is ignored here rather than corrupting the state.
  (when (and tab (jetpacs-shell--tab-p tab))
    (unless (equal tab jetpacs-shell--current-tab)
      (run-hook-with-args 'jetpacs-shell-view-switched-hook tab))
    (setq jetpacs-shell--current-tab tab))
  (let ((snackbar (prog1 jetpacs-shell--snackbar
                    (setq jetpacs-shell--snackbar nil))))
    (condition-case err
        (let* ((active (jetpacs-shell--active-view))
               (target (or switch-to tab))
               ;; A navigation push lands the user on TARGET, so feedback
               ;; (e.g. "Saved init.el") must attach there, not to the view
               ;; they're leaving.
               (snack-view (or target active))
               (views (mapcar
                       (lambda (entry)
                         (let ((name (car entry)))
                           (cons (intern name)
                                 (jetpacs-shell--build-view
                                  name (cdr entry)
                                  (when (equal name snack-view)
                                    snackbar)))))
                       (jetpacs-shell--visible-views))))
          (jetpacs-surface-push
           jetpacs-shell-surface-id
           `((views . ,views)
             (initial_view . ,active))
           nil nil
           ;; Force the companion onto a view only when this push *is* a
           ;; navigation — see SWITCH-TO above.
           target)
          (run-hooks 'jetpacs-shell-after-push-hook))
      (error
       ;; A failed push showed nothing: requeue the snackbar for the next
       ;; one (unless something queued fresher feedback meanwhile).
       (setq jetpacs-shell--snackbar (or jetpacs-shell--snackbar snackbar))
       (message "Jetpacs shell push failed: %s" (error-message-string err))))))

(defun jetpacs-shell-refresh (&rest _)
  "Bypass app caches (via `jetpacs-shell-refresh-hook') and push.
Safe on any hook: extra arguments are ignored."
  (run-hooks 'jetpacs-shell-refresh-hook)
  (jetpacs-shell-push))

;; ─── Host ends of the core seams ─────────────────────────────────────────────

;; A tap that mutates a buffer re-pushes the showing surface through here.
(setq jetpacs-buffer-refresh-function #'jetpacs-shell-push)

;; A failed form submit (inline errors) or a date-picker update re-renders
;; the showing surface through here (jetpacs-surfaces' form layer).
(defvar jetpacs-form-refresh-function)
(setq jetpacs-form-refresh-function #'jetpacs-shell-push)

;; Settings feedback lands in the snackbar; setting changes re-render.
(defvar jetpacs-settings-notify-function)
(defvar jetpacs-settings-refresh-function)
(with-eval-after-load 'jetpacs-settings
  (setq jetpacs-settings-notify-function #'jetpacs-shell-notify
        jetpacs-settings-refresh-function #'jetpacs-shell-push))

;; ─── Wire actions ────────────────────────────────────────────────────────────

(jetpacs-defaction "view.switched"
  (lambda (args _)
    ;; The companion already flipped the view locally — this event only
    ;; synchronizes Emacs's notion of "where the user is" and refreshes
    ;; the (possibly stale) cached views in the background.
    (let ((view (alist-get 'view args)))
      (when view
        (unless (jetpacs-shell--overlay-p view)
          (run-hook-with-args 'jetpacs-shell-view-switched-hook view)
          (when (jetpacs-shell--tab-p view)
            (setq jetpacs-shell--current-tab view)))
        ;; No :switch-to — never yank the user during a background refresh.
        (jetpacs-shell-push)))))

(jetpacs-defaction "nav.tab"
  ;; Legacy round-trip navigation; superseded by the view.switch builtin
  ;; but kept so stale cached UIs from older pushes still work.
  (lambda (args _)
    (let ((tab (alist-get 'tab args)))
      (jetpacs-shell-push tab))))

(jetpacs-defaction "dashboard.refresh"
  ;; Manual refresh is an explicit "give me fresh data": bypass the memos.
  (lambda (_ _) (jetpacs-shell-refresh)))

(jetpacs-defaction "dialog.dismiss"
  (lambda (_ _) (jetpacs-dismiss-dialog)))

;; The shell's own drawer entry: an explicit data refresh.
(jetpacs-shell-add-drawer-item
 70 (lambda ()
      (jetpacs-drawer-item "refresh" "Refresh data"
                        (jetpacs-action "dashboard.refresh" :when-offline "drop"))))

;; ─── Stock settings screen ───────────────────────────────────────────────────

;; The foundation provides the settings screen itself, so a Tier 1 only
;; registers content: defcustom sections through
;; `jetpacs-settings-register-section' and satellite screens through
;; `jetpacs-settings-add-link' — both appear here with no further wiring,
;; and the bare companion has a working Settings screen before any app
;; loads.  Register sections under `with-jetpacs-owner' and they show only
;; while that app is current (once a second app exists).
;;
;; An app that needs a richer screen defines its own
;; \"<appid>.settings\" view splicing `jetpacs-settings-sections' at the
;; end of its own scrollable body; the stock drawer entry resolves to it
;; while that app is current (`jetpacs-shell-resolve-view'), so the one
;; Settings affordance reaches the right screen in every app.  Do NOT
;; redefine the stock \"settings\" view by name — with several apps
;; loaded the last one would hijack the screen for all of them.

(declare-function jetpacs-settings-sections "jetpacs-settings")
(declare-function jetpacs-settings-register-section "jetpacs-settings")

(defun jetpacs-shell-settings-body ()
  "Every registered settings section and satellite link, as one body.
The stock \"settings\" view renders exactly this.  It is a WHOLE
scrollable body (one lazy column): an app replacing the view either
uses it as its entire body, or — when it has controls of its own —
splices `jetpacs-settings-sections' into its own lazy column instead.
Never nest this node inside another scroll container."
  (apply #'jetpacs-lazy-column (jetpacs-settings-sections)))

(defun jetpacs-shell--settings-view (snackbar)
  "The stock settings screen (see `jetpacs-shell-settings-body')."
  (jetpacs-shell-nav-view "Emacs Settings" (jetpacs-shell-settings-body)
                       :snackbar snackbar))

(defun jetpacs-shell--build-features-row ()
  "The Emacs build-feature matrix as a read-only settings row.
The user-visible doctor line for `jetpacs-build-features': every known
optional build feature, check when this Emacs binary has it, dash when
it doesn't.  Informational only — nothing is settable here."
  (jetpacs-column
   (jetpacs-text "Emacs build features" 'label)
   (jetpacs-text
    (mapconcat (lambda (probe)
                 (format "%s %s" (car probe)
                         (if (jetpacs-feature-p (car probe)) "✓" "—")))
               jetpacs--build-feature-probes "   ")
    'caption)))

(with-eval-after-load 'jetpacs-settings
  ;; The foundation's own knobs, so the stock screen is never empty and
  ;; the theme mirror / dialog style are discoverable without docs.
  ;; Entries degrade per-symbol: a setup that never loads a module shows
  ;; "not loaded yet" for its knob instead of losing the section.
  (jetpacs-settings-register-section
   "Bridge"
   '((jetpacs-theme-mode :label "Companion theme")
     (jetpacs-dialog-style :label "Dialog style")
     (jetpacs-reconnect :label "Auto-reconnect")
     (jetpacs-build-features :render jetpacs-shell--build-features-row)))
  (jetpacs-shell-define-view "settings" :builder #'jetpacs-shell--settings-view)
  ;; Two explicit settings domains. Jetpacs Settings is companion-local and
  ;; always works offline; Emacs Settings resolves through the current Tier 1
  ;; so its own defcustom-backed preferences remain part of that screen.
  (jetpacs-shell-add-drawer-item
   59 (lambda ()
        (jetpacs-drawer-item "settings" "Jetpacs Settings"
                          (jetpacs-native-settings-action))))
  (jetpacs-shell-add-drawer-item
   60 (lambda ()
        (jetpacs-drawer-item "tune" "Emacs Settings"
                          (jetpacs-shell-switch-view
                           (jetpacs-shell-resolve-view "settings"))))))

;; ─── Lifecycle pushes ────────────────────────────────────────────────────────

;; After (re)connect, push so the app never shows a stale screen from a
;; previous Emacs session. Depth 10: after the revision snapshot has been
;; absorbed (-50 in jetpacs-surfaces) and any notification re-asserts (0).
(add-hook 'jetpacs-connected-hook
          (lambda (_welcome) (jetpacs-shell-push))
          10)

;; After a replay, queued taps have just mutated state — the cached views
;; on the phone are now behind reality.
(add-hook 'jetpacs-queue-drained-hook #'jetpacs-shell-refresh)

(provide 'jetpacs-shell)
;;; jetpacs-shell.el ends here
