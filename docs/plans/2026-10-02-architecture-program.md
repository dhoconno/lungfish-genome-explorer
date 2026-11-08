# Architecture program, phased implementation plan (2026-10-02)

Status: active. Companion to docs/reports/2026-10-02-architecture-review/REVIEW.md (finding IDs R1 to R18 below refer to it). Delete both together when the program closes.

## Phase 3, Stable first, then the surface contract

Sub-phases (audit of 2026-10-26, replacing the six sub-phases of 2026-10-17). Each sub-phase states its budget before it starts, and at one and a half times the budget the manager starts no new lane until the owner answers. No session adds a sub-phase.

| Id | Scope | Depends on | Budget | Owner decisions needed first |
|---|---|---|---|---|
| 3.0 | Stable. The five Stable blockers OBS-W4, OBS-W6, OBS-W7, OBS-W8 and OBS-W9, each red test first, then obs-22. Point the `ui` profile at `scripts/release/app_smoke_gate.py` (`config/test-catalog.json:255` names a script that never existed) with an XCUI smoke of about ten tasks. Cut the owner check list to at most 20 rows. A packaged walk with the owner at the Mac, then promote to Stable. Beside these, lanes that touch no viewer file take the 3.0 rows of `docs/plans/BACKLOG.md` (MAP-POOLED-PAIRS, MAP-PAIRED-UNBOUND, ESV-READCOUNT-FLAGS, TOOL-TIME-LIMIT, WAIT-QUARANTINE and GEN-MAP), and one documentation lane does BACKLOG-MOVE | Phase 2 exit | 1 session, about $500 | Rows 17, 35 and 13 of `docs/reports/2026.10.24-owner-checks.md`, which the manager asks at the start of 3.0 |
| 3.1 | The quality net, then the classifier core. A view-switch test in a real window for every kind (one viewer installed, only the current Inspector blocks, the frame inside the screen) and one alert presenter in plain words. Database identity for EsViritu, TaxTriage and NAO-MGS. Then 3a's ResultViewport, ViewportHost and SurfaceRegistry with TwelveS and PrimerAnalysis as exemplars, then NaoMgs, EsViritu, TaxTriage, Nvd, Kraken2 (its view moved into a leaf by pure move first) and CzId, with 3e's ClassifierResultActions folded in. Each migration is one revertible PR closed by its view-switch test and a short walk. Ends with a Stable | 3.0 | 2 sessions, about $2,500 | The label set of 3e, ruled by UX at entry |
| 3.2 | The other viewer kinds onto ViewportHost, one revertible PR each closed by its view-switch test and a short walk, in the order of the task table above. Genotype, MSA, phylogenetics and assembly, then the FASTA collection, FASTQ dataset, VCF dataset, MHC reference and Quick Look views, then mapping and reference last. Then the hide list and the optional viewer slots are deleted, and 3b's sidebar registry over BundleKindRegistry retires the three prefix tables with one read-only fallback for manifest-less legacy bundles. Beside these, 3.2 takes GitHub issue 35 and the BLAST rows of O130 and O138 (`0c972abf4:docs/plans/2026-11-03-phase-3-2.md:35`). Ends with a Preview (O128) | 3.1 | 2 sessions, about $3,000 | [6] GEN tags, only if a lane touches those notes |
| 3.3 | The demultiplexing run reads the index in the read names (an S1 that BIO ruled old), the Demux plan reaches the run, Detect counts the read-name index, the smoke gate runs from a checked copy and the walk rows 3.2 left, as `0c972abf4:docs/plans/2026-11-06-phase-3-3.md:62` sets. O159 set aside the first monthly Stable it planned. The owner added this sub-phase on 2026-11-06 (O154), since the table's rule says no session adds one | 3.2 | 1 session, no dollar figure (O154) | none, the panel decides under the owner's delegation (O154) |
| 3.4 | Finish Phase 3 with a Preview and tidy the repository for Phase 4, as `docs/plans/2026-11-08-phase-3-4.md` sets. The owner added this sub-phase on 2026-11-08 (O160) | 3.3 | 1 session, no dollar figure (O78) | none, the panel decides under the standing go (O126) |
| Deferred | 3c's typed event layer beyond a lint on new `Notification.Name` declarations, 3d's OperationLauncher beyond refuse-and-name-the-holder, and the old 3.1's frozen row texts, per-kind accessibility snapshot gate, classifier export byte pins and new ratchets other than viewport hides. The read-ID and unique-count pins of the classifiers stay | User work that touches the files, and Phase 5 for 3d, where RNA-seq brings the first new launch kind | none | none |

The six exit checks of Phase 3.

| Check | Passes when |
|---|---|
| 1 | Stable shipped from 3.0 (2026.10.27) and from 3.1 (2026.10.29), Previews from 3.2 (2026.11.1, 2026.11.2) and from 3.3 (2026.11.3, 2026.11.4), and a Preview from 3.4 with its packaged walk and the whole verification order. Phase 3 exits with that Preview, which carries the user-visible fixes named in `docs/plans/2026-11-08-phase-3-4.md` (owner direction O160, `docs/contracts/SCOPE-AND-DELIVERY.md`, Stable on a clock). The next monthly Stable carries Phase 3's work when the owner asks for one (O159). No Phase 3 check waits for it. |
| 2 | No S1 or S2 finding is open. |
| 3 | The real-window view-switch test of every kind passes in the unit tier, and the XCUI smoke with its view-switch test passes on the packaged candidate, in a session that does not lock, for every kind with a fixture that needs no managed tool. |
| 4 | A stub surface and a stub bundle kind in a test target open from the sidebar with no App edit beyond registration, and the five classifiers share one action component whose extraction tests check read IDs against known lists. |
| 5 | Every classifier records its database by name, version and checksum. |
| 6 | Every viewer kind opens through ViewportHost, the hide list and the optional viewer slots are gone, and the sidebar routes every kind through the registry with one read-only fallback for legacy bundles. |

