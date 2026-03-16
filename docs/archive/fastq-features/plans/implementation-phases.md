# Unified FASTQ/FASTA Workflow Redesign: Phased Implementation Plan

*Date: 2026-03-14*
*Status: Approved by expert panel synthesis*
*Branch: fastq-features*
*Expert inputs: macOS architecture, Swift concurrency, bioinformatics tools, lab scientist, UX design, performance, QA/QC*

---

## Overview

This plan synthesizes recommendations from 7 expert teams into 6 implementation phases. Each phase has clear entry/exit criteria, test requirements, and code review gates. Phases are designed to be independently testable and reviewable.

**Core design decisions (consensus across all experts):**

1. **Virtual by default, materialize on demand.** Operations produce pointer-based bundles (read ID lists, trim position TSVs, orient maps). Full FASTQs are written only when the user explicitly materializes or exports.
2. **`derivatives/` directory inside each bundle.** Non-demux operations write children to `{parent}/derivatives/`. Demux keeps its existing `demux/` path. Hierarchy matches logical lineage.
3. **Operation labels in sidebar, not filenames.** Users see "Quality Trim Q20", not `qtrim-Q20-a1b2c3d4.lungfishfastq`.
4. **References folder as pinned top-level section.** All reference-requiring operations discover candidates from a single well-known project location.
5. **Actor-based materialization pipeline.** `MaterializationPipeline` actor manages concurrent materialization with bounded concurrency, progress callbacks via GCD+assumeIsolated pattern.
6. **Recipe validation via OperationContract.** Type-safe input/output chain validation prevents invalid operation orderings before execution.
7. **Batch generalization beyond demux.** `BatchProcessingEngine` accepts `[BatchSource]` instead of `DemultiplexManifest`, enabling batch operations on any set of selected bundles.

---

## Phase 1: Model Layer & Schema Extensions

**Goal:** Add all new data types needed by subsequent phases. No UI changes, no service changes. Pure LungfishIO additions.

### 1.1 Deliverables

| File | Change | Module |
|------|--------|--------|
| `VirtualFASTQState.swift` (new) | `MaterializationState` enum (.virtual, .materializing(taskID), .materialized(checksum)) | LungfishIO |
| `VirtualFASTQState.swift` (new) | `VirtualFASTQDescriptor` struct (immutable job spec for materialization) | LungfishIO |
| `FASTQDerivatives.swift` | Add `materializationState: MaterializationState?` and `resolvedState` computed property to `FASTQDerivedBundleManifest` | LungfishIO |
| `OperationChain.swift` (new) | `OperationInput`, `OperationOutput`, `OperationContract` enum with static validation methods | LungfishIO |
| `ProcessingRecipe.swift` | Add `validate(inputFormat:inputPairing:) -> ValidationError?` using `OperationContract` | LungfishIO |
| `ReferenceCandidate.swift` (new) | `ReferenceCandidate` enum (.projectReference, .genomeBundleFASTA, .standaloneFASTA) | LungfishIO |
| `FASTQDerivatives.swift` | Add `FASTQDerivativeOperationKind` enum (extracted from operation, for contract mapping) | LungfishIO |

### 1.2 Design Details

**MaterializationState:** Codable + Sendable value type. `materializing(taskID:)` is transient — treated as `.virtual` on app relaunch (stale task ID). The manifest field is optional with nil default for backward compatibility.

**OperationContract:** Maps each operation kind to input requirements (accepted formats, required pairing) and output shape (format, pairing state). Validation walks the recipe step list, threading output→input through the chain. Errors include `incompatibleFormat`, `incompatiblePairing`, `demultiplexNotTerminal`.

**Ordering rules encoded in validation (from bioinformatics expert):**
- ERROR: pairedEndMerge before adapterTrim
- WARNING: qualityTrim before primerRemoval
- WARNING: adapterTrim before primerRemoval

**ReferenceCandidate:** Lightweight enum for populating operation panel dropdowns. Each case carries a URL and display name. `fastaURL` computed property resolves to the actual FASTA file.

### 1.3 Test Requirements

| Test File | New Tests | Priority |
|-----------|-----------|----------|
| `FASTQDerivativesTests.swift` (extend) | MaterializationState round-trip, resolvedState logic for all payload types, backward-compat with manifests missing the field | P0 |
| `ProcessingRecipeTests.swift` (extend) | `validate()` rejects incompatible chains, accepts valid chains, warns on suboptimal ordering | P0 |
| `OperationChainTests.swift` (new) | OperationContract.input/output for all operation kinds, chain threading | P0 |
| `ReferenceSequenceFolderTests.swift` (new) | Import creates bundle, idempotent import, list sorted, malformed bundles skipped, fastaURL nil for missing file | P0 |

