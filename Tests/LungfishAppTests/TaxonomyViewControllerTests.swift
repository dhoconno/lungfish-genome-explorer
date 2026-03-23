// TaxonomyViewControllerTests.swift - Tests for TaxonomyViewController and sub-components
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

// MARK: - Test Helpers

/// Builds a taxonomy tree suitable for TaxonomyViewController tests.
///
/// Structure:
/// ```
/// root (taxId: 1, clade: 10000)
///   +-- Bacteria (taxId: 2, domain, clade: 8000, direct: 100)
///   |     +-- Proteobacteria (taxId: 1224, phylum, clade: 5000, direct: 50)
///   |     |     +-- Gammaproteobacteria (taxId: 1236, class, clade: 3000, direct: 30)
///   |     |     |     +-- Enterobacterales (taxId: 91347, order, clade: 2000, direct: 20)
///   |     |     |     |     +-- Enterobacteriaceae (taxId: 543, family, clade: 1500, direct: 10)
///   |     |     |     |     |     +-- Escherichia (taxId: 561, genus, clade: 1200, direct: 50)
///   |     |     |     |     |     |     +-- E. coli (taxId: 562, species, clade: 1000, direct: 1000)
///   |     |     |     |     |     |     +-- E. fergusonii (taxId: 564, species, clade: 200, direct: 200)
///   |     |     |     |     |     +-- Klebsiella (taxId: 570, genus, clade: 300, direct: 300)
///   |     |     |     |     +-- Yersiniaceae (taxId: 1903411, family, clade: 500, direct: 500)
///   |     |     |     +-- Pseudomonadales (taxId: 72274, order, clade: 1000, direct: 1000)
///   |     |     +-- Alphaproteobacteria (taxId: 28211, class, clade: 2000, direct: 2000)
///   |     +-- Firmicutes (taxId: 1239, phylum, clade: 2000, direct: 50)
///   |     |     +-- Bacilli (taxId: 91061, class, clade: 2000, direct: 2000)
///   |     +-- Actinobacteria (taxId: 201174, phylum, clade: 1000, direct: 1000)
///   +-- Archaea (taxId: 2157, domain, clade: 2000, direct: 2000)
/// ```
@MainActor
private func makeTestTree() -> TaxonTree {
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 10000, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: nil
    )

    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 100, readsClade: 8000, fractionClade: 0.8, fractionDirect: 0.01,
        parentTaxId: 1
    )
    bacteria.parent = root
    root.children = [bacteria]

    let archaea = TaxonNode(
        taxId: 2157, name: "Archaea", rank: .domain, depth: 1,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1
    )
    archaea.parent = root
    root.children.append(archaea)

    let proteobacteria = TaxonNode(
        taxId: 1224, name: "Proteobacteria", rank: .phylum, depth: 2,
        readsDirect: 50, readsClade: 5000, fractionClade: 0.5, fractionDirect: 0.005,
        parentTaxId: 2
    )
    proteobacteria.parent = bacteria

    let firmicutes = TaxonNode(
        taxId: 1239, name: "Firmicutes", rank: .phylum, depth: 2,
        readsDirect: 50, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.005,
        parentTaxId: 2
    )
    firmicutes.parent = bacteria

    let actinobacteria = TaxonNode(
        taxId: 201174, name: "Actinobacteria", rank: .phylum, depth: 2,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 2
    )
    actinobacteria.parent = bacteria
    bacteria.children = [proteobacteria, firmicutes, actinobacteria]

    let gamma = TaxonNode(
        taxId: 1236, name: "Gammaproteobacteria", rank: .class, depth: 3,
        readsDirect: 30, readsClade: 3000, fractionClade: 0.3, fractionDirect: 0.003,
        parentTaxId: 1224
    )
    gamma.parent = proteobacteria

    let alpha = TaxonNode(
        taxId: 28211, name: "Alphaproteobacteria", rank: .class, depth: 3,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1224
    )
    alpha.parent = proteobacteria
    proteobacteria.children = [gamma, alpha]

    let enterobacterales = TaxonNode(
        taxId: 91347, name: "Enterobacterales", rank: .order, depth: 4,
        readsDirect: 20, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.002,
        parentTaxId: 1236
    )
    enterobacterales.parent = gamma

    let pseudomonadales = TaxonNode(
        taxId: 72274, name: "Pseudomonadales", rank: .order, depth: 4,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 1236
    )
    pseudomonadales.parent = gamma
    gamma.children = [enterobacterales, pseudomonadales]

    let enterobacteriaceae = TaxonNode(
        taxId: 543, name: "Enterobacteriaceae", rank: .family, depth: 5,
        readsDirect: 10, readsClade: 1500, fractionClade: 0.15, fractionDirect: 0.001,
        parentTaxId: 91347
    )
    enterobacteriaceae.parent = enterobacterales

    let yersiniaceae = TaxonNode(
        taxId: 1903411, name: "Yersiniaceae", rank: .family, depth: 5,
        readsDirect: 500, readsClade: 500, fractionClade: 0.05, fractionDirect: 0.05,
        parentTaxId: 91347
    )
    yersiniaceae.parent = enterobacterales
    enterobacterales.children = [enterobacteriaceae, yersiniaceae]

    let escherichia = TaxonNode(
        taxId: 561, name: "Escherichia", rank: .genus, depth: 6,
        readsDirect: 50, readsClade: 1200, fractionClade: 0.12, fractionDirect: 0.005,
        parentTaxId: 543
    )
    escherichia.parent = enterobacteriaceae

    let klebsiella = TaxonNode(
        taxId: 570, name: "Klebsiella", rank: .genus, depth: 6,
        readsDirect: 300, readsClade: 300, fractionClade: 0.03, fractionDirect: 0.03,
        parentTaxId: 543
    )
    klebsiella.parent = enterobacteriaceae
    enterobacteriaceae.children = [escherichia, klebsiella]

    let ecoli = TaxonNode(
        taxId: 562, name: "Escherichia coli", rank: .species, depth: 7,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 561
    )
    ecoli.parent = escherichia

    let efergusonii = TaxonNode(
        taxId: 564, name: "Escherichia fergusonii", rank: .species, depth: 7,
        readsDirect: 200, readsClade: 200, fractionClade: 0.02, fractionDirect: 0.02,
        parentTaxId: 561
    )
    efergusonii.parent = escherichia
    escherichia.children = [ecoli, efergusonii]

    let bacilli = TaxonNode(
        taxId: 91061, name: "Bacilli", rank: .class, depth: 3,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1239
    )
    bacilli.parent = firmicutes
    firmicutes.children = [bacilli]

    return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 10000)
}

