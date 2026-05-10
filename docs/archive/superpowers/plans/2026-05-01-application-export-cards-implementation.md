# Application Export Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `Application Exports` Import Center operation family with documented migration cards and a preservation-first generic import workflow for non-Geneious application exports.

**Architecture:** Keep the existing Geneious importer as the specialized first card. Add a generic Application Export importer for other cards that scans folders/ZIP-like exports, imports standalone reference files through the existing reference importer, preserves all unsupported or deferred files, and writes inventory, report, and provenance. Track these workflows under a new `OperationType.applicationExportImport`.

**Tech Stack:** Swift, SwiftUI/AppKit Import Center, XCTest, existing `OperationCenter`, `ReferenceBundleImportService`, `FASTQBundle`, `ProvenanceRecorder`, and `/usr/bin/unzip` through the existing safe archive helper.

---

## File Structure

- Create `Sources/LungfishApp/Services/ApplicationExports/ApplicationExportImportModels.swift`
  - Owns `ApplicationExportKind`, inventory item models, options, and result types for the generic importer.
- Create `Sources/LungfishApp/Services/ApplicationExports/ApplicationExportScanner.swift`
  - Safely inventories selected application export files, folders, and ZIP-like archives.
- Create `Sources/LungfishApp/Services/ApplicationExports/ApplicationExportImportCollectionService.swift`
  - Creates the project collection, routes standalone reference files through the existing reference importer, preserves unsupported artifacts, and writes provenance.
- Modify `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
  - Adds the `Application Exports` tab, application export cards, dispatch cases, panel messages, and history labels.
- Modify `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`
  - Adds the section subtitle for `Application Exports`.
- Modify `Sources/LungfishApp/App/AppDelegate.swift`
  - Adds `importApplicationExportFromURL(_:kind:)` and moves Geneious to `OperationType.applicationExportImport`.
- Modify `Sources/LungfishApp/Services/DownloadCenter.swift`
  - Adds `OperationType.applicationExportImport`.
- Modify `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
  - Verifies the new tab/card catalog and absence of Sanger trace cards.
- Modify `Tests/LungfishAppTests/DownloadCenterTests.swift`
  - Verifies the new operation type.
- Create `Tests/LungfishAppTests/ApplicationExportImportCollectionServiceTests.swift`
  - Verifies collection creation, reference routing, artifact preservation, ZIP inventory, and provenance.

## Task 1: Plan Commit

**Files:**
- Create: `docs/superpowers/plans/2026-05-01-application-export-cards-implementation.md`

- [ ] **Step 1: Add this plan file**

Use `apply_patch` to add the complete plan.

- [ ] **Step 2: Verify the plan has no incomplete markers**

Run:

```bash
rg -n "TB[D]|TO[DO]|FIX[ME]" docs/superpowers/plans/2026-05-01-application-export-cards-implementation.md
```

Expected: exit 1 with no matches.

- [ ] **Step 3: Commit the plan**

Run:

```bash
git add docs/superpowers/plans/2026-05-01-application-export-cards-implementation.md
git commit -m "Plan application export import cards"
```

Expected: commit succeeds.

## Task 2: Import Center Card Tests

**Files:**
- Modify: `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
- Modify: `Tests/LungfishAppTests/DownloadCenterTests.swift`

- [ ] **Step 1: Write failing Import Center tests**

Add tests that assert:

```swift
func testImportCenterHasApplicationExportsTab() {
    XCTAssertTrue(ImportCenterViewModel.Tab.allCases.contains(.applicationExports))
    XCTAssertEqual(ImportCenterViewModel.Tab.applicationExports.title, "Application Exports")
}

func testApplicationExportsTabContainsDocumentedCardsAndNoSangerCard() throws {
    let viewModel = ImportCenterViewModel()
    viewModel.selectedTab = .applicationExports
    let ids = viewModel.visibleCards.map(\.id)

    XCTAssertEqual(ids, [
        "geneious-export",
        "clc-workbench-export",
        "dnastar-lasergene-export",
        "benchling-bulk-export",
        "sequence-design-library-export",
        "alignment-tree-export",
        "sequencing-platform-run-folder",
        "phylogenetics-result-set",
        "qiime2-archive",
        "igv-session-track-set",
    ])
    XCTAssertFalse(viewModel.allCards.contains { $0.id.localizedCaseInsensitiveContains("sanger") })
}

