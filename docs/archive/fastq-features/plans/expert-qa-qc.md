# Comprehensive QA/QC Plan: Lungfish FASTQ Operations Redesign

## Document Metadata

| Field | Value |
|---|---|
| Project | Lungfish Genome Browser |
| Branch | `fastq-features` |
| Date | 2026-03-14 |
| Baseline Tests | ~3,508 test functions across 135 files, 8 test targets |
| FASTQ-Specific Tests | ~170 test functions across 9 files |
| Platform | macOS 26 Tahoe, Swift 6.2, SPM |

---

## 1. Current State Assessment

### 1.1 Existing FASTQ Test Coverage

The current FASTQ test suite consists of nine test files across three test targets:

**LungfishIOTests (model layer)**
- `FASTQDerivativesTests.swift` -- 86 test functions covering manifest round-trips for all 16 operation kinds, payload serialization, lineage chaining, statistics caching, and schema compatibility. This is the strongest test file in the FASTQ subsystem.
- `ProcessingRecipeTests.swift` -- 9 tests covering recipe round-trip, built-in recipe content, pipeline summary formatting, and missing-file handling.
- `BatchManifestTests.swift` -- 10 tests covering `BatchManifest` and `BatchComparisonManifest` round-trips, `BarcodeSummary.finalMetrics` fallback behavior, `StepMetrics` retention calculations, and `StepStatus` exhaustiveness.

**LungfishAppTests (service/integration layer)**
- `FASTQVirtualSubsetTests.swift` -- 2 tests covering length-filtered subsets with trim chaining and demux+trim+orient chaining, including preview generation and materialization.
- `FASTQProjectSimulationTests.swift` -- 5 tests simulating end-to-end project workflows: reference import, multi-operation chaining (trim then filter then search then motif then dedup), primer trim with virtual storage, demultiplex with per-barcode bundles, and parameter validation.
- `FASTQBatchOperationTests.swift` -- 17 tests covering batch label generation, operation kind strings, batch parameters serialization, and request type classification (isTrimOperation, isFullOperation).

**LungfishWorkflowTests (pipeline/tool layer)**
- `DemultiplexingPipelineTests.swift` -- 27 tests covering cutadapt registration, `DemultiplexConfig` defaults, symmetry modes, adapter contexts for all built-in kits, fixed-dual linked adapter matching, virtual demux statistics caching, poly-G trim config, cross-platform error rates, and combinatorial kit validation.
- `FASTQToolIntegrationTests.swift` -- 21 tests covering real tool invocations (seqkit, fastp, bbduk, cutadapt, bbmerge, repair, tadpole, reformat) with a 20-read synthetic FASTQ fixture, including multi-step pipelines, roundtrips, and edge cases (empty input, single read).
- `PrimerTrimFixtureIntegrationTests.swift` -- 1 test with 7 MHC primer fixtures testing native and reverse-complement orientation detection via cutadapt.

### 1.2 Coverage Gaps Identified

**Critical gaps in existing tests:**

1. **BatchProcessingEngine has zero tests.** The actor at `Sources/LungfishApp/Services/BatchProcessingEngine.swift` (454 lines) has no corresponding test file. This is the highest-risk gap because it orchestrates concurrent multi-barcode processing.

2. **ReferenceSequenceFolder has minimal coverage.** Only tested indirectly through `FASTQProjectSimulationTests.testSimulatedProjectImportsReferenceBundle`. No tests for edge cases: duplicate import, invalid FASTA, listing with corrupted manifests, `isProjectReference` path logic.

3. **Materialization correctness is under-tested.** Only 2 tests in `FASTQVirtualSubsetTests` verify that `exportMaterializedFASTQ` produces correct output. No tests verify materialization through orient maps, multi-level lineage chains (3+ deep), or paired-end awareness.

