# Team A report. Audit of Phases 1 and 2 of the Lungfish Genome Explorer program

Audit Team A, 2026-10-26, synthesizing seats A1 (engineering), A2 (science) and A3 (GUI and product) at `ca9091af1`.
Dollars are the galah ledger ($12,904, 40 sessions), which misses the laptop-era Phase 1 to 2.1. Brackets name the
seats behind a point. Two of five spot-checked claims were corrected.

## Team verdict

Phase 2's length was partly warranted. The part that was not came less from attention to minor bugs than from scope
rules that turned structural goals into literal zero targets, and from a process that turned every finding into a
carried row.

Phase 2 ran 2026-10-05 to 2026-10-24, inside the plan's own "weeks 3 to 5", but as 14 sub-phases where the plan had
seven tasks. The planned work (2.2 to 2.9) cost about $5.3K. The tail (2.10 to 2.13) cost $5.84K, 45% of all
measured spend, mostly on CLI commands for every in-process action and viewer export, hidden route keys built to be
deleted one release later, and the last system-tool spawns. Three owner answers of 2026-10-17 set that tail ("No,
Preview only.", "Literal, 2.12 + 2.13.", "Yes, close them in Phase 2."). Reviews then asked for 848 fixes in 196
verdicts, and Moved out rows rose from 16 to 107.

**Team split of the $12.2K Phase 2 spend on galah. Essential 34%, Defensible 34%, Low value 32%**, each plus or minus
10 points. Essential is the result-changing science fixes, the process primitive, one executor, one provenance writer
and the walks. Defensible is the registry, CLIEvent v2, the Operations target and CLI commands for scientific
operations. Low value is viewer-export parity, the key cycle, the per-sub-phase panel and Preview ceremony, and
per-test wait patching.

The sharpest fact is that none of the science fixes reached a Stable user. Stable is still the program's base commit.

## What went well

1. **Phase 1 and 1.5 were fast and fixed real results** [A1, A2]. 641 commits in four days took R4's 58 `start()`
   sites to 0. 1.5 and 2.1 fixed defects that change published numbers (primer removal to `ktrim=l` in `7b6fa7933`,
   Kraken2 pairs as fragments, mate-aware demultiplexing, 12S counting), and the notes gave the size of each change
   (`docs/release-notes/2026.10.9.md`).
2. **Science was pinned before code moved** [A1, A2]. Goldens and genotype suites preceded the risky moves, so 2.6
   recaptured 43 files predicted key by key. 2.3 fixed three MHC defects for about $650
   (`docs/plans/2026-10-09-phase-2-3.md:74-150`).
3. **One process primitive** [A1, A3]. Files creating `Process()` fell from 77 to 0 outside
   `Sources/LungfishCore/Process/`. Cancel now kills the whole tree, Nextflow and Java children included.
4. **GUI and CLI run the same code** [A1, A2]. `NativeToolRunner` in LungfishApp went from 10 files to 0, and the
   CHTC Linux route reused `AnalysisRunExecutor` and matched the Mac on three public runs (`chtc-c5-outcome.md`).
5. **One provenance writer with correct methods facts** [A1, A2]. `write_provenance_functions` went from 25 to 0, and
   records now carry real tool versions (`docs/release-notes/2026.10.15.md`).
6. **Walks found what thousands of tests missed, cheaply** [all]. For $443 to $600 they found about 13 Stable blockers
   and defects older than the program, such as EsViritu identity 0.997 shown as 1.0% since `2d1638f00` (March) and
   pooled mapping that dropped inputs (fixed `208aa71c0`).
7. **Release engineering held** [A3]. 24 notarized Previews, a certificate change, a working Sparkle update and a
   first-try 2.14 publish. O26 cut the notes from 111,565 to about 10,700 characters.
8. **Spend was measured and acted on** [A1]. Effort round 1 moved roles from max to xhigh, and the median direct cost
   per landed lane fell from $13 to $24 (2.7 to 2.10) to $4.93 (2.14) (`RUNNING-A-PHASE-SESSION.md:171-180`).

## What went poorly

1. **No Stable shipped, so users got none of the fixes** [all]. `v2026.9.78` is `1f70a13ea`, the program's base
   commit, and every October note still names it (`docs/release-notes/2026.10.24.md:7`). Its primer removal runs
   bbduk with `ktrim=r`, and it still has F9, the EsViritu identity bug and row 69. No plan considered a patch.
2. **The top finding and the goal are untouched** [A1, A2]. R1 (surface contract) and R17 (RNA-seq prerequisites)
   have no code after 25 days, and no plan from 2.2 to 2.14 mentions RNA-seq. Unscheduled debt grew. LungfishWorkflow
   went from 214,607 to 272,551 lines and `Notification.Name(` declarations from 81 to 118.
3. **The tail made user-visible regressions** [A3]. At least four of the 13 Stable blockers came from program commits,
   row 20 (`d7cb1ac8e`), obs-11 and OBS-W7 (`3cdd9d951`, `71ea2107a`, figures without mismatch marks) and OBS-W8
   (`e1f1eb03c`, a dropped ZIP lost). `c50ca05cd` deleted the old copy route before any walk had driven the new one.
4. **Tests checked internals, not what users see** [all]. Test functions rose from 17,766 to 26,164, yet XCUI holds 40
   at base and head and the `ui` profile names a script that has never existed. Parity tests passed while their
   routes failed. `38ae07de8` pinned the broken pooled-mapping behaviour for nine days. No input was added to the
   classifier fixture folders, where the late science bugs lived.
5. **Findings became rows faster than rows closed** [A1, A3]. 196 review verdicts asked for 848 fixes. Moved out rows
   per plan went from 16 (2.6) to 107 (2.13). The owner check list grew from 3 rows to 97 and was handed to LLM
   consensus (O35).
6. **Process roles cost more than the code** [A1, A2]. Lanes cost $4,443 (34%). Review, manager, design, rulings and
   monitor cost $6,271 (49%). About 85% of some 300 vote margins were unanimous. One uncapped fact-check made 2,791
   calls and took weekly quota from 89% to 95%.
7. **Mechanical churn and document sprawl** [A1]. 397 commits (7.8%) touched nothing but `MODULES.md` or ratchet
   baselines. Contracts grew from 59.7 KB to 427 KB, and release notes reached 111,565 characters.
8. **Live checks were thin until 2.13** [A3, A2]. Four Previews (2026.10.13 to 10.16) shipped on a locked-screen
   substitute that opens a demo, hashes it and quits. The science seat cost $613 (4.8%) and was outvoted 3 to 2 on
   OBS-W7. R17's 3,600 s tool timeout stopped EsViritu on 10-13 and is still the default (`CondaManager.swift:1059`).

## Rabbit holes

Ranked by rough cost within each group, with the overall rank in the first column. Dollars are galah ledger figures or
a seat's judged share of a session. Rule numbers point to Contract amendments.

**Trivial edge cases and scope over-reach**

| Rank | Name | What happened | Rough cost | Evidence | Why low value | Rule that would have stopped it |
|---|---|---|---|---|---|---|
| 1 | CLI leaves for actions that make no scientific data | Every viewer export, label edit, clipboard and share action got a row, a CLI leaf, a parity class and a hidden key. O5 overrode five memos that asked for a census first | About $2,000 judged (half of 2.10 to 2.12), about 240 export commits | `docs/plans/2026-10-17-phase-2-12.md:32` (O5), OBS-W7 | A viewer PNG is not a result that needs replay, and the figure rebuild became a Stable blocker | 7 |
| 3 | Literal exit and the hidden-key cycle | Routes flipped behind a key for one Preview so the next could delete it. The literal reading made that and zero spawns an exit, which created 2.13 | About $750 of 2.13 judged, 144 key and 61 spawn commits in 10-18 to 10-22 | `a0eec8b32` plan:127 against plan:163, `85e584dca` | tar and gzip carried none of R7's risk, and 2.2 had deferred them. No user could reach a key | 5, 6 |
| 4 | Review fixes and carried rows on margins | Each review asked for fixes, and each unfixed item became a carried row | 848 fixes, fix agents $681, about 47 S3 and S4 walk rows sent to Phase 3 | `events.log` of 2.10 to 2.13, `WALK-TALLY.md:226-289` | A 5.3 s cancel against a 6.0 s grace, 255-byte temp names | 9, 10, 11 |
| 10 | Provenance minutiae | Signing spread to downloads and VCF attaches, and the app's name in records changed four ways and back | About 104 commits, about $340 | `904dc1d51` ("Restore lungfish-gui as argv[0]") | No lab sets a key, and no scientist reads argv[0] | 15 |

**Flaky-test and misdirected test work**

| Rank | Name | What happened | Rough cost | Evidence | Why low value | Rule that would have stopped it |
|---|---|---|---|---|---|---|
| 5 | Per-test wait patching under load | Waits raised test by test (10 s to 60 s in `0715907e2`), orphaned CPU burners, red candidates rerun | 112 timing-and-test-only commits, about $535 est, three of four 2.12 candidate rounds | Memory `unit-gate-load-flakes.md`, `phase-2-12-outcome.md` | Gates ran at load 40 to 50 beside lane builds. Each patch chased a symptom | 13 |
| 6 | Parity tests as proof of a GUI route | Each moved route was proved by a test that the app's argv and output equal the CLI's | 481 commits touch `*Parity*` files | `d7cb1ac8e` (row 20 failed after its parity test passed) | Two code paths agreeing does not put the result on screen | 4, 6 |
| 13 | Help-text byte goldens, MEGAHIT study | Every new leaf recaptured help bytes. One lane spent about 8 hours measuring an upstream crash rate | 122 commits on 321 help files, one 2.12 lane | Memory `megahit-arm64-crashes.md` | Help bytes protect no result, and the app cannot fix MEGAHIT | 14, 20 |

**Process work**

| Rank | Name | What happened | Rough cost | Evidence | Why low value | Rule that would have stopped it |
|---|---|---|---|---|---|---|
| 2 | Five-expert panel in every sub-phase | Inventories, memos, votes and rulings before lanes, even for mechanical batches, then five votes on every walk row | $1,640 (design and rulings) plus about $180 of walk votes | `EXPERT-PANEL.md:9`, `:53`, `WALK-TALLY.md` (64 KB) | About 85% of margins were unanimous. Four blockers passed 3 to 2 where a severity rule would have decided | 8, 9 |
| 7 | Release notes as change logs, fact-checked | Notes grew to 111,565 characters with route keys and exit codes, each sentence fact-checked | $397 to $579, one runaway check of 2,791 calls | Memory `runaway-fact-check-agent.md` | Scientists need the result changes. O26 fixed it | 19 |
| 8 | A notarized Preview per sub-phase | 24 Previews in 23 days, ten from 10-05 to 10-08, about 2.5 h of tiers each, four on a walk substitute | $424 of agents, dozens of machine hours | `git tag --sort=creatordate` | No Stable came of it, and most changed screens went unwalked | 1, 2 |
| 9 | Monitor and contract self-editing | A monitor at every checkpoint (12 in 2.13) that also rewrote the process contract | $377, 24 contract commits | `docs/plans/2026-10-20-phase-2-13.md:487-500` | It never asked whether a lane should exist, and missed the runaway agent | 18 |
| 11 | Generated-index and baseline churn | `MODULES.md` carries line numbers, and baselines are lowered by hand | 397 commits that touch nothing else | Spot check 5 | Line numbers in a map have no reader | 17 |
| 12 | Effort A/B, round 2 | A second model-effort round after round 1 had set the roles | $311 | `docs/plans/2026-10-16-effort-ab-round-2.md` | Round 1 ($92) paid back. Round 2 tuned the factory | 18 |

## Thematic allocation

**Over-invested**

| Theme | Effort evidence | Value to users or to Phase 3 | Verdict |
|---|---|---|---|
| CLI parity beyond scientific outputs | Most of 2.10 to 2.12 ($4,308), about 240 export commits | High for runs that write results. Near zero for a viewer PNG, and it made OBS-W7 and obs-11 | Narrow (amendment 7) |
| Pins of current behaviour | 102,782 added lines in parity, replay, pin and golden files. Test lines now exceed source lines | Science pins protect moves. Wording pins make Phase 3 dearer and turned three candidates red | Keep science pins only |
| Provenance record minutiae | 858 of 4,370 commits after 1.5 name provenance or records [A2] | Versions, parameters and status matter. Signing and naming serve no named reader | Freeze (amendment 15) |
| Process governance | Manager, design, rulings and monitor $4,133 (32%). 19 contracts at 427 KB | Owner visibility, through records too large to read | Cut by half (8, 10, 18) |
| Release ceremony and margins | 24 Previews, notes to 111 KB, 235 cancel subjects | Rewind points and tree kill matter. Grace margins do not | Weekly Preview, no margin rows |

**Under-invested**

| Theme | Effort evidence | Value to users or to Phase 3 | Verdict |
|---|---|---|---|
| Stable delivery | 0 Stable in October | Stable users still drop primer-led reads and see F9, obs-6 and row 69 | Badly under. Stable first |
| Automated GUI tests | XCUI 40 functions at base and head, a misnamed `ui` profile, Accessibility tests skip when locked | XCUI catches the blocker classes (a route that never runs, a stale Inspector block) | Badly under. First Phase 3 lane |
| Live walks of the packaged app | $443 to $600, under 5% of spend | Found about 13 Stable blockers | Walk every Preview |
| R1 surface contract | No code. Five of 13 blockers were stale view state [A3] | 3a is the cure | Phase 3 core |
| R17 RNA-seq prerequisites | Nothing in Sources, mapping index rebuilt per run | The program's stated goal | 5a to 5c beside Phase 3 |
| Science inputs and outside checks | 0 new classifier fixture inputs [A2]. Goldens compare LGE with LGE | The late bugs lived in inputs never tested | One input per fixed defect, one external comparison per classifier |
| Large samples and real projects | 3,600 s default, EsViritu exit 137, OBS-W4, the SILVA freeze | Wastewater and panel samples are much of the lab's work | A realistic walk corpus |
| Words on failure | UX 1 freezes strings. OBS-W9 refuses with no words | Users read silence as a bug | Let lanes improve them |

## Scope in hindsight

Phases 1 and 2 should have been about two weeks of science and the plumbing that science needs, with Stable cut
twice, and should have stopped before the CLI-everything tail. All three seats reach this shape.

**Keep.** Phase 1 as run, and 1.5 and 2.1 whole. 2.2's process primitive and tiered tool goldens. 2.3's genotype
science. One provenance writer with the methods facts. The classifier executor. CLI commands for map, assemble,
import, FASTQ recipes and downloads. The walks, 2.13's science fixes, 2.14 and the CHTC core.

**Cut.** CLI leaves and replays for viewer exports, edits, clipboard and share. The hidden-key protocol, the
no-exemption exit and the last 42 system-tool spawns. The panel cycle at every sub-phase and votes per walk row.
Monitor checkpoints beyond one a session and effort round 2. Help byte goldens, extra signing and record naming.
Previews with no user-visible change, and the walk substitute.

**Defer.** The LungfishOperations move (2.9), the descriptor registry beyond tool identity (2.5), and CLIEvent v2 and
BundleKind (2.6), until a Phase 3 surface needs them [A2]. The team still scores them Defensible, with A1, since
Phase 3 uses BundleKind. The general Nextflow contract until a second workflow exists. The MEGAHIT study.

**Should have been in.** A Stable after 2026.10.9 (the science fixes) and after the 2026-10-10 walk fixes. A patch
branch from 9.78 for obs-6 (three lines) and F9. A repaired `ui` profile with an XCUI smoke of about ten journeys
from week 1. A gate on a quiet machine before any wait was patched. The empty LungfishRNASeq target and 5a, which
touch no Phase 2 file.

## Phase 3 scope

Phase 3 should not run as planned. Its core, R1's single viewport slot, is the right next step (OBS-W6 is exactly the
leak one `activeViewport` slot removes). But the plan (`docs/plans/2026-10-02-architecture-program.md:186-378`) has
six sub-phases, migrates about 20 viewports, opens with more pins, carries every open row, and forbids any golden move
(`:199`), which shuts science out. At Phase 2's rate that is about $6,000 and two weeks before any RNA-seq work.

