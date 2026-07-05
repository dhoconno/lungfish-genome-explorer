# LungfishWorkflow — Deferred Items (Phase 3)

Module: `Sources/LungfishWorkflow/**` (272 files, ~124K LOC). Largest non-App module.
Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests ->
independent adversarial review -> revert-on-uncertainty -> commit.

Workflow-specific binding invariants (never refactor away):
- Every pipeline op calls BOTH `OperationCenter.shared.update()` AND
  `OperationCenter.shared.log()` (without `.log()`, only materialization steps persist
  in the expanded row history).
- Materialization semantics: `materializeInputFilesIfNeeded()` reconstructs full FASTQ
  from root + read IDs; config structs have mutable `inputFiles`/`fastq1`/`fastq2`;
  clean up materialized temps via `defer`. Do not alter which reads are materialized.
- NEVER save alignment as SAM (always sorted + indexed BAM via `samtools sort + index`,
  delete the intermediate SAM).
- Background->MainActor dispatch rules (never `Task { @MainActor in }` from GCD; use
  `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` or actors).

## 2026-07-04 expert-review correction

The review found a provenance blocker in `TaxonomyExtractionPipeline`: provenance recorded the
requested `.fastq` path from the config even though the live `ReadExtractionService` writes
actual `.fastq.gz` payloads, and it used bare file records plus a hard-coded `1.0` tool version.
This was fixed. The pipeline now records the actual returned output URLs, checksums and sizes for
inputs/outputs, the current Lungfish version, resolved options/defaults, and a replayable
`lungfish conda extract` argv. A regression test covers the saved sidecar.

Big pipeline files (audit solo, largest first): ONTBarcodeDemuxGenotypingPipeline (5749),
FullLengthONTMHCGenotypingPipeline (3802), DemultiplexingPipeline (3569),
FASTQBatchImporter (1820), NativeToolRunner (1789), TaxTriagePipeline (1598),
AIHaplotypingPatchValidator (1516), ProvenanceExporter (1379), NativeBundleBuilder (1377),
MetagenomicsImportService (1316), etc. Clusters: ONTGenotyping/, Demultiplex/, Native/,
Conda/, Metagenomics/, TaxTriage/, Provenance/, Alignment/, Mapping/, Variants/, Builder/,
Engines/, Databases/, Extraction/, TwelveS/, MSA/, SequenceAnnotation/, Ingestion/.

## Big-pipeline audits (4 largest files) — findings

All four are statement-level clean and PASS every binding invariant (no `.sam`
alignment-save, no `Task { @MainActor` / GCD->MainActor hop, materialization untouched,
no dropped OperationCenter pairing). Each has ONE small verified dead-code apply
(batched together in the dead-code cluster) + a strong split PROPOSAL deferred to its own
reviewed pass.

### Applied (dead-code cluster batch)
- `NativeToolRunner.TailBuffer` (~100-122) — unused class (superseded by
  `ProcessOutputAccumulator`); grep-verified zero instantiations.
- `FASTQBatchImporter.createIngestionWorkspace` (~1685) — dead private static (the live
  same-named method is in LungfishApp/Services/FASTQIngestionService.swift; this one has
  no in-file caller — processSingleSample uses `ProjectTempDirectory.create` inline).
- `ONTBarcodeDemuxGenotypingPipeline.progressNoop` (~1070) — empty no-op + its 1 call site.
- `DemultiplexingPipeline.ExactBareBarcodeMatcher.findFivePrime`/`findThreePrime`
  (~1573/1595) — unreachable (live path is `assignment` -> `findAny` -> `findMatch`).
- 2026-07-04 hardening pass: legacy FASTQ batch import now rejects unsupported recipe steps
  during preflight instead of logging and skipping them; the unsupported legacy `amplicon`
  resolver/help/manual references were removed until primer removal is executable in this path.
