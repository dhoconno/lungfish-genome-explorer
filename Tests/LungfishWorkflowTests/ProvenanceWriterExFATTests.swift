// ProvenanceWriterExFATTests.swift - Record rewrites and their rollbacks on a real ExFAT volume
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// Rewrites a provenance record with an observer and rolls the rewrite back on
/// a real ExFAT volume.
///
/// Observer receipts compare a record's device, inode, link count, mode, size
/// and SHA-256 (`ProvenancePublicationArtifactMetadata`). A rewrite moves the
/// old record to another name and back, so the receipts agree only when the
/// volume keeps a file's inode across a rename. These tests learn that first,
/// before any writer changes. Run them with `scripts/testing/exfat-tests.sh`.
final class ProvenanceWriterExFATTests: XCTestCase {
    func testRewriteAndRollbackKeepTheIdentityReceiptsCompareOnExFAT() throws {
        let folder = try makeRunFolderOnExFAT()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let record = folder.run.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope.fixture(workflowName: "old-record"),
            toSidecar: record
        )
        let oldBytes = try Data(contentsOf: record)
        let oldIdentity = try identity(of: record)

        // A rename away and back keeps the inode the receipts compare.
        let aside = folder.run.appendingPathComponent(".identity-probe")
        XCTAssertEqual(Darwin.rename(record.path, aside.path), 0)
        XCTAssertEqual(try identity(of: aside), oldIdentity)
        XCTAssertEqual(Darwin.rename(aside.path, record.path), 0)
        XCTAssertEqual(try identity(of: record), oldIdentity)

        // The observer accepts the receipt only when the prior state the
        // writer reports equals the state its snapshot saw.
        let harness = try RollbackHarness(urls: [record])
        let writer = ProvenanceWriter(
            publicationMutationDidOccur: harness.accept,
            signingProvider: nil
        )
        try writer.write(
            ProvenanceEnvelope.fixture(workflowName: "new-record"),
            toSidecar: record
        )
        XCTAssertEqual(try workflowName(at: record), "new-record")

        // The rollback restores the old bytes and finds no foreign change.
        XCTAssertEqual(try harness.restore(), [])
        XCTAssertEqual(try Data(contentsOf: record), oldBytes)
        XCTAssertEqual(try names(in: folder.run), [record.lastPathComponent])
    }

    func testRejectedRewriteRestoresTheSameRecordOnExFAT() throws {
        let folder = try makeRunFolderOnExFAT()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let record = folder.run.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope.fixture(workflowName: "old-record"),
            toSidecar: record
        )
        let snapshot = try ProvenancePublicationSnapshot(urls: [record])
        defer { snapshot.discard() }
        let before = try snapshot.captureRollbackWitness()

        let writer = ProvenanceWriter(
            publicationMutationDidOccur: { _ in throw RejectedReceipt() },
            signingProvider: nil
        )
        XCTAssertThrowsError(try writer.write(
            ProvenanceEnvelope.fixture(workflowName: "new-record"),
            toSidecar: record
        )) { XCTAssertTrue($0 is RejectedReceipt, "\($0)") }

        // The very record the snapshot saw is back: same inode, size, mode and digest.
        XCTAssertEqual(try snapshot.changedArtifacts(comparedTo: before), [])
        XCTAssertEqual(try workflowName(at: record), "old-record")
        XCTAssertEqual(try names(in: folder.run), [record.lastPathComponent])
    }

    // MARK: - Helpers

    private struct RejectedReceipt: Error {}

    private struct RunFolder {
        let root: URL
        let run: URL
    }

    private func makeRunFolderOnExFAT() throws -> RunFolder {
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        var information = statfs()
        guard statfs(volume, &information) == 0 else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT does not name a mounted volume.")
        }
        let typeName = withUnsafeBytes(of: information.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard typeName == "exfat" else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT is \(typeName), not exfat.")
        }
        let root = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("provenance-writer-\(UUID().uuidString)", isDirectory: true)
        let run = root.appendingPathComponent("P.lungfish/Analyses/run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        return RunFolder(root: root, run: run)
    }

    private func identity(of url: URL) throws -> [UInt64] {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return [UInt64(information.st_dev), UInt64(information.st_ino)]
    }

    private func workflowName(at url: URL) throws -> String {
        try ProvenanceEnvelopeReader.decode(Data(contentsOf: url)).workflowName
    }

    /// Entry names, without the `._` AppleDouble files macOS adds on ExFAT.
    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }
}

/// Refreshes a rollback witness from each writer receipt, as the production
/// observers do, and restores the snapshot on request.
private final class RollbackHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private var witness: ProvenancePublicationRollbackWitness

    init(urls: [URL]) throws {
        snapshot = try ProvenancePublicationSnapshot(urls: urls)
        witness = try snapshot.captureRollbackWitness()
    }

    func accept(_ mutation: ProvenanceWriterMutation) throws {
        try lock.withLock {
            witness = try snapshot.refreshingRollbackWitness(witness, after: mutation)
        }
    }

    func restore() throws -> [URL] {
        defer { snapshot.discard() }
        return try snapshot.restore(ifCurrentMatches: lock.withLock { witness })
    }
}