**The plan.** Four steps, each with a budget set before it starts.

1. **3.0, a Stable track (days, about $500).** Fix OBS-W4, W6, W7, W8, W9 and obs-22. Point the `ui` profile at the
   real `app_smoke_gate.py` with an XCUI smoke of about ten journeys. Cut the owner check list to 25 journeys. Walk
   the package with the owner at the Mac, then promote to Stable. Science rows that touch no viewer file run as
   parallel lanes, first MAP-POOLED-PAIRS and MAP-PAIRED-UNBOUND (silent layout change), the BIO ruling
   ESV-READCOUNT-FLAGS, the 3,600 s defaults and C6-V11 plain FASTQ.
2. **3.1, the contract and the classifier views (about a week, about $2,000).** 3a's ResultViewport, ViewportHost and
   SurfaceRegistry with TwelveS and PrimerAnalysis as exemplars, then NaoMgs, EsViritu, TaxTriage, Nvd, Kraken2 and
   CzId, with 3e folded in (same five controllers, 10 copies of `showBlastResults`). Each migration is one revertible
   PR closed by a teardown test (open the kind, switch to an empty viewer, assert nothing is left) and a short walk.
   Keep the read-ID pins, and drop the frozen row texts, the accessibility snapshot per kind and the all-pairs switch
   matrix. Take from 3b only the registry path for new kinds, since sidebar routing sits in App files
   (`SidebarItem.swift`, `AppDelegate.swift` 302 to 306). Promote to Stable at the end.
