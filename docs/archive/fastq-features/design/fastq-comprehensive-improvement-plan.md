# FASTQ Functionality Comprehensive Improvement Plan

## Expert Review Teams & Methodology

Five independent expert teams reviewed the FASTQ transformation functionality in parallel:

1. **Swift Code Quality** — Concurrency safety, type mismatches, error handling, memory management
2. **UX Usability** — Information architecture, visual hierarchy, workflow intuitiveness, feedback
3. **Genomics Functionality** — Adapter correctness, multi-step demux, platform parameters, M13BC support
4. **macOS Architecture** — NSSplitView behavior, constraint systems, macOS Tahoe compatibility
5. **QA / Integration Testing** — Test coverage gaps, regression tests, edge cases

Test case: ONT barcode 13 FASTQ with internal PacBio M13BC combinatorial primers for Mamu-E MHC typing (272 samples, 36 unique barcodes).

---

## Phase 1: Critical Bug Fixes (Immediate)

### 1A. Fix Split View Drag Failure (Root Cause Found)

**Root Cause:** `SidebarDropTargetView` in `SidebarViewController.loadView()` sets `translatesAutoresizingMaskIntoConstraints = false` on the root view. NSSplitView manages child view frames via autoresizing masks — disabling this prevents the split view from resizing the sidebar when dividers are dragged.

**Files:**
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` line 155

**Fix:**
- Remove `containerView.translatesAutoresizingMaskIntoConstraints = false` from `SidebarDropTargetView`
- Clear stale autosave from UserDefaults (one-time migration)
- Add `constrainMinCoordinate` / `constrainMaxCoordinate` delegate methods to `MainSplitViewController`
- Test `inspectorWithViewController:` on Tahoe — may need `.collapseBehavior = .preferResizingSplitViewWithFixedSiblings`

**Estimated complexity:** Low (1-line core fix + ~30 lines for delegate methods and autosave cleanup)

### 1B. Fix "Adapter Sequence is Empty" Bug (Root Cause Found)

**Root Cause:** When scout completes for an ONT native barcoding kit (symmetric pairing), `handleScoutProceed` creates `FASTQSampleBarcodeAssignment` entries with `nil` reverse sequences (symmetric kits have no i5 sequence). When `createAdapterConfiguration` processes these assignments via `compactMap`, `resolveSequence` returns nil for the reverse barcode, dropping ALL entries. The resulting empty adapter FASTA causes cutadapt to fail with exit code 2.

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` lines 1577-1587 (`handleScoutProceed`)
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift` lines 455-466 (`createAdapterConfiguration`)

**Fix (two-pronged):**
1. In `handleScoutProceed`: For symmetric kits, populate `reverseBarcodeID` with the forward barcode ID and `reverseSequence` with the reverse complement of the forward sequence
2. In `createAdapterConfiguration`: When `sampleAssignments` are present but the kit has `.symmetric` pairing, fall through to the `linkedSpec` path instead of the sample-assignments path
3. Add a guard that validates all generated adapter FASTA entries have non-empty sequences before writing

**Estimated complexity:** Medium (~40 lines across 2 files)

### 1C. Fix Scout Functionality

**Root Cause:** Scout itself works at the pipeline level, but the integration is broken because:
1. The pruned kit from scout is stored only in-memory (`demuxKitOptions` array) and lost on re-lookup
2. The derivative service re-resolves the kit from a string ID, losing scout pruning
3. Scout results are not persisted to `FASTQDemultiplexMetadata.customBarcodeSets`

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` lines 1551-1600
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift` lines 404-510

**Fix:**
1. Pass the full `BarcodeKitDefinition` object through the request (not just string ID)
2. Persist pruned kit as a custom barcode set in metadata
3. Add `BarcodeKitDefinition?` override parameter to `createDemultiplexDerivative`

**Estimated complexity:** Medium (~60 lines)

---

## Phase 2: Architecture & UX Unification (High Priority)

### 2A. Unify Demux Configuration (Critical UX Issue)

**Problem:** Demultiplexing can be configured in TWO completely independent places with different data models:
1. Operations panel "Demultiplex (Barcodes)" with its own kit popup, location, error rate, windows, trim, scout button
2. Bottom drawer "Demux Setup" tab with step list, kit popup, location, symmetry, error rate, trim, scout button

These operate on different data models with no synchronization.

**Fix:**
- Remove the demux-specific parameter controls from the Operations panel parameter bar
- When "Demultiplex" operation is selected, show a read-only summary of the drawer's `DemultiplexPlan` configuration with a "Configure in Drawer..." button that opens/focuses the Demux Setup tab
- The Run button reads configuration from the drawer's `currentDemuxPlan()`
- Eliminate the duplicate scout button in the Operations panel run bar

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` (parameter bar, buildOperationRequest)
- `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift` (Demux Setup tab)

