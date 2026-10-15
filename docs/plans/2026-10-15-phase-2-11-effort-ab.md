# Effort A/B for LGE agents: does high or medium match max?

Run this in a new session with a fresh weekly quota, whose weekly reading is 10% or less at the start. Work in a
worktree of the Lungfish Genome Explorer repository, never the primary checkout. Follow
`docs/contracts/RUNNING-A-PHASE-SESSION.md` (waits, files written in parts, one command a call) and
`docs/contracts/EXPERT-PANEL.md`. Every rule below is fixed before any result, and none changes after.

## Why

The owner asked whether max effort is needed, or whether a lower effort gives results as good. Phase 2.10's records
cannot answer:
- Every expert, worker, monitor and fact-check message of 2.9 and 2.10 carries the transcript label `effort: max`. That
  includes spawns that passed no effort, whose meta file has no `effort` key. So no record holds a run below max.
- In 2.10, most subagent messages were written without a final usage: 8,240 of 9,176 expert messages end with no stop
  reason. 2.9 kept it on the same Claude Code 2.1.295. So take tokens from `scripts/llm/session_ledger.py`, which
  estimates missing output from content, and report each arm's share of messages without a final usage.
- Effort moves the amount of thinking. General-purpose Opus put 23.5% of its output into thinking at medium and 65.7% at
  max (session `48eceb2d`). Thinking was 66.8% of 2.9's output tokens, and output was 26.9% of 2.10's estimated spend.

## Paths

- ARCH: `/Users/dho/lungfish-phase-records/phase-2-10`, the durable records of 2.10.
- AB: `/Users/dho/lungfish-effort-ab`, created by you. Everything this test writes goes here, in `inputs/`, `keys/`,
  `runs/`, `grades/` and `ledger/`.
- No agent but the grader reads `AB/keys/`.

## Step 0. Freeze the inputs

1. **Repositories, one per task family, so that no answer commit is reachable.** In your worktree, make the local
   branches below and check each with `git log --no-walk --format='%h %s'`. For each family, run `git init`, then a
   `git fetch` of only its branches from your worktree:

   | Repository | Branches |
   |---|---|
   | `AB/repo-e1` | `83e22edfa`, and `f4785a0b7` (main, `Q36-candidate.md:101-102`) |
   | `AB/repo-e2` | `5fa704aa9`, `aa994c25b` |
   | `AB/repo-f1` | `1227d6035` (the notes), `9ad0f149c` (the code) |
   | `AB/repo-w2` | `d1a58cff7`, the parent of `8415005bc` |

   Then check that the answer commits are absent:
   - `git cat-file -e 8415005bc` must fail in `repo-f1` and `repo-w2`;
   - `git cat-file -e d456c7a74` must fail in `repo-e1`.

   If `f4785a0b7` is missing, drop key E1-K2. Each run gets its own `git worktree add` of its family's repository.
2. **Inputs** go in `AB/inputs/<task>/`. Record the sha256 of each file.
   - E1, QA's review of the candidate (part 1 only). Take `ARCH/lanes/Q36/qa-candidate-prompt.txt` with its paths moved
     to AB, and drop any line about memory notes. Take `ARCH/lanes/Q36/Q36.md` cut at the end of its M2 section, since
     the review read "from M1 summary through `## M2`" (`ARCH/reviews/Q36-candidate.md:3`). Record the cut line. Add
     `ARCH/lanes/Q36/red5-base.md`, `ARCH/reviews/Q36-M1-reds.md`, and any other ARCH file the prompt names, except the
     keys below.
   - E2, a ruling on the two unlisted O3 defects. Take `ARCH/record/o3-walk-result.md`, with any lines that name a
     cause cut. Copy the walk record
     `/Users/dho/LGE-GUI-Walk/p210-o3/Pathogen Detection.lungfish/Analyses/kraken2-2026-10-14T17-48-29/.lungfish-provenance.json`,
     and drop E2 if it is missing. Write a neutral brief: for each defect, say whether the record or the display is
     wrong, give the cause at `5fa704aa9` as `path:line`, say what else it hits, and say whether it blocks Preview
     2026.10.18.
   - F1, a fact check. The slice S1 is the first 43 claims of `ARCH/lanes/U40/claims.txt` in file order. Check them
     against `docs/release-notes/2026.10.18.md` at `1227d6035`, with the code at `9ad0f149c`. There is no build: help
     text comes from `Tests/Fixtures/golden/cli-help/`. Leave unscored the claims that U40 marks Report-only
     (`ARCH/reviews/U40-facts-1.md:3`).
   - W2, a Sonnet docs fix. Apply the Corrected wording of every WRONG row of `ARCH/reviews/U40-facts-1.md` to the notes
     at `d1a58cff7`, in one commit. Here the review is the input, not the key. Before any run, check that each flagged
     sentence is present at `d1a58cff7`, and score only those that are.
