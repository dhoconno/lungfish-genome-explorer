# Merge Selected Bundles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sidebar right-click action that merges homogeneous multi-selections of `.lungfishfastq` or `.lungfishref` bundles into a new bundle, with virtual single-end FASTQ merging preferred and sequence-only reference merging in v1.

**Architecture:** Keep sidebar menu logic thin by extracting bundle-merge eligibility and routing into small service helpers. Implement FASTQ merging in a dedicated service that chooses between a virtual `source-files.json` bundle and a physical merged FASTQ bundle, then implement reference merging in a separate service that resolves source FASTA files and reuses the existing reference import/build pipeline to create a standard `BundleManifest` bundle. Wire the sidebar action to prompt for a name, dispatch to the correct service, reload the filesystem view, and reselect the created bundle.

**Tech Stack:** Swift, AppKit, LungfishApp services, LungfishIO FASTQ/reference bundle helpers, LungfishWorkflow native tools and FASTQ statistics, XCTest, `swift test`.

---

## File Structure

### Sidebar Merge Eligibility and Routing

- Create: `Sources/LungfishApp/Services/BundleMergeSelection.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Test: `Tests/LungfishAppTests/BundleMergeSelectionTests.swift`

### FASTQ Merge Service

- Create: `Sources/LungfishApp/Services/FASTQBundleMergeService.swift`
- Test: `Tests/LungfishAppTests/FASTQBundleMergeServiceTests.swift`

### Reference Merge Service

- Create: `Sources/LungfishApp/Services/ReferenceBundleMergeService.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleMergeServiceTests.swift`

### Sidebar Action Integration

- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift`

This split keeps selection-policy logic independent from the file-creation code, gives FASTQ and reference merging separate failure surfaces, and limits `SidebarViewController` to prompting, dispatch, refresh, and selection.

## Task 1: Add Merge Eligibility Detection and Menu Wiring

**Files:**
- Create: `Sources/LungfishApp/Services/BundleMergeSelection.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Test: `Tests/LungfishAppTests/BundleMergeSelectionTests.swift`

- [x] **Step 1: Write the failing eligibility tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class BundleMergeSelectionTests: XCTestCase {
    func testDetectsFastqSelectionKindForHomogeneousMultiSelect() {
        let items = [
            SidebarItem(title: "A", type: .fastqBundle, url: URL(fileURLWithPath: "/tmp/A.lungfishfastq")),
            SidebarItem(title: "B", type: .fastqBundle, url: URL(fileURLWithPath: "/tmp/B.lungfishfastq")),
        ]

        XCTAssertEqual(BundleMergeSelection.detectKind(for: items), .fastq)
    }

    func testDetectsReferenceSelectionKindForHomogeneousMultiSelect() {
        let items = [
            SidebarItem(title: "Ref1", type: .referenceBundle, url: URL(fileURLWithPath: "/tmp/Ref1.lungfishref")),
            SidebarItem(title: "Ref2", type: .referenceBundle, url: URL(fileURLWithPath: "/tmp/Ref2.lungfishref")),
        ]

        XCTAssertEqual(BundleMergeSelection.detectKind(for: items), .reference)
    }

    func testRejectsMixedBundleSelections() {
        let items = [
            SidebarItem(title: "Ref", type: .referenceBundle, url: URL(fileURLWithPath: "/tmp/Ref.lungfishref")),
            SidebarItem(title: "Reads", type: .fastqBundle, url: URL(fileURLWithPath: "/tmp/Reads.lungfishfastq")),
        ]

        XCTAssertNil(BundleMergeSelection.detectKind(for: items))
    }

    func testRejectsSingleSelection() {
        let items = [
            SidebarItem(title: "Reads", type: .fastqBundle, url: URL(fileURLWithPath: "/tmp/Reads.lungfishfastq")),
        ]

        XCTAssertNil(BundleMergeSelection.detectKind(for: items))
    }
}
```

