# Plan: PKM conversion (Obsidian / Logseq / Notion) & the KMP horizon

**STATUS (2026-07-05): draft — direction-setting audit, no tasks started.**

Produced 2026-07-05 from an audit of the repo against two long-horizon
goals:

1. **Conversion** — an experience simple and abstracted enough to
   convert Obsidian, Logseq, and Notion users, on top of the org layer.
2. **KMP** — eventually a Kotlin Multiplatform (Compose Multiplatform)
   companion for Desktop and iOS.

**The bar (normative for every task here):** a convert must **never see
Emacs and never see raw org syntax unless they ask.** Every feature is
judged against that bar. The architecture was accidentally built for
it — the companion is already a pane of glass where the renderer, not
the syntax, is the interface.

Tracks: **C = conversion** (near/mid-term, phased), **K = KMP horizon**
(decision/prep only — no migration work now). Tasks are self-contained:
goal, files, implementation notes, pitfalls, acceptance.

**Relation to the other plans** (this doc re-prioritizes, it does not
duplicate):
- [PLAN-automation-and-launcher.md](PLAN-automation-and-launcher.md):
  its Task 2/3 (`capability.invoke`, intents) carries this plan's media
  picking; its Task 11 (wake/keep-alive story) is the same work as
  zero-Emacs onboarding; its Task 19 (declarative org apps) is the
  Notion-templates analog.
- [PLAN-primitive-completeness.md](PLAN-primitive-completeness.md):
  its deferred inline-images follow-up is **upgraded to
  conversion-critical** here (Task 9).
- The orgro-parity backlog (link nav, timestamp tap-edit) feeds
  Tasks 3–4 and the editing phase.

---

## Audit part 1 — what org already subsumes (data layer: no gaps)

Org-mode subsumes the *data models* of all three apps. Nothing below
requires new storage concepts — the delta is UX abstraction.

| Their concept | Org / eabp equivalent | Status |
|---|---|---|
| Pages / notes (md files, Notion pages) | org files / headings | ✅ |
| Outliner blocks (Logseq) | headings + plain lists | ✅ data, ❌ manipulation UX |
| Links / wikilinks | org links, org-id | ✅ data, ❌ autocomplete + backlinks UX |
| Tags (nested) | org tags (+ inherited) | ✅ |
| Typed properties / frontmatter | property drawers (just landed) | ✅ data, ❌ form UX |
| Tasks, dates, reminders | TODO keywords, timestamps, `reminders.set` | ✅ (reminders already ship) |
| Queries (Dataview, Logseq queries, Notion filters) | org-ql (query builder just refactored) | ✅ engine, ❌ saved-views UX |
| Databases w/ views (Notion) | headings + drawers + org-ql + column view | ✅ data, ❌ view renderings |
| Templates | org-capture templates (+ config-dir merge) | ✅ engine, ❌ friendly UI |
| Block refs / transclusion (Logseq) | org-id + org-transclusion | ✅ engine, ❌ UX |
| Daily notes / journals | datetree / roam-dailies | ✅ engine, ❌ landing surface |
| Flashcards (Logseq), PDF annotation | org-fc / org-noter | ✅ engines exist, deferred |
| Web clipper | share sheet (Android) — already better | ✅ |
| Quick capture, widgets, automation | capture tile/widgets + automation track | ✅ **ahead of all three** |

## Audit part 2 — the seven conversion deltas (common core)

- **C1. Live editing** — all three hide markup (live preview / outliner
  / block editor + slash commands). We render rich but edit raw.
- **C2. Wikilinks + backlinks** — `[[` autocomplete, backlinks panel,
  unlinked mentions.
- **C3. Daily-note landing surface** — open app → today's page.
- **C4. Inline images & attachments** — photos-in-notes are air to
  these audiences.
- **C5. Import** — the #1 switching lever; trial becomes migration on
  import quality.
- **C6. Sync for normal humans** — the FOSS floor + the (already
  contemplated) paid tier.
