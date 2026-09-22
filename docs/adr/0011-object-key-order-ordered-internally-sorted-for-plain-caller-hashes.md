# ADR 0011 — Object key order: insertion-ordered internally, sorted for plain caller hashes

- Status: accepted
- Date: 2026-09-22
- Tags: semantics, runtime, ordering, dependencies, decision, k3

## Context

JS objects iterate in insertion order; Perl hashes do not. Observable upstream
(oracle): `{% for k, v in {b:1, a:2} %}` → `b=1;a=2;`, `dump` →
`{"b":1,"a":2}`, `dictsort|join(',')` → `a,2,b,1`. This touches `for k,v`,
`dump` (JSON.stringify), `list`, `dictsort`, `items`/`keys` (jinja-compat), and
dict literals in templates.

The maintainer's direction is maximum fidelity with new dependencies welcome
("gern neue requirements wenn die dir arbeit abnehmen").

## Decision

Combined (a)+(b):

- **Template dict literals and everything the engine builds** use an
  **insertion-ordered** hash representation, so `{b:1, a:2}` iterates `b` then
  `a` — byte-identical to JS. The representation is **`Hash::Ordered`** (a new
  runtime dependency; fast, no `tie` overhead).
- **Caller-supplied plain Perl hashes** have no order to preserve, so they
  iterate **sorted by key** — a deterministic, documented divergence (the only
  place Perl cannot match JS insertion order because the information was never
  there).
- **Caller-supplied ordered hashes** (`Hash::Ordered`, or a `Tie::IxHash`-tied
  hash) are honoured in their own order.

The ordering mechanism lives in one place (Runtime/Lib), used by every
order-sensitive operation (`for`, `dump`, `list`, `dictsort`, `items`, `keys`).

## Consequences

- `Hash::Ordered` joins the cpanfile as a runtime dependency.
- Template-authored and engine-built objects are 1:1 with JS; a caller who needs
  a specific order passes an ordered hash, exactly as they would for a JSON
  encoder.
- Plain caller hashes render deterministically (key-sorted); this is the one
  documented key-order divergence, and it is unavoidable.
- The corpus pins the measured cases (`for`, `dump`, `dictsort`) in render mode
  once the runtime/environment/filters land.
