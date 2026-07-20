# Genotype-Only Selection Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict genotype-only results to a Summary matrix over a selection-driven detail pane that describes selected samples, alleles, and cells without showing the low-coverage cohort panel.

**Architecture:** Introduce one shared genotype-only display-state normalization rule, apply it in both the inspector view model and result controller, and conditionally hide unsupported controls without deleting the haplotyped-result cases. Keep matrix selection mechanics unchanged; interpret the existing `MatrixTarget` callbacks in `GenotypeResultViewController` and enrich allele details from the already-loaded `ONTGenotypeReferenceMetadata`.

**Tech Stack:** Swift 6, AppKit, SwiftUI Observation, Lungfish genotype bundle models, XCTest, Swift Package Manager, Xcode debug build.

---

## File Structure

- `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`: owns the pure normalization rule for genotype-only display state.
- `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`: stores the inspector capability and conditionally omits unsupported viewport/layout controls.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`: derives the genotype-only capability from the loaded result and passes it to the inspector.
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`: enforces the presentation, switches Summary from cohort to selection detail, and renders sample/allele/cell detail.
- `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`: verifies inspector normalization and conditional control visibility.
- `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`: verifies viewport enforcement, empty state, selection details, GenBank fields, and haplotyped regressions.

No bundle model, workflow, or provenance file changes are required because the feature only changes how already-loaded scientific data is displayed.

### Task 1: Normalize Genotype-Only State and Inspector Capabilities

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`

- [ ] **Step 1: Write failing display-state and inspector tests**

Add tests proving genotype-only state is normalized and that unsupported controls are omitted, while haplotyped results retain them:

```swift
func testGenotypeOnlyDisplayStateForcesSummaryMatrixOverDetail() {
    let input = GenotypeResultDisplayState(
        viewportLens: .audit,
        summaryViewMode: .outline,
        layout: .listTrailing
    )

    let normalized = input.normalized(forGenotypeOnlyResult: true)

    XCTAssertEqual(normalized.viewportLens, .summary)
    XCTAssertEqual(normalized.summaryViewMode, .matrix)
    XCTAssertEqual(normalized.layout, .listTop)
}

func testHaplotypedDisplayStateIsNotNormalized() {
    let input = GenotypeResultDisplayState(
        viewportLens: .review,
        summaryViewMode: .outline,
        layout: .listLeading
    )
    XCTAssertEqual(input.normalized(forGenotypeOnlyResult: false), input)
}

func testGenotypeOnlyInspectorHidesViewportAndLayoutControls() {
    let viewModel = GenotypeResultDisplaySectionViewModel()
    viewModel.update(
        isAvailable: true,
        state: GenotypeResultDisplayState(viewportLens: .audit, layout: .listTrailing),
        hasHaplotypingResult: false,
        isGenotypeOnlyResult: true
    )

    XCTAssertFalse(viewModel.showsViewportAndLayoutControls)
    XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
    XCTAssertEqual(viewModel.displayState.summaryViewMode, .matrix)
    XCTAssertEqual(viewModel.displayState.layout, .listTop)
}

func testHaplotypedInspectorKeepsViewportAndLayoutControls() {
    let viewModel = GenotypeResultDisplaySectionViewModel()
    viewModel.update(
        isAvailable: true,
        hasHaplotypingResult: true,
        isGenotypeOnlyResult: false
    )
    XCTAssertTrue(viewModel.showsViewportAndLayoutControls)
}
```

Also update the existing source-structure test to require `if viewModel.showsViewportAndLayoutControls` around `viewControls` and `layoutControls`.

- [ ] **Step 2: Run the focused inspector tests and verify failure**

Run: `swift test --filter GenotypeResultDisplaySectionTests`

Expected: compilation fails because `normalized(forGenotypeOnlyResult:)`, `isGenotypeOnlyResult`, and `showsViewportAndLayoutControls` do not exist.

- [ ] **Step 3: Implement the pure normalization rule**

Add this method to `GenotypeResultDisplayState`:

```swift
public func normalized(forGenotypeOnlyResult isGenotypeOnlyResult: Bool) -> Self {
    guard isGenotypeOnlyResult else { return self }
    var normalized = self
    normalized.viewportLens = .summary
    normalized.summaryViewMode = .matrix
    normalized.layout = .listTop
    return normalized
}
```

- [ ] **Step 4: Add the inspector capability and enforce it in mutations**

Extend the view model and its update path:

```swift
public var isGenotypeOnlyResult = false

