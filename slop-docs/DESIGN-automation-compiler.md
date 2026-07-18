# Design: the automation compiler (greenfield)

**Status: Claude-authored reference sketch for the hand rebuild. Not code, not
spec — the owner's spec and implementation supersede this document wherever
they diverge.** Sketch policy: signatures, data shapes, and worked examples
only; no finished implementations. Old-code citations are `@HEAD` — the
pre-fork tree, kept for archaeology, not for copying.

## 1. Governing decision

From the decision log (#5, revised): the wire carries only deliberately weak
languages — terminating by construction, closed-vocabulary, safe under partial
understanding. User-facing expressiveness is unlimited **in elisp**. The
compiler is the bridge: it takes a rule authored in the rich source language
and partitions it into

- **(a) declarative wire registrations** — catalog-gated, runnable by the
  companion with Emacs dead, and
- **(b) elisp residue** — a handler behind a `wake` policy, where the full
  power of Emacs applies.

Epigraph: *Tasker parity, Emacs soul.* The companion is Emacs's body — the
catalogs of sensors and effectors grow aggressively — but it never hosts a
second authoring language. Greenspun is contained, not denied: the wire's
little languages (predicates, response lists, substitutions) stay below the
conditionals-state-iteration rung, forever.

## 2. Source language

Starting point to re-derive (not copy): the old authoring surface —
`jetpacs-trigger-register (ID &key type params when policy dedupe throttle-s
on-fire handler)` and the `jetpacs-deftrigger` macro
(`emacs/core/jetpacs-triggers.el:78-119@HEAD`). Its `:when` was a flat list of
predicate alists, ANDed. The greenfield source language keeps everything and
generalizes the gate to a boolean expression:

```
GATE  := LEAF
       | (and GATE ...)
       | (or  GATE ...)
       | (not GATE)
       | (elisp PREDICATE-FN)          ; the escape leaf — any elisp, zero-arg
LEAF  := (TYPE FIELD-ALIST...)         ; a catalog state predicate,
                                       ; e.g. (screen (state . "off"))
```

Illustrative authoring sketch (shape, not API commitment):

```elisp
(jetpacs-defrule my/porch-light
  :on   '(power (state . "connected"))              ; the edge (trigger type+params)
  :when '(and (screen (state . "off"))
              (or (time.window (after . "21:00") (before . "06:00"))
                  (time.window (days . ["sat" "sun"]))))
  :do-device '(((cap . "flashlight") (args . ((on . t)))))  ; on_fire half
  :do   (lambda (data) ...))                        ; elisp half (optional)
```

The old flat-list form remains valid as sugar for a single `and` clause, so
existing rules read unchanged.

## 3. Pipeline

Five stages. Each is a small, hand-implementable function; suggested
signatures are sketches.

### 3.1 Normalize — `(jetpacs-rules--normalize GATE) → CLAUSES`

Rewrite the gate to **disjunctive normal form** (DNF): an OR of AND-clauses,
with `not` pushed down to the leaves (De Morgan). This automates the spec's
own instruction to humans — *"a rule that needs OR is two registrations"* —
because each AND-clause maps exactly onto the wire's `when` (a flat ANDed
array), and the OR across clauses becomes multiple registrations.

`CLAUSES` = list of clauses; clause = list of possibly-negated leaves.

### 3.2 Classify each leaf — `(jetpacs-rules--classify-leaf LEAF CATALOGS) → wire | flip | residue`

Against the **negotiated** catalogs from the welcome (`device.trigger_types`,
`device.state_types` — the old gates `jetpacs-triggers--supported-p` and
`--when-supported-p`, `triggers.el:36-61@HEAD`, are the primitive ancestors):

- catalog predicate, positive → **wire**.
- catalog predicate under `not` → consult the **complement table** (3.3).
- `(elisp FN)` or a type absent from `state_types` → **residue**.

### 3.3 Complements — a per-predicate table, not a rule

`not` is only flippable where the predicate is genuinely **two-valued**:

| predicate | flippable? | complement |
|---|---|---|
| `power` | yes | `connected` ↔ `disconnected` |
| `screen` on/off | yes | `on` ↔ `off` (`unlocked` is NOT two-valued — residue) |
| `airplane`, `wifi.enabled`, `bluetooth.enabled`, `headset` | yes | flip the value |
| `time.window` | yes | complement window (wraps midnight; days invert) — or residue if simpler |
| `battery.level` | yes | `above` ↔ `below` (mind the strict inequality boundary) |
| `call.state` | **no** | three states (`ringing`/`offhook`/`idle`): `(not offhook)` ≠ `idle`. Residue. |
| `network`, `calendar.event` | **no** | "no matching network/instance" is not expressible. Residue. |

Law: **never silently approximate a complement.** A leaf that can't flip goes
to residue; the report (3.6) says so. This table is a required spec amendment
(§ State predicates gets a "complement" column).

### 3.4 Partition — the safety asymmetry (the load-bearing idea)

Each DNF clause lands in one of two regimes, and they have **different
soundness rules**:

- **Autonomy regime (`:do-device` / on_fire):** the companion acts alone, so
  the gate guarding it must compile **exactly** — every leaf `wire` (or
  flipped). A clause with any residue leaf gets **no on_fire registration for
  that clause**: widening a gate on an autonomous action is the `when`-strip
  inversion ("only at night" silently becomes "always"), which the walk
  established as the cardinal sin.
- **Delivery regime (`:do` handler):** Emacs is the final judge, so the gate
  may be **widened** — drop residue leaves from the clause, register the
  weakened gate with `policy: "wake"`, and re-verify the full gate in the
  handler before acting. Widening here costs battery (extra wakes), never
  correctness.

One sentence to carry into the spec: **widen only toward Emacs, never toward
autonomy.**

