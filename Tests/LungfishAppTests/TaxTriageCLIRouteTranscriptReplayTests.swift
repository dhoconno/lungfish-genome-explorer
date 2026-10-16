// TaxTriageCLIRouteTranscriptReplayTests.swift - The TaxTriage CLI route's transcripts against `taxtriage run` on the stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M3. U30 M2 composed the five transcripts of `Tests/Fixtures/cli-events/commands/taxtriage-run/`
// that `TaxTriageCLIRouteRowTests` plays. Each case here runs the `taxtriage run --project` the CLI route runs for
// one of them, in this process with the command's pipeline seam bound to `TaxTriageStandInEngine`, and checks that
// the committed transcript holds the lines the row reads from the command: the start, the folder, each sample's
// start line, every warning, the database line, the Docker line, the failure and the end.
// `LUNGFISH_RECAPTURE_CLI_EVENTS=1` writes the run's lines, its folder rewritten to `/work`, as the transcript.
// `failed-cancelled.ndjson` is the run of a cancel while Docker starts (check list row 24). It runs on a pipeline
// whose Docker daemon never answers and is cancelled on the Docker line, before the pipeline asks macOS to start
// Docker Desktop. The engine starts processes, so the class name ends in ReplayTests, which sends it to the serial
// replay tier.

