# Architecture program, phased implementation plan (2026-10-02)

Status: active. The structural program closed on 2026-11-11 (`docs/reports/2026-11-11-program-review/SUMMARY.md`), and this file is now the plan of the process job, the trust session and Phase 5. Companion to docs/reports/2026-10-02-architecture-review/REVIEW.md (finding IDs R1 to R18 below refer to it).

## Phase 3, Stable first, then the surface contract

Sub-phases (audit of 2026-10-26, replacing the six sub-phases of 2026-10-17). Each sub-phase states its budget before it starts, and at one and a half times the budget the manager starts no new lane until the owner answers. No session adds a sub-phase.

| Id | Scope | Depends on | Budget | Owner decisions needed first |
|---|---|---|---|---|
| 3.0 | Stable. The five Stable blockers OBS-W4, OBS-W6, OBS-W7, OBS-W8 and OBS-W9, each red test first, then obs-22. Point the `ui` profile at `scripts/release/app_smoke_gate.py` (`config/test-catalog.json:255` names a script that never existed) with an XCUI smoke of about ten tasks. Cut the owner check list to at most 20 rows. A packaged walk with the owner at the Mac, then promote to Stable. Beside these, lanes that touch no viewer file take the 3.0 rows of `docs/plans/BACKLOG.md` (MAP-POOLED-PAIRS, MAP-PAIRED-UNBOUND, ESV-READCOUNT-FLAGS, TOOL-TIME-LIMIT, WAIT-QUARANTINE and GEN-MAP), and one documentation lane does BACKLOG-MOVE | Phase 2 exit | 1 session, about $500 | Rows 17, 35 and 13 of `docs/reports/2026.10.24-owner-checks.md`, which the manager asks at the start of 3.0 |
| 3.1 | The quality net, then the classifier core. A view-switch test in a real window for every kind (one viewer installed, only the current Inspector blocks, the frame inside the screen) and one alert presenter in plain words. Database identity for EsViritu, TaxTriage and NAO-MGS. Then 3a's ResultViewport, ViewportHost and SurfaceRegistry with TwelveS and PrimerAnalysis as exemplars, then NaoMgs, EsViritu, TaxTriage, Nvd, Kraken2 (its view moved into a leaf by pure move first) and CzId, with 3e's ClassifierResultActions folded in. Each migration is one revertible PR closed by its view-switch test and a short walk. Ends with a Stable | 3.0 | 2 sessions, about $2,500 | The label set of 3e, ruled by UX at entry |
| 3.2 | The other viewer kinds onto ViewportHost, one revertible PR each closed by its view-switch test and a short walk, in this order. Genotype, MSA, phylogenetics and assembly, then the FASTA collection, FASTQ dataset, VCF dataset, MHC reference and Quick Look views, then mapping and reference last. Then the hide list and the optional viewer slots are deleted, and 3b's sidebar registry over BundleKindRegistry retires the three prefix tables with one read-only fallback for manifest-less legacy bundles. Beside these, 3.2 takes GitHub issue 35 and the BLAST rows of O130 and O138 (`0c972abf4:docs/plans/2026-11-03-phase-3-2.md:35`). Ends with a Preview (O128) | 3.1 | 2 sessions, about $3,000 | [6] GEN tags, only if a lane touches those notes |
| 3.3 | The demultiplexing run reads the index in the read names (an S1 that BIO ruled old), the Demux plan reaches the run, Detect counts the read-name index, the smoke gate runs from a checked copy and the walk rows 3.2 left, as `0c972abf4:docs/plans/2026-11-06-phase-3-3.md:62` sets. O159 set aside the first monthly Stable it planned. The owner added this sub-phase on 2026-11-06 (O154), since the table's rule says no session adds one | 3.2 | 1 session, no dollar figure (O154) | none, the panel decides under the owner's delegation (O154) |
| 3.4 | Finish Phase 3 with a Preview and tidy the repository for Phase 4, as `docs/plans/2026-11-08-phase-3-4.md` sets. The owner added this sub-phase on 2026-11-08 (O160) | 3.3 | 1 session, no dollar figure (O78) | none, the panel decides under the standing go (O126) |
| Deferred | 3c's typed event layer beyond a lint on new `Notification.Name` declarations, 3d's OperationLauncher beyond refuse-and-name-the-holder, and the old 3.1's frozen row texts, per-kind accessibility snapshot gate, classifier export byte pins and new ratchets other than viewport hides. The read-ID and unique-count pins of the classifiers stay | User work that touches the files, and Phase 5 for 3d, where RNA-seq brings the first new launch kind | none | none |

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

