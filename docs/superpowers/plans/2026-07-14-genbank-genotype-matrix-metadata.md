# GenBank Genotype Matrix Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make newly generated GenBank-backed genotype results self-contained and display every GenBank record field as a configurable matrix column, while removing the summary strip, showing all samples, and persisting a resizable metadata/sample split.

**Architecture:** Add an optional checksummed GenBank record-store descriptor to the genotype result manifest and a shared workflow snapshot publisher used by both MHC genotyping pipelines. Load the embedded store into a compact sequence-name lookup, pass it to the genotype matrix, and adapt the established classifier column visibility mechanics to fixed plus record-level fields. Replace the matrix's fixed pinned width with an `NSSplitView`, remove sample windowing from this viewport, and persist split/column preferences through `UserDefaults`.

**Tech Stack:** Swift 6, AppKit, SQLite-backed `GenBankRecordDatabase`, Codable bundle manifests, XCTest, Swift Package Manager.

## Global Constraints

- Existing genotype results do not need GenBank metadata rehydration or provenance-path fallback.
- FASTA-only genotype results must retain the Genotype identifier as their default row label.
- Newly published GenBank-backed results must embed a validated record-store snapshot and complete reproducibility provenance pointing at the final stored payload.
- The row-selection control is permanent; every data column may be shown, hidden, and resized.
- All active sample columns are instantiated by default.
- Preserve unrelated user changes in the worktree.

---

### Task 1: Genotype Result Record-Store Manifest and Loader

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishIO/Bundles/GenBankRecordDatabase.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

**Interfaces:**
- Produces: `ONTGenotypeReferenceRecordStoreInfo` with `databasePath`, `format`, `schemaVersion`, `recordCount`, `fieldCount`, `sha256`, and `sizeBytes`.
- Produces: `ONTGenotypeReferenceMetadata` with ordered `fields`, `recordsBySequenceName`, and `alleleFieldKey`.
- Produces: `ONTGenotypeResultBundleData.referenceMetadata: ONTGenotypeReferenceMetadata?`.

- [ ] **Step 1: Add failing manifest round-trip and loader tests**

Create tests that encode/decode a manifest containing a record-store descriptor, load a fixture database from a bundle-relative path, verify exact fields and full allele values, verify FASTA-only manifests return `nil`, and verify escaped/missing/checksum-mismatched paths throw validation errors.

```swift
let info = ONTGenotypeReferenceRecordStoreInfo(
    databasePath: "metadata/genbank_records.sqlite",
    format: "lungfish-genbank-records-sqlite",
    schemaVersion: 1,
    recordCount: 1,
    fieldCount: 2,
    sha256: expectedSHA256,
    sizeBytes: expectedSize
)
XCTAssertEqual(decoded.referenceRecordStore, info)
XCTAssertEqual(result.referenceMetadata?.recordsBySequenceName["NHP01222"]?["feature.allele"], "Mafa-A1*006:01:02")
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: compilation fails because the descriptor and loaded metadata interfaces do not exist.

- [ ] **Step 3: Implement manifest coding, database metadata helpers, and safe loading**

Add the optional manifest property with defaulted initializer parameters so FASTA-only and existing call sites continue compiling. Add a `fieldCount()` database query. During `loadResult`, validate the bundle-relative path, format/schema, checksum, size, record/field counts, then materialize definitions and a sequence-keyed values dictionary.

```swift
public struct ONTGenotypeReferenceMetadata: Equatable, Sendable {
    public let fields: [GenBankRecordDatabase.FieldDefinition]
    public let recordsBySequenceName: [String: [String: String]]
    public let alleleFieldKey: String?
}
```

- [ ] **Step 4: Run focused IO tests**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit the manifest and loader**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Sources/LungfishIO/Bundles/GenBankRecordDatabase.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: load embedded genotype reference metadata"
```

