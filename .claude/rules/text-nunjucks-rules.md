# Text::Nunjucks House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution over
speed on non-trivial work; use judgment on trivial tasks. Loaded automatically at launch
(same priority as `CLAUDE.md`). Subagents get their discipline from the skills
force-loaded via `briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — State assumptions. When uncertain, ask rather than guess.
   Push back when a simpler approach exists. Stop when confused; name what's unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — Touch only what you must. Match existing style.
4. **Goal-driven execution** — Define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — Contradicting patterns: pick one, explain
   why, flag the other for cleanup. Don't blend.
6. **Read before you write** — Here that means: read the upstream JS file and its
   upstream test file before any Perl. "I know how Nunjucks works" is the dangerous
   sentence in this repo.
7. **Tests verify intent, not just behavior** — A test that can't fail when the logic
   changes is wrong. Reproduce a bug before fixing it; leave a regression test behind.
8. **Checkpoint after every significant step** — Summarize: done / verified / left.
9. **Match the codebase's conventions, even if you disagree** — Conformance > taste.
10. **Fail loud** — "Done" is wrong if anything was skipped silently. "Tests pass" is
    wrong if any were skipped or TODO — report those counts with every green run.
11. **A red test is a claim before it is a failure** — Before changing code to turn a
    test green, say what the test asserts and whether your fix keeps that claim or
    replaces it. If the claim is wrong, fix the claim and say so.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  code yourself — delegate to `text-nunjucks-worker`. Your lane: coordinate, inspect,
  plan, review diffs, run tests, manage git and the board, edit non-behavioral docs,
  and put `decision` tickets in front of the maintainer. When in doubt, delegate. Why:
  only the `text-nunjucks-*` agents get the porting contract force-loaded via
  `briefing.skills`; you get no briefing and would port from memory.

  | Task | Agent |
  |---|---|
  | Port / implement / refactor / debug behavior-relevant code | `text-nunjucks-worker` (default) |
  | Port upstream test suites, grow the corpus, reproduce fidelity bugs | `text-nunjucks-test-writer` |
  | Compare a ported module against its upstream file (read-only) | `text-nunjucks-fidelity-auditor` |
  | Pre-release audit (read-only) | `text-nunjucks-release-checker` |

  A porting ticket goes worker → fidelity-auditor → (findings back to worker) → done.
  Skipping the audit is how "looks right" replaces "is 1:1".

- **You cannot spawn subagents** (you ARE a `text-nunjucks-*` agent): The delegation lock
  does not apply to you — work per your briefing and these rules.

Behavior-relevant = everything under `lib/`, `t/`, `xt/`, `maint/`, plus `cpanfile` and
`dist.ini`. Pure prose (README, ADR text, Changes wording, ticket bodies) is not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope —
don't invoke the `kanban-issues-karr-cli` skill first, just use it. Git-native kanban;
state lives in `refs/karr/*`. Day-to-day:

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create --title "…" --priority high --tags a,b --depends-on 1,2 --body '…'`
- `karr edit ID -a "note"` · `--claim NAME` · `--block "why"` — update
- `karr move ID in-progress --claim NAME` — start · `karr handoff ID --claim NAME --note "…"` — to review

Respect `depends_on`: a port ticket whose `decision` dependency is open is not startable
in full — either take the independent part or take the decision first.

**Serialize board mutations when fanning out.** Implementation may run in parallel;
collect results, then loop `karr move`/`handoff`/`sync` sequentially — N at once has
OOM-rebooted a host before. No background poll loops on the board.

## Release — never without permission

`prove`, `dzil build`, `dzil test` are fine anytime. `dzil release` and any upload are
STRICTLY forbidden without the maintainer's explicit go-ahead — even if a plan or ticket
lists "release" as the next step. For anything heading toward release: stop and ask.

## Public issues — never act without instruction

`karr` is the agent work board. A public tracker (GitHub — ours or **mozilla/nunjucks**)
is a different universe: never list, read, comment on, open or close an issue there on
your own initiative. Found an upstream bug? It gets ported (ADR 0004) and noted in a karr
ticket — reporting it upstream is the maintainer's call.

## Project hazards

- **Porting from memory.** Every model "knows" Nunjucks and Jinja2, and that knowledge is
  subtly wrong for v3.2.4 (autoescape is ON by default; backslash is escaped; `'0'` and
  `[]` are truthy; `null is defined` is true). The trap: memory-written code passes the
  obvious tests. Instead: `echo '{"template":"…"}' | node maint/oracle.js`, then commit
  the probe as a corpus case.
- **`upstream/` is gitignored and may be absent** (fresh clone, cleaned tree). Without it
  the oracle and `xt/oracle-live.t` cannot run and a "green" run proves less. Restore
  with `maint/fetch-upstream`; if there is no network, say the oracle check was NOT run.
- **`prove -l t/` is not the suite.** `t/upstream/` is a subdirectory; always
  `prove -lr t/`.
- **Expected values are generated, never typed.** `maint/corpus-regen` writes
  `expected` from the oracle. A hand-edited `expected` that matches the port's output is
  a test that can only ever agree with the bug.
- **Open mappings get decided once, by ADR, in one place.** Tickets tagged `decision`
  need the maintainer. A worker that quietly picks `sort keys` inside one filter has
  made an architecture decision that the next filter will make differently.

## Perl specifics — reference, don't restate

Module loading, class patterns, cpanfile, Changes and house style live in skills
`getty-perl-core` / `getty-perl-moo`; the porting contract in `text-nunjucks-core` (all
force-loaded for `text-nunjucks-*` agents). Do not duplicate that content here.
