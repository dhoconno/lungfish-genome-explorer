# Running a phase session with LLM agents

This contract is for the manager of a Lungfish Genome Explorer (LGE) phase session. `docs/contracts/SCOPE-AND-DELIVERY.md` (SAD) wins over this file. The agent types in `.claude/agents/` set each role's model, effort, stop line and command rules, and a brief or prompt restates none of them and sets a stop line only where it differs from the type's (E-RUN-36). A rule here is one sentence that says what to do, and its reason is a tag `(E-RUN-<n>)` that points to `/Users/dho/lungfish-phase-records/llm/evidence/RUN.md`. The panel meets only when a phase plan is written (`docs/contracts/EXPERT-PANEL.md`, The meeting).

## Roles

- The manager runs on opus at effort max (owner, 2026-11-11, E-RUN-12). It never reads a contract, report or diff whole, writes no plan or record, drives no walk, runs no chain, package or publish, lands only by fast-forward and edits no code beyond a one-line fix. It writes a brief only for a fix, ruling, data or analysis agent, in at most 3,000 characters, and the planner writes every plan lane brief (E-RUN-28). The targets are 4 manager turns an agent and 15 a landed lane (E-RUN-24). No role runs on haiku.
- `lge-review` is one fresh agent a lane from the field it changes most, plus BIO for scientific output, at most two, none for a lane of only documentation or tests (SAD, Bounded reviews). It starts when the lane has ended, and only a ruling in the event log drops a review the brief names (E-RUN-1).
- `lge-fix` takes a review's findings from the lane head, and a fix that needs judgment runs as `lge-lane-opus` (O103, E-RUN-13).
- `lge-data` runs every staging, reproduction and analysis agent that changes no app code, and none of them runs as general-purpose (E-RUN-26).
- `llm-efficiency-monitor` runs after the last landing and before the final candidate, and again at the close when landings followed (E-RUN-2).

## Files the session keeps

`SCR` is the session's records folder outside the repository, and agents name its files with literal paths.

| File | Writer | Holds |
|---|---|---|
| `SCR/notes.md` | manager | The STATE block only, at most 3 KB, replaced at every landing and launch with `python3 scripts/session/put_state.py NOTES.md STATE.md`. It names each running agent with its type, model, effort and wait timeouts (E-RUN-10), the next launches and the end steps. A step is done only after its call ran, a text sent only after a transcript check shows it, and every time comes from `date '+%H:%M'` or a tool's stamp |
| `SCR/events.log` | manager | The only chronological record, one stamped line an event |
| `SCR/briefs/lane-<LANE>.md` | planner | The files, the change and the check that proves the lane, as `lge-planner` sets (E-RUN-3). A documentation brief gives each fact with its source, and a release-notes check goes in slices of about 40 claims (E-RUN-4) |

Reports go to `SCR/lanes/`, `SCR/reviews/` and `SCR/land/`, and the monitor's files and `done_ids.txt`, the ended agents' ids that `reap_build.py` and `heartbeat.sh` read, to `SCR/llm/`.

## Session start

Before the first launch run `python3 scripts/session/preflight.py [--fetch] [--doctor] [--session-id ID] [--program-worktree DIR]`. It exits 1 on an ACT line, which the manager acts on first, and with `--session-id` it prints ACT when the manager's transcript shows an effort other than max (E-RUN-29). `--start` fills the START prompt from `scripts/session/start-template.md` and the prompt holds nothing else. Read `get_usage`, loaded with ToolSearch in the same message as every other deferred tool (E-RUN-20). The owner starts a phase session in bypass permissions (E-RUN-8). In the default mode only command forms that already ran this session are safe, and a new `rm -rf` or git delete form runs only with the owner present.

## Rules for the manager