- 2026-07-04 hardening pass: `ONTBarcodeDemuxGenotypingPipeline`'s two embedded Python payloads
  moved unchanged into `ONTBarcodeDemuxGenotypingPipeline+Scripts.swift`. The public
  `writeFilterScript` and `writeReportScript` APIs stayed on the pipeline type via extension,
  reducing the main pipeline file from ~5.7K lines to ~3.4K lines without changing script bytes.
- 2026-07-05 hardening pass: `ReferenceBundleAnnotationImportService` now rejects zero-feature
  annotation imports as `noImportableAnnotations`, removes generated SQLite artifacts before
  throwing, and records successful imports with `reject_zero_feature_tracks=true` provenance
  defaults/resolved options.
- 2026-07-05 hardening pass: executed `lungfish workflow run` invocations now fail closed unless
  at least one `--expected-output` is declared. The local and nf-core runners validate that
  contract before creating a `.lungfishrun` bundle or launching a workflow process, so completed
  workflow runs cannot omit focused provenance for their final scientific outputs.

### Deferred SPLITS (each its own reviewed pass — high value, needs promotions)
- `ONTBarcodeDemuxGenotypingPipeline.swift` (now ~3.4K lines after script extraction). The
  script split is resolved; the remaining optional split is a full 5-way stage split by
  Request / InputResolution / Mapping / FilterReportWorkbook / Provenance. That still needs
  ~15 `private`->`internal` promotions of nested step-result structs + cross-stage helpers,
  and crosses provenance/Codable/materialization types.
- `FullLengthONTMHCGenotypingPipeline.swift` (3802L). 5-way split (Request / +Savont /
  +Checkpoints / WorkbookBuilders / XLSXWriter) needs ~15 promotions incl. `isDirectory`
  free func + provenance/checkpoint types. Also A1 (drop unused `sample:` param from
  `materializeFASTQ`/`prepareReadsForSavont`) DEFERRED — it's a signature change, marginal
  value; fold into the split's reviewed pass rather than mixing a semantic edit in.
  NOTE: the `.genotypes.sam` write (~1711/1730) is a genotyping-scoring intermediate
  (clusters-vs-reference for exact scoring), NOT a persisted alignment artifact -> does
  NOT violate the no-SAM rule, flagged for awareness.
- `DemultiplexingPipeline.swift` (3569L). Split precedent already exists (+Scout, +MultiStep
  siblings). 5-seam split (+ExactBare / +ExactAsymmetric / +AdapterFASTA / +TrimPositions /
  +Stats) needs ~15 promotions incl. nested `DemuxTrimEntry`, `AdapterConfiguration`, and
  the barcode/adapter helpers. D8 follow-on: after removing find5/find3, the 3 stored
  matcher fields become unread -> removing them is an init-signature change, deferred.
  RESOLVED 2026-07-05: derived demux bundles now fail closed if required
  `derived.manifest.json` writes fail; the affected bundle is removed and the pipeline throws
  `bundleCreationFailed` instead of logging and returning a lineage-less scientific bundle.
- `NativeToolRunner.swift` (1789L) + `FASTQBatchImporter.swift` (1820L). Both split-able but
  deferred: NativeToolRunner's 4 near-duplicate continuation blocks want a concurrency-dedup
  decision first (touches continuation-resume ordering + pipe lifetime); FASTQBatchImporter's
  split needs `private`->`internal` on `logger` + 4 shared helpers.

### Deferred DEDUP/logic items (semantics-sensitive, per file)
- FullLengthONTMHC: Savont retry re-switch simplification (A2, failure path); two
  `formatNumber` differ in precision (%.1f vs %.3f) -> NOT equivalent, do not merge.
- ONTBarcodeDemux: `writeHaplotypeAnalysisIfRequested` vs `writeCurrentWorkbookHaplotypeAnalysis`
  (Codable-manifest + failure path); `writeProvenance` dual-emit (legacy dict + canonical
  envelope, Codable contract); `runSamtoolsMerge`/`runSamtoolsIndex` (subprocess error
  construction); `resolveMode`/`effectiveMode` (auto-detect ordering).
- Demultiplexing: 4 `createAdapterConfiguration` branches (spec/orientation logic); 3
  derived-manifest writes (Codable + materialization pointers); trim-position chaining.
