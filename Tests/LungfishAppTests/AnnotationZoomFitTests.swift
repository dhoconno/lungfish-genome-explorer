import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class AnnotationZoomFitTests: XCTestCase {
    func testAnnotationFitKeepsWholeFeatureInsideNarrowCanvasWithGutter() throws {
        let controller = makeController(width: 600, chromosome: "NC_045512.2", length: 29_903)
        let annotation = makeAnnotation(chromosome: "NC_045512.2", start: 28_273, end: 29_533)

        controller.viewerView.zoomToAnnotation(annotation)

        let frame = try XCTUnwrap(controller.referenceFrame)
        XCTAssertEqual(frame.start, 28_210, accuracy: 0.001)
        XCTAssertEqual(frame.end, 29_596, accuracy: 0.001)
        XCTAssertEqual(frame.pixelWidth, 600)
        XCTAssertEqual(frame.leadingInset, 120)
        assertVisible(annotation, in: frame, width: 600)
    }

    func testCrossChromosomeNavigationUsesExactExtentAndLiveCanvasGeometry() throws {
        let controller = makeController(width: 600, chromosome: "chr1", length: 29_903)

        controller.navigateToChromosomeAndPosition(
            chromosome: "chr2", chromosomeLength: 29_903, start: 28_210, end: 29_596
        )

        let frame = try XCTUnwrap(controller.referenceFrame)
        XCTAssertEqual(frame.chromosome, "chr2")
        XCTAssertEqual(frame.start, 28_210, accuracy: 0.001)
        XCTAssertEqual(frame.end, 29_596, accuracy: 0.001)
        XCTAssertEqual(frame.pixelWidth, 600)
        XCTAssertEqual(frame.leadingInset, 120)
        XCTAssertEqual(frame.trailingInset, ReferenceFrame.defaultTrailingInset)
        XCTAssertGreaterThanOrEqual(frame.screenPosition(for: 28_210.0), frame.leadingInset)
        XCTAssertLessThanOrEqual(frame.screenPosition(for: 29_596.0), 600 - frame.trailingInset)
    }

    func testMappingZoomRegionRemainsVisibleAfterSharedNavigation() throws {
        let controller = makeController(width: 600, chromosome: "chr1", length: 29_903)
        let annotation = makeAnnotation(chromosome: "chr1", start: 28_273, end: 29_533)
        let region = try XCTUnwrap(MappingAnnotationActionCoordinator.zoomRegion(for: annotation, chromosomeLength: 29_903))

        controller.navigateToChromosomeAndPosition(
            chromosome: region.chromosome, chromosomeLength: 29_903,
            start: region.start, end: region.end
        )

        let frame = try XCTUnwrap(controller.referenceFrame)
        assertVisible(annotation, in: frame, width: 600)
    }

    func testBoundaryAnnotationFitsAreClampedAndVisibleWithAndWithoutGutter() throws {
        for gutter in [CGFloat(0), 120] {
            for bounds in [(0, 20), (80, 100), (0, 100), (50, 51)] {
                let controller = makeController(width: 600, chromosome: "chr1", length: 100, gutter: gutter)
                let annotation = makeAnnotation(chromosome: "chr1", start: bounds.0, end: bounds.1)
                controller.viewerView.zoomToAnnotation(annotation)
                let frame = try XCTUnwrap(controller.referenceFrame)
                XCTAssertGreaterThanOrEqual(frame.start, 0)
                XCTAssertLessThanOrEqual(frame.end, 100)
                XCTAssertGreaterThan(frame.scale, 0)
                assertVisible(annotation, in: frame, width: 600)
            }
        }
    }

    func testResizePreservesFittedGenomicExtentAndVisibility() throws {
        let controller = makeController(width: 1_000, chromosome: "NC_045512.2", length: 29_903)
        let annotation = makeAnnotation(chromosome: "NC_045512.2", start: 28_273, end: 29_533)
        controller.viewerView.zoomToAnnotation(annotation)
        let fittedStart = try XCTUnwrap(controller.referenceFrame).start
        let fittedEnd = try XCTUnwrap(controller.referenceFrame).end

        controller.viewerView.frame.size.width = 600
        controller.viewDidLayout()

        let frame = try XCTUnwrap(controller.referenceFrame)
        XCTAssertEqual(frame.start, fittedStart)
        XCTAssertEqual(frame.end, fittedEnd)
        XCTAssertEqual(frame.pixelWidth, 600)
        assertVisible(annotation, in: frame, width: 600)
    }

    func testPendingSelectionRecenterDoesNotReplaceNewExplicitFit() async throws {
        let controller = makeController(width: 600, chromosome: "chr1", length: 29_903)
        let result = makeResult(chromosome: "chr1", start: 28_273, end: 29_533)
        controller.annotationDrawer(AnnotationTableDrawerView(frame: .zero), didSelectAnnotation: result)
        let annotation = makeAnnotation(chromosome: "chr1", start: 28_273, end: 29_533)
        controller.viewerView.zoomToAnnotation(annotation)
        let fittedStart = try XCTUnwrap(controller.referenceFrame).start
        let fittedEnd = try XCTUnwrap(controller.referenceFrame).end

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.referenceFrame?.start, fittedStart)
        XCTAssertEqual(controller.referenceFrame?.end, fittedEnd)
    }

    func testPendingSelectionRecenterDoesNotReplaceNewCrossChromosomeNavigation() async throws {
        let controller = makeController(width: 600, chromosome: "chr1", length: 29_903)
        controller.annotationDrawer(
            AnnotationTableDrawerView(frame: .zero),
            didSelectAnnotation: makeResult(chromosome: "chr1", start: 28_273, end: 29_533)
        )
        controller.navigateToChromosomeAndPosition(
            chromosome: "chr2", chromosomeLength: 10_000, start: 100, end: 500
        )

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.referenceFrame?.chromosome, "chr2")
        XCTAssertEqual(controller.referenceFrame?.start, 100)
        XCTAssertEqual(controller.referenceFrame?.end, 500)
    }

    private func makeController(
        width: CGFloat,
        chromosome: String,
        length: Int,
        gutter: CGFloat = 120
    ) -> ViewerViewController {
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        controller.viewerView._cachedVariantDataStartX = gutter
        controller.referenceFrame = ReferenceFrame(
            chromosome: chromosome, start: 0, end: Double(length),
            pixelWidth: 1_000, sequenceLength: length
        )
        return controller
    }

    private func makeAnnotation(chromosome: String, start: Int, end: Int) -> SequenceAnnotation {
        SequenceAnnotation(
            type: .gene, name: "N", chromosome: chromosome,
            intervals: [AnnotationInterval(start: start, end: end)]
        )
    }

    private func makeResult(chromosome: String, start: Int, end: Int) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: "N", chromosome: chromosome, start: start, end: end,
            trackId: "annotations", type: "gene", strand: "+"
        )
    }

    private func assertVisible(_ annotation: SequenceAnnotation, in frame: ReferenceFrame, width: CGFloat) {
        XCTAssertGreaterThanOrEqual(frame.screenPosition(for: Double(annotation.start)), frame.leadingInset - 0.001)
        XCTAssertLessThanOrEqual(frame.screenPosition(for: Double(annotation.end)), width - frame.trailingInset + 0.001)
    }
}