4. **No cancellation tests.** `BatchProcessingEngine.cancel()` is implemented but never tested. No tests verify that in-progress operations respect cancellation and leave the filesystem in a clean state.

5. **No concurrent batch tests.** The engine supports `maxConcurrency` but no test verifies that concurrent barcode processing produces identical results to sequential processing.

6. **No schema migration tests.** `FASTQDerivedBundleManifest` has evolved (the `demuxedVirtual` payload added `orientMapFilename`), but no tests verify backward compatibility with manifests written by earlier versions.

7. **No UI/interaction tests for FASTQ panels.** The sidebar, operations panel, and metadata drawer have no automated test coverage.

---

## 2. Test Strategy

### 2.1 Test Pyramid

```
                    /\
                   /  \
                  / E2E \        5-10 tests  (full project workflows)
                 /--------\
                / Integr.   \    30-50 tests (service + pipeline)
               /--------------\
              /   Unit Tests    \  80-120 tests (models + logic)
             /--------------------\
```

**Unit tests (LungfishIOTests):** Pure model serialization, validation, computation. No file I/O beyond temp directories. Target: sub-second execution per test.

**Integration tests (LungfishAppTests, LungfishWorkflowTests):** Service-level operations using in-memory or temp-dir FASTQ fixtures. External tool invocations use real bundled binaries. Target: under 5 seconds per test.

**End-to-end tests (LungfishAppTests):** Full project simulation from import through demux, recipe execution, materialization, and export. Target: under 30 seconds per test.

### 2.2 Test Naming Convention

All new tests follow the existing pattern:
```
test<Component><Scenario><ExpectedOutcome>
```

Examples:
- `testBatchEngineExecutesTwoBarcodesWithThreeSteps`
- `testReferenceImportRejectsEmptyFASTA`
- `testMaterializationThroughOrientTrimFilterChainProducesCorrectSequence`

### 2.3 Fixture Strategy

Tests use **in-memory synthetic FASTQ** constructed by helper methods already established in the codebase. The pattern (`writeFASTQ(records:to:)`) is consistent across all existing test files.

No network-dependent fixtures. No real genomic data in the repository. All fixtures are deterministic with known expected outputs.

---

## 3. Test Data Specification

### 3.1 Standard Fixture Files

**fixture-10reads.fastq** (synthetic, generated in setUp)
- 10 reads, variable lengths (50-150 bp), all Q40
- Used for: subsample, length filter, dedup, statistics

**fixture-paired.fastq** (synthetic, interleaved)
- 4 pairs (8 records), /1 and /2 suffixes
- Used for: PE merge, repair, deinterleave/interleave roundtrip

**fixture-barcoded.fastq** (synthetic, ONT-style)
- 3 reads with ONT native barcode13, 2 reads with barcode14, 1 unassigned
- Used for: demultiplex, batch processing, orient+trim chains

**fixture-reference.fasta** (synthetic)
- 2 sequences: "ref1" (100 bp), "ref2" (200 bp)
- Used for: reference import, orientation, primer trim

**fixture-primers.fasta** (synthetic)
- 2 primer pairs matching fixture-barcoded reads
- Used for: primer trim, linked primer trim

### 3.2 Edge Case Fixtures

| Fixture | Purpose | Construction |
|---|---|---|
| Empty FASTQ (0 bytes) | Graceful handling of empty input | `"".write(to:)` |
| Single-record FASTQ | Boundary: minimum valid input | 1 record, 50 bp |
| Header-only FASTQ (truncated) | Corrupt file handling | Write only `@read1\n` |
| Quality mismatch FASTQ | Validation: seq/qual length mismatch | seq=10bp, qual=8bp |
| Very long read (50 kb) | Performance: single long read | 1 record, 50,000 bp |
| 10,000 identical reads | Dedup edge case | All same sequence |
| Mixed line endings (CR+LF) | Windows-origin files | `\r\n` separators |
| Unicode in header | Encoding robustness | Accented characters in description |
| Gzipped FASTQ | Compression handling | `Data` written with gzip |

