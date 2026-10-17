// FullLengthONTMHCAlignmentProcessRunnerTests.swift - Process semantics of the full-length MHC command runner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCAlignmentProcessRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullLengthONTMHCAlignmentProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCancellationStopsTheWholeTreeAndReturnsACancelledRecord() async throws {
        let childPIDFile = root.appendingPathComponent("child.pid")
        let tool = try script("tree", """
        #!/bin/sh
        echo "started" >&2
        /bin/sleep 300 &
        echo $! > '\(childPIDFile.path)'
        wait
        """)
        let treeRequest = request(tool)
        let task = Task { try await FullLengthONTMHCAlignmentProcessRunner().execute(treeRequest) }
        let child = try await waitForPID(in: childPIDFile)
        let startedAt = ContinuousClock.now
        task.cancel()
        let record = try await task.value
        XCTAssertTrue(record.wasCancelled)
        XCTAssertEqual(record.exitStatus, SIGTERM)
        XCTAssertEqual(record.stderr, "started\n")
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(30))
        try await assertGone(child)
    }

    func testOutputAndStatusAreRecordedFromTheLogs() async throws {
        let tool = try script("noisy", """
        #!/bin/sh
        /usr/bin/awk 'BEGIN { for (i = 0; i < 8000; i++) printf "out-%06d\\n", i }'
        /usr/bin/awk 'BEGIN { for (i = 0; i < 8000; i++) printf "err-%06d\\n", i > "/dev/stderr" }'
        exit 3
        """)
        let record = try await FullLengthONTMHCAlignmentProcessRunner().execute(request(tool))
        XCTAssertFalse(record.wasCancelled)
        XCTAssertEqual(record.exitStatus, 3)
        // 8,000 lines of 11 bytes are 88,000 bytes. The tail is the last 65,536 of them cut to whole lines, so it is
        // shorter than the limit by the part of the line that the cut fell in (Phase 2.11 B63).
        let limit = FullLengthONTMHCAlignmentProcessRunner.maximumDiagnosticBytes
        XCTAssertLessThanOrEqual(record.stdout.utf8.count, limit)
        XCTAssertGreaterThan(record.stdout.utf8.count, limit - 11)
        XCTAssertTrue(record.stdout.hasPrefix("out-"))
        XCTAssertTrue(record.stdout.split(separator: "\n").allSatisfy { $0.count == 10 })
        XCTAssertTrue(record.stdout.hasSuffix("out-007999\n"))
        XCTAssertTrue(record.stderr.hasPrefix("err-"))
        XCTAssertTrue(record.stderr.hasSuffix("err-007999\n"))
    }

    // MARK: Whole lines (Phase 2.11 B63, BIO 4)

    /// A tool that names a project path on every line. Every line is 111 bytes wide.
    private static let pathRoot = "/Users/analyst/Projects/Study.lungfish/Analyses/classify-1"

    private static func pathLine(_ index: Int) -> String {
        String(format: "[bam_sort] %06ld writing to %@/part-%06ld.sorted.bam\n", index, pathRoot, index)
    }

    /// A record keeps the last 65,536 bytes of a log, and that start lies inside a line unless the cut falls on a
    /// line start. 1,000 path lines of 111 bytes are 111,000 bytes, so the tail starts 45,464 bytes in, which is 65
    /// bytes into line 409. Cut there, the record opens with the last 46 bytes of that line, which on a path line
    /// are folder names without their root. The record starts at line 410, the first whole line.
    func testABoundedTailStartsOnAWholeLine() async throws {
        XCTAssertEqual(Self.pathLine(0).utf8.count, 111)
        XCTAssertNotEqual(FullLengthONTMHCAlignmentProcessRunner.maximumDiagnosticBytes % 111, 0)
        let tool = try script("paths", """
        #!/bin/sh
        /usr/bin/awk 'BEGIN { for (i = 0; i < 1000; i++) printf "[bam_sort] %06d writing to \(Self.pathRoot)/part-%06d.sorted.bam\\n", i, i > "/dev/stderr" }'
        """)

        let record = try await FullLengthONTMHCAlignmentProcessRunner().execute(request(tool))

        XCTAssertEqual(record.exitStatus, 0)
        XCTAssertTrue(
            record.stderr.hasPrefix("[bam_sort]"),
            "the tail starts \(record.stderr.prefix(60).debugDescription)"
        )
        let expected = (410..<1000).map(Self.pathLine).joined()
        XCTAssertTrue(
            record.stderr == expected,
            "the tail is \(record.stderr.utf8.count) bytes starting \(record.stderr.prefix(60).debugDescription), "
                + "expected \(expected.utf8.count) bytes"
        )
    }

    /// A log of exactly the 65,536 bytes a record keeps is read from its first byte, so nothing was cut and its
    /// first line is whole.
    func testALogOfExactlyTheLimitIsKeptWhole() async throws {
        let limit = FullLengthONTMHCAlignmentProcessRunner.maximumDiagnosticBytes

        let record = try await recordOfOneLine(width: limit - 1)

        XCTAssertEqual(record.stderr.utf8.count, limit)
    }

    /// One line longer than the tail holds no whole line, so the record keeps none of it. The log file stays beside
    /// the record with its hash.
    func testALineLongerThanTheTailKeepsNothing() async throws {
        let limit = FullLengthONTMHCAlignmentProcessRunner.maximumDiagnosticBytes

        let record = try await recordOfOneLine(width: limit)

        XCTAssertEqual(record.stderr, "")
    }

    /// The record of a tool that prints one line of `width` characters to stderr.
    private func recordOfOneLine(width: Int) async throws -> FullLengthONTMHCCohortAlignmentCommandRecord {
        let tool = try script("one-line-\(width)", """
        #!/bin/sh
        /usr/bin/head -c \(width) /dev/zero | /usr/bin/tr '\\0' x >&2
        echo >&2
        """)
        return try await FullLengthONTMHCAlignmentProcessRunner().execute(request(tool))
    }

    func testLaunchFailureReturnsARecordWithStatusMinusOne() async throws {
        let missing = root.appendingPathComponent("missing-tool")
        let record = try await FullLengthONTMHCAlignmentProcessRunner().execute(request(missing))
        XCTAssertFalse(record.wasCancelled)
        XCTAssertEqual(record.exitStatus, -1)
        XCTAssertFalse(record.stderr.isEmpty)
    }

    func testADescendantStillWritingAfterExitIsAnError() async throws {
        let tool = try script("lingering", """
        #!/bin/sh
        ( /bin/sleep 30; echo late ) &
        exit 0
        """)
        do {
            _ = try await FullLengthONTMHCAlignmentProcessRunner().execute(request(tool))
            XCTFail("Expected incomplete output to be an error")
        } catch let error as FullLengthONTMHCAlignmentSafetyError {
            XCTAssertTrue(error.localizedDescription.contains("incomplete"), error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func request(_ executable: URL) -> FullLengthONTMHCAlignmentProcessRequest {
        FullLengthONTMHCAlignmentProcessRequest(
            executableURL: executable,
            arguments: [],
            inputs: [],
            outputs: [],
            stdoutURL: nil,
            workingDirectoryURL: root,
            logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true),
            toolVersion: nil,
            temporaryRootURL: root,
            pathIdentityValidator: nil
        )
    }

    private func script(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The 30 s deadlines here and in assertGone leave room for the parallel
    /// unit tier. Both return as soon as their condition holds, and the child
    /// sleeps 300 s, so the cancellation bound still shows a stop.
    private func waitForPID(in url: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func assertGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        kill(pid, SIGKILL)
        XCTFail("Process \(pid) outlived the cancelled run", file: file, line: line)
    }
}