- **C7. Zero-Emacs onboarding** — pairing-token-into-init and
  tap-to-open-Emacs are fine for us, fatal for converts.

Per-app distinctives, positioned:

| Feature | App | Position |
|---|---|---|
| Dataview / query views | Obsidian | Strongest existing asset (org-ql builder) → Task 11 |
| Multi-view databases (table/board/calendar) | Notion | Reachable: org-ql + drawers + agenda → Task 11 |
| Block refs / embeds | Logseq | org-id + org-transclusion; UX only → Phase C3 follow-up |
| Outliner drag/indent/fold | Logseq | `reorderable_list` node is the seed → Task 7 |
| Typed-property forms | Notion/Obsidian | Settings controls pattern reused → Task 10 |
| Templates UI | all | capture templates + Task 19 org-apps → Task 5/11 side-effects |
| Graph view | Obsidian/Logseq | demo candy, low retention — non-goal v1 |
| SRS / PDF annotation | Logseq | deferred, engines exist |

## Constraints & realities (read before estimating)

- **The cross-app storage boundary.** Emacs (Termux-signed) home is
  app-private; Glasspane cannot read it, and Emacs cannot read
  Glasspane's private dirs. Anything both sides must touch (org files
  for image rendering, picked photos) lives in **shared storage** (the
  termux-setup-storage convention) with the right media permissions —
  or travels **as bytes over the socket**. Task 9 decides per case;
  today's manifest has *no* storage/media permissions, so verify what
  the current `image` node can actually load before building on it.
- **Remote Emacs ≠ loopback.** The HMAC pairing authenticates but does
  not encrypt; that is fine on `127.0.0.1`, not across a network. The
  moment "remote Emacs" becomes real (iOS, Task 18), the transport
  needs a channel (TLS or SSH tunnel). Flag every design that assumes
  loopback confidentiality.
- **iOS cannot run Emacs** (no fork/exec, App Store rules). The iOS
  client is remote-Emacs-first with, at most, an embedded read/light-
  edit fallback parser. This was anticipated: the pairing design was
  chosen over UDS/signature *specifically* to keep remote Emacs
  possible.
- **Battery discipline applies to indexes.** A backlink index and image
  thumbnailing are the kind of background work that must be event-
  driven (save hooks, cache-invalidate seam), never polling. Pure
  elisp over external binaries, per the standing rule.
- **One syntax.** Native markdown support is *deliberately deferred*
  (see non-goals): import converts to org. Revisit only if import
  proves to be the churn point.
- **FOSS constraint:** sync = Syncthing/git class tools; no
  proprietary services in the floor tier.

## Repo conventions

Same as the other plans: sources in `emacs/core/` + `emacs/apps/`,
bundles regenerated via `emacs --batch -l emacs/build-bundle.el`; ERT
suites + widget golden; SPEC §5 allowlist for every new action; core
stays org-free (linking core in `emacs/core/` must be link-engine
generic; org specifics live in `emacs/apps/glasspane/`); new org-syntax
regexes get case-convention tests; wire additions are additive when
Kotlin can't land in the same pass.

---

## Phase C0 — the two early bets (everything layers on these)

### Task 1: Backlink-engine decision + spike

**Goal:** pick the engine every linking feature builds on: **org-roam**
(sqlite via Emacs 29+ builtin, mature schema, dailies for free, heavier
and opinionated) vs **a lightweight org-id + own index** (pure elisp,
event-driven rebuild behind the cache-invalidate seam, exactly as much
as we need).

**Files:** spike in `emacs/apps/glasspane/` (throwaway), outcome
recorded in this doc + ARCHITECTURE.md.

**Implementation:** prototype *one* function both ways —
`(glasspane-links-backlinks FILE-OR-ID)` returning `(source-heading
context-snippet position)` — over a realistic vault (few hundred
files). Measure: cold index time on-device, incremental update cost on
save, memory. Decide with three criteria: battery (event-driven
updates only), simplicity of the "unlinked mentions" query (needs
full-text anyway → `files.grep` exists), and whether roam's schema
buys Task 5 (dailies) and Task 4 cheaply enough to carry its weight.

