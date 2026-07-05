# Audit: Logseq features worth plundering

**Date:** 2026-07-05. **Reference:** local checkout of Logseq master
(WSL: `~/pkb/resources/logseq`) — this is the **DB-based version**
(Datascript graphs, RTC sync, E2EE, FSRS, typed objects), with the
file-graph code still present and org parsing surviving mainly as
import fodder. Read alongside
[PLAN-pkm-conversion.md](PLAN-pkm-conversion.md), which already maps
Logseq's headline features; this audit is the second-tier pass —
what's *not* yet named in any plan.

## Strategic signals (before the feature list)

1. **Logseq has left plain-text-first.** The DB version stores graphs
   in a database; `graph-parser/exporter.cljs` exists to *convert
   file graphs in* (org included), not to keep them as files.
   Org-flavored Logseq users face a one-way migration off plain text —
   they are the ripest converts PKM 13 will ever see, and the importer
   gains urgency as their file-graph mode decays. Whiteboards are gone
   from this tree; graph-view remains — both stay our non-goals.
2. **Their recurring-tasks spec is literally org repeater cookies**
   (`docs/recurring-tasks.md` documents `.+`/`++`/`+` semantics).
   Zero work for us; a conversion-marketing line for free.
3. **RTC + E2EE is their paid sync.** Validates the contemplated paid
   tier; the FOSS floor (PKM 14) stays first per plan.
4. **Tags-as-classes is the DB version's core idea** — tagging a node
   `#Book` attaches Book's typed property schema and the node appears
   in Book's table view (`components/objects.cljs`, `class.cljs`).
   This is the best available design reference for PKM 10 + 11.

## Already covered — no new tasks

Journals→PKM 5 · block refs/embeds→C3 follow-up · outliner
drag/indent→PKM 7 · queries/views→PKM 11 · importer→PKM 13 ·
WYSIWYG/slash menu→PKM 2/6/8 · sync→PKM 14 · onboarding
(their `handbooks/` guided panels are a UI pattern for PKM 15) ·
templates→capture · aliases→Task 1/3 candidate set · block zoom-in →
`glasspane-org-reader-subtree` already does it · calc blocks → babel ·
plugin marketplace / graph view / whiteboards / Zotero / comments &
reactions (RTC-coupled) → non-goals.

## New plunder candidates

Ordered by value-per-cost for the current single user, with the
roadmap slot each should ride.

### P1. Snackbar-undo for mutating actions — H3, tiny
Logseq: global undo. Us: every detail-view mutation (archive, refile,
todo-set, delete-when-it-exists, reorder) runs in a real Emacs buffer,
so `undo` already works engine-side — there is simply no phone
affordance. Plunder: mutation snackbars gain an **Undo** button →
one allowlisted `heading.undo` (scoped: undo the last wire-initiated
mutation in that file, via undo boundary pushed before each action).
Cheapest genuinely-daily win in this audit.

### P2. Favorites + Recents in the drawer — H3, tiny
Logseq mobile pins favorites in nav; `handler/recent.cljs` tracks
recents. Us: Emacs bookmarks are already bridged (tools hub), the
drawer is the agreed everyday-nav seam. Plunder: "pin" action on
files/headings (writes a bookmark) + a Favorites section and a
Recents line in the drawer. No new machinery — bookmarks + drawer.

### P3. Scheduled/deadlines panel on the daily note — fold into PKM 5
Logseq's today-journal shows a foldable "Scheduled and deadlines"
section grouped by source page (`scheduled_deadlines.cljs`). PKM 5
already plans "carried over yesterday"; add "due today" (the day
agenda extraction, reused) as a second foldable. Acceptance-criteria
edit to PKM 5, not a task.

### P4. Voice-note capture (+ optional transcription) — H4, new
Logseq mobile records audio into the quick-add inbox, with on-device
**transcription to text** where the OS provides it
(`mobile/audio_recorder.cljs`, `components/recorder.cljs`). Nothing in
our plans covers audio. Plunder: a `media.record {kind: audio}` device
capability riding the same channel and storage-boundary decision as
PKM 9 (attachment dir under `org-directory`), capture-template target,
optional Android SpeechRecognizer transcription into the entry body
with the audio file linked. Mobile-first capture at its purest; slot
beside PKM 9 in H4.

### P5. Quick-add inbox convention — PKM 5 rider, near-zero
Logseq quick capture lands on a built-in "Quick add" page, triaged
later. Us: the QS tile + share sheet already capture via templates;
plunder is the *convention* — seed a default inbox capture template
(`inbox.org`), badge the daily-note view with inbox count, one-tap
refile from there (refile is already bridged). Config-dir seeding at
stock values, per contract.

### P6. Per-file history via git — H4, cheap given magit
Logseq shows per-page version history. Us: magit is already bridged
and the FOSS sync floor (PKM 14) assumes git-autocommit. Plunder: a
"History" entry in file properties → commits touching the file
(`git log -- FILE`), tap to view diff (diff shading exists), restore
via revert. Pure composition of landed pieces; also makes PKM 14's
autocommit visible/trustable.

### P7. Search scope chips + in-buffer find — H3-optional
Their cmdk palette filters one search across groups: current page,
nodes, **code blocks**, commands, files. Us: search view, files.grep,
and the command palette are separate; the buffer view has no in-view
find. Plunder: scope chips on the existing search view (This file /
Headings / Code / Files) mapping to org-ql `src` / grep restrictions —
and a find-in-buffer affordance for Tier 0 views. Nice-to-have; do
when search next gets touched.

### P8. Tag-class property schemas — design input to PKM 10/11
Per signal 4: key PKM 10's property-schema registry **by tag**, so
tagging a heading `:book:` makes the detail form render Book's typed
fields, and a PKM 11 saved view "all `:book:`" gets its columns from
the same schema. One registry serves both tasks; write it into their
design sections now so neither task invents its own shape.
*(2026-07-05 update: the PKM Task 1 engine decision landed on
**vulpea v2** — `vulpea-schema-define` (tag predicates, typed fields,
note-typed relations) is this registry; PKM 10/11 target it rather
than inventing one.)*

## Parked, with one-line upgrades

- **Flashcards:** Logseq moved to **FSRS** (`extensions/fsrs.cljs`).
  When SRS unparks, phone review is the killer surface. **Decided
  2026-07-05: the implementation will be a Tier-1 skin over
  `org-srs`** (FSRS-native Emacs package) — not org-fc, not a port.
  Upstream org-srs recently added functionality for Android hosts,
  which derisks on-device review. Stays parked.
- **PDF annotation:** real phone use case, heavy machinery
  (highlight→block links). Stays parked behind demand; org-noter is
  the engine when it comes.
- **Asset library** (`components/library.cljs`): an attachments
  browser; fold into PKM 9's acceptance ("attachment dir browsable in
  files view") rather than a feature.

## Suggested roadmap insertions

- **H3:** P1 (undo snackbar), P2 (favorites/recents), P3+P5 (PKM 5
  riders), P7 opportunistically.
- **H4:** P4 (voice capture, beside PKM 9), P6 (file history).
- **Design edits now, no code:** P8 into PKM 10/11.
- **PKM 13:** add a line — target org-flavored file graphs *before*
  the DB migration wave makes them extinct; the DB version's own
  importer (`graph-parser/exporter.cljs`) documents their md/org
  quirks and is a free test oracle for ours.