public var showsViewportAndLayoutControls: Bool {
    !isGenotypeOnlyResult
}

public func update(
    isAvailable: Bool,
    state: GenotypeResultDisplayState = GenotypeResultDisplayState(),
    hasHaplotypingResult: Bool = false,
    isGenotypeOnlyResult: Bool = false
) {
    self.isAvailable = isAvailable
    self.hasHaplotypingResult = hasHaplotypingResult
    self.isGenotypeOnlyResult = isGenotypeOnlyResult
    displayState = state.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
    updateSelection(nil)
}

func setLayout(_ layout: GenotypeResultPanelLayout) {
    displayState.layout = layout
    displayState = displayState.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
    notifyStateChanged()
}

func setViewportLens(_ lens: GenotypeResultViewportLens) {
    displayState.viewportLens = lens
    displayState = displayState.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
    notifyStateChanged()
}
```

Reset `isGenotypeOnlyResult` in `clear()`. In the SwiftUI body, include the two control groups only when `showsViewportAndLayoutControls` is true:

```swift
if viewModel.showsViewportAndLayoutControls {
    viewControls
    layoutControls
}
```

At the app inspector boundary, derive the capability from actual content rather than from file type alone:

```swift
let isGenotypeOnlyResult = result.haplotypeAnalysis == nil && !result.calls.isEmpty
viewModel.genotypeResultDisplaySectionViewModel.update(
    isAvailable: true,
    state: currentDisplay,
    hasHaplotypingResult: result.haplotypeAnalysis != nil,
    isGenotypeOnlyResult: isGenotypeOnlyResult
)
```

- [ ] **Step 5: Run the focused inspector tests**

Run: `swift test --filter GenotypeResultDisplaySectionTests`

Expected: all selected tests pass.

- [ ] **Step 6: Commit state and inspector behavior**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift
git commit -m "feat: constrain genotype-only display controls"
```

### Task 2: Enforce the Single Viewport and Show Selection Detail

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing viewport presentation tests**

Add tests that use a result with at least one call so it qualifies as genotype-only:

```swift
func testGenotypeOnlyViewportRejectsReviewAndSideBySideState() {
    let controller = GenotypeResultViewController()
    _ = controller.view
    let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 42)
    controller.configure(result: makeResult(samples: [], calls: [call]))

    controller.testingApplyDisplayState(GenotypeResultDisplayState(
        viewportLens: .review,
        summaryViewMode: .outline,
        layout: .listTrailing
    ))

    XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
    XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
    XCTAssertFalse(controller.testingSplitIsVertical)
    XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    XCTAssertTrue(controller.testingLensControlIsHidden)
    XCTAssertEqual(controller.testingContentHostTopInset, 0, accuracy: 0.5)
}

func testGenotypeOnlySummaryUsesDetailPaneInsteadOfCohortPanel() {
    let controller = GenotypeResultViewController()
    _ = controller.view
    let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 42)
    controller.configure(result: makeResult(samples: [], calls: [call]))

    XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
    XCTAssertTrue(controller.testingCohortSummaryIsHidden)
    XCTAssertTrue(controller.testingDetailText.contains("Select a sample column or allele row to view details."))
    XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
}
```

Add a regression test with a non-`nil` haplotype analysis asserting the lens control is visible, Review can be selected, and a side-by-side layout remains vertical. Preserve the existing empty-result lens tests: a bundle with no calls is not classified as a populated genotype-only result.

- [ ] **Step 2: Run focused viewport tests and verify failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: compilation fails for the new testing accessors and the existing viewport accepts Review/layout changes.

- [ ] **Step 3: Normalize controller state and collapse the lens header**

Add a content constraint property and the content predicate:

```swift
private var contentHostTopConstraint: NSLayoutConstraint?

private var isGenotypeOnlyResult: Bool {
    guard let result else { return false }
    return result.haplotypeAnalysis == nil && !result.calls.isEmpty
}

private func normalizedDisplayState(_ state: GenotypeResultDisplayState) -> GenotypeResultDisplayState {
    state.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
}

private func applyViewportCapabilityVisibility() {
    lensControl.isHidden = isGenotypeOnlyResult
    contentHostTopConstraint?.constant = isGenotypeOnlyResult ? 0 : 48
}
```