The review of 2026-11-11 (`docs/reports/2026-11-11-program-review/SUMMARY.md`) closed the structural program. R1 to R5, R7, R14 and R15 are closed. R6, R8 to R13, R16 and R18 are held by their ratchets and move only when a lane that a user outcome sends into the code touches them. R17 is Phase 5.

Phase 4 ends with the Preview of its first session, as `docs/plans/2026-11-09-phase-4.md` sets. That Preview carries the riders and FIGURE-DEPTH. MATRIX-SPLIT-1, L4B-DRAWER, L4D-SEAMS, L4D-GENO, the later 4a slices, the Q-S7-LOCK ruling, MEASURE-AFTER, 4e and 4f are closed and not moved. L4D-PILOT is not landed, and its branch `4db82a4a8` stays in the phase bundle as the recipe for a new domain target. One rule replaces them (`docs/contracts/SCOPE-AND-DELIVERY.md`, Which work earns a lane). A file over the limit is split by the first lane that a user outcome sends into it, as that lane's first commits, with `verify_pure_move.py`.

Reported at the close and never checked are the files over 3,000 lines, the build-time row, the source-text count and the hatch counts.

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

## The trust session and Phase 5

Owner direction O68 held RNA-seq until Phases 3 and 4 exit. Phase 4 exits with its Preview, so that entry is met.

### User outcome

A bench scientist brings bulk or single-cell RNA-seq into LGE, either as results another tool already made or as reads that LGE quantifies on the Mac or on a Linux machine. They get a count table tied to a named reference set, a quality view in the tool's own numbers, and an export that their R or Python workflow reads. Every number equals the tools run by hand on a public test set, and each result records its reference, annotation, kit, instrument, tool versions and the command that reproduces it.

### The route, decided by the second round of the review

The owner left the route to the experts (O166). `seats/R2-SCIENCE.md` and `seats/R2-ARCH.md` of the review hold the reasons and the facts checked.

| Stage | Decision |
|---|---|
| Bulk quantification | Import first (nf-core/rnaseq tables, salmon folders, DRAGEN quant files). Then salmon with selective alignment, on the Mac and on Linux from one plan step |
| Bulk kits with UMIs | Linux only. STAR, then umi_tools with the directional method, then salmon, as nf-core/rnaseq does |
| Single cell (10x 3' and 5' gene expression) | Import Cell Ranger and STARsolo output first. Then STARsolo on Linux. LGE never ships or downloads Cell Ranger, since its licence forbids it |
| Heavy compute | Linux, as a native tool chain under the executor plan that read preprocessing uses. The Mac writes a plan folder, any x86-64 Linux machine runs it in the tool image, and the Mac adopts the result folder. No Nextflow on the node |
| Quality | In LGE, from the tools' own files. A MultiQC report opens as a document |
| Differential expression and enrichment | Hand off first. One export (raw counts, gene lengths, sample sheet, gene table) with a DESeq2 template and an edgeR, limma voom and dream template. A guarded run in the app comes later, on a user's ask |
| Pseudobulk | In LGE. It sums UMI counts by sample and by a label table the analyst exports from Seurat or Scanpy |
| Clustering, annotation, embeddings, spatial | Out. Seurat, Scanpy, Loupe and Xenium Explorer stay the users' tools |
| Isoforms | Transcript rows are kept and exported. Their analysis is out |

