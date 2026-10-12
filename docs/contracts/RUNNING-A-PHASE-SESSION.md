# Running a phase session with LLM agents

This contract sets how a Lungfish Genome Explorer (LGE) phase session spends model time. A phase session is one
manager session that turns a reviewed plan into landed lanes with Claude Code subagents. Its purpose is that every landed
lane costs as little model time as the work allows, without slowing the phase or running out of quota.

The rules come from measured sessions. `scripts/llm/session_ledger.py` reads a session's transcripts on this Mac, prices
every API turn per model and never prints message text. Its totals stay within about 1% of Claude Code's own cost
records. Costs here are API-equivalent estimates. The evidence for each rule is in the tables at the end.

## Every session runs the monitor

The owner asked on 2026-10-11 that the monitor run in every session of this repository, so that each session's lessons
make the next one cheaper. A phase session follows this whole contract and runs every checkpoint. Any other session
that spawns subagents, runs builds or lasts more than about an hour makes the Session start checks and runs the monitor
once, as its last checkpoint, at its end. A short session that spawns no subagent ends with
`python3 scripts/llm/session_ledger.py --md <file> <session id>` and adds its line to the session table under Evidence.
Each run compares its figures with the line of the session before it, names the rules that helped, the ones that did
not and any new rule its numbers support, and the End-of-session duty folds that into this contract.

## Roles

| Role | Model | Spawned | Reads | Leaves behind |
|---|---|---|---|---|
| Manager | the main session, opus | by the owner | the plan, the briefs, `notes.md`, verdict lines of reports | the landed program branch, the plan record, memory notes |
| Expert panel, which leads the session under `docs/contracts/EXPERT-PANEL.md` | opus at effort max | five inventory agents, then five fresh memo agents | the code, then the inventory files | `inv/<FIELD>.md`, `memos/<FIELD>.md` |
| Lane | opus on the longest chain or for judgment, sonnet for mechanical and documentation work | `isolation: "worktree"` on the program head, or in the worktree of the lane it builds on | its brief, `lane-rules.md` and the files it changes | commits, `lanes/<LANE>/<LANE>.md`, a final message under 150 words |
| Reviewer | opus at effort max, one fresh agent per lane | after the lane's final message | the lane report and the diff | `reviews/<LANE>.md` with a verdict and numbered fixes |
| Fix agent | sonnet unless a fix needs judgment | fresh, then EnterWorktree on the lane's worktree | the review file and the lane report | commits, `lanes/<LANE>/<LANE>-fix.md` |
| Landing agent | sonnet | fresh, in the program worktree | `land.md` and the ranges and review files in its prompt | cherry-picks, a build, targeted tests, the module map, ratchets, `land/land-N.md` |
| LLM-efficiency monitor | opus, one fresh agent per checkpoint, defined in `.claude/agents/llm-efficiency-monitor.md` | at the start, after each wave launch, about every two hours, and at the end | `llm/notes.md`, `llm/actions.md`, the last log entry, the session notes and event log | a ledger, a log entry, numbered actions, and at the end the update of this contract |

The manager plans, briefs, spawns and decides. It does not land lanes or edit code beyond a one-line fix, and its own
context is the scarcest resource of the session.

## Files the session keeps

Session files live in the session scratch folder (`SCR` below), outside the repository. Agents name them with literal
paths.

| File | Writer | Holds |
|---|---|---|
| `SCR/notes.md` | manager | The source of truth. A STATE block of about 40 lines, rewritten at every landing and launch, and a continuation guide |
| `SCR/events.log` | manager | One timestamped line per event, written by a small script in the same message as other calls |
| `SCR/briefs/` | manager | `lane-rules.md`, `review.md`, `fix.md`, `land.md` and one `lane-<LANE>.md` per lane |
| `SCR/lanes/<LANE>/<LANE>.md` | lane | Commits, tests, findings and a Handoff section with the state, remaining steps and exact commands |
| `SCR/reviews/<LANE>.md` and `SCR/land/land-N.md` | reviewer, landing agent | The verdict with numbered fixes, the landing record |
| `SCR/llm/` | monitor | Ledgers, `log.md`, `actions.md` and the monitor's `notes.md` |

## Session start

Before the first launch the manager checks the machine and the quota once, in one message.

