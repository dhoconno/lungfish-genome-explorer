// ViralReconWorkflowExecutionServiceLogFileTests.swift - Which writer each log of a Viral Recon bundle from the app has
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10, B31 review fix 3 (BIO 9). `lungfish-cli workflow run nf-core/viralrecon` writes the engine's tails to
// `logs/stdout.log` and `logs/stderr.log` and names them in the bundle's manifest. The route that runs the CLI from the
// app then holds the CLI's own standard output and error, which must land in files of their own so that each log the
// manifest names keeps the one writer its key says.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class ViralReconWorkflowExecutionServiceLogFileTests: XCTestCase {

    /// A stand-in CLI leaves both engine tails in the bundle's logs, as `workflow run` does once the engine exits, and
    /// prints lines of its own. The tails survive the app, and the CLI's lines land in `logs/lungfish-cli.stdout.log`
    /// and `logs/lungfish-cli.stderr.log`.
    func testTheEngineTailsSurviveTheApp() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-log-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: EngineTailsThenOwnLinesRunner()
        )

        let result = try await service.run(request, bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true))

        let logs = result.bundleURL.appendingPathComponent("logs", isDirectory: true)
        func log(_ name: String) throws -> String {
            try String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(try log("stdout.log"), EngineTailsThenOwnLinesRunner.engineOutput, "the engine's output tail did not survive")
        XCTAssertEqual(try log("stderr.log"), EngineTailsThenOwnLinesRunner.engineErrors, "the engine's error tail did not survive")
        XCTAssertEqual(try log("lungfish-cli.stdout.log"), EngineTailsThenOwnLinesRunner.cliOutput)
        XCTAssertEqual(try log("lungfish-cli.stderr.log"), EngineTailsThenOwnLinesRunner.cliErrors)
    }
}

/// A CLI that writes the engine's two tails into the bundle's logs, then prints its own lines and exits 0.
@MainActor
private final class EngineTailsThenOwnLinesRunner: ViralReconWorkflowProcessRunning {
    static let engineOutput = "engine output tail\n"
    static let engineErrors = "engine error tail\n"
    static let cliOutput = "Preparing workflow: nf-core/viralrecon\nThe CLI finished"
    static let cliErrors = "A warning only the CLI printed"

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        let logs = workingDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Self.engineOutput.write(to: logs.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
        try Self.engineErrors.write(to: logs.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
        return ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: Self.cliOutput, standardError: Self.cliErrors)
    }

    func cancel() {}
}