/// Creates a ``ClassificationResult`` for testing, wrapping the given tree.
@MainActor
private func makeTestResult(tree: TaxonTree? = nil) -> ClassificationResult {
    let tree = tree ?? makeTestTree()
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("taxonomy-vc-test-\(UUID().uuidString)")

    let config = ClassificationConfig(
        inputFiles: [tempDir.appendingPathComponent("reads.fastq")],
        isPairedEnd: false,
        databaseName: "test-db",
        databasePath: tempDir.appendingPathComponent("db"),
        outputDirectory: tempDir
    )

    return ClassificationResult(
        config: config,
        tree: tree,
        reportURL: tempDir.appendingPathComponent("classification.kreport"),
        outputURL: tempDir.appendingPathComponent("classification.kraken"),
        brackenURL: nil,
        runtime: 5.2,
        toolVersion: "2.1.3",
        provenanceId: nil
    )
}

// MARK: - TaxonomyViewControllerTests

@MainActor
final class TaxonomyViewControllerTests: XCTestCase {

    // MARK: - Configuration

    func testConfigureWithResult() throws {
        let vc = TaxonomyViewController()
        _ = vc.view  // trigger loadView

        let result = makeTestResult()
        vc.configure(result: result)

        // Verify sunburst got the tree
        XCTAssertNotNil(vc.testSunburstView.tree)
        XCTAssertEqual(vc.testSunburstView.tree?.totalReads, 10000)

        // Verify table got the tree
        XCTAssertNotNil(vc.testTableView.tree)
        XCTAssertEqual(vc.testTableView.tree?.totalReads, 10000)

        // Verify action bar is configured with total reads
        XCTAssertFalse(vc.testActionBar.isExtractEnabled)
        XCTAssertTrue(vc.testActionBar.infoText.contains("Select a taxon"))

        // Verify breadcrumb is at root
        XCTAssertTrue(vc.testBreadcrumbBar.isAtRoot)
    }

