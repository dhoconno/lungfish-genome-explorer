// LungfishCLIProcessRunnerLiveConformanceTests.swift - The FASTQ operations dialog's runner on the built lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A41 M2, under the QA ruling on 2.9 owner direction O5. `LungfishCLIProcessRunnerTests`
// runs the runner against a shell stand-in. This class runs it against the `lungfish-cli` built beside
// the test bundle, with leaves that need no external tool. `fastq platform --format json` prints its
// events on standard output, which no dialog leaf did before 2.10, and `fastq reverse-complement`
// writes a relative output into the runner's working directory.
//
// It runs its body only when LUNGFISH_REQUIRE_TOOLS=1 is set and the built CLI is found. Its name ends
// in LiveConformanceTests, so only the conformance tier selects it, and the stand-in class stays the
// default and the fallback.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport

final class LungfishCLIProcessRunnerLiveConformanceTests: XCTestCase {
    private var scratch: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        guard ToolAvailability.requireTools else {
            throw XCTSkip("Set LUNGFISH_REQUIRE_TOOLS=1 to run the dialog's runner on the built lungfish-cli")
        }
        guard let built = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            try ToolAvailability.skipOrFail("no lungfish-cli is built beside the test bundle")
        }
        cli = built
        scratch = try TestTempDirectory.make(prefix: "lungfish-cli-process-runner-live")
    }

    override func tearDown() {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    /// The real leaf prints its `start` event on standard output, where its row says, and the dialog
    /// is told it.
    func testTheDialogIsToldTheEventsARealLeafPrintsOnStandardOutput() async throws {
        let bundle = try FASTQOperationTestHelper.makeBundle(named: "Sample 1", in: scratch)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 4, readLength: 20)
        let invocation = FASTQCLIInvocation(
            subcommand: "fastq",
            arguments: ["platform", bundle.bundleURL.path, "--set", "illumina", "--format", "json"]
        )
        XCTAssertEqual(invocation.eventChannel, .standardOutput)
        let told = LiveTold()

        _ = try await LungfishCLIProcessRunner(cliURLProvider: { [cli] in cli }).run(
            invocation: invocation,
            outputDirectory: scratch,
            progress: { _, message in told.append(message) }
        )

        XCTAssertEqual(told.messages, ["Recording the sequencing platform of 1 FASTQ bundle(s)"])
    }

    /// A real leaf that fails on standard output is reported with its own `failed` event, not with the
    /// text it also prints on standard error.
    func testAFailedRealLeafIsReportedWithItsFailedEvent() async throws {
        let folder = scratch.appendingPathComponent("not-a-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let invocation = FASTQCLIInvocation(
            subcommand: "fastq",
            arguments: ["platform", folder.path, "--set", "illumina", "--format", "json"]
        )

        do {
            _ = try await LungfishCLIProcessRunner(cliURLProvider: { [cli] in cli }).run(
                invocation: invocation, outputDirectory: scratch, progress: { _, _ in }
            )
            XCTFail("a folder that is not a bundle must fail")
        } catch LungfishCLIRunner.RunError.nonZeroExit(let status, let summary) {
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(summary.isEmpty)
            XCTAssertFalse(summary.contains("{\"event\""), "the summary is the event's message: \(summary)")
            XCTAssertFalse(summary.hasPrefix("Error:"), "the summary is the event, not standard error: \(summary)")
        }
    }

    /// The real CLI runs in the plan's output directory with the managed storage environment, so a
    /// relative output lands there.
    func testARealDerivativeWritesARelativeOutputInTheOutputDirectory() async throws {
        let input = scratch.appendingPathComponent("reads.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: input, readCount: 4, readLength: 20)
        let directory = scratch.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        _ = try await LungfishCLIProcessRunner(cliURLProvider: { [cli] in cli }).run(
            invocation: FASTQCLIInvocation(subcommand: "fastq", arguments: ["reverse-complement", input.path, "-o", "out.fastq"]),
            outputDirectory: directory,
            progress: { _, _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.fastq").path))
    }
}

/// The messages the runner tells the dialog, in order.
private final class LiveTold: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ message: String) {
        storage.withLock { $0.append(message) }
    }

    var messages: [String] {
        storage.withLock { $0 }
    }
}