In `layout()`, retain the top constraint instead of creating it anonymously. In `configure(result:)`, normalize `displayState`, apply capability visibility, call `showEmptySelection()`, and then show Summary. In `applyDisplayState(_:)`, normalize before comparing or applying state. In `showLens`, replace an unsupported requested lens with Summary:

```swift
private func showLens(_ requestedLens: Lens, autoActivateReviewCohort: Bool = true) {
    let lens: Lens = isGenotypeOnlyResult ? .summary : requestedLens
    selectedLens = lens
    displayState = normalizedDisplayState(displayState)
    displayState.viewportLens = lens
    // existing switch remains unchanged
}
```

- [ ] **Step 4: Route genotype-only Summary to the detail scroll view**

Change `applySummaryViewModeVisibility()` after it computes `showsRawMatrix`:

```swift
if isGenotypeOnlyResult && showsRawMatrix {
    cohortSummaryPanel.isHidden = true
    detailScrollView.isHidden = false
    detailContainer.isHidden = false
    callEvidenceHost?.isHidden = true
} else {
    cohortSummaryPanel.isHidden = false
    detailScrollView.isHidden = true
    detailContainer.isHidden = false
}
```

Update the empty state text exactly:

```swift
detailStack.addArrangedSubview(
    caption("Select a sample column or allele row to view details.")
)
```

Add DEBUG accessors for the new assertions:

```swift
var testingLensControlIsHidden: Bool { lensControl.isHidden }
var testingContentHostTopInset: CGFloat { contentHost.frame.minY }
var testingDetailScrollViewIsHidden: Bool { detailScrollView.isHidden }
var testingCohortSummaryIsHidden: Bool { cohortSummaryPanel.isHidden }
var testingDetailText: String { textContent(in: detailStack).joined(separator: "\n") }
```

- [ ] **Step 5: Run focused viewport tests**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: all selected tests pass, including the new genotype-only and existing haplotyped/empty-result lens tests.

- [ ] **Step 6: Commit viewport enforcement**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: focus genotype-only results on summary matrix"
```

### Task 3: Render Sample, Allele, and Cell Selection Details

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing selection-detail tests**

Add one fixture with two samples, two alleles, and `makeGenBankReferenceMetadata()`. Verify the following exact behaviors:

```swift
func testGenotypeOnlyColumnSelectionShowsSampleAndSupportedAlleles() {
    let controller = configuredGenBankGenotypeOnlyController()

    controller.testingSelectMatrixColumn(sample: "AnimalA")

    XCTAssertTrue(controller.testingDetailText.contains("Selected Sample"))
    XCTAssertTrue(controller.testingDetailText.contains("AnimalA"))
    XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
    XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
        $0.0 == "Retained Unique Reads" && $0.1 == "50"
    })
}

func testGenotypeOnlyRowSelectionShowsFullAlleleAndEveryNonEmptyGenBankField() {
    let controller = configuredGenBankGenotypeOnlyController()

    controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

    XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
    XCTAssertTrue(controller.testingDetailText.contains("NHP01222"))
    XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
        $0.0 == "Product" && $0.1 == "MHC class I A1 antigen"
    })
    XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
        $0.0 == "Definition" && $0.1 == "Mafa-A1 complete coding sequence"
    })
}

func testGenotypeOnlyMultiRowSelectionKeepsEveryFullAllele() {
    let controller = configuredGenBankGenotypeOnlyController()

    controller.testingSelectMatrixRows(genotypes: ["NHP01222", "NHP99999"], sample: nil)

    XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
    XCTAssertTrue(controller.testingDetailText.contains("Mafa-B*002:01"))
    XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
        $0.0 == "Selected Alleles" && $0.1 == "2"
    })
}

func testGenotypeOnlyCellSelectionShowsCombinedEvidence() {
    let controller = configuredGenBankGenotypeOnlyController()

    controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")

    XCTAssertTrue(controller.testingDetailText.contains("AnimalA"))
    XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
    XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
        $0.0 == "Unique Reads" && $0.1 == "42"
    })
}
```

Define the fixture helper in the same test class so every selection test uses identical source data:

```swift
private func configuredGenBankGenotypeOnlyController() -> GenotypeResultViewController {
    let a1 = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 42)
    let b1 = makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 8)
    let b2 = makeCall(sample: "AnimalB", genotype: "NHP99999", reads: 24)
    let controller = GenotypeResultViewController()
    _ = controller.view
    controller.configure(result: makeResult(
        samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 50,
                passedUniqueReads: 50,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [a1, b1]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 24,
                passedUniqueReads: 24,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [b2]
            ),
        ],
        calls: [a1, b1, b2],
        referenceMetadata: makeGenBankReferenceMetadata()
    ))
    return controller
}
```

Add these assertions for multi-cell, mixed, comment, and filtered-selection behavior:

```swift
func testGenotypeOnlyMultiCellSelectionShowsEachEvidencePair() {
    let controller = configuredGenBankGenotypeOnlyController()
    controller.testingSelectMatrixRows(
        genotypes: ["NHP01222", "NHP99999"],
        sample: "AnimalA"
    )

    XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
    XCTAssertTrue(controller.testingDetailText.contains("Mafa-B*002:01"))
    XCTAssertTrue(controller.testingDetailText.contains("42"))
    XCTAssertTrue(controller.testingDetailText.contains("8"))
}

