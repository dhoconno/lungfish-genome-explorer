# Running a phase session with LLM agents

This contract sets how a Lungfish Genome Explorer (LGE) phase session spends model time. A phase session is one
manager session that turns a reviewed plan into landed lanes with Claude Code subagents. Its purpose is that every landed
lane costs as little model time as the work allows, without slowing the phase or running out of quota.

The rules come from measured sessions. `scripts/llm/session_ledger.py` reads a session's transcripts on this Mac, prices
every API turn per model and never prints message text. Its totals ran 0.13% under Claude Code's own cost records on
2.12 with the price table of 2026-10-18. Costs here are API-equivalent estimates, with the evidence at the end.

`docs/contracts/SCOPE-AND-DELIVERY.md` sets which work a session takes on, its budget and when it stops. This contract
sets how the session spends model time on that work.

## The monitor runs once, at the end

A phase session runs the monitor agent once, after its last landing and before the final candidate, and again at the
close when landings follow that run, since in 3.1 61% of session 2's spend came after it. Any other session
with subagents, builds or over an hour ends with `python3 scripts/llm/session_ledger.py --md <file> <session id>` and a
line in the session table.

## Roles

| Role | Model | Spawned | Reads | Leaves behind |
|---|---|---|---|---|
| Manager | the main session, opus at effort xhigh, which the owner sets in the app before the session starts | by the owner | the plan, the briefs, `notes.md`, verdict lines of reports | the landed program branch, the plan record, memory notes |
| Expert panel, which sets scope and reviews the exit under `docs/contracts/EXPERT-PANEL.md` | as `docs/contracts/EXPERT-PANEL.md` sets under Spawning an expert | once a phase, five inventory agents, five fresh memo agents, then one agent that drafts the tally | the code, then the inventory files, then the memos | `inv/<FIELD>.md`, `memos/<FIELD>.md`, a tally table with the split questions flagged for the manager |
| Lane | opus at effort xhigh on the longest chain or for judgment, sonnet at effort max for mechanical and documentation work | `isolation: "worktree"`, then the guarded reset under Fresh worktrees to the program head or to the head of the lane it builds on | its brief, `lane-rules.md` and the files it changes | commits, `lanes/<LANE>/<LANE>.md`, a final message under 150 words |
| Reviewer | sonnet at effort max, one fresh agent per lane from the field it changes most, plus BIO when it touches scientific output, and none for a lane of only documentation or only tests. Each review the lane's brief names starts when the lane ends, and only a ruling in the event log drops one, since in 3.1 a BIO review that started 45 minutes late found a batch BLAST reading another sample's alignments | after the lane's final message | the lane report and the diff | `reviews/<LANE>.md` with a verdict, its blockers and at most three should-fix items as `path:line` and text, and rulings on the questions it carries |
| Fix agent | sonnet, at effort high for fixes that paste given words into documentation and at effort max for code fixes, and opus at effort xhigh when a fix needs judgment (O103) | fresh, `isolation: "worktree"`, then the guarded reset to the lane head | the review file and the lane report | commits, `lanes/<LANE>/<LANE>-fix.md` |
| Landing agent | sonnet at effort max | fresh, in the program worktree | `land.md`, the ranges, the review files and the small fixes to fold in | cherry-picks, folded fixes, a build, targeted tests, the module map only when a target, a public type or a folder moved, ratchets (a count that fell writes its own lower baseline when a ratchet runs directly, never in a gate or a hook), `land/land-N.md` |
| LLM-efficiency monitor | opus at effort xhigh, one fresh agent, defined in `.claude/agents/llm-efficiency-monitor.md` | once, after the last landing and before the final candidate, and again at the close when landings follow | `llm/notes.md`, `llm/actions.md`, the last log entry, the session notes and event log | a ledger, a log entry, numbered actions, a dated best-practice diff in `/Users/dho/lungfish-phase-records/best-practices/` when the last check is over 7 days old, and numbered proposals for changes to this contract |

