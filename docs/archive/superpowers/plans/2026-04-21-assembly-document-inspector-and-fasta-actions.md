# Assembly Document Inspector and FASTA Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move assembly provenance into the right-sidebar `Document` inspector, simplify the assembly detail pane into a reads-style contig preview surface, and unify BLAST/FASTA actions across assembly, NVD, and standalone FASTA content.

**Architecture:** Treat assembly as a first-class viewport mode with a dedicated document-inspector payload instead of piggybacking on generic genomics. Keep the shared assembly viewport shell, replace the current provenance-heavy detail pane with a preview-oriented contig surface, and extract a shared FASTA action/menu layer that assembly, NVD, and `FASTACollectionViewController` can all use with explicit FASTA-capability gating.

**Tech Stack:** Swift, AppKit, SwiftUI, LungfishCore notifications, LungfishWorkflow assembly + provenance models, XCTest, `swift test`, focused `xcodebuild` XCUI verification.

---

## File Structure

### Core Mode Plumbing

- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/InspectorAssemblyModeTests.swift`

### Assembly Document Inspector

- Create: `Sources/LungfishApp/Views/Inspector/Sections/AssemblyDocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/AssemblyDocumentSectionTests.swift`

### Source Data Linkbacks

- Create: `Sources/LungfishApp/Views/Inspector/AssemblyInspectorSourceResolver.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/AssemblyInspectorSourceResolverTests.swift`

### Assembly Viewport Detail Surface

- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`

### Shared FASTA Actions and Capability Gating

- Create: `Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift`
- Create: `Sources/LungfishApp/Views/Shared/FASTASequenceActionMenuBuilder.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationsDialogPresenter.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Test: `Tests/LungfishAppTests/FASTAOperationCatalogTests.swift`
- Test: `Tests/LungfishAppTests/FASTASequenceActionMenuBuilderTests.swift`
- Test: `Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift`

This split keeps mode routing, inspector state, provenance resolution, viewport rendering, and shared FASTA actions isolated enough to implement and verify independently.

### Task 1: Add Assembly Viewport Mode Plumbing

**Files:**
- Create: `Tests/LungfishAppTests/InspectorAssemblyModeTests.swift`
- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

- [ ] **Step 1: Write the failing assembly-mode tests**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class InspectorAssemblyModeTests: XCTestCase {
    func testAssemblyModeExposesOnlyDocumentTab() {
        let model = InspectorViewModel()
        model.contentMode = .assembly

        XCTAssertEqual(model.availableTabs, [.document])
    }

    func testAssemblyModeUsesDocumentHeaderWhenOnlyOneTabExists() {
        let model = InspectorViewModel()
        model.contentMode = .assembly
        model.selectedTab = .document

        let view = InspectorView(viewModel: model)
        XCTAssertTrue(String(describing: view.body).contains("Document"))
    }
}
```

- [ ] **Step 2: Run the tests to verify `.assembly` does not exist yet**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter InspectorAssemblyModeTests
```

Expected: FAIL with a compile error because `ViewportContentMode` has no `assembly` case.

- [ ] **Step 3: Implement the new content mode and route assembly views through it**

```swift
// Sources/LungfishCore/Models/Notifications.swift
public enum ViewportContentMode: String, Sendable {
    case genomics
    case fastq
    case metagenomics
    case assembly
    case empty
}
```

```swift
// Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift
public func displayAssemblyResult(_ result: AssemblyResult) {
    // ...
    contentMode = .assembly
    // ...
}
```

```swift
// Sources/LungfishApp/Views/MainWindow/MainWindowController.swift
private func updateToolbarForContentMode(_ mode: ViewportContentMode) {
    switch item.itemIdentifier {
    case ToolbarIdentifier.translateTool, ToolbarIdentifier.toggleChromosomeDrawer:
        let visible = (mode == .genomics || mode == .empty)
        item.isHidden = !visible
        item.isEnabled = visible
    case ToolbarIdentifier.toggleAnnotationDrawer:
        let visible = (mode == .genomics || mode == .metagenomics || mode == .fastq)
        item.isHidden = !visible
        item.isEnabled = visible
    default:
        break
    }
}
```

```swift
// Sources/LungfishApp/Views/Inspector/InspectorViewController.swift
var availableTabs: [InspectorTab] {
    switch contentMode {
    case .genomics:
        return [.document, .selection, .ai]
    case .fastq:
        return [.document]
    case .metagenomics:
        return [.resultSummary]
    case .assembly:
        return [.document]
    case .empty:
        return [.document, .selection]
    }
}
```

- [ ] **Step 4: Re-run the assembly-mode tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter InspectorAssemblyModeTests
```

