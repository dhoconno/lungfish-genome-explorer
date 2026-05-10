# Geneious Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the no-Geneious baseline Import Center workflow that turns a selected `.geneious` archive or Geneious-export folder into one project-visible import collection containing LGE-native outputs where supported, preserved binary artifacts for the rest, inventory/report files, and provenance.

**Architecture:** Add a focused Geneious import service slice under `Sources/LungfishApp/Services/Geneious/`. The scanner inventories folders and `.geneious` zip archives without Geneious installed, the collection importer creates a project-managed output folder and routes standalone reference sequence files through existing reference-bundle import code, and the Import Center/AppDelegate integration exposes the workflow. Native Geneious sidecar decoding remains behind a future decoder boundary; phase 1 preserves native members and reports that native decoding is unavailable.

**Tech Stack:** Swift 6.2, SwiftPM tests, AppKit/SwiftUI Import Center, Foundation file APIs, `/usr/bin/unzip` for safe archive listing/extraction, `ReferenceBundleImportService`, `ProvenanceRecorder`/`WorkflowRun` JSON provenance.

---

## Baseline

Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/geneious-import`

Branch: `codex/geneious-import`

Baseline command already run:

```bash
swift test
```

Observed baseline: the XCTest summary reported `Executed 7665 tests, with 32 tests skipped and 0 failures`. The mixed Swift Testing phase continued after the XCTest summary and the overall process exited nonzero; use targeted tests for each implementation task and repeat `swift test --skip-build` at the end to capture the final tail.

## File Structure

- Create `Sources/LungfishApp/Services/Geneious/GeneiousImportModels.swift`
  - Value types for inventory entries, classification, warnings, collection options, import results, and report/provenance payloads.
- Create `Sources/LungfishApp/Services/Geneious/GeneiousArchiveTool.swift`
  - Thin wrapper over `/usr/bin/unzip` for list/extract with safe path validation and structured diagnostics.
- Create `Sources/LungfishApp/Services/Geneious/GeneiousImportScanner.swift`
  - Scans `.geneious` archives and folders, classifies standard files, records XML/native sidecar metadata, computes sizes/checksums, and returns `GeneiousImportInventory`.
- Create `Sources/LungfishApp/Services/Geneious/GeneiousImportCollectionService.swift`
  - Creates one output collection folder, stages archive contents, imports standalone reference files into native `.lungfishref` bundles, preserves unsupported files as binary artifacts, writes `inventory.json`, `import-report.md`, and `.lungfish-provenance.json`.
- Modify `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
  - Add the Geneious import card/action, panel message, history label, and dispatch routing.
- Modify `Sources/LungfishApp/App/AppDelegate.swift`
  - Add `importGeneiousExportFromURL(_:)`, invoke `GeneiousImportCollectionService`, and show success/failure alerts.
- Create `Tests/LungfishAppTests/GeneiousImportScannerTests.swift`
  - Unit coverage for archive/folder scanning, standard classification, native metadata, and unsafe paths.
- Create `Tests/LungfishAppTests/GeneiousImportCollectionServiceTests.swift`
  - Unit/integration coverage for output collection creation, binary preservation, report/provenance writing, and injected native import routing.
- Modify `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
  - Verify the Geneious card is present and configured for files/folders.

## Task 1: Scanner Models And Archive Inventory

**Files:**
- Create: `Sources/LungfishApp/Services/Geneious/GeneiousImportModels.swift`
- Create: `Sources/LungfishApp/Services/Geneious/GeneiousArchiveTool.swift`
- Create: `Sources/LungfishApp/Services/Geneious/GeneiousImportScanner.swift`
- Create: `Tests/LungfishAppTests/GeneiousImportScannerTests.swift`

- [ ] **Step 1: Write failing scanner tests**

Add tests that create a synthetic Geneious-export folder and a synthetic `.geneious` zip archive. Use `/usr/bin/zip` in tests through a helper:

```swift
private func runZip(workingDirectory: URL, archiveURL: URL, entries: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = workingDirectory
    process.arguments = ["-q", archiveURL.path] + entries
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}
```

Expected test cases:

```swift
func testScannerInventoriesGeneiousArchiveMembersAndNativeMetadata() async throws
func testScannerClassifiesStandardFilesInFolderExport() async throws
func testSafeArchiveMemberValidationRejectsTraversalAndAbsolutePaths() throws
func testScannerRecordsUnresolvedGeneiousSourceURNs() async throws
```

Assertions:

- A `.geneious` archive containing `Example.geneious`, `fileData.0`, and `reads/sample.fa` returns `sourceKind == .geneiousArchive`.
- The XML entry is classified as `.geneiousXML`.
- `fileData.0` is classified as `.geneiousSidecar`.
- `reads/sample.fa` is classified as `.standaloneReferenceSequence`.
- The scanner records Geneious version `2026.0.2`, document class `com.biomatters.geneious.publicapi.documents.sequence.DefaultSequenceListDocument`, and unresolved URN `urn:local:test`.
- Path validation rejects `/absolute.fa`, `../escape.fa`, and `nested/../../escape.fa`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter GeneiousImportScannerTests
```