| Check | Act when |
|---|---|
| `get_usage` for the 5-hour and weekly windows | The weekly window cannot carry the planned lanes at the rates under Quota pacing. Plan fewer lanes or a second session. |
| `df -h ~` and `tmutil listlocalsnapshots /` | Free space is under about 100 GB, or will be after the first wave at 15 GB a worktree. Delete the build folders of old worktrees. Thinning snapshots needs the owner's word. |
| Leftover processes, with the command below | A test stand-in, test runner or build from an earlier day still runs. Stop it before the first build. |
| `uptime` | The load average is over 40. Find the cause before launching. |
| `pwd` | The manager's cwd is not the program worktree. |

```bash
ps aux | rg 'xctest|swift-build|swift-test|lungfish-cli' | rg -v ' rg '
```

## Rules for every agent

Every brief carries these rules through `lane-rules.md`, `review.md`, `fix.md` and `land.md`.

| Rule | What to do |
|---|---|
| Fresh agents, never idle resumes | Start each stage, fix round and continuation with a fresh agent briefed with files. Never resume an agent idle for more than 5 minutes, since the resume writes its whole context to the cache again. |
| Lane budget and Handoff | Plan a lane at about 100 tool calls in milestones and name the stop milestone in the spawn prompt. Past about 150 calls or 400K of context, finish the step, commit, write the Handoff and stop. A fresh agent of the same model continues. Only a named milestone has stopped a lane, never a call count. |
| Batched reads | Put independent reads in one message and several ranges in one command. Do not read a file twice. |
| Guard-safe commands | Run git as a plain single command. Pass literal paths, never a shell variable or computed value, to `rg`, `sed`, `find`, `unzip` and `python3`. Put loops in a script file. |
| Calls inside the cache life | Pass timeout 270000 on every build, test and wait call, never 290000, because the wait and the model time of its turn together must stay under 5 minutes. Keep single model turns under 5 minutes. |
| Wait by blocking | Start a long build or test in the background with its exit code in a log, then wait with one foreground call that returns when the log has it, as below. Repeat the call when it times out. Never wait with Monitor or repeated `tail` calls. |
| Report file and short final message | Write the report to the lane's file, then end with a final message under 150 words (reviews under 100) that gives the head, the tests and the file path. |

The background call runs with `run_in_background` and the wait runs in the foreground with timeout 270000.

```bash
(swift build --skip-update --build-tests; echo "exit=$?") > build/lane/build.log 2>&1
until rg -q '^exit=' build/lane/build.log; do sleep 5; done; tail -n 20 build/lane/build.log
```

## Rules for the manager

| Rule | What to do |
|---|---|
| Exact bases | Paste every base commit into a spawn prompt in full, copied from `git rev-parse` output. Never type a commit hash. |
| Warm worktrees | Spawn fix agents and same-base continuations without `isolation` and have them call EnterWorktree on the lane's worktree. Reusing the worktree path is the only warm start, since the SwiftPM cache is tied to the absolute path. A continuation that first rebases far past its base builds cold anyway. |
| Chained lanes | When a lane builds on another lane whose review fixes are done, start it in that lane's worktree on a new branch from its head (no `isolation`, EnterWorktree, then `git switch -c`), without waiting for the first lane to land. Land its range after the first lane, and keep the worktree until both have landed. |
| Documentation lanes | Write the facts into the brief, each with its source (commit, file and line, or the review item's text), and name the files to edit. Budget about 80 tool calls, since the lane builds nothing. A lane that must find its facts in reviews and inventories reads dozens of files and still gets some wrong. |
| Landing batches | Give each batch of 3 to 5 reviewed lanes to one sonnet landing agent, with up to three small review fixes. Its brief allows the smallest fix of a compile error or a test failure where two lanes meet, in its own commit. For a failure in a file no lane of the batch touched, it runs that file alone and on the base once, records a pre-existing fault and goes on, without rerunning the whole suite. Extend a landing agent by message only while its context stays under about 300K. |
| Fold small follow-ups | Put review follow-ups that do not block a merge into the brief of a later lane on the same files, written out as facts. Keep them off the longest chain, and list the follow-ups of a cut lane under Moved out. |
| Concurrency | Run at most 5 building agents on a 20-core Mac, counting lanes, fix agents and landing agents but not reviews. Launch only at a load average under 40. |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour), aim at $110 to $150 an hour, and hold every spawn at 75%. A 5-hour point has cost about $8 and a weekly point $27 to $33. |
| Disk and snapshots | Each worktree build folder holds about 15 GB. Check `df -h ~` at every landing and delete the build folders of landed worktrees. Thinning local snapshots needs the owner's word. |
| Model choice | Opus at effort max for inventories, memos and reviews, opus for lanes on the longest chain, sonnet for mechanical and documentation lanes, fix agents and landings. |

