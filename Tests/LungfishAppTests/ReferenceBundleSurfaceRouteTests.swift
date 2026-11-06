// ReferenceBundleSurfaceRouteTests.swift - The reference bundle and the mapping result on one route, and every way out (Phase 3.2 lane REFMAP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A mapping result and a `.lungfishref` share one display, one class and one loading state, and a person's mapping result
// reaches the viewer through `displayMappingAnalysisFromSidebar`, the one mapping route since 3.2 deleted
// `displayMappingResult`. So every test of what a person sees goes through the sidebar's routes. These tests read what a slip
// would change: whose BAM, rows and bundle are on screen, the numbers, and what a removed viewport may still do.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

/// What a bundle file that does not read says.
private struct DamagedBundleFile: LocalizedError {
    var errorDescription: String? { "manifest.json ends in the middle of a record" }
}

/// A surface whose load fails, so the viewport's show never installs.
@MainActor
private final class RefusingReferenceSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(.reference) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedBundleFile()
    }
}

/// Counts the summary builds a viewport starts, and holds one open until a test lets it go.
private final class SummaryBuilderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0
    private var cancellation: Bool?

    var calls: Int { lock.withLock { callCount } }
    /// Whether the held build saw its task cancelled when it was let go, nil until then.
    var sawCancellation: Bool? { lock.withLock { cancellation } }

    func count() {
        lock.withLock { callCount += 1 }
    }

    func hold() async {
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            lock.withLock {
                callCount += 1
                continuation = waiting
            }
        }
        let cancelled = Task.isCancelled
        lock.withLock { cancellation = cancelled }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            let held = continuation
            continuation = nil
            return held
        }
        waiting?.resume()
    }
}

/// A mapping result with a folder, a viewer bundle, a contig and numbers of its own.
struct MappingFixture {
    let result: URL
    let bundle: URL
    let bam: URL
    let trackBAM: URL
    let rows: [MappingContigSummary]
}

@MainActor
final class ReferenceBundleSurfaceRouteTests: XCTestCase {
    var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ReferenceSurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface

    func testTheSurfaceAdoptsTheControllerAndConfiguresNothing() throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        let controller = ReferenceBundleViewportController()

        let surface = try viewer.showSurface(.bundle(.reference), input: controller, as: ReferenceBundleSurface.self)

