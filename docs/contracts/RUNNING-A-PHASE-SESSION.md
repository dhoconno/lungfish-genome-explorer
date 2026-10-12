# Running a phase session with LLM agents

This contract sets how a Lungfish Genome Explorer (LGE) phase session spends model time. A phase session is one
manager session that turns a reviewed plan into landed lanes with Claude Code subagents. Its purpose is that every landed
lane costs as little model time as the work allows, without slowing the phase or running out of quota.

The rules come from measured sessions. `scripts/llm/session_ledger.py` reads a session's transcripts on this Mac, prices
every API turn per model and never prints message text. Its totals stay within 0.5% of Claude Code's own cost records
for sonnet and about 3% under them for opus. Costs here are API-equivalent estimates, with the evidence at the end.

## Every session runs the monitor

The owner asked on 2026-10-11 that the monitor run in every session of this repository, so that each session's lessons
make the next one cheaper. A phase session runs every checkpoint. Any other session that spawns subagents, runs builds
or lasts more than about an hour makes the Session start checks and runs the monitor once, at its end. A short session
ends with `python3 scripts/llm/session_ledger.py --md <file> <session id>` and adds its line to the session table. The
End-of-session duty folds the rules that helped, the ones that did not and any new rule a session's numbers support
into this contract.

## Roles

| Role | Model | Spawned | Reads | Leaves behind |
|---|---|---|---|---|
| Manager | the main session, opus | by the owner | the plan, the briefs, `notes.md`, verdict lines of reports | the landed program branch, the plan record, memory notes |
| Expert panel, which leads the session under `docs/contracts/EXPERT-PANEL.md` | opus at effort max, sonnet for the tally | five inventory agents, five fresh memo agents, then one agent that drafts the tally | the code, then the inventory files, then the memos | `inv/<FIELD>.md`, `memos/<FIELD>.md`, a tally table with the split questions flagged for the manager |
| Lane | opus on the longest chain or for judgment, sonnet for mechanical and documentation work | `isolation: "worktree"`, then `git merge --ff-only` to the program head or to the head of the lane it builds on | its brief, `lane-rules.md` and the files it changes | commits, `lanes/<LANE>/<LANE>.md`, a final message under 150 words |
| Reviewer | opus at effort max, one fresh agent per lane that also carries the questions of the other fields the lane touches | after the lane's final message | the lane report and the diff | `reviews/<LANE>.md` with a verdict, numbered fixes as `path:line` and text, and rulings on the questions it carries |
| Fix agent | sonnet unless a fix needs judgment | fresh, `isolation: "worktree"`, then `git merge --ff-only` to the lane head | the review file and the lane report | commits, `lanes/<LANE>/<LANE>-fix.md` |
| Landing agent | sonnet | fresh, in the program worktree | `land.md`, the ranges, the review files and the small fixes to fold in | cherry-picks, folded fixes, a build, targeted tests, the module map, ratchets, `land/land-N.md` |
| LLM-efficiency monitor | opus, one fresh agent per checkpoint, defined in `.claude/agents/llm-efficiency-monitor.md` | at the start, after each wave launch, about every two hours, and at the end | `llm/notes.md`, `llm/actions.md`, the last log entry, the session notes and event log | a ledger, a log entry, numbered actions, and at the end the update of this contract |

The manager plans, briefs, spawns and decides. It does not land lanes or edit code beyond a one-line fix, and its own
context is the scarcest resource of the session.

Spawn lanes, continuations, fix agents and landing agents as `lge-worker`, experts and reviewers as `lge-expert`, and
pass the model on every spawn, since neither type names one and a spawn without it runs opus. Both start at 7K to 8K
tokens against about 45K for a general-purpose subagent. Give every agent that writes a file the Write and Edit tools.

## Files the session keeps

Session files live in the scratch folder `SCR`, outside the repository, and agents name them with literal paths.