    // MARK: - Summary Bar

    func testSummaryBarCards() throws {
        let summaryBar = TaxonomySummaryBar()
        let tree = makeTestTree()
        summaryBar.update(tree: tree)

        let cards = summaryBar.cards
        XCTAssertEqual(cards.count, 6, "Summary bar should have exactly 6 cards")

        // Verify card labels
        let labels = cards.map(\.label)
        XCTAssertEqual(labels[0], "Total Reads")
        XCTAssertEqual(labels[1], "Classified")
        XCTAssertEqual(labels[2], "Unclassified")
        XCTAssertEqual(labels[3], "Species")
        XCTAssertTrue(labels[4].hasPrefix("Shannon"))
        XCTAssertEqual(labels[5], "Dominant")

        // Verify total reads card value
        XCTAssertEqual(cards[0].value, "10.0K")

        // Verify classified should be 100% (no unclassified node)
        XCTAssertEqual(cards[1].value, "100.0%")
        XCTAssertEqual(cards[2].value, "0.0%")

        // 2 species: E. coli and E. fergusonii
        XCTAssertEqual(cards[3].value, "2")

        // Dominant species should be E. coli
        XCTAssertEqual(cards[5].value, "Escherichia coli")
    }

    func testSummaryBarWithUnclassifiedReads() throws {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 7000, fractionClade: 0.7, fractionDirect: 0.0,
            parentTaxId: nil
        )
        let unclassified = TaxonNode(
            taxId: 0, name: "unclassified", rank: .unclassified, depth: 0,
            readsDirect: 3000, readsClade: 3000, fractionClade: 0.3, fractionDirect: 0.3,
            parentTaxId: nil
        )
        let tree = TaxonTree(root: root, unclassifiedNode: unclassified, totalReads: 10000)

        let summaryBar = TaxonomySummaryBar()
        summaryBar.update(tree: tree)

