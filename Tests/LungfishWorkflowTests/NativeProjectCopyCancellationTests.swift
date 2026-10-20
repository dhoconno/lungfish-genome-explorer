// NativeProjectCopyCancellationTests.swift - The native copy step takes a cancel while it hashes and before it copies
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.36 (row COPY-CANCEL-CHECKS). `NativeProjectCopyImportService.copy` hashes each source file,
// copies the item into a `.native-copy-` folder beside its destination and hashes each copied file. A cross-project
// copy runs it inside the stage after SIGTERM, so each hash takes the caller's check between chunks and the copy
// takes one check before it starts. A check that throws stops the copy, leaves no `.native-copy-` folder and
// publishes nothing. The item holds a sparse file of eight hash chunks, so the tests write almost nothing to disk.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class NativeProjectCopyCancellationTests: XCTestCase {
    /// How many chunks of `FileDigest` the sparse file holds.
    private static let chunks = 8
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "native-copy-cancel")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testACheckThatThrowsAtItsFirstCallLeavesNoResidueAndNoDestination() throws {
        let item = try makeItem()
        let destination = destinationURL()
        var calls = 0

        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: item, to: destination, checkCancellation: {
            calls += 1
            throw CancellationError()
        })) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)")
        }

        XCTAssertEqual(calls, 1, "the first check stops the copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing is published")
        XCTAssertEqual(residue(beside: destination), [], "no .native-copy- folder is left")
    }

    func testACheckThatThrowsWhileTheCopyIsHashedLeavesNoResidueAndNoDestination() throws {
        let item = try makeItem()
        let destination = destinationURL()
        var callsAfterTheCopy = 0

        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: item, to: destination, checkCancellation: {
            guard !self.residue(beside: destination).isEmpty else { return }
            callsAfterTheCopy += 1
            throw CancellationError()
        })) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)")
        }

        XCTAssertEqual(callsAfterTheCopy, 1, "a check runs once the copy exists, while it is hashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing is published")
        XCTAssertEqual(residue(beside: destination), [], "no .native-copy- folder is left")
    }

    func testACheckThatThrowsJustBeforeTheCopyStopsItBeforeAnyCopyExists() throws {
        let item = try makeItem()
        let destination = destinationURL()
        // Count the source hash's own calls on the same file, so the next call is the check before `copyItem`.
        var hashCalls = 0
        _ = try ProvenanceFileHasher.sha256(of: item.appendingPathComponent("padding.bin"), cancellationCheck: { hashCalls += 1 })
        var calls = 0
        var residueWhenStopped: [String]?

        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: item, to: destination, checkCancellation: {
            calls += 1
            guard calls == hashCalls + 1 else { return }
            residueWhenStopped = self.residue(beside: destination)
            throw CancellationError()
        })) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)")
        }

        XCTAssertEqual(calls, hashCalls + 1, "the call after the source's hash stops the copy")
        XCTAssertEqual(residueWhenStopped, [], "the check before the copy ran before any copy existed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing is published")
        XCTAssertEqual(residue(beside: destination), [], "no .native-copy- folder is left")
    }

    func testTheCheckRunsBetweenTheChunksOfBothHashes() throws {
        let item = try makeItem()
        let destination = destinationURL()
        var callsBeforeTheCopy = 0
        var callsAfterTheCopy = 0

        let published = try NativeProjectCopyImportService.copy(from: item, to: destination, checkCancellation: {
            if self.residue(beside: destination).isEmpty {
                callsBeforeTheCopy += 1
            } else {
                callsAfterTheCopy += 1
            }
        })

        XCTAssertTrue(FileManager.default.fileExists(atPath: published.appendingPathComponent("padding.bin").path))
        XCTAssertGreaterThanOrEqual(
            callsBeforeTheCopy, Self.chunks + 2,
            "one check before each of the eight reads, one before the empty read at the end of the file, and one before the copy"
        )
        XCTAssertGreaterThanOrEqual(callsAfterTheCopy, Self.chunks, "one check before each chunk of the copy's hash")
        XCTAssertEqual(residue(beside: destination), [], "the copy leaves no .native-copy- folder")
    }

    // MARK: - Fixture

    /// A reference bundle in a source project that holds one sparse file of `chunks` hash chunks.
    private func makeItem() throws -> URL {
        let item = root.appendingPathComponent("Source.lungfish/Reference Sequences/Big.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        let sparse = item.appendingPathComponent("padding.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(Self.chunks * FileDigest.defaultChunkSize))
        try handle.close()
        return item
    }

    private func destinationURL() -> URL {
        root.appendingPathComponent("Target.lungfish/Reference Sequences/Big.lungfishref", isDirectory: true)
    }

    /// The `.native-copy-` folders beside `destination`.
    private func residue(beside destination: URL) -> [String] {
        let folder = destination.deletingLastPathComponent().path
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(".native-copy-") }
    }
}
