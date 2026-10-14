# Running a phase session with LLM agents

This contract sets how a Lungfish Genome Explorer (LGE) phase session spends model time. A phase session is one
manager session that turns a reviewed plan into landed lanes with Claude Code subagents. Its purpose is that every landed
lane costs as little model time as the work allows, without slowing the phase or running out of quota.

The rules come from measured sessions. `scripts/llm/session_ledger.py` reads a session's transcripts on this Mac, prices
every API turn per model and never prints message text. Claude Code writes most subagent messages without their final
usage, so the ledger charges such a message the output estimated from its content. Its totals ran 0.8% under Claude
Code's own cost records on 2.9. Costs here are API-equivalent estimates, with the evidence at the end.

## Every session runs the monitor

The owner asked on 2026-10-11 that the monitor run in every session of this repository, so that each session's lessons
make the next one cheaper. A phase session runs every checkpoint. Any other session that spawns subagents, runs builds
or lasts more than about an hour makes the Session start checks and runs the monitor once, at its end. A short session
ends with `python3 scripts/llm/session_ledger.py --md <file> <session id>` and adds its line to the session table. The
End-of-session duty folds what each session's numbers show into this contract.

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
| `SCR/llm/`, and `build/llm/` of the primary checkout | monitor | Ledgers, `log.md`, `actions.md` and the monitor's `notes.md`, and at the last checkpoint the helper scripts and the landing wrappers for the next session |

## Session start

Before the first launch the manager checks the machine and the quota once, in one message.

| Check | Act when |
|---|---|
| `get_usage` for the 5-hour and weekly windows | The weekly window cannot carry the planned lanes at the rates under Quota pacing. Plan fewer lanes or a second session. |
| `df -h ~` and `tmutil listlocalsnapshots /` | Free space is under about 100 GB, or will be after the first wave at 16 GB a worktree. Delete the build folders of old worktrees, and ask the owner for a standing grant to thin snapshots when free space falls under about 100 GB. |
| Leftover processes, with the command below | A test stand-in, test runner or build from an earlier day still runs. Stop it before the first build. |
| `uptime` and `pwd` | The load average is over 40, or the manager's cwd is not the program worktree. Find the cause before launching. |

```bash
ps aux | rg 'xctest|swift-build|swift-test|lungfish-cli' | rg -v ' rg '
```

## Rules for every agent

Every brief carries these rules through `lane-rules.md`, `review.md`, `fix.md` and `land.md`.