3. **R17 beside 3.1.** 5a (ReferenceIndexCache), 5b (annotation input with a contig check) and 5c (CountMatrix,
   ExperimentDesign, recorded strandedness) live in LungfishWorkflow and LungfishIO and share no file with the viewer
   work. Create the empty LungfishRNASeq and LungfishRNASeqUI targets now. The owner first answers the aligner,
   quantifier and DE engine question, open since 2026-10-02 (program plan:423-425).
4. **The first RNA-seq surface as the contract's third consumer.** It registers through SurfaceRegistry with no App
   edit beyond its registration.

**Keep** 3a, the classifier migrations, 3e, the 3.1 blocker rows and NAO-MGS loads off the main actor. **Merge** 3e
into 3.1, and the six sub-phases into 3.0 and 3.1. **Defer** the other eleven viewport migrations until user work
touches them, the prefix-table retirement, 3c beyond a lint on new `Notification.Name`, 3d beyond the refusal that
names the holder, and Phase 4 except 4c (TrackRenderer) and 4d (Workflow split). **Cut** every carry-in row with no
effect on results, data or a common workflow to the backlog, and fold CHTC P3-R1 to R9 into one README edit.

**How Phase 3 knows it is done.** Five checks, nothing more.

- Stable shipped from 3.0 and again from 3.1.
- No S1 or S2 finding is open.
- The XCUI smoke and the teardown test for every migrated kind pass in the gate on an unlocked session.
- The RNA-seq surface opens, switches and exports through the registry with no App edit beyond its registration, and
  its counts match the tools run by hand on one public dataset. If the owner has not chosen the aligner by the end of
  3.1, a stub surface in a test target stands in, as the plan now says.
