// CLIClassifierRunnerTests.swift - The CLI route's runner over CLISubprocessTransport, fed by executor transcripts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10. The runner set of CLIPrimerTrimRunnerTests for `CLIClassifierRunner`: a
// command that exits at once, a cancel that stops the process tree and gives the command its
// grace, the result folder read by its role and then by its place, the frozen version 1 reader,
// and the argv that runs. The transcripts come from the real analysis run executor in process
// (ClassifierCLIRouteFixtures.swift), played by a shell script in place of `lungfish-cli`.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

final class CLIClassifierRunnerTests: XCTestCase {
    // MARK: - Completion

    /// The runner returns once the command exits and reads today's completion detail back from
    /// the result on disk, never from the command's own message (D9).
    func testARunOfACommandThatExitsAtOnceIsReadBackFromDisk() async throws {
        let run = try await completedKraken2Run()
        let cli = try ClassifierRouteFixtures.standInCLI(in: run.root, lines: run.lines)

        let completion = try await CLIClassifierRunner(cliURLOverride: cli).run(run.request, operationID: UUID())

        let expected = try ClassifierRouteFixtures.expectedKraken2Detail(in: run.folder)
        XCTAssertEqual(completion.detail, expected.completionDetail)
        XCTAssertNotEqual(completion.detail, "the command's own detail")
        XCTAssertFalse(completion.completesWithWarning)
        XCTAssertEqual(completion.folder?.standardizedFileURL, run.folder.standardizedFileURL)
        XCTAssertEqual(completion.taxonomyResult?.tree.totalReads, try ClassificationResult.load(from: run.folder).tree.totalReads)
        XCTAssertNil(completion.readBackProblem)
    }

    /// The early `output` line names the folder by its role. A command that writes none still
    /// names it in its completion, the first place of `outputs`, and the run reads the same.
    func testTheResultFolderIsReadByItsRoleThenByItsPlace() async throws {
        let run = try await completedKraken2Run()
        XCTAssertEqual(run.lines.filter { $0.contains(#""role":"analysis-directory""#) }.count, 1)
        let typed = try ClassifierRouteFixtures.standInCLI(in: run.root, lines: run.lines)
        let placed = try ClassifierRouteFixtures.standInCLI(
            in: run.root,
            lines: run.lines.filter { !$0.contains(#""event":"output""#) }
        )

        let byRole = try await CLIClassifierRunner(cliURLOverride: typed).run(run.request, operationID: UUID())
        let byPlace = try await CLIClassifierRunner(cliURLOverride: placed).run(run.request, operationID: UUID())

        XCTAssertEqual(byRole.folder?.standardizedFileURL, run.folder.standardizedFileURL)
        XCTAssertEqual(byPlace.folder?.standardizedFileURL, run.folder.standardizedFileURL)
        XCTAssertEqual(byPlace.detail, byRole.detail)
    }

    /// A result that cannot be read back keeps the command's own detail and names the problem,
    /// which the route logs as one warning line.
    func testAResultThatCannotBeReadBackKeepsTheCommandsDetail() async throws {
        let run = try await completedKraken2Run()
        try FileManager.default.removeItem(at: run.folder.appendingPathComponent("classification-result.json"))
        let cli = try ClassifierRouteFixtures.standInCLI(in: run.root, lines: run.lines)

        let completion = try await CLIClassifierRunner(cliURLOverride: cli).run(run.request, operationID: UUID())

        XCTAssertEqual(completion.detail, "the command's own detail")
        XCTAssertNil(completion.taxonomyResult)
        XCTAssertTrue(completion.readBackProblem?.hasPrefix("The result in \(run.folder.lastPathComponent) could not be read back") == true)
    }

    /// The command runs with exactly the argv the row records.
    func testTheCommandRunsWithEveryArgumentTheRowRecords() async throws {
        let run = try await completedKraken2Run()
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [run.project.appendingPathComponent("Imports/reads.fastq")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: run.root.appendingPathComponent("Viral"),
            databaseDigest: String(repeating: "0f", count: 32),
            brackenProfileRequest: .automaticDefault,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 3,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: run.root.appendingPathComponent("classification-x"),
            extraArguments: ["--minimum-base-quality", "20"]
        )
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [config], projectURL: run.project))
        let transcript = run.root.appendingPathComponent("events.ndjson")
        let argvFile = run.root.appendingPathComponent("argv.txt")
        try (run.lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let cli = run.root.appendingPathComponent("lungfish-cli-argv")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argvFile.path)'\n/bin/cat '\(transcript.path)'\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        _ = try await CLIClassifierRunner(cliURLOverride: cli).run(
            CLIClassifierRunRequest(tool: .kraken2, arguments: launch.arguments, sampleIDs: launch.sampleIDs),
            operationID: UUID()
        )

        let ran = try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(ran, launch.arguments)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: launch.cliCommand), ran)
        for flag in ["--project", "--db-digest", "--format"] {
            XCTAssertTrue(ran.contains(flag), flag)
        }
    }

