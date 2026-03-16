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

    // MARK: - Edge Cases for Computed Properties

    func testAcceptedCountAllRejected() {
        let detections = [
            BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 50, hitPercentage: 50.0, disposition: .rejected),
            BarcodeDetection(barcodeID: "BC02", kitID: "K", hitCount: 30, hitPercentage: 30.0, disposition: .rejected),
        ]
        let result = BarcodeScoutResult(readsScanned: 100, detections: detections, unassignedCount: 20, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)
        XCTAssertEqual(result.acceptedCount, 0)
        XCTAssertTrue(result.acceptedDetections.isEmpty)
    }

    func testAcceptedCountAllAccepted() {
        let detections = [
            BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 50, hitPercentage: 50.0, disposition: .accepted),
            BarcodeDetection(barcodeID: "BC02", kitID: "K", hitCount: 30, hitPercentage: 30.0, disposition: .accepted),
            BarcodeDetection(barcodeID: "BC03", kitID: "K", hitCount: 20, hitPercentage: 20.0, disposition: .accepted),
        ]
        let result = BarcodeScoutResult(readsScanned: 100, detections: detections, unassignedCount: 0, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)
        XCTAssertEqual(result.acceptedCount, 3)
        XCTAssertEqual(result.acceptedDetections.count, 3)
    }

    func testAcceptedCountAllUndecided() {
        let detections = [
            BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 50, hitPercentage: 50.0, disposition: .undecided),
        ]
        let result = BarcodeScoutResult(readsScanned: 100, detections: detections, unassignedCount: 50, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)
        XCTAssertEqual(result.acceptedCount, 0)
        XCTAssertTrue(result.acceptedDetections.isEmpty)
    }

    func testAssignmentRateFullAssignment() {
        let result = BarcodeScoutResult(readsScanned: 1000, detections: [], unassignedCount: 0, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)
        XCTAssertEqual(result.assignmentRate, 1.0, accuracy: 0.001)
    }

    func testAssignmentRateZeroAssignment() {
        let result = BarcodeScoutResult(readsScanned: 1000, detections: [], unassignedCount: 1000, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)
        XCTAssertEqual(result.assignmentRate, 0.0, accuracy: 0.001)
    }

    func testAcceptedDetectionsPreservesOrder() {
        let detections = [
            BarcodeDetection(barcodeID: "BC03", kitID: "K", hitCount: 10, hitPercentage: 10.0, disposition: .accepted),
            BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 50, hitPercentage: 50.0, disposition: .rejected),
            BarcodeDetection(barcodeID: "BC02", kitID: "K", hitCount: 30, hitPercentage: 30.0, disposition: .accepted),
        ]
        let result = BarcodeScoutResult(readsScanned: 100, detections: detections, unassignedCount: 10, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)
        let accepted = result.acceptedDetections
        XCTAssertEqual(accepted.count, 2)
        XCTAssertEqual(accepted[0].barcodeID, "BC03")
        XCTAssertEqual(accepted[1].barcodeID, "BC02")
    }

    // MARK: - Codable Edge Cases

    func testCodableRoundTripWithNilOptionals() throws {
        let detection = BarcodeDetection(
            barcodeID: "BC01", kitID: "K", hitCount: 100, hitPercentage: 10.0,
            matchedEnds: .unknown, meanEditDistance: nil, disposition: .undecided, sampleName: nil
        )
        let result = BarcodeScoutResult(readsScanned: 1000, detections: [detection], unassignedCount: 900, scoutedKitIDs: ["K"], elapsedSeconds: 0.5)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BarcodeScoutResult.self, from: data)

        XCTAssertNil(decoded.detections.first?.meanEditDistance)
        XCTAssertNil(decoded.detections.first?.sampleName)
    }

    func testCodableRoundTripEmptyDetections() throws {
        let result = BarcodeScoutResult(readsScanned: 10000, detections: [], unassignedCount: 10000, scoutedKitIDs: ["NBD114"], elapsedSeconds: 3.0)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BarcodeScoutResult.self, from: data)

        XCTAssertTrue(decoded.detections.isEmpty)
        XCTAssertEqual(decoded.readsScanned, 10000)
    }

    func testCodableRoundTripMultipleKitIDs() throws {
        let result = BarcodeScoutResult(readsScanned: 5000, detections: [], unassignedCount: 5000, scoutedKitIDs: ["NBD114", "RBK114", "SQK-RBK004"], elapsedSeconds: 2.0)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BarcodeScoutResult.self, from: data)

        XCTAssertEqual(decoded.scoutedKitIDs, ["NBD114", "RBK114", "SQK-RBK004"])
    }

    func testCodableRoundTripPreservesUUID() throws {
        let fixedID = UUID()
        let detection = BarcodeDetection(id: fixedID, barcodeID: "BC01", kitID: "K", hitCount: 10, hitPercentage: 1.0)
        let result = BarcodeScoutResult(readsScanned: 1000, detections: [detection], unassignedCount: 990, scoutedKitIDs: ["K"], elapsedSeconds: 1.0)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BarcodeScoutResult.self, from: data)

        XCTAssertEqual(decoded.detections.first?.id, fixedID)
    }

    // MARK: - Disposition Cycling

    func testDispositionCycleOrder() {
        XCTAssertEqual(DetectionDisposition.undecided.next, .accepted)
        XCTAssertEqual(DetectionDisposition.accepted.next, .rejected)
        XCTAssertEqual(DetectionDisposition.rejected.next, .undecided)
    }

    func testDispositionFullCycleReturnsToStart() {
        var d: DetectionDisposition = .undecided
        d = d.next  // accepted
        d = d.next  // rejected
        d = d.next  // undecided
        XCTAssertEqual(d, .undecided)
    }

    func testDetectionDispositionMutation() {
        var detection = BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 10, hitPercentage: 1.0, disposition: .undecided)
        XCTAssertEqual(detection.disposition, .undecided)
        detection.disposition = .accepted
        XCTAssertEqual(detection.disposition, .accepted)
        detection.disposition = .rejected
        XCTAssertEqual(detection.disposition, .rejected)
    }

    func testSampleNameMutation() {
        var detection = BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 10, hitPercentage: 1.0)
        XCTAssertNil(detection.sampleName)
        detection.sampleName = "Patient-001"
        XCTAssertEqual(detection.sampleName, "Patient-001")
        detection.sampleName = nil
        XCTAssertNil(detection.sampleName)
    }

    // MARK: - Threshold Application

    func testApplyThresholds() {
        var result = BarcodeScoutResult(
            readsScanned: 1000,
            detections: [
                BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 500, hitPercentage: 50.0),
                BarcodeDetection(barcodeID: "BC02", kitID: "K", hitCount: 15, hitPercentage: 1.5),
                BarcodeDetection(barcodeID: "BC03", kitID: "K", hitCount: 5, hitPercentage: 0.5),
                BarcodeDetection(barcodeID: "BC04", kitID: "K", hitCount: 2, hitPercentage: 0.2),
                BarcodeDetection(barcodeID: "BC05", kitID: "K", hitCount: 10, hitPercentage: 1.0),
            ],
            unassignedCount: 468,
            scoutedKitIDs: ["K"],
            elapsedSeconds: 1.0
        )

        result.applyThresholds(acceptMinHits: 10, rejectMaxHits: 3)

        XCTAssertEqual(result.detections[0].disposition, .accepted, "500 hits >= 10")
        XCTAssertEqual(result.detections[1].disposition, .accepted, "15 hits >= 10")
        XCTAssertEqual(result.detections[2].disposition, .undecided, "5 hits between thresholds")
        XCTAssertEqual(result.detections[3].disposition, .rejected, "2 hits <= 3")
        XCTAssertEqual(result.detections[4].disposition, .accepted, "10 hits == boundary")
    }

    func testApplyThresholdsBoundaryReject() {
        var result = BarcodeScoutResult(
            readsScanned: 100,
            detections: [
                BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 3, hitPercentage: 3.0),
            ],
            unassignedCount: 97,
            scoutedKitIDs: ["K"],
            elapsedSeconds: 0.5
        )

        result.applyThresholds(acceptMinHits: 10, rejectMaxHits: 3)
        XCTAssertEqual(result.detections[0].disposition, .rejected, "hitCount == rejectMax should reject")
    }

    func testApplyThresholdsOverlappingAcceptWins() {
        var result = BarcodeScoutResult(
            readsScanned: 100,
            detections: [
                BarcodeDetection(barcodeID: "BC01", kitID: "K", hitCount: 5, hitPercentage: 5.0),
            ],
            unassignedCount: 95,
            scoutedKitIDs: ["K"],
            elapsedSeconds: 0.5
        )

        result.applyThresholds(acceptMinHits: 5, rejectMaxHits: 5)
        XCTAssertEqual(result.detections[0].disposition, .accepted, "When thresholds overlap, accept wins")
    }

    // MARK: - JSON Persistence

    func testScoutResultFilePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutPersistenceTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let detection = BarcodeDetection(
            barcodeID: "BC01", kitID: "NBD114", hitCount: 500, hitPercentage: 50.0,
            matchedEnds: .bothEnds, meanEditDistance: 1.2, disposition: .accepted, sampleName: "Sample-A"
        )
        let result = BarcodeScoutResult(
            readsScanned: 1000, detections: [detection], unassignedCount: 500,
            scoutedKitIDs: ["NBD114"], elapsedSeconds: 4.5
        )

        let scoutURL = tempDir.appendingPathComponent(BarcodeScoutResult.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: scoutURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scoutURL.path))

        let loadedData = try Data(contentsOf: scoutURL)
        let loaded = try JSONDecoder().decode(BarcodeScoutResult.self, from: loadedData)

        XCTAssertEqual(loaded.readsScanned, 1000)
        XCTAssertEqual(loaded.detections.count, 1)
        XCTAssertEqual(loaded.detections.first?.sampleName, "Sample-A")
        XCTAssertEqual(loaded.detections.first?.disposition, .accepted)
        XCTAssertEqual(loaded.elapsedSeconds, 4.5, accuracy: 0.001)
    }

    func testCorruptJSONDecodeFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCorruptTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scoutURL = tempDir.appendingPathComponent(BarcodeScoutResult.filename)
        try "{ this is not valid json".write(to: scoutURL, atomically: true, encoding: .utf8)

        let data = try Data(contentsOf: scoutURL)
        let decoded = try? JSONDecoder().decode(BarcodeScoutResult.self, from: data)
        XCTAssertNil(decoded)
    }
}