import ArgumentParser
import Foundation
import os
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageCLIRouteTranscriptReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-cli-route-transcript").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testOneCleanSampleMatchesCompleteProject() async throws {
        let inputs = try makeInputs(["S1.fastq"])
        try await assertTranscript("complete-project", inputs: inputs, sample: "S1", behaviour: .completes)
    }

    func testTwoSamplesNamedWithADotAndASpaceMatchCompleteBatch() async throws {
        let inputs = try await makeGzippedInputs(["S.1.fastq.gz", "blank 1.fastq.gz"])
        try await assertTranscript("complete-batch", inputs: inputs, sample: nil, behaviour: .completes)
    }

    func testIgnoredTasksMatchCompleteWithWarning() async throws {
        let inputs = try makeInputs(["S1.fastq"])
        try await assertTranscript("complete-with-warning", inputs: inputs, sample: "S1", behaviour: .reportsErroredTasks)
    }

    func testAFailedSampleMatchesFailed() async throws {
        let inputs = try makeInputs(["S1.fastq"])
        try await assertTranscript("failed", inputs: inputs, sample: "S1", behaviour: .failsSamples(["S1"]))
    }

    /// Check list row 24, a cancel while Docker starts. The command runs with the docker profile on a pipeline
    /// whose daemon never answers, so its wait says `Docker daemon unavailable. Launching Docker Desktop...`
    /// before it asks macOS to start Docker Desktop. The sink cancels the task that delivers that line, which is
    /// the task that waits, so the wait ends at once and Docker Desktop never starts, as
    /// `TaxTriageEngineProcessReplayTests.testACancelDuringTheDockerWaitEndsTheRunAtOnce` shows for the pipeline.
    /// The executor then ends the run as a cancel, a `failed` line `TaxTriage was cancelled.` and exit 125.
    func testACancelWhileDockerStartsMatchesFailedCancelled() async throws {
        let inputs = try makeInputs(["S1.fastq"])
        let engine = try TaxTriageStandInEngine(
            root: root.appendingPathComponent("engine", isDirectory: true), behaviour: .completes, maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        let home = engine.home
        let pipeline = TaxTriagePipeline(
            condaManager: engine.condaManager,
            homeDirectoryProvider: { home },
            appIdentity: .preview,
            containerRuntimeProbe: UnreachableDockerProbe()
        )
        let command = try TaxTriageCommand.RunSubcommand.parse(
            try commandArguments(inputs: inputs, sample: "S1", profile: "docker")
        )
        let dockerLine = "Docker daemon unavailable. Launching Docker Desktop..."
        let collected = OSAllocatedUnfairLock<[String]>(initialState: [])
        let events = AnalysisRunEvents.jsonLines { line in
            collected.withLock { $0.append(line) }
            if line.contains(dockerLine) {
                // The wait says this before it runs `open`, so the cancel lands first and the run never
                // asks macOS to start Docker Desktop.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let exitCode = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        let ended = OSAllocatedUnfairLock(initialState: false)
        _ = Task {
            do {
                try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ pipeline }) {
                    try await command.execute(events: events)
                }
            } catch let code as ExitCode {
                exitCode.withLock { $0 = code.rawValue }
            } catch {
                // Another end shows as a missing exit code and in the lines below.
            }
            ended.withLock { $0 = true }
        }
        let finished = await waitUntil(timeout: .seconds(30)) { ended.withLock { $0 } }
        XCTAssertTrue(finished, "the cancelled run never ended")

        let lines = collected.withLock { $0 }.map(normalized)
        XCTAssertEqual(try engine.launches().count, 0, "no engine starts once the run is cancelled")
        XCTAssertEqual(exitCode.withLock { $0 }, 125, "a cancel exits 125, and the lines are \(lines)")
        XCTAssertEqual(lines.filter { $0.contains(dockerLine) }.count, 1, "the Docker line, once: \(lines)")
        let last = lines.last ?? "no line"
        XCTAssertTrue(last.contains(#""error":"TaxTriage was cancelled.""#) && last.contains(#""event":"failed""#), last)
        try compare("failed-cancelled", with: lines)
    }

    // MARK: - One transcript

    /// Runs the CLI route's command for `inputs` on a stand-in with `behaviour`, writes its lines as the
    /// transcript `name` when asked, and checks that the committed transcript reads as the run does.
    private func assertTranscript(
        _ name: String,
        inputs: [URL],
        sample: String?,
        behaviour: TaxTriageStandInEngine.Behaviour
    ) async throws {
        let engine = try TaxTriageStandInEngine(
            root: root.appendingPathComponent("engine", isDirectory: true), behaviour: behaviour, maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        let command = try TaxTriageCommand.RunSubcommand.parse(
            try commandArguments(inputs: inputs, sample: sample, profile: TaxTriageStandInEngine.profile)
        )
        let collected = OSAllocatedUnfairLock<[String]>(initialState: [])
        do {
            try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
                try await command.execute(events: .jsonLines { line in collected.withLock { $0.append(line) } })
            }
        } catch {
            // A failed run ends with its exit code after the failed line, which the transcript keeps.
        }
        try compare(name, with: collected.withLock { $0 }.map(normalized))
    }

    /// Writes `lines` as the transcript `name` when `LUNGFISH_RECAPTURE_CLI_EVENTS=1` asks, and checks that the
    /// committed transcript reads as they do.
    private func compare(_ name: String, with lines: [String]) throws {
        let transcript = Self.transcriptURL(name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Self.rowLines(committed), Self.rowLines(lines), "\(name).ndjson against taxtriage run on the stand-in")
    }

    /// The arguments of the `taxtriage run --project` the CLI route runs for `inputs`, with JSON events.
    private func commandArguments(inputs: [URL], sample: String?, profile: String) throws -> [String] {
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        var arguments = ["run"] + inputs.flatMap { ["--input", $0.path] }
        if let sample { arguments += ["--sample", sample] }
        arguments += ["--project", project.path] + (inputs.count > 1 ? ["--batch"] : [])
        arguments += ["--db", database.path, "--nf-profile", profile, "--max-cpus", "1", "--format", "json"]
        return arguments
    }

    private var project: URL { root.appendingPathComponent("Project.lungfish", isDirectory: true) }

    private func makeInputs(_ names: [String]) throws -> [URL] {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        return try names.map { name in
            let url = imports.appendingPathComponent(name)
            try Self.reads(name).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private func makeGzippedInputs(_ names: [String]) async throws -> [URL] {
        let plain = try makeInputs(names.map { ($0 as NSString).deletingPathExtension })
        var gzipped: [URL] = []
        for url in plain {
            let gz = url.appendingPathExtension("gz")
            try await SystemToolProbe.gzip(url, to: gz)
            try FileManager.default.removeItem(at: url)
            gzipped.append(gz)
        }
        return gzipped
    }

    private static func reads(_ name: String) -> String {
        (1...3).map { "@\(name)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// `line` with this case's folder rewritten to `/work`, as the transcripts keep it.
    private func normalized(_ line: String) -> String {
        line.replacingOccurrences(of: root.path.replacingOccurrences(of: "/", with: "\\/"), with: "\\/work")
            .replacingOccurrences(of: root.path, with: "/work")
    }

    private static func transcriptURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/cli-events/commands/taxtriage-run/\(name).ndjson")
    }

    /// The lines of a transcript the CLI route's row reads (`CLIClassifierRowEvents`), each as its event and
    /// words, with the result folder's timestamp masked: the start, the folder line, each sample's start
    /// line, the database line, the Docker line, every warning, the failure and the end.
    static func rowLines(_ lines: [String]) -> [String] {
        lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String else { return "undecodable \(line)" }
            let words: String?
            switch event {
            case "start", "complete": words = object["message"] as? String
            case "output": words = object["role"] as? String
            case "failed": words = object["error"] as? String
            case "progress":
                let message = object["message"] as? String ?? ""
                let isSampleStart = message.hasPrefix("Running ") && message.hasSuffix(".")
                guard isSampleStart || message.contains("TaxTriage database") || message.hasPrefix("Docker daemon") else { return nil }
                words = message
            case "log":
                guard object["level"] as? String == "warning" else { return nil }
                words = object["message"] as? String
            default: words = nil
            }
            return "\(event) \(words ?? "")".replacingOccurrences(
                of: "taxtriage-batch-[0-9T-]+", with: "taxtriage-batch-<timestamp>", options: .regularExpression
            )
        }
    }
}

/// A Docker probe whose daemon never answers, as `TaxTriageEngineProcessReplayTests` uses to reach the wait for
/// Docker, which says its words before it asks macOS to start Docker Desktop.
private struct UnreachableDockerProbe: ContainerRuntimeProbing {
    func dockerCLIPath() -> String? { "/usr/local/bin/docker" }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        DockerDaemonProbe(reachable: false, clientVersion: "28.3.2", serverVersion: nil, detail: "Cannot connect to the Docker daemon")
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    }
}
