import XCTest
@testable import LungfishApp
@testable import LungfishCore

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
