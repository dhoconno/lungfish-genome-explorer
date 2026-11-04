// FASTQDatasetSurfaceRouteTests.swift - The FASTQ dashboard on the surface host, its drawer and every way out (Phase 3.2 lane FASTQ)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A person sees this kind more than any other, and its drawer feeds a demultiplexing configuration to an operation, so
// these tests read what a slip would change: the room the drawer takes, the configuration where the operation reads it,
// the numbers on the dashboard, and the one notification the Inspector takes them from.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

/// What a FASTQ file that does not read says. A real load throws this kind of error, not a `SurfaceError`.
struct DamagedFASTQFile: LocalizedError {
    var errorDescription: String? { "reads.fastq ends in the middle of a read" }
}

/// A surface whose load fails on the file, so the dashboard's show never installs.
@MainActor
private final class RefusingFASTQSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(.fastq) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedFASTQFile()
    }
}

/// Each `.fastqDatasetLoaded` a test sees, with what the viewer held when it fired.
private final class LoadedPosts: @unchecked Sendable {
    struct Post {
        let dashboardShows: Bool
        let datasetURL: URL?
        let samplesInTheConfiguration: Int?
    }
    var seen: [Post] = []
}

@MainActor
final class FASTQDatasetSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    private let chromeVisible = AlignmentChrome(ruler: false, viewer: false, header: false, status: false)
    private let chromeCovered = AlignmentChrome(ruler: true, viewer: true, header: true, status: true)

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "FASTQSurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface

    func testTheFASTQDashboardOpensThroughTheSurfaceHost() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!

        try await showFASTQRow(in: harness)

        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .bundle(.fastq), "the dashboard is not on the surface host")
        XCTAssertEqual(AlignmentChrome(viewer), chromeCovered, "the genomics chrome shows under the dashboard")
        XCTAssertEqual(viewer.contentMode, .fastq)
    }

    /// The numbers a person reads from the fixture do not change with the host. The same assertions pass at the base.
    func testTheNumbersOfTheFixtureAreWhatTheDashboardShows() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let split = harness.split

        try await showFASTQRow(in: harness)

        let dashboard = try XCTUnwrap(split.viewerController.fastqDatasetController)
        let cards = dashboard.testingSummaryAccessibilityChildren.map {
            "\($0.accessibilityLabel() ?? ""): \(($0.accessibilityValue() as? String) ?? "")"
        }
        XCTAssertEqual(cards, Self.fixtureSummaryCards, "the summary a person reads changed")
        let statistics = try XCTUnwrap(split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics)
        XCTAssertEqual(statistics.readCount, Self.fixtureReadCount, "the Inspector's read count changed")
        XCTAssertEqual(statistics.baseCount, Self.fixtureBaseCount, "the Inspector's base count changed")
    }

    /// Step 8 of the recipe. The base pins the dashboard to the safe area, so its top is not above the toolbar.
    func testFASTQContentStartsBelowTheToolbar() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!

        try await showFASTQRow(in: harness)
        harness.window.contentView?.layoutSubtreeIfNeeded()

        let inset = viewer.view.safeAreaInsets.top
        XCTAssertGreaterThan(inset, 0, "the window has no toolbar inset, so this test cannot tell the two pins apart")
        let dashboard = try XCTUnwrap(viewer.fastqDatasetController).view
        let dashboardTop = dashboard.convert(dashboard.bounds, to: nil).maxY
        let safeTop = viewer.view.convert(viewer.view.safeAreaRect, to: nil).maxY
        XCTAssertLessThanOrEqual(dashboardTop, safeTop + 0.5, "the dashboard starts \(dashboardTop - safeTop) points above the safe area")
    }

    // MARK: - The drawer

    func testTheDrawerShrinksTheDashboardAndGivesTheRoomBackInAFreshWindow() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        try await showFASTQRow(in: harness)

        await assertTheDrawerTakesItsRoomAndGivesItBack(harness.split.viewerController)
    }

    func testTheDrawerShrinksTheDashboardAndGivesTheRoomBackAfterAnotherKind() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let assembly = try await buildRow(of: "Assembly", under: root)
        harness.select(assembly)
        let settled = await settle(harness, on: "Assembly")
        XCTAssertTrue(settled, "the assembly never opened")

        try await showFASTQRow(in: harness)

        await assertTheDrawerTakesItsRoomAndGivesItBack(harness.split.viewerController)
    }

    /// The configuration is read where the operation reads it, not in the drawer.
    func testAPlanSetInTheDrawerReachesTheOperationInAFreshWindow() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        try await showFASTQRow(in: harness)

        try assertAPlanInTheDrawerReachesTheOperation(harness.split.viewerController)
    }

    func testAPlanSetInTheDrawerReachesTheOperationAfterAnotherKind() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let kraken = try await buildRow(of: "Kraken2", under: root)
        harness.select(kraken)
        let settled = await settle(harness, on: "Kraken2")
        XCTAssertTrue(settled, "the Kraken2 result never opened")

        try await showFASTQRow(in: harness)

        try assertAPlanInTheDrawerReachesTheOperation(harness.split.viewerController)
    }

    /// An edit the person did not save goes with the drawer, at the base and at the head, and a saved one comes back.
    /// The test holds the drawer weakly, so a drawer that something kept cannot look like a plan that came back.
    func testAnUnsavedPlanGoesWithTheDrawerAndASavedOneComesBack() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let fastq = try await buildRow(of: "FASTQ", under: root)
        let status = try await buildRow(of: "Status only", under: root)
        harness.select(fastq)
        var settled = await settle(harness, on: "FASTQ")
        XCTAssertTrue(settled, "the dashboard never opened")

        viewer.openDemuxSetupDrawer()
        weak var unsavedDrawer = viewer.fastqMetadataDrawerView
        unsavedDrawer?.applySampleAssignmentsToCurrentStep([Self.assignment])
        harness.select(status)
        settled = await settle(harness, on: "Status only")
        XCTAssertTrue(settled, "the status row never opened")
        let released = await waitUntil(budget: .lookup) { unsavedDrawer == nil }
        XCTAssertTrue(released, "the drawer outlived the dashboard, so its edit is still held")

        harness.select(fastq)
        settled = await settle(harness, on: "FASTQ")
        XCTAssertTrue(settled, "the dashboard never came back")
        viewer.openDemuxSetupDrawer()
        var plan = try XCTUnwrap(viewer.fastqMetadataDrawerView).currentDemuxPlan()
        XCTAssertEqual(plan.steps.first?.sampleAssignments.count, 0, "an edit that was never saved came back")

        // Save, as the drawer's Save button does, and leave again.
        let drawer = try XCTUnwrap(viewer.fastqMetadataDrawerView)
        drawer.applySampleAssignmentsToCurrentStep([Self.assignment])
        viewer.fastqMetadataDrawerViewDidSave(drawer, fastqURL: nil, metadata: drawer.currentMetadata())
        harness.select(status)
        settled = await settle(harness, on: "Status only")
        XCTAssertTrue(settled, "the status row never opened after the save")
        harness.select(fastq)
        settled = await settle(harness, on: "FASTQ")
        XCTAssertTrue(settled, "the dashboard never came back after the save")
        viewer.openDemuxSetupDrawer()
        plan = try XCTUnwrap(viewer.fastqMetadataDrawerView).currentDemuxPlan()
        XCTAssertEqual(plan.steps.first?.sampleAssignments.first?.sampleName, Self.assignment.sampleName, "the saved plan did not come back")
        let request = try XCTUnwrap(viewer.fastqDatasetController?.testingDemultiplexRequest(), "the saved plan did not reach the operation")
        guard case .demultiplex(_, _, _, _, _, _, _, _, _, let assignments, _) = request else {
            return XCTFail("the operation is not a demultiplex: \(request)")
        }
        XCTAssertEqual(assignments?.map(\.sampleName), [Self.assignment.sampleName])
    }

    // MARK: - The notification

    /// Fires once for each display, with the slot set and the sync done, as the base has it. The drawer that stands
    /// before the display is the only way the sync has something to carry, since a dashboard's own drawer goes with it.
    func testTheLoadedNotificationFiresOnceForEachDisplayAfterTheSync() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let fastq = try await buildRow(of: "FASTQ", under: root)
        viewer.configureFASTQMetadataDrawer()
        viewer.fastqMetadataDrawerView?.applySampleAssignmentsToCurrentStep([Self.assignment])
        let posts = LoadedPosts()
        let observer = observeLoadedPosts(of: viewer, into: posts)
        defer { NotificationCenter.default.removeObserver(observer) }

        harness.select(fastq)
        let settled = await settle(harness, on: "FASTQ")
        XCTAssertTrue(settled, "the dashboard never opened")

        XCTAssertEqual(posts.seen.count, 1, "one display, one notification")
        XCTAssertEqual(posts.seen.first?.dashboardShows, true, "the notification fired before the dashboard was in place")
        XCTAssertEqual(posts.seen.first?.samplesInTheConfiguration, 1, "the notification fired before the sync")
        XCTAssertNotNil(posts.seen.first?.datasetURL, "the notification fired before the dataset's URL was set")

        harness.split.loadFASTQDatasetInBackground(sourceURL: try XCTUnwrap(viewer.currentFASTQDatasetURL).deletingLastPathComponent())
        XCTAssertEqual(posts.seen.count, 2, "a second display, a second notification")
    }

    /// A count that a newer selection overtook fires nothing, and leaves the newer kind's chrome and no drawer.
    func testACountThatANewerSelectionOvertookFiresNothing() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let split = harness.split
        let viewer = split.viewerController!
        let assembly = try await buildRow(of: "Assembly", under: root)
        harness.select(assembly)
        let settled = await settle(harness, on: "Assembly")
        XCTAssertTrue(settled, "the assembly never opened")
        let chromeOfTheKind = AlignmentChrome(viewer)
        let bundle = try makeUncountedBundle(named: "overtaken")
        let posts = LoadedPosts()
        let observer = observeLoadedPosts(of: viewer, into: posts)
        defer { NotificationCenter.default.removeObserver(observer) }

        split.loadFASTQDatasetInBackground(sourceURL: bundle)
        let count = try XCTUnwrap(split.fastqLoadTask, "the count did not start")
        harness.select(assembly)
        let back = await settle(harness, on: "Assembly")
        XCTAssertTrue(back, "the assembly never came back")
        await count.value
        await drainTheMainQueue()

        XCTAssertEqual(posts.seen.count, 0, "an overtaken count told the Inspector about its reads")
        XCTAssertNil(viewer.fastqDatasetController, "an overtaken count opened its dashboard")
        XCTAssertNil(viewer.currentFASTQDatasetURL, "an overtaken count left its URL")
        XCTAssertNil(viewer.fastqMetadataDrawerView, "an overtaken count left a drawer")
        XCTAssertEqual(AlignmentChrome(viewer), chromeOfTheKind, "an overtaken count changed the chrome")
    }

    // MARK: - The failure words

    func testAFASTQThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let split = harness.split
        let viewer = split.viewerController!
        try await showFASTQRow(in: harness)
        XCTAssertNotNil(split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics, "the Inspector has no numbers to lose")
        viewer.openDemuxSetupDrawer()
        let bundle = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent("Other", isDirectory: true)).bundle
        viewer.surfaceHost.registry.register(.bundle(.fastq)) { RefusingFASTQSurface() }
        let posts = LoadedPosts()
        let observer = observeLoadedPosts(of: viewer, into: posts)
        defer { NotificationCenter.default.removeObserver(observer) }

        split.loadFASTQDatasetInBackground(sourceURL: bundle)

        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the FASTQ dataset."), "the status line never said the dataset did not open: \(words)")
        XCTAssertTrue(words.contains("reads.fastq ends in the middle of a read."), "the status line left out the file's own words: \(words)")
        XCTAssertTrue(
            words.hasSuffix(" Select the item again. If it still does not open, import the reads again."),
            "the status line gave no next step: \(words)"
        )
        XCTAssertFalse(words.contains("bundle:"), "the words name an internal kind id: \(words)")
        XCTAssertEqual(posts.seen.count, 0, "a dashboard that did not open told the Inspector about its reads")
        XCTAssertNil(viewer.fastqDatasetController, "a dashboard that did not open is on screen")
        XCTAssertNil(viewer.fastqMetadataDrawerView, "a dashboard that did not open left the last one's drawer")
        XCTAssertNil(viewer.currentFASTQDatasetURL, "a dashboard that did not open left a URL")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a refused dashboard left the chrome hidden")
        XCTAssertEqual(viewer.contentMode, .empty, "a refused dashboard left the mode")
        XCTAssertNil(
            split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics,
            "the Inspector still shows the last read set's numbers under a dataset that did not open"
        )
    }

    func testAFASTQWhoseFileIsLockedSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (bundle, fastq) = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent("Locked", isDirectory: true))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fastq.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fastq.path) }

        harness.split.loadFASTQDatasetInBackground(sourceURL: bundle)

        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the FASTQ dataset. "), "the status line never said the dataset did not open: \(words)")
        XCTAssertTrue(words.contains("does not allow \(fastq.lastPathComponent) to be read."), "the words do not say what happened: \(words)")
        XCTAssertTrue(words.contains("permissions"), "the words do not say what to try: \(words)")
        XCTAssertNil(viewer.fastqDatasetController, "a dashboard over a file nobody can read is on screen")
    }

    func testAFASTQWhoseFileIsGoneSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let gone = root.appendingPathComponent("gone.fastq")

        viewer.displayFASTQDataset(statistics: .countsOnlyFixture(readCount: 4, baseCount: 400), records: [], fastqURL: gone)

        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the FASTQ dataset. "), "the status line never said the dataset did not open: \(words)")
        XCTAssertTrue(words.contains("gone.fastq is no longer where it was saved."), "the words do not say what happened: \(words)")
        XCTAssertTrue(words.contains("then select it again."), "the words do not say what to try: \(words)")
        XCTAssertNil(viewer.fastqDatasetController, "a dashboard over a file that is gone is on screen")
    }

    /// A virtual derived bundle has no file of its own, so nothing is checked and its stored numbers show.
    func testADatasetWithNoFileOfItsOwnStillOpens() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!

        viewer.displayFASTQDataset(statistics: .countsOnlyFixture(readCount: 4, baseCount: 400), records: [], fastqURL: nil)

        XCTAssertNotNil(viewer.fastqDatasetController, "a derived dataset with no file of its own did not open")
    }

    // MARK: - Every way out

    /// Each kind is shown from the status row twice, once straight and once with the dashboard and an open drawer in
    /// between. The dashboard and the drawer are gone in the second, and the chrome is what the kind shows alone.
    func testEveryKindOfTheMatrixTakesTheDashboardAndItsDrawerAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rest = try await buildRow(of: "Status only", under: root)
        let fastq = try await buildRow(of: "FASTQ", under: root)

        for kind in ViewSwitchKinds.all where kind.name != "Status only" && kind.name != "FASTQ" {
            let row = try await buildRow(of: kind.name, under: root)
            harness.select(rest)
            let restedAlone = await settle(harness, on: "Status only")
            XCTAssertTrue(restedAlone, "the status row never opened before \(kind.name)")
            harness.select(row)
            let alone = await settle(harness, on: kind.name)
            XCTAssertTrue(alone, "\(kind.name) never opened from the status row")
            let chromeAlone = AlignmentChrome(viewer)

            harness.select(rest)
            let rested = await settle(harness, on: "Status only")
            XCTAssertTrue(rested, "the status row never opened before the dashboard and \(kind.name)")
            harness.select(fastq)
            let shown = await settle(harness, on: "FASTQ")
            XCTAssertTrue(shown, "the dashboard did not show before \(kind.name)")
            viewer.openDemuxSetupDrawer()
            XCTAssertTrue(viewer.isActiveDrawerOpen, "the drawer did not open before \(kind.name)")

            harness.select(row)

            let left = await waitUntil(budget: .lookup) { viewer.fastqDatasetController == nil }
            XCTAssertTrue(left, "\(kind.name) left the dashboard on screen")
            let after = await settle(harness, on: kind.name)
            XCTAssertTrue(after, "\(kind.name) never opened after the dashboard")
            XCTAssertNil(viewer.fastqMetadataDrawerView, "\(kind.name) left the drawer on screen")
            XCTAssertFalse(viewer.isFASTQMetadataDrawerOpen, "\(kind.name) left the drawer's state open")
            XCTAssertNil(viewer.currentFASTQDatasetURL, "\(kind.name) left the dataset's URL")
            XCTAssertEqual(AlignmentChrome(viewer), chromeAlone, "\(kind.name) shows other chrome after the dashboard than alone")
        }
    }

    func testASecondDashboardTakesNothingOfTheFirst() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let split = harness.split
        let viewer = split.viewerController!
        try await showFASTQRow(in: harness)
        let first = try XCTUnwrap(viewer.fastqDatasetController)
        viewer.openDemuxSetupDrawer()
        viewer.fastqMetadataDrawerView?.applySampleAssignmentsToCurrentStep([Self.assignment])
        let (bundle, fastq) = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent("Second", isDirectory: true))

        split.loadFASTQDatasetInBackground(sourceURL: bundle)

        let second = try XCTUnwrap(viewer.fastqDatasetController)
        XCTAssertFalse(first === second, "the first dashboard was kept")
        XCTAssertNil(first.view.superview?.window, "the first dashboard stayed in the window")
        XCTAssertNil(viewer.fastqMetadataDrawerView, "the first dashboard's drawer stayed")
        XCTAssertFalse(viewer.isActiveDrawerOpen, "the second dashboard reads as having an open drawer")
        XCTAssertNil(second.currentDemuxConfig, "the first drawer's plan reached the second dashboard's operation")
        XCTAssertEqual(viewer.currentFASTQDatasetURL?.standardizedFileURL, fastq.standardizedFileURL)
    }

    func testAProjectSwitchTakesTheDashboardAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        try await showFASTQRow(in: harness)
        viewer.openDemuxSetupDrawer()

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.fastqDatasetController, "a project switch left the dashboard on screen")
        XCTAssertNil(viewer.fastqMetadataDrawerView, "a project switch left the drawer on screen")
        XCTAssertFalse(viewer.isFASTQMetadataDrawerOpen, "a project switch left the drawer's state open")
        XCTAssertNil(viewer.currentFASTQDatasetURL, "a project switch left the dataset's URL")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a project switch left chrome hidden")
    }

    func testClosingTheWindowLeavesNoDashboardBehind() async throws {
        let bundleRow = try await buildRow(of: "FASTQ", under: root)
        weak var weakSplit: MainSplitViewController?
        weak var weakDashboard: FASTQDatasetViewController?
        weak var weakDrawer: FASTQMetadataDrawerView?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.select(bundleRow)
            let settled = await settle(harness, on: "FASTQ")
            XCTAssertTrue(settled, "the dashboard never opened")
            harness.split.viewerController.openDemuxSetupDrawer()
            weakSplit = harness.split
            weakDashboard = harness.split.viewerController.fastqDatasetController
            weakDrawer = harness.split.viewerController.fastqMetadataDrawerView
            XCTAssertNotNil(weakDashboard)
            XCTAssertNotNil(weakDrawer)
            // Not `harness.close()`: it clears the viewport through the host, which would remove the dashboard even if
            // the window's own close left it behind.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakDashboard == nil && weakDrawer == nil }
        XCTAssertTrue(released, "the dashboard or its drawer outlived the window")
    }

    // MARK: - Support

    /// The fixture `assembly-ui/illumina/reads_R1.fastq`, read by the app's own reader.
    private static let fixtureReadCount = 1
    private static let fixtureBaseCount: Int64 = 16
    private static let fixtureSummaryCards = [
        "Reads: 1", "Bases: 16 bp", "Mean Length: 16 bp", "Median Length: 16 bp", "N50: 16 bp",
        "Mean Q: 37.0", "Q20: 100.0%", "Q30: 100.0%", "GC: 50.0%",
    ]

    private static let assignment = FASTQSampleBarcodeAssignment(
        sampleID: "bc1001", sampleName: "Sample one",
        forwardBarcodeID: "bc1001", forwardSequence: "ACGTACGT",
        reverseBarcodeID: "bc1001", reverseSequence: "ACGTACGT"
    )

    private func showFASTQRow(in harness: ViewSwitchWindowHarness) async throws {
        let fastq = try await buildRow(of: "FASTQ", under: root)
        harness.select(fastq)
        let settled = await settle(harness, on: "FASTQ")
        XCTAssertTrue(settled, "the dashboard never opened")
    }

    private func assertTheDrawerTakesItsRoomAndGivesItBack(
        _ viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) async {
        guard let dashboard = viewer.fastqDatasetController?.view else {
            return XCTFail("no dashboard", file: file, line: line)
        }
        viewer.view.layoutSubtreeIfNeeded()
        let full = dashboard.frame.height
        XCTAssertFalse(viewer.isActiveDrawerOpen, "a new dashboard starts with its drawer open", file: file, line: line)

        viewer.openDemuxSetupDrawer()

        let drawerHeight = viewer.fastqMetadataDrawerHeightConstraint?.constant ?? 0
        XCTAssertGreaterThan(drawerHeight, 0, "the drawer has no height", file: file, line: line)
        XCTAssertTrue(viewer.isActiveDrawerOpen, "View > Show Drawer reads the drawer as closed", file: file, line: line)
        let shrank = await waitUntil(budget: .lookup) {
            viewer.view.layoutSubtreeIfNeeded()
            return abs(dashboard.frame.height - (full - drawerHeight)) < 1
        }
        XCTAssertTrue(shrank, "the drawer did not take its room: \(dashboard.frame.height) of \(full) with a drawer of \(drawerHeight)", file: file, line: line)

        viewer.toggleAnnotationDrawer()

        XCTAssertFalse(viewer.isActiveDrawerOpen, "View > Show Drawer reads the drawer as open", file: file, line: line)
        let gaveBack = await waitUntil(budget: .lookup) {
            viewer.view.layoutSubtreeIfNeeded()
            return abs(dashboard.frame.height - full) < 1
        }
        XCTAssertTrue(gaveBack, "the drawer did not give its room back: \(dashboard.frame.height) of \(full)", file: file, line: line)
    }

    private func assertAPlanInTheDrawerReachesTheOperation(
        _ viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let dashboard = try XCTUnwrap(viewer.fastqDatasetController, file: file, line: line)
        XCTAssertNil(dashboard.testingDemultiplexRequest(), "an operation ran with no plan", file: file, line: line)

        viewer.openDemuxSetupDrawer()
        let drawer = try XCTUnwrap(viewer.fastqMetadataDrawerView, file: file, line: line)
        drawer.applySampleAssignmentsToCurrentStep([Self.assignment])

        let kit = drawer.currentDemuxPlan().steps.first?.barcodeKitID
        let request = try XCTUnwrap(dashboard.testingDemultiplexRequest(), "the plan did not reach the operation", file: file, line: line)
        guard case .demultiplex(let kitID, _, _, _, _, _, _, _, _, let assignments, _) = request else {
            return XCTFail("the operation is not a demultiplex: \(request)", file: file, line: line)
        }
        XCTAssertEqual(kitID, kit, "the operation took another kit", file: file, line: line)
        XCTAssertEqual(assignments?.map(\.sampleName), [Self.assignment.sampleName], "the operation took other samples", file: file, line: line)
    }

    private func observeLoadedPosts(of viewer: ViewerViewController, into posts: LoadedPosts) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .fastqDatasetLoaded, object: viewer, queue: nil) { _ in
            MainActor.assumeIsolated {
                posts.seen.append(LoadedPosts.Post(
                    dashboardShows: viewer.fastqDatasetController != nil,
                    datasetURL: viewer.currentFASTQDatasetURL,
                    samplesInTheConfiguration: viewer.fastqDatasetController?.currentDemuxConfig?.sampleAssignments.count
                ))
            }
        }
    }

    /// A `.lungfishfastq` folder with a tiny FASTQ and no statistics, so showing it starts a count.
    private func makeUncountedBundle(named name: String) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// Every block already on the main queue runs before this returns, so a count's last hop has happened.
    private func drainTheMainQueue() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    /// Waits until the window shows `name`'s kind: what is installed, whatever mode it sits in.
    private func settle(_ harness: ViewSwitchWindowHarness, on name: String) async -> Bool {
        guard let kind = ViewSwitchKinds.all.first(where: { $0.name == name }),
              let shown = kind.outcome.components(separatedBy: " in ").first else { return false }
        let paths = SafetyNetPathRenderer(root: root)
        return await waitUntil(budget: .lookup) {
            ViewSwitchKinds.outcome(of: RoutingObserver.observe(harness.split, paths: paths, loaded: [])).hasPrefix(shown + " in ")
        }
    }
}
