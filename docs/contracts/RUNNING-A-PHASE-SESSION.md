# Running a phase session with LLM agents

This contract sets how a Lungfish Genome Explorer (LGE) phase session spends model time. A phase session is one
manager session that turns a reviewed plan into landed lanes with Claude Code subagents. Its purpose is that every landed
lane costs as little model time as the work allows, without slowing the phase or running out of quota.

The rules come from measured sessions. `scripts/llm/session_ledger.py` reads a session's transcripts on this Mac, prices
every API turn per model and never prints message text. Its totals stay within 0.4% of Claude Code's own cost records
for sonnet and about 3.5% under them for opus. Costs here are API-equivalent estimates. The evidence for each rule is in
the tables at the end.

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
| Expert panel, which leads the session under `docs/contracts/EXPERT-PANEL.md` | opus at effort max, sonnet for the tally | five inventory agents, five fresh memo agents, then one agent that drafts the tally | the code, then the inventory files, then the memos | `inv/<FIELD>.md`, `memos/<FIELD>.md`, a tally table with the split questions flagged for the manager |
| Lane | opus on the longest chain or for judgment, sonnet for mechanical and documentation work | `isolation: "worktree"`, then `git merge --ff-only` to the program head or to the head of the lane it builds on | its brief, `lane-rules.md` and the files it changes | commits, `lanes/<LANE>/<LANE>.md`, a final message under 150 words |
| Reviewer | opus at effort max, one fresh agent per lane | after the lane's final message | the lane report and the diff | `reviews/<LANE>.md` with a verdict, numbered fixes as `path:line` and text, and rulings on its field's questions |
| Fix agent | sonnet unless a fix needs judgment | fresh, `isolation: "worktree"`, then `git merge --ff-only` to the lane head | the review file and the lane report | commits, `lanes/<LANE>/<LANE>-fix.md` |
| Landing agent | sonnet | fresh, in the program worktree | `land.md`, the ranges, the review files and the small fixes to fold in | cherry-picks, folded fixes, a build, targeted tests, the module map, ratchets, `land/land-N.md` |
| LLM-efficiency monitor | opus, one fresh agent per checkpoint, defined in `.claude/agents/llm-efficiency-monitor.md` | at the start, after each wave launch, about every two hours, and at the end | `llm/notes.md`, `llm/actions.md`, the last log entry, the session notes and event log | a ledger, a log entry, numbered actions, and at the end the update of this contract |

The manager plans, briefs, spawns and decides. It does not land lanes or edit code beyond a one-line fix, and its own
context is the scarcest resource of the session.

Spawn lanes, continuations, fix agents and landing agents as the `lge-worker` agent type, and experts as `lge-expert`.
A general-purpose subagent re-reads a first-turn prefix of about 45K tokens on every turn, and a type with a short tool
list about 10K. Measure the first turns of both types at checkpoint 1.

## Files the session keeps

Session files live in the scratch folder `SCR`, outside the repository, and agents name them with literal paths.

| File | Writer | Holds |
|---|---|---|
| `SCR/notes.md` | manager | The source of truth. A STATE block of about 40 lines, rewritten at every landing and launch, and a continuation guide |
| `SCR/events.log` | manager | One timestamped line per event, written by a small script in the same message as other calls |
| `SCR/briefs/` | manager | `lane-rules.md`, `review.md`, `fix.md`, `land.md` and one `lane-<LANE>.md` per lane |
| `SCR/lanes/<LANE>/<LANE>.md` | lane | Commits, tests, findings and a Handoff section with the state, remaining steps, the files to read with their line ranges and the next command |
| `SCR/reviews/<LANE>.md` and `SCR/land/land-N.md` | reviewer, landing agent | The verdict with numbered fixes, the landing record |
| `SCR/land/*.py` | landing agents | Wrappers that every later landing reuses, such as `run_swift.py`, which runs one swift command and ends its log with an exit line |
| `SCR/llm/` | monitor | Ledgers, `log.md`, `actions.md` and the monitor's `notes.md` |
| `build/llm/` of the primary checkout | monitor, at the last checkpoint | The monitor's helper scripts and the landing wrappers, for the next session |