### 3.3 Deterministic Test Data Generation

All test helpers use the established pattern with explicit read IDs and sequences:

```swift
private func writeFASTQ(records: [(id: String, sequence: String)], to url: URL) throws {
    let lines: [String] = records.flatMap { record in
        ["@\(record.id)", record.sequence, "+",
         String(repeating: "I", count: record.sequence.count)]
    }
    try lines.joined(separator: "\n").appending("\n")
        .write(to: url, atomically: true, encoding: .utf8)
}
```

For operations with stochastic output (subsample), tests assert bounds rather than exact values, following the pattern in `testSeqkitSubsampleByProportion`.

---

## 4. New Tests Required by Feature Area

### 4.1 Virtual-to-Materialized Lifecycle

**File:** `Tests/LungfishAppTests/FASTQMaterializationTests.swift` (new)

| Test | Description | Priority |
|---|---|---|
| `testMaterializeSubsetProducesExactReads` | Subset of 3 from 10 reads, verify exact output | P0 |
| `testMaterializeTrimProducesCorrectSequences` | Fixed trim 5bp/3bp, verify trimmed sequences match | P0 |
| `testMaterializeDemuxVirtualWithOrientMap` | RC'd read with orient map, verify final orientation | P0 |
| `testMaterializeThreeLevelChain` | Root -> trim -> filter -> materialize, verify output | P0 |
| `testMaterializeDemuxTrimFilterChain` | Root -> demux -> trim -> filter -> materialize | P0 |
| `testMaterializePreservesHeaderDescriptions` | Verify description field survives full chain | P1 |
| `testMaterializePairedEndPreservesInterleaving` | Paired reads stay in order through chain | P1 |
| `testMaterializeToSameDirectoryAsSource` | No path collision when output is near source | P2 |
| `testMaterializeEmptySubsetProducesEmptyFile` | Filter removes all reads, output is valid empty FASTQ | P1 |
| `testMaterializeEquivalenceVirtualVsDirect` | Virtual trim+filter output == direct tool processing | P0 |

The **equivalence test** is critical: it runs the same operation through the virtual system (trim positions + read IDs -> materialize) and through direct tool invocation (fastp/seqkit), then compares outputs byte-for-byte (after sorting by read ID, since tool ordering may differ).

### 4.2 Batch Processing Engine

**File:** `Tests/LungfishAppTests/BatchProcessingEngineTests.swift` (new)

| Test | Description | Priority |
|---|---|---|
| `testBatchEngineRejectsEmptyRecipe` | Empty recipe throws `.recipeEmpty` | P0 |
| `testBatchEngineRejectsNoBarcodes` | Empty manifest throws `.noBarcodes` | P0 |
| `testBatchEngineSingleBarcodeSingleStep` | 1 barcode, 1 step (length filter), verify output | P0 |
| `testBatchEngineTwoBarcodesThreeSteps` | 2 barcodes x 3 steps, verify all outputs exist | P0 |
| `testBatchEngineStepFailureSkipsRemaining` | Step 2 fails, steps 3-4 marked `.skipped` | P1 |
| `testBatchEngineCancellationStopsProcessing` | Cancel after 1 barcode, verify `.cancelled` | P1 |
| `testBatchEngineProgressCallbackFires` | Verify progress callback receives all expected updates | P1 |
| `testBatchEngineCreatesDirectoryStructure` | Verify batch-runs/{name}/recipe.json + comparison.json | P0 |
| `testBatchEngineComparisonManifestMetrics` | Verify retention percentages computed correctly | P1 |
| `testBatchEngineDemuxStepRejected` | Recipe with `.demultiplex` throws `.unsupportedStepInRecipe` | P0 |
| `testBatchEngineConcurrentResultsMatchSequential` | maxConcurrency=4 vs maxConcurrency=1, same output | P1 |
| `testBatchEngineResumeAfterPartialFailure` | Re-run batch, verify completed barcodes not re-processed | P2 |

