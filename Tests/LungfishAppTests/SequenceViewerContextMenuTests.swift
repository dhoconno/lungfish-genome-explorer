// SequenceViewerContextMenuTests.swift - Context menu composition regressions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class SequenceViewerContextMenuTests: XCTestCase {
    private var retainedViewerControllers: [ViewerViewController] = []

    override func tearDown() async throws {
        retainedViewerControllers.removeAll()
        try await super.tearDown()
    }

    func testSequenceTargetWithSelectionContainsSharedCommandsOnce() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(
            for: .sequence,
            genomicPosition: 123
        )

        assertSharedCommands(in: menu, viewer: viewer, genomicPosition: 123)
    }

    func testEmptyAlignmentTargetWithSelectionContainsOnlySharedActionsAndValidSeparators() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(for: .alignment([]), genomicPosition: 123)

        XCTAssertEqual(menu.items.map(menuToken), [
            "Copy Visible Region",
            "<separator>",
            "Copy Visible Region as FASTA",
            "Extract Visible Region…",
            "<separator>",
            "Center View Here",
            "Zoom to Selected Region",
        ])
        XCTAssertFalse(menu.items.contains { $0.title == "Show BAM in Finder" })
        XCTAssertFalse(menu.items.contains { $0.title == "Show Alignment File in Finder" })
        assertValidSeparators(in: menu)
    }

    func testSequenceTargetWithSelectionContainsOnlySharedSelectedRangeActions() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(for: .sequence, genomicPosition: 123)

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Copy Visible Region",
                "Copy Visible Region as FASTA",
                "Extract Visible Region…",
                "Center View Here",
                "Zoom to Selected Region",
            ]
        )
        XCTAssertFalse(menu.items.contains { $0.title == "Select All" })
        XCTAssertFalse(menu.items.contains { $0.title == "Zoom to Fit" })
        XCTAssertFalse(menu.items.contains { $0.title == "Show in Inspector" })
    }

    func testSelectedRangeMenuPreservesExtractionAndCenterAdjacency() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(for: .sequence, genomicPosition: 123)
        let tokens = menu.items.map(menuToken)

        XCTAssertEqual(tokens, [
            "Copy Visible Region",
            "<separator>",
            "Copy Visible Region as FASTA",
            "Extract Visible Region…",
            "<separator>",
            "Center View Here",
            "Zoom to Selected Region",
        ])
    }

    func testSequenceTargetWithoutSelectionPreservesBackgroundCommands() {
        let viewer = makeViewer()

        let menu = viewer.testBuildContextMenu(for: .sequence, genomicPosition: 123)

        XCTAssertNotNil(menu.items.first { $0.title == "Select All" })
        XCTAssertNotNil(menu.items.first { $0.title == "Zoom to Fit" })
        let inspectorItem = try! XCTUnwrap(menu.items.first { $0.title == "Show in Inspector" })
        XCTAssertEqual(inspectorItem.action, #selector(SequenceViewerView.showDocumentInInspector(_:)))
        XCTAssertNotNil(menu.items.first { $0.title == "Center View Here" })
    }

    func testAnnotationTargetWithoutSelectionDisambiguatesInspectorActions() throws {
        let viewer = makeViewer()
        let annotation = makeAnnotation()

        let menu = viewer.testBuildContextMenu(for: .annotation(annotation), genomicPosition: 123)
        let annotationItem = try XCTUnwrap(menu.items.first { $0.title == "Show Annotation in Inspector" })
        let documentItems = menu.items.filter { $0.title == "Show Document in Inspector" }

        XCTAssertEqual(documentItems.count, 1)
        XCTAssertEqual(annotationItem.action, #selector(SequenceViewerView.showAnnotationInInspector(_:)))
        XCTAssertEqual(documentItems[0].action, #selector(SequenceViewerView.showDocumentInInspector(_:)))
        XCTAssertFalse(menu.items.contains { $0.title == "Show in Inspector" })
    }

    func testNoSelectionCompositionAppendsGeneralCommandsAfterSpecializedTarget() throws {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)
        viewer.selectionRange = nil

        let sequence1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCGATCG")
        let sequence2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTAGCTA")
        viewer.setSequences([sequence1, sequence2])

        let sequenceMenu = viewer.testBuildContextMenu(
            for: .sequence,
            genomicPosition: 123,
            clickedTrackIndex: 0
        )
        let sequenceTitles = sequenceMenu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertTrue(sequenceTitles.contains("Select All"))
        XCTAssertTrue(sequenceTitles.contains("Center View Here"))
        XCTAssertTrue(sequenceTitles.contains("Zoom to Fit"))
        XCTAssertTrue(sequenceTitles.contains("Show in Inspector"))
        for title in [
            "Copy Visible Region",
            "Copy Visible Region as FASTA",
            "Extract Visible Region…",
            "Zoom to Selected Region",
        ] {
            XCTAssertFalse(sequenceTitles.contains(title), "Unexpected no-selection item: \(title)")
        }

        let trackTranslationItem = try XCTUnwrap(sequenceMenu.items.first { $0.title == "Show Translation" })
        XCTAssertEqual(trackTranslationItem.action, #selector(SequenceViewerView.toggleTrackTranslation(_:)))
        XCTAssertEqual((trackTranslationItem.representedObject as? NSNumber)?.intValue, 0)
        XCTAssertNotNil(sequenceMenu.items.first { $0.title == "Show All Translations" })

        let variantMenu = viewer.testBuildContextMenu(
            for: .variant(makeVariant()),
            genomicPosition: 123
        )
        let variantTitles = variantMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(Array(variantTitles.prefix(2)), ["View Variant in Table", "View Genotypes at Site"])
        XCTAssertLessThan(
            try XCTUnwrap(variantTitles.firstIndex(of: "View Genotypes at Site")),
            try XCTUnwrap(variantTitles.firstIndex(of: "Select All"))
        )
        XCTAssertTrue(variantTitles.contains("Show in Inspector"))
    }

    func testAlignmentTargetPreservesRevealActionPayloadAndSharedCommands() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)
        let url = URL(fileURLWithPath: "/tmp/example.bam")

        let menu = viewer.testBuildContextMenu(
            for: .alignment([
                AlignmentFileMenuEntry(trackId: "reads", title: "Reads", url: url),
            ]),
            genomicPosition: 123
        )

        guard let revealItem = menu.items.first(where: { $0.title == "Show BAM in Finder" }) else {
            XCTFail("Expected Show BAM in Finder")
            return
        }
        XCTAssertEqual(revealItem.action, #selector(SequenceViewerView.showAlignmentFileInFinderAction(_:)))
        XCTAssertTrue(revealItem.target === viewer)
        XCTAssertEqual(revealItem.representedObject as? URL, url)
        assertSharedCommands(in: menu, viewer: viewer, genomicPosition: 123)
    }

    func testReadTargetPreservesSpecializedActionsAndSharedCommands() {
        let viewer = makeViewer()
        let read = makeRead()
        viewer.testSetCachedPackedReads([(0, read)])
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(for: .read(read), genomicPosition: 123)

        for title in ["Copy as FASTA (aligned orientation)", "Extract Reads… (original reads)"] {
            guard let item = menu.items.first(where: { $0.title == title }) else {
                XCTFail("Expected specialized read menu item")
                return
            }
            XCTAssertNotNil(item.target)
            XCTAssertFalse(item.target === viewer)
        }
        assertSharedCommands(in: menu, viewer: viewer, genomicPosition: 123)
    }

    func testVariantTargetPreservesTableAndGenotypeActionsAndSharedCommands() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)
        let variant = makeVariant()

        let menu = viewer.testBuildContextMenu(for: .variant(variant), genomicPosition: 123)

        guard let tableItem = menu.items.first(where: { $0.title == "View Variant in Table" }),
              let genotypeItem = menu.items.first(where: { $0.title == "View Genotypes at Site" }) else {
            XCTFail("Expected variant table and genotype actions")
            return
        }
        XCTAssertEqual(tableItem.action, #selector(SequenceViewerView.viewVariantInTableAction(_:)))
        XCTAssertEqual(genotypeItem.action, #selector(SequenceViewerView.viewVariantGenotypesAction(_:)))
        XCTAssertEqual((tableItem.representedObject as? AnnotationSearchIndex.SearchResult)?.id, variant.id)
        XCTAssertEqual((genotypeItem.representedObject as? AnnotationSearchIndex.SearchResult)?.id, variant.id)
        assertSharedCommands(in: menu, viewer: viewer, genomicPosition: 123)
    }

    func testSelectedRangeSectionIsSeparatedFromVariantActions() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(for: .variant(makeVariant()), genomicPosition: 123)

        guard let copyIndex = menu.items.firstIndex(where: { $0.title == "Copy Visible Region" }) else {
            XCTFail("Expected shared selection section")
            return
        }
        XCTAssertGreaterThan(copyIndex, 0)
        XCTAssertTrue(menu.items[copyIndex - 1].isSeparatorItem)
    }

    func testAnnotationTargetPreservesAnnotationActionsAndSharedCommands() {
        let viewer = makeViewer()
        viewer.testSetUserSelectionRange(100..<200)
        let annotation = makeAnnotation()

        let menu = viewer.testBuildContextMenu(for: .annotation(annotation), genomicPosition: 123)
        let allItems = allMenuItems(in: menu)

        guard let copyNameItem = allItems.first(where: { $0.title == "Copy Name" }),
              let extractItem = allItems.first(where: { $0.title == "Extract Sequence…" }),
              let annotationZoomItem = allItems.first(where: { $0.title == "Zoom to Annotation" }) else {
            XCTFail("Expected annotation actions")
            return
        }
        XCTAssertEqual(copyNameItem.action, #selector(SequenceViewerView.copyAnnotationName(_:)))
        XCTAssertEqual(extractItem.action, #selector(SequenceViewerView.extractAnnotationSequence(_:)))
        XCTAssertEqual(annotationZoomItem.action, #selector(SequenceViewerView.zoomToAnnotationAction(_:)))
        XCTAssertEqual((copyNameItem.representedObject as? SequenceAnnotation)?.id, annotation.id)
        XCTAssertEqual((extractItem.representedObject as? SequenceAnnotation)?.id, annotation.id)
        XCTAssertEqual((annotationZoomItem.representedObject as? SequenceAnnotation)?.id, annotation.id)
        let annotationInspectorItem = try! XCTUnwrap(allItems.first { $0.title == "Show Annotation in Inspector" })
        XCTAssertEqual(annotationInspectorItem.action, #selector(SequenceViewerView.showAnnotationInInspector(_:)))
        assertSharedCommands(in: menu, viewer: viewer, genomicPosition: 123)
        XCTAssertEqual(allItems.filter { $0.title == "Center View Here" }.count, 1)
        XCTAssertEqual(allItems.filter { $0.title == "Zoom to Selected Region" }.count, 1)
    }

    private func assertSharedCommands(
        in menu: NSMenu,
        viewer: SequenceViewerView,
        genomicPosition: Int
    ) {
        let sharedActionSelectors: [(title: String, action: Selector)] = [
            ("Copy Visible Region", #selector(SequenceViewerView.copySelectionAction(_:))),
            ("Copy Visible Region as FASTA", #selector(SequenceViewerView.copySelectionAsFASTA(_:))),
            ("Extract Visible Region…", #selector(SequenceViewerView.extractSelectionSequence(_:))),
            ("Center View Here", #selector(SequenceViewerView.centerViewHereAction(_:))),
            ("Zoom to Selected Region", #selector(SequenceViewerView.zoomToSelectionAction(_:))),
        ]

        let sharedItems = menu.items.filter { item in
            sharedActionSelectors.contains { expected in expected.title == item.title }
        }
        XCTAssertEqual(sharedItems.map(\.title), sharedActionSelectors.map(\.title))
        XCTAssertEqual(sharedItems.count, sharedActionSelectors.count)
        for expected in sharedActionSelectors {
            let matchingItems = menu.items.filter { $0.title == expected.title }
            XCTAssertEqual(matchingItems.count, 1, "Expected one shared item: \(expected.title)")
            guard let item = matchingItems.first else { continue }
            XCTAssertEqual(item.action, expected.action, expected.title)
            XCTAssertTrue(item.target === viewer, expected.title)
            if expected.title == "Center View Here" {
                XCTAssertEqual((item.representedObject as? NSNumber)?.intValue, genomicPosition)
            }
        }
    }

    private func makeRead() -> AlignedRead {
        AlignedRead(
            name: "read-1",
            flag: 0,
            chromosome: "chr1",
            position: 100,
            mapq: 60,
            cigar: CIGAROperation.parse("10M") ?? [],
            sequence: String(repeating: "A", count: 10),
            qualities: []
        )
    }

    private func makeViewer() -> SequenceViewerView {
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        controller.referenceFrame = ReferenceFrame(
            chromosome: "chr1",
            start: 0,
            end: 800,
            pixelWidth: 800,
            sequenceLength: 10_000
        )
        retainedViewerControllers.append(controller)
        return controller.viewerView
    }

    private func makeVariant() -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: "rs123",
            chromosome: "chr1",
            start: 120,
            end: 121,
            trackId: "variants",
            type: "SNP",
            strand: ".",
            ref: "A",
            alt: "G",
            quality: 42,
            filter: "PASS",
            sampleCount: 4,
            variantRowId: 7
        )
    }

    private func makeAnnotation() -> SequenceAnnotation {
        SequenceAnnotation(
            type: .gene,
            name: "gene-1",
            chromosome: "chr1",
            start: 120,
            end: 180
        )
    }

    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems(in:)) ?? [])
        }
    }

    private func menuToken(_ item: NSMenuItem) -> String {
        item.isSeparatorItem ? "<separator>" : item.title
    }

    private func assertValidSeparators(in menu: NSMenu) {
        XCTAssertFalse(menu.items.first?.isSeparatorItem == true)
        XCTAssertFalse(menu.items.last?.isSeparatorItem == true)
        for pair in zip(menu.items, menu.items.dropFirst()) {
            XCTAssertFalse(pair.0.isSeparatorItem && pair.1.isSeparatorItem)
        }
    }
}
