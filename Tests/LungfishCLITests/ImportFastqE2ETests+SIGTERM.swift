// ImportFastqE2ETests+SIGTERM.swift - A second SIGTERM ends `import fastq` at once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import Foundation
import LungfishTestSupport
@testable import LungfishCLI

/// Re-review finding S6-2: the first SIGTERM cancels `import fastq` so its
/// cleanup runs. A second one must end the process at once, so `kill` twice
/// or a timeout tool still stops it.
///
/// The check needs a process that may die, so the test runs this test bundle
/// again in a child xctest process. It lives in ImportFastqE2ETests, which the
/// gate runs serially in the integration tier with the other process suites.
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

        let child = Process()
        child.executableURL = URL(fileURLWithPath: xctest)
        child.arguments = ["-XCTest", "LungfishCLITests.ImportFastqE2ETests/testSIGTERMEscalationChild", bundle]
        // An IDE run hands this process the variables of its test session.
        // The child is a plain xctest run, so it must not join that session.
        var environment = ProcessInfo.processInfo.environment.filter { key, value in
            !(key.hasPrefix("XCTest") || key.hasPrefix("XCInject")
                || (key == "DYLD_INSERT_LIBRARIES" && value.contains("XCTest")))
        }
        environment[Self.childFolderVariable] = folder.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        let ready = folder.appendingPathComponent("ready").path
        let cancelled = folder.appendingPathComponent("cancelled").path
        let listening = await waitUntil(timeout: .seconds(60)) { FileManager.default.fileExists(atPath: ready) }
        XCTAssertTrue(listening, "the child turns SIGTERM into a cancel")
        guard listening else { return }

        kill(child.processIdentifier, SIGTERM)
        let sawCancel = await waitUntil(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: cancelled) }
        XCTAssertTrue(sawCancel, "the first SIGTERM cancels")
        XCTAssertTrue(child.isRunning, "the first SIGTERM does not end the process")

        kill(child.processIdentifier, SIGTERM)
        let ended = await waitUntil(timeout: .seconds(10)) { !child.isRunning }
        XCTAssertTrue(ended, "the second SIGTERM ends the process")
        guard ended else { return }
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
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
        try? await Task.sleep(for: .seconds(60))
    }
}