| File | Writer | Holds |
|---|---|---|
| `SCR/notes.md` | manager | The source of truth. A STATE block of about 40 lines, rewritten at every landing and launch, and a continuation guide |
| `SCR/events.log` | manager | One timestamped line per event, written by a small script in the same message as other calls |
| `SCR/briefs/` | manager | `lane-rules.md`, `review.md`, `fix.md`, `land.md` and one `lane-<LANE>.md` per lane |
| `SCR/lanes/<LANE>/<LANE>.md` | lane | Commits, tests, findings and a Handoff section with the state, remaining steps, the files to read with their line ranges and the next command |
| `SCR/reviews/<LANE>.md` and `SCR/land/land-N.md` | reviewer, landing agent | The verdict with numbered fixes, the landing record |
| `SCR/land/*.py` | landing agents, the monitor | Wrappers that later agents reuse. `run_swift.py` runs one swift command and `run_cmd.py` any command as an argument list, and each ends its log with an `exit=` line |
| `SCR/llm/` | monitor | Ledgers, `log.md`, `actions.md` and the monitor's `notes.md` |
| `build/llm/` of the primary checkout | monitor, at the last checkpoint | The monitor's helper scripts and the landing wrappers, for the next session |

## Session start

Before the first launch the manager checks the machine and the quota once, in one message.

| Check | Act when |
|---|---|
| `get_usage` for the 5-hour and weekly windows | The weekly window cannot carry the planned lanes at the rates under Quota pacing. Plan fewer lanes or a second session. |
| `df -h ~` and `tmutil listlocalsnapshots /` | Free space is under about 100 GB, or will be after the first wave at 16 GB a worktree. Delete the build folders of old worktrees, and ask the owner for a standing grant to thin snapshots when free space falls under about 100 GB. |
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
| Lane budget and Handoff | Name a stop milestone of at most three work items in the spawn prompt. Only a named milestone has stopped a lane, never a call count, so the milestone's size sets the lane's cost. Past about 150 calls or 400K of context the lane finishes its milestone, writes the Handoff and stops, and a fresh agent of the same model takes the next milestone from the lane head. |
| Batched reads | Put independent reads in one message and several ranges in one command. Do not read a file twice. |
| Guard-safe commands | Run each command alone, since the guard refuses a `;` or `&&` chain that names a path under the checkout folder, and every SCR path is one. Run git from your own directory, never with `-C` or after a `cd` into another worktree. Pass literal paths, never a shell variable or computed value, to `rg`, `sed`, `find`, `unzip` and `python3`. Put loops in a script file, and write files with the Write and Edit tools, never through a heredoc. |
| Calls inside the cache life | Pass timeout 180000 on every build, test and wait call of an opus agent and 270000 for a sonnet agent, because the wait and the model time of the turn that issues it must stay under 5 minutes together. Keep single model turns under 5 minutes, and write a long file in parts, one Write and then Edits of at most about 4,000 characters each. |
| Wait by blocking | Start a long build or test in the background with its exit code in a log, then wait with one foreground call that returns when the log has it, as below. Repeat the call when it times out. Never wait with Monitor or repeated `tail` calls. |
| Report file and short final message | Write the report to the lane's file, and let every background command end or stop it. Then end with a final message under 150 words (reviews under 100) that gives the head, the tests and the file path. |

The background call runs with `run_in_background` and the wait with the timeout above. When the guard refuses the
subshell (a log path under SCR, `bash` or git in it), run `python3 SCR/land/run_cmd.py <log> <command> <args>` instead.

```bash
(swift build --skip-update --build-tests; echo "exit=$?") > build/lane/build.log 2>&1
until rg -q '^exit=' build/lane/build.log; do sleep 5; done; tail -n 20 build/lane/build.log
```

## Rules for the manager