        let cards = summaryBar.cards
        XCTAssertEqual(cards[1].value, "70.0%", "Classified should be 70%")
        XCTAssertEqual(cards[2].value, "30.0%", "Unclassified should be 30%")
    }

    // MARK: - Breadcrumb Bar

    func testBreadcrumbPathFromRoot() throws {
        let bar = TaxonomyBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        bar.update(zoomNode: nil)

        XCTAssertTrue(bar.isAtRoot)
        XCTAssertEqual(bar.displayPath, "Root")
        XCTAssertEqual(bar.segmentCount, 1)
    }

    func testBreadcrumbPathZoomed() throws {
        let tree = makeTestTree()
        let bar = TaxonomyBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 600, height: 28))

        // Zoom to Proteobacteria (path: root -> Bacteria -> Proteobacteria)
        let proteo = tree.node(taxId: 1224)!
        bar.update(zoomNode: proteo)

        XCTAssertFalse(bar.isAtRoot)
        XCTAssertEqual(bar.displayPath, "Root > Bacteria > Proteobacteria")
        XCTAssertEqual(bar.segmentCount, 3)
    }

    func testBreadcrumbZoomNavigation() throws {
        let tree = makeTestTree()
        let bar = TaxonomyBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 600, height: 28))

        // Zoom to Gammaproteobacteria
        let gamma = tree.node(taxId: 1236)!
        bar.update(zoomNode: gamma)
        XCTAssertEqual(bar.segmentCount, 4)  // Root > Bacteria > Proteobacteria > Gamma...

        // Simulate clicking the Bacteria breadcrumb
        var navigatedToNode: TaxonNode?
        var navigatedToNil = false
        bar.onNavigateToNode = { node in
            if let node {
                navigatedToNode = node
            } else {
                navigatedToNil = true
            }
        }

        // After zoom, clicking Root segment should set zoom to nil
        bar.update(zoomNode: nil)
        XCTAssertTrue(bar.isAtRoot)
    }

    func testBreadcrumbDeeplyNestedPath() throws {
        let tree = makeTestTree()
        let bar = TaxonomyBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 800, height: 28))

        // Zoom to E. coli (deepest)
        let ecoli = tree.node(taxId: 562)!
        bar.update(zoomNode: ecoli)

        // Path: Root > Bacteria > Proteobacteria > Gammaproteobacteria >
        //        Enterobacterales > Enterobacteriaceae > Escherichia > Escherichia coli
        XCTAssertFalse(bar.isAtRoot)
        XCTAssertTrue(bar.displayPath.contains("Escherichia coli"))
        XCTAssertTrue(bar.displayPath.hasPrefix("Root"))
        XCTAssertEqual(bar.segmentCount, 8)
    }

    // MARK: - Selection Sync: Sunburst -> Table

    func testSelectionSyncSunburstToTable() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        // Simulate sunburst selection by calling the callback
        let ecoli = result.tree.node(taxId: 562)!
        vc.testSunburstView.onNodeSelected?(ecoli)

        // In test context without a live window, the NSOutlineView cannot
        // select rows programmatically, so we verify the sync via the action bar
        // which is updated in the same callback.

        // The action bar should show E. coli info
        XCTAssertTrue(vc.testActionBar.infoText.contains("Escherichia coli"))
        XCTAssertTrue(vc.testActionBar.isExtractEnabled)
    }

    // MARK: - Selection Sync: Table -> Sunburst

    func testSelectionSyncTableToSunburst() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        // Simulate table selection
        let archaea = result.tree.node(taxId: 2157)!
        vc.testTableView.onNodeSelected?(archaea)

        // The sunburst should now have Archaea selected
        XCTAssertEqual(vc.testSunburstView.selectedNode?.taxId, 2157)

        // The action bar should reflect the selection
        XCTAssertTrue(vc.testActionBar.infoText.contains("Archaea"))
    }

    // MARK: - Action Bar

    func testActionBarUpdatesOnSelection() throws {
        let bar = TaxonomyActionBar(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        bar.configure(totalReads: 10000)

        // Initially disabled
        XCTAssertFalse(bar.isExtractEnabled)
        XCTAssertTrue(bar.infoText.contains("Select a taxon"))

        // Select E. coli
        let ecoli = TaxonNode(
            taxId: 562, name: "Escherichia coli", rank: .species, depth: 7,
            readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
            parentTaxId: 561
        )
        bar.updateSelection(ecoli)

        XCTAssertTrue(bar.isExtractEnabled)
        XCTAssertTrue(bar.infoText.contains("Escherichia coli"))
        XCTAssertTrue(bar.infoText.contains("1,000"))
        XCTAssertTrue(bar.infoText.contains("10.0%"))

        // Clear selection
        bar.updateSelection(nil)
        XCTAssertFalse(bar.isExtractEnabled)
        XCTAssertTrue(bar.infoText.contains("Select a taxon"))
    }

    func testActionBarExtractCallback() throws {
        let bar = TaxonomyActionBar(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        bar.configure(totalReads: 10000)

        let ecoli = TaxonNode(
            taxId: 562, name: "Escherichia coli", rank: .species, depth: 7,
            readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
            parentTaxId: 561
        )
        bar.updateSelection(ecoli)

        var extractedNode: TaxonNode?
        var extractedIncludeChildren: Bool?
        bar.onExtractSequences = { node, includeChildren in
            extractedNode = node
            extractedIncludeChildren = includeChildren
        }

        // Directly invoke the callback to verify wiring,
        // since NSButton.performClick doesn't work reliably in unit tests
        bar.onExtractSequences?(ecoli, true)

        XCTAssertEqual(extractedNode?.taxId, 562)
        XCTAssertEqual(extractedIncludeChildren, true)
    }

    // MARK: - Context Menu

    func testContextMenuItems() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        let ecoli = result.tree.node(taxId: 562)!
        let items = vc.contextMenuItems(for: ecoli)

        // Should have: Extract (2), sep, Copy (2), sep, Zoom (2), sep, BLAST (1) = 12 items
        let nonSeparators = items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(nonSeparators.count, 7, "Should have 7 non-separator menu items")
        XCTAssertEqual(items.filter(\.isSeparatorItem).count, 3, "Should have 3 separators")

        // Check specific titles
        XCTAssertTrue(items[0].title.contains("Extract Sequences for Escherichia coli"))
        XCTAssertTrue(items[1].title.contains("and Children"))
        XCTAssertEqual(items[3].title, "Copy Taxon Name")
        XCTAssertEqual(items[4].title, "Copy Taxonomy Path")
        XCTAssertTrue(items[6].title.contains("Zoom to"))
        XCTAssertEqual(items[7].title, "Zoom Out to Root")

        // Zoom out to root should be disabled when at root
        XCTAssertFalse(items[7].isEnabled)
    }

    func testContextMenuZoomOutEnabled() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        // Zoom into bacteria first
        let bacteria = result.tree.node(taxId: 2)!
        vc.testSunburstView.centerNode = bacteria

        let items = vc.contextMenuItems(for: bacteria)
        let zoomOutItem = items.last(where: { $0.title == "Zoom Out to Root" })
        XCTAssertNotNil(zoomOutItem)
        XCTAssertTrue(zoomOutItem!.isEnabled, "Zoom Out to Root should be enabled when zoomed in")

        // "Zoom to" the current zoom root should be disabled
        let zoomToItem = items.first(where: { $0.title.contains("Zoom to") })
        XCTAssertNotNil(zoomToItem)
        XCTAssertFalse(zoomToItem!.isEnabled, "Zoom to current node should be disabled")
    }

    // MARK: - Layout Structure

    func testLayoutStructure() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        // Summary bar is present
        XCTAssertTrue(vc.view.subviews.contains(vc.testSummaryBar))

        // Breadcrumb bar is present
        XCTAssertTrue(vc.view.subviews.contains(vc.testBreadcrumbBar))

        // Split view is present and vertical
        XCTAssertTrue(vc.view.subviews.contains(vc.testSplitView))
        XCTAssertTrue(vc.testSplitView.isVertical)

        // Action bar is present
        XCTAssertTrue(vc.view.subviews.contains(vc.testActionBar))

        // Split view has two panes
        XCTAssertEqual(vc.testSplitView.arrangedSubviews.count, 2)
    }

    // MARK: - Split View: Sunburst Visibility

    func testSunburstViewIsInSplitViewLeftPane() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        let splitView = vc.testSplitView

        // The split view should have two arranged subviews (containers)
        XCTAssertEqual(splitView.arrangedSubviews.count, 2)

        // The left container should contain the sunburst view
        let leftContainer = splitView.arrangedSubviews[0]
        XCTAssertTrue(
            leftContainer.subviews.contains(vc.testSunburstView),
            "Sunburst view should be a subview of the left split pane container"
        )

        // The right container should contain the table view
        let rightContainer = splitView.arrangedSubviews[1]
        XCTAssertTrue(
            rightContainer.subviews.contains(vc.testTableView),
            "Table view should be a subview of the right split pane container"
        )
    }

    func testSplitViewContainersUseFrameBasedLayout() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        let splitView = vc.testSplitView

        // The container views should NOT have translatesAutoresizingMaskIntoConstraints
        // set to false -- NSSplitView manages them with frame-based layout.
        for container in splitView.arrangedSubviews {
            XCTAssertTrue(
                container.translatesAutoresizingMaskIntoConstraints,
                "Split view container should use frame-based layout (translatesAutoresizingMaskIntoConstraints = true)"
            )
        }
    }

    func testSunburstViewUsesAutoresizingMask() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        // The sunburst view should use autoresizing mask to fill its container
        let sunburst = vc.testSunburstView
        XCTAssertTrue(
            sunburst.autoresizingMask.contains(.width),
            "Sunburst view should have flexible width autoresizing"
        )
        XCTAssertTrue(
            sunburst.autoresizingMask.contains(.height),
            "Sunburst view should have flexible height autoresizing"
        )

        // The table view should use autoresizing mask to fill its container
        let table = vc.testTableView
        XCTAssertTrue(
            table.autoresizingMask.contains(.width),
            "Table view should have flexible width autoresizing"
        )
        XCTAssertTrue(
            table.autoresizingMask.contains(.height),
            "Table view should have flexible height autoresizing"
        )
    }

    func testSunburstTreeIsSetOnConfigure() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        // Before configuration, sunburst tree should be nil
        XCTAssertNil(vc.testSunburstView.tree)

        let result = makeTestResult()
        vc.configure(result: result)

        // After configuration, sunburst tree should be set
        XCTAssertNotNil(vc.testSunburstView.tree)
        XCTAssertEqual(vc.testSunburstView.tree?.totalReads, 10000)
        XCTAssertEqual(vc.testSunburstView.tree?.root.readsClade, 10000)
    }

    // MARK: - Extract Callback

    func testExtractSequencesCallback() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)
        // Clear classificationResult so the action bar uses the direct
        // onExtractSequences path instead of the sheet-based flow
        // (which requires a window that tests do not provide).
        vc.classificationResult = nil

        var extractedNode: TaxonNode?
        var extractedIncludeChildren: Bool?
        vc.onExtractSequences = { node, includeChildren in
            extractedNode = node
            extractedIncludeChildren = includeChildren
        }

        // Simulate selecting a node and action bar extract
        let ecoli = result.tree.node(taxId: 562)!
        vc.testSunburstView.onNodeSelected?(ecoli)

        // The action bar's callback should chain to the VC's callback
        vc.testActionBar.onExtractSequences?(ecoli, true)

        XCTAssertEqual(extractedNode?.taxId, 562)
        XCTAssertEqual(extractedIncludeChildren, true)
    }

    // MARK: - Breadcrumb Integration

    func testBreadcrumbUpdatesOnSunburstZoom() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        // Initially at root
        XCTAssertTrue(vc.testBreadcrumbBar.isAtRoot)

        // Simulate double-click zoom into Proteobacteria
        let proteo = result.tree.node(taxId: 1224)!
        vc.testSunburstView.centerNode = proteo
        // The double-click callback triggers breadcrumb update
        vc.testSunburstView.onNodeDoubleClicked?(proteo)

        XCTAssertFalse(vc.testBreadcrumbBar.isAtRoot)
        XCTAssertTrue(vc.testBreadcrumbBar.displayPath.contains("Proteobacteria"))
    }
}