- Ratchet counts are reported, not gated, and an open row is a backlog row, not an exit failure.

**Dissent.** A1 would keep 3b whole and add a 3.2 for the remaining viewports, with the stub surface as the exit. A2
would run a separate science session before any viewport code. A3 agrees with the plan above.

## Contract amendments

Merged from 36 seat proposals into 21. Brackets name the source seats. Most amendments replace a longer rule, and the
rules to delete outright are listed after them.

1. **Stable on a clock.** Target `docs/contracts/VERIFICATION-ORDER.md` and program plan `:163`. Rule. "A Preview
   with no open S1 or S2 finding is promoted to Stable within seven days of its walk. A fix that changes a scientific
   result or closes an S1 finding reaches Stable within seven days, from a patch branch of the last Stable when the
   next Preview is not ready. A phase exit never gates Stable." Evidence. Stable is `1f70a13ea` with `ktrim=r` after
   24 Previews. Replaces O1 of 2026-10-17 as a standing rule. [A1, A2, A3]
2. **Preview cadence.** Target program plan `:167` and `RUNNING-A-PHASE-SESSION.md`. Rule. "A sub-phase ends at a
   green unit tier on main. A Preview ships at most once a week, and only after a live walk of the screens it
   changed." Evidence. Ten Previews in four days, four on a walk substitute. Replaces the directive of 2026-10-05 that
   every sub-phase ends with a Preview. [A1, A3]