func testApplicationExportCardsUseSingleSourceFileOrFolderPanels() throws {
    let viewModel = ImportCenterViewModel()
    let cards = viewModel.allCards.filter { $0.tab == .applicationExports }
    XCTAssertEqual(cards.count, 10)

    for card in cards {
        guard case .openPanel(let config, _) = card.importKind else {
            return XCTFail("\(card.id) must use an open panel")
        }
        XCTAssertTrue(config.canChooseFiles, card.id)
        XCTAssertTrue(config.canChooseDirectories, card.id)
        XCTAssertFalse(config.allowsMultipleSelection, card.id)
        XCTAssertTrue(config.allowsOtherFileTypes, card.id)
    }
}
```

Update the existing catalog test so `geneious-export` is expected under `.applicationExports`, not `.references`.

- [ ] **Step 2: Write failing operation type test**

In `DownloadCenterTests`, assert:

```swift
XCTAssertEqual(OperationType.applicationExportImport.rawValue, "Application Export")
```

and add `.applicationExportImport` to the all-types arrays and counts.

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
swift test --filter ImportCenterMenuTests
swift test --filter DownloadCenterTests/testOperationTypeRawValues
```

Expected: fail because `.applicationExports` and `.applicationExportImport` do not exist.

## Task 3: Application Export Importer Tests

**Files:**
- Create: `Tests/LungfishAppTests/ApplicationExportImportCollectionServiceTests.swift`

- [ ] **Step 1: Write failing service tests**

Create tests that:

```swift
func testImportCreatesApplicationExportCollectionWithInventoryReportAndProvenance() async throws
func testImportRoutesStandaloneReferencesAndPreservesOtherFiles() async throws
func testArchiveImportRejectsUnsafeMembers() async throws
```

The first test creates a temporary project, a ZIP export containing `refs/reference.fa` and `reports/summary.tsv`, imports it with kind `.clcWorkbench`, and asserts:

- collection last path component is `Example CLC Workbench Import`
- `LGE Bundles`, `Binary Artifacts`, and `Source` exist
- `inventory.json`, `import-report.md`, and `.lungfish-provenance.json` exist
- provenance name is `Application Export Import`
- provenance parameters include `applicationExportKind == "clc-workbench-export"`

The second test injects a reference importer, asserts one call for `reference.fa`, and asserts `summary.tsv` is preserved under `Binary Artifacts`.

The third test creates a ZIP with `../escape.fa` and asserts scanning/import throws a safe-member-path error.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter ApplicationExportImportCollectionServiceTests
```

Expected: fail because the service and models do not exist.

## Task 4: Implement Models, Scanner, And Collection Service

**Files:**
- Create: `Sources/LungfishApp/Services/ApplicationExports/ApplicationExportImportModels.swift`
- Create: `Sources/LungfishApp/Services/ApplicationExports/ApplicationExportScanner.swift`
- Create: `Sources/LungfishApp/Services/ApplicationExports/ApplicationExportImportCollectionService.swift`

- [ ] **Step 1: Add `ApplicationExportKind` and inventory models**

Implement the enum cases:

```swift
case clcWorkbench
case dnastarLasergene
case benchlingBulk
case sequenceDesignLibrary
case alignmentTree
case sequencingPlatformRunFolder
case phylogeneticsResultSet
case qiime2Archive
case igvSessionTrackSet
```

Each case exposes `cardID`, `displayName`, `collectionSuffix`, and `cliArgument`.

- [ ] **Step 2: Add scanner**

Implement safe folder, file, ZIP, `.qza`, and `.qzv` inventory. Use `GeneiousArchiveTool` for safe member validation and extraction. Classify files with existing `ReferenceBundleImportService.classify`, `FASTQBundle.isFASTQFileURL`, and extension sets for signal, report, platform metadata, native project files, MSA/tree, and phylogenetics artifacts.

- [ ] **Step 3: Add collection service**

Implement a service matching this public API:

```swift
public struct ApplicationExportImportCollectionService: Sendable {
    public static let `default`: ApplicationExportImportCollectionService

