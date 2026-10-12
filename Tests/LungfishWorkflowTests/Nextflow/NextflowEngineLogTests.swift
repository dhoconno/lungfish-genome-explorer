// NextflowEngineLogTests.swift - The engine's nextflow.log and its streams, failed writes included
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9, the SWIFT review of M1 (fix 3). A write of the log that fails is reported to the
// caller, so it can fail a run whose log is incomplete instead of hashing it.

import Darwin
import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class NextflowEngineLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-engine-log")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testALineThatCannotBeWrittenIsReportedAndStillCounted() throws {
        let url = root.appendingPathComponent("read-only.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var stream = NextflowLogStream(descriptor: descriptor, destination: url, tailLineCount: 3)

        stream.append("a")
        stream.append("b")

        XCTAssertEqual(stream.writeFailure?.contains(url.path), true, "\(String(describing: stream.writeFailure))")
        XCTAssertEqual(stream.tail, ["a", "b"], "a line that could not be written still counts in the tail")
    }

    func testTheLogReportsTheFirstFailedWriteWhenItFinishes() throws {
        let launch = root.appendingPathComponent("launch", isDirectory: true)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        let logFile = root.appendingPathComponent("nextflow.log")
        var log = try NextflowEngineLog.create(
            at: logFile,
            preamble: "preamble\n",
            stderrSidecar: launch.appendingPathComponent(NextflowEngineLog.stderrSidecarName),
            tailLineCount: 3
        )
        log.beginStdout()
        let readOnly = root.appendingPathComponent("read-only.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: readOnly.path, contents: nil))
        let descriptor = Darwin.open(readOnly.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var failing = NextflowLogStream(descriptor: descriptor, destination: readOnly, tailLineCount: 3)
        failing.append("lost line")
        var stderr = log.stderrStream()
        stderr.append("an error")

        let failure = log.finish(stdout: failing, stderr: stderr)

        XCTAssertNotNil(failing.writeFailure)
        XCTAssertEqual(failure, failing.writeFailure, "the stdout part's failure reaches the caller")
        XCTAssertEqual(
            try String(contentsOf: logFile, encoding: .utf8),
            "preamble\n\n--- stdout ---\n\n--- stderr ---\nan error",
            "the rest of the log is still written and synchronized"
        )
    }

    func testALogWhoseEveryWriteSucceedsReportsNoFailure() throws {
        let launch = root.appendingPathComponent("launch", isDirectory: true)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        let logFile = root.appendingPathComponent("nextflow.log")
        var log = try NextflowEngineLog.create(
            at: logFile,
            preamble: "preamble\n",
            stderrSidecar: launch.appendingPathComponent(NextflowEngineLog.stderrSidecarName),
            tailLineCount: 3
        )
        log.beginStdout()
        var stdout = log.stdoutStream()
        stdout.append("a line")
        var stderr = log.stderrStream()
        stderr.append("an error")

        XCTAssertNil(log.finish(stdout: stdout, stderr: stderr))
        XCTAssertEqual(
            try String(contentsOf: logFile, encoding: .utf8),
            "preamble\n\n--- stdout ---\na line\n--- stderr ---\nan error"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: launch.path), [], "the sidecar goes")
    }
}
