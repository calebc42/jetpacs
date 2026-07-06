# On-device acceptance & battery protocol

**STATUS (2026-07-05): pending — H1 and H2 landed code-complete with
all automated checks green; every item below needs the phone.** Check
items off (or note failures) in place; this file is the single list of
what "verified" means before H3 is truly closed out.

Setup for all of it: install the freshly built debug APK
(`gradlew :app:assembleDebug`, artifact in
`app/build/outputs/apk/debug/`), load the regenerated `glasspane.el`
bundle in the on-device Emacs, reconnect. `adb logcat -s
EabpTriggerHost EabpBootReceiver EabpConnection EabpDeviceCaps` is the
observation window for most of this.

## 1. H1 — handshake & device report

- [x] Welcome shows `capabilities` granted (verified 2026-07-05,
      pre-trigger-host build; `triggers` correctly absent then).
- [ ] Current build: welcome grants **both** `capabilities` and
      `triggers`; `M-:` `(eabp-device-caps)` lists 12 capability
      names; `(eabp-device-can-p "write_settings")` matches reality.

## 2. H1 — effectors from the eval REPL (AUTO 3–4)

From the phone's Eval tab (or any REPL against the live bridge):

- [ ] `(eabp-device-intent :action "android.intent.action.VIEW" :data "https://example.com")` — browser opens.
- [ ] `(eabp-device-launch-app)` — picker lists apps; picking one launches it (needs the `<queries>` manifest merge — an empty list is a bug).
- [ ] `(eabp-device-vibrate 300)` and `(eabp-device-vibrate nil '(0 100 50 100))`.
- [ ] `(eabp-device-tts "hello from emacs")` — first call may pause ~1s for engine init; a second call is instant; engine releases after ~60 s idle (logcat).
- [ ] `(eabp-device-flashlight t)` then `(eabp-device-flashlight nil)`.
- [ ] `(eabp-device-volume-set "music" 5)`, `(eabp-device-media-key "play_pause")` with a player open.
- [ ] `(eabp-device-ringer-mode "vibrate")`; then `"silent"` **without** DND access — expect a clean `cap-permission` message naming the deep-link, not a crash; grant via `(eabp-device-settings-open "android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS")`, retry, works without restart.
- [ ] `(eabp-device-clipboard-read (lambda (text) (message "clip: %S" text)))` — real text with Glasspane foregrounded; nil (typed error in *Messages*) when invoked with the app backgrounded.
- [ ] `(eabp-device-keep-screen-on t)` — screen stays awake on the dashboard; leaving the app releases it; `(eabp-device-keep-screen-on nil)` clears.
- [ ] `(eabp-device-settings-open "wifi")` — floating panel (Android 10+).

## 3. H1 — launcher (AUTO 14)

- [ ] Baseline: with only Glasspane loaded, nothing looks different
      (no home view, no "Apps" drawer entry).
- [ ] `(load ".../emacs/apps/eabp-hello.el")` on the live session →
      drawer gains "Apps"; home shows two cards (Glasspane, Hello);
      opening Hello swaps the bottom bar to its tab (plus the core
      Files/Eval/Tools tabs — expected: unclaimed views show everywhere);
      opening Glasspane swaps back.
- [ ] `(eabp-apps-remove "hello")` + `(eabp-shell-remove-view "hello")`
      → everything collapses back to the single-app look.

## 4. H2 — triggers end-to-end (AUTO 6–7, 12)

Register the canary set from the REPL:

```elisp
(eabp-deftrigger test/charge
  :type "power" :params '((state . "connected")) :policy "wake"
  :handler (lambda (data _) (message "power: %S" data)))
(eabp-deftrigger test/screen-off
  :type "screen" :params '((state . "off")) :policy "queue"
  :handler (lambda (_ _) (message "screen went off")))
(eabp-deftrigger test/tick
  :type "time" :params '((every_s . 120)) :policy "drop"
  :handler (lambda (_ _) (message "tick")))
```

- [ ] Live fire: plug in power → `power: ((state . "connected") (plug . "usb"))` (or ac/wireless) in *Messages* within a second.
- [ ] Queue + replay: `M-x eabp-disconnect`, kill Emacs entirely, toggle the screen off/on twice, restart Emacs → on reconnect the replay delivers the queued `screen-off` fires (two, unless dedupe/throttle say otherwise).
- [ ] Replace-set: `(eabp-trigger-unregister "test/screen-off")`, toggle screen → nothing fires, nothing queued (logcat shows the shrunken set armed).
- [ ] Repeating time: `test/tick` logs every ~2 min while connected (drop policy: silence while disconnected is correct).
- [ ] Reboot: with the set registered, reboot the phone **without** opening the app → logcat shows `EabpBootReceiver` rearming; a `boot`-type trigger (add one) queues its fire; a reminder scheduled pre-reboot still notifies on time.
- [ ] Throttle: a `:throttle-s 60` screen trigger fires at most once a minute however fast you toggle.
- [ ] Battery hysteresis (patience): a `battery.level {below N}` trigger set just under the current level fires exactly once as the level crosses down through N, and not again until it re-crosses.