## Session start

Before the first launch the manager checks the machine and the quota once, in one message.

| Check | Act when |
|---|---|
| `get_usage` for the 5-hour and weekly windows | The weekly window cannot carry the planned lanes at the rates under Quota pacing. Plan fewer lanes or a second session. |
| `df -h ~` and `tmutil listlocalsnapshots /` | Free space is under about 100 GB, or will be after the first wave at 16 GB a worktree. Delete the build folders of old worktrees. Thinning snapshots needs the owner's word. |
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
| Lane budget and Handoff | Plan a lane at about 100 tool calls in milestones and name the stop milestone in the spawn prompt. Only a named milestone has stopped a lane, never a call count, so the milestone's size sets the lane's cost. A cold continuation makes 57 to 103 calls before its first edit, so past about 150 calls or 400K of context the lane finishes its milestone, and a fresh agent of the same model takes the next one from the Handoff. |
| Batched reads | Put independent reads in one message and several ranges in one command. Do not read a file twice. |
| Guard-safe commands | Run each command alone, since the guard refuses a `;` or `&&` chain that names a path under the checkout folder, and every SCR path is one. Run git from your own directory, never with `-C` or after a `cd` into another worktree. Pass literal paths, never a shell variable or computed value, to `rg`, `sed`, `find`, `unzip` and `python3`. Put loops in a script file. |
| Calls inside the cache life | Pass timeout 180000 on every build, test and wait call of an opus agent and 270000 for a sonnet agent, because the wait and the model time of the turn that issues it must stay under 5 minutes together. Keep single model turns under 5 minutes, and write a long file in parts. |
| Wait by blocking | Start a long build or test in the background with its exit code in a log, then wait with one foreground call that returns when the log has it, as below. Repeat the call when it times out. Never wait with Monitor or repeated `tail` calls. |
| Report file and short final message | Write the report to the lane's file, then end with a final message under 150 words (reviews under 100) that gives the head, the tests and the file path. |

The background call runs with `run_in_background`, the wait in the foreground with the timeout above. The guard refuses
the subshell when its log path is absolute or under SCR, so landing agents ran swift through a one-file Python wrapper.

```bash
(swift build --skip-update --build-tests; echo "exit=$?") > build/lane/build.log 2>&1
until rg -q '^exit=' build/lane/build.log; do sleep 5; done; tail -n 20 build/lane/build.log
```

## Rules for the manager

| Rule | What to do |
|---|---|
| Exact bases | Paste every base commit into a spawn prompt in full, copied from `git rev-parse` output. Never type a commit hash. |
| Fresh worktrees | Spawn every lane, continuation and fix agent with `isolation: "worktree"` and its base in full, and have it run `git merge --ff-only` to that base first. A subagent cannot enter another agent's worktree, so no worktree is reused. Delete a lane's build folder as soon as its last agent ends. |
| Chained lanes | Start a lane that builds on a reviewed lane from that lane's head commit, without waiting for the first lane to land. Land its range after the first lane. |
| Documentation lanes | Write the facts into the brief, each with its source (commit, file and line, or the review item's text), and name the files to edit. Budget about 80 tool calls, since the lane builds nothing. A lane that must find its facts in reviews and reports reads dozens of files, fills its context and still gets some wrong. |
| Landing batches | Give each batch of 3 to 5 reviewed lanes to one sonnet landing agent, and fold the reviews' small fixes, written as `path:line` and text, into its brief instead of spawning fix agents. Keep fix agents for fixes that need a measurement, a new test design or judgment. The brief allows the smallest fix of a compile error or a test failure where two lanes meet, in its own commit. For a failure in a file no lane of the batch touched, the agent runs that file alone and on the base once, records a pre-existing fault and goes on, without rerunning the whole suite. Extend a landing agent by message only while its context stays under about 300K. |
| Fold small follow-ups | Put review follow-ups that do not block a merge into the brief of a later lane on the same files, written out as facts. Keep them off the longest chain, and list the follow-ups of a cut lane under Moved out. |
| Rulings | Route each open question as `docs/contracts/EXPERT-PANEL.md` sets out under Rulings and disputes. A question of one field goes to the lane's reviewer or one fresh expert of that field. Only a question across fields or a change to a recorded decision goes to a vote of the panel. |
| Concurrency | Run at most 5 building agents on a 20-core Mac, counting lanes, fix agents and landing agents but not reviews. Launch only at a load average under 40. |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour), aim at $110 to $150 an hour, and hold every spawn at 75%. A 5-hour point has cost $7.20 to $8 and a weekly point $27 to $33. |
| Disk and snapshots | Each worktree build folder holds about 16 GB. Check `df -h ~` at every landing. Local snapshots keep deleted folders until a thinning, and thinning needs the owner's word. |
| Model choice | Opus at effort max for inventories, memos and reviews, opus for lanes on the longest chain, sonnet for mechanical and documentation lanes, the memo tally, fix agents and landings. |

