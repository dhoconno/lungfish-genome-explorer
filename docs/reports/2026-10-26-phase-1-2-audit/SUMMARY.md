# Audit of Phases 1 and 2, executive summary

For the owner of Lungfish Genome Explorer (LGE), 2026-10-26, at origin/main `ca9091af1`.

## How the audit ran

Two independent teams audited Phases 1 and 2. Each team had three seats and a chair. The seats were engineering and
architecture, bioinformatics and the LGE domain, and GUI and UX. Team A worked from the records first, which means the
plans, owner directions, panel memos, votes and monitor logs. Team B worked from the artifacts first, which means 5,084
commits, the code and tests at head, and the release notes. Neither team saw the other's work, and neither belonged to
or deferred to the project's expert panel. Both read a shared pack of measured facts, including a ledger of all 40
sessions on the release Mac since 2026-10-07 ($12,904).

Each chair checked the five claims its report leaned on most, and four claims were corrected or dropped. A fresh reviewer then read the contract changes against both reports, and its 15 fixes are applied. The audit cost about $65 by the same ledger. The full
reports are `TEAM-A.md` and `TEAM-B.md` beside this file. The six seat memos, the evidence pack and the spend data are in
`~/lungfish-phase-records/audit-2026-10-26/`.

## The answer

Phase 2's length was partly warranted. It was not slow. Phases 1 and 2 took 23 days, inside the five weeks the plan of
2026-10-02 gave them. It was big. Seven planned Phase 2 tasks became 14 sub-phases, and four of them, 2.10 to 2.13,
cost $5,844. That is 45% of measured spend, and more than the planned work of 2.2 to 2.9 ($5,285).

The excess came mostly from scope rules and from process, not from fussing over small bugs. Three answers of 2026-10-17
set the tail. They read the exit criteria literally, gave every viewer export a CLI command, and ended Phase 2 without a
Stable. A review machine then turned each finding into a carried row, with 848 requested fixes in 196 review verdicts
and Moved out rows growing from 16 to 107 a plan. Detail was worth its cost through about 2.9 (2026-10-12), while each
Preview fixed results. After that most attention went to export parity, record form, pins and process.

The sharpest finding is that no Stable release shipped. Stable is still `v2026.9.78`, the program's base commit
`1f70a13ea`. A Stable user still loses every read that starts with a primer, because primer removal there runs bbduk
with `ktrim=r`. That defect was fixed on 2026-10-04 (`7b6fa7933`). The same holds for Kraken2 counting mates as reads
and the other early science fixes.

| Split of measured spend | Essential | Defensible | Low value |
|---|---|---|---|
| Team A, records first | 34% | 34% | 32% |
| Team B, artifacts first | 30% | 35% | 35% |
| Range across the six seats | 22% to 40% | 28% to 38% | 28% to 40% |

Each split is within about 10 points. Essential means work users need for correct results and a reliable app. That
covers the early science fixes, one process primitive, one provenance writer, the classifier executor and the walks.
Low value means viewer-export parity, the hidden-key cycle, pins of incidental bytes, panel and Preview ceremony at every
sub-phase, and raising test waits one at a time. The laptop sessions of Phase 1 to 2.1 are not in the ledger. They were
the most science-dense part, so the Essential share of the whole program is likely a few points higher.

## Numbers that framed the audit

| Measure | Value |
|---|---|
| Measured spend | $12,904 in 40 sessions on the release Mac, 2026-10-07 to 2026-10-26. Team B puts the unmeasured laptop sessions at about $3,800 more |
| Spend by role | Lane agents 34%, reviews 17%, manager 16%, panel design 10%, other 6%, fixes 5%, landings 3%, monitor 3%, rulings 2%, walks 2% |
| Releases | 24 Previews and no Stable, against 16 Stables among the 98 releases of August and September |
| Tests | Test functions rose from 17,766 to 26,164, and test Swift lines now outnumber source lines. XCUI held 40 tests at base and head |
| Who found the Stable blockers | GUI walks found all 13 for about 2% to 5% of spend. No test and no review found any of them |
| Paperwork | Contracts grew from about 60 KB to 427 KB and plans from 123 KB to 1.88 MB |

## What went well

1. Phases 1, 1.5 and 2.1 fixed results quickly. Kraken2 counts a pair as one fragment, primer removal keeps primer-led
   reads, merged reads no longer pair with R1, non-Illumina reads import with their platform, and 12S counts no read
   twice. Team B counts about 45 fixes that changed results from 2026-10-02 to 2026-10-10.
2. The structural goals of R3, R7 and R8 were met. `Process()` went from 79 files to none outside the process
   primitive, a cancel stops the whole tool tree, provenance writers went from 25 to one, and records name real tool
   versions. The classifiers run through the CLI on one executor, which the CHTC Linux route then reused.
