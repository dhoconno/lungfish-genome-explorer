import AppKit
import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishKit

@MainActor
final class MiniBAMViewportTests: XCTestCase {

    func testMiniPileupViewportUpdateDoesNotRepackReads() {
        let pileupView = MiniPileupView(frame: .zero)
        let reads = makeReads(count: 256)

        pileupView.configure(
            reads: reads,
            contigName: "OR833768.1",
            contigLength: 29_691,
            viewportWidth: 480,
            viewportHeight: 220,
            zoomLevel: 1.0,
            rebuildReference: true
        )

        let initialPackCount = pileupView.testPackInvocationCount
        let initialFrameWidth = pileupView.frame.width

        pileupView.updateViewport(
            viewportWidth: 760,
            viewportHeight: 220,
            zoomLevel: 1.0
        )

        XCTAssertEqual(pileupView.testPackInvocationCount, initialPackCount)
        XCTAssertNotEqual(pileupView.frame.width, initialFrameWidth)
    }

    func testMiniPileupDefersReferenceInferenceWithoutReferenceSequence() {
        let pileupView = MiniPileupView(frame: .zero)
        let reads = makeReads(count: 64)

        pileupView.configure(
            reads: reads,
            contigName: "OR833768.1",
            contigLength: 29_691,
            viewportWidth: 480,
            viewportHeight: 220,
            zoomLevel: 1.0,
            rebuildReference: true
        )

        XCTAssertEqual(pileupView.testInferredReferenceBaseCount, 0)

        let inferred = MiniPileupView.inferReferenceBases(reads: reads, contigLength: 29_691)
        XCTAssertGreaterThan(inferred.count, 0)

        pileupView.applyInferredReferenceBases(inferred)
        XCTAssertEqual(pileupView.testInferredReferenceBaseCount, inferred.count)
    }

    func testMiniPileupReferenceTrackSkipsPerBaseDrawingAtZoomToFitScale() {
        XCTAssertFalse(
            MiniPileupView.testingShouldDrawPerBaseReferenceTrack(basePixelWidth: 0.001),
            "Zoom-to-fit views for megabase references must not iterate and draw every reference base."
        )
        XCTAssertTrue(
            MiniPileupView.testingShouldDrawPerBaseReferenceTrack(basePixelWidth: 1.0)
        )
    }

    func testMiniBAMPinchZoomLevelMapsDirectionAndClampsToViewportBounds() {
        XCTAssertGreaterThan(
            MiniBAMViewController.testingZoomLevel(
                afterMagnification: 0.2,
                currentZoom: 2,
                contigLength: 10_000
            ),
            2
        )
        XCTAssertLessThan(
            MiniBAMViewController.testingZoomLevel(
                afterMagnification: -0.2,
                currentZoom: 2,
                contigLength: 10_000
            ),
            2
        )
        XCTAssertEqual(
            MiniBAMViewController.testingZoomLevel(
                afterMagnification: 0,
                currentZoom: 2,
                contigLength: 10_000
            ),
            2,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            MiniBAMViewController.testingZoomLevel(
                afterMagnification: -10,
                currentZoom: 2,
                contigLength: 10_000
            ),
            1
        )
        XCTAssertLessThanOrEqual(
            MiniBAMViewController.testingZoomLevel(
                afterMagnification: 10,
                currentZoom: 20_000,
                contigLength: 10_000
            ),
            5_000
        )
    }

    /// Reference and read base letters are SF Mono Medium sized to the zoom. Looking that font
    /// up per draw could return nil under load, and CoreText raised on the nil font, so the
    /// view keeps the face instead.
    func testMiniPileupDrawsBaseLettersWithoutLookingSFMonoMediumUp() throws {
        let pileupView = MiniPileupView(frame: .zero)
        let reference = String(repeating: "ACGTTGCA", count: 8)
        let read = AlignedRead(
            name: "read-1", flag: 0, chromosome: "contig", position: 4, mapq: 60,
            cigar: [CIGAROperation(op: .match, length: 40)],
            sequence: String(reference.dropFirst(4).prefix(40)),
            qualities: Array(repeating: 40, count: 40)
        )
        // 64 bp across a 600 pt viewport is about 9 pt per base, wide enough for letters on
        // both the reference track and the read.
        pileupView.configure(
            reads: [read], contigName: "contig", contigLength: 64,
            viewportWidth: 600, viewportHeight: 220, rebuildReference: true, referenceSequence: reference
        )
        let rep = try XCTUnwrap(pileupView.bitmapImageRepForCachingDisplay(in: pileupView.bounds))

        let lookups = monospacedSystemFontLookups(weight: .medium) {
            pileupView.cacheDisplay(in: pileupView.bounds, to: rep)
        }
        XCTAssertEqual(lookups, [], "the pileup looked SF Mono Medium up while drawing")
    }

    private func makeReads(count: Int) -> [AlignedRead] {
        let cigar = [CIGAROperation(op: .match, length: 150)]
        let sequence = String(repeating: "A", count: 150)
        let qualities = Array(repeating: UInt8(40), count: 150)

        return (0..<count).map { index in
            AlignedRead(
                name: "read-\(index)",
                flag: 0,
                chromosome: "OR833768.1",
                position: index * 20,
                mapq: 60,
                cigar: cigar,
                sequence: sequence,
                qualities: qualities,
                mdTag: "150"
            )
        }
    }
}
