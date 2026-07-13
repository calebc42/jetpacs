# API stability — what a Tier 1 can depend on

This document is the contract between the core (`jetpacs-core.el`) and a
third-party Tier 1. Everything listed here is **public and stable**:
within a major version of `jetpacs-api-version` it will not be removed or
change signature incompatibly. Everything else is internal.

- **`jetpacs-api-version`** (a defconst in `jetpacs.el`) is the semver of this
  surface. Check it: `(version<= "1.0.0" jetpacs-api-version)`.
- **The wire/vocabulary version is `jetpacs-protocol-version`** (the SPEC
  number, the envelope `v`) — a *separate* number. Node-vocabulary
  additions are negotiated per-connection (see `jetpacs-node-supported-p`),
  not gated on this.

> **Note on `1.3.0`.** That version exposes *two* independently landed
> additive batches under one number — owner-scoped reminders and the
> foundation-root invariants — so `(version<= "1.3.0" …)` cannot tell them
> apart. Policy going forward: **one minor bump per independently landed API
> batch** (not per individual addition). `1.4.0` opens the binding-layer track
> (the machine-readable wire contract in `contract.json`, and the promoted
> shell/files/action seams below).

## The two rules

1. **`--` means internal.** Any symbol with a double dash after the
   package prefix (`jetpacs--node`, `jetpacs-shell--schedule-repush`,
   `jetpacs-lint--walk`) is private: no stability promise, may change or
   vanish in any release. Do not call it from a Tier 1. If you find
   yourself needing one, that is a bug report ("promote X to public"), not
   a dependency.
2. **Deprecation is gradual.** A public symbol is never removed abruptly:
   it is first marked with `make-obsolete` (which warns at byte-compile),
   survives at least one minor release, and is only removed on a major
   bump. A Tier 1 that compiles cleanly on version N keeps working through
   all of N.x.

## The public surface

### Widget constructors (`jetpacs-widgets.el`)

The node vocabulary. Wire shapes are pinned by `test/widgets.golden`;
the authoring reference is [WIDGETS.md](WIDGETS.md).

Content: `jetpacs-text` `jetpacs-markup` `jetpacs-rich-text` `jetpacs-span`
`jetpacs-icon` `jetpacs-image` `jetpacs-date-stamp` `jetpacs-divider`
`jetpacs-section-header` `jetpacs-empty-state` `jetpacs-progress`
`jetpacs-month-abbrev` (since 1.4.0: the 1–12 → abbrev helper behind
`jetpacs-date-stamp`).

Layout: `jetpacs-row` `jetpacs-flow-row` `jetpacs-scroll-row` `jetpacs-column`
`jetpacs-scroll-column` `jetpacs-box` `jetpacs-surface` `jetpacs-card` `jetpacs-border`
`jetpacs-lazy-column` `jetpacs-scroll-here` `jetpacs-spacer` `jetpacs-collapsible`
`jetpacs-reorderable-list` `jetpacs-table` `jetpacs-table-row` `jetpacs-table-rule`
`jetpacs-table-cell` `jetpacs-swipe-action` `jetpacs-tabs` `jetpacs-tab-item`.
(`row`/`column`/`flow-row` take trailing `:spacing`/`:align`/`:scroll`
keywords; `box`/`surface`/`card` take
`:width`/`:height`/`:fill-fraction`/`:border`; `card` takes
`:swipe-start`/`:swipe-end`.)

Input: `jetpacs-button` `jetpacs-icon-button` `jetpacs-chip` `jetpacs-assist-chip`
`jetpacs-menu` `jetpacs-menu-item` `jetpacs-checkbox` `jetpacs-switch` `jetpacs-slider`
`jetpacs-text-input` `jetpacs-enum-list` `jetpacs-date-button` `jetpacs-time-button`
`jetpacs-editor` `jetpacs-toolbar-item`.

Visualization: `jetpacs-chart` `jetpacs-chart-series` `jetpacs-canvas`
`jetpacs-draw-line` `jetpacs-draw-rect` `jetpacs-draw-circle` `jetpacs-draw-path`
`jetpacs-draw-text` `jetpacs-month-grid`.

Chrome: `jetpacs-scaffold` `jetpacs-top-bar` `jetpacs-bottom-bar` `jetpacs-nav-item`
`jetpacs-drawer` `jetpacs-drawer-item` `jetpacs-fab` `jetpacs-snackbar-action`.
(`nav-item`/`drawer-item`/`icon`/`icon-button` take `:badge`;
`text-input` takes `:keyboard`; `jetpacs-send-dialog` takes an optional
STYLE / `jetpacs-dialog-style`.)

Actions: `jetpacs-action` `jetpacs-clipboard-action`.

Home-surface composition: `jetpacs-widget-item` `jetpacs-widget-divider`
`jetpacs-tile`.

### Session & negotiation (`jetpacs.el`)

