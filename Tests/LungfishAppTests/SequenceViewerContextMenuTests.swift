// SequenceViewerContextMenuTests.swift - Context menu composition regressions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class SequenceViewerContextMenuTests: XCTestCase {
    func testSequenceTargetWithSelectionContainsSharedCommandsOnce() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        viewer.testSetUserSelectionRange(100..<200)

        let menu = viewer.testBuildContextMenu(
            for: .sequence,
            genomicPosition: 123
        )

        let sharedTitles = [
            "Copy Visible Region",
            "Copy Visible Region as FASTA",
            "Extract Visible Region…",
            "Center View Here",
            "Zoom to Selected Region",
        ]
        let sharedItems = menu.items.filter { sharedTitles.contains($0.title) }

        XCTAssertEqual(sharedItems.map(\.title), sharedTitles)
        XCTAssertEqual(sharedItems.count, sharedTitles.count)
        for item in sharedItems {
            XCTAssertTrue(item.target === viewer, item.title)
        }

        let zoomItem = try! XCTUnwrap(menu.items.first { $0.title == "Zoom to Selected Region" })
        XCTAssertEqual(zoomItem.action, #selector(SequenceViewerView.zoomToSelectionAction(_:)))

        let centerItem = try! XCTUnwrap(menu.items.first { $0.title == "Center View Here" })
        XCTAssertEqual((centerItem.representedObject as? NSNumber)?.intValue, 123)
    }

    func testEmptyAlignmentTargetWithSelectionContainsOnlySharedActionsAndValidSeparators() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))

        let menu = viewer.testBuildContextMenu(for: .sequence, genomicPosition: 123)

        XCTAssertNotNil(menu.items.first { $0.title == "Select All" })
        XCTAssertNotNil(menu.items.first { $0.title == "Zoom to Fit" })
        XCTAssertNotNil(menu.items.first { $0.title == "Show in Inspector" })
        XCTAssertNotNil(menu.items.first { $0.title == "Center View Here" })
    }

    func testAlignmentTargetPreservesRevealActionPayloadAndSharedCommands() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        assertSharedCommands(in: menu, viewer: viewer)
    }

    func testReadTargetPreservesSpecializedActionsAndSharedCommands() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        assertSharedCommands(in: menu, viewer: viewer)
    }

    func testVariantTargetPreservesTableAndGenotypeActionsAndSharedCommands() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        assertSharedCommands(in: menu, viewer: viewer)
    }

    func testSelectedRangeSectionIsSeparatedFromVariantActions() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
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
        assertSharedCommands(in: menu, viewer: viewer)
        XCTAssertEqual(allItems.filter { $0.title == "Center View Here" }.count, 1)
        XCTAssertEqual(allItems.filter { $0.title == "Zoom to Selected Region" }.count, 1)
    }

    private func assertSharedCommands(in menu: NSMenu, viewer: SequenceViewerView) {
        let sharedTitles = [
            "Copy Visible Region",
            "Copy Visible Region as FASTA",
            "Extract Visible Region…",
            "Center View Here",
            "Zoom to Selected Region",
        ]
        let sharedItems = menu.items.filter { sharedTitles.contains($0.title) }
        XCTAssertEqual(sharedItems.map(\.title), sharedTitles)
        XCTAssertEqual(sharedItems.count, sharedTitles.count)
        for item in sharedItems {
            XCTAssertTrue(item.target === viewer, item.title)
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