3. **The walk.** Target `VERIFICATION-ORDER.md:40`. Rule. "A person at the Mac walks the packaged candidate over every
   screen and analysis it changed, on a corpus with a renamed project, a copied project, a large reference and records
   from an older release. The walker compares each number on screen with the command-line output and the tool's own
   report. No Preview ships on a walk substitute." Evidence. OBS-W4, OBS-W8 and the SILVA freeze showed only on real
   projects. Replaces D5. [A2, A3]
4. **A GUI gate that runs.** Target `config/test-catalog.json:245-257`. Rule. "The ui profile runs the XCUI journey
   suite, and every final candidate runs it on an unlocked session. A candidate whose XCUI or Accessibility tests
   skipped is not a candidate." Evidence. Spot check 4. Replaces the silent skip. [A3]
5. **Exits name outcomes.** Target program plan `:163` and `:199`. Rule. "Every phase exit names a user outcome and a
   Stable release. A structural count is reported at exit and is never an exit criterion by itself. A zero target may
   carry an exemption list that the owner approves once." Evidence. Spot check 2, and 2.13 at $1,536. Replaces D3 and
   Phase 3's ratchets-at-zero exit. [A1, A2, A3]
6. **Route moves without keys.** Target program plan Rollback and `ADDING-AN-OPERATION.md`. Rule. "No route flips
   behind a hidden key. A route moves when a test that drives the app shows its result in the sidebar or viewer, and
   the old route goes in the same change. Without such a test the old route stays until the next packaged walk has
   driven the new one." Evidence. `d7cb1ac8e` passed parity while row 20 failed, and `c50ca05cd` went before OBS-W8
   was found. Replaces D2. [A1, A2, A3]