## The manager's context budget

Every spawn prompt, brief, final message and tool result stays in the manager's context. Claude Code compacts it at 97%,
and near that line a manager turn costs about four times what it costs after the compaction. With a current STATE block
the compaction costs one turn, so there is no reason to avoid it. Five habits keep the context lean and make the
compaction safe.

| Habit | Why |
|---|---|
| Read verdict lines and named sections with `rg -n` and `sed -n`, never a whole report, diff or log. Pass paths to agents, not content. | Whole-file reads fill the manager fastest. |
| Handle each completion in one message, with the event line, the notes update and the next spawn. Keep text between calls to one line. | Every completion costs turns at the manager's context size. |
| Rewrite the STATE block in `notes.md` at every landing and launch, with a continuation guide naming every running agent, the next launches and the end steps. | The STATE block is the only memory that survives compaction. |
| Keep the cwd inside the program worktree for the whole session, and reach the primary checkout with `git -C`. | EnterWorktree is refused for a subagent while the manager's cwd is outside a worktree. |
| Give landings, small review fixes and probes to sonnet agents. | Their turns cost $0.04 to $0.06 against $0.15 to $0.22 for the manager late in a session. |

## Limits of Claude Code to state in every brief

| Limit | Do instead |
|---|---|
| A subagent Write of a file whose name starts with report is refused | Name the file after the lane, `<LANE>.md` |
| Foreground `sleep` is blocked, and the refusal suggests Monitor | The blocking wait above |
| Monitor returns at once and streams events while the agent keeps working | Use it only to watch while doing other work |
| `python3 -` waits on stdin until the call times out | Write the script to a file and run it |
| A Bash call moves to the background at its timeout, 120 s by default | Pass a timeout on every long call |
| Background and Monitor events of a subagent never reach the manager | Report in the final message and the lane file |
| EnterWorktree is refused when the spawning session's cwd is outside a worktree | Keep the manager's cwd in the program worktree |

## Checkpoint routine

A fresh monitor agent runs each checkpoint, briefed with files. Its scripts read the transcripts, so no transcript text
enters its context. It writes only under `SCR/llm/`, starts no subagents and runs no builds.

1. Run the ledger with the command below, keep its JSON for the next checkpoint, and read its totals, roles, flags and
   failures with the spend per stage since the last checkpoint.
2. Read `get_usage` (5-hour, weekly and the manager's context), `df -h ~` and the size of the build folders.
3. Check that the briefs carry this contract's values (the wait timeout, named milestone stops, the documentation lane
   budget), since a rule that never reaches a brief is not followed.
4. Check the thresholds below, append a dated entry to `SCR/llm/log.md` and put numbered actions with agent ids and
   evidence at the top of `SCR/llm/actions.md`.
5. End with a final message under 200 words.

```bash
python3 scripts/llm/session_ledger.py --top 12 --md SCR/llm/ledger-cpN.md --json SCR/llm/ledger-cpN.json SESSION_ID
```

| Signal | Threshold | Action |
|---|---|---|
| Pending tool call | over 15 minutes | Ask the agent, and stop it with a Handoff when it hangs |
| Lane size | about 150 tool calls or 400K of context, 80 calls for a documentation lane | Finish the step, write the Handoff, continue with a fresh agent |
| Resume of an idle agent | any, after 5 idle minutes | Replace it with a fresh agent briefed with files |
| Guard rejections or new refusals | over 1% of an agent's turns, or a new kind | Fix the command forms in the brief |
| Poll-only turns | over 10% of spend | Restate the blocking wait in the briefs and to the running agents |
| Cache rebuild | any after a wait of 290 s or more | Set the wait timeout in the briefs to 270000 |
| Burn | over about $150 an hour, or above the quota line | Hold launches |
| Building agents and load | over 5, or a load average over 40 | Hold launches |
| Free disk | under about 100 GB | Delete the build folders of landed worktrees |
| Manager context | over 85% | Refresh the STATE block and expect compaction |

## Evidence

The direct cost of a lane is its lane agents, its review, its fix agent and its share of the landing agent. The all-in
cost adds the expert panel, the manager and the monitor.