- [x] **Step 2: Run the tests to verify the helper does not exist yet**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter BundleMergeSelectionTests
```

Expected: FAIL with a compile error because `BundleMergeSelection` is undefined.

- [x] **Step 3: Implement the helper and add menu insertion in the sidebar**

```swift
// Sources/LungfishApp/Services/BundleMergeSelection.swift
import Foundation

enum BundleMergeSelectionKind: Equatable {
    case fastq
    case reference
}

enum BundleMergeSelection {
    static func detectKind(for items: [SidebarItem]) -> BundleMergeSelectionKind? {
        guard items.count >= 2 else { return nil }
        let itemTypes = Set(items.map(\.type))
        if itemTypes == [.fastqBundle] { return .fastq }
        if itemTypes == [.referenceBundle] { return .reference }
        return nil
    }
}
```

```swift
// Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
let mergeSelectionKind = BundleMergeSelection.detectKind(for: items)

if mergeSelectionKind != nil {
    let mergeItem = NSMenuItem(
        title: "Merge into New Bundle…",
        action: #selector(contextMenuMergeIntoNewBundle(_:)),
        keyEquivalent: ""
    )
    mergeItem.target = self
    menu.addItem(mergeItem)
    menu.addItem(NSMenuItem.separator())
}
```

- [x] **Step 4: Re-run the helper tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter BundleMergeSelectionTests
```

Expected: PASS with `4 tests passed`.

- [x] **Step 5: Commit the eligibility helper checkpoint**

```bash
git add \
  Sources/LungfishApp/Services/BundleMergeSelection.swift \
  Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift \
  Tests/LungfishAppTests/BundleMergeSelectionTests.swift
git commit -m "feat: add bundle merge menu eligibility"
```

## Task 2: Implement FASTQ Bundle Merging with Virtual Single-End Preference

**Files:**
- Create: `Sources/LungfishApp/Services/FASTQBundleMergeService.swift`
- Test: `Tests/LungfishAppTests/FASTQBundleMergeServiceTests.swift`

- [x] **Step 1: Write the failing FASTQ merge service tests**

```swift
import XCTest
import LungfishIO
@testable import LungfishApp

@MainActor
final class FASTQBundleMergeServiceTests: XCTestCase {
    func testMergeCreatesVirtualBundleForSingleEndPhysicalInputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try makeBundle(root: root, name: "A", fastqName: "reads.fastq", contents: "@r1\nACGT\n+\nIIII\n", pairing: .singleEnd)
        let second = try makeBundle(root: root, name: "B", fastqName: "reads.fastq", contents: "@r2\nTTTT\n+\nIIII\n", pairing: .singleEnd)

        let mergedURL = try await FASTQBundleMergeService.merge(
            sourceBundleURLs: [first, second],
            outputDirectory: root,
            bundleName: "Merged Reads"
        )

        XCTAssertTrue(FASTQSourceFileManifest.exists(in: mergedURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedURL.appendingPathComponent("preview.fastq").path))

        let manifest = try XCTUnwrap(try? FASTQSourceFileManifest.load(from: mergedURL))
        XCTAssertEqual(manifest.files.count, 2)
        let resolvedFASTQs = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: mergedURL))
        XCTAssertEqual(resolvedFASTQs.count, 2)
    }

    func testMergeFallsBackToPhysicalBundleForInterleavedInputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try makeBundle(root: root, name: "A", fastqName: "reads.fastq", contents: "@r1/1\nACGT\n+\nIIII\n@r1/2\nTGCA\n+\nIIII\n", pairing: .interleaved)
        let second = try makeBundle(root: root, name: "B", fastqName: "reads.fastq", contents: "@r2/1\nCCCC\n+\nIIII\n@r2/2\nGGGG\n+\nIIII\n", pairing: .interleaved)

        let mergedURL = try await FASTQBundleMergeService.merge(
            sourceBundleURLs: [first, second],
            outputDirectory: root,
            bundleName: "Merged Interleaved"
        )

        XCTAssertFalse(FASTQSourceFileManifest.exists(in: mergedURL))
        let mergedFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: mergedURL))
        XCTAssertEqual(mergedFASTQ.lastPathComponent, "reads.fastq")
        XCTAssertEqual(FASTQMetadataStore.load(for: mergedFASTQ)?.ingestion?.pairingMode, .interleaved)
    }

    private func makeBundle(
        root: URL,
        name: String,
        fastqName: String,
        contents: String,
        pairing: IngestionMetadata.PairingMode
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent(fastqName)
        try contents.write(to: fastqURL, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: pairing)),
            for: fastqURL
        )
        return bundleURL
    }
}
```