    public func importApplicationExport(
        sourceURL: URL,
        projectURL: URL,
        kind: ApplicationExportKind,
        options: ApplicationExportImportOptions = .default,
        progress: ApplicationExportImportProgress? = nil
    ) async throws -> ApplicationExportImportResult
}
```

The service creates `Application Exports/<source> <kind.collectionSuffix> Import/`, routes standalone references through the injected reference importer, preserves other items, writes `inventory.json`, `import-report.md`, and `.lungfish-provenance.json`, and includes final file checksums/sizes through `ProvenanceRecorder.fileRecord`.

- [ ] **Step 4: Run service tests and verify GREEN**

Run:

```bash
swift test --filter ApplicationExportImportCollectionServiceTests
```

Expected: pass.

- [ ] **Step 5: Commit importer**

Run:

```bash
git add Sources/LungfishApp/Services/ApplicationExports Tests/LungfishAppTests/ApplicationExportImportCollectionServiceTests.swift
git commit -m "Add application export import service"
```

Expected: commit succeeds.

## Task 5: Implement Import Center Cards And Operation Routing

**Files:**
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Services/DownloadCenter.swift`
- Modify: `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
- Modify: `Tests/LungfishAppTests/DownloadCenterTests.swift`

- [ ] **Step 1: Add `OperationType.applicationExportImport`**

Set raw value to `Application Export`.

- [ ] **Step 2: Add `Application Exports` tab**

Add `case applicationExports` after `.references`, with title `Application Exports` and symbol `shippingbox`.

- [ ] **Step 3: Add ImportAction cases and cards**

Add non-associated `ImportAction` cases for:

```swift
case clcWorkbenchExport
case dnastarLasergeneExport
case benchlingBulkExport
case sequenceDesignLibraryExport
case alignmentTreeExport
case sequencingPlatformRunFolder
case phylogeneticsResultSet
case qiime2Archive
case igvSessionTrackSet
```

Move `geneious-export` to `.applicationExports`. Add the nine new cards from the spec. Do not add a Sanger card.

- [ ] **Step 4: Route generic cards through AppDelegate**

Add `applicationExportKind` mapping in `ImportCenterViewModel` and dispatch each generic application export card to:

```swift
appDelegate.importApplicationExportFromURL(url, kind: kind)
```

Implement the AppDelegate method with `OperationType.applicationExportImport`, CLI command `lungfish import application-export <kind.cliArgument> <path> --project <project>`, progress updates, warnings on completion, and sidebar refresh/select.

- [ ] **Step 5: Run Import Center and operation tests**

Run:

```bash
swift test --filter ImportCenterMenuTests
swift test --filter DownloadCenterTests/testOperationTypeRawValues
swift test --filter DownloadCenterTests/testAllOperationTypesExist
swift test --filter DownloadCenterTests/testOperationTypesIncludeVariantCalling
```

Expected: pass.

- [ ] **Step 6: Commit UI/routing**

Run:

```bash
git add Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishApp/Services/DownloadCenter.swift Tests/LungfishAppTests/ImportCenterMenuTests.swift Tests/LungfishAppTests/DownloadCenterTests.swift
git commit -m "Add application export import cards"
```

Expected: commit succeeds.

## Task 6: Final Verification

**Files:**
- All touched files.

- [ ] **Step 1: Run focused suite**

Run:

```bash
swift test --filter ApplicationExportImportCollectionServiceTests
swift test --filter GeneiousImportCollectionServiceTests
swift test --filter GeneiousImportScannerTests
swift test --filter ImportCenterMenuTests
swift test --filter DownloadCenterTests
```

Expected: focused tests pass.

- [ ] **Step 2: Run diff check and full suite**

Run:

```bash
git diff --check
swift test --skip-build
```

Expected: `git diff --check` passes. If the broad suite exits nonzero for the known baseline issue, capture the log and report the observed failure state.

- [ ] **Step 3: Final status**

Run:

```bash
git status --short --untracked-files=all
git log --oneline -6
```

Expected: worktree clean and commits present.

## Self-Review

- Spec coverage: The plan implements the approved `Application Exports` card family, excludes Sanger traces, adds the generic preservation-first workflow, and keeps provenance mandatory.
- Type consistency: The plan consistently uses `ApplicationExportKind`, `ApplicationExportImportCollectionService`, `ApplicationExportImportResult`, and `OperationType.applicationExportImport`.
- Scope: Native CLC/SnapGene/DNASTAR/QIIME/phylogenetics decoders are not included. This implementation ships the card family and no-vendor-app baseline with standard reference routing and binary preservation.
