// AnnotationTableContextMenuTests.swift - Tests for annotation table right-click context menu
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class AnnotationTableContextMenuTests: XCTestCase {

    private nonisolated(unsafe) var tempDir: URL!

    private final class DrawerDelegateSpy: AnnotationTableDrawerDelegate {
        var extractedAnnotations: [SequenceAnnotation] = []
        var selectedRegion: AnnotationTableDrawerSelectionRegion?
        var visibleAnnotationRenderKeys: Set<String>?
        var annotationTrackDisplayStates: [AnnotationTrackDisplayState] = []

        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestExtract annotations: [SequenceAnnotation]) {
            extractedAnnotations = annotations
        }
        func annotationDrawerSelectedSequenceRegion(_ drawer: AnnotationTableDrawerView) -> AnnotationTableDrawerSelectionRegion? {
            selectedRegion
        }
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion]) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleAnnotationRenderKeys keys: Set<String>?) {
            visibleAnnotationRenderKeys = keys
        }
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateAnnotationTrackDisplayState state: AnnotationTrackDisplayState) {
            annotationTrackDisplayStates.append(state)
        }
        func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {}
        func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}
    }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation_table_ctx_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helper

    /// Creates a drawer view connected to a SQLite-backed search index containing the given BED12 lines.
    private func createDrawerWithDatabase(lines: [String]) throws -> AnnotationTableDrawerView {
        // Create SQLite database from BED12 content
        let bedContent = lines.joined(separator: "\n")
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)

        // buildFromDatabase needs bundle.url + databasePath to find the file
        // The DB is at tempDir/annotations.db, so bundle.url = tempDir, databasePath = "annotations.db"
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "seq.fa.gz",
                indexPath: "seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: []
            )
        )
        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)

        let searchIndex = AnnotationSearchIndex()
        let success = searchIndex.buildFromDatabase(bundle: bundle, trackId: "annotations", databasePath: "annotations.db")
        XCTAssertTrue(success, "Database should open successfully")

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        return drawer
    }

    /// Searches top-level items and one level of submenus for a menu item with the given title.
    private func findMenuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu {
                if let found = submenu.items.first(where: { $0.title == title }) {
                    return found
                }
            }
        }
        return nil
    }

    private func invokeMenuItem(
        titled title: String,
        on drawer: AnnotationTableDrawerView
    ) -> NSMenuItem? {
        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)
        guard let item = findMenuItem(titled: title, in: menu) else { return nil }
        guard let action = item.action else { return nil }
        _ = (item.target as AnyObject?)?.perform(action, with: item)
        return item
    }

    private func makeBEDLine(
        name: String,
        chromosome: String = "chr1",
        start: Int,
        type: String = "gene"
    ) -> String {
        let end = start + 10
        return "\(chromosome)\t\(start)\t\(end)\t\(name)\t0\t+\t\(start)\t\(end)\t0,0,0\t1\t10\t0\t\(type)\tgene=\(name)"
    }

    private func applyAnnotationColumnFilter(
        key: String,
        op: String,
        value: String,
        to drawer: AnnotationTableDrawerView
    ) {
        let item = NSMenuItem()
        item.representedObject = ["key": key, "op": op, "value": value]
        let selector = NSSelectorFromString("applyAnnotationColumnFilterAction:")
        XCTAssertTrue(drawer.responds(to: selector), "Drawer should expose annotation column filter action")
        _ = drawer.perform(selector, with: item)
    }

    func testOverLimitAnnotationQueryKeepsTableHeaderVisible() throws {
        let lines = (0...AppSettings.shared.maxTableDisplayCount).map {
            makeBEDLine(name: "gene-\($0)", start: $0 * 20)
        }

        let drawer = try createDrawerWithDatabase(lines: lines)

        XCTAssertTrue(drawer.displayedAnnotations.isEmpty)
        XCTAssertFalse(drawer.tableView.enclosingScrollView?.isHidden ?? true)
        XCTAssertNotNil(drawer.tableView.headerView)
        XCTAssertGreaterThan(drawer.tableView.tableColumns.count, 0)
    }

    func testAnnotationColumnFilterCanNarrowAfterOverLimitQuery() throws {
        var lines = (0...AppSettings.shared.maxTableDisplayCount).map {
            makeBEDLine(name: "gene-\($0)", start: $0 * 20)
        }
        lines.append(contentsOf: [
            makeBEDLine(name: "target-a", chromosome: "chr2", start: 10),
            makeBEDLine(name: "target-b", chromosome: "chr2", start: 30),
        ])
        let drawer = try createDrawerWithDatabase(lines: lines)
        XCTAssertTrue(drawer.displayedAnnotations.isEmpty)

        applyAnnotationColumnFilter(key: "chromosome", op: "=", value: "chr2", to: drawer)

        XCTAssertEqual(drawer.displayedAnnotations.map(\.name), ["target-a", "target-b"])
        XCTAssertEqual(Set(drawer.displayedAnnotations.map(\.chromosome)), ["chr2"])
        XCTAssertFalse(drawer.tableView.enclosingScrollView?.isHidden ?? true)
    }

    func testAnnotationTrackControlsToggleVisibilityAndReorderTracks() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let spy = DrawerDelegateSpy()
        drawer.delegate = spy
        drawer.setAnnotations([
            AnnotationSearchIndex.SearchResult(
                name: "alpha",
                chromosome: "chr1",
                start: 10,
                end: 30,
                trackId: "track-a",
                type: "gene",
                annotationRowId: 1
            ),
            AnnotationSearchIndex.SearchResult(
                name: "beta",
                chromosome: "chr1",
                start: 20,
                end: 40,
                trackId: "track-b",
                type: "gene",
                annotationRowId: 2
            ),
        ])

        XCTAssertEqual(drawer.debugAnnotationTrackDisplayState.order, ["track-a", "track-b"])
        XCTAssertEqual(spy.annotationTrackDisplayStates.last?.order, ["track-a", "track-b"])

        drawer.debugSetAnnotationTrackVisible(trackId: "track-a", visible: false)
        XCTAssertEqual(spy.annotationTrackDisplayStates.last?.hiddenTrackIDs, ["track-a"])

        drawer.debugMoveAnnotationTrack(trackId: "track-b", direction: .up)
        XCTAssertEqual(spy.annotationTrackDisplayStates.last?.order, ["track-b", "track-a"])
    }

    func testViewportAnnotationPackingKeepsTracksInDisplayOrder() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        viewer.setAnnotationTrackDisplayState(
            AnnotationTrackDisplayState(order: ["track-b", "track-a"], hiddenTrackIDs: [])
        )
        let annotations = [
            SequenceAnnotation(
                type: .gene,
                name: "A1",
                chromosome: "chr1",
                start: 10,
                end: 90,
                qualifiers: ["annotation_db_track_id": AnnotationQualifier("track-a")]
            ),
            SequenceAnnotation(
                type: .gene,
                name: "B1",
                chromosome: "chr1",
                start: 20,
                end: 80,
                qualifiers: ["annotation_db_track_id": AnnotationQualifier("track-b")]
            ),
            SequenceAnnotation(
                type: .gene,
                name: "A2",
                chromosome: "chr1",
                start: 120,
                end: 160,
                qualifiers: ["annotation_db_track_id": AnnotationQualifier("track-a")]
            ),
        ]
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 200, pixelWidth: 800, sequenceLength: 200)

        let trackRows = viewer.debugPackedAnnotationTrackIDs(annotations, frame: frame)

        XCTAssertEqual(trackRows, ["track-b", "track-a"])
    }

    // MARK: - lookupTranslation Tests

    func testLookupTranslationReturnsCDSTranslation() throws {
        // BED12+extras: chrom start end name score strand thickStart thickEnd rgb blockCount blockSizes blockStarts type attributes
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t500\tgag-cds\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tCDS\ttranslation=MKVLGPRSE;product=gag%20protein"
        ])

        let result = AnnotationSearchIndex.SearchResult(
            name: "gag-cds",
            chromosome: "chr1",
            start: 100,
            end: 500,
            trackId: "annotations",
            type: "CDS",
            strand: "+"
        )

        let translation = drawer.lookupTranslation(for: result)
        XCTAssertEqual(translation, "MKVLGPRSE")
    }

    func testLookupTranslationReturnsNilForAnnotationWithoutTranslation() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t5000\tBRCA1\t0\t+\t100\t5000\t0,0,0\t1\t4900\t0\tgene\tgene=BRCA1;product=BRCA1%20DNA%20repair"
        ])

        let result = AnnotationSearchIndex.SearchResult(
            name: "BRCA1",
            chromosome: "chr1",
            start: 100,
            end: 5000,
            trackId: "annotations",
            type: "gene",
            strand: "+"
        )

        let translation = drawer.lookupTranslation(for: result)
        XCTAssertNil(translation, "Gene without translation attribute should return nil")
    }

    func testLookupTranslationReturnsNilWithoutSearchIndex() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))

        let result = AnnotationSearchIndex.SearchResult(
            name: "test",
            chromosome: "chr1",
            start: 0,
            end: 100,
            trackId: "track1",
            type: "CDS",
            strand: "+"
        )

        let translation = drawer.lookupTranslation(for: result)
        XCTAssertNil(translation, "Should return nil when no search index is set")
    }

    func testLookupTranslationReturnsNilForNonexistentAnnotation() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t500\treal-gene\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tCDS\ttranslation=MKVL"
        ])

        let result = AnnotationSearchIndex.SearchResult(
            name: "nonexistent",
            chromosome: "chr1",
            start: 0,
            end: 100,
            trackId: "annotations",
            type: "CDS",
            strand: "+"
        )

        let translation = drawer.lookupTranslation(for: result)
        XCTAssertNil(translation, "Should return nil for annotation not in database")
    }

    func testLookupTranslationHandlesURLEncodedValue() throws {
        // Translation with URL-encoded characters (unusual but possible)
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t0\t300\ttest-cds\t0\t+\t0\t300\t0,0,0\t1\t300\t0\tCDS\ttranslation=MKV%2ALGPRSE"
        ])

        let result = AnnotationSearchIndex.SearchResult(
            name: "test-cds",
            chromosome: "chr1",
            start: 0,
            end: 300,
            trackId: "annotations",
            type: "CDS",
            strand: "+"
        )

        let translation = drawer.lookupTranslation(for: result)
        XCTAssertNotNil(translation)
        // The parsed value should have the %2A decoded to *
        XCTAssertEqual(translation, "MKV*LGPRSE")
    }

    // MARK: - Context menu behavior

    func testAnnotationTableAllowsMultipleSelectionWhenInitializedOnAnnotationTab() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a",
            "chr1\t300\t400\tgene-b\t0\t+\t300\t400\t0,0,0\t1\t100\t0\tgene\tgene=gene-b"
        ])

        XCTAssertTrue(drawer.tableView.allowsMultipleSelection)
    }

    func testAnnotationEditAccessoryViewHasStableSizeForAlertLayout() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a;Note=long"
        ])
        let result = AnnotationSearchIndex.SearchResult(
            name: "gene-a",
            chromosome: "chr1",
            start: 100,
            end: 200,
            trackId: "annotations",
            type: "gene",
            strand: "+",
            attributes: ["gene": "gene-a", "Note": "long"],
            annotationRowId: 1
        )
        let record = AnnotationDatabaseRecord(
            rowID: 1,
            name: "gene-a",
            type: "gene",
            chromosome: "chr1",
            start: 100,
            end: 200,
            strand: "+",
            attributes: "gene=gene-a;Note=long",
            geneName: "gene-a"
        )

        let form = drawer.makeAnnotationEditAccessoryView(for: result, currentRecord: record)

        XCTAssertGreaterThanOrEqual(form.frame.width, 460)
        XCTAssertGreaterThanOrEqual(form.frame.height, 260)
    }

    func testAnnotationContextMenuOffersAddAnnotationWhenNoRowIsClicked() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a"
        ])

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        XCTAssertNotNil(findMenuItem(titled: "Add Annotation\u{2026}", in: menu))
    }

    func testAnnotationCreateFormPrefillsSelectedSequenceRegion() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a"
        ])
        let region = AnnotationTableDrawerSelectionRegion(chromosome: "chr2", start: 120, end: 180)

        let form = drawer.makeAnnotationCreateAccessoryView(defaultRegion: region)

        XCTAssertEqual(form.chromosomeField.stringValue, "chr2")
        XCTAssertEqual(form.startField.stringValue, "120")
        XCTAssertEqual(form.endField.stringValue, "180")
    }

    func testPerformAnnotationCreationPersistsToDatabase() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a"
        ])

        XCTAssertTrue(drawer.performAnnotationCreation(
            name: "new-feature",
            type: "misc_feature",
            chromosome: "chr1",
            start: 220,
            end: 260,
            strand: "+",
            attributes: "Note=created"
        ))

        XCTAssertTrue(drawer.selectAnnotation(named: "new-feature"))
    }

    func testContextMenuUsesSelectedRowWhenNoClickedRow() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t500\tgag-cds\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tCDS\ttranslation=MKVLGPRSE"
        ])

        XCTAssertTrue(drawer.selectAnnotation(named: "gag-cds"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        // Items are now inside the Copy submenu
        XCTAssertNotNil(findMenuItem(titled: "Copy Name", in: menu))
        XCTAssertNotNil(findMenuItem(titled: "Copy Coordinates", in: menu))
        XCTAssertNotNil(findMenuItem(titled: "Copy Translation", in: menu))
    }

    func testContextMenuShowsTranslationForMixedCaseCDSType() throws {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setAnnotations([
            AnnotationSearchIndex.SearchResult(
                name: "test-cds",
                chromosome: "chr1",
                start: 0,
                end: 300,
                trackId: "annotations",
                type: "Cds",
                strand: "+"
            )
        ])

        XCTAssertTrue(drawer.selectAnnotation(named: "test-cds"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let translationItem = findMenuItem(titled: "Copy Translation", in: menu)
        XCTAssertNotNil(translationItem, "Mixed-case CDS type should still offer Copy Translation")
        XCTAssertFalse(translationItem?.isEnabled ?? true, "Without translation data, item should be present but disabled")
    }

    func testCopyTranslationAsFASTAUsesDatabaseIntervals() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t260\tcds-1\t0\t+\t100\t260\t0,0,0\t2\t50,40\t0,120\tCDS\ttranslation=MKVLGPRSE"
        ])
        XCTAssertTrue(drawer.selectAnnotation(named: "cds-1"))

        expectation(
            forNotification: .copyTranslationAsFASTARequested,
            object: nil
        ) { notification in
            let captured = notification.userInfo?["annotation"] as? SequenceAnnotation
            XCTAssertEqual(captured?.type, .cds)
            XCTAssertEqual(captured?.intervals.count, 2)
            XCTAssertEqual(captured?.intervals.first?.start, 100)
            XCTAssertEqual(captured?.intervals.first?.end, 150)
            XCTAssertEqual(captured?.intervals.last?.start, 220)
            XCTAssertEqual(captured?.intervals.last?.end, 260)
            return true
        }

        let item = invokeMenuItem(titled: "Copy Translation as FASTA", on: drawer)
        XCTAssertNotNil(item)
        waitForExpectations(timeout: 1.0)
    }

    func testCopyTranslationAsFASTAUsesRobustTypeParsingWithoutDatabaseRecord() throws {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setAnnotations([
            AnnotationSearchIndex.SearchResult(
                name: "cds-fallback",
                chromosome: "chr1",
                start: 10,
                end: 40,
                trackId: "annotations",
                type: "Cds",
                strand: "+"
            )
        ])
        XCTAssertTrue(drawer.selectAnnotation(named: "cds-fallback"))

        expectation(
            forNotification: .copyTranslationAsFASTARequested,
            object: nil
        ) { notification in
            let captured = notification.userInfo?["annotation"] as? SequenceAnnotation
            XCTAssertEqual(captured?.type, .cds)
            XCTAssertEqual(captured?.intervals.count, 1)
            XCTAssertEqual(captured?.intervals.first?.start, 10)
            XCTAssertEqual(captured?.intervals.first?.end, 40)
            return true
        }

        let item = invokeMenuItem(titled: "Copy Translation as FASTA", on: drawer)
        XCTAssertNotNil(item)
        waitForExpectations(timeout: 1.0)
    }

    func testAnnotationContextMenuSupportsMultiSelectExtractionAndDeletion() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a",
            "chr1\t300\t400\tgene-b\t0\t+\t300\t400\t0,0,0\t1\t100\t0\tgene\tgene=gene-b"
        ])
        let delegate = DrawerDelegateSpy()
        drawer.delegate = delegate
        XCTAssertEqual(drawer.selectAnnotations(named: ["gene-a", "gene-b"]), 2)

        let extractItem = invokeMenuItem(titled: "Extract 2 Sequences\u{2026}", on: drawer)
        XCTAssertNotNil(extractItem)
        XCTAssertEqual(delegate.extractedAnnotations.map(\.name), ["gene-a", "gene-b"])

        let deleteItem = invokeMenuItem(titled: "Delete 2 Selected Annotations", on: drawer)
        XCTAssertNotNil(deleteItem)
        XCTAssertFalse(drawer.selectAnnotation(named: "gene-a"))
        XCTAssertFalse(drawer.selectAnnotation(named: "gene-b"))
    }

    func testAnnotationViewportFilterDoesNotEmitRowKeysUntilEnabled() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a",
            "chr1\t300\t400\tgene-b\t0\t+\t300\t400\t0,0,0\t1\t100\t0\tgene\tgene=gene-b"
        ])
        let delegate = DrawerDelegateSpy()
        drawer.delegate = delegate

        drawer.debugSetAnnotationFilterText("gene-a")
        drawer.debugRefreshDisplayedAnnotations()

        XCTAssertEqual(drawer.displayedAnnotations.map(\.name), ["gene-a"])
        XCTAssertNil(delegate.visibleAnnotationRenderKeys)
    }

    func testAnnotationViewportFilterEmitsDisplayedRowKeysWhenEnabled() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a",
            "chr1\t300\t400\tgene-b\t0\t+\t300\t400\t0,0,0\t1\t100\t0\tgene\tgene=gene-b"
        ])
        let delegate = DrawerDelegateSpy()
        drawer.delegate = delegate

        drawer.setAnnotationViewportFilterEnabled(true)
        drawer.debugSetAnnotationFilterText("gene-a")
        drawer.debugRefreshDisplayedAnnotations()

        XCTAssertEqual(delegate.visibleAnnotationRenderKeys, ["annotations:1"])
    }

    func testAnnotationViewportFilterControlRemainsVisibleInMinimalToolbarDensity() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a"
        ])
        drawer.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        drawer.switchToTab(.annotations)
        drawer.layoutSubtreeIfNeeded()

        XCTAssertTrue(drawer.isAnnotationViewportFilterControlVisible)
    }

    func testAnnotationContextMenuExposesEditForSingleDatabaseAnnotation() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t200\tgene-a\t0\t+\t100\t200\t0,0,0\t1\t100\t0\tgene\tgene=gene-a"
        ])
        XCTAssertTrue(drawer.selectAnnotation(named: "gene-a"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let editItem = findMenuItem(titled: "Edit Annotation\u{2026}", in: menu)
        XCTAssertNotNil(editItem)
        XCTAssertTrue(editItem?.isEnabled ?? false)
        XCTAssertNotNil(findMenuItem(titled: "Delete Annotation", in: menu))
    }

    func testSelectRelatedGeneFeaturesConnectsGeneExonAndCDSRows() throws {
        let drawer = try createDrawerWithDatabase(lines: [
            "chr1\t100\t500\tgene-a\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=gene-a;ID=gene-a",
            "chr1\t160\t220\texon-a\t0\t+\t160\t220\t0,0,0\t1\t60\t0\texon\tgene=gene-a;Parent=gene-a",
            "chr1\t160\t220\tcds-a\t0\t+\t160\t220\t0,0,0\t1\t60\t0\tCDS\tgene=gene-a;Parent=gene-a"
        ])
        XCTAssertTrue(drawer.selectAnnotation(named: "cds-a"))

        let relatedItem = invokeMenuItem(titled: "Select Related Gene Features", on: drawer)
        XCTAssertNotNil(relatedItem)

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)
        XCTAssertNotNil(findMenuItem(titled: "Extract 3 Sequences\u{2026}", in: menu))
    }
}