### Task 2: Shared Record-Store Snapshot Publisher

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeReferenceRecordStoreSnapshot.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeReferenceRecordStoreSnapshotTests.swift`

**Interfaces:**
- Consumes: `ReferenceBundle.recordStoreDatabase()` and `ONTGenotypeReferenceRecordStoreInfo`.
- Produces: `GenotypeReferenceRecordStoreSnapshot.publish(fromReferenceBundle:toResultBundle:) throws -> PublishedSnapshot?`.
- Produces: `PublishedSnapshot.info`, `sourceURL`, `destinationURL`, `startedAt`, `completedAt`, and provenance file descriptors.

- [ ] **Step 1: Add failing publisher tests**

Cover no record store returning `nil`, a successful atomic copy under `metadata/genbank_records.sqlite`, matching source/destination checksum and size, declared counts, replacement of stale staging data, and failure for an invalid declared source store.

```swift
let snapshot = try XCTUnwrap(
    GenotypeReferenceRecordStoreSnapshot.publish(
        fromReferenceBundle: referenceBundleURL,
        toResultBundle: resultURL
    )
)
XCTAssertEqual(snapshot.info.databasePath, "metadata/genbank_records.sqlite")
XCTAssertEqual(snapshot.info.sha256, try ProvenanceFileHasher.sha256(of: snapshot.destinationURL))
```

- [ ] **Step 2: Run the publisher tests and confirm failure**

Run: `swift test --filter GenotypeReferenceRecordStoreSnapshotTests`

Expected: compilation fails because the publisher does not exist.

- [ ] **Step 3: Implement atomic validated snapshot publication**

Open the source through `ReferenceBundle`, copy to a sibling staging file, validate it with `GenBankRecordDatabase`, calculate final checksum/size/counts, atomically replace the destination, reopen the final file, and return final-path provenance descriptors. Clean staging files on every error path.

- [ ] **Step 4: Run the publisher tests**

Run: `swift test --filter GenotypeReferenceRecordStoreSnapshotTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit the publisher**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeReferenceRecordStoreSnapshot.swift Tests/LungfishWorkflowTests/GenotypeReferenceRecordStoreSnapshotTests.swift
git commit -m "feat: snapshot genotype reference record stores"
```

### Task 3: Publish Snapshots and Provenance from Both Genotyping Workflows

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`

**Interfaces:**
- Consumes: `GenotypeReferenceRecordStoreSnapshot.publish(...)`.
- Produces: manifests containing `referenceRecordStore` for GenBank references.
- Produces: workflow provenance containing source/final store paths, hashes, sizes, step status, runtime identity, argv/defaults, and wall time.

- [ ] **Step 1: Add failing workflow publication tests**

Build small annotated reference fixtures for each workflow path and assert the final manifest descriptor and provenance refer to the final embedded payload. Add FASTA-only assertions that the descriptor is absent. Add a forced publisher failure assertion that no final manifest is published.

- [ ] **Step 2: Run focused workflow tests and confirm failure**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests && swift test --filter ONTBarcodeDemuxGenotypingPipelineTests`

Expected: new assertions fail because neither workflow publishes the snapshot.

- [ ] **Step 3: Integrate the snapshot before provenance and manifest publication**

Resolve the enclosing reference bundle, publish the snapshot after scientific outputs exist but before final provenance/manifest publication, pass `snapshot.info` into manifest construction, and append a provenance step whose inputs and outputs describe the source and final SQLite files. Any snapshot/provenance error must prevent the manifest write.

- [ ] **Step 4: Run focused workflow tests**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests && swift test --filter ONTBarcodeDemuxGenotypingPipelineTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit workflow integration**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift
git commit -m "feat: preserve GenBank metadata in genotype results"
```

### Task 4: Dynamic GenBank Columns in the Matrix

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeMatrixColumnController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces:**
- Consumes: `ONTGenotypeResultBundleData.referenceMetadata`.
- Produces: `GenotypeMatrixColumnController` managing stable fixed/dynamic identifiers, header menu, defaults, widths, and `UserDefaults` persistence.
- Produces: matrix row values and search/sort behavior for every GenBank field.

- [ ] **Step 1: Add failing dynamic-column tests**

Assert that every field definition appears in the pinned header menu; `feature.allele` is visible with its complete value; Genotype defaults hidden for GenBank and visible for FASTA; fixed/dynamic columns toggle and resize; missing row matches are blank; hidden GenBank values remain searchable; and sort order handles blank values deterministically.