## 5. H2 — Automations view (AUTO 12)

- [ ] Settings → Automations lists the canary triggers with wire
      summaries.
- [ ] Toggling one off: switch flips, `triggers.set` re-pushes
      (logcat), the device event no longer fires; state survives an
      Emacs restart (Customize wrote `eabp-triggers-disabled`).
- [ ] "Fire now" runs the handler (message appears) and updates the
      last-fired line on the next render.

## 6. H2 — Emacs-dead `on_fire` (AUTO 10)

```elisp
(eabp-deftrigger test/torch
  :type "power" :params '((state . "connected")) :policy "queue"
  :on-fire [((cap . "flashlight") (args . ((on . t))))
            ((notify . ((title . "Charging") (text . "torch on"))))])
```

- [ ] Force-stop Emacs (not just disconnect). Plug in power →
      flashlight comes on and the notification posts, Emacs still dead.
- [ ] Restart Emacs → the queued `trigger.fired` replays (the fire was
      not lost to the local response).

## 7. AUTO 11 — the wake spike (timeboxed, record either way)

- [ ] Does the Termux-signed Emacs APK expose a compliant silent-start
      vector? Try Termux `RunCommandService`
      (`com.termux.permission.RUN_COMMAND` in the host manifest,
      `am startservice` equivalent from adb first) to start a daemon
      `emacs --daemon`; inspect `dumpsys package org.gnu.emacs` for
      exported services/activity-aliases. Write the result — including
      a dead end — into ARCHITECTURE.md's "Execution model" section.

## 8. ⛔ The battery gate (blocks H3 *verification*, measured not assumed)

Hypothesis: triggers ride the existing FGS for ≈0 marginal cost —
broadcasts and alarms, no polling, no wakelocks.

1. **Baseline day:** normal use, bridge running, **no triggers
   registered**. Record: screen-on time and the battery graph
   (Settings → Battery), plus `adb shell dumpsys batterystats
   --charged com.calebc42.glasspane*` (the app's blame share) at
   day's end. (`adb shell dumpsys batterystats --reset` after a full
   charge starts a clean window.)
2. **Trigger day:** same usage pattern with the canary set live
   (screen + power + a 2-min time trigger — deliberately chattier
   than real use).
3. **Compare:** the app's mAh/percentage share and partial wakelock
   count between the two days. Pass = trigger-day delta within noise
   (±1% of total, no new wakelock entries). Fail = find the item in
   `batterystats` before building anything else on the host.

Note the result in ROADMAP.md at the H2→H3 gate line; H3 features are
landing ahead of this measurement (2026-07-05 decision), so the gate
becomes "verify before H4" rather than "verify before H3".

## 9. H3 — daily-driver org value

- [ ] **Journal:** the Journal tab shows today; typing in the capture
      row and submitting lands a `- item` under today's datetree in
      journal.org (file created on first capture); ‹ › browses days;
      the date button opens the native picker; a TODO scheduled
      yesterday appears under "Carried over" and its "Today" button
      reschedules it (gone from the section, snackbar confirms);
      Settings → Journal → "Open on the journal" + Emacs restart lands
      on Journal.
- [ ] **Saved views:** drawer → Saved views → New view (name "Work",
      query `todo:TODO`, rendering board) → the view opens with one
      column per TODO state; the card menu moves a heading to another
      state (verify in the file); chips flip list/board/calendar; the
      definition survives an Emacs restart.
- [ ] **Org automations:** create automations.org with the header
      example from glasspane-automations.el; save from the phone
      editor → `M-x glasspane-automations-reload` happens implicitly
      (check the Automations view lists `org/Charge sync`); mark the
      heading DONE and re-save → gone from the set.
- [ ] **Network trigger:** register `:type "network" :params
      '((event . "available") (transport . "wifi"))`; toggle Wi-Fi →
      one fire per gain with `transport: wifi`; airplane mode on →
      a `lost` fire.
- [ ] **Sparse filter:** open a large org file in read mode; the
      filter row narrows by `tags:x` / `todo:TODO` / free text;
      "n of m headings" + Clear behave; a nonsense query shows its
      error instead of a blank file.
- [ ] **Vulpea (needs the updated starter init + network once):**
      startup installs vulpea and `vulpea-db-autosync-mode` builds the
      index (first run on a big vault: note the wall time — this IS
      the PKM 1 spike's cold-index number; also note incremental
      update lag after a save and Emacs RSS before/after).
- [ ] **Wikilinks:** in the phone editor type `[[` in an org file —
      the strip offers notes immediately; typing narrows; accepting
      inserts `[[id:…][Title]]`. Offline `[[` completes nothing.
- [ ] **Backlinks:** open a heading with an ID that other notes link
      to — "Linked references (n)" lists them, cards open the source;
      "Find mentions" runs the ripgrep pass (needs `rg` from Termux)
      and "Link it" rewrites the mention into a real link (verify the
      source file).