- [x] **Step 2: Run the tests to verify the FASTQ merge service does not exist yet**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter FASTQBundleMergeServiceTests
```

Expected: FAIL with a compile error because `FASTQBundleMergeService` is undefined.

- [x] **Step 3: Implement the FASTQ merge service with virtual single-end mode and physical fallback**

```swift
// Sources/LungfishApp/Services/FASTQBundleMergeService.swift
import Foundation
import LungfishIO
import LungfishWorkflow

enum FASTQBundleMergeService {
    private enum MergeMode {
        case virtualSingleEnd
        case physical(pairing: IngestionMetadata.PairingMode)
    }

    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws -> URL {
        let mode = try determineMode(for: sourceBundleURLs)
        switch mode {
        case .virtualSingleEnd:
            return try createVirtualBundle(
                sourceBundleURLs: sourceBundleURLs,
                outputDirectory: outputDirectory,
                bundleName: bundleName
            )
        case .physical(let pairing):
            return try await createPhysicalBundle(
                sourceBundleURLs: sourceBundleURLs,
                outputDirectory: outputDirectory,
                bundleName: bundleName,
                pairing: pairing
            )
        }
    }

    private static func determineMode(for bundleURLs: [URL]) throws -> MergeMode {
        var pairings: [IngestionMetadata.PairingMode] = []

        for bundleURL in bundleURLs {
            if FASTQBundle.isDerivedBundle(bundleURL) {
                let pairing = FASTQBundle.loadDerivedManifest(in: bundleURL)?.pairingMode ?? .singleEnd
                pairings.append(pairing)
                return .physical(pairing: pairing)
            }
            if FASTQBundle.classifiedFileURLs(for: bundleURL) != nil {
                let pairing = FASTQBundle.loadDerivedManifest(in: bundleURL)?.pairingMode ?? .singleEnd
                pairings.append(pairing)
                return .physical(pairing: pairing)
            }
            guard let allURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !allURLs.isEmpty else {
                throw NSError(domain: "FASTQBundleMergeService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No FASTQ files found in \(bundleURL.lastPathComponent)"])
            }
            if allURLs.count != 1 {
                return .physical(pairing: .singleEnd)
            }
            let pairing = FASTQMetadataStore.load(for: allURLs[0])?.ingestion?.pairingMode ?? .singleEnd
            pairings.append(pairing)
        }