A reference set is one named object with checksums that bulk, single cell, the Mac and Linux share. It holds the genome FASTA, the GTF with its source and release, the transcript FASTA and gene table derived from them, the indexes, and extra sequences such as the virus. The defaults are GRCh38 with GENCODE for human, Mmul_10 with Ensembl for rhesus with T2T-MMU8v2.0 offered beside it, and T2T-MFA8v1.1 with RefSeq for cynomolgus. A virus counts as one feature a genome or segment, carries a not-host flag and stays out of size factors, and counts from two reference sets never join in one table.

One bundle kind holds a result, with a bulk or single-cell modality. A bulk matrix loads whole. A single-cell matrix is kept as given with its checksum and is never loaded, rewritten or converted. One streaming pass writes a per-cell summary to SQLite, and tables page from it. LGE reads Matrix Market text and links no HDF5 library.

### Owner answers of 2026-11-11

| Id | Question | The owner's answer | What it sets |
|---|---|---|---|
| O161 | Promote Phase 4's closing Preview to a stable release? | "Yes, we can do a release at the end of Phase 4. Make sure our Stable packaging workflow contract is effective and efficient." | A stable release follows Phase 4's closing Preview by the steps of `docs/contracts/VERIFICATION-ORDER.md`, Promoting a Preview to a stable release |
| O162 | Is the first use bulk host-response RNA-seq only? | "We should assume both bulk and single cell RNAseq when this is built" | Phase 5 covers bulk and single-cell |
| O163 | Hosts and libraries | "We should support UMIs, humans, rhesus, and cynomolgus macaques with common Illumina / 10X workflows." | Three host references, UMI handling, and the common Illumina and 10x kits |
| O164 | Does the lab run nf-core/rnaseq on CHTC or a server? | "No, but we probably should support using the Linux orchestrator to do the heavy compute, like we do with the read pre-processing." | Heavy alignment and quantification run on Linux through the executor |
| O165 | May the first release stop at a count table and an export that DESeq2 reads? | "Yes" | Sub-phase 5.1, and no in-app statistics until a user asks |
| O166 | The route | "Whatever the experts decide." The owner's notes from a meeting with RNA-seq users are in `~/lungfish-phase-records/review-2026-11-11/briefs/OWNER-ANSWERS.md` | The route decided by the second round of the review, above |
| O167 | Move the repository out of `~/Documents`? | "This is a good idea. Relocate it somewhere sensible, maybe a new ~/lge folder? Make sure it doesn't break GitHUb" | `docs/contracts/MACHINES.md`, Where the repository lives, at the close of Phase 4 |
| O168 | Start the user manual now? | "I want to finish all of the phases first, then revisit the user manual and screencasts." | No change |

### Asks of the owner before 5.0

| Ask | Why |
|---|---|
| Of the lab's last ten experiments, how many used a bulk kit with UMIs, and how many sampled the same animal more than once? | The first decides whether bulk needs the STAR route in 5.4. The second decides whether a later in-app test must handle repeated animals |
| Which reference did the lab's existing macaque runs and Cell Ranger references use? | The macaque defaults |
| Which versions of nf-core/rnaseq and Cell Ranger made the results people hold, with one result folder of each | The importers of 5.1 and 5.2 read those layouts |
| What does the note "Are S10s available" mean? | The reviewers could not read it |
| The positive control data from the lab member | The acceptance walk of 5.1 and 5.2. It is not a pin, since it is not public |

### The trust session, with sub-phase 5.0 inside it

One session of about 16 lanes. It ends in a Preview when a lane lands a fix a user can see or a result fix. BIO names the two families of the sweep, and the review suggests variant calling with Viral Recon consensus, then MHC genotyping.