- NativeToolRunner: 4 continuation-block dedup (concurrency); `NativeTool` 6 parallel switch
  tables (provenance-adjacent).
- FASTQBatchImporter: `reproducibleImportCommand` arg construction; `concatenateFiles`
  whole-file-in-memory (perf note, behavior change to stream).

## Second big-file tier (TaxTriage/AIHaplotyping/Provenance/NativeBundleBuilder/Metagenomics/GenotypeWorkbookRevision) — findings

All 6 clean at statement level, PASS all binding invariants (no SAM-save, no MainActor
dispatch hop, ProvenanceRecorder/OperationMarker are the correct patterns for these
non-op-pipeline layers, NOT OperationCenter violations).

### Applied (second Workflow batch)
- `NativeBundleBuilder.stripExtraBEDColumns` (~1274) — dead private throwing instance method;
  the live caller uses a distinct `static func` in LungfishApp/ViewModels/BundleBuildHelpers.swift.
- `GenotypeWorkbookRevisionService.snapshotRole` (~244) — identical-both-branches ternary
  (`.externalEditSnapshot` either way) -> plain assignment; the separate `label:` ternary
  below genuinely differs and stays.
- `AIHaplotypingPatchValidator.SampleLocus` (~1507) — dead private struct (zero in-file
  constructions; the same-named struct in AIHaplotypingRevisionPublisher.swift is a distinct
  file-private type, untouched). Kept `SampleLocusLabel`.

### Deferred SPLITS (separate reviewed passes)
- RESOLVED 2026-07-04: `GenotypeWorkbookRevisionService.swift` no longer carries the
  ~660-line embedded Python `workbookOverrideScript`. The script moved unchanged to
  `GenotypeWorkbookRevisionService+OverrideScript.swift`, dropping the service file to
  ~633L while keeping the workflow behavior pinned by `GenotypeWorkbookRevisionServiceTests`.
- RESOLVED 2026-07-04: `TaxTriagePipeline` now fails closed if `taxtriage-result.json`
  or run provenance cannot be saved. Source-policy and fake-runtime tests prevent returning
  a successful scientific workflow result after durable result/provenance sidecars are missing.
- RESOLVED 2026-07-04: `ONTBarcodeDemuxGenotypingPipeline` heredoc extraction is complete;
  the moved script payloads were byte-verified and covered by `ONTBarcodeDemuxGenotypingPipelineTests`.
- RESOLVED 2026-07-05: `DatabaseRegistry` managed installs now write durable install
  provenance for `human-scrubber`, `deacon-panhuman`, and `deacon-ribokmers`, and fail
  closed by removing final payloads and override state if the provenance sidecar cannot be
  written. `HumanScrubberDatabaseTests` cover deterministic URLSession/Deacon stubs and
  provenance-write failure cleanup; a source policy test prevents success-capable installer
  paths from discarding install-provenance failures.
- RESOLVED 2026-07-05: `GATKPipelineExecutor` now removes newly-created declared outputs
  when a completed managed GATK run cannot persist final provenance, preventing successful
  GATK artifacts from being left without a sidecar.
- RESOLVED 2026-07-05: `EsVirituPipeline` now treats `esviritu-result.json` as a required
  result artifact. Sidecar write failure marks the run failed when possible and throws a typed
  pipeline error; successful runs record both the final EsViritu output files and a Lungfish
  wrapper provenance step for the JSON result sidecar.
- RESOLVED 2026-07-05: `ClassificationPipeline` now treats `classification-result.json` as a
  required workflow artifact instead of leaving persistence to AppDelegate. Successful runs
  record a Lungfish wrapper provenance step for the sidecar, and the sidecar is removed if final
  root provenance cannot be saved. Failed sidecar writes now also record failed Lungfish wrapper
  steps before failed-run provenance is saved.
