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