| Lane | What it does | Proof |
|---|---|---|
| SWEEP-1, SWEEP-2 | The truth sweep. For one tool family each, run the tool by hand on a real public data set with real-shaped inputs (sample names with spaces, a virus in segments, two samples of one taxon, a negative control) and compare every number the app shows and exports with the tool's own files | A table of numbers compared. Each difference is a finding with its severity, and an S1 or S2 becomes a lane |
| PROBES | The 21 backlog rows whose rating waits on a measurement, each probed in at most 40 calls or rated by BIO as if the condition holds | No row keeps a conditional rating |
| SCALE-SMOKE | A real-size corpus in the golden cache (a 20,000-record FASTA, a 100,000-read FASTQ bundle, a BAM of about 1 GB, one result of each viewer kind). One XCUI test opens each in the packaged app and fails when the main thread does not answer for 5 s or the footprint passes a bound. MAIN-THREAD-BLOCK leaves the backlog | The test is red on 2026.11.1's FASTA hang and green on the head |
| MEM-WORDS | A managed tool that ends by SIGKILL or exit 137 says it stopped, most likely for memory, with the peak it reached. The app and the CLI stop in words before they grow past a set share of memory | Tests on a stand-in that is killed |
| UPGRADE-CORPUS | One project a release, made by the `lungfish-cli` inside the DMGs of the last stable release and the newest Preview, with one result of every kind. A check lists, verifies and exports every result with the candidate's CLI and fails on a difference | The check runs after the golden compare |
| AFFECTED | A table in the app of results that a fixed S1 made wrong (result kind, builds, one sentence, what to do). A result whose record names such a build shows the sentence in its viewer and Inspector | A test on a record of an affected build |
| TWINS | The walk rows left unwalked since 2026.11.3 become XCUI tests in a second profile that does not bind, or close on UX's or BIO's word. The owner list is written new at 20 rows | The list's row count, and the tests on the package |
| P5-LAYOUT (5.0), opus, no code | The bundle layout in `docs/formats/` and the fixtures. One nf-core/rnaseq result of the yeast test set, salmon folders, a Cell Ranger `outs/` folder cut to about 200 cells, a STARsolo folder, and 10x's public pbmc_1k_v3 matrix | The fixtures in the golden cache with the script that made them |
| P5-PINS (5.0) | BIO states the numbers from salmon by hand and from the tools' own summaries, and which outputs are pinned byte for byte and which by a tolerance | A pin table in this plan |
| P5-REFS (5.0) | For human, rhesus and cynomolgus, the assembly and annotation release of each default, and the count of annotation contigs missing from the FASTA, which must be 0 | A one-page report |
| SPIKE-STREAM (5.0) | No app code. One streaming pass over a matrix of 500,000 cells on the Mac | Under 10 minutes and under 1 GB, or the design of 5.2 changes |
| SPIKE-SALMON (5.0) | No app code. Salmon from a lock entry on Apple silicon, with index and quantification of one real-size sample on a human and a macaque reference set, peak memory, disk and time | The figure for a 16 GB Mac |
| P5-PREMISES (5.0) | ARCH checks every row of 5.1 to 5.5 against the head and writes corrections into this plan as a Premises corrected table | The table, at a commit no more than seven days old |
| SURFACE-RECIPE (5.0) | The touch-point table of `ADDING-AN-ANALYSIS-SURFACE.md` rewritten from the real App files of the 12S leaf and the CZ ID import, with the Workflow Operations dialog as a third launch family in `ADDING-AN-OPERATION.md` | The path check passes |

Exit of 5.0. The fixtures and pins are in the golden cache, the two spikes have their numbers, and the tables below are confirmed or corrected.

### 5.1, counts in and counts out (bulk, no new tool, no Linux)

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

