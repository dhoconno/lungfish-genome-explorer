# Architecture program, phased implementation plan (2026-10-02)

Status: active. The structural program closed on 2026-11-11 (`docs/reports/2026-11-11-program-review/SUMMARY.md`), and this file is now the plan of the process job, the trust session, Phase 5 (Biomark X) and Phase 6 (RNA-seq). Companion to docs/reports/2026-10-02-architecture-review/REVIEW.md (finding IDs R1 to R18 below refer to it).

## Phase 3, Stable first, then the surface contract

Sub-phases (audit of 2026-10-26, replacing the six sub-phases of 2026-10-17). Each sub-phase states its budget before it starts, and at one and a half times the budget the manager starts no new lane until the owner answers. No session adds a sub-phase.

| Id | Scope | Depends on | Budget | Owner decisions needed first |
|---|---|---|---|---|
| 3.0 | Stable. The five Stable blockers OBS-W4, OBS-W6, OBS-W7, OBS-W8 and OBS-W9, each red test first, then obs-22. Point the `ui` profile at `scripts/release/app_smoke_gate.py` (`config/test-catalog.json:255` names a script that never existed) with an XCUI smoke of about ten tasks. Cut the owner check list to at most 20 rows. A packaged walk with the owner at the Mac, then promote to Stable. Beside these, lanes that touch no viewer file take the 3.0 rows of `docs/plans/BACKLOG.md` (MAP-POOLED-PAIRS, MAP-PAIRED-UNBOUND, ESV-READCOUNT-FLAGS, TOOL-TIME-LIMIT, WAIT-QUARANTINE and GEN-MAP), and one documentation lane does BACKLOG-MOVE | Phase 2 exit | 1 session, about $500 | Rows 17, 35 and 13 of `docs/reports/2026.10.24-owner-checks.md`, which the manager asks at the start of 3.0 |
| 3.1 | The quality net, then the classifier core. A view-switch test in a real window for every kind (one viewer installed, only the current Inspector blocks, the frame inside the screen) and one alert presenter in plain words. Database identity for EsViritu, TaxTriage and NAO-MGS. Then 3a's ResultViewport, ViewportHost and SurfaceRegistry with TwelveS and PrimerAnalysis as exemplars, then NaoMgs, EsViritu, TaxTriage, Nvd, Kraken2 (its view moved into a leaf by pure move first) and CzId, with 3e's ClassifierResultActions folded in. Each migration is one revertible PR closed by its view-switch test and a short walk. Ends with a Stable | 3.0 | 2 sessions, about $2,500 | The label set of 3e, ruled by UX at entry |
| 3.2 | The other viewer kinds onto ViewportHost, one revertible PR each closed by its view-switch test and a short walk, in this order. Genotype, MSA, phylogenetics and assembly, then the FASTA collection, FASTQ dataset, VCF dataset, MHC reference and Quick Look views, then mapping and reference last. Then the hide list and the optional viewer slots are deleted, and 3b's sidebar registry over BundleKindRegistry retires the three prefix tables with one read-only fallback for manifest-less legacy bundles. Beside these, 3.2 takes GitHub issue 35 and the BLAST rows of O130 and O138 (`0c972abf4:docs/plans/2026-11-03-phase-3-2.md:35`). Ends with a Preview (O128) | 3.1 | 2 sessions, about $3,000 | [6] GEN tags, only if a lane touches those notes |
| 3.3 | The demultiplexing run reads the index in the read names (an S1 that BIO ruled old), the Demux plan reaches the run, Detect counts the read-name index, the smoke gate runs from a checked copy and the walk rows 3.2 left, as `0c972abf4:docs/plans/2026-11-06-phase-3-3.md:62` sets. O159 set aside the first monthly Stable it planned. The owner added this sub-phase on 2026-11-06 (O154), since the table's rule says no session adds one | 3.2 | 1 session, no dollar figure (O154) | none, the panel decides under the owner's delegation (O154) |
| 3.4 | Finish Phase 3 with a Preview and tidy the repository for Phase 4, as `docs/plans/2026-11-08-phase-3-4.md` sets. The owner added this sub-phase on 2026-11-08 (O160) | 3.3 | 1 session, no dollar figure (O78) | none, the panel decides under the standing go (O126) |
| Deferred | 3c's typed event layer beyond a lint on new `Notification.Name` declarations, 3d's OperationLauncher beyond refuse-and-name-the-holder, and the old 3.1's frozen row texts, per-kind accessibility snapshot gate, classifier export byte pins and new ratchets other than viewport hides. The read-ID and unique-count pins of the classifiers stay | User work that touches the files, and Phase 6 for 3d, where RNA-seq brings the first new launch kind | none | none |