| Rule | What to do |
|---|---|
| Exact bases | Paste every base commit into a spawn prompt in full, copied from `git rev-parse` output. Never type a commit hash. |
| Fresh worktrees | Spawn every lane, continuation and fix agent with `isolation: "worktree"` and its base in full, and have it run `git merge --ff-only` to that base first. A subagent cannot enter another agent's worktree, so no worktree is reused. Delete a lane's build folder as soon as its last agent ends. |
| Chained lanes | Start a continuation from the head of the agent before it as soon as that agent ends, and a lane that builds on a reviewed lane from that lane's head commit, without waiting for a review or a landing. Land its range after the first lane. |
| Documentation lanes | Write the facts into the brief, each with its source (commit, file and line, or the review item's text), and name the files to edit. The lane writes one section at a time and budgets about 80 tool calls, since it builds nothing. Check release notes in slices of about 40 claims, one sonnet agent a slice. |
| Landing batches | Give each batch of 3 to 5 reviewed lanes to one sonnet landing agent, and fold the reviews' small fixes, written as `path:line` and text, into its brief instead of spawning fix agents. Keep fix agents for fixes that need a measurement, a new test design or judgment. The brief allows the smallest fix of a compile error or a test failure where two lanes meet, in its own commit. For a failure in a file no lane of the batch touched, the agent runs that file alone and on the base once, records a pre-existing fault and goes on, without rerunning the whole suite. Extend a landing agent by message only while its context stays under about 300K. |
| Fold small follow-ups | Put review follow-ups that do not block a merge into the brief of a later lane on the same files, written out as facts. Keep them off the longest chain, and list the follow-ups of a cut lane under Moved out. |
| Rulings | Route each open question as `docs/contracts/EXPERT-PANEL.md` sets out under Rulings and disputes. A question of one field goes to the lane's reviewer or one fresh expert of that field. Only a question across fields or a change to a recorded decision goes to a vote of the panel. |
| Concurrency | Run at most 5 building agents on a 20-core Mac, counting lanes, fix agents and landing agents but not reviews. Launch only at a load average under 40. |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour, about $140 an hour at $7 a point), and hold every spawn at 75%. A 5-hour point has cost $6 to $8 and a weekly point $25 to $33. |
| Disk and snapshots | Each worktree build folder holds about 16 GB. Check `df -h ~` at every landing. Local snapshots keep deleted folders, so under the owner's standing grant thin them at the first reading under about 100 GB with `tmutil thinlocalsnapshots / 400000000000 4`, which needs no sudo. |
| Model choice | Opus at effort max for inventories, memos and reviews, opus for lanes on the longest chain, sonnet for mechanical and documentation lanes, the memo tally, fact-checks, fix agents and landings. |

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
| Foreground `sleep` is blocked and the refusal suggests Monitor, which returns at once while the agent keeps working | The blocking wait above, and Monitor only to watch while doing other work |
| `python3 -` waits on stdin until the call times out, and a Bash call moves to the background at its timeout, 120 s by default | Write the script to a file, and pass a timeout on every long call |
| Background and Monitor events of a subagent never reach the manager | Report in the final message and the lane file |
| A background command that ends after the final message wakes the agent, which writes its context to the cache again | Let it end, or stop it, before the final message |
| A type without the Write tool writes through heredocs, and the guard refuses a heredoc into SCR | Give a writing agent a type with Write and Edit |
| EnterWorktree from a subagent into another agent's worktree is refused | `isolation: "worktree"` and `git merge --ff-only` to the head to build on |
| Agent types in `.claude/agents/` load only when the session starts | Commit a new type before the session that uses it |

## Checkpoint routine

A fresh monitor agent runs each checkpoint as `.claude/agents/llm-efficiency-monitor.md` sets out, briefed with files.
Its scripts read the transcripts, so no transcript text enters its context, and it writes only under `SCR/llm/`. It
checks the ledger, `get_usage`, disk, the briefs (a rule that never reaches a brief is not followed) and the thresholds
below, and leaves a log entry, numbered actions with agent ids and evidence, and a final message under 200 words.

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
| Free disk | under about 100 GB | Delete the build folders of finished lanes, then thin the snapshots under the owner's grant |
| Manager context | over 85% | Refresh the STATE block and expect compaction |

## Evidence

The direct cost of a lane is its lane agents, its review, its fix agent and its share of the landing agent. The all-in
cost adds the expert panel, the manager and the monitor.