### 5.2, cells in and pseudobulk out (single cell, no Linux)

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| RS-SC-IMPORT | opus | The Matrix Market reader over the gzip streams, the summarizer and `cells.sqlite`, for Cell Ranger (also `cellranger multi`) and STARsolo folders. The `.h5` file is kept with its checksum and not read | Per-cell sums equal numbers from a tool run directly on the fixture. The tool's own summary is shown as given, with chemistry and version from its files |
| RS-SC-VIEW | sonnet | The summary, the barcode rank plot and three histograms, paged from SQLite | Bins equal `cells.sqlite`. A matrix of 500,000 cells opens inside the bound of SPIKE-STREAM |
| RS-PSEUDOBULK | opus, BIO review | `lungfish-cli rnaseq pseudobulk` with a label table (barcode and label). Groups under 10 cells are dropped and said | Sums by group equal an independent sum, and a replay of the recorded command gives the same table |
| RS-SC-HANDOFF | sonnet | The matrix folder with Seurat and Scanpy templates, and the pseudobulk table into 5.1's export | The templates read the fixture and report the cell count of the tool's summary |
| RS-SC-GLUE | sonnet, UX review | The import sheet rows and the words | UX reads the words |

Exit checks. X1 the Preview and its walk on the lab's positive control. X2 the per-cell pin. X3 the pseudobulk pin and its replay. X4 the 500,000-cell bound. X5 the templates run. X6 no S1 or S2 open.

### 5.3, reference sets and salmon on the Mac

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| RS-LOCK | sonnet | Salmon and gffread in the managed-tools lock for both platforms | Lock tests, `doctor` green |
| RS-REFSET | opus | The reference set for human, rhesus and cynomolgus with extra sequences, its derived files and its id | A transcript id in one file and not the other is refused with the names listed. Nothing is renamed. A changed virus sequence makes a new id |
| RS-INDEX | sonnet | The salmon index, cached by the reference set id, salmon version, k and decoys | A second run reuses it, and the key is in the record |
| RS-QUANT | opus | `lungfish-cli rnaseq quant` through the existing executor, one recorded step a sample, mates by `READ-PAIRING.md`, the virus flagged not-host | CLI and app parity. The recorded command reproduces the pinned counts within BIO's pin class |
| RS-PREFLIGHT | sonnet | One shared preflight in Workflow that refuses in words before a run that cannot fit, and names the Linux route | A refusal test. No scientific parameter changes |
| RS-DIALOG | sonnet, UX review | The launch dialog and the Operations row words | UX reads the words |

Exit checks. X1 the Preview and its walk from the dialog to a count table. X2 parity. X3 the recorded command reproduces the pin. X4 the reference refusal. X5 the index reuse test. X6 no S1 or S2 open.

### 5.4 and 5.5, the same steps on Linux, then STARsolo

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
| SOLO-PLAN (5.5) | opus, BIO review | The 10x chain for 3' and 5' gene expression, with the 10x filter rule on the GTF and the barcode list from the user's install or a licensed public source | STARsolo on pbmc_1k_v3 against 10x's public matrix, at BIO's threshold |
| SOLO-LIVE (5.5) | manager | One real 10x library on CHTC, adopted | The cells and counts equal the node's own summary |

Exit checks. X1 a Preview after 5.4 and one after 5.5, each with its walk of the plan sheet and the adopt. X2 the stand-in parity. X3 the adopted bundle equals a direct import. X4 version 1 plans are unchanged. X5 the live batch equals the tools by hand. X6 no S1 or S2 open.

Phase 5 exits when 5.5's checks pass. Later, and only on a user's ask, come a guarded differential expression in the app (edgeR with limma voom, dream for repeated animals, DESeq2 for two groups), fgsea, a launch of the user's own Cell Ranger from a staged archive, an H5 and h5ad converter, nf-core/rnaseq as a Nextflow launch on a Mac with Docker, a splice view, and spatial data.

### Budget

Computed as `docs/contracts/SCOPE-AND-DELIVERY.md` sets, at $24 a landed lane ($36 for a lane that adds a type, a viewer or a launch), $120 a session and $100 a packaged candidate, with two candidates a Preview.

| Session | Lanes | Dollars | Week points |
|---|---|---|---|
| Trust session with 5.0 | 16 | about $700 | about 36 |
| 5.1 and 5.2, two Previews | 12 | about $900 | about 45 |
| 5.3 | 6 | about $500 | about 25 |
| 5.4 and 5.5, two Previews | 10 | about $900 | about 45 |
| Total | 44 | about $3,000, ask line $4,500 | about 150 |

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
