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

## Result

Round 2 ran on 2026-10-15 in session `c397af17-1a00-415f-87b1-34a58de72069` from 15:47 to about 23:50 CDT, from a
weekly reading of 64% to 79%, with the Preview 2026.10.19 release in the same window until about 19:00. The session
ledger reads $328.43, of which the 48 runs took $190.09. The owner chose to test every type, with no new run at a weekly
reading of 83% and every agent stopped at 85%. At 17:48 the projection crossed the launch line, so the memo tally, haiku
and the third run of each arm of the opus lane were cut in the pre-registered order. The records are in
`/Users/dho/lungfish-effort-ab/round-2` (`prereg.md`, `effort-ab-result.md`, `runs.csv`, `grades/`, `tools/`), and the
keys, the run map and the run log are in `/Users/dho/lungfish-effort-ab-private/round-2`.

| Task type | Setting | Measured on |
|---|---|---|
| Code-diff lane review | sonnet at effort max, kept | The review of lane A30 M3. Sonnet at max summed 7.5 of 14 recall points with no false finding against opus at max's 7.0 with 1, for a median $2.81 against $3.23 a run. Sonnet at high summed 6.0 with 6 false findings |
| Single-field ruling | opus at effort xhigh | The SWIFT ruling on the FXT2 double close. Xhigh summed 24.0 of 30 with 1 false finding against max's 25.5 with none, for $2.00 against $3.11. Sonnet at max made 3 false findings |
| Inventory or memo | opus at effort xhigh | QA's memo of Phase 2.10. Xhigh summed 93.0 of 122 with no false finding against max's 95.0 with 2, for $3.17 against $6.66. Sonnet at max summed 82.5 |
| Monitor checkpoint | opus at effort xhigh | Checkpoint 4 of 2.10. Xhigh summed 43.5 of 48 against max's 42.0, each with 4 false findings, for $6.38 against $9.29. Sonnet at max matched for $12.99 |
| Lane on the longest chain | opus at effort xhigh | Lane A18 through M2. Xhigh summed 25.5 of 26 with 2 false findings against max's 26.0 with 1, for $3.54 against $5.97, and both runs passed the hidden tests. Sonnet at max matched for $4.73 |
| Mechanical lane | sonnet at effort max, kept | Lane S34 M1 and M2. High summed 30.5 of 39 with 4 false findings against max's 34.0 with 1, under the floor of 32.0 |
| Code fix agent | sonnet at effort max, kept | FX30, the five fixes of the A30 M3 review. High summed 20.5 of 21 with 4 false findings against max's 21.0 with 1, over the limit of 3. Its false findings are miscounts in its reports of the suite list and the bundle totals |
| Landing agent | sonnet at effort max, kept and not measured | Landing 12. All four runs at high were void, since each ran the chapter lint, whose `npm install` reached the network against the brief. Graded blind as a check, they scored 17.25 a run against 18.5 at max |
| Memo tally | sonnet at effort max, kept and not measured | Cut |

Each arm ran 2 runs, or 3 for the fix and the mechanical lane, and the landing ran 2 at max with 4 void runs at high.
Every graded building run ended with a clean build and its named tests passing. Thinking was 56% to 89% of output at
max, 46% to 70% at xhigh and 12% to 52% at high, and xhigh took 50% to 71% of max's time.

Limits.
- Two or three runs an arm and one task a type, so a match means only that no large loss showed on that task. Votes and
  inventories did not run as tasks, and the type "inventory or memo" was measured on a memo.
- One blind grader per task, opus at max. A second grader rescored one report each of the memo, the ruling and the
  monitor and agreed within one item. No building task had a second grader.
- The landing's frozen inputs lacked the lint packages that the fix's carried, so a landing that linted needed the
  network, and that gap left landings unmeasured. Two of the void runs also ran `pkill -f swift-build` across the
  machine and stopped another run's build each time.
- Before any building grade the check script was found to differ from two keys. The ratchets first ran under bash, and
  the lanes' hidden tests were first copied over the runs' own tests instead of the base's. Both were run again by each
  key's own procedure, and the fix's mutated readers and lints were added (rulings R10 and R11 in the run log).
- The review's sonnet at max cost 87% of opus at max, over the 85% the rule calls cheaper. The rule takes the lowest
  median of the settings that pass, so reviews stay on sonnet.

Tasks a later round could add.
- The landing again, with the lint packages frozen in its inputs.
- The memo tally, a vote and an inventory.
- Opus at high or medium for the four types where xhigh matched, measured against xhigh.
- A second grader on the building tasks, and three runs for every arm.