func testGenotypeOnlyMixedTargetsUseGenericAnnotationSummary() {
    let controller = configuredGenBankGenotypeOnlyController()
    controller.testingShowMatrixTargetSelection([
        .row(locus: "MHC-A", genotype: "NHP01222"),
        .column(sample: "AnimalA"),
    ])

    XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
        $0.0 == "Selection Type" && $0.1 == "Mixed"
    })
}
```

Extend `testMatrixCommentsPersistAndAppearInSelectionDetails` to keep its existing `Cell Comment` assertion after the new builder is installed. Extend `testMatrixColumnSelectionClearsWhenSampleFilterHidesSelectedColumn` with:

```swift
XCTAssertTrue(controller.testingDetailText.contains(
    "Select a sample column or allele row to view details."
))
```

Add this DEBUG helper solely to exercise the mixed-target fallback without changing production selection mechanics:

```swift
func testingShowMatrixTargetSelection(
    _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
) {
    showMatrixTargetSelection(targets)
}
```

- [ ] **Step 2: Run focused viewport tests and verify failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: the sample and GenBank assertions fail because `showMatrixTargetSelection` only reports target identities, and the detail pane lacks reference fields.

- [ ] **Step 3: Add reference label and field lookup helpers**

Use the result's already-validated in-memory metadata:

```swift
private func referenceRecord(for genotype: String) -> [String: String]? {
    result?.referenceMetadata?.recordsBySequenceName[genotype]
}

private func alleleDisplayLabel(for genotype: String) -> String {
    guard let metadata = result?.referenceMetadata,
          let key = metadata.alleleFieldKey,
          let value = metadata.recordsBySequenceName[genotype]?[key],
          !value.isEmpty else {
        return genotype
    }
    return value
}

private func referenceDetailRows(for genotype: String) -> [(String, String)] {
    guard let metadata = result?.referenceMetadata,
          let record = metadata.recordsBySequenceName[genotype] else { return [] }
    return metadata.fields.compactMap { field in
        guard let value = record[field.key], !value.isEmpty else { return nil }
        return (field.displayTitle, value)
    }
}
```

- [ ] **Step 4: Enrich the single-row shared-call detail**

At the start of `showSharedCall`, show the full allele label and preserve the source sequence name when it differs:

```swift
let alleleLabel = alleleDisplayLabel(for: sharedCall.genotype)
detailStack.addArrangedSubview(sectionTitle("Selected Allele"))
detailStack.addArrangedSubview(wrappingText(alleleLabel, weight: .medium))
if alleleLabel != sharedCall.genotype {
    detailStack.addArrangedSubview(detailRows([("Reference Sequence", sharedCall.genotype)]))
}
let genBankRows = referenceDetailRows(for: sharedCall.genotype)
if !genBankRows.isEmpty {
    detailStack.addArrangedSubview(sectionTitle("GenBank Fields"))
    detailStack.addArrangedSubview(detailRows(genBankRows))
}
```

Keep the existing support summary, selected-cell evidence, co-occurrence caveat, supporting-sample table, comments, and `publishSelectionState` behavior. Append the GenBank rows to the published `GenotypeResultSelectionState.detailRows` so the inspector and lower detail agree.

- [ ] **Step 5: Dispatch matrix targets to focused detail builders**

First route multi-target row/cell callbacks to the target builder; retain `showSharedCall` for one row or one cell so its existing rich support content remains available:

```swift
comparisonMatrix.onSharedCallSelected = { [weak self] sharedCall, sample, matrixTargets in
    guard let self else { return }
    if matrixTargets.count > 1 {
        showMatrixTargetSelection(matrixTargets)
    } else {
        showSharedCall(sharedCall, sample: sample, matrixTargets: matrixTargets)
    }
}
```

Then replace the generic-only target path with homogeneous selection handling:

```swift
private enum MatrixSelectionKind {
    case rows
    case columns
    case cells
    case mixed
    case empty
}

