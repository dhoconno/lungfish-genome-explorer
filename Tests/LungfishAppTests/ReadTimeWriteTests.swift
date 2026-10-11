// ReadTimeWriteTests.swift - Opening a project and viewing a bundle write nothing the user did not ask for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane B3 (plan rows S11 and S12). The GUI walk of 2026-10-10 found three writes that
// opening a project or viewing a bundle made on their own. Opening a project wrote the search
// index record, viewing a FASTQ bundle with no cached statistics rewrote `<reads>.lungfish-meta.json`
// (a file that every recorded directory digest covers), and viewing a reference saved the viewer's
// place in `.viewstate.json`.
//
// The project cases copy a fixture project, hash every file under it with the hidden ones included,
// drive the code the sidebar and the split view run, and require that no path outside the declared
// app state changed. The viewer cases drive `ViewerViewController` directly and cover the paths that
// a window with no live Inspector never reaches, such as showing another bundle, clearing the
// display, and a save that a programmatic restore asks for.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ReadTimeWriteTests: XCTestCase {

    // MARK: - Declared app state

    /// The paths, relative to the project, that a run of the project cases may change.
    enum DeclaredAppState {
        /// Derived caches that the app builds on demand and that carry no record. The search index
        /// (plan row S12) keeps its write-ahead log beside it while it is open. The reference browser
        /// mirrors a bundle's summary when the manifest holds none.
        static let derivedCaches: Set<String> = [
            ".universal-search.db",
            ".universal-search.db-shm",
            ".universal-search.db-wal",
            ".lungfish-cache",
            ".lungfish-cache/bundle-browser.sqlite",
        ]

        /// Scratch space that the app creates on demand and empties after use, such as the FASTA
        /// preview of the FASTQ dashboard. The run requires it to hold no file at the end.
        static let scratch: Set<String> = [".tmp"]

        /// A view with no input changes no view state (plan row S11), so it declares no path. The
        /// registry names `.viewstate.json` as the app state of a reference bundle. That is what a
        /// view with input may write, and the cases below prove that no input writes none.
        static let viewStateWithNoInput: Set<String> = []

        /// Everything the whole run may change.
        static let wholeRun: Set<String> = derivedCaches.union(scratch).union(viewStateWithNoInput)
    }

    /// How long a case waits for work that is scheduled after a view, such as the 500 ms view-state
    /// debounce and the incremental search update, before it hashes the project again.
    private static let settleTime: Duration = .milliseconds(1_800)

    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "read-time-writes")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    // MARK: - Opening a project and viewing bundles

    /// Viewing a FASTQ bundle with no cached statistics computes them for the dashboard. The
    /// sidecar `<reads>.lungfish-meta.json` is covered by recorded directory digests, so the
    /// numbers stay in memory for the session and the sidecar keeps its bytes.
    func testViewingAFASTQBundleWithNoCachedStatisticsLeavesItsSidecarAndDigestAlone() async throws {
        try await requireSeqkit()
        let fixture = try makeFixtureProject()
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let sidecar = FASTQMetadataStore.metadataURL(for: fixture.fastqPayload)
        let sidecarBefore = try Data(contentsOf: sidecar)
        let digestBefore = try ProvenanceFileHasher.directoryManifest(for: fixture.fastqBundle)

        try await open(fixture.project, in: windowController)
        try await view(fixture.fastqBundle, in: windowController)
        try await Task.sleep(for: Self.settleTime)

        XCTAssertEqual(
            try Data(contentsOf: sidecar), sidecarBefore,
            "Viewing rewrote \(sidecar.lastPathComponent), which every recorded digest of the bundle covers."
        )
        XCTAssertEqual(try ProvenanceFileHasher.directoryManifest(for: fixture.fastqBundle), digestBefore)
        let dashboard = try XCTUnwrap(windowController.mainSplitViewController.viewerController.fastqDatasetController)
        XCTAssertGreaterThan(dashboard.testingSummaryCardCount, 0, "The dashboard still shows the computed statistics.")
        withExtendedLifetime(delegate) {}
    }

    /// The statistics of a dataset that was viewed stay in memory, so viewing it again in the same
    /// session computes nothing new and still writes nothing.
    func testViewingTheSameFASTQBundleAgainReusesTheStatisticsFromThisSession() async throws {
        try await requireSeqkit()
        let fixture = try makeFixtureProject()
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let split = windowController.mainSplitViewController!
        try await open(fixture.project, in: windowController)
        try await view(fixture.fastqBundle, in: windowController)
        try await view(fixture.reference, in: windowController)
        let before = try ProjectDigest(of: fixture.project)

        let item = try XCTUnwrap(Self.find(fixture.fastqBundle, in: split.sidebarController.rootItems))
        split.displayContent(for: item)

        XCTAssertNil(
            FASTQMetadataStore.load(for: fixture.fastqPayload)?.computedStatistics,
            "The sidecar still holds no statistics, so the reuse below comes from memory."
        )
        XCTAssertNil(split.fastqLoadTask, "The statistics of the first view are reused, so no computation starts.")
        let dashboard = try XCTUnwrap(split.viewerController.fastqDatasetController)
        XCTAssertGreaterThan(dashboard.testingSummaryCardCount, 0)
        try await Task.sleep(for: Self.settleTime)
        let sidecar = Self.relativePath(of: FASTQMetadataStore.metadataURL(for: fixture.fastqPayload), in: fixture.project)
        XCTAssertEqual(try ProjectDigest(of: fixture.project).entries[sidecar], before.entries[sidecar])
        withExtendedLifetime(delegate) {}
    }

    /// The search index is a derived cache (plan row S12). Opening a project builds it and
    /// leaves no provenance record beside it.
    func testOpeningAProjectBuildsTheSearchIndexAndWritesNoRecordForIt() async throws {
        let fixture = try makeFixtureProject()
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let before = try ProjectDigest(of: fixture.project)

        try await open(fixture.project, in: windowController)
        try await Task.sleep(for: Self.settleTime)

        let after = try ProjectDigest(of: fixture.project)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".universal-search.db").path),
            "Opening a project builds the search index."
        )
        let record = ".universal-search.db.lungfish-provenance.json"
        XCTAssertNil(after.entries[record], "Opening a project wrote the search index record \(record).")
        XCTAssertEqual(
            after.differences(from: before).filter { !DeclaredAppState.derivedCaches.contains($0.path) }.map(\.summary),
            [],
            "Opening changed paths outside the derived caches."
        )
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Window and project

    private func makeMainWindowAndDelegate() throws -> (MainWindowController, AppDelegate) {
        let delegate = AppDelegate()
        let directory = scratch.appendingPathComponent("window-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: directory.appendingPathComponent("windows.json"))

        let windowController = delegate.createAndShowMainWindow()
        // Layout runs the same off screen, and an ordered-out window keeps the display link
        // from redrawing the viewer while the test waits.
        windowController.window?.orderOut(nil)
        addTeardownBlock {
            windowController.mainSplitViewController.sidebarController.closeProject()
            windowController.close()
        }
        return (windowController, delegate)
    }

    /// Opens the project the way the sidebar does for a project folder, which scans it and
    /// schedules the search index.
    private func open(_ project: URL, in windowController: MainWindowController) async throws {
        windowController.mainSplitViewController.sidebarController.openProject(at: project)
        let indexed = await waitUntil(timeout: .seconds(60)) {
            let stats = try? await UniversalProjectSearchService.shared.indexStats(projectURL: project)
            return (stats?.entityCount ?? 0) > 0
        }
        XCTAssertTrue(indexed, "The search index was not built after opening \(project.lastPathComponent).")
    }

    /// Views a bundle through the router that a sidebar selection reaches, once the sidebar has
    /// scanned the row, and waits until the bundle is on screen.
    private func view(_ bundle: URL, in windowController: MainWindowController) async throws {
        let split = windowController.mainSplitViewController!
        let item = try XCTUnwrap(
            Self.find(bundle, in: split.sidebarController.rootItems),
            "The sidebar scan has no row for \(bundle.lastPathComponent)."
        )
        split.displayContent(for: item)
        let shown = await waitUntil(timeout: .seconds(60)) {
            switch item.type {
            case .referenceBundle:
                return split.viewerController.referenceBundleViewportController?
                    .testEmbeddedViewerController.currentBundleURL?.resolvingSymlinksInPath()
                    == bundle.resolvingSymlinksInPath()
            case .multipleSequenceAlignmentBundle:
                return split.viewerController.multipleSequenceAlignmentViewController != nil
            case .phylogeneticTreeBundle:
                return split.viewerController.phylogeneticTreeViewController != nil
            default:
                return split.fastqLoadTask == nil && split.viewerController.fastqDatasetController != nil
            }
        }
        XCTAssertTrue(shown, "\(bundle.lastPathComponent) was not displayed.")
        // Let the display's own follow-up work run before the next view.
        try await Task.sleep(for: .milliseconds(300))
    }

    private static func find(_ url: URL, in items: [SidebarItem]) -> SidebarItem? {
        for item in items {
            if item.url?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() { return item }
            if let match = find(url, in: item.children) { return match }
        }
        return nil
    }

    private static func relativePath(of url: URL, in project: URL) -> String {
        let root = project.resolvingSymlinksInPath().pathComponents
        return url.resolvingSymlinksInPath().pathComponents.dropFirst(root.count).joined(separator: "/")
    }

    private func requireSeqkit() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed (the dashboard statistics are computed with it)")
        }
    }

    // MARK: - Fixture project

    private struct FixtureProject {
        let project: URL
        let reference: URL
        let secondReference: URL
        let alignment: URL
        let tree: URL
        let fastqBundle: URL
        let fastqPayload: URL
    }

    /// A project folder with two committed reference bundles, a committed alignment bundle, a tree
    /// bundle made by the importer the app uses, and a FASTQ bundle whose sidecar holds metadata but
    /// no statistics, as every demo FASTQ bundle does.
    private func makeFixtureProject() throws -> FixtureProject {
        let project = scratch.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let referenceFolder = project.appendingPathComponent("Reference Sequences", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
        let reference = referenceFolder.appendingPathComponent("TestGenome.lungfishref", isDirectory: true)
        let secondReference = referenceFolder.appendingPathComponent("HepatitisB.lungfishref", isDirectory: true)
        try FileManager.default.copyItem(at: Self.testData("TestGenome.lungfishref"), to: reference)
        try FileManager.default.copyItem(at: Self.testData("HepatitisB.lungfishref"), to: secondReference)

        let alignmentFolder = project.appendingPathComponent("Analyses/Multiple Sequence Alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentFolder, withIntermediateDirectories: true)
        let alignment = alignmentFolder.appendingPathComponent("sars-cov-2-genomes-mafft.lungfishmsa", isDirectory: true)
        try FileManager.default.copyItem(at: Self.alignmentFixture(), to: alignment)

        let newick = scratch.appendingPathComponent("fixture-tree.nwk")
        try "((A:0.1,B:0.2)90:0.3,(C:0.2,D:0.1)80:0.4);\n".write(to: newick, atomically: true, encoding: .utf8)
        let treeFolder = project.appendingPathComponent("Phylogenetic Trees", isDirectory: true)
        try FileManager.default.createDirectory(at: treeFolder, withIntermediateDirectories: true)
        let tree = treeFolder.appendingPathComponent("fixture-tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: tree)

        let fastqBundle = project.appendingPathComponent("Downloads/NoStatistics.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: fastqBundle, withIntermediateDirectories: true)
        let payload = fastqBundle.appendingPathComponent("reads.fastq")
        try """
        @read1
        ACGTACGTAC
        +
        IIIIIIIIII
        @read2
        ACGTACGTACGT
        +
        IIIIIIIIIIII
        @read3
        ACGTAC
        +
        IIIIII
        @read4
        ACGTACGTACGTAC
        +
        IIIIIIIIIIIIII

        """.write(to: payload, atomically: true, encoding: .utf8)
        try FASTQMetadataStore.write(
            PersistedFASTQMetadata(downloadDate: Date(timeIntervalSince1970: 1_790_000_000), downloadSource: "read-time-write fixture"),
            for: payload
        )
        return FixtureProject(
            project: project,
            reference: reference,
            secondReference: secondReference,
            alignment: alignment,
            tree: tree,
            fastqBundle: fastqBundle,
            fastqPayload: payload
        )
    }

    /// The checkout root, resolved from this file's path.
    private static var checkoutRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LungfishAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // checkout
    }

    private static func testData(_ name: String) -> URL {
        checkoutRoot.appendingPathComponent("TestData", isDirectory: true).appendingPathComponent(name)
    }

    private static func alignmentFixture() -> URL {
        checkoutRoot.appendingPathComponent(
            "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa",
            isDirectory: true
        )
    }
}

// MARK: - Project digest

/// Every entry under a folder, hidden ones included, with the SHA-256 and the modification date of
/// each regular file. A rewrite that keeps the bytes still shows through the date.
struct ProjectDigest {
    enum Entry: Equatable {
        case file(sha256: String, modified: Date)
        case directory
        case symlink(String)
    }

    struct Difference {
        let path: String
        let summary: String
    }

    let entries: [String: Entry]

    init(of root: URL) throws {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var found: [String: Entry] = [:]
        for case let relative as String in walker {
            let url = root.appendingPathComponent(relative)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                found[relative] = .symlink(try fileManager.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory:
                found[relative] = .directory
            case .typeRegular:
                found[relative] = .file(
                    sha256: try ProvenanceFileHasher.sha256(of: url),
                    modified: attributes[.modificationDate] as? Date ?? .distantPast
                )
            default:
                break
            }
        }
        entries = found
    }

    /// What differs from `earlier`, in path order.
    func differences(from earlier: ProjectDigest) -> [Difference] {
        var report: [Difference] = []
        for path in Set(entries.keys).union(earlier.entries.keys).sorted() {
            switch (earlier.entries[path], entries[path]) {
            case (nil, _?):
                report.append(Difference(path: path, summary: "added \(path)"))
            case (_?, nil):
                report.append(Difference(path: path, summary: "removed \(path)"))
            case (.file(let oldHash, _)?, .file(let newHash, _)?) where oldHash != newHash:
                report.append(Difference(path: path, summary: "rewrote \(path)"))
            case (let old?, let new?) where old != new:
                report.append(Difference(path: path, summary: "touched \(path)"))
            default:
                break
            }
        }
        return report
    }
}
