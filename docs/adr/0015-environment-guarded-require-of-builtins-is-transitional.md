# ADR 0015 — Environment loads built-in filters/tests/globals via a transitional guarded require

- Status: accepted (transitional — closes when k18 and k19 land)
- Date: 2026-09-22
- Tags: environment, transitional, decision, k16, k17, k18

## Context

Upstream `Environment` hard-`require`s its built-in bags at construction
(environment.js: `./filters`, `./tests`, `./globals`). Upstream can therefore
never have a missing built-in bag.

The Perl port lands these across several tickets: the built-in `is` tests came
forward with `Environment` (k16, `Text::Nunjucks::Tests`), but filters are
k17, globals are k18 (together with `Tests`), and the concrete loaders are k19. Between k16 and those, a
`use Text::Nunjucks::Filters` / `Globals` would fail to compile the whole
module.

`Environment::init` (`_load_builtin`, `Environment.pm:155-167`) therefore loads
each bag through a **guarded require** that swallows only the "module absent"
case (`Can't locate <that module>.pm`) and re-throws every other load error
(a syntax error in a bag that *does* exist still fails loud).

The current, oracle-confirmed effect: a fresh `Environment` ships with **no
filters and no globals**, so `{{ "x"|upper }}` raises filter-not-found and
`{{ range(3) }}` raises global-not-found, where upstream renders.

## Decision

Accept the guarded require as an explicit **transitional scaffold**, recorded in
the divergence ledger rather than only as an inline comment. Constraints:

- The swallow stays narrow: only the target module being absent is tolerated;
  any real load failure propagates.
- Each bag becomes an unconditional load (`use`) as its ticket lands — filters
  at k17, `Tests` and globals at k18, and the guard is removed once no built-in
  bag can be absent.

## Consequences

- Until the bags land, templates that depend on a built-in filter or global
  error instead of rendering. This is a known, temporary gap, not a semantic
  choice about how filters/globals behave.
- No behavioural divergence remains once all three bags exist: with filters,
  tests and globals present, the guarded require and a hard `use` are
  indistinguishable.
- This ADR is closed (superseded by the plain loads) when k18 and k19 land; the
  k18 and k19 tickets carry the pointer back here.

## Update (2026-11-13, k17)

Alignment of the ticket references; the decision above is unchanged. This
ADR first named globals as k17 work. The k17 run ports the filters only:
`Text::Nunjucks::Filters` is a hard `use` in `Environment` since k17, and the
guarded require no longer covers it. `Text::Nunjucks::Tests` (present since k16)
and `Globals` (k18, "Port tests.js + globals.js") still load through the guarded
require, so the guard stays until k18 lands, and the loaders (k19) follow.
