# Scope and delivery

This contract sets which work a Lungfish Genome Explorer (LGE) phase takes on, when that work stops, and how its results
reach users. Read it before planning or briefing any phase, sub-phase or lane. It comes from the independent audit of
Phases 1 and 2 of 2026-10-26 (`docs/reports/2026-10-26-phase-1-2-audit/SUMMARY.md`). Two teams of outside experts ran
that audit on the records, the code and the measured spend, blind to each other and to the expert panel. Where another
contract or a recorded panel decision disagrees with this one, this one holds. The last table names the decisions it
replaces.

## Why it exists

Phases 1 and 2 ran 23 days, inside the five weeks the program plan gave them, but the seven planned Phase 2 tasks
became 14 sub-phases. Both teams judged about a third of the measured $12,904 essential, a third defensible and a third
of low value. Sub-phases 2.10 to 2.13 cost $5,844, more than the planned work of 2.2 to 2.9. Most of that went to CLI
commands for viewer exports and clipboard actions, hidden route keys shipped and deleted a release later, and zero
counts that a literal exit asked for.

No Stable release shipped in the program. The primer trim that cut every primer-led read to nothing was fixed on
2026-10-04 (`7b6fa7933`), yet Stable `v2026.9.78` still runs it. Walks of the packaged app found all 13 Stable blockers
for under 5% of the spend, and about 8,400 new test functions found none of them.

## Stable comes first

| Rule | What it means |
|---|---|
| Stable on a clock | Stable ships at least every 14 days while a fix waits for it. A Preview with no open S1 or S2 finding is promoted within seven days of its packaged walk. |
| Result fixes reach Stable fast | A fix that changes a scientific result or stops data loss reaches Stable within seven days. It goes by promotion, or by a patch release from the last Stable tag when the next Preview is not ready. |
| A phase never holds Stable | No phase exit, sub-phase or refactor holds a Stable release. Only an open S1 or S2 finding does. |
| A short owner check list | The Stable check list holds at most 20 rows. Each is a task a person does in about two minutes that no automated test covers, and a row that an automated test comes to cover is deleted. |
| Previews carry something | A Preview ships when it carries a change a user can see or a result fix, after a person walks the changed screens on the packaged build. A sub-phase with neither ends at a green unit tier on `main` and publishes nothing. No Preview ships on a walk substitute, and no weekly cap applies, since the daily Previews of 2026-10-03 to 2026-10-08 each carried result fixes. |

## Plans have an outcome and a budget

| Rule | What it means |
|---|---|
| Plan shape | A phase plan states the user outcome, a budget in sessions and dollars, and at most six exit checks that one command or one walk answers. It holds scope, checks, budget and decisions in at most 300 lines. Records, rulings, votes and lane reports stay in `~/lungfish-phase-records/`. |
| Exits name outcomes | Every phase exit names a user outcome and a Stable release. A structural count, such as a ratchet at zero, is reported at exit and is never an exit check by itself. A zero target may carry an exemption list that the owner approves once. |
| Budgets stop work | At one and a half times its budget a session starts no new lane until the owner answers. When a check fails late or the budget runs out, the owner moves or waives the check. No session adds a sub-phase on its own. |
| Process work stays small | Trials of the process itself, such as model and effort tests, take at most 2% of a phase budget. A session's monitor proposes changes to a process contract, and the owner accepts them. |

## Which work earns a lane

A row becomes a lane only when its work does one of these.

- It changes a scientific result or fixes a wrong one.
- It stops data loss, a crash or a hang.
- It fixes something a user or a walk met.
- It builds what the phase's user outcome names.
- It fixes the cause of an S1 or S2 finding that a user, a walk or a BIO ruling traced to the code the lane changes.

Every other row goes to the backlog, an edge case that nobody has met included.

| Rule | What it means |
|---|---|
| One backlog | Open rows live in `docs/plans/BACKLOG.md`, each with its effect on results or users. The owner ranks it once a phase. A row left unscheduled for two phases closes unless it changes results, loses data or crashes. A plan holds only its own rows and no Moved out table. |
| Severity, not votes | Each finding gets a severity from the table below. BIO sets it for anything that touches a scientific number, and no vote lowers an S1. UX sets it for everything else, and the owner settles a dispute. S1 and S2 block Stable. S3 and S4 go to the backlog with no vote. |
| Bounded reviews | A lane review returns its blockers and at most three should-fix items. A blocker is a wrong result, data loss, a crash, a security hole, a broken build, an S1 or S2 finding or an unmet requirement of the brief. Every other finding goes to the backlog. |
| Upstream defects | A defect inside a third-party tool gets a retry where one helps and a Known limit, not a study. A Known limit that the app reports in words is not an open S1 or S2 finding. |

| Severity | Meaning |
|---|---|
| S1 | A false number, a silently wrong result, silent data loss or a crash of the app |
| S2 | A common task fails, or a failure or refusal shows no words |
| S3 | A rare task fails, or words mislead without changing a result |
| S4 | Appearance only |

## What tests and goldens hold