- RESOLVED 2026-07-05: `build-db kraken2` can now receive repeated `--sample-dir` arguments for
  known-successful sample result directories. Explicit sample mode ignores unrelated sibling
  kreports, limits cleanup and provenance input/output discovery to the selected samples, and
  records the selected directories in replay argv and provenance options.
- `TaxTriagePipeline.swift` (1598L): 4-way actor-extension split, NO promotions (actor
  extensions keep `private` in-module... but across files `private` doesn't span — so any
  cross-file helper needs `internal`; verify per-seam). Test-pinned internals stay internal.
- `AIHaplotypingPatchValidator.swift` (1516L): 3-way split; the error enum (~262L, lines
  4-266) is self-contained. ValidationContext cluster needs `private`->`internal` promotion.
- `ProvenanceExporter.swift` (1379L): 4-way split; needs `internal` promotion of ~14 shared
  private helpers (`private` doesn't cross files). Codable-heavy -> schema untouchable.
- `NativeBundleBuilder.swift` (1377L): 4-way stage split; NO promotions needed (same-module
  extensions on the `@MainActor` class). `convertGenBankToBED` stays test-visible.
- `MetagenomicsImportService.swift` (1316L): models/importers/NaoMgs/helpers split; statics
  already appropriately scoped, `selectTopAccessionsPerTaxon` test-pinned.

### Deferred DEDUP-that-isn't (verified NON-equivalent, do NOT merge)
- ProvenanceExporter `shellCommand` vs `portableCommand` vs `exportPython` inline: share
  args[0] normalization but join differently (`" \\\n    "` vs `" "`) -> semantic, not exact.
- ProvenanceExporter 4 `Set<String>` dedup loops: each keys on a DIFFERENT composite; two
  also sort/filter-by-existence -> not equivalent.
- NativeBundleBuilder `detectionURL` gz-strip repeated 3x but embedded in different control
  flow with different downstream use.
- FullLengthONTMHC two `formatNumber` differ in precision (recorded earlier).

## Third big-file tier (Minimap2/ManagedMapping/ViralVariant + Conda/MetagenomicsDB/TwelveS/AIRunner) — findings

No-SAM invariant traced and PASSES in all mapping/variant pipelines (intermediate SAM
deleted on every path; ViralVariant's only `.sam` are header-scratch for `samtools
reheader`, not alignment payloads). No MainActor-dispatch violations.

### Applied (third Workflow batch)
- `Minimap2Pipeline.parseFlagstat` (~927): tightened internal->private (only self-use at
  ~876; the ManagedMapping copy is a separate private static).
- `AIHaplotypingRunner.promptInputJSONString` (~582) + its sole-use private struct
  `PromptInput` (~1178): dead pair removed together (grep-verified zero callers; distinct
  from AIHaplotypingPromptInputPayload/Encoder).

### Deferred (applied-adjacent, held for churn/value)
- `ViralVariantCallingPipeline`: drop redundant `return` in single-expression arg builders
  (~976/984/992/1031/1121) + fix 2 indentation anomalies (~325/392). Cosmetic, exact-
  equivalent, but near-zero value on a correctness-critical file -> deferred to avoid churn.
- `Minimap2Pipeline` (~538/578): `condaToolVersionString(...)` computed twice; hoist is
  exact-equivalent but touches a failure-path provenance step -> deferred.

### TRAPS the audits caught (look like cleanup, are NOT safe — do NOT touch)
- `TwelveSAmpliconMatchingWorkflow` (~1184): private `zip<T,U>(_:_:) -> (T,U)?` free func
  intentionally SHADOWS `Swift.zip` so `.map` works on the optional tuple. Removing it binds
  to `Swift.zip` (sequence zip) -> behavior/compile change. Keep. If ever split, move it
  WITH its sole user `writeProvenance`.
- `CondaManager` single-string `install(packageSpec:)`/`reinstall(packageSpec:)` overloads:
  look redundant vs the `packages:`-array versions but are pinned by CondaManagerTests:159/178.
- `ProvenanceExporter`/`ViralVariant`/`Minimap2` `parseFlagstat`/`fileFormat` cross-file
  near-duplicates: behaviorally DIVERGENT (bai case, leading-space check, .fa.gz handling)
  -> not exact-equivalent, do NOT dedup across files.

### Deferred SPLITS (separate reviewed passes; all same-module extension moves, no promotions)
- Minimap2Pipeline (1263L): Types / Result+Persistence / Error / core.
- ManagedMappingPipeline (1203L): Types / +Normalization / streaming helpers.
- ViralVariantCallingPipeline (1229L): Types / +Arguments / +Execution.
- CondaManager (1282L): +LauncherRepairs / +Nextflow / Models.
- MetagenomicsDatabaseRegistry (1240L): Support types / +Recommendations.
- TwelveSAmpliconMatchingWorkflow (1187L): +Bundle (TSV/JSON writers) / +Provenance (move
  the `zip` shadow with it) / Types.
- AIHaplotypingRunner (1191L): +Types / +MinimalMCM / +ProviderErrors.

### RESOLVED — metagenomics database singleton mutability
- `MetagenomicsDatabaseRegistry.shared` is now an immutable actor singleton (`public static let`),
  removing the unsynchronized mutable global slot that was unsafe under strict concurrency.
- The same adjacent pattern in `EsVirituDatabaseManager.shared` was hardened to `public static let`.
  Tests now exercise storage-root changes through injected manager/registry instances instead of
  reassigning process-global singletons.

## Fourth big-file tier (PluginPackStatusService/DatabaseRegistry/ProvenanceEnvelope/SequenceAnnotationTrackWorkflow/ClassifierReadResolver) — ZERO safe applies

All 5 audited clean: every apparent cleanup is a failure-path, a public/test-pinned
surface, a Codable/provenance contract, or read-resolution logic. No invariant violations
(no persisted SAM, no GCD->MainActor, no dropped op-log).

### More TRAPS caught (do NOT touch)
- PluginPackStatusService: protocol-extension default vs concrete actor override
  (`status(forPackID:)`, `visibleStatuses(...)`) — identical bodies but the concrete
  override is intentional (static resolution on the concrete type; test doubles rely on the
  protocol requirement). Keep both.
- ProvenanceEnvelope: `ProvenanceVersion.required` and `ProvenanceName.required` are
  byte-identical but are distinct semantic namespaces referenced cross-file. Do NOT merge.
- ClassifierReadResolver: 4 never-thrown error cases (`kraken2OutputMissing`,
  `kraken2TreeMissing`, `destinationNotWritable`, `fastaConversionFailed`) — but
  `ClassifierExtractionError` is PUBLIC and switched exhaustively by consumers -> removing
  cases is an API break, NOT behavior-preserving. Keep.
- DatabaseRegistry `downloadExitCode` literal `0` records URLSession download success in
  managed-install provenance. Keep it unless replacing that download step with a richer
  status model.
- SequenceAnnotationTrackWorkflow `restoreFiles` inline dup (~411-420): in a rollback
  failure path -> defer.

### Deferred SPLITS (all >1000L, same-module extension moves)
- PluginPackStatusService (1145L): Models out / +SmokeTest.
- DatabaseRegistry (1144L): Models / Installers / ManagedDatabaseDownload.
- ProvenanceEnvelope (1070L): per-Codable-type files (SAFEST split kind — whole type incl.
  CodingKeys moves together, zero behavior change; but low priority, schema-sensitive).
- SequenceAnnotationTrackWorkflow (1062L): +Provenance / +ORF (pure-compute core) / Models.
- ClassifierReadResolver (1029L): split ONLY non-resolution parts (Error enum, LineReader);
  KEEP the extraction pipeline together (resolveBAMURL/resolveKraken2SourceFASTQs are the
  materialization-adjacent virtual-FASTQ logic — untouchable).

## Phase 3 status assessment (after ~25 largest files audited)

The LungfishWorkflow layer is ALREADY high-quality at the statement level. Across every
big-file audit the pattern held: a few small provably-safe dead-code/access applies + large
DEFERRED file splits. Applied so far (3 committed batches, all green): 4 dead-code removals,
2 dead-code removals + 1 identical-branch collapse, 1 access-tighten + 1 dead pair removal =
9 items, ~150 lines net removed. The remaining high-value work is entirely FILE SPLITS,
which are deferred by design (each is a large relocation needing per-seam private->internal
promotion across provenance/Codable/materialization-critical types, warranting its own
reviewed pass — exactly what the defer doc catalogs for the downstream LLM).

Remaining ~247 smaller Workflow files (<1000L): given the strong statement-level-clean
signal from the 25 largest (the most complex) files, these are swept in clustered
coverage-audit batches (by directory) rather than solo, applying only provably-safe
dead-code/dedup that survives grep + the trap-checks above.

## Mid-size tier sweep (28 files, 500-950L, 3 clustered coverage audits) — 2 applies, rest clean

Reinforces the statement-level-clean finding: only 2 of 28 files had a safe apply.

### Applied (fourth Workflow batch)
- `ONTFluidigmAmpliconMaterializer` (~759, ~913): dead `gzipCompress` static + dead
  `SampleAccumulator.orderedSequences()` (grep-verified zero callers; real compression goes
  through `CountedFASTQMaterializer.write(compress:)`). KEPT the public `.compressionFailed`
  case (public API, switched in errorDescription — removing it is not allowed).
- `TaxonomyExtractionPipeline` (~494/627/722): dead closed chain
  `filterFASTQ`->`filterGzippedFASTQ`->`extractReadId` (~216 lines; superseded by the
  seqkit/ReadExtractionService route). Live extraction path untouched -> which reads get
  extracted is unchanged.

### More TRAPS (do NOT touch) discovered in the sweep
- Two shadowing free functions: `MAFFTAlignmentPipeline.msaShellEscape` and
  `AIHaplotypingEvidenceRegistry.lexicographicallyPrecedes` (the latter shadows the stdlib
  Sequence method with DIFFERENT semantics — element-wise then by count). Do NOT "simplify".
- Orient test-pins: `vsearchArgumentsForTesting` (PUBLIC, consumed by a LungfishCLITests
  module — cannot internalize despite the name), `parseOrientResults` (internal, @testable).
- RESOLVED: `GATKCommandBuilder.jointGenotypingCommands` `.auto` now asserts because the
  resolver should never return it, then falls back to concrete CombineGVCFs commands instead of
  recursively calling itself.
- RESOLVED: `NativeBundleBuilder` no longer falls back to copying a VCF and creating an empty
  CSI when native BCF conversion fails or `bcftools` is unavailable. The workflow now fails closed
  with a clear request for a real indexed BCF/CSI pair instead of producing misleading scientific
  artifacts.
- RESOLVED: `NativeBundleBuilder` no longer copies bedGraph or unknown signal inputs to `.bw`
  filenames. Until bedGraph-to-BigWig conversion has complete native-tool provenance, non-BigWig
  signal inputs fail closed instead of fabricating BigWig tracks.
- RESOLVED 2026-07-05: `ReferenceBundleAnnotationImportService` no longer publishes
  zero-feature annotation tracks for empty or malformed GFF3/BED inputs; generated database
  artifacts are removed and the existing manifest/provenance layout is left untouched.
- Public-but-uncalled symbols across the tier (`SnakemakeRunner.minimumVersion`,
  `ReadExtractionService.samtoolsRegion`, `OrientResult.totalCount`, several unused-but-
  public error cases + `WorkflowGraphError.connectionNotFound`/`.emptyGraph`): NOT removable
  (public API surface / exhaustive-switch consumers).
- `GeneiousImportCollectionService.decodedFASTAURLs` always-empty but provenance-wired.
- Amplicon/Sample materializer twin namespaces + cross-file `relativePath`/`appendUnique`/
  `format`/`shellEscape` duplicates: distinct types, NOT cross-file-dedup-able.
- Two files (`MSAReferenceBundleBuilder`, `AIHaplotypingEvidenceRegistry`) have an
  `import LungfishCore` with no qualified use, but symbols may resolve transitively -> import
  removal not provable without a compile -> deferred.

## Small-file tier sweep (185 files <500L, 5 directory-scoped coverage audits) — 2 applies, rest clean

COMPLETES Phase 3 audit coverage (all 272 Workflow files audited). Uniformly clean:
only 2 of 185 small files had a provably-safe apply.

### Applied (fifth Workflow batch)
- `ProvenanceWriter.swift`: dead private `ProvenanceStep.replacingOutputDescriptors`
  (~450) — grep-verified zero callers; private extension method, not a Codable/protocol
  member; sibling `replacingOutputs` (used) kept.
- `AIHaplotypingRunContext.swift`: `region(for:)` (~155) no-op conditional collapse — both
  ternary/if arms returned `locus` unconditionally -> single-expression body. Provably
  behavior-identical.

### More TRAPS caught (do NOT touch) — the sweep's main deliverable
- `WorkflowLibraryStore.shellEscape` (private) shadows the module `ShellUtilities.shellEscape`
  but is NON-equivalent (private safe-set includes `%`, module one doesn't). Do NOT dedup.
- Test-pinned "ForTesting"/DI members across the layer: `OrientConfig.vsearchArgumentsForTesting`
  (PUBLIC, consumed by LungfishCLITests), `NFCoreSupportedWorkflowCatalog.{firstWave,
  legacyWorkflows,futureCustomInterfaceWorkflows}`, many internal `init(...trackIDProvider:/
  metadataAppender:/metadataCollector:)` DI overloads in Alignment services, and numerous
  internal `static` parse helpers consumed cross-file + @testable. NONE removable/tightenable.
- Hand-enumerated JSON-schema arrays (`AIHaplotypingResultSchema.aiCallStateRawValues` etc.):
  do NOT "simplify" to `allCases.map(\.rawValue)` — order/membership is an on-wire contract.
- `RecipeRegistryV2` deliberately named to avoid collision with LungfishIO's legacy
  `RecipeRegistry` (identical-but-distinct namespaces).
- Cross-file byte-identical private helpers (`directoryChecksum`/`directorySize`,
  `relativePath`/`appendUnique`, `decompressGzipPrefix` with DIFFERENT buffer sizes):
  distinct types in distinct files -> NOT intra-file-dedup-able, and some behaviorally diverge.
- Always-empty-but-provenance-wired fields (`BundleContainerExportResult.provenanceURL`,
  `GeneiousImportCollectionService.decodedFASTAURLs`, `AssemblyProvenance.advancedOptions`).
- Defensive exhaustive `.sam` switch case in `PreparedAlignmentAttachmentService`
  (unreachable because `validateSupportedFormat` rejects `.sam` first — NEVER-SAM upheld).
- RESOLVED: `GATKCommandBuilder.jointGenotypingCommands` `.auto` recursion bomb.
- `IVarCodonMerger` `_ = positions` deliberate placeholder ("retained for future codon-
  position annotation") — not removed.

### NEVER-SAM invariant: verified upheld module-wide
All alignment/variant pipelines convert to sorted+indexed BAM and delete intermediate SAM;
the only `.sam` files found are converted intermediates (`<sample>.raw.sam`,
`aligned.sam`) or header-scratch for `samtools reheader` / genotyping-scoring
(clusters-vs-reference) — none are persisted alignment artifacts.

## Phase 3 (LungfishWorkflow) — audit COMPLETE

272/272 files audited. Applied: 5 committed batches totaling ~11 provably-safe items
(dead-code removals, 2 access tightens, 1 identical-branch collapse, 1 no-op collapse),
~430 lines net removed. The layer is statement-level clean; ALL substantial quality value
is in the DEFERRED file splits (14 large files >1000L catalogued above with per-seam
promotion lists — each its own reviewed relocation pass for the downstream LLM). Rich trap
inventory recorded so a future pass does not misfire on look-like-cleanup non-edits.

## Deferred items (later batches)

_(none reverted — all applied items were provably safe and verified green)_
