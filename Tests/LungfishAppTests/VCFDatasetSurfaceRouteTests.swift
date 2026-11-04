// VCFDatasetSurfaceRouteTests.swift - The VCF dataset dashboard on the surface host leaves nothing behind (Phase 3.2 lane VCF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Nothing in the app calls `displayVCFDataset` today (a standalone VCF is imported into a bundle), so no sidebar row
// reaches the dashboard and the view-switch matrix cannot name it. These tests open it in a real window by calling the
// display, and take it away by each way it can leave: another kind of the matrix, a second dashboard, a project switch
// and a window close. The dashboard holds a filter, a sort and a selection in memory and saves nothing, so a test reads
// what is left of the view and the chrome, not an edit.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

/// What the VCF reader says about a file it cannot read. A real load throws this kind of error, not a `SurfaceError`.
struct DamagedVCFFile: LocalizedError {
    var errorDescription: String? { "VCF file is missing its header line: #CHROM" }
}

/// A surface whose load fails on the file, so the dashboard's show never installs.
@MainActor
private final class RefusingVCFSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .view(.vcfDataset) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedVCFFile()
    }
}

@MainActor
final class VCFDatasetSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    private let chromeVisible = AlignmentChrome(ruler: false, viewer: false, header: false, status: false)
    private let chromeCovered = AlignmentChrome(ruler: true, viewer: true, header: true, status: true)

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "VCFSurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface

    func testTheViewKindsAreNamedByTheirIds() {
        XCTAssertEqual("\(SurfaceKind.view(.vcfDataset))", "view:vcf-dataset")
        XCTAssertEqual("\(SurfaceKind.view(.fastaCollection))", "view:fasta-collection")
        XCTAssertEqual("\(SurfaceKind.view(.quickLook))", "view:quick-look")
        XCTAssertNotEqual(SurfaceKind.view(.vcfDataset), SurfaceKind.bundle(BundleKindID(rawValue: "vcf-dataset")))
    }

    func testTheVCFDatasetOpensThroughTheSurfaceHost() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()

        viewer.displayVCFDataset(summary: summary, variants: variants)

        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .view(.vcfDataset), "the dashboard is not on the surface host")
        let dashboard = try XCTUnwrap(viewer.vcfDatasetController, "the viewer's slot does not answer the dashboard")
        XCTAssertEqual(viewer.children.filter { $0 is VCFDatasetViewController }.count, 1, "the dashboard is not one child")
        XCTAssertTrue(dashboard.view.superview === viewer.view, "the dashboard is not in the viewer's view")
        XCTAssertEqual(AlignmentChrome(viewer), chromeCovered, "the genomics chrome shows under the dashboard")
    }

    /// The number a person reads from the fixture does not change with the host. The same assertions pass at the base.
    func testTheVariantCountOfTheFixtureIsWhatTheDashboardShows() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()
        XCTAssertEqual(summary.variantCount, Self.fixtureVariantCount, "the fixture changed")

        viewer.displayVCFDataset(summary: summary, variants: variants)

        let dashboard = try XCTUnwrap(viewer.children.compactMap { $0 as? VCFDatasetViewController }.first)
        XCTAssertEqual(dashboard.numberOfRows(in: NSTableView()), Self.fixtureVariantCount)
        XCTAssertEqual(dashboard.displayedVariantCountForTesting, variants.count)
        XCTAssertEqual(dashboard.testDisplayedVariants.map(\.position), variants.map(\.position), "the order of the table changed")
    }

    /// Step 8 of the recipe. The base pins the dashboard to the safe area, so its top is not above the toolbar.
    func testVCFContentStartsBelowTheToolbar() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()

        viewer.displayVCFDataset(summary: summary, variants: variants)
        harness.window.contentView?.layoutSubtreeIfNeeded()

        // In a real window the viewer's safe area starts 52 points down (the toolbar), measured for this lane.
        let inset = viewer.view.safeAreaInsets.top
        XCTAssertGreaterThan(inset, 0, "the window has no toolbar inset, so this test cannot tell the two pins apart")
        let dashboard = try XCTUnwrap(viewer.children.compactMap { $0 as? VCFDatasetViewController }.first).view
        let dashboardTop = dashboard.convert(dashboard.bounds, to: nil).maxY
        let safeTop = viewer.view.convert(viewer.view.safeAreaRect, to: nil).maxY
        XCTAssertLessThanOrEqual(dashboardTop, safeTop + 0.5, "the dashboard starts \(dashboardTop - safeTop) points above the safe area (inset \(inset))")
    }

    /// The display sets no content mode, so the dashboard shows under the mode the kind before left. That is the base.
    func testTheDisplayLeavesTheContentModeToTheKindBefore() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()
        let assembly = try await buildRow(of: "Assembly", under: root)
        harness.select(assembly)
        let settled = await settle(harness, on: "Assembly")
        XCTAssertTrue(settled, "the assembly never opened")
        let before = viewer.contentMode

        viewer.displayVCFDataset(summary: summary, variants: variants)

        XCTAssertEqual(viewer.contentMode, before, "the display changed the content mode")
    }

    // MARK: - The failure words

    /// The host cannot show the dashboard. The base never asks the host, so it shows the dashboard and says nothing.
    func testAVCFDatasetThatTheHostRefusesSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.surfaceHost.registry.register(.view(.vcfDataset)) { RefusingVCFSurface() }
        let (summary, variants) = try await readFixture()

        viewer.displayVCFDataset(summary: summary, variants: variants)

        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the VCF dataset."), "the status line never said the dashboard did not open: \(words)")
        XCTAssertTrue(words.contains("VCF file is missing its header line: #CHROM"), "the status line left out the file's own words: \(words)")
        XCTAssertTrue(
            words.hasSuffix(" Open the VCF file again. If it still does not open, import it into a project."),
            "the status line gave no next step that can help: \(words)"
        )
        XCTAssertFalse(words.contains("view:"), "the words name an internal kind id: \(words)")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a refused dashboard left the chrome hidden")
        XCTAssertNil(viewer.vcfDatasetController, "a dashboard that did not open is on screen")
        XCTAssertFalse(viewer.children.contains { $0 is VCFDatasetViewController }, "a refused dashboard is a child")
    }

    // MARK: - Every way out

    /// Each kind of the matrix is shown from the status row twice, once straight and once with the dashboard in
    /// between. The dashboard is gone in the second, and the chrome is what the kind shows alone.
    func testEveryKindOfTheMatrixTakesTheVCFDatasetAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()
        let rest = try await buildRow(of: "Status only", under: root)

        for kind in ViewSwitchKinds.all where kind.name != "Status only" {
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
            viewer.displayVCFDataset(summary: summary, variants: variants)
            XCTAssertNotNil(viewer.vcfDatasetController, "the dashboard did not show before \(kind.name)")
            harness.select(row)

            let left = await waitUntil(budget: .lookup) { viewer.vcfDatasetController == nil }
            XCTAssertTrue(left, "\(kind.name) left the VCF dataset on screen")
            let after = await settle(harness, on: kind.name)
            XCTAssertTrue(after, "\(kind.name) never opened after the dashboard")
            XCTAssertFalse(viewer.children.contains { $0 is VCFDatasetViewController }, "\(kind.name) left the dashboard a child")
            XCTAssertNotEqual(viewer.installedSurface?.surfaceKind, .view(.vcfDataset), "\(kind.name) left the dashboard on the host")
            XCTAssertEqual(AlignmentChrome(viewer), chromeAlone, "\(kind.name) shows other chrome after the dashboard than alone")
        }
    }

    /// FASTQ's display has no `hideVCFDatasetView()` in its hide list. The host replaces the surface it shows, so the
    /// dashboard goes all the same.
    func testTheFASTQDisplayTakesTheVCFDatasetAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()
        let rest = try await buildRow(of: "Status only", under: root)
        let fastq = try await buildRow(of: "FASTQ", under: root)
        harness.select(rest)
        let restedAlone = await settle(harness, on: "Status only")
        XCTAssertTrue(restedAlone, "the status row never opened")
        viewer.displayVCFDataset(summary: summary, variants: variants)

        harness.select(fastq)

        let opened = await waitUntil(budget: .lookup) { viewer.fastqDatasetController != nil }
        XCTAssertTrue(opened, "the FASTQ dashboard never opened")
        XCTAssertNil(viewer.vcfDatasetController)
    }

    /// The first dashboard's filter is memory only and goes with it. The test holds the first controller, since the
    /// question is what a controller that something else still holds can reach.
    func testASecondVCFDatasetReplacesTheFirstAndTakesNoFilterFromIt() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()

        viewer.displayVCFDataset(summary: summary, variants: variants)
        let first = try XCTUnwrap(viewer.vcfDatasetController)
        first.setFilterText("no-variant-has-this-text")
        XCTAssertEqual(first.displayedVariantCountForTesting, 0, "the filter did not apply")

        viewer.displayVCFDataset(summary: summary, variants: variants)

        let second = try XCTUnwrap(viewer.vcfDatasetController)
        XCTAssertFalse(first === second, "the first dashboard was kept")
        XCTAssertEqual(second.displayedVariantCountForTesting, variants.count, "the first dashboard's filter reached the second")
        XCTAssertNil(first.view.superview, "the first dashboard's view stayed in the viewer")
        XCTAssertNil(first.parent, "the first dashboard stayed a child")
        XCTAssertEqual(viewer.children.filter { $0 is VCFDatasetViewController }.count, 1)
    }

    func testAProjectSwitchTakesTheVCFDatasetAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (summary, variants) = try await readFixture()
        viewer.displayVCFDataset(summary: summary, variants: variants)
        XCTAssertNotNil(viewer.vcfDatasetController)

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.vcfDatasetController, "a project switch left the dashboard on screen")
        XCTAssertFalse(viewer.children.contains { $0 is VCFDatasetViewController }, "a project switch left the dashboard a child")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a project switch left chrome hidden")
    }

    func testClosingTheWindowLeavesNoVCFDatasetBehind() async throws {
        let (summary, variants) = try await readFixture()
        weak var weakSplit: MainSplitViewController?
        weak var weakDashboard: VCFDatasetViewController?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.split.viewerController.displayVCFDataset(summary: summary, variants: variants)
            weakSplit = harness.split
            weakDashboard = harness.split.viewerController.vcfDatasetController
            XCTAssertNotNil(weakDashboard)
            // Not `harness.close()`: it clears the viewport through the host, which would remove the dashboard even if
            // the window's own close left it behind.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakDashboard == nil }
        XCTAssertTrue(released, "the dashboard outlived the window")
    }

    // MARK: - Support

    /// The variants in `Tests/Fixtures/sarscov2/test.vcf`, read by the app's own reader.
    private static let fixtureVariantCount = 9

    private func readFixture() async throws -> (summary: VCFSummary, variants: [LungfishIO.VCFVariant]) {
        let url = SafetyNetPaths.fixture("sarscov2").appendingPathComponent("test.vcf")
        let reader = VCFReader()
        return (try await reader.summarize(from: url), try await reader.readAll(from: url))
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
