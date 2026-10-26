# The expert panel

This contract sets the part a panel of five expert agents plays in a Lungfish Genome Explorer (LGE) session. The panel
sets a phase's scope when the phase is planned and reviews its exit. Between those, the manager, the main session,
decides inside the plan and hands the work to cheaper agents, one reviewer reads each lane, and severities rather than
votes settle findings, as `docs/contracts/SCOPE-AND-DELIVERY.md` sets. `docs/contracts/RUNNING-A-PHASE-SESSION.md`,
called the efficiency contract below, sets how a session spends model time, and this contract refers to its rules
without repeating them.

The owner directed on 2026-10-11 that the five experts lead every later session. The audit of 2026-10-26 narrowed that,
and the owner accepted the change by putting it on `main` (`docs/reports/2026-10-26-phase-1-2-audit/SUMMARY.md`). About 85% of the margins of some 300
votes were unanimous. Panel design, reviews and rulings cost about $3,800 of the $12,904 measured on the release Mac
from 2026-10-07 to 2026-10-26, and about one review fix in six touched a defect a user could meet. Domain review earned its place, since a
BIO ruling caught a wrong multi-sample Clade % in 2.13. The dated evidence below comes from Phase 2.7, whose record is
`docs/plans/2026-10-11-phase-2-7.md`.

## Scope

| Session | What the panel does |
|---|---|
| Phase session | Every stage under How the panel leads a session. The inventory and memo stages run once, when the phase is planned, and the panel reviews the phase's exit. A sub-phase plan is written by the manager from the phase plan and read by the ARCH expert. |
| Any other session, such as a fix, a probe, a documentation change or a release | No inventory, memo or vote. Before a change lands, one fresh expert from the field it changes most reviews it, with BIO as well when it touches scientific output, the fact-check reads any user-facing text, and the QA and QC expert reviews every release step before it runs. A question that no recorded decision answers goes to the panel as Rulings and disputes sets out. |

## The panel

The manager ruled on the panel's makeup on 2026-10-11. Five experts vote, and two checks report without a vote. Both
checks are agents in `.claude/agents/`.

| Seat | Field id | Votes | Remit |
|---|---|---|---|
| High-performance Swift and macOS | `SWIFT`, letter S | yes | Concurrency and actor isolation, the main thread, process launch and cancel, durable writes, hashing and memory cost, and all process, file-system and other security-sensitive code |
| Software architecture | `ARCH`, letter A | yes | Module layering, which component owns each write, one command path for the GUI and the CLI, names and layouts on disk, ratchets and file size, and rollback routes |
| Bioinformatics | `BIO`, letter B | yes | Scientific payloads and counts, read layouts and effective parameters, sample identity, the facts in provenance records and their traceability, and golden changes to scientific output |
| UI and UX | `UX`, letter U | yes | Labels, warnings and progress, the end of a run, failure and cancel, the Inspector and the Provenance tab, VoiceOver order, and every word a user reads |
| QA and QC | `QA`, letter Q | yes | Freeze and pin order, test tiers and real-tool tests, goldens and contract counts, determinism, the gates, and release engineering and code signing (Developer ID, notarization, Sparkle) |
| Documentation fact-check, the `manual-fidelity-reviewer` agent | none | no | Every factual claim of a lane that writes user-facing text (the manual, release notes, an owner check list). It writes `SCR/reviews/<LANE>-facts.md` beside the field review, and each wrong fact is a fix that lands with the lane |
| LLM-efficiency monitor, the `llm-efficiency-monitor` agent | none | no | The model spend of every session, measured once at its end, as the efficiency contract sets under The monitor runs once, at the end |

The voting panel stays at five. In Phase 2.7 the five fields covered all 39 reviews of 34 lanes, and no lane waited for
want of a field. Two remits widened on 2026-10-11. QA and QC took release engineering and code signing, and Swift and
macOS took process, file-system and other security-sensitive code. The fact-check joined because the 2.7
documentation lanes cost the most per line and carried the only factual errors that reached review.