        XCTAssertEqual(surface.surfaceKind, .bundle(.reference))
        XCTAssertTrue(surface.viewController === controller)
        XCTAssertTrue(viewer.referenceBundleViewportController === controller)
        XCTAssertTrue(controller.parent === viewer)
        XCTAssertTrue(controller.view.superview === viewer.view)
        XCTAssertNil(controller.currentInput, "the load configured the viewport before the install ended")
        XCTAssertThrowsError(try viewer.showSurface(.bundle(.reference), input: "not a viewport", as: ReferenceBundleSurface.self))
    }

    // MARK: - One document at a time

    /// The landing that would be an S1: a stale track or another bundle's reads on the screen of the second result.
    func testTheSecondMappingResultShowsOnlyItsOwnBAMAndRows() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let second = try makeMapping("B", contig: "chrB", readsOnContig: 7)

        for mapping in [first, second, first] {
            harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
            try await assertShows(mapping, in: viewer)
        }
    }

    func testAReferenceThenAMappingResultAndBackTakesTheFilterAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let reference = try makeReference("Filtered")
        let mapping = try makeMapping("B", contig: "chrB", readsOnContig: 7)

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await assertShowsReference(reference, in: viewer)
        let filtered = try XCTUnwrap(viewer.referenceBundleViewportController)
        filtered.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.selectedReadGroups: Set(["S1-rg"])])
        XCTAssertEqual(filtered.testSelectedReadGroups, ["S1-rg"], "the filter never reached the first viewer")

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        XCTAssertEqual(viewer.referenceBundleViewportController?.testSelectedReadGroups, [], "the mapping result took the reference's filter")

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await assertShowsReference(reference, in: viewer)
        XCTAssertEqual(viewer.referenceBundleViewportController?.testSelectedReadGroups, [], "the reference came back with its old filter")
    }

    /// `MappingResultViewController` is a `ReferenceBundleViewportController`, so a plain cast would answer both slots and
    /// every reader of the reference slot would see the dead route's class. The live route must never build that class.
    func testTheMappingClassDoesNotAnswerTheReferenceSlot() async throws {
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        XCTAssertTrue(type(of: viewport) == ReferenceBundleViewportController.self, "the sidebar's route built \(type(of: viewport))")
        XCTAssertTrue(viewer.activeMappingViewportController === viewport)
    }

    /// Call Variants and the VCF import find a mapping result's reference copy through the reference viewport the
    /// sidebar's route installs, so they need no slot of the dead route's class.
    func testTheReferenceResolverFindsTheMappingResultThroughTheReferenceViewport() async throws {
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        let resolved = AppDelegate().currentReferenceBundleURL(for: viewer)
        XCTAssertEqual(resolved?.standardizedFileURL, mapping.bundle.standardizedFileURL, "Call Variants would act on another bundle")
    }

    // MARK: - The numbers

    /// The summary bar and each contig row of a result the viewport does not measure, as literals read at the base. A real
    /// BAM's measured row is in `ReferenceBundleNumbersConformanceTests`.
    func testTheNumbersOfTheFixtureAreWhatTheViewportShows() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)

        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        XCTAssertEqual(viewport.testSummaryText, "minimap2 Mapping — 9 / 10 reads mapped (90.0%)")
        let row = try XCTUnwrap(viewport.testContigTableView.displayedRows.first)
        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 1)
        XCTAssertEqual(row.contigName, "chrA")
        XCTAssertEqual(row.contigLength, 100)
        XCTAssertEqual(row.mappedReads, 9)
        XCTAssertEqual(row.mappedReadPercent, 90, accuracy: 0.0001)
        XCTAssertEqual(row.meanDepth, 3.5, accuracy: 0.0001)
        XCTAssertEqual(row.coverageBreadth, 0.8, accuracy: 0.0001)
        XCTAssertEqual(row.medianMAPQ, 60, accuracy: 0.0001)
        XCTAssertEqual(row.meanIdentity, 0.99, accuracy: 0.0001)
    }

    // MARK: - The same input again, and the placeholder

    func testAnUnchangedReferenceKeepsFocusRowRegionAndDrawer() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let reference = try makeReference("Kept", chromosomes: ["chr1", "chr2"])

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await assertShowsReference(reference, in: viewer, sequences: ["chr1", "chr2"])
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        viewport.testSelectSequence(named: "chr2")
        viewport.testEnterFocusedDetailMode()
        viewer.toggleAnnotationDrawer()
        // A person's zoom. A reset could write these fields in place, so they compare by value, not by object.
        let region = try XCTUnwrap(viewport.activeSequenceViewerController.referenceFrame)
        region.start = 20
        region.end = 60

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await harness.split.bundleOpenTask?.value

        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "the same input rebuilt the viewport")
        XCTAssertEqual(viewport.testSelectedSequenceName, "chr2", "the row was lost")
        XCTAssertTrue(viewport.testIsFocusedDetailMode, "focus mode was lost")
        let shown = try XCTUnwrap(viewport.activeSequenceViewerController.referenceFrame)
        XCTAssertEqual(shown.start, 20, "the zoom was lost")
        XCTAssertEqual(shown.end, 60, "the zoom was lost")
        XCTAssertTrue(viewer.isActiveDrawerOpen, "the drawer closed")
    }

    func testAnUnchangedMappingResultKeepsFocusRowAndDrawer() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9, otherContigs: ["chrB"])

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        // The second row, since a reset lands on the first.
        viewport.testSelectContig(named: "chrB")
        await viewport.testAwaitAlignmentActionContext()
        XCTAssertEqual(viewport.testSelectedContigName, "chrB", "the second row never took the selection")
        viewport.testEnterFocusedDetailMode()
        viewer.toggleAnnotationDrawer()
        let region = try XCTUnwrap(viewport.activeSequenceViewerController.referenceFrame)
        region.start = 20
        region.end = 60

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        await harness.split.bundleOpenTask?.value

        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "the same input rebuilt the viewport")
        XCTAssertEqual(viewport.testSelectedContigName, "chrB", "the row was lost")
        let shown = try XCTUnwrap(viewport.activeSequenceViewerController.referenceFrame)
        XCTAssertEqual(shown.start, 20, "the zoom was lost")
        XCTAssertEqual(shown.end, 60, "the zoom was lost")
        XCTAssertTrue(viewport.testIsFocusedDetailMode, "focus mode was lost")
        XCTAssertTrue(viewer.isActiveDrawerOpen, "the drawer closed")
    }

    /// `viewerAwaitsBundleOpen` is the only thing that stops a decoded open landing on what replaced its placeholder.
    func testAFilledPlaceholderIsTheSameViewportAndADecodedOpenDoesNotLandAfterAnotherKind() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try makeReference("Filled")
        let second = try makeReference("Dropped")
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let fastq = try await buildRow(of: "FASTQ", under: root)

        harness.split.displayReferenceBundleViewportFromSidebar(at: first)
        let placeholder = try XCTUnwrap(viewer.referenceBundleViewportController)
        XCTAssertTrue(placeholder.isAwaitingOpenInput, "the route showed no loading state")
        await harness.split.bundleOpenTask?.value
        XCTAssertTrue(viewer.referenceBundleViewportController === placeholder, "the placeholder was not filled in place")
        XCTAssertFalse(placeholder.isAwaitingOpenInput)
        XCTAssertEqual(placeholder.testDisplayedSequenceNames, ["chr1"])

        // A route that starts no display request, so only the viewer's own check can stop the open.
        harness.split.displayReferenceBundleViewportFromSidebar(at: second)
        let dropped = harness.split.bundleOpenTask
        viewer.clearViewport()
        await dropped?.value
        XCTAssertNil(viewer.referenceBundleViewportController, "a decoded open landed after the viewer cleared")
        XCTAssertEqual(viewer.contentMode, .empty)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        let droppedMapping = harness.split.bundleOpenTask
        harness.select(fastq)
        await droppedMapping?.value
        let replaced = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(replaced, "the FASTQ dashboard never replaced the mapping's placeholder")
        XCTAssertNil(viewer.referenceBundleViewportController, "a decoded open landed after another kind")
    }

    // MARK: - The drawer

    func testShowDrawerReachesTheEmbeddedDrawerOfAReferenceAndOfAMappingResult() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let reference = try makeReference("Drawn")
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await assertShowsReference(reference, in: viewer)
        try assertTheDrawerIsTheViewports(in: viewer, showing: "a reference")

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        try assertTheDrawerIsTheViewports(in: viewer, showing: "a mapping result")
    }

    func testMakeDrawerTallerReachesTheEmbeddedDrawer() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        let embedded = try XCTUnwrap(viewer.referenceBundleViewportController).activeSequenceViewerController
        // The drag handle saves the height a person chose, so it saves in a suite of the test's, as `AnnotationDrawerSizingTests` does.
        embedded.annotationDrawerDefaults = makeTestDefaultsSuite(prefix: "ReferenceBundleSurfaceRouteTests").defaults
        viewer.toggleAnnotationDrawer()
        let before = try XCTUnwrap(embedded.annotationDrawerHeightConstraint?.constant, "the drawer did not open in the embedded viewer")

        harness.controller.makeDrawerTaller(nil)

        let after = try XCTUnwrap(embedded.annotationDrawerHeightConstraint?.constant)
        XCTAssertGreaterThan(after, before, "Make Drawer Taller did not reach the embedded drawer")
        XCTAssertNil(viewer.annotationDrawerView, "Make Drawer Taller made an empty drawer under the viewport")
    }

    func testTheDrawerGoesWithTheViewportOnEveryWayOut() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let second = try makeMapping("B", contig: "chrB", readsOnContig: 7)
        let fastq = try await buildRow(of: "FASTQ", under: root)

        harness.split.displayMappingAnalysisFromSidebar(at: first.result)
        try await assertShows(first, in: viewer)
        viewer.toggleAnnotationDrawer()
        XCTAssertTrue(viewer.isActiveDrawerOpen)

        harness.select(fastq)
        let left = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(left, "the FASTQ dashboard never replaced the viewport")
        XCTAssertFalse(viewer.isActiveDrawerOpen, "the viewport's drawer stayed open under another kind")

        harness.split.displayMappingAnalysisFromSidebar(at: first.result)
        try await assertShows(first, in: viewer)
        XCTAssertFalse(viewer.isActiveDrawerOpen, "the viewport came back with its old drawer open")

        viewer.toggleAnnotationDrawer()
        harness.split.displayMappingAnalysisFromSidebar(at: second.result)
        try await assertShows(second, in: viewer)
        XCTAssertFalse(viewer.isActiveDrawerOpen, "the second result took the first one's drawer")

        viewer.toggleAnnotationDrawer()
        viewer.clearViewport()
        XCTAssertFalse(viewer.isActiveDrawerOpen, "the drawer stayed open with nothing shown")
    }

    func testReferenceContentStartsBelowTheToolbar() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)

        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        viewport.view.layoutSubtreeIfNeeded()
        let safeTop = viewport.view.convert(viewport.view.safeAreaRect, to: nil).maxY
        let summaryTop = viewport.summaryLabel.convert(viewport.summaryLabel.bounds, to: nil).maxY
        XCTAssertLessThanOrEqual(summaryTop, safeTop + 0.5, "the summary bar runs under the toolbar")
    }

    // MARK: - A removed viewport

    /// A refresh runs samtools children for as long as it lasts, so a removal stops it, and what it finds writes nothing.
    func testARefreshThatEndsAfterTheViewerLeftWritesNothing() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9, secondTrack: true)
        let fastq = try await buildRow(of: "FASTQ", under: root)
        let builds = SummaryBuilderLog()
        defer { builds.release() }
        let late = MappingContigSummary(
            contigName: "chrA", contigLength: 100, mappedReads: 777_777, mappedReadPercent: 100,
            meanDepth: 1, coverageBreadth: 1, medianMAPQ: 60, meanIdentity: 1
        )

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        // An open refreshes more than once, and each refresh cancels the one before it, so this one starts after the open
        // ended, and only the removal can cancel it.
        viewport.setAlignmentTrackSummaryBuilderForTesting { _, _, _ in
            await builds.hold()
            return [late]
        }
        viewport.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.visibleAlignmentTrackID: "second-track"])
        let holding = await waitUntil(budget: .lookup) { builds.calls == 1 }
        XCTAssertTrue(holding, "the refresh never reached its summary build")
        let refresh = viewport.mappingRowsRefreshTask

        harness.select(fastq)
        let left = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(left, "the FASTQ dashboard never replaced the viewport")
        let inspector = harness.split.inspectorController.viewModel.documentSectionViewModel
        let (words, bundleURL) = (viewer.statusBar.positionLabel.stringValue, inspector.bundleURL)

        builds.release()
        await refresh?.value

        XCTAssertEqual(builds.sawCancellation, true, "the removal left the refresh and its samtools children running")
        XCTAssertFalse(viewport.testContigTableView.displayedRows.contains { $0.mappedReads == 777_777 }, "the refresh wrote its rows after the viewer left")
        XCTAssertEqual(viewer.statusBar.positionLabel.stringValue, words, "the refresh wrote the status line of the next kind")
        XCTAssertEqual(inspector.bundleURL, bundleURL, "the refresh wrote the Inspector of the next kind")
    }

    /// The Inspector keeps its last alignment block after the viewer leaves (`NET-ALIGNMENT-SECTION-STAYS`), so a person
    /// can still touch that block's filter. It must not reach a viewport that is gone.
    func testAStaleInspectorFilterStartsNoWorkAfterTheViewerLeft() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9, secondTrack: true)
        let fastq = try await buildRow(of: "FASTQ", under: root)
        let builds = SummaryBuilderLog()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        var opened: ReferenceBundleViewportController? = try XCTUnwrap(viewer.referenceBundleViewportController)
        weak var left = opened
        let rows = mapping.rows
        opened?.setAlignmentTrackSummaryBuilderForTesting { _, _, _ in
            builds.count()
            return rows
        }
        let settled = await waitUntil(budget: .lookup) {
            guard let viewport = left else { return false }
            return builds.calls > 0 && viewport.mappingRowsRefreshTask == nil
                && viewport.testEmbeddedViewerController.currentReferenceBundle != nil
                && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(settled, "the viewport never settled with its Inspector block")
        opened = nil
        // A refresh still reading its stats when the viewer leaves goes on to its builder, and that is no stale filter.
        let inFlight = left?.mappingRowsRefreshTask

        harness.select(fastq)
        let moved = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(moved, "the FASTQ dashboard never replaced the viewport")
        await inFlight?.value
        let stale = try XCTUnwrap(readStyle.onSettingsChanged, "the block is gone, so this test proves nothing")
        let before = builds.calls

        readStyle.selectedVisibleAlignmentTrackID = "second-track"
        stale()
        await left?.mappingRowsRefreshTask?.value

        XCTAssertEqual(builds.calls, before, "a stale filter started a summary build on a viewport that is gone")
    }

    func testARemovedViewportIsReleased() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let fastq = try await buildRow(of: "FASTQ", under: root)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        weak var removed = viewer.referenceBundleViewportController
        XCTAssertNotNil(removed)

        harness.select(fastq)
        let left = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(left, "the FASTQ dashboard never replaced the viewport")

        let released = await waitUntil(budget: .lookup) { removed == nil }
        XCTAssertTrue(released, "the removed viewport outlived its removal")
    }

    /// The release comes from the split going, not from a clear, so its order against `AppDelegate.windowWillClose` does
    /// not matter here. That close clears no viewport in this test, as no delegate is the app's, and `deinit` is the
    /// backstop that cancels a refresh (`ReferenceBundleViewportController.swift:190`).
    func testClosingTheWindowLeavesNoReferenceBehind() async throws {
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        weak var weakSplit: MainSplitViewController?
        weak var weakViewport: ReferenceBundleViewportController?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
            try await assertShows(mapping, in: harness.split.viewerController)
            weakSplit = harness.split
            weakViewport = harness.split.viewerController.referenceBundleViewportController
            XCTAssertNotNil(weakViewport)
            // Not `harness.close()`: it clears the viewport through the host, which would remove the viewport even if the
            // window's own close left it behind.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakViewport == nil }
        XCTAssertTrue(released, "the viewport outlived the window")
    }

    /// The edit's end reads this slot's URL before it reloads (`AppDelegate+SequenceMenu.swift:549-552`, `:797-800`), and a
    /// mapping job's end reads the active mapping viewport (`ViewerViewController+Mapping.swift:101-103`). After the viewer
    /// left, each finds nothing, so the write stands on disk and the screen stays as it is.
    func testAnAnnotationEditThatEndsAfterTheViewerLeftReloadsNothing() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let fastq = try await buildRow(of: "FASTQ", under: root)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        harness.select(fastq)
        let left = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(left, "the FASTQ dashboard never replaced the viewport")

        XCTAssertNil(viewer.referenceBundleViewportController, "an edit that ends now would reload a viewport that left")
        XCTAssertNil(viewer.activeMappingViewportController, "a job that ends now would reload a viewport that left")
        XCTAssertNotEqual(viewer.drawnReferenceBundle?.url.standardizedFileURL, mapping.bundle.standardizedFileURL)
        XCTAssertNoThrow(try viewer.reloadMappingViewerBundleIfDisplayed())
        XCTAssertEqual(viewer.contentMode, .fastq, "the reload changed what is on screen")
    }

    // MARK: - A failed open

    func testAReferenceBundleThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let shown = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let reference = try makeReference("Refused")
        harness.split.displayMappingAnalysisFromSidebar(at: shown.result)
        try await assertShows(shown, in: viewer)
        viewer.surfaceHost.registry.register(.bundle(.reference)) { RefusingReferenceSurface() }

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await harness.split.bundleOpenTask?.value

        assertNoViewportAndWords(startingWith: "Unable to open the reference bundle. ", endingWith: "Select it again.", in: harness)
    }

    func testAMappingResultThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let shown = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let refused = try makeMapping("B", contig: "chrB", readsOnContig: 7)
        harness.split.displayMappingAnalysisFromSidebar(at: shown.result)
        try await assertShows(shown, in: viewer)
        viewer.surfaceHost.registry.register(.bundle(.reference)) { RefusingReferenceSurface() }

        harness.split.displayMappingAnalysisFromSidebar(at: refused.result)
        await harness.split.bundleOpenTask?.value

        assertNoViewportAndWords(startingWith: "Unable to open the mapping result. ", endingWith: "Select it again.", in: harness)
    }

    /// A real file that does not read: the placeholder shows, the decode fails, and the route says the file's own words.
    func testAReferenceBundleWhoseManifestDoesNotReadSaysWhatHappenedAndWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let shown = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let damaged = try makeReference("Damaged")
        try "{ \"name\" : ".write(to: damaged.appendingPathComponent(BundleManifest.filename), atomically: true, encoding: .utf8)
        harness.split.displayMappingAnalysisFromSidebar(at: shown.result)
        try await assertShows(shown, in: viewer)

        harness.split.displayReferenceBundleViewportFromSidebar(at: damaged)
        await harness.split.bundleOpenTask?.value

        assertNoViewportAndWords(
            startingWith: "Unable to open the reference bundle. ",
            endingWith: "Select the item again. If it still does not open, check that the bundle's folder is complete or import it again.",
            in: harness
        )
    }

    /// The base read the file before it cleared the Inspector, so the last row's numbers stayed under its words.
    func testAMappingResultWhoseFileDoesNotReadSaysWhatHappenedAndWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let shown = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let damaged = try makeMapping("B", contig: "chrB", readsOnContig: 7)
        try "{ \"mapper\" : ".write(to: damaged.result.appendingPathComponent("mapping-result.json"), atomically: true, encoding: .utf8)
        harness.split.displayMappingAnalysisFromSidebar(at: shown.result)
        try await assertShows(shown, in: viewer)
        XCTAssertNotNil(harness.split.inspectorController.viewModel.documentSectionViewModel.mappingDocument, "the first result set no document")

        harness.split.displayMappingAnalysisFromSidebar(at: damaged.result)
        await harness.split.bundleOpenTask?.value

        assertNoViewportAndWords(
            startingWith: "Unable to open the mapping result. ",
            endingWith: "Select the item again. If it still does not open, check that the result's folder is complete or run the mapping again.",
            in: harness
        )
    }

    /// The old hide brought the ruler, the viewer and the status bar back on every call, whatever was showing. The new one
    /// acts only when this kind is installed, so the words of a failed open must still be in view.
    func testAFailedOpenBringsBackTheStatusLine() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let shown = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let damaged = try makeMapping("B", contig: "chrB", readsOnContig: 7)
        try "{ \"mapper\" : ".write(to: damaged.result.appendingPathComponent("mapping-result.json"), atomically: true, encoding: .utf8)
        harness.split.displayMappingAnalysisFromSidebar(at: shown.result)
        try await assertShows(shown, in: viewer)

        harness.split.displayMappingAnalysisFromSidebar(at: damaged.result)
        await harness.split.bundleOpenTask?.value

        XCTAssertFalse(viewer.statusBar.isHidden, "the words of a failed open are in a hidden status bar")
        XCTAssertFalse(viewer.enhancedRulerView.isHidden, "the ruler stayed hidden after a failed open")
        XCTAssertFalse(viewer.viewerView.isHidden, "the viewer stayed hidden after a failed open")
    }

    // MARK: - Support

    /// A mapping result saved by its own writer, in a folder of its own. The track names the result's own BAM, so All
    /// Alignments shows the record's values.
    func makeMapping(
        _ name: String, contig: String, readsOnContig: Int, secondTrack: Bool = false, otherContigs: [String] = []
    ) throws -> MappingFixture {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = try MappingRoutingFixture.makeReferenceBundle(
            name: "Viewer \(name)", chromosomes: ([contig] + otherContigs).map { .init(name: $0, length: 100) }, in: folder
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundle, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true,
            originalSourcePath: MappingRoutingFixture.ownBAMOriginalSourcePath
        )
        if secondTrack {
            try MappingRoutingFixture.addSingleSampleAlignment(
                to: bundle, sampleID: "S2", trackID: "second-track", includeReadGroup: false, includeChromosomeStats: true
            )
        }
        let result = folder.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let summaries = ([contig] + otherContigs).map {
            MappingContigSummary(
                contigName: $0, contigLength: 100, mappedReads: readsOnContig, mappedReadPercent: Double(readsOnContig) * 10,
                meanDepth: 3.5, coverageBreadth: 0.8, medianMAPQ: 60, meanIdentity: 0.99
            )
        }
        let saved = MappingRoutingFixture.makeMappingResult(resultDirectory: result, viewerBundleURL: bundle, contigs: summaries)
        try saved.save(to: result)
        let labelled = ([contig] + otherContigs).map {
            MappingContigSummary(
                sampleID: "S1", alignmentTrackID: "reads-track", readGroupIDs: [],
                contigName: $0, contigLength: 100, mappedReads: readsOnContig, mappedReadPercent: Double(readsOnContig) * 10,
                meanDepth: 3.5, coverageBreadth: 0.8, medianMAPQ: 60, meanIdentity: 0.99
            )
        }
        return MappingFixture(
            result: result, bundle: bundle, bam: saved.bamURL,
            trackBAM: bundle.appendingPathComponent("alignments/reads-track.bam"), rows: labelled
        )
    }

    func makeReference(_ name: String, chromosomes: [String] = ["chr1"]) throws -> URL {
        let folder = root.appendingPathComponent("reference-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try MappingRoutingFixture.makeReferenceBundle(
            name: name, chromosomes: chromosomes.map { .init(name: $0, length: 100) }, in: folder
        )
    }

    /// Waits for the open to settle, then reads whose BAM, rows and bundle each reader of the viewer sees.
    func assertShows(
        _ mapping: MappingFixture, in viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let settled = await waitUntil(budget: .lookup) {
            guard let viewport = viewer.referenceBundleViewportController else { return false }
            return viewport.currentInput?.mappingResultDirectoryURL == mapping.result.standardizedFileURL
                && viewport.testContigTableView.displayedRows.sorted(by: { $0.contigName < $1.contigName }) == mapping.rows
                && viewport.mappingRowsRefreshTask == nil
                && viewport.testEmbeddedViewerController.currentReferenceBundle != nil
        }
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController, file: file, line: line)
        XCTAssertTrue(settled, "the viewport never settled on its own rows, it reads \(viewport.testContigTableView.displayedRows)", file: file, line: line)
        // The evidence snapshot follows the selected row, so a person's click comes first.
        viewport.testSelectContig(named: mapping.rows[0].contigName)
        let snapshot = await waitUntil(budget: .lookup) { viewport.testAlignmentActionContext != nil }
        XCTAssertTrue(snapshot, "the selected row made no evidence snapshot", file: file, line: line)
        await viewport.testAwaitAlignmentActionContext()
        XCTAssertEqual(viewport.currentResult?.bamURL.standardizedFileURL, mapping.bam.standardizedFileURL, "another result's BAM", file: file, line: line)
        XCTAssertEqual(viewport.testContigTableView.displayedRows.sorted(by: { $0.contigName < $1.contigName }), mapping.rows, "another result's rows", file: file, line: line)
        XCTAssertEqual(viewport.testAlignmentActionContext?.alignmentURL.standardizedFileURL, mapping.trackBAM.standardizedFileURL, "the evidence snapshot names another BAM", file: file, line: line)
        XCTAssertEqual(viewport.testEmbeddedViewerController.viewerView.currentReferenceBundle?.url.standardizedFileURL, mapping.bundle.standardizedFileURL, "the embedded viewer draws another bundle", file: file, line: line)
        XCTAssertEqual(viewer.drawnReferenceBundle?.url.standardizedFileURL, mapping.bundle.standardizedFileURL, "File > Export would read another bundle", file: file, line: line)
        // The Inspector's metadata import writes through this context, so it must name this result.
        let split = try XCTUnwrap(sequence(first: viewer as NSViewController, next: { $0.parent }).compactMap { $0 as? MainSplitViewController }.first, file: file, line: line)
        XCTAssertEqual(split.bamMetadataPresentationContext?.finalResultURL.standardizedFileURL, mapping.result.standardizedFileURL, "the Inspector's metadata context reads another result", file: file, line: line)
    }

    func assertShowsReference(
        _ reference: URL, in viewer: ViewerViewController, sequences: [String] = ["chr1"],
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let settled = await waitUntil(budget: .lookup) {
            guard let viewport = viewer.referenceBundleViewportController else { return false }
            return viewport.currentInput?.renderedBundleURL == reference.standardizedFileURL
                && viewport.testDisplayedSequenceNames == sequences
                && viewport.testEmbeddedViewerController.currentReferenceBundle != nil
        }
        XCTAssertTrue(settled, "the reference never showed its own sequences", file: file, line: line)
        if let viewport = viewer.referenceBundleViewportController {
            XCTAssertEqual(viewport.testEmbeddedViewerController.viewerView.currentReferenceBundle?.url.standardizedFileURL, reference.standardizedFileURL, "the embedded viewer draws another bundle", file: file, line: line)
            XCTAssertEqual(viewer.drawnReferenceBundle?.url.standardizedFileURL, reference.standardizedFileURL, "File > Export would read another bundle", file: file, line: line)
        }
    }

    private func assertTheDrawerIsTheViewports(
        in viewer: ViewerViewController, showing name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController, file: file, line: line)
        XCTAssertFalse(viewer.isActiveDrawerOpen, "\(name) opened with its drawer open", file: file, line: line)

        viewer.toggleAnnotationDrawer()
        XCTAssertTrue(viewer.isActiveDrawerOpen, "Show Drawer reads closed on \(name)", file: file, line: line)
        XCTAssertTrue(viewport.isEmbeddedAnnotationDrawerOpen, "Show Drawer did not reach the embedded drawer of \(name)", file: file, line: line)
        XCTAssertNil(viewer.annotationDrawerView, "Show Drawer made an empty drawer under \(name)", file: file, line: line)

        viewer.toggleAnnotationDrawer()
        XCTAssertFalse(viewer.isActiveDrawerOpen, "Hide Drawer reads open on \(name)", file: file, line: line)
        XCTAssertFalse(viewport.isEmbeddedAnnotationDrawerOpen, "Hide Drawer did not reach the embedded drawer of \(name)", file: file, line: line)
        XCTAssertNil(viewer.annotationDrawerView, "Hide Drawer made an empty drawer under \(name)", file: file, line: line)
    }

    private func assertNoViewportAndWords(
        startingWith headline: String, endingWith nextStep: String, in harness: ViewSwitchWindowHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let viewer = harness.split.viewerController!
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix(headline), "the status line never said so: \(words)", file: file, line: line)
        XCTAssertTrue(words.hasSuffix(nextStep), "the status line gave no next step: \(words)", file: file, line: line)
        XCTAssertFalse(words.contains("bundle:"), "the words name an internal kind id: \(words)", file: file, line: line)
        XCTAssertFalse(viewer.statusBar.isHidden, "the words are in a hidden status bar", file: file, line: line)
        XCTAssertNil(viewer.referenceBundleViewportController, "a viewport stayed under the words", file: file, line: line)
        XCTAssertNil(viewer.activeMappingViewportController, "a viewport stayed under the words", file: file, line: line)
        XCTAssertNil(viewer.installedSurface, "a surface stayed under the words", file: file, line: line)
        XCTAssertEqual(viewer.contentMode, .empty, file: file, line: line)
        XCTAssertNil(
            harness.split.inspectorController.viewModel.documentSectionViewModel.mappingDocument,
            "the last row's numbers stayed in the Inspector under the words", file: file, line: line
        )
    }
}