3. Pinning science before moving code caught real defects, such as zero-read rows counted toward MHC calls in 2.3.
4. The walks were the best-value testing of the program. Release engineering held through 24 notarized Previews and a
   certificate change.
5. Spend was measured, which made this audit possible. Direct cost per landed lane fell from $13 to $24 in 2.7 to 2.10
   to $5 to $15 in 2.11 to 2.14.

## What went poorly

1. No Stable shipped, so users on Stable received none of the fixes.
2. Scope grew in small unpriced steps. The literal exit created 2.13, the walk created 2.14, and nine plans moved out
   446 rows.
3. CLI parity outran its purpose. Exports, figures, clipboard actions and copies got CLI commands, parity classes and
   replays, and the moves made Stable blockers. OBS-W7 is a mapping figure without its mismatch marks, and OBS-W8 is a
   dropped ZIP that was lost while its row read Completed.
4. Tests pinned incidental detail and missed what users met. 241 commits kept help text, event logs and record shapes
   byte-identical, against 69 on scientific fixtures. GUI automation stood still, and the `ui` test profile names a
   script that never existed, so no GUI test ran in any gate.
5. Review and panel ceremony cost more than it returned. Reviews, panel design, rulings and the monitor cost about
   $4,100, about 85% of vote margins were unanimous, and about one review fix in six touched a defect a user could
   meet. BIO review was the exception and earned its place.

## The rabbit holes

Ranked by rough cost. The rows overlap, so they do not add up.

| Rabbit hole | Kind | Rough cost | Rule that would have stopped it |
|---|---|---|---|
| CLI commands, parity classes and replays for exports, figures, copies and clipboard actions | Scope | About $2,000 | CLI equivalence for scientific data only |
| Five-expert panel and per-field review of every lane | Process | About $3,800 by role, part of it well spent | Panel at plan and exit, one bounded reviewer a lane |
| Help text, event logs and record shapes kept byte-identical, with six masks | Tests | About $1,000 to $1,500 | Byte goldens for science only |
| Hidden route keys shipped and deleted a Preview later, and a literal exit | Scope | About $750 of 2.13, and the reason 2.13 existed | Exits name outcomes, and no route key is published |
| Test waits raised one test at a time under load | Flaky tests | About $400 to $900, and three of 2.12's four candidate fix rounds | A quiet gate, one rerun for timed-out waits, a quarantine list |
| Provenance form, such as signing everywhere and the recorded app name | Edge cases | About $340 to $800 | Records stop at the methods minimum |
| Release notes and an owner check list kept as full records | Process | About $400 to $580 | Notes for scientists, a check list of 20 rows |
| Module map and baseline commits after nearly every lane | Process | 397 commits | No line counts in the map |
| Edge cases nobody met, such as 255-byte temp names and a 1e-16 digit put to a five-expert vote | Edge cases | Disputed, from under $100 to $1,450 | A row earns a lane only when it changes results, loses data or was met |

## Where effort went

| Theme | Verdict | What changes |
|---|---|---|
| CLI parity beyond analyses | Over | Only operations that make or change scientific data record a command |
| Provenance record form | Over | Stop at a methods minimum, and add database identity for every classifier |
| Pins and goldens of output that is not science | Over | Science byte goldens stay, and help text and events get parse and schema tests |
| Process governance and release ceremony | Over | Panel at plan and exit, one monitor run a session, Previews only with something to show |
| Stable releases | Under, the most | Stable on a clock, before any Phase 3 refactor |
| Automated GUI checks and packaged walks | Under | An XCUI smoke and a view-switch test bind every candidate |
| The surface contract (R1) and RNA-seq groundwork (R17) | Under | The core of Phase 3, with RNA-seq groundwork beside it |
| Database identity, truth sets and large samples | Under | Database identity in 3.1, and no default wall-clock limit on tools (a 3,600 s default stopped EsViritu) |
| Words people read when something fails | Under | One alert presenter, and a failure with no words is an S2 finding |

## Phase 3, rescoped

Both teams say Phase 3 should not run as planned. Its six sub-phases would migrate about 20 viewports, cost about
$4,000 to $9,000 and two to three weeks, and give users no new capability while R17 and Stable wait. Its core is right,
because one viewport slot ends the stale-view class behind about five of the 13 Stable blockers. The plan in
`docs/plans/2026-10-02-architecture-program.md` now reads as below.

