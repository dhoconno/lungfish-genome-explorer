# Audit Team B report on Phases 1 and 2

The chair's synthesis of the three Team B seats, B1 engineering and architecture, B2 bioinformatics and domain, and B3
GUI and UX. Their memos sit beside this file. Everything was read only, at origin/main `ca9091af1` against the base
`1f70a13ea`. Dollars are the measured galah spend of $12,904 over 40 sessions unless marked. The laptop sessions of
Phase 1, 1.5, 2.1 and part of 2.2 are not in that figure, and B1 puts them at about $3.8K more. "w" dollars are B1's
allocation of each day's spend to its commits.

## Team verdict

Partly warranted. Phase 2 was not slow, it was big. The 10-02 plan gave Phases 1 and 2 five weeks
(`docs/plans/2026-10-02-architecture-program.md:95,149`) and they took 23 days. The length the owner felt came from scope
that grew from seven tasks to fourteen sub-phases, and from shipping no Stable, so most users received none of it.

**Essential 30% (about $3.9K), Defensible 35% (about $4.5K), Low value 35% (about $4.5K), each within about 10
points.** The seats gave 40/28/32 (B1), 22/38/40 (B2) and 30/35/35 (B3). We did not average. Low value converged, since
three different methods land between 32 and 40. Essential split on a definition. B2 counted only result-changing
science, so it filed the process primitive and the classifier executor as Defensible while keeping both in its own Keep
list. The mandate's Essential includes a reliable app, which adds about 8 points (B3's sizing). B1 counted half of a
feature bucket as Essential, but after 2.6 only about a quarter of sampled GUI commits changed anything visible (B3) and
result fixes fell about five-fold (B2). Both corrections land near 30.

The detail was warranted through about 2.9 (10-12), when each Preview fixed results. After that most attention went to
export parity, record form, pins and process, while the defects users met were found by GUI walks costing 2 to 5% of
spend. The unmeasured laptop phases were mostly Essential, so the program-wide Essential share is somewhat higher.

## What went well

1. **Result-changing science fixes came early.** Phase 1.5 and 2.1 fixed Kraken2 counting each mate, bbduk primer
   removal dropping reads, merged reads paired with R1, non-Illumina reads imported as Illumina, 12S double counting and
   a `primer-remove` k-mer default longer than every bundled primer (`docs/release-notes/2026.10.2.md:15-48`,
   `2026.10.9.md:15-75`). All three seats rank this first. B2 counts about 45 such fixes from 10-02 to 10-10.
2. **One process primitive and one cancel.** `Process()` sat in 79 Sources files at the base and in no code file now
   (spot check 4). SIGTERM gives exit 125 and a `cancelled` record on every CLI leaf, so a cancel stops the whole process
   group and leaves no half result. R7 is closed.
3. **One provenance writer with true tool versions.** Writers fell from 25 to 0
   (`scripts/ratchets/provenance-writers.baseline`). Tool goldens caught bwa-mem2 recording `ERROR: unknown command
   '--version'` as its version and EsViritu recording Python's (`2026.10.14.md:29-46`), the text a methods section copies.
