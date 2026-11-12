# Scope and delivery

This contract sets which work a Lungfish Genome Explorer (LGE) phase takes on, when that work stops, and how its results
reach users. Read it before planning or briefing any phase, sub-phase or lane. It comes from the independent audit of
Phases 1 and 2 of 2026-10-26 (`docs/reports/2026-10-26-phase-1-2-audit/SUMMARY.md`). Two teams of outside experts ran
that audit on the records, the code and the measured spend, blind to each other and to the expert panel. The review of 2026-11-11
(`docs/reports/2026-11-11-program-review/SUMMARY.md`) added the rules on structural lanes, truth, scale and session
size.

Precedence. The owner's words in chat hold first, then the owner's recorded directions, then this contract, then the
phase plan, then any other contract. An agent definition or a brief that disagrees with a contract is a defect to fix
and not a choice.

## Why it exists

The audit judged about a third of the $12,904 of Phases 1 and 2 essential, a third defensible and a third of low
value, and no Stable release shipped in that program. Walks of the packaged app found all 13 Stable blockers for under
5% of the spend, and about 8,400 new test functions found none of them. The review of Phase 3 found the same pattern.
Wrong numbers and hangs were found by the packaged walk, by BIO measuring against the tool itself and by the owner,
and by no gate. The decisions this contract replaced are listed in
`docs/reports/2026-10-26-phase-1-2-audit/REPLACED-DECISIONS.md`.

## Stable comes first

| Rule | What it means |
|---|---|
| Stable on a clock | Stable ships about once a month, about four weeks after the last Stable, from the newest Preview that passed its packaged walk with no open S1 or S2 finding (owner direction O128). A phase ends in a Preview and not in a Stable, since the Stable loop took longer than a phase could carry. When the date falls inside a phase, the manager promotes that Preview and the phase goes on. A stable release is built only on the owner's word (O159). |
| Result fixes reach a Preview fast | A fix that changes a scientific result or stops data loss reaches a Preview within seven days of landing, and the next monthly Stable carries it. When BIO rules that an S1 live in Stable cannot wait for that Stable, the manager asks the owner for a known-issue line on the Stable's release page and a patch release from the last Stable tag. |
| Known issues reach the Stable page | A Preview that fixes an S1 or S2 living in the last Stable adds its known-issue line to that Stable's release page in the same publish step. |
| A phase never holds Stable | No phase exit, sub-phase or refactor holds a Stable release. Only an open S1 or S2 finding does. |
| A short owner check list | The Stable check list holds at most 20 rows. Each is a task a person does in about two minutes that no automated test covers, and a row that an automated test comes to cover is deleted. A row that needs a person's own senses, such as a real-mouse drag or hearing VoiceOver, does not block a release and runs when the owner is next at the Mac. The list is written new for each release and carries no older list. A walk row left unwalked in two walks running becomes an XCUI test in the next session or closes on UX's or BIO's word. |
| Previews carry something | A Preview ships when it carries a change a user can see or a result fix, after a person, or the manager by computer use, walks the changed screens on the packaged build. A sub-phase with neither ends at a green unit tier on `main` and publishes nothing. No Preview ships on a walk substitute, and no weekly cap applies, since the daily Previews of 2026-10-03 to 2026-10-08 each carried result fixes. |

## The standing go

The owner set these on 2026-11-03 (O126). In 3.1 session 2, 20h43m of 55h33m went to waits for the owner, and every go given was a yes. The rules bind a session only when the owner's start prompt or a message in chat gives the go, since a file cannot authorize a send or a publish.

| Rule | What it means |
|---|---|
| Releases | A session pushes `main` by fast-forward and publishes a Preview with no go in chat, and a stable release once the owner has asked for one, once the gates, the smoke, the packaged walk and the evidence read of `docs/contracts/VERIFICATION-ORDER.md` pass. An open S1 or S2 stops the publish, whoever found it, and a row that reads S1 if reachable gets its ruling first. The manager then reports the release facts and the yank command. |
| Outside services | A send to NCBI or a download from SRA needs no go for the walk clones under `~/LGE-GUI-Walk` and for public test data, and each request ID goes in the event log. Any other data waits for the owner's go, since a send cannot be recalled. |
| Questions never stop work | The manager asks in a plain message and goes on with what does not depend on the answer. An S1 or S2 is fixed by default. When no fix is possible, BIO for a scientific number and UX for the rest may rule it a Known limit with its notes line, and the owner can reverse that. A question with no answer after 15 minutes takes the manager's stated recommendation, the event log says so, and the owner can reverse it. A background wait of 15 minutes wakes the manager when nothing else will. |
| Hung apps | A session ends an LGE app that it launched, by its process id and after one `sample`, when the app has not answered for 10 minutes or its memory footprint passes 20 GB, and logs it. Memory is read as footprint and never as `ps` RSS. |
| What stays the owner's | macOS permission prompts, accepting terms, passwords, the approval of full-screen control and the budget's ask line. |

