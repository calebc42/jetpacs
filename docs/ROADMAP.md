# Roadmap — the Jetpacs foundation

**STATUS (2026-07-16): current.** This is the *foundation* roadmap: the
wire, the core elisp client, the `:jetpacs` renderer library, and the
reference companion shell. The **app-level roadmap** — the Glasspane org
app, PKM conversion, the automation/launcher feature tracks, on-device
acceptance — lives with the
[glasspane repo](https://github.com/calebc42/glasspane) and its
`docs/PLAN-*.md`. This revision is **transport-first**, informed by the
2026-07-14 survey of the Termux repos (termux-app, termux-api,
termux-gui, termux-widget — production prior art for the UDS transport,
FGS battery discipline, the device-API catalog, and external automation
ingress); the previous (2026-07-13) ordering, and the pre-split unified
roadmap before it, are in this file's git history.

The platform now includes the **declarative binding layer + engine-pack
seam** (api 1.5.0: `jetpacs-defsource`, `:spec` views, the action
catalog — [BINDING.md](BINDING.md)) and the **`jetpacs-org` primitive
layer** (the one org query/mutation grammar, confined to its module).
The standing thesis is *rich server, thin client*: expressiveness comes
from Emacs and its package ecosystem (vulpea, org-ql — installed as pack
dependencies by the composer), never from widening the wire grammar
(see `Glasspane/docs/DECISION-no-binding-template-dsl.md`).

## The meta-goal

**Adoptability.** The foundation should outlive any single app and any
single maintainer: a stranger can build a Tier 1
([BUILDING-TIER1.md](BUILDING-TIER1.md)) or a companion
([BUILDING-COMPANION.md](https://github.com/calebc42/ebp/blob/main/BUILDING-COMPANION.md)
in the ebp protocol repo) without asking anyone's
permission, and a future maintainer inherits a versioned, negotiable,
tested platform (the completed
[PLAN-platform-hardening.md](PLAN-platform-hardening.md)). Every item
below is weighed against that.

The wire contract itself is **extracted**: SPEC, `contract.json`, and
the golden conformance corpus live in the
[ebp repo](https://github.com/calebc42/ebp), pinned here as the
`ebp/` submodule ([PLAN-ebp-extraction.md](PLAN-ebp-extraction.md)
is the record) — the pinnable surface a third-party companion depends
on without depending on this repo's layout.

The org-logic consolidation is **done**: the core owns the one query
grammar and both consumers stand on it
([PLAN-org-extraction.md](PLAN-org-extraction.md) is the record).

## Now — the aligned execution path (2026-07-16)

Three review tracks merged on this date —
[AUDIT-architecture-vui-vulpea.md](AUDIT-architecture-vui-vulpea.md)
(arch N.N below), [PLAN-easer-adoptions.md](PLAN-easer-adoptions.md)
(Easer A–F), and
[AUDIT-termux-api-guidance.md](AUDIT-termux-api-guidance.md) (Termux
A1/A2/B2) — and their items interleave with the standing numbered
items below as **lanes**. Lanes touch disjoint code and run in
parallel; order *within* a lane is load-bearing. Already landed with
the merge: the fireRow receiver-thread crash fix (Easer Item A,
`53b23e8`) and the launch-trampoline token (Termux A3, `ce7c9d3`).

- **Defects lane — first, three repos in parallel.** jetpacs core:
  async settle hardening + snackbar restore (arch 1.5 + defect 4, one
  sitting). glasspane: the `glasspane-vulpea.el` rewrite (arch 1.1).
  composer: `:requires-ast t` (arch 1.2). Then the CI engine-smoke
  (arch 1.3) that would have caught both integration breakages.
- **Measurement lane — jetpacs elisp.** Devtools/instrumentation
  (arch 1.4) immediately after the core defects: it unblocks every
  measurement gate below. Then the independent smalls: `:key` attr
  (arch 1.6), ui-state scope (arch 2.6), `:on-enter`/`:on-leave`
  (arch 2.7).
- **Companion lane — Kotlin, ordered.** Easer B (firing history) → C
  (`manual` + `trigger.fire`; the one contract.json-touching item) →
  Termux A1 (runtime-permission auto-request) → Easer D (catalog
  parity) → E (`state.edge`, the keystone) → F (`trigger_unavailable`).
  Termux A2 (`error_codes` in the contract) rides item 11's
  conformance track instead, beside a contract regen.
- **Glasspane lane — opens after arch 1.1.** Vulpea A.4 execution
  (arch 2.1) → worker-done repush seam (2.2) → schema forms/health
  (2.3) and database views (2.4) in either order.
- **On-device / owner lane.** Termux B2 (the wake-Emacs spike: one
  `RUN_COMMAND` manifest line, then an `intent.start` evening); the
  Easer items' acceptance rows as they land; battery B0
  (calendar-bound; still gates transport S5 and new surface classes,
  item 2).

Two reconciliations recorded so nothing is built twice: arch 2.5
(visibility-gated pushes, an inbound `app.lifecycle` event) and the
battery plan's B3 (screen-state frame) are two drafts of **one
signal** — design them as a single negotiated addition, owner
sign-off on the wire change. And Tier 3 (arch 3.1 build reuse → 3.2
transcript deltas → 3.3 renderer skippable model) stays strictly
behind arch 1.4's measurements — do not start early.

## Near term

1. **Transport 1.0: profiles + peer-credential UDS**
   ([PLAN-transport-profiles.md](PLAN-transport-profiles.md)) —
   promoted from mid-term. SPEC §1 becomes a profile table (`uds` /
   `tcp-loopback` / `tcp-remote`) with a per-profile auth floor: the
   UDS rung adds kernel-verified peer identity (SO_PEERCRED, pinned at
   pairing) under the existing HMAC, the remote rung is tunnel-first
   for the future KMP/iOS client, and one paragraph splits *who dials*
   from *who speaks first* so the remote direction never needs a
   breaking change. Supersedes the old "shared-signature directory"
   wording. §1 is outside the 1.0-rc freeze surface, so this proceeds
   in parallel with item 11's in-flight work.
2. **Battery: profile, then discipline**
   ([PLAN-battery-discipline.md](PLAN-battery-discipline.md)) — the
   old "battery profiling" item, expanded with the termux-proven
   lifecycle patterns: a published baseline (B0) **lands before item
   1's default flip** so the UDS switch gets a measured delta — that
   adjacency is the pairing; then idle self-stop, the opt-in
   notification wakelock toggle, and screen-state throttling of client
   pushes; then re-profile and delete "unprofiled" from the README.
3. **Generic onboarding + Tier-1 app delivery.** The `:app` shell is
   still Glasspane-branded, and the repo split left a hole flagged in
   `app/build.gradle.kts` (`TODO(repo-split)`): the onboarding wizard
   can no longer stage `glasspane.el` as an APK asset, so its "install
   the app bundle" step degrades. Design the real story: a companion
   that onboards for *the foundation* (pair, install `jetpacs-core.el`,
   demo `jetpacs-hello.el`) and delivers any Tier-1 bundle — Glasspane
   as the first payload, not a hardcoded special case. Sequenced
   *after* transport S3 so the pairing wizard bakes in the
   trust-on-first-use pin step once, not twice.
4. **Hardening residue — landed** (`dff6388`, "three-leg node-type +
   contract drift gates"): the Kotlin `SduiRendererNodeTypesTest` pins
   `SDUI_NODE_TYPES` to the renderer's `when (type)` cases — completing
   the node-type mirror (lint = golden = set = dispatch) — and the elisp
   `jetpacs-api-stability-symbols-bound` sweep asserts every symbol named
   in [API-STABILITY.md](API-STABILITY.md) (212 today) is bound. Both run
   in the standing suites; nothing outstanding here.
5. **MELPA packaging.** Explicitly deferred until after the repo split;
   the split is done. Package the elisp client properly (the
   `emacs/core/` sources are already package-shaped; the bundle stays
   for the no-package-manager path). Middle path available now:
   `package-vc-install '(jetpacs :url … :lisp-dir "emacs/core")`
   installs and tracks straight from git (hardening Task 24) — MELPA
   remains only about discoverability.

## Mid term

6. **Device layer, automation ingress, and new surface classes**
   ([PLAN-device-and-surfaces.md](PLAN-device-and-surfaces.md)) — the
   vetted picks from the termux-api catalog as registry additions
   (notification-listener event source, JobScheduler constraint
   triggers, Keystore-backed secrets, speech input for prompts);
   **absorbs the old wifi.ssid/bluetooth.device item** as its Task 3
   (the permission-degrade design is the point; hardware-gated); the
   Tasker-class allowlisted intent surface (default off,
   §5-actions-only, RUN_COMMAND posture); and Device Controls +
   PiP/overlay/lockscreen as new companion surface classes.
   Companion engine plan:
   [PLAN-conditions-and-dynamics.md](PLAN-conditions-and-dynamics.md) —
   the 2026-07-14 Easer survey's yield: a `when` state-gate layer +
   `state.get` sampling, `${…}` placeholder dynamics in `on_fire`, and
   the adapter/calendar/SMS/call trigger batch (deliberately overriding
   the device plan's SMS reject, see its amended Rejects row). Its
   predicate catalog is designed so Task 3's `wifi.ssid`/`bluetooth.device`
   slot in as `state_types` entries.
7. **Pinned lifecycle semantics, then a second companion.** The
   strongest possible validation of the spec — desktop tray, e-ink,
   TUI, anything
   ([BUILDING-COMPANION.md](https://github.com/calebc42/ebp/blob/main/BUILDING-COMPANION.md)
   is the invitation; the ebp repo's goldens + `validate.py` are the
   conformance kit). Now explicitly gated on the
   device plan's Task 9: SPEC must pin the visibility/queueing/
   lifecycle rules (termux-gui `Protocol.md` is the model) before a
   clean-room implementer can be expected to get them right.
8. **PRIM residue: point/region indication** in the Tier 0 buffer
   renderer (optional polish;
   [PLAN-primitive-completeness.md](PLAN-primitive-completeness.md)
   Task 15).

## Long term

9. **Port the pane (KMP).** The companion is a thin renderer by
   contract; a Kotlin Multiplatform port (Compose Desktop, iOS against
   a remote Emacs) is "port the pane, keep the brain." The
   `:jetpacs`/`:app` module split is the extraction seam. Gated on the
   conformance kit (item 11) **and on transport S0/S4** — the
   `tcp-remote` profile and the dial-direction split are what make
   "iOS against a remote Emacs" a spec-conforming sentence rather than
   an architecture change.
10. **F-Droid distribution** of the reference companion — the natural
    channel for this project's audience, and the forcing function for
    release hygiene (versioning, reproducible builds, changelogs).
11. **Spec 1.0.** Freeze the wire
    ([PLAN-spec-freeze.md](PLAN-spec-freeze.md) — **in flight**:
    1.0-rc declared, the freeze surface named, the
    [SPEC-CHANGES.md](https://github.com/calebc42/ebp/blob/main/SPEC-CHANGES.md)
    amendment log instituted): the
    envelope, handshake, and §4–§6 semantics stop being "draft".
    Additive node-vocabulary growth continues through negotiation and
    is explicitly *not* a version bump (SPEC §3).

## Standing gates (checked on every substantial change)

- **Battery:** no feature that adds background work lands without
  stating its cost; event-driven over polling, always.
- **Contract:** every companion behavior traceable to a SPEC section
  (the ARCHITECTURE conformance table is the tripwire); protocol in
  `:jetpacs`, opinion in `:app`.
- **Boundary:** every new wire action is allowlisted, validated, and
  documented in SPEC §5 — no exceptions for "internal" features. The
  declarative binding grammar ([BINDING.md](BINDING.md)) is likewise closed
  data compiled to allowlisted nodes/actions, never code on the wire.
- **Bundle + goldens:** `jetpacs-core.el` regenerated with every
  `emacs/` change; goldens regenerated only for intentional wire
  changes, documented in SPEC.