| Rule | What to do |
|---|---|
| Fresh agents, never idle resumes | Start each stage, fix round and continuation with a fresh agent briefed with files. Answer a stopped agent by message within 4 minutes of its last turn or start a fresh one, since a later resume writes its whole context to the cache again. |
| Lane budget and Handoff | Name a stop milestone of at most three work items and a stop line in calls, about 30 calls past the milestone's last expected commit. The agent counts every tool call, each call of a parallel batch as one, and writes the count into its report at each commit. At the first commit past the line or 400K of context it writes the Handoff and stops, and a fresh agent of the same model takes the next milestone from the lane head. A message that adds work restates the line. |
| Batched reads | Put independent reads in one message and several ranges in one command. Do not read a file twice. |
| Guard-safe commands | Run each command alone, since the guard refuses a `;` or `&&` chain that names a path under the checkout folder, and every SCR path is one. Run git from your own directory, never with `-C` or after a `cd` into another worktree. Pass literal paths, never a shell variable or computed value, to `rg`, `sed`, `find`, `unzip` and `python3`. Put loops in a script file, and write files with the Write and Edit tools, never through a heredoc. A refusal because the auto mode classifier gave no verdict is a server error, so run the same command once more before changing it. |
| Calls inside the cache life | Pass timeout 180000 on every build, test and wait call of an opus agent and 270000 for a sonnet agent, because the wait and the model time of the turn that issues it must stay under 5 minutes together. Keep single model turns under 5 minutes, and write a long file in parts, one Write and then Edits of at most about 4,000 characters each. |
| Wait by blocking | Start a long build or test in the background with its exit code in a log, then wait with one foreground call that returns when the log has it, as below. Repeat the call when it times out. Never wait with Monitor or repeated `tail` calls. |
| Report file and short final message | Write the report to the lane's file, and let every background command end or stop it. Then end with a final message under 150 words (reviews under 100) that gives the head, the tests and the file path. |
| Tests that post SIGTERM | A test that posts SIGTERM to its own process ignores SIGTERM first. Then it waits for the handler's cancel before the instance ends, which is the cheap form, or puts the handler out of reach before the post. A test that needs a post held in flight holds it with a seam, not with another thread. |

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
| Chained lanes | Start the longest chains first. Start a continuation from the head of the agent before it as soon as that agent ends, and a lane that builds on a reviewed lane from that lane's head commit, without waiting for a review or a landing. Land its range after the first lane. |
| Documentation lanes | Write the facts into the brief, each with its source (commit, file and line, or the review item's text), and name every file that holds them. The lane writes one section at a time and stops at about 80 calls by its own count, since it builds nothing. Check release notes in slices of about 40 claims, one sonnet agent a slice. |
| Landing batches | Give each batch of 3 or 4 reviewed ranges to one sonnet landing agent, which stops at about 150 calls by its own count. Fold one or two small review fixes of a range, written as `path:line` and text, into its brief, and give three to five to one fix agent before the landing, a sixth to a second one. Keep fix agents also for fixes that need a measurement, a new test design or judgment. The brief allows the smallest fix of a compile error or a test failure where two lanes meet, in its own commit. For a failure in a file no lane of the batch touched, the agent runs that file alone and on the base once, records a pre-existing fault and goes on, without rerunning the whole suite. |
| Fold small follow-ups | Put review follow-ups that do not block a merge into the brief of a later lane on the same files, written out as facts. Keep them off the longest chain, and list the follow-ups of a cut lane under Moved out. |
| Rulings and checks | Route each open question as `docs/contracts/EXPERT-PANEL.md` sets out under Rulings and disputes. Answer a question that a recorded rule settles by message. Give a question of one field, with its ranges named, to an expert already checking a nearby range or to one fresh expert of that field. When two ranges that share files hand back within about 30 minutes, one expert at effort max checks both, each with its own section and verdict. Only a question across fields or a change to a recorded decision goes to a vote of the panel. |
| Concurrency | Run at most 5 building agents on a 20-core Mac, counting lanes, fix agents and landing agents but not reviews. Launch only at a load average under 40, space cold launches about 3 minutes apart, and keep a background wait running so that an agent's end wakes the manager. |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour, about $140 an hour at $7 a point), and hold every spawn at 75%. Project the weekly close from a list of the rows left, each with a low and a high cost, at about $27 a point. When the projection crosses the stop line, ask the owner which rows move to the next phase. At a launch line about 6 points under the stop no new row starts, and the owner hears the projection. |
| Disk and snapshots | Each worktree build folder holds about 16 GB. Check `df -h ~` before every launch and landing. Local snapshots keep deleted folders, so under the owner's standing grant thin them at the first reading under about 100 GB with `tmutil thinlocalsnapshots / 400000000000 4`, which needs no sudo. |
| Model choice | Opus at effort max for inventories, memos and reviews, opus for lanes on the longest chain, sonnet for mechanical and documentation lanes, the memo tally, fact-checks, fix agents and landings. |
| Done means sent | Write a step into the STATE or the event log as done only after its call ran, and record a text to the owner as sent only after a transcript check shows it. |

## The manager's context budget

Every spawn prompt, brief, final message and tool result stays in the manager's context. Set `"autoCompactWindow":
600000` in the settings before the session starts, or have the owner type `/autocompact 600000`, since a saved value
waits for the next session. The manager then compacts near 567K, where a turn costs about twice what it costs after,
and with a current STATE block a compaction repeats no work. These habits keep the context lean.

| Habit | Why |
|---|---|
| Read verdict lines and named sections with `rg -n` and `sed -n`, never a whole report, diff or log. Pass paths to agents, not content. | Whole-file reads fill the manager fastest. |
| Handle each completion in one message, with the event line, the notes update and the next spawn. Keep text between calls to one line. | Every completion costs turns at the manager's context size. |
| Rewrite the STATE block in `notes.md` at every landing and launch, with a continuation guide naming every running agent, the next launches and the end steps. | The STATE block is the only memory that survives compaction. |
| Write the spawn settings (model, effort, isolation and the wait timeouts) into the STATE block. | After the first compaction of 2.10 every expert spawn ran without effort max until the settings went into the STATE. |
| Never load a skill in the manager. Edit a known settings key with Edit, or give the change to a sonnet agent. | Claude Code puts a loaded skill's text back after every compaction. |
| Keep the cwd inside the program worktree for the whole session and run git there, where `git rev-parse worktree-agent-<id>` reads any lane's head. | The guard refuses `git -C` into another worktree, and a landing agent spawned without isolation works in the manager's worktree. |

## Limits of Claude Code to state in every brief

| Limit | Do instead |
|---|---|
| A subagent Write of a file whose name starts with report is refused | Name the file after the lane, `<LANE>.md` |
| Foreground `sleep` is blocked and the refusal suggests Monitor, which returns at once while the agent keeps working | The blocking wait above, and Monitor only to watch while doing other work |
| `python3 -` waits on stdin until the call times out, and a Bash call moves to the background at its timeout, 120 s by default | Write the script to a file, and pass a timeout on every long call |
| Background and Monitor events of a subagent never reach the manager | Report in the final message and the lane file |
| A background command that ends after the final message wakes the agent, which writes its context to the cache again | Let it end, or stop it, before the final message |
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
| Lane size | past the stop line of its prompt (80 calls for a documentation lane), read as 0.7 of the ledger's calls, or 400K of context | Check that the lane stops at its next commit with a Handoff, and give the next milestone to a fresh agent |
| Resume of an idle agent | any, after 5 idle minutes | Replace it with a fresh agent briefed with files |
| Guard rejections or new refusals | over 1% of an agent's turns, or a new kind | Fix the command forms in the brief |
| Poll-only turns | over 10% of spend | Restate the blocking wait in the briefs and to the running agents |
| Cache rebuild | any after a long wait or a long turn | Set the wait timeouts to 180000 for opus and 270000 for sonnet, and have long files written in parts |
| Burn, load and quota | over about $150 an hour, above the 5-hour line, over 5 building agents or a load average of 40, or a weekly projection over the stop line | Hold launches, and tell the owner of the weekly projection |
| Free disk | under about 100 GB | Delete the build folders of finished lanes, then thin the snapshots under the owner's grant |
| Manager context | over 85% of the window | Refresh the STATE block and expect compaction |

## Evidence

The direct cost of a lane is its lane agents, its review, its fix agent and its share of the landing agent. The all-in
cost adds the expert panel, the manager and the monitor.

| Session | Date | Spend and wall time | Lanes landed | Direct cost per landed lane | All-in per landed lane |
|---|---|---|---|---|---|
| 2.6, two sessions | 2026-10-10 | $1,438 over 16h05m | 24 | about $53 | about $60 |
| 2.7, one session | 2026-10-11 | $1,136 over 11h49m | 34 | median $23.60, mean $26.72 | $33.41 |
| 2.8, one session, to its last landing | 2026-10-11 | $604 over 6h35m | 24 | median $15.37, mean $19.27 | $25.16 |
| 2.9, one session, to its last monitor checkpoint, before the last landing, the final candidate and the release | 2026-10-12 | $659 over 8h43m, $68 of it the panel | 20, and 3 more in the last landing | median $13.03, mean $17.54 | $32.94 |
| 2.10, one session, to its last monitor checkpoint, after the last landing and before the final candidate and the release | 2026-10-13 and 14 | $2,334 over 29h40m, about $101 of it the panel | 48 | median $23.86, mean $37.24 | $48.62 |

| Rule | Measurement | Sessions |
|---|---|---|
| Fresh agents | 16 resumed fix rounds cost $189 at a median context of 680K, and 22 fresh fix agents $119 (median $4.50). Answers by message within a minute of a handback wrote 1.1K to 1.3K tokens, one at 295 s read its 223K context from the cache with 5 s to spare, and a resume after 2 hours idle (366K) cost about $3 more than a fresh agent. | 2.6 to 2.10 |
| Lane budget and Handoff | Milestones of two or three items ran 131 to 196 calls with one agent, and four or more ran 263 to 447 calls, some with a second agent. Continuations at a milestone end read 33 to 67 calls first ($0.65 to $0.93) and saved $5.85 to $7.36 each against one longer agent, and a restart inside a milestone cost $0.96 more. Own counts ran 0.48 to 1.0 of the ledger's, and the agent that counted each call of a parallel batch came within 3% (150 for 154). An agent stopped at its own line with a Handoff (120 by its count, 171 by the ledger's), one told by message at its line to keep working ran 112 calls past it, and a fix agent's only commit came at call 74 of a 60-call line. Past-line work cost $1.47 more than fresh continuations at peaks of 283K to 389K. | 2.8 to 2.10 |
| Batched reads | 1.11 to 1.19 calls a turn with 23% single read-only turns, then 1.34 to 1.79 calls a turn, and 1.67 in 2.10. | 2.6 to 2.10 |
| Guard-safe commands | 2.7% of turns rejected, then 0.52% to 0.65% once the command forms reached the briefs, and 0.21% in 2.10. Two fact-check agents of a type without Write sent their tables through heredocs and raised the last 88 minutes of 2.9 to 1.13%. A server-side classifier error refused 123 calls of 2.10, 4.2% of calls in its worst two hours. | 2.6 to 2.10 |
| Calls inside the cache life | 44 cache rebuilds cost $88, then 5 about $6, then 13 about $12 (9 in the panel's long turns). Three opus waits of 261 to 271 s rebuilt 286K to 366K each, no opus wait at 180000 did in three sessions, and 107 sonnet waits at 270000 in the last six hours of 2.10 rebuilt nothing. Single turns of 363 to 838 s rebuilt memos, tallies and a review, and none did in reviews and votes that wrote in parts of about 4,000 characters. | 2.7 to 2.10 |
| Wait by blocking | Poll-only turns took 27% to 29% of spend in busy periods, with 61 Monitor calls. After the rule they took 4% to 8%, with none, and 7% in 2.10. | 2.7 to 2.10 |
| Short final messages | Final messages fell from up to 4,600 characters to about 1,000, and the manager's context then grew 1.0K tokens a minute against 2.6K. A background command that ended 6 minutes after a lane's final message woke the lane, which wrote 448K to the cache again for a short reply ($2.27). In 2.10 each completion reached the manager as 1.7K to 2.7K characters whatever the report's size. | 2.7 to 2.10 |
| Fresh worktrees and concurrency | Warm first builds took a median 45 s against 191 s fresh, and cold first builds in fresh worktrees 164 to 298 s. With 8 to 13 builders the load reached 105 to 122 and cold builds took 375 to 673 s. With at most 5 it stayed under 35 in 2.8 and 2.9, and in 2.10 three cold builds started within 3 minutes drove it to 65.8, two launched 20 s apart took 360 s each, and launches about 3 minutes apart took 174 to 221 s. With a background wait the manager kept 97.9% of the slots busy for two hours. | 2.7 to 2.10 |
| Chained lanes | From the base lane's head commit, two lanes started 18 and 81 minutes before their base lanes landed, and ten continuations started within 13 minutes of the agent before them. Starting the two longest chains first moved a five-step chain about an hour earlier. | 2.8 to 2.10 |
| Documentation lanes | A lane briefed by reference made 211 calls, read 81 files and got 3 facts wrong. Notes lanes briefed with the source of each fact made 134 calls for $8.39 (peak 524K), then, written one section at a time in parts, 150 calls for $5.71 (peak 341K). Two sonnet fact-check slices of about 114 claims cost $16.34 against $32.94 for one opus agent. A collection of release notes made 150 calls ($4.69) on a line of 80, since the early landing reports kept their facts outside the notes file. | 2.7 to 2.10 |
| Landing batches | Fix agents fell from 24 for 34 lanes ($126) to 4 for 20 ($10) as landings folded the fixes, and 29 landings landed the 48 lanes of 2.10 for $203. A stop at about 150 calls by own count held five landings to 180K to 306K of context and $1.69 a range against $3.68 before it, while a landing past 300K paid $4 to $8 more in reads. A fix made by a landing cost $0.55 at 115K to 137K of context and $1.83 at 155K to 292K, one fix agent of five fixes $0.74 a fix, and a one-fix agent $1.16 to $4.28 with a cold build. A fix agent given ten items ran 289 calls to 515K. | 2.7 to 2.10 |
| Quota pacing | The weekly quota ran out after wave 1 of 2.6, and at $207 an hour a 5-hour window would have run out an hour early. A 5-hour point cost $5.9 to $7.4 and a weekly point $25 to $27, in 2.10 $26.92 to $27.26 from readings 4 or more points apart. A formula of 1.4 points a row read 95% to 105% as reviews and rulings grew the rows in progress, while a list of the rows left kept its center within 1.7 points over the last 5.5 hours. The owner moved seven Opus rows to the next phase on such a projection, about 11 to 15 points, and with a launch line 6 points under the stop every row started before it. | 2.6 to 2.10 |
| Disk and snapshots | 20 build folders held 309 GB with 48 GiB free. Deleted folders stayed in local snapshots until a thinning, which took 112 to 176 s and gave 476 to 551 GiB, with no stop of the session. In 2.10, 16 fresh worktrees took 94 GiB an hour, and a df check that lapsed for six launches let free space fall to 70 GiB. | 2.7 to 2.10 |
| Model choice and agent types | An opus lane turn cost $0.104, a sonnet lane turn $0.073 and a landing turn $0.045 to $0.055, and a fix turn $0.055 in 2.10. Two typed spawns without a model ran opus ($35.95). A general-purpose subagent starts at 45.3K tokens, the `lge-worker` and `lge-expert` types at 6.9K to 8.5K, which saved about $45 in 2.9 and $197 in 2.10. A type added mid-session was not found. | 2.7 to 2.10 |
| Reviews | One reviewer that carried other fields' questions cost a median $4.51 against $3.76 for one field, and second reviews fell from $20.85 for six lanes to one check of $3.35. In 2.10, 65 reviews cost a median $4.68. One expert that checked two ranges sharing files with a co-reviewer's lines cost $5.83, and a question asked of an expert already checking a nearby range about $1.1 against $2.40 to $2.93 alone. Two checks run apart on ranges that shared 3 small files would have saved $0.04 of reads as a pair. | 2.8 to 2.10 |
| Manager context | 26 manager turns between 93% and 97% of the 1M window cost $0.217 each, and $0.058 after the compaction. In 2.10 the 600K window compacted the manager seven times, each recovered in 13 to 18 turns with no review, ruling, spawn or message repeated, a net saving of $67.25 against the 1M window's four compactions ($75.90 with two subagents). The update-config skill cost $3.30 to load, and its 44,000 characters came back after every compaction. A step written into the STATE as done 68 s before a compaction was never sent, while owner texts recorded only after a transcript check all went out. | 2.7 to 2.10 |
| Rulings | Votes of the experts cost $9.50 in 9 minutes, then $2.65 and $6.81 in 4 and 8 minutes. A ruling of one field cost $1.33 to $1.44 and one briefed without ranges $5.92. Seven experts spent 73% of their cost reading before the first Write, and a one-field question that a reviewed mask and a precedent settled cost $2.75 as a ruling where an answer by message cost nothing. | 2.8 to 2.10 |
| Session start and exact bases | A test stand-in from an earlier day had run for two days (52 CPU minutes) before an agent found it. Two lane prompts named a mistyped base, and both lanes stopped at the fast-forward. | 2.7 |
| Tests that post SIGTERM | A unit run crashed with SIGBUS when a test posted SIGTERM and ended its instance while another thread still took the post. The fix agent and its review cost $9.96. | 2.10 |

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