The six exit checks of Phase 3, with the state of each at the close of 3.4. The states come from `docs/plans/2026-11-08-phase-3-4.md` (decisions A and B, section Phase 3's exit and the exit checks X1 to X6) and from the record of Preview 2026.11.5 (`docs/reports/2026.11.5-technical.md`).

| Check | Passes when | State | Evidence |
|---|---|---|---|
| 1 | Stable shipped from 3.0 (2026.10.27) and from 3.1 (2026.10.29), Previews from 3.2 (2026.11.1, 2026.11.2) and from 3.3 (2026.11.3, 2026.11.4), and a Preview from 3.4 with its packaged walk and the whole verification order. Phase 3 exits with that Preview, which carries the user-visible fixes named in `docs/plans/2026-11-08-phase-3-4.md` (owner direction O160, `docs/contracts/SCOPE-AND-DELIVERY.md`, Stable on a clock). The next monthly Stable carries Phase 3's work when the owner asks for one (O159). No Phase 3 check waits for it. | Met for the Preview, its packaged walk and the verification order. X1 also asks that the full tier on the published commit has a verdict, and the plan records that verdict in section Phase 4's entry criteria, row Phase 3 exit. Decision A rewrote this check, 5 to 0 | Tag `v2026.11.5`, build 12859, commit `a46e89605`, with its smoke, walk, QA read and publish in `docs/reports/2026.11.5-technical.md`. Plan exit check X1 |
| 2 | No S1 or S2 finding is open. | Met at the close of 3.4. It read not met at the start (BIO and UX), and X3 and X5 closed it. The packaged walk left no S1 or S2 open, `ExactBareWordsXCUITests` ran on the package with no skip, the three TaxTriage prefix tests passed in the unit tier, and the Rescan twin ran green once | `SCR/walk/walk-log.md:500`, `SCR/reviews/CANDIDATE-a46e896052de2c0e2f03e1b7566cde80c1d3e83e-QA.md` sections 1, 3 and 4, plan section Phase 3's exit row 2 and exit checks X3 and X5 |
| 3 | The real-window view-switch test of every kind passes in the unit tier, and the XCUI smoke with its view-switch test passes on the packaged candidate, in a session that does not lock, for every kind with a fixture that needs no managed tool. | Met with notes, by QA's ruling at `0c972abf4`. The plan rules no more than that. Decision A reworded the check to the 3.2 plan's narrower words for the packaged half, and the plan leaves that half to check 1 and exit check X1 | Plan section Phase 3's exit row 3, decision A |
| 4 | A stub surface and a stub bundle kind in a test target open from the sidebar with no App edit beyond registration, and the five classifiers share one action component whose extraction tests check read IDs against known lists. | Met with notes, by ARCH's ruling at `0c972abf4`. The plan names nothing more to close it | Plan section Phase 3's exit row 4 |
| 5 | Every classifier records its database by name, version and checksum. | Met with notes, by BIO's ruling at `0c972abf4`. The plan names nothing more to close it | Plan section Phase 3's exit row 5 |
| 6 | Every viewer kind opens through ViewportHost, the hide list and the optional viewer slots are gone, and the sidebar routes every kind through the registry with one read-only fallback for legacy bundles. | Met with notes, by the ruling of SWIFT and ARCH at `0c972abf4`, which holds that the base sequence view is not a kind (ARCH, Q-S1). The plan names nothing more to close it. Decision B closed check 6 of the 3.2 and 3.3 plans on the BLAST hold and rules nothing on this row | Plan section Phase 3's exit row 6, decision B |

The budget of Phase 3 is five sessions, about $6,000 measured, and at $9,000 the manager stops for the owner. The audit's dissent is recorded in its report. Both science seats would run a science session before any viewport code, and both teams would have left the eleven later viewer migrations until user work touched them, which O70 overrode.

## Phase 4, closed at its first session's Preview

The review of 2026-11-11 (`docs/reports/2026-11-11-program-review/SUMMARY.md`) closed the structural program. R1 to R5, R7, R14 and R15 are closed. R6, R8 to R13, R16 and R18 are held by their ratchets and move only when a lane that a user outcome sends into the code touches them. R17 is Phase 6.

Phase 4 ends with the Preview of its first session, as `docs/plans/2026-11-09-phase-4.md` sets. That Preview carries the riders and FIGURE-DEPTH. By the owner's word (O170) and the panel's ruling at the close, MATRIX-SPLIT-1 and L4B-DRAWER landed, the Q-S7-LOCK ruling is written and MEASURE-AFTER runs after the Preview, while L4D-SEAMS, L4D-GENO, the later 4a slices, 4e and 4f are closed with measured reasons. L4D-PILOT landed at the close by the owner's word (O169) and is the recipe for a new domain target. One rule replaces them (`docs/contracts/SCOPE-AND-DELIVERY.md`, Which work earns a lane). A file over the limit is split by the first lane that a user outcome sends into it, as that lane's first commits, with `verify_pure_move.py`.

Reported at the close and never checked are the files over 3,000 lines, the build-time row, the source-text count and the hatch counts.

The six exit checks of Phase 4, with the state of each at the close. The checks are X1 to X6 of `docs/plans/2026-11-09-phase-4.md` (section Exit checks) with the three changes of its section Close of Phase 4. The states come from the QA reads of Preview 2026.11.6 (SCR `reviews/CANDIDATE-7dc5e466c15a76ed7ab13fdc06f3024ac4b90302-QA.md`, section 7) and of Stable 2026.11.7 (SCR `reviews/CANDIDATE-6b6e0c0f33f55fdfee566fff4d2c84ed602695b0-QA.md`) and from the records `docs/reports/2026.11.6-technical.md` and `docs/reports/2026.11.7-technical.md`. Phase 4 published Preview 2026.11.6 (tag `v2026.11.6`, build 12962, commit `7dc5e466c`) and, by the owner's ask (O161), Stable 2026.11.7 (tag `v2026.11.7`, build 12972, commit `6b6e0c0f3`).

| Check | Passes when | State | Evidence |
|---|---|---|---|
| X1 | The last packaged Preview passes its walk of the changed screens and the XCUI smoke with no skip, no S1 or S2 finding of its walk or gates is open, and the full tier on its commit has a verdict. At the close X1 reads the integration and conformance tiers where it reads the full tier, and the walk keeps the drawer, matrix and saved 12S rows | Met with a named gap. The smoke on the published package of P3 passed 12 of 12 with no skip and restored the preferences exactly. The whole full tier, which holds the integration and conformance tiers, ran on P2 from 17:39:52 to 19:15:30 and read GATE PASS, and P3 and S inherit it over docs-only paths. Walkers 1 to 4 passed every changed screen that background control could drive, rows 12 and 18 again on build 12960 after round 2, and no S1 or S2 finding is open. The gap is the owner rows, which block no release. The drawer, matrix and saved 12S rows (15, 16 and 17) got background screenshots only, and rows 5, 11, 14, the hover of 19, the track change of 2, the file route of 18 and the hands-on parts of 10, 16 and 17 wait for the owner | SCR `cand/smoke-3.log`, `cand/chain-2.log`, `cand/full-2.log`, `cand/full-evidence-3.log`, `walk/walk-log-2026.11.6.md:553-554`, the Preview QA read sections 4 and 7, `docs/reports/2026.11.6-owner-checks.md` |
| X2 | Depth across a spliced read and a deleted read equals `samtools depth` (`ReadTrackRendererCoverageDepthPinTests` on the Preview's commit, BIO's numbers) | Met. The two pins of L4C-PIN passed in LAND-1, and the unit-tier record of P2 lists both among its added tests | SCR `cand/x6-3.log:42-43`, the unit-tier record `gate-20261111-171722-a8384152d-65587` of P2, the Preview QA read section 7 |
| X3 | Genotype workbooks, the matrix and the haplotype band read the numbers of 2026.11.5, and nothing under `Tests/Fixtures/golden/genotype-gui/` or `Tests/Fixtures/golden/genotype/exports/` moved | Met. No file under `Tests/Fixtures/golden` changed from `77a13f511` to P3, the 133 genotype golden files matched, and the bundle `LungfishGenotypeUITests` of the full tier, which holds the four characterization suites, passed on P2 | SCR `cand/golden-2.log`, the full-tier record `gate-20261111-173952-a8384152d-55294`, the Preview QA read section 7 |
| X4 | A recorded `lungfish-cli` run still reproduces (`python3 scripts/golden/golden.py compare` on that commit, no scientific golden moved) | Met. The golden compare passed on P2 in 109.3 s with no golden moved, and P3 and S change docs only | SCR `cand/golden-2.log`, `cand/chain-2.log` |
| X5 | Each rider that landed and that a person can reach reads fixed on its screen in the same walk. `KRAKEN-TOTAL-FALLBACK` and `EXTRACT-SCAN-EXTENDED-ID` are held by the tests their rows name. A figure exported with the filters set equals the window's strip, and the NAO-MGS header equals Unique Taxa | Met with a named gap. Read on their screens were the Results button of row 12 on build 12960, the NAO-MGS header against Unique Taxa (row 13, 4 and 4 with five samples, 2 and 2 with one) and the background half of `KRAKEN-TOTAL-FALLBACK` (row 19). `KRAKEN-TOTAL-FALLBACK` and `EXTRACT-SCAN-EXTENDED-ID` are held by their tests. The gap is FIGURE-DEPTH (rows 10 and 11, a Save panel), the ONT words (row 14, an Open panel) and the hover half of row 19, which no walker could drive in background control and which wait for the owner | SCR `walk/walk-log-2026.11.6.md:50-65`, `:116-121`, `:476-504`, `:537-540`, the Preview QA read section 7 and item R4 |
| X6 | No test that guards a result was lost in a move (`python3 scripts/testing/test_set_diff.py` against SCR `cand/gate-base-a46e89605.result.json`, no GONE outside the allow list). At the close X6 runs with the allow list SCR `lanes/L4B-DRAWER/deleted-tests.txt` | Met with a named gap. Run 3 on the unit-tier record of P2 read GONE 3 with all 3 allowed, ADDED 54, MOVED 0 and exit 0. Its allow list, SCR `lanes/X6-allow-all.txt`, is wider than the plan's by the two Demultiplex tests that lane DEMUX-STAGED-INPUT deleted with the staging they pinned, which QA's ruling allowed with their replacements named. The ruling names two S4 test gaps that are not new. No test sends a physical multi-file bundle through the dialog with Cutadapt or Read Names (backlog row DEMUX-STAGED-INPUT-S4-GROUP item 4), and no command-line test runs `--engine header-index` on a multi-file bundle (row X6-CLI-HEADERINDEX-MULTIFILE) | SCR `cand/x6-1.log`, `cand/x6-2.log`, `cand/x6-3.log`, `rulings/X6-QA.md` |

## The process job, before the trust session

One short job with no meeting, no monitor and no Preview rebuilds what a session runs on. The seat reports `B1.md` and `B2.md` of the review hold each lane's facts. Every lane is documentation or scripts with tests, on sonnet at max, with one QA review of the whole job.

| Lane | Product | Proof |
|---|---|---|
| CONFLICTS | The 14 contradictions of `B2.md` F1 settled, one value each, in the contract that owns the rule | A grep for each old sentence finds nothing |
| AGENT-TYPES | Typed agents in `.claude/agents/` with `model` and `effort` in their frontmatter and each role's rules in at most 6 KB (`lge-lane`, `lge-lane-opus`, `lge-review`, `lge-fix`, `lge-land`, `lge-ruling`, `lge-planner`, `lge-walker`, `lge-release`). The lane-rules stack of the records folder goes | One trial spawn of each type shows its model and effort |
| SESSION-SCRIPTS | A tracked `scripts/session/` with tests (`preflight.py`, `lane_start.sh`, `agent_ended.py`, `reap_build.py`, `ctx_watch.py`, `memwatch.py`, `heartbeat.sh`, `run_gates.py`, `put_state.py`, `end_hung_app.py`) | `scripts/tests` green, and each contract row names its command |
| CONTRACT-SIZE | `scripts/checks/contract-size.py` with a byte baseline in the pre-push checks. A file over its cap may only shrink | The check fails on a grown file |
| RUN-TRIM, EP-TRIM, VO-TRIM | `RUNNING-A-PHASE-SESSION.md` to 12 KB for the orchestrator only, `EXPERT-PANEL.md` to 10 KB, `VERIFICATION-ORDER.md` to 12 KB with galah's measured times. Reasons move to the records as evidence tags. `LLM-EVIDENCE.md` and `CLAUDE-CODE-PRACTICES.md` leave the repository | The size check passes at the caps |
| OWNER-DIRECTIONS | `docs/contracts/OWNER-DIRECTIONS.md`, at most 6 KB, each direction with its id, date, the owner's words and whether it is in force | The owner reads it once |
| BACKLOG-SPLIT | `BACKLOG.md` holds open S1, S2 and probe rows and the rows of this and the next phase in at most 80 KB. Other open rows go to `backlog-later.tsv`. Done rows are deleted. `scripts/checks/backlog.py` holds the caps and prints one phase's rows | The check passes, and the hook limit has room |
| START-SHAPE | A START prompt template of at most 4 KB filled by `preflight.py`. It restates no rule and orders no meeting | The next START prompt fits it |
| FILESIZE-RULE | `scripts/ratchets/file-size.sh` lets a landing raise a baselined row for a fix lane and refuses a commit that only removes blank lines | The ratchet's own tests |
| SHORT-PATH | `analysis-surface-checklist.md` becomes the one path for a new operation and surface in at most 10 KB, each box naming its exemplar by path and symbol. Clauses that wait on a closed phase are deleted | A sonnet agent given only that file lists the files of a new command |

Budget. Ten lanes at $24 and $120 for the session, about $360, with no candidate.

## The trust session

One session of about 14 lanes, before Phase 5. It ends in a Preview when a lane lands a fix a user can see or a result fix. BIO names the two families of the sweep, and the review suggests variant calling with Viral Recon consensus, then MHC genotyping. The four lanes of sub-phase 5.0 run beside these and start when the lab's Biomark X files are at hand.

| Lane | What it does | Proof |
| SWEEP-1, SWEEP-2 | The truth sweep. For one tool family each, run the tool by hand on a real public data set with real-shaped inputs (sample names with spaces, a virus in segments, two samples of one taxon, a negative control) and compare every number the app shows and exports with the tool's own files | A table of numbers compared. Each difference is a finding with its severity, and an S1 or S2 becomes a lane |
| PROBES | The 21 backlog rows whose rating waits on a measurement, each probed in at most 40 calls or rated by BIO as if the condition holds | No row keeps a conditional rating |
| SCALE-SMOKE | A real-size corpus in the golden cache (a 20,000-record FASTA, a 100,000-read FASTQ bundle, a BAM of about 1 GB, one result of each viewer kind). One XCUI test opens each in the packaged app and fails when the main thread does not answer for 5 s or the footprint passes a bound. MAIN-THREAD-BLOCK leaves the backlog | The test is red on 2026.11.1's FASTA hang and green on the head |
| MEM-WORDS | A managed tool that ends by SIGKILL or exit 137 says it stopped, most likely for memory, with the peak it reached. The app and the CLI stop in words before they grow past a set share of memory | Tests on a stand-in that is killed |
| UPGRADE-CORPUS | One project a release, made by the `lungfish-cli` inside the DMGs of the last stable release and the newest Preview, with one result of every kind. A check lists, verifies and exports every result with the candidate's CLI and fails on a difference | The check runs after the golden compare |
| AFFECTED | A table in the app of results that a fixed S1 made wrong (result kind, builds, one sentence, what to do). A result whose record names such a build shows the sentence in its viewer and Inspector | A test on a record of an affected build |
| TWINS | The walk rows left unwalked since 2026.11.3 become XCUI tests in a second profile that does not bind, or close on UX's or BIO's word. The owner list is written new at 20 rows | The list's row count, and the tests on the package |

Budget. Fourteen lanes with the four of 5.0, about $660 and about 34 points of the week.

## Phase 5, Biomark X SNP genotyping and parentage

The owner added this phase on 2026-11-11 and put it before RNA-seq. "We use this instrument to do parentage assays using SNPs throughout the genome. We need to understand how genotypes are currently called with the BiomarkX software, then we need to implement this into LGE so we can import the BioMarkX data files and perform the SNP analyses and interpretation within the LGE interface." The research behind this plan, with its sources, is `seats/BIOMARK.md` of the review. No Biomark, Fluidigm or parentage code exists in the tree today.

### User outcome

A person imports the files of a Biomark X genotyping run. LGE shows the chip, its assays and samples, the calls and the intensity plot of every assay, checks the run's quality, and assigns each offspring's sire and dam from the candidate animals with a verdict and the loci that support it. Imported calls equal the vendor's, LGE's own calls agree with the vendor's on the lab's runs at a rate BIO sets, and every result records the run, the panel, the settings and the command that reproduces it.

### What is known and what is not

| Topic | State |
|---|---|
| Runs | Genotyping uses 48.48, 96.96, Flex Six and 192.24 chips with SNP Type (FAM and HEX) or TaqMan (FAM and VIC) assays and ROX as the reference dye. The current software is Standard BioTools SNP Genotyping Analysis. Whether the lab's runs are read at the end point or in real time is not confirmed |
| Exports | The software writes four CSV exports (summary, detailed, call map, detailed with raw data). The call map layout is verified from a real file. It has a header block with the confidence threshold and the normalization method, then sections `SNP Calls` (XX, XY, YY, No Call, NTC, Invalid) and `SNP Converted Calls` (bases). Delimiters and offsets vary, so a reader finds sections by their marker and never by line number |
| The calling method | Not documented in any page the research could open. From secondary sources it normalizes by SNP Type or by the no-template controls, clusters each assay's scatter plot, and applies a confidence threshold that the user sets. The vendor's guides sit behind links that returned nothing, so the method must come from the guide PDFs the lab holds and from the lab's own files |
| Raw intensities | Only the detailed export with raw data, or the native run file, holds them. Neither was seen, and no open tool re-clusters them. No paper compares the vendor's calls with an independent method |
| Parentage | 60 to 100 SNPs are enough for likelihood methods. Exclusion alone needs about 40% more loci. A mismatch tolerance near 1% and the verdict bands of ISAG and ICAR (accepted, doubtful, excluded) are the model of good practice. No published SNP parentage panel or tolerance for rhesus or cynomolgus was found, so the lab's panel is the only source |
| Test data | Twelve real call map files are public (final calls only). No public raw-intensity file and no macaque parentage truth set exist, so parentage is pinned on a simulated pedigree and on the lab's solved cases |

### What the lab must supply before 5.1

Without these the phase cannot start, since the file layouts and the calling method cannot be taken from public sources.

| Item | Used for |
|---|---|
| One complete Biomark X run folder with all four exports of that run, and one older run if old data must import | The readers of 5.1 and the re-calling of 5.2 |
| The SNP Genotyping Analysis version, and the vendor's analysis guides as PDFs | The calling method |
| The assay panel (names, the two alleles, chromosome and position with its assembly, the species each assay works in, sex or origin markers, known problem assays) | The panel file and the base calls |
| The lab's calling settings and habits (confidence threshold, normalization, no-template controls, when a call is changed by hand, repeat rules) | The defaults and the review screen |
| Sample and plate maps as the lab imports them, and the animal identifier scheme | The sample sheet |
| Candidate sire and dam lists, the existing pedigree, and how results go back into the colony records | Parentage and its export |
| The decision rule in use today, and a few solved and unsolved cases | The truth for 5.3 |

### 5.0, read the files and write the methods (in the trust session, no app code)

| Lane | Model | Product | Proof |
|---|---|---|---|
| BMX-FILES | opus | The layout of every export and of the run folder, written in `docs/formats/` from the lab's real files, with fixtures cut from them and the public call maps | A script reads every file the lab gave and reports each section and column |
| BMX-CALLING | opus, BIO | The vendor's calling method as the guides state it, and a script outside the app that calls genotypes from the raw export. It reports agreement with the vendor's automatic calls for each assay | The agreement rate on the lab's runs, and BIO's threshold for 5.2. If the method cannot be matched, 5.2 keeps the vendor's call as the record and shows LGE's clusters as a check |
| BMX-PARENTAGE | opus, BIO | The parentage method. Exclusion with a tolerance and a likelihood score with a genotyping error rate, the panel's power from allele frequencies, and the verdict bands. A simulated pedigree with errors and missing parents | The method assigns the simulated pedigree at the error rate BIO states and agrees with the lab's solved cases |
| P5-PREMISES | opus, ARCH | Every row of 5.1 to 5.3 checked against the head, written here as a Premises corrected table | The table, at a commit no more than seven days old |

### 5.1, import a run and see it

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| BMX-KIND | sonnet | Targets `LungfishSNPAssay` and `LungfishSNPAssayUI`, one bundle kind for a run, its manifest and registry rows | The kind opens from the sidebar and joins the view-switch test |
| BMX-IMPORT | opus | `lungfish-cli snp import` for the exports, found by section marker, with the header block (software version, confidence threshold, normalization, dye mapping) in the record. The original files are kept with their checksums | Calls equal the vendor's export cell for cell on every fixture. A file that is not an export is refused in words |
| BMX-PANEL | sonnet | The panel file (assay, alleles, position, assembly, species) and the sample sheet with animal identifiers, controls and replicates | An assay the panel does not know, or one with other alleles than the export, is said in words |
| BMX-VIEW | opus | The call map as a table, and one scatter plot an assay drawn from the stored intensities and coloured by call | Table and plot equal the stored values, and a 192.24 chip opens inside a stated time |
| BMX-QC | sonnet, BIO review | Call rate for each sample and assay, the no-template controls, invalid chambers, replicate agreement, and flags at the lab's thresholds | The numbers equal an independent count on the fixtures |
| BMX-GLUE | sonnet, UX review | The Import Center card, its sheet and the CLI runner, and an export of calls as a table | The sheet's argv parses through the real subcommand |

Exit checks. X1 a Preview ships after its walk on one of the lab's runs. X2 imported calls equal the export. X3 the view-switch test passes with the new kind. X4 the quality numbers equal an independent count. X5 the refusals show their words. X6 no S1 or S2 of this Preview is open.

### 5.2, call and review genotypes

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| BMX-CALL | opus, BIO review | `lungfish-cli snp call`, the method of BMX-CALLING in the app, with every setting recorded. The vendor's call and LGE's call sit side by side | Agreement with the vendor's automatic calls at BIO's threshold on the lab's runs, and each disagreement is listed |
| BMX-REVIEW | opus, UX review | A person changes a call or marks a chamber invalid on the plot. Each change is recorded with who, when and why, and the automatic call is kept | A changed call survives a reopen, and the record lists it |
| BMX-MERGE | sonnet | One genotype table an animal across chips and runs, with the rule for replicates that disagree | The table equals a hand merge of two fixture runs |
| BMX-IDENTITY | sonnet, BIO review | Duplicate and swapped samples by genotype match, and sex against the record when the panel carries a marker | Two fixture samples of one animal are found, and a swapped pair is flagged |

Exit checks. X1 the Preview and its walk. X2 the agreement rate. X3 a manual change is recorded and kept. X4 the merged table pin. X5 the duplicate test. X6 no S1 or S2 open.

### 5.3, parentage and its report

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| PAR-INPUT | sonnet | Candidate sire and dam lists and the existing pedigree, with dates that rule a candidate out | An animal born after the offspring is refused as a parent in words |
| PAR-RUN | opus, BIO review | `lungfish-cli snp parentage` in `LungfishSNPAssay`. Exclusion with a tolerance, the likelihood score, duo and trio cases, and a missing parent | The simulated pedigree at BIO's error rate, and the lab's solved cases |
| PAR-POWER | sonnet, BIO review | The panel's power for the animals at hand from allele frequencies, and a warning when the loci typed are too few to decide | The figures equal a calculation by hand on a small panel |
| PAR-VIEW | opus, UX review | For each offspring the verdict (accepted, doubtful, excluded, unresolved), the ranked candidates, and the loci that mismatch | Numbers on screen equal the result file |
| PAR-REPORT | sonnet, UX review | A report and a table export in the form the colony records take | UX and the owner read one |
| PAR-TRACE | sonnet | One provenance test | A verdict traces by checksum to its runs, panel, settings and candidate list |

Exit checks. X1 the Preview and its walk on a solved case of the lab's. X2 the simulated pedigree pin. X3 the lab's solved cases agree, and each that does not is explained. X4 the recorded command reproduces the result. X5 the trace test. X6 no S1 or S2 open.

### Budget

| Session | Lanes | Dollars | Week points |
|---|---|---|---|
| 5.0, inside the trust session | 4 | in that session's figure | in that session's figure |
| 5.1 and 5.2, two Previews | 10 | about $850 | about 42 |
| 5.3 | 6 | about $520 | about 26 |
| Total | 20 | about $1,400, ask line $2,100 | about 68 |

## Phase 6, RNA-seq (was Phase 5 until 2026-11-11)

Owner direction O68 held RNA-seq until Phases 3 and 4 exit. Phase 4 exits with its Preview, so that entry is met.

### User outcome

A bench scientist brings bulk or single-cell RNA-seq into LGE, either as results another tool already made or as reads that LGE quantifies on the Mac or on a Linux machine. They get a count table tied to a named reference set, a quality view in the tool's own numbers, and an export that their R or Python workflow reads. Every number equals the tools run by hand on a public test set, and each result records its reference, annotation, kit, instrument, tool versions and the command that reproduces it.

### The route, decided by the second round of the review

The owner left the route to the experts (O166). `seats/R2-SCIENCE.md` and `seats/R2-ARCH.md` of the review hold the reasons and the facts checked.

| Stage | Decision |
|---|---|
| Bulk quantification | Import first (nf-core/rnaseq tables, salmon folders, DRAGEN quant files). The default run is on Linux, STAR then salmon on the alignments, with STAR's gene counts kept beside it, since most published human and macaque studies align with STAR and the Quartet and MAQC benchmark of 45 laboratories recommends genome alignment. Salmon alone with selective alignment is the light route on the Mac, and the record says which route ran |
| Bulk kits with UMIs | A rare path (1 of 48 sampled series). Linux only. STAR, then umi_tools with the directional method, then salmon. Duplicates are never removed without UMIs |
| Single cell (10x 3' and 5' gene expression) | Import Cell Ranger and STARsolo output first. Then STARsolo on Linux for 10x 3' v3 and v3.1 and 5' v2, with two named presets (match Cell Ranger 4 to 6 with exons only, and match Cell Ranger 7 and later with introns counted), the preset in the record, and output in Cell Ranger's layout. Each chemistry is gated on agreement with 10x's public matrix. LGE never ships or downloads Cell Ranger, since its licence forbids it. Flex, Parse, BD Rhapsody, V(D)J and feature barcodes are import only |
| Heavy compute | Linux, as a native tool chain under the executor plan that read preprocessing uses. The Mac writes a plan folder, any x86-64 Linux machine runs it in the tool image, and the Mac adopts the result folder. No Nextflow on the node |
| Quality | In LGE, from the tools' own files. A MultiQC report opens as a document |
| Differential expression and enrichment | Hand off first. One export (raw counts, gene lengths, sample sheet, gene table) with a DESeq2 template and an edgeR, limma voom and dream template. A guarded run in the app comes later, on a user's ask |
| Pseudobulk | In LGE. It sums raw UMI counts by sample and by a label table the analyst exports from Seurat or Scanpy, drops groups under 10 cells with a note, refuses a comparison with fewer than 3 animals a group, and carries the animal identifier, since five benchmarks find that tests on single cells give false discoveries |
| Clustering, annotation, embeddings, spatial | Out. Seurat, Scanpy, Loupe and Xenium Explorer stay the users' tools |
| Isoforms | Transcript rows are kept and exported. Their analysis is out |

A reference set is one named object with checksums that bulk, single cell, the Mac and Linux share. It holds the genome FASTA, the GTF with its source and release, the transcript FASTA and gene table derived from them, the indexes, and extra sequences such as the virus. The defaults are GRCh38 with GENCODE for human, Mmul_10 with Ensembl for rhesus, with RefSeq's annotation as an equal choice and T2T-MMU8v2.0 offered, and T2T-MFA8v1.1 with RefSeq for cynomolgus, with Macaca_fascicularis_6.0 and 5.0 offered so that results compare with deposited tables. No T2T macaque assembly appears in any sampled study, and the cynomolgus field has no standard. LGE refuses to align one species to another's reference without the person saying so, and records species and origin for each animal. A virus counts as one feature a genome or segment, carries a not-host flag and stays out of size factors, and counts from two reference sets never join in one table. Viral counts are reported for each cell and for empty droplets, and one viral UMI is never called an infected cell. Mitochondrial genes are found by their contig and never by a name prefix, since Ensembl names the macaque genes ND1 and COX1 with no MT- prefix and a prefix test reads 0 percent. Genes of the MHC, KIR, immunoglobulin and T cell receptor loci are marked unreliable at gene level. The quality view reports the share of reads on globin and rRNA genes.

One bundle kind holds a result, with a bulk or single-cell modality. A bulk matrix loads whole. A single-cell matrix is kept as given with its checksum and is never loaded, rewritten or converted. One streaming pass writes a per-cell summary to SQLite, and tables page from it. LGE reads Matrix Market text and links no HDF5 library.

### Owner answers of 2026-11-11

| Id | Question | The owner's answer | What it sets |
|---|---|---|---|
| O161 | Promote Phase 4's closing Preview to a stable release? | "Yes, we can do a release at the end of Phase 4. Make sure our Stable packaging workflow contract is effective and efficient." | A stable release follows Phase 4's closing Preview by the steps of `docs/contracts/VERIFICATION-ORDER.md`, Promoting a Preview to a stable release |
| O162 | Is the first use bulk host-response RNA-seq only? | "We should assume both bulk and single cell RNAseq when this is built" | Phase 6 covers bulk and single-cell |
| O163 | Hosts and libraries | "We should support UMIs, humans, rhesus, and cynomolgus macaques with common Illumina / 10X workflows." | Three host references, UMI handling, and the common Illumina and 10x kits |
| O164 | Does the lab run nf-core/rnaseq on CHTC or a server? | "No, but we probably should support using the Linux orchestrator to do the heavy compute, like we do with the read pre-processing." | Heavy alignment and quantification run on Linux through the executor |
| O165 | May the first release stop at a count table and an export that DESeq2 reads? | "Yes" | Sub-phase 6.1, and no in-app statistics until a user asks |
| O166 | The route | "Whatever the experts decide." The owner's notes from a meeting with RNA-seq users are in `~/lungfish-phase-records/review-2026-11-11/briefs/OWNER-ANSWERS.md` | The route decided by the second round of the review, above |
| O167 | Move the repository out of `~/Documents`? | "This is a good idea. Relocate it somewhere sensible, maybe a new ~/lge folder? Make sure it doesn't break GitHUb" | `docs/contracts/MACHINES.md`, Where the repository lives, at the close of Phase 4 |
| O168 | Start the user manual now? | "I want to finish all of the phases first, then revisit the user manual and screencasts." | No change |

### What the literature set

The owner asked that recent literature, and not the lab's own practice, set the tools, references and control data (2026-11-11). Two reviewers sampled recent human and macaque infection, vaccine and immunology studies and the benchmark papers. Their reports with every citation are `seats/LIT-BULK.md` and `seats/LIT-SC.md` of the review, and the route table above holds their results. The usual library is poly-A, rRNA-depleted or SMART-Seq v4 at 20 to 50 million read pairs from whole blood, PBMC or tissue. DESeq2 leads the statistics, and only 1 of 20 macaque papers modelled repeated sampling of one animal, so the templates take an animal term and the sample sheet always asks for the animal.

Control data, all public. BIO picks the pins from these in 6.0, and every macaque run is cut to about 5 million pairs.

| Use | Data | Truth it gives |
|---|---|---|
| Bulk fixture | HBR and UHR with ERCC, chromosome 22 subset, 117 MB (genomedata.org) | The ERCC mix ratios |
| Bulk benchmark | SEQC samples A and B, GEO GSE47774 | TaqMan values for about 1,000 genes and the mix ratios |
| Rhesus bulk | GEO GSE304256 (whole blood, vaccine) and GSE301415 (deposited salmon output) | Deposited counts on Mmul_10 |
| Cynomolgus bulk | GEO GSE290671 (featureCounts table) and GSE341361 (repeated sampling, dream design) | Deposited counts |
| Bulk UMI kit | GEO GSE163196 and the small GSE300831 | Counts made with UMI-tools |
| 10x 3' v3 | pbmc_1k_v3, 5.55 GB of reads | 10x's own matrix and its 1,222 cells |
| 10x 5' v2 | sc5p_v2_hs_PBMC_1k, 7.98 GB | 10x's own matrix |
| Species mix | hgmm_1k_v3, 4.88 GB | Species purity and doublet rate |
| Rhesus 10x | GEO GSE293992 (3' v3.1, Mmul_10) and GSE183579 (with a virus in the reference) | Deposited matrices |
| Cynomolgus 10x | GEO GSE296788 (a pathogen in the reference) | Deposited matrices |

### 6.0, pins, fixtures and spikes (a short job at the start of Phase 6)

| Lane | What it does | Proof |
| SWEEP-1, SWEEP-2 | The truth sweep. For one tool family each, run the tool by hand on a real public data set with real-shaped inputs (sample names with spaces, a virus in segments, two samples of one taxon, a negative control) and compare every number the app shows and exports with the tool's own files | A table of numbers compared. Each difference is a finding with its severity, and an S1 or S2 becomes a lane |
| P6-LAYOUT, opus, no code | The bundle layout in `docs/formats/` and the fixtures. One nf-core/rnaseq result of the yeast test set, salmon folders, a Cell Ranger `outs/` folder cut to about 200 cells, a STARsolo folder, and 10x's public pbmc_1k_v3 matrix | The fixtures in the golden cache with the script that made them |
| P6-PINS | BIO states the numbers from salmon by hand and from the tools' own summaries, and which outputs are pinned byte for byte and which by a tolerance | A pin table in this plan |
| P6-REFS | For human, rhesus and cynomolgus, the assembly and annotation release of each default, and the count of annotation contigs missing from the FASTA, which must be 0 | A one-page report |
| SPIKE-STREAM | No app code. One streaming pass over a matrix of 500,000 cells on the Mac | Under 10 minutes and under 1 GB, or the design of 6.2 changes |
| SPIKE-SALMON | No app code. Salmon from a lock entry on Apple silicon, with index and quantification of one real-size sample on a human and a macaque reference set, peak memory, disk and time | The figure for a 16 GB Mac |
| P6-PREMISES | ARCH checks every row of 6.1 to 6.5 against the head and writes corrections into this plan as a Premises corrected table | The table, at a commit no more than seven days old |
| SURFACE-RECIPE | The touch-point table of `ADDING-AN-ANALYSIS-SURFACE.md` rewritten from the real App files of the 12S leaf and the CZ ID import, with the Workflow Operations dialog as a third launch family in `ADDING-AN-OPERATION.md` | The path check passes |

Exit of 6.0. The fixtures and pins are in the golden cache, the two spikes have their numbers, and the tables below are confirmed or corrected.

### 6.1, counts in and counts out (bulk, no new tool, no Linux)

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| ARMS | sonnet | The switches over `FASTQOperationToolID` and the Workflow Operations kind lose their `default` arms | A new case fails the build at every arm |
| RS-KIND | sonnet | Targets `LungfishRNASeq` and `LungfishRNASeqUI`, the bundle kind with its manifest, the registry rows and a stub surface | The kind opens from the sidebar and joins the view-switch test |
| RS-BULK-IMPORT | opus | `lungfish-cli rnaseq import` for a plain table, salmon folders, nf-core/rnaseq tables and DRAGEN quant files, with the sample sheet | Counts equal the source by value. Gene sums equal tximport by hand. Sample ids that differ are refused in words. The record states what the files state and reads Not recorded for the rest |
| RS-BULK-VIEW | opus | The table with gene search, and the quality view (library size, mapping rate, detected library type, rRNA and virus share, a sample correlation plot) | The table equals `counts.tsv`, and the quality numbers equal the tool's files |
| RS-HANDOFF | sonnet, BIO review | The export with the DESeq2 template and the edgeR, limma voom and dream template | Each template runs in a locked R environment on the pin and equals the numbers by hand |
| RS-INSTRUMENT | sonnet | At FASTQ import, the instrument id, run number, flowcell and lanes from the read names, a model inferred from the id and marked inferred, and `RunInfo.xml` when a run folder is at hand | A test on read names of three instrument families |
| RS-GLUE | sonnet, UX review | The Import Center card, its sheet and the CLI runner | The sheet's argv parses through the real subcommand |

Exit checks. X1 a Preview ships after its walk, which imports the lab's positive control. X2 an imported table equals its source (BIO's pin). X3 the view-switch test passes with the new kind. X4 the quality numbers equal the tool's files. X5 the refusals show their words. X6 no S1 or S2 of this Preview is open. Reported and not checked is the count of LungfishApp files edited, expected near 7.

### 6.2, cells in and pseudobulk out (single cell, no Linux)

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| RS-SC-IMPORT | opus | The Matrix Market reader over the gzip streams, the summarizer and `cells.sqlite`, for Cell Ranger (also `cellranger multi`) and STARsolo folders. The `.h5` file is kept with its checksum and not read | Per-cell sums equal numbers from a tool run directly on the fixture. The tool's own summary is shown as given, with chemistry and version from its files |
| RS-SC-VIEW | sonnet | The summary, the barcode rank plot and three histograms, paged from SQLite | Bins equal `cells.sqlite`. A matrix of 500,000 cells opens inside the bound of SPIKE-STREAM |
| RS-PSEUDOBULK | opus, BIO review | `lungfish-cli rnaseq pseudobulk` with a label table (barcode and label). Groups under 10 cells are dropped and said | Sums by group equal an independent sum, and a replay of the recorded command gives the same table |
| RS-SC-HANDOFF | sonnet | The matrix folder with Seurat and Scanpy templates, and the pseudobulk table into 6.1's export | The templates read the fixture and report the cell count of the tool's summary |
| RS-SC-GLUE | sonnet, UX review | The import sheet rows and the words | UX reads the words |

Exit checks. X1 the Preview and its walk on the lab's positive control. X2 the per-cell pin. X3 the pseudobulk pin and its replay. X4 the 500,000-cell bound. X5 the templates run. X6 no S1 or S2 open.

### 6.3, reference sets and salmon on the Mac

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| RS-LOCK | sonnet | Salmon and gffread in the managed-tools lock for both platforms | Lock tests, `doctor` green |
| RS-REFSET | opus | The reference set for human, rhesus and cynomolgus with extra sequences, its derived files and its id | A transcript id in one file and not the other is refused with the names listed. Nothing is renamed. A changed virus sequence makes a new id |
| RS-INDEX | sonnet | The salmon index, cached by the reference set id, salmon version, k and decoys | A second run reuses it, and the key is in the record |
| RS-QUANT | opus | `lungfish-cli rnaseq quant` through the existing executor, one recorded step a sample, mates by `READ-PAIRING.md`, the virus flagged not-host | CLI and app parity. The recorded command reproduces the pinned counts within BIO's pin class |
| RS-PREFLIGHT | sonnet | One shared preflight in Workflow that refuses in words before a run that cannot fit, and names the Linux route | A refusal test. No scientific parameter changes |
| RS-DIALOG | sonnet, UX review | The launch dialog and the Operations row words | UX reads the words |

Exit checks. X1 the Preview and its walk from the dialog to a count table. X2 parity. X3 the recorded command reproduces the pin. X4 the reference refusal. X5 the index reuse test. X6 no S1 or S2 open.

### 6.4 and 6.5, the same steps on Linux, then STARsolo

Spikes on a CHTC node come first, by the manager with the owner's CHTC access. They give STAR's peak memory, time and disk for the index and for one sample of 50 million pairs, the minutes a job spends placing a 30 GB index, the megabytes that come home a sample, and STARsolo against simpleaf on pbmc_1k_v3 (called cells, correlation with 10x's public matrix, memory). If simpleaf is as near to Cell Ranger at a fraction of the memory, it replaces STARsolo.

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| EX-SCHEMA, no code | opus | Plan schema 2 in `docs/formats/executor-plan.md`. A `tool` step kind, a `reference` entry role, an output policy a file (home or stays) and a pipeline identity | ARCH and BIO read it |
| EX-TOOL | opus | Schema 2 in LungfishPortable and the `tool` step in the plan runner | A schema 2 plan with a stand-in tool runs in a Mac replay and in the Linux tier, and no version 1 plan byte moves |
| EX-IMAGE | sonnet | Salmon, STAR and umi_tools in the Linux lock, and the image rebuilt at CHTC | The image manifest lists each tool at its pin |
| EX-INDEX | sonnet | `rnaseq index-plan` and the adopted index record. The index stays on Linux | The record's digests equal the run record's outputs |
| EX-PLAN | sonnet | The plan emitter for bulk (salmon, and the STAR and UMI route when the sheet names a UMI kit), staged reads and the request rule from the spikes | Plan bytes pinned on a fixture |
| EX-ADOPT | opus | The adopt split into its checks and its payload writer, with the RNA-seq payload | The adopted bundle equals `rnaseq import` of the same folder, and a FASTQ adopt is byte equal to before |
| EX-APP | sonnet, UX review | The plan sheet and the adopt card | The sheet's argv parses through the real subcommand |
| EX-LIVE | manager | One real bulk batch on CHTC, compared with the same tools by hand | The comparison in the technical record |
| SOLO-PLAN (6.5) | opus, BIO review | The 10x chain for 3' and 5' gene expression, with the 10x filter rule on the GTF and the barcode list from the user's install or a licensed public source | STARsolo on pbmc_1k_v3 against 10x's public matrix, at BIO's threshold |
| SOLO-LIVE (6.5) | manager | One real 10x library on CHTC, adopted | The cells and counts equal the node's own summary |

Exit checks. X1 a Preview after 6.4 and one after 6.5, each with its walk of the plan sheet and the adopt. X2 the stand-in parity. X3 the adopted bundle equals a direct import. X4 version 1 plans are unchanged. X5 the live batch equals the tools by hand. X6 no S1 or S2 open.

Phase 6 exits when 6.5's checks pass. Later, and only on a user's ask, come a guarded differential expression in the app (edgeR with limma voom, dream for repeated animals, DESeq2 for two groups), fgsea, a launch of the user's own Cell Ranger from a staged archive, an H5 and h5ad converter, nf-core/rnaseq as a Nextflow launch on a Mac with Docker, a splice view, and spatial data.

### Budget

Computed as `docs/contracts/SCOPE-AND-DELIVERY.md` sets, at $24 a landed lane ($36 for a lane that adds a type, a viewer or a launch), $120 a session and $100 a packaged candidate, with two candidates a Preview.

| Session | Lanes | Dollars | Week points |
|---|---|---|---|
| 6.0 | 7 | about $290 | about 15 |
| 6.1 and 6.2, two Previews | 12 | about $900 | about 45 |
| 6.3 | 6 | about $500 | about 25 |
| 6.4 and 6.5, two Previews | 10 | about $900 | about 45 |
| Total | 35 | about $2,600, ask line $3,900 | about 130 |

The week points bind, and a session starts with at least 35 points of the week free.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A pure move silently changes behaviour through access control or initialization order | Medium | High | No logic edits in move commits, golden fixtures and the unit gate per merge |
| Golden fixtures mask timestamps too loosely and hide a provenance regression | Medium | High | Mask only RFC 3339 timestamps and run IDs, diff everything else byte for byte |
| Source-text tests break on every rename and get deleted instead of replaced | High | Medium | Ratchet freezes the count, deletion allowed only with a behavioural replacement named in the commit |
| Lanes collide on shared files | Medium | Medium | Disjoint file sets per lane, install-git-hooks.sh owned by one lane, F2 and F4 serialized |
| The unit gate takes 12 to 14 minutes and serial merges stretch the night | High | Low | Merge documentation lanes first, batch F1 to F4 into one gate run |
| TaxTriage or PBAA break on Macs with a system JDK once JAVA_HOME is set | Low | High | Phase 1 smoke runs on both a JDK and a no-JDK machine before merge |
| Executor migration changes classifier result layout for existing projects | Medium | High | Legacy layout recognised by the scanner snapshot test, migration behind the old path until parity is green |
| Genotype extraction alters calls or ambiguity tokens | Low | Very high | Byte-identical workbook and matrix exports required per commit, notebook-parity fixtures |
| The agent indices drift as code moves | High | Medium | module-map-current.py, doc-path-references.py and features-yaml-sources.py in the pre-push hook |
| Primer legacy salvage removed while still scientifically used | Low | High | Owner confirmation required before any removal, CLI and dialog kept identical |

## Open decisions for the owner

Whether primer "legacy salvage" is still a user-facing mode. Whether Kraken2's CLI command moves to a top-level `classify` with `conda classify` kept as an alias.
