# SPEC amendment log

Every normative change to [SPEC.md](SPEC.md) — anything that alters what
a conforming implementation must do — lands as one row here, in the same
commit as the change itself. The row records what changed, which
machine-checked fixtures were regenerated to match, and who reviewed it.

This log is the provenance trail for the frozen spec. Credibility
attaches to the artifacts, not the authorship: an amendment is
trustworthy because a human reviewed it and both reference
implementations' conformance suites re-verified the regenerated
fixtures, regardless of who or what drafted the words.

Rules:

- Wording-only edits (typos, formatting, clarifications that change no
  requirement) need no entry.
- An amendment to the freeze surface (envelope, handshake, §4–§6
  semantics — see the SPEC header) must state in its Change cell why it
  is not wire-breaking, or bump the envelope `v` alongside.
- *Fixtures regenerated* names every regenerated artifact
  (`test/widgets.golden`, `test/frames.golden`, `test/hypertext.golden`,
  `docs/contract.json`) or says `none`.
- *Reviewed by* is filled by the human who reviews the amendment before
  it merges to main; a blank cell marks an amendment still in flight.

| # | Date | Section(s) | Change | Fixtures regenerated | Reviewed by |
|---|------------|------------|--------|----------------------|-------------|
| 0 | 2026-07-14 | header | Status → **1.0-rc**: freeze surface declared (envelope §2, handshake §3, §4–§6 semantics; §7–§11 negotiated/optional; §9 node vocabulary additive via §3 negotiation) and this amendment policy instituted. Bookkeeping only — no requirement changed, no wire change. | none | |
| 1 | 2026-07-14 | §3, §5, §8, §9 | Schema registry authored (S1): per-node required/optional keys and the frame-kind table now live in `jetpacs-lint.el` and publish as contract_format 2 (`node_schema`/`kind_schema`/`spec_version`). Hand-review of goldens ∪ constructors vs WIDGETS.md/SPEC §9 found the node vocabulary consistent, but several frame *sketches* disagreed with both reference implementations (which agree with each other) — corrected to wire truth, no implementation changed: §5 `event.action` carries `surface`/`revision_seen`/`fields`/`queued_at` (not `revision`; `when_offline`/`dedupe` are queue policy, not echoed); §8 companion→client legs ride `event.action` as actions (not frame kinds), `edit.resync` is `{id, session}` (not `{file, session}`), `diagnostics.show`/`fontify.show` carry load-bearing `seq`, `edit.caret`/`edit.complete` args corrected; §3 welcome also carries informational `protocol`/`server`. Not wire-breaking: every change describes what v1 implementations already emit/accept. | docs/contract.json (format 2) | |
