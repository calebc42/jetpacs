# Alpha demo video — shooting script

One continuous on-device story: fresh install → onboarding → pair →
grow three apps into a live session without ever restarting Emacs.
Target length **10–12 minutes**. Every UI label and eval form below is
verified against the current code.

The arc, in one line: *"The phone is a pane of glass; Emacs is the
source of truth — watch me grow three apps into a running session."*

---

## Pre-flight (off camera, do all of this before recording)

**Device state**

- [ ] Emacs APK (the Termux-signature build) and Termux installed and
      working. Emacs must NOT be running when recording starts.
- [ ] Uninstall the Jetpacs companion (or `adb shell pm clear
      com.calebc42.jetpacs`) so onboarding shows — it only appears
      until the first successful pair.
- [ ] Move the existing Emacs config aside for an authentic first run:
      in Termux, `mv ~/.emacs.d ~/.emacs.d.bak` (and stash
      `early-init.el` if it exists in the org.emacs sandbox). Restore
      after the shoot.
- [ ] Empty (or move aside) `~/org` so Orgzly's empty state and the
      demo-corpus reveal both land.
- [ ] Build the APK on the dev machine: `./gradlew assembleDebug`,
      copy `app/build/outputs/apk/debug/*.apk` to the phone (or have
      the release APK download link ready if you're showing that).

**Bundles**

- [ ] `jetpacs-core.el` and `jetpacs-hello.el` need **no staging** —
      the wizard installs them from APK assets.
- [ ] `orgzly.el` and `glasspane.el`: the authentic beat is
      downloading them in the phone browser from each repo's root on
      GitHub. **⚠ As of 2026-07-10 orgzly-native has no GitHub remote
      and jetpacs/glasspane have unpushed commits — push everything
      first**, or `adb push` both files to `/sdcard/Documents/jetpacs/`
      and narrate "I've already downloaded these two."
- [ ] Confirm both bundles at repo roots are freshly regenerated
      (`emacs --batch -l emacs/build-bundle.el` in each repo).
- [ ] **All three bundles must be the same generation (core ≥1.2.0,
      2026-07-10 multi-app namespacing).** A pre-namespacing `orgzly.el`
      or `glasspane.el` next to a new core recreates the tab-hijacking
      collisions the demo's money shot depends on not having — stage
      `jetpacs-core.el`, `orgzly.el`, and `glasspane.el` together.

**Recording hygiene**

- [ ] Do Not Disturb on; screen recorder with touch indicators on.
- [ ] Network ON (the starter init tries MELPA for org-ql /
      vulpea / org-srs; the demo works without them, but SRS review
      and backlinks only appear with them installed).
- [ ] Full dry run once. Known pacing beats: `glasspane.el` is a big
      bundle — its `(load ...)` takes a few seconds (narrate over
      it); the first agenda build after seeding also pauses briefly.

---

## Scene 0 — Cold open (0:00–0:45)

**SHOW:** the phone home screen, nothing running. Optionally a 5-second
title card first.

**SAY (roughly):**

> Every mobile org app works the same way: parse the file, and
> reconstruct what Emacs *would* have computed. Custom TODO sequences,
> capture hooks, agenda skip functions — a parser can only approximate
> them.
>
> This is Jetpacs, and it takes the opposite premise: don't approximate
> Emacs — **connect to it**. The phone is a thin pane of glass; Emacs,
> running right here on this device, is the source of truth behind it.
>
> In the next ten minutes I'll install it fresh, pair it, and then grow
> three complete apps into the running session — live, without
> restarting Emacs once.

---

## Scene 1 — Install + onboarding (0:45–3:30)

**DO / SHOW:**

1. Install the APK (files app → tap → install) and open **Jetpacs**.
2. Onboarding **Welcome** screen: *"Set up Jetpacs"* — read the intro
   line on screen, then tap **"No — set me up (recommended)"**.
   - (Point at **"Yes — I manage my own init.el"**: "if you already
     have a config, it hands you a five-line bootstrap instead.")
3. **Termux step**: *"Is Emacs sharing a signature with Termux?"* —
   tap **"Yes — redirect Emacs to Termux"**.
   - SAY: "My Emacs APK shares Termux's signature, so it can use
     Termux's FOSS tools and one shared home. If you don't know what
     that means, the answer is No and the wizard adapts."
4. **Deliver step** — the heart of onboarding. SAY the framing first:

   > Android sandboxing means this companion can't write into Emacs's
   > private folders. So instead of pretending, the wizard is honest:
   > it *generates* everything and hands it over.

   Then work the cards top to bottom:
   - Card 1 *"Grant Termux storage access"* — tap **Copy command**,
     switch to Termux, paste `termux-setup-storage`, run it, and
     approve the storage prompt. SAY: "Emacs borrows Termux's identity,
     so it reads the foundation bundle from shared storage through
     Termux's permission — this grants it once."
   - Card 2 *"Termux redirect → early-init.el"* — tap **Copy
     snippet**, switch to Emacs/Termux, create the file at the path
     shown on the card, paste, save. (Rehearse this switch; it's the
     fiddliest moment of the video. A text editor in Termux —
     `nano` — reads fine on camera.)
   - Card 3 *"Starter init.el"* — tap **Copy snippet**, paste as
     `~/.emacs.d/init.el`. SAY: "Notice the pairing token is already
     filled in — this init is ready to connect, zero editing."
   - Card 4 *"Install jetpacs-core.el"* — tap **Install to
     Documents**. SAY: "The foundation bundle is one elisp file. It
     goes to shared storage, and the init you just pasted adopts it on
     startup — that's also how every app will arrive."
   - *"Get apps"* card — just point at it: "apps aren't shipped by
     this APK; they're single files you download. We'll do exactly
     that in a minute."
   - *"Try the hello demo"* card — tap **Install jetpacs-hello.el**.
     "And this one we'll use right away."
5. Tap **"Done — pair Emacs"** → the pairing screen.

---

## Scene 2 — First pairing (3:30–4:30)

**DO:** Launch the Emacs app. Say nothing for a beat — let the
handshake land on camera. The pairing screen flips to the live shell
the moment Emacs finishes starting.

**SAY:**

> That's it. Emacs read the starter init, adopted the core bundle from
> Documents, and dialed in over a mutually-authenticated local socket.
> No app logic crossed the wire — Emacs pushes UI specs, the phone
> renders them.

**SHOW:** swipe through what the *foundation alone* provides — the
**Eval** tab, the Files browser, the command palette / M-x. SAY: "No
app is installed yet. This is the empty foundation: any buffer, any
prompt, any keymap, already rendered native."

---

## Scene 3 — jetpacs-hello.el: an app in 60 lines (4:30–6:00)

**DO:** open the **Eval** tab and evaluate:

```elisp
(load "/sdcard/Documents/jetpacs/jetpacs-hello.el")
```

**SHOW:** a **Hello** tab appears in the bottom bar. No restart, no
reconnect. Open it, tap **"Tap me"** a few times — the counter climbs
and a snackbar fires per tap.

**SAY:**

> That file is sixty lines of elisp, and it just became an app in the
> running session. The view is built in Emacs — that version string is
> `emacs-version` evaluated live. The button doesn't call code over the
> wire; it sends the semantic action "hello.tap", and a handler on the
> Emacs side decides what that means. That allowlist is the security
> model.
>
> Registering a view on a live session schedules its own refresh —
> which means everything you're about to see installs the same way:
> load a file, and the phone follows.

*(Optional flourish if pacing allows: from Eval, `(setq
jetpacs-hello--count 100)` then `(jetpacs-shell-push)` — "and of course,
any state is just Emacs state.")*

---

## Scene 4 — orgzly.el: a real app, zero Kotlin (6:00–8:30)

**DO:**

1. (If showing the download live) open the phone browser, grab
   `orgzly.el` from the orgzly-native repo root → lands in Download,
   then move it into `Documents/jetpacs`. Otherwise narrate: "I've
   downloaded orgzly.el — one file."
2. Eval tab:

   ```elisp
   (load "/sdcard/Documents/jetpacs/orgzly.el")
   ```

3. **SHOW — beat #1:** the shell reorganizes into the **launcher
   home**: two app cards, **Orgzly** and **Hello**. SAY: "Two apps now
   live in one session, so Jetpacs grows a launcher. Each keeps its
   own tab bar."
4. Open **Orgzly**. Books is empty — good. Create the first notebook
   and capture a note *live*: title, a TODO state, schedule it with
   the timestamp dialog, a tag. Save.
5. Show two or three marquee moves, no more:
   - the note list: fold, swipe/long-press quick actions, cycle the
     TODO state;
   - **Search** with a dotted query, e.g. `i.todo s.le.today` — SAY:
     "This is Orgzly Revived's actual query language, ported
     faithfully — parser, agenda semantics, saved searches";
   - the drawer: every notebook and saved search one tap away.

**SAY (the thesis line of this scene):**

> This is a rebuild of Orgzly Revived with **zero Kotlin**. Every
> screen, the query language, reminders, the home-screen widget —
> elisp. And the database? There is no database. Your org files on
> disk *are* the database, and it's the same Emacs org-mode doing the
> computing.

---

## Scene 5 — glasspane.el + the money shot (8:30–11:00)

**DO:**

1. Eval tab (narrate over the load — it's the big bundle):

   ```elisp
   (load "/sdcard/Documents/jetpacs/glasspane.el")
   ```

2. **SHOW:** launcher home now has **three** cards. Open
   **Glasspane** — agenda, journal, tasks, clock, search, saved
   views, SRS review.
3. Empty agendas are boring, so seed the guided tour. Eval:

   ```elisp
   (glasspane-config-ensure)
   (glasspane-demo-setup-org)
   ```

   SAY: "Glasspane ships a demo corpus *inside the bundle* — Emacs
   writes it to `~/org` itself, because only Emacs can write there."
4. **SHOW** Glasspane come alive — pick 3 beats max:
   - **Agenda** with the month calendar grid and the swipeable tab
     pager;
   - open a note's detail view — rendered org: tables, headings (and
     backlinks, if vulpea installed itself);
   - **SRS review** — swipe through a flashcard or two: "spaced
     repetition, driven by org-srs in Emacs, rendered native."
5. **THE MONEY SHOT.** Go back to the launcher → open **Orgzly**. The
   demo corpus is there too — same books, same notes.

**SAY:**

> Look at that. I never told Orgzly anything. Both of these apps are
> windows onto the same `~/org` directory in the same running Emacs.
> Two different opinions about UI, one source of truth. That's the
> whole architecture on one screen.

---

## Scene 6 — Make it stick + outro (11:00–12:00)

**DO:** show (don't fully type) the persistence step: open `init.el`,
change the adopt list —

```elisp
(dolist (bundle '("jetpacs-core.el" "orgzly.el" "glasspane.el"))
```

— and add `(require 'orgzly)` / `(require 'glasspane)` after
`(require 'jetpacs-core)`. SAY: "Everything I loaded live tonight
survives a restart with two lines in the init — the same adopt
mechanism that delivered the core."

**SAY (closing):**

> So: a fresh phone to three live apps, all elisp, one file each, no
> restarts. This is alpha — local-only transport, unprofiled battery,
> rough edges — but the foundation is written down: the wire protocol
> is a spec anyone can implement, and BUILDING-TIER1 is the guide for
> making the *fourth* app, which is really the point. Links below.
> Thanks for watching.

**End card / description links:** jetpacs repo (spec, ROADMAP,
BUILDING-TIER1.md), glasspane repo, orgzly-native repo, license
(GPLv3).

---

## Fallbacks & gotchas (keep this page next to you)

| Moment | Failure | Recovery |
|---|---|---|
| Pairing | screen doesn't flip | in Emacs: `M-x jetpacs-connect`; check the token line made it into init.el |
| Any live load | tab doesn't appear | `M-x jetpacs-ping`, then re-eval the `(load ...)` — it's idempotent |
| Demo corpus | mangled during rehearsal | `(glasspane-demo-setup-org)` again — setup always overwrites to pristine |
| Backlinks / SRS missing | MELPA installs deferred (offline) | skip those beats; nothing else depends on them |
| Onboarding needed again | already paired | clear the companion's app data; onboarding shows until first pair |
| Eval typing painful on camera | — | pre-place each form in a note you can copy from, or keep Termux clipboard handy |

Cut-for-time order if running long: Scene 3 flourish → Orgzly drawer →
Glasspane detail view. Never cut: the launcher-appears beat (Scene 4)
and the money shot (Scene 5).