### 4.3 Reference Sequence Management

**File:** `Tests/LungfishIOTests/ReferenceSequenceFolderTests.swift` (new)

| Test | Description | Priority |
|---|---|---|
| `testImportCreatesLungfishrefBundle` | Import FASTA, verify bundle structure | P0 |
| `testImportCopiesFASTAContent` | Verify sequence.fasta matches source | P0 |
| `testImportWritesManifestWithCorrectFields` | Verify manifest.json contains name, source, creation date | P0 |
| `testImportIdempotent` | Import same file twice, verify single bundle | P0 |
| `testImportSanitizesNameWithSlashes` | Name with `/` and `:` produces safe filename | P1 |
| `testListReferencesReturnsSorted` | Multiple imports listed alphabetically | P0 |
| `testListReferencesSkipsMalformedBundles` | Bundle without manifest.json is excluded | P1 |
| `testFastaURLReturnsNilForMissingFile` | Bundle with manifest but deleted FASTA | P1 |
| `testIsProjectReferenceForInternalPath` | URL inside Reference Sequences/ returns true | P0 |
| `testIsProjectReferenceForExternalPath` | URL outside project returns false | P0 |
| `testEnsureFolderCreatesDirectory` | Folder created if absent | P0 |
| `testEnsureFolderIdempotent` | Folder already exists, no error | P0 |
| `testImportEmptyFASTA` | Zero-sequence FASTA file is importable | P2 |

### 4.4 Sidebar Organization (Virtual File Trees)

**File:** `Tests/LungfishAppTests/FASTQSidebarTreeTests.swift` (new)

These tests operate on the model layer (not AppKit views):

| Test | Description | Priority |
|---|---|---|
| `testParentBundleDiscoversDemuxChildren` | Root bundle finds child demux bundles | P0 |
| `testChildBundleResolvesParentPath` | Derived manifest relative path resolves correctly | P0 |
| `testNestedDerivativeResolvesRootBundle` | 3-level chain resolves back to root FASTQ | P0 |
| `testOrphanedChildHandledGracefully` | Parent deleted, child manifest has dangling path | P1 |
| `testBatchRunChildrenDiscoveredUnderDemux` | batch-runs/ directory found inside demux group | P1 |

### 4.5 Recipe System Improvements

**File:** `Tests/LungfishIOTests/ProcessingRecipeTests.swift` (extend existing)

| Test | Description | Priority |
|---|---|---|
| `testRecipeWithAllOperationKindsRoundTrips` | Recipe with 14 step kinds serializes/deserializes | P0 |
| `testRecipeRegistrySaveAndLoad` | Save to user directory, load back | P1 |
| `testRecipeRegistryLoadCorruptedFileSkipped` | Invalid JSON in recipes/ directory | P1 |
| `testRecipeValidationRejectsDemuxStep` | Recipe containing demux step flagged invalid | P1 |
| `testRecipePairingModeValidation` | PE-required recipe on single-end input fails early | P1 |
| `testRecipeStepConversionCoversAllKinds` | `convertStepToRequest` handles all non-demux kinds | P0 |

### 4.6 Operation Chaining Correctness

**File:** `Tests/LungfishAppTests/FASTQOperationChainTests.swift` (new)

| Test | Description | Priority |
|---|---|---|
| `testTrimThenFilterStatisticsReflectChainedResult` | Stats after filter reflect trimmed lengths, not raw | P0 |
| `testDemuxThenTrimPreviewShowsTrimmedSequence` | Preview FASTQ shows sequence with both demux and trim applied | P0 |
| `testLineageAccumulatesAcrossChain` | 4-step chain has lineage array of length 4 | P0 |
| `testRootBundlePathRemainsStableThroughChain` | All derivatives point to same root | P0 |
| `testFilterAfterDemuxPreservesTrimPositions` | Length filter on demuxed bundle carries forward trim file | P0 |
| `testOrientThenDemuxThenTrimMaterializesCorrectly` | Orient -> demux -> trim, verify final sequence | P0 |

