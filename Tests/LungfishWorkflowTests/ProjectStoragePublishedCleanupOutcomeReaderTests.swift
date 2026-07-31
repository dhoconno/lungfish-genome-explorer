import CryptoKit
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ProjectStoragePublishedCleanupOutcomeReaderTests: XCTestCase {
    private var root: URL!
    private var operationDirectory: URL!
    private var operationIdentity: FileSystemObjectIdentity!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProjectStoragePublishedOutcomeReaderTests-"
                + UUID().uuidString,
            isDirectory: true
        )
        operationDirectory = root.appendingPathComponent(
            "operation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: operationDirectory,
            withIntermediateDirectories: true
        )
        operationIdentity = try FileSystemObjectIdentity.noFollow(
            operationDirectory
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsValidMultiItemPublishedOutcome() throws {
        let cleanupID = UUID()
        try writeReceiptPair(
            in: operationDirectory,
            cleanupID: cleanupID,
            itemCount: 128
        )

        let result = try ProjectStoragePublishedCleanupOutcomeReader()
            .readLatest(
                operationDirectoryURL: operationDirectory,
                expectedOperationDirectoryIdentity: operationIdentity,
                cleanupID: cleanupID
            )

        XCTAssertEqual(result.summary.cleanupID, cleanupID)
        XCTAssertEqual(result.summary.items.count, 128)
        XCTAssertEqual(
            result.summaryURL.lastPathComponent,
            "execution-summary-00000001.json"
        )
        XCTAssertEqual(
            result.provenanceURL.lastPathComponent,
            "execution-provenance-00000001.json"
        )
    }

    func testRejectsDuplicateSummaryItemIdentifiers() throws {
        let cleanupID = UUID()
        try writeReceiptPair(
            in: operationDirectory,
            cleanupID: cleanupID,
            duplicateItemIDs: true
        )

        XCTAssertThrowsError(
            try ProjectStoragePublishedCleanupOutcomeReader()
                .readLatest(
                    operationDirectoryURL: operationDirectory,
                    expectedOperationDirectoryIdentity: operationIdentity,
                    cleanupID: cleanupID
                )
        )
    }

    func testIgnoresNonCanonicalSequenceWidthDecoyPair() throws {
        let cleanupID = UUID()
        try writeReceiptPair(
            in: operationDirectory,
            cleanupID: cleanupID,
            sequence: "00000010"
        )
        try writeReceiptPair(
            in: operationDirectory,
            cleanupID: cleanupID,
            sequence: "9"
        )

        let result = try ProjectStoragePublishedCleanupOutcomeReader()
            .readLatest(
                operationDirectoryURL: operationDirectory,
                expectedOperationDirectoryIdentity: operationIdentity,
                cleanupID: cleanupID
            )

        XCTAssertEqual(
            result.summaryURL.lastPathComponent,
            "execution-summary-00000010.json"
        )
    }

    func testRejectsOperationDirectoryPathReplacementAfterOpen() throws {
        let cleanupID = UUID()
        let originalOperationDirectory = try XCTUnwrap(operationDirectory)
        try writeReceiptPair(
            in: originalOperationDirectory,
            cleanupID: cleanupID
        )
        let displaced = root.appendingPathComponent(
            "displaced-operation",
            isDirectory: true
        )
        let replacement = root.appendingPathComponent(
            "replacement-operation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacement,
            withIntermediateDirectories: false
        )
        try writeReceiptPair(in: replacement, cleanupID: cleanupID)
        let replaced = LockedFlag()
        let reader = ProjectStoragePublishedCleanupOutcomeReader(
            operations: .init(
                afterOpenOperationDirectory: {
                    try FileManager.default.moveItem(
                        at: originalOperationDirectory,
                        to: displaced
                    )
                    try FileManager.default.moveItem(
                        at: replacement,
                        to: originalOperationDirectory
                    )
                    _ = replaced.setIfFalse()
                }
            )
        )

        XCTAssertThrowsError(
            try reader.readLatest(
                operationDirectoryURL: originalOperationDirectory,
                expectedOperationDirectoryIdentity: operationIdentity,
                cleanupID: cleanupID
            )
        )
        XCTAssertTrue(replaced.value)
    }

    func testRejectsSummaryDirectoryEntryReplacementDuringRead()
        throws
    {
        let cleanupID = UUID()
        let pair = try writeReceiptPair(
            in: operationDirectory,
            cleanupID: cleanupID
        )
        let displaced = operationDirectory.appendingPathComponent(
            "displaced-summary.json"
        )
        let replacement = operationDirectory.appendingPathComponent(
            "replacement-summary.json"
        )
        try pair.summaryData.write(to: replacement)
        let replaced = LockedFlag()
        let reader = ProjectStoragePublishedCleanupOutcomeReader(
            operations: .init(
                afterFirstReadChunk: { role in
                    guard role == .summary,
                          replaced.setIfFalse() else {
                        return
                    }
                    try FileManager.default.moveItem(
                        at: pair.summaryURL,
                        to: displaced
                    )
                    try FileManager.default.moveItem(
                        at: replacement,
                        to: pair.summaryURL
                    )
                }
            )
        )

        XCTAssertThrowsError(
            try reader.readLatest(
                operationDirectoryURL: operationDirectory,
                expectedOperationDirectoryIdentity: operationIdentity,
                cleanupID: cleanupID
            )
        )
        XCTAssertTrue(replaced.value)
    }

    func testRejectsProvenanceDirectoryEntryReplacementDuringRead()
        throws
    {
        let cleanupID = UUID()
        let pair = try writeReceiptPair(
            in: operationDirectory,
            cleanupID: cleanupID
        )
        let displaced = operationDirectory.appendingPathComponent(
            "displaced-provenance.json"
        )
        let replacement = operationDirectory.appendingPathComponent(
            "replacement-provenance.json"
        )
        let provenanceData = try Data(contentsOf: pair.provenanceURL)
        try provenanceData.write(to: replacement)
        let replaced = LockedFlag()
        let reader = ProjectStoragePublishedCleanupOutcomeReader(
            operations: .init(
                afterFirstReadChunk: { role in
                    guard role == .provenance,
                          replaced.setIfFalse() else {
                        return
                    }
                    try FileManager.default.moveItem(
                        at: pair.provenanceURL,
                        to: displaced
                    )
                    try FileManager.default.moveItem(
                        at: replacement,
                        to: pair.provenanceURL
                    )
                }
            )
        )

        XCTAssertThrowsError(
            try reader.readLatest(
                operationDirectoryURL: operationDirectory,
                expectedOperationDirectoryIdentity: operationIdentity,
                cleanupID: cleanupID
            )
        )
        XCTAssertTrue(replaced.value)
    }

    @discardableResult
    private func writeReceiptPair(
        in directory: URL,
        cleanupID: UUID,
        itemCount: Int = 3,
        duplicateItemIDs: Bool = false,
        sequence: String = "00000001"
    ) throws -> (
        summaryURL: URL,
        provenanceURL: URL,
        summaryData: Data
    ) {
        let summaryURL = directory.appendingPathComponent(
            "execution-summary-\(sequence).json"
        )
        let provenanceURL = directory.appendingPathComponent(
            "execution-provenance-\(sequence).json"
        )
        let repeatedItemID = UUID()
        let items = (0..<itemCount).map { index in
            ProjectStorageCleanupExecutionSummary.Item(
                itemID: duplicateItemIDs ? repeatedItemID : UUID(),
                sourceRelativePath: ".tmp/item-\(index)",
                state: .failed,
                quarantineRelativePath: nil,
                trashDestinationPath: nil,
                reason: "Cancelled."
            )
        }
        let summary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: root.path,
            projectIdentity: .init(device: 41, inode: 73),
            state: .failed,
            items: items,
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        let summaryData = try ProvenanceJSON.encoder.encode(summary)
        try summaryData.write(to: summaryURL)
        let checksum = SHA256.hash(data: summaryData)
            .map { String(format: "%02x", $0) }
            .joined()
        let provenance = ProvenanceEnvelope(
            id: cleanupID,
            workflowName: "Project Storage Cleanup Execution",
            toolName: "lungfish-project-storage",
            outputs: [
                .init(
                    path: summaryURL.path,
                    checksumSHA256: checksum,
                    fileSize: UInt64(summaryData.count),
                    format: .json,
                    role: .output
                ),
            ]
        )
        try ProvenanceJSON.encoder.encode(provenance).write(
            to: provenanceURL
        )
        return (summaryURL, provenanceURL, summaryData)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func setIfFalse() -> Bool {
        lock.withLock {
            guard !storedValue else { return false }
            storedValue = true
            return true
        }
    }
}