When a phase's scope reaches a field none of the five owns, such as the security of downloads, updates and plugin
installation, the panel co-opts a sixth expert for that phase by a vote of at least 4 to 1. The plan records the vote
with the field, its remit and its checklist. The sixth expert writes an inventory and a memo, votes on that phase's
questions and reviews its lanes, and its seat ends with the phase.

## How the panel leads a session

A phase session runs these stages in order. The efficiency contract sets how each agent is spawned, sized and paced.

| Stage | Who works, on which model | What it leaves |
|---|---|---|
| Owner direction | The owner, written down by the manager with its date. While the owner is at the Mac and before the first spawn, the manager uses the AskUserQuestion tool to ask what only the owner can answer, on scope, what stays out, risks, tradeoffs and the result that ends the phase, and asks nothing that the last plan or a recorded decision answers. When the plan is drafted at the end of a long session, the questions go to a short session of its own. Each answer becomes a row with an id, the question, the owner's choice quoted and what it sets. Once agents run, the manager asks the owner in a plain message that ends its turn, never in a question call, so that the agents' notifications still wake it | The first section of the phase plan, which names what is in scope, what stays out and the result that ends the phase. While the owner is away, a question only the owner can answer goes on the owner check list |
| Inventory, once a phase | One fresh read-only agent per field, Opus at effort xhigh, starting from the last plan's decisions and the backlog's ranked rows | `SCR/inv/<FIELD>.md` with facts at a named commit, candidate lanes with their files and models, risks, open questions `Q-<letter><n>` and what should move out |
| Memos and decisions, once a phase | One fresh agent per field, Opus at effort xhigh, reading every inventory and the manager's merged question list | `SCR/memos/<FIELD>.md` with votes, objections, scope, order and the field's checks for the phase, which the manager tallies into the decision table |
| Plan | The manager, from the decisions | The phase plan with the decisions, lanes, models, dependencies and the panel's cut order, first to cut first |
| Lanes | One agent per lane, Sonnet at effort max for mechanical or well-pinned work, Opus at effort xhigh for design-sensitive work and the longest chain | Commits and a lane report |
| Review | One fresh agent from the field the lane changes most, plus BIO when the lane touches scientific output, Sonnet at effort max since the tests of 2026-10-15, which measured a candidate review and a code-diff review, plus the fact-check for user-facing text, also Sonnet at effort max. A lane that changes only documentation or only tests gets the fact-check where it writes user-facing text and no field review | `SCR/reviews/<LANE>.md` with a verdict (Merge, Merge after fixes or Block), its blockers and at most three should-fix items. A blocker is a wrong result, data loss, a crash, a security hole, a broken build, an S1 or S2 finding or a requirement of the lane's brief that the lane does not meet. Every other finding goes to `docs/plans/BACKLOG.md` with its `path:line` and its effect on results or users, with no fix agent spawned for it |
| Fixes | A fresh fix agent, Sonnet at effort max for code fixes and at effort high for given words pasted into documentation, Opus at effort max when a fix needs judgment | Commits that answer each numbered fix |
| Landing | Landing agents in batches, Sonnet at effort max | The program branch, holding reviewed lanes only |
| Final candidate | The manager runs the gates of `docs/contracts/VERIFICATION-ORDER.md` once, the XCUI smoke and the packaged walk among them, and the QA and QC expert reviews their evidence | The candidate commit, the findings with their severities and the owner check list |
| Record | The manager | What ran, Expert reviews and Final candidate in the phase plan, and new rows in `docs/plans/BACKLOG.md` |

Three rules hold at every stage. Experts never edit code or build. They read, vote, rule and review, and a review that
needs a test rerun names it as a fix. Lanes never decide scope. A lane that meets a question its brief does not answer
writes it in its report and goes on only with work the question does not touch. The manager carries out the panel's
decisions, cuts lanes only in the cut order, and brings an open question to the panel only as Rulings and disputes sets out.