---

## 5. Performance Benchmarks

### 5.1 Materialization Performance

| Metric | Target | Measurement Method |
|---|---|---|
| Materialize 1,000-read subset from 10,000-read root | < 2 seconds | `measure {}` block |
| Materialize 100,000-read file through 3-step chain | < 30 seconds | Wall clock in integration test |
| Batch process 12 barcodes x 3 steps (1,000 reads each) | < 60 seconds | `BatchProcessingEngine` integration test |

### 5.2 UI Responsiveness

| Scenario | Target | Validation |
|---|---|---|
| Sidebar re-render after adding 24 demux children | < 100 ms main thread block | Instruments Time Profiler |
| Operation panel parameter change | < 16 ms (1 frame) | No dropped frames |
| Recipe selection dropdown with 20 recipes | < 50 ms | Instruments |
| Metadata drawer open/close animation | 60 fps sustained | Instruments Core Animation |

### 5.3 Memory

| Scenario | Target |
|---|---|
| Open project with 24 demux bundles + 3 derivatives each | < 200 MB RSS |
| Materialize 100,000-read file (streaming) | < 50 MB peak above baseline |
| Batch process 24 barcodes (concurrent=4) | < 500 MB peak |

---

## 6. Quality Gates

### 6.1 Phase Gate: Model Layer Complete

**Exit criteria:**
- All `FASTQDerivedBundleManifest` payload types have round-trip serialization tests
- `ProcessingRecipe` covers all built-in recipes and user recipe CRUD
- `BatchManifest`, `BatchComparisonManifest`, `BarcodeSummary`, `StepMetrics` tested with edge cases (zero reads, failed steps, nil retention)
- `ReferenceSequenceManifest` import/list/resolve tested
- Schema version backward compatibility verified (load manifest from previous schema versions)
- **Metric: 100% of public model types have at least one round-trip test**
- **Metric: Zero test failures in LungfishIOTests**

### 6.2 Phase Gate: Service Layer Complete

**Exit criteria:**
- `FASTQDerivativeService.createDerivative` tested for all request types
- `FASTQDerivativeService.exportMaterializedFASTQ` tested through at least 3 lineage depths
- `BatchProcessingEngine.executeBatch` tested with 2+ barcodes and 3+ steps
- Cancellation produces clean filesystem state (no partial bundles)
- Concurrent execution produces deterministic results
- **Metric: All service-layer tests pass with no flaky failures (3 consecutive green runs)**
- **Metric: Test coverage > 85% for FASTQDerivativeService and BatchProcessingEngine (line coverage)**

### 6.3 Phase Gate: Integration Complete

**Exit criteria:**
- End-to-end workflow test: import FASTQ -> demux -> apply recipe -> materialize -> verify output
- Virtual-vs-direct equivalence test passes for trim, filter, and trim+filter chains
- All bundled tools (seqkit, fastp, cutadapt, bbduk, bbmerge, repair, tadpole, reformat) pass integration smoke tests (already covered by FASTQToolIntegrationTests)
- Reference import -> orient -> demux -> batch pipeline works end-to-end
- **Metric: Zero regression in existing 3,508 tests**
- **Metric: All new integration tests pass on macOS 26 Tahoe**

### 6.4 Phase Gate: Release Candidate

**Exit criteria:**
- All quality gates from phases 1-3 satisfied
- Performance benchmarks met (Section 5)
- No known P0 or P1 defects open
- Exploratory testing completed (see Section 8)
- Documentation updated (code-level doc comments on all new public API)
- **Metric: Full test suite passes in < 10 minutes**

---

## 7. Code Review Checklist for FASTQ Operations