The budget of Phase 3 is five sessions, about $6,000 measured, and at $9,000 the manager stops for the owner. The audit's dissent is recorded in its report. Both science seats would run a science session before any viewport code, and both teams would have left the eleven later viewer migrations until user work touched them, which O70 overrode.

## Phase 4, god-object splits and module splits (weeks 8 to 12)

The audit of 2026-10-26 ranks 4c (TrackRenderer) and 4d (the LungfishWorkflow split) first. The panel plans Phase 4 at its start under `docs/contracts/SCOPE-AND-DELIVERY.md`, and a task that no user outcome needs goes to the backlog.

Entry criteria. Phase 3 exit, science pins in place for any responsibility a lane moves that produces scientific output (`docs/contracts/SCOPE-AND-DELIVERY.md`, Pins before a change are for science), byte-identical genotype export fixtures in place. Anything else is pinned only when a lane's brief asks for it.

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| Genotype extraction by responsibility (export coordinator, review eligibility, matrix projection, haplotype-band disclosure), instrumentation behind one protocol | R6 | LungfishGenotypeUI/* | Fable, pure moves | 4a | Workbook and matrix exports byte-identical, testing* identifiers fall, files at or under 1,500 lines |
| ViewerViewController and AnnotationTableDrawer collaborator extraction | R6 | LungfishApp/Views/Viewer/* | Opus | 4b | Source-text assertion ratchet falls as behavioural tests replace them |
| LungfishGenomeBrowserUI leaf with TrackRenderer protocol | R13 | New target, SequenceViewerView family, ReadTrackRenderer.swift, LungfishAlignmentUI | Fable | 4c | Renderer tests on spliced and deleted reads pass before and after, coverage ignores N and D |
| LungfishWorkflow split into WorkflowCore and domain targets, LungfishRNASeq created empty | R12 | Package.swift, folder moves only | Sonnet | 4d | Build times measured before and after with scripts/measure-build-times.sh, CLI --help and provenance schemas unchanged |
| Test tree mirrors source tree, tests move to their module's target, TEST-MAP generated | R11 | Tests/* | Sonnet | 4e | Parity suites and LUNGFISH_REQUIRE_TOOLS runs still find every suite |
| Concurrency hatch reduction, @TaskLocal probes, CommandEnvironment | R10 | The 23 static seams, CLI override sites | Opus | 4f | Hatch ratchet falls, VariantDatabase rollback tests pass through the injected observer, PARALLEL_HAZARD_SUITES shrinks |

Exit criteria. No file over 3,000 lines in UI modules, build-time measurement published. Rollback. Every move is a pure-move commit, reverted as a unit.

## Phase 5, RNA-seq prerequisites and the first surface built on the contracts (after Phases 3 and 4)

Entry criteria. Phases 3 and 4 exit, since RNA-seq work waits until the other phases are done (owner O68 of 2026-10-26). The owner has chosen the aligner (STAR or HISAT2) and quantifier (salmon or kallisto) and confirmed the DE engine (R with DESeq2 or edgeR, or a native alternative).

| Task | Finding | Files | Model | Lane | Acceptance |
|---|---|---|---|---|---|
| ReferenceIndexCache keyed by reference checksum, tool, version, parameters, GTF checksum | R17 | LungfishWorkflow/Indexes/* (new), ManagedMappingPipeline.swift | Opus | 5a | Minimap2 index reuse across runs proven by a test, cache key recorded in provenance |
| Annotation input type with checksum and contig-name validation against the FASTA | R17 | LungfishIO/Formats/GFF, request types | Opus | 5b | GTF and FASTA contig mismatch fails the request with a named error |
| CountMatrix result, ExperimentDesign sample sheet, strandedness detection recorded | R17 | LungfishIO/Analysis/* (new) | Fable | 5c | Round-trip tests, strandedness value present in provenance |
| Resource admission (resourceClass, block or queue, logged in provenance) and R activation profile | R17 | OperationCenter admission, descriptor resourceClass, Conda activation profiles | Opus | 5d | Admission never changes scientific parameters, STAR genomeGenerate class runs past the old 3600 s timeout |
| LungfishRNASeq domain target and LungfishRNASeqUI leaf built strictly through the registries, executor, launcher, recorder and ResultViewport | R1 to R4, R17 | New targets only | Fable | 5e (after 5a to 5d) | Zero edits to LungfishApp beyond registration, CLI and GUI parity test, junction track as a TrackRenderer |

Exit criteria. The RNA-seq surface ships with CLI parity, provenance and OperationCenter coverage and the add-a-surface checklist fully ticked without any App composition-root edit.

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

Which aligner, quantifier and DE engine the RNA-seq surface uses, since the activation profiles and resource classes depend on it. Whether primer "legacy salvage" is still a user-facing mode. Whether the UI-free operations code becomes a new LungfishOperations target or folders inside LungfishWorkflowCore. Whether Kraken2's CLI command moves to a top-level `classify` with `conda classify` kept as an alias.