    // MARK: - Failure

    /// A command that ends with a `failed` line fails with its message, never its detail.
    func testAFailedCommandFailsWithItsMessage() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-failed")
        defer { TestTempDirectory.cleanup(root) }
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: [
            #"{"event":"start","message":"Starting Kraken2.","progress":0,"schemaVersion":2}"#,
            #"{"detail":"the detail","error":"Database 'Viral' is not installed.","event":"failed","schemaVersion":2}"#,
        ], exitStatus: 126)

        do {
            _ = try await CLIClassifierRunner(cliURLOverride: cli).run(
                CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"]),
                operationID: UUID()
            )
            XCTFail("a failed command must throw")
        } catch let failure as CLIClassifierFailure {
            XCTAssertEqual(failure, CLIClassifierFailure(message: "Database 'Viral' is not installed.", errorMessage: nil, errorDetail: nil))
        }
    }

    // MARK: - Cancel

    /// A cancel stops the command and every process it started, also one that ignores SIGTERM,
    /// which SIGKILL stops after the grace. The run ends under 9 seconds after the cancel, inside
    /// the 10 seconds `OperationCenter` waits for a cancelling row before it logs that the worker
    /// did not respond (review fix 7).
    func testACancelStopsTheCommandsProcessTree() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let childPIDURL = root.appendingPathComponent("child.pid")
        let cli = root.appendingPathComponent("lungfish-cli")
        try """
        #!/bin/sh
        nohup /bin/sh -c 'trap "" TERM HUP INT; while :; do sleep 1; done' >/dev/null 2>&1 &
        echo "$!" > "\(childPIDURL.path)"
        printf '%s\\n' '{"event":"start","message":"Starting Kraken2.","progress":0,"schemaVersion":2}'
        while kill -0 "$!" 2>/dev/null; do
          sleep 0.1
        done
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let runner = CLIClassifierRunner(cliURLOverride: cli)
        let run = Task {
            try await runner.run(
                CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"]),
                operationID: UUID()
            )
        }
        let childPID = try await waitForPID(in: childPIDURL)
        defer { ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0) }

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        runner.cancel()
        let outcome = await run.result
        let cancelTook = clock.now - cancelledAt

        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("a cancelled run must end in CancellationError, got \(outcome)")
        }
        XCTAssertLessThan(cancelTook, .seconds(9), "the cancel took \(cancelTook), past the row's cancel window")
        let stopped = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(25)) {
            !ProcessTreeTerminator.processExists(pid: childPID)
        }
        XCTAssertTrue(stopped, "process \(childPID) was still running after the cancel")
    }

    /// E5 and SWIFT X1. The command gets SIGTERM and time to record its run as cancelled before
    /// SIGKILL, so its handler runs and its cancel record is in the folder. The stand-in writes
    /// the record the executor's `settle(.cancelled)` writes.
    func testTheGraceLetsTheCommandRecordItsCancel() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-grace")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("Project.lungfish/Analyses/kraken2-x", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "kraken2", command: "lungfish-cli kraken2 classify"), in: folder)
        let runRecord = AnalysisRunRecord.url(in: folder)
        let commandsCancel = try ClassifierRouteFixtures.cancelledRecord(
            of: runRecord,
            in: root.appendingPathComponent("command-cancel", isDirectory: true)
        )
        let ready = root.appendingPathComponent("ready")
        let terminated = root.appendingPathComponent("terminated")
        let cli = try ClassifierRouteFixtures.cancellableCLI(
            in: root,
            lines: [#"{"event":"start","message":"Starting Kraken2.","progress":0,"schemaVersion":2}"#],
            ready: ready,
            terminated: terminated,
            lastLine: #"{"error":"Kraken2 was cancelled.","event":"failed","schemaVersion":2}"#,
            cancelledRecord: (commandsCancel, runRecord)
        )
        let runner = CLIClassifierRunner(cliURLOverride: cli)
        let run = Task {
            try await runner.run(
                CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"]),
                operationID: UUID()
            )
        }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(25)) {
            FileManager.default.fileExists(atPath: ready.path)
        }
        XCTAssertTrue(started, "the stand-in command never started")

        runner.cancel()
        let outcome = await run.result

        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("a cancelled run must end in CancellationError, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminated.path), "the command's SIGTERM handler never ran")
        XCTAssertEqual(AnalysisRunRecord.load(from: folder)?.outcome, .cancelled, "the command recorded its cancel")
        XCTAssertEqual(try Data(contentsOf: runRecord), try Data(contentsOf: commandsCancel))
        XCTAssertGreaterThanOrEqual(CLIClassifierRunner.terminationGracePeriod, .seconds(5))
        XCTAssertLessThanOrEqual(CLIClassifierRunner.terminationGracePeriod, .seconds(8))
    }

    // MARK: - Version 1

    /// An app of schema version 1 reads the executor's version 2 lines to the same events, with
    /// one last line, so an older app reads the same row.
    func testTheFrozenVersion1ReaderReadsTheTranscriptToTheSameEvents() async throws {
        let run = try await completedKraken2Run()
        let frozen = try run.lines.map { try XCTUnwrap(try FrozenCLIEventV1LineDecoder().decode(line: $0), $0) }
        let current = try run.lines.map { try XCTUnwrap(try CLIEventLineDecoder().decodeLine($0), $0) }

        XCTAssertEqual(frozen.map(\.asCLIEvent), current.compactMap(\.event))
        XCTAssertEqual(current.map(\.schemaVersion), Array(repeating: 2, count: run.lines.count))
        XCTAssertEqual(frozen.filter(\.isTerminal).count, 1)
        XCTAssertTrue(frozen.contains { if case .output = $0 { return true } else { return false } })
    }

    // MARK: - Helpers

    private struct Kraken2Run {
        let root: URL
        let project: URL
        let folder: URL
        let lines: [String]
        let request: CLIClassifierRunRequest
    }

    /// A completed Kraken2 run of one sample into a new project, with the lines the executor printed.
    private func completedKraken2Run() async throws -> Kraken2Run {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let transcript = await ClassifierRouteFixtures.transcript(
            of: StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder),
            project: made.project,
            inputs: made.inputs,
            arguments: ["kraken2", "classify"]
        )
        XCTAssertEqual(transcript.report.status, .completed)
        return Kraken2Run(
            root: root,
            project: made.project,
            folder: try XCTUnwrap(transcript.report.analysisDirectory),
            lines: transcript.lines,
            request: CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"])
        )
    }

    /// The PID the stand-in wrote. The shell creates the file before it writes the number, so an
    /// empty or partial read means not yet.
    private func waitForPID(in url: URL) async throws -> Int32 {
        var pid: Int32?
        await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(25)) {
            pid = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return try XCTUnwrap(pid, "the stand-in never wrote \(url.path)")
    }
}