| Rule | What to do |
|---|---|
| Spawn | Paste each base commit into the prompt in full, copied from `git rev-parse`. Every Agent call names the type, and sets `model` and `effort` where the type names none. The prompt opens with `You run as <agent type> on <model> at effort <level>.`, and a brief that delegates work names the same three for each agent. Every agent keeps each turn under 4 minutes and waits at most 4 minutes a call, since the 55-minute round of E-RUN-22 is the manager's alone, and writes a file in parts of at most 4,000 characters, one Write then Edits (E-RUN-15, E-RUN-30). A fix or plan-fill prompt, like the `lge-data` type, says that a table a script writes changes only through that script, so the agent edits the script, reruns it and commits both (E-RUN-33). Commit a new type before the session that uses it |
| Queue, don't wait | A lane whose heavy step waits on a shared lock, the PAUSE file or the load launches it under `nohup` with a wrapper that waits, writes a Handoff with the PIDs and next commands, and ends (E-RUN-30) |
| Fresh worktrees | Spawn every lane, continuation and fix agent with `isolation: "worktree"` and its base in full, and it starts with the guarded reset `bash scripts/session/lane_start.sh <full base>`, never `git merge --ff-only`. Start the longest chains first, and a continuation or a lane that builds on a reviewed lane from the previous head without waiting for a review or a landing |
| Fresh agents | Start each stage, fix round and continuation with a fresh agent briefed with files. Spawn an agent that needs a ruling after the ruling ends, with its items in the prompt, and send no new work to an agent past half its stop line (E-RUN-32). Answer a stopped agent by message within 4 minutes of its last turn, or start a fresh one. Only an agent that waits on the owner or a ruling, with under about 250K of context, resumes later by message (E-RUN-13) |
| Lane scope | A brief names a milestone of at most three work items. A sonnet lane holds at most two rows that each need a test that fails first, and a lane that clears the failing lines of a comparison test gets at most 6 named rows of one side (E-RUN-14) |
| Landing batches | A lane based on the program head whose review reads Merge with no fold lands by `git merge --ff-only`. Any other range waits for a batch of three or 45 minutes and goes to one `lge-land` agent. Fold at most two small review fixes into the brief as `path:line` and text. A review with three or more, or a fix that needs a measurement, a new test design or judgment, goes to a fix agent first. The unit tier runs as the Integration row of `docs/contracts/VERIFICATION-ORDER.md` sets, and once before a candidate (E-RUN-17). Other findings go to `docs/plans/BACKLOG.md` |
| Rulings | Route each open question as `docs/contracts/EXPERT-PANEL.md` sets under Rulings and disputes. Answer a question that a recorded rule settles by message, and give the others to one `lge-ruling` agent a field once 8 gather or 20 minutes pass, unless one is an S1 or blocks a running chain, with no stop line in its prompt (E-RUN-31). Rule a row that reads S1 if reachable before the next chain starts (E-RUN-5). A finding takes a severity, never a vote |
| Concurrency | At most 5 building agents (lanes, fix and landing agents, not reviews), launched only at a load average under 40 on galah and about 3 minutes apart, the first wave included (E-RUN-6). When another session's work runs at nice 15 to 20, judge the load by this session's own processes, while the cap and the memory alarm hold (E-RUN-35) |
| Quota pacing | Read `get_usage` at every landing. Keep the 5-hour figure under a straight line from the window start (20 points an hour) and hold every spawn at 75%. Project the weekly close from the rows left, each with a low and a high cost, at this week's own dollars a point from two readings about 10 points apart (E-RUN-7). When the projection crosses the stop line, ask the owner which rows move on. Start no new lane past 92% of the week, and at one and a half times the budget follow SAD, row Budgets stop work |
| Disk and snapshots | Remove a finished lane's build folder with `python3 scripts/session/reap_build.py <worktree> --done-ids SCR/llm/done_ids.txt --execute` once its last agent has ended, or write the command into STATE for the owner when the permission mode refuses it. Thin the local snapshots in the same step and at the first reading under about 100 GB with `tmutil thinlocalsnapshots / 400000000000 4` (E-RUN-19). Archives go to `/Volumes/lge_scratch/lge/archive/`, and with that disk missing tell the owner and move none |
| Confirmed end | Start a review, a landing or a check of an agent's work only when `python3 scripts/session/agent_ended.py TRANSCRIPT.jsonl [--min-age 30] [--worktree DIR]` prints ENDED (E-RUN-37) |
| Own processes only | Stop only a process you started, by PID, never by name with `pkill` or `killall` (E-RUN-18). End a hung Lungfish app with `python3 scripts/session/end_hung_app.py --list`, then `end_hung_app.py PID [--execute]` |
| GUI walk | An `lge-walker` agent runs the packaged walk in background control, a fresh one for each block of rows, and it counts as the packaged walk of `docs/contracts/VERIFICATION-ORDER.md` with or without the owner at the Mac (O126). Full-screen control is taken only on the owner's go in chat, and the other rules are the Walk section of `docs/contracts/MACHINES.md` |

