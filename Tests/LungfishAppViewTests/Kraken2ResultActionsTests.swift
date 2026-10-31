// Kraken2ResultActionsTests.swift - Kraken2 takes the shared classifier actions (Phase 3.1 lane K2, milestone 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Kraken2 kept its own BLAST Results toggle (no tooltip and no hint), its own bar, and menu words that no other
// classifier uses: BLAST Matching Reads…, Copy Taxon Name and a Look Up on NCBI submenu. It now takes the bar of
// `ClassifierResultActions` with its BLAST Results button, which shows or hides the drawer's BLAST tab, and the
// menus take the shared row words of UX-3E-LABELS (approved as O86, section 4).

import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishTestSupport
@testable import LungfishTaxonomyUI

@MainActor
final class Kraken2ResultActionsTests: XCTestCase {
    /// The drawer's open state and height go to this suite, never the standard defaults.
    private var drawerDefaults: TestDefaultsSuite?

    override func setUp() async throws {
        try await super.setUp()
        let suite = TestDefaultsSuite(prefix: "Kraken2ResultActionsTests")
        drawerDefaults = suite
        TaxaCollectionsDrawerSeams.defaults = suite.defaults
    }

    override func tearDown() async throws {
        TaxaCollectionsDrawerSeams.defaults = .standard
        drawerDefaults = nil
        try await super.tearDown()
    }

    /// The bar holds one BLAST Results button, the shared one, with its tooltip, label and hint.
    func testTheBarHoldsTheSharedBLASTResultsButton() throws {
        let controller = makeController()
        let button = try XCTUnwrap(blastResultsButton(of: controller), "Kraken2's bar has no BLAST Results button of the shared component")
        XCTAssertEqual(button.title, ClassifierActionWords.blastResultsTitle)
        XCTAssertEqual(button.toolTip, ClassifierActionWords.blastResultsTooltip)
        XCTAssertEqual(button.accessibilityLabel(), ClassifierActionWords.blastResultsTitle)
        XCTAssertEqual(button.accessibilityHelp(), ClassifierActionWords.blastResultsHint)
        let titled = buttons(in: controller.testActionBar).filter { $0.title == ClassifierActionWords.blastResultsTitle }
        XCTAssertEqual(titled.count, 1, "the bar holds one BLAST Results button")
    }

    /// BLAST Results opens the drawer on its BLAST tab and closes it again, and the button follows the drawer when
    /// View > Show Drawer opens and closes it.
    func testBLASTResultsShowsAndHidesTheDrawersBLASTTab() throws {
        let controller = makeController()
        let button = try XCTUnwrap(blastResultsButton(of: controller), "Kraken2's bar has no BLAST Results button of the shared component")

        button.performClick(nil)
        XCTAssertTrue(controller.isTaxaCollectionsDrawerOpen, "BLAST Results opens the drawer")
        XCTAssertEqual(controller.taxaCollectionsDrawerView?.selectedTab, .blastResults)
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(controller.collectionsToggleButton.state, .off)

        button.performClick(nil)
        XCTAssertFalse(controller.isTaxaCollectionsDrawerOpen, "BLAST Results closes the drawer it opened")
        XCTAssertEqual(button.state, .off)

        controller.toggleTaxaCollectionsDrawer()
        XCTAssertEqual(button.state, .on, "the drawer opens on the BLAST tab it showed last, and the button says so")
        controller.toggleTaxaCollectionsDrawer()
        XCTAssertEqual(button.state, .off)
    }

    /// The table's menu and the chart's menu use the shared row words, with the NCBI commands as flat items.
    func testTheMenusUseTheSharedRowWords() throws {
        let controller = makeController()
        let tableTitles = try XCTUnwrap(controller.testTableView.testingContextMenu).items.map(\.title)
        for title in ["Verify with BLAST\u{2026}", "Copy Name", "Open Taxonomy on NCBI", "Open GenBank Record", "Search PubMed"] {
            XCTAssertTrue(tableTitles.contains(title), "the table's menu offers \(title)")
        }
        for old in ["BLAST Matching Reads\u{2026}", "Copy Taxon Name", "Look Up on NCBI"] {
            XCTAssertFalse(tableTitles.contains(old), "the table's menu still offers \(old)")
        }
        XCTAssertTrue(try XCTUnwrap(controller.testTableView.testingContextMenu).items.allSatisfy { $0.submenu == nil })

        let ecoli = try XCTUnwrap(controller.tree?.node(taxId: 562))
        let chartTitles = controller.contextMenuItems(for: ecoli).map(\.title)
        XCTAssertTrue(chartTitles.contains("Verify with BLAST\u{2026}"), "the chart's menu offers Verify with BLAST…")
        XCTAssertTrue(chartTitles.contains("Copy Name"), "the chart's menu offers Copy Name")
        XCTAssertFalse(chartTitles.contains("Copy Taxon Name"))
    }

    /// Several picked rows read as rows in the bar, as in the other classifier viewers.
    func testSeveralRowsReadAsRowsSelected() throws {
        let controller = makeController()
        controller.testTableView.onMultipleNodesSelected?(2)
        XCTAssertEqual(controller.testActionBar.infoLabel.stringValue, "2 rows selected")
    }

    // MARK: - Helpers

    private func makeController() -> TaxonomyViewController {
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configure(result: makeResult())
        return controller
    }

    private func blastResultsButton(of controller: TaxonomyViewController) -> NSButton? {
        buttons(in: controller.testActionBar).first { $0.accessibilityIdentifier() == "classifier-result-blast-results" }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    /// A root with Escherichia coli and Archaea under it.
    private func makeResult() -> ClassificationResult {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 1000, fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )
        let ecoli = TaxonNode(
            taxId: 562, name: "Escherichia coli", rank: .species, depth: 1,
            readsDirect: 800, readsClade: 800, fractionClade: 0.8, fractionDirect: 0.8, parentTaxId: 1
        )
        let archaea = TaxonNode(
            taxId: 2157, name: "Archaea", rank: .domain, depth: 1,
            readsDirect: 200, readsClade: 200, fractionClade: 0.2, fractionDirect: 0.2, parentTaxId: 1
        )
        ecoli.parent = root
        archaea.parent = root
        root.children = [ecoli, archaea]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kraken2-result-actions-\(UUID().uuidString)")
        let config = ClassificationConfig(
            inputFiles: [folder.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: folder.appendingPathComponent("db"),
            outputDirectory: folder
        )
        return ClassificationResult(
            config: config,
            tree: TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1000),
            reportURL: folder.appendingPathComponent("classification.kreport"),
            outputURL: folder.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }
}