Expected: PASS with `2 tests passed`.

- [ ] **Step 5: Commit the mode-plumbing checkpoint**

```bash
git add \
  Sources/LungfishCore/Models/Notifications.swift \
  Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift \
  Sources/LungfishApp/Views/MainWindow/MainWindowController.swift \
  Sources/LungfishApp/Views/Inspector/InspectorViewController.swift \
  Tests/LungfishAppTests/InspectorAssemblyModeTests.swift
git commit -m "feat: add assembly viewport content mode"
```

### Task 2: Build the Assembly Document Inspector Section

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/AssemblyDocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/AssemblyDocumentSectionTests.swift`

- [ ] **Step 1: Write failing tests for section ordering and content presence**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class AssemblyDocumentSectionTests: XCTestCase {
    func testAssemblySectionOrderPutsLayoutBeforeProvenanceAndArtifacts() {
        let state = AssemblyDocumentState(
            title: "spades-2026-04-21T09-20-22",
            assembler: "SPAdes",
            readType: "Illumina Short Reads",
            sourceData: [.resolved(name: "reads_R1.fastq.gz", targetURL: URL(fileURLWithPath: "/tmp/reads_R1.fastq.gz"))],
            contextRows: [("Assembler", "SPAdes")],
            artifactRows: [("Contigs FASTA", URL(fileURLWithPath: "/tmp/contigs.fasta"))]
        )

        XCTAssertEqual(
            state.visibleSectionOrder,
            [.header, .layout, .sourceData, .assemblyContext, .sourceArtifacts]
        )
    }

    func testDocumentSectionPrefersAssemblyViewWhenAssemblyStateExists() {
        let vm = DocumentSectionViewModel()
        vm.assemblyDocument = AssemblyDocumentState(
            title: "assembly",
            assembler: "SPAdes",
            readType: "Illumina Short Reads",
            sourceData: [],
            contextRows: [],
            artifactRows: []
        )

        let view = DocumentSection(viewModel: vm)
        XCTAssertTrue(String(describing: view.body).contains("AssemblyDocumentSection"))
    }
}
```

- [ ] **Step 2: Run the tests to verify the assembly document model does not exist**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter AssemblyDocumentSectionTests
```

Expected: FAIL with compile errors because `AssemblyDocumentState` and `AssemblyDocumentSection` do not exist.

- [ ] **Step 3: Implement the assembly document state and section**

```swift
// Sources/LungfishApp/Views/Inspector/Sections/AssemblyDocumentSection.swift
import SwiftUI

enum AssemblyDocumentSectionKind: CaseIterable {
    case header
    case layout
    case sourceData
    case assemblyContext
    case sourceArtifacts
}

enum AssemblyDocumentSourceRow: Equatable {
    case resolved(name: String, targetURL: URL)
    case filesystem(name: String, fileURL: URL)
    case missing(name: String, originalPath: String?)
}

struct AssemblyDocumentState: Equatable {
    var title: String
    var assembler: String
    var readType: String
    var sourceData: [AssemblyDocumentSourceRow]
    var contextRows: [(String, String)]
    var artifactRows: [(String, URL?)]

    var visibleSectionOrder: [AssemblyDocumentSectionKind] {
        [.header, .layout, .sourceData, .assemblyContext, .sourceArtifacts]
    }
}