4. **GUI and CLI compute with the same code for analyses.** `cli-parity-gaps` is 0, the classifiers run on one executor
   (closing R3's preview-reads defect, `docs/reports/2026-10-02-architecture-review/REVIEW.md:54-63`), a UI-free
   `LungfishOperations` target exists, and the CHTC program used that path to run batches on Linux.
5. **GUI walks were the best-value testing.** They cost $258 by ledger role and about $670 all-in by B3's count, 2 to 5%
   of spend, and found all 13 Stable blockers, including Save Assignments failing silently since July (`900c0fabb`). No
   test and no review found any of the 13.
6. **Characterization paid off where it met science.** Pinning the genotype export in 2.3 ($596) exposed zero-read rows
   counted toward calls and IPD accessions read as loci (`19bbb6238`, `2026.10.13.md:15-60`).
7. **Scientific goldens are small and aimed.** Read counts, `samtools view --no-PG` hashes, idxstats and sorted
   classifier tables, touched by only 69 commits in the whole program (B2).
8. **The program learned to measure itself and to talk to users.** The session ledger made this audit possible, O26 cut
   release notes from 58 to 111 KB down to 11 to 19 KB, and the later Previews published first try.

## What went poorly

1. **No Stable in 24 days.** All 24 October releases are Preview and name `v2026.9.78` as the Stable baseline, against
   16 Stables among the 98 releases of August and September (spot check 1). Stable labs still run the primer-trim read
   loss and mate-pairing defects fixed in the first week. All three seats call this the largest cost of the program.
   Decision T8 of 2.7 made an owner check list the only path to Stable, and that list grew from 20 to 92 rows.
2. **Scope grew in small unpriced steps, and CLI parity outran its purpose.** Seven tasks became fourteen sub-phases and
   nine plans moved out 446 rows. The literal reading of the exit criteria created 2.13 and the walk created 2.14
   (`architecture-program.md:167`). Sessions 2.10 to 2.13 cost $5,844, 45% of spend, much of it to give exports,
   copies, clipboard actions and viewer images a `lungfish-cli` leaf (about 32 of 40 new CLI paths, B2). That work
   shipped regressions. OBS-W7, a mapping image with no mismatch marks, comes from moving Export Image onto `bundle
   export-graphic` (spot check 5).
3. **Tests pinned incidental detail and missed what users hit.** In B1's sample of 70 new tests, 27% pin layout, argv
   spelling, key shapes, messages or record placement, and 29% pin something a user meets. 241 commits kept help, event
   and record pins byte-identical against 69 on scientific fixtures (B2). Files named `*Pin*` went from 2 to 153. About
   8,400 net new test functions caught none of the 13 Stable blockers.

4. **Review and panel ceremony cost more than it returned.** Review $2,138, panel design $1,329, rulings $311, monitor
   $377 and the A/B rounds $403 total about $4.6K, 35% of spend. Two independent samples agree that about one review fix
   in six touched a defect a user could hit (B1 5 or 6 of 32, B3 about 5 of 30), down to `a42275260` "Take the colon out
   of one test comment". The exception is domain review. BIO ruling R1 caught a multi-sample Clade % error in 2.13.
5. **GUI automation stood still while headless tests doubled.** `Tests/LungfishXCUITests` holds 20 files at base and
   head with 3 commits, the last on 10-06. The ui profile names a script that does not exist
   (`config/test-catalog.json:255`), a defect known since 10-17 and deferred to 3.1. `LungfishAppTests` went from 514 to
   1,092 files.
6. **Load flakes were fixed one wait at a time.** 266 commits name a timing word and 112 touch only tests (evidence
   pack). The Provenance Inspector waits rose to 60 s in two rounds (`0715907e2` on 10-15, `c1fc3d9b1` on 10-19), the 2.12
   candidate needed four fix rounds, and the shared wait budget (`29eb9dc98`) arrived only on 10-21. The integration
   budget went from 90 to 150 minutes and was then pinned by a test (`483cc46d1`).
7. **The structural debt on the RNA-seq path is untouched or worse.** LungfishWorkflow grew from 215K to 272K lines
   (R12). `AnalysisToolDescriptor` is used by two source files (R2). Source-text assertions fell only from 1,647 to 1,388
   (R11). `ADDING-AN-OPERATION.md` doubled to 55 KB, and two agent docs still say `Process()` is created directly
   (`Sources/LungfishCore/AGENTS.md:48`, `Sources/LungfishKit/AGENTS.md:58`).
8. **Science content waited while record form was polished.** Signing, the stderr window and the recorded app name took
   118 commits (B2), while database identity, the field a metagenomics reviewer asks for first, is "not scheduled yet"
   for EsViritu, TaxTriage and NAO-MGS (`docs/contracts/RECORDING-PROVENANCE.md:66`). EsViritu died with exit 137 on a
   12.5M-pair sample and the response was a friendlier message.

## Rabbit holes

One table, ranked by rough cost across all groups (the # column), grouped as the mandate asks. Rows overlap, so do not
add them. Where the seats' figures differ we give the range.

| # | Name | What happened | Rough cost | Evidence | Why low value | Rule that would have stopped it |
|---|---|---|---|---|---|---|
| | **Process and scope work** | | | | | |
| 1 | Panel, per-field review and fix loop on every lane | Five-expert inventories, memos and votes each sub-phase, a fresh reviewer per field per lane, then fix agents | $3.8K by role (design, review, rulings), 29% | Ledger roles, 248 to 316 review-fix commits, `a42275260` | About one review fix in six touched a user-visible defect, and walks found every Stable blocker | Amendment 10 |
| 2 | CLI parity for exports, copies, clipboard and images | 2.10 to 2.12 gave actions that compute nothing a CLI leaf, a row command and A, B and C parity sides | About half of 2.10 to 2.12's $4,308, so about $2K. 2.12 alone $1,103 | `CLI-EQUIVALENCE.md:7`, 32 of 40 new CLI paths, OBS-W7, OBS-W2 | An export needs to cite the run it came from, not its own replay, and the move degraded figures | Amendment 3 |
| 3 | Governance corpus and self-measurement | Plans, contracts and agent docs rewritten each sub-phase, two effort A/B rounds, monitor checkpoints | 310 process-doc commits ($804 w), A/B $403, monitor $377, about $1.6K | Plans 123 KB to 1.88 MB, contracts 60 KB to 427 KB | Agents reread it every session and it drifts (two stale AGENTS.md rows) | Amendments 11 and 14 |
| 7 | Release notes and owner check list as records | Notes of 58 to 111 KB and a check list of 20 to 92 rows carried "still open in full" | 484 KB of notes, 41 commits, at least $470 of agents | `2026.10.21.md:243`, `2026.10.22-owner-checks.md`, a 132,811-character draft GitHub refused | Users skim notes, and a list nobody runs blocks Stable while testing nothing | Amendment 1. O26 already fixed the notes |

| 10 | Hidden route keys made, then deleted | Each route moved behind a `defaults` key that shipped and was deleted a Preview later | 25 to 44 key commits, $100 to $330, and one of the two reasons 2.13 existed | `architecture-program.md:167`, `2026.10.18.md:13`, `2026.10.20.md:15` | With no Stable behind them, the previous Preview was already the rewind point | Amendment 12 |
| 11 | Bookkeeping commits | Module map regenerated and ratchet baselines lowered after nearly every lane | 455 commits (9%), cheap in tokens but each a commit, gate and landing | `docs/architecture/MODULES.md` in 488 commits, `EsVirituDiagnostics.swift` created to stay under a baseline | Generated files need no commit per lane, and a baseline decided where science code lives | Amendment 15 |
| | **Flaky and churning test work** | | | | | |
| 4 | Metadata kept byte-identical | Help text, CLI event transcripts, record shapes and the Provenance tab pinned byte for byte, with six masks for clocks and rates | 241 commits on these fixtures and 67 mask commits, about $1.0K to $1.5K (B2's range runs to $2.6K) | 321 `cli-help` captures, `cli-events` 87 commits, masks at `CLI-EQUIVALENCE.md:38-43` | None of these bytes is a result, and each wording fix cost a recapture | Amendment 4 |
| 5 | Load-sensitive waits raised one at a time | Short waits failed on a busy 20-core Mac and were raised test by test, and final candidates reran | 266 timing commits, 112 test-only, $370 to $900, four fix rounds in 2.12, about 15 minutes a rerun | `0715907e2`, `c1fc3d9b1`, `29eb9dc98`, memory `unit-gate-load-flakes.md` | Most failing tests checked display or routing, not results | Amendment 9 |
| 9 | Pin today, then change | A lane pinned behaviour it was about to change, then rewrote or deleted the pin | 61 test files of 8,923 lines created and deleted, plus rewrites such as 882 lines in and out over 19 commits. Dollars not measured | B1 `throwaway.py`, `09ee35cb6`, decision G1 of the 2.10 plan | The pin is thrown away by design | Amendment 4 |
| | **Trivial edge cases** | | | | | |
| 6 | Provenance form one site at a time | Signing sorted into 86 sites, two stderr windows, the recorded app name changed back and forth, 26 `recordedToolName` commits in two days | $400 to $800 (B2 118 commits, B3 half of about 490 record-only commits) | `RECORDING-PROVENANCE.md:35-40`, `904dc1d51` against `e9d7450ea` | Nothing signs without a key, and database identity still waits | Amendment 13 |
| 8 | Cancel precision tail | Per-route grace windows, staging cleanup and race wording such as "Finished before Cancel took effect" | About half of roughly 296 cancel commits, $350 to $450 | `2026.10.16.md` (6 s grace), `2026.10.22.md` | A user needs cancel to stop and leave no half result, which the core already does | One cancel contract, tested once in the launcher |
| 12 | Edge cases nobody reported | 255-byte temp names, autofs probes, volume names read as versions, locale order, a 1e-16 digit voted on by five experts | Disputed, from under 20 commits (B2) to about 440 commits and $1.45K (B3) | `6fb42ea2b`, `4e973b96e`, OBS-W3 at `2026-10-23-phase-2-14.md:281` | Each is real and rare, and together they crowded out obs-22 and the quit alert | Amendment 2 |
| 13 | Archive symlink refusal | Every archive import refuses a link that leaves its folder, then any absolute link | 11 commits, about $30, plus Stable blocker OBS-W9 | `2026.10.22.md`, Things to know | It was never tried on the official Kraken2 and EsViritu archives it guards | Amendment 7 |

**How the disagreements here were resolved.** For timing (B1 84, B2 258, B3 266) we use the evidence pack's 266 subject
matches and 112 test-only commits. For hidden keys we leave out B1's 64 route deletions, because a direct switch deletes
the old route anyway. For edge cases B3 sized a broad class from subjects, while B2 counted only cases that change no
result and lose no data. B2's test is the right one and B3's examples fail it, but the class size is unresolved, so it
ranks low with a wide range.

## Thematic allocation

All three seats put CLI parity of exports, record form, pins and process on the over side, and Stable and GUI
automation on the under side. B2 alone saw the science content gaps, B3 alone the alert words and UX backlog, B1 alone
the RNA-seq-path debt. We kept all three, because each rests on evidence the others did not look at.

### Over-invested

| Theme | Effort evidence | Value to users or to Phase 3 | Verdict |
|---|---|---|---|
| CLI parity past analyses | 2.10 to 2.12 $4,308, 172 parity test files (7 at base), 32 of 40 new CLI paths are exports or copies | High for classify, map, assemble and import. Near zero for exports and images, and twice negative (OBS-W7, OBS-W2) | Stop at operations that compute data |
| Provenance record form | 571 commits touch provenance files ($2,352 w), provenance code 25 to 95 files, `RECORDING-PROVENANCE.md` 50 KB | The methods minimum is Essential and was wrong before 10.14. Placement, signing and naming are not | Freeze at a methods minimum, add database identity |
| Byte goldens and pins of non-science output | 321 help captures, 153 `*Pin*` files, the UX 1 frozen strings, "row texts are frozen" for 3.1 (`architecture-program.md:221`) | They stop accidents and also stop better words. The bad appQuit alert template is pinned at `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeDraftAlertTests.swift:42` | Keep tool and science goldens, delete the rest |
| Process governance | About $4.6K by role, contracts 7 times larger, plans 15 times | A 300-agent session needs some structure. Overhead absorbed most of the fall in direct lane cost (spot check 5) | Cut by about two thirds |
| Headless app tests of rewiring | `LungfishAppTests` 514 to 1,092 files | Pins routes and argv, blind to focus, layout and words | Trim as XCUI grows |
| Cancel precision | About 296 cancel commits ($692 w) | The core is Essential and done | Spend nothing more |

### Under-invested

| Theme | Effort evidence | Value to users or to Phase 3 | Verdict |
|---|---|---|---|
| Stable releases and backports | 0 of 24 October releases, 16 of 98 in August and September | Highest. Stable labs lack every result fix of October | Ship Stable before any Phase 3 refactor |
| Automated GUI checks | 20 XCUI files unchanged since 10-06, broken ui profile, one `visibleFrame` test | B3 maps 12 of the 13 Stable blockers to six checks that cost less than one walk-and-fix cycle | First priority after Stable |
| Database identity and truth sets | Only Kraken2 records its database. No Freyja demix golden, eight files mention a mock community | A database release changes calls. Goldens prove sameness, not truth | One science session in Phase 3 |
| Real-data scale | EsViritu exit 137 on 12.5M pairs, MEGAHIT capped to one thread, COLLECTION-PERF 24.2 s against 16.0 s at base | Cores run tens of millions of reads per sample | One scale lane per phase |
| Structural debt on the RNA-seq path | Workflow 215K to 272K lines, the descriptor in two files, 1,388 source-text assertions | RNA-seq code lands here first | A separate RNA-seq target, R2 finished for new tools |
| Alert words | 158 `NSAlert(` sites in 69 files, 74 with raw error text, no shared presenter | Bench scientists act on alerts. OBS-W5 and the appQuit alert still ship | One presenter in plain words |
| Window size, main thread and UX triage | obs-22 failed in two walks, W1-T, 36 of 48 walk rows in 2.13 name UX | Users feel hangs and oversized windows before record detail | A standing UX backlog |

## Scope in hindsight

**Phase 1 and 1.5 (10-02 to 10-05) were right-sized.** All three seats keep them whole. Agent docs, the R6 moves of the
worst files, goldens of scientific output, read pairing, platform inference, Kraken2 pairs, and CLI equivalence for
analyses. Most of the program's scientific value was made here, on the laptop, outside the measured spend.

**Phase 2, keep.**
- 2.1's result-changing follow-ups and ExFAT-safe durable writes.
- 2.2 ToolProcess with per-tool goldens, and the version probes that fixed recorded tool versions.
- 2.3 genotype characterization with its calling fixes.
- 2.4 one provenance recorder, frozen at a methods minimum plus database identity for every classifier.
- 2.6's CLIEvent v2 core and the BundleKind registry.
- 2.7 to 2.9, the classifiers on one executor through the CLI, the `LungfishOperations` target and the Nextflow
  contract.
- From 2.13, the removal of the last `Process()` sites and the second writer.
- One packaged GUI walk, its fixes, then Stable.

**Phase 2, cut.**
- CLI leaves, row commands and byte parity for exports, viewer images, clipboard actions, copies between projects, demo
  fetch and tool updates (most of 2.10 to 2.12 beyond analyses).
- Byte goldens of help text and event transcripts, masks M-1 to M-6, and per-site record pins.
- Signing beyond what existed, the two-window stderr rule and the recorded-name changes.
- Hidden route keys and the part of 2.13 that existed to delete them.
- Pin-first tests of non-scientific behaviour.
- Module map and baseline commits per lane.
- The second effort A/B round and monitor checkpoints inside a session.
- Five-field review of doc-only and test-only lanes, and five-expert votes on cosmetic walk rows.
- Release notes and an owner check list used as internal records.

**Phase 2, defer.**
- CLI routes for low-traffic in-app actions until a lane touches them.
- The CHTC Linux program until after the first Stable. It is real user work and was cheap on galah (about $705), but it
  ran while five Stable blockers waited.
- Genotype characterization beyond the export coordinator, to Phase 4.
- The 40 Known limits marked "Phase 3 candidate", to a tracker the owner ranks.

**Resolved disagreement.** B2 would have deferred the general Nextflow contract until a second workflow was chosen. B3
kept it because RNA-seq pipelines are Nextflow. B3 is right on the evidence, since the program's stated goal is an
RNA-seq surface, and the cost (2.9, $703) is already paid.

**What it would have cost.** The three independent estimates agree within their error (B1 about $8K, B2 $5K to $6K
saved, B3 $4K to $5K saved). The team figure is $7K to $9K measured instead of $12.9K, with Phase 2 ending between 10-15
and 10-17 with a Stable, a week earlier than it did.

## Phase 3 scope

**Phase 3 should not run as planned.** All three seats agree. The plan (`architecture-program.md:186-378`) is six
sub-phases that migrate about twenty viewports, the sidebar, the event layer and the launcher, behind a 3.1 that first
adds pins and meters. At Phase 2's rate that is $4K to $9K and two to three weeks, with about 200 carry-in rows. By its
exit (line 199) users get fewer leaks and no new capability, and it skips R2, R11, R12 and R17, which RNA-seq meets
first. The leak class is real, though. `hideNonBundleViews()` misses four kinds and the Inspector clears per-kind
blocks by hand (OBS-W6), so the core is worth building.

**Recommended plan.**

| Step | Content | Decision | Budget |
|---|---|---|---|
| 3.0 Stable | OBS-W4, W6, W7, W8 and W9, obs-22, the owner's three items. Fix `config/test-catalog.json:255` and run the XCUI smoke. One packaged walk, then ship Stable | Promote plan rows 316 to 321 to their own session | 1 session, about $300 (2.14 cost $274) |
| 3.1 User and science quality | A switch matrix in a real window (one viewer installed, current Inspector blocks only, frame inside `visibleFrame`, first responder, no writes). One alert presenter. Completed means the outputs are where the user looks. Database identity for EsViritu, TaxTriage and NAO-MGS. The symlink refusal tried on the official archives. TT-FUZZY-NAME. The S2 and S3 UX walk rows | New. Replaces 3.1's pins and meters as the safety net for the refactor | 1 session, about $800 |
| 3.2 Core and classifiers | ResultViewport, ViewportHost and SurfaceRegistry with the 12S and primer exemplars and the stub-surface test, then 3e ClassifierResultActions across the five classifiers (10 copies of `showBlastResults`) | Merge the plan's 3.1 core, 3.2 and 3.3 | 1 to 2 sessions, about $1.5K |
| 3.3 RNA-seq groundwork | 5a to 5c (reference index cache, GTF and FASTA contig checks, count matrix and strandedness). Descriptor-driven tool identity for new tools (R2). An empty `LungfishRNASeq` target so RNA-seq code does not land in Workflow | Pull forward from Phase 5. May run beside 3.2 | 1 session, about $800 |
| Deferred | 3.4 and 3.5 view migrations (genotype, MSA, phylogenetics, assembly, FASTA collection, FASTQ dataset, VCF, MHC reference, Quick Look, mapping, reference). 3b beyond new kinds. 3c typed AppEvent, with a lint on new names instead. 3d OperationLauncher until RNA-seq needs a new launch kind | Migrate when touched | None |

**Cut from 3.1.** Frozen row texts, the per-kind accessibility snapshot as a gate (VoiceOver row 13 joins the XCUI
smoke instead), classifier export byte pins (pin read IDs and counts against known lists instead), four of the five new
ratchets (keep viewport hides) and the exit clause on cli-help captures.

**Carry-in.** The roughly 200 rows go to a tracker the owner ranks. B2's list of rows that matter to scientists goes on
top (TT-FUZZY-NAME, VARIANT-IMPACT-KEYS, CDS-CUT-NUMBERING, GFF3-MULTIVALUE, Known limits 139, 141, 155, 167, 183, 213
and 251, C6-RIBO, C6-CLUMP-ORDER, COLLECTION-PERF). A row becomes a lane only under amendment 2.

**How Phase 3 knows it is done.** Six checks.
1. Stable shipped in 3.0, and a second Stable within 14 days.
2. The XCUI smoke and the switch matrix pass on three final candidates in a row.
3. A stub surface and a stub bundle kind in a test target open from the sidebar with no App edit.
4. The five classifiers share one action component whose extraction tests check read IDs against known lists.
5. Every classifier records its database by name, version and checksum.
6. Phase 5's first RNA-seq surface, the count matrix, is started on the registry.

The budget is four to five sessions, about $3.5K to $4K. When it runs out the manager stops for an owner decision and
never adds a sub-phase.

**Dissent.** B1 would pull the Phase 4d split of LungfishWorkflow ahead of RNA-seq. The team chose an empty RNA-seq
target instead, because new code can be born outside Workflow, while splitting 272K lines means weeks of moves that trip
1,388 source-text assertions. B1's view stands as dissent. B2 would run the RNA-seq prerequisites before the viewport
core. The team lets 3.3 run beside 3.2, since 5a to 5c do not need the host, but keeps the core early because the
classifier copies held the 10.22 wrong-reference defect. B3 asked for two Stables two weeks apart as an exit, which
check 1 adopts.

## Contract amendments

The seats proposed 36 amendments. Merged and deduplicated they are 15. The seat numbers after each say where it came
from. Amendments 10 and 11 reverse the owner's direction of 2026-10-11 and need the owner's word.

1. **Stable cadence and the owner check list.** Target `docs/contracts/RUNNING-A-PHASE-SESSION.md` (new section) and
   decision T8 at `docs/plans/2026-10-11-phase-2-7.md:76`. Rule. "A Stable release ships at least every 14 days from the
   newest Preview that passes the packaged XCUI smoke and a short owner walk. A fix that changes results or stops data
   loss reaches Stable within three working days, by promotion or by a point release. The owner check list holds at
   most 15 rows of at most two minutes each, and a row a machine can check moves into the XCUI smoke." Evidence. No
   Stable in 24 releases against 16 of 98 before, and a list grown from 20 to 92 rows. Replaces T8 ("an owner check list
   blocks Stable"). B1's cap of two Previews a week is not adopted, since the daily Previews of 10-03 to 10-08 each
   carried result fixes. (B1 13, B2 7, B3 1 and 2.)
2. **Phase budget, exit and edge cases.** Target `docs/plans/2026-10-02-architecture-program.md:167` and
   `RUNNING-A-PHASE-SESSION.md`. Rule. "A phase plan states the user outcome, a budget in sessions and dollars, and at
   most six exit checks that one command or one walk answers. When a check fails late or the budget runs out, the owner
   moves or waives the check, and no sub-phase is added by itself. Only an edge case that changes a result, loses data
   or was met by a user or a walk becomes a lane, and every other row goes to a tracker the owner ranks." Evidence. The
   literal reading created 2.13, and 446 moved-out rows became about 200 carry-in rows. Replaces "the exit criteria read
   literally" and carrying every moved-out row forward. (B1 11 and 12, B2 8 and 11, B3.)
3. **CLI equivalence binds analyses, and same means same science.** Target `docs/contracts/CLI-EQUIVALENCE.md` lines 7,
   38 to 43 and 49. Rule. "An operation that computes or transforms scientific data records a `lungfish-cli` command
   that reproduces it. An export, a copy, a clipboard action, a viewer image or a download cites the record it read and
   needs no command of its own. Same result means the same scientific content, so a comparison reads sequences,
   alignment records, counts, calls and sorted tables and leaves clocks, rates and container bytes out." Evidence.
   2.10 to 2.12 cost $4,308, most new CLI paths are exports or copies, the Export Image move produced OBS-W7, and masks
   took 67 commits. Replaces line 7, the masks and the owner decision of 10-17 to close every viewer export in Phase 2.
   (B1 4, B2 1 and 2, B3 8.)
4. **What tests and goldens hold.** Target `docs/contracts/ADDING-AN-OPERATION.md` Rule 10 and its CLI route recipe,
   `Tests/Fixtures/golden/README.md` and `docs/contracts/VERIFICATION-ORDER.md`. Rule. "A test checks what a user or a
   replay depends on, and goldens hold scientific output only. Help text gets a parse test and the event stream a
   schema test. Old behaviour is pinned before a change only when it is scientific output." Evidence. 27% of sampled new
   tests pin incidental detail, and 241 metadata pin commits ran against 69 on science fixtures. Replaces the per-route
   parse, SIGTERM, parity-class and gap-marker set with one argv round trip, one replay and one cancel test per operation
   family. (B1 5, 6 and 10, B2 5.)

5. **Phase 3 exit text.** Target `architecture-program.md:199` and the 3.1 row at line 221. Rule. "No scientific golden
   moves in a Phase 3 commit. Help text and row words may change when the change makes them clearer to a person."
   Evidence. 47 help-golden recaptures, each for an intended change. Replaces "No golden and no cli-help capture moves in any Phase 3 commit" and "row texts are frozen".
   (B1 6, B2 6, B3.)
6. **Words people read.** Target `docs/contracts/EXPERT-PANEL.md` UX 1 (line 128) and UX 4 (line 131). Rule. "Words a
   person reads say what happened and what to do next in the person's terms, and frozen text applies only to output a
   program parses. Every alert goes through one shared presenter that names the step that failed and the next thing to
   try, and View Log holds the log tail." Evidence. The template behind the appQuit alert is pinned by
   `GenotypeManualHaplotypeDraftAlertTests.swift:42`, the GUI has 158 `NSAlert(` sites with 74 showing raw error text,
   and OBS-W5 ships internal workflow words. Replaces "equal the frozen strings" for GUI text and "a failure alert holds
   the error with the log tail as detail". (B3 5 and 6.)
7. **No silent outcomes, and refusals tried on real inputs.** Target `EXPERT-PANEL.md` (new UX 8) and
   `docs/contracts/RUNNING-A-TOOL.md`. Rule. "A row reads Completed only after its outputs exist where the person will
   look, and every refusal or failed save shows words in view. A change that refuses user input lands only after it
   passes on the real files users feed it, such as the official database archives." Evidence. OBS-W8 (a ZIP drop
   Completed with nothing added), OBS-W9 (a refusal with no words), Save Assignments silent since July (`900c0fabb`),
   and the 10.22 note that nobody knows whether the official Kraken2 and EsViritu archives hold such a link. Adds, and
   replaces nothing. (B2 9, B3 7.)
8. **GUI checks bind the candidate.** Target `docs/contracts/VERIFICATION-ORDER.md`, `config/test-catalog.json` and
   `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`. Rule. "Every final candidate runs the XCUI smoke and the switch matrix
   on the packaged app in a session that does not lock, and the result binds like the unit tier. A main-thread stall
   over two seconds in app code fails it. A new bundle kind joins the switch matrix in the change that adds it."
   Evidence. XCUI unchanged since 10-06, the missing script at `config/test-catalog.json:255`, and W1-T found only by a
   Debug trap during a walk. Replaces `config/test-catalog.json:6` and moves the 3.1 switch matrix ahead of the
   refactor. (B1, B3 3 and 4.)
9. **Load-sensitive tests.** Target `VERIFICATION-ORDER.md`, "A red unit tier is diagnosed, not retried". Rule. "Every
   wait uses the one shared budget. When every failure in a red unit tier is a timed-out wait in a display or routing
   test, those classes rerun once, and if they pass the session files one row and goes on. A test that fails only under
   load twice in a phase moves to a quarantine list that one lane clears per phase." Evidence. 112 test-only timing
   commits, four candidate fix rounds in 2.12, and 13 Provenance Inspector cases that failed on one 21 s stall and passed
   on retry (memory `unit-gate-load-flakes.md`). Replaces the no-retry rule for this one case. (B1 8, B2, B3.)
10. **Panel and review.** Target `EXPERT-PANEL.md`, "How the panel leads a session", "Scope", the Review stage and
    checklists, and walk rulings. Rule. "The panel meets twice in a phase, once to set scope and once at exit, and
    between those the manager decides inside the plan. Each lane gets one reviewer from the field it changes most, with
    BIO on any lane that touches results, and a finding names a defect a user, a replay or a later lane would meet. The
    panel votes only on S1 and S2 walk findings, and UX files the rest into a standing backlog." Evidence. About $3.8K by
    role, one review fix in six touching a user-visible defect, and a five-expert vote on a 1e-16 digit (OBS-W3). BIO
    stays on science lanes because BIO-R1 caught a real wrong answer. Replaces per-sub-phase inventories and memos, one
    reviewer per field, and votes on every walk row. (B1 1 and 2, B3 10 and 11.)

11. **One ledger run per phase.** Target `RUNNING-A-PHASE-SESSION.md`, "Every session runs the monitor" and
    "Checkpoint routine". Rule. "The manager runs the session ledger once at the end of a phase and adds one row to the
    cost table. The effort table of 2026-10-16 stands until a model changes." Evidence. Monitor $377 and A/B rounds
    $403. All-in cost per landed lane went from $25 to $49 (2.7 to 2.10) to $21 to $27 (2.11 to 2.14) while direct cost
    fell further, so the A/B rounds likely paid back but the checkpoints did not move the all-in figure (spot check 5).
    Replaces both sections. (B1 3, B2.)
12. **No published route keys.** Target `architecture-program.md:167` and `RUNNING-A-PHASE-SESSION.md`. Rule. "No route
    switch is published to users as a setting. While no Stable release carries the old route, a route moves in one step
    and the Preview before it is the rewind point." Evidence. 25 to 44 key commits, ten keys published in 10.18 and
    deleted in 10.20, and the part of 2.13 that existed to delete keys. Replaces "a key that 2.12 ships can be deleted
    only one release later". (B1 9, B2, B3 9.)
13. **Provenance at a methods minimum.** Target `docs/contracts/RECORDING-PROVENANCE.md`. Rule. "A record holds what a
    methods section and a rerun need, which is the tool and version that ran, every parameter, the reference and
    database with name, version and checksum, input and output checksums, the app version and the final status. Every
    classifier records its database identity before any other record work starts. A new field needs a request from a
    user or a reviewer, and tests check replay and the schema rather than where a field sits." Evidence. Line 66 leaves
    three classifiers unscheduled while 118 commits went to signing, stderr and naming. Replaces the signing family table
    (signing freezes as it is), the recorded-name rules and the two-window stderr rule, which becomes "keep the last 8 KB
    of stderr". (B1 5, B2 3 and 4, B3.)
14. **Short plans, short contracts, true agent docs.** Target `RUNNING-A-PHASE-SESSION.md` ("Files the session keeps"),
    `docs/contracts/README.md` and `Sources/*/AGENTS.md`. Rule. "A phase plan holds scope, exit checks, budget and
    decisions in at most 300 lines, and records, rulings, votes and lane reports stay outside the repo. A contract states
    the current rules and the code that shows them in at most 20 KB, and dated history goes to the records. An agent doc
    row that a phase makes false is fixed in that phase." Evidence. Plans grew from 123 KB to 1.88 MB, contracts from
    60 KB to 427 KB, `ADDING-AN-OPERATION.md` is 55 KB, and two AGENTS.md rows still describe `Process()` sites that are
    gone. (B1 11 and 14.)
15. **Generated files and the size ratchet.** Target `AGENTS.md`, `RUNNING-A-PHASE-SESSION.md` and
    `scripts/ratchets/file-size.sh`. Rule. "The module map is generated at release time and not per lane. The size check
    fails a file that grows past the limit, keeps no per-file list, and lets a file already over the limit grow with one
    line of reason in the commit. A pure file move lands only with the change that needs it." Evidence. 319 module-map
    commits, 136 baseline commits, about 100 pure GUI moves, and `EsVirituDiagnostics.swift`, which exists because
    `EsVirituPipeline.swift` sat at its baseline. Replaces per-lane regeneration and the per-file baselines. (B1 7, B2 10,
    B3.)

**Rules to delete outright.**
- Decision T8 of 2.7 (`docs/plans/2026-10-11-phase-2-7.md:76`).
- "The exit criteria read literally" and "a key that 2.12 ships can be deleted only one release later"
  (`architecture-program.md:167`).
- Masks M-1 to M-6 (`CLI-EQUIVALENCE.md:38-43`) and the clipboard and share destinations row (line 49).
- The 321 `cli-help` byte captures and the `cli-events` transcript goldens.
- "No golden and no cli-help capture moves in any Phase 3 commit" (line 199) and "row texts are frozen" (line 221).
- "Equal the frozen strings" for GUI text in UX 1 and "holds the error with the log tail as detail" in UX 4.
- "All native XCUITests remain explicit app-smoke diagnostics" (`config/test-catalog.json:6`).
- The `EXPERT-PANEL.md` Scope row that sends every fix, probe or documentation session to a fresh expert per field,
  five-expert votes on S3 and S4 walk rows, and the prose rules applied to code and test comments.
- "Every session runs the monitor" and "Checkpoint routine" in `RUNNING-A-PHASE-SESSION.md`.
- The signing family table, the recorded-name rules and the two-window stderr rule in `RECORDING-PROVENANCE.md`.
- Per-lane module-map regeneration and per-file size baselines.
- The pin-first step of the CLI route recipe and decision G1 of the 2.10 plan.

## Spot checks

| # | Claim the report leans on | How checked | Result |
|---|---|---|---|
| 1 | No Stable in October, against a steady Stable cadence before | `rg` over `docs/release-notes/2026.{8,9,10}.*.md` for `^Channel:` and `Stable baseline` | **Pass.** All 24 October notes are Preview and all name `v2026.9.78`. August and September had 82 Preview and 16 Stable, the last Stable being 2026.9.78 |
| 2 | Phases 1 and 2 ran inside the plan's calendar, and the CLI-route sub-phases cost $4,308 (2.10 to 2.12) and $5,844 (2.10 to 2.13) | Plan headings at `architecture-program.md:95,149,186,394` and sums over `spend-by-session.md` | **Pass.** Phase 1 weeks 1 to 2, Phase 2 weeks 3 to 5, Phase 5 weeks 10 to 14. 2,240 + 965 + 812 + 291 = 4,308, and adding 1,446 and the 90 walk continuation gives 5,844, 45% of $12,904 |
| 3 | XCUI stood still and the ui profile names a missing script | `git ls-tree` at both commits, `git log` on the folder, `sed` on `config/test-catalog.json`, `ls scripts/release` | **Pass, one correction.** 20 files at base and head, 3 commits, the last `c1c0f1b2c` on 10-06. Line 6 says what B3 quotes. The missing `app-smoke-gate.sh` sits at line 255, not 254, and the 2.12 panel decisions already called it stale on 10-17 and left the fix to 3.1 |
| 4 | `Process()` went from 79 files to none, and the contract texts the amendments target read as cited | `git grep -lF 'Process()'` at both commits, `process-spawn.baseline`, `sed` on `CLI-EQUIVALENCE.md:7,38-43,49`, `RECORDING-PROVENANCE.md:66`, `EXPERT-PANEL.md:128,131`, `architecture-program.md:167,199,221`, `phase-2-7.md:76`, the pinned alert test at line 42 | **Pass.** 79 files at base. At head four files match, all of them AGENTS.md prose or `finishProcess()`, and the ratchet reads 0. Every quoted rule text matches. Side finding, two AGENTS.md rows are stale |
| 5 | The overhead and the parity work returned little | `phase-2-14/events.log:149,160`, 10.22 notes line 30, `RUNNING-A-PHASE-SESSION.md:174-181`, a count of `phase-2-13/reviews` | **Mixed.** OBS-W7 passes, since the walk saw no mismatch marks in the `bundle export-graphic` image and the panel split 3 to 2. B1's "all-in per lane from about $25 to about $24" is corrected to $25.16 to $48.62 (2.7 to 2.10) and $21.07 to $26.54 (2.11 to 2.14), while median direct cost fell from $13 to $24 to $5 to $15. B1's "39 of 135 reviews ask for no change" is not reproduced, because the reviews have no uniform verdict line, so the report drops it and relies on the two commit samples |

## Dissent and confidence

**Dissent kept on the record.**
- B3 holds its verdict that the length was "not warranted by what users received". The team says "partly" because the
  calendar was met and the early science was Essential. The two readings agree on every number.
- B2's Essential 22% stands as the right figure if Essential means result-changing science only.
- B1 would split LungfishWorkflow before RNA-seq, and would cap Previews at two a week.
- B2 would have deferred the Nextflow contract.

**Confidence.**
- High on the Stable gap, the over-extension of CLI parity, the static XCUI suite, the pin and golden counts, and the
  rule texts. Each was measured or checked against the repo.
- Medium on the 30/35/35 split. Allocating dollars to commits is a model, and B1 shows that weighting by commit count
  instead of by lines can move one bucket by a factor of two. The split could be off by 10 points.
- Low on the size of the edge-case rabbit hole (under $100 to $1.45K) and on the cost of pin-then-change.
- The laptop phases (about $3.8K and 1,146 commits) are dark. They were mostly Essential.
- Commits show what reviews changed, not what they stopped. If reviews blocked many bad lanes before they landed,
  amendment 10 overstates the waste. Keeping BIO on science lanes limits that risk.
- B3's claim that six checks would have caught 12 of the 13 Stable blockers comes from the finding descriptions, not
  from building the checks. XCUI on the Mac Studio needs a session that does not lock (memory `screen-lock-blocks-gui-walk.md`).
- Nobody knows how many labs run Stable rather than Preview. If almost all run Preview, the Stable gap costs less, though
  the gate and release-note findings stand.
- The value judgments are a core facility's and a desktop shop's. A regulated clinical lab would value signing and byte
  replay more, and nothing in the repo shows such a user today.
