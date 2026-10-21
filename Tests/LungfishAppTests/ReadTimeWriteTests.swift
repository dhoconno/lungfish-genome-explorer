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
@testable import LungfishOperations
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

    /// The plan's acceptance case. Open the project, then view two reference bundles, a multiple
    /// sequence alignment, a tree and a FASTQ bundle that has no cached statistics, all through the
    /// code the sidebar and the split view run. No byte outside the declared app state may change.
    /// The alignment and the tree keep the `.viewstate.json` that their creation wrote, because
    /// their manifests checksum it, and nothing may touch it.
    func testOpeningAProjectAndViewingABundleOfEachKindChangesNoByteOutsideDeclaredAppState() async throws {
        try await requireSeqkit()
        let fixture = try makeFixtureProject()
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let before = try ProjectDigest(of: fixture.project)
        let fastqDigestBefore = try ProvenanceFileHasher.directoryManifest(for: fixture.fastqBundle)

        try await open(fixture.project, in: windowController)
        try await view(fixture.reference, in: windowController)
        try await view(fixture.secondReference, in: windowController)
        try await view(fixture.alignment, in: windowController)
        try await view(fixture.tree, in: windowController)
        try await view(fixture.fastqBundle, in: windowController)
        try await Task.sleep(for: Self.settleTime)

        let after = try ProjectDigest(of: fixture.project)
        let changes = after.differences(from: before)
        XCTAssertEqual(
            changes.filter { !DeclaredAppState.wholeRun.contains($0.path) }.map(\.summary), [],
            "Opening and viewing changed paths outside the declared app state \(DeclaredAppState.wholeRun.sorted())."
        )
        XCTAssertEqual(
            after.entries.keys.filter { $0.hasPrefix(".tmp/") }.sorted(), [],
            "A view left a file in the project scratch folder."
        )
        // The registry names the files of a bundle that hold app state. A view with no input changes none of
        // them, and `.viewstate.json` stays as the creation wrote it, or absent, in every kind.
        for bundle in [fixture.reference, fixture.secondReference, fixture.alignment, fixture.tree] {
            let declared = BundleKindRegistry.descriptor(forLowercasedExtensionOf: bundle)?.appStateFileNames ?? []
            for name in Set(declared).union([BundleViewState.filename]) {
                let path = Self.relativePath(of: bundle.appendingPathComponent(name), in: fixture.project)
                XCTAssertEqual(
                    before.entries[path], after.entries[path],
                    "Viewing \(bundle.lastPathComponent) with no input changed its \(name)."
                )
            }
        }
        XCTAssertEqual(
            try ProvenanceFileHasher.directoryManifest(for: fixture.fastqBundle), fastqDigestBefore,
            "A record that covers the FASTQ bundle by directory digest no longer verifies."
        )
        withExtendedLifetime(delegate) {}
    }

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

    /// A payload that is a link to reads kept elsewhere changes when its target does, and the link
    /// itself keeps its size and date. The statistics held in memory belong to the target, so the
    /// next view computes them again.
    func testViewingAgainComputesStatisticsAgainWhenTheTargetOfALinkedPayloadChanged() async throws {
        try await requireSeqkit()
        let fixture = try makeFixtureProject()
        let target = scratch.appendingPathComponent("linked-reads.fastq")
        try FileManager.default.moveItem(at: fixture.fastqPayload, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.fastqPayload, withDestinationURL: target)
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let split = windowController.mainSplitViewController!
        try await open(fixture.project, in: windowController)
        try await view(fixture.fastqBundle, in: windowController)

        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("@read5\nACGTACGT\n+\nIIIIIIII\n".utf8))
        try handle.close()
        let item = try XCTUnwrap(Self.find(fixture.fastqBundle, in: split.sidebarController.rootItems))
        split.displayContent(for: item)

        XCTAssertNotNil(split.fastqLoadTask, "The target of the link gained a read, so the statistics are computed again.")
        let finished = await waitUntil(budget: .lookup) { split.fastqLoadTask == nil }
        XCTAssertTrue(finished, "The second computation did not finish.")
        withExtendedLifetime(delegate) {}
    }

    /// A payload replaced by a copy of the same size that kept the old date is a different file. Its
    /// inode and change date differ, so the statistics held in memory no longer apply.
    func testViewingAgainComputesStatisticsAgainWhenASameSizeCopyKeptTheDate() async throws {
        try await requireSeqkit()
        let fixture = try makeFixtureProject()
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let split = windowController.mainSplitViewController!
        try await open(fixture.project, in: windowController)
        try await view(fixture.fastqBundle, in: windowController)

        var originalInfo = stat()
        XCTAssertEqual(stat(fixture.fastqPayload.path, &originalInfo), 0)
        let copy = scratch.appendingPathComponent("same-size-reads.fastq")
        let original = try String(contentsOf: fixture.fastqPayload, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "ACGTACGTAC\n", with: "TGCATGCATG\n")
        XCTAssertEqual(changed.utf8.count, original.utf8.count)
        XCTAssertNotEqual(changed, original)
        try changed.write(to: copy, atomically: true, encoding: .utf8)
        // `cp -p` and `touch -r` keep the date to the nanosecond, which `setAttributes` does not.
        var keptTimes = [originalInfo.st_atimespec, originalInfo.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, copy.path, &keptTimes, 0), 0)
        try FileManager.default.removeItem(at: fixture.fastqPayload)
        try FileManager.default.moveItem(at: copy, to: fixture.fastqPayload)
        let item = try XCTUnwrap(Self.find(fixture.fastqBundle, in: split.sidebarController.rootItems))
        split.displayContent(for: item)

        XCTAssertNotNil(split.fastqLoadTask, "The payload is a different file of the same size and date, so the statistics are computed again.")
        let finished = await waitUntil(budget: .lookup) { split.fastqLoadTask == nil }
        XCTAssertTrue(finished, "The second computation did not finish.")
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

    // MARK: - The viewer and its view state

    /// Showing another bundle and clearing the display used to save the previous bundle's view
    /// state whether or not anyone had touched it. The embedded reference viewer does both when it
    /// shows a bundle again.
    func testShowingAnotherBundleAndClearingTheDisplayWriteNoViewStateWhenNothingChanged() async throws {
        let (first, second) = try makeTwoReferences()
        let viewer = makeViewer()

        try viewer.displayBundle(at: first.url, mode: .sequence(name: first.firstSequence, restoreViewState: false))
        viewer.clearViewport(statusMessage: "Loading reference viewer...")
        try viewer.displayBundle(at: second.url, mode: .sequence(name: second.firstSequence, restoreViewState: false))
        try viewer.displayBundle(at: first.url, mode: .sequence(name: first.firstSequence, restoreViewState: true))
        viewer.clearBundleDisplay()
        try await Task.sleep(for: Self.settleTime)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.url.appendingPathComponent(BundleViewState.filename).path),
            "Showing and leaving \(first.url.lastPathComponent) with no input wrote its \(BundleViewState.filename)."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: second.url.appendingPathComponent(BundleViewState.filename).path),
            "Showing and leaving \(second.url.lastPathComponent) with no input wrote its \(BundleViewState.filename)."
        )
    }

    /// A save that a programmatic restore asks for carries the values that were just restored. The
    /// Inspector does this when it takes the restored settings, because its controls report a change
    /// whether a person or the restore made it. That save must not reach the file. This one is
    /// marked while the restore still runs, as the Inspector's first report is.
    func testASaveMarkedWhileTheRestoreRunsWritesNothing() async throws {
        let (first, _) = try makeTwoReferences()
        let viewer = makeViewer()
        try viewer.displayBundle(at: first.url, mode: .sequence(name: first.firstSequence, restoreViewState: false))

        viewer.scheduleViewStateSave()
        try await Task.sleep(for: Self.settleTime)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.url.appendingPathComponent(BundleViewState.filename).path),
            "A save marked while the restore ran wrote \(BundleViewState.filename)."
        )
    }

    /// The same echo can arrive after the restore has settled, 100 ms after the display. It carries
    /// the restored values, so it equals the restored state and writes nothing.
    func testASaveThatCarriesTheRestoredValuesAfterTheRestoreWritesNothing() async throws {
        let (first, _) = try makeTwoReferences()
        let viewer = makeViewer()
        try viewer.displayBundle(at: first.url, mode: .sequence(name: first.firstSequence, restoreViewState: false))
        try await Task.sleep(for: .milliseconds(400))

        viewer.scheduleViewStateSave()
        try await Task.sleep(for: Self.settleTime)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.url.appendingPathComponent(BundleViewState.filename).path),
            "A save that only repeated the restored values wrote \(BundleViewState.filename)."
        )
    }

    /// A change that a person makes is still saved, by the debounce and when the viewer leaves
    /// the bundle, and a later save that repeats it writes nothing more.
    func testAUserChangeIsSavedByTheDebounceAndByLeavingTheBundle() async throws {
        let (first, second) = try makeTwoReferences()
        let viewer = makeViewer()
        let viewStateURL = first.url.appendingPathComponent(BundleViewState.filename)
        try viewer.displayBundle(at: first.url, mode: .sequence(name: first.firstSequence, restoreViewState: false))
        try await Task.sleep(for: .milliseconds(400))
        let restoredScale = try XCTUnwrap(viewer.referenceFrame?.scale)

        viewer.zoomIn() // a user event handler, which marks the state changed
        try await Task.sleep(for: Self.settleTime)

        let saved = BundleViewState.load(from: first.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewStateURL.path), "The debounce did not save a zoom.")
        XCTAssertLessThan(try XCTUnwrap(saved.lastScale), restoredScale, "The saved scale is the zoomed one.")
        let writtenBytes = try Data(contentsOf: viewStateURL)
        let writtenDate = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: viewStateURL.path)[.modificationDate] as? Date
        )

        viewer.scheduleViewStateSave() // nothing new since the save
        try await Task.sleep(for: Self.settleTime)
        XCTAssertEqual(try Data(contentsOf: viewStateURL), writtenBytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: viewStateURL.path)[.modificationDate] as? Date, writtenDate,
            "A save that repeated what was already saved rewrote the file."
        )

        // A change made just before the viewer leaves, inside the debounce, is flushed on the way out.
        viewer.zoomOut()
        try viewer.displayBundle(at: second.url, mode: .sequence(name: second.firstSequence, restoreViewState: false))
        let flushed = BundleViewState.load(from: first.url)
        XCTAssertGreaterThan(try XCTUnwrap(flushed.lastScale), try XCTUnwrap(saved.lastScale), "Leaving flushed the zoom out.")
    }

    /// Adding or removing an annotation track shows the same bundle again. A change that a person made
    /// just before is still pending then, and the settle that follows the new display must not drop it.
    func testAUserChangeBeforeTheAnnotationTrackReloadIsSaved() async throws {
        let (first, _) = try makeTwoReferences()
        let viewer = makeViewer()
        try viewer.displayBundle(at: first.url, mode: .sequence(name: first.firstSequence, restoreViewState: false))
        try await Task.sleep(for: .milliseconds(400))
        let restoredScale = try XCTUnwrap(viewer.referenceFrame?.scale)

        viewer.zoomIn() // marks the state changed, and the debounce has not run
        try viewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: first.url)
        try await Task.sleep(for: Self.settleTime)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: first.url.appendingPathComponent(BundleViewState.filename).path),
            "The reload dropped the zoom that was pending when it began."
        )
        XCTAssertLessThan(try XCTUnwrap(BundleViewState.load(from: first.url).lastScale), restoredScale, "The saved scale is the zoomed one.")
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
        let indexed = await waitUntil(budget: .lookup) {
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
        let shown = await waitUntil(budget: .lookup) {
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

    // MARK: - Viewer fixtures

    private struct ReferenceFixture {
        let url: URL
        let firstSequence: String
    }

    private func makeViewer() -> ViewerViewController {
        let viewer = ViewerViewController()
        _ = viewer.view
        return viewer
    }

    /// Two copies of the committed reference bundles under a scratch folder.
    private func makeTwoReferences() throws -> (ReferenceFixture, ReferenceFixture) {
        let folder = scratch.appendingPathComponent("references-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func copy(_ name: String) throws -> ReferenceFixture {
            let destination = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: Self.testData(name), to: destination)
            let manifest = try BundleManifest.load(from: destination)
            return ReferenceFixture(url: destination, firstSequence: try XCTUnwrap(manifest.genome?.chromosomes.first?.name))
        }
        return (try copy("TestGenome.lungfishref"), try copy("HepatitisB.lungfishref"))
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