**Pitfalls:** don't let the spike become the feature; it answers the
question and dies. If org-roam wins, its db rebuild must be wired to
the existing save/refresh hooks, never timers.

**Acceptance:** decision paragraph merged into this doc; the chosen
backlinks function passes an ERT test against a fixture vault; numbers
(index time, update time) recorded.

### Task 2: Editing-model design (the WYSIWYG direction)

**Goal:** a written design for how raw org disappears from the editor
— the largest single conversion lever, decided *before* incremental
editor work begins.

**Files:** design section appended to this doc (or docs/DESIGN-editing.md);
no code.

**Implementation — evaluate three layers, cheapest first:**
1. **Conceal via fontify runs.** The editor-sync sub-protocol already
   pushes `fontify.show` runs (SPEC §8); extend runs with a `conceal`
   attribute so `*bold*` markers vanish and links show descriptions —
   Emacs-side org knowledge, companion-side dumb rendering. Covers
   emphasis/links/entities cheaply.
2. **Structural chrome instead of syntax.** Headings/lists/checkboxes
   as rendered rows with direct manipulation (Task 7), so structure is
   never typed as asterisks.
3. **Slash menu** (Task 8) so block *insertion* never involves syntax.

Decide what stays raw-visible (tables? src blocks?) and what the
"show source" escape hatch looks like (converts never need it; we
always get it).

**Pitfalls:** resist a companion-side org parser — layer 1 keeps all
org knowledge in Emacs, which is the whole architecture. Cursor
adjacency rules for conceal (marker reveals when caret enters) need
explicit spec or editing feels haunted.

**Acceptance:** design reviewed; Tasks 6–8 rewritten against it if
needed; SPEC §8 draft of the `conceal` run attribute.

---

## Phase C1 — linking core

### Task 3: Wikilink autocomplete

**Goal:** typing `[[` in any editor offers headings/files, inserts a
proper org link.

**Files:** `emacs/core/eabp-complete.el` (source),
`app/src/main/java/com/calebc42/eabp/SduiInputNodes.kt`
(`COMPLETION_TRIGGER_CHARS` — add `[`; Kotlin change, same pass),
`emacs/apps/glasspane/` (org candidate source from the Task 1 engine).

**Implementation:** ride the existing capf bridge (`edit.complete` /
`completions.show`, queue-bypassing). Companion change: `[` as a
trigger char and bracket-aware prefix extraction. Candidates from the
Task 1 engine (titles + aliases), annotation = file. Insertion is
companion-side (existing mechanism); the inserted text is a full
`[[id:…][Title]]` link, so raw syntax exists in the buffer but Task 2
concealment renders it as the title.

**Pitfalls:** candidate volume — cap + rank by recency; don't ship the
whole vault per keystroke. The completion path bypasses the offline
queue by design; offline `[[` simply completes nothing (fine).

**Acceptance:** on-device: type `[[`, pick a note, link renders as its
title; ERT covers the candidate function and prefix math.

### Task 4: Backlinks panel + unlinked mentions

**Goal:** every note detail view grows a backlinks section; unlinked
mentions listed below with one-tap "link it".

**Files:** `emacs/apps/glasspane/glasspane-ui.el` (detail view),
engine from Task 1, `files.grep` for unlinked mentions.

**Implementation:** collapsible "Linked references (n)" under the note
body: source heading + context snippet, tap → navigate (reuses the
existing detail navigation). "Unlinked mentions" = title/alias grep
minus linked sources, behind a fold (computed on expand, not on every
render — memoised per the cache contract). `link.materialize` action
converts a mention into a real link (edits the source file; queue
policy `queue`).