3. **Keys** go in `AB/keys/`. For each key, write the numbered findings before any run.
   - E1: `ARCH/reviews/Q36-candidate.md` part 1 (`:5-194`).
     - K1: the class hung in five runs, not four (its "### 2" section).
     - K2: a rebase of `main` conflicts in `docs/architecture/MODULES.md` (`:101-102`).
     - K3: `publish` must run on `main` in the worktree that holds the candidate (`:103-106`).
     - K4: "a 2.11 row fixes it" is unsupported, since a stack with no app frame cannot tell a test fault from an app
       continuation that never resumes.
     - K5: row 56 cannot be followed to an outcome.
     - Not scored: the appcast path (`:157`), which depends on the file system of 2026-10-15.
   - E2: `ARCH/reviews/O3-defects.md`.
     - Defect 1 (`:5-60`): the record is right, `looksLikePath` takes the `sh -c` script for a path, and
       `tailUnderProjectRoot` cuts at the first `.lungfish/`.
     - Defect 2 (`:61-111`).
     - The Verdict (`:112` on).
   - F1: U40's verdict for each id in S1. Its 86 claims hold 16 WRONG (`U40-facts-1.md:9-95`).
   - W2: `git show 8415005bc -- docs/release-notes/2026.10.18.md`, and the deviations that QA accepted in section 1 of
     `Q36-candidate.md`.

## Arms, and a check that each effort takes hold

| Role | Agent type | Model | Arms |
|---|---|---|---|
| Expert panel | `lge-expert` | opus | max, high, medium |
| Fact check | `manual-fidelity-reviewer` | sonnet | max, high, medium |
| Fix worker | `lge-worker` | sonnet | max, high, medium |

Set the effort on every spawn, and never name it in a brief. Before the first block, spawn one agent of one call per
arm. Check that its meta file (`subagents/agent-<id>.meta.json` of this session) holds `"effort":"<arm>"`, and record
what its transcript's `effort` field says. Void any later run whose meta file lacks its arm's effort.

## Runs and order

- Make 3 runs per arm per task: E1 and E2 for experts, F1 for the fact check, W2 for the fix worker. That is 36 runs.
- Each run is a fresh agent in its own worktree. Every arm gets the same brief.
- Stop lines, by the agent's own count and the same for every arm: about 60 calls for E1, E2 and W2, and about 80 for
  F1. Record a run that reaches its line.
- Run the tasks in priority order: E1, F1, W2, E2.
- Within a task, rotate the arms: run 1 max, high, medium; run 2 medium, max, high; run 3 high, medium, max. Run at most
  3 agents at once. Build nothing.
- **Contamination.** After each run, scan its transcript with a small script. Look for any read under `ARCH/reviews/`,
  `ARCH/lanes/U40/U40*`, `AB/keys/` or `/Users/dho/lungfish-phase-records`, and for any git command naming a commit
  outside its repository. A hit voids the run, which you rerun once.

## Blind grading

- Copy each report to `AB/grades/blind/<random id>.md`, and strip agent ids, times and token counts from it. Keep the
  map of ids to arms in `AB/runs/map.csv`, which no grader reads.