private func matrixSelectionKind(
    for targets: [GenotypeAnnotationSidecar.MatrixTarget]
) -> MatrixSelectionKind {
    guard let first = targets.first else { return .empty }
    let firstKind: MatrixSelectionKind
    switch first {
    case .row: firstKind = .rows
    case .column: firstKind = .columns
    case .cell: firstKind = .cells
    }
    return targets.dropFirst().allSatisfy { target in
        switch (firstKind, target) {
        case (.rows, .row), (.columns, .column), (.cells, .cell): return true
        default: return false
        }
    } ? firstKind : .mixed
}

private func showMatrixTargetSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
    let targets = uniqueMatrixTargets(targets)
    switch matrixSelectionKind(for: targets) {
    case .columns:
        showSelectedSamples(targets)
    case .rows:
        showSelectedAlleles(targets)
    case .cells:
        showSelectedCells(targets)
    case .mixed, .empty:
        showGenericMatrixTargets(targets)
    }
}
```

Implement the builders using `sampleResultsByName`, `callsBySample`, `result.locusSummaries.flatMap(\.sharedCalls)`, `alleleDisplayLabel(for:)`, `referenceDetailRows(for:)`, and `supportFractionLabel(genotype:sample:)`. The sample detail rows begin with:

```swift
var rows: [(String, String)] = [
    ("Sample", sample),
    ("Retained Unique Reads", integer(sampleResult.passedUniqueReads)),
    ("Alignments", integer(sampleResult.passedAlignments)),
    ("QC", sampleResult.qcStatus.displayName),
]
```

Resolve aggregate allele rows from the existing bundle projection, without introducing a second aggregation algorithm:

```swift
private func sharedCall(locus: String, genotype: String) -> ONTGenotypeSharedCall? {
    result?.locusSummaries
        .flatMap(\.sharedCalls)
        .first { $0.locus == locus && $0.genotype == genotype }
}
```

Sort sample calls by locus, then descending `passedUniqueReads`, then allele label. For multi-row selections publish `("Selected Alleles", "\(rows.count)")` and one full allele summary per target. For cells, include only evidence for the specified sample/allele pair; an empty cell reports Sample, Allele, and “No supporting reads” without inventing counts. Preserve `matrixCommentDetailRows(for:)` in every published selection state.

- [ ] **Step 6: Restore the empty state when filters prune selection**

Ensure the matrix selection-cleared callback calls `showEmptySelection()` and retain the matrix view's existing pruning callbacks:

```swift
comparisonMatrix.onSelectionCleared = { [weak self] in
    self?.showEmptySelection()
}
```

- [ ] **Step 7: Run focused viewport tests**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: all selected tests pass, including existing matrix annotation, style, range-selection, filtering, and full-label tests.

- [ ] **Step 8: Commit selection-driven detail**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: show genotype matrix selection details"
```

### Task 4: Regression Verification and Debug Build

**Files:**
- Verify only; modify production files only if a failing regression is directly caused by Tasks 1–3.

- [ ] **Step 1: Run the complete focused module suites**

Run:

```bash
swift test --filter LungfishGenotypeUITests
swift test --filter GenotypeResultDisplaySectionTests
```

Expected: both commands exit 0 with no failures.

- [ ] **Step 2: Verify provenance-sensitive workflow behavior remains unchanged**

Run:

```bash
swift test --filter GenotypeReferenceRecordStoreSnapshotTests
swift test --filter FullLengthONTMHCGenotypingPipelineTests
```

Expected: both commands exit 0. This confirms the display-only work did not regress the embedded GenBank store or final-payload provenance checks required by `AGENTS.md`.

- [ ] **Step 3: Build a testable Debug application**

Run:

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS' CONFIGURATION_BUILD_DIR="$PWD/build/Debug" build
```

Expected: `** BUILD SUCCEEDED **` and `build/Debug/Lungfish.app` exists.

- [ ] **Step 4: Perform a clean working-tree and artifact check**

Run:

```bash
git status --short
test -d build/Debug/Lungfish.app
```

Expected: no uncommitted source/test changes and the app check exits 0. The ignored debug build may remain on disk for user testing.
