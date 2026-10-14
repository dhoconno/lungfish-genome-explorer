// ReadsLaunchRouteTests.swift - The mapping and assembly keys, the CLI route's argv and the L6 runner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M1 and M2, decisions C4 and C5, ARCH 7. Each key value picks its route, each
// launch has its own key, the mapping key's CLI route records the argv it runs, and CLIReadsRunner
// reads an events leaf's end: its completion, its failed line, a failure with the command's standard
// error when no failed line came, and a cancel before the run that launches nothing. The runner runs
// a stand-in `lungfish-cli` script, so no tool runs.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ReadsLaunchRouteTests: XCTestCase {
    func testAnUnsetKeyKeepsTodaysInProcessRoute() {
        let settings = ReadsLaunchRouteSettings(defaults: makeTestDefaultsSuite(prefix: "reads-route").defaults)
        XCTAssertEqual(ReadsLaunchRouteSettings.defaultRoute, .legacy)
        for path in ReadsLaunchPath.allCases {
            XCTAssertEqual(settings.route(for: path), .legacy, path.rawValue)
        }
    }

    func testEachKeyValuePicksItsRoute() {
        let defaults = makeTestDefaultsSuite(prefix: "reads-route").defaults
        let settings = ReadsLaunchRouteSettings(defaults: defaults)
        let cases: [(Any, ReadsLaunchRoute)] = [
            ("cli", .cli), ("CLI", .cli), ("legacy", .legacy), (true, .cli), (false, .legacy), ("in-process", .legacy),
        ]
        for (value, route) in cases {
            defaults.set(value, forKey: ReadsLaunchPath.mapping.defaultsKey)
            XCTAssertEqual(settings.route(for: .mapping), route, "\(value)")
        }
    }

    func testEachLaunchHasItsOwnKey() {
        let defaults = makeTestDefaultsSuite(prefix: "reads-route").defaults
        let settings = ReadsLaunchRouteSettings(defaults: defaults)
        XCTAssertEqual(ReadsLaunchPath.mapping.defaultsKey, "ReadsLaunchRoute.mapping")
        XCTAssertEqual(ReadsLaunchPath.assembly.defaultsKey, "ReadsLaunchRoute.assembly")
        defaults.set("cli", forKey: ReadsLaunchPath.mapping.defaultsKey)
        XCTAssertEqual(settings.route(for: .mapping), .cli)
        XCTAssertEqual(settings.route(for: .assembly), .legacy)
    }

    func testTheCLIRouteRecordsTheMapArgvItRuns() throws {
        let root = try TestTempDirectory.make(prefix: "reads-route-argv")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analysis = try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: project)
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [project.appendingPathComponent("Imports/sampleA.lungfishfastq", isDirectory: true)],
            referenceFASTAURL: project.appendingPathComponent("genome.fasta"),
            projectURL: project,
            outputDirectory: analysis,
            sampleName: "sampleA",
            threads: 2
        )

        let arguments = AppDelegate.managedMappingCLIArguments(for: request)
        XCTAssertEqual(arguments, ["map"] + MappingCLIInvocationBuilder.arguments(for: request) + ["--format", "json"])
        let reporter = RecordingOperationReporter()
        AppDelegate.beginManagedMappingOperation(
            request: request,
            routeContext: nil,
            reporter: reporter,
            cliArguments: arguments
        ) { _ in }
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), arguments)
        XCTAssertEqual(item.title, "Map Reads (minimap2): sampleA", "the CLI route keeps today's title")
        let parsed = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        XCTAssertEqual(parsed.outputDir, analysis.path)
        XCTAssertEqual(parsed.readLayout, .auto)
    }

    func testACancelBeforeTheRunLaunchesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "reads-runner-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let launched = root.appendingPathComponent("launched")
        let runner = CLIReadsRunner(cliURLOverride: try standInCLI("touch '\(launched.path)'; exit 0"))
        runner.cancel()
        do {
            _ = try await runner.runEvents(arguments: ["map"], operationID: UUID())
            XCTFail("a cancel before the run stops it")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched.path), "the command never launched")
    }

    func testTheRunnerFailsAnExitWithNoFailedEventWithTheCommandsStandardError() async throws {
        let cli = try standInCLI("echo 'Error: the reference is not a FASTA file' >&2; exit 64")
        do {
            _ = try await CLIReadsRunner(cliURLOverride: cli).runEvents(arguments: ["map"], operationID: UUID())
            XCTFail("exit 64 is a failure")
        } catch let error as CLISubprocessTransport.RunError {
            guard case .nonZeroExit(let status, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 64)
            XCTAssertTrue(detail.contains("the reference is not a FASTA file"), detail)
        }
    }

    func testTheRunnerReturnsAnEventsLeafsCompletion() async throws {
        let cli = try standInCLI(#"echo '{"event":"complete","outputs":["/work/a.bam"],"progress":1,"schemaVersion":2}'; exit 0"#)
        let result = try await CLIReadsRunner(cliURLOverride: cli).runEvents(arguments: ["assemble"], operationID: UUID())
        XCTAssertEqual(result.outputs, ["/work/a.bam"])
    }

    func testTheRunnerFailsAnEventsLeafWithItsFailedEvent() async throws {
        let cli = try standInCLI(#"echo '{"event":"failed","error":"the reads are empty","schemaVersion":2}'; exit 1"#)
        do {
            _ = try await CLIReadsRunner(cliURLOverride: cli).runEvents(arguments: ["assemble"], operationID: UUID())
            XCTFail("a failed event fails the run")
        } catch let error as CLISubprocessTransport.RunError {
            XCTAssertEqual(error, .failedEvent(message: "the reads are empty", detail: nil))
        }
    }

    /// A `lungfish-cli` stand-in that runs `body` whatever it is given.
    private func standInCLI(_ body: String) throws -> URL {
        let root = try TestTempDirectory.make(prefix: "reads-runner")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let script = root.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
