# API stability — what a Tier 1 can depend on

This document is the contract between the core (`eabp-core.el`) and a
third-party Tier 1. Everything listed here is **public and stable**:
within a major version of `eabp-api-version` it will not be removed or
change signature incompatibly. Everything else is internal.

- **`eabp-api-version`** (a defconst in `eabp.el`) is the semver of this
  surface. Check it: `(version<= "1.0.0" eabp-api-version)`.
- **The wire/vocabulary version is `eabp-protocol-version`** (the SPEC
  number, the envelope `v`) — a *separate* number. Node-vocabulary
  additions are negotiated per-connection (see `eabp-node-supported-p`),
  not gated on this.

## The two rules

1. **`--` means internal.** Any symbol with a double dash after the
   package prefix (`eabp--node`, `eabp-shell--schedule-repush`,
   `glasspane-org--query`) is private: no stability promise, may change or
   vanish in any release. Do not call it from a Tier 1. If you find
   yourself needing one, that is a bug report ("promote X to public"), not
   a dependency.
2. **Deprecation is gradual.** A public symbol is never removed abruptly:
   it is first marked with `make-obsolete` (which warns at byte-compile),
   survives at least one minor release, and is only removed on a major
   bump. A Tier 1 that compiles cleanly on version N keeps working through
   all of N.x.

## The public surface

### Widget constructors (`eabp-widgets.el`)

The node vocabulary. Wire shapes are pinned by `test/widgets.golden`.

Content: `eabp-text` `eabp-markup` `eabp-rich-text` `eabp-span`
`eabp-icon` `eabp-image` `eabp-date-stamp` `eabp-divider`
`eabp-section-header` `eabp-empty-state` `eabp-progress`.

Layout: `eabp-row` `eabp-flow-row` `eabp-scroll-row` `eabp-column`
`eabp-scroll-column` `eabp-box` `eabp-surface` `eabp-card`
`eabp-lazy-column` `eabp-scroll-here` `eabp-spacer` `eabp-collapsible`
`eabp-reorderable-list` `eabp-table` `eabp-table-row` `eabp-table-rule`
`eabp-table-cell`.

Input: `eabp-button` `eabp-icon-button` `eabp-chip` `eabp-assist-chip`
`eabp-menu` `eabp-menu-item` `eabp-checkbox` `eabp-switch`
`eabp-text-input` `eabp-enum-list` `eabp-date-button` `eabp-time-button`
`eabp-editor`.

Chrome: `eabp-scaffold` `eabp-top-bar` `eabp-bottom-bar` `eabp-nav-item`
`eabp-drawer` `eabp-drawer-item` `eabp-fab`.

Actions: `eabp-action` `eabp-clipboard-action`.

Home-surface composition: `eabp-widget-item` `eabp-widget-divider`
`eabp-tile`.

### Session & negotiation (`eabp.el`)

`eabp-connected-p` `eabp-granted-p` `eabp-node-supported-p`
`eabp-device-caps` `eabp-device-cap-p` `eabp-device-can-p`
`eabp-capability-invoke` — plus the customization vars `eabp-host`
`eabp-port` `eabp-auth-token` `eabp-wants`.

### Actions & state (`eabp-surfaces.el`)

`eabp-defaction` `eabp-on-state-change` `eabp-ui-state`
`eabp-ui-state-put` `eabp-ui-state-clear` `eabp-surface-push`
`eabp-surface-remove`.

### The shell / app seams

App scaffold (`eabp-shell.el`): `eabp-shell-define-view`
`eabp-shell-tab-view` `eabp-shell-nav-view` `eabp-shell-push`
`eabp-shell-notify` `eabp-shell-add-drawer-item`
`eabp-shell-add-top-action` `eabp-shell-default-fab-function`, and the
hooks `eabp-shell-view-switched-hook` `eabp-shell-refresh-hook`
`eabp-shell-after-push-hook`.

App identity (`eabp-apps.el`): `eabp-defapp` `eabp-apps-remove`.

Buffer skins (`eabp-buffer.el`): `eabp-render-buffer-register`.

Tablist skins (`eabp-tablist.el`): the `eabp-tablist-header-functions`
`eabp-tablist-row-functions` `eabp-tablist-filter-functions` alists.

Files/editor (`eabp-files.el`): `eabp-files-editor-body-functions`
`eabp-files-editor-actions-functions` `eabp-files-editor-toolbar-function`
`eabp-files-open-hook` `eabp-files-after-save-hook`.

Settings (`eabp-settings.el`): `eabp-settings-register-section`
`eabp-settings-after-set-hook`.

### Validation (`eabp-lint.el`)

`eabp-lint-spec` `eabp-render-to-json` (see Phase B).

## Anything not listed here

Internal, even without a `--`. If a Tier 1 needs it, promote it here
first (that is the review gate for widening the surface). The
byte-compile of `test/core-load-test.el` plus a stability test assert
that every symbol named above is bound.