Every PR modifying FASTQ functionality must verify:

### 7.1 Correctness

- [ ] Manifest serialization: any new fields added to `FASTQDerivedBundleManifest`, `BatchManifest`, or `ProcessingRecipe` have default values for backward compatibility
- [ ] Relative paths: all `parentBundleRelativePath` and `rootBundleRelativePath` values tested with `../` traversal and verified to resolve correctly
- [ ] Statistics consistency: `cachedStatistics.readCount` matches actual read count in preview/materialized FASTQ
- [ ] Trim position propagation: when chaining operations, trim positions from parent are carried forward (not lost or doubled)
- [ ] Orient map awareness: any code that reads sequences from root FASTQ and applies trims must check for orient maps in the lineage
- [ ] Quality string length: materialized FASTQ quality strings are exactly the same length as sequence strings

### 7.2 Concurrency Safety

- [ ] `BatchProcessingEngine` is an `actor` -- all mutable state is actor-isolated
- [ ] `FASTQDerivativeService` is an `actor` -- no `@MainActor` dispatch from within (see MEMORY.md pattern)
- [ ] Progress callbacks are `@Sendable` -- no capturing of non-Sendable state
- [ ] File operations use `atomically: true` for writes to prevent partial files on crash
- [ ] Temporary directories cleaned up in `defer` blocks

### 7.3 Error Handling

- [ ] All `BatchProcessingError` cases have non-nil `errorDescription`
- [ ] Tool failures (`NativeToolRunner.run` returning non-zero exit code) produce actionable error messages including stderr
- [ ] Missing bundle files (deleted between discovery and processing) handled gracefully
- [ ] Disk full conditions during materialization do not leave corrupt output

### 7.4 Platform Compatibility

- [ ] No use of deprecated macOS 26 APIs (see MEMORY.md rules)
- [ ] No `wantsLayer = true` on any view
- [ ] No `lockFocus()`/`unlockFocus()` in rendering code
- [ ] Toolbar items use `NSButton(frame:)` with `.bezelStyle = .toolbar`

---

## 8. Regression Testing Approach

### 8.1 Regression Suite Structure

The regression suite consists of three tiers:

**Tier 1: Smoke (runs on every commit, < 30 seconds)**
- All unit tests in LungfishIOTests
- All unit tests in LungfishAppTests that do not invoke external tools
- `swift build` compiles without warnings

**Tier 2: Integration (runs on PR merge, < 5 minutes)**
- All tests including tool integration tests
- FASTQProjectSimulationTests end-to-end scenarios

**Tier 3: Full (runs nightly or before release, < 15 minutes)**
- Everything in Tiers 1-2
- Performance benchmark tests
- Large-file edge case tests (10,000+ reads)

### 8.2 Regression Triggers

Any change to these files requires running the full FASTQ regression suite:

| File | Risk Area |
|---|---|
| `FASTQDerivatives.swift` | All derivative tests, all materialization tests |
| `FASTQDerivativeService.swift` | All service tests, all project simulation tests |
| `BatchProcessingEngine.swift` | All batch tests |
| `DemultiplexingPipeline.swift` | All demux tests, batch tests with demux input |
| `ProcessingRecipe.swift` | Recipe tests, batch tests |
| `ReferenceSequenceFolder.swift` | Reference tests, orient pipeline tests |
| `BatchManifest.swift` | Batch manifest tests, comparison tests |
| `FASTQDemultiplexMetadata.swift` | Demux config tests, sample assignment tests |

### 8.3 Materialization Equivalence Validation

To validate that virtual-to-materialized produces identical results to direct processing:

1. Create a known 100-read input FASTQ with deterministic content
2. Apply operation X directly using the external tool (e.g., `fastp -i input.fastq -o direct.fastq --trim_front1 5 --trim_tail1 3`)
3. Apply operation X through the virtual system (`createDerivative` -> `exportMaterializedFASTQ`)
4. Sort both output files by read ID
5. Compare sequences and quality strings byte-for-byte
6. This test exists for: fixed trim, quality trim, length filter, adapter trim, dedup