**Estimated complexity:** High (~200 lines refactor)

### 2B. Wire Multi-Step DemultiplexPlan to Execution

**Problem:** `DemultiplexingPipeline.runMultiStep()` exists (fully implemented) but has ZERO callers. The `FASTQDerivativeService` only calls `pipeline.run()` (single-step). The Demux Setup tab's multi-step UI is entirely decorative.

**Fix:**
- Add `createMultiStepDemultiplexDerivative()` to `FASTQDerivativeService`
- When `DemultiplexPlan.steps.count > 1`, route to `runMultiStep()` instead of `run()`
- Wire the drawer's `currentDemuxPlan()` through the unified execution path

**Files:**
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`

**Estimated complexity:** Medium (~80 lines)

### 2C. Add Cross-Platform Error Rate Intelligence

**Problem:** When running a PacBio M13BC kit on ONT reads, the pipeline uses PacBio's error rate (0.10) instead of the more appropriate ONT rate (0.15). For 16 bp M13BC barcodes, this allows only 1 mismatch instead of 2, causing significant under-assignment.

**Fix:**
- Detect source platform from FASTQ bundle metadata (`PersistedFASTQMetadata.ingestion.platform`)
- Use `max(kitErrorRate, sourcePlatformErrorRate)` for cross-platform demux
- Display a warning in the UI when cross-platform demux is detected

**Files:**
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift`

**Estimated complexity:** Low (~20 lines)

---

## Phase 3: Error Feedback & Validation (High Priority)

### 3A. Replace Silent Status Label Errors with Visible Feedback

**Problem:** All parameter validation errors go to a 10pt tertiary-color status label at the bottom-left. Users click Run, nothing happens, and they don't know why.

**Fix:**
- Use `.systemRed` color for error messages in the status label
- Add inline validation near offending fields (red border + tooltip)
- Add brief shake animation on Run button when validation fails
- Disable Run button until minimum required parameters are entered

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` (buildOperationRequest, updateParameterBar)

**Estimated complexity:** Medium (~100 lines)

### 3B. Replace Modal Alerts with Inline Error Banners

**Problem:** Operation failures present `NSAlert.runModal()` — blocking modal dialogs that break workflow.

**Fix:**
- Replace `runModal()` with inline error banner below parameter bar
- Include actionable guidance (e.g., "Check barcode kit definition")
- Add "Show Details" disclosure for full error text
- Keep `\(error)` debug representation available

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` (runOperationClicked error handler)

**Estimated complexity:** Medium (~60 lines)

### 3C. Add Empty Adapter Sequence Validation

**Problem:** No guard prevents empty adapter sequences from reaching cutadapt.

**Fix:**
- In `createAdapterConfiguration`, validate all FASTA entries before writing
- Throw a descriptive `DemultiplexError` instead of letting cutadapt fail with a cryptic message

**Files:**
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`

**Estimated complexity:** Low (~15 lines)

---

## Phase 4: Layout & Responsiveness (Medium Priority)

### 4A. Fix Parameter Bar Overflow for Demux Operation

**Problem:** The demux operation adds 9 controls to a single horizontal NSStackView row. At narrow widths, controls truncate or become invisible.

**Fix:**
- Use a two-row or form-style layout for demux specifically
- Row 1: Kit + Location
- Row 2: Error Rate + Windows + Trim
- Or: use an NSScrollView with horizontal scrolling

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` (updateParameterBar for .demultiplex)

**Estimated complexity:** Medium (~50 lines)

### 4B. Fix Summary Bar Card Text Overlap

**Problem:** The FASTQSummaryBar draws 9 cards with equal width. At narrow widths, CoreGraphics text overflows card bounds and overlaps adjacent cards.

**Fix:**
- Check text width against card width before drawing
- Use abbreviated labels when narrow (e.g., "Med. Len" instead of "Median Length")
- Or reduce to 6 essential cards with overflow in a tooltip/popover

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQChartViews.swift` (FASTQSummaryBar.draw)

**Estimated complexity:** Medium (~40 lines)

### 4C. Fix Drawer Constraint Conflicts at Small Heights

**Problem:** Multiplier constraints (0.35, 0.3) conflict with minimum height constraints at small drawer heights.

**Fix:**
- Add `greaterThanOrEqualToConstant: 60` to kit list scroll view (currently missing)
- Ensure multiplier constraints have lower priority than minimum height constraints
- Already partially fixed — verify the `.defaultHigh` vs `.defaultHigh + 1` priorities

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift`