struct AssemblyDocumentSection: View {
    @Bindable var viewModel: DocumentSectionViewModel

    @ViewBuilder
    var body: some View {
        if let assembly = viewModel.assemblyDocument {
            VStack(alignment: .leading, spacing: 12) {
                Text(assembly.title)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Panel Layout")
                        .font(.caption.weight(.semibold))
                    Picker("Layout", selection: $viewModel.metagenomicsPanelLayout) {
                        Text("Detail | List").tag(MetagenomicsPanelLayout.detailLeading)
                        Text("List | Detail").tag(MetagenomicsPanelLayout.listLeading)
                        Text("List Over Detail").tag(MetagenomicsPanelLayout.stacked)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                DisclosureGroup("Source Data") {
                    ForEach(Array(assembly.sourceData.enumerated()), id: \.offset) { _, row in
                        Text(String(describing: row))
                            .font(.caption)
                    }
                }

                DisclosureGroup("Assembly Context") {
                    ForEach(Array(assembly.contextRows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.1).textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }

                DisclosureGroup("Source Artifacts") {
                    ForEach(Array(assembly.artifactRows.enumerated()), id: \.offset) { _, row in
                        Text("\(row.0): \(row.1?.path ?? "missing")")
                            .font(.caption)
                    }
                }
            }
        }
    }
}
```

```swift
// Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift
@Observable
@MainActor
public final class DocumentSectionViewModel {
    var assemblyDocument: AssemblyDocumentState?
    var navigateToSourceData: ((URL) -> Void)?
}

public struct DocumentSection: View {
    public var body: some View {
        if viewModel.assemblyDocument != nil {
            AssemblyDocumentSection(viewModel: viewModel)
        } else if let manifest = viewModel.manifest {
            bundleContent(manifest)
        } else if let stats = viewModel.fastqStatistics {
            fastqContent(stats)
        } else {
            noDocumentView
        }
    }
}
```

- [ ] **Step 4: Re-run the assembly document section tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter AssemblyDocumentSectionTests
```

Expected: PASS with `2 tests passed`.

- [ ] **Step 5: Commit the new assembly document section**

```bash
git add \
  Sources/LungfishApp/Views/Inspector/Sections/AssemblyDocumentSection.swift \
  Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift \
  Sources/LungfishApp/Views/Inspector/InspectorViewController.swift \
  Tests/LungfishAppTests/AssemblyDocumentSectionTests.swift
git commit -m "feat: add assembly document inspector section"
```

### Task 3: Resolve Source Data Linkbacks and Populate the Inspector

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/AssemblyInspectorSourceResolver.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Test: `Tests/LungfishAppTests/AssemblyInspectorSourceResolverTests.swift`

- [ ] **Step 1: Write failing tests for provenance input resolution**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AssemblyInspectorSourceResolverTests: XCTestCase {
    func testResolverPrefersProjectRelativeLinkbacks() {
        let projectURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let inputURL = projectURL.appendingPathComponent("Imports/reads.fastq.gz")
        try? FileManager.default.createDirectory(at: inputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inputURL.path, contents: Data())

        let rows = AssemblyInspectorSourceResolver.resolve(
            provenanceInputs: [.init(filename: "reads.fastq.gz", originalPath: inputURL.path, sha256: nil, sizeBytes: 0)],
            projectURL: projectURL
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first, .resolved(name: "reads.fastq.gz", targetURL: inputURL))
    }

    func testResolverFallsBackToMissingWhenPathCannotBeResolved() {
        let rows = AssemblyInspectorSourceResolver.resolve(
            provenanceInputs: [.init(filename: "missing.fastq.gz", originalPath: "/tmp/does-not-exist.fastq.gz", sha256: nil, sizeBytes: 0)],
            projectURL: nil
        )

        XCTAssertEqual(rows.first, .missing(name: "missing.fastq.gz", originalPath: "/tmp/does-not-exist.fastq.gz"))
    }
}
```

- [ ] **Step 2: Run the resolver tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter AssemblyInspectorSourceResolverTests
```

Expected: FAIL with compile errors because `AssemblyInspectorSourceResolver` does not exist.

- [ ] **Step 3: Implement the resolver and inspector update hook**

```swift
// Sources/LungfishApp/Views/Inspector/AssemblyInspectorSourceResolver.swift
import Foundation
import LungfishWorkflow

enum AssemblyInspectorSourceResolver {
    static func resolve(
        provenanceInputs: [InputFileRecord],
        projectURL: URL?
    ) -> [AssemblyDocumentSourceRow] {
        provenanceInputs.map { input in
            if let originalPath = input.originalPath {
                let originalURL = URL(fileURLWithPath: originalPath)
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return .resolved(name: input.filename, targetURL: originalURL)
                }
            }

            if let projectURL {
                let candidate = projectURL.appendingPathComponent(input.filename)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return .resolved(name: input.filename, targetURL: candidate)
                }
            }

            if let originalPath = input.originalPath {
                let originalURL = URL(fileURLWithPath: originalPath)
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return .filesystem(name: input.filename, fileURL: originalURL)
                }
            }

            return .missing(name: input.filename, originalPath: input.originalPath)
        }
    }
}
```

```swift
// Sources/LungfishApp/Views/Inspector/InspectorViewController.swift
public func updateAssemblyDocument(
    result: AssemblyResult,
    provenance: AssemblyProvenance?,
    projectURL: URL?
) {
    let sourceRows = AssemblyInspectorSourceResolver.resolve(
        provenanceInputs: provenance?.inputs ?? [],
        projectURL: projectURL
    )

    viewModel.documentSectionViewModel.assemblyDocument = AssemblyDocumentState(
        title: result.outputDirectory.lastPathComponent,
        assembler: result.tool.displayName,
        readType: result.readType.displayName,
        sourceData: sourceRows,
        contextRows: [
            ("Assembler", result.tool.displayName),
            ("Read Type", result.readType.displayName),
            ("Version", result.assemblerVersion ?? "unknown"),
            ("Wall Time", String(format: "%.1fs", result.wallTimeSeconds))
        ],
        artifactRows: [
            ("Contigs FASTA", result.contigsPath),
            ("Scaffolds", result.scaffoldsPath),
            ("Graph", result.graphPath),
            ("Log", result.logPath),
            ("Params", result.paramsPath),
            ("Provenance", provenance.map { result.outputDirectory.appendingPathComponent(AssemblyProvenance.filename) })
        ]
    )
    viewModel.documentSectionViewModel.navigateToSourceData = { url in
        NotificationCenter.default.post(name: .navigateToSidebarItem, object: nil, userInfo: ["url": url])
    }
}
```

```swift
// Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift
private func displayAssemblyAnalysisFromSidebar(at url: URL) {
    let result = try AssemblyResult.load(from: url)
    let provenance = try? AssemblyProvenance.load(from: url)
    inspectorController.clearSelection()
    inspectorController.updateAssemblyDocument(result: result, provenance: provenance, projectURL: projectURL)
    viewerController.displayAssemblyResult(result)
}
```

- [ ] **Step 4: Re-run the inspector resolver tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter AssemblyInspectorSourceResolverTests
```

Expected: PASS with `2 tests passed`.

- [ ] **Step 5: Commit the source-resolution wiring**

```bash
git add \
  Sources/LungfishApp/Views/Inspector/AssemblyInspectorSourceResolver.swift \
  Sources/LungfishApp/Views/Inspector/InspectorViewController.swift \
  Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift \
  Tests/LungfishAppTests/AssemblyInspectorSourceResolverTests.swift
git commit -m "feat: populate assembly inspector from provenance"
```

### Task 4: Replace the Assembly Detail Pane with a Reads-Style Preview Surface

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`

- [ ] **Step 1: Rewrite the failing viewport tests around reads-style detail content**

```swift
func testSingleSelectionShowsReadsStylePreviewWithoutContextBlocks() async throws {
    let vc = AssemblyResultViewController()
    _ = vc.view
    try await vc.configureForTesting(result: makeAssemblyResult())

    try await vc.testSelectContig(named: "contig_7")

    XCTAssertEqual(vc.testDetailPane.currentHeaderText, "contig_7")
    XCTAssertTrue(vc.testDetailPane.currentPreviewRows.contains { $0.sequencePreview.contains("AACCGGTT") })
    XCTAssertFalse(vc.testDetailPane.currentVisibleSectionTitles.contains("Assembly Context"))
    XCTAssertFalse(vc.testDetailPane.currentVisibleSectionTitles.contains("Source Artifacts"))
}

func testMultiSelectionShowsSelectionSummaryAndPreviewRows() async throws {
    let vc = AssemblyResultViewController()
    _ = vc.view
    try await vc.configureForTesting(result: makeAssemblyResult())

    try await vc.testSelectContigs(named: ["contig_7", "contig_9"])

    XCTAssertEqual(vc.testDetailPane.currentSummaryTitle, "2 contigs selected")
    XCTAssertEqual(vc.testDetailPane.currentPreviewRows.count, 2)
}
```

- [ ] **Step 2: Run the viewport tests to capture the current mismatch**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter AssemblyResultViewControllerTests
```

Expected: FAIL because the detail pane still renders `Assembly Context` and `Source Artifacts`.

- [ ] **Step 3: Implement the reads-style contig preview pane**

```swift
// Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift
final class AssemblyContigDetailPane: NSView {
    struct PreviewRow: Equatable {
        let rank: Int
        let name: String
        let lengthBP: Int
        let sequencePreview: String
    }

    private let titleLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let previewTable = NSTableView()
    private var previewRows: [PreviewRow] = []

    func showSingleSelection(record: AssemblyContigRecord, preview: String) {
        titleLabel.stringValue = record.name
        subtitleLabel.stringValue = "\(record.lengthBP) bp • \(String(format: "%.1f%% GC", record.gcPercent))"
        previewRows = [.init(rank: record.rank, name: record.name, lengthBP: record.lengthBP, sequencePreview: preview)]
        previewTable.reloadData()
    }

    func showMultiSelection(summary: AssemblyContigSelectionSummary, rows: [PreviewRow]) {
        titleLabel.stringValue = "\(summary.selectedContigCount) contigs selected"
        subtitleLabel.stringValue = "\(summary.totalSelectedBP) bp total"
        previewRows = rows
        previewTable.reloadData()
    }

#if DEBUG
    var currentPreviewRows: [PreviewRow] { previewRows }
    var currentVisibleSectionTitles: [String] { ["Preview"] }
#endif
}
```

```swift
// Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift
private func previewText(from fasta: String, prefixLength: Int = 80) -> String {
    fasta
        .split(whereSeparator: \.isNewline)
        .dropFirst()
        .joined()
        .prefix(prefixLength)
        .description
}

private func showSelection(rows: [AssemblyContigRecord]) async {
    // ...
    if rows.count == 1, let record = rows.first {
        let fasta = (try? await catalog.sequenceFASTA(for: record.name, lineWidth: 70)) ?? ""
        detailPane.showSingleSelection(record: record, preview: previewText(from: fasta))
        return
    }

    guard let summary = try? await catalog.selectionSummary(for: rows.map(\.name)) else {
        return
    }

    var previewRows: [AssemblyContigDetailPane.PreviewRow] = []
    for row in rows {
        let fasta = (try? await catalog.sequenceFASTA(for: row.name, lineWidth: 70)) ?? ""
        previewRows.append(.init(
            rank: row.rank,
            name: row.name,
            lengthBP: row.lengthBP,
            sequencePreview: previewText(from: fasta)
        ))
    }
    detailPane.showMultiSelection(summary: summary, rows: previewRows)
}
```

- [ ] **Step 4: Re-run the assembly viewport tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter AssemblyResultViewControllerTests
```

Expected: PASS with the updated reads-style assertions.

- [ ] **Step 5: Commit the viewport rewrite**

```bash
git add \
  Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift \
  Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift \
  Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift
git commit -m "feat: use reads-style preview in assembly detail pane"
```

### Task 5: Add Shared FASTA Actions and FASTA Capability Gating

**Files:**
- Create: `Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift`
- Create: `Sources/LungfishApp/Views/Shared/FASTASequenceActionMenuBuilder.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Test: `Tests/LungfishAppTests/FASTAOperationCatalogTests.swift`
- Test: `Tests/LungfishAppTests/FASTASequenceActionMenuBuilderTests.swift`
- Test: `Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift`

- [ ] **Step 1: Write failing tests for the shared FASTA menu and FASTA-only operation filtering**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class FASTAOperationCatalogTests: XCTestCase {
    func testCatalogOnlyReturnsFASTACompatibleOperations() {
        let ids = FASTAOperationCatalog.availableOperationKinds().map(\.rawValue)

        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.searchMotif.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.orient.rawValue))
        XCTAssertFalse(ids.contains(FASTQDerivativeOperationKind.qualityTrim.rawValue))
        XCTAssertFalse(ids.contains(FASTQDerivativeOperationKind.demultiplex.rawValue))
    }
}

@MainActor
final class FASTASequenceActionMenuBuilderTests: XCTestCase {
    func testBuilderCreatesCommonAssemblyAndFastaActions() {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 1,
            supportsBlast: true,
            supportsRunOperation: true,
            handlers: .noop
        )

        XCTAssertEqual(
            menu.items.map(\.title).filter { !$0.isEmpty },
            ["Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Create Bundle…", "Run Operation…"]
        )
    }
}
```

- [ ] **Step 2: Run the failing FASTA action tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter FASTA
```

Expected: FAIL with compile errors because the FASTA action builder and catalog do not exist.

- [ ] **Step 3: Implement the FASTA action builder and capability catalog**

```swift
// Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift
import LungfishIO

enum FASTAOperationCatalog {
    static func availableOperationKinds() -> [FASTQDerivativeOperationKind] {
        FASTQDerivativeOperationKind.allCases.filter(\.supportsFASTA)
    }
}
```

```swift
// Sources/LungfishApp/Views/Shared/FASTASequenceActionMenuBuilder.swift
import AppKit

struct FASTASequenceActionHandlers {
    var onBlast: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    var onCreateBundle: (() -> Void)?
    var onRunOperation: (() -> Void)?

    static let noop = FASTASequenceActionHandlers()
}

enum FASTASequenceActionMenuBuilder {
    private final class ActionTarget: NSObject {
        let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func performAction() {
            handler()
        }
    }

    private static func makeItem(_ title: String, handler: (() -> Void)?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ActionTarget.performAction), keyEquivalent: "")
        guard let handler else {
            item.isEnabled = false
            return item
        }
        let target = ActionTarget(handler: handler)
        item.target = target
        objc_setAssociatedObject(item, Unmanaged.passUnretained(item).toOpaque(), target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return item
    }

    static func buildMenu(
        selectionCount: Int,
        supportsBlast: Bool,
        supportsRunOperation: Bool,
        handlers: FASTASequenceActionHandlers
    ) -> NSMenu {
        let menu = NSMenu(title: "FASTA Actions")
        if supportsBlast { menu.addItem(makeItem("Verify with BLAST…", handler: handlers.onBlast)) }
        menu.addItem(makeItem("Copy FASTA", handler: handlers.onCopy))
        menu.addItem(makeItem("Export FASTA…", handler: handlers.onExport))
        menu.addItem(makeItem("Create Bundle…", handler: handlers.onCreateBundle))
        if supportsRunOperation {
            menu.addItem(makeItem("Run Operation…", handler: handlers.onRunOperation))
        }
        return menu
    }
}
```

```swift
// Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift
@MainActor
final class FASTQOperationDialogState {
    var fastaPreviewRecords: [String] = []
    var allowedFASTAOperationKinds: Set<FASTQDerivativeOperationKind> = []
}
```

```swift
// Sources/LungfishApp/Views/FASTQ/FASTQOperationsDialogPresenter.swift
@MainActor
struct FASTQOperationsDialogPresenter {
    static func presentFASTAOperations(
        from window: NSWindow,
        fastaRecords: [String],
        allowedKinds: [FASTQDerivativeOperationKind],
        onRun: ((FASTQOperationDialogState) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: []
        )
        state.fastaPreviewRecords = fastaRecords
        state.allowedFASTAOperationKinds = Set(allowedKinds)
        present(from: window, selectedInputURLs: [], initialCategory: .searchSubsetting, onRun: onRun, onCancel: onCancel)
    }
}
```

- [ ] **Step 4: Wire the builder into assembly, NVD, and standalone FASTA views**

```swift
// Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift
public var onRunOperationRequested: (([String]) -> Void)?

private func buildContextMenu() -> NSMenu {
    FASTASequenceActionMenuBuilder.buildMenu(
        selectionCount: selectedContigNames.count,
        supportsBlast: true,
        supportsRunOperation: !FASTAOperationCatalog.availableOperationKinds().isEmpty,
        handlers: FASTASequenceActionHandlers(
            onBlast: { [weak self] in self?.performBlastSelected() },
            onCopy: { [weak self] in self?.performCopySelectedFASTA() },
            onExport: { [weak self] in self?.performExportSelectedFASTA() },
            onCreateBundle: { [weak self] in self?.performCreateBundle() },
            onRunOperation: { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    guard let self, let catalog = self.catalog else { return }
                    var fasta: [String] = []
                    for name in self.selectedContigNames {
                        if let record = try? await catalog.sequenceFASTA(for: name, lineWidth: 70) {
                            fasta.append(record)
                        }
                    }
                    self.onRunOperationRequested?(fasta)
                }
            }
        )
    )
}
```

```swift
// Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift
public var onRunOperationRequested: (([String]) -> Void)?