Expected: compile fails because `GeneiousImportScanner`, `GeneiousArchiveTool`, and model types do not exist.

- [ ] **Step 3: Implement scanner models and archive tool**

Implement these public/internal types:

```swift
enum GeneiousImportSourceKind: String, Codable, Sendable {
    case geneiousArchive
    case folder
    case file
}

enum GeneiousImportItemKind: String, Codable, Sendable {
    case geneiousXML
    case geneiousSidecar
    case standaloneReferenceSequence
    case annotationTrack
    case variantTrack
    case alignmentTrack
    case fastq
    case signalTrack
    case treeOrAlignment
    case report
    case binaryArtifact
    case unsupported
}

struct GeneiousImportItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sourceRelativePath: String
    let stagedRelativePath: String?
    let kind: GeneiousImportItemKind
    let lgeDestination: String?
    let sizeBytes: UInt64?
    let sha256: String?
    let geneiousDocumentClass: String?
    let geneiousDocumentName: String?
    let warnings: [String]
}

struct GeneiousImportInventory: Codable, Sendable, Equatable {
    let sourceURL: URL
    let sourceKind: GeneiousImportSourceKind
    let sourceName: String
    let createdAt: Date
    let geneiousVersion: String?
    let geneiousMinimumVersion: String?
    let items: [GeneiousImportItem]
    let documentClasses: [String]
    let unresolvedURNs: [String]
    let warnings: [String]
}
```

`GeneiousArchiveTool` responsibilities:

- `static func validateSafeMemberPath(_ path: String) throws`
- `func listMembers(archiveURL: URL) throws -> [String]`
- `func extract(archiveURL: URL, to destinationURL: URL) throws`
- Reject empty member names, absolute paths, `..` path components, and paths ending in `/..`.
- Use `/usr/bin/unzip -Z1 <archive>` for listing and `/usr/bin/unzip -qq <archive> -d <destination>` for extraction after validation.

- [ ] **Step 4: Implement `GeneiousImportScanner`**

`GeneiousImportScanner.scan(sourceURL:)` should:

- Detect `.geneious` archives by path extension.
- Extract archives to a caller-owned temp directory for scanning.
- Walk folders recursively with hidden files skipped.
- Classify file types using `ReferenceBundleImportService.classify(_:)` plus FASTQ suffix checks.
- Treat `fileData.<number>` as `.geneiousSidecar`.
- Treat XML files whose root text includes `<geneious` as `.geneiousXML`.
- Extract Geneious version/minimumVersion, `geneiousDocument class="..."`, `cache_name`, `override_cache_name`, and `excludedDocument class="urn"` values with bounded XML/text parsing.
- Compute `sizeBytes` and SHA-256 via `ProvenanceRecorder.fileRecord(for:format:role:)` or equivalent file reads.

- [ ] **Step 5: Run scanner tests and commit**

Run:

```bash
swift test --filter GeneiousImportScannerTests
```

Expected: all scanner tests pass.

Commit:

```bash
git add Sources/LungfishApp/Services/Geneious/GeneiousImportModels.swift Sources/LungfishApp/Services/Geneious/GeneiousArchiveTool.swift Sources/LungfishApp/Services/Geneious/GeneiousImportScanner.swift Tests/LungfishAppTests/GeneiousImportScannerTests.swift
git commit -m "Add Geneious import scanner"
```

## Task 2: Output Collection, Preservation, Reports, And Provenance

**Files:**
- Modify: `Sources/LungfishApp/Services/Geneious/GeneiousImportModels.swift`
- Create: `Sources/LungfishApp/Services/Geneious/GeneiousImportCollectionService.swift`
- Create: `Tests/LungfishAppTests/GeneiousImportCollectionServiceTests.swift`

- [ ] **Step 1: Write failing collection service tests**

Test cases:

```swift
func testImportCreatesOneCollectionFolderWithInventoryReportAndProvenance() async throws
func testImportPreservesUnsupportedArchiveMembersAsBinaryArtifacts() async throws
func testImportUsesInjectedReferenceImporterForStandaloneReferenceFiles() async throws
func testImportFolderNameIsSanitizedAndUniqued() async throws
```

Use an injected reference importer closure so the test does not build a real `.lungfishref`:

```swift
let service = GeneiousImportCollectionService(
    scanner: GeneiousImportScanner(),
    referenceImporter: { sourceURL, outputDirectory, preferredName in
        let bundle = outputDirectory.appendingPathComponent("\(preferredName).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return ReferenceBundleImportResult(bundleURL: bundle, bundleName: preferredName)
    }
)
```

Expected collection layout:

```text
<project>/Geneious Imports/Example Geneious Import/
  LGE Bundles/
  Binary Artifacts/
  Source/
  inventory.json
  import-report.md
  .lungfish-provenance.json
```

- [ ] **Step 2: Run collection tests and verify RED**

Run:

```bash
swift test --filter GeneiousImportCollectionServiceTests
```

Expected: compile fails because `GeneiousImportCollectionService` does not exist.

- [ ] **Step 3: Implement collection models and service**

Add:

```swift
struct GeneiousImportOptions: Sendable, Equatable {
    var collectionName: String?
    var preserveRawSource: Bool
    var importStandaloneReferences: Bool
    var preserveUnsupportedArtifacts: Bool
}

struct GeneiousImportResult: Sendable, Equatable {
    let collectionURL: URL
    let inventoryURL: URL
    let reportURL: URL
    let provenanceURL: URL
    let nativeBundleURLs: [URL]
    let preservedArtifactURLs: [URL]
    let warnings: [String]
}
```

`GeneiousImportCollectionService.importGeneiousExport(sourceURL:projectURL:options:progress:)` should:

- Create `<project>/Geneious Imports/<sanitized source name> Geneious Import`.
- Create `LGE Bundles`, `Binary Artifacts`, and `Source` subdirectories.
- Preserve the original `.geneious` archive under `Source/` when `preserveRawSource == true`.
- For archive inputs, extract to a temp staging directory and copy unsupported members to `Binary Artifacts/<relative path>`.
- For folder inputs, copy unsupported files to `Binary Artifacts/<relative path>`.
- For `.standaloneReferenceSequence`, call the injected reference importer with output directory `LGE Bundles`.
- For `.annotationTrack`, `.variantTrack`, `.alignmentTrack`, `.fastq`, `.signalTrack`, `.treeOrAlignment`, and `.report`, preserve the file in `Binary Artifacts/` and add a warning that the item is recognized but not auto-routed in the no-Geneious baseline.
- Write pretty JSON `inventory.json`.
- Write `import-report.md` with source path, counts by kind, native bundles, preserved artifacts, and warnings.
- Write `.lungfish-provenance.json` as a `WorkflowRun` named `Geneious Import` with at least scan, preserve, and reference-import steps.

- [ ] **Step 4: Run collection tests and commit**

Run:

```bash
swift test --filter GeneiousImportCollectionServiceTests
```

Expected: all collection tests pass.

Commit:

```bash
git add Sources/LungfishApp/Services/Geneious/GeneiousImportModels.swift Sources/LungfishApp/Services/Geneious/GeneiousImportCollectionService.swift Tests/LungfishAppTests/GeneiousImportCollectionServiceTests.swift
git commit -m "Create Geneious import collections"
```

## Task 3: Import Center And AppDelegate Integration

**Files:**
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
- Add integration assertions to `Tests/LungfishAppTests/GeneiousImportCollectionServiceTests.swift`

- [ ] **Step 1: Write failing Import Center catalog test**

Add assertions to `testImportCenterCatalogUsesExplicitImportCategoriesInsteadOfProjectFiles`:

```swift
XCTAssertTrue(ids.contains("geneious-export"))
let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "geneious-export" })
XCTAssertEqual(card.title, "Geneious Export")
XCTAssertEqual(card.importAction, .geneiousExport)
```

Add a test that checks the Geneious card accepts files and directories:

```swift
func testGeneiousImportCardAcceptsArchivesAndFolders() throws {
    let viewModel = ImportCenterViewModel()
    let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "geneious-export" })
    guard case .openPanel(let config, let action) = card.importKind else {
        return XCTFail("Geneious import must use an open panel")
    }
    XCTAssertEqual(action, .geneiousExport)
    XCTAssertTrue(config.canChooseFiles)
    XCTAssertTrue(config.canChooseDirectories)
    XCTAssertFalse(config.allowsMultipleSelection)
}
```

- [ ] **Step 2: Run catalog tests and verify RED**

Run:

```bash
swift test --filter ImportCenterMenuTests/testImportCenterCatalogUsesExplicitImportCategoriesInsteadOfProjectFiles
swift test --filter ImportCenterMenuTests/testGeneiousImportCardAcceptsArchivesAndFolders
```

Expected: compile fails because `.geneiousExport` is missing, or tests fail because the card is absent.

- [ ] **Step 3: Add Import Center card and dispatch**

In `ImportCenterViewModel`:

- Add `case geneiousExport` to `ImportAction`.
- Add a card in the References tab:

```swift
ImportCardInfo(
    id: "geneious-export",
    title: "Geneious Export",
    description: "Import a Geneious archive or export folder into one Lungfish project collection with native bundles and preserved artifacts.",
    sfSymbol: "shippingbox",
    fileHint: ".geneious archive or Geneious export folder",
    tab: .references,
    importKind: .openPanel(
        configuration: .init(
            allowedTypes: [
                UTType(filenameExtension: "geneious") ?? .data,
                .folder,
            ],
            canChooseFiles: true,
            canChooseDirectories: true,
            allowsMultipleSelection: false,
            allowsOtherFileTypes: true
        ),
        action: .geneiousExport
    )
)
```

- Add panel message `"Select a Geneious archive or export folder to import"`.
- Dispatch to `appDelegate.importGeneiousExportFromURL(url)` for the selected URL.
- Add history label `"Geneious"`.

- [ ] **Step 4: Add AppDelegate workflow method**

Add:

```swift
func importGeneiousExportFromURL(_ url: URL) {
    guard let projectURL = mainWindowController?.mainSplitViewController?.sidebarController.currentProjectURL
            ?? workingDirectoryURL else {
        showAlert(title: "No Project Open", message: "Please open a project before importing a Geneious export.")
        return
    }

    let opID = OperationCenter.shared.start(
        title: "Geneious Import",
        detail: "Importing \(url.lastPathComponent)...",
        operationType: .ingestion,
        cliCommand: OperationCenter.buildCLICommand(
            subcommand: "import",
            args: ["geneious", url.path, "--project", projectURL.path]
        )
    )

    Task.detached { [weak self] in
        do {
            let result = try await GeneiousImportCollectionService.default.importGeneiousExport(
                sourceURL: url,
                projectURL: projectURL,
                options: .default
            ) { progress, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: progress, detail: message)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let detail = result.warningCount == 0
                        ? "Imported \(result.collectionURL.lastPathComponent)"
                        : "Imported \(result.collectionURL.lastPathComponent) with \(result.warningCount) warnings"
                    if result.warningCount == 0 {
                        OperationCenter.shared.complete(id: opID, detail: detail)
                    } else {
                        OperationCenter.shared.completeWithWarning(id: opID, detail: detail)
                    }
                    self?.refreshSidebarAndSelectImportedURL(result.collectionURL)
                }
            }
        } catch {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                    self?.showAlert(title: "Geneious Import Failed", message: error.localizedDescription)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Run integration tests and commit**

Run:

```bash
swift test --filter ImportCenterMenuTests
swift test --filter GeneiousImportCollectionServiceTests
```

Expected: tests pass.

Commit:

```bash
git add Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/ImportCenterMenuTests.swift Tests/LungfishAppTests/GeneiousImportCollectionServiceTests.swift
git commit -m "Expose Geneious import in Import Center"
```

## Task 4: Real Sample Smoke Path And Documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-05-01-geneious-import-design.md` only if implementation behavior differs from the spec.
- No sample fixture should be committed from `/Users/dho/Downloads`.

- [ ] **Step 1: Run scanner against the real sample when present**

Use a temporary Swift test helper or a one-off `swift test` case guarded by environment variable:

```bash
LUNGFISH_GENEIOUS_SAMPLE=/Users/dho/Downloads/MCM_MHC_haplotypes-annotated.geneious swift test --filter GeneiousImportScannerTests/testExternalSampleInventoryWhenAvailable
```

Expected when the file exists:

- Inventory source kind is `.geneiousArchive`.
- It finds one Geneious XML item and thirteen `fileData.*` sidecar items.
- It records Geneious version `2026.0.2`.
- It records unresolved URNs.

- [ ] **Step 2: Run final targeted verification**

Run:

```bash
swift test --filter GeneiousImportScannerTests
swift test --filter GeneiousImportCollectionServiceTests
swift test --filter ImportCenterMenuTests
git diff --check
```

Expected: targeted tests pass and diff check reports no whitespace errors.

- [ ] **Step 3: Run final no-build suite check**

Run:

```bash
swift test --skip-build > /tmp/lge-geneious-final.log 2>&1; status=$?; echo STATUS:$status; tail -n 160 /tmp/lge-geneious-final.log
```

Expected: capture the final status and tail. If the status remains nonzero with no Geneious-related failures, document it in the final response as a pre-existing baseline issue.

- [ ] **Step 4: Commit final verification/doc adjustment**

If the external sample test or docs changed:

```bash
git add Tests/LungfishAppTests/GeneiousImportScannerTests.swift docs/superpowers/specs/2026-05-01-geneious-import-design.md
git commit -m "Verify Geneious sample inventory"
```

If no files changed after verification, do not create an empty commit.