Operations where exact equivalence is not possible (subsample, error correction) test statistical properties instead (read count within expected range, quality distribution similar).

---

## 9. Acceptance Criteria Per Phase

### Phase 1: Model Layer and Schema

**Technical criteria:**
- All 16 `FASTQDerivativeOperation.Kind` cases serialize and deserialize correctly
- `ProcessingRecipe` with up to 10 steps round-trips through JSON
- `BatchManifest` and `BatchComparisonManifest` round-trip correctly
- `ReferenceSequenceManifest` round-trips correctly
- Schema version 1 manifests load correctly with version 2+ code (backward compatibility)
- All new model types conform to `Sendable`, `Codable`, `Equatable`

**User-facing criteria:**
- N/A (model layer only)

**Test count target:** 40+ new unit tests
**Duration:** All pass in < 10 seconds

### Phase 2: Service Layer (Virtual Operations + Batch Engine)

**Technical criteria:**
- `FASTQDerivativeService.createDerivative` works for all request types with 3+ reads
- `FASTQDerivativeService.exportMaterializedFASTQ` works through 1-, 2-, and 3-level lineage chains
- `BatchProcessingEngine` processes 2+ barcodes with 3+ recipe steps
- Cancellation tested and verified
- Progress callbacks fire with correct barcode counts and step indices
- Error in one barcode does not corrupt other barcodes' output
- `convertStepToRequest` handles all non-demux operation kinds

**User-facing criteria:**
- A biologist can: import a FASTQ, run demux, apply a built-in recipe to all barcodes, and export materialized results
- Batch progress is visible (progress callback provides barcode-level granularity)
- Error messages are actionable ("Step 2 failed for barcode bc03: fastp exited with code 1")

**Performance criteria:**
- Materialize 1,000-read subset in < 2 seconds
- Batch process 12 barcodes x 3 steps in < 60 seconds

**Test count target:** 30+ new integration tests
**Duration:** All pass in < 3 minutes

### Phase 3: Reference Management + Operation Chaining

**Technical criteria:**
- Reference FASTA import creates valid `.lungfishref` bundle
- Reference listing works with 0, 1, and 10+ references
- Orient operation uses imported reference correctly
- Chaining orient -> demux -> trim -> filter -> materialize produces correct sequences
- Lineage array accurately reflects full operation chain
- Root bundle path stable through arbitrary chain depth

**User-facing criteria:**
- A biologist can: import a reference FASTA, select it for orientation, run demux with trimming, apply a recipe, and verify results match expected amplicon sizes
- Reference selection dropdown shows all imported references sorted by name
- Operation panel shows current lineage as breadcrumb trail

**Performance criteria:**
- Reference import for 10 MB FASTA in < 5 seconds
- Sidebar refreshes in < 100 ms after adding 24 demux child bundles

**Test count target:** 20+ new tests
**Duration:** All pass in < 2 minutes

### Phase 4: UI Polish and Release

**Technical criteria:**
- All quality gates from Phases 1-3 remain green
- No P0 or P1 defects open
- Zero regression in the baseline 3,508 tests
- Performance benchmarks met

**User-facing criteria (exploratory testing checklist):**
- [ ] Import a FASTQ file > 100 MB -- UI remains responsive
- [ ] Demux with 24 barcodes -- sidebar tree renders correctly
- [ ] Apply Illumina WGS recipe to all barcodes -- batch completes, comparison table shows metrics
- [ ] Export materialized FASTQ -- file opens correctly in external tool (e.g., `seqkit stats`)
- [ ] Cancel batch mid-processing -- no corrupt files, UI recovers gracefully
- [ ] Import reference, select for orient, verify oriented preview is correct
- [ ] Create custom recipe, save, reload app, recipe persists
- [ ] Delete a parent bundle -- child bundles show error state, not crash
- [ ] Resize sidebar during batch processing -- no UI freeze
- [ ] Close and reopen project -- all bundles, derivatives, and references rediscovered