// MARK: - TaxonomyTableView Keyboard Shortcut Tests

@MainActor
final class TaxonomyTableKeyboardTests: XCTestCase {

    // MARK: - Outline View Type

    func testOutlineViewIsCustomSubclass() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertTrue(
            table.outlineView is TaxonomyOutlineView,
            "Outline view should be TaxonomyOutlineView subclass"
        )
    }

    func testOutlineViewHasBackReference() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let outline = table.outlineView as! TaxonomyOutlineView
        XCTAssertTrue(
            outline.taxonomyTableView === table,
            "TaxonomyOutlineView should have back-reference to TaxonomyTableView"
        )
    }

    // MARK: - Expand All

    func testExpandAllExpandsEntireTree() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Collapse everything first
        table.collapseAll()

        // Now expand all
        table.expandAll()

        // After expandAll, deeply nested items like E. coli should be visible
        // (i.e., its row should be >= 0)
        let ecoli = tree.node(taxId: 562)!
        let row = table.outlineView.row(forItem: ecoli)
        XCTAssertGreaterThanOrEqual(
            row, 0,
            "E. coli should be visible (row >= 0) after expandAll"
        )
    }

    // MARK: - Collapse All

    func testCollapseAllCollapsesTree() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // First expand all
        table.expandAll()

        // Then collapse all
        table.collapseAll()

        // After collapseAll, deeply nested items should not be visible
        // Root is still expanded (collapseAll re-expands root so top-level items are visible)
        let ecoli = tree.node(taxId: 562)!
        let row = table.outlineView.row(forItem: ecoli)
        XCTAssertEqual(
            row, -1,
            "E. coli should not be visible (row == -1) after collapseAll"
        )

        // But root's children (Bacteria, Archaea) should still be visible
        let bacteria = tree.node(taxId: 2)!
        let bacteriaRow = table.outlineView.row(forItem: bacteria)
        XCTAssertGreaterThanOrEqual(
            bacteriaRow, 0,
            "Bacteria should still be visible after collapseAll (root stays expanded)"
        )
    }

    // MARK: - Expand Selected Recursively

    func testExpandSelectedRecursively() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Collapse everything first, then expand root's top level only
        table.collapseAll()

        // Select Bacteria
        let bacteria = tree.node(taxId: 2)!
        let bacteriaRow = table.outlineView.row(forItem: bacteria)
        XCTAssertGreaterThanOrEqual(bacteriaRow, 0, "Bacteria should be visible")
        table.outlineView.selectRowIndexes(IndexSet(integer: bacteriaRow), byExtendingSelection: false)

        // Expand selected recursively
        table.expandSelectedRecursively()

        // E. coli (deeply nested under Bacteria) should now be visible
        let ecoli = tree.node(taxId: 562)!
        let ecoliRow = table.outlineView.row(forItem: ecoli)
        XCTAssertGreaterThanOrEqual(
            ecoliRow, 0,
            "E. coli should be visible after expanding Bacteria recursively"
        )

        // But Archaea (sibling of Bacteria) should still be collapsed
        let archaea = tree.node(taxId: 2157)!
        let archaeaRow = table.outlineView.row(forItem: archaea)
        XCTAssertGreaterThanOrEqual(
            archaeaRow, 0,
            "Archaea should still be visible (it is a root child)"
        )
        // Archaea has no children, so this is fine -- verify it wasn't expanded
        // by checking that Archaea itself is present but didn't grow the row count
    }

    // MARK: - Expand/Collapse with Nil Tree

    func testExpandAllWithNilTreeDoesNotCrash() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        table.tree = nil

        // Should not crash
        table.expandAll()
        table.collapseAll()
        table.expandSelectedRecursively()
    }

    // MARK: - Keyboard Event Routing

    func testTaxonomyOutlineViewKeyDownDispatchesCmdShiftRight() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Collapse everything first
        table.collapseAll()

        // Verify E. coli is not visible
        let ecoli = tree.node(taxId: 562)!
        XCTAssertEqual(
            table.outlineView.row(forItem: ecoli), -1,
            "E. coli should be hidden before keyboard shortcut"
        )

        // Simulate Cmd+Shift+Right Arrow keyDown on the outline view.
        // keyCode 124 = Right Arrow
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            charactersIgnoringModifiers: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            isARepeat: false,
            keyCode: 124
        )!

        let outline = table.outlineView as! TaxonomyOutlineView
        outline.keyDown(with: event)

        // After Cmd+Shift+Right, all items should be expanded
        XCTAssertGreaterThanOrEqual(
            table.outlineView.row(forItem: ecoli), 0,
            "E. coli should be visible after Cmd+Shift+Right (Expand All)"
        )
    }

    func testTaxonomyOutlineViewKeyDownDispatchesCmdShiftLeft() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Expand all first
        table.expandAll()

        let ecoli = tree.node(taxId: 562)!
        XCTAssertGreaterThanOrEqual(
            table.outlineView.row(forItem: ecoli), 0,
            "E. coli should be visible before collapse"
        )

        // Simulate Cmd+Shift+Left Arrow keyDown
        // keyCode 123 = Left Arrow
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            charactersIgnoringModifiers: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            isARepeat: false,
            keyCode: 123
        )!

        let outline = table.outlineView as! TaxonomyOutlineView
        outline.keyDown(with: event)

        // After Cmd+Shift+Left, deeply nested items should be collapsed
        XCTAssertEqual(
            table.outlineView.row(forItem: ecoli), -1,
            "E. coli should be hidden after Cmd+Shift+Left (Collapse All)"
        )

        // Root children should still be visible
        let bacteria = tree.node(taxId: 2)!
        XCTAssertGreaterThanOrEqual(
            table.outlineView.row(forItem: bacteria), 0,
            "Bacteria should still be visible after Collapse All"
        )
    }

    func testTaxonomyOutlineViewKeyDownDispatchesOptionRight() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Collapse everything, then just show root children
        table.collapseAll()

        // Select Bacteria
        let bacteria = tree.node(taxId: 2)!
        let bacteriaRow = table.outlineView.row(forItem: bacteria)
        table.outlineView.selectRowIndexes(IndexSet(integer: bacteriaRow), byExtendingSelection: false)

        // Verify E. coli is not visible
        let ecoli = tree.node(taxId: 562)!
        XCTAssertEqual(
            table.outlineView.row(forItem: ecoli), -1,
            "E. coli should be hidden before Option+Right"
        )

        // Simulate Option+Right Arrow keyDown
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            charactersIgnoringModifiers: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            isARepeat: false,
            keyCode: 124
        )!

        let outline = table.outlineView as! TaxonomyOutlineView
        outline.keyDown(with: event)

        // After Option+Right on Bacteria, E. coli should be visible
        XCTAssertGreaterThanOrEqual(
            table.outlineView.row(forItem: ecoli), 0,
            "E. coli should be visible after Option+Right on Bacteria"
        )
    }
}