The manager plans, briefs, spawns and decides. It does not land lanes or edit code beyond a one-line fix, and its own
context is the scarcest resource of the session. Spawn lanes, continuations, fix agents and landing agents as
`lge-worker`, experts and reviewers as `lge-expert`, and pass the model on every spawn, since neither type names one and
a spawn without it runs opus. Both start at 7K to 8K tokens against about 45K for a general-purpose subagent. Give every
agent that writes a file the Write and Edit tools.

## Files the session keeps

Session files live in the scratch folder `SCR`, outside the repository, and agents name them with literal paths.

| File | Writer | Holds |
|---|---|---|
| `SCR/notes.md` | manager | The source of truth. A STATE block of about 40 lines, rewritten at every landing and launch, and a continuation guide. Every time in it comes from `date '+%H:%M'` or a tool's stamp, never a typed time |
| `SCR/events.log` | manager | One timestamped line per event, written by a small script in the same message as other calls. The stamp is the event's time, and neither the line's text nor a record copies a typed time |
| `SCR/briefs/` | manager | `lane-rules.md`, `review.md`, `fix.md`, `land.md` and one `lane-<LANE>.md` per lane. Each lane file names the files and interfaces involved and the check that proves the lane, as the test names or the build, ratchet or golden command and the result that counts as a pass. When that check is a GUI or device gate, the file gives the result of one run of it at the base on the session's Mac, since no lane passes a gate that the Mac cannot run. A lane that reports a GUI or launch route as working puts the app it launched by that route on this Mac into its report, with the pid and the first window or a Test Case line, since in 3.1 one route claim that no run backed led to three GUI runs that failed at launch |
| `SCR/lanes/<LANE>/<LANE>.md` | lane | Commits, tests, findings and a Handoff section with the state, remaining steps, the files to read with their line ranges and the next command |
| `SCR/reviews/<LANE>.md` and `SCR/land/land-N.md` | reviewer, landing agent | The verdict with numbered fixes, the landing record |
| `SCR/land/*.py` | landing agents, the monitor | Wrappers that later agents reuse. `run_swift.py` runs one swift command and `run_cmd.py` any command as an argument list, and each ends its log with an `exit=` line |
| `SCR/llm/`, and `build/llm/` of the primary checkout | monitor | Ledgers, `log.md`, `actions.md` and the monitor's `notes.md`, and at the end the helper scripts and the landing wrappers for the next session |

## Session start

Before the first launch the manager checks the machine and the quota once, in one message.

| Check | Act when |
|---|---|
| `get_usage` for the 5-hour and weekly windows, loaded with ToolSearch in the same message as every other deferred tool the session needs, such as computer use, since a later load rewrites the cache after the tool prefix | The weekly window cannot carry the planned lanes at the rates under Quota pacing. Plan fewer lanes or a second session. |
| `df -h ~ /Volumes/lge_scratch`, `tmutil listlocalsnapshots /` and `sysctl vm.swapusage` | Swap is over about 90% used. Start the memory watch below before the first launch. The internal disk has under about 100 GB free, or will after the first wave at 18 GB a worktree. Delete the build folders of old worktrees, and ask the owner for a standing grant to thin snapshots. The `df` line of the scratch disk is missing, or shows it mounted somewhere other than `/Volumes/lge_scratch`. Tell the owner, and move no archive until it is back. |
| Leftover processes, with the command below | A test stand-in, test runner or build from an earlier day still runs. Stop it before the first build. |
| `uptime`, `pwd`, `git fetch` and `git rev-list --left-right --count main...origin/main` | The load average is over 40, the manager's cwd is not the program worktree, or local main is behind or ahead of origin/main. Find the cause before launching, base the program branch on origin/main, and tell the owner of commits only local main holds. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -checkFirstLaunchStatus` | It exits other than 0, as it does after an Xcode update. Ask the owner to open Xcode and finish its setup while present, since the release's `doctor` stops on it. |
| `find /Users/dho/.claude/projects -maxdepth 3 -name '<session id>*'` | It finds the session's transcript under a project folder other than the one the briefs and helpers name, as when the session starts in a worktree. Write the found folder into the STATE block, the helpers and every brief, and never type it. |

