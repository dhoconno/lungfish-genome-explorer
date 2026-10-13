// ImportFastqE2ETests+SIGTERM.swift - A second SIGTERM ends `import fastq` at once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI

/// Re-review finding S6-2: the first SIGTERM cancels `import fastq` so its
/// cleanup runs. A second one must end the process at once, so `kill` twice
/// or a timeout tool still stops it.
///
/// The check needs a process that may die, so the test runs this test bundle
/// again in a child xctest process, which `CLISIGTERMHarness` starts, signals
/// and waits for (Phase 2.10 lane S30). It lives in ImportFastqE2ETests, which
/// the gate runs serially in the integration tier with the other process suites.
extension ImportFastqE2ETests {

    private static let childFolderVariable = "LUNGFISH_SIGTERM_ESCALATION_CHILD"

    func testASecondSIGTERMEndsTheProcessAtOnce() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let xctest = arguments.first, xctest.hasSuffix("xctest") else {
            throw XCTSkip("Needs to run under xctest to start a child test process")
        }
        let bundle = Bundle(for: Self.self).bundlePath
        let folder = try TestTempDirectory.make(prefix: "sigterm-escalation")
        defer { TestTempDirectory.cleanup(folder) }

        // An IDE run hands this process the variables of its test session, which
        // the harness leaves out, so the child is a plain xctest run.
        let child = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: xctest),
            arguments: ["-XCTest", "LungfishCLITests.ImportFastqE2ETests/testSIGTERMEscalationChild", bundle],
            environment: CLISIGTERMHarness.childEnvironment(overriding: [Self.childFolderVariable: folder.path])
        )
        defer { child.stop() }

        // Loading this test bundle in the child can take longer than a process wait.
        let ready = folder.appendingPathComponent("ready")
        let listening = await CLISIGTERMHarness.waitForFile(ready, timeout: .seconds(60))
        XCTAssertTrue(listening, "the child turns SIGTERM into a cancel")
        guard listening else { return }

        child.sendSIGTERM()
        let sawCancel = await CLISIGTERMHarness.waitForFile(folder.appendingPathComponent("cancelled"))
        XCTAssertTrue(sawCancel, "the first SIGTERM cancels")
        XCTAssertTrue(child.isRunning, "the first SIGTERM does not end the process")

        let stop = await CLISIGTERMHarness.cancel(child)
        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), "the second SIGTERM ends the process.\(stop.diagnostics)")
        if let elapsed = stop.elapsed {
            XCTAssertLessThanOrEqual(elapsed, CLISIGTERMHarness.operationGrace, "the second SIGTERM ends the process at once")
        }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
    }

    /// Runs only in the child process that the test above starts.
    func testSIGTERMEscalationChild() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.childFolderVariable] else {
            throw XCTSkip("Runs only as the child of testASecondSIGTERMEndsTheProcessAtOnce")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let cancelled = folder.appendingPathComponent("cancelled")
        let termination = SIGTERMCancellation(secondSignalEndsProcess: true) {
            FileManager.default.createFile(atPath: cancelled.path, contents: Data())
        }
        defer { termination.end() }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("ready").path, contents: Data())
        // The parent ends this process. The ceiling only bounds an orphan.
        try? await Task.sleep(for: .seconds(120))
    }
}
