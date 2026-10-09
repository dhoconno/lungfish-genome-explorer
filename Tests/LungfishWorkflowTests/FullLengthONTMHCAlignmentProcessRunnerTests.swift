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
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(5))
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
        XCTAssertEqual(record.stdout.utf8.count, FullLengthONTMHCAlignmentProcessRunner.maximumDiagnosticBytes)
        XCTAssertTrue(record.stdout.hasSuffix("out-007999\n"))
        XCTAssertTrue(record.stderr.hasSuffix("err-007999\n"))
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

    private func waitForPID(in url: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(10)
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
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        kill(pid, SIGKILL)
        XCTFail("Process \(pid) outlived the cancelled run", file: file, line: line)
    }
}