```bash
ps aux | rg 'xctest|swift-build|swift-test|lungfish-cli' | rg -v ' rg '
```

## Rules for every agent

Every brief carries these rules through `lane-rules.md`, `review.md`, `fix.md` and `land.md`.

| Rule | What to do |
|---|---|
| Fresh agents, never idle resumes | Start each stage, fix round and continuation with a fresh agent briefed with files. Answer a stopped agent by message within 4 minutes of its last turn or start a fresh one, since a later resume writes its whole context to the cache again. An operator that waits on the owner or a ruling with less than about 250K of context may be resumed by message, since its cache write costs what a fresh agent's first reads do. The same holds for a review that rereads the fix of its own finding. Prefer the message within the 4 minutes when the agent's worktree holds a build that a fresh worktree would repeat, such as an Xcode build of about 25 minutes. When free disk is under the alarm's line, a finished agent under about 240K of context whose last range has landed may take a new lane of its own model and effort by message in its own worktree. It first makes the guarded reset to the new base, its id comes off `SCR/llm/done_ids.txt` in the same message, and its stop line is (290K less its context) / 2.5K calls, or (390K less its context) / 2.5K calls for an opus lane. |
| Lane budget and Handoff | Name a stop milestone of at most three work items and a stop line in calls, about 30 calls past the milestone's last expected commit, and for a fix agent about 1.5 times its estimated calls. The agent counts every tool call singly, so a parallel batch of five calls counts five, and writes the count into its report at each commit. A review, ruling or check counts the same way and writes the exact count, never an estimate, into its file at each Write, and a review or fact-check writes its verdict file by call 50 and stops at 70. About 20 calls before the line by its own count an agent starts no new step, commits what passes, writes the Handoff and stops, and it never commits past the line. An agent cannot read its own context, so the manager's context alarm sends it the same stop by message, at 400K for an opus lane and at 300K for a sonnet agent, a review, a ruling or a fact-check. A fresh agent of the same model takes the next milestone from the lane head. A sonnet lane or fix stops at about 85 calls with its Handoff at 75, and a message that resumes one adds at most (290K less its context) / 2.5K calls, what a resumed agent grows a call. A message that adds work says about how many calls it adds and the raised line, and work that would pass the line goes to a continuation. A lane that clears the failing lines of a comparison test gets at most 6 named rows of one side, each with a test that fails first, finishes a row when it leaves the test's output, and writes the count of lines still failing at its Handoff. |
| Batched reads | Put independent reads in one message and several ranges in one command. Do not read a file twice. |
| Guard-safe commands | Run each command alone, since the guard refuses a `;` or `&&` chain that names a path under the checkout folder, and every SCR path is one. Run git from your own directory, never with `-C` or after a `cd` into another worktree. Pass literal paths, never a shell variable or computed value, to `rg`, `sed`, `find`, `unzip` and `python3`. Put loops in a script file, and write files with the Write and Edit tools, never through a heredoc. In the background form give each test class its own `--filter`, since the guard refuses one filter that joins test names as alternatives inside the subshell, run a script file through `run_cmd.py` below rather than `bash`, and commit with `git commit -F <file>`. A refusal because the auto mode classifier gave no verdict is a server error, so run the same command once more before changing it. The manager follows this rule as well, with one literal path a call for `rm`, `kill` and `git`. |
| Calls inside the cache life | Pass timeout 180000 on every build, test and wait call of an opus agent and 270000 for a sonnet agent, because the wait and the model time of the turn that issues it must stay under 5 minutes together. Keep every turn of an agent, the panel's seats at effort max included, under 4 minutes, and write a file in parts, one Write and then Edits of at most 4,000 characters each, since three opus max seats and reviews rebuilt 126K to 168K of cache after single turns past the cache life. A run of an hour gets the same timeout and more waits, never a longer one. |
| Wait by blocking | Start a long build or test in the background with its exit code in a log, then wait with one foreground call that returns when the log has it, as below. Repeat the call when it times out. Never wait with Monitor or repeated `tail` calls. |
| Own processes only | Stop only a process you started, by its PID. `lsof -a -c swift-build -d cwd` lists every build with its folder, and yours runs in your worktree. Never stop processes by name or pattern with `pkill` or `killall`, since up to five building agents share the Mac and `pkill -f swift-build` stops all their builds. From the session start after it lands, the PreToolUse hook `.claude/hooks/deny_process_by_name.py` refuses a Bash call that runs either program, and `kill` fed by `pgrep`. This rule still binds, since the hook lets a call through when it fails and does not see a script that runs one |
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
| Fresh worktrees | Spawn every lane, continuation and fix agent with `isolation: "worktree"` and its base in full. A new worktree starts at origin/main, which can move during the session, so the agent first makes the guarded reset. It checks that `git branch --show-current` names a `worktree-agent-` branch and `git status --short` is empty, then runs `git reset --hard` to the base. Delete a lane's build folder as soon as its last agent ends. |
| Chained lanes | Start the longest chains first. Start a continuation from the head of the agent before it as soon as that agent ends, and a lane that builds on a reviewed lane from that lane's head commit, without waiting for a review or a landing. Land its range after the first lane. |
| Documentation lanes | Write the facts into the brief, each with its source (commit, file and line, or the review item's text), and name every file that holds them. The lane writes one section at a time, reads a file over 20 KB by line range, never joins its sources into one file to read, and builds nothing, so its brief says "Write your Handoff at 45 calls and stop at 60 by your own count, every call counted singly." A documentation agent, a records agent included, runs as `lge-worker` on sonnet at effort max, since two records agents of 3.2 session 2 ran on opus at xhigh against the Model choice row. The context alarm often binds first. An agent that records decisions gets each row with its source and opens no source. Check release notes with one sonnet agent a slice of about 40 claims that cite a record line, or about 30 code-behavior claims, which writes its file by call 50 and stops at 70. Give each claim as its id, the sentence, the token it states and the deciding `path:line` or test, and have the agent read five claims a message. Check an internal record with a script against its cited lines and one sampled slice a part. Open claims go to the fix part, never to a new slice. |
| Landing batches | Give each batch of 3 or 4 reviewed ranges to one sonnet landing agent, which stops at about 150 calls by its own count. Split a batch of more than four folds into Part A and Part B in the brief. Fold one or two small review fixes of a range, written as `path:line` and text, into its brief, and give three to five to one fix agent before the landing, a sixth to a second one. Keep fix agents also for fixes that need a measurement, a new test design or judgment. The brief allows the smallest fix of a compile error or a test failure where two lanes meet, in its own commit. For a failure in a file no lane of the batch touched, the agent runs that file alone and on the base once, records a pre-existing fault and goes on, without rerunning the whole suite. Run the full unit tier after about every 10 landings and once before the candidate, and have a landing that changes export text run the Conformance pins of that export, found with `rg -l` on the changed literal under Tests. |
| Fold small follow-ups | Put a should-fix item that does not block a merge into the brief of a later lane on the same files, written out as facts, and keep it off the longest chain. Every other finding, and the follow-ups of a cut lane, go to `docs/plans/BACKLOG.md`. |
| Rulings and checks | Route each open question as `docs/contracts/EXPERT-PANEL.md` sets out under Rulings and disputes. Answer a question that a recorded rule settles by message. Give a question of one field, with its ranges named, to an expert already checking a nearby range or to one fresh expert of that field. When two ranges that share files hand back within about 30 minutes, one expert at effort max checks both, each with its own section and verdict. Rule a row that reads S1 if reachable before the next chain starts. A ruling's prompt names its stop line, since one of three without one ran 124 calls for $5.21. A ruling measures what it expects of real data before it lets a row wait, since one that did not expect a false badge let an S1 wait one candidate. A finding takes a severity, never a vote. Only a disagreement of two fields on scope or on an S1 or S2 finding, or a change to a recorded decision, goes to a vote of the panel. |
| Concurrency | Run at most 5 building agents, counting lanes, fix agents and landing agents but not reviews. On the 20-core Mac launch only at a load average under 40. On the 14-core laptop three cold builds take the load past 200, so launch there by the count alone. Space cold launches about 3 minutes apart, the first wave of a session included, since two cold builds 98 s apart took the load to 63.7, and keep a background wait running so that an agent's end wakes the manager. Put a run that needs the Mac free of other test runs back to back with a landing's or the candidate's unit tier. |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour, $76 to $110 an hour at $3.8 to $5.5 a point), and hold every spawn at 75%. When `get_usage` lists no 5-hour window, as on 2026-11-03, the burn line below holds alone. Project the weekly close from a list of the rows left, each with a low and a high cost, at the dollars a point of this week's own readings, taken from two readings about 10 points apart, since a point cost $14 to $22 from one week to the next on the same price table. When the projection crosses the stop line, ask the owner which rows move to the next phase. At a launch line about 6 points under the stop no new row starts, and the owner hears the projection. The same holds at one and a half times the phase's dollar budget. |
| Disk and snapshots | Each worktree build folder holds 17 to 18 GB. Check `df -h ~` before every launch and landing, and have the background alarm read it as well. Local snapshots keep deleted folders, so under the owner's standing grant thin them in the same step as each deletion of build folders and at the first reading under about 100 GB, with `tmutil thinlocalsnapshots / 400000000000 4`, which needs no sudo. Closed walk corpora and the phase-end worktree bundle go to `/Volumes/lge_scratch/lge/archive/`, never the current walk's folders or `SCR`. |
| Model choice | The two effort and model tests of 2026-10-15 set these. Opus at effort xhigh for inventories, memos, rulings, the monitor, opus lanes (the longest chain, judgment and design-sensitive work) and, by the owner's O103, fix agents that need judgment. Sonnet at effort max for reviews, fact-checks, code fix agents, mechanical and documentation lanes, landings and the memo tally, and at effort high for fix agents that paste given words into documentation. The next panel meeting runs round 1 at xhigh and round 2 at max, and the monitor compares their cost, cache rebuilds and the facts round 2 corrected. The manager runs on opus at effort xhigh. No expert runs below effort xhigh, and no role runs on haiku. |
| Model and effort on every delegation | Every Agent call sets the agent type, `model` and `effort` explicitly, so no spawn inherits the session's settings. Every brief opens with the line `You run as <agent type> on <model> at effort <level>.`, and every brief or recommendation that delegates work names the agent type, model and effort of each agent it calls for. The STATE block and the spawn map record all three for each spawn. A spawn that sets no effort inherits the session's, and its transcript then reads the session's setting, which is why every 2.10 transcript read max. A spawn that sets one records it in its meta file and in its transcript alike (68 of 68 runs in the two tests of 2026-10-15), and the meta file stays the source. A test run gets its task's frozen brief without the opening line, so its arm stays blind, while its spawn sets the model and effort. The Model choice row holds the settings of `471167711:docs/plans/2026-10-15-phase-2-11-effort-ab.md` and `471167711:docs/plans/2026-10-16-effort-ab-round-2.md`. |
| Done means sent | Write a step into the STATE or the event log as done only after its call ran, and record a text to the owner as sent only after a transcript check shows it. |
| Confirmed end | Start a review, a landing or a check of an agent's work only after the agent has ended. It has ended when its transcript's last entry is its final message, with no tool call and at least 30 s old, and no build or test of its own still runs in its worktree (`lsof -a -c <name> -d cwd` lists them by folder). A background command that ends after the final message wakes the agent, which goes on working. |
| Unattended hours | A call held at the permission step holds the manager's turn, so no notification wakes it and no heartbeat sees it, and keep-awake does not help. So the owner starts a phase session in bypass permissions, as 3.1 session 2 ran. `.claude/settings.json` holds an allowlist for a session in the default mode and deny rules for `git -C`, `pkill`, `killall`, force pushes and merge commits. It cannot match shell loops, so in the default mode run only command forms that already ran this session. |
| GUI walk by computer use | A walk by computer use counts as the packaged walk of `docs/contracts/VERIFICATION-ORDER.md` with or without the owner at the Mac, on an unlocked screen (O126). The owner approves full-screen control once at the walk's start and the manager holds it through the walk, since an unanswered approval reads as denied and cost 49 minutes in 3.1. Before the chain of a new candidate, run the rows that the last lanes added on a Debug build and make one real send under the standing go of `docs/contracts/SCOPE-AND-DELIVERY.md`, since in 3.1 a walk of the new rows ended a candidate in 11 minutes after a chain, package and smoke of 3h24m, and the S1 that ended each of candidates 5 and 6 came from a real send. Keep the screen on with `caffeinate -d -i -t 43200`, since under `caffeinate -u` the idle limit locked it overnight. Start the walk with the context under about 150K and have the owner type `/compact` at each block boundary past about 300K, since screenshots grow it 5K to 16K a minute, and in 3.1 a walk started at 556K rewrote 511K for $4.12 and compacted 79 s later. Press Cancel only on the only running row, or after reading its name in the same frame. Never search the home folder. State the storage root of every Debug pass, since a Debug app whose tool locks match the packaged app's shares `~/.lungfish`. Hide the Debug windows before a full-screen control prompt, since they cover the Claude app's prompt. Run no packaged app beside a Debug pass. A Finder drag works by computer use as a press, stepped moves, a pause and a release. A save sheet refuses a typed path, so choose its folder from the folder pop-up's Recent Places. Keep full control while the owner may leave, since after `release_full_control` the next full-screen action needs a new approval card and the background app tools open no pop-up menu. A copied walk project keeps classifier results whose stored absolute paths point into the old project, so run a fresh result in the copy before any Extract. `lungfish-cli provenance verify` checks signed sidecars only. The five walk votes run on opus at effort xhigh, read the walk state file and its images, stop at 45 calls and write `VOTE` lines that the manager tallies. |

## The manager's context budget

Every spawn prompt, brief, final message and tool result stays in the manager's context. Set `"autoCompactWindow":
600000` in the user settings, `~/.claude/settings.json`, before the session starts, and never in the tracked
`.claude/settings.json`, or have the owner type `/autocompact 600000`, since a saved value
waits for the next session. The manager then compacts near 567K, where a turn costs about twice what it costs after,
and with a current STATE block a compaction repeats no work. These habits keep the context lean.

| Habit | Why |
|---|---|
| Read verdict lines and named sections with `rg -n` and `sed -n`, never a whole report, diff or log. Pass paths to agents, not content. | Whole-file reads fill the manager fastest. |
| Handle each completion in one message. Keep text between calls to one line. | Every completion costs turns at the manager's context size. |
| Rewrite the STATE block in `notes.md` at every landing and launch, with a continuation guide naming every running agent, the next launches and the end steps. | The STATE block is the only memory that survives compaction. |
| Write the spawn settings (model, effort, isolation and the wait timeouts) into the STATE block. | After the first compaction of 2.10 every expert spawn ran without effort max until the settings went into the STATE. |
| While agents or an outside job such as a cluster batch run for over an hour, keep a background command that ends within about 55 minutes, such as the context alarm or one wait on the job with that run time, and answer its end with one short turn. | The main session's cache lives one hour, and a turn after a longer idle gap writes the whole context again, so keep the STATE block current before any wait that may pass the hour. |
| Never load a skill in the manager. Edit a known settings key with Edit, or give the change to a sonnet agent. | Claude Code puts a loaded skill's text back after every compaction. |
| Keep the cwd inside the program worktree for the whole session and run git there, where `git rev-parse worktree-agent-<id>` reads any lane's head. Run `pwd` in the message that spawns a landing agent. | The guard refuses `git -C` into another worktree, and a landing agent spawned without isolation works in the manager's cwd. In 3.1 one started in the primary checkout after the cwd moved there, and landed nothing. |
| Run one phase or one named task in a session, and start unrelated work in a fresh session or with a fresh agent. After two failed corrections of one issue, hand it to a fresh agent whose brief names the files and what the two attempts showed | Unrelated work and failed attempts stay in the manager's context, and every later turn rereads them, which the Manager context row of `docs/contracts/LLM-EVIDENCE.md` measures |

## Limits of Claude Code to state in every brief

| Limit | Do instead |
|---|---|
| A subagent Write of a file whose name starts with report is refused | Name the file after the lane, `<LANE>.md` |
| Foreground `sleep` is blocked and the refusal suggests Monitor, which returns at once while the agent keeps working | The blocking wait above, and Monitor only to watch while doing other work |
| `python3 -` waits on stdin until the call times out, and a Bash call moves to the background at its timeout, 120 s by default | Write the script to a file, and pass a timeout on every long call |
| Background and Monitor events of a subagent never reach the manager | Report in the final message and the lane file |
| A background command that ends after the final message wakes the agent, which writes its context to the cache again | Let it end, or stop it, before the final message |
| EnterWorktree from a subagent into another agent's worktree is refused, and a new worktree starts at origin/main | `isolation: "worktree"` and the guarded reset to the head to build on |
| Agent types in `.claude/agents/` load only when the session starts | Commit a new type before the session that uses it |
| In bypass mode `SubagentHandback` is refused | End with the final message |

## End check and heartbeat

At the end a fresh monitor agent briefed with files runs as `.claude/agents/llm-efficiency-monitor.md` sets out, with
scripts that read the transcripts so no transcript text enters its context. It leaves a ledger, a table of spend by
role, model and effort, and numbered proposals for the owner. While agents run, the manager keeps a heartbeat of at
most 45 minutes that reads `get_usage`, disk and each agent's transcript size, and acts on the thresholds below.

| Signal | Threshold | Action |
|---|---|---|
| Pending tool call | over 15 minutes | Ask the agent, and stop it with a Handoff when it hangs |
| Lane size | past the stop line of its prompt (60 calls for a documentation lane) by the ledger's calls, or 400K of context, 300K for a sonnet agent, review, ruling or fact-check | Check that the agent stopped with a Handoff at its own count. Read every agent's context with `SCR/llm/ctx_watch.py` in each manager wait, and keep a background alarm with both lines and a free-disk line running while any agent runs, restarted at each end. At the line send "Write your Handoff now and stop.", never a later call number. Give the next milestone to a fresh agent |
| Resume of an idle agent | any past about 250K of context, after 5 idle minutes | Replace it with a fresh agent briefed with files |
| Guard rejections or new refusals | over 1% of an agent's turns, or a new kind | Fix the command forms in the brief |
| Poll-only turns | over 10% of spend | Restate the blocking wait in the briefs and to the running agents |
| Cache rebuild | any after a long wait or a long turn | Set the wait timeouts to 180000 for opus and 270000 for sonnet, and have long files written in parts |
| Burn, load, memory and quota | over about $120 an hour, above the 5-hour line, over 5 building agents or a load average of 40, swap over about 90% used or kernel memory pressure at level 2, or a weekly projection over the stop line | Hold launches, and tell the owner of the weekly projection. For memory, keep the watch of `build/llm/memwatch.py` running, which stops relaunchable user daemons by PID, restarts a leaking root daemon only through the owner's installed helper and writes a hold file |
| Free disk | under about 100 GB | Delete the build folders of finished lanes, then thin the snapshots under the owner's grant. Keep the alarm running through chain and walk days |
| Manager context | over 85% of the window, or over half of it before a long wait or a GUI walk by computer use | Refresh the STATE block, and before the wait or the walk have the owner type `/compact` |
| Model or effort unset | any spawn without an explicit `model` or `effort`, or a brief without its opening line | Name each as a breach with its agent id, and restate the rule in the next briefs |

## Evidence

The direct cost of a lane is its lane agents, its review, its fix agent and its share of the landing agent, and the
all-in cost adds the panel, the manager and the monitor. `docs/contracts/LLM-EVIDENCE.md` holds the measurement behind
each rule. A manager reads it only to question or change a rule, and the monitor adds to it at the end of a session.
Rows of earlier phases, 2.7 to 3.2 so far, are in `/Users/dho/lungfish-phase-records/session-table.md`, and the docs
commit that adds a phase's first row moves the earlier phase's rows there.

| Session | Date | Spend and wall time | Lanes landed | Direct cost per landed lane | All-in per landed lane |
|---|---|---|---|---|---|
| 3.3 session 1, to the monitor after the last landing and before the final candidate | 2026-11-06 and 07 | $477 over 17h57m by the ledger estimate (opus $267, sonnet $211), $94 of it the manager with three compactions, $41 the panel's meeting of ten opus max seats in two rounds, $34 fifteen rulings and re-rates, $109 fifty-five reviews and checks, $51 twenty-one landings, the week 8% to 41% at about $14 to $19 a point. The owner set no budget for 3.3 | 24 in 17 landing batches | median $10.23, mean $13.13 | $19.89 |
| 2026.11.4 job of 3.3, started as the first monthly stable job until O159 made it a Preview, to the monitor after the last landing and during the last package | 2026-11-07 | $93 over 4h15m by the ledger estimate (opus $72, sonnet $21), $24 of it the manager with no compaction, $32 the panel's meeting of ten opus max seats in two rounds, $6.61 three rulings at opus xhigh, $9.17 five reviews, $7.00 four documentation agents, the week 45% to 51% with the 3.3 session open. No budget figure was set | 6, three in one landing and three documentation commits the manager picked | median $2.19, mean $4.88 | $15.51 |

## End-of-session duty

The monitor at the end of every phase session proposes changes to this contract, and the owner accepts or declines
them (`docs/contracts/SCOPE-AND-DELIVERY.md`). A commit that changes `scripts/llm/` or `.claude/agents/` lands before
the final candidate, and its landing runs `python3 -m unittest scripts/tests/test_session_ledger.py`, since the unit
tier runs that test only under `--profile extended`. A commit that changes only `docs/contracts/` is release-neutral and
may follow the release as a fast-forward that inherits the unit evidence.

- Add the session to the session table, and its measurements to `docs/contracts/LLM-EVIDENCE.md` in place of older ones.
- Propose to change or remove a rule that a before-and-after measurement contradicts, and a new rule only when a
  measurement or a `page` basis of `docs/contracts/CLAUDE-CODE-PRACTICES.md` supports it. This file stays under about 200 lines.
- Update `.claude/agents/llm-efficiency-monitor.md` and the ledger with its test when they changed, commit any agent
  type the session proposed, since types load only at a session's start, and copy the helpers to `build/llm/`.
- For this file, `CLAUDE.md`, `AGENTS.md` and each contract the session changed, list the lines that no longer prevent
  a mistake in one numbered proposal. A fact about code moves to `docs/architecture/ARCHITECTURE.md` or the module's
  `AGENTS.md`.
