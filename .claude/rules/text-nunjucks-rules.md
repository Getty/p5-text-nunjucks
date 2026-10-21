# Text::Nunjucks House Rules

Apply to every task here unless explicitly overridden. Subagents get their conventions
from `briefing.skills` — skill content is not restated here. Bias: caution over speed on
non-trivial work; judgment on trivial ones.

## Engineering discipline

1. **Think before coding** — State assumptions; when uncertain, ask rather than guess, push back
   when a simpler approach exists. Stop when confused; name what's unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — Touch only what you must. Match existing style.
4. **Goal-driven execution** — Define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — pick one, explain why, flag the other; don't blend.
6. **Read before you write** — Read the upstream JS file and its upstream test file before any Perl.
   "I know how Nunjucks works" is the dangerous sentence here.
7. **Tests verify intent, not just behavior** — A test that can't fail when the logic changes is
   wrong. Reproduce a bug before fixing it; leave a regression test behind.
8. **Checkpoint after every significant step** — Summarize: done / verified / left.
9. **Match the codebase's conventions, even if you disagree** — Conformance > taste.
10. **Fail loud** — "Done" is wrong if anything was skipped silently. "Tests pass" is wrong if any
   were skipped or TODO — report those counts with every green run.
11. **A red test is a claim before it is a failure** — Before turning a test green, say what it
   asserts and whether your fix keeps or replaces that claim. If the claim is wrong, fix the claim.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant code
  yourself — delegate to `text-nunjucks-worker`. Your lane: coordinate, inspect, plan, review diffs,
  run tests, manage the board, edit prose docs, put `decision` tickets in front of the maintainer.
  When in doubt, delegate. Why: only the `text-nunjucks-*` agents get the porting contract via
  `briefing.skills`; you get none and would port from memory.

| Task | Agent |
|---|---|
| Port / implement / refactor / debug behavior-relevant code | `text-nunjucks-worker` (default) |
| Port upstream test suites, grow the corpus, reproduce fidelity bugs | `text-nunjucks-test-writer` |
| Compare a ported module against its upstream file (read-only) | `text-nunjucks-fidelity-auditor` |
| Commits, `Changes`, card → done, pre-release audit | `text-nunjucks-release-manager` |

Porting: worker → fidelity-auditor → worker → done; no audit means "looks right" beats "is 1:1".

- **You cannot spawn subagents** (you ARE a `text-nunjucks-*` agent): the delegation lock does not
  apply to you — work per your briefing and these rules.

Behavior-relevant = `lib/`, `t/`, `xt/`, `maint/`, `cpanfile`, `dist.ini`; pure prose is not.

**Only `text-nunjucks-release-manager` commits**; workers hand over a commit-ready tree + card.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't invoke
the `kanban-issues-karr-coordination` skill first, just use it. State lives in `refs/karr/*`.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create --title "…" --priority high --body '…'` · `karr edit ID -a "note"` · `--block "why"`
- `karr move ID in-progress --claim NAME` — start · `karr handoff ID --claim NAME --note` — review

Respect `depends_on`: an open `decision` blocks the ticket — take the rest or the decision first.

**Serialize board mutations when fanning out.** Implementation parallel is fine; collect, then loop
`karr move`/`handoff`/`sync` sequentially — N at once OOM-rebooted a host; no background poll loops.

## Release — never without permission

`prove`, `dzil build`, `dzil test` are fine anytime. `dzil release` and any upload are STRICTLY
forbidden without the maintainer's explicit go-ahead — even if a plan says "release". Stop and ask.

## Public issues — never act without instruction

`karr` is the agent work board. A public tracker (GitHub — ours or **mozilla/nunjucks**) is a
different universe: never list, read, comment on, open or close an issue there unasked. An upstream
bug gets ported (ADR 0004) and noted in a karr ticket; reporting upstream is the maintainer's call.

## Project hazards — locks here, mechanisms in `text-nunjucks-core`

- **Never port from memory** — ask the oracle, commit the probe as a corpus case.
- **`upstream/` may be absent** — then the oracle can't run; say the oracle check was NOT run.
- **`prove -lr t/`, never `prove -l t/`** — `t/upstream/` is a subdirectory the short form skips.
- **Expected values are generated, never typed** — `maint/corpus-regen` writes `expected`.
- **Open mappings are decided once, by ADR** — `decision` tickets need the maintainer, not a filter.
- **House Perl style lives in skills** — `getty-perl-core` / `getty-perl-moo`: module loading, class
  patterns, cpanfile, Changes; porting contract in `text-nunjucks-core`. Don't duplicate it here.
