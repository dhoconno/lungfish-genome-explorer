# Genotype Matrix Native Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native genotype-only matrix annotation workflow with persistent Lungfish annotations, display filters, and debounced Excel sync.

**Architecture:** Genotype-only bundles open a raw native matrix. Persistent comments/styles live in `annotations.json` as matrix-aware targets and are rendered by `GenotypeComparisonMatrixView`. The inspector gets a dedicated `Annotations` tab; workbook sync writes saved annotations into `current.xlsx` with provenance.

**Tech Stack:** Swift/AppKit/SwiftUI, XCTest, existing Lungfish genotype sidecar/provenance/workbook services, `xcodebuild` debug builds.

---

## File Structure

- `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
  - Add matrix annotation records, style value, target identity, decode defaults.
- `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift`
  - Persist matrix comments/styles and append audit/provenance entries.
- `Sources/LungfishGenotypeUI/GenotypeResultSelectionState.swift`
  - Add raw matrix target and multi-selection identity.
- `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
  - Render genotype-only matrix annotations, empty-cell targets, column selection, display filters, and helper selection.
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  - Default genotype-only bundles to raw matrix, bridge selection/annotations/sync status to the app inspector.
- `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
  - Add display-only raw matrix filter state.
- `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
  - Surface reversible matrix display controls in `View`.
- `Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift`
  - New SwiftUI editor for persistent matrix annotation comments/styles.
- `Sources/LungfishApp/Views/Inspector/*`
  - Add a dedicated `Annotations` tab and view model state.
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
  - Route genotype-only result bundles to native matrix.
- `Sources/LungfishApp/Services/GenotypeMatrixWorkbookSyncService.swift`
  - Debounced `current.xlsx` sync orchestration.
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
  - Apply matrix annotations to current workbook.
- `Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift`
  - Export matrix styles/comments when producing annotation-bearing workbooks.

## Task 1: Genotype-Only Native Matrix Routing

**Files:**
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`

- [ ] **Step 1: Write failing routing test**

Add or update a test named:

```swift
func testGenotypeResultWithoutHaplotypeAnalysisDisplaysNativeRawMatrix() throws
```

Expected assertions:

```swift
XCTAssertNil(viewerController.testQuickLookURL)
XCTAssertNotNil(viewerController.genotypeResultViewController)
XCTAssertEqual(viewerController.genotypeResultViewController?.testingSummaryViewMode, .matrix)
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter MappingViewportRoutingTests/testGenotypeResultWithoutHaplotypeAnalysisDisplaysNativeRawMatrix
```

Expected: fail because genotype-only bundles still Quick Look preview `current.xlsx` or because default mode is not matrix.

- [ ] **Step 3: Implement minimal routing change**

Change `shouldPreviewPrimaryWorkbook(for:)` so a loadable genotype result uses native display even without haplotype analysis. Keep workbook Quick Look only for native-load fallback.

In `GenotypeResultViewController.configure(result:)`, when `result.haplotypeAnalysis == nil`, set summary mode to `.matrix` and configure the raw comparison matrix.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter MappingViewportRoutingTests/testGenotypeResultWithoutHaplotypeAnalysisDisplaysNativeRawMatrix
swift test --filter MappingViewportRoutingTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishAppTests/MappingViewportRoutingTests.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift
git commit -m "feat: open genotype-only bundles in native matrix"
```

## Task 2: Matrix Annotation Schema And Store

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift`
- Modify: `Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift`

- [ ] **Step 1: Write failing sidecar/store tests**

Add tests for:

```swift
func testMatrixStyleRoundTripsForRowColumnAndCellTargets() throws
func testMatrixCommentPersistsForEmptyCellTarget() throws
func testMatrixAnnotationWritesAuditEntryAndProvenance() throws
```

Expected model shape:

```swift
GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-B", genotype: "Mamu-I*01")
GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AR3628")
GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-B", genotype: "Mamu-I*01", sample: "AR3628")
GenotypeAnnotationSidecar.MatrixStyle(fillColor: "#FFF2CC", textColor: "#C00000", isBold: true, isItalic: false)
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter GenotypeAnnotationStoreTests/testMatrix
swift test --filter GenotypeAnnotationSidecarTests/testMatrix
```

Expected: fail because matrix model/store APIs do not exist.

- [ ] **Step 3: Implement schema/store**

Add sidecar arrays:

```swift
public var matrixStyles: [MatrixStyleAnnotation]
public var matrixComments: [MatrixComment]
```

Add store methods:

```swift
func setMatrixStyle(target: GenotypeAnnotationSidecar.MatrixTarget, style: GenotypeAnnotationSidecar.MatrixStyle?) throws
func addMatrixComment(target: GenotypeAnnotationSidecar.MatrixTarget, body: String) throws
```

Append audit entries with actions `setMatrixStyle` and `addMatrixComment`.

- [ ] **Step 4: Verify GREEN**

Run the same tests plus:

```bash
swift test --filter GenotypeAnnotationStoreTests
swift test --filter GenotypeAnnotationSidecarTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift
git commit -m "feat: persist genotype matrix annotations"
```

## Task 3: Matrix Selection, Rendering, And Display Filters

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultSelectionState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests for:

```swift
func testRawMatrixCanSelectEmptyCellTarget() throws
func testMatrixStylePrecedenceCombinesRowAndColumnAndLetsCellOverride() throws
func testPerCellReadThresholdHidesCellsAndKeepsRowsWithVisibleCells() throws
func testPercentThresholdCanUseSampleOrLocusDenominator() throws
func testSupportedCellSelectionHelperSkipsEmptyCells() throws
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testRawMatrix
swift test --filter GenotypeResultViewportTests/testMatrixStyle
swift test --filter GenotypeResultViewportTests/testPerCell
swift test --filter GenotypeResultViewportTests/testSupportedCellSelectionHelper
```

Expected: fail because selection/filter/style APIs are missing.

- [ ] **Step 3: Implement selection/filter/rendering**

Add a matrix selection identity with row, column, cell, and multi-target support. Render styles from sidecar matrix annotations. Support empty cells as selectable coordinates. Add display-only filters:

```swift
public var matrixMinimumReads: Int
public var matrixMinimumPercent: Double
public var matrixPercentDenominator: GenotypeMatrixPercentDenominator
public var matrixRowFilterText: String
public var matrixSampleFilterText: String
```

Rows remain visible when at least one visible cell remains after thresholds and sample filters.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter GenotypeResultViewportTests
swift test --filter GenotypeResultDisplaySectionTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultSelectionState.swift Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: annotate and filter genotype matrix cells"
```

