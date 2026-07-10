# Plan: decouple the org capture/clock surfaces — the toolbar's siblings

**STATUS (2026-07-10): approved, implemented same-day.** Follow-up to
`docs/PLAN-data-driven-toolbars.md` (landed as `e51783b`): a post-landing
review found four more pieces of Glasspane/org opinion living as Kotlin
in this repo — two of them in the **library**, which violates the
standing rule (protocol → `:jetpacs`, opinion → `:app`) outright.

## Why

The foundation's promise is "any UI in elisp, never Kotlin", and the
repo split (`docs/PLAN-platform-hardening.md` Phase F) requires the
foundation to carry **zero** org knowledge. After the toolbar landed,
these remained:

1. **`JetpacsWidgetProvider.kt:152`** (`:jetpacs`) — the agenda widget's
   header "+" button hardcodes `org.capture.show`. The *library* fires
   an org action.
2. **`JetpacsClockWidgetProvider.kt`** (`:jetpacs`) — an entire org-clock
   widget provider hardcoding `org.clock.in-last` / `org.clock.out`
   (static, surface name `widget:clock` used only as a tap label).
3. **`CaptureTileService.kt`** (`:app`) + manifest entry + the
   `"Org Capture"` string — a QS tile hardcoding `org.capture.show`.
4. **Launcher naming** — the manifest points at
   `@mipmap/ic_launcher_glasspane` while `app_name` is already
   "Jetpacs" (the artwork itself is still flagged separately).

The replacement machinery already exists: five blank elisp-composed
`widget:customN` slots (`WidgetSlots.kt`) and five `tile:customN` slots
(`TileSlots.kt`, which supports `tap_in_app` with keyguard unlock and
shade collapse — everything `CaptureTileService` does). Only the agenda
widget's header button needs one new wire key.

## The wire design (SPEC §4 delta)

Widget surface specs gain one **top-level** key (sibling of
`views`/`initial_view` — chrome is view-independent, and
`SurfaceRecord.resolveSpec` returns only the view object for multi-view
specs, so the companion reads it from `record.spec`):

- **`header_action`** — an ordinary §5 action object. When present, the
  widget header shows the "+" button, which opens the app with the
  action embedded (the `JetpacsLaunch` trampoline — header actions are
  for flows that need the visible app, e.g. capture needs a keyboard).
  The pushed object rides **verbatim** (`when_offline` included), per
  §9's embedded-action convention. Absent → the button is hidden.
  Honored by both the agenda provider and the custom slots (which
  today hide the button unconditionally).

Forward compat: additive key — an old companion ignores it and keeps
its hardcoded button (harmless until the APK updates); a new companion
with an old bundle hides the button until the bundle re-pushes.

## Tasks — jetpacs repo

1. **`JetpacsWidgetProvider.kt`** — replace the hardcoded capture wiring
   with `record?.spec?.optJSONObject("header_action")`: present → wire
   `widget_capture` through `trampolineIntent` carrying the pushed
   object verbatim (change its signature to take the action JSONObject);
   absent → `View.GONE`.
2. **`WidgetSlots.kt`** (custom slots) — same `header_action` support
   where the button is currently force-hidden.
3. **Delete `JetpacsClockWidgetProvider.kt`**, its manifest `<receiver>`,
   `res/layout/widget_jetpacs_clock.xml`,
   `res/xml/jetpacs_clock_widget_info.xml`, and the
   `widget_clock_label` string.
4. **`:app`: delete `CaptureTileService.kt`**, its manifest `<service>`
   entry, and `tile_capture_label`; update the MainActivity comment
   that names the tile.
5. **Launcher naming**: rename `ic_launcher_glasspane*` assets (mipmap
   xml, foreground drawable, and the unreferenced
   `drawable/ic_launcher_glasspane.xml`) to `ic_launcher_jetpacs*`;
   update the manifest `icon`/`roundIcon` and the mipmap's foreground
   reference. Same artwork — the art replacement stays a separate,
   flagged task.
6. **Docs** — SPEC §4: document the widget-spec envelope keys the
   companion reads (`title`, `views`/`initial_view`, `empty`,
   `header_action`); ARCHITECTURE: `:app` file list and the closing
   divergence paragraph (org-aware Kotlin is now **zero**);
   `jetpacs-widgets.el` docstrings where they mention the schema.
7. Regen `jetpacs-core.el` if elisp changed; full battery;
   `./gradlew :jetpacs:assembleDebug :app:assembleDebug`; one commit.

## Tasks — glasspane repo (WSL `~/pkb/projects/Glasspane`)

8. **Bump the `jetpacs` submodule pin** to the commit from Task 7
   (standing rule: pin → regen → suite → commit).
9. **`glasspane-ui.el`** — the `widget:agenda` push gains top-level
   `header_action` = `(jetpacs-action "org.capture.show"
   :when-offline "queue")`; add a memo-guarded `tile:custom1` push:
   `(jetpacs-tile "Capture" :icon "add" :state "active" :on-tap … :in-app t)`.
10. **`glasspane-clock.el`** — a memo-guarded `widget:custom1` push:
    title "Org clock", two rows ("Clock in (last)" → `org.clock.in-last`,
    "Clock out" → `org.clock.out`, both `:when-offline "queue"`,
    broadcast taps — no app open, matching the deleted provider).
11. Tests (spec shapes serialize + carry the expected actions), regen
    `glasspane.el`, suite green, TESTING-ON-DEVICE entries, one commit.

## Out of scope (flagged, not forgotten)

- The launcher **artwork** (still Glasspane art under the new neutral
  name).
- Widget slot launcher labels ("Jetpacs custom N") — a rename/labeling
  story for slots is a later niceness.
- orgzly-native — gets `header_action` and the slots for free.

## Verification

- **jetpacs:** grep proves no `org.` action string remains under
  `jetpacs/src` or `app/src`; battery green; both modules assemble
  (proving `:app` builds without `CaptureTileService` and `:jetpacs`
  without the clock provider).
- **glasspane:** suite green against the bumped pin; `glasspane.el`
  contains the tile and clock-widget pushes.
- **On-device (user):** agenda widget still shows the "+" and it opens
  capture; a `tile:custom1` tile added to the shade captures from
  anywhere (after first push); a `widget:custom1` widget clocks in/out
  with Emacs alive and queues when dead. Added to the glasspane repo's
  TESTING-ON-DEVICE list.
