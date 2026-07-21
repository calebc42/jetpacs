# Decision: no template DSL in the binding layer — lean on the rich server

**Status: Accepted (2026-07-13).** Applies to the jetpacs binding layer and every
Tier-1 built on it. Recorded here so the choice is visible to reviewers and
collaborators, not just in one author's notes.

## Context

The jetpacs binding layer (api 1.5.0) ships declarative `:spec` views: a named
**source** produces normalized item data, and a **template** of closed-vocabulary
wire data renders each item (one leaf binds one field through one of eight
transforms). It was deliberately minimal; anything harder was pushed to
*source-side normalization* or left to an elisp `:builder`.

During Glasspane's Stage-3 adoption we found that **none** of Glasspane's real
cards can be reproduced byte-comparably by a v1 `:spec`: they compose strings
(`"todo · file"`), expand a list into per-tag tappable chips, apply conditional
styling (done → strikethrough, `[A]` priority spans), or render tables. A design
was drafted (and committed to a since-deleted jetpacs branch,
`feat/binding-layer-templates`) to add template **constructs** — `join` (string
interpolation), `each` (repeat over a list), `when` (conditional), and a `table`
layout — bumping the api to 1.6.0.

## Decision

**Reject the template DSL.** The declarative `:spec`/template grammar stays
minimal. Rich, bespoke rendering stays in elisp `:builder`s. The binding layer is
not extended to reproduce hand-crafted cards.

## Rationale

The leverage of server-driven UI is that the **server is rich and the client is
thin**. The Emacs side already has string composition, iteration, conditionals,
and — via its package ecosystem — powerful data engines (org-ql, and especially
**vulpea**'s async SQLite note index). Re-encoding control flow as JSON wire data
is reinventing what elisp does natively: it bloats the versioned contract, adds a
mini-language to learn and lint, and buys nothing a `:builder` can't already do.

The `:spec` layer's real customer is the no-code **composer**, which binds a
*source* to a *simple* view. It does not need to reproduce a Tier-1's opinions.
So the value goes where it belongs:

- **Sources** normalize engine data (`glasspane.org` over the org query engine,
  `glasspane.notes` over vulpea's `db-query`) into domain-neutral fields the
  composer can bind.
- **Rich rendering** stays in `:builder`s that lean on the rich server.
- **The engine-pack dependency model** (`glasspane-pack.json`'s `depends`)
  declares the packages the composer auto-installs (vulpea, org-ql, org, cl-lib)
  — the seam through which the SDUI's "bring in whatever you need" power flows.

## Consequences

- Five of Glasspane's six card surfaces stay `:builder`; the board (curated
  column order + move-menu) already was. Notes backlinks remains a `:builder`
  that now shares helpers with the `glasspane.notes` source.
- The composer binds Glasspane's **data** (two sources) and its **actions** (the
  annotated `jetpacs-action-catalog`), and authors its own simple `:spec` views —
  without reading elisp.
- Future expressiveness, if ever truly needed, is a **source** concern (emit a
  derived field) or a **new engine** (a package brought in as a pack dependency),
  never a wire-grammar extension.

## Alternatives considered

- **Template DSL (`join`/`each`/`when`/`table`, api 1.6.0)** — rejected above.
- **Source-precomputed derived fields** — adopted where it helps (e.g. a
  basename `file_name` field); the idiomatic escape hatch, no contract change.

## See also

- `jetpacs/docs/PLAN-binding-layer.md` (the binding-layer master plan; T2.3
  "source-side normalization") · `jetpacs/docs/BINDING.md` (the grammar).
- The author-facing rationale also lives in agent memory
  (`sdui-rich-server-not-wire-dsl`).