## The manager's context budget

Every spawn prompt, brief, final message and tool result stays in the manager's context. Claude Code compacts it at 97%,
and near that line a manager turn costs about four times what it costs after the compaction. With a current STATE block
the compaction costs one turn, so there is no reason to avoid it. These habits keep the context lean and safe.

| Habit | Why |
|---|---|
| Read verdict lines and named sections with `rg -n` and `sed -n`, never a whole report, diff or log. Pass paths to agents, not content. | Whole-file reads fill the manager fastest. |
| Handle each completion in one message, with the event line, the notes update and the next spawn. Keep text between calls to one line. | Every completion costs turns at the manager's context size. |
| Rewrite the STATE block in `notes.md` at every landing and launch, with a continuation guide naming every running agent, the next launches and the end steps. | The STATE block is the only memory that survives compaction. |
| Keep the cwd inside the program worktree for the whole session and run git there, where `git rev-parse worktree-agent-<id>` reads any lane's head. | The guard refuses `git -C` into another worktree, and a landing agent spawned without isolation works in the manager's worktree. |
| Give landings, small review fixes, the memo tally and probes to sonnet agents. | Their turns cost $0.04 to $0.06 against $0.12 to $0.22 for the manager. |

## Limits of Claude Code to state in every brief

| Limit | Do instead |
|---|---|
| A subagent Write of a file whose name starts with report is refused | Name the file after the lane, `<LANE>.md` |
| Foreground `sleep` is blocked, and the refusal suggests Monitor | The blocking wait above |
| Monitor returns at once and streams events while the agent keeps working | Use it only to watch while doing other work |
| `python3 -` waits on stdin until the call times out | Write the script to a file and run it |
| A Bash call moves to the background at its timeout, 120 s by default | Pass a timeout on every long call |
| Background and Monitor events of a subagent never reach the manager | Report in the final message and the lane file |
| EnterWorktree from a subagent into another agent's worktree is refused | `isolation: "worktree"` and `git merge --ff-only` to the head to build on |
| Agent types in `.claude/agents/` load only when the session starts | Commit a new type before the session that uses it |

## Checkpoint routine

A fresh monitor agent runs each checkpoint as `.claude/agents/llm-efficiency-monitor.md` sets out, briefed with files.
Its scripts read the transcripts, so no transcript text enters its context, and it writes only under `SCR/llm/`. It
reads the ledger, `get_usage`, `df -h ~` and the build folder sizes, checks that the briefs carry this contract's values
(a rule that never reaches a brief is not followed) and checks the thresholds below. It leaves a log entry, numbered
actions with agent ids and evidence at the top of `SCR/llm/actions.md`, and a final message under 200 words.