### 3.5 Emit — `(jetpacs-rules--emit RULE CLAUSES) → registrations`

One wire registration per compilable clause. Mechanics to re-derive from the
old proto-compiler `jetpacs-triggers--specs` (`triggers.el:164-210@HEAD`),
whose habits are worth keeping: omit nil fields (additive-friendly), rename
`:throttle-s`→`throttle_s` / `:on-fire`→`on_fire`, sort by id and `vconcat`
so identical rule sets produce byte-identical frames.

- **ids:** `BASE#N` per clause (`my/porch-light#1`, `#2`) — stable ordering,
  same ownership claim as the base rule.
- **dedupe:** default = the rule's dedupe key shared across all branches, so
  an OR-rule queued offline collapses to one fire regardless of which branch
  tripped. (Open decision 6.1.)

### 3.6 Report — `(jetpacs-rules-compile-report &optional RULE-ID)`

Compilation is only honest if the author *sees the split*, at authoring time:

```
my/porch-light  →  2 registrations on-device (clauses 1,2)
                   on_fire: armed (gate compiles exactly)
my/quiet-sms    →  1 registration, gate WIDENED (dropped: (not (call.state)))
                   full gate re-verified in handler; policy=wake
my/inbox-guard  →  0 registrations; fully residue (org predicate) — wake only
```

Surface this in the automations management view (the old view's repush hook,
`jetpacs-automations.el:135-138@HEAD`, is the pattern) and as a plain command.

## 4. Per-connection recompilation

The catalogs are **negotiated per companion**, so compilation output is
per-connection: compile at welcome (the old connected-hook re-arm,
`triggers.el:277-283@HEAD`, is the trigger point), cache keyed by a **catalog
fingerprint** — e.g. a hash of the sorted `trigger_types` + `state_types`
lists. Same companion, same output, no recompute; a different or upgraded
companion recompiles, and a rule that was residue yesterday may compile today
(the report should celebrate that).

Gate testability carries over: the old `jetpacs-device-state (callback &key
types when)` (`jetpacs-device.el:252-277@HEAD`) evaluated a gate through the
same companion code path that gates fires — keep that, and add "evaluate this
*compiled clause*" so authors can probe exactly what shipped.

## 5. Spec amendments this design requires

1. **Per-`on_fire`-entry `when` gates** (decision #5): the autonomy regime
   needs per-entry guards, not just per-registration.
2. **Complement column** in the state-predicate catalog (table 3.3) — which
   predicates are two-valued, and what the flip is.
3. Optional, if 6.2 resolves that way: **throttle groups** (shared throttle
   bucket across registrations), else document per-branch throttling.

## 6. Open decisions (flagged, not resolved)

1. **Dedupe across branches** — shared key collapses OR-branch fires into one
   queued event (recommended: an OR-rule is one logical rule); but a rule
   whose branches carry *different* `data` payloads may want per-branch keys.
2. **Throttle bookkeeping** — the companion sees N registrations, so
   `throttle_s` buckets are per-branch; an OR-rule can fire N× faster than
   its author intended. Accept and document, or amend the spec with throttle
   groups. Interacts with the gate-before-throttle ordering rule.
3. **When to compile** — eagerly at registration (errors surface at author
   time, but against a guessed catalog) vs. lazily at connect (true catalog,
   later feedback). Recommendation: parse/normalize eagerly (syntax errors
   immediate), classify/emit at welcome.
4. **Residue re-verification** — the handler re-checks the full gate; does it
   sample device state over the wire (`state.get`, adds a round-trip) or
   trust Emacs-side knowledge where it has any? Probably `state.get` with the
   original clause, since the same predicate vocabulary is already the shared
   language.

## 7. Worked examples

### 7.1 OR splits into two registrations

Source: porch-light rule from §2 — flashlight on power-connect, only with
screen off, at night **or** on weekends.

DNF: `(and screen-off night) ∨ (and screen-off weekend)` → two clauses, both
fully catalog-expressible → two registrations:

```json
{"id": "my/porch-light#1", "type": "power", "params": {"state": "connected"},
 "when": [{"type": "screen", "state": "off"},
          {"type": "time.window", "after": "21:00", "before": "06:00"}],
 "dedupe": "my/porch-light",
 "on_fire": [{"cap": "flashlight", "args": {"on": true}}]}

{"id": "my/porch-light#2", "type": "power", "params": {"state": "connected"},
 "when": [{"type": "screen", "state": "off"},
          {"type": "time.window", "days": ["sat", "sun"]}],
 "dedupe": "my/porch-light",
 "on_fire": [{"cap": "flashlight", "args": {"on": true}}]}
```

Runs with Emacs dead. Report: "2 registrations, on_fire armed."

### 7.2 A non-flippable leaf widens the delivery gate — and disarms autonomy

Source: "notify me on SMS from Sam, *unless I'm on a call*" — gate
`(not (call.state))`, response includes both a `:do-device` notify and a
`:do` handler.

`call.state` is three-valued → the `not` cannot flip → residue leaf. Autonomy
regime: the on_fire notify **does not ship** (a widened gate would notify
during calls — inversion). Delivery regime: register the edge with the gate
widened to nothing, `policy: "wake"`; the handler re-verifies "not on a call"
(via `state.get` with `(call.state)` and inverting `holds`) before notifying
through Emacs. Report says exactly this, including the battery consequence.

### 7.3 Fully residue

Source: "when I get home (wifi network), file a reminder *unless my org inbox
is empty*" — the org-inbox test is an `(elisp …)` leaf. No clause compiles
beyond the edge itself → one registration carrying just the edge with
`policy: "wake"`, no `when`, no `on_fire`; all logic in the handler. This is
the "keep Emacs alive" boundary working as intended — and the compile report
is where the author learns their rule costs a wake.