## Rulings and disputes

| Question | Settled by | Written down as |
|---|---|---|
| A fact, such as what the code does or what a file holds | Reading the code or the data at a named commit, never another review's reading | `path:line` at that commit, in the review, memo or plan that relies on it |
| A question within one field | The expert of that field, as a ruling | The ruling with its evidence in the review or memo, and in the plan when it binds more than one lane |
| A finding from a review or a walk | Its severity under `docs/contracts/SCOPE-AND-DELIVERY.md`, set by BIO for anything that touches a scientific number and by UX for the rest, with no vote | The finding, its severity and its `path:line` or walk row. S1 and S2 go to the plan, S3 and S4 to the backlog |
| A question across fields, or a change to a recorded decision | A vote of the panel, only when two fields disagree on scope or on an S1 or S2 finding, or when the owner asks | A row of the plan's decision table with the vote |

A vote passes by a majority of the experts who vote, and an expert abstains on a question its field cannot judge. A
tie goes to the option that loses no recorded scientific information and can be verified in the session, then to the
smaller change, the rule of Phase 2.7. When two readings of a fact disagree, the manager has a fresh agent of the field
read the code at a named commit, and that reading is recorded as the ruling.

In 2.7 two reviews disagreed on whether Kraken2 results grow when the CLI route keeps its materialized inputs. A fix
agent, the manager's notes and an edit of decision E3 followed the first review's reading. The second review read
`Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift` at `0c259de2b` and found the replay copy that the
in-process route already kept, so only EsViritu results grow, as E3 had said. The code settled it, and a later commit
restored the E3 rationale.

## Decisions persist

The plan records each decision under Panel decisions, in a table of Id, Decision and Vote. An id is a topic letter and
a number, unique within its plan, and a later plan cites it with its phase, as 2.7 E3. A vote reads as `5 to 0`,
`4 to 0, Swift abstained` or `4 to 1, bioinformatics voted removal`, and an amended decision says so.

A recorded decision binds every later session until the panel revisits it with a recorded vote, or until a contract
the owner accepts replaces it, as the last table of `docs/contracts/SCOPE-AND-DELIVERY.md` does. The revisit is a row of
the new plan's table under the old id, with the new decision, the vote and the evidence that reopened it. Before a plan
is deleted, its decisions still in force move into the next plan or into the contract they belong to.

Each phase's inventory stage starts from the previous plan's decisions and the backlog's ranked rows. An inventory
names the decisions its field's work rests on and the backlog rows it takes up, and it reopens a decision only with new
evidence.

## Review checklists

A review applies the checklist of the lane's field and of every other field the lane touches, plus the checks the
phase's memos add, and cites each check by its id.