| Signal | Threshold | Action |
|---|---|---|
| Pending tool call | over 15 minutes | Ask the agent, and stop it with a Handoff when it hangs |
| Lane size | about 150 tool calls or 400K of context, 80 calls for a documentation lane | Check that the lane works inside its named milestone, and give the next milestone to a fresh agent |
| Resume of an idle agent | any, after 5 idle minutes | Replace it with a fresh agent briefed with files |
| Guard rejections or new refusals | over 1% of an agent's turns, or a new kind | Fix the command forms in the brief |
| Poll-only turns | over 10% of spend | Restate the blocking wait in the briefs and to the running agents |
| Cache rebuild | any after a long wait or a long turn | Set the wait timeouts to 180000 for opus and 270000 for sonnet, and have long files written in parts |
| Burn | over about $150 an hour, or above the quota line | Hold launches |
| Building agents and load | over 5, or a load average over 40 | Hold launches |
| Free disk | under about 100 GB | Delete the build folders of finished lanes, then ask the owner for a thinning |
| Manager context | over 85% | Refresh the STATE block and expect compaction |

## Evidence

The direct cost of a lane is its lane agents, its review, its fix agent and its share of the landing agent. The all-in
cost adds the expert panel, the manager and the monitor.

| Session | Date | Spend and wall time | Lanes landed | Direct cost per landed lane | All-in per landed lane |
|---|---|---|---|---|---|
| 2.6, two sessions | 2026-10-10 | $1,438 over 16h05m | 24 | about $53 | about $60 |
| 2.7, one session | 2026-10-11 | $1,136 over 11h49m | 34 | median $23.60, mean $26.72 | $33.41 |
| 2.8, one session, to its last landing | 2026-10-11 | $604 over 6h35m | 24 | median $15.37, mean $19.27 | $25.16 |