```swift
XCTAssertEqual(matrix.testingVisiblePinnedTitles.first, "Allele")
XCTAssertEqual(matrix.testingPinnedValue(row: 0, title: "Allele"), "Mafa-A1*006:01:02")
XCTAssertFalse(matrix.testingVisiblePinnedTitles.contains("Genotype"))
XCTAssertTrue(matrix.testingAvailablePinnedTitles.contains("Definition"))
```

- [ ] **Step 2: Run focused UI tests and confirm failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: compilation or assertions fail because dynamic genotype metadata columns do not exist.

- [ ] **Step 3: Implement column identities, chooser, cells, search, and sort**

Reuse the classifier controller's menu/zero-width resize behavior while keeping genotype-specific per-row lookup separate. Use `genbank.<field-key>` identifiers, display record-store titles, always retain the selector, and persist visible columns and widths. Pass `referenceMetadata` from the result controller into matrix configuration.

- [ ] **Step 4: Run focused UI tests**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit dynamic columns**

```bash
git add Sources/LungfishGenotypeUI/GenotypeMatrixColumnController.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: expose GenBank fields in genotype matrix"
```

### Task 5: Resizable Persistent Matrix Split

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces:**
- Produces: draggable `NSSplitView` boundary between pinned metadata and samples.
- Produces: persisted `genotypeMatrixPinnedPaneWidth` preference with bounds clamping.

- [ ] **Step 1: Add failing split-layout tests**

Assert the divider moves, both panes respect minimum widths, the pinned pane has a horizontal scroller, vertical scrolling stays synchronized, a saved width restores in a new matrix, and an out-of-range saved width is clamped.

- [ ] **Step 2: Run focused UI tests and confirm failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: assertions fail because the pinned width is a computed fixed constraint.

- [ ] **Step 3: Replace the fixed constraint with a split view**

Host both scroll views in `NSSplitView`, implement minimum-coordinate delegate methods, enable the pinned horizontal scroller, save the divider position after user movement, restore it after layout, and retain the existing synchronized vertical clip handling.

- [ ] **Step 4: Run focused UI tests**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit the resizable layout**

```bash
git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: resize genotype matrix panes"
```

### Task 6: Remove Summary Strip and Sample Window

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces:**
- Removes: genotype viewport `summaryStrip` and matrix `SampleColumnWindowBanner` usage.
- Preserves: `SampleColumnWindow` for other consumers; only this matrix stops using it.

- [ ] **Step 1: Replace old cap tests with failing all-samples and no-strip tests**

Assert 150 input samples produce 150 instantiated sample columns immediately, no reveal banner exists, and summary text is absent in Summary, Review, and Audit while the lens control remains accessible.

- [ ] **Step 2: Run focused UI tests and confirm failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: old behavior still caps at 60 and exposes the summary values.

- [ ] **Step 3: Remove matrix windowing and compact the lens toolbar**

Build sample columns directly from `visibleSampleNames`, remove banner callbacks/state/test hooks, delete summary-pill creation and layout constraints, and anchor the content host below a compact lens-control toolbar.

- [ ] **Step 4: Run focused UI tests**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit viewport simplification**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: simplify genotype review viewport"
```

### Task 7: Regression Verification and Debug Build

**Files:**
- Modify only files required by failures found during verification.

**Interfaces:**
- Verifies the complete design as one integrated result.

- [ ] **Step 1: Run all affected module tests**

Run: `swift test --filter LungfishIOTests && swift test --filter LungfishWorkflowTests && swift test --filter LungfishGenotypeUITests`

Expected: all selected test suites pass with zero failures.

- [ ] **Step 2: Run the full package test suite**

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 3: Inspect provenance and manifest fixtures**

Generate or load a small GenBank-backed genotype fixture and verify the embedded SQLite file, final checksum/size, full allele lookup, and provenance paths all refer to the published result bundle rather than staging files.

- [ ] **Step 4: Build the debug application**

Run the repository's established debug build command and verify `build/Debug/Lungfish.app` exists and launches to a stable idle state.

- [ ] **Step 5: Review the final diff and working tree**

Run: `git diff --check && git status --short`

Expected: no whitespace errors and only the commits/files described by this plan. If verification required a code fix, repeat that task's focused test cycle and include the fix in that task's commit rather than making an unreviewed catch-all commit.