**Estimated complexity:** Low (~10 lines)

---

## Phase 5: Workflow Improvements (Medium Priority)

### 5A. Add Excel/TSV Import for Combinatorial Sample Assignments

**Problem:** The test case requires 272 `FASTQSampleBarcodeAssignment` entries from an Excel barcode spreadsheet. Currently no import pathway exists for this format.

**Fix:**
- Add TSV/CSV import that parses columns: `sample_id, forward_barcode_id, reverse_barcode_id[, sample_name]`
- Auto-detect column headers from common naming patterns
- Wire to the Samples tab's import button

**Files:**
- `Sources/LungfishIO/Formats/FASTQ/FASTQSampleBarcodeCSV.swift` (extend parser)
- `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift` (import handler)

**Estimated complexity:** Medium (~80 lines)

### 5B. Rename "Scout" to "Detect Barcodes"

**Problem:** "Scout" is not standard bioinformatics terminology. Users don't understand what the button does.

**Fix:**
- Rename all instances: "Scout Barcodes" → "Detect Barcodes", "Scout" → "Detect"
- Add tooltip: "Scan the first 10,000 reads to identify which barcodes are present"
- Rename `BarcodeScoutSheet` → `BarcodeDetectionSheet`, `BarcodeScoutResult` → `BarcodeDetectionResult`

**Files:** Multiple files (search for "Scout" across codebase)

**Estimated complexity:** Low but wide (~30 files touched)

### 5C. Add Sparkline Click Discoverability

**Problem:** Clicking disabled sparkline areas triggers quality report computation, but there's no visual indication they're clickable.

**Fix:**
- Draw "Click to compute" overlay on disabled sparkline areas
- Change cursor to `.pointingHand` on hover

**Files:**
- `Sources/LungfishApp/Views/Viewer/FASTQSparklineStrip.swift`

**Estimated complexity:** Low (~15 lines)

---

## Phase 6: Code Quality & Cleanup (Lower Priority)

### 6A. Migrate Illumina Typealias Names

**Problem:** `IlluminaBarcodeDefinition` and `IlluminaBarcodeKitRegistry` are typealiases for `BarcodeKitDefinition` and `BarcodeKitRegistry`. The Illumina-prefixed names are used throughout the codebase even for ONT and PacBio kits, causing confusion.

**Fix:**
- Replace all call sites with canonical names
- Add `@available(*, deprecated, renamed:)` to typealiases
- Eventual removal

**Estimated complexity:** Low but wide

### 6B. Fix Retain Cycle Risk in operationTask Closure

**Problem:** `onRunOperation` is captured strongly in the Task closure, creating a potential retain cycle.

**Fix:**
```swift
operationTask = Task { [weak self, onRunOperation] in
    guard let onRunOperation else { return }
```

**Estimated complexity:** Trivial

### 6C. Fix deinit @MainActor Isolation

**Problem:** `FASTQDatasetViewController.deinit` accesses `@MainActor`-isolated Task properties without isolation.

**Fix:** Mark the Task handle properties as `nonisolated(unsafe)` since `Task.cancel()` is thread-safe.

**Estimated complexity:** Trivial

### 6D. Fix Logging Convention

**Problem:** Some log messages use `error.localizedDescription` instead of `\(error)` per project convention.

**Fix:** Replace `.localizedDescription` with `\(error)` in logger calls.

**Estimated complexity:** Trivial

---

## Phase 7: Test Coverage (Ongoing, Parallel with Fixes)

### P0 Tests (Must ship with Phase 1 fixes)

| Test | Target | Description |
|------|--------|-------------|
| `testLinkedSpecNeverEmptyForAllONTKits` | LungfishIOTests | All ONT kits produce non-empty linked specs |
| `testAdapterFASTAContentNonEmptyForAllKits` | LungfishWorkflowTests | Generated FASTA has no empty sequences for all 18 kits |
| `testRunWithONTNativeBarcoding24` | LungfishWorkflowTests | End-to-end pipeline run with ONT native kit |
| `testScoutWithSyntheticONTFASTQ` | LungfishWorkflowTests | Scout pipeline produces detections |
| `testAllBuiltinKitsResolvableByID` | LungfishIOTests | Every kit round-trips through registry lookup |

