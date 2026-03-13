import XCTest
@testable import LungfishIO

final class FASTQBatchManifestTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - FASTQBatchManifest Round-Trip

    func testEmptyManifestRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = FASTQBatchManifest()
        try manifest.save(to: dir)

        let loaded = FASTQBatchManifest.load(from: dir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.operations.count, 0)
    }

    func testManifestWithOperationsRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = BatchOperationRecord(
            label: "Filter by Length (500-5000 bp)",
            operationKind: "lengthFilter",
            parameters: ["minLength": "500", "maxLength": "5000"],
            outputBundlePaths: [
                "barcode01.lungfishfastq/barcode01-len-500-5000.lungfishfastq",
                "barcode02.lungfishfastq/barcode02-len-500-5000.lungfishfastq"
            ],
            inputBundlePaths: [
                "barcode01.lungfishfastq",
                "barcode02.lungfishfastq"
            ],
            failureCount: 0,
            wallClockSeconds: 12.5
        )

        let manifest = FASTQBatchManifest(operations: [record])
        try manifest.save(to: dir)

        let loaded = FASTQBatchManifest.load(from: dir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.operations.count, 1)

        let loadedRecord = loaded!.operations[0]
        XCTAssertEqual(loadedRecord.label, "Filter by Length (500-5000 bp)")
        XCTAssertEqual(loadedRecord.operationKind, "lengthFilter")
        XCTAssertEqual(loadedRecord.parameters["minLength"], "500")
        XCTAssertEqual(loadedRecord.parameters["maxLength"], "5000")
        XCTAssertEqual(loadedRecord.outputBundlePaths.count, 2)
        XCTAssertEqual(loadedRecord.inputBundlePaths.count, 2)
        XCTAssertEqual(loadedRecord.successCount, 2)
        XCTAssertEqual(loadedRecord.failureCount, 0)
        XCTAssertEqual(loadedRecord.wallClockSeconds, 12.5, accuracy: 0.01)
    }

    func testLoadMissingManifest() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(FASTQBatchManifest.load(from: bogus))
    }

    // MARK: - Append Operation

    func testAppendOperationCreatesNewFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = BatchOperationRecord(
            label: "Subsample 10%",
            operationKind: "subsampleProportion",
            parameters: ["proportion": "0.10"],
            outputBundlePaths: ["bc01-subsample.lungfishfastq"],
            inputBundlePaths: ["bc01.lungfishfastq"]
        )

        try FASTQBatchManifest.appendOperation(record, to: dir)

        let loaded = FASTQBatchManifest.load(from: dir)
        XCTAssertEqual(loaded?.operations.count, 1)
        XCTAssertEqual(loaded?.operations[0].label, "Subsample 10%")
    }

    func testAppendOperationAddsToExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record1 = BatchOperationRecord(
            label: "First Op",
            operationKind: "lengthFilter",
            outputBundlePaths: ["out1.lungfishfastq"],
            inputBundlePaths: ["in1.lungfishfastq"]
        )
        let record2 = BatchOperationRecord(
            label: "Second Op",
            operationKind: "qualityTrim",
            outputBundlePaths: ["out2.lungfishfastq"],
            inputBundlePaths: ["in2.lungfishfastq"]
        )

        try FASTQBatchManifest.appendOperation(record1, to: dir)
        try FASTQBatchManifest.appendOperation(record2, to: dir)

        let loaded = FASTQBatchManifest.load(from: dir)
        XCTAssertEqual(loaded?.operations.count, 2)
        XCTAssertEqual(loaded?.operations[0].label, "First Op")
        XCTAssertEqual(loaded?.operations[1].label, "Second Op")
    }

    // MARK: - BatchOperationRecord

    func testBatchOperationRecordIdentifiable() {
        let record = BatchOperationRecord(
            label: "Test",
            operationKind: "test",
            outputBundlePaths: [],
            inputBundlePaths: []
        )
        // UUID should be unique
        let record2 = BatchOperationRecord(
            label: "Test",
            operationKind: "test",
            outputBundlePaths: [],
            inputBundlePaths: []
        )
        XCTAssertNotEqual(record.id, record2.id)
    }

    func testBatchOperationRecordSuccessCount() {
        let record = BatchOperationRecord(
            label: "Test",
            operationKind: "lengthFilter",
            outputBundlePaths: ["a.lungfishfastq", "b.lungfishfastq", "c.lungfishfastq"],
            inputBundlePaths: ["x.lungfishfastq", "y.lungfishfastq", "z.lungfishfastq"],
            failureCount: 1
        )
        XCTAssertEqual(record.successCount, 3)
        XCTAssertEqual(record.failureCount, 1)
    }

    func testBatchOperationRecordDateEncoding() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let date = Date()
        let record = BatchOperationRecord(
            label: "Date Test",
            operationKind: "test",
            performedAt: date,
            outputBundlePaths: [],
            inputBundlePaths: []
        )

        let manifest = FASTQBatchManifest(operations: [record])
        try manifest.save(to: dir)

        let loaded = FASTQBatchManifest.load(from: dir)
        XCTAssertNotNil(loaded)
        // ISO 8601 loses sub-second precision, so check within 1 second
        XCTAssertEqual(
            loaded!.operations[0].performedAt.timeIntervalSince1970,
            date.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - Equatable

    func testManifestEquatable() {
        let id = UUID()
        let date = Date()
        let record1 = BatchOperationRecord(
            id: id, label: "Test", operationKind: "test",
            performedAt: date,
            outputBundlePaths: ["a"], inputBundlePaths: ["b"]
        )
        let record2 = BatchOperationRecord(
            id: id, label: "Test", operationKind: "test",
            performedAt: date,
            outputBundlePaths: ["a"], inputBundlePaths: ["b"]
        )
        XCTAssertEqual(record1, record2)

        let manifest1 = FASTQBatchManifest(operations: [record1])
        let manifest2 = FASTQBatchManifest(operations: [record2])
        XCTAssertEqual(manifest1, manifest2)
    }

    // MARK: - Filename

    func testManifestFilename() {
        XCTAssertEqual(FASTQBatchManifest.filename, "batch-operations.json")
    }
}
