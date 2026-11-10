# Text::Nunjucks

A **1:1 Perl port of [Nunjucks](https://mozilla.github.io/nunjucks/) v3.2.4** — same
templates, same context, same options → byte-identical output and the same error
messages as the JavaScript original. CPAN distribution `Text-Nunjucks`, Perl 5.40+, Moo.

Status: bootstrap. The distribution is a stub; the work is laid out on the karr board
(`karr board`). Start there, not here.

## How "1:1" is enforced

- `maint/fetch-upstream` checks the pinned upstream tag out to `upstream/` (gitignored).
  Needs network + node. Run it first on a fresh clone.
- `maint/oracle.js` renders / lexes / parses cases with the real upstream. Its output is
  correct by definition (ADR 0004):
  `echo '{"template":"{{ [1,2] }} {{ 1/3 }}"}' | node maint/oracle.js`
- `docs/adr/` records every decided JS→Perl mapping and every deliberate difference. A
  difference without an ADR is a bug.
- Test suite: `prove -lr t/` (`-r` is mandatory). Author check: `prove -l xt/`.

The porting contract, the upstream-file → Perl-module map and the test layout live in
skill `text-nunjucks-core`; the measured JS-semantics catalogue in its
`references/js-semantics.md`.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
the principle is a shared house rule (skilletor bundle `getty-cpan-dist@getty`); lanes
and hazards are in `.claude/rules/text-nunjucks-rules.md`.

| Task | Agent |
|---|---|
| Port / implement / refactor / debug behavior-relevant code | `text-nunjucks-worker` (default) |
| Port upstream test suites, grow the corpus | `text-nunjucks-test-writer` |
| Audit a ported module against its upstream file (read-only) | `text-nunjucks-fidelity-auditor` |
| Commits, `Changes`, card → done, pre-release audit | `text-nunjucks-release-manager` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/` —
`text-nunjucks-core` is project-owned; the `getty-*`, `perl-release-dist-ini`,
`feedback-loop-debugging` and `kanban-issues-karr-*` ones are installed by skilletor from
`.claude/skilletor.json` and change in their source repos.

## Working the board

Work coordination runs on the local `karr` board. The order is encoded in `depends_on`:

1. **k1** — the corpus harness. Everything after it is measured with it.
2. **k2–k8, tagged `decision`** — open JS→Perl mappings. They need the maintainer: put
   the options and a recommendation in front of them, record the answer as an ADR. Do
   these early; `Runtime` (k14) and `Filters` (k17) are blocked on them.
3. **k9 onwards** — the port itself, upstream file by upstream file, front to back
   through the pipeline (lib → lexer → nodes → parser → transformer → runtime →
   compiler → environment → filters/tests/globals → loaders → API).

Each porting ticket: worker ports → fidelity-auditor compares against upstream →
worker fixes findings → done.
