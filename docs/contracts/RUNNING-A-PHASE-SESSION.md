# Running a phase session with LLM agents

This contract is for the manager of a Lungfish Genome Explorer (LGE) phase session. The agent types in `.claude/agents/` set each role's model, effort, stop line and command rules. `docs/contracts/SCOPE-AND-DELIVERY.md` (SAD) wins over this file. A rule here is one sentence that says what to do, and its reason is a tag `(E-RUN-<n>)` that points to `/Users/dho/lungfish-phase-records/llm/evidence/RUN.md`. The panel meets once, when a phase plan is written (`docs/contracts/EXPERT-PANEL.md`, section The meeting), and a later session of the same plan, a fix session, a release job and a short job hold no meeting.

## Roles

- The manager runs on opus at effort max (owner, 2026-11-11, E-RUN-12). It never reads a contract, report or diff whole, writes no plan, brief or record, drives no walk, runs no chain, package or publish, lands only by fast-forward and edits no code beyond a one-line fix. The targets are 4 manager turns an agent and 15 a landed lane (E-RUN-24). No role runs on haiku.
- `lge-review` is one fresh agent a lane from the field it changes most, plus BIO for scientific output, at most two, none for a lane of only documentation or tests (SAD, Bounded reviews). It starts when the lane has ended, and only a ruling in the event log drops a review the brief names (E-RUN-1).
- `lge-fix` takes a review's findings from the lane head. A fix that needs judgment runs as `lge-lane-opus` on opus at effort xhigh, which matched max at about half the cost (O103, E-RUN-13).
- `llm-efficiency-monitor` runs after the last landing and before the final candidate, and again at the close when landings followed (E-RUN-2).

## Files the session keeps

`SCR` is the session's records folder outside the repository, and agents name its files with literal paths.

| File | Writer | Holds |
|---|---|---|
| `SCR/notes.md` | manager | The STATE block only, at most 3 KB, replaced at every landing and launch with `python3 scripts/session/put_state.py NOTES.md STATE.md [--max-bytes 3072]`. It names each running agent with its type, model, effort and wait timeouts (E-RUN-10), the next launches and the end steps. A step is done only after its call ran, a text sent only after a transcript check shows it, and every time comes from `date '+%H:%M'` or a tool's stamp |
| `SCR/events.log` | manager | The only chronological record, one stamped line an event |
| `SCR/briefs/lane-<LANE>.md` | planner | The files, the change and the check that proves the lane (tests, or the build, ratchet or golden command, and the passing result). A documentation brief gives each fact with its source, and a release-notes check goes in slices of about 40 claims (E-RUN-4). A GUI or device gate adds one run of it at the base on this Mac, and a lane that reports a GUI or launch route as working puts the app it launched, with the pid and the first window, into its report (E-RUN-3) |

Reports go to `SCR/lanes/`, `SCR/reviews/` and `SCR/land/`. The monitor keeps ledgers, the log, actions and `done_ids.txt` (the ids of ended agents that `reap_build.py` and `heartbeat.sh` read) in `SCR/llm/`, and writes the session table and the measurements to `/Users/dho/lungfish-phase-records/`, never into the repository.

## Session start

Before the first launch run `python3 scripts/session/preflight.py [--fetch] [--doctor] [--session-id ID] [--program-worktree DIR]`. It prints PASS, ACT or SKIP lines and exits 1 on ACT, which the manager acts on first. `--start` fills the START prompt from `scripts/session/start-template.md` and the prompt holds nothing else. Read `get_usage`, loaded with ToolSearch in the same message as every other deferred tool (E-RUN-20). A call held at the permission step holds the manager's turn and no notification wakes it, so the owner starts a phase session in bypass permissions (E-RUN-8), and in the default mode only command forms that already ran this session are safe.

## Rules for the manager

