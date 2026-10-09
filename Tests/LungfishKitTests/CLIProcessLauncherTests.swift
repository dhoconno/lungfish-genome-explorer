// CLIProcessLauncherTests.swift - The one lungfish-cli spec and the one outcome mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
@testable import LungfishKit

/// Phase 2.2 lane 5B (finding R7). Five runners built their own spec and
/// mapped their own outcome. They now share CLIProcessLauncher.
final class CLIProcessLauncherTests: XCTestCase {
    private let cli = URL(fileURLWithPath: "/usr/local/bin/lungfish-cli")

    func testTheSpecCarriesTheEventLineLimitNullStdinAndManagedStorage() {
        let spec = CLIProcessLauncher.spec(executableURL: cli, arguments: ["tree", "infer"])
        XCTAssertEqual(spec.argv, [cli.path, "tree", "infer"])
        XCTAssertEqual(spec.maxLineBytes, 16 * 1024 * 1024)
        XCTAssertEqual(spec.stdin, .null)
        XCTAssertEqual(spec.stdout, .capture(limit: 0))
        XCTAssertEqual(spec.stderr, .capture(limit: ToolProcessSpec.defaultStderrCaptureLimit))
        XCTAssertEqual(spec.drainGracePeriod, ToolProcessSpec.defaultDrainGracePeriod)
        XCTAssertEqual(spec.terminationGracePeriod, .zero)
        XCTAssertNotNil(spec.environment["LUNGFISH_STORAGE_ROOT"])
        XCTAssertNotNil(spec.environment["LUNGFISH_CONDA_ROOT"])
        XCTAssertEqual(spec.label, "lungfish-cli")
    }

    func testCapturedOutputKeepsStdout() {
        let spec = CLIProcessLauncher.spec(executableURL: cli, arguments: [], standardOutput: .captured)
        XCTAssertEqual(spec.stdout, .capture())
    }

    func testACleanExitIsSuccessAndDecodesInvalidUTF8Lossily() throws {
        let outcome = CLIProcessLauncher.map(.success(result(stdout: Data([0x6F, 0xFF, 0x6B]))), cancelRequested: false)
        guard case .exited(let exit) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exit.succeeded)
        XCTAssertEqual(exit.stdout, "o\u{FFFD}k")
    }

    func testIncompleteOutputIsAFailureEvenAfterACleanExit() throws {
        let outcome = CLIProcessLauncher.map(
            .success(result(stderr: Data("warn".utf8), drainTimedOut: true)),
            cancelRequested: false
        )
        guard case .exited(let exit) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(exit.succeeded)
        let reason = try XCTUnwrap(exit.incompleteOutput)
        XCTAssertEqual(exit.failureDetail, "warn\n\(reason)")
    }

    func testACancelBeforeTheLaunchHasNoExit() {
        guard case .cancelled(nil) = CLIProcessLauncher.map(.failure(.cancelled(results: [])), cancelRequested: true) else {
            return XCTFail("a cancel before launch has no exit")
        }
    }

    func testACancelDuringTheRunKeepsTheExit() {
        let cancelled = result(termination: .signaled(signal: SIGTERM), stop: .cancelled)
        guard case .cancelled(let exit?) = CLIProcessLauncher.map(.failure(.cancelled(results: [cancelled])), cancelRequested: true) else {
            return XCTFail("a cancel during the run keeps the exit")
        }
        XCTAssertEqual(exit.status, SIGTERM)
        XCTAssertNil(exit.incompleteOutput, "a stop ToolProcess made on purpose is not incomplete output")
    }

    func testACancelAfterTheExitStillReadsAsCancelled() {
        guard case .cancelled = CLIProcessLauncher.map(.success(result()), cancelRequested: true) else {
            return XCTFail("a cancel asked for during the run wins")
        }
    }

    func testALaunchFailureKeepsItsReason() {
        let outcome = CLIProcessLauncher.map(
            .failure(.launchFailed(label: "lungfish-cli", reason: "No such file", results: [])),
            cancelRequested: false
        )
        guard case .launchFailed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason, "No such file")
    }

    private func result(
        termination: ToolProcessTermination = .exited(code: 0),
        stop: ToolProcessStop? = nil,
        stdout: Data = Data(),
        stderr: Data = Data(),
        drainTimedOut: Bool = false
    ) -> ToolProcessResult {
        ToolProcessResult(
            label: "lungfish-cli",
            pid: 1,
            termination: termination,
            stop: stop,
            stdout: stdout,
            stderr: stderr,
            stdoutTruncated: false,
            stderrTruncated: false,
            outputDrainTimedOut: drainTimedOut,
            wallTime: .zero
        )
    }
}