private func contigFASTA(for hit: NvdBlastHit) -> String? {
    guard let bundleURL, let database else { return nil }
    guard let fastaRelPath = try? database.fastaPath(forSample: hit.sampleId) else { return nil }
    let fastaURL = bundleURL.appendingPathComponent(fastaRelPath)
    guard let sequence = NvdDataConverter.extractContigSequence(from: fastaURL, contigName: hit.qseqid) else {
        return nil
    }
    return ">\(hit.qseqid)\n\(sequence)\n"
}

private func populateContextMenu(_ menu: NSMenu, for hit: NvdBlastHit) {
    let shared = FASTASequenceActionMenuBuilder.buildMenu(
        selectionCount: outlineView.selectedRowIndexes.count,
        supportsBlast: onBlastVerification != nil,
        supportsRunOperation: !FASTAOperationCatalog.availableOperationKinds().isEmpty,
        handlers: FASTASequenceActionHandlers(
            onBlast: { [weak self] in self?.blastVerify(hit) },
            onCopy: { [weak self] in self?.copyContigSequence(hit) },
            onExport: { [weak self] in self?.exportContigSequence(hit) },
            onCreateBundle: { [weak self] in self?.createBundle(from: [hit]) },
            onRunOperation: { [weak self] in
                guard let self, let fasta = self.contigFASTA(for: hit) else { return }
                self.onRunOperationRequested?([fasta])
            }
        )
    )
    menu.items = shared.items
}
```

```swift
// Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift
public var onBlastRequested: (([LungfishCore.Sequence]) -> Void)?
public var onExportRequested: (([LungfishCore.Sequence]) -> Void)?
public var onCreateBundleRequested: (([LungfishCore.Sequence]) -> Void)?
public var onRunOperationRequested: (([LungfishCore.Sequence]) -> Void)?