## Plans have an outcome and a budget

| Rule | What it means |
|---|---|
| Plan shape | A phase plan states the user outcome, a budget in sessions and dollars, and at most six exit checks that one command or one walk answers. It holds scope, checks, budget and decisions in at most 300 lines. Records, rulings, votes and lane reports stay in `~/lungfish-phase-records/`. Every row cites a file and line read at a commit no more than seven days older than the plan. |
| Checks a session can answer | An exit check is answered by one command or by a walk in background control. A check that needs the owner, full-screen control or a live service is an owner list row and never an exit check. A check ends Met or Moved to a named backlog row with its severity. Met with notes is not a state. |
| A computed budget | The budget is the planned lanes times the last phase's all-in cost a landed lane ($24, and $36 for a lane that adds a type, a viewer or a launch), plus $120 a session and $100 a packaged candidate, with two candidates a Preview, and the plan prints the sum. It is also stated in points of the week, and the week points bind. |
| Session size | A session plans at least 12 lanes and starts with at least 35 points of the week free. Fewer lanes run as a short job with no meeting and no monitor, only the ledger command. A session may run two sub-phases back to back with a Preview at each. |
| Exits name outcomes | Every phase exit names a user outcome and the Preview that carries it. A structural count, such as a ratchet at zero, is reported at exit and is never an exit check by itself. A zero target may carry an exemption list that the owner approves once. |
| Budgets stop work | At one and a half times its budget a session starts no new lane until the owner answers. When a check fails late or the budget runs out, the owner moves or waives the check, or an expert rules a Known limit as The standing go sets. No session adds a sub-phase on its own. |
| Process work stays small | Trials of the process itself, such as model and effort tests, take at most 2% of a phase budget. A session's monitor proposes changes to a process contract, and the owner accepts them. |

## Which work earns a lane

A row becomes a lane only when its work does one of these.

- It changes a scientific result or fixes a wrong one.
- It stops data loss, a crash or a hang.
- It fixes something a user or a walk met.
- It builds what the phase's user outcome names.
- It fixes the cause of an S1 or S2 finding that a user, a walk or a BIO ruling traced to the code the lane changes.

A lane of the phase's truth sweep, and a probe of a row whose severity waits on a measurement, earn their place too. Every other row goes to the backlog, an edge case that nobody has met included.

A structural change (a move, a split, a new target, a ratchet lowered) is never a lane of its own. It rides the first lane that a user outcome sends into the code, as that lane's first commits, with `verify_pure_move.py`. A phase outcome cannot name maintenance as its own reason.

| Rule | What it means |
|---|---|
| One backlog | Open rows live in two files, each row with its effect on results or users. `docs/plans/BACKLOG.md` holds at most 80 KB. It opens with a section Results and data that holds every open S1, S2 and probe row, and goes on with the section of the phase now and the section of the next phase. Its header carries a `Phase now` line with the number of the phase now. Every other open row lives in `docs/plans/backlog-later.tsv`, one row a line, with the tab separated columns id, severity, field, effect, source, phase_filed and keep, and no agent reads that file whole. A review files a row only for an S1, an S2, or an S3 that names what a person sees. An S4 finding and an edge case nobody met stay in the review file. A row that is done is deleted in the landing that closes it, and that commit is its record. At each phase close a row left unscheduled for two phases closes unless it changes results, loses data, crashes or hangs, and `keep` records which of results, data, crash or hang protects a later row. `scripts/checks/backlog.py` holds the caps and these rules, and the pre-push hook runs it. A plan holds only its own rows and no Moved out table. |
| Severity, not votes | Each finding gets a severity from the table below. BIO sets it for anything that touches a scientific number, and no vote lowers an S1. UX sets it for everything else, and the owner settles a dispute. S1 and S2 block Stable. S3 and S4 go to the backlog with no vote. A rating that depends on a measurement is written `S? probe`. The next phase runs its probe in a lane of at most 40 calls, or BIO rates the row as if the condition holds, and no row keeps `S? probe` for two phases. |
| Bounded reviews | A lane review returns its blockers and at most three should-fix items. A blocker is a wrong result, data loss, a crash, a security hole, a broken build, an S1 or S2 finding or an unmet requirement of the brief. Every other finding goes to the backlog. A lane gets one review from the field it changes most, and BIO's when a number, a file a scientist exports or a record changes, and never more than two unless a ruling names the risk. A commit that prints `PURE-MOVE OK` gets no review by an agent. ARCH reviews no single lane and reads once a wave any commit that edits `Package.swift` or widens access. UX reads a session's new words in one read at the notes step. |
| Upstream defects | A defect inside a third-party tool gets a retry where one helps and a Known limit, not a study. A Known limit that the app reports in words is not an open S1 or S2 finding. |
| Live services | The app treats a third-party service as one that can stall at any time. A test, gate or walk row never counts on how fast such a service answers, or on which of several equally right records it returns. Those paths are tested on a stand-in with faults on demand. A live call in a walk is a smoke: any honest ending passes, and its time is reported (O138). |

