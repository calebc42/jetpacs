;;; jetpacs-shell.el --- Multi-view app shell for Jetpacs -*- lexical-binding: t; -*-

;; The app-agnostic host: a registry of named views pushed together as one
;; multi-view surface (`app:dashboard'), with companion-local tab switching
;; (the `view.switch' builtin), a snackbar queue, drawer/bottom-bar/top-bar
;; chrome helpers, and the refresh/navigation actions every view shares.
;;
;; Tier 1 apps do not build a shell — they register views into this one:
;;
;;   (jetpacs-shell-define-view "agenda"
;;     :builder #'my-agenda-view
;;     :tab '(:icon "event" :label "Agenda") :order 10)
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

;; ─── View registry ───────────────────────────────────────────────────────────

(defvar jetpacs-shell-views nil
  "Ordered list of (NAME . PLIST) registered shell views.
Managed by `jetpacs-shell-define-view'; kept sorted by :order.")

(cl-defun jetpacs-shell-define-view (name &key builder tab when overlay (order 100))
  "Register (or replace) shell view NAME.
BUILDER is a function of one argument (snackbar text or nil) returning
the view's scaffold alist.  TAB, when non-nil, is a plist
\(:icon :label :badge) placing the view in the bottom bar; landing on a
tab view makes it the current tab.  :badge, when non-nil, is a nullary
function called on every push whose result overlays the tab icon — a
count (capped at 99+ on-device), \"\" for a bare dot, or nil for none;
errors and nil render no badge, so a badge can never break the push.
WHEN, when non-nil, is a predicate gating the view's inclusion in each
push.  OVERLAY, when non-nil, is a predicate: while it holds, this view
is the active one shown on a background push (a detail drill-in over
the current tab).  ORDER sorts views and bottom-bar items."
  (setq jetpacs-shell-views
        (sort (cons (cons name (list :builder builder :tab tab :when when
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
  "The current tab name (the first included tab when none is set)."
  (or jetpacs-shell--current-tab
      (car (cl-find-if (lambda (e)
                         (and (plist-get (cdr e) :tab)
                              (jetpacs-shell--view-filtered-p (car e))))
                       jetpacs-shell-views))))

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

;; ─── Hooks (the app seams) ───────────────────────────────────────────────────

(defvar jetpacs-shell-view-switched-hook nil
  "Hook run with the view NAME the user is switching to.
Runs before the shell's own tab bookkeeping, for both companion-local
switches (`view.switched') and Emacs-driven tab pushes — but never for
overlay views.  Modules reset their drill-in state here.")

(defvar jetpacs-shell-refresh-hook nil
  "Hook run before a push that must bypass caches.
Runs on the explicit `dashboard.refresh' action and after an offline
queue drain; apps drop their memo caches here.")

(defvar jetpacs-shell-after-push-hook nil
  "Hook run after each successful shell push.
For cheap piggybacked sends (home-screen widgets, reminder syncs); keep
handlers memo-guarded so unchanged data sends nothing.")

;; ─── Chrome: drawer, bottom bar, top bar ─────────────────────────────────────

(defvar jetpacs-shell-drawer-header "Glasspane"
  "Text rendered at the top of the app drawer.")

(defvar jetpacs-shell-drawer-items nil
  "Ordered list of (ORDER . BUILDER) drawer entries.
BUILDER is a function of no arguments returning an `jetpacs-drawer-item'.")

(defun jetpacs-shell-add-drawer-item (order builder)
  "Add BUILDER (a nullary function returning a drawer item) at ORDER."
  (setq jetpacs-shell-drawer-items
        (sort (cons (cons order builder) jetpacs-shell-drawer-items)
              (lambda (a b) (< (car a) (car b)))))
  (jetpacs-shell--schedule-repush))

(defvar jetpacs-shell-top-actions nil
  "Ordered list of (ORDER . BUILDER) default top-bar trailing actions.
BUILDER is a function of no arguments returning an icon-button node.")

(defun jetpacs-shell-add-top-action (order builder)
  "Add BUILDER (a nullary function returning an icon button) at ORDER."
  (setq jetpacs-shell-top-actions
        (sort (cons (cons order builder) jetpacs-shell-top-actions)
              (lambda (a b) (< (car a) (car b)))))
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

(defun jetpacs-shell-drawer ()
  "The navigation drawer built from `jetpacs-shell-drawer-items'.
A builder returning nil contributes nothing — conditional entries
\(e.g. the multi-app \"Apps\" item) just return nil when hidden."
  (jetpacs-drawer (delq nil (mapcar (lambda (e) (funcall (cdr e)))
                                 jetpacs-shell-drawer-items))
               :header jetpacs-shell-drawer-header))

(defun jetpacs-shell-bottom-bar (selected)
  "The bottom bar of the included :tab views, with SELECTED highlighted.
Honours the app filter, so each app shows its own tabs."
  (jetpacs-bottom-bar
   (cl-loop for (name . plist) in jetpacs-shell-views
            for tab = (plist-get plist :tab)
            when (and tab (jetpacs-shell--view-filtered-p name))
            collect (jetpacs-nav-item (plist-get tab :icon)
                                   (plist-get tab :label)
                                   (jetpacs-shell-switch-view name)
                                   :selected (equal name selected)
                                   :badge (when-let ((fn (plist-get tab :badge)))
                                            (condition-case nil (funcall fn)
                                              (error nil)))))))

(cl-defun jetpacs-shell-default-top-bar (title &key extra-actions)
  "The standard top bar: TITLE plus the registered trailing actions.
EXTRA-ACTIONS are prepended (view-specific buttons before the globals)."
  (jetpacs-top-bar title
                :actions (append extra-actions
                                 (mapcar (lambda (e) (funcall (cdr e)))
                                         jetpacs-shell-top-actions))))

(cl-defun jetpacs-shell-tab-view (name body &key top-bar (fab nil fab-given) snackbar)
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
                   ;; Tab views support pull-to-refresh; navigation/detail
                   ;; views don't (a stray pull mustn't rebuild them).
                   :on-refresh (jetpacs-action "dashboard.refresh"
                                            :when-offline "drop"))))))

(cl-defun jetpacs-shell-nav-view (title body &key back-to nav-action actions
                                     fab snackbar bottom-bar floating-toolbar)
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
  (condition-case err
      (funcall (plist-get plist :builder) snackbar)
    (error
     (jetpacs-shell-nav-view
      (capitalize name)
      (jetpacs-column
       (jetpacs-text (format "Error building view \"%s\"" name) 'title)
       (jetpacs-text (error-message-string err) 'body))
      :snackbar snackbar))))

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
  (when tab
    (unless (equal tab jetpacs-shell--current-tab)
      (run-hook-with-args 'jetpacs-shell-view-switched-hook tab))
    (setq jetpacs-shell--current-tab tab))
  (condition-case err
      (let* ((active (jetpacs-shell--active-view))
             (target (or switch-to tab))
             ;; A navigation push lands the user on TARGET, so feedback
             ;; (e.g. "Saved init.el") must attach there, not to the view
             ;; they're leaving.
             (snack-view (or target active))
             (snackbar (prog1 jetpacs-shell--snackbar
                         (setq jetpacs-shell--snackbar nil)))
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
     (message "Jetpacs shell push failed: %s" (error-message-string err)))))

(defun jetpacs-shell-refresh (&rest _)
  "Bypass app caches (via `jetpacs-shell-refresh-hook') and push.
Safe on any hook: extra arguments are ignored."
  (run-hooks 'jetpacs-shell-refresh-hook)
  (jetpacs-shell-push))

;; ─── Host ends of the core seams ─────────────────────────────────────────────

;; A tap that mutates a buffer re-pushes the showing surface through here.
(setq jetpacs-buffer-refresh-function #'jetpacs-shell-push)

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