### P1 Tests (Should ship with Phase 2)

| Test | Target | Description |
|------|--------|-------------|
| `testCreateDemultiplexDerivativeUnknownKitThrows` | LungfishAppTests | Service rejects unknown kit IDs |
| `testCreateDemultiplexDerivativeLocationParsing` | LungfishAppTests | All location strings parse correctly |
| `testResolvedAdapterContextForAllBuiltinKits` | LungfishWorkflowTests | Correct context type per kit |
| `testCombinatorialDualWithoutAssignmentsThrows` | LungfishWorkflowTests | Guard fires for combinatorial kits |
| `testSplitViewItemsHaveCorrectThicknesses` | LungfishAppTests | Regression test for split view config |
| `testCustomCSVKitUsesBareAdapterContext` | LungfishIOTests | Custom kits get BareAdapterContext |

### P2 Tests (Subsequent phases)

| Test | Target | Description |
|------|--------|-------------|
| `testBuildCutadaptArgumentsIncludesPolyGTrim` | LungfishWorkflowTests | Poly-G flag present in args |
| `testBarcodeLocationDecodesAnywhereAsBothEnds` | LungfishIOTests | Backward compat decoding |
| `testWindowedAdapterFASTAGeneratesOffsetPatterns` | LungfishWorkflowTests | Window > 0 generates offset FASTA |
| `testLoadCustomCSVEmptySequence` | LungfishIOTests | Edge case handling |
| `testHandleScoutProceedPrunesKit` | LungfishAppTests | Scout kit pruning |

---

## Implementation Order

| Phase | Priority | Items | Est. Effort |
|-------|----------|-------|-------------|
| **1** | Critical | 1A + 1B + 1C + P0 tests | ~3 hours |
| **2** | High | 2A + 2B + 2C + P1 tests | ~4 hours |
| **3** | High | 3A + 3B + 3C | ~2 hours |
| **4** | Medium | 4A + 4B + 4C | ~2 hours |
| **5** | Medium | 5A + 5B + 5C | ~2 hours |
| **6** | Lower | 6A + 6B + 6C + 6D | ~1 hour |
| **7** | Ongoing | P2 tests | ~2 hours |

**Total estimated effort: ~16 hours across 7 phases**

---

## Appendix: Review Team Reports

### Team 1 — Swift Code Quality (17 findings)
- 2 Critical: Pruned kit lost in serialization; symmetric ONT nil reverse sequences
- 3 High: Scout results not persisted; symmetric assignment resolution fails; split view
- 6 Medium: Retain cycles, deinit isolation, logging, modal alerts, detached task cleanup
- 6 Low: Magic numbers, typealias confusion, minor inefficiencies

### Team 2 — UX Usability (16 findings)
- 2 Critical: Dual demux configuration confusion; duplicate scout buttons
- 4 High: Parameter bar overflow; invisible error feedback; modal alerts; premature Run enable
- 6 Medium: Category header deselection; no undo; opaque "Scout" terminology; sparklines; demux parameter density; Operations/Reads tab selector
- 5 Low: Summary bar truncation; no keyboard shortcuts; split view constraints; font inconsistency; scout sheet width

### Team 3 — Genomics Functionality (9 findings)
- 1 Critical: Empty adapter sequences from nil reverse in symmetric kits
- 2 High: Multi-step plan not wired; combinatorial assignment workflow gap
- 1 Medium: Cross-platform error rate mismatch
- 5 Low: Adapter sequences correct; M13BC coverage sufficient; linked spec correct; read orientation handling correct

### Team 4 — macOS Architecture (7 findings)
- 1 Critical: `translatesAutoresizingMaskIntoConstraints = false` on sidebar root view
- 1 High: Missing `constrainMinCoordinate`/`constrainMaxCoordinate` delegate methods
- 3 Medium: `inspectorWithViewController:` Tahoe overlay; stale autosaveName; drawer constraint conflicts
- 1 Low: Holding priority values correct
- 1 Info: Inner split pane setup correct

### Team 5 — QA / Integration Testing (23 gaps identified)
- 4 P0: ONT adapter FASTA, scout pipeline, ONT run integration, adapter config for all kits
- 6 P1: Kit ID round-trip, derivative service, validation logic, adapter contexts, combinatorial guard, custom kit context
- 10 P2: CSV edge cases, backward compat, scout sheet UI, kit pruning, request passthrough, windowed matching, poly-G integration, assignments, manifest persistence, split view
- 3 P3: Zero thresholds, symmetry completeness, concurrent multi-step