        if Set(pairings) == [.singleEnd] {
            return .virtualSingleEnd
        }
        return .physical(pairing: pairings.first ?? .singleEnd)
    }
}
```

```swift
private static func createVirtualBundle(
    sourceBundleURLs: [URL],
    outputDirectory: URL,
    bundleName: String
) throws -> URL {
    let fm = FileManager.default
    let bundleURL = outputDirectory.appendingPathComponent("\(bundleName.replacingOccurrences(of: " ", with: "_")).lungfishfastq", isDirectory: true)
    try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
    try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)

    var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
    for (index, sourceBundleURL) in sourceBundleURLs.enumerated() {
        guard let sourceFASTQ = FASTQBundle.resolveAllFASTQURLs(for: sourceBundleURL)?.first else {
            throw NSError(
                domain: "FASTQBundleMergeService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No FASTQ payload found in \(sourceBundleURL.lastPathComponent)"]
            )
        }
        let linkedURL = chunksDir.appendingPathComponent(String(format: "%03d-%@", index, sourceFASTQ.lastPathComponent))
        do {
            try fm.linkItem(at: sourceFASTQ, to: linkedURL)
        } catch {
            try fm.copyItem(at: sourceFASTQ, to: linkedURL)
        }
        entries.append(.init(
            filename: "chunks/\(linkedURL.lastPathComponent)",
            originalPath: sourceFASTQ.path,
            sizeBytes: (try? sourceFASTQ.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
            isSymlink: false
        ))
    }

    try FASTQSourceFileManifest(files: entries).save(to: bundleURL)
    try generatePreview(from: entries.map { bundleURL.appendingPathComponent($0.filename) }, to: bundleURL.appendingPathComponent("preview.fastq"))
    try FASTQBundleCSVMetadata.save(FASTQSampleMetadata(sampleName: bundleName).toLegacyCSV(), to: bundleURL)
    return bundleURL
}
```

```swift
private static func createPhysicalBundle(
    sourceBundleURLs: [URL],
    outputDirectory: URL,
    bundleName: String,
    pairing: IngestionMetadata.PairingMode
) async throws -> URL {
    let fm = FileManager.default
    let bundleURL = outputDirectory.appendingPathComponent("\(bundleName.replacingOccurrences(of: " ", with: "_")).lungfishfastq", isDirectory: true)
    try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let outputFASTQ = bundleURL.appendingPathComponent("reads.fastq")
    fm.createFile(atPath: outputFASTQ.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: outputFASTQ)
    defer { try? outputHandle.close() }

    for sourceBundleURL in sourceBundleURLs {
        let sourceFASTQ = try resolveBundleInputFASTQ(for: sourceBundleURL)
        let inputHandle = try FileHandle(forReadingFrom: sourceFASTQ)
        defer { try? inputHandle.close() }
        while true {
            let chunk = inputHandle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            outputHandle.write(chunk)
        }
    }

    FASTQMetadataStore.save(
        PersistedFASTQMetadata(
            ingestion: IngestionMetadata(isClumpified: false, isCompressed: false, pairingMode: pairing)
        ),
        for: outputFASTQ
    )
    _ = try await FASTQStatisticsService.computeAndCache(for: outputFASTQ)
    try FASTQBundleCSVMetadata.save(FASTQSampleMetadata(sampleName: bundleName).toLegacyCSV(), to: bundleURL)
    return bundleURL
}
```

- [x] **Step 4: Re-run the FASTQ merge tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter FASTQBundleMergeServiceTests
```

Expected: PASS with `2 tests passed`.

- [x] **Step 5: Commit the FASTQ merge checkpoint**

```bash
git add \
  Sources/LungfishApp/Services/FASTQBundleMergeService.swift \
  Tests/LungfishAppTests/FASTQBundleMergeServiceTests.swift
git commit -m "feat: add FASTQ bundle merge service"
```

## Task 3: Implement Sequence-Only Reference Bundle Merging

**Files:**
- Create: `Sources/LungfishApp/Services/ReferenceBundleMergeService.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleMergeServiceTests.swift`

- [x] **Step 1: Write the failing reference merge tests**

```swift
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class ReferenceBundleMergeServiceTests: XCTestCase {
    func testMergeCreatesSequenceOnlyBundleManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(from: fastaA, into: projectURL, displayName: "A")
        let bundleB = try ReferenceSequenceFolder.importReference(from: fastaB, into: projectURL, displayName: "B")

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged Reference"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.annotations.count, 0)
        XCTAssertEqual(manifest.variants.count, 0)
        XCTAssertEqual(manifest.tracks.count, 0)
        XCTAssertNotNil(manifest.genome)
        XCTAssertEqual(manifest.name, "Merged Reference")
    }
}
```

- [x] **Step 2: Run the tests to verify the reference merge service does not exist yet**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter ReferenceBundleMergeServiceTests
```

Expected: FAIL with a compile error because `ReferenceBundleMergeService` is undefined.

- [x] **Step 3: Implement the reference merge service using the existing reference import/build pipeline**

```swift
// Sources/LungfishApp/Services/ReferenceBundleMergeService.swift
import Foundation
import LungfishIO

