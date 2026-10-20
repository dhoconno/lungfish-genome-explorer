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
        // Call 1 comes before the copy. Call 2 is the first chunk of the first hash, so the staging bundle exists.
        try assertCancelled(atCall: 2)
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
    private func makeBundle() throws -> URL {
        let bundle = root.appendingPathComponent("Source/Reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        let output = try ProvenanceFileDescriptor.file(url: fastq, format: .fastq, role: .output)
        let step = ProvenanceStep(
            toolName: "source-fastq-tool", toolVersion: "1.0", argv: ["source-fastq-tool", fastq.path],
            outputs: [output], exitStatus: 0, wallTimeSeconds: 0.1
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "source FASTQ bundle", workflowVersion: "1.0", toolName: "source-fastq-tool",
            toolVersion: "1.0", argv: ["source-fastq-tool", fastq.path], files: [output], output: output,
            outputs: [output], steps: [step], wallTimeSeconds: 0.1, exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundle)
        return bundle
    }
}
