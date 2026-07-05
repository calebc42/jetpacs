;;; eabp-shell.el --- Multi-view app shell for EABP -*- lexical-binding: t; -*-

;; The app-agnostic host: a registry of named views pushed together as one
;; multi-view surface (`app:dashboard'), with companion-local tab switching
;; (the `view.switch' builtin), a snackbar queue, drawer/bottom-bar/top-bar
;; chrome helpers, and the refresh/navigation actions every view shares.
;;
;; Tier 1 apps do not build a shell — they register views into this one:
;;
;;   (eabp-shell-define-view "agenda"
;;     :builder #'my-agenda-view
;;     :tab '(:icon "event" :label "Agenda") :order 10)
;;
;; A builder is a function of one argument (the snackbar text to attach, or
;; nil) returning a full scaffold view alist — use `eabp-shell-tab-view' /
;; `eabp-shell-nav-view' for the standard chrome.  Views registered with
;; :tab appear in the bottom bar and become the current tab when the user
;; lands on them; :when gates inclusion per push (e.g. an editor view that
;; only exists while a file is open); :overlay marks a view that, while its
;; predicate holds, is the active view without being a tab (e.g. a detail
;; drill-in).
;;
;; This module also owns the host ends of the core seams: it points the
;; Tier 0 buffer renderer's `eabp-buffer-refresh-function' at the shell
;; push, wires `eabp-settings' feedback to the snackbar, pushes on connect
;; and after an offline-queue drain, and handles the `view.switched',
;; `nav.tab', and `dashboard.refresh' wire actions.  Apps that need to run
;; on those moments register on the hooks below instead of redefining them.

;;; Code:

(require 'cl-lib)
(require 'eabp)
(require 'eabp-widgets)
(require 'eabp-surfaces)
(require 'eabp-buffer)

;; ─── View registry ───────────────────────────────────────────────────────────

(defvar eabp-shell-views nil
  "Ordered list of (NAME . PLIST) registered shell views.
Managed by `eabp-shell-define-view'; kept sorted by :order.")

(cl-defun eabp-shell-define-view (name &key builder tab when overlay (order 100))
  "Register (or replace) shell view NAME.
BUILDER is a function of one argument (snackbar text or nil) returning
the view's scaffold alist.  TAB, when non-nil, is a plist (:icon :label)
placing the view in the bottom bar; landing on a tab view makes it the
current tab.  WHEN, when non-nil, is a predicate gating the view's
inclusion in each push.  OVERLAY, when non-nil, is a predicate: while it
holds, this view is the active one shown on a background push (a detail
drill-in over the current tab).  ORDER sorts views and bottom-bar items."
  (setq eabp-shell-views
        (sort (cons (cons name (list :builder builder :tab tab :when when
                                     :overlay overlay :order order))
                    (assoc-delete-all name eabp-shell-views))
              (lambda (a b)
                (< (plist-get (cdr a) :order) (plist-get (cdr b) :order)))))
  (eabp-shell--schedule-repush)
  name)

(defun eabp-shell-remove-view (name)
  "Unregister shell view NAME."
  (setq eabp-shell-views (assoc-delete-all name eabp-shell-views))
  (eabp-shell--schedule-repush))

(defvar eabp-shell-view-filter-function nil
  "When non-nil, a predicate on a view NAME gating inclusion per push.
The app layer (eabp-apps.el) installs the current-app filter here; nil
means every registered view shows — the single-app default.")

(defun eabp-shell--view-filtered-p (name)
  "Non-nil when NAME passes `eabp-shell-view-filter-function'.
A filter that signals passes the view — a broken app layer must not
blank the phone."
  (or (null eabp-shell-view-filter-function)
      (condition-case nil (funcall eabp-shell-view-filter-function name)
        (error t))))

(defun eabp-shell--visible-views ()
  "The registry entries included in this push (:when + app filter honoured).
A pred that signals counts as nil — a broken predicate must cost its
view, not the push."
  (cl-remove-if-not (lambda (entry)
                      (let ((pred (plist-get (cdr entry) :when)))
                        (and (eabp-shell--view-filtered-p (car entry))
                             (or (null pred)
                                 (condition-case nil (funcall pred)
                                   (error nil))))))
                    eabp-shell-views))

(defun eabp-shell--tab-p (name)
  "Non-nil when view NAME is registered as a bottom-bar tab."
  (plist-get (cdr (assoc name eabp-shell-views)) :tab))

(defun eabp-shell--overlay-p (name)
  "Non-nil when view NAME is registered as an overlay."
  (plist-get (cdr (assoc name eabp-shell-views)) :overlay))

;; ─── Shell state ─────────────────────────────────────────────────────────────

(defvar eabp-shell--current-tab nil
  "Name of the current bottom-bar tab, or nil for the first registered tab.")

(defvar eabp-shell--snackbar nil
  "Text queued by `eabp-shell-notify' for the next push, or nil.")

(defun eabp-shell-current-tab ()
  "The current tab name (the first included tab when none is set)."
  (or eabp-shell--current-tab
      (car (cl-find-if (lambda (e)
                         (and (plist-get (cdr e) :tab)
                              (eabp-shell--view-filtered-p (car e))))
                       eabp-shell-views))))

(defun eabp-shell--active-view ()
  "The view a push should land on: a firing overlay, else the current tab."
  (or (car (cl-find-if (lambda (e)
                         (let ((pred (plist-get (cdr e) :overlay)))
                           (and pred
                                (eabp-shell--view-filtered-p (car e))
                                (condition-case nil (funcall pred)
                                  (error nil)))))
                       eabp-shell-views))
      (eabp-shell-current-tab)))

(defun eabp-shell-notify (text)
  "Queue TEXT to show as a snackbar on the next shell push.
Note: the companion re-shows a snackbar only when the text *changes*,
so two identical messages back-to-back display once."
  (setq eabp-shell--snackbar text))

;; ─── Hooks (the app seams) ───────────────────────────────────────────────────

(defvar eabp-shell-view-switched-hook nil
  "Hook run with the view NAME the user is switching to.
Runs before the shell's own tab bookkeeping, for both companion-local
switches (`view.switched') and Emacs-driven tab pushes — but never for
overlay views.  Modules reset their drill-in state here.")

(defvar eabp-shell-refresh-hook nil
  "Hook run before a push that must bypass caches.
Runs on the explicit `dashboard.refresh' action and after an offline
queue drain; apps drop their memo caches here.")

(defvar eabp-shell-after-push-hook nil
  "Hook run after each successful shell push.
For cheap piggybacked sends (home-screen widgets, reminder syncs); keep
handlers memo-guarded so unchanged data sends nothing.")

;; ─── Chrome: drawer, bottom bar, top bar ─────────────────────────────────────

(defvar eabp-shell-drawer-header "Glasspane"
  "Text rendered at the top of the app drawer.")

(defvar eabp-shell-drawer-items nil
  "Ordered list of (ORDER . BUILDER) drawer entries.
BUILDER is a function of no arguments returning an `eabp-drawer-item'.")

(defun eabp-shell-add-drawer-item (order builder)
  "Add BUILDER (a nullary function returning a drawer item) at ORDER."
  (setq eabp-shell-drawer-items
        (sort (cons (cons order builder) eabp-shell-drawer-items)
              (lambda (a b) (< (car a) (car b)))))
  (eabp-shell--schedule-repush))

(defvar eabp-shell-top-actions nil
  "Ordered list of (ORDER . BUILDER) default top-bar trailing actions.
BUILDER is a function of no arguments returning an icon-button node.")

(defun eabp-shell-add-top-action (order builder)
  "Add BUILDER (a nullary function returning an icon button) at ORDER."
  (setq eabp-shell-top-actions
        (sort (cons (cons order builder) eabp-shell-top-actions)
              (lambda (a b) (< (car a) (car b)))))
  (eabp-shell--schedule-repush))

(defvar eabp-shell-default-fab-function nil
  "Function of a view name returning that view's default FAB node, or nil.
Apps set this to offer a global affordance (e.g. a capture button) on
views that don't define their own.")

(defun eabp-shell-default-fab (name)
  "The app-provided default FAB for view NAME, or nil."
  (when (functionp eabp-shell-default-fab-function)
    (funcall eabp-shell-default-fab-function name)))

(defun eabp-shell-switch-view (view)
  "Action descriptor for the companion-local `view.switch' builtin."
  `((builtin . "view.switch") (view . ,view)))

(defun eabp-shell-drawer ()
  "The navigation drawer built from `eabp-shell-drawer-items'.
A builder returning nil contributes nothing — conditional entries
\(e.g. the multi-app \"Apps\" item) just return nil when hidden."
  (eabp-drawer (delq nil (mapcar (lambda (e) (funcall (cdr e)))
                                 eabp-shell-drawer-items))
               :header eabp-shell-drawer-header))

(defun eabp-shell-bottom-bar (selected)
  "The bottom bar of the included :tab views, with SELECTED highlighted.
Honours the app filter, so each app shows its own tabs."
  (eabp-bottom-bar
   (cl-loop for (name . plist) in eabp-shell-views
            for tab = (plist-get plist :tab)
            when (and tab (eabp-shell--view-filtered-p name))
            collect (eabp-nav-item (plist-get tab :icon)
                                   (plist-get tab :label)
                                   (eabp-shell-switch-view name)
                                   :selected (equal name selected)))))

(cl-defun eabp-shell-default-top-bar (title &key extra-actions)
  "The standard top bar: TITLE plus the registered trailing actions.
EXTRA-ACTIONS are prepended (view-specific buttons before the globals)."
  (eabp-top-bar title
                :actions (append extra-actions
                                 (mapcar (lambda (e) (funcall (cdr e)))
                                         eabp-shell-top-actions))))

(cl-defun eabp-shell-tab-view (name body &key top-bar (fab nil fab-given) snackbar)
  "A standard tab view: drawer, bottom bar, pull-to-refresh, default chrome.
NAME selects the bottom-bar highlight; BODY is the content node.  TOP-BAR
defaults to `eabp-shell-default-top-bar' on the capitalized name.  When FAB
is not given at all, the app's `eabp-shell-default-fab' is used; pass an
explicit nil to render no FAB."
  `((children . ,(vector
                  (eabp-scaffold
                   :top-bar (or top-bar (eabp-shell-default-top-bar (capitalize name)))
                   :body body
                   :fab (if fab-given fab (eabp-shell-default-fab name))
                   :bottom-bar (eabp-shell-bottom-bar name)
                   :drawer (eabp-shell-drawer)
                   :snackbar snackbar
                   ;; Tab views support pull-to-refresh; navigation/detail
                   ;; views don't (a stray pull mustn't rebuild them).
                   :on-refresh (eabp-action "dashboard.refresh"
                                            :when-offline "drop"))))))

(cl-defun eabp-shell-nav-view (title body &key back-to nav-action actions
                                     fab snackbar bottom-bar floating-toolbar)
  "A navigation view: back arrow in the top bar, no tabs or drawer.
BACK-TO names the view the arrow switches to (default: the current tab)
as a companion-local switch; NAV-ACTION overrides it with an explicit
action descriptor.  ACTIONS are trailing top-bar buttons."
  `((children . ,(vector
                  (eabp-scaffold
                   :top-bar (eabp-top-bar title
                                          :nav-icon "arrow_back"
                                          :nav-action
                                          (or nav-action
                                              (eabp-shell-switch-view
                                               (or back-to (eabp-shell-current-tab))))
                                          :actions actions)
                   :body body
                   :fab fab
                   :snackbar snackbar
                   :bottom-bar bottom-bar
                   :floating-toolbar floating-toolbar)))))

;; ─── The push ────────────────────────────────────────────────────────────────

(defvar eabp-shell-surface-id "app:dashboard"
  "Surface id the shell pushes to.  One multi-view surface: the companion
switches views locally, so navigation never waits on Emacs.")

(defun eabp-shell--build-view (name plist snackbar)
  "Build view NAME from its :builder in PLIST, degrading errors in place.
A broken builder must cost its own screen, not the whole push — with a
Tier 1 being live-coded against a running session, the rest of the app
keeps updating and the broken view *shows* its error."
  (condition-case err
      (funcall (plist-get plist :builder) snackbar)
    (error
     (eabp-shell-nav-view
      (capitalize name)
      (eabp-column
       (eabp-text (format "Error building view \"%s\"" name) 'title)
       (eabp-text (error-message-string err) 'body))
      :snackbar snackbar))))

(defvar eabp-shell--repush-timer nil)

(defun eabp-shell--schedule-repush ()
  "Debounced push after a registry mutation on a live session.
Loading a Tier 1 file registers views/chrome in a burst; one idle push
after the burst means `eval-buffer' (or `load') against a connected
phone updates the app with no explicit `eabp-shell-push' — the
live-coding loop.  A no-op while disconnected: the on-connect push will
carry the registrations."
  (when (and (eabp-connected-p) (not (timerp eabp-shell--repush-timer)))
    (setq eabp-shell--repush-timer
          (run-with-idle-timer 0.5 nil
                               (lambda ()
                                 (setq eabp-shell--repush-timer nil)
                                 (eabp-shell-push))))))

(cl-defun eabp-shell-push (&optional tab &key switch-to)
  "Push every registered view as one multi-view surface.
TAB switches the logical tab before building.  SWITCH-TO additionally
forces the companion onto that view (used when a push *is* the
navigation, e.g. opening a detail); plain background refreshes never
yank the user off whatever they're looking at."
  ;; Any explicit push satisfies a pending registry repush.
  (when (timerp eabp-shell--repush-timer)
    (cancel-timer eabp-shell--repush-timer)
    (setq eabp-shell--repush-timer nil))
  (when tab
    (unless (equal tab eabp-shell--current-tab)
      (run-hook-with-args 'eabp-shell-view-switched-hook tab))
    (setq eabp-shell--current-tab tab))
  (condition-case err
      (let* ((active (eabp-shell--active-view))
             (target (or switch-to tab))
             ;; A navigation push lands the user on TARGET, so feedback
             ;; (e.g. "Saved init.el") must attach there, not to the view
             ;; they're leaving.
             (snack-view (or target active))
             (snackbar (prog1 eabp-shell--snackbar
                         (setq eabp-shell--snackbar nil)))
             (views (mapcar
                     (lambda (entry)
                       (let ((name (car entry)))
                         (cons (intern name)
                               (eabp-shell--build-view
                                name (cdr entry)
                                (when (equal name snack-view)
                                  snackbar)))))
                     (eabp-shell--visible-views))))
        (eabp-surface-push
         eabp-shell-surface-id
         `((views . ,views)
           (initial_view . ,active))
         nil nil
         ;; Force the companion onto a view only when this push *is* a
         ;; navigation — see SWITCH-TO above.
         target)
        (run-hooks 'eabp-shell-after-push-hook))
    (error
     (message "EABP shell push failed: %s" (error-message-string err)))))

(defun eabp-shell-refresh (&rest _)
  "Bypass app caches (via `eabp-shell-refresh-hook') and push.
Safe on any hook: extra arguments are ignored."
  (run-hooks 'eabp-shell-refresh-hook)
  (eabp-shell-push))

;; ─── Host ends of the core seams ─────────────────────────────────────────────

;; A tap that mutates a buffer re-pushes the showing surface through here.
(setq eabp-buffer-refresh-function #'eabp-shell-push)

;; Settings feedback lands in the snackbar; setting changes re-render.
(defvar eabp-settings-notify-function)
(defvar eabp-settings-refresh-function)
(with-eval-after-load 'eabp-settings
  (setq eabp-settings-notify-function #'eabp-shell-notify
        eabp-settings-refresh-function #'eabp-shell-push))

;; ─── Wire actions ────────────────────────────────────────────────────────────

(eabp-defaction "view.switched"
  (lambda (args _)
    ;; The companion already flipped the view locally — this event only
    ;; synchronizes Emacs's notion of "where the user is" and refreshes
    ;; the (possibly stale) cached views in the background.
    (let ((view (alist-get 'view args)))
      (when view
        (unless (eabp-shell--overlay-p view)
          (run-hook-with-args 'eabp-shell-view-switched-hook view)
          (when (eabp-shell--tab-p view)
            (setq eabp-shell--current-tab view)))
        ;; No :switch-to — never yank the user during a background refresh.
        (eabp-shell-push)))))

(eabp-defaction "nav.tab"
  ;; Legacy round-trip navigation; superseded by the view.switch builtin
  ;; but kept so stale cached UIs from older pushes still work.
  (lambda (args _)
    (let ((tab (alist-get 'tab args)))
      (eabp-shell-push tab))))

(eabp-defaction "dashboard.refresh"
  ;; Manual refresh is an explicit "give me fresh data": bypass the memos.
  (lambda (_ _) (eabp-shell-refresh)))

(eabp-defaction "dialog.dismiss"
  (lambda (_ _) (eabp-dismiss-dialog)))

;; The shell's own drawer entry: an explicit data refresh.
(eabp-shell-add-drawer-item
 70 (lambda ()
      (eabp-drawer-item "refresh" "Refresh data"
                        (eabp-action "dashboard.refresh" :when-offline "drop"))))

;; ─── Lifecycle pushes ────────────────────────────────────────────────────────

;; After (re)connect, push so the app never shows a stale screen from a
;; previous Emacs session. Depth 10: after the revision snapshot has been
;; absorbed (-50 in eabp-surfaces) and any notification re-asserts (0).
(add-hook 'eabp-connected-hook
          (lambda (_welcome) (eabp-shell-push))
          10)

;; After a replay, queued taps have just mutated state — the cached views
;; on the phone are now behind reality.
(add-hook 'eabp-queue-drained-hook #'eabp-shell-refresh)

(provide 'eabp-shell)
;;; eabp-shell.el ends here