---

## 10. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Orient + trim position interaction produces wrong sequences | High | Critical | Equivalence tests comparing virtual vs direct tool output |
| Batch engine concurrent access to shared temp directories | Medium | High | Actor isolation + unique temp dir per barcode (already in code) |
| Schema changes break existing project files | Medium | High | Backward compatibility tests loading v1 manifests |
| External tool version change alters output format | Low | Medium | Pin tool versions in `NativeToolRunner.bundledVersions`, test with pinned versions |
| Large file (>1 GB) materialization runs out of memory | Medium | High | Streaming materialization (already implemented), add memory benchmark test |
| Primer trim with `--revcomp` produces unexpected orientation | Medium | High | PrimerTrimFixtureIntegrationTests already covers this; expand with more primers |
| Sidebar performance degrades with 100+ derivative bundles | Low | Medium | Performance benchmark test for sidebar refresh |
| Recipe with incompatible step order (e.g., PE merge then deinterleave) | Medium | Medium | Recipe validation at creation time, not just execution time |

---

## 11. Test Infrastructure Requirements

### 11.1 Shared Test Helpers

Extract common patterns into a shared helper file `Tests/TestHelpers/FASTQTestHelpers.swift`:

- `makeTempDir() throws -> URL` -- create unique temp directory
- `makeFASTQBundle(named:in:) throws -> (bundleURL: URL, fastqURL: URL)` -- create bundle structure
- `writeFASTQ(records:to:) throws` -- write synthetic FASTQ
- `writeFASTA(records:to:) throws` -- write synthetic FASTA
- `loadFASTQRecords(from:) async throws -> [FASTQRecord]` -- read back for assertion
- `countFASTQRecords(at:) throws -> Int` -- quick count
- `XCTAssertThrowsErrorAsync` -- already exists in FASTQProjectSimulationTests, should be shared

These helpers are currently duplicated across 5+ test files. Centralizing them reduces maintenance burden and ensures consistency.

### 11.2 Test Resource Bundles

For `PrimerTrimFixtureIntegrationTests`, fixture files are loaded via `Bundle.module`. New fixture files (if any) should follow this pattern using SPM resource declarations in `Package.swift`.

### 11.3 CI Integration

Tests should be runnable via:
```bash
swift test --filter LungfishIOTests
swift test --filter LungfishAppTests
swift test --filter LungfishWorkflowTests
swift test  # all targets
```

No special environment setup required beyond having the bundled tools in the expected location (already handled by `NativeToolRunner`).

---

## 12. Summary: New Test Files and Estimated Counts

| New Test File | Target | Estimated Tests | Priority |
|---|---|---|---|
| `ReferenceSequenceFolderTests.swift` | LungfishIOTests | 13 | P0 |
| `FASTQMaterializationTests.swift` | LungfishAppTests | 10 | P0 |
| `BatchProcessingEngineTests.swift` | LungfishAppTests | 12 | P0 |
| `FASTQSidebarTreeTests.swift` | LungfishAppTests | 5 | P1 |
| `FASTQOperationChainTests.swift` | LungfishAppTests | 6 | P0 |
| ProcessingRecipeTests.swift (extend) | LungfishIOTests | 6 | P1 |
| FASTQDerivativesTests.swift (extend) | LungfishIOTests | 5 (schema compat) | P1 |

**Total new tests: ~57**
**Total FASTQ tests after completion: ~227**
**Overall test suite: ~3,565**

---

*Document prepared based on analysis of the `fastq-features` branch as of commit `ca1171f`. All file paths, type names, and method signatures reference actual codebase entities verified through source code review.*
