// Kraken2SurfaceRouteTests.swift - The Kraken2 result leaves the Summary with its viewer (Phase 3.1 lane K2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A Kraken2 result gives the Summary an Operation Details block named Kraken2. A later 12S or FASTQ item kept that
// block, because only the next classifier display cleared it (NET-UX row 4, INSPECTOR-BLOCK-OWNER). The Kraken2
// viewer now opens through the surface host, its surface takes out a block named Kraken2, and no other, when the host
// removes it, and View > Show Drawer reaches its Collections and BLAST Results drawer through the host (NAOMGS-ARCH
// carry list, items 1 to 3 and 9).
//
// Each test opens a Kraken2 result as the sidebar does (`displayContent(for:)`). The result is the routing fixture's
// Kraken2 database with the analysis metadata and the classification sidecar written beside it, so the Summary gets
// the Kraken2 block. As in `TaxTriageSurfaceRouteTests`, the test methods are synchronous and wait by turning the
// main run loop.

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxonomyUI
@testable import LungfishWorkflow

/// A surface whose load always fails, so the Kraken2 show never installs.
@MainActor
private final class RefusingKraken2Surface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.kraken2) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(surfaceKind)
    }
}

@MainActor
final class Kraken2SurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var kraken2: URL!
    private var secondKraken2: URL!

    /// The Kraken2 view may save its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?
    /// The drawer's open state and height go to this suite, never the standard defaults.
    private var drawerDefaults: TestDefaultsSuite?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "kraken2-surface-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        let suite = TestDefaultsSuite(prefix: "Kraken2SurfaceRouteTests")
        drawerDefaults = suite
        TaxaCollectionsDrawerSeams.defaults = suite.defaults
        kraken2 = try makeKraken2Result(named: "kraken2-2026-10-31T10-00-00", sample: "SRR12486983")
        secondKraken2 = try makeKraken2Result(named: "kraken2-2026-10-31T11-00-00", sample: "SRR12486989")
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
        TaxaCollectionsDrawerSeams.defaults = .standard
        drawerDefaults = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A 12S result and a FASTQ bundle, each opened after a Kraken2 result, hold no Kraken2 block.
    func testA12SResultOrAFASTQBundleAfterKraken2HoldsNoKraken2Block() async throws {
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
            openKraken2WithItsBlock()
            controller.displayContent(for: result.item)
            XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { result.isShown() }, "\(result.name) never opened")
            XCTAssertNotEqual(
                summary.batchOperationTool, "Kraken2",
                "\(result.name) opened after a Kraken2 result must hold no Kraken2 block"
            )
        }
    }

    /// The viewer's teardown takes the Kraken2 block out, and only that block. A block of another tool, such as
    /// TaxTriage's Operation Details, stays (NAOMGS-ARCH item 2, match the shared block by its content).
    func testTheKraken2ViewerTakesOnlyItsOwnBlockWhenItLeaves() {
        openKraken2WithItsBlock()
        controller.viewerController.hideTaxonomyView()
        XCTAssertNil(summary.batchOperationTool, "the Kraken2 block must leave with the Kraken2 viewer")

        openKraken2WithItsBlock()
        controller.inspectorController.updateBatchOperationDetails(
            tool: "TaxTriage", parameters: [:], timestamp: nil, sourceSamples: []
        )
        controller.viewerController.hideTaxonomyView()
        XCTAssertEqual(summary.batchOperationTool, "TaxTriage", "the leaving Kraken2 viewer wiped another tool's block")
        XCTAssertFalse(controller.viewerController.children.contains { $0 is TaxonomyViewController })
        XCTAssertNil(controller.viewerController.taxonomyViewController)
    }

    /// A Kraken2 viewer that does not open says what happened and what to try, with no internal kind id, and gives
    /// the Summary no block (NAOMGS-ARCH item 3).
    func testAKraken2ResultThatDoesNotOpenSaysWhatToTry() {
        controller.viewerController.surfaceHost.registry.register(.analysis(.kraken2)) { RefusingKraken2Surface() }
        controller.displayContent(for: item(kraken2, .classificationResult))

        let viewer = controller.viewerController!
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            viewer.statusBar.positionLabel.stringValue.contains("Unable to open the Kraken2 result.")
        }, "no failure words: \(viewer.statusBar.positionLabel.stringValue)")
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Select it again."), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertFalse(viewer.children.contains { $0 is TaxonomyViewController })
        XCTAssertNil(viewer.taxonomyViewController)
        XCTAssertNil(summary.batchOperationTool)
    }

    /// The CLI route's display (`displayTaxonomyResult`) has its own catch. A viewer that does not open says what
    /// to try in the same words, names no internal kind id and leaves no Kraken2 child (NAOMGS-ARCH item 3,
    /// K2-ARCH B1).
    func testACliShownKraken2ResultThatDoesNotOpenSaysWhatToTry() {
        let viewer = controller.viewerController!
        viewer.surfaceHost.registry.register(.analysis(.kraken2)) { RefusingKraken2Surface() }

        viewer.displayTaxonomyResult(makeCliResult())

        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            viewer.statusBar.positionLabel.stringValue.contains("Unable to open the Kraken2 result.")
        }, "no failure words: \(viewer.statusBar.positionLabel.stringValue)")
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Select it again."), words)
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        XCTAssertFalse(viewer.children.contains { $0 is TaxonomyViewController })
        XCTAssertNil(viewer.taxonomyViewController)
    }

    /// View > Show Drawer and the toolbar button open and close the Kraken2 Collections and BLAST Results drawer
    /// through the host, which asks the installed surface first (NAOMGS-ARCH item 9, the second arm).
    func testShowDrawerTogglesTheKraken2DrawerThroughTheHost() {
        openKraken2WithItsBlock()
        let viewer = controller.viewerController!
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .analysis(.kraken2), "the Kraken2 viewer is not on the host")
        XCTAssertFalse(viewer.isActiveDrawerOpen)

        viewer.toggleAnnotationDrawer()
        XCTAssertEqual(viewer.installedSurface?.isDrawerOpen, true, "the host's surface must answer for the drawer")
        XCTAssertTrue(viewer.isActiveDrawerOpen)
        XCTAssertEqual(viewer.taxonomyViewController?.isTaxaCollectionsDrawerOpen, true)

        viewer.toggleAnnotationDrawer()
        XCTAssertEqual(viewer.installedSurface?.isDrawerOpen, false)
        XCTAssertFalse(viewer.isActiveDrawerOpen)
        XCTAssertEqual(viewer.taxonomyViewController?.isTaxaCollectionsDrawerOpen, false)
    }

    /// The view switch smoke test finds the Kraken2 viewer by its identifier (lane SMOKE's request).
    func testTheKraken2ResultViewCarriesItsIdentifier() {
        openKraken2WithItsBlock()
        XCTAssertEqual(
            controller.viewerController.taxonomyViewController?.view.accessibilityIdentifier(), "kraken2-result-view"
        )
    }

    // MARK: - Its own kind

    /// A second Kraken2 result replaces the first: one viewer, showing the second result, and the second result's
    /// block arrives after the old viewer took its own out (no skip and no flag).
    func testASecondKraken2ResultReplacesTheFirstAndKeepsItsOwnBlock() {
        openKraken2WithItsBlock()
        controller.displayContent(for: item(secondKraken2, .classificationResult))
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            self.controller.viewerController.taxonomyViewController?.batchURL?.standardizedFileURL
                == self.secondKraken2.standardizedFileURL
        }, "the second Kraken2 result never opened")
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the second Kraken2 result lost its block")
        XCTAssertEqual(controller.viewerController.children.filter { $0 is TaxonomyViewController }.count, 1)
    }

    // MARK: - Helpers

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    /// Opens the first Kraken2 result, which shows it and gives the Summary its block.
    private func openKraken2WithItsBlock(file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: item(kraken2, .classificationResult))
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            self.controller.viewerController.taxonomyViewController?.batchURL?.standardizedFileURL
                == self.kraken2.standardizedFileURL && self.summary.batchOperationTool == "Kraken2"
        }, "the Kraken2 result is shown with its block", file: file, line: line)
    }

    /// The routing fixture's Kraken2 database, its analysis metadata and the classification sidecar that gives the
    /// Summary its Operation Details.
    private func makeKraken2Result(named name: String, sample: String) throws -> URL {
        let result = try RoutingSafetyNetFixtures.kraken2Result(named: name, in: root, samples: [sample])
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: false, created: Date()),
            to: result
        )
        let sidecar = """
        {"config":{"databaseName":"Viral","databaseVersion":"2026-01","goal":"profile","confidence":0.2,\
        "minimumHitGroups":2,"threads":1,"sampleDisplayName":"\(sample)"},\
        "toolVersion":"2.1.3","runtime":42,"savedAt":"2026-10-01T00:00:00Z"}
        """
        try sidecar.write(
            to: result.appendingPathComponent(ClassificationResult.sidecarFilename), atomically: true, encoding: .utf8
        )
        return result
    }

    /// A loaded Kraken2 result as the CLI route hands it to the viewer, a root with one species, in this test's folder.
    private func makeCliResult() -> ClassificationResult {
        let rootNode = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )
        let species = TaxonNode(
            taxId: 562, name: "Escherichia coli", rank: .species, depth: 1,
            readsDirect: 100, readsClade: 100, fractionClade: 1.0, fractionDirect: 1.0, parentTaxId: 1
        )
        species.parent = rootNode
        rootNode.children = [species]
        let folder = root.appendingPathComponent("kraken2-cli-result", isDirectory: true)
        let config = ClassificationConfig(
            inputFiles: [folder.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: folder.appendingPathComponent("db"),
            outputDirectory: folder
        )
        return ClassificationResult(
            config: config,
            tree: TaxonTree(root: rootNode, unclassifiedNode: nil, totalReads: 100),
            reportURL: folder.appendingPathComponent("classification.kreport"),
            outputURL: folder.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }

    private func item(_ url: URL, _ type: SidebarItemType) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: type, url: url)
    }
}
