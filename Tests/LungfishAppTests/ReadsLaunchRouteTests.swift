// ReadsLaunchRouteTests.swift - The mapping and assembly keys, the CLI route's argv and the L6 runner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M1 and M2, decisions C4 and C5, ARCH 7. Each key value picks its route, each
// launch has its own key, the mapping key's CLI route records the argv it runs, and CLIReadsRunner
// reads an events leaf's end: its completion, its failed line, a failure with the command's standard
// error when no failed line came, and a cancel before the run that launches nothing. Fix 8 adds the
// route's end after a cancel, a command that finished first keeping its result and one that honoured
// the cancel losing its folder. M3 adds each key value's route through the launch that reads it
// (ARCH 7). The runner runs a stand-in `lungfish-cli` script, so no tool runs.

import AppKit
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
    func testAnUnsetKeyTakesTheCLIRoute() {
        let settings = ReadsLaunchRouteSettings(defaults: makeTestDefaultsSuite(prefix: "reads-route").defaults)
        XCTAssertEqual(ReadsLaunchRouteSettings.defaultRoute, .cli, "the CLI route is the default (C4)")
        for path in ReadsLaunchPath.allCases {
            XCTAssertEqual(settings.route(for: path), .cli, path.rawValue)
        }
    }

    func testEachKeyValuePicksItsRoute() {
        let defaults = makeTestDefaultsSuite(prefix: "reads-route").defaults
        let settings = ReadsLaunchRouteSettings(defaults: defaults)
        // A value the reader does not know, such as "in-process", reads the default, the CLI route.
        let cases: [(Any, ReadsLaunchRoute)] = [
            ("cli", .cli), ("CLI", .cli), ("legacy", .legacy), ("LEGACY", .legacy), (true, .cli), (false, .legacy),
            ("in-process", .cli),
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
        XCTAssertEqual(ReadsLaunchPath.ontImport.defaultsKey, "ReadsLaunchRoute.ontImport")
        defaults.set("legacy", forKey: ReadsLaunchPath.mapping.defaultsKey)
        XCTAssertEqual(settings.route(for: .mapping), .legacy)
        XCTAssertEqual(settings.route(for: .assembly), .cli, "the other launch keeps its own route")
        defaults.set("legacy", forKey: ReadsLaunchPath.assembly.defaultsKey)
        defaults.removeObject(forKey: ReadsLaunchPath.mapping.defaultsKey)
        XCTAssertEqual(settings.route(for: .mapping), .cli, "an unset key reads the default again")
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

    /// The Reassemble key's CLI route launches, on the runner, the argv its row records, with
    /// `--reference-bundle` and `--format json`, and a failed line fails the row with its words.
    func testTheReassembleCLIRouteRunsTheCommandItsRowRecords() async throws {
        let root = try TestTempDirectory.make(prefix: "reassemble-cli-route")
        defer { TestTempDirectory.cleanup(root) }
        let launched = root.appendingPathComponent("argv")
        let cli = try standInCLI("""
        printf '%s\\n' "$@" > '\(launched.path)'
        echo '{"error":"the stand-in refused","event":"failed","schemaVersion":2}'
        exit 1
        """)
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [root.appendingPathComponent("reads.fastq")],
            projectName: "demo",
            outputDirectory: root.appendingPathComponent("Assemblies", isDirectory: true),
            threads: 1
        ).normalizedForExecution()

        let opID = try XCTUnwrap(AssemblyRunner.startManagedAssembly(
            request: request,
            routeContext: nil,
            route: .cli,
            runner: CLIReadsRunner(cliURLOverride: cli)
        ))
        defer { OperationCenter.shared.clearItem(id: opID) }
        let ended = await waitUntil(timeout: .seconds(30)) {
            OperationCenter.shared.items.first { $0.id == opID }?.state == .failed
        }

        XCTAssertTrue(ended, "the row fails")
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == opID })
        let argv = try String(contentsOf: launched, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, try RecordedCLICommand.arguments(of: item.cliCommand), "the route runs what its row records")
        XCTAssertEqual(argv, AssemblyRunner.managedAssemblyCLIArguments(
            for: request,
            outputDirectory: AssemblyRunner.executionRequest(for: request).outputDirectory
        ))
        XCTAssertEqual(Array(argv.suffix(3)), ["--reference-bundle", "--format", "json"])
        XCTAssertEqual(item.detail, "the stand-in refused")
    }

    // MARK: - Each key value runs its route (ARCH 7, lane A46 M3)

    /// The Reassemble key's `legacy` value runs the managed pipeline in this process and launches
    /// no `lungfish-cli`. The reads are missing, so the pipeline fails at once.
    func testTheLegacyReassembleRouteRunsInProcessAndLaunchesNoCommand() async throws {
        let root = try TestTempDirectory.make(prefix: "reassemble-legacy-route")
        defer { TestTempDirectory.cleanup(root) }
        let launched = root.appendingPathComponent("launched")
        let cli = try standInCLI("touch '\(launched.path)'; exit 1")
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [root.appendingPathComponent("missing.fastq")],
            projectName: "demo",
            outputDirectory: root.appendingPathComponent("Assemblies", isDirectory: true),
            threads: 1
        ).normalizedForExecution()

        let opID = try XCTUnwrap(AssemblyRunner.startManagedAssembly(
            request: request, routeContext: nil, route: .legacy, runner: CLIReadsRunner(cliURLOverride: cli)
        ))
        defer { OperationCenter.shared.clearItem(id: opID) }
        let ended = await waitUntil(timeout: .seconds(30)) {
            OperationCenter.shared.items.first { $0.id == opID }?.finishedAt != nil
        }

        XCTAssertTrue(ended, "the row ends")
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == opID })
        XCTAssertTrue(
            item.logEntries.contains { $0.message == "Launching managed assembly pipeline" },
            "the in-process pipeline ran: \(item.logEntries.map(\.message))"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched.path), "the legacy route launches no lungfish-cli")
    }

    /// Reassemble reads its key in `runValidated`. `legacy` runs the managed pipeline in this
    /// process and launches no `lungfish-cli`, and `cli` launches the `lungfish-cli` that
    /// LUNGFISH_CLI_PATH names, a stand-in that fails with its `failed` line. An unset key takes the
    /// default, which is the CLI route. The reads are missing, so the in-process run fails at once too.
    func testEachReassembleKeyValueRunsItsRoute() async throws {
        // runValidated asks AppDelegate.shared, which reads NSApp, so the application must exist
        // when this class runs on its own.
        _ = NSApplication.shared
        let saved = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        defer {
            if let saved { setenv("LUNGFISH_CLI_PATH", saved, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        let keyValues: [(String?, Bool)] = [("legacy", false), ("cli", true), (nil, true)]
        for (keyValue, runsCLI) in keyValues {
            let value = keyValue ?? "unset"
            let root = try TestTempDirectory.make(prefix: "reassemble-key-\(value)")
            defer { TestTempDirectory.cleanup(root) }
            let launched = root.appendingPathComponent("launched")
            let cli = try standInCLI("""
            touch '\(launched.path)'
            echo '{"error":"the stand-in refused","event":"failed","schemaVersion":2}'
            exit 1
            """)
            setenv("LUNGFISH_CLI_PATH", cli.path, 1)
            let suite = makeTestDefaultsSuite(prefix: "reads-route")
            if let keyValue { suite.defaults.set(keyValue, forKey: ReadsLaunchPath.assembly.defaultsKey) }
            let request = AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [root.appendingPathComponent("missing.fastq")],
                projectName: "key-\(value)",
                outputDirectory: root.appendingPathComponent("Assemblies", isDirectory: true),
                threads: 1
            )
            let before = Set(OperationCenter.shared.items.map(\.id))

            AssemblyRunner.runValidated(request: request, routeSettings: ReadsLaunchRouteSettings(defaults: suite.defaults))
            var ended: OperationCenter.Item?
            await waitUntil(timeout: .seconds(30)) {
                ended = OperationCenter.shared.items.first {
                    !before.contains($0.id) && $0.title.hasSuffix("Assembly: key-\(value)") && $0.finishedAt != nil
                }
                return ended != nil
            }

            let item = try XCTUnwrap(ended, "the \(value) row never ended")
            defer { OperationCenter.shared.clearItem(id: item.id) }
            XCTAssertEqual(item.state, .failed, "\(value): \(item.detail)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: launched.path), runsCLI, "\(value) launches lungfish-cli only on cli")
            if runsCLI {
                XCTAssertEqual(item.detail, "the stand-in refused", "\(value): the failed line is the row's detail")
            } else {
                XCTAssertTrue(
                    item.logEntries.contains { $0.message == "Launching managed assembly pipeline" },
                    "the in-process pipeline ran: \(item.logEntries.map(\.message))"
                )
            }
        }
    }

    /// Map Reads reads its key at launch. `legacy` runs the in-process route, whose row records the
    /// command without `--format json` and launches no `lungfish-cli`, and `cli` launches the
    /// `lungfish-cli` that LUNGFISH_CLI_PATH names, a stand-in that fails, with the argv its row
    /// records. An unset key takes the default, which is the CLI route. The reads are missing, so
    /// the in-process run fails at once too.
    func testEachMappingKeyValueRunsItsRoute() async throws {
        let saved = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        defer {
            if let saved { setenv("LUNGFISH_CLI_PATH", saved, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        let keyValues: [(String?, Bool)] = [("legacy", false), ("cli", true), (nil, true)]
        for (keyValue, runsCLI) in keyValues {
            let value = keyValue ?? "unset"
            let root = try TestTempDirectory.make(prefix: "map-key-\(value)")
            defer { TestTempDirectory.cleanup(root) }
            let launched = root.appendingPathComponent("launched")
            let cli = try standInCLI("""
            touch '\(launched.path)'
            echo '{"error":"the stand-in refused","event":"failed","schemaVersion":2}'
            exit 1
            """)
            setenv("LUNGFISH_CLI_PATH", cli.path, 1)
            let suite = makeTestDefaultsSuite(prefix: "reads-route")
            if let keyValue { suite.defaults.set(keyValue, forKey: ReadsLaunchPath.mapping.defaultsKey) }
            let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let request = MappingRunRequest(
                tool: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [root.appendingPathComponent("missing.fastq")],
                referenceFASTAURL: root.appendingPathComponent("missing.fasta"),
                projectURL: project,
                outputDirectory: project.appendingPathComponent("Analyses/unused", isDirectory: true),
                sampleName: "key-\(value)",
                threads: 1
            )
            let title = "Map Reads (\(MappingTool.minimap2.displayName)): key-\(value)"
            let before = Set(OperationCenter.shared.items.map(\.id))
            let appDelegate = AppDelegate()

            appDelegate.runManagedMapping(
                plan: MappingRunPlan(requests: [request], mode: .perBundle, warning: nil),
                routeContext: nil,
                routeSettings: ReadsLaunchRouteSettings(defaults: suite.defaults)
            )
            var ended: OperationCenter.Item?
            await waitUntil(timeout: .seconds(30)) {
                ended = OperationCenter.shared.items.first { !before.contains($0.id) && $0.title == title && $0.finishedAt != nil }
                return ended != nil
            }
            withExtendedLifetime(appDelegate) {}

            let item = try XCTUnwrap(ended, "the \(value) row never ended")
            defer { OperationCenter.shared.clearItem(id: item.id) }
            let parsed = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
            XCTAssertEqual(parsed.globalOptions.outputFormat == .json, runsCLI, "\(value): \(item.cliCommand ?? "no command")")
            XCTAssertEqual(FileManager.default.fileExists(atPath: launched.path), runsCLI, "\(value) launches lungfish-cli only on cli")
            XCTAssertEqual(item.state, .failed, "\(value): \(item.detail)")
        }
    }

    // MARK: - A cancel that reaches a finished command (fix 8 of lane A46)

    /// A cancel the row takes after `map` wrote its result, printed its `complete` line and exited 0
    /// keeps the result. The folder stays and is listed, and the row ends cancelled.
    func testACancelThatComesAfterMapFinishedKeepsItsResult() async throws {
        let run = try MappingCancelRun(prefix: "reads-route-late-cancel")
        defer { run.cleanup() }
        let complete = run.root.appendingPathComponent("complete.ndjson")
        let line = try JSONEncoder().encode(CLIEvent.complete(outputs: [run.folder.path], message: "Mapped"))
        try (String(decoding: line, as: UTF8.self) + "\n").write(to: complete, atomically: true, encoding: .utf8)
        let cli = try standInCLI("""
        trap "touch '\(run.marker.path)'" TERM
        touch '\(run.started.path)'
        i=0
        while [ ! -f '\(run.marker.path)' ] && [ $i -lt 50 ]; do /bin/sleep 0.1; i=$((i+1)); done
        /bin/cat '\(complete.path)'
        exit 0
        """)

        let outcome = try await run.cancelOnceStarted(cli: cli)

        XCTAssertTrue(FileManager.default.fileExists(atPath: run.folder.path), "the finished run keeps its folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.marker.path), "the cancel reached the command")
        XCTAssertFalse(AnalysesFolder.isAnalysisIncomplete(run.folder), "the kept folder is listed")
        XCTAssertEqual(outcome.state, .cancelled, "the row ends cancelled")
        XCTAssertTrue(outcome.returned, "the route reports the run as finished")
    }

    /// A cancel `map` honours, with its `failed` line and exit 125, removes the run's folder.
    func testACancelMapHonoursRemovesItsFolder() async throws {
        let run = try MappingCancelRun(prefix: "reads-route-honoured-cancel")
        defer { run.cleanup() }
        let failed = run.root.appendingPathComponent("failed.ndjson")
        try "{\"error\":\"Mapping cancelled\",\"event\":\"failed\",\"schemaVersion\":2}\n"
            .write(to: failed, atomically: true, encoding: .utf8)
        let cli = try standInCLI("""
        trap "/bin/cat '\(failed.path)'; exit 125" TERM
        touch '\(run.started.path)'
        i=0
        while [ $i -lt 50 ]; do /bin/sleep 0.1; i=$((i+1)); done
        exit 0
        """)

        let outcome = try await run.cancelOnceStarted(cli: cli)

        XCTAssertFalse(FileManager.default.fileExists(atPath: run.folder.path), "a cancelled run's folder goes")
        XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertFalse(outcome.returned)
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

/// One run of the mapping key's CLI route on a stand-in `lungfish-cli`, whose folder already holds a
/// result, cancelled from its row once the stand-in has started (fix 8 of lane A46).
@MainActor
private struct MappingCancelRun {
    let root: URL
    let folder: URL
    let request: MappingRunRequest
    /// Touched by the stand-in once it runs.
    let started: URL
    /// Touched by a stand-in that took the cancel's SIGTERM.
    let marker: URL

    init(prefix: String) throws {
        root = try TestTempDirectory.make(prefix: prefix)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        folder = try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: project)
        let reference = root.appendingPathComponent("genome.fasta")
        try ">chr1\nACGTACGTAC\n".write(to: reference, atomically: true, encoding: .utf8)
        request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [root.appendingPathComponent("sampleA.fastq")],
            referenceFASTAURL: reference,
            projectURL: project,
            outputDirectory: folder,
            sampleName: "sampleA",
            threads: 1
        )
        _ = try AppUITestMappingBackend.writeResult(for: request)
        started = root.appendingPathComponent("started")
        marker = root.appendingPathComponent("terminated")
    }

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }

    /// Runs the route on `cli`, cancels its row once the stand-in has started, and returns what the
    /// route returned and the state its row ended in.
    func cancelOnceStarted(cli: URL) async throws -> (returned: Bool, state: OperationCenter.Item.State?) {
        let operation = OperationIDBox()
        let request = self.request
        let folder = self.folder
        let route = Task { @MainActor in
            await AppDelegate().runSingleManagedMappingThroughCLI(
                request: request,
                warning: nil,
                routeContext: nil,
                preassignedAnalysisDirectory: folder,
                runner: CLIReadsRunner(cliURLOverride: cli),
                cancelBatch: {},
                registerCancel: { operation.id = $0 }
            )
        }
        let started = self.started
        let up = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: started.path) }
        XCTAssertTrue(up, "the stand-in never started")
        let opID = try XCTUnwrap(operation.id, "the row never began")
        defer { OperationCenter.shared.clearItem(id: opID) }
        OperationCenter.shared.cancel(id: opID)
        let returned = await route.value
        return (returned, OperationCenter.shared.items.first { $0.id == opID }?.state)
    }
}

@MainActor
private final class OperationIDBox {
    var id: UUID?
}