## Task 4: Annotations Inspector Tab

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorSupportingTypes.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewModel.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorView.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
- Test: `Tests/LungfishAppTests/GenotypeMatrixAnnotationInspectorTests.swift`

- [ ] **Step 1: Write failing inspector tests**

Add tests for:

```swift
func testInspectorExposesAnnotationsTabForGenotypeMatrixSelection() throws
func testCellSelectionShowsRowColumnAndCellComments() throws
func testMultiSelectionAppliesStyleToAllTargets() throws
func testReadOnlyBundleDisablesAnnotationEditing() throws
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter GenotypeMatrixAnnotationInspectorTests
```

Expected: fail because the tab and view model do not exist.

- [ ] **Step 3: Implement inspector tab**

Add a dedicated `Annotations` tab. Use `NSColorWell` for fill/text color. Add bold and italic segmented controls. Comments are plain text. Show sync state: `saved`, `pending`, `syncing`, `failed`, `readOnly`.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter GenotypeMatrixAnnotationInspectorTests
swift test --filter GenotypeResultDisplaySectionTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift Sources/LungfishApp/Views/Inspector Tests/LungfishAppTests/GenotypeMatrixAnnotationInspectorTests.swift
git commit -m "feat: add genotype matrix annotations inspector"
```

## Task 5: Debounced Workbook Sync And Export Provenance

**Files:**
- Create: `Sources/LungfishApp/Services/GenotypeMatrixWorkbookSyncService.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeViewportExportService.swift`
- Test: `Tests/LungfishAppTests/GenotypeMatrixWorkbookSyncTests.swift`
- Test: `Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift`

- [ ] **Step 1: Write failing sync/export tests**

Add tests for:

```swift
func testWorkbookSyncWritesMatrixStylesAndCommentsToCurrentXlsx() throws
func testWorkbookSyncWritesAnnotationsForHiddenTargets() throws
func testWorkbookSyncFailureKeepsSidecarSavedAndReportsFailedState() throws
func testAnnotationBearingExportProvenanceReferencesAnnotationSidecar() throws
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter GenotypeMatrixWorkbookSyncTests
swift test --filter GenotypeExportSubcommandTests/testAnnotationBearingExportProvenanceReferencesAnnotationSidecar
```

Expected: fail because workbook sync/export annotation propagation is missing.

- [ ] **Step 3: Implement workbook sync**

After sidecar save, schedule debounced sync. Write styles/comments into `current.xlsx`. Include every saved annotation regardless of active filters. Record provenance with stable `annotations.json` input.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter GenotypeMatrixWorkbookSyncTests
swift test --filter GenotypeExportSubcommandTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/GenotypeMatrixWorkbookSyncService.swift Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift Sources/LungfishGenotypeUI/GenotypeViewportExportService.swift Tests/LungfishAppTests/GenotypeMatrixWorkbookSyncTests.swift Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift
git commit -m "feat: sync genotype matrix annotations to workbooks"
```

## Task 6: Debug Build And Release Candidate Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Run focused verification**

Run:

```bash
swift test --filter MappingViewportRoutingTests
swift test --filter GenotypeAnnotationStoreTests
swift test --filter GenotypeAnnotationSidecarTests
swift test --filter GenotypeResultViewportTests
swift test --filter GenotypeMatrixAnnotationInspectorTests
swift test --filter GenotypeMatrixWorkbookSyncTests
swift test --filter GenotypeExportSubcommandTests
```

Expected: pass.

- [ ] **Step 2: Build debug app**

Run:

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/debug-derived-data build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Record build path**

Debug app path:

```text
.build/debug-derived-data/Build/Products/Debug/Lungfish.app
```

- [ ] **Step 4: Commit any final test/build metadata only if source changed**

Do not commit build products.
