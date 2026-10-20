// FASTQBundleCopyImportCancellationTests.swift - The read bundle copy takes a cancel before it copies and while it hashes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.36 (row COPY-CANCEL-CHECKS). A cross-project copy of a read bundle runs
// `FASTQBundleCopyImportWorkflow.importBundle` inside its stage, so the import takes the copier's check once before
// it copies and between the chunks of each hash. A check that throws publishes nothing and leaves no staging bundle.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQBundleCopyImportCancellationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-copy-cancel")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testACheckThatThrowsBeforeTheCopyPublishesNothing() throws {
        try assertCancelled(atCall: 1)
    }

    func testACheckThatThrowsWhileTheCopyIsHashedLeavesNoStagingBundle() throws {
        // Call 1 comes before the copy. Call 2 is the first chunk of the first hash the import makes, which is the
        // rehydrator's hash of the file the source record names, so the staging bundle exists.
        try assertCancelled(atCall: 2)
    }

    func testTheRehydratorOfTheSourceRecordTakesTheCheckToo() throws {
        // A clean run makes one check before the copy, then the calls of the hash of the source file and of the hash
        // of the copy, which `FileDigest` makes for this file. Any call beyond those is the rehydrator hashing the
        // file that the source record names, so a rehydrator that takes no check leaves the total at its floor.
        let source = try makeBundle()
        var hashCalls = 0
        _ = try FileDigest.sha256(of: source.appendingPathComponent("reads.fastq"), cancellationCheck: { hashCalls += 1 })
        var total = 0

        _ = try FASTQBundleCopyImportWorkflow().importBundle(
            sourceBundleURL: source,
            outputURL: root.appendingPathComponent("Target", isDirectory: true),
            context: .init(workflowName: "copy", toolName: "lungfish-cli", argv: ["lungfish-cli", "copy"]),
            checkCancellation: { total += 1 }
        )

        XCTAssertGreaterThan(total, 1 + 2 * hashCalls, "the rehydrator checks the cancel between the chunks of its hash")
    }

    func testTheHashOfTheCopiedFilesTakesTheCheckBetweenItsChunks() throws {
        // The bundle holds a sparse file that its record does not name, so the rehydrator never hashes it. The import
        // hashes it twice, as a source file and as a copied file, with a check before each read. Four more chunks
        // therefore add four checks to each of the two hashes, and a hash of the copy that takes no check adds only four.
        let small = try countChecks(ofAnImportWithASparseFileOf: 2, in: "Small")
        let large = try countChecks(ofAnImportWithASparseFileOf: 6, in: "Large")
        XCTAssertEqual(large - small, 2 * (6 - 2), "each of the two hashes of the sparse file checks between its chunks")
    }

    /// The checks that a clean import makes when the bundle also holds a sparse file of `chunks` hash chunks.
    private func countChecks(ofAnImportWithASparseFileOf chunks: Int, in folder: String) throws -> Int {
        let source = try makeBundle(in: folder)
        let sparse = source.appendingPathComponent("extra.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(chunks * FileDigest.defaultChunkSize))
        try handle.close()
        var total = 0

        _ = try FASTQBundleCopyImportWorkflow().importBundle(
            sourceBundleURL: source,
            outputURL: root.appendingPathComponent("\(folder)Target", isDirectory: true),
            context: .init(workflowName: "copy", toolName: "lungfish-cli", argv: ["lungfish-cli", "copy"]),
            checkCancellation: { total += 1 }
        )
        return total
    }

    private func assertCancelled(atCall stop: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try makeBundle()
        let output = root.appendingPathComponent("Target", isDirectory: true)
        var calls = 0
        var stagedWhenStopped: [String] = []

        XCTAssertThrowsError(
            try FASTQBundleCopyImportWorkflow().importBundle(
                sourceBundleURL: source,
                outputURL: output,
                context: .init(workflowName: "copy", toolName: "lungfish-cli", argv: ["lungfish-cli", "copy"]),
                checkCancellation: {
                    calls += 1
                    guard calls == stop else { return }
                    stagedWhenStopped = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
                    throw CancellationError()
                }
            ),
            file: file, line: line
        ) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)", file: file, line: line)
        }

        XCTAssertEqual(calls, stop, "the check that throws stops the import", file: file, line: line)
        XCTAssertEqual(stagedWhenStopped.isEmpty, stop == 1, "the copy exists only after the first check", file: file, line: line)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertEqual(left, [], "nothing is published and no staging bundle is left", file: file, line: line)
    }

    /// A read bundle with one FASTQ file and the provenance a copy requires.
    private func makeBundle(in folder: String = "Source") throws -> URL {
        let bundle = root.appendingPathComponent("\(folder)/Reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        let envelope = try ProvenanceRunBuilder(
            workflowName: "source FASTQ bundle", workflowVersion: "1.0", toolName: "source-fastq-tool", toolVersion: "1.0"
        )
        .argv(["source-fastq-tool", fastq.path])
        .output(fastq, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundle)
        return bundle
    }
}