**Target: 30+ new unit tests, all < 10 seconds**

### 1.4 Exit Criteria

- All new types conform to `Sendable`, `Codable`, `Equatable`
- Existing manifests without `materializationState` decode correctly (nil → resolvedState fallback)
- `ProcessingRecipe.validate()` correctly identifies all bioinformatics expert ordering violations
- Zero test failures in LungfishIOTests
- All existing ~3,508 tests still pass

---

## Phase 2: Service Layer & Materialization Pipeline

**Goal:** Decompose FASTQDerivativeService, implement MaterializationPipeline actor, generalize BatchProcessingEngine.

### 2.1 Deliverables

| File | Change | Module |
|------|--------|--------|
| `MaterializationPipeline.swift` (new) | Actor with bounded concurrency, job registry, progress callbacks, cancellation | LungfishApp |
| `FASTQDerivativeService.swift` | Extract `VirtualDatasetFactory` methods (pointer creation, no tool execution) | LungfishApp |
| `FASTQDerivativeService.swift` | Add `derivatives/` output directory for non-demux operations | LungfishApp |
| `BatchProcessingEngine.swift` | Accept `[BatchSource]` instead of `DemultiplexManifest`; keep existing API as convenience wrapper | LungfishApp |
| `BatchProcessingEngine.swift` | Add per-step concurrency limit support (from bioinformatics expert) | LungfishApp |
| `FASTQBundle.swift` | Add helpers: `derivativesDirectoryURL(in:)`, `scanDerivatives(in:)` | LungfishIO |

### 2.2 Design Details

**MaterializationPipeline actor:**
- Manages `activeTasks: [UUID: Task<JobResult, Never>]` and `progressSnapshots: [UUID: JobProgress]`
- `materialize(_:onProgress:) -> UUID` enqueues a job, returns immediately
- `materializeBatch(_:onProgress:)` uses `withTaskGroup` with bounded concurrency
- Progress reported via `@Sendable` callback; UI dispatches via `DispatchQueue.main.async { MainActor.assumeIsolated { } }`
- Writes to temp directory first, atomically moves into bundle on success
- Updates manifest with `.materialized(checksum:)` on completion

**derivatives/ directory:**
- `FASTQDerivativeService.createDerivative` writes non-demux results to `{parentBundle}/derivatives/{opname}-{shortid}.lungfishfastq/`
- Sidebar scan (`SidebarViewController.buildSidebarTree`) extended to scan `derivatives/` in addition to `demux/`
- Short UUID suffix (first 8 chars) prevents collisions for repeated operations