| Severity | Meaning |
|---|---|
| S1 | A false number, a silently wrong result, silent data loss, or a crash, a hang or a memory run-away of the app |
| S2 | A common task fails, a run on an input of ordinary size ends for memory or time, or a failure or refusal shows no words |
| S3 | A rare task fails, or words mislead without changing a result |
| S4 | Appearance only |

Ordinary sizes are 20 M read pairs, 20,000 FASTA records, a reference of 3,000 sequences and 96 samples, until the owner sets others from the lab's runs. A new result kind is probed at them before its Preview.

## What tests and goldens hold

| Rule | What it means |
|---|---|
| Science is pinned byte for byte | Byte goldens cover scientific payloads (reads, alignments, counts, calls and sorted tables) and the record facts of the methods minimum. A scientific golden moves only with a BIO note that names the change. |
| Everything else is checked by meaning | Help text gets a parse test and the CLI event stream a schema test, not byte captures. Words a person reads may change when the change makes them clearer. A pin of wording, layout or source text goes when the move it guarded lands. |
| Pins before a change are for science | Old behaviour is pinned before a change only when it is scientific output. A science pin needs BIO's word that the pinned behaviour is right, since `38ae07de8` pinned a broken pooled mapping for nine days. |
| Truth probes | Every operation family that makes a scientific number has one probe, namely a small public input, the number LGE reports through `lungfish-cli`, and the same number from the tool run directly or from an independent count. BIO owns the list, and a new operation lands with its probe. A comparison of the screen with `lungfish-cli` is a display check and not a truth check. |
| The truth sweep | Each phase BIO names two tool families that no lane read in the last two phases. One lane a family runs the tool by hand on a real public data set with real-shaped inputs and compares every number the app shows and exports with the tool's own files. Each difference is a finding with its severity. |
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
| Affected results | Each fix of an S1 that an earlier build wrote into a result adds one row to a table in the app (result kind, builds, one sentence, what to do). A result whose record names such a build shows that sentence in its viewer and Inspector until it is redone. The rule binds once lane AFFECTED of the trust session lands. |
| Tool run time | An analysis tool has no wall-clock limit by default. A limit is a named option recorded in the run, and a watchdog that stops a run says why. |

## Documents stay small

| Document | Rule |
|---|---|
| Contracts | From Phase 3.0 on, a new contract stays under 20 KB, and a phase that edits a longer one leaves it shorter. A contract states the rules in force and the code that shows them, and dated history goes to the records. Ten contracts were over 20 KB when the audit closed, and backlog row CONTRACT-TRIM brings them under, the largest first. |
| Release notes | The notes stay under 15,000 characters and are written for bench scientists (owner direction O26). The technical record and the owner check list are separate files in `docs/reports/`. |
| Technical record | At most 15 KB, with the release facts, the landed ranges, the S1 and S2 results, the limits added and what stays open, and paths into the records. One documentation lane writes it after the publish. A change of documents after the walked package lands after the tag and never causes a new package. |
| File sizes | A new Swift file over 800 lines fails. A baselined file that grows in a fix or rider lane does not fail the lane, since the landing raises its row in the batch's fold commit and names the lane, with `scripts/ratchets/file-size.sh --raise <path> --lane <LANE-ID>`, which prints the line `<path> <old> -> <new> <LANE-ID>` for the commit message and changes no other row. No commit removes blank lines or joins lines to hold a count, and `scripts/ratchets/file-size.sh --range <base>..<head>` fails and names any commit in the range whose only change to a baselined Swift file is removed blank lines or joined lines. |
| Agent docs | A row of an `AGENTS.md` file that a phase makes false is fixed in that phase. |
| Generated files | The module map holds no line counts, so a lane regenerates it only when it adds, removes or renames a target, a public type or a folder. A ratchet whose count falls writes its own lower baseline. |
