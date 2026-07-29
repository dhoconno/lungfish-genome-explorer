import Darwin
import Foundation
import LungfishIO
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

    func testSecondPublicationFailureCannotLeaveSuccessfulTerminalReceipt() throws {
        let bundle = try makeBundle()
        defer {
            try? FileManager.default.removeItem(
                at: bundle.deletingLastPathComponent()
            )
        }
        let publications = SendableIntegerCounter()
        let store = DurableAtomicFileStore(
            operations: .init(
                renameExclusive: {
                    sourceDirectory,
                    source,
                    destinationDirectory,
                    destination,
                    flags in
                    let destinationName = String(cString: destination)
                    if destinationName == "provenance.json",
                       publications.incrementAndGet() == 1 {
                        errno = EIO
                        return -1
                    }
                    return Darwin.renameatx_np(
                        sourceDirectory,
                        source,
                        destinationDirectory,
                        destination,
                        flags
                    )
                }
            )
        )
        let handle = try GenotypeWorkbookUpdateAttemptRecorder(
            atomicFileStore: store
        ).begin(
            bundleURL: bundle,
            argv: ["lungfish-cli"]
        )

        XCTAssertThrowsError(try handle.finalize(exitStatus: 0))
        XCTAssertTrue(handle.isFinalized)
        XCTAssertEqual(handle.testingTerminalOwnershipCount, 1)
        let receipt = try ProvenanceJSON.decoder.decode(
            GenotypeWorkbookUpdateAttemptReceipt.self,
            from: Data(
                contentsOf: handle.directoryURL
                    .appendingPathComponent("receipt.json")
            )
        )
        XCTAssertEqual(receipt.exitStatus, 1)
        XCTAssertTrue(
            receipt.stderr?.contains(
                "terminal provenance publication failed"
            ) == true
        )
    }

    func testReplacingAttemptDirectoryCannotRedirectTerminalPublication() throws {
        let bundle = try makeBundle()
        defer {
            try? FileManager.default.removeItem(
                at: bundle.deletingLastPathComponent()
            )
        }
        let handle = try GenotypeWorkbookUpdateAttemptRecorder().begin(
            bundleURL: bundle,
            argv: ["lungfish-cli"]
        )
        let detached = handle.directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("detached-\(handle.attemptID)")
        try FileManager.default.moveItem(
            at: handle.directoryURL,
            to: detached
        )
        try FileManager.default.createDirectory(
            at: handle.directoryURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try handle.finalize(exitStatus: 0))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: handle.directoryURL
                    .appendingPathComponent("receipt.json").path
            )
        )
        XCTAssertFalse(handle.isFinalized)
        XCTAssertTrue(handle.hasPublicationFailure)
    }

    func testFinalizeRebindsAttestedAttemptInCurrentBundleGeneration() throws {
        let bundle = try makeBundle()
        let root = bundle.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try GenotypeWorkbookUpdateAttemptRecorder().begin(
            bundleURL: bundle,
            argv: ["lungfish-cli"]
        )
        let retired = root.appendingPathComponent(
            "retired.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: bundle, to: retired)
        try FileManager.default.copyItem(at: retired, to: bundle)

        try handle.finalize(exitStatus: 0)

        let relativeAttempt = "artifacts/workbooks/updates/attempts/"
            + handle.attemptID
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent(relativeAttempt)
                    .appendingPathComponent("receipt.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent(relativeAttempt)
                    .appendingPathComponent("receipt.json").path
            )
        )
    }

    func testRollbackDoesNotDeleteSubstitutedReceipt() throws {
        let bundle = try makeBundle()
        defer {
            try? FileManager.default.removeItem(
                at: bundle.deletingLastPathComponent()
            )
        }
        let receiptURLBox = SendableURLBox()
        let substituted = Data("substituted receipt".utf8)
        let store = DurableAtomicFileStore(
            operations: .init(
                renameExclusive: {
                    sourceDirectory,
                    source,
                    destinationDirectory,
                    destination,
                    flags in
                    let destinationName = String(cString: destination)
                    if destinationName == "provenance.json",
                       let receiptURL = receiptURLBox.value {
                        try? FileManager.default.removeItem(at: receiptURL)
                        try? substituted.write(to: receiptURL)
                        errno = EIO
                        return -1
                    }
                    return Darwin.renameatx_np(
                        sourceDirectory,
                        source,
                        destinationDirectory,
                        destination,
                        flags
                    )
                }
            )
        )
        let handle = try GenotypeWorkbookUpdateAttemptRecorder(
            atomicFileStore: store
        ).begin(
            bundleURL: bundle,
            argv: ["lungfish-cli"]
        )
        let receiptURL = handle.directoryURL.appendingPathComponent(
            "receipt.json"
        )
        receiptURLBox.value = receiptURL

        XCTAssertThrowsError(try handle.finalize(exitStatus: 0))
        XCTAssertEqual(try Data(contentsOf: receiptURL), substituted)
        XCTAssertFalse(handle.isFinalized)
        XCTAssertTrue(handle.hasPublicationFailure)
    }

    func testConcurrentFinalizeCallsPublishOneTerminalOutcome() throws {
        let bundle = try makeBundle()
        defer {
            try? FileManager.default.removeItem(
                at: bundle.deletingLastPathComponent()
            )
        }
        let handle = try GenotypeWorkbookUpdateAttemptRecorder().begin(
            bundleURL: bundle,
            argv: ["lungfish-cli"]
        )
        let results = SendableErrorCollector()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try handle.finalize(exitStatus: index)
                results.append(nil)
            } catch {
                results.append(error)
            }
        }

        XCTAssertEqual(results.values.count, 2)
        XCTAssertEqual(results.values.compactMap { $0 }.count, 1)
        XCTAssertTrue(handle.isFinalized)
        XCTAssertEqual(handle.testingTerminalOwnershipCount, 1)
        XCTAssertNoThrow(
            try ProvenanceJSON.decoder.decode(
                GenotypeWorkbookUpdateAttemptReceipt.self,
                from: Data(
                    contentsOf: handle.directoryURL
                        .appendingPathComponent("receipt.json")
                )
            )
        )
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

private final class SendableIntegerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGet() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class SendableURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: URL?

    var value: URL? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class SendableErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error?] = []

    var values: [Error?] {
        lock.withLock { storage }
    }

    func append(_ error: Error?) {
        lock.withLock { storage.append(error) }
    }
}
