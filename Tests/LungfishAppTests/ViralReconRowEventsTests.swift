// ViralReconRowEventsTests.swift - The Viral Recon row reads its CLI's events through the bridge's one rule
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, ARCH's ruling on M3 (commit 6, decision N5). The Viral Recon runner passes --format json and
// hands each line of standard output, decoded, to `OperationCenterCLIBridge.onEvent(operationID:)`, and each line of
// standard error to it as an info log event, as `CLISubprocessTransport` does. So only a warning event, the CLI's
// outcome line, makes the row Completed with Warnings, and a line of standard error never does. The bridge writes to
// `OperationCenter.shared`, so these cases run there and read their own row by its id. No case starts a process.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ViralReconRowEventsTests: XCTestCase {
    private var scratch: URL!
    private var savedFailureReportStore: OperationFailureReportStore?

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "viralrecon-row-events")
        savedFailureReportStore = OperationCenter.shared.failureReportStore
        OperationCenter.shared.failureReportStore = OperationFailureReportStore(
            directory: scratch.appendingPathComponent("failure-reports", isDirectory: true)
        )
    }

    override func tearDown() async throws {
        if let savedFailureReportStore { OperationCenter.shared.failureReportStore = savedFailureReportStore }
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    private static let failedSample = "1 failed sample: S2. Too few reads were left after trimming or mapping to call variants."

    func testAFailedSampleMakesTheRowCompletedWithWarnings() async throws {
        let item = try await run([
            .standardOutput(Self.line(.start(message: ""))),
            .standardOutput(Self.line(.log(level: .info, message: "Preparing workflow: nf-core/viralrecon"))),
            .standardOutput(Self.line(.log(level: .info, message: "Created run bundle: /work/viralrecon.lungfishrun"))),
            .standardOutput(Self.line(.log(level: .warning, message: Self.failedSample))),
            .standardOutput(Self.line(.complete(outputs: ["/work/viralrecon.lungfishrun", "/work/results"], message: nil))),
        ])

        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertTrue(Self.loggedLines(of: item).contains("warning: \(Self.failedSample)"), "\(Self.loggedLines(of: item))")
        XCTAssertFalse(Self.loggedLines(of: item).contains { $0.contains("{\"event\"") }, "the log holds messages, not JSON")
    }

    func testAStandardErrorLineLeavesTheRowCompleted() async throws {
        let item = try await run([
            .standardOutput(Self.line(.log(level: .info, message: "Read pairing: S1: paired R1/R2 files, runs paired-end"))),
            .standardError("WARN: low coverage"),
        ])

        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed", "standard error stays at info (rule 5)")
        XCTAssertTrue(Self.loggedLines(of: item).contains("info: WARN: low coverage"))
    }

    /// The bridge takes each event one main-queue hop after the runner hands it over, so a warning that is the CLI's
    /// last line lands after the run returns. The route waits one turn of the main queue before it reads the row.
    func testALastLineWarningSetsTheLabel() async throws {
        let item = try await run([.standardOutput(Self.line(.log(level: .warning, message: Self.failedSample)))])

        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
    }

    /// The bundle's `logs/stdout.log` holds the words of each event, not its JSON. The empty `start` that opens the
    /// CLI's stream has no words, so it adds no line and the log opens with the first line that has some (A30 M3
    /// review, fix 3).
    func testTheEmptyStartLeavesNoBlankLineAtTheTopOfTheBundlesStdoutLog() async throws {
        let stdout = [
            Self.line(.start(message: "")),
            Self.line(.log(level: .info, message: "Preparing workflow: nf-core/viralrecon")),
            Self.line(.log(level: .info, message: "Created run bundle: /work/viralrecon.lungfishrun")),
            Self.line(.complete(outputs: ["/work/viralrecon.lungfishrun", "/work/results"], message: nil)),
        ].joined(separator: "\n")

        let result = try await runRoute(standardOutput: stdout)

        let log = try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stdout.log"), encoding: .utf8)
        XCTAssertEqual(
            log,
            "Preparing workflow: nf-core/viralrecon\nCreated run bundle: /work/viralrecon.lungfishrun\n/work/viralrecon.lungfishrun\n/work/results"
        )
    }

    // MARK: - Helpers

    /// Runs the Viral Recon route on `OperationCenter.shared` with a CLI that hands over `streamed` and exits 0, and
    /// returns the row as the route left it.
    private func run(_ streamed: [ViralReconWorkflowProcessOutput]) async throws -> OperationCenter.Item {
        let result = try await runRoute(streamed: streamed)
        return try XCTUnwrap(result.operationItem)
    }

    /// Runs the Viral Recon route on `OperationCenter.shared` with a CLI that streams `streamed`, hands back
    /// `standardOutput` as the text it printed and exits 0.
    private func runRoute(
        streamed: [ViralReconWorkflowProcessOutput] = [],
        standardOutput: String = ""
    ) async throws -> ViralReconWorkflowExecutionService.RunResult {
        let root = scratch.appendingPathComponent("viral-recon-\(UUID().uuidString)", isDirectory: true)
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: root)
        let runner = StreamingRunner(streamed: streamed, standardOutput: standardOutput)
        let service = ViralReconWorkflowExecutionService(
            operationCenter: .shared,
            processRunner: runner,
            referenceDownloader: { _, _ in },
            resultIngest: { _ in }
        )
        let result = try await service.run(request, bundleRoot: root.appendingPathComponent("Analyses", isDirectory: true))
        XCTAssertEqual(runner.arguments.suffix(2), ["--format", "json"], "the route reads the CLI's events")
        return result
    }

    private static func line(_ event: CLIEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(CLIEventLine(event: event, artifacts: []))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private static func loggedLines(of item: OperationCenter.Item) -> [String] {
        item.logEntries.filter { !$0.isElisionMarker }.map { "\($0.level.rawValue): \($0.message)" }
    }
}

/// A Viral Recon CLI that hands over its lines as they would stream and exits 0 at once.
@MainActor
private final class StreamingRunner: ViralReconWorkflowProcessRunning {
    let streamed: [ViralReconWorkflowProcessOutput]
    let standardOutput: String
    private(set) var arguments: [String] = []

    init(streamed: [ViralReconWorkflowProcessOutput], standardOutput: String = "") {
        self.streamed = streamed
        self.standardOutput = standardOutput
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        self.arguments = arguments
        for output in streamed { outputHandler?(output) }
        return ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: standardOutput, standardError: "", didStreamOutput: !streamed.isEmpty)
    }

    func cancel() {}
}
