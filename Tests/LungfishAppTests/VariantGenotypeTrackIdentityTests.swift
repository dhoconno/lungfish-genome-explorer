// VariantGenotypeTrackIdentityTests.swift - multi-track genotype row identity tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishKit
@testable import LungfishApp

private final class VariantSelectionNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedObject: AnyObject?
    private var capturedUserInfo: [AnyHashable: Any]?

    var object: AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return capturedObject
    }

    var userInfo: [AnyHashable: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedUserInfo
    }

    func record(_ notification: Notification) {
        lock.lock()
        capturedObject = notification.object as AnyObject?
        capturedUserInfo = notification.userInfo
        lock.unlock()
    }
}

@MainActor
final class VariantGenotypeTrackIdentityTests: XCTestCase {

    private final class DrawerDelegateSpy: AnnotationTableDrawerDelegate {
        var selectedAnnotations: [AnnotationSearchIndex.SearchResult] = []
        var highlightedVariants: [AnnotationSearchIndex.SearchResult] = []

        func annotationDrawer(
            _ drawer: AnnotationTableDrawerView,
            didSelectAnnotation result: AnnotationSearchIndex.SearchResult
        ) {
            selectedAnnotations.append(result)
        }

        func annotationDrawer(
            _ drawer: AnnotationTableDrawerView,
            didHighlightVariant result: AnnotationSearchIndex.SearchResult
        ) {
            highlightedVariants.append(result)
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

    func testVariantCallSingleAndMultipleSelectionHighlightWithoutNavigation() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let delegate = DrawerDelegateSpy()
        let first = makeVariant(trackId: "track-a", trackName: "Caller A", name: "rs-a")
        let second = makeVariant(trackId: "track-b", trackName: "Caller B", name: "rs-b")
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.displayedAnnotations = [first, second]
        drawer.tableView.reloadData()

        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        drawer.delegate = delegate
        drawer.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: drawer.tableView)
        )