**Pitfalls:** unlinked-mention grep on a big vault is the battery
risk — compute lazily on fold-expand only, cache per note, drop via
the standard invalidate seam. Snippet extraction must not load every
source buffer; use the grep output.

**Acceptance:** fixture vault: linked refs correct, mention
materializes and moves lists on refresh; case test (org links are
case-sensitive in paths, titles matched case-insensitively).

---

## Phase C2 — the landing surface

### Task 5: Daily note as home

**Goal:** open app → today's page, ready to type; calendar back-nav;
yesterday's unfinished tasks surfaced. The Logseq bootstrapping habit,
org-native.

**Files:** new `emacs/apps/glasspane/glasspane-journal.el`,
`glasspane-config.el` (journal file convention seeded softly),
shell view registration.

**Implementation:** a `journal` view registered as the initial view
(a Customize setting — existing users keep Agenda). Datetree (or roam
dailies if Task 1 chose roam — one code path, decided there). Body =
today's subtree via the foldable reader + an always-focused capture
row; header chips for ‹ yesterday | calendar | tomorrow ›. "Carried
over" section = org-ql for yesterday's unfinished TODOs with one-tap
reschedule (timestamp tap-edit from the orgro backlog folds in here).

**Pitfalls:** don't invent a new file layout — datetree is standard
and importable; seed the journal target only at stock values per the
config-dir contract.

**Acceptance:** fresh vault: first open shows today, typed text lands
in the datetree; carried-over TODO reschedules; setting flips the
landing view back to Agenda.

---

## Phase C3 — editing increments (order fixed by Task 2's design)

### Task 6: Concealed live formatting

**Goal:** emphasis markers, link syntax, and entities invisible while
editing; what you type is what you see.

**Files:** `emacs/core/eabp-sync.el` (emit conceal runs),
`SduiInputNodes.kt` / `EditorSync.kt` (apply runs: zero-width render +
caret-adjacent reveal), SPEC §8.

**Implementation:** per Task 2 layer 1 — fontify runs gain
`{conceal: true, display?: "…"}`; Emacs computes them from org
font-lock/org-element (the same invisibility org-mode itself uses);
companion renders concealed spans collapsed except when the caret is
inside the span. All org knowledge stays Emacs-side.

**Pitfalls:** offset math is already code-point-safe by protocol —
keep it that way (conceal changes *rendering*, never offsets, or every
delta breaks). Reveal-on-caret needs debounce or fast cursor movement
flickers.

**Acceptance:** `*bold*` shows **bold**; caret inside reveals markers;
deltas round-trip with concealment active (extend the editor-sync ERT
+ a Kotlin-side reveal test); golden updated for the run shape.

### Task 7: Structural manipulation (outliner parity)

**Goal:** headings and list items drag to reorder/refile, indent/
outdent by gesture or toolbar, fold state persists — Logseq's feel on
org data.

**Files:** `emacs/apps/glasspane/glasspane-org-reader.el` (reader is
already collapsible trees), `eabp-widgets.el` if `reorderable_list`
needs nesting support (wire change + golden), org actions in
`glasspane-ui.el` (`heading.refile-to`, `heading.promote/demote`,
`item.indent/outdent` — allowlisted, position-validated).

**Pitfalls:** drag semantics on nested trees are the hard part —
consider v1 as reorder-within-siblings + explicit "move under…" picker
(a bridged `completing-read` is free) before free-form tree drag.
Every mutation invalidates the org cache (standing contract).

**Acceptance:** reorder siblings by drag; demote/promote from
toolbar; refile via picker; file diff shows clean org moves
(`org-refile` semantics, not text surgery).

### Task 8: Slash-command insert menu

**Goal:** `/` in the editor opens the block menu (heading, todo, list,
table, image, date, src block, quote) — Notion's muscle memory.

**Files:** `SduiInputNodes.kt` (trigger + menu strip, reusing the
completion-strip UI), `emacs/core/eabp-complete.el` (a `slash`
completion kind answered from a registered menu),
`eabp-files.el`/glasspane (org menu registration — per-file-type via
the existing editor seams).

