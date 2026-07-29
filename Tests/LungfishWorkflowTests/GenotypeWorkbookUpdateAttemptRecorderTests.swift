import Foundation
import XCTest
@testable import LungfishWorkflow

final class GenotypeWorkbookUpdateAttemptRecorderTests: XCTestCase {
    func testFinalizedAttemptWritesSortedReceiptAndCanonicalProvenance() throws {
        let root = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 104.25)
        let recorder = GenotypeWorkbookUpdateAttemptRecorder(
            dateProvider: { startedAt },
            uuidProvider: { UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")! }
        )
        let argv = [
            "lungfish-cli", "fastq", "update-current-workbook",
            root.path, "--calls-json", "/tmp/calls with quote'.json",
        ]
        let handle = try recorder.begin(
            bundleURL: root,
            argv: argv,
            attemptedInputPaths: ["/tmp/calls with quote'.json"]
        )
        try handle.recordResolvedOptions([
            "projectionMode": "manual-genotype-only",
            "annotationOnly": "false",
        ])
        try handle.recordRuntimeIdentity([
            "pythonExecutable": "/tmp/openpyxl/bin/python",
            "openpyxlVersion": "3.1.5",
        ])
        try handle.finalize(
            exitStatus: 1,
            stderr: "primary transform failure",
            cleanupPendingWarning: nil,
            completedAt: completedAt
        )

        let directory = root.appendingPathComponent(
            "artifacts/workbooks/updates/attempts/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            isDirectory: true
        )
        let receiptData = try Data(contentsOf: directory.appendingPathComponent("receipt.json"))
        let receipt = try ProvenanceJSON.decoder.decode(
            GenotypeWorkbookUpdateAttemptReceipt.self,
            from: receiptData
        )
        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.argv, argv)
        XCTAssertEqual(
            receipt.reproducibleCommand,
            "'lungfish-cli' 'fastq' 'update-current-workbook' '\(root.path)' '--calls-json' '/tmp/calls with quote'\"'\"'.json'"
        )
        XCTAssertEqual(receipt.resolvedOptions["annotationOnly"], "false")
        XCTAssertEqual(receipt.runtimeIdentity["openpyxlVersion"], "3.1.5")
        XCTAssertEqual(receipt.attemptedInputPaths, ["/tmp/calls with quote'.json"])
        XCTAssertEqual(receipt.exitStatus, 1)
        XCTAssertEqual(receipt.stderr, "primary transform failure")
        XCTAssertEqual(receipt.wallTimeSeconds, 4.25, accuracy: 0.001)
        XCTAssertTrue(String(decoding: receiptData, as: UTF8.self).contains("\n  \"argv\""))

        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: directory.appendingPathComponent("provenance.json"))
        )
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.exitStatus, 1)
        XCTAssertEqual(envelope.stderr, "primary transform failure")
        XCTAssertEqual(
            try XCTUnwrap(envelope.wallTimeSeconds),
            4.25,
            accuracy: 0.001
        )
        XCTAssertEqual(envelope.toolName, "lungfish-cli fastq update-current-workbook")
        XCTAssertEqual(envelope.runtimeIdentity.condaEnvironment, "openpyxl")
    }

    func testEveryBeginCreatesAnIndependentExclusiveAttemptDirectory() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let identifiers = SendableUUIDQueue([
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        ])
        let recorder = GenotypeWorkbookUpdateAttemptRecorder(
            uuidProvider: {
                identifiers.removeFirst()
            }
        )

        let first = try recorder.begin(bundleURL: bundle, argv: ["one"])
        let second = try recorder.begin(bundleURL: bundle, argv: ["two"])
        XCTAssertNotEqual(first.attemptID, second.attemptID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directoryURL.path))
        try first.finalize(exitStatus: 0)
        try second.finalize(exitStatus: 0)
    }

    func testAttemptMayFinalizeExactlyOnce() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let handle = try GenotypeWorkbookUpdateAttemptRecorder().begin(
            bundleURL: bundle,
            argv: ["lungfish-cli"]
        )

        try handle.finalize(exitStatus: 0)
        XCTAssertThrowsError(try handle.finalize(exitStatus: 1)) { error in
            XCTAssertEqual(
                error as? GenotypeWorkbookUpdateAttemptRecorderError,
                .attemptAlreadyFinalized(handle.attemptID)
            )
        }
    }

    private func makeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkbookAttemptRecorderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundle = root.appendingPathComponent(
            "analysis.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        return bundle
    }
}

private final class SendableUUIDQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [UUID]

    init(_ identifiers: [UUID]) {
        self.identifiers = identifiers
    }

    func removeFirst() -> UUID {
        lock.withLock { identifiers.removeFirst() }
    }
}
