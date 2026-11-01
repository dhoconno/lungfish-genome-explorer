// TaxTriageSurfaceRouteTests.swift - The TaxTriage result leaves the Summary with its viewer (Phase 3.1 lane TT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A TaxTriage result gives the Summary an Operation Details block named TaxTriage. A later 12S or FASTQ item kept
// that block, because only the next classifier display cleared it (NET-UX row 4, INSPECTOR-BLOCK-OWNER). The
// TaxTriage viewer now opens through the surface host, its surface takes out a block named TaxTriage, and no other,
// when the host removes it, and View > Show Drawer reaches its BLAST drawer through the host (NAOMGS-ARCH carry list,
// items 1 to 3 and 9).
//
// Each test opens a TaxTriage batch as the sidebar does (`displayContent(for:)`), which shows it in the same turn.
// The batch is the routing fixture's TaxTriage database with the analysis metadata written beside it. As in
// `EsVirituSurfaceRouteTests`, the test methods are synchronous and wait by turning the main run loop.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxTriageUI
@testable import LungfishWorkflow

/// A surface whose load always fails, so the TaxTriage show never installs.
@MainActor
private final class RefusingTaxTriageSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.taxtriage) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class TaxTriageSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var taxTriage: URL!
    private var secondTaxTriage: URL!

    /// The TaxTriage result view may save its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "taxtriage-surface-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        taxTriage = try makeTaxTriageBatch(named: "taxtriage-batch-2026-10-31T10-00-00")
        secondTaxTriage = try makeTaxTriageBatch(named: "taxtriage-batch-2026-10-31T11-00-00")
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        window.contentViewController = nil
        window = nil
        controller = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A 12S result and a FASTQ bundle, each opened after a TaxTriage batch, hold no TaxTriage block.
    func testA12SResultOrAFASTQBundleAfterTaxTriageHoldsNoTaxTriageBlock() async throws {
        let twelveS = try RoutingSafetyNetFixtures.twelveSResultBundle(in: root).bundle
        let fastqBundle = try await RoutingSafetyNetFixtures.fastqBundle(in: root).bundle
        let next: [(name: String, item: SidebarItem, isShown: @MainActor () -> Bool)] = [
            ("a 12S result", item(twelveS, .twelveSAmpliconResultBundle), {
                self.controller.viewerController.twelveSAmpliconResultViewController != nil
            }),
            ("a FASTQ bundle", item(fastqBundle, .fastqBundle), {
                self.controller.viewerController.isDisplayingFASTQDataset
            }),
        ]
        for result in next {
            openTaxTriageWithItsBlock()
            controller.displayContent(for: result.item)
            XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { result.isShown() }, "\(result.name) never opened")
            XCTAssertNotEqual(
                summary.batchOperationTool, "TaxTriage",
                "\(result.name) opened after a TaxTriage batch must hold no TaxTriage block"
            )
        }
    }

    /// The viewer's teardown takes the TaxTriage block out, and only that block. A block of another tool, such as
    /// Kraken2's Operation Details, stays (NAOMGS-ARCH item 2, match the shared block by its content).
    func testTheTaxTriageViewerTakesOnlyItsOwnBlockWhenItLeaves() {
        openTaxTriageWithItsBlock()
        controller.viewerController.hideTaxTriageView()
        XCTAssertNil(summary.batchOperationTool, "the TaxTriage block must leave with the TaxTriage viewer")

        openTaxTriageWithItsBlock()
        controller.inspectorController.updateBatchOperationDetails(
            tool: "Kraken2", parameters: [:], timestamp: nil, sourceSamples: []
        )
        controller.viewerController.hideTaxTriageView()
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the leaving TaxTriage viewer wiped another tool's block")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is TaxTriageResultViewController })
        XCTAssertNil(controller.viewerController.taxTriageViewController)
    }

    /// A TaxTriage viewer that does not open says what happened and what to try, with no internal kind id, and
    /// gives the Summary no block (NAOMGS-ARCH item 3).
    func testATaxTriageResultThatDoesNotOpenSaysWhatToTry() {
        controller.viewerController.surfaceHost.registry.register(.analysis(.taxtriage)) { RefusingTaxTriageSurface() }
        controller.displayContent(for: item(taxTriage, .batchGroup))

        let words = controller.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the TaxTriage result."), words)
        XCTAssertTrue(words.contains("Select it again."), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is TaxTriageResultViewController })
        XCTAssertNil(controller.viewerController.taxTriageViewController)
        XCTAssertNil(summary.batchOperationTool)
    }

    /// View > Show Drawer and the toolbar button open and close the TaxTriage BLAST drawer through the host, which
    /// asks the installed surface first (NAOMGS-ARCH item 9).
    func testShowDrawerTogglesTheTaxTriageBlastDrawerThroughTheHost() {
        openTaxTriageWithItsBlock()
        let viewer = controller.viewerController!
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .analysis(.taxtriage), "the TaxTriage viewer is not on the host")
        XCTAssertFalse(viewer.isActiveDrawerOpen)

        viewer.toggleAnnotationDrawer()
        XCTAssertEqual(viewer.installedSurface?.isDrawerOpen, true, "the host's surface must answer for the BLAST drawer")
        XCTAssertTrue(viewer.isActiveDrawerOpen)
        XCTAssertEqual(viewer.taxTriageViewController?.isBlastDrawerOpen, true)

        viewer.toggleAnnotationDrawer()
        XCTAssertEqual(viewer.installedSurface?.isDrawerOpen, false)
        XCTAssertFalse(viewer.isActiveDrawerOpen)
        XCTAssertEqual(viewer.taxTriageViewController?.isBlastDrawerOpen, false)
    }

    /// The view switch smoke finds the TaxTriage viewer by `taxtriage-result-view`. AppKit leaves a plain NSView out of
    /// the accessibility tree whatever identifier it carries, so the root the host installs must be an element
    /// (3.1 lane ROBOTS, GUI run 1).
    func testTheInstalledTaxTriageRootIsAnAccessibilityGroupTheSmokeCanFind() {
        openTaxTriageWithItsBlock()
        let root = controller.viewerController.installedSurface?.viewController.view
        XCTAssertEqual(root?.accessibilityIdentifier(), "taxtriage-result-view")
        XCTAssertEqual(root?.isAccessibilityElement(), true, "a plain NSView root is left out of the accessibility tree")
        XCTAssertEqual(root?.accessibilityRole(), .group)
    }

    // MARK: - Its own kind

    /// A second TaxTriage batch replaces the first: one viewer, showing the second batch, and the second batch's block
    /// arrives after the old viewer took its own out (no skip and no flag).
    func testASecondTaxTriageResultReplacesTheFirstAndKeepsItsOwnBlock() {
        openTaxTriageWithItsBlock()
        controller.displayContent(for: item(secondTaxTriage, .batchGroup))
        XCTAssertEqual(summary.batchOperationTool, "TaxTriage", "the second TaxTriage batch lost its block")
        XCTAssertEqual(controller.viewerController.children.filter { $0 is TaxTriageResultViewController }.count, 1)
        XCTAssertEqual(
            controller.viewerController.taxTriageViewController?.batchGroupURL?.standardizedFileURL,
            secondTaxTriage.standardizedFileURL
        )
    }

    // MARK: - Helpers

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    /// Opens the first TaxTriage batch, which shows it and gives the Summary its block in the same turn.
    private func openTaxTriageWithItsBlock(file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: item(taxTriage, .batchGroup))
        XCTAssertNotNil(controller.viewerController.taxTriageViewController, "the TaxTriage batch is shown", file: file, line: line)
        XCTAssertEqual(summary.batchOperationTool, "TaxTriage", "the TaxTriage batch gave no block", file: file, line: line)
    }

    /// The routing fixture's TaxTriage database and its analysis metadata.
    private func makeTaxTriageBatch(named name: String) throws -> URL {
        let batch = try RoutingSafetyNetFixtures.taxTriageResult(named: name, in: root, samples: ["HG002"])
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true, created: Date()),
            to: batch
        )
        return batch
    }

    private func item(_ url: URL, _ type: SidebarItemType) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: type, url: url)
    }
}