7. **CLI equivalence for scientific data.** Target `docs/contracts/CLI-EQUIVALENCE.md:7`. Rule. "An operation that
   makes or changes scientific data records a lungfish-cli command that reproduces it. Reads, alignments, variants,
   classifications, assemblies, trees, genotype calls, imports and downloads are such data. A viewer export writes a
   sidecar that names its inputs and settings, and a clipboard copy, share action or label edit records nothing."
   Evidence. About 240 export commits, OBS-W7 and obs-11. Replaces D4. [A1, A2]
8. **The panel works at plan time.** Target `docs/contracts/EXPERT-PANEL.md:9` and `:53`. Rule. "The full panel cycle
   runs once when a phase is planned. One architect writes each sub-phase plan, a field expert reviews only lanes in
   its field, and the panel votes only when two fields disagree or the owner asks." Evidence. $1,640, about 85%
   unanimous margins. Replaces D1. [A1, A2]

9. **Severity, not votes, for findings.** Target `EXPERT-PANEL.md:75-78` and the walk rulings. Rule. "Each finding
   gets a severity from S1 to S4. BIO sets it for anything that touches a scientific number, and a false number, a
   silently wrong result or a silent loss is S1 that no vote lowers. UX sets it for everything else, the owner settles
   a dispute, S1 and S2 block Stable, and S3 and S4 go to the backlog with no vote." Evidence. OBS-W7 passed 3 to 2
   against BIO, and 75 walk questions got five files each. Replaces D6. [A2, A3]
10. **Bounded reviews.** Target `RUNNING-A-PHASE-SESSION.md` roles and `.claude/agents/lge-expert.md`. Rule. "A lane
    review returns blockers and at most three should-fix items. A blocker is a wrong result, data loss, a crash, a
    security hole or a broken build. Every other finding goes to the backlog." Evidence. 848 fixes in 196 verdicts.
    Replaces open-ended "Merge after N fixes". [A1]
11. **One backlog.** Target the Moved out section of every plan. Rule. "A plan holds only its own rows. Open rows live
    in one backlog file that states each row's effect on results or users, and the owner triages it once a phase. A
    row left unscheduled for two phases closes unless it changes results, loses data or crashes." Evidence. Moved out
    rows 16 to 107. Replaces D8. [A1, A2, A3]
12. **A check list a person can walk.** Target the owner check list. Rule. "The Stable check list holds at most 25 user
    journeys that no automated test can see. A row an automated test covers is deleted." Evidence. 3 rows to 97, then
    LLM consensus (O35). Replaces D8. [A3]
13. **A timing tier and a quiet gate.** Target `VERIFICATION-ORDER.md:56`. Rule. "A test that waits on a process, the
    file system or the clock runs in a timing tier that retries once and does not block a push. A gate runs with no
    lane builds on the machine. A new sleep in a test is a review blocker." Evidence. 112 timing-and-test-only commits,
    sleep calls in Tests 288 to 421. Replaces "diagnosed, not retried" for timing classes. [A1, A2, A3]
14. **Pins and goldens.** Target `Tests/AGENTS.md` and `VERIFICATION-ORDER.md`. Rule. "Byte goldens cover scientific payloads and the record facts of amendment 15,
    help text is checked by parsing, and a golden moves only with a BIO note that names the change. A pin on wording,
    layout or source text is removed when the move it guarded lands. Each fixed science defect adds its smallest
    failing input with numbers from the tool run directly, and a science pin needs BIO's word that the pinned
    behaviour is right." Evidence. `38ae07de8` pinned a broken behaviour, and no classifier input was added. Replaces
    D9. [A1, A2]
15. **A complete record, then stop.** Target `docs/contracts/RECORDING-PROVENANCE.md`. Rule. "A record is complete
    when it holds the command, each tool's version and build, each database's name, version and digest, each input's
    checksum, the parameters that change results and the run status. Signatures beyond result records, the name a
    record gives the app, byte layout and script exports other than shell are not acceptance criteria and get no lane
    without a named user." Evidence. About 104 signing and naming commits. [A2, A1]
16. **Failure words may improve.** Target `EXPERT-PANEL.md:128`. Rule. "A lane may improve any word a user reads on
    failure, refusal or cancel, and the UX reviewer reads the new words. A failure or refusal that shows no words is an
    S2 finding." Evidence. OBS-W9 refuses with no words. Replaces D7. [A3]

