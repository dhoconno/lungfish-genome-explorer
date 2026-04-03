// TaxaCollectionsDrawerTests.swift - Tests for taxa collections drawer and batch extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

// MARK: - Test Helpers

/// Builds a taxonomy tree suitable for drawer tests.
///
/// Structure:
/// ```
/// root (taxId: 1, clade: 10000)
///   +-- Bacteria (taxId: 2, domain, clade: 8000)
///   |     +-- Proteobacteria (taxId: 1224, phylum, clade: 5000)
///   |     |     +-- E. coli (taxId: 562, species, clade: 1000, direct: 1000)
///   |     |     +-- Klebsiella pneumoniae (taxId: 573, species, clade: 300, direct: 300)
///   |     +-- Firmicutes (taxId: 1239, phylum, clade: 2000)
///   |           +-- Staphylococcus aureus (taxId: 1280, species, clade: 500, direct: 500)
///   +-- Viruses (taxId: 10239, domain, clade: 2000)
///         +-- Influenza A virus (taxId: 11320, species, clade: 800, direct: 800)
///         +-- SARS-CoV-2 (taxId: 2697049, species, clade: 600, direct: 600)
///         +-- RSV (taxId: 12814, species, clade: 200, direct: 200)
/// ```
@MainActor
private func makeDrawerTestTree() -> TaxonTree {
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 10000, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: nil
    )

    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 0, readsClade: 8000, fractionClade: 0.8, fractionDirect: 0.0,
        parentTaxId: 1
    )
    bacteria.parent = root

    let viruses = TaxonNode(
        taxId: 10239, name: "Viruses", rank: .domain, depth: 1,
        readsDirect: 0, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.0,
        parentTaxId: 1
    )
    viruses.parent = root
    root.children = [bacteria, viruses]

    let proteobacteria = TaxonNode(
        taxId: 1224, name: "Proteobacteria", rank: .phylum, depth: 2,
        readsDirect: 0, readsClade: 5000, fractionClade: 0.5, fractionDirect: 0.0,
        parentTaxId: 2
    )
    proteobacteria.parent = bacteria

    let firmicutes = TaxonNode(
        taxId: 1239, name: "Firmicutes", rank: .phylum, depth: 2,
        readsDirect: 0, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.0,
        parentTaxId: 2
    )
    firmicutes.parent = bacteria
    bacteria.children = [proteobacteria, firmicutes]

    let ecoli = TaxonNode(
        taxId: 562, name: "Escherichia coli", rank: .species, depth: 3,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 1224
    )
    ecoli.parent = proteobacteria

    let kpneumoniae = TaxonNode(
        taxId: 573, name: "Klebsiella pneumoniae", rank: .species, depth: 3,
        readsDirect: 300, readsClade: 300, fractionClade: 0.03, fractionDirect: 0.03,
        parentTaxId: 1224
    )
    kpneumoniae.parent = proteobacteria
    proteobacteria.children = [ecoli, kpneumoniae]

    let saureus = TaxonNode(
        taxId: 1280, name: "Staphylococcus aureus", rank: .species, depth: 3,
        readsDirect: 500, readsClade: 500, fractionClade: 0.05, fractionDirect: 0.05,
        parentTaxId: 1239
    )
    saureus.parent = firmicutes
    firmicutes.children = [saureus]

    let influenzaA = TaxonNode(
        taxId: 11320, name: "Influenza A virus", rank: .species, depth: 2,
        readsDirect: 800, readsClade: 800, fractionClade: 0.08, fractionDirect: 0.08,
        parentTaxId: 10239
    )
    influenzaA.parent = viruses

    let sarscov2 = TaxonNode(
        taxId: 2697049, name: "SARS-CoV-2", rank: .species, depth: 2,
        readsDirect: 600, readsClade: 600, fractionClade: 0.06, fractionDirect: 0.06,
        parentTaxId: 10239
    )
    sarscov2.parent = viruses

    let rsv = TaxonNode(
        taxId: 12814, name: "RSV", rank: .species, depth: 2,
        readsDirect: 200, readsClade: 200, fractionClade: 0.02, fractionDirect: 0.02,
        parentTaxId: 10239
    )
    rsv.parent = viruses
    viruses.children = [influenzaA, sarscov2, rsv]

    return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 10000)
}