| Sub-phase | Content | Budget |
|---|---|---|
| 3.0 Stable | The five Stable blockers and obs-22, a working `ui` profile with an XCUI smoke, a check list of at most 20 rows, and a packaged walk with you at the Mac, then Stable. Science rows that touch no viewer file run beside them | 1 session, about $500 |
| 3.1 Quality net and classifier core | A view-switch test for every kind, one alert presenter and database identity for three classifiers. Then the viewport host and registry with the classifier views and their shared actions. Ends with a Stable | 2 sessions, about $2,500 |
| 3.2 RNA-seq groundwork, beside 3.1 | The reference index cache, annotation input checks, the count matrix with strandedness, and empty RNA-seq targets | 1 session, about $800 |
| Deferred | The other eleven viewport migrations, and the typed event layer and launcher beyond what new work needs | Until user work touches them |

Phase 3 ends when six checks pass. Two Stables ship no more than 14 days apart. No S1 or S2 finding is open. The XCUI
smoke and the view-switch tests pass on the packaged app. A stub surface opens with no App edit and the classifiers
share one action component. Every classifier records its database. The RNA-seq groundwork has landed. The budget is four
sessions, about $3,800, with a stop for your decision at $5,700.

## What changed in the contracts

Everything is on branch `audit/phase-1-2` and is not pushed.

| File | Change |
|---|---|
| `docs/contracts/SCOPE-AND-DELIVERY.md`, new | Stable at least every 14 days and result fixes within seven, Previews only with a visible change or result fix after a packaged walk, plans with an outcome, a budget and at most six exit checks, which rows earn a lane, one backlog, severities S1 to S4 in place of votes, bounded reviews, byte goldens for science only, and the decisions it replaces |
| `docs/contracts/EXPERT-PANEL.md` | The panel sets scope when a phase is planned and reviews its exit. One reviewer a lane, BIO on every science lane, blockers and at most three should-fix items. Words people read may improve, a new check UX 8 bans silent outcomes, and QA 8 adds the XCUI smoke |
| `docs/contracts/RUNNING-A-PHASE-SESSION.md` | The monitor runs once at the end with a 45-minute heartbeat between, findings go to the backlog, and the monitor proposes contract changes for you to accept |
| `docs/contracts/VERIFICATION-ORDER.md` | The XCUI smoke and a walk of the packaged build on a realistic corpus before a publish, no walk substitute, a quiet gate, one rerun of the unit tier when only timed-out waits failed, a quarantine list, and the steps of a Stable promotion |
| `docs/contracts/CLI-EQUIVALENCE.md` | A recorded command only for operations that make or change scientific data, and no new masks |
| `docs/contracts/RECORDING-PROVENANCE.md` | Record work stops at a methods minimum, with classifier database identity first |
| The program plan and `docs/plans/BACKLOG.md` (new) | The Phase 3 rescope with its outcome, budget and exit checks, a note on Phase 4, and the backlog seed with the rows 3.0 takes |
| `.claude/agents/llm-efficiency-monitor.md`, `CLAUDE-CODE-PRACTICES.md`, `ADDING-AN-OPERATION.md`, `RUNNING-A-TOOL.md`, the surface checklist, `AGENTS.md`, the contract index and three module guides | The same rules where these files said the opposite, and two stale rows about `Process()` |

## Decisions for you

1. Accept the rescope and the contract changes, then push the branch. Two changes reverse your own directions. The
   panel no longer leads every session (2026-10-11), and the monitor no longer runs at every checkpoint (2026-10-11 and
   2026-10-15). Both teams recommended this, and Team B noted that it needs your word.
2. Choose the aligner, quantifier and DE engine for RNA-seq. The question has been open since 2026-10-02 and 3.2 needs
   the answer.
3. Rank the backlog once 3.0 has moved the carry-in rows into it.
4. Decide whether to keep the LLM measurement contracts, `LLM-EVIDENCE.md` and `CLAUDE-CODE-PRACTICES.md` with its
   weekly check. One seat would retire them, and both teams left the call to you.

## Where the teams disagreed

- Team B's GUI seat holds that the length was not warranted by what users received. Both chairs say partly, since the
  calendar held and the early science was essential.
- Team B's engineering seat would split LungfishWorkflow (Phase 4d) before RNA-seq, and both science seats would run a
  science session before any viewport code. The rescoped plan runs science lanes beside 3.0 and the RNA-seq groundwork
  beside 3.1 instead.
- On Stable timing, Team A asked for promotion within seven days of a walk, and Team B for a Stable at least every 14
  days with result fixes within three working days. The contract takes 14 days for the clock and seven for result
  fixes.

## Limits

- The laptop sessions of Phase 1 to 2.1 are not measured.
- The splits are judgment, within about 10 points, and commit classes come from keyword matches and samples.
- Nobody ran tests or the app. If reviews stopped bad lanes before they landed, the review waste is overstated.
- Nobody knows how many labs run Stable rather than Preview. If almost all run Preview, the Stable gap costs less.