- Give each task one grader: a fresh `lge-expert` on opus at effort max. It gets the task's key, the frozen inputs and
  the blind reports in random order. It never sees an arm, the map or a cost.
- **Rubric.** Score each key finding as found (1), partly found (0.5: the right place, with the cause wrong or missing)
  or missed (0). Mark every other finding:
  - true-new: checked at the frozen commit with `path:line`; listed, with no penalty;
  - false: contradicted by the code or the inputs;
  - unsupported: no evidence that can be checked.

  In W2, score each flagged sentence as fixed (1), partly fixed (0.5) or not fixed (0). Count each new false statement
  as false.
- The grader writes `AB/grades/<task>.csv`: id, recall, false, unsupported, and one reason per finding.
- A second fresh grader rescores 4 random reports. Where the two graders differ by more than one finding in a report,
  rule from the key and record it.

## Metrics per run

- Recall of known findings, as found over known.
- False and unsupported findings.
- Estimated $, and output and thinking tokens, from `session_ledger.py` on this session, with the run's share of
  messages without a final usage.
- Wall time, tool calls, and whether the run reached its stop line.

## Decision rule, fixed now

For each role, compare each arm with max over that role's tasks.
- **Match.** On every task, the arm's recall summed over its runs is at least max's minus 1, and its false plus
  unsupported findings are at most max's plus 1. On E1, it also finds K2 and K3 in at least as many runs as max.
- **Cheaper.** On every task, its median estimated $ a run is at most 85% of max's.
- **Choice.** Use the lowest effort that matches and is cheaper, provided every effort between it and max also matches.
  Otherwise keep max.
- **Too few runs.** Keep max for a role where any arm has fewer than 2 graded runs of a task.
- **Limit.** With 3 runs an arm, a match means no large loss on these tasks, not proven equality. Say so in the result.

## Budget and stop lines

- **Readings.** Read the weekly quota with `get_usage` at the start (Q0), after every 3 runs, and before each launch.
- **Plan.** 36 runs, plus grading, at the medians that 2.10 measured:
  - a review $4.67 and a fix $4.61 (`ARCH/llm/ledger-cp12b.md:28-29`);
  - two Sonnet fact-check slices of about 114 claims each, $16.34 together (`RUNNING-A-PHASE-SESSION.md:179`).

  That comes to about $150 to $250, or 6 to 9 points at $26.92 to $27.26 a point (`RUNNING-A-PHASE-SESSION.md:181`).
- **Stop lines.** Launch no run at Q0 + 9. At Q0 + 12, stop every agent and grade what is done. The rotation keeps the
  arms balanced at any stop. Stop and grade any run that passes twice the median cost of its task's max runs.

## Applying the result

- Whatever the result, add it to the Evidence table of `docs/contracts/RUNNING-A-PHASE-SESSION.md`: arms, runs, recall,
  false findings and median $.
- If a role moves to effort X, set `effort: X` in the frontmatter of `.claude/agents/lge-expert.md` (the panel) or of
  `.claude/agents/manual-fidelity-reviewer.md` (the fact check).
- For Sonnet fix workers, set X in the Fix agent row (`RUNNING-A-PHASE-SESSION.md:28`) and in the STATE's spawn line,
  not in `lge-worker.md`, since that type also runs Opus lanes and landings that this test did not cover.
- Update "opus at effort max" in the Roles rows (`:25`, `:27`), in the ruling rule (`:101`) and in Model choice
  (`:105`).
- Commit agent types before the session that uses them, because a type added mid-session was not found (`:183`).
- At that session's first checkpoint, confirm with `ARCH/llm/spawn_effort.py` that the meta files carry the new effort.
  If the frontmatter does not reach them, set the effort on every spawn.

## Report

Write `AB/effort-ab-result.md` with:
- the setup checks and sha256s;
- the effort check;
- a table per task: arm, run, recall, false, unsupported, estimated $, output and thinking tokens, calls, wall time,
  stop line reached, voided;
- the decision per role, by the rule;
- the quota readings.

End with one line per role: `<role>: <effort>, because <numbers>`. Run the monitor once at the end, as the contract
asks of short sessions.