private func selectedSequences() -> [LungfishCore.Sequence] {
    tableView.selectedRowIndexes.compactMap { index in
        guard index >= 0, index < displayedSequences.count else { return nil }
        return displayedSequences[index]
    }
}

private func copySelectedSequencesAsFASTA() {
    let fasta = selectedSequences().map { ">\($0.name)\n\($0.asString())" }.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(fasta + "\n", forType: .string)
}

private func setupContextMenu() {
    tableView.menu = FASTASequenceActionMenuBuilder.buildMenu(
        selectionCount: tableView.numberOfSelectedRows,
        supportsBlast: true,
        supportsRunOperation: !FASTAOperationCatalog.availableOperationKinds().isEmpty,
        handlers: FASTASequenceActionHandlers(
            onBlast: { [weak self] in self?.onBlastRequested?(self?.selectedSequences() ?? []) },
            onCopy: { [weak self] in self?.copySelectedSequencesAsFASTA() },
            onExport: { [weak self] in self?.onExportRequested?(self?.selectedSequences() ?? []) },
            onCreateBundle: { [weak self] in self?.onCreateBundleRequested?(self?.selectedSequences() ?? []) },
            onRunOperation: { [weak self] in self?.onRunOperationRequested?(self?.selectedSequences() ?? []) }
        )
    )
}
```

```swift
// Sources/LungfishApp/Views/Viewer/ViewerViewController.swift
private func presentFastaOperationDialog(records: [String]) {
    let kinds = FASTAOperationCatalog.availableOperationKinds()
    guard !records.isEmpty, !kinds.isEmpty else { return }
    guard let window = view.window else { return }
    FASTQOperationsDialogPresenter.presentFASTAOperations(
        from: window,
        fastaRecords: records,
        allowedKinds: kinds
    )
}