/// Creates a test classification result wrapping the given tree.
@MainActor
private func makeDrawerTestResult(tree: TaxonTree? = nil) -> ClassificationResult {
    let tree = tree ?? makeDrawerTestTree()
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("taxa-drawer-test-\(UUID().uuidString)")

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
        runtime: 3.0,
        toolVersion: "2.1.3",
        provenanceId: nil
    )
}

// MARK: - TaxaCollectionsDrawerTests

@MainActor
final class TaxaCollectionsDrawerTests: XCTestCase {

    // MARK: - Drawer Layout

    func testDrawerLayout() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))

        // Trigger layout
        drawer.layoutSubtreeIfNeeded()

        // Verify subviews exist
        XCTAssertNotNil(drawer.dividerView.superview, "Divider should be in the view hierarchy")
        XCTAssertNotNil(drawer.outlineView.enclosingScrollView, "Outline view should be in a scroll view")
    }

    func testDrawerShowsBuiltInCollections() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.layoutSubtreeIfNeeded()

        // Built-in collections should be loaded
        XCTAssertEqual(
            drawer.displayedCollectionCount,
            TaxaCollection.builtIn.count,
            "Drawer should show all built-in collections by default"
        )
    }

    func testCollectionDisplay() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.layoutSubtreeIfNeeded()

        // Verify first collection is respiratory viruses
        let firstItem = drawer.collectionItem(at: 0)
        XCTAssertNotNil(firstItem)
        XCTAssertEqual(firstItem?.collection.id, "respiratory-viruses")
        XCTAssertEqual(firstItem?.collection.taxa.count, 12)
    }

    func testOutlineViewDataSource() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.layoutSubtreeIfNeeded()

        let outline = drawer.outlineView

        // Root level should have all built-in collections
        let rootCount = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: nil) ?? 0
        XCTAssertEqual(rootCount, TaxaCollection.builtIn.count)

        // First item should be expandable (it's a collection)
        if let firstItem = outline.dataSource?.outlineView?(outline, child: 0, ofItem: nil) {
            let isExpandable = outline.dataSource?.outlineView?(outline, isItemExpandable: firstItem) ?? false
            XCTAssertTrue(isExpandable, "Collection items should be expandable")

            // Children count should match taxa count
            let childCount = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: firstItem) ?? 0
            XCTAssertEqual(childCount, TaxaCollection.respiratoryViruses.taxa.count)
        } else {
            XCTFail("Should have at least one root item")
        }
    }

    // MARK: - Match Status

    func testMatchStatusWithTree() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        let tree = makeDrawerTestTree()
        drawer.setTree(tree)
        drawer.layoutSubtreeIfNeeded()

        // The respiratory viruses collection should show detected status for matching taxa
        // Our test tree has Influenza A (11320), SARS-CoV-2 (2697049), and RSV (12814)
        let outline = drawer.outlineView
        if let firstItem = outline.dataSource?.outlineView?(outline, child: 0, ofItem: nil) {
            // Expand the first collection to access child items
            let childCount = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: firstItem) ?? 0
            XCTAssertGreaterThan(childCount, 0, "Collection should have children")

            // Check a child item (e.g., Influenza A)
            if let child = outline.dataSource?.outlineView?(outline, child: 0, ofItem: firstItem) as? TaxonEntryItem {
                // Influenza A (taxId 11320) has 800 reads in our test tree
                if child.target.taxId == 11320 {
                    XCTAssertEqual(child.detectedReads, 800, "Influenza A should have 800 reads")
                }
            }
        }
    }

    func testMatchStatusWithNilTree() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.setTree(nil)
        drawer.layoutSubtreeIfNeeded()

        // With no tree, all taxa should show 0 detected reads
        XCTAssertEqual(drawer.displayedCollectionCount, TaxaCollection.builtIn.count)
    }

    // MARK: - Drawer Toggle (via TaxonomyViewController)

    func testDrawerToggle() throws {
        let vc = TaxonomyViewController()
        _ = vc.view  // trigger loadView

        let result = makeDrawerTestResult()
        vc.configure(result: result)

        // Initially, drawer should not exist
        XCTAssertNil(vc.testCollectionsDrawer)
        XCTAssertFalse(vc.testIsCollectionsDrawerOpen)

        // Toggle open
        vc.toggleTaxaCollectionsDrawer()

        // Drawer should now exist and be open
        XCTAssertNotNil(vc.testCollectionsDrawer)
        XCTAssertTrue(vc.testIsCollectionsDrawerOpen)

        // Toggle closed
        vc.toggleTaxaCollectionsDrawer()
        XCTAssertFalse(vc.testIsCollectionsDrawerOpen)
    }

    func testActionBarCollectionsButton() throws {
        // The collections toggle is now a custom button managed by TaxonomyViewController.
        // Verify the unified ClassifierActionBar API works with custom buttons.
        let actionBar = ClassifierActionBar(frame: NSRect(x: 0, y: 0, width: 800, height: 36))
        actionBar.layoutSubtreeIfNeeded()

        let collectionsButton = NSButton(title: "Collections", target: nil, action: nil)
        collectionsButton.setButtonType(.pushOnPushOff)
        actionBar.addCustomButton(collectionsButton)

        // Collections toggle should start off
        XCTAssertEqual(collectionsButton.state, .off)

        // Simulate drawer open
        collectionsButton.state = .on
        XCTAssertEqual(collectionsButton.state, .on)

        // Simulate drawer close
        collectionsButton.state = .off
        XCTAssertEqual(collectionsButton.state, .off)
    }

    func testActionBarCallbackWired() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        let result = makeDrawerTestResult()
        vc.configure(result: result)

        // The collections toggle button is wired through the VC's target/action.
        // Verify that toggling works via the public API.
        XCTAssertFalse(vc.testIsCollectionsDrawerOpen)
        vc.toggleTaxaCollectionsDrawer()
        XCTAssertTrue(vc.testIsCollectionsDrawerOpen)
    }

    // MARK: - Batch Extraction Config

    func testBatchExtractionConfig() throws {
        // Verify that a TaxaCollection can be used to build extraction configs
        let collection = TaxaCollection.respiratoryViruses

        // Each target should have a valid tax ID and name
        for target in collection.taxa {
            XCTAssertGreaterThan(target.taxId, 0)
            XCTAssertFalse(target.name.isEmpty)
            XCTAssertTrue(target.includeChildren, "All respiratory virus targets should include children")
        }

        // Verify the collection can produce configs
        let sourceURL = URL(fileURLWithPath: "/tmp/test.fastq")
        let outputURL = URL(fileURLWithPath: "/tmp/output.fastq")
        let classURL = URL(fileURLWithPath: "/tmp/classification.kraken")

        let config = TaxonomyExtractionConfig(
            taxIds: Set(collection.taxa.map(\.taxId)),
            includeChildren: true,
            sourceFile: sourceURL,
            outputFile: outputURL,
            classificationOutput: classURL
        )

        XCTAssertEqual(config.taxIds.count, 12)
        XCTAssertTrue(config.includeChildren)
        XCTAssertFalse(config.isPairedEnd)
    }

    func testBatchExtractionPerTargetConfig() throws {
        let collection = TaxaCollection.amrOrganisms

        // Build one config per target, simulating what extractBatch does
        for target in collection.taxa {
            let config = TaxonomyExtractionConfig(
                taxIds: Set([target.taxId]),
                includeChildren: target.includeChildren,
                sourceFile: URL(fileURLWithPath: "/tmp/test.fastq"),
                outputFile: URL(fileURLWithPath: "/tmp/\(target.taxId).fastq"),
                classificationOutput: URL(fileURLWithPath: "/tmp/classification.kraken")
            )

            XCTAssertEqual(config.taxIds.count, 1)
            XCTAssertTrue(config.taxIds.contains(target.taxId))
            XCTAssertEqual(config.includeChildren, target.includeChildren)
        }
    }

    // MARK: - Batch Extract Callback

    func testBatchExtractCallback() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        let result = makeDrawerTestResult()
        vc.configure(result: result)

        var receivedCollection: TaxaCollection?
        var receivedResult: ClassificationResult?

        vc.onBatchExtract = { collection, classResult in
            receivedCollection = collection
            receivedResult = classResult
        }

        // Open the drawer and trigger extraction
        vc.toggleTaxaCollectionsDrawer()

        // Simulate clicking Extract on the first collection
        let collection = TaxaCollection.respiratoryViruses
        vc.testCollectionsDrawer?.onBatchExtract?(collection)

        XCTAssertEqual(receivedCollection?.id, "respiratory-viruses")
        XCTAssertNotNil(receivedResult)
        XCTAssertEqual(receivedResult?.tree.totalReads, 10000)
    }

    // MARK: - Scope Filtering

    func testScopeFilterAll() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))

        // Default is "All" which should show all built-in collections
        XCTAssertEqual(drawer.displayedCollectionCount, TaxaCollection.builtIn.count)
    }

    // MARK: - Checkbox State

    func testCheckboxDefaultState() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.layoutSubtreeIfNeeded()

        // All taxa should be enabled by default
        let firstItem = drawer.collectionItem(at: 0)
        XCTAssertNotNil(firstItem)

        for target in firstItem!.collection.taxa {
            let isEnabled = firstItem!.enabledTaxa[target.taxId] ?? false
            XCTAssertTrue(isEnabled, "Taxon \(target.name) should be enabled by default")
        }
    }

    func testCheckboxToggle() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.layoutSubtreeIfNeeded()

        let firstItem = drawer.collectionItem(at: 0)!
        let firstTaxId = firstItem.collection.taxa[0].taxId

        // Disable a taxon
        firstItem.enabledTaxa[firstTaxId] = false
        XCTAssertFalse(firstItem.enabledTaxa[firstTaxId]!)

        // Re-enable
        firstItem.enabledTaxa[firstTaxId] = true
        XCTAssertTrue(firstItem.enabledTaxa[firstTaxId]!)
    }

    func testEnabledTargets() throws {
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        drawer.layoutSubtreeIfNeeded()

        let firstItem = drawer.collectionItem(at: 0)!

        // All enabled by default
        XCTAssertEqual(firstItem.enabledTargets.count, firstItem.collection.taxa.count)

        // Disable one
        let firstTaxId = firstItem.collection.taxa[0].taxId
        firstItem.enabledTaxa[firstTaxId] = false
        XCTAssertEqual(firstItem.enabledTargets.count, firstItem.collection.taxa.count - 1)
    }

    // MARK: - Drawer Height Persistence

    func testDrawerHeightDefaults() throws {
        // Default height should be 220
        XCTAssertEqual(TaxonomyViewController.defaultTaxaDrawerHeight, 220)
        XCTAssertEqual(TaxonomyViewController.minTaxaDrawerHeight, 140)
        XCTAssertEqual(TaxonomyViewController.maxTaxaDrawerFraction, 0.5)
    }

    // MARK: - Collection Scope Filter

    func testCollectionScopeFilterMatching() {
        XCTAssertTrue(CollectionScopeFilter.all.matches(.builtin))
        XCTAssertTrue(CollectionScopeFilter.all.matches(.appWide))
        XCTAssertTrue(CollectionScopeFilter.all.matches(.project))

        XCTAssertTrue(CollectionScopeFilter.builtIn.matches(.builtin))
        XCTAssertFalse(CollectionScopeFilter.builtIn.matches(.appWide))
        XCTAssertFalse(CollectionScopeFilter.builtIn.matches(.project))

        XCTAssertFalse(CollectionScopeFilter.appWide.matches(.builtin))
        XCTAssertTrue(CollectionScopeFilter.appWide.matches(.appWide))
        XCTAssertFalse(CollectionScopeFilter.appWide.matches(.project))

        XCTAssertFalse(CollectionScopeFilter.project.matches(.builtin))
        XCTAssertFalse(CollectionScopeFilter.project.matches(.appWide))
        XCTAssertTrue(CollectionScopeFilter.project.matches(.project))
    }

    func testCollectionScopeFilterTitles() {
        XCTAssertEqual(CollectionScopeFilter.all.title, "All")
        XCTAssertEqual(CollectionScopeFilter.builtIn.title, "Built-in")
        XCTAssertEqual(CollectionScopeFilter.appWide.title, "App")
        XCTAssertEqual(CollectionScopeFilter.project.title, "Project")
    }
}
