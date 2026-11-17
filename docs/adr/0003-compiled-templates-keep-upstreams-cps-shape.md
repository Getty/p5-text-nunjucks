# ADR 0003 — Compiled templates keep upstream's callback (CPS) shape

- Status: accepted
- Date: 2026-09-22
- Tags: compiler, async, structure

## Context

Upstream compiles a template to `function root(env, context, frame, runtime,
cb)`. Output and errors leave through `cb`; `asyncEach`, `asyncAll`, `ifAsync`
and async filters are nested callbacks. Perl has no event loop in core, so a
port could drop all of that and compile to functions that simply return a
string.

## Decision

Keep the shape. The Perl compiler emits `sub root ( $env, $context, $frame,
$runtime, $cb )` and the same callback nesting as `compiler.js`. A callback is
invoked synchronously unless user code (an async filter, an extension) defers
it.

Since ADR 0021 the nesting is the same but the text is not literally upstream's:
every continuation but the callbacks of a block call and of `super()` is wrapped in
`$runtime->_continuation($context, sub { ... })`,
the first statement of a root or block sub is a `_render_scope` call, and
imports, macros and includes carry a few port-only statements. ADR 0021 lists
them, and none changes output or error text.

## Consequences

- `compiler.js` can be ported method by method and reviewed side by side; a
  return-value design would be a rewrite, not a port.
- Async filters, async tags and the callback form of `render` exist and behave
  as upstream. An event-loop binding (Future / IO::Async) can be layered on
  later without touching the compiler.
- A plain `render` without callback must still return the string: it works
  because sync callbacks have fired by the time the root call returns — and it
  must fail loud if a template deferred and no callback was given.
- Deep callback nesting costs Perl stack depth on long `asyncEach` loops; watch
  for "Deep recursion" warnings in the ported compiler suite.
