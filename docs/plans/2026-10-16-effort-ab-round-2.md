# Effort and model test, round 2, for the task types round 1 left untested

Round 1 (`docs/plans/2026-10-15-phase-2-11-effort-ab.md`, Result) measured three task types and set reviews and fact
checks to sonnet at effort max and documentation fixes to sonnet at effort high. The owner asked on 2026-10-15 for the
same analysis of every other task type that LGE sessions use often, so that each contract role runs on a measured model
and effort. This brief is for the manager that designs and runs round 2. It is row P9 of the 2.11 plan.

## What to test

| Task type | Agent type and current setting | A task with a known answer, from `ARCH` = `/Users/dho/lungfish-phase-records/phase-2-10` |
|---|---|---|
| Code-diff lane review | `lge-expert`, sonnet at max since round 1, which tested only a candidate review | A lane whose review in `ARCH/reviews/` found numbered defects, scored on those defects |
| Inventory or memo | `lge-expert`, opus at max | A 2.10 field inventory or memo in `ARCH/inv/` or `ARCH/memos/`, scored on the questions and decisions the panel recorded |
| Single-field ruling | `lge-expert`, opus at max | A ruling in `ARCH/reviews/` (such as `ruling-A54.md`) whose outcome the plan records |
| Implementation lane | `lge-worker`, opus on the longest chain, sonnet for mechanical work, effort max | A small 2.10 lane from its frozen base, scored on its tests and its review's findings |
| Code fix agent | `lge-worker`, sonnet at max | A 2.10 fix round, scored on the review's numbered fixes and a passing build |
| Landing agent | `lge-worker`, sonnet at max | A 2.10 landing batch in `ARCH/land/`, scored on the ranges landed, the folded fixes and the build |
| Monitor checkpoint and memo tally | `llm-efficiency-monitor` on opus, the tally on sonnet, effort max | A 2.10 checkpoint in `ARCH/llm/` and the 2.10 tally, scored on their findings |

Choose by the spend each type took in 2.10 (the ledgers in `ARCH/llm/`) and drop any type whose task has no checkable
answer. Before freezing a task, take its brief from the 2.10 transcript of the spawn that wrote the keyed output
(`/Users/dho/lungfish-effort-ab/tools/find_spawn.py`), because round 1's plan named an earlier draft (correction C1).

## Arms

- Each role's current setting against one step down, the `xhigh` effort for opus roles where high lost in round 1, and
  a cheaper model at max where it could do the work (sonnet for an opus role). Round 1 found haiku not worth it, so add
  it only for a role where sonnet at high already passes.
- Two runs an arm at least, three for the types that build, where cost allows.

## Method, as round 1 ran it

- Write the pre-registration (tasks, keys, arms, margins, stop lines) before any run, and change nothing after it.
- Freeze inputs in bare repositories that cannot reach the answer commits, and keep the keys and the map of runs to arms
  outside both the test folder and the session scratchpad, since agents write temp files there.
- Reuse the tools in `/Users/dho/lungfish-effort-ab/tools/` (run setup, contamination scan, blinding, grading brief,
  unblinding, per-run cost from `scripts/llm/session_ledger.py`, result tables). Write round 2 under
  `/Users/dho/lungfish-effort-ab/round-2/`.
- Subagents start in the session's cwd and see the memory index, so the briefs pin each run to its own worktree, and the
  scan flags any read of the primary checkout, other worktrees, the memory folder, the phase records or the 2.10
  scratch folder. A spawn's effort is in its meta file and its transcript.
- Grade blind with a fresh `lge-expert` on opus at max per task and stage, with a second grader on three random reports.

Two lessons of round 1 shape the tasks and the runs.

- Avoid ceiling tasks. Round 1's documentation fix scored 44 of 44 in every arm and so measured only cost.
- Builds follow the efficiency contract (at most 5 building agents, launches about 3 minutes apart, disk checks).

## Budget and order

Round 1 used about 4 weekly points and left the reading at 64%, and the owner's ceiling is 90%. Lanes, fix agents and
landings build, so round 2 may take 10 to 15 points. Run the cheap types first (reviews, rulings, inventories, the
tally, the monitor) and the building types last, set stop lines that leave room for 2.11 itself, and ask the owner
which types to drop if the projection crosses them. Run each type before 2.11 spawns that type for its own work, or
spawn it at its current setting until its result is in.

## Done when

The Model choice row and the Roles table of `docs/contracts/RUNNING-A-PHASE-SESSION.md`, `docs/contracts/EXPERT-PANEL.md`
and the evidence tables carry each tested type's setting with its numbers, and this plan's Result section records the
decisions, the limits and the tasks a later round could add.