| Session | Date | Spend and wall time | Lanes landed | Direct cost per landed lane | All-in per landed lane |
|---|---|---|---|---|---|
| 2.6, two sessions | 2026-10-10 | $1,438 over 16h05m | 24 | about $53 | about $60 |
| 2.7, one session, at its fourth checkpoint | 2026-10-11 | $1,069 over 9h12m | 30, with 4 more to land | median $23.60, mean $27.03 | $35.64 |

| Rule | Measurement | Sessions |
|---|---|---|
| Fresh agents | 16 resumed fix rounds cost $189 at a median context of 680K. 22 fresh fix agents cost $119 (median $4.50), and fresh memo agents $19 against about $29 by resuming the experts. | 2.6, 2.7 |
| Lane budget and Handoff | Lanes ran a median 313 turns, and in one session spent 72% of lane money above 400K. A named milestone later stopped a lane at 162 calls, while a lane with only a call count in its brief ran to 258. $174 went into turns past 150 calls, where fresh continuations would have cost about $121. | 2.6, 2.7 |
| Batched reads | 1.11 to 1.19 calls a turn with 23% single read-only turns, then 1.34 and 17%. | 2.6, 2.7 |
| Guard-safe commands | 2.7% of turns rejected, then 0.65%. About half of the rest were git in a compound command or `rg` given a variable, most of them from sonnet agents. | 2.6, 2.7 |
| Calls inside the cache life | 44 cache rebuilds cost $88, then 5 cost about $6, two of them right after a 290 s wait. | 2.6, 2.7 |
| Wait by blocking | Poll-only turns took 27% to 29% of spend in busy periods, with 61 Monitor calls. After the rule they took 6% to 7%, with none. | 2.7 |
| Short final messages | Final messages fell from up to 4,600 characters to about 1,000, and the manager's context then grew 1.0K tokens a minute against 2.6K. | 2.7 |
| Warm worktrees | First builds took a median 45 s warm against 191 s in fresh worktrees, and warm fix agents cost a median $3.39 against $6.86. | 2.7 |
| Chained lanes | A lane started in its base lane's worktree 39 minutes before that lane landed, and its first build took under 2 minutes against up to 388 s cold. | 2.7 |
| Documentation lanes | A lane briefed by reference made 211 calls and read 81 files, and its review found 3 wrong facts. With review and fix it cost $31, more than the median landed lane that builds. | 2.7 |
| Landing batches | 7 sonnet landing agents landed 28 lanes for $54 ($1.93 a lane) against $2.78 for the manager's one landing. One spent 35 minutes on two full test runs for a pre-existing fault, and one handed a two-lane test fix back to the manager. | 2.7 |
| Concurrency | With 8 to 13 builders the load reached 105 to 122 and cold builds took 375 to 673 s instead of 153 s. With the cap the load stayed under 20, apart from one spike to 65. | 2.7 |
| Quota pacing | The weekly quota ran out after wave 1. At $207 an hour a 5-hour window would have run out an hour early, and at $111 it read 75% 17 minutes before its reset. | 2.6, 2.7 |
| Disk and snapshots | 20 build folders held 309 GB with 48 GiB free. Deleting landed build folders and thinning snapshots left 14 folders of 204 GB and 496 GiB free. | 2.7 |
| Model choice | An opus turn cost $0.098 on average, a sonnet turn $0.070 and a landing turn $0.056. | 2.7 |
| Manager context | 26 manager turns between 93% and 97% cost $0.217 each. After the compaction at 966K the manager resumed in one turn, and its turns cost $0.058. | 2.7 |
| Session start | A test stand-in from an earlier day had run for two days (52 CPU minutes) before an agent found it. | 2.7 |
| Exact bases | Two lane prompts named a mistyped base, and both lanes stopped at the fast-forward. | 2.7 |

## End-of-session duty

The monitor's last checkpoint of every phase session updates this contract in a commit that lands before the final
candidate, so the unit tier covers the ledger's test.

- Add the session to the session table and replace measurements with newer ones.
- Change or remove a rule that a before-and-after measurement contradicts. Add a rule only when a measurement supports
  it, and keep this file under about 200 lines.
- Update `.claude/agents/llm-efficiency-monitor.md`, and `scripts/llm/session_ledger.py` with
  `scripts/tests/test_session_ledger.py`, when they changed during the session.
- The next session's checkpoint 0 records the closing figures of the session before it, for its own update.