17. **Generated files that do not churn.** Target `scripts/index/generate-module-map.py`,
    `scripts/install-git-hooks.sh:243` and `scripts/ratchets/`. Rule. "The module map lists targets, dependencies and
    public types with no line counts or line numbers. When a ratchet count falls, the gate writes the lower baseline
    itself, and a ratchet at zero becomes a plain lint." Evidence. Spot check 5. Replaces D10 and hand lowering. [A1]
18. **Budget, measure once, guard always.** Target `RUNNING-A-PHASE-SESSION.md:28` and `:143`. Rule.
    "Each sub-phase plan states a budget, the ledger runs once at session end, and a quota heartbeat every 45 minutes
    stops any agent far past its call cap. At one and a half times the budget the manager starts no new lane until the
    owner answers. Process experiments get at most 2% of a phase budget, and only the owner changes a process
    contract." Evidence. The tail cost $5.84K against $5.3K for the planned work, and the 2,791-call agent passed every
    checkpoint. Replaces D11. [A1, A2]
19. **Size caps.** Target `docs/contracts/README.md` and `release.py package`. Rule. "A contract stays under 20 KB.
    Release notes stay under 15,000 characters, and release.py package refuses a longer file." Evidence. Contracts at
    427 KB, a failed publish at 132,811 characters. Codifies O26. [A1, A3]
20. **Tools run until done.** Target `docs/contracts/RUNNING-A-TOOL.md`. Rule. "An analysis tool has no wall-clock
    limit by default. A limit is a named option recorded in the run, and a watchdog that stops a run says why. An
    upstream tool defect gets a retry and a Known limit, not a study." Evidence. The 3,600 s default stopped EsViritu
    and still applies (`CondaManager.swift:1059`). [A2, A1]
21. **RNA-seq does not wait for Phase 3.** Target the program plan's Phase 5 entry. Rule. "Tasks 5a to 5c start after
    the next Stable and need no Phase 3 exit. The owner answers the aligner, quantifier and DE engine question before
    5a starts." Evidence. No R17 code, and the decision open since 2026-10-02 (plan:423-425). [A2, A1]

**Rules to delete outright**

- D1. `EXPERT-PANEL.md:9` and `:53`, the panel leading every session.
- D2. The one-release hidden-key protocol (program plan Rollback, 2.10 C4, 2.12 R-A1) and the exit clause on
  deleting every hidden route key.
- D3. "with no exemption list" in plan:163.
- D4. `CLI-EQUIVALENCE.md:49`, replay of clipboard and share actions.
- D5. The locked-screen walk substitute and the Debug-build walk at `VERIFICATION-ORDER.md:40`.
- D6. The five-field vote on walk rows and its tie rules.
- D7. UX 1's frozen strings by default and the 3.1 row-text freeze.
- D8. Moved out tables, and "Every row that is not Pass stays on this list".
- D9. Help-text byte goldens, and the Phase 3 ban on any golden move.
- D10. Line counts and line numbers in `MODULES.md`.
- D11. Monitor checkpoints after each wave, the end-of-session contract rewrite, and the session table at
  `RUNNING-A-PHASE-SESSION.md:171-180`, which moves to the records.
- D12, owner to decide. A1 alone would delete `LLM-EVIDENCE.md`, `CLAUDE-CODE-PRACTICES.md` and the weekly
  best-practice check. The team would move them to the records, since the owner directed them.

## Spot checks

The five claims this report leans on most, checked by the chair with git read commands in REPO and `grep` over the
records. Two held as stated, one held with a narrower meaning, and two were corrected.