enum ReferenceBundleMergeService {
    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws -> URL {
        let tempDirectory = try ProjectTempDirectory.createFromContext(prefix: "reference-merge-", contextURL: outputDirectory)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let mergedFASTA = tempDirectory.appendingPathComponent("merged.fa")
        FileManager.default.createFile(atPath: mergedFASTA.path, contents: nil)
        let handle = try FileHandle(forWritingTo: mergedFASTA)
        defer { try? handle.close() }

        for bundleURL in sourceBundleURLs {
            let fastaURL = try resolveFASTAURL(in: bundleURL)
            let data = try Data(contentsOf: fastaURL)
            handle.write(data)
            if !data.ends(with: Data("\n".utf8)) {
                handle.write(Data("\n".utf8))
            }
        }

        // TODO: merge annotations, variants, signal tracks, and alignment metadata for .lungfishref bundles.
        let result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: mergedFASTA,
            outputDirectory: outputDirectory,
            preferredBundleName: bundleName
        )
        return result.bundleURL
    }

    private static func resolveFASTAURL(in bundleURL: URL) throws -> URL {
        if let simpleFASTA = ReferenceSequenceFolder.fastaURL(in: bundleURL) {
            return simpleFASTA
        }
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(at: genomeDir, includingPropertiesForKeys: nil)
        if let fasta = contents.first(where: { name in
            let lower = name.lastPathComponent.lowercased()
            return lower.hasSuffix(".fa") || lower.hasSuffix(".fasta") || lower.hasSuffix(".fna") ||
                lower.hasSuffix(".fa.gz") || lower.hasSuffix(".fasta.gz") || lower.hasSuffix(".fna.gz")
        }) {
            return fasta
        }
        throw NSError(domain: "ReferenceBundleMergeService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No FASTA found in \(bundleURL.lastPathComponent)"])
    }
}
```

- [x] **Step 4: Re-run the reference merge tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter ReferenceBundleMergeServiceTests
```

Expected: PASS with `1 test passed`.

- [x] **Step 5: Commit the reference merge checkpoint**

```bash
git add \
  Sources/LungfishApp/Services/ReferenceBundleMergeService.swift \
  Tests/LungfishAppTests/ReferenceBundleMergeServiceTests.swift
git commit -m "feat: add reference bundle merge service"
```

## Task 4: Wire the Sidebar Action, Prompt, Refresh, and Selection

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift`

- [x] **Step 1: Write the failing sidebar action test**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class SidebarViewControllerSelectionTests: XCTestCase {
    func testSuggestedMergedBundleNameUsesFirstSelectedTitle() {
        let items = [
            SidebarItem(title: "Sample A", type: .fastqBundle, url: URL(fileURLWithPath: "/tmp/A.lungfishfastq")),
            SidebarItem(title: "Sample B", type: .fastqBundle, url: URL(fileURLWithPath: "/tmp/B.lungfishfastq")),
        ]

        XCTAssertEqual(
            SidebarViewController.suggestedMergedBundleName(for: items),
            "Sample A merged"
        )
    }
}
```

- [x] **Step 2: Run the tests to verify the naming helper does not exist yet**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter SidebarViewControllerSelectionTests
```

Expected: FAIL with a compile error because `suggestedMergedBundleName(for:)` is undefined.

- [x] **Step 3: Implement the sidebar action and post-merge selection**

```swift
// Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
static func suggestedMergedBundleName(for items: [SidebarItem]) -> String {
    let base = items.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Merged Bundle"
    return base.isEmpty ? "Merged Bundle" : "\(base) merged"
}