`jetpacs-connected-p` `jetpacs-granted-p` `jetpacs-node-supported-p`
`jetpacs-device-caps` `jetpacs-device-cap-p` `jetpacs-device-can-p`
`jetpacs-capability-invoke` — plus the customization vars `jetpacs-host`
`jetpacs-port` `jetpacs-auth-token` `jetpacs-wants`.

### Actions & state (`jetpacs-surfaces.el`)

`jetpacs-defaction` `jetpacs-on-state-change` `jetpacs-on-state-change-clear`
`jetpacs-ui-state` `jetpacs-ui-state-put` `jetpacs-ui-state-clear`
`jetpacs-ui-state-list` `jetpacs-in-action-p` (since 1.4.0: coerce a
multi-select value to a list of strings; report whether code runs inside an
action handler) `jetpacs-surface-push` `jetpacs-surface-remove`.

### Multi-tenant ownership (`jetpacs-surfaces.el`, `jetpacs-apps.el`)

`with-jetpacs-owner` `jetpacs-app-unregister` — plus the customization var
`jetpacs-strict-namespaces`. Wrap a Tier 1's registrations in
`(with-jetpacs-owner "my-app" …)` so its actions/views/settings are
attributed to it; then a cross-owner name collision warns (or errors
under `jetpacs-strict-namespaces`), and `jetpacs-app-unregister` tears the app
down cleanly for live reload or uninstall. Since 1.2.0 ownership also
*scopes*: owned drawer items, top actions, and settings sections/links
render only while their app is current (see BUILDING-TIER1 §7), and app
view names are namespaced `"<appid>.<view>"`.

### The shell / app seams

App scaffold (`jetpacs-shell.el`): `jetpacs-shell-define-view`
`jetpacs-shell-tab-view` `jetpacs-shell-nav-view` `jetpacs-shell-push`
`jetpacs-shell-notify` `jetpacs-shell-add-drawer-item`
`jetpacs-shell-add-top-action` `jetpacs-shell-default-fab-function`
`jetpacs-shell-settings-body` (since 1.1.0: the stock "settings" view's
whole scrollable body — an app with controls of its own defines a
`"<appid>.settings"` view and splices `jetpacs-settings-sections` into its
own lazy column instead), `jetpacs-shell-resolve-view` (since 1.2.0: a
logical core view name through the per-app override resolver — the
stock Settings drawer entry targets `(jetpacs-shell-resolve-view
"settings")`), and the hooks `jetpacs-shell-view-switched-hook`
`jetpacs-shell-refresh-hook` `jetpacs-shell-after-push-hook`.  Tab access
(since 1.4.0): `jetpacs-shell-current-tab` reads the active tab and
`jetpacs-shell-set-current-tab` switches to a registered tab through
`jetpacs-shell-push`.

App identity (`jetpacs-apps.el`): `jetpacs-defapp` `jetpacs-apps-remove`
`jetpacs-apps-current` `jetpacs-apps-current-p` `jetpacs-apps-set-default-fab`
(since 1.2.0: the current-app predicate for gating dynamic
registrations, and the per-app default FAB that replaces setting
`jetpacs-shell-default-fab-function` directly — the direct set still works
but leaks the FAB onto every coexisting app's views).

Buffer skins (`jetpacs-buffer.el`): `jetpacs-render-buffer-register`.

Tablist skins (`jetpacs-tablist.el`): the `jetpacs-tablist-header-functions`
`jetpacs-tablist-row-functions` `jetpacs-tablist-filter-functions` alists.

Files/editor (`jetpacs-files.el`): `jetpacs-files-editor-body-functions`
`jetpacs-files-editor-actions-functions` `jetpacs-files-editor-toolbar-function`
`jetpacs-files-open-hook` `jetpacs-files-after-save-hook` (since 1.4.0:
`jetpacs-files-open` opens a readable in-root path in the editor, and
`jetpacs-files-current-file` reads the currently open path).

Settings (`jetpacs-settings.el`): `jetpacs-settings-register-section`
`jetpacs-settings-remove-section` `jetpacs-settings-after-set-hook`
`jetpacs-settings-add-link` `jetpacs-settings-add-native-link`
`jetpacs-settings-sections` (since 1.1.0:
the flat node list an app splices into its own body when it replaces
the stock "settings" view), plus `jetpacs-native-settings-action`
from `jetpacs-widgets.el`. Native links render first and must remain
useful offline; regular links render under Emacs Settings. Registered
sections and links render on the foundation's stock "settings" view
without further wiring.

### Validation (`jetpacs-lint.el`)

`jetpacs-lint-spec` `jetpacs-render-to-json` (see Phase B).

## Anything not listed here

Internal, even without a `--`. If a Tier 1 needs it, promote it here
first (that is the review gate for widening the surface). The
byte-compile of `test/core-load-test.el` plus a stability test assert
that every symbol named above is bound.