| Rule | What it means |
|---|---|
| Science is pinned byte for byte | Byte goldens cover scientific payloads (reads, alignments, counts, calls and sorted tables) and the record facts of the methods minimum. A scientific golden moves only with a BIO note that names the change. |
| Everything else is checked by meaning | Help text gets a parse test and the CLI event stream a schema test, not byte captures. Words a person reads may change when the change makes them clearer. A pin of wording, layout or source text goes when the move it guarded lands. |
| Pins before a change are for science | Old behaviour is pinned before a change only when it is scientific output. A science pin needs BIO's word that the pinned behaviour is right, since `38ae07de8` pinned a broken pooled mapping for nine days. |
| Each science fix adds an input | A fixed science defect adds its smallest failing input, with the numbers taken from the tool run directly. |
| GUI checks bind the candidate | Every final candidate runs the XCUI smoke on the packaged app in a session that does not lock, and its result binds like the unit tier. A candidate whose XCUI or Accessibility tests skipped is not a candidate. A new bundle kind joins the view-switch test in the change that adds it. |
| Load-sensitive waits | `docs/contracts/VERIFICATION-ORDER.md` sets how a red tier of timed-out waits is handled. No lane raises the wait of one test. |
| Tests per family | A family of commands takes one argv round trip, one replay and one cancel test. A new route in the family adds a case to them and not a new set. |
| Help text until HELP-GOLDENS | Until that backlog row lands, a lane that changes help text recaptures only the help files it changed. |

## What the app must do

| Area | Rule |
|---|---|
| CLI equivalence | An operation that makes or changes scientific data records a `lungfish-cli` command that reproduces it, as `docs/contracts/CLI-EQUIVALENCE.md` sets. An export, a figure, a copy, a clipboard action or a share needs no command of its own. |
| Provenance | A record is complete at the methods minimum of `docs/contracts/RECORDING-PROVENANCE.md`. Database identity for EsViritu, TaxTriage and NAO-MGS comes before any other record work. |
| Route moves | No route flips behind a hidden key. A route moves when a test that drives the app shows its result in the sidebar or viewer, and the old route goes in the same change. Without such a test the old route stays until the next packaged walk has driven the new one. |
| Words and outcomes | A row reads Completed only when its outputs exist where the person will look. Every refusal and failure shows words that say what happened and what to try next. A lane may improve any such words, and the UX reviewer reads them. |
| Refusals | A change that refuses user input lands only after it passes on the real files users feed it, such as the official database archives. |
| Tool run time | An analysis tool has no wall-clock limit by default. A limit is a named option recorded in the run, and a watchdog that stops a run says why. |

## Documents stay small

| Document | Rule |
|---|---|
| Contracts | From Phase 3.0 on, a new contract stays under 20 KB, and a phase that edits a longer one leaves it shorter. A contract states the rules in force and the code that shows them, and dated history goes to the records. Ten contracts were over 20 KB when the audit closed, and backlog row CONTRACT-TRIM brings them under, the largest first. |
| Release notes | The notes stay under 15,000 characters and are written for bench scientists (owner direction O26). The technical record and the owner check list are separate files in `docs/reports/`. |
| Agent docs | A row of an `AGENTS.md` file that a phase makes false is fixed in that phase. |
| Generated files | The module map holds no line counts, so a lane regenerates it only when it adds, removes or renames a target, a public type or a folder. A ratchet whose count falls writes its own lower baseline. Until backlog row GEN-MAP lands, the current check still fails on a changed line count. |

## Decisions this contract replaces

| Decision | Where it was recorded | Replaced by |
|---|---|---|
| T8, an owner check list blocks Stable and a locked-screen substitute stands in for the walk | `docs/plans/2026-10-11-phase-2-7.md` | Stable comes first |
| Every sub-phase ends with a Preview, the owner directive of 2026-10-05 | `docs/plans/2026-10-02-architecture-program.md` | Previews carry something |
| O2 of 2026-10-17, the exit read literally with no exemption list | `docs/plans/2026-10-17-phase-2-12.md` | Exits name outcomes |
| A route key ships and goes one release later (2.10 C4, 2.12 R-A1) | `docs/plans/2026-10-02-architecture-program.md` | Route moves |
| O5 of 2026-10-17, every viewer export gets a row and a command | `docs/plans/2026-10-17-phase-2-12.md` | CLI equivalence |
| G1, a family lane pins today's behaviour first | `docs/plans/2026-10-13-phase-2-10.md` | Pins before a change are for science |
| O35, the experts replace the owner in the check list by consensus | `docs/plans/2026-10-23-phase-2-14.md` | A short owner check list, and Severity, not votes |
| No golden and no cli-help capture moves in any Phase 3 commit, and row texts are frozen in 3.1 | `docs/plans/2026-10-02-architecture-program.md` | Everything else is checked by meaning |

The panel's place in a session and the monitor's checkpoints changed with this contract too, in
`docs/contracts/EXPERT-PANEL.md` and `docs/contracts/RUNNING-A-PHASE-SESSION.md`. Both reverse owner directions of
2026-10-11 and 2026-10-15, and the owner accepted that by putting this contract on `main`.
