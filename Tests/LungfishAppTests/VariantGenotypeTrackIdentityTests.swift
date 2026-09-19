// VariantGenotypeTrackIdentityTests.swift - multi-track genotype row identity tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class VariantGenotypeTrackIdentityTests: XCTestCase {

    private final class DrawerDelegateSpy: AnnotationTableDrawerDelegate {
        var selectedAnnotation: AnnotationSearchIndex.SearchResult?

        func annotationDrawer(
            _ drawer: AnnotationTableDrawerView,
            didSelectAnnotation result: AnnotationSearchIndex.SearchResult
        ) {
            selectedAnnotation = result
        }

        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion]) {}
        func annotationDrawer(
            _ drawer: AnnotationTableDrawerView,
            didUpdateVisibleVariantRenderKeys keys: Set<String>?
        ) {}
        func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {}
        func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}
    }

    func testGenotypeFilterKeepsOnlyMatchingTrackWhenRowIDsOverlap() {
        let drawer = makeGenotypeDrawer()
        let firstVariant = makeVariant(trackId: "track-a", trackName: "Caller A", name: "rs-a")
        let secondVariant = makeVariant(trackId: "track-b", trackName: "Caller B", name: "rs-b")

        drawer.baseDisplayedVariantAnnotations = [firstVariant, secondVariant]
        drawer.baseDisplayedGenotypes = [
            makeGenotype(trackId: "track-a", trackName: "Caller A", sampleName: "sample-a"),
            makeGenotype(trackId: "track-b", trackName: "Caller B", sampleName: "sample-b"),
        ]
        drawer.genotypeColumnFilterClauses = [
            .init(key: "sample", op: "=", value: "sample-b")
        ]

        drawer.applyGenotypeColumnFiltersFromBase()

        XCTAssertEqual(drawer.displayedGenotypes.map(\.trackId), ["track-b"])
        XCTAssertEqual(drawer.displayedAnnotations.map(\.trackId), ["track-b"])
    }

    func testGenotypeSelectionNavigatesToVariantInSameTrackWhenRowIDsOverlap() {
        let drawer = makeGenotypeDrawer()
        let delegate = DrawerDelegateSpy()
        let firstVariant = makeVariant(trackId: "track-a", trackName: "Caller A", name: "rs-a")
        let secondVariant = makeVariant(trackId: "track-b", trackName: "Caller B", name: "rs-b")

        drawer.delegate = delegate
        drawer.displayedAnnotations = [firstVariant, secondVariant]
        drawer.displayedGenotypes = [
            makeGenotype(trackId: "track-b", trackName: "Caller B", sampleName: "sample-b")
        ]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        delegate.selectedAnnotation = nil

        drawer.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: drawer.tableView)
        )

        XCTAssertEqual(delegate.selectedAnnotation?.trackId, "track-b")
        XCTAssertEqual(delegate.selectedAnnotation?.variantRowId, 7)
        XCTAssertEqual(delegate.selectedAnnotation?.name, "rs-b")
    }

    func testProgrammaticSelectionUsesTrackForCallsAndGenotypes() {
        let drawer = makeGenotypeDrawer()
        let first = makeVariant(trackId: "track-a", trackName: "Caller A", name: "rs-a")
        let second = makeVariant(trackId: "track-b", trackName: "Caller B", name: "rs-b")
        drawer.displayedAnnotations = [first, second]
        drawer.activeVariantSubtab = .calls
        drawer.tableView.reloadData()
        drawer.selectVariant(matching: second)
        XCTAssertEqual(drawer.tableView.selectedRow, 1)

        drawer.activeVariantSubtab = .genotypes
        drawer.displayedGenotypes = [
            makeGenotype(trackId: "track-b", trackName: "Caller B", sampleName: "sample-b"),
            makeGenotype(trackId: "track-a", trackName: "Caller A", sampleName: "sample-a")
        ]
        drawer.tableView.reloadData()
        drawer.selectVariant(matching: second)
        XCTAssertEqual(drawer.tableView.selectedRow, 0)
    }

    private func makeGenotypeDrawer() -> AnnotationTableDrawerView {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .genotypes
        return drawer
    }

    private func makeVariant(
        trackId: String,
        trackName: String,
        name: String
    ) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: name,
            chromosome: "chr1",
            start: 99,
            end: 100,
            trackId: trackId,
            trackName: trackName,
            type: "SNP",
            ref: "A",
            alt: "G",
            variantRowId: 7
        )
    }

    private func makeGenotype(
        trackId: String,
        trackName: String,
        sampleName: String
    ) -> AnnotationTableDrawerView.GenotypeDisplayRow {
        AnnotationTableDrawerView.GenotypeDisplayRow(
            sampleName: sampleName,
            variantRowId: 7,
            variantID: ".",
            chromosome: "chr1",
            position: 99,
            ref: "A",
            alt: "G",
            genotype: "0/1",
            zygosity: "Het",
            alleleDepths: "10,10",
            depth: 20,
            genotypeQuality: 99,
            alleleBalance: 0.5,
            infoDict: [:],
            trackId: trackId,
            trackName: trackName
        )
    }
}