| Id | Check |
|---|---|
| SWIFT 1 | Isolation. The `concurrency-hatches` and `process-spawn` ratchets stay flat, no actor state is read across an `await` that another call can interleave, and no `Task.detached` or GCD hop sits inside a task-local scope. |
| SWIFT 2 | Main thread. No hashing, file read, SQLite query or result load runs on the main actor, and events reach the main queue in order. |
| SWIFT 3 | Processes and cancel. Every launch goes through a runner that `docs/contracts/RUNNING-A-TOOL.md` names, a cancel stops the whole tool tree inside its grace with the status taken from the cancel request, and a test finds no process left. |
| SWIFT 4 | Durability. Writes go through `DurableReplace` or `PortableRename`, scratch files stay out of bundles, and `scripts/testing/exfat-tests.sh --simulate` ran for each touched write path. |
| SWIFT 5 | Cost. One open serves digest and size, each large file is hashed once per command, no database folder is hashed per run, and large inputs are streamed rather than loaded whole. |
| SWIFT 6 | Security. Arguments reach a process as an argv, never as a shell string built from user or file input. Paths from users, records or downloads are resolved and checked before a write, move or delete, and no secret or signing identity reaches a log, a record or a golden. |
| SWIFT 7 | Timing. Timing-sensitive suites ran with every core busy, and no test passes only on an idle machine. |
| ARCH 1 | Layering. No module imports one above it in `docs/architecture/MODULES.md`, a lower module reaches a higher one only through a protocol it declares, and new public types or folders are reported for the module map. |
| ARCH 2 | One path for both surfaces. The GUI runs the command the CLI runs, the row's command equals the argv the transport ran (`docs/contracts/CLI-EQUIVALENCE.md`), the record's argv equals the command run, and the GUI writes no byte after the CLI exits. |
| ARCH 3 | Ownership of writes. One component creates, settles or discards each result folder and writes its root record last, and a planning step writes nothing. |
| ARCH 4 | Names and layouts. One sanitizer feeds every name of a sample, layouts follow `docs/formats/`, and older layouts still open, with any changed route named in its commit. |
| ARCH 5 | Records name files that exist. `provenance verify` passes on every new result, cleanup deletes nothing a record names, and every move of an output is a recorded step. |
| ARCH 6 | Ratchets and size. No baselined file grows, new files stay at or under 800 lines, no ratchet rises (`provenance-writers` and `cli-parity-gaps` included), and contract counts move only by the leaves converted. |
| ARCH 7 | Rollback. A route being replaced stays untouched with its pins passing until the panel decides its removal, a switch routes back to it, and a parity test runs both routes. |
| BIO 1 | Payloads. Scientific outputs are byte-identical to the frozen base in every case, sorted where the order is not defined, with only declared shape differences. |
| BIO 2 | Counts and read layouts. Read counts, pairing (pairs, merged and single reads) and read-set plans equal the base under `docs/contracts/READ-PAIRING.md`, and every argv carries the same layout flags, thresholds and database. |
| BIO 3 | Effective parameters. Every command keeps its effective parameters, including a run with no flags, and recorded defaults equal the command's real defaults. |
| BIO 4 | No fact lost and no false fact. Every frozen record fact is present with an equal value, a degraded result says so with its reason, no option is recorded that was not chosen, no digest is recorded for what was not checked, and versions come from the environment that ran. |
| BIO 5 | Sample identity. Grouping and order do not depend on the locale, one label names a sample in its folder, tool tables and index, and ids with dots or other punctuation keep their results. |
| BIO 6 | Traceability. Lineage runs from each tool input to its bundle and payload checksums, records are written before any removal, every output a record names exists with its digest, and a replay regenerates the recorded digest. |
| BIO 7 | Goldens. Each change is predicted key by key and checked, and no scientific payload moves unless that is the lane's purpose. |
| UX 1 | Labels. Words a person reads say what happened and what to do next, for every outcome (success, empty, warnings, partial batch, failed, cancelled). Output that a program parses, such as CLI JSON, record keys and exported tables, keeps its frozen form unless the lane changes it on purpose. A lane may make other words clearer, and the reviewer reads the new words. |
| UX 2 | Warnings. Completed with Warnings appears in exactly the cases it did at the base, with one warning line per cause, and no information line becomes a warning. |
| UX 3 | Progress. Every stage message reaches the row's detail, the log and the viewer overlay, batch lines name the sample, and the held progress never moves back. The panel draws a bar only for progress evidence, so a bridged row shows none (Phase 2.11 U30 W4 ruling). |
| UX 4 | End of run, failure and cancel. Results open from the tracked folder, a result shows in the sidebar only when complete, a failure alert names the step that failed and the next thing to try, with the log tail behind View Log, a cancel reads Cancelled with no alert, and Copy CLI Command replays into a new folder where the operation records one. |
| UX 5 | Inspector and Provenance tab. New rows appear in Copy text and VoiceOver order, a derived value reads Not recorded, older records display unchanged, and every display fixture diff is read line by line. |
| UX 6 | No silent writes. Reading or displaying writes nothing (hash before and after), and nothing is written into a bundle or a read-only project. |
| UX 7 | Words. New strings use sentence case and plain words under the prose rules, release notes name each change a user can see, and `docs/user-manual/features.yaml` is updated. |
| UX 8 | No silent outcomes. A row reads Completed only when its outputs exist where the person will look, every refusal or failed save shows words in view, and a refusal of user input passed on the real files users feed it. A failure or refusal with no words is an S2 finding. |
| QA 1 | Freeze first, for scientific output only. A pin or freeze commit of scientific output passes at its base with the run shown, changes no file under `Sources`, and lands before the behaviour it pins, with BIO's word that the behaviour is right. A defect fix shows its test failing at the base. |
| QA 2 | Behaviour, not source text. Assertions read outputs, records, events or labels, and the `source-text-assertions` ratchet does not rise. |
| QA 3 | Tiers and tools. A real-tool test sits in the tier its class name selects, gates on `ToolAvailability` and never on a bare `XCTSkip`, and ran once with `LUNGFISH_REQUIRE_TOOLS=1` with no skip. The gate, the test catalog and the tier tests change only when the brief says so. |
| QA 4 | Terminal states. Success, a degraded result, failure and cancel each end with the exit code, status and row the decisions set, through the real transport. |
| QA 5 | Goldens and contracts. Each changed key has a prediction row, the compare is clean at the base, one capture commit names the CLI build commit, no run-varying key is unmasked, and contract counts move by exactly the converted leaves. |
| QA 6 | Determinism. Tests use `--threads 1`, `TestTempDirectory` and 30-second process waits with an explicit timeout, write nothing to `UserDefaults.standard`, and leave every ratchet flat. |
| QA 7 | Release and signing. Package, push, `release.py setup` and `publish` run in the order of `docs/contracts/VERIFICATION-ORDER.md` on the release Mac of `docs/contracts/MACHINES.md`, and a change to signing, notarization or the Sparkle feed follows `docs/development/developer-id.md` and is checked on a packaged build. |
| QA 8 | GUI. The XCUI smoke ran on the packaged candidate in a session that does not lock, with no skip, and a new bundle kind joined the view-switch test. |