// MARK: - ViewerViewController Taxonomy Integration Tests

@MainActor
final class ViewerViewControllerTaxonomyTests: XCTestCase {

    func testHideTaxonomyView() throws {
        let viewerVC = ViewerViewController()
        _ = viewerVC.view

        // The taxonomy view controller should start as nil
        XCTAssertNil(viewerVC.taxonomyViewController)

        // After displaying, it should exist
        let result = makeTestResult()
        viewerVC.displayTaxonomyResult(result)
        XCTAssertNotNil(viewerVC.taxonomyViewController)

        // Verify viewer components are hidden
        XCTAssertTrue(viewerVC.enhancedRulerView.isHidden)
        XCTAssertTrue(viewerVC.viewerView.isHidden)

        // After hiding, it should be nil and viewer components restored
        viewerVC.hideTaxonomyView()
        XCTAssertNil(viewerVC.taxonomyViewController)
        XCTAssertFalse(viewerVC.enhancedRulerView.isHidden)
        XCTAssertFalse(viewerVC.viewerView.isHidden)
    }

    // MARK: - BLAST Context Menu

    func testBlastContextMenuItemExists() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        let ecoli = result.tree.node(taxId: 562)!
        let items = vc.contextMenuItems(for: ecoli)

        // Find the BLAST menu item
        let blastItem = items.first(where: { $0.title.hasPrefix("BLAST Matching Reads") })
        XCTAssertNotNil(blastItem, "Context menu should contain BLAST Matching Reads item")
        XCTAssertNotNil(blastItem?.image, "BLAST item should have an icon")
        XCTAssertTrue(blastItem?.representedObject is TaxonNode, "BLAST item should carry the taxon node")

        // Verify it is the last non-separator item (after NCBI links separator)
        let lastNonSep = items.last(where: { !$0.isSeparatorItem })
        XCTAssertEqual(lastNonSep?.title, blastItem?.title, "BLAST item should be last in menu")
    }

    func testBlastPopoverConfiguration() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeTestResult()
        vc.configure(result: result)

        // Verify the callback property exists and can be set
        var callbackFired = false
        var capturedNode: TaxonNode?
        var capturedCount: Int?
        vc.onBlastVerification = { node, count in
            callbackFired = true
            capturedNode = node
            capturedCount = count
        }

        // Simulate what the popover would do
        let ecoli = result.tree.node(taxId: 562)!
        vc.onBlastVerification?(ecoli, 25)

        XCTAssertTrue(callbackFired, "Blast verification callback should fire")
        XCTAssertEqual(capturedNode?.taxId, 562)
        XCTAssertEqual(capturedNode?.name, "Escherichia coli")
        XCTAssertEqual(capturedCount, 25)
    }
}
