// EsVirituSurfaceRouteTests.swift - The EsViritu result leaves the Summary with its viewer (Phase 3.1 lane ESV)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An EsViritu batch whose folder holds a batch manifest gives the Summary an Operation Details block named EsViritu.
// A later 12S or FASTQ item kept that block, because only the next classifier display cleared it, as NET-UX row 4
// (INSPECTOR-BLOCK-OWNER) found for NAO-MGS and TaxTriage. The EsViritu viewer now opens through the surface host,
// and its surface takes out a block named EsViritu, and no other, when the host removes it (NAOMGS-ARCH carry list,
// items 1 to 3).
//
// Each test opens an EsViritu batch as the sidebar does (`displayContent(for:)`), which shows it in the same turn.
// The batch is the routing fixture's EsViritu database with the analysis metadata and a batch manifest written beside
// it. As in `NaoMgsSurfaceRouteTests`, the test methods are synchronous and wait by turning the main run loop.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

/// A surface whose load always fails, so the EsViritu show never installs.
@MainActor
private final class RefusingEsVirituSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.esviritu) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class EsVirituSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var esViritu: URL!
    private var secondEsViritu: URL!

    /// The EsViritu result view saves its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "esviritu-surface-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        esViritu = try makeEsVirituBatch(named: "esviritu-batch-2026-10-30T10-00-00")
        secondEsViritu = try makeEsVirituBatch(named: "esviritu-batch-2026-10-30T11-00-00")
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

    /// A 12S result and a FASTQ bundle, each opened after an EsViritu batch, hold no EsViritu block.
    func testA12SResultOrAFASTQBundleAfterEsVirituHoldsNoEsVirituBlock() async throws {
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
            openEsVirituWithItsBlock()
            controller.displayContent(for: result.item)
            XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { result.isShown() }, "\(result.name) never opened")
            XCTAssertNotEqual(
                summary.batchOperationTool, "EsViritu",
                "\(result.name) opened after an EsViritu batch must hold no EsViritu block"
            )
        }
    }

    /// The viewer's teardown takes the EsViritu block out, and only that block. A block of another tool, such as
    /// Kraken2's Operation Details, stays (NAOMGS-ARCH item 2, match the shared block by its content).
    func testTheEsVirituViewerTakesOnlyItsOwnBlockWhenItLeaves() {
        openEsVirituWithItsBlock()
        controller.viewerController.hideEsVirituView()
        XCTAssertNil(summary.batchOperationTool, "the EsViritu block must leave with the EsViritu viewer")

        openEsVirituWithItsBlock()
        controller.inspectorController.updateBatchOperationDetails(
            tool: "Kraken2", parameters: [:], timestamp: nil, sourceSamples: []
        )
        controller.viewerController.hideEsVirituView()
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the leaving EsViritu viewer wiped another tool's block")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is EsVirituResultViewController })
        XCTAssertNil(controller.viewerController.esVirituViewController)
    }

    /// An EsViritu viewer that does not open says what happened and what to try, with no internal kind id, and
    /// gives the Summary no block (NAOMGS-ARCH item 3).
    func testAnEsVirituResultThatDoesNotOpenSaysWhatToTry() {
        controller.viewerController.surfaceHost.registry.register(.analysis(.esviritu)) { RefusingEsVirituSurface() }
        controller.displayContent(for: item(esViritu, .batchGroup))

        let words = controller.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the EsViritu result."), words)
        XCTAssertTrue(words.contains("Select it again."), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is EsVirituResultViewController })
        XCTAssertNil(controller.viewerController.esVirituViewController)
        XCTAssertNil(summary.batchOperationTool)
    }

    // MARK: - Its own kind

    /// A second EsViritu batch replaces the first: one viewer, showing the second batch, and the second batch's block
    /// arrives after the old viewer took its own out (no skip and no flag).
    func testASecondEsVirituResultReplacesTheFirstAndKeepsItsOwnBlock() {
        openEsVirituWithItsBlock()
        controller.displayContent(for: item(secondEsViritu, .batchGroup))
        XCTAssertEqual(summary.batchOperationTool, "EsViritu", "the second EsViritu batch lost its block")
        XCTAssertEqual(controller.viewerController.children.filter { $0 is EsVirituResultViewController }.count, 1)
        XCTAssertEqual(
            controller.viewerController.esVirituViewController?.batchURL?.standardizedFileURL,
            secondEsViritu.standardizedFileURL
        )
    }

    // MARK: - Helpers

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    /// Opens the first EsViritu batch, which shows it and gives the Summary its block in the same turn.
    private func openEsVirituWithItsBlock(file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: item(esViritu, .batchGroup))
        XCTAssertNotNil(controller.viewerController.esVirituViewController, "the EsViritu batch is shown", file: file, line: line)
        XCTAssertEqual(summary.batchOperationTool, "EsViritu", "the EsViritu batch gave no block", file: file, line: line)
    }

    /// The routing fixture's EsViritu database, its analysis metadata and the batch manifest that gives the block.
    private func makeEsVirituBatch(named name: String) throws -> URL {
        let batch = try RoutingSafetyNetFixtures.esVirituResult(named: name, in: root, samples: ["SRR12486983"])
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "esviritu", isBatch: true, created: Date()),
            to: batch
        )
        try MetagenomicsBatchResultStore.saveEsViritu(
            EsVirituBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(schemaVersion: 1, createdAt: Date(), sampleCount: 1),
                summaryTSV: "esviritu-batch-summary.tsv",
                samples: [MetagenomicsBatchSampleRecord(
                    sampleId: "SRR12486983", resultDirectory: "SRR12486983", inputFiles: [], isPairedEnd: false
                )]
            ),
            to: batch
        )
        return batch
    }

    private func item(_ url: URL, _ type: SidebarItemType) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: type, url: url)
    }
}
