# Roadmap — the Jetpacs foundation

**STATUS (2026-07-13): current.** This is the *foundation* roadmap: the
wire, the core elisp client, the `:jetpacs` renderer library, and the
reference companion shell. The **app-level roadmap** — the Glasspane org
app, PKM conversion, the automation/launcher feature tracks, on-device
acceptance — lives with the
[glasspane repo](https://github.com/calebc42/glasspane) and its
`docs/PLAN-*.md`. The pre-split unified roadmap ordering both worlds is
in this file's git history.

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
([BUILDING-COMPANION.md](BUILDING-COMPANION.md)) without asking anyone's
permission, and a future maintainer inherits a versioned, negotiable,
tested platform (the completed
[PLAN-platform-hardening.md](PLAN-platform-hardening.md)). Every item
below is weighed against that.

The org-logic consolidation is **done**: the core owns the one query
grammar and both consumers stand on it
([PLAN-org-extraction.md](PLAN-org-extraction.md) is the record).

## Near term

1. **Generic onboarding + Tier-1 app delivery.** The `:app` shell is
   still Glasspane-branded, and the repo split left a hole flagged in
   `app/build.gradle.kts` (`TODO(repo-split)`): the onboarding wizard
   can no longer stage `glasspane.el` as an APK asset, so its "install
   the app bundle" step degrades. Design the real story: a companion
   that onboards for *the foundation* (pair, install `jetpacs-core.el`,
   demo `jetpacs-hello.el`) and delivers any Tier-1 bundle — Glasspane
   as the first payload, not a hardcoded special case.
2. **Hardening residue** (small, from the completed plan's deferred
   acceptance notes): a Kotlin-side unit test pinning `SDUI_NODE_TYPES`
   against the renderer's `when` cases (the drift guard's other half),
   and an `fboundp` sweep asserting every symbol promised in
   [API-STABILITY.md](API-STABILITY.md) is bound.
3. **MELPA packaging.** Explicitly deferred until after the repo split;
   the split is done. Package the elisp client properly (the
   `emacs/core/` sources are already package-shaped; the bundle stays
   for the no-package-manager path).
4. **Battery profiling.** The standing unmeasured gate: a normal day's
   cost of the FGS plus a real trigger set. Publish the numbers in the
   README — "unprofiled" is the word we most need to delete for
   credibility.

## Mid term

5. **Transport 1.0: the signed Unix domain socket.** The v0 loopback
   TCP socket trusts the pairing HMAC alone; the 1.0 target adds a UDS
   in a shared-signature directory (SPEC §1). Only the connection
   bootstrap changes on either side — that claim is the test.
6. **A second companion.** The strongest possible validation of the
   spec — desktop tray, e-ink, TUI, anything
   ([BUILDING-COMPANION.md](BUILDING-COMPANION.md) is the invitation;
   the goldens are the conformance kit). First-party or contributed;
   what matters is that it's written against SPEC.md, not against the
   Kotlin.
7. **The remaining trigger batch.** `wifi.ssid` and `bluetooth.device`
   (SPEC §11 reserves them): their value is the permission-degrade
   design — degrade to `network` transport matching when ungranted,
   never fire garbage. Hardware-gated.
8. **PRIM residue: point/region indication** in the Tier 0 buffer
   renderer (optional polish;
   [PLAN-primitive-completeness.md](PLAN-primitive-completeness.md)
   Task 15).

## Long term

9. **Port the pane (KMP).** The companion is a thin renderer by
   contract; a Kotlin Multiplatform port (Compose Desktop, iOS against
   a remote Emacs) is "port the pane, keep the brain." The
   `:jetpacs`/`:app` module split is the extraction seam.
10. **F-Droid distribution** of the reference companion — the natural
    channel for this project's audience, and the forcing function for
    release hygiene (versioning, reproducible builds, changelogs).
11. **Spec 1.0.** Freeze the wire: the envelope, handshake, and §4–§6
    semantics stop being "draft". Additive node-vocabulary growth
    continues through negotiation and is explicitly *not* a version
    bump (SPEC §3).

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