## The manager's context budget

Keep `"autoCompactWindow": 600000` in `~/.claude/settings.json`, never in the tracked `.claude/settings.json` (E-RUN-38).

- While agents or an outside job run over an hour, keep a background command that ends within about 55 minutes, such as the heartbeat, and answer its end with one short turn (E-RUN-22).
- Never load a skill in the manager (E-RUN-21).
- Keep the cwd inside the program worktree and run git there. Run `pwd` in the message that spawns a landing agent (E-RUN-11).
- Run one phase or one named task in a session, and hand an issue that two corrections did not fix to a fresh agent whose brief names the files and what the attempts showed (E-RUN-23).

## End check and heartbeat

While agents run, keep `bash scripts/session/heartbeat.sh --project DIR --session SID [--records SCR/llm]` in the background, a round of up to 45 minutes that stops at its first finding, and `python3 scripts/session/memwatch.py --dir SCR/llm` for the memory alarm. The heartbeat runs `ctx_watch.py --calls` every 5 minutes and ends its round when an agent's ledger calls reach the stop line of its type or prompt (E-RUN-27).

| Signal | Threshold | Action |
|---|---|---|
| Pending tool call | over 15 minutes (`python3 scripts/session/ctx_watch.py PROJECT_DIR SID [--stalled SECONDS]`) | Ask the agent, and stop it with a Handoff when it hangs |
| Lane size | past its stop line by the ledger's calls (`--calls`) or its token line (`ctx_watch.py PROJECT_DIR SID [--over K] [--busy]`) | Send "Write your Handoff now and stop." at the line, never a later call number. A fresh agent takes the next milestone (E-RUN-16) |
| Refusals, polling, cache | guard rejections over 1% of turns or a new kind, poll-only turns over 10% of spend, any cache rebuild | Fix the command forms, waits and timeouts in the briefs |
| Burn, load, memory and quota | over about $120 an hour, above the 5-hour line, over 5 building agents, a load average over 40, a `memwatch.alarm` line, or a weekly projection over the stop line | Hold launches and tell the owner of the projection. End the process that a RUNAWAY or BIGPROC alarm line names, by PID |
| Free disk | under about 100 GB | Remove finished lanes' build folders, then thin the snapshots |

## End-of-session duty

A session with subagents, builds or over an hour ends with `python3 scripts/llm/session_ledger.py --md <file> <session id>` and a line in the session table. The ledger takes each agent's role from its `lge-` type, and from the description only for a general-purpose agent (E-RUN-34). A commit that changes `scripts/llm/` or `.claude/agents/` lands before the final candidate and runs `python3 -m unittest scripts/tests/test_session_ledger.py`. A commit that changes only `docs/contracts/` is release-neutral.

- A sentence added after one incident carries its date, and the monitor deletes it after two sessions without a repeat unless a script now holds it (E-RUN-25).