@objc private func contextMenuMergeIntoNewBundle(_ sender: Any?) {
    let items = selectedItems()
    guard let mergeKind = BundleMergeSelection.detectKind(for: items) else { return }
    let selectedURLs = items.compactMap(\.url)
    guard let destinationDirectory = deepestCommonParent(for: selectedURLs) else { return }

    let alert = NSAlert()
    alert.messageText = "Merge into New Bundle"
    alert.informativeText = "Enter a name for the merged bundle:"
    alert.addButton(withTitle: "Merge")
    alert.addButton(withTitle: "Cancel")

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    textField.stringValue = Self.suggestedMergedBundleName(for: items)
    alert.accessoryView = textField

    guard let window = view.window else { return }
    alert.beginSheetModal(for: window) { [weak self] response in
        guard response == .alertFirstButtonReturn else { return }
        let bundleName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleName.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let mergedURL: URL
                switch mergeKind {
                case .fastq:
                    mergedURL = try await FASTQBundleMergeService.merge(
                        sourceBundleURLs: selectedURLs,
                        outputDirectory: destinationDirectory,
                        bundleName: bundleName
                    )
                case .reference:
                    mergedURL = try await ReferenceBundleMergeService.merge(
                        sourceBundleURLs: selectedURLs,
                        outputDirectory: destinationDirectory,
                        bundleName: bundleName
                    )
                }
                self.reloadFromFilesystem()
                _ = self.selectItem(forURL: mergedURL)
            } catch {
                self.presentError(error)
            }
        }
    }
}
```

```swift
private func deepestCommonParent(for urls: [URL]) -> URL? {
    let componentLists = urls.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
    guard var shared = componentLists.first else { return nil }

    for components in componentLists.dropFirst() {
        while !shared.isEmpty && !components.starts(with: shared) {
            shared.removeLast()
        }
    }

    guard !shared.isEmpty else { return nil }
    return shared.dropFirst().reduce(URL(fileURLWithPath: "/")) { partial, component in
        partial.appendingPathComponent(component, isDirectory: true)
    }
}
```

- [x] **Step 4: Re-run the sidebar naming test**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter SidebarViewControllerSelectionTests
```

Expected: PASS with the new naming helper test and the existing symlink-selection test both passing.

- [x] **Step 5: Commit the sidebar integration checkpoint**

```bash
git add \
  Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift \
  Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift
git commit -m "feat: wire sidebar bundle merge action"
```

## Task 5: Run the Full Focused Verification Pass

**Files:**
- Modify: `docs/superpowers/plans/2026-04-22-merge-selected-bundles.md`

- [x] **Step 1: Run the focused merge-related test targets**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter BundleMergeSelectionTests
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter FASTQBundleMergeServiceTests
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter ReferenceBundleMergeServiceTests
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter SidebarViewControllerSelectionTests
```

Expected: PASS with `0 failures` across all four targeted runs.

- [x] **Step 2: Run one broader sidebar/app regression slice**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/merge-selected-bundles --filter Sidebar
```

Expected: PASS or, if unrelated failures already exist, document the exact failing tests before claiming completion.

- [x] **Step 3: Mark the final plan state and summarize any deviations**

```markdown
- [x] Task 1 complete
- [x] Task 2 complete
- [x] Task 3 complete
- [x] Task 4 complete
- [x] Task 5 complete
```

Observed deviation: a broader `swift test` run exposed an unrelated failure in
`AssemblyViewerIntegrationTests.testBlastCallbackReceivesRealFastaPayload`
(`Asynchronous wait failed: Exceeded timeout of 2 seconds, with unfulfilled expectations: "blast callback"`).
Feature-focused merge verification passed independently.

- [x] **Step 4: Commit the verified implementation state**

```bash
git add \
  Sources/LungfishApp/Services/BundleMergeSelection.swift \
  Sources/LungfishApp/Services/FASTQBundleMergeService.swift \
  Sources/LungfishApp/Services/ReferenceBundleMergeService.swift \
  Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift \
  Tests/LungfishAppTests/BundleMergeSelectionTests.swift \
  Tests/LungfishAppTests/FASTQBundleMergeServiceTests.swift \
  Tests/LungfishAppTests/ReferenceBundleMergeServiceTests.swift \
  Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift \
  docs/superpowers/plans/2026-04-22-merge-selected-bundles.md
git commit -m "feat: merge selected FASTQ and reference bundles"
```

- [x] **Step 5: Hand off to branch-finishing workflow**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: clean worktree and the final feature commit visible at `HEAD`.
```