**BatchProcessingEngine generalization:**
- New `BatchSource` struct: `bundleURL`, `displayName`, `readCount`
- `executeBatch(sources:recipe:batchName:outputDirectory:progress:)` replaces demux-specific API
- Existing `executeBatch(demuxGroupURL:manifest:...)` becomes a convenience wrapper that converts `DemultiplexManifest.barcodes` to `[BatchSource]`
- Per-step concurrency: recipe steps can declare `maxConcurrency` override (default: engine's global setting)

### 2.3 Test Requirements

| Test File | New Tests | Priority |
|-----------|-----------|----------|
| `FASTQMaterializationTests.swift` (new) | Materialize subset (exact reads), trim (correct sequences), 3-level chain, demux+trim+filter chain, empty subset, equivalence vs direct tool | P0 |
| `BatchProcessingEngineTests.swift` (new) | Empty recipe rejected, single barcode/step, 2 barcodes × 3 steps, step failure skips remaining, cancellation, progress callbacks, directory structure, concurrent == sequential | P0 |
| `FASTQOperationChainTests.swift` (new) | Trim→filter stats reflect chain, demux→trim preview correct, lineage accumulates, root path stable through chain | P0 |

**Target: 30+ new integration tests, all < 3 minutes**

### 2.4 Exit Criteria

- MaterializationPipeline materializes through 1-, 2-, and 3-level lineage chains
- BatchProcessingEngine processes 2+ sources with 3+ recipe steps
- Cancellation leaves clean filesystem (no partial bundles)
- Concurrent execution (maxConcurrency=4) produces same results as sequential (maxConcurrency=1)
- Virtual-vs-direct equivalence test passes for trim, filter, and trim+filter chains
- All existing tests still pass

---

## Phase 3: Reference Sequence Management

**Goal:** Implement the References folder, reference discovery service, and integrate with operation configuration panels.

### 3.1 Deliverables

| File | Change | Module |
|------|--------|--------|
| `ReferenceDiscoveryService.swift` (new) | `@MainActor` service discovering all reference candidates in project | LungfishApp |
| `ReferenceSequenceScanner.swift` (new) | `AsyncStream`-based scanner for incremental reference discovery | LungfishIO |
| `SidebarViewController.swift` | Add "Reference Sequences" top-level section, always visible, pinned above Data | LungfishApp |
| `SidebarViewController.swift` | Context menus: "Add Reference Genome...", "Import Reference File...", "Remove from Project" | LungfishApp |
| `FASTQDatasetViewController.swift` | Reference dropdown in operation config panels populated from ReferenceDiscoveryService | LungfishApp |
| `ReferenceSequenceFolder.swift` | `ensureFolder(in:)` auto-creates on project open; folder icon SF Symbol | LungfishIO |

### 3.2 Design Details

**Reference discovery (three sources, per macOS architecture expert):**
1. Explicit references from `Reference Sequences/` folder (`.lungfishref` bundles)
2. Genome bundle FASTAs from `Downloads/` (`.lungfishref` bundles)
3. Standalone FASTA files anywhere in project tree

**Operation panel integration:**
- NSPopUpButton pre-populated with candidates grouped by source
- Separator + "Browse..." + "Download from NCBI..." at bottom
- Last-used reference remembered per operation type per project (UserDefaults)
- When user browses and picks a file, prompt "Add to project References folder?"

**Auto-discovery filtering (from bioinformatics expert):**
- Files named `*primer*` or `*oligo*` → primer removal operations
- Files named `*contam*`, `*host*`, `*phix*` → contaminant filtering
- Largest FASTA or `*genome*`/`*reference*` named → mapping, orientation

### 3.3 Test Requirements

| Test File | New Tests | Priority |
|-----------|-----------|----------|
| `ReferenceSequenceFolderTests.swift` (extend) | ensureFolder creates dir, idempotent, isProjectReference for internal/external paths | P0 |
| `FASTQProjectSimulationTests.swift` (extend) | Import reference → orient → demux → batch pipeline end-to-end | P0 |
| `FASTQSidebarTreeTests.swift` (new) | Parent discovers demux children, child resolves parent path, 3-level chain resolves root, orphaned child handled | P1 |

**Target: 20+ new tests, all < 2 minutes**

### 3.4 Exit Criteria

- Reference import creates valid `.lungfishref` bundle with correct manifest
- Reference listing works with 0, 1, and 10+ references
- Orient operation uses imported reference correctly
- Reference dropdown shows all imported references sorted by name
- Sidebar "Reference Sequences" section renders correctly
- Sidebar refreshes in < 100ms after adding 24 demux child bundles

---

## Phase 4: Sidebar UI & Batch UX

**Goal:** Implement the Geneious-inspired sidebar hierarchy with operation labels, status badges, virtual batch groups, and batch selection mechanisms.

### 4.1 Deliverables

| File | Change | Module |
|------|--------|--------|
| `SidebarViewController.swift` | Show operation `shortLabel` instead of filenames for derived bundles | LungfishApp |
| `SidebarViewController.swift` | Virtual/materialized icon badges (no badge = virtual, filled circle = materialized, spinner = materializing, warning triangle = stale) | LungfishApp |
| `SidebarViewController.swift` | Scan `derivatives/` directory for non-demux children | LungfishApp |
| `SidebarViewController.swift` | Virtual batch group nodes under "Batch Results" top-level section | LungfishApp |
| `SidebarViewController.swift` | "Select All Siblings" (Cmd+Shift+A) | LungfishApp |
| `SidebarViewController.swift` | Collapsed summary row for >12 barcode children ("96 barcodes, 12.4M total reads") | LungfishApp |
| `SidebarViewController.swift` | Context menus: "Materialize...", "Run Operation on All...", "Export as FASTQ...", "Compare with Parent", "Create Group from Selection" | LungfishApp |
| `SidebarViewController.swift` | Subtitle line: read count + mean quality in `.caption` style | LungfishApp |
| `BatchProgressViewController.swift` (new) | Batch progress grid (barcodes × steps) with per-cell status | LungfishApp |

### 4.2 Design Details

**Icon treatment (from UX expert):**

| Status | Icon | Text Color | Subtitle |
|--------|------|------------|----------|
| Root FASTQ | Standard file icon | `.labelColor` | "1.2M reads  Q32.1" |
| Virtual derivative | Operation SF Symbol, standard opacity | `.secondaryLabelColor` | "23.4K reads  Q34.2" |
| Materialized derivative | Same + filled circle badge (bottom-right) | `.labelColor` | "23.4K reads  Q34.2  156 MB" |
| Materializing | Same + spinning indicator | `.secondaryLabelColor` | "Materializing... 67%" |
| Stale | Same + yellow warning triangle | `.secondaryLabelColor` | "Source changed" |

**Batch group behavior:**
- Created automatically when batch completes
- Selecting group shows Batch Comparison Table in content area
- Expanding group shows flat list of member items
- "Run Operation on All..." applies operation to all members
- Group is a computed overlay — deleting group never deletes data

**Batch selection mechanisms (three tiers):**
1. Virtual batch group nodes (primary)
2. Select All Siblings — Cmd+Shift+A (secondary)
3. Sidebar search filter by operation type with Cmd+A (tertiary)

### 4.3 Test Requirements

| Test File | New Tests | Priority |
|-----------|-----------|----------|
| `FASTQSidebarTreeTests.swift` (extend) | Batch run children discovered under demux, operation labels render, virtual/materialized status correct | P1 |

**UI testing is primarily exploratory (from QA/QC expert checklist):**
- Import FASTQ > 100 MB — UI responsive
- Demux with 24 barcodes — sidebar renders correctly
- Apply recipe to all barcodes — batch completes, comparison table shows metrics
- Cancel batch mid-processing — no corrupt files, UI recovers
- Resize sidebar during batch — no freeze
- Close and reopen project — all bundles rediscovered

### 4.4 Exit Criteria

- Derived bundles show operation labels, not filenames
- Status badges render correctly for all 5 states
- Batch groups appear, expand, and support "Run Operation on All..."
- Cmd+Shift+A selects all siblings
- Sidebar performs well with 96+ barcode children (< 100ms refresh)
- All existing tests still pass

---

## Phase 5: Performance Fixes

**Goal:** Address P0 and P1 performance issues identified by the performance expert.

### 5.1 Deliverables

| File | Change | Priority |
|------|--------|----------|
| `GzipSupport.swift` | **P0:** Stream from gzip subprocess pipe in 1 MB chunks instead of loading entire decompressed file into RAM | P0 |
| `FASTQDerivativeService.swift` | **P0:** Merge `extractTrimPositions` two-pass into single pass, building only `trimmedByBaseID` | P0 |
| `FASTQWriter.swift` | **P1:** Add 256 KB write buffer, reducing syscalls by ~1000x (estimated 3-5x faster writes) | P1 |
| `FASTQDerivativeService.swift` | **P1:** Piggyback `FASTQStatisticsCollector` onto materialization/extraction pass (single-pass stats) | P1 |
| `MainSplitViewController.swift` | **P1:** Merge initial FASTQ load two-pass (seqkit stats + FASTQReader histogram) into single pass | P1 |

### 5.2 Design Details

**GzipInputStream streaming (P0):**
- Current: `decompressWithSystemGzip()` reads entire gzip into `Data` → `String`. 30 GB gzipped = ~130 GB RAM.
- Fix: Stream from subprocess pipe in 1 MB chunks, yield lines as available. Memory: O(1 MB buffer).

**extractTrimPositions single-pass (P0):**
- Current: Reads trimmed FASTQ twice, two dictionaries. 10M reads × 500 bytes = ~10 GB.
- Fix: Single pass building only `trimmedByBaseID`.

**Streaming materialization architecture:**
```
[Root FASTQ Reader] → [ID/Trim Filter] → [Buffered Writer] → [Output File]
                           |
                    [Stats Collector] (piggyback)
```

### 5.3 Test Requirements

- Memory benchmark: materialization of 100K-read file < 50 MB peak above baseline
- Write throughput: FASTQWriter benchmark showing ≥3x improvement
- Regression: all existing materialization tests still pass with streaming implementation
- Large file test: 10K+ reads through 3-step chain without OOM

### 5.4 Exit Criteria

- Peak memory during materialization < 500 MB regardless of file size
- Peak memory during statistics computation < 200 MB
- Materialize 1,000-read subset in < 2 seconds
- Batch 12 barcodes × 3 steps in < 60 seconds
- No regressions in existing tests

---

## Phase 6: Polish & Advanced Features

**Goal:** Implement high-value UX features identified by lab scientist and UX experts.

### 6.1 Deliverables

| Feature | Priority (lab scientist ranking) | Files |
|---------|----------------------------------|-------|
| **Before/after comparison** — overlaid quality/length distributions | #1 | FASTQDatasetViewController.swift, new ComparisonView |
| **Methods text export** — publication-ready processing description with tool versions and parameters | #4 | ProcessingRecipe.swift, FASTQDerivedBundleManifest |
| **Recipe templates with runtime placeholders** — separate "what to do" from "with what sequences" | #7 | ProcessingRecipe.swift |
| **Sample sheet as primary demux input** — import CSV with barcode→sample name mapping before demux | #3 (partial) | DemultiplexingPipeline.swift, FASTQDemultiplexMetadata.swift |
| **Materialized file drag-to-Finder** | UX phase 4 | SidebarViewController.swift |
| **Staleness detection** — yellow warning triangle when root modified post-materialization | UX phase 4 | FASTQDerivativeService.swift |

### 6.2 Design Details

**Before/after comparison (lab scientist #1 priority):**
- Dual-trace overlay: quality distribution (blue=before, orange=after)
- Summary table: total reads, mean quality, mean length, % removed
- Accessible via context menu "Compare with Parent" or toolbar button
- Uses cached statistics from both parent and child bundles

**Methods text export (lab scientist #4):**
- "Generate Methods Text" button produces publication-ready paragraph
- Includes tool names + versions (fastp v0.23.4, cutadapt v4.4)
- Includes all non-default parameters
- Optionally includes per-step read count statistics
- Example output provided in lab scientist expert plan Section 4.3

**Recipe templates with placeholders:**
- Recipe steps can have `placeholder` fields (e.g., `forwardPrimer`, `reversePrimer`, `referencePath`)
- When applying a template recipe, a form collects placeholder values
- Filled values stored in the batch manifest, not the recipe definition
- Separates "what to do" from "with what sequences"

### 6.3 Test Requirements

- Comparison view shows correct overlay for trim operation
- Methods text includes all pipeline steps with correct parameters
- Recipe with placeholders prompts for values and fills correctly
- Sample sheet import maps barcodes to sample names in sidebar

### 6.4 Exit Criteria

- Lab scientist can: import FASTQ → demux with sample sheet → apply recipe → view before/after comparison → export methods text
- All quality gates from phases 1-5 remain green
- No P0 or P1 defects open
- Full test suite passes in < 10 minutes
- Zero regressions in baseline tests

---

## Cross-Phase Constraints

### Concurrency Patterns (enforced in ALL phases)

- **NEVER** `Task { @MainActor in }` from GCD background queues
- **ALWAYS** `DispatchQueue.main.async { MainActor.assumeIsolated { } }` for UI updates from actors
- **ALWAYS** generation counters in `@MainActor` view controllers
- **ALWAYS** `@Sendable` progress callbacks, never `@Published` from actors
- **ALWAYS** `defer` cleanup for temp directories
- **ALWAYS** `Task.isCancelled` checks before tool invocations

### Code Review Checklist (every PR)

- [ ] New `FASTQDerivedBundleManifest` fields have default values (backward compat)
- [ ] Relative paths tested with `../` traversal
- [ ] Statistics consistency: cached read count matches actual
- [ ] Trim positions propagated through chain (not lost or doubled)
- [ ] Orient map awareness in sequence extraction
- [ ] Quality string length == sequence string length in materialized output
- [ ] No deprecated macOS 26 APIs (no wantsLayer, no lockFocus, no constrainMinCoordinate)
- [ ] Toolbar items use NSButton(frame:) with .bezelStyle = .toolbar

### Bioinformatics Operation Ordering (enforced in recipe validation)

Mandatory rules (from bioinformatics expert):
1. Primer removal BEFORE quality/adapter trimming
2. Adapter trimming BEFORE paired-end merging
3. Quality trimming BEFORE paired-end merging
4. PE repair BEFORE any PE operation
5. Demux BEFORE per-barcode processing
6. All preprocessing BEFORE mapping

---

## Summary Timeline

| Phase | Scope | Key Metric |
|-------|-------|------------|
| **1: Model Layer** | 7 files, ~30 tests | 100% of public model types have round-trip tests |
| **2: Service Layer** | 6 files, ~30 tests | Materialization through 3-level chains works |
| **3: References** | 6 files, ~20 tests | Reference dropdown populated from project |
| **4: Sidebar UI** | 2 files + 1 new, exploratory testing | Operation labels and status badges render |
| **5: Performance** | 5 files, benchmarks | Peak memory < 500 MB for any file size |
| **6: Polish** | 6+ files, ~15 tests | Lab scientist can complete full workflow |

**Total new tests across all phases: ~125**
**Final FASTQ test count: ~295**
**Overall test suite: ~3,633**

Each phase completes with expert review before proceeding. Human UI review occurs after Phase 6 completion.
