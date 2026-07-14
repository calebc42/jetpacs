# PLAN: Spec 1.0 freeze + cross-implementation conformance kit

STATUS (2026-07-14): PLANNED — nothing landed. Branch `feat/spec-freeze` is cut
from main `280f182` (api 1.10.0). Stage designs were source-verified during the
2026-07-13 planning session; the "state of the world" section below updates
them for what landed since. This is Part V of the elisp-expansion program
(Parts I–IV: hypertext substrate, magit-section substrate, TRAMP hosts hub —
all merged).

## Why

Freeze the wire protocol as a normative Spec 1.0 with a machine-checkable
conformance kit, so any future implementation — a fork's, a community
Rust/Flutter companion, an LLM's — is *verifiable* rather than trusted.
This is also the honest provenance story for an LLM-assisted codebase:
credibility attaches to a human-reviewed spec plus fixtures consumed by two
independent implementations, not to who typed the code. ROADMAP already
names "freeze Spec 1.0" (item 11) and the KMP port as long-term direction.

## State of the world (verified; supersedes older notes)

- `jetpacs-api-version` = **1.10.0**; `contract_format` = 1; frame
  `protocol_version` = 1. Version-coherence already machine-checked:
  `jetpacs-version-header-pinned-to-api` (Version: header ↔ defconst),
  `jetpacs-contract-artifact-current` (byte-pins docs/contract.json),
  `jetpacs-api-stability-symbols-bound` (every backticked API-STABILITY
  symbol exists), and the lint = widgets.golden = Kotlin `SDUI_NODE_TYPES`
  equality test.
- **Three golden layers now**: `test/widgets.golden` (per-constructor node
  shapes, regen `jetpacs-tests-regen-widget-golden`), `test/frames.golden`
  (kind-level frame payloads, regen `jetpacs-tests-regen-frame-golden`),
  and `test/hypertext.golden` (document-emitter output, regen
  `jetpacs-tests-regen-hypertext-golden`). Session transcripts become the
  *fourth* layer.
- `docs/contract.json` is **generated** from `jetpacs-lint.el` tables by
  `emacs/build-contract.el`. Gotcha: loading defines only — regen is
  `emacs --batch -l emacs/build-contract.el -f jetpacs-contract-write`.
- The lint tables are typed-attribute (numeric/color/action classes + a
  flat node-type list). There is **no per-node required/optional field
  registry** — that authoring is Stage 1's real work.
- Kotlin: `Envelope.kt` (Frame + Kind) and `FrameCodec.kt`
  (NdjsonFrameCodec) are JVM-pure; `JetpacsConnection`/`JetpacsAuth`/
  `JetpacsServer` import android.* — so the **behavioral** conformance leg
  lives in ERT (drive `jetpacs--filter` headless), the **structural** leg
  in JUnit. Plain-JVM unit tests get Android's stubbed `org.json`: Stage 2
  needs `testImplementation("org.json:json:…")` in `jetpacs/build.gradle.kts`.
  Repo-file discovery pattern: `SduiRendererNodeTypesTest.kt`'s directory
  walk. Gate: `gradlew :jetpacs:testDebugUnitTest`.
- Elisp protocol core: `emacs/core/jetpacs.el` (codec/socket/handshake/
  negotiation; the send point and `jetpacs--filter` are where a transcript
  sink taps). Naming constraint: `jetpacs-spec.el` exists (data-view
  compiler) — the transcript module must not be called "spec"
  (`jetpacs-transcript.el`).
- Freeze surface (ROADMAP item 11): envelope + handshake + SPEC §4–§6
  semantics; §7–§11 negotiated/optional; node-vocabulary growth stays
  additive via negotiation and is **not** a version bump.
- Since the stage design, additive action strings landed (hypertext.nav,
  sections.menu/visit, hosts.*) — actions are registry entries, not frame
  kinds; SPEC deliberately doesn't enumerate per-substrate action strings.

## Environment & conventions (for a fresh session)

- Suite gate: `wsl -d Debian -- test/run-tests.sh` (core-load guard + ERT,
  currently **167/167**; batch Emacs 30.1, always `</dev/null` + timeout).
- Bundle regen after any emacs/core edit:
  `emacs --batch -l emacs/build-bundle.el` → commit `jetpacs-core.el` too.
  New core files wire in FOUR places: build-bundle list, core-load-test
  requires, jetpacs-tests requires, bundle regen.
- Repo is LF (`* text=auto eol=lf`); check new files with `tr -cd '\r' | wc -c`.
- **Never write/stage `docs/PLAN-elisp-expansion.md`, `docs/AUDIT-package-skins.md`,
  or root `hello-world.org`/`tasks.org`** (owner-authored / other lanes).
  Stage files explicitly; never `git add -A`.
- Owner pushes; agent sessions have no SSH creds. main is ahead of origin.
- Action-handler table for tests: `(gethash "name" jetpacs-action-handlers)`.

## Stages (each independently landable; no wire changes anywhere)

**S0 — Freeze bookkeeping (S, 1 evening).** `docs/SPEC.md` status block →
`1.0-rc` naming the freeze surface + amendment policy; new
`docs/SPEC-CHANGES.md` amendment log (date/section/change/fixture-regen/
reviewed-by — the sign-off ritual IS the provenance artifact); ERT
version-coherence test extended to the SPEC header version. Accept: suite
green, zero behavior change. *S0 alone stops spec drift during alpha.*

