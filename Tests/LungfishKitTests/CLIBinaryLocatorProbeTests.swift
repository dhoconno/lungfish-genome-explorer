// CLIBinaryLocatorProbeTests.swift - The SwiftPM bin path probe of the CLI locator
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.11 (R6 of M879). The locator asks SwiftPM where it builds with
// `swift build --show-bin-path`, which waits on the build lock another `swift build` or `swift test`
// holds. The 2.12 verify run waited 884 s on that call because nothing bounded it. These cases run the
// probe's seam against shell stand-ins, so no swift process starts. The probe always runs on a global
// queue, since `ToolProcess.runBlocking` must not run on the main thread.

import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishKit

/// Holds what a probe returned on another thread.
private final class ProbeOutcome: Sendable {
    private let stored = Mutex<URL?>(nil)

    func record(_ url: URL?) {
        stored.withLock { $0 = url }
    }

    var url: URL? {
        stored.withLock { $0 }
    }
}

final class CLIBinaryLocatorProbeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try TestTempDirectory.make(prefix: "cli-locator-probe")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
        try super.tearDownWithError()
    }

    private func writeStub(_ name: String, _ body: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Ends a stand-in that outlived its test, so a probe with no bound cannot leave it running.
    private func killStub(pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProcessTreeTerminator.processExists(pid: pid)
        else { return }
        kill(pid, SIGKILL)
    }

    /// Runs the probe on a global queue and waits for it with `await`, so no thread of the test blocks
    /// the main queue. `returned` is false when the probe still ran after the test's own 30 s wait.
    private func runProbe(
        executable: URL,
        arguments: [String] = [],
        timeout: Duration
    ) async -> (returned: Bool, url: URL?) {
        await withCheckedContinuation { continuation in
            let outcome = ProbeOutcome()
            let returned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                outcome.record(
                    CLIBinaryLocator.swiftPMDevelopmentBinPath(executable: executable, arguments: arguments, timeout: timeout)
                )
                returned.signal()
            }
            DispatchQueue.global().async {
                let didReturn = returned.wait(timeout: .now() + 30) == .success
                continuation.resume(returning: (didReturn, outcome.url))
            }
        }
    }

    // MARK: - Results

    /// `swift build` can print a warning before the path, so the last line of standard output is the answer.
    func testTheProbeTakesTheLastLineOfStandardOutputAsTheDirectory() async throws {
        let stub = try writeStub("prints-path", "echo 'warning: a plugin was skipped'\necho /opt/build/debug")

        let probe = await runProbe(executable: stub, timeout: .seconds(30))

        XCTAssertTrue(probe.returned)
        XCTAssertEqual(probe.url?.path, "/opt/build/debug")
    }

    func testAProbeThatExitsNonzeroReturnsNil() async throws {
        let stub = try writeStub("fails", "echo /opt/build/debug\nexit 3")

        let probe = await runProbe(executable: stub, timeout: .seconds(30))

        XCTAssertTrue(probe.returned)
        XCTAssertNil(probe.url)
    }

    func testAProbeThatCannotLaunchReturnsNil() async {
        let missing = scratch.appendingPathComponent("no-such-program")

        let probe = await runProbe(executable: missing, timeout: .seconds(30))

        XCTAssertTrue(probe.returned)
        XCTAssertNil(probe.url)
    }

    // MARK: - The bound

    /// A probe that never exits, as `swift build --show-bin-path` behind another build's lock, returns
    /// nil inside its timeout and leaves no process. The test waits 30 s for the probe, far above the
    /// 5 s bound, so a probe without a bound fails here and does not hang the runner.
    func testAProbeThatNeverExitsReturnsNilInsideItsBoundAndLeavesNoProcess() async throws {
        let pidFile = scratch.appendingPathComponent("stub.pid")
        let stub = try writeStub("never-exits", "echo $$ > \"$1\"\nexec sleep 3600")
        defer { killStub(pidFile: pidFile) }

        let probe = await runProbe(executable: stub, arguments: [pidFile.path], timeout: .seconds(5))

        XCTAssertTrue(probe.returned, "the probe did not return within 30 s although its bound is 5 s")
        XCTAssertNil(probe.url)
        let text = try XCTUnwrap(
            try? String(contentsOf: pidFile, encoding: .utf8),
            "the stand-in never wrote its process ID"
        )
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: pid), "the stand-in still runs after the timeout")
    }

    /// The production bound is a named constant of at most 120 s (TALLY row 13.11).
    func testTheProductionBoundIsAtMost120Seconds() {
        XCTAssertLessThanOrEqual(CLIBinaryLocator.swiftPMProbeTimeout, .seconds(120))
        XCTAssertGreaterThan(CLIBinaryLocator.swiftPMProbeTimeout, .seconds(0))
    }
}

/// The PATH step of the locator finds the CLI without starting `which` (Phase 2.13 lane 13.11).
final class CLIBinaryLocatorPathLookupTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try TestTempDirectory.make(prefix: "cli-locator-path")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
        try super.tearDownWithError()
    }

    private func writeCLI(executable: Bool) throws {
        let url = scratch.appendingPathComponent(CLICommandIdentity.executableName)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
    }

    func testTheCLIInADirectoryOfThePathIsFound() throws {
        try writeCLI(executable: true)

        let found = CLIBinaryLocator.pathLookupForCLI(path: "/nonexistent:\(scratch.path)")

        XCTAssertEqual(found?.lastPathComponent, CLICommandIdentity.executableName)
        XCTAssertEqual(found?.deletingLastPathComponent().path, scratch.path)
    }

    func testNoCLIOnThePathIsNotFound() {
        XCTAssertNil(CLIBinaryLocator.pathLookupForCLI(path: scratch.path))
    }

    func testACLIFileWithoutAnExecutePermissionIsNotFound() throws {
        try writeCLI(executable: false)

        XCTAssertNil(CLIBinaryLocator.pathLookupForCLI(path: scratch.path))
    }
}