| Rule | What to do |
|---|---|
| Spawn | Paste each base commit into the prompt in full, copied from `git rev-parse`. Every Agent call names the type, and sets `model` and `effort` where the type names none. The prompt opens with `You run as <agent type> on <model> at effort <level>.`, and a brief that delegates work names the same three for each agent. Every agent keeps each turn under 4 minutes and writes a file in parts, one Write of at most 4,000 characters, then Edits of at most 4,000 characters each (E-RUN-15). Commit a new type before the session that uses it |
| Fresh worktrees | Spawn every lane, continuation and fix agent with `isolation: "worktree"` and its base in full. It starts with the guarded reset, which checks that `git branch --show-current` names a `worktree-agent-` branch and `git status --short` is empty, then runs `git reset --hard <full base>`. `bash scripts/session/lane_start.sh <full base>` does all three. Never `git merge --ff-only` as a start. Start the longest chains first, and a continuation or a lane that builds on a reviewed lane from the previous head without waiting for a review or a landing |
| Fresh agents | Start each stage, fix round and continuation with a fresh agent briefed with files. Answer a stopped agent by message within 4 minutes of its last turn, or start a fresh one. Only an agent that waits on the owner or a ruling, with under about 250K of context, resumes later by message (E-RUN-13) |
| Lane scope | The type sets the stop line and the brief names a milestone of at most three work items. A sonnet lane holds at most two rows that each need a test that fails first, and a lane that clears the failing lines of a comparison test gets at most 6 named rows of one side (E-RUN-14) |
| Landing batches | A lane based on the program head whose review reads Merge with no fold lands by `git merge --ff-only`. Any other range waits for a batch of three or 45 minutes, whichever comes first, and goes to one `lge-land` agent. Fold at most two small review fixes into the brief as `path:line` and text. A review with three or more, or a fix that needs a measurement, a new test design or judgment, goes to a fix agent first. The unit tier runs as the Integration row of `docs/contracts/VERIFICATION-ORDER.md` sets, and once before a candidate (E-RUN-17). Other findings go to `docs/plans/BACKLOG.md` |
| Rulings | Route each open question as `docs/contracts/EXPERT-PANEL.md` sets under Rulings and disputes. Answer a question that a recorded rule settles by message, and give any other to one `lge-ruling` agent. Rule a row that reads S1 if reachable before the next chain starts, with the ruling measuring what it expects of real data (E-RUN-5). A finding takes a severity, never a vote |
| Concurrency | At most 5 building agents (lanes, fix agents and landing agents, not reviews), launched only at a load average under 40 on galah (20 cores) and about 3 minutes apart, the first wave included (E-RUN-6). |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour) and hold every spawn at 75%. Project the weekly close from the rows left, each with a low and a high cost, at this week's own dollars a point from two readings about 10 points apart (E-RUN-7). When the projection crosses the stop line, ask the owner which rows move on. At one and a half times the budget the manager starts no new lane, tells the owner and closes the session with a Preview if one is due. A question to the owner never stops other work |
| Disk and snapshots | A build folder holds 17 to 18 GB. The manager removes a finished lane's with `python3 scripts/session/reap_build.py <worktree> --done-ids SCR/llm/done_ids.txt --execute` once the lane's last agent has ended, with no owner word. If the session's permission mode refuses it, the manager writes the command into STATE for the owner and goes on. Under the owner's standing grant, thin the local snapshots in the same step and at the first reading under about 100 GB with `tmutil thinlocalsnapshots / 400000000000 4` (E-RUN-19). Archives go to `/Volumes/lge_scratch/lge/archive/`, and with that disk missing the manager tells the owner and moves no archive |
| Confirmed end | Start a review, a landing or a check of an agent's work only when `python3 scripts/session/agent_ended.py TRANSCRIPT.jsonl [--min-age 30] [--worktree DIR]` prints ENDED, since a background command that ends after the final message wakes the agent |
| Own processes only | Stop only a process you started, by PID, never by name with `pkill` or `killall` (E-RUN-18). End a hung Lungfish app with `python3 scripts/session/end_hung_app.py --list`, then `end_hung_app.py PID [--execute]` |
| GUI walk | An `lge-walker` agent runs the packaged walk in background control, a fresh one for each block of rows, and it counts as the packaged walk of `docs/contracts/VERIFICATION-ORDER.md` with or without the owner at the Mac (O126). Full-screen control is taken only on the owner's go in chat, and `request_full_control` asks for approval on galah's own screen, not on the owner's laptop. A row that needs the app in front without that go is an owner list row. The other rules are the Walk section of `docs/contracts/MACHINES.md`. |

## The manager's context budget

Keep `"autoCompactWindow": 600000` in the user settings `~/.claude/settings.json`, never in the tracked `.claude/settings.json`, since a saved value takes effect at the next session start.

- While agents or an outside job run over an hour, keep a background command that ends within about 55 minutes, such as the heartbeat, and answer its end with one short turn (E-RUN-22).
- Never load a skill in the manager (E-RUN-21).
- Keep the cwd inside the program worktree and run git there, where `git rev-parse worktree-agent-<id>` reads any lane's head. Run `pwd` in the message that spawns a landing agent (E-RUN-11).
- Run one phase or one named task in a session, and hand an issue that two corrections did not fix to a fresh agent whose brief names the files and what the attempts showed (E-RUN-23).

## End check and heartbeat

While agents run, keep `bash scripts/session/heartbeat.sh --project DIR --session SID [--records SCR/llm]` in the background, a round of up to 45 minutes that stops at its first finding, and `python3 scripts/session/memwatch.py --dir SCR/llm` for the memory alarm.

| Signal | Threshold | Action |
|---|---|---|
| Pending tool call | over 15 minutes (`python3 scripts/session/ctx_watch.py PROJECT_DIR SID [--stalled SECONDS]`) | Ask the agent, and stop it with a Handoff when it hangs |
| Lane size | past the stop line of its type by the ledger's calls, or past its token line (`ctx_watch.py PROJECT_DIR SID [--over K] [--busy]`) | Send "Write your Handoff now and stop." at the line, never a later call number. A fresh agent takes the next milestone (E-RUN-16) |
| Refusals, polling, cache | guard rejections over 1% of turns or a new kind, poll-only turns over 10% of spend, any cache rebuild | Fix the command forms, waits and timeouts in the briefs |
| Burn, load, memory and quota | over about $120 an hour, above the 5-hour line, over 5 building agents, a load average over 40, a `memwatch.alarm` line, or a weekly projection over the stop line | Hold launches and tell the owner of the projection. End the process that a RUNAWAY or BIGPROC alarm line names, by PID |
| Free disk | under about 100 GB | Remove finished lanes' build folders, then thin the snapshots (Disk and snapshots) |

## End-of-session duty

A session with subagents, builds or over an hour ends with `python3 scripts/llm/session_ledger.py --md <file> <session id>` and a line in the session table. The monitor proposes changes to this contract, which land as SAD sets under Process work stays small, and adds the session's row and measurements to the records. A commit that changes `scripts/llm/` or `.claude/agents/` lands before the final candidate and runs `python3 -m unittest scripts/tests/test_session_ledger.py`. A commit that changes only `docs/contracts/` is release-neutral.

- A sentence added after one incident carries its date, and the monitor deletes it after two sessions without a repeat unless a script now holds it. A reason goes to the entry its tag names (E-RUN-25).