| Session | Date | Spend and wall time | Lanes landed | Direct cost per landed lane | All-in per landed lane |
|---|---|---|---|---|---|
| 2.6, two sessions | 2026-10-10 | $1,438 over 16h05m | 24 | about $53 | about $60 |
| 2.7, one session | 2026-10-11 | $1,136 over 11h49m | 34 | median $23.60, mean $26.72 | $33.41 |
| 2.8, one session, to its last landing | 2026-10-11 | $604 over 6h35m | 24 | median $15.37, mean $19.27 | $25.16 |
| 2.9, one session, to its last monitor checkpoint, before the last landing, the final candidate and the release | 2026-10-12 | $659 over 8h43m, $68 of it the panel | 20, and 3 more in the last landing | median $13.03, mean $17.54 | $32.94 |

| Rule | Measurement | Sessions |
|---|---|---|
| Fresh agents | 16 resumed fix rounds cost $189 at a median context of 680K, and 22 fresh fix agents $119 (median $4.50). Fresh memo agents cost $19 against about $29 by resuming the experts. 2.8 and 2.9 resumed no idle agent and sent their 6 and 5 messages to busy ones. | 2.6 to 2.9 |
| Lane budget and Handoff | Stop milestones of two or three work items ran 131 to 196 calls with one agent, and four or more ran 263 to 447 calls, two of them with a second agent. Lanes with two or more agents cost a median $25.97 against $10.59. Lane agents ran a median 168 calls against a plan of about 100. Turns past 150 calls cost $74 against $66 for fresh agents, and cold continuations made 49 to 116 calls ($0.90 to $4.03) before their first edit, also when told to read only the Handoff's files. | 2.8, 2.9 |
| Batched reads | 1.11 to 1.19 calls a turn with 23% single read-only turns, then 1.34, 1.53 and 1.79 calls a turn. | 2.6 to 2.9 |
| Guard-safe commands | 2.7% of turns rejected, then 0.65%. New refusals raised it to 1.58% until the command forms reached the briefs, and 0.52% after, the 2.9 rate as well. Two fact-check agents of a type without Write sent their tables through heredocs and raised the last 88 minutes of 2.9 to 1.13% (10 of 15 refusals). | 2.6 to 2.9 |
| Calls inside the cache life | 44 cache rebuilds cost $88, then 5 about $6, then 13 about $12 (9 in the panel's long turns). Three opus waits of 261 to 271 s rebuilt 286K to 366K each, and no opus wait at 180000 did in two sessions. Single turns of 363 to 838 s rebuilt memos, tallies and a review, three ended at max_tokens with nothing kept, and none did in the 17 reviews and 5 votes that wrote in parts of about 4,000 characters. | 2.7, 2.8, 2.9 |
| Wait by blocking | Poll-only turns took 27% to 29% of spend in busy periods, with 61 Monitor calls. After the rule they took 4% to 8%, with none. | 2.7, 2.8, 2.9 |
| Short final messages | Final messages fell from up to 4,600 characters to about 1,000, and the manager's context then grew 1.0K tokens a minute against 2.6K. In 2.9 they averaged 840 characters and the manager grew 1.13K a minute. A background command that ended 6 minutes after a lane's final message woke the lane, which wrote 448K to the cache again for a short reply ($2.27). | 2.7, 2.9 |
| Fresh worktrees | Warm first builds took a median 45 s against 191 s fresh. Fresh fix agents with `path:line` fixes cost a median $4.28, then $2.67, and cold first builds in fresh worktrees took 164 to 298 s (median 196 s). | 2.7, 2.8, 2.9 |
| Chained lanes | From the base lane's head commit, two lanes started 18 and 81 minutes before their base lanes landed. Ten continuations started within 13 minutes of the agent before them, half in the same minute, while a review took a median 18 minutes and a landing 32, and each first-built cold in 164 to 254 s. | 2.8, 2.9 |
| Documentation lanes | A lane briefed by reference made 211 calls, read 81 files and got 3 facts wrong. Notes lanes briefed with the source of each fact made 134 calls for $8.39 (peak 524K), then, written one section at a time in parts, 150 calls for $5.71 (peak 341K). Two sonnet fact-check slices of about 114 claims cost $16.34 against $32.94 for one opus agent, and made 174 and 250 calls against a budget of 60. | 2.7, 2.8, 2.9 |
| Landing batches | 7 sonnet landing agents landed 28 lanes for $54 ($1.93 a lane), and one spent 35 minutes on two full test runs for a pre-existing fault. Then six landed 20 lanes for $40 ($2.00 a lane) and seven landed 20 for $28 ($1.40 a lane), as fix agents fell from 24 for 34 lanes ($126) to 8 for 24 ($33) and 4 for 20 ($10). | 2.7, 2.8, 2.9 |
| Concurrency | With 8 to 13 builders the load reached 105 to 122 and cold builds took 375 to 673 s instead of 153 s. With at most 5 the load stayed under 21, then under 35. | 2.7, 2.8, 2.9 |
| Quota pacing | The weekly quota ran out after wave 1. At $207 an hour a 5-hour window would have run out an hour early. At $92 an hour a window peaked near 70%, and at $75 an hour with five builders (10-minute peaks $132) near 62%. A 5-hour point cost $5.9 in the panel stage and $7.0 to $7.4 with lanes, a weekly point $26. | 2.6, 2.8, 2.9 |
| Disk and snapshots | 20 build folders held 309 GB with 48 GiB free. Deleted folders stayed in local snapshots until a thinning, which took 176 s at 87 GiB and gave 551 GiB, then 112 s at 98 GiB under a standing grant and gave 476 GiB, with no stop of the session. | 2.7, 2.8, 2.9 |
| Model choice | An opus lane turn cost $0.104, a sonnet lane turn $0.073 and a landing turn $0.045 (2.8 $0.096, $0.067 and $0.055). Sonnet tallies of five memos cost $3.12 and $5.99. Two typed spawns without a model ran opus ($35.95), and with the model passed every spawn ran as asked. | 2.8, 2.9 |
| Reviews | One reviewer that carried other fields' questions cost a median $4.51 (10 reviews) against $3.76 for one field (19), and second reviews fell from $20.85 for six lanes to one check of $3.35. Review money per code lane fell from $6.04 to $5.58. | 2.8, 2.9 |
| Manager context | 26 manager turns between 93% and 97% cost $0.217 each, and after the compaction at 966K the manager resumed in one turn at $0.058 a turn. Without a compaction the manager reached 74% in 6h35m at $0.125 a turn, then 86% in 8h43m at $0.137. | 2.7, 2.8, 2.9 |
| Rulings | Votes of the experts cost $9.50 in 9 minutes, then $2.65 and $6.81 in 4 and 8 minutes. A ruling of one field cost $1.44 and $1.33 in 7 minutes, and scope questions ruled inside reviews cost nothing extra. | 2.8, 2.9 |
| Agent types | A general-purpose subagent starts at 45.3K tokens, the `lge-worker` and `lge-expert` types at 6.9K to 8.0K, which saved about $45 in 2.9. A type added to `.claude/agents/` mid-session was not found. | 2.7, 2.8, 2.9 |
| Session start and exact bases | A test stand-in from an earlier day had run for two days (52 CPU minutes) before an agent found it. Two lane prompts named a mistyped base, and both lanes stopped at the fast-forward. | 2.7 |

## End-of-session duty

The monitor's last checkpoint of every phase session updates this contract in a commit that lands before the final
candidate, so the unit tier covers the ledger's test.

- Add the session to the session table and replace measurements with newer ones.
- Change or remove a rule that a before-and-after measurement contradicts. Add a rule only when a measurement supports
  it, and keep this file under about 200 lines.
- Update `.claude/agents/llm-efficiency-monitor.md`, and `scripts/llm/session_ledger.py` with
  `scripts/tests/test_session_ledger.py`, when they changed. Commit any agent type the session proposed, since it loads
  only at the next session's start, and copy the helpers to `build/llm/`.
- The next session's checkpoint 0 records the closing figures of the session before it, for its own update.
