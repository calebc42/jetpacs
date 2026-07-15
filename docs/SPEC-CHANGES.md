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
| 2 | 2026-07-14 | §5, §9 | Configurable notification action buttons. §9: a notification's `meta.actions` is an ordered array of `{label, on_tap, icon?, dismiss?, input?}` rendered as the platform notification's actions — `dismiss` cancels the notification on tap (Done/Snooze), `input {hint?, key?}` makes the button an inline text reply. §5: `fields` is no longer always `null` — an inline-reply action delivers its typed text there as `{key: text}`. Not wire-breaking: both are additive. `meta.actions` is an unknown meta key to a companion that predates it (it posts no buttons and a body `button` remains the fallback), and `fields` was already part of the `event.action` shape and `null` for every existing interaction, so a client that emits no inline-reply action never receives a non-null value. | none normative — notification `meta` is rendering guidance, not part of the machine-checked node/kind vocabulary in `docs/contract.json`, and no golden carries a notification spec; `docs/contract.json` regenerates only its `api_version` (1.11.0 → 1.12.0, the added builders), not a contract-shape change | |
| 1 | 2026-07-14 | §3, §5, §8, §9 | Schema registry authored (S1): per-node required/optional keys and the frame-kind table now live in `jetpacs-lint.el` and publish as contract_format 2 (`node_schema`/`kind_schema`/`spec_version`). Hand-review of goldens ∪ constructors vs WIDGETS.md/SPEC §9 found the node vocabulary consistent, but several frame *sketches* disagreed with both reference implementations (which agree with each other) — corrected to wire truth, no implementation changed: §5 `event.action` carries `surface`/`revision_seen`/`fields`/`queued_at` (not `revision`; `when_offline`/`dedupe` are queue policy, not echoed); §8 companion→client legs ride `event.action` as actions (not frame kinds), `edit.resync` is `{id, session}` (not `{file, session}`), `diagnostics.show`/`fontify.show` carry load-bearing `seq`, `edit.caret`/`edit.complete` args corrected; §3 welcome also carries informational `protocol`/`server`. Not wire-breaking: every change describes what v1 implementations already emit/accept. | docs/contract.json (format 2) | |
| 3 | 2026-07-14 | §11 | `on_fire` placeholder dynamics ([PLAN-conditions-and-dynamics.md](PLAN-conditions-and-dynamics.md) Phase 1). String values inside an `on_fire` entry's `notify` and `args` (recursively) are interpolated at fire time with `${id}`, `${type}`, `${data.FIELD}`, following §9's snippet-placeholder rules (single pass, unknown/unresolvable tokens stay literal, result always a string; the `cap` name never interpolates). Additive and not wire-breaking: an `on_fire` carrying no `${…}` token is byte-identical on the wire and in behaviour, and the companion is the only interpreter — the tokens ride the existing `triggers.set` shape as ordinary strings. | test/frames.golden | |