| # | Claim | Check | Result |
|---|---|---|---|
| 1 | Stable is still the base commit and drops primer-led reads [A2] | `v2026.9.78^{commit}` is `1f70a13ea` ("Prepare Stable 2026.9.78"). At the tag, `FastqCommand.swift:2054` passes `"ktrim=r"` to bbduk in `nativePrimerRemovalExecution`. `2026.10.24.md:7` reads "Stable baseline: v2026.9.78", and every later tag is a Preview | Holds |
| 2 | The literal exit ruling, not the original plan, created 2.13 [A1, A2] | `a0eec8b32` plan line 127 reads "at the adapter sites only". Today's line 163 reads "with no exemption list". `docs/plans/2026-10-17-phase-2-12.md:32-36` quotes the owner's O1, O2 and O5 | Holds. These were the owner's own answers, so the tail is owner-set scope, not agent drift |
| 3 | 196 reviews asked for 848 fixes [A1] | Case-insensitive count of "merge after N" in `events.log`. 2.10 gave 1 and 2, 2.11 39 and 282, 2.12 50 and 240, 2.13 106 and 324, so 196 and 848 | Holds as 196 verdict lines, which include BIO reads and re-reviews, not 196 distinct lanes. The "one lane merged as is" could not be reproduced and is dropped |
| 4 | No GUI test was added and the `ui` profile points at a deleted script [A3] | 40 `func test` in `Tests/LungfishXCUITests` at base and head. `config/test-catalog.json:245-257` names `scripts/release/app-smoke-gate.sh`, which no commit ever added or deleted (`34548a699` does not touch it). `app_smoke_gate.py` exists at base and head | Corrected. Never deleted, but misnamed since before Phase 1, so the GUI gate never ran in the program. The finding is stronger |
| 5 | 451 commits (9%) were map regeneration or baseline lowering [A1] | Over `1f70a13ea..ca9091af1`, 488 commits touch `docs/architecture/MODULES.md`, 256 touch only it, 85 touch only ratchet baselines, and 397 touch nothing but the map or baselines. Subject matches give 321 and 138 | Corrected to 397 commits (7.8%). The point stands |

Also confirmed. The tail of $5,844 sums the 2.10 to 2.13 sessions in `spend-by-session.md`. The blocker commits
carry the dates given, and `38ae07de8` (10-14) came nine days before `208aa71c0`. The 2026.10.22 check list has 97
table rows, so the seats' 92, 95 and 97 differ only in the sections counted. Tags show 2026.10.3 to 10.12 shipped
from 10-05 to 10-08. The contract lines the amendments target say what the amendments say they say.

## Dissent and confidence

**Agreement.** All three seats found no Stable, cheap and productive walks, low-value export parity and key cycles,
costly panel and release ceremony, symptom-chasing timing work, and starved R1 and R17.

**One seat alone.** A1 saw the map and baseline churn, contract sprawl and unscheduled debt growth. A2 saw Stable's
`ktrim=r`, the pinned pooled-mapping bug, the 3,600 s default, the missing science inputs and BIO outvoted. A3 saw the
flat XCUI count, the misnamed `ui` profile, the walk substitute, the program-made blockers and silent failure words.

**How disagreements were resolved.**

| Question | Positions | Resolution and basis |
|---|---|---|
| The split | A1 35/37/28, A2 and A3 30/35/35 | Started from A1's per-group table, the only one that sums to the ledger ($12,179). Moved 10 points of 2.10 to 2.12 from Defensible to Low value, since A2's and A3's evidence ties that work to four Stable blockers. Result 34/34/32. A2's blend with the laptop era gives 32/36/32 |
| Verdict | A1 "partly", A2 "both, by period", A3 "no" | Partly. The calendar held (plan line 149), so "no" overstates, but 45% of spend went to a tail the original exit did not require |
| When an old route goes | A1 on green parity, A3 after a walk | Toward A3, since parity passed while users failed (`d7cb1ac8e`). Same-change deletion kept where an app-driving test exists |
| Viewer exports | A1 nothing, A2 a sidecar | Sidecar for file exports, since figures go into papers. Nothing for clipboard and share |
| 3b | A1 keep, A2 and A3 defer | Registry path for new kinds only, since sidebar routing sits in App files |
| Phase 3 exit proof | A1 a stub, A2 and A3 an RNA-seq surface | The real surface, with the stub as fallback |
| Science first | A2 a separate session | Parallel lanes in 3.0, as the files do not overlap. A2 dissents |
| Effort A/B | A1 well, A2 and A3 low value | Round 1 ($92) Defensible, round 2 ($311) Low value |
| LLM contracts | A1 alone would delete | Move to records, owner decides (D12) |

**Confidence.** The direction is solid. Every seat, from three lenses and three methods, put Low value between 28%
and 35%, and the tail outspent the planned work under any reweighting. The split is still judgment, plus or minus 10
points.

**Limits.**

- The laptop sessions (Phase 1 to 2.1, CHTC 1 to 3) are not in the ledger. They were the most science-dense part, so
  the true Low value share is likely a few points lower.
- Commit and test-file classes are keyword matches, so any one theme could be off by a factor of 1.5.
- Nobody ran tests or the app. If pins caught silent science regressions the records do not name, some pin work moves
  to Essential.
- We could not see who runs Stable. If everyone runs Preview, the Stable harm is smaller.
- Program-made blockers could be three to six of 13. Four were traced to commits.
- Part of the tail was the owner's explicit choice (O2 and O5). The Low value calls judge the return, not the chooser.
- Team B's report was not read, by design.

