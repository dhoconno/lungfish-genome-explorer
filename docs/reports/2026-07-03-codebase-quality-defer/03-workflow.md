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

### Deferred SPLITS (each its own reviewed pass — high value, needs promotions)
- `ONTBarcodeDemuxGenotypingPipeline.swift` (5749L, but ~3370L Swift + two embedded Python
  heredocs `filterScript` 3376-3977 / `reportScript` 3979-5749). Highest-value move:
  extract the two heredocs to `ONTBarcodeDemuxGenotypingScripts.swift` (they inflate the
  file to 5749L while being opaque strings to the Swift toolchain). Full 6-way split by
  stage (Request / InputResolution / Mapping / FilterReportWorkbook / Provenance / Scripts)
  needs ~15 `private`->`internal` promotions of nested step-result structs + cross-stage
  helpers. Defer: crosses provenance/Codable/materialization types.
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
- `GenotypeWorkbookRevisionService.swift` (1298L): ~660L is the embedded Python
  `workbookOverrideScript`. HIGHEST-value low-risk move: extract that computed property to
  `GenotypeWorkbookRevisionService+OverrideScript.swift` (same-type extension, same module,
  no access change) -> drops the file to ~640L.
- `ONTBarcodeDemuxGenotypingPipeline` heredoc extraction (noted above) is the parallel move.
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

## Deferred items (later batches)

_(populated per batch as uncertain changes are reverted)_
