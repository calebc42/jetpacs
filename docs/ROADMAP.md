# Roadmap: unified prioritization across all plans

**STATUS (2026-07-05): current.** This is the cross-plan ordering; the
task bodies live in their plan docs. When this doc and a plan's
internal sequencing disagree, **this doc wins** (the two deliberate
overrides are marked ⚠ and justified inline).

Task references:
- **PRIM n** — [PLAN-primitive-completeness.md](PLAN-primitive-completeness.md) (all phases done; residue only)
- **AUTO n** — [PLAN-automation-and-launcher.md](PLAN-automation-and-launcher.md) (Tasks 1–13 + 14–19 = launcher track)
- **PKM n** — [PLAN-pkm-conversion.md](PLAN-pkm-conversion.md) (Tasks 1–15 conversion, 16–18 KMP)
- **ORGRO: item** — the orgro-parity backlog (LaTeX, sparse filter,
  org-crypt, org-protocol, link nav, timestamp tap-edit)

## The principles behind the order

1. **Verified before new.** Outstanding on-device verification is debt;
   it goes first because everything else stacks on those paths.
2. **Protocol before features.** AUTO 1–2 are a day of paper + stubs
   that unblock both the automation and launcher tracks and one PKM
   task. Nothing else has that fan-out.
3. **You-first, converts-later.** There is exactly one user today, and
   they read org syntax fluently. Features that user runs daily
   (automation, agenda, capture, linking) outrank convert-facing
   polish (import, onboarding, WYSIWYG) — the PKM plan's convert
   deliverables are *parked*, not cancelled, with an explicit unpark
   trigger.
4. **Battery gates between horizons.** Measure before stacking
   (standing project rule); the FGS-rides-free hypothesis for triggers
   gets tested before more device integration lands on top.
5. **Absorb, don't duplicate.** Orgro-parity items that overlap funded
   tasks ride along (link nav → PKM 1/3/4; timestamp tap-edit →
   PKM 5) instead of being scheduled twice.
6. **Kotlin additions get the tripwire.** PKM 16 (contract-discipline
   audit) runs right after the first wave of automation Kotlin, so the
   companion stays a portable renderer while it grows.

Within a horizon, the streams listed are independent and safely
parallel; horizons themselves are ordered.

**Completed pre-work (2026-07-05):** the Kotlin side is now two Gradle
modules — `:jetpacs` (protocol + renderer library, host-agnostic by
construction: `JetpacsLaunch` / `JetpacsToolbars` seams) and `:app` (the
Glasspane shell). This is the in-repo half of the repo-split decision
(see ARCHITECTURE.md); it gives PKM 16 its enforcement point and PKM 17
its extraction seam, and future Kotlin from AUTO tasks lands in `:jetpacs`
only if it is protocol, in `:app` if it is opinion. CI
(`.github/workflows/ci.yml`) now runs the three elisp test entry
points, the bundle-freshness check, and both Gradle modules on every
push/PR — the automated half of the standing gates below. Contribution
rules consolidated in CONTRIBUTING.md.

---

## Horizon 0 — ✅ closed 2026-07-05

On-device verification done: magit commit end-to-end, diff shading,
live compile refresh (PRIM residue). Stays deferred deliberately:
PRIM Task 15 (point/region indication — optional polish); PRIM
inline-images follow-up is absorbed by PKM 9 in Horizon 4.

## Horizon 1 — protocol seams + three quick wins (current)

| order | item | why |
|---|---|---|
| 1 ✅ | **AUTO 1 + AUTO 2** — `triggers.set` / `trigger.fired` spec; `capability.invoke` + device-permission map | Landed 2026-07-05: SPEC §10–§11, `jetpacs-triggers.el`, capability helpers, `DeviceCapabilities.kt` (`settings.open` first), `frames.golden` |
| 2 (par.) ✅ | **AUTO 3 + AUTO 4** — intent escape hatch; permission-free effectors | Landed 2026-07-05: 12-cap catalog in `DeviceCapabilities.kt` + `jetpacs-device.el`; REPL pass on device pending |
| 2 (par.) ✅ | **AUTO 14 (launcher Task 14)** — `jetpacs-defapp` + home + per-app chrome | Landed 2026-07-05: `jetpacs-apps.el` + shell filter seam; Glasspane is the first defapp, jetpacs-hello the second; on-device check pending |

## Horizon 2 — the minimum usable automation loop

| order | item | why |
|---|---|---|
| 1 ✅ | **AUTO 6** — trigger host, persistence, boot receiver | Landed 2026-07-05 (TriggerHost.kt, boot rearm, reminder reboot fix); on-device acceptance pending |
| 2 ✅ | **AUTO 7** — trigger batch 1 (time/power/battery/screen/…) | Landed 2026-07-05 with AUTO 6 (9 types, SPEC §11 catalog); on-device checks pending |
| 3 ✅ | **AUTO 12** ⚠ — `jetpacs-deftrigger` + Automations view | Landed 2026-07-05 (macro, toggles via Customize, test-fire, jetpacs-automations.el); on-device pass pending |
| 4 ✅ | **AUTO 10** — companion-local `on_fire` | Landed 2026-07-05 (cap invocations + notify posts in TriggerHost); on-device pass pending |
| any 🟡 | **AUTO 11** — wake spike (timeboxed) | Docs half landed 2026-07-05 (ARCHITECTURE "Execution model"); Termux silent-start spike needs hardware |
| after Kotlin lands ✅ | **PKM 16** — contract-discipline audit | Done 2026-07-05: conformance checklist in ARCHITECTURE.md; one divergence found (on_change `value` injection) and spec'd into §9 |

