// TaxTriageCLIRouteTranscriptReplayTests.swift - The TaxTriage CLI route's transcripts against `taxtriage run` on the stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M3. U30 M2 composed the five transcripts of `Tests/Fixtures/cli-events/commands/taxtriage-run/`
// that `TaxTriageCLIRouteRowTests` plays. Each case here runs the `taxtriage run --project` the CLI route runs for
// one of them, in this process with the command's pipeline seam bound to `TaxTriageStandInEngine`, and checks that
// the committed transcript holds the lines the row reads from the command: the start, the folder, each sample's
// start line, every warning, the database line, the failure and the end. `LUNGFISH_RECAPTURE_CLI_EVENTS=1` writes
// the run's lines, its folder rewritten to `/work`, as the transcript. `failed-cancelled.ndjson` stays composed,
// since the stand-in prints no Docker line (check list row 24). The engine starts processes, so the class name
// ends in ReplayTests, which sends it to the serial replay tier.

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
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        var arguments = ["run"] + inputs.flatMap { ["--input", $0.path] }
        if let sample { arguments += ["--sample", sample] }
        arguments += ["--project", project.path] + (inputs.count > 1 ? ["--batch"] : [])
        arguments += ["--db", database.path, "--nf-profile", TaxTriageStandInEngine.profile, "--max-cpus", "1", "--format", "json"]
        let command = try TaxTriageCommand.RunSubcommand.parse(arguments)
        let collected = OSAllocatedUnfairLock<[String]>(initialState: [])
        do {
            try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
                try await command.execute(events: .jsonLines { line in collected.withLock { $0.append(line) } })
            }
        } catch {
            // A failed run ends with its exit code after the failed line, which the transcript keeps.
        }
        let lines = collected.withLock { $0 }.map(normalized)
        let transcript = Self.transcriptURL(name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Self.rowLines(committed), Self.rowLines(lines), "\(name).ndjson against taxtriage run on the stand-in")
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
    /// line, the database line, every warning, the failure and the end.
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
                guard isSampleStart || message.contains("TaxTriage database") else { return nil }
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
