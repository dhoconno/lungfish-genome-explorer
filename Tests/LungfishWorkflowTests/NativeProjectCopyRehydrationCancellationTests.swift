// NativeProjectCopyRehydrationCancellationTests.swift - The native copy takes a cancel while a file item's own record is rehydrated
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.36 (row COPY-CANCEL-CHECKS), fix round after the SWIFT review. A file item that carries its own
// provenance record gets more passes over its file once the copy is published. The rehydrator checks the source file
// against the record and hashes the copy again for the rewritten record, so the copy's check must run in those passes
// too, or a cancel waits for them. The test throws at the first check that runs once the file is published, so a
// rehydrator that takes no check lets the copy finish and the test fails. A sparse file of eight hash chunks stands
// for the large file, so the test writes almost nothing to disk.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class NativeProjectCopyRehydrationCancellationTests: XCTestCase {
    /// How many chunks of `FileDigest` the sparse file holds.
    private static let chunks = 8
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "native-copy-rehydration-cancel")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testACheckThatThrowsOnceTheFileIsPublishedStopsTheRehydrationAndRollsTheCopyBack() throws {
        let file = try makeFile()
        let destination = root.appendingPathComponent("Target.lungfish/Documents/Big.bin")
        var existedAtTheFirstCheck: Bool?
        var callsOnceCopied = 0

        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: file, to: destination, checkCancellation: {
            if existedAtTheFirstCheck == nil { existedAtTheFirstCheck = FileManager.default.fileExists(atPath: destination.path) }
            guard FileManager.default.fileExists(atPath: destination.path) else { return }
            callsOnceCopied += 1
            throw CancellationError()
        })) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)")
        }

        XCTAssertEqual(existedAtTheFirstCheck, false, "nothing sits at the destination before the copy is published")
        XCTAssertEqual(callsOnceCopied, 1, "the rehydration checks the cancel between the chunks of its first hash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the published copy is rolled back")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: destination).path),
            "no record is left beside the destination"
        )
        XCTAssertEqual(residue(beside: destination), [], "no .native-copy- folder is left")
    }

    // MARK: - Fixture

    /// A file item of `chunks` hash chunks whose record sits beside it as a sidecar.
    private func makeFile() throws -> URL {
        let folder = root.appendingPathComponent("Source.lungfish/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sparse = folder.appendingPathComponent("Big.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(Self.chunks * FileDigest.defaultChunkSize))
        try handle.close()
        try ProvenanceWriter(signingProvider: nil).write(
            try record(naming: sparse), toSidecar: ProvenanceRecorder.fileSidecarURL(for: sparse)
        )
        return sparse
    }

    /// The record of a source run that made `output`, built as the CLI builds one.
    private func record(naming output: URL) throws -> ProvenanceEnvelope {
        try ProvenanceRunBuilder(
            workflowName: "source item", workflowVersion: "1.0", toolName: "source-tool", toolVersion: "1.0"
        )
        .argv(["source-tool", output.path])
        .output(output, format: .unknown, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
    }

    /// The `.native-copy-` folders beside `destination`.
    private func residue(beside destination: URL) -> [String] {
        let folder = destination.deletingLastPathComponent().path
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(".native-copy-") }
    }
}