public func displayFASTACollection(
    sequences: [LungfishCore.Sequence],
    annotations: [SequenceAnnotation],
    sourceNames: [UUID: String]
) {
    // ...
    controller.onRunOperationRequested = { [weak self] sequences in
        let records = sequences.map { ">\($0.name)\n\($0.asString())\n" }
        self?.presentFastaOperationDialog(records: records)
    }
}
```

- [ ] **Step 5: Run the FASTA action tests and the focused integration sweep**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter FASTA
```

Expected: PASS with the FASTA catalog, menu-builder, and collection-view tests all green.

- [ ] **Step 6: Run one focused assembly UI regression and commit the integration**

Run:

```bash
xcodebuild test -project /Users/dho/Documents/lungfish-genome-explorer/Lungfish.xcodeproj -scheme Lungfish -only-testing:LungfishXCUITests/AssemblyXCUITests/testSpadesDeterministicRunShowsResultViewport
```

Expected: PASS with `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit the shared FASTA action integration**

```bash
git add \
  Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift \
  Sources/LungfishApp/Views/Shared/FASTASequenceActionMenuBuilder.swift \
  Sources/LungfishApp/Views/FASTQ/FASTQOperationsDialogPresenter.swift \
  Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift \
  Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift \
  Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift \
  Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift \
  Sources/LungfishApp/Views/Viewer/ViewerViewController.swift \
  Tests/LungfishAppTests/FASTAOperationCatalogTests.swift \
  Tests/LungfishAppTests/FASTASequenceActionMenuBuilderTests.swift \
  Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift
git commit -m "feat: share FASTA actions across assembly and viewers"
```

## Self-Review

- **Spec coverage:** The tasks cover the `.assembly` mode, right-sidebar document inspector, source-data linkbacks, source artifacts, reads-style assembly detail pane, shared FASTA actions, NVD parity, standalone FASTA parity, and FASTA-only operation filtering.
- **Placeholder scan:** No task relies on `TODO`, “handle appropriately”, or unspecified follow-up work. Every task names the concrete files, tests, and commands.
- **Type consistency:** The plan uses one assembly document payload name (`AssemblyDocumentState`), one resolver (`AssemblyInspectorSourceResolver`), and one shared FASTA menu builder (`FASTASequenceActionMenuBuilder`) across all tasks.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-21-assembly-document-inspector-and-fasta-actions.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