**Pitfalls:** `/` is common in prose and paths — trigger only at
line start or after whitespace, and make dismissal effortless.
Insertion templates are plain text snippets with a caret marker;
no code on the wire.

**Acceptance:** `/tab` → table skeleton inserted, caret in first cell;
per-file-type menus verified (org vs plain text).

---

## Phase C4 — media

### Task 9: Inline images + photo capture (upgraded from deferred)

**Goal:** images render inline in reader and rich views; a note can
receive a photo from camera/gallery in two taps.

**Files:** `glasspane-org-rich.el` / reader (inline placement — the
deferred primitive-completeness follow-up), `DeviceCapabilities.kt`
(`media.pick {source: camera|gallery}` — rides the automation plan's
Task 2 channel), `AndroidManifest.xml` (media permissions as needed),
attachment action in glasspane.

**Implementation:** first, settle the storage boundary (see
constraints): decide per the actual deployment whether org files +
attachments live in shared storage (companion loads paths directly;
needs media/storage permission) or whether images cross the socket as
bytes (companion → Emacs for picked photos; Emacs → companion
thumbnails for rendering). Recommendation: **shared-storage
attachments dir** (`org-attach` convention under `org-directory`) —
both processes read it, nothing large rides NDJSON — with picked
photos saved there by the companion and only the *path* sent in the
action args (validated against the attachment root, per the files-view
confinement pattern).

**Pitfalls:** verify what the current `image` node can load *today*
(manifest has no storage permissions — http(s) may be the only working
source right now). Thumbnail/downsample companion-side; never decode
full-res into widget lists. EXIF strip on capture (privacy default).

**Acceptance:** photo → FAB "attach photo" → appears inline in the
note and in the reader offline (cached spec + readable path); large
vault list views stay smooth.

---

## Phase C5 — properties & database views

### Task 10: Typed property forms

**Goal:** property drawers render and edit as native forms (text,
number, date, select, checkbox), never as drawer syntax — Notion
properties on org data.

