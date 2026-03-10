import XCTest
@testable import LungfishIO

final class BarcodeScoutResultTests: XCTestCase {

    // MARK: - BarcodeScoutResult

    func testAssignmentRate() {
        let result = BarcodeScoutResult(
            readsScanned: 100,
            detections: [],
            unassignedCount: 20,
            scoutedKitIDs: ["BC01"],
            elapsedSeconds: 1.0
        )
        XCTAssertEqual(result.assignmentRate, 0.80, accuracy: 0.001)
    }

    func testAssignmentRateZeroReads() {
        let result = BarcodeScoutResult(
            readsScanned: 0,
            detections: [],
            unassignedCount: 0,
            scoutedKitIDs: [],
            elapsedSeconds: 0
        )
        XCTAssertEqual(result.assignmentRate, 0.0)
    }

    func testAcceptedCount() {
        let detections = [
            BarcodeDetection(barcodeID: "BC01", kitID: "NBD114", hitCount: 50, hitPercentage: 50.0, disposition: .accepted),
            BarcodeDetection(barcodeID: "BC02", kitID: "NBD114", hitCount: 30, hitPercentage: 30.0, disposition: .rejected),
            BarcodeDetection(barcodeID: "BC03", kitID: "NBD114", hitCount: 10, hitPercentage: 10.0, disposition: .undecided),
            BarcodeDetection(barcodeID: "BC04", kitID: "NBD114", hitCount: 5, hitPercentage: 5.0, disposition: .accepted),
        ]
        let result = BarcodeScoutResult(
            readsScanned: 100,
            detections: detections,
            unassignedCount: 5,
            scoutedKitIDs: ["NBD114"],
            elapsedSeconds: 2.0
        )
        XCTAssertEqual(result.acceptedCount, 2)
    }

    func testAcceptedDetections() {
        let detections = [
            BarcodeDetection(barcodeID: "BC01", kitID: "NBD114", hitCount: 50, hitPercentage: 50.0, disposition: .accepted),
            BarcodeDetection(barcodeID: "BC02", kitID: "NBD114", hitCount: 30, hitPercentage: 30.0, disposition: .rejected),
        ]
        let result = BarcodeScoutResult(
            readsScanned: 100,
            detections: detections,
            unassignedCount: 20,
            scoutedKitIDs: ["NBD114"],
            elapsedSeconds: 1.0
        )
        let accepted = result.acceptedDetections
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.barcodeID, "BC01")
    }

    func testFilename() {
        XCTAssertEqual(BarcodeScoutResult.filename, "scout-result.json")
    }

    func testCodableRoundTrip() throws {
        let detection = BarcodeDetection(
            barcodeID: "BC01",
            kitID: "NBD114",
            hitCount: 500,
            hitPercentage: 50.0,
            matchedEnds: .bothEnds,
            meanEditDistance: 1.5,
            disposition: .accepted,
            sampleName: "Sample-1"
        )
        let result = BarcodeScoutResult(
            readsScanned: 1000,
            detections: [detection],
            unassignedCount: 500,
            scoutedKitIDs: ["NBD114"],
            elapsedSeconds: 5.2
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BarcodeScoutResult.self, from: data)

        XCTAssertEqual(decoded.readsScanned, 1000)
        XCTAssertEqual(decoded.detections.count, 1)
        XCTAssertEqual(decoded.detections.first?.barcodeID, "BC01")
        XCTAssertEqual(decoded.detections.first?.sampleName, "Sample-1")
        XCTAssertEqual(decoded.detections.first?.matchedEnds, .bothEnds)
        XCTAssertEqual(decoded.detections.first?.disposition, .accepted)
        XCTAssertEqual(decoded.unassignedCount, 500)
        XCTAssertEqual(decoded.elapsedSeconds, 5.2, accuracy: 0.001)
    }

    // MARK: - BarcodeDetection

    func testDetectionDefaults() {
        let detection = BarcodeDetection(
            barcodeID: "BC01",
            kitID: "test",
            hitCount: 10,
            hitPercentage: 5.0
        )
        XCTAssertEqual(detection.disposition, .undecided)
        XCTAssertEqual(detection.matchedEnds, .unknown)
        XCTAssertNil(detection.sampleName)
        XCTAssertNil(detection.meanEditDistance)
    }

    // MARK: - Enum Raw Values

    func testDetectionDispositionRawValues() {
        XCTAssertEqual(DetectionDisposition.accepted.rawValue, "accepted")
        XCTAssertEqual(DetectionDisposition.rejected.rawValue, "rejected")
        XCTAssertEqual(DetectionDisposition.undecided.rawValue, "undecided")
    }

    func testMatchedEndsRawValues() {
        XCTAssertEqual(MatchedEnds.fivePrimeOnly.rawValue, "fivePrimeOnly")
        XCTAssertEqual(MatchedEnds.threePrimeOnly.rawValue, "threePrimeOnly")
        XCTAssertEqual(MatchedEnds.bothEnds.rawValue, "bothEnds")
        XCTAssertEqual(MatchedEnds.unknown.rawValue, "unknown")
    }

    func testBarcodeSymmetryModeCases() {
        XCTAssertEqual(BarcodeSymmetryMode.allCases.count, 3)
        XCTAssertEqual(BarcodeSymmetryMode.symmetric.rawValue, "symmetric")
        XCTAssertEqual(BarcodeSymmetryMode.asymmetric.rawValue, "asymmetric")
        XCTAssertEqual(BarcodeSymmetryMode.singleEnd.rawValue, "singleEnd")
    }

    func testBarcodeSymmetryModeCodable() throws {
        for mode in BarcodeSymmetryMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(BarcodeSymmetryMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
