# Architecture program, phased implementation plan (2026-10-02)

The structural program closed on 2026-11-11 (`docs/reports/2026-11-11-program-review/SUMMARY.md`), and this file is now the plan of the process job, the trust session and Phase 5. Companion to docs/reports/2026-10-02-architecture-review/REVIEW.md (finding IDs R1 to R18 below refer to it).

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

From the FASTQ files of an infection experiment and a sample sheet, a bench scientist gets gene counts for every sample, a quality table (reads, mapping rate, the library type the tool detected, the viral share) and a differential expression table for a design they wrote, on the Mac they have. Every number equals the tools run by hand on a public test set, and each result records its reference, annotation, library type, tool versions and the `lungfish-cli` command that reproduces it.

### Owner questions, asked at the Phase 4 close

The manager takes the default when no answer comes, and the owner can reverse it.

| Id | Question | Default |
|---|---|---|
| Q1 | Promote Phase 4's closing Preview to a stable release? Stable 2026.10.29 lacks 14 fixes rated S1 | Yes, as its own short job |
| Q2 | Is the first use bulk Illumina host-response RNA-seq in macaque and human, with no single-cell, long-read or isoform work? | Yes |
| Q3 | Which hosts and annotations, and which libraries does the lab make (stranded or not, paired or single, UMIs, 3' tag kits)? | Human GENCODE and rhesus Mmul_10 Ensembl, stranded paired reads, no UMI |
| Q4 | Does the lab already run nf-core/rnaseq on CHTC or a server? | Unknown. Sub-phase 5.1 opens those folders either way |
| Q5 | May the first release stop at a count table and an export that DESeq2 reads, with DESeq2 in the app one release later? | Yes |
| Q6 | The route for running from LGE, picked after the measured run of 5.0. Native salmon on any Mac, or nf-core/rnaseq under Docker | Native salmon. No STAR, HISAT2 or junction track until a user asks |
| Q7 | Move the repository out of `~/Documents`, where privacy prompts cost over six hours in Phase 3? | Yes, one owner act of about 15 minutes |
| Q8 | Start the user manual for the surfaces of Phases 1 to 4 in a separate session? | No change. Each release note carries a short how-to |

### The trust session, with sub-phase 5.0 inside it

One session of about 16 lanes. It ends in a Preview when a lane lands a fix a user can see or a result fix. BIO names the two families of the sweep, and the review suggests variant calling with Viral Recon consensus, then MHC genotyping.

| Lane | What it does | Proof |
|---|---|---|
| SWEEP-1, SWEEP-2 | The truth sweep. For one tool family each, run the tool by hand on a real public data set with real-shaped inputs (sample names with spaces, a virus in segments, two samples of one taxon, a negative control) and compare every number the app shows and exports with the tool's own files | A table of numbers compared. Each difference is a finding with its severity, and an S1 or S2 becomes a lane |
| PROBES | The 21 backlog rows whose rating waits on a measurement, each probed in at most 40 calls or rated by BIO as if the condition holds | No row keeps a conditional rating |
| SCALE-SMOKE | A real-size corpus in the golden cache (a 20,000-record FASTA, a 100,000-read FASTQ bundle, a BAM of about 1 GB, one result of each viewer kind). One XCUI test opens each in the packaged app and fails when the main thread does not answer for 5 s or the footprint passes a bound. MAIN-THREAD-BLOCK leaves the backlog | The test is red on 2026.11.1's FASTA hang and green on the head |
| MEM-WORDS | A managed tool that ends by SIGKILL or exit 137 says it stopped, most likely for memory, with the peak it reached. The app and the CLI stop in words before they grow past a set share of memory | Tests on a stand-in that is killed |
| UPGRADE-CORPUS | One project a release, made by the `lungfish-cli` inside the DMGs of Stable 2026.10.29 and the newest Preview, with one result of every kind. A check lists, verifies and exports every result with the candidate's CLI and fails on a difference | The check runs after the golden compare |
| AFFECTED | A table in the app of results that a fixed S1 made wrong (result kind, builds, one sentence, what to do). A result whose record names such a build shows the sentence in its viewer and Inspector | A test on a record of an affected build |
| TWINS | The walk rows left unwalked since 2026.11.3 become XCUI tests in a second profile that does not bind, or close on UX's or BIO's word. The owner list is written new at 20 rows | The list's row count, and the tests on the package |
| P5-PINS (5.0) | BIO states the public test set (small SRA data, O43), the numbers from salmon and tximport and from DESeq2 run by hand, and which outputs are pinned byte for byte and which by a tolerance | The data in `/Users/Shared/lungfish-golden` with its script in `scripts/golden/` |
| SPIKE-SALMON (5.0) | No app code. Salmon from a lock entry on Apple silicon. Index and quantification of the test set and of one real-size sample (30 M pairs) on galah, with peak memory, disk and time, and the figure for a 16 GB Mac | A one-page report |
| SPIKE-NFCORE (5.0) | No app code. The nf-core/rnaseq `test` profile on galah with the lock's Nextflow under Docker, salmon-only and with STAR. Time, peak memory, any container fault, and the result folder's file tree saved as a fixture listing | A one-page report |
| SPIKE-DESEQ2 (5.0) | No app code. A solved Apple silicon environment with R, tximport and DESeq2 and its explicit lock file, run on the pin matrix | The lock file, or the fallback and its cost |
| P5-PREMISES (5.0) | ARCH checks every row of 5.1 to 5.3 against the head and writes corrections into this plan as a Premises corrected table | The table, at a commit no more than seven days old |
| SURFACE-RECIPE (5.0) | The touch-point table of `ADDING-AN-ANALYSIS-SURFACE.md` rewritten from the 12S leaf's 21 App files, with the Workflow Operations dialog as a third launch family in `ADDING-AN-OPERATION.md` | The path check passes |

Exit of 5.0. Q2 to Q6 are answered or defaulted, the two spikes say with numbers what fits galah and a 16 GB Mac, the pin data is in the golden cache, and the tables below are confirmed or corrected. If neither route fits a 16 GB Mac, 5.2 is replanned and the owner is asked.

### 5.1, open and trust a count table

The same on either route, so it goes first. It ends in a Preview.

| Lane | Model | Files it owns | Proof |
|---|---|---|---|
| ARMS | sonnet | The switches over `FASTQOperationToolID` and the Workflow Operations kind | No `default` arm is left, so a new case fails the build at every arm |
| CM-TYPE | opus | New `Sources/LungfishIO/Analysis/CountMatrix*.swift` and `ExperimentDesign*.swift` | Round trip. Transcript and gene level with counts, TPM and effective length, sample ids exact |
| CM-IMPORT | sonnet | `lungfish-cli import rnaseq <folder>` and its Import Center row, for salmon quant folders and for nf-core/rnaseq merged tables | Gene sums equal tximport by hand on the pin set. Source checksums and the detected library type are in the record. A folder that is not a result is refused in words |
| CM-KIND | sonnet | The bundle kind, the sidebar registry row and the view-switch test | The kind opens in the real-window view-switch test in the same change |
| CM-LEAF | opus | New target `LungfishRNASeqUI` and the count table viewport through `ResultViewport` | Counts on screen equal the source table cell for cell. Search, sort and a minimum-count filter. Opens the real-size set inside a stated time and footprint |
| CM-QC | sonnet | The leaf's quality panel | Library size, mapping rate, library type and viral share equal the tool's own files |
| CM-DESIGN | sonnet | The sample sheet editor and its validation | A sheet whose ids differ from the columns fails with a named error |
| CM-EXPORT | sonnet | Export for DESeq2 (the quant folders or matrix, the sheet and an R script that uses tximport) | The script runs in the 5.0 environment and equals the pin |

Exit checks. X1 a Preview ships after its walk. X2 an imported table equals its source (BIO's pin). X3 the view-switch test passes with the new kind. X4 the quality numbers equal the tool's files. X5 the two refusals show their words. X6 no S1 or S2 of this Preview is open. Reported and not checked is the count of LungfishApp files edited.

### 5.2, run quantification from LGE

The table is for the default route, native salmon. If the owner picks nf-core/rnaseq at Q6, the lanes are the ten steps of `ADDING-A-NEXTFLOW-WORKFLOW.md` section 8 with the same exits.

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| RS-LOCK | sonnet | Salmon in the managed-tools lock and the `rna-seq` pack | Lock tests, `doctor` green |
| RS-REF | opus | The quantification reference. A transcript FASTA, a transcript-to-gene map from its GTF with its checksum, and extra sequences such as the virus | A transcript id in one and not the other is refused with the names listed. Nothing is renamed |
| RS-INDEX | opus | The salmon index, cached by FASTA checksum, salmon version, k and decoys | A second run reuses it, and the key is in the record |
| RS-QUANT | opus | `lungfish-cli rnaseq quant` through the existing executor in a new `LungfishRNASeq` target, one recorded step a sample, mates by `READ-PAIRING.md` | CLI and app parity. The recorded command reproduces the pinned counts within BIO's pin class |
| RS-PREFLIGHT | sonnet | One shared preflight in Workflow that refuses in words before a run that cannot fit (needs X GB, this Mac has Y, what to try). No queue | A refusal test. No scientific parameter changes |
| RS-DIALOG | sonnet, UX review | The launch dialog and the Operations row words | UX reads the words |
| RS-FINALIZE | sonnet | Finalize calls 5.1's import and opens the table | The run's table equals a direct import of the same folder |
| RS-SCALE | sonnet | A run of 12 samples of 30 M pairs measured on galah, with peak memory and time in the record | The figures in the technical record |

Exit checks. X1 the Preview and its walk from the dialog to a count table. X2 parity. X3 the recorded command reproduces the pin. X4 the reference refusal. X5 the index reuse test. X6 no S1 or S2 open.

### 5.3, compare groups

| Lane | Model | What it builds | Proof |
|---|---|---|---|
| ENV-DRIFT | sonnet | Before a managed tool runs, its environment is compared with the lock's explicit list. A difference is said in words with Reinstall offered, and the record says the run was off the lock | A test on an environment with one changed package |
| DE-ENV | sonnet | The locked R environment as a managed tool, with its own library and no user profile | Versions recorded |
| DE-RUN | opus | `lungfish-cli rnaseq de` in `LungfishRNASeq`. One factor with optional batch and paired subject | It refuses TPM input, a group with no replicates and an id mismatch, each in words |
| DE-PIN | sonnet, BIO review | The pin test | LGE's table equals DESeq2 run by hand, at printed precision |
| DE-KIND, DE-VIEW | sonnet, opus | The result kind and its viewport with MA and volcano plots. A row opens its gene in the count table | The view-switch test, and numbers on screen equal the result file |
| DE-DIALOG | sonnet, UX review | The contrast dialog (design, reference level, threshold) | UX reads the words |
| DE-TRACE | sonnet | One provenance test | A result traces by checksum to its table, run, reads, FASTA and GTF |

Exit checks. X1 the Preview and its walk. X2 the DE pin. X3 the three refusals. X4 the recorded command reproduces the table. X5 the trace test. X6 no S1 or S2 open.

Phase 5 exits when 5.3's checks pass. Later, and only on a user's ask, come nf-core/rnaseq as a launch (if not picked at Q6), HISAT2 or STAR genome alignment, a junction view as a new layer of the figure scene, resource admission by class, kallisto and single-cell.

### Budget

Computed as `docs/contracts/SCOPE-AND-DELIVERY.md` sets, at $24 a landed lane ($36 for a lane that adds a type, a viewer or a launch), $120 a session and $100 a packaged candidate, with two candidates a Preview.

| Session | Lanes | Dollars | Week points |
|---|---|---|---|
| Trust session with 5.0 | 16 | about $700 | about 36 |
| 5.1 | 8 | about $560 | about 28 |
| 5.2 | 8 | about $600 | about 30 |
| 5.3 | 8 | about $560 | about 28 |
| Total | 40 | about $2,400, ask line $3,600 | about 122 |

The week points bind. A session starts with at least 35 points of the week free, and 5.1 and 5.2 may run back to back in one session when the week allows.

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

Questions Q1 to Q8 under The trust session and Phase 5. Whether primer "legacy salvage" is still a user-facing mode. Whether Kraken2's CLI command moves to a top-level `classify` with `conda classify` kept as an alias.