**Files:** `emacs/apps/glasspane/` (detail view section + a property-
schema registry: per-key type/options, defcustom'd), actions
`property.set` (exists already? extend), reusing the settings-controls
pattern (`eabp-settings` proved the schema→control mapping).

**Pitfalls:** schema is advisory — unknown keys still render as free
text (org files are wild); dates must round-trip org timestamp format
exactly; case-insensitive drawer recognition + case tests.

**Acceptance:** a heading with mixed known/unknown properties renders
a form; edits produce clean drawer diffs; date property opens the
native picker.

### Task 11: Saved queries as views (Dataview / Notion databases)

**Goal:** the org-ql query builder's output becomes persistent, named
views with three renderings — **list/table** (property columns),
**board** (kanban by TODO state or property), **calendar/agenda**
(scheduled dates) — over the same query.

**Files:** `emacs/apps/glasspane/` (saved-view registry persisted via
Customize; renderings on the existing table node + a board layout —
check whether `row` of `lazy_column`s suffices before adding a wire
node), shell integration (saved views listed in the app's views;
pairs naturally with the launcher plan's Task 14 app grouping and
Task 19 org-apps, where a heading's `:VIEW:` drawer names a saved
query).

**Pitfalls:** board drag-between-columns = `todo-set`/`property.set`
actions (already allowlisted patterns) — not a new mechanism. Column
rendering of arbitrary property values needs width discipline (the
table node already pans). Memoise per the cache contract; org-ql over
a big vault per render is the battery risk.

**Acceptance:** build a query in the builder → "save as view" → named
view appears with all three renderings; drag a card between board
columns → TODO state changes in the file; survives restart.

---

## Phase C6 — import (the switching lever)

### Task 12: Obsidian / markdown vault importer

**Goal:** point at a vault, get a faithful org vault: md → org,
`[[wikilinks]]` (incl. aliases, heading anchors) → org links, YAML
frontmatter → property drawers, tags preserved, daily-notes folder →
the Task 5 journal convention.

**Files:** new `emacs/apps/glasspane/glasspane-import.el` (pure elisp
converter — pandoc via Termux is the fallback, not the plan, per the
pure-elisp rule), a wizard flow in the files view (pick dir → dry-run
report → convert).

**Implementation:** two-pass: (1) index titles/aliases across the
vault, (2) convert files, resolving wikilinks against the index
(unresolved → plain text + report). Dry-run first: counts, unresolved
links, unsupported syntax list. Keep originals untouched; convert into
a fresh `org-directory` subtree.

**Pitfalls:** markdown dialect sprawl — target CommonMark + the
Obsidian extensions that matter (wikilinks, callouts → org quote
blocks with a label, embeds → transclusion comments), and *report*
the rest rather than mangle it. Link-resolution correctness beats
coverage: a convert forgives a lost callout, not a broken link graph.

**Acceptance:** a real published Obsidian vault (grab a public one as
a fixture) converts with zero broken resolvable links; dry-run report
matches conversion result; ERT fixtures for each syntax mapping.

### Task 13: Logseq + Notion importers

**Goal:** the other two on-ramps.

**Implementation:** **Logseq** — if the graph is org-flavored, it's a
config mapping (journals dir, `logseq/` metadata ignored, block-ref
UUIDs → org-id), not a conversion; md-flavored graphs reuse Task 12
plus block-ref (`((uuid))`) resolution to org-id links. **Notion** —
export zip: md pages via Task 12; **csv databases → org headings with
property drawers** (one file per database, one heading per row,
columns → properties) so Task 11 views pick them up immediately —
that's the "your Notion database still works" demo.

**Pitfalls:** Notion's export flattens relations to page links —
map to org links, report rollups/formulas as unsupported. Logseq
`:PROPERTIES:` on blocks (not just pages) must land on the right
level.

**Acceptance:** fixture Logseq graph and Notion export both convert;
a Notion database csv renders as a Task 11 board untouched.

---

## Phase C7 — sync & onboarding

### Task 14: The FOSS sync floor

**Goal:** a blessed, documented multi-device story: git-autocommit
(Emacs-side, event-driven on save/idle, magit already bridged for
conflict surgery) and/or Syncthing guidance; org-aware conflict
default (both versions kept, conflict heading inserted, never silent
loss).

**Files:** `emacs/apps/glasspane/glasspane-sync.el` (autocommit +
conflict materialization), docs section; settings toggle via the
existing seam.

**Pitfalls:** autocommit cadence is a battery item — save-hook +
debounce, no timers. Don't build a sync service; the paid-tier idea
(see FOSS memory/plan) is a *later* product decision, and the floor
must be genuinely good or it poisons the conversion story.

**Acceptance:** two-device (or device + desktop) edit of the same file
produces a materialized conflict heading, not data loss; a week of
normal use produces a sane git log.

### Task 15: Zero-Emacs onboarding

**Goal:** first-run to first-note without seeing Emacs: welcome →
create/import vault → pairing handled invisibly → daily note.

**Files:** `MainActivity.kt` (first-run flow), `glasspane-config.el` /
`docs/starter-init.el` (the Emacs side already exists — this task
automates its delivery), coordination with the automation plan's
Task 11 (keep-alive/wake) — that task owns "Emacs stays invisible
*after* setup"; this one owns setup itself.

**Implementation:** the honest v1: Glasspane detects the Emacs APK,
walks the user through install if absent, and hands Emacs a prepared
starter-init + pairing token through the one deliberate manual step
(or a share-intent handoff if the spike in automation-Task 11 finds a
compliant channel). Every subsequent launch: Glasspane only.

**Pitfalls:** don't fake seamlessness we can't deliver — a *clear*
three-step setup beats a flaky "automatic" one. The pairing token
remains the trust root; never weaken the handshake for onboarding
convenience.

**Acceptance:** a tester who has never used Emacs goes from APK
install to typed-and-synced daily note following on-screen
instructions only, and never sees an Emacs frame afterward.

---

## Phase K — the KMP horizon (prep only; no migration work now)

### Task 16: Contract discipline audit (cheap, do anytime)

**Goal:** keep the companion portable by construction: verify no
app logic has crept into Kotlin beyond SPEC (the renderer's only
org knowledge should remain the opt-in `OrgEditToolbar`), and add a
CI-ish checklist: every renderer behavior traceable to a SPEC section.
The launcher/automation plans add Kotlin — this audit is the tripwire
that they add *protocol*, not *policy*.

**Acceptance:** a written conformance checklist in ARCHITECTURE.md;
divergences either spec'd or removed.

### Task 17: Compose Multiplatform desktop spike (timeboxed)

**Goal:** measure, don't assume, the port cost: extract the renderer
core (`SduiRenderer`/`SduiContentNodes`/`SduiScaffold`, codec, auth)
into a shared module compiling for desktop; stub platform services
(notifications, widgets, tiles = Android-only `expect/actual`).
Deliverable is a *report* (what moved cleanly, what's entangled), not
a product. Strategic note: desktop KMP matters **because of the
conversion goal** — for converts, the desktop app is the
Obsidian-shaped shell running a hidden local Emacs daemon; Emacs users
don't need it.

**Acceptance:** the hello/demo surfaces render in a desktop window
against a real Emacs over loopback; entanglement list recorded.

### Task 18: iOS architecture RFC

**Goal:** a written RFC, decided before any iOS code: remote-Emacs
transport (TLS or SSH tunnel — see constraints; pairing HMAC rides
inside), reconnection/offline UX on a client that is *usually* remote,
and the scope of an embedded fallback parser (orgmode-kmp) for
offline read/light-edit — **explicitly revising, for iOS only, the
standing "do not adopt orgmode-kmp" rule**, which stands unchanged on
Android where Emacs is on-device. The surface cache already gives
offline read of last-rendered UI; the RFC decides how much more iOS
needs (probably: render cached surfaces + queue actions + parse
*unseen* org files read-only).

**Acceptance:** RFC merged with the transport decision, the fallback
scope, and an explicit list of what iOS v1 does **not** do.

---

## Sequencing

```
C0: 1, 2 (the bets — do first, cheap, everything layers on them)
C1: 3, 4  ──┐                    (needs 1)
C2: 5     ──┤ independent after C0
C3: 6, 7, 8 ┘                    (needs 2; order per its design)
C4: 9      (anytime; pairs with automation-plan Task 2/3)
C5: 10, 11 (anytime; 11 shines after 13's Notion csv import)
C6: 12 → 13 (the switching lever — start 12 early, it's parallel)
C7: 14, 15 (15 coordinates with automation-plan Task 11)
K:  16 anytime · 17, 18 only when the horizon is real
```

Suggested first motions: **Tasks 1 + 2** (the bets), then **Task 5**
(cheap, instantly demoable, sets the convert-facing tone) and
**Task 12** (long pole for any real convert trial), with C1 following
Task 1's decision.

## Explicit non-goals (decided now)

- **Real-time collaboration / multiplayer** — Notion's core, massive,
  and structurally at odds with local-first single-writer Emacs.
- **Plugin-marketplace parity** — the answer is Tier 1 elisp builds
  and declarative org-apps (launcher plan L2/L3), not a plugin store.
- **Graph view v1** — demo candy; a cheap 2D canvas *maybe* ever.
- **Native markdown as a second first-class syntax** — import converts
  to org; one syntax, one feature set. Gate to revisit: import churn
  data says otherwise.
- **AI features** — no.
- **Web publish v1** — org-export exists for the motivated; not a
  conversion lever.
- **SRS / PDF annotation v1** — engines exist Emacs-side; revisit on
  demand.