        XCTAssertEqual(delegate.selectedAnnotations.count, 0)
        XCTAssertEqual(delegate.highlightedVariants.map(\.trackId), ["track-a"])
        XCTAssertEqual(drawer.tableView.selectedRowIndexes, IndexSet(integer: 0))

        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: true)
        drawer.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: drawer.tableView)
        )

        XCTAssertEqual(delegate.selectedAnnotations.count, 0)
        XCTAssertEqual(delegate.highlightedVariants.map(\.trackId), ["track-a"])
        XCTAssertEqual(drawer.tableView.selectedRowIndexes, IndexSet(integersIn: 0...1))
    }

    func testGenotypeSelectionHighlightsVariantInSameTrackWithoutNavigation() {
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
        drawer.delegate = delegate
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertEqual(delegate.selectedAnnotations.count, 0)
        XCTAssertEqual(delegate.highlightedVariants.count, 1)
        XCTAssertEqual(delegate.highlightedVariants.first?.trackId, "track-b")
        XCTAssertEqual(delegate.highlightedVariants.first?.variantRowId, 7)
        XCTAssertEqual(delegate.highlightedVariants.first?.name, "rs-b")
        XCTAssertEqual(drawer.tableView.selectedRowIndexes, IndexSet(integer: 0))
    }

    func testExplicitGenotypeActivationNavigatesUsingFullTrackAndRowIdentity() {
        let drawer = makeGenotypeDrawer()
        let delegate = DrawerDelegateSpy()
        let firstVariant = makeVariant(trackId: "track-a", trackName: "Caller A", name: "rs-a")
        let secondVariant = makeVariant(trackId: "track-b", trackName: "Caller B", name: "rs-b")
        drawer.delegate = delegate
        drawer.displayedAnnotations = [firstVariant, secondVariant]
        drawer.displayedGenotypes = [
            makeGenotype(trackId: "track-b", trackName: "Caller B", sampleName: "sample-b")
        ]

        drawer.activateRow(at: 0)

        XCTAssertEqual(delegate.selectedAnnotations.count, 1)
        XCTAssertEqual(delegate.selectedAnnotations.first?.trackId, "track-b")
        XCTAssertEqual(delegate.selectedAnnotations.first?.variantRowId, 7)
        XCTAssertEqual(delegate.selectedAnnotations.first?.name, "rs-b")

        drawer.activateRow(at: -1)
        drawer.activateRow(at: 1)
        XCTAssertEqual(delegate.selectedAnnotations.count, 1)
    }

    func testAnnotationSelectionStillNavigatesAndSampleSelectionDoesNot() {
        let delegate = DrawerDelegateSpy()
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        drawer.activeTab = .annotations
        drawer.displayedAnnotations = [
            AnnotationSearchIndex.SearchResult(
                name: "gene-a", chromosome: "chr1", start: 9, end: 20,
                trackId: "annotations", trackName: "Annotations", type: "gene"
            )
        ]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        drawer.delegate = delegate

        drawer.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: drawer.tableView)
        )

        XCTAssertEqual(delegate.selectedAnnotations.map(\.name), ["gene-a"])
        XCTAssertTrue(delegate.highlightedVariants.isEmpty)

        drawer.activeTab = .samples
        drawer.displayedSamples = [
            .init(rowKey: "sample-a", name: "sample-a", sourceFile: "reads.bam", isVisible: true, metadata: [:])
        ]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        drawer.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: drawer.tableView)
        )

        XCTAssertEqual(delegate.selectedAnnotations.map(\.name), ["gene-a"])
        XCTAssertTrue(delegate.highlightedVariants.isEmpty)
    }

    func testVariantLocalFilterPreservesSelectionByTrackAndRowAndPublishesRestoredSelectionOnce() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let delegate = DrawerDelegateSpy()
        let alpha = makeVariant(trackId: "track-a", trackName: "Alpha", name: "rs-a")
        let beta = makeVariant(trackId: "track-b", trackName: "Beta", name: "rs-b")
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.configureColumnsForTab(.variants)
        drawer.setVariantBaseResults([beta, alpha])
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        drawer.delegate = delegate

        drawer.variantColumnFilterClauses = [.init(key: "track_name", op: "=", value: "Alpha")]
        drawer.applyVariantColumnFiltersFromBase()

        XCTAssertEqual(delegate.selectedAnnotations.count, 0)
        XCTAssertEqual(delegate.highlightedVariants.map(\.trackId), ["track-a"])
        XCTAssertEqual(drawer.displayedAnnotations.map(\.trackId), ["track-a"])
        XCTAssertEqual(drawer.tableView.selectedRowIndexes, IndexSet(integer: 0))
    }

    func testVariantSortPreservesSelectionWhenTrackIdentityMovesToNewIndex() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let delegate = DrawerDelegateSpy()
        let alpha = makeVariant(trackId: "track-a", trackName: "Alpha", name: "rs-a")
        let beta = makeVariant(trackId: "track-b", trackName: "Beta", name: "rs-b")
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.configureColumnsForTab(.variants)
        drawer.displayedAnnotations = [beta, alpha]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        drawer.delegate = delegate
        let item = NSMenuItem()
        item.representedObject = drawer.tableView.tableColumns.first {
            $0.title == "Variant Track"
        }?.identifier.rawValue

        drawer.sortVariantColumnAscending(item)

        XCTAssertEqual(delegate.selectedAnnotations.count, 0)
        XCTAssertEqual(delegate.highlightedVariants.map(\.trackId), ["track-a"])
        XCTAssertEqual(drawer.displayedAnnotations.map(\.trackId), ["track-a", "track-b"])
        XCTAssertEqual(drawer.tableView.selectedRowIndexes, IndexSet(integer: 0))
    }

    func testViewerVariantHighlightPreservesViewportAndPublishesSelection() {
        let controller = ViewerViewController()
        _ = controller.view
        let drawer = AnnotationTableDrawerView(frame: .zero)
        let variant = makeVariant(trackId: "track-a", trackName: "Caller A", name: "rs-a")
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .genotypes
        drawer.displayedAnnotations = [variant]
        drawer.displayedGenotypes = [
            makeGenotype(trackId: "track-a", trackName: "Caller A", sampleName: "sample-a"),
            makeGenotype(trackId: "track-a", trackName: "Caller A", sampleName: "sample-b"),
        ]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.referenceFrame = ReferenceFrame(
            chromosome: "chr1", start: 10, end: 510, pixelWidth: 800, sequenceLength: 10_000
        )
        let notification = expectation(description: "one enriched variant selection")
        notification.expectedFulfillmentCount = 1
        notification.assertForOverFulfill = true
        let capture = VariantSelectionNotificationCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .variantSelected,
            object: nil,
            queue: nil
        ) { posted in
            capture.record(posted)
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.annotationDrawer(drawer, didHighlightVariant: variant)

        wait(for: [notification], timeout: 0.1)
        XCTAssertEqual(controller.referenceFrame?.chromosome, "chr1")
        XCTAssertEqual(controller.referenceFrame?.start, 10)
        XCTAssertEqual(controller.referenceFrame?.end, 510)
        XCTAssertEqual(controller.viewerView.selectedAnnotation?.name, "rs-a")
        XCTAssertTrue(capture.object === drawer)
        XCTAssertEqual(drawer.tableView.selectedRowIndexes, IndexSet(integer: 1))
        let published = capture.userInfo?[NotificationUserInfoKey.searchResult]
            as? AnnotationSearchIndex.SearchResult
        XCTAssertEqual(published?.trackId, "track-a")
        XCTAssertEqual(published?.variantRowId, 7)
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
