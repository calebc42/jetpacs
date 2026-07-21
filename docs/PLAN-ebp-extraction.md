# PLAN: extract the Wire into `ebp` (Emacs–Android Bridge Protocol)

Status: **Option A decided 2026-07-15 — executing.** Branch
`claude/jetpacs-modularization-59725d`. Companion decision doc: none (this
file is the whole track).

**Update 2026-07-21: inverted to Option B** (ebp SPEC-CHANGES #30) — the
contract is authored in ebp; ebp carries no dependency on this repo.
`emacs/build-contract.el` stays here as the conformance projector, and
the drift test's mismatch workflow flips: amend ebp first, then make the
lint tables match. The §"source-of-truth" analysis below is preserved as
the record of why A was chosen first.

## Motivation

The protocol contract — SPEC, `contract.json`, the golden corpus — is the one
artifact with multiple independent consumers (elisp core, Kotlin renderer,
jetpacs-composer, invited third-party companions per BUILDING-COMPANION.md)
and a deliberately frozen change velocity (Spec 1.0-rc, additive-only).
Today consumers reach it by filesystem accident: `WireGoldenConformanceTest.
repoFile()` walks *up* from `user.dir` until it finds `docs/contract.json`,
which only works because everything shares one repo. A third party has
nothing stable to pin. Extracting the contract into its own repo (`ebp`)
gives a small, versioned, pinnable surface — the adoptability lever.

Explicitly **out of scope**: splitting the Kotlin `:jetpacs` renderer into its
own repo (defer until a second companion exists — the Gradle module boundary
already enforces the design; ARCHITECTURE.md calls it "the future repo
boundary"). Apps are already spun out (glasspane).

## Target: the `ebp` repo

```
ebp/
├── SPEC.md                    ← docs/SPEC.md
├── SPEC-CHANGES.md            ← docs/SPEC-CHANGES.md
├── contract.json              ← docs/contract.json
├── BUILDING-COMPANION.md      ← docs/BUILDING-COMPANION.md
├── goldens/
│   ├── frames.golden          ← test/frames.golden
│   ├── widgets.golden         ← test/widgets.golden
│   └── hypertext.golden       ← test/hypertext.golden
├── validate.py                new: stdlib-only self-validator (goldens vs
│                              contract.json — the third-party day-one script,
│                              doubling as ebp's own CI gate)
├── .github/workflows/validate.yml  new: run validate.py on push/PR
├── README.md                  new (what the protocol is, versioning, consumers)
├── LICENSE                    copy of jetpacs's GPL
└── .gitattributes             `* text=auto eol=lf` (byte-stable artifacts)
```

Initial tag: `spec-1.0-rc`. Tags follow the protocol/spec numbers, never the
elisp `jetpacs-api-version`.

**Done** (2026-07-15): the repo exists locally at
`C:\Users\caleb\AndroidStudioProjects\ebp` — initial commit `0ad0d2b`,
tagged `spec-1.0-rc`, `validate.py` green. Awaiting the owner's GitHub
create + push (below).

## The source-of-truth question (and what the code actually says)

The wire vocabulary is authored in `emacs/core/jetpacs-lint.el`
(`jetpacs-lint-node-schema`, `jetpacs-lint-kind-schema`,
`jetpacs-lint-node-types`, action/toolbar/binding defconsts) because
`jetpacs-lint` is a *runtime linter* apps and the composer call — those tables
stay elisp regardless. `emacs/build-contract.el` projects them into
`contract.json`; the goldens are emitted by the constructors via the
`jetpacs-tests-regen-*` commands.

Key observation that shrinks the bake-off: the drift tests are mechanically
**symmetric** — `jetpacs-contract-artifact-current` and the golden tests all
reduce to "generate from source, `string=` against the committed file." Moving
the committed file into `ebp/` doesn't change the test; only the *workflow on
mismatch* differs:

- **Option A (elisp stays generator):** mismatch ⇒ run the regen, commit the
  submodule, bump the pointer. `ebp` is a published mirror of jetpacs.
- **Option B (full inversion):** mismatch ⇒ edit `ebp` first, then make the
  elisp tables/constructors match. `ebp` is *the* spec; jetpacs conforms.

So A vs B is ~90% documentation, release flow, and the `api_version` question —
not test rewrites. **Decided: Option A** (2026-07-15), on four grounds:

1. **B's canonicity is partly fictional.** The goldens are generated from the
   constructors — under B a wire change would still be "edit elisp, regen,
   commit the output to ebp first and call it the decision." Ceremony, not
   inversion; the authorship doesn't move, only the blame.
2. **Under B the canonical repo is the only one that can't validate itself.**
   ebp is inert data with no test harness; under A every ebp commit is
   produced by a green ERT run by construction. (Mitigated either way by the
   `validate.py` self-check below — but a validator is not a generator.)
3. **S1 deliberately consolidated authorship into elisp** ("STATIC AND
   AUTHORED ONLY: the hand-reviewed `jetpacs-lint.el` tables" —
   build-contract.el). B relocates it again right after; and
   client-authoritative is the project's premise.
4. **A → B is a cheap, reversible door**: the artifacts are identical either
   way, so inversion later is docs + workflow rewording.

**Revisit trigger (recorded):** flip to B when a second independent
implementation with its own maintainers exists, or when the spec goes
1.0-final and governance is handed off. Until then, PR-as-proposal works
against the mirror: someone PRs ebp, the maintainer implements in elisp, the
regen either reproduces the proposal or the discussion continues.

Two pieces of B are severable and adopted under A (Phase 1): the
`api_version` cleanup and the ebp self-validator.

## Phase 0 — shared skeleton (all path repoints; direction unchanged)

Every step keeps both CI jobs green.

**T0.1 — init the `ebp` repo** *(owner, or agent locally + owner pushes)*
`git init` + initial commit + tag `spec-1.0-rc` in
`C:\Users\caleb\AndroidStudioProjects\ebp`; owner creates
`github.com/calebc42/ebp` and pushes. Fix intra-file links that assumed the
monorepo layout **before** the first commit:
- `BUILDING-COMPANION.md` 23, 27: `../test/widgets.golden` /
  `../test/frames.golden` → `goldens/widgets.golden` / `goldens/frames.golden`.
- `SPEC.md` 393/408: link text "docs/contract.json" → "contract.json";
  406: `../test/widgets.golden` → `goldens/widgets.golden`.
- `SPEC-CHANGES.md` 22–23 (header prose): `test/*.golden`, `docs/contract.json`
  → `goldens/*.golden`, `contract.json`. Historical table rows stay verbatim
  (point-in-time record).

**T0.2 — add the submodule** *(agent; worktree-aware)*
In jetpacs: `git submodule add <url> ebp`. The committed `.gitmodules` must
carry the public URL (`https://github.com/calebc42/ebp`), never the local
path — the glasspane gotcha. Recipe when the GitHub repo doesn't exist yet:
add with the local path, then edit `.gitmodules` to the public URL before
committing; the local path stays in `.git/config` (uncommitted) as the
override. Note: in a linked worktree the submodule's git dir lands in the main
repo's `.git/modules` — expected, but do the `submodule add` from whichever
checkout will carry the branch.

**T0.3 — remove the moved files from jetpacs**
`git rm docs/SPEC.md docs/SPEC-CHANGES.md docs/contract.json
docs/BUILDING-COMPANION.md test/frames.golden test/widgets.golden
test/hypertext.golden`. Same commit as T0.2 + T0.4 + T0.5 so no ref dangles.

**T0.4 — repoint every reader/writer** (one mechanical sweep)

Kotlin — `jetpacs/src/test/java/com/calebc42/jetpacs/WireGoldenConformanceTest.kt`
(the only Kotlin file that reads these; `OnFireInterpolationTest.kt` mentions
frames.golden in a comment only):
- 57: `repoFile("docs/contract.json")` → `repoFile("ebp/contract.json")`
- 210, 228, 279, 308: `"test/frames.golden"` → `"ebp/goldens/frames.golden"`
- 248: `"test/widgets.golden"` → `"ebp/goldens/widgets.golden"`
- 265: `"test/hypertext.golden"` → `"ebp/goldens/hypertext.golden"`
The `repoFile` up-walk itself is unchanged.

Elisp generator — `emacs/build-contract.el`:
- `jetpacs-contract-file` (133–135): `"docs/contract.json"` → `"ebp/contract.json"`
- `jetpacs-contract--spec-version` (42): `"docs/SPEC.md"` → `"ebp/SPEC.md"`
(Yes, in Phase 0 — `jetpacs-contract-artifact-current` regenerates via these
paths and diffs the committed file, so CI breaks without this repoint.)

Elisp tests — `test/jetpacs-tests.el` (defconsts resolve against
`jetpacs-tests--dir`, i.e. `test/`; they need `../ebp/...`):
- `jetpacs-tests--golden-file` (1141): → `../ebp/goldens/widgets.golden`
- `jetpacs-tests--hypertext-golden-file` (1874): → `../ebp/goldens/hypertext.golden`
- `jetpacs-tests--frames-golden-file` (4602): → `../ebp/goldens/frames.golden`
- `jetpacs-spec-header-version-coherent` (3007): SPEC path → `../ebp/SPEC.md`
- audit `jetpacs-contract-artifact-current` (3596) for any hardcoded path not
  routed through `jetpacs-contract-file`.
The regen commands (`jetpacs-tests-regen-widget-golden` 1317,
`-regen-hypertext-golden` 1916, frames regen ~4696) inherit the new paths and
now write into the submodule.

**T0.5 — CI** — `.github/workflows/ci.yml`: add `with: submodules: recursive`
to both `actions/checkout@v4` steps (elisp + android jobs).

**T0.6 — link audit in remaining docs/code** (repoint or reword to the ebp
repo; skip historical `docs/PLAN-*.md`):
`README.md`, `CONTRIBUTING.md` (rules 1, 4-adjacent, **5** — "goldens are the
wire truth" cites `test/widgets.golden`), `docs/ARCHITECTURE.md`,
`docs/API-STABILITY.md`, `docs/BINDING.md`, `docs/BUILDING-TIER1.md`,
`docs/CONTRIBUTING-NODES.md`, `docs/WIDGETS.md`, `docs/TUTORIAL.md`,
`docs/ROADMAP.md` (+ add this track as a row), and SPEC-citing elisp headers
(`jetpacs-lint.el`, `jetpacs-comint.el`, `jetpacs-customize.el`,
`jetpacs-witheditor.el`). GitHub renders links *into* a submodule as a link to
the submodule commit, not the file — prose that targets readers on github.com
should name the ebp repo URL; paths are fine for tests/tools.

## Phase 1 — Option A wiring + the salvaged pieces

**T1.1 — release flow in CONTRIBUTING.** Edit tables/constructors → regen into
`ebp/` → commit in ebp (tag if the wire moved) → bump the submodule pointer.
`ebp/README.md` positions the repo as the published, pinnable contract of the
reference implementation.

**T1.2 — ebp self-validator** (ships in the initial ebp commit, T0.1).
`validate.py`, stdlib-only: every golden line validates against
`contract.json` (node types, required/optional keys, the discriminated action
schema, kind schema + direction for frames) — a simplified mirror of
`WireGoldenConformanceTest`'s validators and the third-party day-one script.
A one-job GitHub workflow runs it, so even the mirror can't publish an
internally inconsistent state.

**T1.3 — `api_version` → `reference_api_version`, `contract_format` 3.**
`contract.json` currently publishes `api_version` (elisp Tier-1 surface,
1.20.0) beside the wire numbers; it describes an implementation, not the
protocol. Rename it (informational) and bump `jetpacs-contract-format` to 3
in `emacs/build-contract.el`; update the `contract_format 2` mention in
SPEC.md §9, add a SPEC-CHANGES.md entry (dogfoods the amendment flow in the
new repo), update `WireGoldenConformanceTest.contractIsFormatTwoAndCoherent`
(185, pins `== 2`), regen, commit ebp, bump the pointer. Do this as its own
commit *after* Phase 0 is green — it's the first amendment, not part of the
move. jetpacs-composer may read `api_version`; its repoint is a follow-up in
that repo and any breakage surfaces there.

## Verification (per phase, per worktree)

- `emacs -Q --batch -l test/core-load-test.el`
- `emacs -Q --batch -l test/jetpacs-tests.el -f ert-run-tests-batch-and-exit`
- `emacs -Q --batch -l test/jetpacs-primitives-test.el -f ert-run-tests-batch-and-exit`
- `emacs --batch -l emacs/build-bundle.el && git diff --exit-code jetpacs-core.el`
  (bundle list untouched by the move — these files were never bundled)
- `./gradlew :jetpacs:testDebugUnitTest :app:testDebugUnitTest` — the point:
  `WireGoldenConformanceTest` green reading `ebp/`
- `./gradlew :jetpacs:assembleDebug :app:assembleDebug`
- Fresh `git clone --recurse-submodules` smoke; confirm a clone *without*
  submodules fails loudly (tests can't find `ebp/`), not silently.
- Third-party day-one: clone `ebp` alone in a scratch dir, validate
  `goldens/*` against `contract.json` with a ~20-line standalone script.

## Owner steps (no agent SSH creds)

1. Create `github.com/calebc42/ebp`; push the initial commit + `spec-1.0-rc`.
2. Confirm the committed `.gitmodules` URL; keep any local-path override in
   `.git/config` only.
3. Push jetpacs main after merge; composer repoint (its `contract.json`
   consumption) is a separate follow-up in that repo.