**⛔ GATE (deferred to the H3→H4 boundary, decided 2026-07-05):**
battery profile of a normal day with a real trigger set (screen +
power + a time trigger) active; expectation is ≈0 delta over the
existing FGS. H3 landed ahead of the measurement because the user was
away from hardware and H3 is elisp-side value; the gate still blocks
H4's heavier device integration. Protocol + the full pending
acceptance list: [TESTING-ON-DEVICE.md](TESTING-ON-DEVICE.md).

## Horizon 3 — daily-driver org value (self-serving PKM + orgro absorption)

| item | why |
|---|---|
| ✅ **PKM 5** — daily-note landing surface (absorbs ORGRO: timestamp tap-edit via carried-over reschedule) | Landed 2026-07-05: glasspane-journal.el (datetree, carried-over reschedule, landing setting) |
| ⏸ **PKM 1** — backlink-engine spike/decision (vulpea v2 decided; spike = on-device validation) | Hardware-gated: cold-index/incremental/memory numbers need the phone |
| ✅ **PKM 3 → PKM 4** — wikilink autocomplete; backlinks panel + unlinked mentions | Landed 2026-07-05 ahead of the spike (glasspane-notes.el; degrades to absent without vulpea); on-device pass + spike numbers pending |
| ✅ **PKM 11** — saved org-ql queries as table/board/calendar views | Landed 2026-07-05: glasspane-views.el (hub + 3 renderings over glasspane-org--query) |
| 🟡 **AUTO 8** — connectivity triggers (network/SSID/BT) | `network` landed 2026-07-05; SSID/BT hardware-gated (their value is the permission-degrade flow) |
| ✅ **AUTO 13** — org-defined automations | Landed 2026-07-05: glasspane-automations.el (automations.org, DONE = disabled, case test) |
| ✅ **ORGRO: sparse filter** | Landed 2026-07-05: files.filter row over the org read-mode heading list |

## Horizon 4 — launcher maturity + heavier device integration

| item | why |
|---|---|
| **AUTO 9** — notification listener (trigger + effectors) | Tasker's most-loved trigger; isolated because of special access + privacy review |
| **AUTO 15 → 16 → 17 (launcher Tasks 15–17)** — offline app switching; shortcuts/pinning; widget/tile slot picker | The "installed app" illusion, in dependency order |
| **PKM 9** — inline images + photo capture | Settles the cross-app storage-boundary question; genuine personal value (photos in notes), convert-critical later; needs AUTO 2/3 (H1) |
| **PKM 10** — typed property forms | Drawer syntax disappears from the detail view; reuses the settings-controls pattern |
| **AUTO 5** — special-access effectors (brightness, DND) | Opportunistic — pull earlier any time a real automation wants one |
| **ORGRO: LaTeX** — make the TeX-vs-KaTeX decision, then implement | The decision is the blocker, not the work; stop carrying it undecided |

## Horizon 5 — convert-facing (parked, not cancelled)

**Unpark trigger:** a concrete second user in sight — an F-Droid
release push, or a real Obsidian/Logseq/Notion convert willing to
trial. Until then this horizon accrues design notes only.

- **PKM 2** ⚠ — editing-model design, then **PKM 6 → 7 → 8** (conceal,
  structural manipulation, slash menu). **Override:** the PKM plan
  calls Task 2 an early bet; cross-plan it moves here because the sole
  current user reads org natively and the standing scope rule is
  "usable, not IDE" — the bet still precedes its dependents, just
  later. Exception kept: if any earlier editor work would touch
  editor-sync rendering, PKM 2's design gets written first.
- **PKM 12 → 13** — Obsidian/markdown, then Logseq + Notion importers
  (the switching lever; PKM 13's csv→drawers demo pairs with the
  already-landed PKM 11).
- **PKM 14** — FOSS sync floor. **PKM 15** — zero-Emacs onboarding
  (consumes AUTO 11's spike results).
- **AUTO 18 → 19 (launcher Tasks 18–19)** — build import with consent;
  declarative org apps. (19 may pull into H4 on personal desire — it's
  useful without converts.)
- **ORGRO: org-crypt, org-protocol** — org-protocol is mostly a
  desktop concern (share sheet already covers Android capture).

**Parked separately (no horizon):** PKM 17–18 (KMP desktop spike, iOS
RFC) — wake them only when KMP stops being "much down the line".
PKM 16 is the exception and already lives in H2.

## The next five concrete actions

1. AUTO 1 + 2: write SPEC §11 + the capability section; land the
   Emacs/Kotlin stubs.
2. AUTO 3 + 4: `DeviceCapabilities.kt` + `jetpacs-device.el`, effectors
   green from the REPL.
3. AUTO 14: `jetpacs-defapp` + home view, Glasspane as the first app,
   zero visible change single-app.
4. AUTO 6: trigger table + boot receiver + firing pipeline.
5. AUTO 7: trigger batch 1 (time/power/battery/screen/…).

## Standing gates (checked at every horizon boundary)

- **Battery:** no horizon exit without knowing what the last one cost.
- **Contract:** new Kotlin traceable to a SPEC section (PKM 16
  checklist once it exists).
- **Boundary:** every new wire action is allowlisted, validated,
  documented in SPEC §5 — no exceptions for "internal" features.
- **Bundles + goldens:** regenerated on every wire change; case tests
  on every new org regex.