| Rule | Measurement | Sessions |
|---|---|---|
| Fresh agents | 16 resumed fix rounds cost $189 at a median context of 680K. 22 fresh fix agents cost $119 (median $4.50), and fresh memo agents $19 against about $29 by resuming the experts. 2.8 resumed no idle agent and sent its 6 messages to busy ones. | 2.6, 2.7, 2.8 |
| Lane budget and Handoff | Lanes ran a median 313 turns, and in one session spent 72% of lane money above 400K. Named milestones stopped lanes at 162 calls, then at 179 to 259, while a lane whose stop line came after its launch ran to 272. Turns past 150 calls cost $178, then $75, against $124 and $56 for fresh continuations, and the three cold continuations of 2.8 made 57 to 103 calls ($1.38 to $4.43) before their first edit. | 2.6, 2.7, 2.8 |
| Batched reads | 1.11 to 1.19 calls a turn with 23% single read-only turns, then 1.34 and 17%, then 1.53 calls a turn. | 2.6, 2.7, 2.8 |
| Guard-safe commands | 2.7% of turns rejected, then 0.65%. New refusals (a chain naming an SCR path, `git -C` or `cd` into another worktree, an absolute log path) raised it to 1.58% until the command forms reached the review, fix and landing briefs, and 0.52% after. | 2.6, 2.7, 2.8 |
| Calls inside the cache life | 44 cache rebuilds cost $88, then 5 cost about $6. Three opus waits of 261 to 271 s issued by turns of 61 to 102 s rebuilt 286K to 366K each (about $4.70), and no opus call at 180000 did. No sonnet wait rebuilt, with issuing turns of 2 to 39 s. Single turns of 363 s and 637 s rebuilt a memo and the tally. | 2.6, 2.7, 2.8 |
| Wait by blocking | Poll-only turns took 27% to 29% of spend in busy periods, with 61 Monitor calls. After the rule they took 5% to 7%, with none. | 2.7, 2.8 |
| Short final messages | Final messages fell from up to 4,600 characters to about 1,000, and the manager's context then grew 1.0K tokens a minute against 2.6K. In 2.8 they averaged 950 characters. | 2.7, 2.8 |
| Fresh worktrees | Warm first builds took a median 45 s against 191 s fresh, and warm fix agents cost a median $3.39 against $6.86 cold. When EnterWorktree was refused, fresh fix agents with `path:line` fixes cost a median $4.28 and first-built in 170 to 272 s. | 2.7, 2.8 |
| Chained lanes | A lane started in its base lane's worktree 39 minutes before that lane landed and first-built in under 2 minutes. From the base lane's head commit, two lanes started 18 and 81 minutes before their base lanes landed, with cold first builds (158 s where measured). | 2.7, 2.8 |
| Documentation lanes | A lane briefed by reference made 211 calls and read 81 files, and its review found 3 wrong facts. With review and fix it cost $31. A notes lane briefed with the sources of each paragraph made 134 calls for $8.39 and peaked at 524K. | 2.7, 2.8 |
| Landing batches | 7 sonnet landing agents landed 28 lanes for $54 ($1.93 a lane), one spent 35 minutes on two full test runs for a pre-existing fault, and one handed a two-lane test fix back to the manager. Six then landed 20 lanes with 26 review fixes folded in for $40 ($2.00 a lane), and fix agents fell from 24 for 34 lanes ($126) to 8 for 24 lanes ($33). | 2.7, 2.8 |
| Concurrency | With 8 to 13 builders the load reached 105 to 122 and cold builds took 375 to 673 s instead of 153 s. With 6 to 8 builders at load 57 to 79 first builds took a median 359 s against 223 s, and with at most 5 the load stayed under 21. | 2.7, 2.8 |
| Quota pacing | The weekly quota ran out after wave 1. At $207 an hour a 5-hour window would have run out an hour early, and at $111 it read 75% 17 minutes before its reset. At $92 an hour a window peaked near 70%. | 2.6, 2.7, 2.8 |
| Disk and snapshots | 20 build folders held 309 GB with 48 GiB free. Later, deleted folders stayed in local snapshots and free space fell to 87 GiB, until a 176 s thinning brought 551 GiB and deleting each finished folder at once left 417 GiB at the end. | 2.7, 2.8 |
| Model choice | An opus turn cost $0.098 on average, a sonnet turn $0.070 and a landing turn $0.056, then $0.096, $0.067 and $0.055. A sonnet tally of five memos cost $3.12. | 2.7, 2.8 |
| Manager context | 26 manager turns between 93% and 97% cost $0.217 each. After the compaction at 966K the manager resumed in one turn, and its turns cost $0.058. In 2.8 the manager reached 74% in 6h35m without a compaction, at $0.125 a turn. | 2.7, 2.8 |
| Rulings | A vote of the five experts cost $9.50 and 9 minutes, a ruling of one field on a fix $1.44 and 7 minutes, and two scope questions ruled inside their reviews cost nothing extra. | 2.8 |
| Agent types | A general-purpose subagent starts at 45.3K tokens, the monitor type with eight tools at 10.2K to 10.7K. A type added to `.claude/agents/` mid-session was not found. | 2.7, 2.8 |
| Session start | A test stand-in from an earlier day had run for two days (52 CPU minutes) before an agent found it. | 2.7 |
| Exact bases | Two lane prompts named a mistyped base, and both lanes stopped at the fast-forward. | 2.7 |

## End-of-session duty

The monitor's last checkpoint of every phase session updates this contract in a commit that lands before the final
candidate, so the unit tier covers the ledger's test.

- Add the session to the session table and replace measurements with newer ones.
- Change or remove a rule that a before-and-after measurement contradicts. Add a rule only when a measurement supports
  it, and keep this file under about 200 lines.
- Update `.claude/agents/llm-efficiency-monitor.md`, and `scripts/llm/session_ledger.py` with
  `scripts/tests/test_session_ledger.py`, when they changed during the session. Commit any agent type the session
  proposed, since it loads only at the next session's start, and copy the helpers to `build/llm/`.
- The next session's checkpoint 0 records the closing figures of the session before it, for its own update.