## Spawning an expert

Each expert task runs in a fresh agent, on Opus at effort xhigh for inventories, memos and rulings (`model: "opus"`,
`effort: "xhigh"`), on Opus at effort max for votes, and on Sonnet at effort max for reviews (`model: "sonnet"`,
`effort: "max"`), as the efficiency contract's Model choice row sets from the two tests of 2026-10-15. It is briefed
with files and
never resumed, as the efficiency contract's rule on fresh agents sets. Its memory is its field's inventory, memo and
reviews in `SCR` within a session, and the plan's decisions across sessions. A shared brief per stage holds what every
expert needs, and the prompt adds the role. The spawn sets the model and the effort, and the prompt's first line states
them, as the efficiency contract's row on model and effort sets. An expert's report opens with the model and effort it
ran at, and any lane, fix, landing, check or fact-check it calls for names the agent type, model and effort.

```text
You run as lge-expert on <model> at effort <level>.
You are the <FIELD NAME> expert of the LGE panel for <SESSION>, field <FIELD>, letter <L>.
Your remit and checklist are in docs/contracts/EXPERT-PANEL.md, and the shared brief is <SCR>/briefs/<STAGE>.md.
Your task is <the inventory | the memo | the review of lane <LANE> | a ruling on <QUESTION>>.
Read the brief, then the panel decisions of <PLAN> and the backlog rows it names, then only what the task needs.
The code is <WORKTREE> at <FULL COMMIT HASH>, read only. Cite each fact as path and line at that commit.
Write only <OUTPUT FILE>. Do not edit, build, commit or start agents.
Name the agent type, model and effort of every lane, fix, landing, check or fact-check you call for.
End with a final message of at most <N> words that names the file you wrote and any open question ids.
```
