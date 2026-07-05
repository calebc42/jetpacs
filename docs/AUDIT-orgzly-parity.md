# Audit: feature parity with Orgzly Revived

**Date:** 2026-07-05. **Reference:** local checkout of
orgzly-android-revived (WSL: `~/pkb/resources/emacs/orgzly-android-revived`),
surveyed from its preference XMLs, source packages (`repos`, `query`,
`reminders`, `widgets`, `calendar`, `external`, `ui`), and manifest.

**Verdict: functional parity is substantially achieved and exceeded in
most areas.** The residue is (a) the client-settings bucket already
suspected, plus (b) four functional gaps that are *not* mere settings:
reminder-notification interactivity, calendar-provider sync, image
share-in, and subtree delete/cut/copy from the UI. Three of the four are
already tracked on the roadmap; calendar sync is the only unplanned one.

## Parity matrix

| Orgzly area | Orgzly capability | Glasspane/EABP status |
|---|---|---|
| Notebooks | list/create/rename/delete/export, preface, default notebook | ✅ different shape: org files on disk via `eabp-files` browser (create/rename/delete/grep/properties); export/import moot (plain files); capture templates choose targets |
| Note rendering | styled text, checkboxes, drawers, breadcrumbs, inline images | ✅➕ rich renderer: emphasis, links, checkbox toggle, folded drawers, footnotes, logbook, foldable outline reader; **tables rendered + editable + formulas** and **babel execution** (orgzly has neither); inline images display (file/http/attachment) — capture/storage story is PKM 9 |
| Note editing | state, priority, schedule/deadline w/ time+repeater, tags, properties | ✅ detail view: todo chips, priority chips, schedule/deadline incl. time + repeater fields, tags, prop add/set, add-note, clock-in; plus full-text editor w/ org toolbar + capf |
| Structure ops | promote/demote/move, cut/copy/paste, delete | ⚠️ drag reorder with level change (`heading.reorder`), refile, archive — but **no subtree delete/cut/copy/paste from the UI** (editor text-ops only). PKM 7 (H5, parked) covers the rest; *delete* is the everyday one worth pulling forward |
| Search | dotted query lang (`i. t. b. s. d. e. c. p. o. ad.`), negation, sort | ✅➕ free text + token filters + **full org-ql sexps** + guided builder (status/tags/priority/due/text) with fallback interpreter. Deltas: no per-query **sort order**, no **per-file/notebook scoping token** |
| Saved searches | searches file, used by widget/views | ✅ `glasspane-org-custom-agendas`, managed in Settings, persisted via Customize, rendered as widget views |
| Agenda | query-driven day list, hide empty days, group-with-today | ✅➕ real `org-agenda` (deadline warnings, repeaters, events/plain timestamps, diary) in day/week/**month** views + date nav + custom agendas |
| Reminders | scheduled/deadline/event classes; **snooze (time/type)**; **mark-done from notification (repeater-aware)**; daily reminder time for date-only items; alarm mode (sound/vibrate/LED, alarm-clock); per-class toggles | ⚠️ exact alarms for all timed agenda items in a 24 h horizon, reboot persistence, heads-up notification, tap→open. **Gaps: no Done/Snooze actions, date-only items never remind, no per-class toggles or alarm mode.** Largest true functional gap |
| Sync | Directory/SAF, Dropbox, Git+SSH (keygen UI), WebDAV; auto-sync rules; `.orgzlyignore`; two-way conflict detection | ✅ by architecture: files live in on-device Emacs; git via the magit app, ssh/syncthing via Termux. Orgzly's repo model deliberately not replicated; convert-facing floor is PKM 14 (H5, parked). No in-app auto-sync rules/conflict UX — accepted trade |
| Calendar sync | writes query-selected notes into an Android **Calendar provider** account | ❌ no calendar capability in the device catalog. Unplanned; natural fit as an AUTO capability (`calendar.insert`/provider account) if wanted |
| Home-screen widget | saved-search list widget, checkmarks, colors/opacity/font/update-freq | ✅➕ agenda widget with multi-view selector (today + every custom agenda), todo-cycle button, offline from cache, refresh; plus 5 Elisp-composed custom widget slots + clock widget. Appearance knobs = client-settings bucket; update frequency moot (push-driven) |
| Quick capture / share | share text **and image**, direct-share to notebook, static shortcuts (new note/sync), ongoing new-note notification | ⚠️ SEND text/plain → capture with template prompts; QS capture tile. **Gaps: image share (PKM 9), static shortcuts/direct-share (AUTO 16, H4)**; ongoing-notification capture could be composed today from the notification capability in Elisp |
| External API | broadcast API (edit notes, run search, manage widgets), Tasker | ✅➕ the entire system is programmable Emacs + triggers + 12-cap device catalog + QS tiles |
| App machinery | settings import/export, clear DB, getting-started notebook | ✅ different shape: custom.el/dotfiles are the export; Customize browser exceeds it. Getting-started/onboarding = PKM 15 (parked, convert-facing) |
| States/priorities config | states pref, default/min priority | ✅ TODO-sequences editor + global tags in Settings; priority range from org vars (Customize) |
| New-note defaults | initial state, scheduled, prepend, ID/created-at property | ✅ org-capture-templates express all of these natively |
| Org file format | newline separation, tags column, indent mode | ✅ Emacs org is canonical; N/A |
| Clocking | — (none in orgzly) | ➕ clock tab, in/out/switch/in-last, recent clocks, chronometer notification, logbook view |

## The client-settings residue (acknowledged bucket)

Orgzly knobs with no Glasspane equivalent — all cosmetic/UX, none
blocking: theme + light/dark color schemes (app is dynamic-color +
system dark only), font size, monospace toggle, styled-text on/off &
marks display (org-hide-emphasis-markers **is** registered ✅), keep
screen on, English-locale override, list density, content-in-list
show/fold toggles + line count, book-name-in-search, inherited tags in
results, note popup/swipe button configuration, reversed click action,
widget colors/opacity/font size, ongoing new-note notification,
hide-empty-agenda-days / group-scheduled-with-today.

Settings currently registered on the wire: line numbers, saved
searches, TODO sequences, global tags, org-directory, org-log-done,
org-log-into-drawer, org-archive-location, org-agenda-span,
org-deadline-warning-days, org-startup-folded, org-startup-indented,
org-hide-emphasis-markers, org-return-follows-link, babel timeout —
plus the whole Customize browser as escape hatch.

## Recommended ordering of the true gaps

1. **Reminder notification actions** (Done w/ repeater awareness +
   Snooze) — daily-driver value, fits H3; needs a `reminder.action`
   wire action back into Emacs (boundary rule applies) and offline
   handling (queue or companion-local like AUTO 10).
2. **Subtree delete** from detail view — one action + confirm dialog;
   cheap, closes the most-noticed structure-ops hole before PKM 7.
3. **Date-only daily reminder time** — small extension of
   `glasspane-org--upcoming-reminders`.
4. **Image share-in** — already PKM 9 (H4); no change.
5. **Calendar provider sync** — decide want/not-want; if wanted, a new
   device capability + a trigger-driven push mirroring the widget push.
6. Client-settings bucket — batch behind a "Look & feel" settings
   section when it starts to itch; nothing load-bearing.