**S1 — Node/payload schema registry (M–L, 2–4 evenings; the authoring
stage).** New tables in `emacs/core/jetpacs-lint.el`:
`jetpacs-lint-node-schema` (per node type: required/optional keys, type
class per key reusing existing classes) + a frame-kind table (kind →
payload keys, both directions, mirroring `Kind` in Envelope.kt and SPEC
§§4–8, 10–11). Extend `jetpacs-lint-spec` to enforce (unknown key on known
node = warning, missing required = error) with negative ERT cases. Extend
`build-contract.el` → `contract_format: 2` adding `node_schema` /
`kind_schema` / `spec_version` in contract.json's own required/optional
idiom (NO JSON-Schema-draft dependency). Bootstrap the key sets
mechanically from widgets.golden ∪ constructor signatures in
`jetpacs-widgets.el`, hand-review against WIDGETS.md + SPEC §9, log the
review as SPEC-CHANGES entry #1. Accept: every widgets/frames/hypertext
golden line validates; a seeded bad field fails; byte-pin regen intentional.
*Hard stop: if authoring reveals widespread golden/SPEC §9 disagreement,
that's a correctness finding — stop and reconvene.*

**S2 — Kotlin conformance leg A: golden replay (M, 2 evenings). THE MVP
LINE.** Add real org.json test dep; new `WireGoldenConformanceTest.kt`
(directory-walk): every frames.golden line parses via `Frame.fromJson`,
v==1, kind ∈ schema, payload keys ⊆ schema, single-line NDJSON round-trip
stability; every widgets.golden tree validates node types + keys + action
schema; `NdjsonFrameCodec` re-reads the corpus as a byte stream (tolerating
blank keep-alives). Fallback if S1 slips: land against contract_format 1
(kinds/node-types/action_schema only). Accept: all golden lines green under
`:jetpacs:testDebugUnitTest`; seeded bad line fails; no `main` changes.
Stopping after S2 is respectable: "machine-checkable frozen contract,
verified by two implementations."

**S3 — Wire transcripts + ERT session replay (M–L, 2–3 evenings + one
live-phone evening; riskiest).** Nil-default `jetpacs--transcript-sink`
consulted at jetpacs.el's send point and inside `jetpacs--filter` (the only
runtime edit in the whole plan). Dev-only `emacs/core/jetpacs-transcript.el`:
record/stop commands → `test/transcripts/NAME.transcript`, one frame per
line prefixed `> ` (client→companion) / `< `. Canonicalization is normative,
in the file header: id remap preserving reply_to links; auth
nonce/mac/server_proof → shape tokens (never store real material); key sort
via the tests' canonicalizer; per-transcript volatile-field allowlist.
Record 3–5 sessions (pairing/negotiation; surface push → tap →
state.changed; offline queue replay/drained; dialog/toast; triggers.set +
capability round-trip). ERT replay: feed `< ` lines through
`jetpacs--filter` on a fake process, capture sends via the sink,
canonical-compare. *Kill-valve: 2-evening timebox on canonicalization →
synthetic transcripts composed from frames.golden sequences.* Accept:
replay green headless; re-recording the scripted session is canonically
identical; suite green with sink nil.

**S4 — Kotlin conformance leg B: transcript validation (S–M, 1–2
evenings).** `TranscriptConformanceTest.kt`: direction-aware parse, v==1,
kind legal per direction, payloads schema-valid, reply_to referential
integrity, handshake-ordering sequence assertions. Explicitly NOT
behavioral companion emulation (android imports; that seam belongs to the
future KMP item). Depends: S1+S2+S3.

**S5 — Declare Frozen 1.0 + provenance (S–M, 1–2 evenings).** SPEC status →
`Frozen 1.0`; §12 rewritten operationally: conforming = passes the kit —
enumerate the normative artifacts (contract.json format 2, the three
goldens, transcripts, both suites). New `docs/PROVENANCE.md`: the
artifact-attached provenance model — human-reviewed spec + SPEC-CHANGES
sign-off, dual-consumed fixtures, rewrite-must-pass-kit-before-merge,
honest LLM-assistance disclosure and why artifact gates substitute for a
two-team clean room. ROADMAP item 11 → done; KMP item annotated "gated on
the conformance kit". Degrades to goldens-only wording if S3 was killed.

**S6 — SPDX/REUSE hygiene (3×S, fully parallel, safe anytime).**
`SPDX-FileCopyrightText` + `SPDX-License-Identifier: GPL-3.0-or-later` in
all .el/.kt/.kts (jetpacs, then Glasspane at the WSL checkout, then
jetpacs-composer); `LICENSES/` + `REUSE.toml` for non-annotatable files;
an ERT sweep test asserting every tracked source file carries an SPDX
line. All three repos are already GPLv3 at the root — this makes it
legible per-file.

**S7 — Deploy dedup (S, optional, cut first).** Declare jetpacs
`deploy.ps1`/`.sh` canonical; Glasspane's copies become thin delegates or
get a divergence note; composer's `Deployer.kt` documented as an
intentional JVM re-implementation.

Dependency spine: S0 → S1 → S2 → S4 → S5, with S3 hanging off S0 (feeds
S4). S6 anytime. Alpha pressure valve: everything except S0 defers cleanly.

## Verification

Per stage above, plus always: `wsl -d Debian -- test/run-tests.sh` and
`gradlew :jetpacs:testDebugUnitTest` green; seeded-failure tests prove the
validators bite; contract byte-pin makes regen intentional; transcript
re-record determinism. End state: a stranger reads PROVENANCE.md + SPEC §12
and can name every normative artifact and run both conformance suites
without touching a phone (hardware needed only once, for S3 recording).
